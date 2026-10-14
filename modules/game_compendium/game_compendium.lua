-- Game Compendium: in-game news, guides and client information.

local BUNDLED_NEWS_FILE = "/game_compendium/compendium.json"
local CACHED_NEWS_FILE = "/compendium_cache.json"
local IMAGES_PATH = "/game_compendium/images/"
local MAX_NEWS_FILE_SIZE = 10 * 1024 * 1024

local OTC_CATEGORY = "OTC"
local OTC_REDEMPTION_TITLE = "OTC Redemption"
local OTC_REDEMPTION_URL =
    "https://raw.githubusercontent.com/kokekanon/OTredemption-Picture-NODELETE/refs/heads/main/Wiki/readme.html"

-- Display order and presentation of the known news categories.
local CATEGORIES = {
    { id = "MAJOR UPDATES", text = "Major Updates", icon = "icon-news-major-updates" },
    { id = "PLAYER GUIDE", text = "Player Guide", icon = "icon-news-player-guide" },
    { id = "CLIENT FEATURES", text = "Client Features", icon = "icon-news-client-features" },
    { id = "USEFUL INFO", text = "Useful Info", icon = "icon-news-useful-info" },
    { id = "SUPPORT", text = "Support", icon = "icon-news-support" }
}
local DEFAULT_CATEGORY_ICON = "icon-news-player-guide"
local CATEGORY_BUTTON_HEIGHT = 36
local CATEGORY_BUTTON_SPACING = 1 -- must match the #categoryPanel layout spacing

compendiumController = Controller:new()

local compendiumButton = nil
local treeView = nil
local categoryRadioGroup = nil
local newsData = nil
local needsRebuild = true
local newsRequestId = nil
local otcRequestId = nil
local otcPageCache = nil
local contentToken = 0

-- /*=============================================
-- =            Helpers                  =
-- =============================================*/

local function isUiAlive()
    local ui = compendiumController.ui
    return ui ~= nil and not ui:isDestroyed()
end

local function cancelRequest(operationId)
    if operationId then
        HTTP.cancel(operationId)
    end
    return nil
end

local function normalizeCategory(category)
    if type(category) ~= "string" or category == "" then
        return nil
    end
    return category:upper()
end

local function getCategoryInfo(categoryId)
    for _, info in ipairs(CATEGORIES) do
        if info.id == categoryId then
            return info
        end
    end

    local text = categoryId:lower():gsub("(%a)(%w*)", function(first, rest)
        return first:upper() .. rest
    end)
    return { id = categoryId, text = text, icon = DEFAULT_CATEGORY_ICON }
end

-- The HTML engine evaluates "on*" handlers and "*" bindings as Lua code, so tags are
-- rebuilt keeping only presentational attributes.
local ALLOWED_HTML_ATTRIBUTES = {
    style = true, width = true, height = true, src = true, alt = true, href = true,
    align = true, valign = true, border = true, cellpadding = true, cellspacing = true,
    colspan = true, rowspan = true, vspace = true, hspace = true, title = true, bgcolor = true
}

local function stripUnsafeAttributes(tag)
    local tagName, pos = tag:match("^<([%w]+)()")
    if not tagName then
        return ""
    end

    local parts = { "<", tagName }
    local tagEnd = #tag - 1
    while pos <= tagEnd do
        local nextPos = tag:match("^[%s/]+()", pos)
        if nextPos then
            pos = nextPos
        else
            local name, afterName = tag:match("^([^%s=/>\"'`<]+)()", pos)
            if not name then
                pos = pos + 1
            else
                pos = afterName
                local value
                local eqPos = tag:match("^%s*=%s*()", pos)
                if eqPos then
                    local quote = tag:sub(eqPos, eqPos)
                    if quote == '"' or quote == "'" then
                        local closing = tag:find(quote, eqPos + 1, true)
                        if not closing or closing > tagEnd then
                            closing = tagEnd + 1
                        end
                        value = tag:sub(eqPos + 1, closing - 1)
                        pos = closing + 1
                    else
                        local raw, afterValue = tag:match("^([^%s>\"'`<]*)()", eqPos)
                        value = raw
                        pos = afterValue
                    end
                end

                if ALLOWED_HTML_ATTRIBUTES[name:lower()] then
                    if value then
                        parts[#parts + 1] = string.format(' %s="%s"', name, (value:gsub('"', "&quot;")))
                    else
                        parts[#parts + 1] = " " .. name
                    end
                end
            end
        end
    end

    if tag:match("/%s*>$") then
        parts[#parts + 1] = " /"
    end
    parts[#parts + 1] = ">"
    return table.concat(parts)
end

-- Remote/bundled content is untrusted: drop scripts, styles and Lua-evaluated attributes.
local function sanitizeHtml(text)
    if type(text) ~= "string" then
        return ""
    end

    text = text:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<[sS][cC][rR][iI][pP][tT].-</[sS][cC][rR][iI][pP][tT]%s*>", "")
    text = text:gsub("<[sS][tT][yY][lL][eE].-</[sS][tT][yY][lL][eE]%s*>", "")
    -- Text between "{{" and "}}" is evaluated as Lua by the HTML engine.
    while text:find("{{", 1, true) do
        text = text:gsub("{{", "{ {")
    end
    -- Relative/empty image sources would resolve against the module folder and fail to load.
    text = text:gsub("<[iI][mM][gG][^>]*>", function(tag)
        if tag:find("[sS][rR][cC]%s*=%s*[\"']?[hH][tT][tT][pP][sS]?://") then
            return tag
        end
        return ""
    end)
    text = text:gsub("<[%a][^>]*>", stripUnsafeAttributes)
    -- The HTML engine does not draw list markers, so numbers/bullets are added as text.
    text = text:gsub("<[lL][iI]>", "<li>- ")
    text = text:gsub("<[lL][iI](%s[^>]*)>", "<li%1>- ")
    text = text:gsub("(<[oO][lL][^>]*>)(.-)(</[oO][lL]%s*>)", function(open, body, close)
        local index = 0
        body = body:gsub("<li([^>]*)>%- ", function(attrs)
            index = index + 1
            return string.format("<li%s>%d. ", attrs, index)
        end)
        return open .. body .. close
    end)
    return text
end

local function formatTimestamp(timestamp)
    timestamp = tonumber(timestamp)
    if not timestamp or timestamp <= 0 then
        return nil
    end
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

local function getDataTimestamp(data)
    if type(data) ~= "table" then
        return 0
    end
    return math.max(tonumber(data.lastupdatetimestamp) or 0, tonumber(data.maxeditdate) or 0)
end

local function isValidNewsData(data)
    return type(data) == "table" and type(data.gamenews) == "table"
end

-- /*=============================================
-- =            Json                  =
-- =============================================*/

local function readNewsFile(path)
    if not g_resources.fileExists(path) then
        return nil
    end

    local status, result = pcall(function()
        return json.decode(g_resources.readFileContents(path))
    end)
    if not status then
        g_logger.error(string.format("[Compendium] Unable to read '%s': %s", path, tostring(result)))
        return nil
    end

    if not isValidNewsData(result) then
        g_logger.warning(string.format("[Compendium] Ignoring '%s': missing gamenews", path))
        return nil
    end
    return result
end

local function loadLocalNews()
    local bundled = readNewsFile(BUNDLED_NEWS_FILE)
    local cached = readNewsFile(CACHED_NEWS_FILE)
    if cached and (not bundled or getDataTimestamp(cached) >= getDataTimestamp(bundled)) then
        return cached
    end
    return bundled
end

local function saveNewsCache(data)
    local status, result = pcall(json.encode, data, 2)
    if not status then
        g_logger.error("[Compendium] Unable to encode news data: " .. tostring(result))
        return false
    end
    if result:len() > MAX_NEWS_FILE_SIZE then
        g_logger.error("[Compendium] News data is too large, cache not saved")
        return false
    end

    local saved, err = pcall(g_resources.writeFileContents, CACHED_NEWS_FILE, result)
    if not saved then
        g_logger.error("[Compendium] Unable to save news cache: " .. tostring(err))
        return false
    end
    return true
end

-- /*=============================================
-- =            Content                  =
-- =============================================*/

-- Rendering is deferred and coalesced so rapid entry switches only build the last selection,
-- and pending HTML layout tasks of the previous content are not destroyed mid-flush.
local function renderContent(token, title, message)
    if token ~= contentToken or not isUiAlive() then
        return
    end

    local contentPanel = compendiumController:findWidget("#contentPanel")
    if contentPanel then
        contentPanel:setTitle(title or "")
    end

    local contentArea = compendiumController:findWidget("#contentArea")
    if not contentArea then
        return
    end

    local html = sanitizeHtml(message)
    if html:trim() == "" then
        contentArea:destroyChildren()
    else
        contentArea:html(html)
    end

    if contentArea.verticalScrollBar then
        contentArea.verticalScrollBar:setValue(0)
    end
end

local function setContent(title, message)
    contentToken = contentToken + 1
    local token = contentToken
    addEvent(function()
        renderContent(token, title, message)
    end)
    return token
end

local function showOtcRedemption()
    if otcPageCache then
        setContent(OTC_REDEMPTION_TITLE, otcPageCache)
        return
    end

    local token = setContent(OTC_REDEMPTION_TITLE, "<p>Loading...</p>")
    otcRequestId = cancelRequest(otcRequestId)
    otcRequestId = HTTP.get(OTC_REDEMPTION_URL, function(data, err)
        otcRequestId = nil
        if err or type(data) ~= "string" or data == "" then
            g_logger.warning("[Compendium] Unable to load the OTC Redemption page: " .. tostring(err or "empty response"))
            if token == contentToken then
                setContent(OTC_REDEMPTION_TITLE,
                    "<p>Unable to load the OTC Redemption page. Please check your connection and try again.</p>")
            end
            return
        end

        otcPageCache = data
        if token == contentToken then
            setContent(OTC_REDEMPTION_TITLE, otcPageCache)
        end
    end)
end

-- /*=============================================
-- =            build treeView                  =
-- =============================================*/

-- The tree is not an HTML node, so the list does not notice when its height changes
-- (category filter, group expand/collapse) and the scroll range must be refreshed manually.
local function refreshEntryListScroll(resetToTop)
    local function refresh()
        if not isUiAlive() then
            return
        end

        local entryList = compendiumController:findWidget("#entryList")
        if not entryList or entryList:isDestroyed() then
            return
        end

        entryList:updateScrollBars()
        local scrollBar = entryList.verticalScrollBar
        if scrollBar and resetToTop then
            scrollBar:setValue(scrollBar:getMinimum())
        end
    end

    refresh()
    -- The tree relayouts (and resizes) after the filter/expand call returns.
    addEvent(refresh)
end

local function destroyCategoryButtons()
    if categoryRadioGroup then
        categoryRadioGroup.onSelectionChange = nil
        categoryRadioGroup:destroy()
        categoryRadioGroup = nil
    end

    local categoryPanel = compendiumController:findWidget("#categoryPanel")
    if categoryPanel then
        categoryPanel:destroyChildren()
    end
end

local function createCategoryButton(parent, id, text, icon)
    local button = g_ui.createWidget("ButtonTibia14", parent)
    button:setId((id:gsub("%s", "_")))
    button.categoryId = id
    button:setText(text)
    button:setHeight(CATEGORY_BUTTON_HEIGHT)
    button.icon:setImageSource(icon)
    button.icon:setImageSize("32 32")
    button.icon:setSize({ width = 32, height = 32 })
    -- Shift the centered label right of the 32px icon so long names are not covered.
    button:setTextOffset({ x = 18, y = 0 })
    return button
end

-- Spread the panel width over the buttons (remainder pixels go to the first ones) so the row
-- always ends exactly at the panel edge.
local function fitCategoryButtons()
    if not isUiAlive() then
        return
    end

    local categoryPanel = compendiumController:findWidget("#categoryPanel")
    if not categoryPanel or categoryPanel:isDestroyed() then
        return
    end

    local buttons = categoryPanel:getChildren()
    local count = #buttons
    if count == 0 then
        return
    end

    local available = categoryPanel:getPaddingRect().width - CATEGORY_BUTTON_SPACING * (count - 1)
    -- ButtonTibia14 uses negative margins, so neighbours overlap; the margins are part of the row width.
    for _, button in ipairs(buttons) do
        available = available - button:getMarginLeft() - button:getMarginRight()
    end
    if available <= 0 then
        return
    end

    local baseWidth = math.floor(available / count)
    local remainder = available - baseWidth * count
    for index, button in ipairs(buttons) do
        button:setWidth(baseWidth + (index <= remainder and 1 or 0))
    end
end

local function createCategoryButtons(presentCategories)
    destroyCategoryButtons()

    local categoryPanel = compendiumController:findWidget("#categoryPanel")
    if not categoryPanel then
        return
    end

    local ordered = {}
    for _, info in ipairs(CATEGORIES) do
        if presentCategories[info.id] then
            table.insert(ordered, info)
        end
    end

    local unknown = {}
    for categoryId in pairs(presentCategories) do
        local known = categoryId == OTC_CATEGORY
        for _, info in ipairs(CATEGORIES) do
            if info.id == categoryId then
                known = true
                break
            end
        end
        if not known then
            table.insert(unknown, getCategoryInfo(categoryId))
        end
    end
    table.sort(unknown, function(a, b)
        return a.id < b.id
    end)
    for _, info in ipairs(unknown) do
        table.insert(ordered, info)
    end

    categoryRadioGroup = UIRadioGroup.create()
    for _, info in ipairs(ordered) do
        local button = createCategoryButton(categoryPanel, info.id, info.text, IMAGES_PATH .. info.icon)
        categoryRadioGroup:addWidget(button)
    end

    local otcButton = createCategoryButton(categoryPanel, OTC_CATEGORY, OTC_CATEGORY, IMAGES_PATH .. "otcicon")
    otcButton.icon:setImageSize("16 16")
    categoryRadioGroup:addWidget(otcButton)
    fitCategoryButtons()

    categoryRadioGroup.onSelectionChange = function(_, selectedWidget)
        if selectedWidget and treeView then
            treeView:filterByFlag("category", selectedWidget.categoryId, true)
            refreshEntryListScroll(true)
        end
    end

    local defaultButton = categoryRadioGroup:getFirstWidget()
    if defaultButton then
        categoryRadioGroup:selectWidget(defaultButton)
    end
end

local function addOtcContent()
    treeView:addCategory(OTC_REDEMPTION_TITLE, "/images/icons/icon_controls", showOtcRedemption, nil, {
        category = OTC_CATEGORY,
        type = "REGULAR",
        id = "otc-redemption"
    })
end

local function buildNewsUI()
    if not treeView or not isUiAlive() then
        return
    end

    treeView:clearCategories()
    setContent("", "")

    local data = newsData or { gamenews = {} }
    local headers = {}
    local presentCategories = {}

    local function createCallback(entry)
        return function()
            setContent(entry.headline, entry.message)
        end
    end

    -- Group headers first, since entries can reference headers declared later in the data.
    for _, entry in ipairs(data.gamenews) do
        if type(entry) == "table" and entry.id ~= nil and tostring(entry.type):upper() == "GROUP HEADER" then
            local category = normalizeCategory(entry.category)
            if category then
                presentCategories[category] = true
            end
            headers[entry.id] = treeView:addCategory(tostring(entry.headline or ""), "", createCallback(entry), nil, {
                category = category,
                type = "GROUP HEADER",
                id = entry.id
            })
        end
    end

    for _, entry in ipairs(data.gamenews) do
        local entryType = type(entry) == "table" and tostring(entry.type):upper() or nil
        if entryType == "REGULAR" or entryType == "RETURNER" then
            local parent = entry.groupheaderid ~= nil and headers[entry.groupheaderid] or nil
            local category = normalizeCategory(entry.category)
            if not category and parent then
                category = parent.flags.category
            end
            if category then
                presentCategories[category] = true
            end

            local flags = { category = category, type = entryType, id = entry.id }
            local headline = tostring(entry.headline or "")
            if parent then
                treeView:addSubCategory(parent, headline, "", createCallback(entry), nil, flags)
            else
                treeView:addCategory(headline, "", createCallback(entry), nil, flags)
            end
        end
    end

    addOtcContent()
    createCategoryButtons(presentCategories)

    local lastUpdateLabel = compendiumController:findWidget("#lastUpdateLabel")
    if lastUpdateLabel then
        local date = formatTimestamp(getDataTimestamp(data))
        lastUpdateLabel:setText(date and tr("Last update: %s", date) or "")
        lastUpdateLabel:setVisible(date ~= nil)
    end

    needsRebuild = false
end

-- /*=============================================
-- =            HTTP                  =
-- =============================================*/

local function requestRemoteNews()
    if newsRequestId or not Services or type(Services.status) ~= "string" or Services.status == "" then
        return
    end

    newsRequestId = HTTP.post(Services.status, json.encode({ type = "news" }), function(message, err)
        newsRequestId = nil
        if err then
            g_logger.warning("[Compendium] News request failed: " .. tostring(err))
            return
        end

        local jsonPart = type(message) == "string" and message:match("{.*}") or nil
        if not jsonPart then
            g_logger.warning("[Compendium] News response does not contain JSON")
            return
        end

        local status, remoteNews = pcall(json.decode, jsonPart)
        if not status or not isValidNewsData(remoteNews) or #remoteNews.gamenews == 0 then
            g_logger.warning("[Compendium] News response has an invalid format")
            return
        end

        saveNewsCache(remoteNews)
        newsData = remoteNews
        needsRebuild = true
        if isUiAlive() and compendiumController.ui:isVisible() then
            buildNewsUI()
        end
    end, false)
end

-- /*=============================================
-- =            Windows                  =
-- =============================================*/

function show()
    if not isUiAlive() then
        return
    end

    compendiumController.ui:show()
    compendiumController.ui:raise()
    compendiumController.ui:focus()
    if compendiumButton then
        compendiumButton:setOn(true)
    end

    if not newsData then
        newsData = loadLocalNews()
        needsRebuild = true
    end
    if needsRebuild then
        buildNewsUI()
    end
    requestRemoteNews()
end

function hide()
    if not isUiAlive() then
        return
    end

    compendiumController.ui:hide()
    if compendiumButton then
        compendiumButton:setOn(false)
    end
end

function toggle()
    if not isUiAlive() then
        return
    end

    if compendiumController.ui:isVisible() then
        hide()
    else
        show()
    end
end

function compendiumController:hide()
    hide()
end

-- /*=============================================
-- =            Controller                  =
-- =============================================*/

function compendiumController:onInit()
    self:loadHtml("game_compendium.html")
    self.ui:hide()

    local entryList = self:findWidget("#entryList")
    treeView = UITreeView.create()
    treeView:setId("compendiumTreeView")
    treeView:setup(entryList, self:findWidget("#contentArea"))
    treeView:setAutoSelectFirstSubCategory(true)
    treeView:setCategorySpacing(8)
    treeView:setUseSubCategoryIndentation(true)
    treeView:setMargin(15)

    -- The tree is not an HTML node, so keep its width in sync with the list (minus its scrollbar).
    local function fitTreeToList()
        if not treeView or treeView:isDestroyed() or entryList:isDestroyed() then
            return
        end
        local scrollBar = entryList.verticalScrollBar
        local scrollBarWidth = scrollBar and scrollBar:getWidth() or 0
        local width = entryList:getPaddingRect().width - scrollBarWidth
        if width > 0 then
            treeView:setWidth(width)
        end
    end
    self:registerUIEvents(entryList, {
        onGeometryChange = fitTreeToList
    })
    self:registerUIEvents(treeView, {
        onGeometryChange = function()
            refreshEntryListScroll(false)
        end
    })
    self:registerUIEvents(self:findWidget("#categoryPanel"), {
        onGeometryChange = fitCategoryButtons
    })
    fitTreeToList()
end

function compendiumController:onTerminate()
    contentToken = contentToken + 1
    newsRequestId = cancelRequest(newsRequestId)
    otcRequestId = cancelRequest(otcRequestId)
    destroyCategoryButtons()

    if treeView then
        if not treeView:isDestroyed() then
            treeView:clearCategories()
            treeView:destroy()
        end
        treeView = nil
    end

    if compendiumButton then
        compendiumButton:destroy()
        compendiumButton = nil
    end

    newsData = nil
    otcPageCache = nil
    needsRebuild = true
end

function compendiumController:onGameStart()
    if not compendiumButton then
        compendiumButton = modules.game_mainpanel.addToggleButton("compendiumButton", tr("Compendium"),
            IMAGES_PATH .. "button_compendium", toggle, false, 22)
        -- button_compendium is a vertical sprite: normal state at y 0-20, active state at y 20-40.
        if compendiumButton then
            compendiumButton:mergeStyle({
                ["$pressed"] = { ["image-clip"] = "0 20 20 20" },
                ["$on"] = { ["image-clip"] = "0 20 20 20" }
            })
        end
    end
end

function compendiumController:onGameEnd()
    hide()
    otcRequestId = cancelRequest(otcRequestId)
end

-- __SMOKE_BEGIN__
scheduleEvent(function()
    local L = function(...) g_logger.info("[CompendiumTest] " .. string.format(...)) end
    local function mark(name) L("%s", name); g_resources.writeFileContents("/smoke_mark.txt", name) end
    if rootWidget.__smoke then return end
    rootWidget.__smoke = true
    L("writeDir=%s", g_resources.getWriteDir())
    show()
    compendiumController:onGameStart()
    scheduleEvent(function()
        local c = compendiumButton:getImageClip()
        L("toggle size=%dx%d clip off=%d,%d,%d,%d", compendiumButton:getWidth(), compendiumButton:getHeight(), c.x, c.y, c.width, c.height)
        compendiumButton:setOn(true)
        scheduleEvent(function()
            local c2 = compendiumButton:getImageClip()
            L("toggle clip on=%d,%d,%d,%d", c2.x, c2.y, c2.width, c2.height)
            compendiumButton:setOn(false)
        end, 200)
    end, 300)
    scheduleEvent(function()
        local panel = compendiumController:findWidget("#categoryPanel")
        local pr = panel:getPaddingRect()
        local parts = {}
        for _, b in ipairs(panel:getChildren()) do local r = b:getRect(); parts[#parts+1] = string.format("%s[x=%d w=%d]", b:getId(), r.x, r.width) end
        L("panel rect x=%d w=%d padRect x=%d w=%d | %s", panel:getRect().x, panel:getRect().width, pr.x, pr.width, table.concat(parts, " "))
        local entryList = compendiumController:findWidget("#entryList")
        local sb = entryList.verticalScrollBar
        local buttons = panel:getChildren()
        local function checkCat(i)
            if i > #buttons then
                local ids = { 1, 2, 28, 35, 97, 115 }
                local function renderNext(j)
                    if j > #ids then
                        mark("DONE")
                        scheduleEvent(function() g_app.exit() end, 2500)
                        return
                    end
                    local entry
                    for _, e in ipairs(newsData.gamenews) do if e.id == ids[j] then entry = e end end
                    setContent(entry.headline, entry.message)
                    scheduleEvent(function()
                        local area = compendiumController:findWidget("#contentArea")
                        local ar = area:getPaddingRect()
                        local count, overflow, fonts, over = 0, 0, {}, {}
                        local function walk(w)
                            for _, c in ipairs(w:getChildren()) do
                                if c:isVisible() then
                                    count = count + 1
                                    local r = c:getRect()
                                    if r.x + r.width > ar.x + ar.width + 2 then overflow = overflow + 1; if #over < 3 then over[#over+1] = string.format("%s(%s)w=%d", c:getId(), c:getStyleName(), r.width) end end
                                    local t = c:getText()
                                    if t and #t > 0 then fonts[c:getFont()] = (fonts[c:getFont()] or 0) + 1 end
                                    walk(c)
                                end
                            end
                        end
                        walk(area)
                        local fl = {}
                        for f, n in pairs(fonts) do fl[#fl+1] = f .. ":" .. n end
                        L("entry %d '%s' widgets=%d areaW=%d overflowing=%d %s fonts=[%s] scrollMax=%s", ids[j], entry.headline, count, ar.width, overflow, table.concat(over, ","), table.concat(fl, ", "), area.verticalScrollBar and area.verticalScrollBar:getMaximum())
                        mark("SHOT_" .. ids[j])
                        scheduleEvent(function() renderNext(j + 1) end, 2500)
                    end, 3000)
                end
                renderNext(1)
                return
            end
            categoryRadioGroup:selectWidget(buttons[i])
            scheduleEvent(function()
                local visible = 0
                L("category %s visibleCats=%d scroll min=%s max=%s value=%s listH=%d treeH=%d", buttons[i].categoryId, visible, sb:getMinimum(), sb:getMaximum(), sb:getValue(), entryList:getHeight(), treeView:getHeight())
                checkCat(i + 1)
            end, 300)
        end
        checkCat(1)
    end, 1000)
end, 4000)
-- __SMOKE_END__
