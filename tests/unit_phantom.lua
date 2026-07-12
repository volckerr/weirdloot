-- Unit tests for PHANTOM lots (LootCore:MintPhantom + Loot/LootObserver.lua): items the ML can
-- never hold -- a pure-Unique already in their bags (visible on the corpse but the self-assign
-- no-ops) or a quest-gated drop they cannot see at all. Pins:
--   * a phantom is invisible to ALL bag-truth accounting: empty bags never retire it, a real bag
--     copy of the same item mints its own lot (never merges), retiring real copies never touches
--     phantom awards, and the trade delivery path (MarkDeliveredFor) never consumes a phantom owe;
--   * a phantom resolve creates NO payout owe and NO owed-loot indicator (the copy goes
--     corpse-to-winner via master loot, not by trade);
--   * the phantom flag rides the wire (raider mirrors agree it is not owed-tradeable);
--   * the observer skips AutoLoot's doomed self-assign for a held pure-Unique, warns ONCE per
--     corpse, and mints the phantom; a missing guaranteed quest drop warns once per corpse;
--   * after the roll, re-opening the corpse auto-assigns the copy to the winner and the cleared
--     slot records the delivery + whispers the winner (sent DIRECTLY, not come-trade-me).
--
-- Run from the addon dir:  luajit tests/unit_phantom.lua

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("phantom lots + loot observer battery")

local makeWorld, startSession, setBag, bagUpdate = F.makeWorld, F.startSession, F.setBag, F.bagUpdate
local lotsFor, openLot, owedCount = F.lotsFor, F.openLot, F.owedCount
local flushWireTo, clearWire, linkFor = F.flushWireTo, F.clearWire, F.linkFor

local UNIQUE_ID = 44444
-- Sapphiron: base creature entry 15989 (0x003E75) in a 3.3.5 corpse GUID; guidNpcId reads sub(8,12)
local SAPH_GUID = "0xF130003E750001A2"
local OTHER_GUID = "0xF1300012340009F9"   -- entry 0x1234: not in the quest-drop map

-- ---------------------------------------------------------------------------
-- core: bag-truth isolation
-- ---------------------------------------------------------------------------

H.test("MintPhantom: fresh NEW lot, count 1, deduped while open", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local core = w.addon.lootCore
    local lot = core:MintPhantom(UNIQUE_ID, 1)
    H.check(lot ~= nil and lot.phantom == true, "minted with the phantom flag")
    H.eq(lot.state, core.STATE.NEW, "phantom mints fresh (auto-surfaces like a real drop)")
    H.eq(lot.count, 1, "one copy")
    local again = core:MintPhantom(UNIQUE_ID, 1)
    H.eq(again.id, lot.id, "re-detection returns the open phantom, no duplicate lot")
end)

H.test("empty bags never retire a phantom (reconcile + drain-to-zero immune)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local core = w.addon.lootCore
    local lot = core:MintPhantom(UNIQUE_ID, 1)
    bagUpdate(w)                                   -- full reconcile against bags that lack the item
    local kept = core:Get(lot.id)
    H.check(kept and not kept.removed and kept.count == 1, "phantom survives a bag reconcile untouched")
end)

H.test("a real bag copy of the same item mints its OWN lot; phantom neither absorbs nor masks", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local core = w.addon.lootCore
    local phantom = core:MintPhantom(UNIQUE_ID, 1)
    setBag(w, UNIQUE_ID, 1); bagUpdate(w)
    local real = openLot(w, UNIQUE_ID)             -- openLotForItem is bag-backed-only by contract
    H.check(real ~= nil and real.id ~= phantom.id, "bag copy got a separate non-phantom lot")
    H.check(not real.phantom, "the bag-backed lot is not phantom")
    H.eq(#lotsFor(w, UNIQUE_ID), 2, "two lots coexist for the item")
    H.eq(core:Get(phantom.id).count, 1, "phantom count untouched by the bag mint")
end)

H.test("retiring real copies never touches phantom awards", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local core = w.addon.lootCore
    local phantom = core:MintPhantom(UNIQUE_ID, 1)
    w.addon:StartLiveRoll(phantom.id)
    w.addon:RegisterInterest(phantom.id, "Gorgarg", "ms")
    w.addon:ResolveLiveRoll(phantom.id)
    setBag(w, UNIQUE_ID, 1); bagUpdate(w)          -- real copy arrives...
    setBag(w, UNIQUE_ID, 0); bagUpdate(w)          -- ...and leaves the bags again
    local a = core:Get(phantom.id).awards[1]
    H.eq(a.state, core.AWARD.OWED, "phantom award still owed after the real copy retired")
end)

-- ---------------------------------------------------------------------------
-- core: resolve semantics + payout / owed indicators / trade path
-- ---------------------------------------------------------------------------

-- resolve a phantom to a non-ML winner through the real live-roll flow
local function resolvePhantomTo(w, itemId, winner)
    local lot = w.addon.lootCore:MintPhantom(itemId, 1)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, winner, "ms")
    w.addon:ResolveLiveRoll(lot.id)
    return lot.id
end

H.test("phantom resolve: award owed to the winner with NO holder, and NO payout owe", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local core = w.addon.lootCore
    local lotId = resolvePhantomTo(w, UNIQUE_ID, "Gorgarg")
    local a = core:Get(lotId).awards[1]
    H.eq(a.state, core.AWARD.OWED, "winner's copy is owed (awaiting the corpse send)")
    H.eq(a.winner, "Gorgarg", "winner recorded")
    H.eq(a.holder, nil, "no holder: the copy sits on the corpse, not in the ML's bags")
    H.eq(owedCount(w), 0, "payout owes nothing (no come-trade whisper/delivery)")
    H.eq(core:OwedCountFor("Gorgarg"), 0, "no owed-loot indicator for a corpse-sent copy")
    H.check(w.addon.phantomSends and w.addon.phantomSends[lotId] ~= nil, "pending send registered at resolve")
    H.eq(w.addon.phantomSends[lotId].target, "Gorgarg", "send targets the roll winner")
end)

H.test("trade delivery (MarkDeliveredFor) consumes the REAL owe, never the phantom's", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local core = w.addon.lootCore
    local phantomId = resolvePhantomTo(w, UNIQUE_ID, "Gorgarg")
    local realId = F.resolveOwedTo(w, UNIQUE_ID, "Gorgarg")   -- bag-backed copy owed to the same player
    H.check(core:MarkDeliveredFor("Gorgarg", UNIQUE_ID), "trade delivery report lands")
    H.eq(core:Get(realId).awards[1].state, core.AWARD.DELIVERED, "the real award delivered")
    H.eq(core:Get(phantomId).awards[1].state, core.AWARD.OWED, "the phantom award untouched by the trade")
end)

H.test("the phantom flag rides the wire: a synced raider shows no owed indicator for it", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Gorgarg", false)
    startSession(ml)
    local lotId = resolvePhantomTo(ml, UNIQUE_ID, "Gorgarg")
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(raider)
    local mirrored = raider.addon.lootCore:Get(lotId)
    H.check(mirrored ~= nil and mirrored.phantom == true, "raider's mirror carries the phantom flag")
    H.eq(raider.addon.lootCore:OwedCountFor("Gorgarg"), 0, "winner's client shows no come-trade-me owed loot")
end)

H.test("unlock + reroll works on a phantom", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local core = w.addon.lootCore
    local lotId = resolvePhantomTo(w, UNIQUE_ID, "Gorgarg")
    w.addon.phantomSends[lotId] = nil
    H.check(core:Unlock(lotId), "unlocks")
    H.eq(core:Get(lotId).count, 1, "count preserved for the reroll")
    w.addon:StartLiveRoll(lotId)
    H.eq(core:State(lotId), core.STATE.ROLLING, "rerolls")
end)

-- ---------------------------------------------------------------------------
-- observer: loot-window mocks
-- ---------------------------------------------------------------------------

-- Install a mock loot window into a world: slots = { {itemId=, bind=("bop"|"boe"|nil)}, ... },
-- corpseGuid on UnitGUID("target"), master-loot candidate list, and a GiveMasterLoot recorder.
-- Returns the recorder table.
local function mockLootWindow(w, slots, corpseGuid, candidates)
    local env = w.env
    env.UnitExists = function(unit) return unit == "target" and corpseGuid ~= nil end
    env.UnitIsDead = function(unit) return unit == "target" and corpseGuid ~= nil end
    env.UnitGUID = function(unit) if unit == "target" then return corpseGuid end return "Player-0" end
    env.UnitIsUnit = function() return true end
    env.GetInstanceDifficulty = function() return 1 end
    env.GetNumLootItems = function() return #slots end
    env.LootSlotIsItem = function(slot) return slots[slot] ~= nil end
    env.GetLootSlotLink = function(slot) return slots[slot] and linkFor(slots[slot].itemId) end
    env.GetLootSlotInfo = function(slot)
        local s = slots[slot]
        return "icon", "name", 1, (s and s.quality) or 4
    end
    env.GetMasterLootCandidate = function(i) return (candidates or {})[i] end
    local given = {}
    env.GiveMasterLoot = function(slot, idx) given[#given + 1] = { slot = slot, idx = idx } end
    -- bind type normally comes from a live tooltip scan; feed it from the slot spec instead
    w.addon.LootSlotBindType = function(self, slot) return slots[slot] and slots[slot].bind end
    return given
end

-- capture firm alerts instead of asserting on chat output
local function captureAlerts(w)
    local alerts = {}
    w.addon.LootAlert = function(self, text) alerts[#alerts + 1] = text end
    return alerts
end

H.test("blocked unique: self-assign skipped, phantom minted, warned once per corpse", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local alerts = captureAlerts(w)
    -- the ML already holds this pure-Unique
    w.addon.PlayerHoldsItem = function(self, id) return id == UNIQUE_ID end
    w.addon.IsItemPureUnique = function(self, id) return id == UNIQUE_ID end
    local given = mockLootWindow(w, { { itemId = UNIQUE_ID, bind = "bop" } }, OTHER_GUID, { "Masterlooter" })

    w.addon:LOOT_OPENED()
    H.eq(#given, 0, "the doomed GiveMasterLoot-to-self never fires")
    local phantom = w.addon.lootCore:openPhantomLotForItem(UNIQUE_ID)
    H.check(phantom ~= nil, "phantom lot minted for the blocked unique")
    H.eq(#alerts, 1, "warned exactly once")

    w.addon:LOOT_OPENED()                          -- ML re-opens the same corpse
    H.eq(#alerts, 1, "no re-warn on the same corpse")
    H.eq(#lotsFor(w, UNIQUE_ID), 1, "no duplicate phantom on re-open")
end)

H.test("unblocked BoP still self-assigns (the skip is unique-specific)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.PlayerHoldsItem = function() return false end
    local given = mockLootWindow(w, { { itemId = 50001, bind = "bop" } }, OTHER_GUID, { "Masterlooter" })
    w.addon:LOOT_OPENED()
    H.eq(#given, 1, "BoP routed to the ML as before")
end)

H.test("missing guaranteed quest drop (Sapphiron, no key): firm warning once per corpse", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local alerts = captureAlerts(w)
    mockLootWindow(w, { { itemId = 50002, bind = "boe", quality = 4 } }, SAPH_GUID, { "Masterlooter" })
    w.addon:LOOT_OPENED()
    H.eq(#alerts, 1, "warned: the 100%-drop key is absent from the ML's loot")
    H.check(alerts[1] and alerts[1]:find("Focusing Iris", 1, true) ~= nil, "warning names the item")
    w.addon:LOOT_OPENED()
    H.eq(#alerts, 1, "same corpse never re-warns")
end)

H.test("quest drop present (or unknown mob): no warning", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local alerts = captureAlerts(w)
    w.addon.PlayerHoldsItem = function() return false end
    mockLootWindow(w, { { itemId = 44569, bind = "bop" } }, SAPH_GUID, { "Masterlooter" })
    w.addon:LOOT_OPENED()
    H.eq(#alerts, 0, "key visible in the loot: nothing to warn about")

    local w2 = makeWorld("Masterlooter", true)
    startSession(w2)
    local alerts2 = captureAlerts(w2)
    mockLootWindow(w2, { { itemId = 50003, bind = "boe", quality = 4 } }, OTHER_GUID, { "Masterlooter" })
    w2.addon:LOOT_OPENED()
    H.eq(#alerts2, 0, "unmapped mob: no warning")
end)

H.test("resolved phantom: re-opening the corpse assigns to the winner, records + whispers on clear", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    captureAlerts(w)
    local core = w.addon.lootCore
    w.addon.PlayerHoldsItem = function(self, id) return id == UNIQUE_ID end
    w.addon.IsItemPureUnique = function(self, id) return id == UNIQUE_ID end
    local whispers = {}
    w.env.ChatThrottleLib = nil
    w.env.SendChatMessage = function(msg, kind, _, target) whispers[#whispers + 1] = { msg = msg, target = target } end

    local given = mockLootWindow(w, { { itemId = UNIQUE_ID, bind = "bop" } }, OTHER_GUID, { "Masterlooter", "Gorgarg" })
    w.addon:LOOT_OPENED()                                     -- detect + mint
    w.addon:LOOT_CLOSED()                                     -- ML walks away while the roll runs
    local lot = core:openPhantomLotForItem(UNIQUE_ID)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    H.check(w.addon.phantomSends[lot.id] ~= nil, "send pending after resolve")

    w.addon:LOOT_OPENED()                                     -- ML re-opens the corpse
    H.eq(#given, 1, "exactly one assign fired")
    H.eq(given[1].idx, 2, "assigned to the winner's candidate index")

    w.addon:LOOT_SLOT_CLEARED(given[1].slot)                  -- server confirms
    H.eq(core:Get(lot.id).awards[1].state, core.AWARD.DELIVERED, "delivery recorded on the phantom award")
    H.eq(core:Get(lot.id).awards[1].recipient, "Gorgarg", "actual recipient recorded")
    H.eq(w.addon.phantomSends[lot.id], nil, "pending send cleared")
    H.eq(#whispers, 1, "winner whispered once")
    H.check(whispers[1].target == "Gorgarg" and whispers[1].msg:find("master%-looted") ~= nil,
        "whisper says the item went to them directly")
end)

H.test("winner not a candidate at the corpse: no assign, send stays pending for a retarget", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    captureAlerts(w)
    local core = w.addon.lootCore
    w.addon.PlayerHoldsItem = function(self, id) return id == UNIQUE_ID end
    w.addon.IsItemPureUnique = function(self, id) return id == UNIQUE_ID end
    local given = mockLootWindow(w, { { itemId = UNIQUE_ID, bind = "bop" } }, OTHER_GUID, { "Masterlooter" })
    w.addon:LOOT_OPENED()
    local lot = core:openPhantomLotForItem(UNIQUE_ID)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    w.addon:ResolveLiveRoll(lot.id)

    w.addon:LOOT_OPENED()
    H.eq(#given, 0, "no assign to an absent candidate")
    H.check(w.addon.phantomSends[lot.id] ~= nil, "send still pending")

    -- retarget from the card's flyout to someone who IS a candidate, window still open
    w.env.GetMasterLootCandidate = function(i) return ({ "Masterlooter", "Lexissa" })[i] end
    w.addon:SetPhantomSendTarget(lot.id, "Lexissa")
    H.eq(#given, 1, "retarget assigns immediately while the window is open")
    H.eq(given[1].idx, 2, "assigned to the new target")
end)

F.endSuite()
