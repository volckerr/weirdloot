local addon = WeirdLoot
local util = addon.util

local ROW_HEIGHT = 22
local TAB_KEYS = { "loot", "results", "raiders", "master", "options" }
local TAB_LABELS = {
    loot = "Loot",
    raiders = "Roster",
    results = "Loot Results",
    master = "Loot Master",
    options = "Options",
}

local function createLabel(parent, text, anchor, relativeTo, relativePoint, offsetX, offsetY)
    local fontString = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontString:SetPoint(anchor, relativeTo, relativePoint, offsetX, offsetY)
    fontString:SetJustifyH("LEFT")
    fontString:SetText(text)
    return fontString
end

local function elevateInteractiveFrame(frame, parent, extraLevel)
    if not frame or not parent or type(parent.GetFrameLevel) ~= "function" then
        return
    end
    if type(parent.GetFrameStrata) == "function" then
        frame:SetFrameStrata(parent:GetFrameStrata())
    end
    frame:SetFrameLevel((parent:GetFrameLevel() or 0) + (extraLevel or 5))
end

local function createButton(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    elevateInteractiveFrame(button, parent, 8)
    button:SetWidth(width)
    button:SetHeight(height)
    button:SetText(text)
    return button
end

-- attach a hover tooltip (title + wrapped body) to a button
local function setButtonTooltip(button, title, body)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(title, 1, 0.82, 0)
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function createBackdropFrame(name, parent)
    local frame = CreateFrame("Frame", name, parent)
    elevateInteractiveFrame(frame, parent, 1)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
    return frame
end

local function createTextWindow(name, width, height, titleText, options)
    options = options or {}
    local frame = createBackdropFrame(name, UIParent)
    frame:SetWidth(width)
    frame:SetHeight(height)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(selfFrame)
        selfFrame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(selfFrame)
        selfFrame:StopMovingOrSizing()
    end)
    frame:Hide()

    local title = createLabel(frame, titleText or "", "TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetFontObject(GameFontHighlightLarge)

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    elevateInteractiveFrame(closeButton, frame, 10)
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local scroll = CreateFrame("ScrollFrame", name .. "Scroll", frame, "UIPanelScrollFrameTemplate")
    elevateInteractiveFrame(scroll, frame, 6)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -42)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, options.showSaveButton and 44 or 12)

    local editBox = CreateFrame("EditBox", name .. "EditBox", scroll)
    elevateInteractiveFrame(editBox, frame, 7)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(width - 56)
    editBox:SetHeight(height - 72)
    editBox:SetAutoFocus(false)
    editBox:EnableMouse(true)
    editBox:SetTextInsets(4, 4, 4, 4)
    editBox:SetScript("OnEscapePressed", function()
        editBox:ClearFocus()
        frame:Hide()
    end)
    editBox:SetScript("OnEditFocusGained", function()
        if options.highlightOnFocus then
            editBox:HighlightText()
        end
    end)
    if options.readOnly then
        editBox:SetScript("OnTextChanged", function(selfBox)
            selfBox:HighlightText()
        end)
    end
    scroll:SetScrollChild(editBox)

    local saveButton
    if options.showSaveButton then
        saveButton = createButton(frame, options.saveButtonText or "Save", 90, 22)
        saveButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 12)
        saveButton:SetScript("OnClick", function()
            if options.onSave then
                options.onSave(editBox:GetText() or "", frame)
            end
        end)
    end

    frame.title = title
    frame.scroll = scroll
    frame.editBox = editBox
    frame.saveButton = saveButton
    return frame
end

local function buildPlainCandidateSummary(candidate)
    return table.concat({
        candidate.name or "Unknown",
        util:TitleCaseWords(string.trim((candidate.className or "") .. " " .. (candidate.specName or ""))),
        util:PlayerDisplayStatus(candidate.status),
    }, " - ")
end

local function groupedRollSortValue(candidate)
    if candidate.auto or candidate.rollText == "AUTO" then
        return 101
    end
    return tonumber(candidate.roll) or tonumber(candidate.rollText) or -1
end

local function sortGroupedRollers(entries)
    table.sort(entries, function(left, right)
        local leftRoll = groupedRollSortValue(left)
        local rightRoll = groupedRollSortValue(right)
        if leftRoll == rightRoll then
            return string.lower(left.name or "") < string.lower(right.name or "")
        end
        return leftRoll > rightRoll
    end)
end

-- Shared UI helpers exposed for the split UI/<feature>.lua files. Each split file re-localizes only
-- what it needs from this namespace; bodies move verbatim. Grows as more of UI.lua is extracted.
addon.UI = addon.UI or {}
addon.UI.createTextWindow = createTextWindow
addon.UI.sortGroupedRollers = sortGroupedRollers
addon.UI.buildPlainCandidateSummary = buildPlainCandidateSummary
addon.UI.createLabel = createLabel
addon.UI.elevateInteractiveFrame = elevateInteractiveFrame
addon.UI.createButton = createButton
addon.UI.setButtonTooltip = setButtonTooltip
addon.UI.createBackdropFrame = createBackdropFrame

local function formatSpecPriorityDisplay(specPriorityText)
    local normalized = string.trim(specPriorityText or "")
    if normalized == "" then
        return "none"
    end

    local tiers = {}
    for _, tierText in ipairs(util:Split(normalized, ">")) do
        tierText = string.trim(tierText)
        if tierText ~= "" then
            if string.find(tierText, "/", 1, true) then
                local formattedEntries = {}
                for _, entryText in ipairs(util:Split(tierText, "/")) do
                    entryText = string.trim(entryText)
                    formattedEntries[#formattedEntries + 1] = util:NormalizeKey(entryText) == "lc" and "LC" or util:TitleCaseWords(entryText)
                end
                tiers[#tiers + 1] = table.concat(formattedEntries, " / ")
            else
                tiers[#tiers + 1] = util:NormalizeKey(tierText) == "lc" and "LC" or util:TitleCaseWords(tierText)
            end
        end
    end

    if #tiers == 0 then
        return "none"
    end

    return table.concat(tiers, "\n---\n")
end
addon.UI.formatSpecPriorityDisplay = formatSpecPriorityDisplay

local function createScrollList(parent, name, rowCount, initializer)
    local frame = createBackdropFrame(name, parent)
    frame.scroll = CreateFrame("ScrollFrame", name .. "Scroll", frame, "FauxScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 0, -4)
    frame.scroll:SetPoint("BOTTOMRIGHT", -26, 4)

    frame.rows = {}
    for index = 1, rowCount do
        local row = CreateFrame("Button", name .. "Row" .. index, frame)
        elevateInteractiveFrame(row, frame, 4)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("LEFT", 6, 0)
        row:SetPoint("RIGHT", -26, 0)   -- stop short of the scrollbar gutter so rows never cover the bar
        if index == 1 then
            row:SetPoint("TOP", frame, "TOP", 0, -8)
        else
            row:SetPoint("TOP", frame.rows[index - 1], "BOTTOM", 0, -2)
        end
        initializer(row, index)
        frame.rows[index] = row
    end

    -- The FauxScroll scrollbar is a low-level child of the scroll frame; the interactive rows sit
    -- above it (frame+4) and would otherwise occlude it, so it reads as "hidden behind the panel".
    -- Lift the bar (its arrow buttons inherit) clear of the rows so it is visible and clickable.
    local scrollBar = _G[frame.scroll:GetName() .. "ScrollBar"]
    if scrollBar then
        scrollBar:SetFrameLevel(frame:GetFrameLevel() + 6)
    end

    frame.update = function(totalCount, updater)
        frame.totalCount = totalCount
        frame.rowUpdater = updater
        local offset = FauxScrollFrame_GetOffset(frame.scroll)
        FauxScrollFrame_Update(frame.scroll, totalCount, rowCount, ROW_HEIGHT)
        for index, row in ipairs(frame.rows) do
            local dataIndex = index + offset
            updater(row, dataIndex)
        end
    end

    frame.scroll:SetScript("OnVerticalScroll", function(scrollFrame, offset)
        FauxScrollFrame_OnVerticalScroll(scrollFrame, offset, ROW_HEIGHT, function()
            if frame.rowUpdater then
                frame.update(frame.totalCount or 0, frame.rowUpdater)
            end
        end)
    end)

    return frame
end
addon.UI.createScrollList = createScrollList   -- exposed for split UI/<feature>.lua files

function addon:InitializeUI()
    self.ui = self.ui or {}

    local frame = createBackdropFrame("WeirdLootFrame", UIParent)
    frame:SetWidth(980)
    frame:SetHeight(640)
    frame:SetPoint("CENTER", UIParent, "CENTER", self.db.ui.frame.x or 0, self.db.ui.frame.y or 0)
    -- HIGH sits one band below DIALOG, where StaticPopups live, so our own confirmation
    -- popups (End/Start Session, Reroll, LC override) render in front of this window.
    -- Toplevel + the OnShow Raise keeps us above other same-strata addon frames.
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetFrameLevel(1000)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(selfFrame)
        selfFrame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(selfFrame)
        selfFrame:StopMovingOrSizing()
        local _, _, _, x, y = selfFrame:GetPoint()
        addon.db.ui.frame.x = x
        addon.db.ui.frame.y = y
    end)
    frame:SetScript("OnShow", function(selfFrame)
        selfFrame:Raise()
    end)
    frame:Hide()

    tinsert(UISpecialFrames, "WeirdLootFrame")

    local title = createLabel(frame, "WeirdLoot", "TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetFontObject(GameFontHighlightLarge)

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    elevateInteractiveFrame(closeButton, frame, 10)
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local status = createLabel(frame, "", "TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    status:SetWidth(720)

    local content = CreateFrame("Frame", nil, frame)
    elevateInteractiveFrame(content, frame, 4)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -64)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 44)

    self.ui.frame = frame
    self.ui.status = status
    self.ui.content = content
    self.ui.tabs = {}
    self.ui.panels = {}
    self.ui.selectedTab = self.db.ui.selectedTab or "loot"

    self:BuildLootTab()
    self:BuildRaidersTab()
    self:BuildResultsTab()
    self:BuildMasterTab()
    self:BuildOptionsTab()
    self:BuildBottomTabs()
    self:BuildMinimapButton()

    self:RegisterCallback("STATE_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("CONFIG_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("ROSTER_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("AUTHORITY_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("SESSION_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("RESULTS_UPDATED", function()
        addon:RefreshUI()
    end)

    self:SelectTab(self.ui.selectedTab)
    self:RefreshUI()
end

function addon:BuildBottomTabs()
    local previous
    for _, key in ipairs(TAB_KEYS) do
        local tab = createButton(self.ui.frame, TAB_LABELS[key], 120, 24)
        if not previous then
            tab:SetPoint("BOTTOMLEFT", self.ui.frame, "BOTTOMLEFT", 16, 12)
        else
            tab:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        end
        tab:SetScript("OnClick", function()
            addon:SelectTab(key)
        end)
        self.ui.tabs[key] = tab
        previous = tab
    end

    local versionLabel = self.ui.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    versionLabel:SetPoint("BOTTOMRIGHT", self.ui.frame, "BOTTOMRIGHT", -16, 18)
    versionLabel:SetWidth(120)
    versionLabel:SetJustifyH("RIGHT")
    versionLabel:SetText("v" .. tostring(addon.version or "1.0"))
    self.ui.versionLabel = versionLabel
end

-- transient = show the tab without remembering it as the last-used tab (for the owed-loot minimap
-- jump, which must not overwrite the user's real last tab).
function addon:SelectTab(tabKey, transient)
    self.ui.selectedTab = tabKey
    if not transient then self.db.ui.selectedTab = tabKey end

    for key, panel in pairs(self.ui.panels) do
        if key == tabKey then
            panel:Show()
        else
            panel:Hide()
        end
    end

    -- Freshen the eligible list when the loot tab is opened: drops items whose trade window
    -- lapsed silently (no bag event), so they can't be rolled. No-op unless ML with a session.
    if tabKey == "loot" then self:ReconcileLootNow() end
    self:RefreshUI()
end

function addon:ToggleMainFrame()
    if not self.ui or not self.ui.frame then
        self:Print("UI is not initialized yet. If this keeps happening, reload the UI and check script errors.")
        return
    end

    if self.ui.frame:IsShown() then
        self.ui.frame:Hide()
    else
        self.ui.frame:Show()
        if self.ui.selectedTab == "loot" then self:ReconcileLootNow() end
        self:RefreshUI()
    end
end

-- Master refresh dispatcher: repaints the status line and every data tab. Lives here with the frame
-- orchestration (it is what ToggleMainFrame calls on open). Note: it intentionally does not refresh the
-- Options tab, whose widgets re-read state when that tab is selected.
function addon:RefreshUI()
    self:UpdateMinimapOwedGlow()
    self:UpdateMinimapTradeStatus()
    self:UpdateMinimapMLActive()
    if not self.ui or not self.ui.frame then
        return
    end

    local session = self:GetCurrentSession()
    local lootMasterName = self:GetLootMasterName() or "Unknown"
    local authority = self:IsAuthorizedLootMaster() and "Yes" or "No"
    local sessionState = session.active and ("Active session " .. (session.id or "")) or "No active session"
    self.ui.status:SetText(string.format("Loot master: %s | Authorized: %s | %s", lootMasterName, authority, sessionState))

    self:RefreshLootTab()
    self:RefreshRaidersTab()
    self:RefreshResultsTab()
    self:RefreshMasterTab()
end

function addon:TradeSelectedWinner()
    local result = self.ui and self.ui.selectedResult
    local winner = result and result.winner
    if not result or not winner or winner == "" or winner == "No winner" then
        self:Print("No winner is selected for trade.")
        return
    end

    if UnitExists("target") and util:NormalizeKey(util:GetPlayerName("target") or "") == util:NormalizeKey(winner) then
        InitiateTrade("target")
    else
        self:Print("Click Target Winner first, then click Trade Winner.")
    end
end

-- Fill the open trade from the loot ledger via the TradeDeliver engine. Routes
-- manual delivery through the same filler as auto-payout (stack/split-correct,
-- soonest-to-expire first) instead of hand-placing an item, so the two never
-- double-fill the same trade window.
function addon:FillSelectedTrade()
    self:FillOpenTrade()
end

function addon:UnlockAllSessionRolls()
    self:UnlockAllRolls()
end

local function getOptions(self)
    self.db.options = self.db.options or {}
    return self.db.options
end
addon.UI.getOptions = getOptions   -- exposed for split UI/<feature>.lua files

local function createOptionsCheckbox(parent, label)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    elevateInteractiveFrame(cb, parent, 8)
    cb:SetWidth(24)
    cb:SetHeight(24)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    fs:SetText(label)
    cb.label = fs
    return cb
end

-- Make a set of checkboxes mutually exclusive (radio-style, but all-off is allowed). Each member is
--   { cb = <checkbox>, get = function() return on end, set = function(on) end, onToggle = optional }
-- Clicking one persists via its set(); if it turned ON, every other member is set(false). Then all
-- checkboxes re-sync from their get(). Shared by the new-loot auto modes and the whitelist/blacklist
-- filter so the mutex is wired once here instead of in each checkbox's own handler.
local function bindExclusiveCheckboxes(members)
    local function resync()
        for _, m in ipairs(members) do m.cb:SetChecked(m.get() and true or false) end
    end
    for _, m in ipairs(members) do
        m.cb:SetScript("OnClick", function(selfCB)
            local on = selfCB:GetChecked() and true or false
            m.set(on)
            if on then
                for _, other in ipairs(members) do
                    if other ~= m then other.set(false) end
                end
            end
            resync()
            if m.onToggle then m.onToggle(on) end
        end)
    end
    return resync
end

local function createNumberEditBox(parent, width)
    local w = width or 50
    local h = 20

    local bg = CreateFrame("Frame", nil, parent)
    elevateInteractiveFrame(bg, parent, 8)
    bg:SetWidth(w)
    bg:SetHeight(h)
    bg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bg:SetBackdropColor(0, 0, 0, 0.7)
    bg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local box = CreateFrame("EditBox", nil, bg)
    elevateInteractiveFrame(box, bg, 1)
    box:SetPoint("TOPLEFT", bg, "TOPLEFT", 4, -2)
    box:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -4, 2)
    box:SetFontObject(GameFontHighlight)
    box:SetJustifyH("CENTER")
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(4)
    box:SetScript("OnEscapePressed", function(selfBox) selfBox:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(selfBox) selfBox:ClearFocus() end)

    -- Expose box methods on the container so existing call sites that anchor
    -- to / read from the "edit box" keep working through the wrapper.
    bg.editBox = box
    bg.SetText = function(_, text) box:SetText(text) end
    bg.GetText = function() return box:GetText() end
    bg.SetTextColor = function(_, r, g, b, a) box:SetTextColor(r, g, b, a or 1) end
    bg.SetScript = function(_, scriptType, fn) box:SetScript(scriptType, fn) end
    bg.SetNumeric = function(_, v) box:SetNumeric(v) end
    bg.SetFocus = function() box:SetFocus() end
    bg.ClearFocus = function() box:ClearFocus() end

    return bg
end

local function createTextEditBox(parent, width)
    local w = width or 140
    local h = 20

    local bg = CreateFrame("Frame", nil, parent)
    elevateInteractiveFrame(bg, parent, 8)
    bg:SetWidth(w)
    bg:SetHeight(h)
    bg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bg:SetBackdropColor(0, 0, 0, 0.7)
    bg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local box = CreateFrame("EditBox", nil, bg)
    elevateInteractiveFrame(box, bg, 1)
    box:SetPoint("TOPLEFT", bg, "TOPLEFT", 6, -2)
    box:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -6, 2)
    box:SetFontObject(GameFontHighlight)
    box:SetJustifyH("LEFT")
    box:SetAutoFocus(false)
    box:SetMaxLetters(20)
    box:SetScript("OnEscapePressed", function(selfBox) selfBox:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(selfBox) selfBox:ClearFocus() end)

    bg.editBox = box
    bg.SetText = function(_, text) box:SetText(text or "") end
    bg.GetText = function() return box:GetText() end
    bg.SetScript = function(_, scriptType, fn) box:SetScript(scriptType, fn) end
    bg.SetFocus = function() box:SetFocus() end
    bg.ClearFocus = function() box:ClearFocus() end

    return bg
end

local multilineScrollSeq = 0
local function createMultilineEditScroll(parent, width, height)
    multilineScrollSeq = multilineScrollSeq + 1
    local baseName = "WeirdLootOptionsScroll" .. multilineScrollSeq

    local container = CreateFrame("Frame", baseName .. "Container", parent)
    elevateInteractiveFrame(container, parent, 6)
    container:SetWidth(width)
    container:SetHeight(height)
    container:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    container:SetBackdropColor(0, 0, 0, 0.6)

    local scroll = CreateFrame("ScrollFrame", baseName, container, "UIPanelScrollFrameTemplate")
    elevateInteractiveFrame(scroll, container, 1)
    scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -26, 6)

    local editBox = CreateFrame("EditBox", baseName .. "Edit", scroll)
    elevateInteractiveFrame(editBox, container, 2)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(width - 36)
    editBox:SetHeight(height - 12)
    editBox:SetAutoFocus(false)
    editBox:EnableMouse(true)
    editBox:SetScript("OnEscapePressed", function(selfBox) selfBox:ClearFocus() end)
    scroll:SetScrollChild(editBox)

    container.editBox = editBox
    container.scroll = scroll
    return container
end
-- Options-tab widgets exposed for split UI/<feature>.lua files.
addon.UI.createOptionsCheckbox = createOptionsCheckbox
addon.UI.bindExclusiveCheckboxes = bindExclusiveCheckboxes
addon.UI.createNumberEditBox = createNumberEditBox
addon.UI.createTextEditBox = createTextEditBox
addon.UI.createMultilineEditScroll = createMultilineEditScroll

