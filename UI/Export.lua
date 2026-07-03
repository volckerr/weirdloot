-- WeirdLoot export/import windows: winners list, detailed audit log, and roster / named-items
-- import. Pure presentation; pulls shared widgets from the addon.UI namespace defined in UI.lua.
local addon = WeirdLoot
local UI = addon.UI
local createTextWindow = UI.createTextWindow
local sortGroupedRollers = UI.sortGroupedRollers
local buildPlainCandidateSummary = UI.buildPlainCandidateSummary
local formatSpecPriorityDisplay = UI.formatSpecPriorityDisplay

function addon:BuildWinnersExportText()
    local lines = {}

    for _, result in ipairs(self.lootView.results or {}) do
        local itemName = result.itemName or ""
        if result.winners and #result.winners > 0 then
            for _, winnerName in ipairs(result.winners) do
                lines[#lines + 1] = string.format("%s\t%s", itemName, winnerName or "")
            end
        elseif result.isLootCouncil then
            lines[#lines + 1] = string.format("%s\t%s", itemName, "Loot Council")
        else
            lines[#lines + 1] = string.format("%s\t%s", itemName, "No winner")
        end
    end

    if #lines == 0 then
        return ""
    end

    return table.concat(lines, "\n")
end

function addon:BuildDetailedExportLogText()
    local blocks = {}
    local groups = {
        { key = "bis", label = "BiS Rollers:" },
        { key = "ms", label = "MS Rollers:" },
        { key = "mu", label = "MU Rollers:" },
        { key = "os", label = "OS Rollers:" },
        { key = "tm", label = "TM Rollers:" },
    }

    for _, result in ipairs(self.lootView.results or {}) do
        local groupedRollers = {
            bis = {},
            ms = {},
            mu = {},
            os = {},
            tm = {},
        }
        local lines = {}
        local quantityText = (result.quantity or 1) > 1 and string.format(" x%d", result.quantity or 1) or ""
        local lcNamesText = string.trim(result.lcNamesText or "")
        local hasLcNames = lcNamesText ~= "" and lcNamesText ~= "none"
        lines[#lines + 1] = "Item: " .. (result.itemName or "") .. quantityText
        lines[#lines + 1] = ""

        for _, roller in ipairs(result.allRollerDetails or {}) do
            local choice = roller.responseType or "pass"
            if choice ~= "pass" then
                groupedRollers[choice] = groupedRollers[choice] or {}
                groupedRollers[choice][#groupedRollers[choice] + 1] = roller
            end
        end

        local renderedGroups = 0
        for _, group in ipairs(groups) do
            local entries = groupedRollers[group.key] or {}
            if #entries > 0 then
                sortGroupedRollers(entries)
                if renderedGroups > 0 then
                    lines[#lines + 1] = ""
                end

                lines[#lines + 1] = group.label
                for _, roller in ipairs(entries) do
                    local rollText = roller.rollText and (" - (" .. roller.rollText .. ")") or ""
                    lines[#lines + 1] = buildPlainCandidateSummary(roller) .. rollText
                end
                renderedGroups = renderedGroups + 1
            end
        end

        if renderedGroups > 0 then
            lines[#lines + 1] = ""
        end

        if hasLcNames then
            lines[#lines + 1] = "LC Names:"
            lines[#lines + 1] = lcNamesText
            lines[#lines + 1] = ""
        end

        lines[#lines + 1] = "Spec Priority:"
        lines[#lines + 1] = formatSpecPriorityDisplay(result.specPriorityText)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Prioritized Rolls:"
        if #(result.rollDetails or {}) == 0 then
            lines[#lines + 1] = "none"
        else
            for _, roll in ipairs(result.rollDetails or {}) do
                local rollValue = roll.auto and "AUTO" or tostring(roll.roll or "")
                local namedText = roll.isNamed and " - LC" or ""
                lines[#lines + 1] = string.format("%s - (%s)%s", buildPlainCandidateSummary(roll), rollValue, namedText)
            end
        end

        lines[#lines + 1] = ""
        lines[#lines + 1] = "Winner:"
        if result.isLootCouncil then
            lines[#lines + 1] = "Loot Council"
        elseif #(result.winnerDetails or {}) == 0 then
            lines[#lines + 1] = "No winner"
        else
            for _, winner in ipairs(result.winnerDetails or {}) do
                local rollValue = winner.auto and "AUTO" or tostring(winner.roll or "")
                local priorityText = winner.isNamed and " - LC Prio" or ""
                lines[#lines + 1] = string.format("%s (%s)%s", winner.name or "Unknown", rollValue, priorityText)
            end
        end

        blocks[#blocks + 1] = table.concat(lines, "\n")
    end

    return table.concat(blocks, "\n\n")
end

function addon:ShowExportWindow(kind, titleText, bodyText)
    self.ui = self.ui or {}
    self.ui.exportWindows = self.ui.exportWindows or {}

    local window = self.ui.exportWindows[kind]
    if not window then
        window = createTextWindow("WeirdLoot" .. kind .. "ExportWindow", 720, 520, titleText, {
            readOnly = true,
            highlightOnFocus = true,
        })
        self.ui.exportWindows[kind] = window
    end

    window.title:SetText(titleText or "")
    window.editBox:SetText(bodyText or "")
    window.editBox:SetFocus()
    window.editBox:HighlightText()
    window.scroll:SetVerticalScroll(0)
    window:Show()
end

function addon:ShowImportWindow(kind, titleText, bodyText, onSave)
    self.ui = self.ui or {}
    self.ui.importWindows = self.ui.importWindows or {}

    local window = self.ui.importWindows[kind]
    if not window then
        window = createTextWindow("WeirdLoot" .. kind .. "ImportWindow", 720, 520, titleText, {
            showSaveButton = true,
            saveButtonText = "Save Import",
        })
        self.ui.importWindows[kind] = window
    end

    window.saveButton:SetScript("OnClick", function()
        if onSave then
            onSave(window.editBox:GetText() or "")
        end
        window.editBox:ClearFocus()
        window:Hide()
    end)

    window.title:SetText(titleText or "")
    window.editBox:SetText(bodyText or "")
    window.editBox:SetFocus()
    window.scroll:SetVerticalScroll(0)
    window:Show()
end

-- Exports are open to everyone: raiders render lootView.results from the same synced ledger as the
-- ML, so anyone can pull a winners list or audit log for the loot sheet without holding ML.
function addon:ExportWinners()
    self:ShowExportWindow("Winners", "Export Winners", self:BuildWinnersExportText())
end

function addon:ExportLog()
    self:ShowExportWindow("Log", "Export Log", self:BuildDetailedExportLogText())
end

function addon:ImportRoster()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can import the roster.")
        return
    end

    self:ShowImportWindow("Roster", "Import Roster", self.config.rosterImportText or "", function(text)
        addon:SaveImports(text, addon.config.lootPriorityText, addon.config.namedItemsText)
    end)
end

function addon:ImportNamedItems()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can import named items.")
        return
    end

    self:ShowImportWindow("NamedItems", "Import Named Items", self.config.namedItemsText or "", function(text)
        addon:SaveImports(addon.config.rosterImportText, addon.config.lootPriorityText, text)
    end)
end
