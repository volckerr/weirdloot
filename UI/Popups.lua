-- Static popup dialogs used by the addon. These are registered into the WoW global
-- StaticPopupDialogs table at addon load (see the static initializer at the bottom).
-- Loaded by the toc; no exports -- the global table is the contract.
--
-- Popups here:
--   WEIRDLOOT_SAVE_WHITELIST_PRESET    -- name + body, save into customWhitelistPresets
--   WEIRDLOOT_DELETE_WHITELIST_PRESET -- confirm before deleting a custom whitelist preset
--   WEIRDLOOT_SAVE_BLACKLIST_PRESET    -- name + body, save into customBlacklistPresets
--   WEIRDLOOT_DELETE_BLACKLIST_PRESET -- confirm before deleting a custom blacklist preset
--   WEIRDLOOT_SET_LC_OVERRIDE         -- per-item loot-council priority override
--   WEIRDLOOT_REROLL_ITEM             -- confirm before unlocking a resolved lot for re-roll
--   WEIRDLOOT_END_SESSION             -- confirm before ending the current session
--   WEIRDLOOT_START_SESSION           -- zone-in prompt when becoming ML with no session
--   WEIRDLOOT_RESTART_SESSION         -- confirm before restarting mid-session
--
-- see REFACTOR_PLAN.md Phase 3 for the planned dedupe of the 4 near-identical whitelist/blacklist
-- save+delete dialogs (they share OnShow / OnAccept / EditBoxOnEnterPressed / EditBoxOnEscapePressed
-- and differ only in text, the source box, the save/delete call, and the dropdown refresh).

local addon = WeirdLoot

-- Helper: build the SAVE + DELETE preset dialog pair for one list kind ("whitelist" or "blacklist").
-- Each kind reads its text from a different editBox on the options panel, saves/deletes into a
-- different SavedVariable, and refreshes a different dropdown. The dialog plumbing (the editBox,
-- the OnAccept handlers, the common flags) is identical.
local function buildPresetDialogs(kind)
    local cap   = kind:sub(1, 1):upper() .. kind:sub(2)         -- "Whitelist" / "Blacklist"
    local box   = kind .. "Box"                                  -- "whitelistBox" / "blacklistBox"
    local save  = "SaveCustom"   .. cap .. "Preset"
    local del   = "DeleteCustom" .. cap .. "Preset"
    local refr  = "Refresh"      .. cap .. "PresetDropdown"

    -- The Options "panel" is a ScrollFrame; the multi-line text widgets live on the scroll child
    -- stashed at addon.ui.optionsPanel. Reading from addon.ui.panels.options here returns nil for
    -- the box and silently saves an empty preset.
    local function readBodyText()
        local inner = addon.ui and addon.ui.optionsPanel
        local widget = inner and inner[box] and inner[box].editBox
        return (widget and widget:GetText()) or ""
    end

    StaticPopupDialogs["WEIRDLOOT_SAVE_" .. kind:upper() .. "_PRESET"] = {
        text = "Save " .. kind .. " as preset. Enter a name:",
        button1 = ACCEPT or "Save",
        button2 = CANCEL or "Cancel",
        hasEditBox = 1,
        editBoxWidth = 200,
        maxLetters = 40,
        OnShow = function(self)
            if self.editBox then self.editBox:SetText("") self.editBox:SetFocus() end
        end,
        OnAccept = function(self)
            local name = self.editBox and self.editBox:GetText() or ""
            name = string.match(name, "^%s*(.-)%s*$") or ""
            if name == "" then return end
            if addon[save](addon, name, readBodyText()) then
                if addon[refr] then addon[refr](addon, name) end
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            if parent and parent.button1 then parent.button1:Click() end
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
    }

    StaticPopupDialogs["WEIRDLOOT_DELETE_" .. kind:upper() .. "_PRESET"] = {
        text = "Delete custom " .. kind .. " preset \"%s\"?",
        button1 = YES,
        button2 = NO,
        OnAccept = function(self, data)
            if addon[del](addon, data) then
                if addon[refr] then addon[refr](addon, nil) end
            end
        end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
    }
end

buildPresetDialogs("whitelist")
buildPresetDialogs("blacklist")

StaticPopupDialogs["WEIRDLOOT_SET_LC_OVERRIDE"] = {
    text = "Session LC priority for %s\nFormat:  player1/player2  or  player1 > player2 > LC\nLeave blank to clear.",
    button1 = ACCEPT or "Save",
    button2 = CANCEL or "Cancel",
    hasEditBox = 1,
    editBoxWidth = 260,
    maxLetters = 200,
    OnShow = function(self)
        local data = self.data
        if self.editBox then
            self.editBox:SetText((data and data.current) or "")
            self.editBox:SetFocus()
            self.editBox:HighlightText()
        end
        if data and data.itemLink and data.itemLink ~= "" then
            GameTooltip:SetOwner(self, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("TOPLEFT", self, "TOPRIGHT", 8, 0)
            GameTooltip:SetHyperlink(data.itemLink)
            GameTooltip:Show()
        end
    end,
    OnAccept = function(self)
        local data = self.data
        local text = self.editBox and self.editBox:GetText() or ""
        if data and data.itemName then
            addon:SetSessionLCOverride(data.itemName, text)
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        if parent and parent.button1 then parent.button1:Click() end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    OnHide = function() GameTooltip:Hide() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["WEIRDLOOT_REROLL_ITEM"] = {
    text = "Confirm you want to reroll %s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self)
        local data = self.data
        if data and data.lotId then
            addon:UnlockSessionRoll(data.lotId)
        end
    end,
    OnShow = function(self)
        local data = self.data
        if data and data.itemLink and data.itemLink ~= "" then
            GameTooltip:SetOwner(self, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("TOPLEFT", self, "TOPRIGHT", 8, 0)
            GameTooltip:SetHyperlink(data.itemLink)
            GameTooltip:Show()
        end
    end,
    OnHide = function() GameTooltip:Hide() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["WEIRDLOOT_END_SESSION"] = {
    text = "End the current WeirdLoot session and clear its state?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        addon:ClearSession()
        addon:Print("Loot session ended.")
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
}

-- ML loan (MLLoan.lua): when the loan's OWNER is not the raid leader, the LEADER's client prompts
-- them to perform the role swaps (only the leader can SetLootMethod). data = the player to hand
-- the WoW master-looter role to; the loan transitions drive these via MaybePromptLeaderLoanSwap.
StaticPopupDialogs["WEIRDLOOT_LOAN_SWAP"] = {
    text = "WeirdLoot: lend master loot to %s so they can pick up %s?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self)
        if SetLootMethod and self.data then SetLootMethod("master", self.data) end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
}

StaticPopupDialogs["WEIRDLOOT_LOAN_RESTORE"] = {
    text = "WeirdLoot: the loaned item was picked up. Return master loot to %s?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self)
        if SetLootMethod and self.data then SetLootMethod("master", self.data) end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
}

StaticPopupDialogs["WEIRDLOOT_START_SESSION"] = {
    text = "Start a WeirdLoot session for this raid?",
    button1 = YES,
    button2 = NO,
    OnAccept = function() addon:StartLootSession() end,
    OnCancel = function() addon.raidPrompt.declined = true end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
}

-- Restarting mid-session wipes the live roll/loot tally and re-baselines from current bags
-- (StartLootSession resets lootCore, responses and owed payouts), so gate it behind an explicit
-- confirmation the same way End Session is.
StaticPopupDialogs["WEIRDLOOT_RESTART_SESSION"] = {
    text = "A WeirdLoot session is already running. Starting fresh wipes the current raid's roll and loot history and re-baselines from your current bags. Continue?",
    button1 = YES,
    button2 = NO,
    OnAccept = function() addon:StartLootSession() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
}
