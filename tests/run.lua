-- Out-of-game test battery for WeirdLoot's LootCore migration.
-- Loads the REAL addon files into mocked WoW environments (one per simulated client via
-- setfenv) and drives end-to-end flows: bag reconcile, live rolls, top-N resolution,
-- the stale-roll regression, payout owes, per-copy delivery, and ML->raider snapshot sync.
--
-- Run from the addon dir:  luajit tests/run.lua
--
-- Most bag/tooltip eligibility is monkeypatched (we inject eligible counts directly), so we rarely
-- need GameTooltip line scraping; everything else runs the actual addon code.
--
-- EXCEPTION -- item tradeability: the TradeDeliver payout engine decides at place-time whether a held
-- copy is tradeable by scanning its tooltip (soulbound line + BoP trade-window line). A scan-tooltip
-- mock (`newScanTip`, in makeWorld below) feeds it real left-lines via putBag(..., { lines = {...} })
-- or the shorthand { bound = true, win = secs }. The authoritative line strings are REAL in-game
-- captures kept in `tests/tooltip_fixtures.lua` -- use those for any tradeability test instead of
-- inventing tooltip text (e.g. the "tooltip ground truth" test drives every fixture through the engine).
--
-- UI.lua is intentionally omitted: it is pure presentation and pulls in heavy FrameXML
-- (FauxScrollFrame_*, templates) irrelevant to loot accounting. The projections the tests
-- assert on (lootView.items / lootView.results) are built in Session, not UI.
--
-- This file is now a thin orchestrator over the per-module suites. The shared harness
-- (makeWorld, setBag, flushWireTo, syncView, ...) lives in tests/_framework.lua, and each suite
-- in tests/unit_*.lua / tests/integration_*.lua calls F = framework:get() then drives the same
-- helpers. New tests should prefer adding a focused suite rather than appending here.
local F = dofile("tests/_framework.lua").get()
local check, eq, test = F.check, F.eq, F.test
local makeWorld, setBag, bagUpdate, startSession = F.makeWorld, F.setBag, F.bagUpdate, F.startSession
local lotsFor, openLot, owedCount = F.lotsFor, F.openLot, F.owedCount
local flushWireTo, clearWire, syncView = F.flushWireTo, F.clearWire, F.syncView
local makeRng, putBag, fillBagsExcept = F.makeRng, F.putBag, F.fillBagsExcept
local fireEvent, pump, setPartner = F.fireEvent, F.pump, F.setPartner
local runTrade, runManualTrade, resolveOwedTo = F.runTrade, F.runManualTrade, F.resolveOwedTo
local linkFor = F.linkFor
local flushTaplistBounces = F.flushTaplistBounces
-- All mutable test state lives on the framework: WIRE (the recorded wire queue) and CLOCK
-- (the simulated clock). Tests read F.WIRE / F.CLOCK directly so they always see the current
-- queue/clock even after flushWireTo reassigns F.WIRE to a fresh table.

-- ===========================================================================
-- INTEGRATION BATTERY (the original 147 end-to-end tests, migrated verbatim to the framework)
-- ===========================================================================
-- back-compat: original tests used locals named `pass`/`fail`; the framework owns these now,
-- so we read through F after the battery completes.

-- ===========================================================================
-- BATTERY
-- ===========================================================================

test("core self-checks (in-harness)", function()
    local w = makeWorld("Masterlooter", true)
    check(w.addon.LootCore.RunSelfChecks(false), "all core self-checks pass")
end)

test("shipped defaults: 30s rolls, 10s winner popup auto-close, auto-start on", function()
    local w = makeWorld("Masterlooter", true)
    eq(w.shippedDefaults.rollDuration, 30, "roll duration default is 30s")
    eq(w.shippedDefaults.resultPopupAutoCloseEnabled, true, "winner popup auto-close is enabled by default")
    eq(w.shippedDefaults.resultPopupAutoCloseSeconds, 10, "winner popup auto-close duration is 10s")
    eq(w.shippedDefaults.autoStartRoll, true, "new loot auto-starts rolls by default")
end)

test("named-item winners render as LC Prio instead of BiS", function()
    local w = makeWorld("Masterlooter", true)
    local record = {
        allRollerDetails = {
            { name = "Volcker", responseType = "bis", rollText = "88", isNamed = true },
        },
        winnerDetails = {
            { name = "Volcker", className = "Warrior", roll = 88, isNamed = true },
        },
        winners = { "Volcker" },
        itemName = "Item-name",
        quantity = 1,
        lcNamesText = "",
        specPriorityText = "",
    }

    local sections = w.addon:SectionsFromResult(record)
    local detailText = w.addon:BuildResultDetail(record)
    eq(sections[1] and sections[1].members[1] and sections[1].members[1].isNamed, true, "named flag carried into popup sections")
    check(string.find(detailText, "LC Prio", 1, true) ~= nil, "resolver detail text labels named winners as LC Prio")
end)

test("session start baselines existing loot as idle (no auto-roll)", function()
    local w = makeWorld("Masterlooter", true)
    setBag(w, 40001, 1)             -- already carrying one before the session
    startSession(w)
    local lot = openLot(w, 40001)
    check(lot ~= nil, "baseline lot minted")
    eq(lot and lot.state, "idle", "pre-existing loot is idle, not surfaced")
    check(w.addon.lootCore:State(lot.id) ~= "pending", "not auto-surfaced")
end)

test("fresh drop mints a NEW lot and auto-surfaces (pending)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40002, 1)
    bagUpdate(w)
    local lot = openLot(w, 40002)
    check(lot ~= nil, "fresh lot minted")
    eq(lot and lot.state, "pending", "fresh drop auto-surfaced to pending")
    eq(#w.addon.lootView.items, 1, "projection has one item")
    eq(w.addon.lootView.items[1].itemId, 40002, "projection itemId from link")
end)

test("pre-roll duplicate grows the open lot (one row, quantity 2)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40002, 1); bagUpdate(w)
    setBag(w, 40002, 2); bagUpdate(w)
    eq(#lotsFor(w, 40002), 1, "still a single lot")
    eq(openLot(w, 40002).count, 2, "lot count grew to 2")
    eq(w.addon.lootView.items[1].quantity, 2, "projection quantity 2")
end)

test("skip then re-drop re-surfaces the lot (popup returns for new loot)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40002, 1); bagUpdate(w)
    local lot = openLot(w, 40002)
    eq(w.addon.lootCore:State(lot.id), "pending", "first drop surfaced")
    w.addon.lootCore:Skip(lot.id)
    eq(w.addon.lootCore:State(lot.id), "skipped", "skip snoozes it")
    -- same boss killed again: a second copy enters the bags. The fresh count increase must
    -- re-surface the snoozed lot rather than leave it stuck (the surfacing-by-mint-event bug).
    setBag(w, 40002, 2); bagUpdate(w)
    eq(w.addon.lootCore:State(lot.id), "pending", "re-drop re-surfaces the skipped lot")
    eq(openLot(w, 40002).count, 2, "count grew to 2")
end)

test("live roll: single copy, two rollers -> one owed winner + payout", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    eq(w.addon.lootCore:State(lot.id), "rolling", "lot is rolling")
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:RegisterInterest(lot.id, "Bob", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    eq(L.state, "resolved", "lot resolved")
    eq(#L.awards, 1, "one award for a 1x lot")
    eq(L.awards[1].state, "owed", "winner is owed (non-ML)")
    check(L.awards[1].winner == "Alice" or L.awards[1].winner == "Bob", "winner is one of the rollers")
    eq(owedCount(w), 1, "payout owes exactly one item")
end)

test("top-N: 2x drop, 3 rollers -> 2 distinct owed winners", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40004, 2); bagUpdate(w)
    local lot = openLot(w, 40004)
    eq(lot.count, 2, "lot count 2")
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:RegisterInterest(lot.id, "Bob", "ms")
    w.addon:RegisterInterest(lot.id, "Cara", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    eq(#L.awards, 2, "two awards")
    eq(L.awards[1].state, "owed", "award 1 owed")
    eq(L.awards[2].state, "owed", "award 2 owed")
    local a, b = L.awards[1].winner, L.awards[2].winner
    check(a ~= b, "the two winners are distinct")
    local pool = { Alice = true, Bob = true, Cara = true }
    check(pool[a] and pool[b], "both winners are rollers")
    eq(owedCount(w), 2, "payout owes two items")
end)

test("top-N surplus: 2x drop, 1 roller -> 1 owed + 1 no-winner kept", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40004, 2); bagUpdate(w)
    local lot = openLot(w, 40004)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    eq(#L.awards, 2, "two awards")
    eq(L.awards[1].winner, "Alice", "the sole roller wins one")
    eq(L.awards[1].state, "owed", "that copy is owed")
    eq(L.awards[2].winner, nil, "surplus copy has no winner")
    eq(L.awards[2].state, "resolved", "ML keeps the surplus copy")
    eq(owedCount(w), 1, "payout owes only the won copy")
end)

test("self-win stays resolved, not owed (no payout)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40003, 1); bagUpdate(w)
    local lot = openLot(w, 40003)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Masterlooter", "ms")  -- the ML rolls and is the only roller
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    eq(L.awards[1].winner, "Masterlooter", "ML won")
    eq(L.awards[1].state, "resolved", "self-win is resolved, not owed")
    eq(owedCount(w), 0, "no payout owed for self-win")
end)

test("stale-roll regression: re-drop after resolve is a fresh lot, no bleed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40001, 1); bagUpdate(w)
    local lot1 = openLot(w, 40001)
    w.addon:StartLiveRoll(lot1.id)
    w.addon:RegisterInterest(lot1.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot1.id)
    local first = w.addon.lootCore:Get(lot1.id)
    eq(first.state, "resolved", "first lot resolved")
    local firstWinner = first.awards[1].winner
    -- winner keeps it; a NEW identical copy drops (bag now shows 2 of the item)
    setBag(w, 40001, 2); bagUpdate(w)
    eq(#lotsFor(w, 40001), 2, "a NEW lot is minted, not the resolved one reused")
    local fresh = openLot(w, 40001)
    check(fresh.id ~= lot1.id, "fresh lot has a new id")
    eq(next(fresh.responses), nil, "fresh lot has empty responses (no stale bleed)")
    eq(w.addon.lootCore:Get(lot1.id).awards[1].winner, firstWinner, "original award is untouched")
end)

test("unlock retracts the owe (payout forgive)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    eq(owedCount(w), 1, "owed before unlock")
    w.addon.lootCore:Unlock(lot.id)
    eq(owedCount(w), 0, "unlock forgave the owe")
    eq(w.addon.lootCore:State(lot.id), "idle", "lot back to idle for reroll")
end)

test("reroll: UnlockSessionRoll unlocks one resolved lot and retracts its owe", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    eq(w.addon.lootCore:State(lot.id), "resolved", "lot resolved before reroll")
    eq(owedCount(w), 1, "owed before reroll")
    local ok = w.addon:UnlockSessionRoll(lot.id)
    check(ok, "UnlockSessionRoll returned true")
    eq(w.addon.lootCore:State(lot.id), "idle", "lot back to idle for reroll")
    eq(owedCount(w), 0, "reroll forgave the owe")
end)

test("reroll: UnlockSessionRoll broadcasts a CANCEL for the lot and clears the ML's own roll record", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local cancels = {}
    local origSend = w.addon.SendLargeMessage
    w.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "CANCEL" then cancels[#cancels + 1] = values[1] end
        return origSend(self, command, values, ...)
    end
    w.addon:UnlockSessionRoll(lot.id)
    w.addon.SendLargeMessage = origSend
    eq(#cancels, 1, "exactly one CANCEL broadcast on unlock")
    eq(cancels[1], lot.id, "the CANCEL names the unlocked lot")
    check(not (w.addon.live and w.addon.live.rolls and w.addon.live.rolls[lot.id]),
          "ML's own live roll record cleared on unlock")
end)

test("reroll: Unlock-All broadcasts a CANCEL for every resolved lot", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local a = openLot(w, 40005)
    w.addon:StartLiveRoll(a.id); w.addon:RegisterInterest(a.id, "Alice", "ms"); w.addon:ResolveLiveRoll(a.id)
    setBag(w, 40006, 1); bagUpdate(w)
    local b = openLot(w, 40006)
    w.addon:StartLiveRoll(b.id); w.addon:RegisterInterest(b.id, "Bob", "ms"); w.addon:ResolveLiveRoll(b.id)
    local cancels = {}
    local origSend = w.addon.SendLargeMessage
    w.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "CANCEL" then cancels[#cancels + 1] = values[1] end
        return origSend(self, command, values, ...)
    end
    w.addon:UnlockAllRolls()
    w.addon.SendLargeMessage = origSend
    eq(#cancels, 2, "one CANCEL per resolved lot on Unlock-All")
    local seen = {}; for _, id in ipairs(cancels) do seen[id] = true end
    check(seen[a.id] and seen[b.id], "both unlocked lots were retracted")
    eq(w.addon.lootCore:State(a.id), "idle", "lot A idle after Unlock-All")
    eq(w.addon.lootCore:State(b.id), "idle", "lot B idle after Unlock-All")
end)

-- An LC (loot-council) item resolves to the council, not a roll winner, so the record carries no
-- winners. The banner must show a Loot Council card (matching the Loot Results tab), NOT the "no one
-- rolled" / reroll card, even though people rolled.
test("LC banner: an LC item resolves to a Loot Council card, not 'no one rolled'", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    check(w.addon:SetSessionLCOverride("Blade of Test", "lc"), "LC override set for the item")
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Masterlooter", "bis")   -- ML rolls BiS
    w.addon:RegisterInterest(lot.id, "Alice", "ms")           -- raider (relayed) rolls MS
    local captured, winMode
    local origAdd, origSend = w.addon.AddLootBannerItem, w.addon.SendLargeMessage
    w.addon.AddLootBannerItem = function(self, item) captured = item; return origAdd(self, item) end
    w.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "WIN" then winMode = values[4] end
        return origSend(self, command, values, ...)
    end
    w.addon:ResolveLiveRoll(lot.id)
    w.addon.AddLootBannerItem, w.addon.SendLargeMessage = origAdd, origSend
    check(captured and captured.lootCouncil, "banner item is a Loot Council card")
    check(not (captured and captured.noWinner), "not the no-one-rolled card")
    eq(winMode, "lc", "WIN message carries result mode 'lc'")
end)

-- The candidate list for the LC award flyout: every roller plus any named-rule candidate present in the
-- raid who did not roll (shown with no roll, tagged "Named").
test("LC candidates: rollers plus named-in-raid non-rollers", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:SetSessionLCOverride("Blade of Test", "Zara/lc")   -- names Zara, then loot council
    local sections = { { label = "MS", members = { { name = "Alice", roll = 41 } } } }
    local cands = w.addon:LootCouncilCandidates("Blade of Test", sections)
    local byName = {}
    for _, c in ipairs(cands) do byName[string.lower(c.name)] = c end
    check(byName["alice"] and byName["alice"].roll == 41, "roller Alice present with her roll")
    check(byName["zara"] and byName["zara"].roll == nil and byName["zara"].bracket == "Named",
          "named non-roller Zara present, no roll, tagged Named")
end)

-- Clicking a candidate awards the next copy through the normal win machinery: the copy gets a winner,
-- payout owes it (non-ML), and a normal-mode WIN goes to the raid.
test("LC award: awarding a candidate owes them and broadcasts a normal WIN", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    check(w.addon:SetSessionLCOverride("Blade of Test", "lc"), "LC override set")
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    eq(owedCount(w), 0, "nothing owed before the ML awards")
    local winText, winMode, banner
    local origSend, origBanner = w.addon.SendLargeMessage, w.addon.AddLootBannerItem
    w.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "WIN" then winText, winMode = values[3], values[4] end
        return origSend(self, command, values, ...)
    end
    w.addon.AddLootBannerItem = function(self, item) banner = item; return origBanner(self, item) end
    w.addon:AwardLootCouncilCopy(lot.id, "Alice")
    w.addon.SendLargeMessage, w.addon.AddLootBannerItem = origSend, origBanner
    local award = w.addon.lootCore:Get(lot.id).awards[1]
    eq(award.winner, "Alice", "copy 1 awarded to Alice")
    eq(award.state, "owed", "a non-ML award is OWED")
    eq(owedCount(w), 1, "Alice is now owed the item")
    eq(winMode, "lcwin", "award broadcasts an LC-decision WIN (raid win card)")
    check(winText and string.find(winText, "Alice"), "WIN names the winner")
    -- the collapsed win card shows the winner with an "LC Decision" line, not their roll
    check(banner and banner.winners and banner.winners[1], "a win card was shown for the award")
    eq(banner.winners[1].name, "Alice", "the win card names the awarded winner")
    eq(banner.winners[1].section, "LC Decision", "the winner line reads LC Decision, not a roll bracket")
    check(banner.winners[1].roll == nil, "no roll number is shown for an LC decision")
end)

test("LC award: awarding the ML is a self-win (RESOLVED, nothing owed)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:SetSessionLCOverride("Blade of Test", "lc")
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    w.addon:AwardLootCouncilCopy(lot.id, "Masterlooter")
    local award = w.addon.lootCore:Get(lot.id).awards[1]
    eq(award.winner, "Masterlooter", "copy awarded to the ML")
    eq(award.state, "resolved", "a self-win stays RESOLVED")
    eq(owedCount(w), 0, "a self-win owes nothing")
end)

test("LC award: multi-copy awards one per click, then no free copy remains", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:SetSessionLCOverride("Blade of Test", "lc")
    setBag(w, 40005, 2); bagUpdate(w)   -- two copies
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:RegisterInterest(lot.id, "Bob", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    eq(#w.addon.lootCore:Get(lot.id).awards, 2, "two award copies")
    w.addon:AwardLootCouncilCopy(lot.id, "Alice")
    w.addon:AwardLootCouncilCopy(lot.id, "Bob")
    local awards = w.addon.lootCore:Get(lot.id).awards
    eq(awards[1].winner, "Alice", "copy 1 -> Alice")
    eq(awards[2].winner, "Bob", "copy 2 -> Bob")
    eq(owedCount(w), 2, "both copies owed")
    check(w.addon.lootCore:AwardCopy(lot.id, "Carl") == nil, "no free copy left to award")
end)

test("reroll: UnlockSessionRoll only affects the target lot, not other resolved lots", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local a = openLot(w, 40005)
    w.addon:StartLiveRoll(a.id)
    w.addon:RegisterInterest(a.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(a.id)
    setBag(w, 40006, 1); bagUpdate(w)
    local b = openLot(w, 40006)
    w.addon:StartLiveRoll(b.id)
    w.addon:RegisterInterest(b.id, "Bob", "ms")
    w.addon:ResolveLiveRoll(b.id)
    w.addon:UnlockSessionRoll(a.id)
    eq(w.addon.lootCore:State(a.id), "idle", "rerolled lot is unlocked")
    eq(w.addon.lootCore:State(b.id), "resolved", "untouched lot stays resolved")
end)

test("reroll: UnlockSessionRoll refuses when caller is not the loot master", function()
    local w = makeWorld("Raider", false)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    -- raider can't mint a resolved lot the normal way; stage a fake resolved lot on the core
    local lot = w.addon.lootCore:mint(40005, 1, true)
    lot.state = w.addon.lootCore.STATE.RESOLVED
    lot.awards = { { winner = "Alice", state = "owed" } }
    local ok = w.addon:UnlockSessionRoll(lot.id)
    check(not ok, "UnlockSessionRoll refused for non-LM")
    eq(w.addon.lootCore:State(lot.id), "resolved", "lot state unchanged")
end)

test("LC override: SetSessionLCOverride routes through GetNamedRule and survives until ClearSession", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    -- Set an override BEFORE the item exists. GetNamedRule reads it back, parsed identically to
    -- a persistent named rule (same shape: tiers[].entries[].playerKey).
    local ok = w.addon:SetSessionLCOverride("Sand-Worn Band", "alpha/beta")
    check(ok, "SetSessionLCOverride returned true")
    local rule = w.addon:GetNamedRule("sand-worn band")
    check(rule ~= nil, "GetNamedRule returns the override (case-insensitive)")
    eq(rule and rule.raw, "alpha/beta", "rule.raw mirrors the input prio text")
    eq(rule and rule.tiers and #rule.tiers, 1, "single tier (one '>' segment)")
    eq(rule and rule.tiers[1] and #rule.tiers[1].entries, 2, "tier has two entries (alpha, beta)")
    -- ClearSession nukes the override (session-scoped, not persisted).
    w.addon:ClearSession()
    check(w.addon:GetNamedRule("sand-worn band") == nil, "override wiped by ClearSession")
end)

test("LC override: ClearSessionLCOverride / blank input removes a single item's override", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:SetSessionLCOverride("Gatekeeper", "alpha")
    w.addon:SetSessionLCOverride("Heritage", "beta")
    check(w.addon:GetSessionLCOverride("Gatekeeper") ~= nil, "Gatekeeper override set")
    check(w.addon:GetSessionLCOverride("Heritage") ~= nil, "Heritage override set")
    w.addon:ClearSessionLCOverride("Gatekeeper")
    check(w.addon:GetSessionLCOverride("Gatekeeper") == nil, "Gatekeeper override cleared")
    check(w.addon:GetSessionLCOverride("Heritage") ~= nil, "Heritage override untouched")
end)

test("LC override: empty / unparseable input refuses without disturbing existing override", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:SetSessionLCOverride("Heritage", "alpha")
    -- A whitespace-only priority (after the comma) yields zero tiers; the helper returns false.
    local ok = w.addon:SetSessionLCOverride("Heritage", "   ,  ")
    check(not ok, "unparseable input refused")
    local rule = w.addon:GetNamedRule("Heritage")
    eq(rule and rule.raw, "alpha", "prior override preserved on failed parse")
end)

test("LC override: takes precedence over a persistent named rule for the same item", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    -- Stage a persistent named rule the way Config does (key by NormalizeKey).
    w.addon.config.namedRules = w.addon.config.namedRules or {}
    local key = w.addon.util:NormalizeKey("Plague Igniter")
    w.addon.config.namedRules[key] = {
        itemName = "Plague Igniter", key = key, raw = "persistent",
        tiers = { { index = 1, raw = "persistent", entries = { { raw = "persistent", playerKey = "persistent" } } } },
    }
    eq(w.addon:GetNamedRule("Plague Igniter").raw, "persistent", "baseline: persistent rule is in effect")
    w.addon:SetSessionLCOverride("Plague Igniter", "session-winner")
    eq(w.addon:GetNamedRule("Plague Igniter").raw, "session-winner", "session override wins over persistent rule")
    w.addon:ClearSessionLCOverride("Plague Igniter")
    eq(w.addon:GetNamedRule("Plague Igniter").raw, "persistent", "persistent rule re-emerges after override cleared")
end)

test("reroll: UnlockSessionRoll refuses when the lot is not resolved", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    -- lot is PENDING here (auto-surfaced); a reroll request is a no-op
    local ok = w.addon:UnlockSessionRoll(lot.id)
    check(not ok, "UnlockSessionRoll refused for non-resolved lot")
    eq(w.addon.lootCore:State(lot.id), "pending", "lot state unchanged")
end)

test("delivery records per-copy disposition", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local ok = w.addon.lootCore:MarkDeliveredFor("Alice", 40005, F.CLOCK)
    check(ok, "MarkDeliveredFor succeeded")
    eq(w.addon.lootCore:Get(lot.id).awards[1].state, "delivered", "award marked delivered")
    eq(w.addon.lootCore:Get(lot.id).awards[1].recipient, "Alice", "recipient recorded")
end)

test("owed-to-me queries: a non-ML winner is owed their item until delivery", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)

    eq(w.addon.lootCore:OwedCountFor("Alice"), 1, "Alice is owed one copy")
    eq(w.addon.lootCore:OwedCountFor("Bob"), 0, "a non-winner is owed nothing")
    local items = w.addon.lootCore:OwedItemsFor("Alice")
    eq(#items, 1, "one distinct owed item")
    eq(items[1].itemId, 40005, "the owed itemId is listed")
    eq(items[1].count, 1, "count of one")

    w.addon.lootCore:MarkDeliveredFor("Alice", 40005, F.CLOCK)
    eq(w.addon.lootCore:OwedCountFor("Alice"), 0, "delivery clears the owed count")
end)

test("expired trade window: a re-scan drops a now-untradeable item still sitting in bags", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    eq(w.addon.lootCore:LiveCount(lot.id), 1, "tradeable initially")
    -- the 2h window expires: the item is still in bags but the scan no longer counts it, and NO
    -- bag event fires. The periodic / on-open reconcile must drop it.
    setBag(w, 40005, 0)
    w.addon:ReconcileLootNow()
    eq(w.addon.lootCore:LiveCount(lot.id), 0, "re-scan retired the expired item from the eligible set")
end)

test("Start Roll refuses an item whose every copy's trade window expired (not broadcast)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    setBag(w, 40005, 0)                          -- window expired, no bag event
    w.addon:StartLiveRoll(lot.id)                -- must reconcile + refuse
    check(w.addon.lootCore:State(lot.id) ~= "rolling", "expired item was not put up for roll")
    eq(w.addon.lootCore:LiveCount(lot.id), 0, "expired item retired, not rolled")
end)

test("Start Roll respects per-copy windows: rolls the tradeable copy when a duplicate expired", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 2); bagUpdate(w)            -- two copies, both tradeable
    local lot = openLot(w, 40005)
    eq(lot.count, 2, "lot has both copies")
    setBag(w, 40005, 1)                          -- ONE window expires (no bag event), one still good
    w.addon:StartLiveRoll(lot.id)                -- reconcile shrinks to 1, then rolls it
    eq(w.addon.lootCore:State(lot.id), "rolling", "still rolls: a tradeable copy remains")
    eq(w.addon.lootCore:LiveCount(lot.id), 1, "rolls only the still-tradeable copy")
end)

test("reconcile retire: item leaves bags -> lot retired", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40002, 1); bagUpdate(w)
    local lot = openLot(w, 40002)
    check(w.addon.lootCore:State(lot.id) ~= nil, "lot exists")
    setBag(w, 40002, 0); bagUpdate(w)
    eq(w.addon.lootCore:LiveCount(lot.id), 0, "lot retired when item left bags")
end)

test("itemId identity: two different links, same itemId, collapse to one lot", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    -- two bag entries that resolve to the same itemId via different link strings
    w.addon.BuildTradeableEpicCounts = function()
        return {
            ["|cffa335ee|Hitem:40001:0:0:0|h[Mantle]|h|r"] = 1,
            ["|cffFFFFFF|Hitem:40001:5:0:0|h[Mantle of the Bear]|h|r"] = 1,
        }
    end
    bagUpdate(w)
    eq(#lotsFor(w, 40001), 1, "one lot for the shared itemId")
    eq(openLot(w, 40001).count, 2, "both copies counted into it")
end)

test("comm sync: ML snapshot mirrors onto a raider", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40004, 2); bagUpdate(ml)
    local lot = openLot(ml, 40004)
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:RegisterInterest(lot.id, "Alice", "ms")
    ml.addon:RegisterInterest(lot.id, "Bob", "ms")
    ml.addon:ResolveLiveRoll(lot.id)
    -- force one clean full snapshot (AutoBroadcastSession is debounced on a frozen clock here)
    clearWire()
    ml.addon:BroadcastSession()
    flushWireTo(raider)
    local rl = raider.addon.lootCore:Get(lot.id)
    check(rl ~= nil, "raider mirrored the lot by id")
    eq(rl and rl.itemId, 40004, "raider lot itemId matches")
    eq(rl and rl.state, "resolved", "raider sees it resolved")
    eq(#raider.addon.lootView.results, 1, "raider results projection has the lot")
    local mlRes = ml.addon.lootView.results[1]
    local rRes = raider.addon.lootView.results[1]
    eq(rRes.winnersText, mlRes.winnersText, "raider winners match the ML's")
end)

test("raider pick whispers the ML and is applied", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40005, 1); bagUpdate(ml)
    local lot = openLot(ml, 40005)
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:BroadcastSession()        -- raider first syncs the session (SNAP_BEGIN sets context), as on join
    flushWireTo(raider)                -- raider gets the DROP + delta + full snapshot
    -- raider records a loot-tab response -> routed to ML as a SELECTION whisper
    raider.addon:SetPlayerResponse(lot.id, "Raidertwo", "ms")
    flushWireTo(ml)                     -- ML receives the SELECTION
    local L = ml.addon.lootCore:Get(lot.id)
    check(L.responses["raidertwo"] ~= nil, "ML recorded the raider's pick on the lot")
end)

test("delta sync: a single change sends a LOTD delta, not a full snapshot", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40006, 1); bagUpdate(ml)
    local lot = openLot(ml, 40006)
    ml.addon:BroadcastSession()          -- baseline: full snapshot
    flushWireTo(raider)
    check(raider.addon.lootCore:Get(lot.id) ~= nil, "raider has the lot after baseline snapshot")

    -- a single state change must delta-sync (D), never a full snapshot (SB) burst
    clearWire()
    ml.addon:StartLiveRoll(lot.id)
    local snaps, deltas = 0, 0
    for _, m in ipairs(F.WIRE) do
        local cmd = m.value and m.value[1]
        if cmd == "SNAP" then snaps = snaps + 1 end
        if cmd == "D" then deltas = deltas + 1 end
    end
    eq(snaps, 0, "no full snapshot emitted for a single change")
    check(deltas >= 1, "a delta (D) was sent")

    flushWireTo(raider)
    eq(raider.addon.lootCore:Get(lot.id).state, "rolling", "raider mirrored the delta (now rolling)")
end)

test("delta fuzz: a delta-synced raider always equals the ML across random operations", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    ml.addon:BroadcastSession(); flushWireTo(raider)      -- initial baseline
    local rng = makeRng(20260619)
    local items = { 40001, 40002, 40003, 40004, 40050, 40051 }
    local players = { "Alice", "Bob", "Cara", "Dan", "Eve", "Finn" }
    local tiers = { "bis", "ms", "mu", "os", "tm", "pass" }
    local bag = {}

    local function lotsByState(stateSet)
        local out = {}
        for _, lot in ipairs(ml.addon.lootCore:All()) do
            if stateSet[lot.state] and not lot.removed then out[#out + 1] = lot end
        end
        return out
    end
    local function pick(t) return #t > 0 and t[rng(1, #t)] or nil end

    local mismatch = nil
    for step = 1, 200 do
        local op = rng(1, 100)
        if op <= 32 then                                  -- drop / grow an item
            local id = items[rng(1, #items)]
            bag[id] = (bag[id] or 0) + 1
            setBag(ml, id, bag[id]); bagUpdate(ml)
        elseif op <= 45 then                              -- an item leaves bags (retire)
            local id = items[rng(1, #items)]
            if (bag[id] or 0) > 0 then bag[id] = bag[id] - 1; setBag(ml, id, bag[id]); bagUpdate(ml) end
        elseif op <= 60 then                              -- start a roll on a pending lot
            local lot = pick(lotsByState({ pending = true }))
            if lot then ml.addon:StartLiveRoll(lot.id) end
        elseif op <= 84 then                              -- a player responds on an open lot
            local lot = pick(lotsByState({ rolling = true, pending = true, idle = true, new = true }))
            if lot then ml.addon:SetPlayerResponse(lot.id, players[rng(1, #players)], tiers[rng(1, #tiers)]) end
        elseif op <= 94 then                              -- resolve a rolling lot
            local lot = pick(lotsByState({ rolling = true }))
            if lot then ml.addon:ResolveLiveRoll(lot.id) end
        else                                              -- unlock all resolved lots
            if #ml.addon.lootCore:Resolved() > 0 then ml.addon:UnlockAllRolls() end
        end

        ml.addon:AutoBroadcastSession()                   -- flush coalesced response dirty for the compare
        flushWireTo(raider)                               -- deliver whatever deltas/snapshots resulted
        flushWireTo(ml)                                   -- deliver any raider->ML traffic (resync requests)
        flushWireTo(raider)                               -- and any snapshot that produced
        if syncView(ml) ~= syncView(raider) then
            mismatch = string.format("step %d (op=%d)\n--- ML ---\n%s\n--- raider ---\n%s",
                step, op, syncView(ml), syncView(raider))
            break
        end
    end
    check(mismatch == nil, "raider matched ML at every step" .. (mismatch and ("\n" .. mismatch) or ""))
end)

test("rejoin mid-roll: raider restores the roll popup with the ML's remaining time", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40005, 1); bagUpdate(ml)
    local lot = openLot(ml, 40005)
    ml.addon:StartLiveRoll(lot.id)                 -- ML rolls; deadline = now + 30s (default duration)
    local mlRoll = ml.addon.live.rolls[lot.id]
    check(mlRoll and mlRoll.deadline, "ML recorded a roll deadline")

    F.advanceClock(6)                              -- 6s elapse on the ML's roll (24s left)
    clearWire()
    ml.addon:BroadcastSession()                   -- a freshly-reloaded raider pulls the full snapshot
    flushWireTo(raider)

    local rr = raider.addon.live.rolls[lot.id]
    check(rr ~= nil, "raider restored a roll record for the rolling lot")
    check(raider.addon:HasOpenRollForLot(lot.id), "raider has an open roll popup")
    local remaining = rr and rr.deadline and (rr.deadline - F.CLOCK) or nil
    check(remaining ~= nil and remaining >= 23.5 and remaining <= 24.5,
        "restored countdown reflects the ML's remaining ~24s, not a fresh 30s (got " .. tostring(remaining) .. ")")
end)

-- ---- live pick list (RSTATE): raiders see who is rolling, in real time ----
local function countKeys(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
local function countWire(tag) local n = 0 for _, m in ipairs(F.WIRE) do if m.value and m.value[1] == tag then n = n + 1 end end return n end
local function rollFor(w, lotId) return w.addon.live and w.addon.live.rolls and w.addon.live.rolls[lotId] end

-- shared setup: ML opens a lot, starts a roll, raider receives the DROP -> open roll popup.
local function rollWithRaider(itemId)
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, itemId, 1); bagUpdate(ml)
    local lot = openLot(ml, itemId)
    ml.addon:BroadcastSession(); flushWireTo(raider)   -- raider mirrors the lot
    ml.addon:StartLiveRoll(lot.id); flushWireTo(raider) -- DROP -> raider's interest popup
    return ml, raider, lot
end

-- The Obsidian Greathelm no-winner reproduction: a raider who rolled the first time must be able to
-- roll again on a reroll. Before the CANCEL-on-unlock fix the raider kept a resolved roll record, so
-- the reroll DROP was discarded, the popup never reopened, no response reached the ML, and End
-- resolved with no rollers. The CANCEL clears that record so the fresh DROP opens a new popup.
test("reroll: a raider re-rolls after unlock and the reroll resolves to a winner", function()
    local ml, raider, lot = rollWithRaider(40005)
    check(rollFor(raider, lot.id), "raider has an open roll for the first roll")

    -- first roll: raider picks MS, ML resolves, WIN closes the raider's popup (record stays resolved)
    raider.addon:SetPlayerResponse(lot.id, "Raidertwo", "ms"); flushWireTo(ml)
    ml.addon:ResolveLiveRoll(lot.id); flushWireTo(raider)
    check(rollFor(raider, lot.id) and rollFor(raider, lot.id).resolved, "raider's record is resolved after the win")

    -- reroll: unlock broadcasts CANCEL -> raider drops its stale resolved record
    ml.addon:UnlockSessionRoll(lot.id); flushWireTo(raider)
    check(rollFor(raider, lot.id) == nil, "CANCEL cleared the raider's resolved record")

    -- second DROP opens a fresh popup the raider can act on
    ml.addon:StartLiveRoll(lot.id); flushWireTo(raider)
    local reroll = rollFor(raider, lot.id)
    check(reroll and not reroll.resolved, "raider has a fresh unresolved roll after the reroll DROP")

    -- raider re-picks MS; the response reaches the ML and End resolves to a real winner
    raider.addon:SetPlayerResponse(lot.id, "Raidertwo", "ms"); flushWireTo(ml)
    ml.addon:ResolveLiveRoll(lot.id)
    local award = ml.addon.lootCore:Get(lot.id)
    eq(ml.addon.lootCore:State(lot.id), "resolved", "reroll resolved")
    check(award.awards and award.awards[1] and award.awards[1].winner == "Raidertwo",
          "the reroll recorded Raidertwo as the winner (no more empty no-winner resolve)")
end)

test("LC banner: a raider renders a Loot Council card from a WIN with mode 'lc'", function()
    local ml, raider, lot = rollWithRaider(40005)
    local captured
    local origAdd = raider.addon.AddLootBannerItem
    raider.addon.AddLootBannerItem = function(self, item) captured = item; return origAdd(self, item) end
    -- WIN wire: { lotId, itemId, winnersText (empty for LC), mode, "0", sectionsText }
    raider.addon:OnWinMessage({ lot.id, tostring(40005), "", "lc", "0", "" })
    raider.addon.AddLootBannerItem = origAdd
    check(captured and captured.lootCouncil, "raider shows a Loot Council card for a mode-lc WIN")
    check(not (captured and captured.noWinner), "not a no-winner card")
end)

test("live pick list: a raider sees who is rolling via RSTATE", function()
    local ml, raider, lot = rollWithRaider(40005)
    check(rollFor(raider, lot.id), "raider has an open roll for the lot")

    ml.addon:SetPlayerResponse(lot.id, "Alice", "bis")   -- as relayed SELECTIONs would record
    ml.addon:SetPlayerResponse(lot.id, "Bob", "ms")
    clearWire()
    ml.addon:FlushRollState()                            -- throttled push -> one RSTATE
    flushWireTo(raider)

    local roll = rollFor(raider, lot.id)
    local util = raider.addon.util
    eq(countKeys(roll.registrants), 2, "raider's live roster has both pickers")
    check(roll.registrants[util:NormalizeKey("Alice")] and
          roll.registrants[util:NormalizeKey("Alice")].tier == "bis", "Alice present as BiS")
    check(roll.registrants[util:NormalizeKey("Bob")] and
          roll.registrants[util:NormalizeKey("Bob")].tier == "ms", "Bob present as MS")
end)

test("live pick list: a full-replace push drops a player who passes or leaves", function()
    local ml, raider, lot = rollWithRaider(40005)
    ml.addon:SetPlayerResponse(lot.id, "Alice", "bis")
    ml.addon:SetPlayerResponse(lot.id, "Bob", "ms")
    clearWire(); ml.addon:FlushRollState(); flushWireTo(raider)
    eq(countKeys(rollFor(raider, lot.id).registrants), 2, "both present first")

    ml.addon:SetPlayerResponse(lot.id, "Bob", "pass")    -- Bob backs out
    clearWire(); ml.addon:FlushRollState(); flushWireTo(raider)

    local roll = rollFor(raider, lot.id)
    local util = raider.addon.util
    check(roll.registrants[util:NormalizeKey("Bob")] == nil, "Bob dropped after passing")
    check(roll.registrants[util:NormalizeKey("Alice")] ~= nil, "Alice still present")
end)

test("live pick list: a burst of picks coalesces to one RSTATE per flush", function()
    local ml, raider, lot = rollWithRaider(40005)
    ml.addon:SetPlayerResponse(lot.id, "Alice", "bis")
    ml.addon:SetPlayerResponse(lot.id, "Bob", "ms")
    ml.addon:SetPlayerResponse(lot.id, "Cara", "os")
    clearWire()
    ml.addon:FlushRollState()
    eq(countWire("RSTATE"), 1, "three picks collapse to a single RSTATE on flush")
end)

test("live pick list: RSTATE is display-only and never writes the raider's ledger", function()
    local ml, raider, lot = rollWithRaider(40005)
    local before = countKeys(raider.addon.lootCore:Get(lot.id) and raider.addon.lootCore:Get(lot.id).responses)
    ml.addon:SetPlayerResponse(lot.id, "Alice", "bis")
    clearWire(); ml.addon:FlushRollState(); flushWireTo(raider)

    local lotR = raider.addon.lootCore:Get(lot.id)
    eq(countKeys(lotR and lotR.responses), before, "raider's core lot.responses untouched by RSTATE")
    check(next(rollFor(raider, lot.id).registrants) ~= nil, "but the display roster WAS updated")
end)

test("live pick list: the ML never broadcasts its own raider count (no self-apply)", function()
    local ml, raider, lot = rollWithRaider(40005)
    ml.addon:SetPlayerResponse(lot.id, "Alice", "bis")
    clearWire(); ml.addon:FlushRollState()
    flushWireTo(ml)   -- deliver the wire back to the ML; self-skip must drop its own RSTATE
    -- the ML's roll is owner=true; OnRollStateMessage early-returns on owner rolls regardless
    local mlRoll = rollFor(ml, lot.id)
    check(mlRoll and mlRoll.owner, "ML's roll stays owner-driven, unaffected by RSTATE")
end)

test("roll result tooltip anchor: defaults to the right of the popup; modes map; cursor is nil", function()
    local w = makeWorld("Raidertwo", false)
    w.addon.db.options = {}
    -- default (unset) docks the tooltip's TOPLEFT to the popup's TOPRIGHT == right of the popup
    local p, rp, x = w.addon:RollTooltipAnchorPoints()
    eq(p, "TOPLEFT", "default tooltip corner")
    eq(rp, "TOPRIGHT", "default docks to the popup's RIGHT edge")
    eq(x, 2, "default offset snug to the right")
    local function corner(mode) w.addon.db.options.rollResultTooltipAnchor = mode; return (w.addon:RollTooltipAnchorPoints()) end
    eq(corner("LEFT"), "TOPRIGHT", "LEFT mode: tooltip's TOPRIGHT meets the popup's left edge")
    eq(corner("TOP"), "BOTTOMLEFT", "TOP mode")
    eq(corner("BOTTOM"), "TOPLEFT", "BOTTOM mode")
    eq(corner("CURSOR"), nil, "CURSOR mode returns nil (ANCHOR_CURSOR)")
end)

test("cold cache: the loot list warms uncached item names via the scan-tooltip machinery", function()
    local w = makeWorld("Raidertwo", false)
    -- simulate a cold cache: ItemRender returns nil for this item until it is "warmed"
    local warmed = false
    w.addon.util.ItemRender = function(_, id)
        if id == 49623 and not warmed then return nil end
        return "Shadowmourne", "|cffff8000|Hitem:49623|h[Shadowmourne]|h|r", "Interface\\Icons\\inv_axe"
    end
    local primed = {}
    w.addon.PrimeItemInfo = function(_, id) primed[id] = true end

    local items = { { id = "L:1", itemId = 49623 }, { id = "L:2", itemId = 40005 } }
    local pending = w.addon:WarmLootItemNames(items)
    check(pending, "list flagged pending while the name is uncached")
    check(primed[49623], "the uncached item was primed through PrimeItemInfo (reused machinery)")
    eq(w.addon._lootNamesPending, true, "_lootNamesPending set so the shared ticker re-renders")

    warmed = true                                   -- client cached it
    pending = w.addon:WarmLootItemNames(items)
    check(not pending, "no longer pending once the name resolves")
    eq(w.addon._lootNamesPending, false, "_lootNamesPending cleared -> ticker can stop")
end)

-- Cold-cache on the RESULTS tab. Unlike the Loot tab (which renders from a live projection and
-- re-resolves every draw), a result record is a frozen, persisted snapshot: a lot resolved before
-- its item data arrived bakes the "item:<id>" fallback into itemName/itemLink/detailText. These
-- exercise the heal-in-place path (RehydrateResult) that the UI's RefreshResultsTab drives.
test("results cold cache: ResultRealItemId recovers the real item id (record.itemId is the lot key)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    local record = w.addon.lootCore:Get(lotId).record
    check(string.find(record.itemId, "^L:") ~= nil, "record.itemId is the lot key, not the item id")
    eq(w.addon:ResultRealItemId(record), 40005, "real item id recovered via the lot")
end)

test("results cold cache: a record resolved while cold heals in place once the data arrives", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local warmed = false
    local origRender = w.addon.util.ItemRender
    w.addon.util.ItemRender = function(self, id)
        if id == 40005 and not warmed then return nil, "item:" .. id, "Interface\\Icons\\INV_Misc_QuestionMark" end
        return origRender(self, id)
    end
    local lotId = resolveOwedTo(w, 40005, "Alice")
    local record = w.addon.lootCore:Get(lotId).record
    eq(record.itemName, "item:40005", "name baked to the fallback while cold")
    check(string.find(record.detailText or "", "item:40005", 1, true) ~= nil, "detail text baked the fallback too")

    warmed = true                                   -- client now has the data
    w.addon:RehydrateResult(record)
    eq(record.itemName, "Blade of Test", "itemName healed to the real name")
    check(string.find(record.itemLink, "Blade of Test", 1, true) ~= nil, "itemLink healed to the real link")
    check(string.find(record.detailText, "Blade of Test", 1, true) ~= nil, "detail text rebuilt with the real name")
    check(string.find(record.detailText, "item:40005", 1, true) == nil, "no stale fallback left in the detail text")
end)

test("results cold cache: a still-cold record keeps the fallback and flags the resolve ticker", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local origRender = w.addon.util.ItemRender
    w.addon.util.ItemRender = function(self, id)
        if id == 40005 then return nil, "item:" .. id, "Interface\\Icons\\INV_Misc_QuestionMark" end
        return origRender(self, id)
    end
    local primed = {}
    w.addon.PrimeItemInfo = function(_, id) primed[id] = true end
    local lotId = resolveOwedTo(w, 40005, "Alice")
    local record = w.addon.lootCore:Get(lotId).record
    w.addon._lootNamesPending = false
    w.addon:RehydrateResult(record)
    eq(record.itemName, "item:40005", "still the fallback while the data is cold")
    check(primed[40005], "primed the client for the cold item (reused machinery)")
    eq(w.addon._lootNamesPending, true, "flagged so the shared ticker re-renders the results tab")
end)

test("core persistence: the ledger snapshot carries owing (awards survive a reload)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    resolveOwedTo(w, 40005, "Alice")
    -- the ledgerChanged hook persisted the ledger under session.lootCore
    local snap = w.addon.session.lootCore
    check(snap and snap.lots and #snap.lots >= 1, "ledger persisted to session.lootCore")
    local found = false
    for _, lot in ipairs(snap.lots) do
        for _, a in ipairs(lot.awards or {}) do
            if a.state == "owed" and a.winner and string.find(string.lower(a.winner), "alice") then found = true end
        end
    end
    check(found, "the persisted snapshot carries Alice's OWED award -> owing now survives a reload")
end)

test("payout stays in sync live: an owed copy leaving the bags forgives the owe (awardRemoved)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    resolveOwedTo(w, 40005, "Alice")
    eq(owedCount(w), 1, "owed while held")
    setBag(w, 40005, 0); bagUpdate(w)               -- copy leaves bags, no trade -> core REMOVED -> awardRemoved
    eq(owedCount(w), 0, "payout forgave the owe when the core retired the award (no drift)")
end)

test("payout vs bags: an owe we still hold is kept", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 1, "|cffffffff|Hitem:40005|h[Blade]|h|r")
    eq(owedCount(w), 1, "owed before reconcile")
    eq(w.addon:ReconcilePayoutAgainstBags({ [40005] = 1 }), 0, "held -> nothing forgiven")
    eq(owedCount(w), 1, "the deliverable owe survives")
end)

test("payout vs bags: an owe we no longer hold is forgiven (nothing to owe)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 1, "|cffffffff|Hitem:40005|h[Blade]|h|r")  -- held
    w.addon.payout:Owe("Ghost", 49623, 1, "|cffffffff|Hitem:49623|h[Sand-worn Band]|h|r")  -- not held
    eq(owedCount(w), 2, "two owes")
    eq(w.addon:ReconcilePayoutAgainstBags({ [40005] = 1 }), 1, "only the unheld one is forgiven")
    eq(owedCount(w), 1, "the held owe survives, the phantom is gone")
end)

test("payout vs bags: a stale owe for an unheld item is cleared by the bag scan once settled", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Ghost", 49623, 1, "|cffffffff|Hitem:49623|h[Sand-worn Band]|h|r")  -- no core lot, not in bags
    eq(owedCount(w), 1, "stale owe present")
    w.addon.bagSettleAt = 0          -- bags settled
    w.addon:OnBagUpdate()            -- the scan reconciles owes against (empty) bag truth
    eq(owedCount(w), 0, "the bag scan forgave the unheld owe -- no core history needed")
end)

test("trade-expiry timer arms 5s after the soonest window, clears when nothing is windowed", function()
    local w = makeWorld("Masterlooter", true)
    w.addon:ArmTradeExpiryTimer(120)
    eq(w.addon._tradeExpiryAt, F.CLOCK + 125, "armed for 5s after the 120s window lapses")
    w.addon:ArmTradeExpiryTimer(nil)
    eq(w.addon._tradeExpiryAt, nil, "cleared when no windowed items remain")
end)

test("payout resume defers until bags settle, then reconciles owes before whispering", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Ghost", 49623, 1, "|cffffffff|Hitem:49623|h[Sand-worn Band]|h|r")  -- stale, not held
    -- bags NOT settled yet: a half-loaded bag could look empty, so resume DEFERS (no whisper, no forgive)
    w.addon.bagSettleAt = F.CLOCK + 100
    w.addon:ResumePayoutMode()
    eq(w.addon._payoutResumePending, true, "deferred while bags load")
    eq(owedCount(w), 1, "not forgiven yet -- never act on an unsettled bag")
    -- bags settle: resume reconciles owes against bag truth (forgives the unheld one) THEN whispers
    w.addon.bagSettleAt = F.CLOCK - 1
    w.addon:ResumePayoutMode()
    eq(w.addon._payoutResumePending, false, "no longer pending once settled")
    eq(owedCount(w), 0, "the unheld owe was reconciled away before the login whisper went out")
end)

test("unreadable raid roster detection: flags the would-be ML, not raiders or healthy rosters", function()
    local f = makeWorld("ML", true).addon
    -- broken: master loot, GetLootMethod names us as ML (partyID 0), roster can't name the index
    eq(f:RosterUnreadableForML("master", 0, 2, nil), true, "broken post-relog roster for the ML")
    -- healthy: the ML index resolves to a name
    eq(f:RosterUnreadableForML("master", 0, 2, "Masterlooter"), false, "roster loaded -> not flagged")
    -- a raider (partyID != 0) is never flagged as the would-be ML
    eq(f:RosterUnreadableForML("master", 1, 2, nil), false, "raider in ML's subgroup -> not flagged")
    eq(f:RosterUnreadableForML("master", nil, 2, nil), false, "raider in another subgroup -> not flagged")
    -- not master loot, or no raid ML index
    eq(f:RosterUnreadableForML("group", 0, 0, nil), false, "not master loot -> not flagged")
    eq(f:RosterUnreadableForML("master", 0, nil, nil), false, "no raid ML index -> not flagged")
end)

test("unreadable raid roster: ML is NOT self-granted, recovers when the roster names its index", function()
    -- Captured in-game (ML 'Saelinen' relog): a transient window where loot method is master,
    -- partyMasterIndex == 0 (the API flags US), our raid index exists, but GetRaidRosterInfo cannot
    -- name it yet (a PARTIAL roster load -- other rows named while ours is not). We must NOT self-grant
    -- here: partyMasterIndex == 0 cannot tell the real ML from a relogging ex-ML, and raid-leader/
    -- assistant rank is not a proxy for master-looter (our test ML holds master loot while being
    -- neither). Recovery comes from the roster naming our index, which RAID_ROSTER_UPDATE drives a
    -- moment later -- verified in-game to self-heal within the same login, no /reload.
    local w = makeWorld("Masterlooter", true)
    w.env.GetLootMethod = function() return "master", 0, 1 end   -- master loot, API flags us, our index = 1

    -- Stage 1: roster has not named our index yet -> flagged unreadable, but NOT authorized.
    w.env.GetRaidRosterInfo = function() return nil, nil end
    w.addon:RefreshLootAuthority()
    eq(w.addon.roster.isLootMaster, false, "no self-grant while the roster cannot name the ML index")
    eq(w.addon.roster.mlRosterUnreadable, true, "the unreadable state is detected and flagged")

    -- Stage 2: the roster finishes loading and names our index -> the name-match recovers authority.
    w.env.GetRaidRosterInfo = function(i) if i == 1 then return "Masterlooter", 0 end return "SomeoneElse", 0 end
    w.addon:RefreshLootAuthority()
    eq(w.addon.roster.isLootMaster, true, "name-match recovers authority once the index is named")
    eq(w.addon.roster.mlRosterUnreadable, false, "no longer flagged once recovered")
end)

test("raider requests a sync the moment its loot master resolves (no heartbeat wait)", function()
    -- In-game (raider 'Saeaea' fresh login): the raid roster loads a beat late, so the ML name is
    -- unresolved at login and resolves only when RAID_ROSTER_UPDATE finally lands. Without an explicit
    -- request on that transition, the raider sat idle until the ML's next ~30s heartbeat. Resolving the
    -- ML must pull the session at once, exactly once, and not re-fire on steady re-resolves.
    local w = makeWorld("Raider", false)
    w.env.GetLootMethod = function() return "master", 1, 1 end   -- raider: master loot, ML at raid index 1
    local syncs = 0
    w.addon.RequestSessionSync = function() syncs = syncs + 1 end

    w.env.GetRaidRosterInfo = function() return nil, nil end      -- roster cannot name the index yet
    w.addon:RefreshLootAuthority()
    eq(w.addon.roster.lootMasterName, nil, "ML unresolved while the roster cannot name the index")
    eq(syncs, 0, "no sync request while we cannot name the loot master")

    w.env.GetRaidRosterInfo = function(i) if i == 1 then return "Masterlooter", 2 end return "Raider", 0 end
    w.addon:RefreshLootAuthority()
    eq(w.addon.roster.lootMasterName, "Masterlooter", "ML resolves once the index is named")
    eq(syncs, 1, "resolving the ML fires exactly one sync request")

    w.addon:RefreshLootAuthority()
    eq(syncs, 1, "a steady re-resolve of the same ML does not re-request")
end)

test("slash export commands stay available without loot-master authority", function()
    local w = makeWorld("Raider", false)
    local winners, logs = 0, 0
    w.addon.ExportWinners = function() winners = winners + 1 end
    w.addon.ExportLog = function() logs = logs + 1 end

    w.addon:HandleSlashCommand("winners")
    w.addon:HandleSlashCommand("export winner")
    w.addon:HandleSlashCommand("log")
    w.addon:HandleSlashCommand("export log")

    eq(winners, 2, "winner export aliases dispatch without ML authority")
    eq(logs, 2, "log export aliases dispatch without ML authority")
end)

-- Equip-eligibility self-block (item 11). Test player is a Warrior (UnitClass -> WARRIOR), so:
-- a wand is unusable -> "class"; plate is usable -> nil; cloth is usable too (a plate class can wear
-- every lighter armor, option a) -> nil. Class/weapon sets are validated against SkillRaceClassInfo.dbc.
test("roll self-block: class cannot equip the item", function()
    local w = makeWorld("Warrior", true)
    local function setItem(class, sub, equipLoc)
        w.env.GetItemInfo = function(idOrLink)
            local id = tonumber(idOrLink) or tonumber(string.match(tostring(idOrLink), "item:(%d+)")) or 0
            return "TestItem", "|cffa335ee|Hitem:" .. id .. "|h[TestItem]|h|r", 4, 200, 80, class, sub, 1, equipLoc, "tex", 0
        end
    end

    setItem("Weapon", "Wands", "INVTYPE_RANGED")
    eq(w.addon:RollSelfBlockReason(98001), "class", "warrior is blocked from a wand")

    setItem("Weapon", "Staves", "INVTYPE_2HWEAPON")
    eq(w.addon:RollSelfBlockReason(98002), nil, "warrior can use staves (DBC-confirmed), not blocked")

    setItem("Armor", "Plate", "INVTYPE_CHEST")
    eq(w.addon:RollSelfBlockReason(98003), nil, "warrior is not blocked from plate")

    setItem("Armor", "Cloth", "INVTYPE_CHEST")
    eq(w.addon:RollSelfBlockReason(98004), nil, "warrior can wear lower armor (cloth), not blocked")

    -- Non-gear (a Miscellaneous container like Large Satchel of Spoils) has no class gate.
    setItem("Miscellaneous", "Junk", "")
    eq(w.addon:RollSelfBlockReason(98005), nil, "a satchel/container is never class-blocked")

    -- Tier set tokens are class-restricted by item id. Warrior is Protector; a Vanquisher token is
    -- not for them, a Protector token is. (Ids from item_template; id-based so GetItemInfo is moot.)
    eq(w.addon:RollSelfBlockReason(40612), "class", "warrior blocked from a Vanquisher token (Lost Vanquisher)")
    eq(w.addon:RollSelfBlockReason(31091), nil, "warrior can use a Protector token (Forgotten Protector)")
    eq(w.addon:RollSelfBlockReason(29754), "class", "warrior blocked from a TBC Champion token")
    eq(w.addon:RollSelfBlockReason(29753), nil, "warrior can use a TBC Defender token")
end)

-- Token roll-eligibility now comes from the item-id table (IsClassAllowedForItem), keyed by itemId,
-- not the per-name ItemInfo note. (40612 = Lost Vanquisher = Rogue/DK/Mage/Druid; 40611 = Protector.)
test("token allowed-class gate is driven by the tier-token id table", function()
    local a = makeWorld("ML", true).addon
    eq(a:IsClassAllowedForItem(40612, "ignored", "warrior"), false, "warrior not allowed on a Vanquisher token")
    eq(a:IsClassAllowedForItem(40612, "ignored", "rogue"), true, "rogue allowed on a Vanquisher token")
    eq(a:IsClassAllowedForItem(40612, "ignored", "death knight"), true, "DK allowed on a Vanquisher token")
    eq(a:IsClassAllowedForItem(40611, "ignored", "warrior"), true, "warrior allowed on a Protector token")
    -- a non-token item with no note is unrestricted
    eq(a:IsClassAllowedForItem(99999, "Some Sword", "warrior"), true, "non-token without a note is unrestricted")
end)

-- Opt-in "hide rolls my class can't use" (item 11 follow-up). Non-ML Warrior. Off by default; when on,
-- it suppresses only CLASS-unusable items (a wand) -- NOT items unusable for other reasons.
test("hide-unusable-rolls option suppresses class-unusable popups for non-ML only", function()
    local w = makeWorld("Raider", false)   -- not ML; UnitClass -> WARRIOR
    w.addon.db.options = w.addon.db.options or {}
    local function wand() w.env.GetItemInfo = function(idOrLink)
        local id = tonumber(idOrLink) or tonumber(string.match(tostring(idOrLink),"item:(%d+)")) or 0
        return "Wand","|cffa335ee|Hitem:"..id.."|h[Wand]|h|r",4,200,80,"Weapon","Wands",1,"INVTYPE_RANGED","tex",0 end end
    wand()

    eq(w.addon:ShouldSuppressRollPopup({ itemId = 97001, name = "Wand" }), false, "off by default: wand roll still shown")

    w.addon.db.options.hideUnusableRolls = true
    eq(w.addon:ShouldSuppressRollPopup({ itemId = 97001, name = "Wand" }), true, "wand roll hidden for warrior when option on")

    -- a usable weapon (sword) is never hidden
    w.env.GetItemInfo = function(idOrLink)
        local id = tonumber(idOrLink) or tonumber(string.match(tostring(idOrLink),"item:(%d+)")) or 0
        return "Sword","|cffa335ee|Hitem:"..id.."|h[Sword]|h|r",4,200,80,"Weapon","One-Handed Swords",1,"INVTYPE_WEAPONMAINHAND","tex",0 end
    eq(w.addon:ShouldSuppressRollPopup({ itemId = 97002, name = "Sword" }), false, "usable sword roll still shown")

    -- the ML never has popups suppressed
    local ml = makeWorld("Masterlooter", true)
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.hideUnusableRolls = true
    ml.env.GetItemInfo = function() return "Wand","|cffa335ee|Hitem:97001|h[Wand]|h|r",4,200,80,"Weapon","Wands",1,"INVTYPE_RANGED","tex",0 end
    eq(ml.addon:ShouldSuppressRollPopup({ itemId = 97001, name = "Wand" }), false, "ML never has popups suppressed")
end)

test("roll resolution shows the raider the win banner and closes the interest popup", function()
    local ml, raider, lot = rollWithRaider(40005)
    local roll = rollFor(raider, lot.id)
    check(roll and roll.popup and roll.popup.mode == "interest", "raider has an open interest popup")
    ml.addon:SetPlayerResponse(lot.id, "Raidertwo", "ms")   -- a roller, so the resolve yields a winner
    ml.addon:ResolveLiveRoll(lot.id)
    flushWireTo(raider)   -- delivers the RESOLVED sync delta (enqueued first) AND the WIN: the race
    local hasResult, hasInterest = false, false
    for _, f in ipairs(raider.addon.live.active) do
        if f.mode == "result" then hasResult = true end
        if f.mode == "interest" then hasInterest = true end
    end
    check(not hasInterest, "the interest popup was closed on resolve, not left or vanished")
    check(not hasResult, "no result popup: the loot banner replaces it")
    eq(#raider.addon._bannerItems, 1, "raider got exactly one loot-banner item for the win")
    check(raider.addon._bannerItems[1].winner ~= nil, "the banner item names the winner")
end)

test("BannerItemFromResult: the win banner item carries winner, reason, and the full roll list", function()
    local ml, raider, lot = rollWithRaider(40005)
    ml.addon:SetPlayerResponse(lot.id, "Alice", "bis")   -- BiS beats MS
    ml.addon:SetPlayerResponse(lot.id, "Bob", "ms")
    ml.addon:ResolveLiveRoll(lot.id)
    eq(#ml.addon._bannerItems, 1, "one banner item for the resolved roll")
    local item = ml.addon._bannerItems[1]
    check(item.winner ~= nil, "the banner item names the winner")
    check(item.why and item.why ~= "", "carries the winning reason (roll/bracket)")
    eq(item.rolls and #item.rolls, 2, "lists every roller (Alice + Bob), pass excluded")
    check(item.winners and #item.winners >= 1, "winners list is populated")
    eq(item.winners[1].name, item.winner, "winners[1] matches the headline winner")
end)

test("BannerItemFromResult: a multi-copy item lists every winner, bracket-sorted", function()
    local ml = makeWorld("Masterlooter", true)
    local roll = { id = "lot1", link = "[Token]", icon = "icon", quantity = 2 }
    -- Two copies, awarded to a BiS roller then an MS roller; sections come pre-grouped by bracket.
    local winners = { "Alice", "Bob" }
    local sections = {
        { label = "BiS", members = { { name = "Alice", roll = 80 } } },
        { label = "MS",  members = { { name = "Bob",   roll = 95 } } },
    }
    local item = ml.addon:BannerItemFromResult(roll, winners, sections)
    eq(#item.winners, 2, "one winner entry per copy")
    eq(item.winners[1].name, "Alice", "first winner is the BiS roller")
    eq(item.winners[1].section, "BiS", "first winner's bracket")
    eq(item.winners[2].name, "Bob", "second winner is the MS roller")
    eq(item.winners[2].section, "MS", "second winner's bracket")
    eq(item.rolls[1].name, "Alice", "rolls are bracket-sorted: BiS first")
    eq(item.rolls[2].name, "Bob", "then MS")
end)

test("ML cancel closes the raider's roll popup (the only sync-driven close)", function()
    local ml, raider, lot = rollWithRaider(40005)
    check(rollFor(raider, lot.id), "raider has a roll")
    ml.addon:CancelLiveRoll(lot.id)
    flushWireTo(raider)
    check(not rollFor(raider, lot.id), "raider's roll cleared on cancel")
    local hasInterest = false
    for _, f in ipairs(raider.addon.live.active) do if f.mode == "interest" then hasInterest = true end end
    check(not hasInterest, "no interest popup remains after cancel")
end)

-- item 10: a second click on the already-selected bracket dismisses a raider's popup (any bracket,
-- not just Pass). Real brackets keep the interest they sent; Pass clears its choice.
test("two-click dismiss: a second click on the selected bracket hides a raider's popup", function()
    local ml, raider, lot = rollWithRaider(40005)
    raider.addon.IsPlayerAllowedForItem = function() return true end
    local roll = rollFor(raider, lot.id)
    check(roll and roll.popup, "raider has an open interest popup")

    raider.addon:ChooseInterest(roll, "ms")             -- first click selects MS
    check(roll.popup, "one click keeps the popup open")
    eq(roll.choice, "ms", "MS is selected")

    raider.addon:ChooseInterest(roll, "ms")             -- second click on the same bracket dismisses
    check(not roll.popup, "second click on the selected bracket closes the popup")
    eq(roll.choice, "ms", "a real bracket keeps its interest when dismissed (only Pass clears)")
end)

test("two-click dismiss: switching to a different bracket does not close the popup", function()
    local ml, raider, lot = rollWithRaider(40005)
    raider.addon.IsPlayerAllowedForItem = function() return true end
    local roll = rollFor(raider, lot.id)
    raider.addon:ChooseInterest(roll, "ms")             -- select MS
    raider.addon:ChooseInterest(roll, "os")             -- switch to OS (different bracket)
    check(roll.popup, "switching brackets keeps the popup open")
    eq(roll.choice, "os", "selection moved to OS")
end)

test("two-click dismiss: the ML's own popup never closes on a repeat click", function()
    local ml, raider, lot = rollWithRaider(40005)
    ml.addon.IsPlayerAllowedForItem = function() return true end
    local mlRoll = rollFor(ml, lot.id)
    check(mlRoll and mlRoll.popup and mlRoll.owner, "ML owns an interest popup")
    ml.addon:ChooseInterest(mlRoll, "ms")
    ml.addon:ChooseInterest(mlRoll, "ms")
    check(mlRoll.popup, "ML popup stays open: it drives the roll")
end)

-- The win banner shows raid-wide by default: a passer learns the winner via the banner even after
-- dismissing their popup, unless they opt into hideUnrolledWins (tested below).
test("a passing raider still gets the win banner by default (hideUnrolledWins off)", function()
    local ml, raider, lot = rollWithRaider(40005)
    local roll = rollFor(raider, lot.id)
    raider.addon:ChooseInterest(roll, "pass")
    raider.addon:ChooseInterest(roll, "pass")           -- two-click dismiss
    check(not roll.popup, "raider dismissed the popup")
    ml.addon:SetPlayerResponse(lot.id, "Alice", "ms")   -- another roller wins, so there is a banner
    ml.addon:ResolveLiveRoll(lot.id); flushWireTo(raider)
    local hasResult = false
    for _, f in ipairs(raider.addon.live.active) do if f.mode == "result" then hasResult = true end end
    check(not hasResult, "no result popup is created (the banner replaced it)")
    eq(#raider.addon._bannerItems, 1, "the win banner shows for a passer with the option off")
end)

test("hideUnrolledWins on: a passer's win banner is suppressed", function()
    local ml, raider, lot = rollWithRaider(40006)
    raider.addon.db.options.hideUnrolledWins = true
    local roll = rollFor(raider, lot.id)
    raider.addon:ChooseInterest(roll, "pass")
    check(roll.passed, "the roll records the local pass")
    ml.addon:SetPlayerResponse(lot.id, "Alice", "ms")   -- Alice wins
    ml.addon:ResolveLiveRoll(lot.id); flushWireTo(raider)
    eq(#raider.addon._bannerItems, 0, "the passer sees no win banner with the option on")
end)

test("hideUnrolledWins on: a non-passer still sees the win banner", function()
    local ml, raider, lot = rollWithRaider(40006)
    raider.addon.db.options.hideUnrolledWins = true
    raider.addon.IsPlayerAllowedForItem = function() return true end
    local roll = rollFor(raider, lot.id)
    raider.addon:ChooseInterest(roll, "ms")             -- rolled, did not pass
    check(not roll.passed, "a real bracket clears the pass flag")
    ml.addon:SetPlayerResponse(lot.id, "Alice", "bis")  -- Alice wins over the raider's MS
    ml.addon:ResolveLiveRoll(lot.id); flushWireTo(raider)
    eq(#raider.addon._bannerItems, 1, "the option only suppresses items you actually passed on")
end)

test("hideUnrolledWins on: leaving the default Pass (no action) is suppressed too", function()
    local ml, raider, lot = rollWithRaider(40006)
    raider.addon.db.options.hideUnrolledWins = true
    local roll = rollFor(raider, lot.id)
    check(roll.passed, "the roll seeds passed=true from the default Pass response (no action taken)")
    ml.addon:SetPlayerResponse(lot.id, "Alice", "ms")   -- Alice wins
    ml.addon:ResolveLiveRoll(lot.id); flushWireTo(raider)
    eq(#raider.addon._bannerItems, 0, "you only see banners for loot you actually rolled on")
end)

test("no-winner resolve: the ML gets a 'no one rolled' card with a working reroll", function()
    local ml, raider, lot = rollWithRaider(40005)
    ml.addon:ResolveLiveRoll(lot.id)   -- nobody rolled (all default pass) -> no winner
    eq(#ml.addon._bannerItems, 1, "the ML still gets a win card for a no-winner roll")
    local item = ml.addon._bannerItems[1]
    check(item.noWinner, "the card is flagged no-winner")
    check(type(item.onReroll) == "function", "and carries a reroll callback")
    local core = ml.addon.lootCore
    check(core:IsResolved(lot.id), "the lot is resolved after the empty roll")
    item.onReroll()
    check(not core:IsResolved(lot.id), "reroll unlocked the lot")
    check(ml.addon.live.rolls[lot.id] ~= nil, "a fresh roll is live after reroll")
end)

test("hideUnrolledWins on: a filtered-out (blacklisted) item's win is suppressed even if not passed", function()
    local ml, raider, lot = rollWithRaider(40005)   -- "Blade of Test"
    raider.addon.db.options.hideUnrolledWins = true
    raider.addon.db.options.blacklistEnabled = true
    raider.addon:SetItemFilterText("blacklist", "Blade of Test")
    local roll = rollFor(raider, lot.id)
    roll.passed = false   -- isolate the filter path: prove the blacklist alone suppresses the win
    ml.addon:SetPlayerResponse(lot.id, "Alice", "ms")   -- Alice wins
    ml.addon:ResolveLiveRoll(lot.id); flushWireTo(raider)
    eq(#raider.addon._bannerItems, 0, "a filtered item's win is hidden regardless of pass state")
end)

-- ---------------------------------------------------------------------------
-- banner roll cards: the live wiring. The banner is the default surface in-game; the harness stub
-- refuses cards by default (popup battery above tests the fallback path), so these opt in.
-- ---------------------------------------------------------------------------
local function bannerRollWithRaider(itemId)
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    ml.addon._rollBannerAccept = true
    raider.addon._rollBannerAccept = true
    startSession(ml)
    setBag(ml, itemId, 1); bagUpdate(ml)
    local lot = openLot(ml, itemId)
    ml.addon:BroadcastSession(); flushWireTo(raider)
    ml.addon:StartLiveRoll(lot.id); flushWireTo(raider)
    return ml, raider, lot
end
local function cardFor(w, lotId)
    for _, it in ipairs(w.addon._rollBannerItems) do
        if it.key == lotId then return it end
    end
end

test("banner mode: a roll shows as a card on both sides, no interest popup", function()
    local ml, raider, lot = bannerRollWithRaider(40005)
    local mlCard, raiderCard = cardFor(ml, lot.id), cardFor(raider, lot.id)
    check(mlCard, "the ML got a roll card")
    check(raiderCard, "the raider got a roll card")
    for _, w in ipairs({ ml, raider }) do
        for _, f in ipairs(w.addon.live.active) do
            check(f.mode ~= "interest", "no interest popup alongside the card")
            check(f.mode ~= "pending", "the ML's pending popup was closed when the card took over")
        end
    end
    check(mlCard.onMLEnd and mlCard.onMLCancel and mlCard.onExpired, "the ML card carries the ML controls")
    check(not (raiderCard.onMLEnd or raiderCard.onMLCancel or raiderCard.onExpired), "the raider card does not")
    check(mlCard.isOwner, "the ML card is flagged owner (repeat click must not dismiss it)")
    check(not raiderCard.isOwner, "the raider card is not")
    check(type(mlCard.getTimeLeft) == "function", "card asks the roll for time, it owns no clock")
    local left = mlCard.getTimeLeft()
    check(mlCard.rollDuration and left > 0 and left <= mlCard.rollDuration, "honest countdown from the deadline")
    check(type(raiderCard.getRollers) == "function", "card exposes the roller thunk")
end)

test("banner mode: a card pick routes through ChooseInterest to the ML", function()
    local ml, raider, lot = bannerRollWithRaider(40005)
    cardFor(raider, lot.id).onPick("MS")
    flushWireTo(ml)
    local found
    for _, e in ipairs(ml.addon:ActiveRollers(lot.id)) do
        if e.name == "Raidertwo" and e.tier == "ms" then found = true end
    end
    check(found, "the ML registered the raider's MS pick")
    eq(rollFor(raider, lot.id).choice, "ms", "raider's local choice tracks the pick")
    local synced = raider.addon._rollBannerChoices[#raider.addon._rollBannerChoices]
    check(synced and synced.key == lot.id and synced.bracket == "MS", "the card highlight was synced back")
end)

test("banner mode: card pass records the pass and a dismiss clears the choice", function()
    local ml, raider, lot = bannerRollWithRaider(40005)
    local card = cardFor(raider, lot.id)
    card.onPick("Pass")
    local roll = rollFor(raider, lot.id)
    check(roll.passed, "the pass is recorded for hideUnrolledWins")
    card.onChosen("Pass")   -- repeat click: the card dismissed itself
    eq(roll.choice, nil, "a pass dismiss clears the choice (it carries no interest)")
end)

test("banner mode: ML End resolves the roll and closes cards everywhere", function()
    local ml, raider, lot = bannerRollWithRaider(40005)
    cardFor(raider, lot.id).onPick("MS")
    flushWireTo(ml)
    cardFor(ml, lot.id).onMLEnd()
    flushWireTo(raider)
    eq(#raider.addon._bannerItems, 1, "the raider got the win banner")
    local closed
    for _, k in ipairs(raider.addon._rollBannerClosed) do if k == lot.id then closed = true end end
    check(closed, "the raider's roll card was closed by the WIN")
    closed = nil
    for _, k in ipairs(ml.addon._rollBannerClosed) do if k == lot.id then closed = true end end
    check(closed, "the ML's roll card was closed by the resolve")
end)

test("banner mode: ML Cancel closes cards and returns the lot to pending", function()
    local ml, raider, lot = bannerRollWithRaider(40005)
    cardFor(ml, lot.id).onMLCancel()
    flushWireTo(raider)
    local core = ml.addon.lootCore
    eq(core:Get(lot.id).state, core.STATE.PENDING, "lot went back to pending")
    local closed
    for _, k in ipairs(raider.addon._rollBannerClosed) do if k == lot.id then closed = true end end
    check(closed, "the raider's card was closed by the CANCEL")
end)

test("banner mode: onExpired auto-resolves for the ML like the popup deadline did", function()
    local ml, raider, lot = bannerRollWithRaider(40005)
    ml.addon:SetPlayerResponse(lot.id, "Alice", "ms")   -- a roller, so the resolve yields a winner
    cardFor(ml, lot.id).onExpired()
    flushWireTo(raider)
    eq(#raider.addon._bannerItems, 1, "expiry resolved the roll and the win reached the raider")
end)

test("banner mode: a prefired pick opens the ML's card preselected", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    ml.addon._rollBannerAccept = true
    startSession(ml)
    setBag(ml, 40005, 1); bagUpdate(ml)
    local lot = openLot(ml, 40005)
    ml.addon:SetPlayerResponse(lot.id, "Masterlooter", "bis")   -- loot-tab pick before the roll
    ml.addon:StartLiveRoll(lot.id)
    eq(cardFor(ml, lot.id).selected, "BiS", "the card opened with the prior pick highlighted")
end)

test("banner mode: a refused card falls back to the interest popup", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    ml.addon._rollBannerAccept = false   -- defensive banner refusal (also the harness default)
    startSession(ml)
    setBag(ml, 40005, 1); bagUpdate(ml)
    local lot = openLot(ml, 40005)
    ml.addon:StartLiveRoll(lot.id)
    eq(#ml.addon._rollBannerItems, 0, "no card was shown")
    local hasInterest
    for _, f in ipairs(ml.addon.live.active) do
        if f.mode == "interest" then hasInterest = true end
    end
    check(hasInterest, "the roll fell back to the popup instead of being lost")
end)

test("banner mode: cold item cache still yields a card with a fallback name", function()
    local ml = (function()
        clearWire()
        return makeWorld("Masterlooter", true)
    end)()
    local raider = makeWorld("Raidertwo", false)
    ml.addon._rollBannerAccept = true
    raider.addon._rollBannerAccept = true
    startSession(ml)
    setBag(ml, 40005, 1); bagUpdate(ml)
    local lot = openLot(ml, 40005)
    ml.addon:BroadcastSession(); flushWireTo(raider)
    ml.addon:StartLiveRoll(lot.id)
    local realGetItemInfo = raider.env.GetItemInfo
    raider.env.GetItemInfo = function() return nil end   -- raider has never seen the item
    flushWireTo(raider)
    local card = cardFor(raider, lot.id)
    check(card, "the raider still got a card")
    eq(card.link, "item:40005", "bare item:id stands in for the missing link")
    check(card.fallbackName ~= nil and card.fallbackName ~= "", "a fallback name rides along")

    -- the cache resolves (server answered the prime): the ticker re-renders the card in place
    raider.env.GetItemInfo = realGetItemInfo
    pump(raider, 0.3)
    local refresh = raider.addon._rollBannerRefreshes[#raider.addon._rollBannerRefreshes]
    check(refresh and refresh.key == lot.id, "the card was refreshed once the item resolved")
    check(refresh.link and refresh.link ~= "item:40005", "the refresh carries the real link")
end)

test("ineligible class: roll brackets are DISABLED (not just message-guarded)", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    raider.addon.IsPlayerAllowedForItem = function() return false end   -- class can't use this item
    startSession(ml)
    setBag(ml, 40004, 1); bagUpdate(ml)
    local lot = openLot(ml, 40004)
    ml.addon:StartLiveRoll(lot.id)
    flushWireTo(raider)                       -- DROP -> ShowInterestPopup -> applyInterestButtonAvailability
    local roll = raider.addon.live.rolls[lot.id]
    local f = roll and roll.popup
    check(f, "raider built an interest popup")
    check(not f.bisBtn:IsEnabled(), "BiS button disabled for an item the class cannot use")
    check(not f.msBtn:IsEnabled(),  "MS button disabled")
    check(not f.tmBtn:IsEnabled(),  "TM button disabled")
    check(f.passBtn:IsEnabled(),    "Pass remains enabled (anyone may pass)")
end)

test("eligible class: roll brackets stay enabled", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    raider.addon.IsPlayerAllowedForItem = function() return true end
    ml.addon.GetLiveItemPrio = function() return "Warrior Fury" end   -- ML broadcasts a listed prio
    startSession(ml)
    setBag(ml, 40004, 1); bagUpdate(ml)
    local lot = openLot(ml, 40004)
    ml.addon:StartLiveRoll(lot.id)
    flushWireTo(raider)
    local f = raider.addon.live.rolls[lot.id].popup
    check(f.bisBtn:IsEnabled() and f.msBtn:IsEnabled(), "brackets enabled for an item the class can use")
end)

test("ML authority: popup BiS follows the synced prio, not the raider's local list", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    raider.addon.IsPlayerAllowedForItem = function() return true end
    raider.addon.ItemHasPriority = function() return true end           -- raider's local list says "has prio"...
    ml.addon.GetLiveItemPrio = function() return "MS > MU > OS > TM" end -- ...but the ML broadcasts no-prio
    startSession(ml)
    setBag(ml, 40004, 1); bagUpdate(ml)
    local lot = openLot(ml, 40004)
    ml.addon:StartLiveRoll(lot.id)
    flushWireTo(raider)
    local f = raider.addon.live.rolls[lot.id].popup
    check(not f.bisBtn:IsEnabled(), "BiS disabled: the ML's no-prio broadcast wins over the raider's local list")
    check(f.msBtn:IsEnabled(), "MS stays available")
end)

test("a raider requesting sync from a session-less ML gets no phantom session", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)        -- authorized ML, but no session started
    local raider = makeWorld("Raidertwo", false)
    raider.addon:RequestSessionSync()                 -- raider asks
    flushWireTo(ml)                                    -- ML answers with an empty snapshot (epoch "")
    flushWireTo(raider)                                -- raider applies it
    eq(raider.addon.session.active, false, "raider stays session-less (empty epoch -> not active)")
    eq(#raider.addon.lootCore:All(), 0, "no lots fabricated")
end)

test("delta sync: a dropped delta is detected via rev gap and auto-resynced", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40001, 1); bagUpdate(ml)
    local lot = openLot(ml, 40001)
    ml.addon:BroadcastSession(); flushWireTo(raider)      -- baseline; raider lastRev set
    eq(syncView(raider), syncView(ml), "synced at baseline")

    ml.addon:StartLiveRoll(lot.id)
    clearWire()                                           -- DROP this delta (simulate a lost LOTD)
    ml.addon:SetPlayerResponse(lot.id, "Alice", "ms")     -- recorded locally (coalesced, not broadcast)
    ml.addon:ResolveLiveRoll(lot.id)                      -- a state change -> a delta with a rev gap
    flushWireTo(raider)                                   -- raider sees the gap, requests a full resync
    check(raider.addon.syncChannel.pendingRequest ~= nil, "raider flagged a resync after the gap")
    flushWireTo(ml)                                       -- ML answers the sync request with a targeted snapshot
    flushWireTo(raider)                                   -- raider applies it
    eq(syncView(raider), syncView(ml), "raider converged to ML truth after gap + resync")
end)

test("resync retry defers (no nil-target whisper) while the loot master is unresolved, resumes when it returns", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    ml.addon:BroadcastSession(); flushWireTo(raider)      -- baseline -> raider has lastRev + appliedEpoch
    local ch = raider.addon.syncChannel

    ch:RequestSync()                                      -- raider has an in-flight resync request
    check(ch.pendingRequest ~= nil, "raider has a pending resync request")

    -- The loot master goes offline / the raider leaves the raid: authorityName() no longer resolves.
    -- Before the fix, Tick whispered this nil target and the client threw
    -- "SendAddonMessage(): Whisper message missing target player!". Now it skips the send but HOLDS the
    -- request (still under maxAttempts), so a transient outage doesn't drop the resync.
    raider.addon.roster.lootMasterName = nil
    clearWire()
    ch:Tick(F.CLOCK + 1000)
    ch:Tick(F.CLOCK + 2000)
    for _, m in ipairs(F.WIRE) do
        check(not (m.dist == "WHISPER" and m.target == nil), "no whisper queued with a nil target")
    end
    check(ch.pendingRequest ~= nil, "request held (deferring) while no authority resolves")

    -- The ML returns: the very next retry resolves a target and whispers it (resume + retarget for free,
    -- no dependency on a heartbeat). The target is read fresh each tick, never cached on the request.
    raider.addon.roster.lootMasterName = "Masterlooter"
    clearWire()
    ch:Tick(F.CLOCK + 3000)
    local whispered = false
    for _, m in ipairs(F.WIRE) do
        if m.dist == "WHISPER" and m.target == "Masterlooter" then whispered = true end
    end
    check(whispered, "retry resumes whispering the loot master once it resolves again")
end)

test("resync retry gives up on a bounded horizon when no authority ever resolves (no infinite poll)", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    ml.addon:BroadcastSession(); flushWireTo(raider)
    local ch = raider.addon.syncChannel

    ch:RequestSync()
    raider.addon.roster.lootMasterName = nil              -- authority never comes back
    clearWire()
    -- Drive many retries; each deferred tick still counts against maxAttempts, so it must stop.
    for i = 1, 20 do
        if not ch.pendingRequest then break end
        ch:Tick(F.CLOCK + i * 1000)
    end
    eq(ch.pendingRequest, nil, "deferred retries are bounded by maxAttempts, not an infinite poll")
    for _, m in ipairs(F.WIRE) do
        check(not (m.dist == "WHISPER" and m.target == nil), "never whispered a nil target while deferring")
    end

    -- Bounded give-up is not terminal: a heartbeat from the returned ML re-arms the resync.
    raider.addon.roster.lootMasterName = "Masterlooter"
    ch:OnReceive("Masterlooter", { "H", ml.addon:GetCurrentSession().id, tostring((ch.lastRev or 0) + 5) })
    check(ch.pendingRequest ~= nil, "a heartbeat re-arms the resync after a bounded give-up")
end)

test("resync retry still fires normally while the loot master is present", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    ml.addon:BroadcastSession(); flushWireTo(raider)
    local ch = raider.addon.syncChannel

    ch:RequestSync()
    local firstAttempts = ch.pendingRequest.attempts
    clearWire()
    ch:Tick(F.CLOCK + 1000)                                 -- ML still in the raid: retry must proceed

    eq(ch.pendingRequest ~= nil, true, "request stays in flight while the authority is present")
    check(ch.pendingRequest.attempts > firstAttempts, "retry counted (resend happened, not a give-up)")
    local whispered = false
    for _, m in ipairs(F.WIRE) do
        if m.dist == "WHISPER" and m.target == "Masterlooter" then whispered = true end
    end
    check(whispered, "retry whispered the resolved loot master")
end)

-- ===========================================================================
-- TRADE ENGINE (drives the real TradeDeliver fill/complete machinery)
-- ===========================================================================

test("trade engine: owed player trades -> item delivered, disposition recorded", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    eq(owedCount(w), 1, "Alice owed 1")
    putBag(w, 0, 1, 40005, 1)                  -- the won item sits in the ML's bags
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 0, "owe cleared after the trade completes")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "delivered", "award delivered through the engine")
    eq(w.addon.lootCore:Get(lotId).awards[1].recipient, "Alice", "recipient recorded")
end)

test("manual hand-trade of an owed item records the delivery (not just auto-fill)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")     -- Alice owed 1x 40005 from a resolved roll
    eq(owedCount(w), 1, "owed before the hand-trade")
    runManualTrade(w, "Alice", 40005, 1)               -- ML drags the item in by hand (no StartPayout)
    eq(owedCount(w), 0, "owe cleared by the hand-trade")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "delivered", "core recorded the award delivered")
    eq(w.addon.lootCore:Get(lotId).awards[1].recipient, "Alice", "recipient recorded")
end)

test("manual hand-trade of a NON-owed item delivers nothing (no phantom)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    resolveOwedTo(w, 40005, "Alice")                   -- Alice owed 40005
    runManualTrade(w, "Alice", 40004, 1)               -- but we hand her a different item
    eq(owedCount(w), 1, "owe for 40005 untouched by trading an unrelated item")
end)

-- Allow All Trades OFF (autoCancel): decline UNSOLICITED incoming trades, but never a trade the ML
-- starts. ChromieCraft does not fire TRADE_REQUEST, so the discriminator is the InitiateTrade hook:
-- a trade the ML opens arms _selfInitiated; an incoming trade does not. Helpers reach the lib flag and
-- the client's own failure strings (so the match stays locale-independent in the test too).
local function tdLib(w) return w.env.LibStub("TradeDeliver-1.0") end
local function armSelfInitiate(w) tdLib(w)._selfInitiated = true end       -- simulate the InitiateTrade hook
local function tooFarMsg(w) return w.env.ERR_TRADE_TOO_FAR or "Trade target is too far away." end
local function busyMsg(w) return string.format(w.env.ERR_PLAYER_BUSY_S or "%s is busy right now.", "Stranger") end

test("autoCancel: an unsolicited incoming trade is declined", function()
    local w = makeWorld("Masterlooter", true)
    w.addon.payout:SetAutoCancel(true)
    setPartner(w, "Stranger")
    w.env.__closeTrade = 0
    fireEvent(w, "TRADE_SHOW")                    -- incoming: no InitiateTrade armed the flag
    eq(w.env.__closeTrade, 1, "unsolicited trade is closed by autoCancel")
end)

test("autoCancel: a self-initiated trade is allowed", function()
    local w = makeWorld("Masterlooter", true)
    w.addon.payout:SetAutoCancel(true)
    setPartner(w, "Friend")
    w.env.__closeTrade = 0
    armSelfInitiate(w)                            -- the ML opened it (InitiateTrade hook)
    fireEvent(w, "TRADE_SHOW")
    eq(w.env.__closeTrade, 0, "a trade the ML starts is not declined even with autoCancel on")
end)

test("autoCancel: a failed self-initiate (too far) disarms; the next incoming trade is declined", function()
    local w = makeWorld("Masterlooter", true)
    w.addon.payout:SetAutoCancel(true)
    setPartner(w, "Stranger")
    w.env.__closeTrade = 0
    armSelfInitiate(w)                            -- ML tried to open a trade...
    fireEvent(w, "UI_ERROR_MESSAGE", tooFarMsg(w))   -- ...but it failed (too far): disarm
    fireEvent(w, "TRADE_SHOW")                    -- now an incoming trade opens
    eq(w.env.__closeTrade, 1, "stale arm cleared by the too-far error, so the incoming trade is declined")
end)

test("autoCancel: a failed self-initiate (busy, system message) disarms; next incoming trade declined", function()
    local w = makeWorld("Masterlooter", true)
    w.addon.payout:SetAutoCancel(true)
    setPartner(w, "Stranger")
    w.env.__closeTrade = 0
    armSelfInitiate(w)                            -- ML tried to open a trade...
    fireEvent(w, "CHAT_MSG_SYSTEM", busyMsg(w))   -- ...target busy: announced only via CHAT_MSG_SYSTEM
    fireEvent(w, "TRADE_SHOW")                    -- now an incoming trade opens
    eq(w.env.__closeTrade, 1, "stale arm cleared by ERR_PLAYER_BUSY_S, so the incoming trade is declined")
end)

-- Fix: automated payout is hard-gated to the ACTIVE ML. InitializePayout runs on every client and the
-- owe ledger persists in saved vars, so without the gate a raider who was ML earlier -- or holds any
-- stale owe -- would auto-fill a trade with someone else's owed loot (the reported raider-A bug).
test("payout is ML-only: a non-ML never auto-fills a trade, even with a stale owe", function()
    local w = makeWorld("Raidernonml", false)
    eq(w.addon:IsAuthorizedLootMaster(), false, "world is not the active ML")
    w.addon.payout:Owe("Bob", 40005, 1, linkFor(40005))   -- stale owe in this client's persisted ledger
    putBag(w, 0, 1, 40005, 1, { win = 7200 })             -- and a perfectly tradeable copy in their bags
    setPartner(w, "Bob")
    w.env.__tradeSlots = 0
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)
    eq(w.env.__tradeSlots, 0, "non-ML placed nothing: the active-ML gate blocked auto-fill")
end)

-- Fix (critical): never hand out an item with no trade duration. A won BoP copy whose 2h window lapsed
-- is permanently soulbound -- it reads window==nil just like a freebie, so the soulbound check is what
-- keeps it from being placed. (Ground truth captured in-game: e.g. an expired 40629/43346 copy shows
-- "Soulbound" and no "You may trade this item..." line, while an in-window copy of the SAME item does.)
test("payout never places an expired (soulbound, no-window) copy", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    resolveOwedTo(w, 40005, "Alice")
    eq(owedCount(w), 1, "Alice owed before the trade")
    putBag(w, 0, 1, 40005, 1, { bound = true })           -- only copy is permanently bound (window gone)
    setPartner(w, "Alice")
    w.env.__tradeSlots = 0
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)
    eq(w.env.__tradeSlots, 0, "nothing placed: the untradeable copy is excluded")
    eq(owedCount(w), 1, "owe remains -- it was never delivered")
end)

-- teeth: the duplicate-copy case behind the original bug -- an expired copy AND a windowed copy of the
-- same item. The windowed one must still be delivered (and the expired one never chosen).
test("payout places the windowed copy when a duplicate is expired", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    resolveOwedTo(w, 40005, "Alice")
    putBag(w, 0, 1, 40005, 1, { bound = true })            -- expired copy (no window) -- must be skipped
    putBag(w, 0, 2, 40005, 1, { bound = true, win = 1800 })-- in-window copy -- must be delivered
    setPartner(w, "Alice")
    w.env.__tradeSlots = 0
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)
    check(w.env.__tradeSlots >= 1, "the windowed copy is delivered even though a duplicate is expired")
end)

-- Ground truth: run every authoritative in-game tooltip capture through the real engine and assert the
-- copy is placed IFF it is genuinely tradeable. This validates isSoulbound / tradeWindowSeconds against
-- REAL ChromieCraft strings (expired BoP, in-window BoP, BoE, the 40629/43346 duplicate copies).
test("tooltip ground truth: tradeability is derived correctly from real captured tooltips", function()
    local fixtures = dofile("tests/tooltip_fixtures.lua")
    check(#fixtures > 0, "fixtures loaded")
    for _, fx in ipairs(fixtures) do
        local w = makeWorld("Masterlooter", true)
        w.addon.payout:Owe("Alice", fx.id, 1, fx.link)
        putBag(w, 0, 1, fx.id, 1, { lines = fx.lines })
        setPartner(w, "Alice")
        w.env.__tradeSlots = 0
        fireEvent(w, "TRADE_SHOW")
        for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
        pump(w, 1.0)
        eq(w.env.__tradeSlots >= 1, fx.tradeable, fx.name)
    end
end)

test("trade engine: short stock delivers what it can, rest stays owed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 2, linkFor(40005))   -- owed 2
    putBag(w, 0, 1, 40005, 1)                                -- only 1 in bags
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 1, "1 of 2 delivered; 1 still owed")
end)

test("trade engine: ML pulls a rejected unique before re-accepting; only traded items settle", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    for i = 1, 4 do
        w.addon.payout:Owe("Alice", 41000 + i, 1, linkFor(41000 + i))
        putBag(w, 0, i, 41000 + i, 1)
    end
    eq(owedCount(w), 4, "Alice owed 4 up front")

    -- spy the one back-channel into the core: a traded item must be reported delivered; a pulled one
    -- must NOT (a wrongly-reported delivery would flip the core award to the DELIVERED terminal).
    local marked = {}
    local core = w.addon.lootCore
    local orig = core.MarkDeliveredFor
    core.MarkDeliveredFor = function(self, player, itemId, when) marked[itemId] = true; return orig(self, player, itemId, when) end

    -- capture whispers so we can assert the recipient is told WHY their item was held back
    local whispers = {}
    w.env.ChatThrottleLib.SendChatMessage = function(_, _, _, text, chatType, _, target)
        if chatType == "WHISPER" then whispers[#whispers + 1] = { text = text, target = target } end
    end

    w.addon.payout:StartPayout()

    -- auto-fill stuffs all 4 owed items into the window
    setPartner(w, "Alice")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)

    -- first accept with all 4: Alice already holds the unique 41003, so the whole trade is rejected.
    -- The window still holds 4 at this point. The ML's client emits the giver-side message (which on
    -- this client is the "You have too many" one, emitted backwards) -- we must key off that too.
    w.env.__tradePlaced = { { id = 41001 }, { id = 41002 }, { id = 41003 }, { id = 41004 } }
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "UI_ERROR_MESSAGE", w.env.ERR_TRADE_MAX_COUNT_EXCEEDED)   -- red error, not info

    -- ML pulls the unique out and re-accepts; only 3 are now in the window, and the trade completes.
    w.env.__tradePlaced = { { id = 41001 }, { id = 41002 }, { id = 41004 } }
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)

    eq(owedCount(w), 1, "3 traded, 1 still owed (not 0)")
    local entry = w.addon.payout:GetOwed("Alice")
    eq(entry and #entry.items, 1, "exactly one item remains owed")
    eq(entry and entry.items[1].id, 41003, "the pulled unique is what stays owed")
    check(marked[41001] and marked[41002] and marked[41004], "the 3 traded items were reported delivered to the core")
    check(not marked[41003], "the pulled unique was NEVER reported delivered to the core")
    eq(w.addon.payout.lastTradeError and w.addon.payout.lastTradeError.ml,
        "recipient can't hold another of a unique item",
        "giver-side message normalized to a direction-agnostic cause")

    -- the one held-back item is provably the culprit, so the recipient is told which item and why
    local told = false
    for _, m in ipairs(whispers) do
        if m.target == "Alice" and m.text:find("Trade failed, you already hold one (or more) unique", 1, true)
           and m.text:find("Item41003", 1, true) then told = true end
    end
    check(told, "recipient whispered the specific item link + recipient-facing reason")
    -- ...and is NOT told to "open another trade" (re-opening can't fix a unique rejection)
    local nagged = false
    for _, m in ipairs(whispers) do
        if m.target == "Alice" and m.text:find("open another trade", 1, true) then nagged = true end
    end
    check(not nagged, "no futile re-open nudge after a rejection")
end)

-- ---- taplist (BoP eligible-looter) duplicate retry ---------------------------
-- Shared setup: a winner owed ONE token; the ML holds duplicate tradeable copies (looted from
-- different kills, so different eligible-looter sets) plus a permanently-bound third copy that must
-- never be offered. `elig` is the SERVER's per-instance taplist, invisible to the addon.
local function spyDelivered(w)
    local marked = {}
    local core = w.addon.lootCore
    local orig = core.MarkDeliveredFor
    core.MarkDeliveredFor = function(self, player, itemId, when) marked[itemId] = true; return orig(self, player, itemId, when) end
    return marked
end
local function spyWhispers(w)
    local whispers = {}
    w.env.ChatThrottleLib.SendChatMessage = function(_, _, _, text, chatType, _, target)
        if chatType == "WHISPER" then whispers[#whispers + 1] = { text = text, target = target } end
    end
    return whispers
end

test("taplist: ineligible copy bounces, the next eligible copy is auto-placed and delivered", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Dremera", 40629, 1, linkFor(40629))
    putBag(w, 0, 1, 40629, 1, { win = 3600, elig = { Flab = true } })       -- soonest-to-expire, INELIGIBLE
    putBag(w, 0, 2, 40629, 1, { win = 7200, elig = { Dremera = true } })    -- the eligible copy
    putBag(w, 0, 3, 40629, 1, { bound = true })                            -- permanently soulbound: never offered
    local marked = spyDelivered(w)
    local prints = {}
    local origPrint = w.addon.payout._print
    w.addon.payout._print = function(s) prints[#prints + 1] = s; return origPrint(s) end
    w.addon.payout:StartPayout()

    setPartner(w, "Dremera")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)                       -- finalize the fill: places the soonest (ineligible) copy first
    flushTaplistBounces(w)             -- server bounces it; engine places the eligible copy in its place
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)

    eq(owedCount(w), 0, "owe cleared: the eligible duplicate was delivered after the bounce")
    check(marked[40629], "the token was reported delivered to the core")
    check(not w.addon.payout.lastTradeError, "a recovered bounce sets no trade-wide failure")
    local skipNote = false
    for _, s in ipairs(prints) do
        if s:find("skipped 1 ineligible copy of", 1, true) and s:find("Dremera", 1, true) then skipNote = true end
    end
    check(skipNote, "ML told one ineligible copy was skipped before the trade")
end)

test("taplist: ML is told the count when several copies are skipped to reach an eligible one", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Dremera", 40629, 1, linkFor(40629))
    putBag(w, 0, 1, 40629, 1, { win = 1800, elig = { Flab = true } })      -- skipped 1st
    putBag(w, 0, 2, 40629, 1, { win = 3600, elig = { Borg = true } })      -- skipped 2nd
    putBag(w, 0, 3, 40629, 1, { win = 7200, elig = { Dremera = true } })   -- the eligible copy
    local prints = {}
    local origPrint = w.addon.payout._print
    w.addon.payout._print = function(s) prints[#prints + 1] = s; return origPrint(s) end
    w.addon.payout:StartPayout()

    setPartner(w, "Dremera")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)
    flushTaplistBounces(w)             -- bounces through both ineligible copies before the eligible one
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)

    eq(owedCount(w), 0, "delivered the eligible copy after skipping two")
    local told = false
    for _, s in ipairs(prints) do
        if s:find("skipped 2 ineligible copies of", 1, true) and s:find("Dremera", 1, true) then told = true end
    end
    check(told, "ML told exactly two copies were skipped (plural)")
end)

test("taplist: every copy ineligible -> nothing traded, owe kept, both sides informed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Dremera", 40629, 1, linkFor(40629))
    putBag(w, 0, 1, 40629, 1, { win = 3600, elig = { Flab = true } })
    putBag(w, 0, 2, 40629, 1, { win = 7200, elig = { Flab = true } })
    local marked = spyDelivered(w)
    local whispers = spyWhispers(w)
    local prints = {}
    local origPrint = w.addon.payout._print
    w.addon.payout._print = function(s) prints[#prints + 1] = s; return origPrint(s) end
    w.addon.payout:StartPayout()

    setPartner(w, "Dremera")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)
    flushTaplistBounces(w)             -- both copies bounce in turn; the engine runs out of copies

    -- both sides are told the MOMENT the slot is known unfillable, while the trade is STILL OPEN --
    -- before any TRADE_CLOSED / completion.
    local told = false
    for _, m in ipairs(whispers) do
        if m.target == "Dremera" and m.text:find("eligible for the item when the boss died", 1, true)
           and m.text:find("Item40629", 1, true) then told = true end
    end
    check(told, "recipient whispered immediately on exhaustion, mid-trade")
    local mlTold = false
    for _, s in ipairs(prints) do
        if s:find("no copy this player was eligible to loot", 1, true) then mlTold = true end
    end
    check(mlTold, "ML told immediately on exhaustion, mid-trade")
    check(not w.addon.payout.lastTradeError, "no trade-wide cause set: reporting was immediate, not at close")

    fireEvent(w, "TRADE_CLOSED")       -- the window has nothing left; it closes
    pump(w, 0.6)                       -- the deferred close decision stays quiet (already informed)

    eq(owedCount(w), 1, "owe is KEPT: a future eligible copy could still fill it")
    check(not marked[40629], "nothing was reported delivered")
    local dupTold = 0
    for _, m in ipairs(whispers) do
        if m.target == "Dremera" and m.text:find("eligible for the item when the boss died", 1, true) then dupTold = dupTold + 1 end
    end
    eq(dupTold, 1, "recipient told exactly once (no duplicate at close)")
end)

test("taplist: owed 2 but only one eligible copy -> one delivered, one kept and reported", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Dremera", 40629, 2, linkFor(40629))
    putBag(w, 0, 1, 40629, 1, { win = 3600, elig = { Flab = true } })      -- ineligible
    putBag(w, 0, 2, 40629, 1, { win = 7200, elig = { Dremera = true } })   -- eligible
    local marked = spyDelivered(w)
    local whispers = spyWhispers(w)
    w.addon.payout:StartPayout()

    setPartner(w, "Dremera")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)                       -- both copies placed (owed 2); no spare copy to retry with
    flushTaplistBounces(w)             -- the ineligible one bounces and cannot be replaced
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)

    eq(owedCount(w), 1, "one copy delivered, one still owed")
    check(marked[40629], "the eligible copy was delivered")
    local told = false
    for _, m in ipairs(whispers) do
        if m.target == "Dremera" and m.text:find("eligible for the item when the boss died", 1, true) then told = true end
    end
    check(told, "recipient told the remaining copy could not be traded to them")
end)

test("trade engine: several uniques held back -- names each PURE-unique candidate, excludes unique-equipped", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    for i = 1, 4 do
        w.addon.payout:Owe("Alice", 41000 + i, 1, linkFor(41000 + i))
        putBag(w, 0, i, 41000 + i, 1)
    end

    -- 41002 & 41003 are pure Unique (possible culprits); 41004 is Unique-Equipped, which can NEVER trip
    -- the carry-one rejection, so it must be excluded from the candidates we name to the raider.
    w.addon.payout._isPureUnique = function(_, it) return it.id == 41002 or it.id == 41003 end

    local marked = {}
    local core = w.addon.lootCore
    local orig = core.MarkDeliveredFor
    core.MarkDeliveredFor = function(self, player, itemId, when) marked[itemId] = true; return orig(self, player, itemId, when) end

    local whispers = {}
    w.env.ChatThrottleLib.SendChatMessage = function(_, _, _, text, chatType, _, target)
        if chatType == "WHISPER" then whispers[#whispers + 1] = { text = text, target = target } end
    end

    w.addon.payout:StartPayout()
    setPartner(w, "Alice")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)

    -- first accept of all 4 is rejected (Alice holds the two uniques already); window still shows 4
    w.env.__tradePlaced = { { id = 41001 }, { id = 41002 }, { id = 41003 }, { id = 41004 } }
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "UI_ERROR_MESSAGE", w.env.ERR_TRADE_MAX_COUNT_EXCEEDED)   -- red error, not info

    -- ML pulls all three problem items; only 41001 transfers and the trade completes
    w.env.__tradePlaced = { { id = 41001 } }
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)

    eq(owedCount(w), 3, "all three held-back items stay owed")
    check(marked[41001] and not marked[41002] and not marked[41003] and not marked[41004],
        "only the one transferred item was reported delivered")

    local reasonWhisper
    for _, m in ipairs(whispers) do
        if m.target == "Alice" and m.text:find("you already hold one (or more) unique", 1, true) then reasonWhisper = m.text end
    end
    check(reasonWhisper ~= nil, "recipient whispered the unique-collision candidates")
    check(reasonWhisper and reasonWhisper:find("Item41002", 1, true), "names pure-unique 41002")
    check(reasonWhisper and reasonWhisper:find("Item41003", 1, true), "names pure-unique 41003")
    check(reasonWhisper and not reasonWhisper:find("Item41004", 1, true), "excludes unique-equipped 41004 from the candidates")
end)

test("trade engine: a unique rejection that CLOSES the trade (no complete) still informs, not silent", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    for i = 1, 3 do
        w.addon.payout:Owe("Alice", 41000 + i, 1, linkFor(41000 + i))
        putBag(w, 0, i, 41000 + i, 1)
    end
    w.addon.payout._isPureUnique = function(_, it) return it.id == 41002 end

    local marked, whispers = {}, {}
    local core = w.addon.lootCore
    local orig = core.MarkDeliveredFor
    core.MarkDeliveredFor = function(self, player, itemId, when) marked[itemId] = true; return orig(self, player, itemId, when) end
    w.env.ChatThrottleLib.SendChatMessage = function(_, _, _, text, chatType, _, target)
        if chatType == "WHISPER" then whispers[#whispers + 1] = { text = text, target = target } end
    end

    w.addon.payout:StartPayout()
    setPartner(w, "Alice")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)

    -- both accept; the whole trade is rejected (Alice holds unique 41002) and the window CLOSES with
    -- nothing delivered. No ERR_TRADE_COMPLETE ever fires -- the old code reported nothing here.
    -- The red UI_ERROR_MESSAGE lands AFTER TRADE_CLOSED (the real in-game order per the captured log),
    -- so the abort must arm on close and wait for the cause rather than require it up front.
    w.env.__tradePlaced = { { id = 41001 }, { id = 41002 }, { id = 41003 } }
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "TRADE_CLOSED")
    fireEvent(w, "UI_ERROR_MESSAGE", w.env.ERR_TRADE_MAX_COUNT_EXCEEDED)   -- red error, arrives post-close
    pump(w, 1.0)   -- drive the deferred abort-confirm timer

    eq(owedCount(w), 3, "nothing delivered -> all three stay owed")
    check(not marked[41001] and not marked[41002] and not marked[41003], "no deliveries reported to the core")
    local told = false
    for _, m in ipairs(whispers) do
        if m.target == "Alice" and m.text:find("Trade failed, you already hold one (or more) unique", 1, true)
           and m.text:find("Item41002", 1, true) then told = true end
    end
    check(told, "recipient told which unique blocked the trade even though it never completed")
end)

test("trade engine: a bag-full rejection states the reason but does NOT link items (links are a unique hint only)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    for i = 1, 2 do
        w.addon.payout:Owe("Alice", 41000 + i, 1, linkFor(41000 + i))
        putBag(w, 0, i, 41000 + i, 1)
    end

    local whispers = {}
    w.env.ChatThrottleLib.SendChatMessage = function(_, _, _, text, chatType, _, target)
        if chatType == "WHISPER" then whispers[#whispers + 1] = { text = text, target = target } end
    end

    w.addon.payout:StartPayout()
    setPartner(w, "Alice")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)

    -- the recipient's bags are full: a trade-wide failure that closes the window. Reason only, no items.
    w.env.__tradePlaced = { { id = 41001 }, { id = 41002 } }
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "TRADE_CLOSED")
    fireEvent(w, "UI_ERROR_MESSAGE", w.env.ERR_TRADE_TARGET_BAG_FULL)
    pump(w, 1.0)

    eq(owedCount(w), 2, "nothing delivered -> both stay owed")
    local reasonWhisper
    for _, m in ipairs(whispers) do
        if m.target == "Alice" and m.text:find("your bags are full", 1, true) then reasonWhisper = m.text end
    end
    check(reasonWhisper ~= nil, "recipient told the bag-full reason")
    check(reasonWhisper and not reasonWhisper:find("Item4100", 1, true), "no item links on a trade-wide cause")
end)

test("trade engine: a plain cancel (no red error) stays silent -- no whisper, owe untouched", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))
    putBag(w, 0, 1, 40005, 1)

    local whispers = {}
    w.env.ChatThrottleLib.SendChatMessage = function(_, _, _, text, chatType, _, target)
        if chatType == "WHISPER" then whispers[#whispers + 1] = { text = text, target = target } end
    end

    w.addon.payout:StartPayout()
    setPartner(w, "Alice")
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end
    pump(w, 1.0)                                  -- auto-fill places the item (pending set)

    -- either party just cancels: TRADE_CLOSED fires with nothing delivered and NO red error follows.
    fireEvent(w, "TRADE_CLOSED")
    pump(w, 1.0)                                  -- the 0.5s arm elapses with no cause captured

    eq(owedCount(w), 1, "owe untouched by a bare cancel")
    local nagged = false
    for _, m in ipairs(whispers) do
        if m.target == "Alice" and (m.text:find("Trade failed", 1, true) or m.text:find("not traded", 1, true)) then nagged = true end
    end
    check(not nagged, "no failure whisper on a plain cancel")
end)

test("trade engine: more than 6 owed items cap at one trade's 6 slots", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    for i = 1, 7 do
        w.addon.payout:Owe("Alice", 41000 + i, 1, linkFor(41000 + i))
        putBag(w, 0, i, 41000 + i, 1)
    end
    eq(owedCount(w), 7, "7 owed up front")
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 1, "6 delivered this trade, 1 remains (slot cap)")
end)

test("trade engine: full bags block a required split; item stays owed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))   -- owed 1
    putBag(w, 0, 1, 40005, 3)                                -- only a stack of 3 (a split is needed)
    fillBagsExcept(w)                                         -- no free slot to split into
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 1, "couldn't split into full bags -> nothing delivered, still owed")
end)

test("trade engine: split delivery works when a free slot exists", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))   -- owed 1
    putBag(w, 0, 1, 40005, 3)                                -- a stack of 3, free slots available
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 0, "split off 1 and delivered it")
end)

test("trade engine: declines a non-owed player's trade during payout", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    -- autoCancel now defaults OFF (Allow All Trades on by default), so flip it on for THIS test.
    w.addon:SetAllowAllTrades(false)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))   -- someone is owed
    w.addon.payout:StartPayout()
    setPartner(w, "Bob")                                     -- Bob is NOT owed
    fireEvent(w, "TRADE_SHOW")
    check(w.env.__closeTrade >= 1, "non-owed trade declined (CloseTrade called)")
    eq(owedCount(w), 1, "Alice still owed; nothing handed to Bob")
end)

test("trade engine: Allow All Trades OFF declines an owed player's trade during payout", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:SetAllowAllTrades(false)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))
    w.addon.payout:StartPayout()
    local closesBefore = w.env.__closeTrade
    setPartner(w, "Alice")
    fireEvent(w, "TRADE_SHOW")
    check(w.env.__closeTrade > closesBefore, "owed trade declined when allow-all is off")
    eq(owedCount(w), 1, "owed item remains owed because the trade never opened")
end)

test("trade engine: Allow All Trades OFF declines trades even with payout paused", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:SetAllowAllTrades(false)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))
    w.addon:StopPayout()
    local closesBefore = w.env.__closeTrade
    setPartner(w, "Alice")
    fireEvent(w, "TRADE_SHOW")
    check(w.env.__closeTrade > closesBefore, "trade declined even while payout is off")
    eq(owedCount(w), 1, "owed item remains owed with payout paused")
end)

test("trade engine: Allow All Trades default ON lets a non-owed trade open during payout", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    eq(w.addon:IsAllowAllTrades(), true, "allow-all is on by default")
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))   -- someone IS owed (payout in progress)
    w.addon.payout:StartPayout()
    local closesBefore = w.env.__closeTrade
    setPartner(w, "Bob")                                     -- Bob is NOT owed
    fireEvent(w, "TRADE_SHOW")
    eq(w.env.__closeTrade, closesBefore, "non-owed trade is NOT auto-declined while allow-all is on")
    eq(owedCount(w), 1, "Alice still owed; the non-owed trade did not touch the ledger")
end)

test("accepting-trades: ML predicate requires payout ON and allow-all ON", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:StartPayout()
    eq(w.addon:IsLootMasterAcceptingTrades(), true, "payout on + allow-all on -> accepting")
    w.addon:StopPayout()
    eq(w.addon:IsLootMasterAcceptingTrades(), false, "payout paused -> not accepting")
    w.addon:StartPayout()
    w.addon:SetAllowAllTrades(false)
    eq(w.addon:IsLootMasterAcceptingTrades(), false, "trades auto-declined -> not accepting")
    w.addon:SetAllowAllTrades(true)
    eq(w.addon:IsLootMasterAcceptingTrades(), true, "restored -> accepting")
end)

test("accepting-trades: ML syncs its flag; a raider reads it from the snapshot", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    ml.addon:StartPayout()
    eq(raider.addon:IsLootMasterAcceptingTrades(), true, "raider defaults to accepting before any sync")
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(raider)
    eq(raider.addon._mlAcceptingTrades, true, "raider mirrored accepting=true")
    eq(raider.addon:IsLootMasterAcceptingTrades(), true, "raider sees the ML accepting")
    ml.addon:StopPayout()
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(raider)
    eq(raider.addon._mlAcceptingTrades, false, "raider mirrored accepting=false after pause")
    eq(raider.addon:IsLootMasterAcceptingTrades(), false, "raider sees the ML not accepting")
end)

test("accepting-trades: ML left-click toggle flips incoming trades, leaves payout alone", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon:StartPayout()
    eq(w.addon:IsAllowAllTrades(), true, "trades allowed by default")
    -- the minimap left-click path: toggle incoming trades off
    w.addon:ToggleAllowAllTrades()
    eq(w.addon:IsAllowAllTrades(), false, "toggle -> incoming trades declined")
    eq(w.addon:IsLootMasterAcceptingTrades(), false, "declining -> not accepting")
    eq(w.addon.payout:IsPayoutActive(), true, "payout mode untouched by the trade toggle")
    -- toggle back on
    w.addon:ToggleAllowAllTrades()
    eq(w.addon:IsAllowAllTrades(), true, "toggle -> incoming trades allowed")
    eq(w.addon:IsLootMasterAcceptingTrades(), true, "payout on + trades on -> accepting")
end)

-- ===========================================================================
-- ROLL BLOCK: a pure-Unique item the player already holds (self-only, like the class block)
-- ===========================================================================

test("roll block: RollTierAvailability with a blockReason disables every bracket but Pass", function()
    local w = makeWorld("Masterlooter", true)
    local blocked = w.addon.util:RollTierAvailability(40005, true, false, "unique")
    eq(blocked.pass, nil, "Pass stays available when self-blocked")
    for _, k in ipairs({ "bis", "ms", "mu", "os", "tm" }) do
        eq(blocked[k], "unique", k .. " bracket carries the block reason")
    end
    local quest = w.addon.util:RollTierAvailability(40005, true, false, "quest")
    eq(quest.bis, "quest", "the reason string is passed through verbatim")
    local open = w.addon.util:RollTierAvailability(40005, true, false, nil, true)
    eq(open.bis, nil, "BiS is available when not self-blocked and the item has a listed priority")
end)

test("roll block: BiS is disabled for an item with no listed priority", function()
    local w = makeWorld("Masterlooter", true)
    -- hasPrio=false: only the BiS bracket gains the noprio reason; every other bracket is untouched.
    local noprio = w.addon.util:RollTierAvailability(40005, true, false, nil, false)
    eq(noprio.bis, "noprio", "BiS is disabled when the item has no listed priority")
    for _, k in ipairs({ "ms", "mu", "os", "tm", "pass" }) do
        eq(noprio[k], nil, k .. " stays available; noprio only touches BiS")
    end
    -- noprio is lowest precedence: a more specific BiS block still wins.
    local locked = w.addon.util:RollTierAvailability(40005, true, true, nil, false)
    eq(locked.bis, "locked", "a locked lot reports locked, not noprio")
    local blocked = w.addon.util:RollTierAvailability(40005, true, false, "unique", false)
    eq(blocked.bis, "unique", "a self-block reason still wins over noprio")
end)

test("roll block: PlayerHoldsItem sees bag contents, equipped gear, and equipped bags", function()
    local w = makeWorld("Saelinen", false)
    check(not w.addon:PlayerHoldsItem(40005), "not held to start")

    putBag(w, 0, 1, 40005, 1)
    check(w.addon:PlayerHoldsItem(40005), "found in a bag")

    w.env.__bags[0][1] = nil
    w.env.__equipped[11] = 40005                 -- a ring slot
    check(w.addon:PlayerHoldsItem(40005), "found in equipped gear")

    w.env.__equipped[11] = nil
    w.env.__equipped[20] = 40004                 -- a Unique BAG equipped in the first bag slot
    check(w.addon:PlayerHoldsItem(40004), "found as an equipped bag")
end)

test("roll block: OwnsBlockingUnique needs the item to be pure-Unique AND held", function()
    local w = makeWorld("Saelinen", false)
    w.addon.IsItemPureUnique = function(_, id) return id == 40005 or id == 40001 end
    putBag(w, 0, 1, 40005, 1)                     -- pure-unique AND held
    putBag(w, 0, 2, 40004, 1)                     -- held but not pure-unique
    check(w.addon:OwnsBlockingUnique(40005), "held pure-unique is blocked")
    check(not w.addon:OwnsBlockingUnique(40004), "held non-unique is not blocked")
    check(not w.addon:OwnsBlockingUnique(40001), "pure-unique not held is not blocked")
end)

test("roll block: the ML is exempt from the own-unique block (holds the drop only to hand it out)", function()
    local w = makeWorld("Masterlooter", true)
    w.addon.IsItemPureUnique = function(_, id) return id == 40005 end
    putBag(w, 0, 1, 40005, 1)                     -- the unique drop sits in the ML's bags during rolls
    w.addon.IsAuthorizedLootMaster = function() return true end
    check(not w.addon:OwnsBlockingUnique(40005), "ML holding the dropped unique is not self-blocked")
    -- a non-ML holding the same unique is still blocked: the copy is genuinely theirs
    w.addon.IsAuthorizedLootMaster = function() return false end
    check(w.addon:OwnsBlockingUnique(40005), "a non-ML holder is still blocked")
end)

test("roll block: PlayerHoldsItem also scans the keyring (quest-reward keys live there)", function()
    local w = makeWorld("Saelinen", false)
    check(not w.addon:PlayerHoldsItem(44582), "reward key not held initially")
    w.env.__keyring[3] = 44582                    -- the normal Focusing Iris reward key, in the keyring
    check(w.addon:PlayerHoldsItem(44582), "found in the keyring")
end)

test("roll block: a dropped quest-starter is blocked once you hold the quest's reward (quest done)", function()
    local w = makeWorld("Saelinen", false)
    -- 44569 (the dropped normal key) starts a quest whose reward is the keyring key 44582.
    eq(w.addon:RollSelfBlockReason(44569), nil, "not blocked before the quest is done")
    w.env.__keyring[1] = 44582                    -- completed the quest -> hold the reward
    eq(w.addon:RollSelfBlockReason(44569), "quest", "holding the reward blocks rolling the drop")
    eq(w.addon:RollSelfBlockReason(44577), nil, "heroic drop unaffected by the normal reward")
    w.env.__keyring[2] = 44581                    -- heroic reward
    eq(w.addon:RollSelfBlockReason(44577), "quest", "heroic drop blocked by the heroic reward")
end)

-- ===========================================================================
-- ADVERSARIAL / FAILURE-MODE cases (where things break, by design or as a known gap)
-- ===========================================================================

test("trade in progress: an owed copy leaving bags is protected; delivery is recorded", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    -- a payout trade window is open (the ML is handing the item to Alice)
    w.addon.payout.tradeOpen = true
    -- BAG_UPDATE reconciles BEFORE the trade-complete callback (the old race order)
    setBag(w, 40005, 0); bagUpdate(w)
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "owed", "owed copy NOT written off while a trade is open")
    check(w.addon.lootCore:MarkDeliveredFor("Alice", 40005), "trade-complete still records the delivery")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "delivered", "copy recorded delivered, not removed")
end)

test("no trade open: an owed copy genuinely leaving bags is recorded removed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    -- no trade window: the item really left (destroyed / mailed), so removal is correct
    setBag(w, 40005, 0); bagUpdate(w)
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "removed", "with no trade open, the copy is removed")
end)

test("guard: a response on a resolved lot is rejected", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    check(not w.addon.lootCore:SetResponse(lotId, "bob", "ms"), "core refuses to mutate a resolved lot")
end)

test("guard: a rolling lot is never retired on a mid-roll bag-count drop", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40004, 2); bagUpdate(w)
    local lot = openLot(w, 40004)
    w.addon:StartLiveRoll(lot.id)                 -- count 2, rolling
    setBag(w, 40004, 1); bagUpdate(w)             -- a copy leaves mid-roll
    eq(w.addon.lootCore:State(lot.id), "rolling", "still rolling, not retired")
    eq(w.addon.lootCore:Get(lot.id).count, 2, "count not shrunk under an active roll")
end)

test("guard: MarkDeliveredFor with the wrong player or item is a no-op", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    check(not w.addon.lootCore:MarkDeliveredFor("Nobody", 40005), "wrong player -> false")
    check(not w.addon.lootCore:MarkDeliveredFor("Alice", 99999), "wrong item -> false")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "owed", "award still owed")
end)

test("guard: reconcile retires an un-rolled copy before an owed one", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")   -- owed copy held in bags
    setBag(w, 40005, 2); bagUpdate(w)                -- a fresh copy drops alongside it
    local fresh = openLot(w, 40005)
    check(fresh and fresh.id ~= lotId, "a separate fresh lot exists")
    setBag(w, 40005, 1); bagUpdate(w)                -- drop one: the un-rolled one should go
    eq(w.addon.lootCore:LiveCount(fresh.id), 0, "the un-rolled fresh copy was retired")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "owed", "the owed copy was preserved")
end)

test("guard: a malformed/unknown sync value is ignored (no crash)", function()
    local w = makeWorld("Raidertwo", false)
    -- WeirdComm hands WeirdSync a decoded VALUE; a non-table or an unknown-tag table must be
    -- dropped, not staged. (There is no longer a stray "SE without SB": a snapshot is atomic.)
    local ok = pcall(function()
        w.addon.syncChannel:OnReceive("Masterlooter", "not a table")
        w.addon.syncChannel:OnReceive("Masterlooter", { "BOGUS", "x", "y" })
        w.addon.syncChannel:OnReceive("Masterlooter", {})
    end)
    check(ok, "malformed sync values handled without error")
    eq(#w.addon.lootCore:All(), 0, "nothing staged into the ledger")
end)

test("guard: a roll with no responders resolves to no winner and no owe", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:ResolveLiveRoll(lot.id)                  -- nobody rolled
    eq(w.addon.lootCore:Get(lot.id).awards[1].winner, nil, "no winner")
    eq(w.addon.lootCore:Get(lot.id).awards[1].state, "resolved", "ML keeps it")
    eq(owedCount(w), 0, "no owe created")
end)

test("guard: unlock + reroll retracts the owe and re-creates it for the new winner", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    eq(owedCount(w), 1, "owed after first resolve")
    w.addon.lootCore:Unlock(lotId)
    eq(owedCount(w), 0, "owe retracted on unlock")
    w.addon:StartLiveRoll(lotId)
    w.addon:RegisterInterest(lotId, "Bob", "ms")
    w.addon:ResolveLiveRoll(lotId)
    eq(owedCount(w), 1, "re-owed after reroll")
end)

-- ---------------------------------------------------------------------------
-- auto-start dispatch order: a debounced loot batch must broadcast (and pop up) in
-- OrderLotIdsNonEquipFirst order, NOT reversed. Regression for the synchronous-ledgerChanged
-- re-entrancy that drained the batch depth-first and reversed it for raiders.
-- ---------------------------------------------------------------------------
test("auto-start respects rollBatchSize: 7 fresh lots with batchSize=5 broadcast 5 immediately", function()
    local ml = makeWorld("Masterlooter", true)
    local sent = {}
    local origSend = ml.addon.SendLargeMessage
    ml.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "DROP" then sent[#sent + 1] = tonumber(values[2]) end
        return origSend(self, command, values, ...)
    end
    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = false
    ml.addon.db.options.autoSkipRoll = false
    ml.addon.db.options.rollBatchSize = 5

    -- mint 7 lots quietly (auto-start off), then flip on and drive one batch pass.
    for i = 1, 7 do setBag(ml, 40000 + i, 1); bagUpdate(ml) end
    clearWire()
    ml.addon.db.options.autoStartRoll = true
    ml.addon:SyncPendingPopups()

    -- Only the first batchSize lots should have broadcast a DROP; the remaining 2 are queued.
    eq(#sent, 5, "exactly batchSize (5) DROPs broadcast immediately")
    eq(ml.addon:CountActiveRollBatch(), 5, "5 lots are active in the batch")
    eq(ml.addon._rollBatch and #ml.addon._rollBatch.queue, 2, "2 lots remain queued")
end)

test("auto-start: the remaining queue drains as the active rolls finish", function()
    local ml = makeWorld("Masterlooter", true)
    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = false
    ml.addon.db.options.autoSkipRoll = false
    ml.addon.db.options.rollBatchSize = 5

    for i = 1, 7 do setBag(ml, 40000 + i, 1); bagUpdate(ml) end
    ml.addon.db.options.autoStartRoll = true
    ml.addon:SyncPendingPopups()

    eq(ml.addon:CountActiveRollBatch(), 5, "first batch is full (5 active)")
    eq(#ml.addon._rollBatch.queue, 2, "2 lots queued for the next batch")

    -- Resolve the 5 active rolls one by one. After the last, AdvanceRollBatch should start the
    -- remaining 2 (queue empties to 0; active becomes 2).
    local activeIds = {}
    for id in pairs(ml.addon._rollBatch.active) do activeIds[#activeIds + 1] = id end
    for _, id in ipairs(activeIds) do
        ml.addon:ResolveLiveRoll(id)
    end
    -- Now the 2 queued lots should be active.
    eq(ml.addon._rollBatch and ml.addon:CountActiveRollBatch(), 2, "remaining 2 lots now active")
    eq(#ml.addon._rollBatch.queue, 0, "queue empty after second batch starts")
end)

test("auto-start broadcasts the batch in order (not reversed)", function()
    local ml = makeWorld("Masterlooter", true)
    local sent = {}
    local origSend = ml.addon.SendLargeMessage
    ml.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "DROP" then sent[#sent + 1] = tonumber(values[2]) end   -- field 2 = itemId
        return origSend(self, command, values, ...)
    end
    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = false   -- mint quietly first so mint order is deterministic
    ml.addon.db.options.autoSkipRoll = false

    -- mint A B C in a known order (the harness bag scan is pairs()-unordered, so mint one at a
    -- time), leaving them NEW; then flip auto-start on and drive the single batch pass.
    setBag(ml, 40001, 1); bagUpdate(ml)
    setBag(ml, 40002, 1); bagUpdate(ml)
    setBag(ml, 40003, 1); bagUpdate(ml)
    clearWire()
    ml.addon.db.options.autoStartRoll = true
    ml.addon:SyncPendingPopups()

    eq(#sent, 3, "all three lots broadcast")
    eq(sent[1], 40001, "first DROP is the first-minted lot (A)")
    eq(sent[2], 40002, "second DROP is B")
    eq(sent[3], 40003, "third DROP is C (was reversed to C B A before the guard)")
end)

test("auto-start keeps non-equipment ahead of equipment in the batch", function()
    local ml = makeWorld("Masterlooter", true)
    ml.addon.util.REDUCED_ROLL_ITEMS[40004] = true   -- mark 40004 as known non-equipment (rolls first)
    local sent = {}
    local origSend = ml.addon.SendLargeMessage
    ml.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "DROP" then sent[#sent + 1] = tonumber(values[2]) end
        return origSend(self, command, values, ...)
    end
    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = false
    ml.addon.db.options.autoSkipRoll = false

    -- mint equipment 40001 BEFORE non-equipment 40004; non-equip must still lead the broadcast
    setBag(ml, 40001, 1); bagUpdate(ml)
    setBag(ml, 40004, 1); bagUpdate(ml)
    clearWire()
    ml.addon.db.options.autoStartRoll = true
    ml.addon:SyncPendingPopups()

    eq(#sent, 2, "both lots broadcast")
    eq(sent[1], 40004, "non-equipment leads despite being minted second")
    eq(sent[2], 40001, "equipment follows")
end)

-- capture the itemId order in which a world opens roll popups (ShowInterestPopup), ML or raider.
local function tapPopups(w)
    local seen = {}
    local orig = w.addon.ShowInterestPopup
    w.addon.ShowInterestPopup = function(self, roll, slot)
        seen[#seen + 1] = roll.itemId
        return orig(self, roll, slot)
    end
    return seen
end

-- (1) keystone: what the ML pops up == what raiders receive. Guards the exact reported symptom
-- (ML sees one order, raiders see the reverse) across the full dispatch -> wire -> OnDropMessage path.
test("auto-start: raider roll order matches the ML's own popup order", function()
    local ml = makeWorld("Masterlooter", true)
    local r1 = makeWorld("Raider", false)
    local mlPops = tapPopups(ml)
    local r1Pops = tapPopups(r1)

    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = false
    ml.addon.db.options.autoSkipRoll = false

    setBag(ml, 40001, 1); bagUpdate(ml)
    setBag(ml, 40002, 1); bagUpdate(ml)
    setBag(ml, 40003, 1); bagUpdate(ml)
    clearWire()
    ml.addon.db.options.autoStartRoll = true
    ml.addon:SyncPendingPopups()
    flushWireTo(r1, "Masterlooter")

    eq(#mlPops, 3, "ML opened three popups")
    eq(#r1Pops, 3, "raider opened three popups")
    eq(table.concat(r1Pops, ","), table.concat(mlPops, ","), "raider order equals ML popup order")
    eq(table.concat(mlPops, ","), "40001,40002,40003", "and both are the in-order batch (not reversed)")
end)

-- (2) bulk path: the Start Rolls button broadcasts in OrderLotIdsNonEquipFirst order, non-equip first.
test("bulk ProcessLoot broadcasts non-equipment first, in order", function()
    local ml = makeWorld("Masterlooter", true)
    ml.addon.util.REDUCED_ROLL_ITEMS[40004] = true   -- 40004 = known non-equipment (rolls first)
    local sent = {}
    local origSend = ml.addon.SendLargeMessage
    ml.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "DROP" then sent[#sent + 1] = tonumber(values[2]) end
        return origSend(self, command, values, ...)
    end
    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = false
    ml.addon.db.options.rollBatchSize = 99           -- one batch, no draining gaps

    setBag(ml, 40001, 1); bagUpdate(ml)              -- equipment, minted first
    setBag(ml, 40004, 1); bagUpdate(ml)              -- non-equipment, minted second
    clearWire()
    ml.addon:ProcessLoot()

    eq(#sent, 2, "both lots broadcast")
    eq(sent[1], 40004, "non-equipment leads")
    eq(sent[2], 40001, "equipment follows")
end)

-- (3) split debounce (laggy mid-pickup): two reconcile windows must broadcast every lot exactly
-- once -- none stranded, none double-sent.
test("split-debounce auto-start broadcasts all loot exactly once", function()
    local ml = makeWorld("Masterlooter", true)
    local sent = {}
    local origSend = ml.addon.SendLargeMessage
    ml.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "DROP" then sent[#sent + 1] = tonumber(values[2]) end
        return origSend(self, command, values, ...)
    end
    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = true
    ml.addon.db.options.autoSkipRoll = false
    clearWire()

    -- window 1: two items settle
    setBag(ml, 40001, 1); setBag(ml, 40002, 1); bagUpdate(ml)
    -- window 2: the rest of the corpse lands a beat later
    setBag(ml, 40003, 1); setBag(ml, 40004, 1); bagUpdate(ml)

    eq(#sent, 4, "all four lots broadcast across the two windows")
    local seen = {}
    for _, id in ipairs(sent) do seen[id] = (seen[id] or 0) + 1 end
    eq(seen[40001], 1, "40001 sent once"); eq(seen[40002], 1, "40002 sent once")
    eq(seen[40003], 1, "40003 sent once"); eq(seen[40004], 1, "40004 sent once")
    local rolling = 0
    for _, lot in ipairs(ml.addon.lootCore:List()) do if lot.state == "rolling" then rolling = rolling + 1 end end
    eq(rolling, 4, "every lot ended up rolling (nothing stranded)")
end)

-- (5) a StartLiveRoll error mid-batch must not latch _autoStarting (which would disable all future
-- auto-starts until reload). The error still propagates; the flag clears; the next batch works.
test("auto-start error does not permanently disable auto-start", function()
    local ml = makeWorld("Masterlooter", true)
    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = false        -- mint quietly so the lots stay NEW
    ml.addon.db.options.autoSkipRoll = false

    setBag(ml, 40001, 1); bagUpdate(ml)
    setBag(ml, 40002, 1); bagUpdate(ml)

    -- make the dispatch blow up mid-batch, then drive the pass (it re-raises, so pcall it here)
    local origStart = ml.addon.StartLiveRoll
    ml.addon.StartLiveRoll = function() error("boom") end
    clearWire()
    ml.addon.db.options.autoStartRoll = true
    local ok = pcall(function() ml.addon:SyncPendingPopups() end)
    check(not ok, "the StartLiveRoll error propagates (not swallowed)")
    eq(ml.addon._autoStarting, false, "_autoStarting cleared despite the error")

    -- recover: real StartLiveRoll, fresh drop -> auto-start still fires
    ml.addon.StartLiveRoll = origStart
    local sent = {}
    local origSend = ml.addon.SendLargeMessage
    ml.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "DROP" then sent[#sent + 1] = tonumber(values[2]) end
        return origSend(self, command, values, ...)
    end
    setBag(ml, 40003, 1); bagUpdate(ml)
    check(#sent >= 1, "auto-start still works after the earlier error")
end)

-- (4) guard-hygiene invariant. CAVEAT: this is a WHITE-BOX test of the _autoStarting flag by name,
-- not a behavior test. If the re-entrancy is ever solved a different way (deferred/coalesced
-- ledgerChanged, a renamed or differently-scoped guard, etc.), this test can fail while the addon
-- is perfectly correct -- the behavior tests above (order preserved, all loot broadcast) are the
-- real contract. So a failure HERE is a signal to re-check the mechanism, not proof of a bug: if the
-- ordering/completeness tests still pass, update or delete this one rather than "fixing" the code.
test("auto-start guard: a re-entrant SyncPendingPopups is a no-op while dispatching", function()
    local ml = makeWorld("Masterlooter", true)
    local sent = {}
    local origSend = ml.addon.SendLargeMessage
    ml.addon.SendLargeMessage = function(self, command, values, ...)
        if command == "DROP" then sent[#sent + 1] = tonumber(values[2]) end
        return origSend(self, command, values, ...)
    end
    startSession(ml)
    ml.addon.db.autoRoll = false
    ml.addon.db.options = ml.addon.db.options or {}
    ml.addon.db.options.autoStartRoll = false        -- mint quietly: lots stay NEW
    ml.addon.db.options.autoSkipRoll = false
    setBag(ml, 40001, 1); bagUpdate(ml)
    setBag(ml, 40002, 1); bagUpdate(ml)

    -- simulate "a dispatch is already in flight": with the flag set, the call must short-circuit.
    ml.addon.db.options.autoStartRoll = true
    ml.addon._autoStarting = true
    clearWire()
    ml.addon:SyncPendingPopups()
    eq(#sent, 0, "guarded call sends nothing")
    local stillNew = 0
    for _, lot in ipairs(ml.addon.lootCore:List()) do if lot.state == "new" then stillNew = stillNew + 1 end end
    eq(stillNew, 2, "guarded call leaves the NEW lots untouched")

    -- clearing the flag restores normal dispatch
    ml.addon._autoStarting = false
    ml.addon:SyncPendingPopups()
    eq(#sent, 2, "dispatch resumes once the guard clears")
    eq(ml.addon._autoStarting, false, "flag is back to false after a completed pass")
end)

-- ===========================================================================
-- 25-man message-load report (opt-in: WLLOAD=1). Reveals the real outgoing message
-- count/bytes of a full raid loot session WITHOUT testing in-game, by tallying the mocked
-- wire and modelling ChatThrottleLib (MAX_CPS=800, 40B/msg overhead, 245B chunk size).
-- ===========================================================================
local function loadReport()
    local PREFIX = "WeirdLoot"
    local MAXLEN, CPS, OVERHEAD = 254 - #PREFIX, 800, 40

    -- summarize WIRE (and clear it): logical msgs, physical chunks, CTL bytes, drain seconds.
    local function drain(label)
        local byCmd, byPrio = {}, { ALERT = 0, BULK = 0 }
        local logical, chunks, bytes = 0, 0, 0
        for _, m in ipairs(F.WIRE) do
            -- All WeirdLoot traffic rides ONE WeirdComm channel over SendAddonMessage. m.value is
            -- the serialized logical message (always present now); m.msg is a legacy field kept
            -- for backward compat with older test stubs that captured raw strings, and is nil for
            -- everything WeirdComm produces. The 254-byte ceiling is the addon-channel server
            -- hard limit, not an AceComm limit.
            local cmd = (m.value and m.value[1]) or string.match(m.msg or "", "^[^|" .. string.char(30) .. "]+") or "?"
            byCmd[cmd] = (byCmd[cmd] or 0) + 1
            local prio = m.prio or "BULK"
            byPrio[prio] = (byPrio[prio] or 0) + 1
            local len = m.msg and #m.msg or 0
            local c = m.msg and math.max(1, math.ceil(len / MAXLEN)) or 0
            logical = logical + 1; chunks = chunks + c; bytes = bytes + len + c * OVERHEAD
        end
        clearWire()                                -- alias: clears F.WIRE, which the local WIRE reads
        return { label = label, logical = logical, chunks = chunks, bytes = bytes,
                 secs = bytes / CPS, byCmd = byCmd, byPrio = byPrio }
    end
    local function line(r)
        local parts = {}
        for k, v in pairs(r.byCmd) do parts[#parts + 1] = k .. ":" .. v end
        table.sort(parts)
        return string.format("  %-22s %4d msg  %4d chunks  %6dB  %5.1fs drain  [A:%d B:%d]  %s",
            r.label, r.logical, r.chunks, r.bytes, r.secs, r.byPrio.ALERT or 0, r.byPrio.BULK or 0, table.concat(parts, " "))
    end

    local ml = makeWorld("Masterlooter", true)
    startSession(ml)
    local attendees = {}
    for i = 1, 25 do attendees[i] = { name = "Raider" .. i, className = "Warrior", specName = "Arms", status = "main" } end
    ml.addon.session.attendees = attendees
    ml.addon.GetAttendees = function() return attendees end

    print("")
    print("=== 25-man comm load report (delta sync) ===")

    -- cost of ONE full snapshot at this roster size (the old per-change unit)
    clearWire(); ml.addon:BroadcastSession()
    print(line(drain("one full snapshot")))

    -- representative single operations (delta path)
    clearWire(); setBag(ml, 40001, 1); bagUpdate(ml)
    print(line(drain("one fresh drop")))
    local lot = openLot(ml, 40001)
    clearWire(); ml.addon:StartLiveRoll(lot.id)
    print(line(drain("one Start Roll")))
    clearWire(); ml.addon:SetPlayerResponse(lot.id, "Raider5", "ms")
    print(line(drain("one raider response")))
    clearWire(); ml.addon:ResolveLiveRoll(lot.id)
    print(line(drain("one resolve")))

    -- a full session: 12 items (2 of them x2), each rolled by 12 of 25 raiders
    clearWire()
    local items = { 40001, 40002, 40003, 40004, 40005, 40006, 40007, 40008, 40009, 40010, 40011, 40012 }
    for idx, id in ipairs(items) do
        local qty = (idx <= 2) and 2 or 1
        setBag(ml, id, qty); bagUpdate(ml)
        local lt = openLot(ml, id)
        if lt then
            ml.addon:StartLiveRoll(lt.id)
            for r = 1, 12 do ml.addon:SetPlayerResponse(lt.id, "Raider" .. r, (r % 5 == 0) and "bis" or "ms") end
            ml.addon:ResolveLiveRoll(lt.id)
        end
    end
    local sess = drain("full session (12 items)")
    print(line(sess))
    print(string.format("  -> old model (full snapshot per change) would be ~%d state-changes x one-snapshot.",
        12 * 3))
    print("")
end
if os.getenv("WLLOAD") then loadReport() end

-- ===========================================================================
-- Boss-drop latency: a 40-person raid that already has 30 items sitting in the
-- drop list; a boss dies dropping 5 more, which the ML puts up for roll. How long
-- until raiders SEE the 5 roll popups? Models ChatThrottleLib (MAX_CPS=800, 40B/msg
-- overhead, 245B chunks). ALERT is sent ahead of BULK by CTL, so the popup latency
-- is the ALERT lane's drain time, independent of the BULK ledger/roster traffic.
-- ===========================================================================
local function bossDropReport()
    local PREFIX = "WeirdLoot"
    local MAXLEN, CPS, OVERHEAD = 254 - #PREFIX, 800, 40
    local function tally(filter)
        local logical, chunks, bytes, byCmd = 0, 0, 0, {}
        for _, m in ipairs(F.WIRE) do
            local prio = m.prio or "BULK"
            if (not filter) or prio == filter then
                local cmd = (m.value and m.value[1]) or string.match(m.msg or "", "^[^|" .. string.char(30) .. "]+") or "?"
                byCmd[cmd] = (byCmd[cmd] or 0) + 1
                local len = m.msg and #m.msg or 0
                local c = m.msg and math.max(1, math.ceil(len / MAXLEN)) or 0
                logical, chunks, bytes = logical + 1, chunks + c, bytes + len + c * OVERHEAD
            end
        end
        local parts = {}; for k, v in pairs(byCmd) do parts[#parts + 1] = k .. ":" .. v end; table.sort(parts)
        return logical, chunks, bytes, table.concat(parts, " ")
    end

    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    local attendees = {}
    for i = 1, 39 do attendees[i] = { name = "Raider" .. i, className = "Warrior", specName = "Arms", status = "main" } end
    ml.addon.session.attendees = attendees
    ml.addon.GetAttendees = function() return attendees end

    -- 30 items already dropped and listed (pending), fully synced to the raider
    for i = 1, 30 do setBag(ml, 41000 + i, 1); bagUpdate(ml); openLot(ml, 41000 + i) end
    ml.addon:BroadcastSession(); flushWireTo(raider)
    clearWire()                                            -- baseline: wire is quiet, raider in sync

    -- BOSS DIES: 5 new BoP items land; the ML puts each up for roll
    for i = 1, 5 do setBag(ml, 42000 + i, 1); bagUpdate(ml) end   -- fresh-drop deltas (BULK)
    local rollLots = {}
    for i = 1, 5 do rollLots[i] = openLot(ml, 42000 + i) end
    for i = 1, 5 do ml.addon:StartLiveRoll(rollLots[i].id) end    -- 5 DROP (ALERT) + state deltas

    local aL, aC, aB, aCmd = tally("ALERT")
    local bL, bC, bB, bCmd = tally("BULK")
    local tL, tC, tB = tally(nil)

    print("")
    print("=== boss-drop latency: 40-raider, 30 items already listed, 5 new -> roll ===")
    print(string.format("  ALERT (roll popups):  %2d msg  %2d chunks  %5dB  ->  all 5 popups delivered in %.2fs  [%s]", aL, aC, aB, aB / CPS, aCmd))
    print(string.format("  BULK  (ledger deltas):%3d msg  %2d chunks  %5dB  ->  %.2fs background drain        [%s]", bL, bC, bB, bB / CPS, bCmd))
    print(string.format("  first popup ~%.2fs, last (5th) popup ~%.2fs  (CTL sends ALERT before BULK)", (aB / 5) / CPS, aB / CPS))
    print(string.format("  total on wire this tick: %d msg / %d chunks / %dB (%.2fs if drained serially)", tL, tC, tB, tB / CPS))

    clearWire(); ml.addon:BroadcastSession()
    local sL, sC, sB = tally(nil); clearWire()        -- alias: clears F.WIRE
    print(string.format("  (worst case -- a raider ZONING IN right then pulls a full 35-lot snapshot: %d chunks / %dB -> %.2fs, BULK)", sC, sB, sB / CPS))
    print("")
end
if os.getenv("WLBOSS") then bossDropReport() end

-- ===========================================================================
-- epoch generation counter + loot-master handoff takeover (the stale-epoch poison fix)
-- ===========================================================================

-- Epochs are a monotonic counter now, not tostring(time()); the harness clock is frozen at CLOCK,
-- so under the old scheme two session starts would collide on the same id. The counter must still
-- strictly increase.
test("epoch: session ids are a monotonic counter, independent of the clock", function()
    local ml = makeWorld("Masterlooter", true)
    startSession(ml)
    local e1 = tonumber(ml.addon.session.id)
    check(e1 ~= nil, "epoch is numeric")
    startSession(ml)
    local e2 = tonumber(ml.addon.session.id)
    check(e2 and e1 and e2 > e1, "second epoch > first with the clock frozen (got " .. tostring(e2) .. " vs " .. tostring(e1) .. ")")
end)

-- Migration safety: a peer still on a time()-stamp epoch must not out-rank a freshly minted one.
-- Observing any epoch lifts the high-water, so the next mint lands above it.
test("epoch: a mint always lands above any epoch seen on the wire (migration-safe)", function()
    local ml = makeWorld("Masterlooter", true)
    ml.addon:ObserveEpoch("1781803516")     -- a legacy time()-stamp from an un-upgraded peer
    startSession(ml)
    check(tonumber(ml.addon.session.id) > 1781803516, "new epoch out-ranks the legacy time-stamp epoch")
end)

-- The safety guard: a session restored from disk (active, but never mirrored this run) must NEVER be
-- rebroadcast on ML gain -- that would push stale leftover loot onto the raid.
test("handoff: a disk-restored leftover session is not rebroadcast on ML gain", function()
    local w = makeWorld("Promotee", false)
    w.addon.session.active = true            -- looks active...
    w.addon.session.id = "5"
    w.addon._mirrorActive = false            -- ...but it is NOT a live mirror (disk leftover)
    clearWire()
    w.addon:AssumeLootMasterSession()
    eq(w.addon.session.id, "5", "epoch left untouched (no takeover)")
    eq(#F.WIRE, 0, "nothing broadcast")
end)

-- The feature: gaining ML over a session we were actively mirroring continues it -- a fresh, higher
-- epoch is minted, the mirrored ledger is kept, and a snapshot goes out so the raid rebaselines.
test("handoff: gaining ML over a live mirror continues it under a higher epoch, ledger intact", function()
    local ml = makeWorld("Masterlooter", true)
    local promotee = makeWorld("Promotee", false)
    startSession(ml)
    setBag(ml, 40001, 1); bagUpdate(ml)      -- a fresh drop auto-rolls and broadcasts
    flushWireTo(promotee, "Masterlooter")     -- promotee mirrors the live session

    check(promotee.addon._mirrorActive == true, "promotee marked as a live mirror")
    local mirrored = #promotee.addon.lootCore:All()
    check(mirrored > 0, "promotee mirrored the lot(s)")
    local epBefore = tonumber(promotee.addon.session.id)

    promotee.addon.roster.isLootMaster = true  -- they just became the raid's loot master
    clearWire()
    promotee.addon:AssumeLootMasterSession()

    check(tonumber(promotee.addon.session.id) > epBefore, "epoch bumped above the mirrored one (got "
        .. tostring(promotee.addon.session.id) .. " vs " .. tostring(epBefore) .. ")")
    eq(#promotee.addon.lootCore:All(), mirrored, "ledger preserved across the takeover")
    check(#F.WIRE > 0, "a snapshot was broadcast at the new epoch")
end)

-- Q2: a fresh login transiently reports partyMasterIndex==0 (self) before the raid roster loads.
-- In a RAID that must not self-claim loot master; in a 5-man PARTY it legitimately still does.
test("Q2: in a raid, an unresolved master-index does not self-claim loot master", function()
    local w = makeWorld("Bystander", false)
    w.env.GetNumRaidMembers = function() return 5 end
    w.env.GetNumPartyMembers = function() return 0 end
    w.env.GetLootMethod = function() return "master", 0, nil end   -- partyMaster=0, raid index unresolved
    w.addon:RefreshLootAuthority()
    eq(w.addon.roster.isLootMaster, false, "did not self-claim ML in a raid")
end)

-- A 5-man party with master loot pointed at us legitimately makes us the loot master. The relog
-- race that the raid-only gate was guarding against has numParty == 0 too (no group has loaded),
-- so this branch's numParty > 0 gate keeps the race from co-opting it.
test("ML gating: in a 5-man party with master loot pointed at self, we ARE the loot master", function()
    local w = makeWorld("Masterlooter", true)
    w.env.GetNumRaidMembers = function() return 0 end
    w.env.GetNumPartyMembers = function() return 4 end
    w.env.GetLootMethod = function() return "master", 0, nil end   -- party master loot pointed at self
    w.addon:RefreshLootAuthority()
    eq(w.addon.roster.isLootMaster, true, "party master loot self-grants ML authority")
end)

test("ML gating: in a 5-man party with master loot pointed at someone else, we are NOT the ML", function()
    local w = makeWorld("Masterlooter", true)
    w.env.GetNumRaidMembers = function() return 0 end
    w.env.GetNumPartyMembers = function() return 4 end
    w.env.UnitName = function(unit) if unit == "party1" then return "OtherPlayer" end return "Masterlooter" end
    w.env.GetLootMethod = function() return "master", 1, nil end   -- party master loot pointed at party1
    w.addon:RefreshLootAuthority()
    eq(w.addon.roster.isLootMaster, false, "party master loot pointed elsewhere does NOT grant authority")
end)

-- The original incident, reproduced deterministically. A is the real ML and B mirrors A. C was a
-- loot master earlier, so it carries a stale active session with its own (higher) epoch, and is now
-- just a raider. C "logs in": PLAYER_ENTERING_WORLD runs while GetLootMethod is in the post-relog
-- window -- master loot, partyMasterIndex==0 (the API flagging C as self), the raid master index not
-- yet resolvable. Pre-fix, C self-claimed loot master there and broadcast its stale session, and
-- peers adopted it over the real ML. The raid-only ML gate must keep C from ever claiming authority,
-- so it broadcasts nothing. (Drive PLAYER_ENTERING_WORLD, not just RefreshLootAuthority, so the real
-- broadcast path is exercised: revert the gate and C emits a SNAP here, failing the test.)
test("regression: a demoted ex-ML relogging in the login window never broadcasts as authority", function()
    local A = makeWorld("Masterlooter", true)
    local B = makeWorld("Raider", false)
    local C = makeWorld("Exmaster", false)

    startSession(A)
    setBag(A, 40001, 1); bagUpdate(A)
    flushWireTo(B, "Masterlooter")
    local aEpoch = A.addon.session.id
    eq(B.addon.session.id, aEpoch, "B is mirroring A's session")
    local bLots = #B.addon.lootCore:All()
    check(bLots > 0, "B mirrored A's lot(s)")

    -- C carries a stale active session from when it was ML (its own, higher legacy-shaped epoch).
    C.addon.session.active = true
    C.addon.session.id = "9999999999"          -- stale and numerically higher than A's counter epoch
    C.addon._mirrorActive = false              -- disk-restored leftover, not a live mirror

    -- the transient post-relog window: in a raid, master loot, partyMaster=0 (self), raid index unresolved
    C.env.GetNumRaidMembers = function() return 5 end
    C.env.GetNumPartyMembers = function() return 0 end
    C.env.GetLootMethod = function() return "master", 0, nil end
    clearWire()
    C.addon:PLAYER_ENTERING_WORLD()            -- the actual login path (RefreshAll + broadcast-if-authority)

    eq(C.addon.roster.isLootMaster, false, "C did not self-claim loot master in the login window")
    local cAuthorityTraffic = 0
    for _, m in ipairs(F.WIRE) do
        if m.sender == "Exmaster" and m.value and (m.value[1] == "SNAP" or m.value[1] == "H") then
            cAuthorityTraffic = cAuthorityTraffic + 1
        end
    end
    eq(cAuthorityTraffic, 0, "C broadcast no authority traffic (SNAP/H) at login")

    -- and a peer correctly bound to the real ML is untouched by anything C put on the wire
    flushWireTo(B, "Exmaster")
    eq(B.addon.session.id, aEpoch, "B still on A's session (not poisoned by C)")
    eq(#B.addon.lootCore:All(), bLots, "B's mirrored ledger unchanged")
end)

-- ===========================================================================
-- authoritative ledger sync: per-copy disposition (winner/state/holder) on the wire, holder-aware
-- live count, and the handoff masking bug it fixes.
-- ===========================================================================

-- The disposition is authoritative ledger state (not derivable from itemId), so it must survive the
-- wire intact -- otherwise a promoted ML cannot inherit the owed map.
test("ledger sync: award disposition (winner/state/holder) round-trips on the wire", function()
    local w = makeWorld("Masterlooter", true)
    local lot = { id = "L:1", itemId = 40005, state = "resolved", count = 1, responses = {},
        awards = {
            { winner = "bob",         state = "owed",     holder = "masterlooter" },
            { winner = "masterlooter", state = "resolved", holder = "masterlooter" },
        } }
    local back = w.addon:DecodeLotValue(w.addon:BuildLotValue(lot))
    check(back.awards and #back.awards == 2, "both awards survived")
    eq(back.awards[1].winner, "bob", "owed winner preserved")
    eq(back.awards[1].state, "owed", "owed state preserved")
    eq(back.awards[1].holder, "masterlooter", "holder preserved")
    eq(back.awards[2].state, "resolved", "self-win state preserved")
end)

-- A held/owed copy lives in the HOLDER's bags, so it must only count toward that ML's bag reconcile.
test("ledger: holder-aware live count excludes a previous ML's held copy", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Masterlooter", "ms")   -- the ML wins his own roll (self-win)
    w.addon:ResolveLiveRoll(lot.id)
    eq(w.addon.lootCore:liveCountForItem(40005), 1, "held by the resolving ML: counts")
    w.addon.lootCore:SetML("Someoneelse")
    eq(w.addon.lootCore:liveCountForItem(40005), 0, "after the ML changes, the old ML's held copy no longer counts")
end)

-- The Crimson Steel bug, end to end. A self-wins an item (resolved, held by A). B mirrors it (with
-- holder=A on the wire), becomes ML, and loots a FRESH copy of the same item. Pre-fix, A's inherited
-- self-won copy counted as live for B, so want(1)==live(1) and the drop was masked -- never rolled.
-- Holder-aware live count means A's copy (holder != B) does not count, so the fresh drop surfaces.
test("handoff: a previous ML's self-won item does not mask the new ML's fresh drop", function()
    local A = makeWorld("Masterlooter", true)
    local B = makeWorld("Promotee", false)

    startSession(A)
    setBag(A, 40005, 1); bagUpdate(A)
    local won = openLot(A, 40005)
    A.addon:StartLiveRoll(won.id)
    A.addon:RegisterInterest(won.id, "Masterlooter", "ms")   -- A wins his own loot
    A.addon:ResolveLiveRoll(won.id)
    eq(A.addon.lootCore:State(won.id), "resolved", "A self-won and resolved the item")
    A.addon:AutoBroadcastSession(true)                       -- full snapshot carries the disposition

    flushWireTo(B, "Masterlooter")
    local mirror = B.addon.lootCore:Get(won.id)
    check(mirror and mirror.awards and mirror.awards[1].holder, "B's mirror carries the award holder")

    -- B becomes loot master and continues the session.
    B.addon.roster.isLootMaster = true
    B.addon.roster.lootMasterName = "Promotee"
    B.addon.lootCore:SetML("Promotee")
    B.addon:AssumeLootMasterSession()

    -- B loots a fresh copy of the same item.
    setBag(B, 40005, 1); bagUpdate(B)
    local fresh
    for _, l in ipairs(B.addon.lootCore:lotsForItem(40005)) do
        if l.id ~= won.id and not l.removed then fresh = l end
    end
    check(fresh ~= nil, "B's fresh drop minted a NEW lot (not masked by A's inherited copy)")
    check(fresh and (fresh.state == "pending" or fresh.state == "rolling"), "the fresh drop surfaced for rolling")
    check(B.addon.lootCore:Get(won.id) ~= nil, "A's resolved lot is still kept as the loot log")
end)


-- ===========================================================================
-- ORCHESTRATOR: run the unit suites, then report the whole battery.
--
-- The unit suites (tests/unit_*.lua) are self-contained and each calls F.report on its own.
-- This file's own tests ran inline above; their pass/fail counts are already folded into F.
-- The final summary below totals everything.
-- ===========================================================================
local suites = { "tests/unit_util.lua", "tests/unit_config.lua", "tests/unit_guildroster.lua", "tests/unit_lootcore.lua", "tests/unit_resolver.lua", "tests/unit_iteminfo.lua", "tests/unit_preset_registry.lua", "tests/unit_bagslots.lua", "tests/unit_itemfilter.lua", "tests/unit_toc.lua", "tests/unit_perchar.lua", "tests/unit_debug.lua", "tests/unit_upcomingrolls.lua", "tests/unit_uiload.lua", "tests/unit_bannerlifetime.lua", "tests/unit_phantom.lua", "tests/unit_mlloan.lua" }
for _, path in ipairs(suites) do
    print(string.format("\n--- running %s ---", path))
    local ok, err = pcall(dofile, path)
    if not ok then
        print("ERROR loading " .. path .. ": " .. tostring(err))
        F.fail = F.fail + 1
        F.failures[#F.failures + 1] = path .. ": " .. tostring(err)
    end
end

print("")
print(string.format("=== WeirdLoot battery: %d passed, %d failed ===", F.pass, F.fail))
if F.fail > 0 then
    print("FAILURES:")
    for _, f in ipairs(F.failures) do print("  - " .. f) end
    os.exit(1)
end
