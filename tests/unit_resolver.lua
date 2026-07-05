-- Unit tests for addon:FilterByStatus and addon:RollCandidates (Resolver.lua).
-- The full resolver integration flows are exercised by tests/integration_session.lua; this file
-- focuses on the small pure helpers that other code relies on for status/roll routing.
--
-- Run from the addon dir:  luajit tests/unit_resolver.lua
-- (or just `luajit tests/run.lua` to run the whole battery).

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("resolver unit battery")

-- Framework helpers under bare names so the integration flows (moved here from run.lua) read cleanly.
local makeWorld, setBag, bagUpdate, startSession, openLot = H.makeWorld, H.setBag, H.bagUpdate, H.startSession, H.openLot
local test, eq, check = H.test, H.eq, H.check

H.test("FilterByStatus: BiS mode keeps only the highest-status candidates", function()
    local w = H.makeWorld("Masterlooter", true)
    local cands = {
        { name = "Alice", status = "main" },
        { name = "Bob",   status = "designatedalt" },
        { name = "Carol", status = "nil" },
    }
    local out, highest = w.addon:FilterByStatus(cands, false)
    H.eq(#out, 1, "BiS mode keeps only Mains")
    H.eq(out[1].name, "Alice", "Alice kept")
    H.eq(highest, 3, "highest actual is Main=3")
end)

H.test("FilterByStatus: non-BiS mode merges Main + DesAlt into one effective rank", function()
    local w = H.makeWorld("Masterlooter", true)
    local cands = {
        { name = "Alice", status = "main" },
        { name = "Bob",   status = "designatedalt" },
        { name = "Carol", status = "nil" },
    }
    local out, highest = w.addon:FilterByStatus(cands, true)
    -- Effective rank: Alice=2, Bob=2 (main collapsed to 2 when mergeMainAndAlt=true), Carol=1
    H.eq(#out, 2, "non-BiS keeps Main+DesAlt")
    H.eq(highest, 3, "highestActual still reports Alice's real status (main=3)")
    -- And the nil player (Carol) is dropped
    local kept = {}
    for _, c in ipairs(out) do kept[c.name] = true end
    H.truthy(kept.Alice, "Alice kept")
    H.truthy(kept.Bob,   "Bob kept")
    H.check(not kept.Carol, "Carol dropped (nil status)")
end)

H.test("FilterByStatus: unknown IS a main at resolution time", function()
    local w = H.makeWorld("Masterlooter", true)
    local cands = {
        { name = "Alice",  status = "main" },
        { name = "Mystery", status = "unknown" },   -- unmapped rank / off-roster guest
        { name = "Bob",    status = "designatedalt" },
        { name = "Carol",  status = "nil" },
    }
    local out, highest = w.addon:FilterByStatus(cands, false)
    local kept = {}
    for _, c in ipairs(out) do kept[c.name] = true end
    H.eq(#out, 2, "BiS mode keeps mains AND unknowns")
    H.truthy(kept.Alice, "main kept")
    H.truthy(kept.Mystery, "unknown competes as a main, not below")
    H.eq(highest, 3, "tier reported as Main")

    out = w.addon:FilterByStatus(cands, true)
    kept = {}
    for _, c in ipairs(out) do kept[c.name] = true end
    H.eq(#out, 3, "non-BiS merge keeps main+unknown+dalt")
    H.truthy(kept.Mystery, "unknown merged exactly like a main")
    H.check(not kept.Carol, "Alt tier still drops")
end)

H.test("FilterByStatus: empty input returns empty", function()
    local w = H.makeWorld("Masterlooter", true)
    local out, highest = w.addon:FilterByStatus({}, false)
    H.eq(#out, 0, "empty input -> empty output")
    H.eq(highest, 0, "highest defaults to 0 on empty")
end)

H.test("RollCandidates: rolls come from rollAssignments when present", function()
    local w = H.makeWorld("Masterlooter", true)
    local cands = { { name = "Alice" }, { name = "Bob" } }
    local rolls = w.addon:RollCandidates(cands, {
        alice = { name = "Alice", roll = 95 },
        bob   = { name = "Bob",   roll = 50 },
    })
    H.eq(#rolls, 2, "two rolls")
    -- Sorted descending: Alice (95) first, Bob (50) second
    H.eq(rolls[1].name, "Alice", "highest roll first")
    H.eq(rolls[1].roll, 95, "roll preserved")
    H.eq(rolls[2].roll, 50, "second roll preserved")
end)

H.test("RollCandidates: ties broken by lowercase name", function()
    local w = H.makeWorld("Masterlooter", true)
    local cands = { { name = "Bob" }, { name = "alice" } }
    local rolls = w.addon:RollCandidates(cands, {
        bob   = { name = "Bob",   roll = 50 },
        alice = { name = "alice", roll = 50 },
    })
    H.eq(rolls[1].name, "alice", "tie: lowercase 'alice' beats 'Bob'")
end)


-- ===========================================================================
-- Resolver: response tier / status tier / spec tier priority and fall-through.
-- ===========================================================================
-- Per-test resolver setup: stage roster status/spec per player, force deterministic rolls,
-- start a roll on a fresh lot, return (world, lot). Profiles are keyed by lowercase name and
-- declared in the form { className=, specName=, status= }. Status values: "main" /
-- "designatedalt" / anything else (treated as nil).
local function setupResolver(itemId, count, profiles, rolls)
    local w = makeWorld("Masterlooter", true)
    w.addon.GetRosterProfile = function(_, name)
        local key = w.addon.util:NormalizeKey(name or "")
        local p = profiles and profiles[key]
        if not p then
            return { name = name, className = "", specName = "", status = "nil" }
        end
        local displayName = (tostring(name):gsub("^%l", string.upper))
        return {
            name = displayName,
            className = p.className or "Warrior",
            specName = p.specName or "Arms",
            status = p.status or "main",
        }
    end
    w.addon.GetAttendee = w.addon.GetRosterProfile
    -- Pre-seeded roll table makes "winners" assertions order-stable. Falling back to 50 means a
    -- name absent from the table still rolls something deterministic.
    w.addon.RollCandidates = function(self, candidates)
        local out = {}
        for _, c in ipairs(candidates) do
            local key = self.util:NormalizeKey(c.name)
            out[#out + 1] = { name = c.name, roll = (rolls and rolls[key]) or 50, auto = false }
        end
        table.sort(out, function(a, b)
            if a.roll == b.roll then return string.lower(a.name) < string.lower(b.name) end
            return a.roll > b.roll
        end)
        return out
    end
    startSession(w)
    setBag(w, itemId, count); bagUpdate(w)
    local lot = openLot(w, itemId)
    w.addon:StartLiveRoll(lot.id)
    return w, lot
end

local function resolveWith(w, lot, registrations)
    for _, r in ipairs(registrations) do
        w.addon:RegisterInterest(lot.id, r[1], r[2])
    end
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    local winners = {}
    for _, a in ipairs(L.awards or {}) do
        winners[#winners + 1] = a.winner
    end
    return winners
end

test("resolver: 1x BiS, Main beats DesAlt regardless of roll", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "designatedalt" },
    }
    -- Bob outrolls Alice on the dice -- but Main outranks DesAlt for BiS, so Alice wins.
    local rolls = { alice = 10, bob = 99 }
    local w, lot = setupResolver(40005, 1, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "bis" }, { "Bob", "bis" } })
    eq(#winners, 1, "one award")
    eq(winners[1], "Alice", "Main wins BiS over DesAlt")
end)

test("resolver: 2x BiS, Main + DesAlt -> Main wins copy 1, DesAlt wins copy 2", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "designatedalt" },
    }
    -- Bob's higher roll doesn't help him in copy 1 (Main priority) but he still claims copy 2.
    local rolls = { alice = 10, bob = 99 }
    local w, lot = setupResolver(40004, 2, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "bis" }, { "Bob", "bis" } })
    eq(#winners, 2, "two awards")
    eq(winners[1], "Alice", "Main wins the first BiS copy")
    eq(winners[2], "Bob", "DesAlt falls through to the second copy")
end)

test("resolver: 3x BiS, Main + DesAlt + nil -> three winners in priority order", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "designatedalt" },
        carol = { status = "nil" },
    }
    -- Carol rolls highest, Bob second, Alice last -- the status tier ordering must dominate.
    local rolls = { alice = 10, bob = 50, carol = 99 }
    local w, lot = setupResolver(40004, 3, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "bis" }, { "Bob", "bis" }, { "Carol", "bis" } })
    eq(#winners, 3, "three awards")
    eq(winners[1], "Alice", "Main wins copy 1")
    eq(winners[2], "Bob", "DesAlt wins copy 2")
    eq(winners[3], "Carol", "nil-status wins copy 3")
end)

test("resolver: 2x BiS, 2 Mains + 1 DesAlt -> both Mains win, DesAlt excluded", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "main" },
        carol = { status = "designatedalt" },
    }
    -- Carol's roll is the highest but DesAlts only fall through when Mains run out of copies.
    local rolls = { alice = 80, bob = 60, carol = 99 }
    local w, lot = setupResolver(40004, 2, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "bis" }, { "Bob", "bis" }, { "Carol", "bis" } })
    eq(#winners, 2, "two awards")
    -- Roll order within the Mains tier: Alice (80) > Bob (60).
    eq(winners[1], "Alice", "highest-rolling Main wins copy 1")
    eq(winners[2], "Bob", "second Main wins copy 2 -- DesAlt excluded while Mains remain")
end)

test("resolver: 1x MS, DesAlt with higher roll beats Main with lower roll", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "designatedalt" },
    }
    -- Outside BiS, Main and DesAlt compete on equal footing -- the higher roll wins.
    local rolls = { alice = 10, bob = 99 }
    local w, lot = setupResolver(40005, 1, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "ms" }, { "Bob", "ms" } })
    eq(#winners, 1, "one award")
    eq(winners[1], "Bob", "DesAlt wins MS on the higher roll")
end)

test("resolver: 1x MS, nil-status with higher roll loses to Main", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "nil" },
    }
    -- Even at equal-priority Main+DesAlt, a non-roster (nil) raider sits below them.
    local rolls = { alice = 10, bob = 99 }
    local w, lot = setupResolver(40005, 1, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "ms" }, { "Bob", "ms" } })
    eq(winners[1], "Alice", "nil-status loses to Main on MS even with the higher roll")
end)

test("resolver: 2x MS, Main + DesAlt + nil -> Main and DesAlt win, nil excluded", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "designatedalt" },
        carol = { status = "nil" },
    }
    -- Carol rolls highest but the two non-nil rollers fill both copies first.
    local rolls = { alice = 70, bob = 80, carol = 99 }
    local w, lot = setupResolver(40004, 2, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "ms" }, { "Bob", "ms" }, { "Carol", "ms" } })
    eq(#winners, 2, "two awards")
    -- Both have the same effective status rank for MS, so they're ordered by roll: Bob > Alice.
    eq(winners[1], "Bob", "highest-rolling Main/DesAlt wins copy 1")
    eq(winners[2], "Alice", "second-highest Main/DesAlt wins copy 2")
end)

test("resolver: 2x with MS + OS rollers -> MS wins copy 1, OS wins copy 2", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "main" },
    }
    local rolls = { alice = 50, bob = 99 }
    local w, lot = setupResolver(40004, 2, profiles, rolls)
    -- Bob's huge OS roll can't beat Alice's MS for copy 1, but he claims copy 2 instead of nobody.
    local winners = resolveWith(w, lot, { { "Alice", "ms" }, { "Bob", "os" } })
    eq(#winners, 2, "two awards")
    eq(winners[1], "Alice", "MS roller wins copy 1")
    eq(winners[2], "Bob", "OS roller falls through to copy 2")
end)

test("resolver: 1x with MS + OS rollers -> only MS wins", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "main" },
    }
    local rolls = { alice = 50, bob = 99 }
    local w, lot = setupResolver(40005, 1, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "ms" }, { "Bob", "os" } })
    eq(#winners, 1, "one award")
    eq(winners[1], "Alice", "MS wins; OS is not considered while MS rollers remain")
end)

test("resolver: 2x BiS DesAlt + MS Main -> BiS wins copy 1, MS wins copy 2", function()
    local profiles = {
        alice = { status = "designatedalt" },
        bob   = { status = "main" },
    }
    local rolls = { alice = 10, bob = 99 }
    local w, lot = setupResolver(40004, 2, profiles, rolls)
    -- Response tier dominates status: a BiS DesAlt still beats an MS Main for copy 1.
    local winners = resolveWith(w, lot, { { "Alice", "bis" }, { "Bob", "ms" } })
    eq(#winners, 2, "two awards")
    eq(winners[1], "Alice", "BiS DesAlt wins copy 1 over MS Main")
    eq(winners[2], "Bob", "MS Main claims copy 2")
end)

test("resolver: 2x BiS Main + MS Main -> BiS first, MS second", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "main" },
    }
    local rolls = { alice = 10, bob = 99 }
    local w, lot = setupResolver(40004, 2, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "bis" }, { "Bob", "ms" } })
    eq(winners[1], "Alice", "BiS wins copy 1 regardless of roll")
    eq(winners[2], "Bob", "MS wins copy 2")
end)

test("resolver: 1x BiS Main + 1x MS DesAlt with same roll -> BiS Main wins", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "designatedalt" },
    }
    local rolls = { alice = 50, bob = 50 }
    local w, lot = setupResolver(40005, 1, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "bis" }, { "Bob", "ms" } })
    eq(winners[1], "Alice", "BiS Main beats MS DesAlt on equal roll")
end)

test("resolver: 2x BiS, all rollers passed -> no winners", function()
    local profiles = { alice = { status = "main" } }
    local w, lot = setupResolver(40004, 2, profiles, {})
    -- Pass is filtered out entirely; the lot should resolve with no awarded winners.
    local winners = resolveWith(w, lot, { { "Alice", "pass" } })
    eq(#winners, 0, "no winners when every roller passed")
end)

test("resolver: 3x with BiS Main + MS DesAlt + OS nil -> all three tiers fall through", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "designatedalt" },
        carol = { status = "nil" },
    }
    local rolls = { alice = 30, bob = 60, carol = 90 }
    local w, lot = setupResolver(40004, 3, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "bis" }, { "Bob", "ms" }, { "Carol", "os" } })
    eq(#winners, 3, "three awards")
    eq(winners[1], "Alice", "BiS wins copy 1")
    eq(winners[2], "Bob", "MS wins copy 2")
    eq(winners[3], "Carol", "OS nil falls through to copy 3 only after MS exhausted")
end)

test("resolver: 2x MS, 2 DesAlts + 1 Main -> roll order across Main+DesAlt fills both copies", function()
    local profiles = {
        alice = { status = "main" },
        bob   = { status = "designatedalt" },
        carol = { status = "designatedalt" },
    }
    -- Main+DesAlt collapse to one bucket for MS, so roll order decides among the three.
    local rolls = { alice = 50, bob = 99, carol = 80 }
    local w, lot = setupResolver(40004, 2, profiles, rolls)
    local winners = resolveWith(w, lot, { { "Alice", "ms" }, { "Bob", "ms" }, { "Carol", "ms" } })
    eq(#winners, 2, "two awards")
    eq(winners[1], "Bob", "highest roll in merged Main+DesAlt bucket wins copy 1")
    eq(winners[2], "Carol", "second-highest roll wins copy 2")
end)


-- ---------------------------------------------------------------------------
-- Named-rule / Loot-Council, spec-priority, result-record integrity, and edges.
-- These call ResolveSessionItem directly (it RETURNS the result record) so we can assert on
-- winners / winnerDetails / winnersText / isLootCouncil, and stub the rules per test.
-- ---------------------------------------------------------------------------
local _u = makeWorld("Masterlooter", true).addon.util
local function nk(s) return _u:NormalizeKey(s) end

-- Named rule from tiers of tokens: a player name, "LC", or "rest".
local function namedRule(tiers)
    local rule = { tiers = {}, raw = "named" }
    for _, t in ipairs(tiers) do
        local entries = {}
        for _, tok in ipairs(t) do
            if tok == "LC" then entries[#entries + 1] = { isLootCouncil = true }
            elseif tok == "rest" then entries[#entries + 1] = { isRest = true }
            else entries[#entries + 1] = { playerKey = nk(tok) } end
        end
        rule.tiers[#rule.tiers + 1] = { entries = entries }
    end
    return rule
end

-- Spec (loot) rule from tiers of "class spec" match strings (or "rest").
local function lootRule(raw, tiers)
    local rule = { tiers = {}, raw = raw }
    for _, t in ipairs(tiers) do
        local entries = {}
        for _, tok in ipairs(t) do
            if tok == "rest" then entries[#entries + 1] = { isRest = true }
            else entries[#entries + 1] = { matchKeys = { nk(tok) } } end
        end
        rule.tiers[#rule.tiers + 1] = { entries = entries }
    end
    return rule
end

-- Resolve a hand-built lot directly and return the result record.
local function resolveDirect(opts)
    local w = makeWorld("Masterlooter", true)
    local util = w.addon.util
    w.addon.GetRosterProfile = function(_, name)
        local key = util:NormalizeKey(name or "")
        local p = opts.profiles and opts.profiles[key]
        local display = (tostring(name):gsub("^%l", string.upper))
        return {
            name = display,
            className = (p and p.className) or "Warrior",
            specName = (p and p.specName) or "Arms",
            status = (p and p.status) or "main",
        }
    end
    w.addon.GetAttendee = w.addon.GetRosterProfile
    w.addon.RollCandidates = function(self, cands)
        local out = {}
        for _, c in ipairs(cands) do
            local key = self.util:NormalizeKey(c.name)
            out[#out + 1] = { name = c.name, roll = (opts.rolls and opts.rolls[key]) or 50, auto = false }
        end
        table.sort(out, function(a, b)
            if a.roll == b.roll then return string.lower(a.name) < string.lower(b.name) end
            return a.roll > b.roll
        end)
        return out
    end
    w.addon.GetNamedRule = function() return opts.named end
    w.addon.GetLootRule = function() return opts.loot end
    w.addon.IsPlayerAllowedForItem = function(_, _, _, name)
        return not (opts.disallow and opts.disallow[util:NormalizeKey(name or "")])
    end
    local responses = {}
    for name, tier in pairs(opts.responses or {}) do
        responses[util:NormalizeKey(name)] = tier
    end
    local lot = { id = "L:1", itemId = opts.itemId or 40000, count = opts.count or 1, responses = responses }
    return w.addon:ResolveSessionItem(lot)
end

local function winnerNames(result)
    local names = {}
    for _, wd in ipairs(result.winnerDetails or {}) do names[#names + 1] = wd.name end
    return names
end

test("resolver: named player wins their bracket regardless of roll", function()
    local r = resolveDirect{
        itemId = 40010, count = 1,
        responses = { Alice = "ms", Bob = "ms" },
        profiles = { alice = { status = "main" }, bob = { status = "main" } },
        rolls = { alice = 1, bob = 99 },
        named = namedRule({ { "Alice" } }),
    }
    eq(winnerNames(r)[1], "Alice", "named Alice wins MS over higher-rolling Bob")
end)

test("resolver: LC-tier item resolves to Loot Council, no awarded winner", function()
    local r = resolveDirect{
        itemId = 40011, count = 1,
        responses = { Alice = "ms", Bob = "ms" },
        profiles = { alice = { status = "main" }, bob = { status = "main" } },
        named = namedRule({ { "LC" } }),
    }
    check(r.isLootCouncil, "resolves as Loot Council")
    eq(#r.winnerDetails, 0, "no awarded winners under LC")
    eq(r.winnersText, "Loot Council", "winnersText reads Loot Council")
end)

test("resolver: named tier 1 beats named tier 2", function()
    local r = resolveDirect{
        itemId = 40012, count = 1,
        responses = { Alice = "ms", Bob = "ms" },
        profiles = { alice = { status = "main" }, bob = { status = "main" } },
        rolls = { alice = 1, bob = 99 },
        named = namedRule({ { "Alice" }, { "Bob" } }),
    }
    eq(winnerNames(r)[1], "Alice", "tier-1 Alice beats tier-2 Bob despite lower roll")
end)

test("resolver: higher spec-priority tier wins over lower regardless of roll", function()
    local r = resolveDirect{
        itemId = 40013, count = 1,
        responses = { Alice = "ms", Bob = "ms" },
        profiles = {
            alice = { status = "main", className = "Warrior", specName = "Arms" },
            bob   = { status = "main", className = "Rogue", specName = "Combat" },
        },
        rolls = { alice = 1, bob = 99 },
        loot = lootRule("Warrior Arms > Rogue Combat", { { "warrior arms" }, { "rogue combat" } }),
    }
    eq(winnerNames(r)[1], "Alice", "Warrior Arms (tier 1) beats Rogue Combat (tier 2) despite lower roll")
end)

test("resolver: spec 'rest' tier catches players outside the named specs", function()
    local r = resolveDirect{
        itemId = 40014, count = 1,
        responses = { Alice = "ms", Bob = "ms" },
        profiles = {
            alice = { status = "main", className = "Mage", specName = "Fire" },
            bob   = { status = "main", className = "Warrior", specName = "Arms" },
        },
        rolls = { alice = 99, bob = 1 },
        loot = lootRule("Warrior Arms > rest", { { "warrior arms" }, { "rest" } }),
    }
    eq(winnerNames(r)[1], "Bob", "Warrior Arms (tier 1) wins over a rest-tier Mage despite lower roll")
end)

test("resolver: result record -- winners distinct, capped at quantity, winner=winners[1]", function()
    local r = resolveDirect{
        itemId = 40015, count = 2,
        responses = { Alice = "ms", Bob = "ms", Carol = "ms" },
        profiles = { alice = { status = "main" }, bob = { status = "main" }, carol = { status = "main" } },
        rolls = { alice = 90, bob = 80, carol = 70 },
    }
    eq(#r.winners, 2, "2x lot -> 2 winners")
    eq(r.winners[1], "Alice", "highest roll first")
    eq(r.winner, r.winners[1], "singular winner is winners[1]")
    local seen = {}
    for _, n in ipairs(r.winners) do check(not seen[n], "no duplicate winner: " .. n); seen[n] = true end
    eq(r.winnersText, "Alice, Bob", "winnersText joins the winners")
end)

test("resolver: quantity exceeding roller count -> only as many winners as rollers", function()
    local r = resolveDirect{
        itemId = 40016, count = 3,
        responses = { Alice = "ms", Bob = "ms" },
        profiles = { alice = { status = "main" }, bob = { status = "main" } },
        rolls = { alice = 50, bob = 40 },
    }
    eq(#r.winners, 2, "3x lot with 2 rollers -> 2 winners, no error")
end)

test("resolver: no responses -> no winner, clean record", function()
    local r = resolveDirect{ itemId = 40017, count = 1, responses = {} }
    eq(#r.winners, 0, "no rollers -> no winners")
    eq(r.winner, "No winner", "winner field reads 'No winner'")
    check(not r.isLootCouncil, "not an LC result")
end)

test("resolver: a passer is excluded; the active roller wins", function()
    local r = resolveDirect{
        itemId = 40018, count = 1,
        responses = { Alice = "pass", Bob = "ms" },
        profiles = { alice = { status = "main" }, bob = { status = "main" } },
        rolls = { alice = 99, bob = 1 },
    }
    eq(#r.winners, 1, "one winner")
    eq(r.winners[1], "Bob", "passer Alice excluded despite high roll; Bob wins")
end)

test("resolver: a class barred from the item is dropped from the rollers", function()
    local r = resolveDirect{
        itemId = 40019, count = 1,
        responses = { Alice = "ms", Bob = "ms" },
        profiles = { alice = { status = "main" }, bob = { status = "main" } },
        rolls = { alice = 99, bob = 1 },
        disallow = { alice = true },
    }
    eq(#r.winners, 1, "one winner")
    eq(r.winners[1], "Bob", "barred Alice excluded despite high roll")
end)

F.endSuite()
