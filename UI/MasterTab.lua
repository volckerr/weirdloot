-- WeirdLoot Master (loot master) tab: roster import, loot-priority + named-items editors, auto-mode
-- and disenchanter controls, and the bag snapshot. Pure presentation; pulls shared widgets from addon.UI.
local addon = WeirdLoot
local util = addon.util
local UI = addon.UI
local createLabel = UI.createLabel
local createButton = UI.createButton
local setButtonTooltip = UI.setButtonTooltip
local elevateInteractiveFrame = UI.elevateInteractiveFrame
local getOptions = UI.getOptions

function addon:BuildMasterTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.master = panel

    panel.warning = createLabel(panel, "", "TOPLEFT", panel, "TOPLEFT", 12, 2)
    panel.warning:SetTextColor(1, 0.2, 0.2)

    -- Section header style matches the Options tab: gold-tinted large text with a thin gold
    -- horizontal divider underneath. Returns the divider so the next widget can anchor below it.
    local function makeSectionHeader(text, anchorTo, anchorPoint, offsetY)
        local h = createLabel(panel, text, "TOPLEFT", anchorTo, anchorPoint or "BOTTOMLEFT", 0, offsetY or -16)
        h:SetFontObject(GameFontHighlightLarge)
        h:SetTextColor(1, 0.82, 0)
        local d = panel:CreateTexture(nil, "ARTWORK")
        d:SetTexture("Interface\\Buttons\\WHITE8x8")
        d:SetVertexColor(0.5, 0.4, 0.1, 0.6)
        d:SetHeight(1)
        d:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
        d:SetPoint("RIGHT", panel, "RIGHT", -40, 0)
        return h, d
    end

    -- Section 1: Loot Master Controls -- session-time actions.
    local lmHeader, lmDivider = makeSectionHeader("Loot Master Controls", panel, "TOPLEFT", -12)
    lmHeader:ClearAllPoints()
    lmHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -12)

    local processButton = createButton(panel, "Start Rolls", 120, 24)
    processButton:SetPoint("TOPLEFT", lmDivider, "BOTTOMLEFT", 0, -8)
    processButton:SetScript("OnClick", function()
        addon:ProcessLoot()
    end)

    local payoutButton = createButton(panel, "Start Payout", 120, 24)
    payoutButton:SetPoint("LEFT", processButton, "RIGHT", 8, 0)
    payoutButton:SetScript("OnClick", function()
        addon:TogglePayout()
    end)

    -- Incoming-trades toggle. Default ON. When OFF, UNSOLICITED incoming trades are declined;
    -- trades the ML starts always go through (and still auto-fill owed items).
    local allowTradesButton = createButton(panel, "Incoming Trades: ON", 160, 24)
    allowTradesButton:SetPoint("LEFT", payoutButton, "RIGHT", 8, 0)
    allowTradesButton:SetScript("OnClick", function()
        addon:ToggleAllowAllTrades()
    end)

    -- Section 2: Session Controls. ML-gated, grouped with the Loot Master Controls above. The
    -- Import/Export section sits below since its exports are usable by any raider (not ML-gated).
    local sessHeader, sessDivider = makeSectionHeader("Session Controls", processButton, "BOTTOMLEFT", -16)

    local startButton = createButton(panel, "Start Session", 120, 24)
    startButton:SetPoint("TOPLEFT", sessDivider, "BOTTOMLEFT", 0, -8)
    startButton:SetScript("OnClick", function()
        -- Restarting over a live session is destructive (wipes the running tally), so confirm first.
        if addon.session and addon.session.active then
            StaticPopup_Show("WEIRDLOOT_RESTART_SESSION")
        else
            addon:StartLootSession()
        end
    end)

    local endSessionButton = createButton(panel, "End Session", 120, 24)
    endSessionButton:SetPoint("LEFT", startButton, "RIGHT", 8, 0)
    endSessionButton:SetScript("OnClick", function()
        StaticPopup_Show("WEIRDLOOT_END_SESSION")
    end)

    local scanButton = createButton(panel, "Scan Bags", 120, 24)
    scanButton:SetPoint("LEFT", endSessionButton, "RIGHT", 8, 0)
    scanButton:SetScript("OnClick", function()
        addon:RefreshSessionItems(true)
    end)

    local unlockButton = createButton(panel, "Unlock Roll", 100, 24)
    unlockButton:SetPoint("LEFT", scanButton, "RIGHT", 8, 0)
    unlockButton:SetScript("OnClick", function()
        addon:UnlockAllSessionRolls()
    end)

    -- ML-loan reset: same action as the loan card's Cancel Loan / "/wl loan cancel". Ends the
    -- running loan and returns the WoW role to the owner; the winner and the pending offer
    -- survive, so the loan can be restarted from the card. Enabled only while a loan is active.
    local loanCancelButton = createButton(panel, "Cancel ML Loan", 120, 24)
    loanCancelButton:SetPoint("LEFT", unlockButton, "RIGHT", 8, 0)
    loanCancelButton:SetScript("OnClick", function()
        if addon:ActiveMLLoan() then addon:EndMLLoan("cancelled") end
        addon:RefreshMasterTab()
    end)

    -- Section 3: Import/Export Controls. Exports are open to everyone (raiders render results from
    -- the synced ledger); the import/broadcast buttons stay ML-gated by the refresh below.
    local ioHeader, ioDivider = makeSectionHeader("Import/Export Controls", startButton, "BOTTOMLEFT", -16)

    local exportWinnersButton = createButton(panel, "Export Winners", 110, 24)
    exportWinnersButton:SetPoint("TOPLEFT", ioDivider, "BOTTOMLEFT", 0, -8)
    exportWinnersButton:SetScript("OnClick", function()
        addon:ExportWinners()
    end)

    local exportLogButton = createButton(panel, "Export Log", 100, 24)
    exportLogButton:SetPoint("LEFT", exportWinnersButton, "RIGHT", 8, 0)
    exportLogButton:SetScript("OnClick", function()
        addon:ExportLog()
    end)

    local importRosterButton = createButton(panel, "Import Roster", 110, 24)
    importRosterButton:SetPoint("LEFT", exportLogButton, "RIGHT", 8, 0)
    importRosterButton:SetScript("OnClick", function()
        addon:ImportRoster()
    end)

    -- No Broadcast Roster button: roster edits auto-broadcast from whoever makes them
    -- (GUEST_UPSERT from the Raiders tab add flow; guild data needs no push at all).

    local importNamedItemsButton = createButton(panel, "Import Named Items", 130, 24)
    importNamedItemsButton:SetPoint("LEFT", importRosterButton, "RIGHT", 8, 0)
    importNamedItemsButton:SetScript("OnClick", function()
        addon:ImportNamedItems()
    end)

    local broadcastNamedItemsButton = createButton(panel, "Broadcast Named Items", 150, 24)
    broadcastNamedItemsButton:SetPoint("LEFT", importNamedItemsButton, "RIGHT", 8, 0)
    broadcastNamedItemsButton:SetScript("OnClick", function()
        addon:BroadcastNamedItems()
    end)

    panel.startButton = startButton
    panel.endSessionButton = endSessionButton
    panel.scanButton = scanButton
    panel.processButton = processButton
    panel.unlockButton = unlockButton
    panel.exportWinnersButton = exportWinnersButton
    panel.exportLogButton = exportLogButton
    panel.importRosterButton = importRosterButton
    panel.importNamedItemsButton = importNamedItemsButton
    panel.broadcastNamedItemsButton = broadcastNamedItemsButton
    panel.payoutButton = payoutButton
    panel.allowTradesButton = allowTradesButton
    panel.loanCancelButton = loanCancelButton

    setButtonTooltip(loanCancelButton, "Cancel ML Loan",
        "Ends the running master-loot loan and returns the loot-master role to you (or prompts the "
        .. "raid leader to). The winner is kept: the loan can be restarted from the item's win card. "
        .. "Use this to reset a loan that went wrong instead of swapping loot master by hand.")

    setButtonTooltip(allowTradesButton, "Incoming Trades (Toggle)",
        "Controls trades OTHERS open with you. When ON (default), incoming trades open normally. When "
        .. "OFF, unsolicited incoming trades are auto-declined. Trades YOU start (right-click -> Trade) "
        .. "are never declined and still auto-fill owed items in Payout Mode.")

    setButtonTooltip(payoutButton, "Payout Mode (Toggle)",
        "Turn automatic loot delivery on or off. While ON: each winner is whispered to open a trade with you, "
        .. "and their owed items auto-fill into the trade window (you click Trade to send). If Incoming Trades "
        .. "is OFF, unsolicited incoming trades are declined before payout can fill them (trades you start still fill). "
        .. "Pause keeps the owed list but stops auto-fill.")
		
	setButtonTooltip(startButton, "Start Session",
        "Establishes the active loot session.")
		
	setButtonTooltip(scanButton, "Scan Bags",
        "Searches the Lootmaster's bags for tradeable |cffa335ee[Epic]|r items to be rolled out during an active session.")
	
	setButtonTooltip(unlockButton, "Unlock Roll",
        "Clears the rollout lock so the current session's loot can be rerolled intentionally.")

	setButtonTooltip(exportWinnersButton, "Export Winners",
        "Generates a plain-text list of all looted items and their recipients for recordkeeping.")
		
	setButtonTooltip(exportLogButton, "Export Log",
		"Generates a audit log of all looted items and their associated rolls and outcomes.")

	setButtonTooltip(importRosterButton, "Import Roster",
		"Opens an editable import window where you can paste the current weekly roster list and save it to WeirdLoot. This includes information such as character name, class, specialization, and designation (Main, Designated Alt, Alt).")

	setButtonTooltip(importNamedItemsButton, "Import Named Items",
		"Opens an editable import window where you can paste the current named-item priority list and save it to WeirdLoot. This is reserved for items that are prioritized based on Loot Council decision.")

	setButtonTooltip(processButton, "Start Rolls",
		"Starts live rolls in batches (size configurable in Options). The next batch starts when the current one finishes.")

    panel.controlsTitle = createLabel(panel, "Controls", "TOPLEFT", exportWinnersButton, "BOTTOMLEFT", 0, -24)
    panel.controlsTitle:SetFontObject(GameFontHighlightLarge)

    panel.summary = createLabel(panel, "", "TOPLEFT", panel.controlsTitle, "BOTTOMLEFT", 0, -8)
    panel.summary:SetWidth(900)
    panel.summary:SetJustifyV("TOP")

    panel.snapshotTitle = createLabel(panel, "Session Snapshot", "TOPLEFT", panel.summary, "BOTTOMLEFT", 0, -20)
    panel.snapshotTitle:SetFontObject(GameFontHighlightLarge)

    panel.snapshot = createLabel(panel, "", "TOPLEFT", panel.snapshotTitle, "BOTTOMLEFT", 0, -8)
    panel.snapshot:SetWidth(900)
    panel.snapshot:SetJustifyV("TOP")

    self.ui.masterPanel = panel
end

function addon:RefreshMasterTab()
    local panel = self.ui.masterPanel
    local authorized = self:IsAuthorizedLootMaster()
    if not authorized and self.roster.mlRosterUnreadable then
        -- We ARE the master looter (per GetLootMethod) but rarely the server will fail to load
        -- a roster so the name-match can't confirm it. Only a reload recovers the roster.
        panel.warning:SetText("|cffff4040The raid roster failed to load, so loot-master controls are disabled. Please /reload to fix it.|r")
    else
        panel.warning:SetText(authorized and "" or "You are not the current Loot Master. Controls are locked.")
    end

    -- Exports are open to everyone, so keep them enabled regardless of ML authority.
    panel.exportWinnersButton:Enable()
    panel.exportLogButton:Enable()

    if authorized then
        panel.startButton:Enable()
        panel.endSessionButton:Enable()
        panel.scanButton:Enable()
        panel.processButton:Enable()
        panel.importRosterButton:Enable()
        panel.importNamedItemsButton:Enable()
        panel.broadcastNamedItemsButton:Enable()
        panel.payoutButton:Enable()
        if panel.allowTradesButton then panel.allowTradesButton:Enable() end
    else
        panel.startButton:Disable()
        panel.endSessionButton:Disable()
        panel.scanButton:Disable()
        panel.processButton:Disable()
        panel.importRosterButton:Disable()
        panel.importNamedItemsButton:Disable()
        panel.broadcastNamedItemsButton:Disable()
        panel.payoutButton:Disable()
        if panel.allowTradesButton then panel.allowTradesButton:Disable() end
    end

    if panel.unlockButton then
        if authorized then
            panel.unlockButton:Show()
            if self:HasLockedItems() then
                panel.unlockButton:Enable()
            else
                panel.unlockButton:Disable()
            end
        else
            panel.unlockButton:Disable()
        end
    end

    -- Only the loan's owner can end it (EndMLLoan is owner-gated; the pin keeps the owner
    -- authorized mid-loan), so authority + an active loan is exactly the enabled condition.
    local loan = self:ActiveMLLoan()
    if panel.loanCancelButton then
        if authorized and loan then
            panel.loanCancelButton:Enable()
        else
            panel.loanCancelButton:Disable()
        end
    end

    local payoutActive = self.payout and self.payout:IsPayoutActive()
    panel.payoutButton:SetText(payoutActive and "Payout Mode: ON" or "Payout Mode: OFF")

    if panel.allowTradesButton then
        local allow = self:IsAllowAllTrades()
        panel.allowTradesButton:SetText(allow and "Incoming Trades: ON" or "Incoming Trades: OFF")
    end

    local attendeeCount = #(self:GetAttendees() or {})
    local itemCount = #(self.lootView.items or {})
    local resultCount = #(self.lootView.results or {})
    local lockedCount = 0
    for _, item in ipairs(self.lootView.items or {}) do
        if self:IsItemLocked(item.id) then
            lockedCount = lockedCount + 1
        end
    end
    panel.summary:SetText(table.concat({
        "Start Session: Establishes the active loot session.",
        "Scan Bags: Searches bags for current epic items from the loot master's bags.",
        "Start Rolls: Starts live rolls in batches (size configurable in Options). The next batch starts when the current one finishes.",
        "Unlock Roll: Clears the rollout lock so the current session's loot can be rerolled intentionally.",
        "Pause Payout: Toggles payout mode so owed winners can trade for auto-filled loot, or pauses that flow without clearing the ledger.",
        "Export Winners: Opens a simple item-to-winner export list for sharing or cleanup.",
        "Export Log: Opens the detailed loot-resolution audit log for review or record keeping.",
        "Import Roster: Opens an editable import window where you can paste the current weekly roster list and save it to WeirdLoot.",
        "Import Named Items: Opens an editable import window where you can paste the current named-item priority list and save it to WeirdLoot.",
        "Broadcast Named Items: Sends your current named-item list to the raid once so each raider's addon saves and uses the latest version.",
    }, "\n"))

    local snapshotText = string.format(
        "Config revision: %d\nRaid attendees: %d\nSession items: %d\nLocked items: %d\nProcessed results: %d",
        self.config.revision or 0,
        attendeeCount,
        itemCount,
        lockedCount,
        resultCount
    )
    if loan then
        local _, link = util:ItemRender(loan.itemId)
        snapshotText = snapshotText .. string.format(
            "\n|cffffd200ML loan active:|r %s holds the loot-master role for %s (owner: %s).",
            loan.borrower, link or ("item " .. tostring(loan.itemId)), loan.owner)
    end
    panel.snapshot:SetText(snapshotText)
end
