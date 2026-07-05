-- Spec/status pickers bolted onto the guild member detail popout (GuildMemberDetailFrame),
-- shown only to clients with edit-officer-note permission. Selecting a value rewrites the
-- member's officer note through ComposeOfficerNote, preserving the free text and the other
-- token, so leadership never types the 3-letter tokens by hand (typo-proof, and hand-typed
-- notes still parse identically). The panel flies out to the right of the popout to avoid
-- WeirdGuildNotes' restore button below it.

local addon = WeirdLoot
local util = addon.util

-- Officer notes cap at 31 characters server-side; a silent truncation would eat the trailing
-- tokens, so writes that would exceed it are refused with a message instead.
local OFFICER_NOTE_MAX = 31

local STATUS_CHOICES = {
    { token = nil,    label = "(by rank)" },
    { token = "main", label = "Main" },
    { token = "dalt", label = "Designated Alt" },
    { token = "alt",  label = "Alt" },
}

local function selectedGuildMember()
    local selection = GetGuildRosterSelection and GetGuildRosterSelection()
    if not selection or selection == 0 then
        return nil
    end
    local name, _, _, _, classLocalized, _, _, officerNote, _, _, classFileName = GetGuildRosterInfo(selection)
    if not name then
        return nil
    end
    return {
        index = selection,
        name = string.match(name, "^[^-]+") or name,
        className = addon:NormalizeClassName(classFileName or classLocalized or ""),
        officerNote = officerNote or "",
    }
end

-- Rewrite the selected member's officer note with the given tokens (nil drops that token).
local function writeOfficerNote(statusToken, specToken)
    local member = selectedGuildMember()
    if not member then
        return
    end
    if not (CanEditOfficerNote and CanEditOfficerNote()) then
        return
    end
    local freeText = addon:SplitOfficerNote(member.officerNote, member.className)
    local newNote = addon:ComposeOfficerNote(freeText, statusToken, specToken)
    if string.len(newNote) > OFFICER_NOTE_MAX then
        addon:Print(string.format(
            "Officer note for %s would be %d chars (max %d); shorten its free text to fit the tokens.",
            member.name, string.len(newNote), OFFICER_NOTE_MAX))
        return
    end
    GuildRosterSetOfficerNote(member.index, newNote)
    if GuildRoster then
        GuildRoster()   -- push the change out; the GUILD_ROSTER_UPDATE reply re-scans and refreshes us
    end
end

local function orderedSpecEntries(className)
    local tokens = addon.specTokens[className] or {}
    local entries = {}
    for token, specName in pairs(tokens) do
        entries[#entries + 1] = { token = token, specName = specName }
    end
    table.sort(entries, function(a, b) return a.specName < b.specName end)
    return entries
end

function addon:RefreshGuildSpecPanel()
    local panel = self.guildSpecPanel
    if not panel then
        return
    end
    local member = selectedGuildMember()
    if not member
        or not (CanEditOfficerNote and CanEditOfficerNote())
        or not self.specTokens[member.className] then
        panel:Hide()
        return
    end

    local _, specName, statusOverride = self:SplitOfficerNote(member.officerNote, member.className)
    UIDropDownMenu_SetText(panel.specDropdown, specName ~= "" and util:TitleCaseWords(specName) or "(none)")
    local statusLabel = "(by rank)"
    for _, choice in ipairs(STATUS_CHOICES) do
        if choice.token and self.noteStatusTokens[choice.token] == statusOverride then
            statusLabel = choice.label
        end
    end
    UIDropDownMenu_SetText(panel.statusDropdown, statusLabel)
    panel:Show()
end

local function initSpecDropdown()
    local member = selectedGuildMember()
    if not member then
        return
    end
    local _, currentSpec = addon:SplitOfficerNote(member.officerNote, member.className)

    local none = UIDropDownMenu_CreateInfo()
    none.text = "(none)"
    none.checked = currentSpec == ""
    none.func = function()
        writeOfficerNote(addon:StatusTokenFor(select(3, addon:SplitOfficerNote(member.officerNote, member.className))), nil)
    end
    UIDropDownMenu_AddButton(none)

    for _, entry in ipairs(orderedSpecEntries(member.className)) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = util:TitleCaseWords(entry.specName) .. " (" .. entry.token .. ")"
        info.checked = currentSpec == entry.specName
        info.func = function()
            local _, _, statusOverride = addon:SplitOfficerNote(member.officerNote, member.className)
            writeOfficerNote(addon:StatusTokenFor(statusOverride), entry.token)
        end
        UIDropDownMenu_AddButton(info)
    end
end

local function initStatusDropdown()
    local member = selectedGuildMember()
    if not member then
        return
    end
    local _, currentSpec, statusOverride = addon:SplitOfficerNote(member.officerNote, member.className)

    for _, choice in ipairs(STATUS_CHOICES) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = choice.label
        if choice.token then
            info.checked = addon.noteStatusTokens[choice.token] == statusOverride
        else
            info.checked = statusOverride == nil
        end
        info.func = function()
            writeOfficerNote(choice.token, addon:SpecTokenFor(member.className, currentSpec))
        end
        UIDropDownMenu_AddButton(info)
    end
end

function addon:InitializeGuildSpecUI()
    if self.guildSpecPanel or not GuildMemberDetailFrame then
        return
    end

    local panel = CreateFrame("Frame", "WeirdLootGuildSpecPanel", GuildMemberDetailFrame)
    panel:SetWidth(190)
    panel:SetHeight(150)
    panel:SetPoint("TOPLEFT", GuildMemberDetailFrame, "TOPRIGHT", -4, -12)
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("WeirdLoot Note")

    local specLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    specLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    specLabel:SetText("Spec")

    local specDropdown = CreateFrame("Frame", "WeirdLootGuildSpecDropdown", panel, "UIDropDownMenuTemplate")
    specDropdown:SetPoint("TOPLEFT", specLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_SetWidth(specDropdown, 130)
    UIDropDownMenu_JustifyText(specDropdown, "LEFT")
    UIDropDownMenu_Initialize(specDropdown, initSpecDropdown)
    panel.specDropdown = specDropdown

    local statusLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statusLabel:SetPoint("TOPLEFT", specDropdown, "BOTTOMLEFT", 16, -4)
    statusLabel:SetText("Status override")

    local statusDropdown = CreateFrame("Frame", "WeirdLootGuildStatusDropdown", panel, "UIDropDownMenuTemplate")
    statusDropdown:SetPoint("TOPLEFT", statusLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_SetWidth(statusDropdown, 130)
    UIDropDownMenu_JustifyText(statusDropdown, "LEFT")
    UIDropDownMenu_Initialize(statusDropdown, initStatusDropdown)
    panel.statusDropdown = statusDropdown

    self.guildSpecPanel = panel

    GuildMemberDetailFrame:HookScript("OnShow", function()
        addon:RefreshGuildSpecPanel()
    end)
    GuildMemberDetailFrame:HookScript("OnHide", function()
        panel:Hide()
    end)
    -- Clicking another member while the popout is already open never re-fires OnShow;
    -- GuildStatus_Update runs on every selection change and roster redraw, so the shown
    -- values track the live note of whoever is actually selected.
    if hooksecurefunc and GuildStatus_Update then
        hooksecurefunc("GuildStatus_Update", function()
            if GuildMemberDetailFrame:IsShown() then
                addon:RefreshGuildSpecPanel()
            end
        end)
    end
    -- A note edit (ours via the GuildRoster() re-query, or anyone else's) re-scans the guild;
    -- re-derive the shown values whenever the popout is up.
    self:RegisterCallback("GUILD_ROSTER_REFRESHED", function()
        if GuildMemberDetailFrame:IsShown() then
            addon:RefreshGuildSpecPanel()
        end
    end)

    panel:Hide()
end
