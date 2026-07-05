-- WeirdLoot Raiders tab: roster list with sort plus the attendance summary. Pure presentation;
-- pulls shared widgets from the addon.UI namespace defined in UI.lua.
local addon = WeirdLoot
local util = addon.util
local UI = addon.UI
local createLabel = UI.createLabel
local createButton = UI.createButton
local createScrollList = UI.createScrollList
local createBackdropFrame = UI.createBackdropFrame
local elevateInteractiveFrame = UI.elevateInteractiveFrame

function addon:SetRosterSortMode(sortMode)
    self.db.ui.rosterSortMode = sortMode or "name"
    self:RefreshRaidersTab()
end

function addon:GetSortedRosterEntries()
    local entries = util:CloneTable(self:GetRosterDisplayList() or {})
    local sortMode = self.db.ui.rosterSortMode or "name"

    if self.db.ui.rosterRaidOnly then
        local present = {}
        for _, entry in ipairs(entries) do
            if entry.present then
                present[#present + 1] = entry
            end
        end
        entries = present
    end

    table.sort(entries, function(left, right)
        -- Unhandled guests float above every sort mode until a spec is assigned.
        if (left.isGuest or false) ~= (right.isGuest or false) then
            return left.isGuest or false
        end
        if sortMode == "raid" then
            if left.present ~= right.present then
                return left.present
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        elseif sortMode == "classspec" then
            local leftClassSpec = util:NormalizeKey(string.trim((left.className or "") .. " " .. (left.specName or "")))
            local rightClassSpec = util:NormalizeKey(string.trim((right.className or "") .. " " .. (right.specName or "")))
            if leftClassSpec ~= rightClassSpec then
                return leftClassSpec < rightClassSpec
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        elseif sortMode == "status" then
            local leftRank = util:StatusRank(left.status)
            local rightRank = util:StatusRank(right.status)
            if leftRank ~= rightRank then
                return leftRank > rightRank
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end

        return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
    end)

    return entries
end

-- Parse the add-guest line ("Name, class spec[, status]"; status defaults to main: a guest
-- competes as a main) and upsert + broadcast it. Authority: the ML or guild leadership;
-- receivers re-verify in OnGuestUpsert, so a local-only edit by anyone else is refused here
-- rather than silently diverging.
function addon:AddGuestFromInput(line)
    line = string.trim(line or "")
    if line == "" then
        return false
    end
    if not (self:IsAuthorizedLootMaster() or self:IsGuildLeadership(util:GetPlayerName("player"))) then
        self:Print("Only the loot master or guild leadership can add roster entries.")
        return false
    end
    local parsed = self:ParseRosterImport(line)[1]
    if not parsed or not parsed.className then
        self:Print("Add guest: use Name, class spec (e.g. Puggo, mage frost). Status is optional and defaults to main.")
        return false
    end
    local parts = util:Split(line, ",")
    if string.trim(parts[3] or "") == "" then
        parsed.status = "main"
    end
    self:UpsertRosterEntry(parsed)
    self:SendGuestUpsert(parsed)
    self:Print(string.format("Roster: added %s (%s, %s).",
        util:TitleCaseWords(parsed.name), string.trim((parsed.className or "") .. " " .. (parsed.specName or "")),
        util:PlayerDisplayStatus(parsed.status)))
    return true
end

function addon:BuildRaidersTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.raiders = panel

    local summary = createLabel(panel, "", "TOPLEFT", panel, "TOPLEFT", 8, -6)
    summary:SetWidth(760)
    summary:SetTextColor(0.9, 0.82, 0.5)

    -- Controls row: add-guest input + raid-only filter, between the summary and the list.
    local addBoxBg = CreateFrame("Frame", nil, panel)
    elevateInteractiveFrame(addBoxBg, panel, 8)
    addBoxBg:SetWidth(240)
    addBoxBg:SetHeight(20)
    addBoxBg:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -6)
    addBoxBg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    addBoxBg:SetBackdropColor(0, 0, 0, 0.7)
    addBoxBg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local addBox = CreateFrame("EditBox", nil, addBoxBg)
    elevateInteractiveFrame(addBox, addBoxBg, 1)
    addBox:SetPoint("TOPLEFT", addBoxBg, "TOPLEFT", 6, -2)
    addBox:SetPoint("BOTTOMRIGHT", addBoxBg, "BOTTOMRIGHT", -6, 2)
    addBox:SetFontObject(GameFontHighlight)
    addBox:SetAutoFocus(false)
    addBox:SetMaxLetters(64)
    addBox:SetScript("OnEscapePressed", function(selfBox) selfBox:ClearFocus() end)

    local addButton = createButton(panel, "Add Guest", 90, 20)
    addButton:SetPoint("LEFT", addBoxBg, "RIGHT", 6, 0)
    local function submitGuest()
        if addon:AddGuestFromInput(addBox:GetText()) then
            addBox:SetText("")
        end
        addBox:ClearFocus()
    end
    addButton:SetScript("OnClick", submitGuest)
    addBox:SetScript("OnEnterPressed", submitGuest)

    local addHint = createLabel(panel, "Name, class spec  (guests default to main)", "LEFT", addButton, "RIGHT", 8, 0)
    addHint:SetTextColor(0.6, 0.6, 0.6)

    local raidOnly = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    elevateInteractiveFrame(raidOnly, panel, 8)
    raidOnly:SetWidth(24)
    raidOnly:SetHeight(24)
    raidOnly:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -110, -22)
    local raidOnlyLabel = createLabel(panel, "Raid only", "LEFT", raidOnly, "RIGHT", 2, 0)
    raidOnlyLabel:SetTextColor(0.9, 0.9, 0.9)
    raidOnly:SetScript("OnClick", function(selfCB)
        addon.db.ui.rosterRaidOnly = selfCB:GetChecked() and true or false
        addon:RefreshRaidersTab()
    end)
    panel.raidOnlyCheckbox = raidOnly
    panel.addGuestButton = addButton

    local rosterFrame = createBackdropFrame("WeirdLootRaidersFrame", panel)
    rosterFrame:SetPoint("TOPLEFT", addBoxBg, "BOTTOMLEFT", 0, -8)
    rosterFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 0)

    local headerPresence = createButton(rosterFrame, "Raid", 54, 18)
    headerPresence:SetPoint("TOPLEFT", rosterFrame, "TOPLEFT", 6, -6)
    headerPresence:SetScript("OnClick", function()
        addon:SetRosterSortMode("raid")
    end)

    local headerName = createButton(rosterFrame, "Name", 132, 18)
    headerName:SetPoint("LEFT", headerPresence, "RIGHT", 8, 0)
    headerName:SetScript("OnClick", function()
        addon:SetRosterSortMode("name")
    end)

    local headerClassSpec = createButton(rosterFrame, "Class / Spec", 200, 18)
    headerClassSpec:SetPoint("LEFT", headerName, "RIGHT", 4, 0)
    headerClassSpec:SetScript("OnClick", function()
        addon:SetRosterSortMode("classspec")
    end)

    local headerStatus = createButton(rosterFrame, "Status", 110, 18)
    headerStatus:SetPoint("LEFT", headerClassSpec, "RIGHT", 12, 0)
    headerStatus:SetScript("OnClick", function()
        addon:SetRosterSortMode("status")
    end)

    local headerSource = createButton(rosterFrame, "Source", 80, 18)
    headerSource:SetPoint("LEFT", headerStatus, "RIGHT", 12, 0)
    headerSource:SetScript("OnClick", function()
    end)

    local list = createScrollList(rosterFrame, "WeirdLootRaidersList", 18, function(row)
        row.present = createLabel(row, "", "LEFT", row, "LEFT", 8, 0)
        row.present:SetWidth(48)
        row.name = createLabel(row, "", "LEFT", row.present, "RIGHT", 14, 0)
        row.name:SetWidth(132)
        row.classSpec = createLabel(row, "", "LEFT", row.name, "RIGHT", 4, 0)
        row.classSpec:SetWidth(200)
        row.status = createLabel(row, "", "LEFT", row.classSpec, "RIGHT", 12, 0)
        row.status:SetWidth(110)
        row.source = createLabel(row, "", "LEFT", row.status, "RIGHT", 12, 0)
        row.source:SetWidth(80)
    end)
    list:SetPoint("TOPLEFT", headerPresence, "BOTTOMLEFT", 0, -8)
    list:SetPoint("BOTTOMRIGHT", rosterFrame, "BOTTOMRIGHT", -6, 6)
    self.ui.raidersList = list
    self.ui.raidersSummary = summary
end

function addon:RefreshRaidersTab()
    local panel = self.ui.panels and self.ui.panels.raiders
    if panel then
        if panel.raidOnlyCheckbox then
            panel.raidOnlyCheckbox:SetChecked(self.db.ui.rosterRaidOnly and true or false)
        end
        if panel.addGuestButton then
            local canEdit = self:IsAuthorizedLootMaster()
                or self:IsGuildLeadership(util:GetPlayerName("player"))
            if canEdit then panel.addGuestButton:Enable() else panel.addGuestButton:Disable() end
        end
    end

    local rosterEntries = self:GetSortedRosterEntries()
    local configuredCount = #self:GetRosterEntries()
    local attendeeCount = #self:GetAttendees()
    local matchedCount = 0
    local unconfiguredCount = 0

    for _, entry in ipairs(rosterEntries) do
        if entry.present and entry.source == "configured" then
            matchedCount = matchedCount + 1
        elseif entry.present and entry.source == "unconfigured" then
            unconfiguredCount = unconfiguredCount + 1
        end
    end

    if self.ui.raidersSummary then
        self.ui.raidersSummary:SetText(string.format(
            "Master roster: %d | In current raid: %d | Matched: %d | Unconfigured in raid: %d",
            configuredCount,
            attendeeCount,
            matchedCount,
            unconfiguredCount
        ))
    end

    self.ui.raidersList.update(#rosterEntries, function(row, index)
        local entry = rosterEntries[index]
        if not entry then
            row:Hide()
            return
        end
        row:Show()
        row.present:SetText(entry.present and "Yes" or "No")
        row.present:SetTextColor(entry.present and 0.3 or 0.7, entry.present and 0.9 or 0.3, 0.3)
        row.name:SetText((util:GetClassColorCode(entry.className) or "|cffffffff") .. util:TitleCaseWords(entry.name or "") .. "|r")
        row.classSpec:SetText((util:GetClassColorCode(entry.className) or "|cffffffff") .. util:TitleCaseWords(string.trim((entry.className or "") .. " " .. (entry.specName or ""))) .. "|r")
        row.status:SetText(util:PlayerDisplayStatus(entry.status))
        if entry.isGuest then
            row.source:SetText("Guest")
            row.source:SetTextColor(1, 0.82, 0.2)
        else
            row.source:SetText(entry.source == "configured" and "Roster" or "Live")
            row.source:SetTextColor(entry.source == "configured" and 0.85 or 1, entry.source == "configured" and 0.85 or 0.45, entry.source == "configured" and 0.85 or 0.45)
        end
    end)
end
