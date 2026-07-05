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

    -- The raid filter only means something inside a raid; outside one the tab shows the
    -- guild roster regardless, and the user's saved preference just waits (checkbox renders
    -- disabled but keeps its state).
    if self.db.ui.rosterRaidOnly and #self:GetAttendees() > 0 then
        local present = {}
        for _, entry in ipairs(entries) do
            if entry.present then
                present[#present + 1] = entry
            end
        end
        entries = present
    end

    table.sort(entries, function(left, right)
        -- Underspecified raid members (blank spec / unknown status, incl. unhandled guests)
        -- float above every sort mode until their data is filled.
        if (left.needsAttention or false) ~= (right.needsAttention or false) then
            return left.needsAttention or false
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
            -- Display order only: Unknowns lead (they need leadership attention), then Main,
            -- DAlt, Alt. Resolution still treats unknown as main (util:StatusRank).
            local function displayRank(status)
                if util:NormalizeKey(status) == "unknown" then return 4 end
                return util:StatusRank(status)
            end
            local leftRank = displayRank(left.status)
            local rightRank = displayRank(right.status)
            if leftRank ~= rightRank then
                return leftRank > rightRank
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end

        return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
    end)

    return entries
end

-- ---- on-the-fly overrides: click a row's Class/Spec or Status cell, pick from a dropdown ----
-- Authority: ML or guild leadership (receivers re-verify in the comm handlers). Guildies get
-- a persistent override record on top of rank/note (SetRosterOverride, "stored for next
-- time"); non-guildies write their guest-layer entry directly, so a pug's pick is remembered
-- for their next visit too. Both broadcast from whoever clicked.

local rosterMenuFrame

local function canEditRoster()
    return addon:CanEditRoster()
end

local function applyPick(entry, specName, status)
    if addon:GetGuildMemberProfile(entry.name) then
        local override = addon:GetRosterOverride(entry.name) or {}
        addon:SetRosterOverride(entry.name,
            specName ~= nil and specName or (override.specName or ""),
            status ~= nil and status or (override.status or ""))
        addon:SendRosterOverride(entry.name)
    else
        local updated = {
            name = entry.name,
            className = entry.className,
            specName = specName ~= nil and specName or (entry.specName or ""),
            status = status ~= nil and status or (entry.status or "main"),
        }
        if updated.status == "unknown" then updated.status = "main" end   -- picking a spec registers a guest; guests compete as mains
        addon:UpsertRosterEntry(updated)
        addon:SendGuestUpsert(updated)
    end
end

-- The menu's name line: a REAL title (disabled, no hover), class-colored via text escape.
local function rosterMenuNameEntry(entry)
    return {
        text = (util:GetClassColorCode(entry.className) or "|cffffffff") .. util:TitleCaseWords(entry.name or "") .. "|r",
        isTitle = true,
        notCheckable = true,
    }
end

local function showRosterMenu(menu)
    if not EasyMenu then
        addon:Print("EasyMenu is missing from FrameXML; cannot show the roster picker.")
        return
    end
    rosterMenuFrame = rosterMenuFrame or CreateFrame("Frame", "WeirdLootRosterMenu", UIParent, "UIDropDownMenuTemplate")
    EasyMenu(menu, rosterMenuFrame, "cursor", 0, 0, "MENU", 2)
    -- Titles are hard-forced onto GameFontNormalSmallLeft at build time; bump just OUR title
    -- (always item 1) after the list renders. Titles draw with the disabled font, and the next
    -- menu to reuse this button re-forces its own font, so nothing leaks.
    local titleButton = _G["DropDownList1Button1"]
    if titleButton and GameFontNormalLeft then
        titleButton:SetDisabledFontObject(GameFontNormalLeft)
    end
end

-- Every refusal is loud: with scriptErrors off, a silent return here is indistinguishable
-- from a dead click target, which makes "nothing pops up" undiagnosable from the outside.
local function refuseRosterEdit(entry)
    if not entry then return true end
    if not canEditRoster() then
        addon:Print("Roster edit requires guild leadership (officer rank).")
        return true
    end
    return false
end

function addon:OpenRosterSpecMenu(entry)
    if refuseRosterEdit(entry) then return end
    local specs = self.specTokens[util:NormalizeKey(entry.className or "")]
    if not specs then
        self:Print(string.format("No class known for %s; cannot pick a spec.", util:TitleCaseWords(entry.name or "?")))
        return
    end
    local ordered = {}
    for _, specName in pairs(specs) do ordered[#ordered + 1] = specName end
    table.sort(ordered)

    local menu = { rosterMenuNameEntry(entry) }
    for _, specName in ipairs(ordered) do
        menu[#menu + 1] = {
            text = util:TitleCaseWords(specName),
            checked = entry.specName == specName,
            func = function() applyPick(entry, specName, nil) end,
        }
    end
    if entry.overriddenSpec then
        menu[#menu + 1] = {
            text = "Clear override (use note/rank)",
            notCheckable = true,
            func = function() applyPick(entry, "", nil) end,
        }
    end
    showRosterMenu(menu)
end

function addon:OpenRosterStatusMenu(entry)
    if refuseRosterEdit(entry) then return end
    local menu = {
        rosterMenuNameEntry(entry),
        { text = "Main", checked = entry.status == "main", func = function() applyPick(entry, nil, "main") end },
        { text = "Designated Alt", checked = entry.status == "designatedalt", func = function() applyPick(entry, nil, "designatedalt") end },
        { text = "Alt", checked = entry.status == "nil", func = function() applyPick(entry, nil, "nil") end },
    }
    if entry.overriddenStatus then
        menu[#menu + 1] = {
            text = "Clear override (use note/rank)",
            notCheckable = true,
            func = function() applyPick(entry, nil, "") end,
        }
    end
    showRosterMenu(menu)
end

function addon:BuildRaidersTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.raiders = panel

    local summary = createLabel(panel, "", "TOPLEFT", panel, "TOPLEFT", 8, -6)
    summary:SetWidth(760)
    summary:SetTextColor(0.9, 0.82, 0.5)

    local editHint = createLabel(panel, "Click a Class / Spec or Status cell to assign it (officers).", "TOPLEFT", summary, "BOTTOMLEFT", 0, -6)
    editHint:SetTextColor(0.6, 0.6, 0.6)
    panel.editHint = editHint

    local raidOnly = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    elevateInteractiveFrame(raidOnly, panel, 8)
    raidOnly:SetWidth(24)
    raidOnly:SetHeight(24)
    raidOnly:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -110, -22)
    local raidOnlyLabel = createLabel(panel, "Raid only", "LEFT", raidOnly, "RIGHT", 2, 0)
    raidOnlyLabel:SetTextColor(0.9, 0.9, 0.9)
    panel.raidOnlyLabel = raidOnlyLabel
    raidOnly:SetScript("OnClick", function(selfCB)
        addon.db.ui.rosterRaidOnly = selfCB:GetChecked() and true or false
        addon:RefreshRaidersTab()
    end)
    panel.raidOnlyCheckbox = raidOnly

    local rosterFrame = createBackdropFrame("WeirdLootRaidersFrame", panel)
    rosterFrame:SetPoint("TOPLEFT", editHint, "BOTTOMLEFT", 0, -8)
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

        -- Invisible click targets over the editable cells; entryData is stamped by the
        -- update closure below so the menus always act on the row's current occupant.
        -- Explicit geometry (label anchor + width, fixed height): a FontString's own rect
        -- auto-sizes from its text and can be degenerate, which would leave a SetAllPoints
        -- button with no clickable area.
        -- Attention tint: a quiet red wash under rows whose raid member needs data filled.
        row.attentionBg = row:CreateTexture(nil, "BACKGROUND")
        row.attentionBg:SetAllPoints(row)
        row.attentionBg:SetTexture(0.8, 0.1, 0.1, 0.14)
        row.attentionBg:Hide()

        row.specClick = CreateFrame("Button", nil, row)
        elevateInteractiveFrame(row.specClick, row, 10)   -- same lift as LootTab's itemHitbox; default child level sits below the list chrome
        row.specClick:RegisterForClicks("LeftButtonUp")
        row.specClick:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
        row.specClick:SetWidth(200)
        row.specClick:SetHeight(16)
        row.specClick:SetScript("OnClick", function()
            local ok, err = pcall(addon.OpenRosterSpecMenu, addon, row.entryData)
            if not ok then addon:Print("Spec menu error: " .. tostring(err)) end
        end)
        row.statusClick = CreateFrame("Button", nil, row)
        elevateInteractiveFrame(row.statusClick, row, 10)
        row.statusClick:RegisterForClicks("LeftButtonUp")
        row.statusClick:SetPoint("LEFT", row.classSpec, "RIGHT", 12, 0)
        row.statusClick:SetWidth(110)
        row.statusClick:SetHeight(16)
        row.statusClick:SetScript("OnClick", function()
            local ok, err = pcall(addon.OpenRosterStatusMenu, addon, row.entryData)
            if not ok then addon:Print("Status menu error: " .. tostring(err)) end
        end)
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
            local cb = panel.raidOnlyCheckbox
            cb:SetChecked(self.db.ui.rosterRaidOnly and true or false)
            -- Outside a raid the filter is inert but the toggle stays live (the choice is
            -- saved for the next raid); desaturation is the only cue that it does nothing
            -- right now.
            local inRaid = #self:GetAttendees() > 0
            local desaturate = inRaid and 0 or 1
            if cb.GetNormalTexture and cb:GetNormalTexture() then
                cb:GetNormalTexture():SetDesaturated(desaturate)
            end
            if cb.GetCheckedTexture and cb:GetCheckedTexture() then
                cb:GetCheckedTexture():SetDesaturated(desaturate)
            end
            if panel.raidOnlyLabel then
                if inRaid then
                    panel.raidOnlyLabel:SetTextColor(0.9, 0.9, 0.9)
                else
                    panel.raidOnlyLabel:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
        if panel.editHint then
            if canEditRoster() then panel.editHint:Show() else panel.editHint:Hide() end
        end
    end

    local rosterEntries = self:GetSortedRosterEntries()

    -- Counts come from the FULL display list, not the (possibly raid-only filtered) view.
    local guildCount, guestLayerCount, guestCount, attentionCount = 0, 0, 0, 0
    for _, entry in ipairs(self:GetRosterDisplayList()) do
        if entry.source == "guild" then
            guildCount = guildCount + 1
        elseif entry.source == "configured" then
            guestLayerCount = guestLayerCount + 1
        end
        if entry.isGuest then
            guestCount = guestCount + 1
        end
        if entry.needsAttention then
            attentionCount = attentionCount + 1
        end
    end
    -- The tab-button alarm (badge + pulse) is a call to action, so only people who can act
    -- get it; the in-list signals below (sort-to-top, row tint, red cells) stay for everyone,
    -- since knowing WHY someone isn't matching spec prio is useful to any raider.
    self:UpdateRaidersTabAlert(canEditRoster() and attentionCount or 0)

    if self.ui.raidersSummary then
        self.ui.raidersSummary:SetText(string.format(
            "Guild: %d | Guest layer: %d | In current raid: %d | Unhandled guests: %d",
            guildCount,
            guestLayerCount,
            #self:GetAttendees(),
            guestCount
        ))
    end

    self.ui.raidersList.update(#rosterEntries, function(row, index)
        local entry = rosterEntries[index]
        if not entry then
            row.entryData = nil
            row:Hide()
            return
        end
        row:Show()
        row.entryData = entry
        row.present:SetText(entry.present and "Yes" or "No")
        row.present:SetTextColor(entry.present and 0.3 or 0.7, entry.present and 0.9 or 0.3, 0.3)
        row.name:SetText((util:GetClassColorCode(entry.className) or "|cffffffff") .. util:TitleCaseWords(entry.name or "") .. "|r")
        -- Overridden cells get a gold star: the durable source (note/rank) is being outvoted.
        -- Underspecified cells on raid members get a red call-to-action instead of a quiet
        -- blank: the cell itself is the click target that fixes it.
        local specText = (util:GetClassColorCode(entry.className) or "|cffffffff") .. util:TitleCaseWords(string.trim((entry.className or "") .. " " .. (entry.specName or ""))) .. "|r"
            .. (entry.overriddenSpec and "|cffffcc00*|r" or "")
        if entry.needsAttention and (entry.specName or "") == "" then
            specText = specText .. " |cffff3333set spec!|r"
        end
        row.classSpec:SetText(specText)
        if entry.needsAttention and entry.status == "unknown" then
            row.status:SetText("|cffff3333Unknown!|r")
        else
            row.status:SetText(util:PlayerDisplayStatus(entry.status)
                .. (entry.overriddenStatus and "|cffffcc00*|r" or ""))
        end
        if row.attentionBg then
            if entry.needsAttention then row.attentionBg:Show() else row.attentionBg:Hide() end
        end
        if entry.isGuest then
            row.source:SetText("Guest")
            row.source:SetTextColor(1, 0.82, 0.2)
        elseif entry.source == "guild" then
            row.source:SetText("Guild")
            row.source:SetTextColor(0.6, 0.9, 0.6)
        else
            row.source:SetText(entry.source == "configured" and "Roster" or "Live")
            row.source:SetTextColor(entry.source == "configured" and 0.85 or 1, entry.source == "configured" and 0.85 or 0.45, entry.source == "configured" and 0.85 or 0.45)
        end
    end)
end
