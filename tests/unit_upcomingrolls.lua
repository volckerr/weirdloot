-- Unit tests for addon:CountUpcomingRolls (LiveRoll.lua): the "up to N more items left to roll" count.
-- The count is per-viewer: it walks the OPEN lots on the (replicated) ledger and drops the ones this
-- client's own roll filters would suppress, so it equals the number of roll cards this client will still
-- see. Pins: only open lots count (rolling/resolved excluded), the ML sees all, and a raider's
-- whitelist/blacklist and "hide rolls my class can't use" option each shrink its count -- computed from
-- the ledger the ML SYNCED to it, which is the whole point (no new wire traffic; raiders derive it).
--
-- Run from the addon dir:  luajit tests/unit_upcomingrolls.lua

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("upcoming-rolls count battery")

local makeWorld, startSession, setBag, bagUpdate = F.makeWorld, F.startSession, F.setBag, F.bagUpdate
local openLot, flushWireTo, clearWire = F.openLot, F.flushWireTo, F.clearWire

-- Mint `ids` as open (pending) lots on an ML, then broadcast the ledger to a fresh raider whose roll
-- filters all start off. Returns (raider, raiderOptions, ml). The raider's count is then derived from
-- the synced ledger, exactly as in-game.
local function syncedRaider(ids)
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raider", false)
    local ropt = raider.addon.db.options
    ropt.hideUnusableRolls = false; ropt.whitelistEnabled = false; ropt.blacklistEnabled = false
    startSession(ml)
    for _, id in ipairs(ids) do setBag(ml, id, 1) end
    bagUpdate(ml)
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(raider)
    return raider, ropt, ml
end

H.test("a synced raider counts every open lot when no filter is active", function()
    local raider = syncedRaider({ 40001, 40002, 40003 })
    H.eq(raider.addon:CountUpcomingRolls(), 3, "three synced pending lots -> 3")
end)

H.test("only open lots count: rolling and resolved are excluded (ML view)", function()
    local w = makeWorld("Masterlooter", true)   -- ML: no filter in play, isolate the state gate
    startSession(w)
    setBag(w, 40001, 1); setBag(w, 40002, 1); setBag(w, 40003, 1); bagUpdate(w)
    H.eq(w.addon:CountUpcomingRolls(), 3, "all three still to roll")

    local lot1 = openLot(w, 40001)
    w.addon:StartLiveRoll(lot1.id)              -- 40001 -> ROLLING (here now, not "more coming")
    H.eq(w.addon:CountUpcomingRolls(), 2, "a rolling lot is no longer upcoming")

    local lot2 = openLot(w, 40002)
    w.addon:StartLiveRoll(lot2.id)
    w.addon:RegisterInterest(lot2.id, "Bob", "ms")
    w.addon:ResolveLiveRoll(lot2.id)            -- 40002 -> RESOLVED
    H.eq(w.addon:CountUpcomingRolls(), 1, "a resolved lot is excluded; only 40003 remains")
end)

H.test("idle background loot is not counted (baselined / re-derived-on-reload)", function()
    -- Idle is loot that is listed but never auto-surfaced: baselined at session start, or a copy the
    -- bag scan re-derives on reload (e.g. an item the raid already rolled and passed on, still in the
    -- ML's bags). It is not a roll still owed, so it must not inflate the count.
    local w = makeWorld("Masterlooter", true)
    setBag(w, 40001, 1)          -- already carried before the session begins...
    startSession(w)              -- ...so it baselines as IDLE, not a fresh pending drop
    local lot = openLot(w, 40001)
    H.eq(lot and lot.state, "idle", "precondition: the pre-existing item is idle")
    H.eq(w.addon:CountUpcomingRolls(), 0, "idle background loot is not counted")
end)

H.test("raider blacklist drops the listed item from the count", function()
    local raider, opt = syncedRaider({ 40001, 40002, 40003 })
    opt.blacklistEnabled = true
    raider.addon:SetItemFilterText("blacklist", "Mantle of Test")   -- 40001
    H.eq(raider.addon:CountUpcomingRolls(), 2, "blacklisted item not counted")
end)

H.test("raider whitelist counts only whitelisted items", function()
    local raider, opt = syncedRaider({ 40001, 40002, 40003 })
    opt.whitelistEnabled = true
    raider.addon:SetItemFilterText("whitelist", "Helm of Test")     -- only 40002
    H.eq(raider.addon:CountUpcomingRolls(), 1, "only the whitelisted item counts")
end)

H.test("the loot master's count ignores its own filters (it sees every roll)", function()
    local ml = makeWorld("Masterlooter", true)
    ml.addon.db.options.blacklistEnabled = true
    ml.addon:SetItemFilterText("blacklist", "Mantle of Test")
    startSession(ml)
    setBag(ml, 40001, 1); setBag(ml, 40002, 1); setBag(ml, 40003, 1); bagUpdate(ml)
    H.eq(ml.addon:CountUpcomingRolls(), 3, "ML is never suppressed, so all three count")
end)

H.test("hideUnusableRolls excludes unusable items only when the option is on", function()
    local raider, opt = syncedRaider({ 40001, 40005 })   -- one usable, one to be made plate
    F.setClass(raider, "MAGE", "Mage")   -- cloth-only
    -- The raider evaluates usability with ITS OWN GetItemInfo; make 40005 a plate chest a mage can never
    -- equip, leaving the others as the default cloth shoulder.
    local origGII = raider.env.GetItemInfo
    raider.env.GetItemInfo = function(x)
        local id = tonumber(x) or tonumber(string.match(tostring(x), "item:(%d+)"))
        if id == 40005 then
            return "Blade of Test", F.linkFor(40005), 4, 200, 80, "Armor", "Plate", 1, "INVTYPE_CHEST", "tex", 0
        end
        return origGII(x)
    end

    opt.hideUnusableRolls = false
    H.eq(raider.addon:CountUpcomingRolls(), 2, "option off: the plate item still counts")
    opt.hideUnusableRolls = true
    H.eq(raider.addon:CountUpcomingRolls(), 1, "option on: the plate item is excluded for a mage")

    raider.env.GetItemInfo = origGII
end)

H.test("no session / empty ledger counts zero", function()
    local w = makeWorld("Raider", false)
    H.eq(w.addon:CountUpcomingRolls(), 0, "nothing to roll -> 0")
end)

F.endSuite()
