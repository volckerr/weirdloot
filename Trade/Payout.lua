local addonName, addon = ...
addon = WeirdLoot

-- Payout bridge: connects WeirdLoot's loot results to the TradeDeliver-1.0 engine.
--
-- Upstream delivery was manual and one-at-a-time (target + whisper the winner, then
-- "Load Item" + "Trade Winner" by hand). This replaces that with the engine's
-- owed-ledger + partner-initiated auto-fill: every processed winner is "owed" their
-- item, then the loot master runs a single payout. Winners open a trade and their
-- items are filled automatically (the LM just clicks Trade to send -- AcceptTrade is
-- hardware-gated on 3.3.5a, so the final click can't be automated).
--
-- The engine owns its own trade/bag events, stack-correct splitting, throttled
-- whispers, and soonest-to-expire ordering for time-limited BoP loot.

function addon:InitializePayout()
    local TradeDeliver = LibStub and LibStub("TradeDeliver-1.0", true)
    if not TradeDeliver then
        self:Print("TradeDeliver-1.0 not found; auto-trade payout disabled.")
        return
    end

    WeirdLootDB.payout = WeirdLootDB.payout or {}
    self.payout = TradeDeliver:New({
        db     = WeirdLootDB.payout,                 -- owed ledger persists here
        name   = "WeirdLoot",
        prefix = "WeirdLootPay",                     -- distinct from the addon's comm prefix
        print  = function(text) addon:Print(text) end,
        debug  = function(text)
            if WeirdLootDB.payoutDebug then addon:Print("|cff888888[pay]|r " .. text) end
        end,
        -- a completed trade is the authoritative "where it went": record per-copy delivery.
        onDelivered = function(player, itemId)
            local ok = addon.lootCore and addon.lootCore:MarkDeliveredFor(player, itemId, time())
            -- trace the seam: did the engine report a delivery, and did the core match an owed award?
            addon:LogCoreEvent("deliver-cb", { player = player, itemId = itemId, ok = ok and true or false })
        end,
        -- route the engine's own trade-flow trace to the same debug log as the core.
        log = function(ev, data) addon:LogCoreEvent(ev, data) end,
        -- Automated trade management (auto-decline + auto-payout) is an ACTIVE-ML-ONLY action. The
        -- engine bails when this returns false, so a non-ML never declines a trade or auto-places owed
        -- items -- even though InitializePayout runs on every client and the owe ledger persists.
        isActive = function() return addon:IsAuthorizedLootMaster() end,
    })

    -- Owes are derived from the core's per-copy awards. A resolve adds owes for that lot's
    -- non-ML winners (whispered once if payout is live); an unlock retracts them. The ML
    -- owns this; raiders never run payout.
    if self.lootCore and not self._payoutWired then
        self._payoutWired = true
        self.lootCore:On("lotResolved", function(lot) addon:OnLotResolvedPayout(lot) end)
        -- one copy of a loot-council lot got a manually-picked winner (AwardCopy): owe just that copy,
        -- not the whole lot (Owe increments, so re-owing the lot would double already-owed copies).
        self.lootCore:On("lotAwarded", function(lot, award) addon:OnLotAwardedPayout(lot, award) end)
        self.lootCore:On("lotUnlocked", function(lot, winners) addon:OnLotUnlockedPayout(lot, winners) end)
        -- core retired an owed copy (it left the bags): forgive it so payout never owes something
        -- the core no longer backs. This keeps the two ledgers in sync during a live session.
        self.lootCore:On("awardRemoved", function(itemId, winner) addon:OnAwardRemovedPayout(itemId, winner) end)
    end
end

function addon:OnAwardRemovedPayout(itemId, winner)
    if not self.payout or not self:IsAuthorizedLootMaster() then return end
    if winner then self.payout:Forgive(winner, itemId) end
end

function addon:OnLotResolvedPayout(lot)
    if not self.payout or not self:IsAuthorizedLootMaster() then return end
    local selfKey = addon.util:NormalizeKey(addon.util:GetPlayerName("player") or "")
    local _, link = addon.util:ItemRender(lot.itemId)
    for _, award in ipairs(lot.awards or {}) do
        local winner = award.state == addon.lootCore.AWARD.OWED and award.winner or nil
        if winner and addon.util:NormalizeKey(winner) ~= selfKey then
            self.payout:Owe(winner, lot.itemId, 1, link)
        end
    end
end

function addon:OnLotAwardedPayout(lot, award)
    if not self.payout or not self:IsAuthorizedLootMaster() then return end
    if not award or award.state ~= addon.lootCore.AWARD.OWED then return end   -- a self-win owes nothing
    local selfKey = addon.util:NormalizeKey(addon.util:GetPlayerName("player") or "")
    if addon.util:NormalizeKey(award.winner or "") == selfKey then return end
    local _, link = addon.util:ItemRender(lot.itemId)
    self.payout:Owe(award.winner, lot.itemId, 1, link)
end

function addon:OnLotUnlockedPayout(lot, winners)
    if not self.payout or not self:IsAuthorizedLootMaster() then return end
    for _, winner in ipairs(winners or {}) do
        self.payout:Forgive(winner, lot.itemId)
    end
end

-- Any change to the accepting-trades state (payout on/off, allow-all-trades on/off): repaint the
-- master tab, refresh the local minimap warning, and push the new flag to raiders. The broadcast is
-- a forced full snapshot (the accepting-trades flag rides the "M" meta line, which deltas omit);
-- AutoBroadcastSession no-ops when no session is active, so this is safe to call unconditionally.
local function onPayoutStateChanged(self)
    if self.ui and self.ui.masterPanel then self:RefreshMasterTab() end
    if self.UpdateMinimapTradeStatus then self:UpdateMinimapTradeStatus() end
    self:AutoBroadcastSession(true)
end

-- True when owed winners can currently trade the loot master for their items: payout mode is on AND
-- incoming trades are not being auto-declined. The ML computes this locally; a raider reads the last
-- value the ML synced onto the session snapshot (defaulting to accepting, so a raider who has not yet
-- received a snapshot never shows a false "closed" warning).
function addon:IsLootMasterAcceptingTrades()
    if self:IsAuthorizedLootMaster() then
        return self.payout ~= nil and self.payout:IsPayoutActive() and self:IsAllowAllTrades()
    end
    if self._mlAcceptingTrades == nil then return true end
    return self._mlAcceptingTrades
end

-- Loot master: whisper everyone still owed and turn on auto-fill.
function addon:StartPayout()
    if not self.payout then
        self:Print("Payout engine unavailable.")
        return
    end
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can run payouts.")
        return
    end
    -- Pure toggle: turn payout mode on even with nothing owed yet. New winners auto-whisper
    -- as they're added, and trades auto-fill on TRADE_SHOW.
    local sent = self.payout:StartPayout()
    if sent > 0 then
        self:Print("Payout ON: whispered " .. sent .. " winner(s). They open a trade; items auto-fill -- click Trade to send.")
    else
        self:Print("Payout ON. No one owed yet; winners will be whispered as they're decided.")
    end
    onPayoutStateChanged(self)
end

-- Pause: stop auto-fill but KEEP the owed list, so Start resumes where it left off.
function addon:StopPayout()
    if self.payout then
        self.payout:StopPayout()
        self:Print("Payout paused. Owed list kept; Start Payout again to resume.")
        onPayoutStateChanged(self)
    end
end

-- Allow-all-trades toggle. This is now a hard master switch for incoming trades:
-- when allow-all is OFF, every incoming trade is declined immediately; when ON,
-- every incoming trade is allowed to open normally.
function addon:IsAllowAllTrades()
    if not self.payout then return false end
    return not self.payout:GetAutoCancel()
end

function addon:SetAllowAllTrades(allow)
    if not self.payout then return end
    self.payout:SetAutoCancel(not allow)
    self:Print(allow
        and "All trades allowed."
        or "All incoming trades will be auto-declined.")
    onPayoutStateChanged(self)
end

function addon:ToggleAllowAllTrades()
    self:SetAllowAllTrades(not self:IsAllowAllTrades())
end

-- An owe only exists because the ML is holding the item to hand over. If the ML does not
-- physically hold it (delivered, vendored, traded away, or a stale owe from before this accounting
-- existed), there is nothing to owe. Reconcile the persisted owe ledger against BAG REALITY -- the
-- same tradeable counts the core reconciles against (itemId -> count) -- and forgive any owe we
-- cannot back with a held copy. This is driven by the bag scan (Session:OnBagUpdate), which only
-- calls it once bags have fully settled and no trade is mid-flight: that is the only safe moment to
-- conclude "we do not have this". It keys off bag truth, never the core's loseable award history,
-- so it can neither be fooled by a lost ledger nor wrongly delete a copy we still hold.
function addon:ReconcilePayoutAgainstBags(heldCounts)
    if not self.payout or not self:IsAuthorizedLootMaster() then return 0 end
    heldCounts = heldCounts or {}
    -- collect-then-forgive: Forgive mutates db.owed, so do not remove while iterating it
    local stale = {}
    for _, entry in pairs(self.payout:GetOwed() or {}) do
        for _, item in ipairs(entry.items or {}) do
            if (heldCounts[item.id] or 0) <= 0 then
                stale[#stale + 1] = { player = entry.name, itemId = item.id }
            end
        end
    end
    for _, s in ipairs(stale) do
        self.payout:Forgive(s.player, s.itemId)
        self:LogCoreEvent("payout-reconcile", { player = s.player, itemId = s.itemId, reason = "not-held" })
    end
    return #stale
end

-- Turn payout mode on whenever a session is active (fresh start OR restored at login).
-- payoutActive is runtime-only and resets every login, so a restored session would
-- otherwise sit with owes that never whisper or auto-fill. Re-whispers anyone still
-- owed so they know to open a trade.
function addon:ResumePayoutMode()
    if not self.payout then return end
    if not (self.session and self.session.active) then return end
    if not self:IsAuthorizedLootMaster() then return end   -- only the real ML re-arms/whispers
    -- Bags load in stages after a login. Reconcile owes against bag reality BEFORE whispering, but
    -- only once bags have settled -- otherwise a half-loaded bag looks empty and we'd both whisper
    -- AND forgive phantoms. If not settled yet, DEFER: set a flag the auth-retry loop re-fires each
    -- frame until bags settle, so the re-whisper happens exactly once, against correct bag truth.
    -- This is what makes the cleanup graceful by design: a stale owe for an item we no longer hold
    -- is reconciled away here, before the login whisper, so it never goes out and never recurs.
    local settled = self.bagSettleAt and (GetTime() >= self.bagSettleAt)
    if not settled then
        self._payoutResumePending = true
        return
    end
    self._payoutResumePending = false
    self:ReconcileLootNow()      -- settled bag scan forgives any owe we no longer hold (nothing to owe)
    local sent = self.payout:StartPayout()
    if sent and sent > 0 then
        self:Print("Payout mode ON: re-whispered " .. sent .. " owed winner(s).")
    end
    if self.ui and self.ui.masterPanel then self:RefreshMasterTab() end
    if self.UpdateMinimapTradeStatus then self:UpdateMinimapTradeStatus() end
end

function addon:TogglePayout()
    if self.payout and self.payout:IsPayoutActive() then
        self:StopPayout()
    else
        self:StartPayout()
    end
end

-- Fill the currently-open trade from the loot ledger via the engine -- the manual
-- delivery path, using the same filler as auto-payout (no hand-placing items, so the
-- two can't conflict). Owing happens at Process Loot, so this works whether or not
-- payout mode is on.
function addon:FillOpenTrade()
    if not self.payout then
        self:Print("Payout engine unavailable.")
        return
    end
    local ok, reason = self.payout:FillOpenTrade()
    if not ok then
        self:Print(reason or "Could not fill the trade.")
    end
end
