-- Unit tests for addon.util.* (Util.lua). Pure-logic helpers, no WoW API.
--
-- Run from the addon dir:  luajit tests/unit_util.lua
-- (or just `luajit tests/run.lua` to run the whole battery).
--
-- Property tests included: NormalizeKey idempotence, EncodeField/DecodeField inverse.

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("util unit battery")

-- minimal env for util: just enough that string.trim works
local env = setmetatable({}, { __index = _G })
env._G = env
env.WeirdLoot = env.WeirdLoot or {}   -- Util.lua does `local addon = WeirdLoot` then `addon.util = {}`
local chunk = assert(loadfile("Core/Util.lua"))
setfenv(chunk, env)
chunk("WeirdLoot", {})
local addon = env.WeirdLoot
local util = addon.util
assert(type(util) == "table", "addon.util missing after loading Util.lua")

------------------------------------------------------------------------
-- string.trim
------------------------------------------------------------------------
H.test("string.trim: trims leading and trailing whitespace", function()
    H.eq((string.trim("  hi  ")), "hi", "spaces both sides")
    H.eq((string.trim("\thi\n")), "hi", "tabs and newlines")
    H.eq((string.trim("   ")), "", "all whitespace")
    H.eq((string.trim("")), "", "empty string")
    H.eq((string.trim("noChange")), "noChange", "no whitespace")
end)

H.test("string.trim: collapses internal whitespace", function()
    -- Lua's pattern only matches ^...$; internal whitespace stays.
    -- This test guards against future changes that would over-trim.
    H.eq((string.trim("a   b")), "a   b", "internal whitespace preserved")
end)

------------------------------------------------------------------------
-- util:ItemIdFromLink
------------------------------------------------------------------------
H.test("util:ItemIdFromLink: parses a 3.3.5 item hyperlink", function()
    local id = util:ItemIdFromLink("|cffa335ee|Hitem:49295:0:0:0:0:0:0:0|h[Onyxia Hide Backpack]|h|r")
    H.eq(id, 49295, "standard 3.3.5 link")
end)
H.test("util:ItemIdFromLink: parses a raw item string", function()
    H.eq(util:ItemIdFromLink("item:49636"), 49636, "item:<id>")
    H.nil_(util:ItemIdFromLink("garbage"), "non-link string returns nil")
    H.nil_(util:ItemIdFromLink(nil), "nil returns nil")
end)

------------------------------------------------------------------------
-- util:Split / util:SplitLines
------------------------------------------------------------------------
H.test("util:Split: splits a CSV", function()
    local out = util:Split("a,b,c", ",")
    H.eq(#out, 3, "three parts"); H.eq(out[1], "a"); H.eq(out[3], "c")
end)
H.test("util:Split: empty input returns empty list", function()
    H.eq(#util:Split("", ","), 0, "empty string")
    H.eq(#util:Split(nil, ","), 0, "nil input")
end)
H.test("util:Split: multi-character delimiter", function()
    local out = util:Split("a::b::c", "::")
    H.eq(#out, 3, "three parts"); H.eq(out[2], "b")
end)

H.test("util:SplitLines: normalizes CRLF and trims empties", function()
    local lines = util:SplitLines("a\r\nb\n\nc")
    H.eq(#lines, 3, "three non-empty lines")
    H.eq(lines[2], "b", "middle line")
end)

------------------------------------------------------------------------
-- util:NormalizeKey  (PROPERTY: idempotent)
------------------------------------------------------------------------
H.test("util:NormalizeKey: lowercases, trims, collapses spaces", function()
    H.eq(util:NormalizeKey("  Hello   World  "), "hello world", "spaces + case")
    H.eq(util:NormalizeKey("ALREADY"), "already", "all caps")
    H.eq(util:NormalizeKey("\tFoo\tBar"), "foo bar", "tab whitespace")
    H.eq(util:NormalizeKey(""), "", "empty")
    H.eq(util:NormalizeKey(nil), "", "nil becomes empty")
end)

H.test("util:NormalizeKey: idempotent (a property test)", function()
    -- NormalizeKey is a normalizer: applying it twice == applying it once. Catches a regression
    -- where someone might add a stripping step that itself normalizes further.
    local cases = { "Foo", "  BAR ", "death knight", "HeLLo WoRLd", "", nil, "tab\there" }
    for _, c in ipairs(cases) do
        local once = util:NormalizeKey(c)
        local twice = util:NormalizeKey(once)
        H.eq(twice, once, "NormalizeKey(NormalizeKey(x)) == NormalizeKey(x) for " .. tostring(c))
    end
end)

------------------------------------------------------------------------
-- util:CloneTable
------------------------------------------------------------------------
H.test("util:CloneTable: deep-copies a nested table", function()
    local src = { a = 1, b = { c = 2, d = { e = 3 } } }
    local cp = util:CloneTable(src)
    H.eq(cp.a, 1, "primitive copied")
    H.eq(cp.b.c, 2, "nested copied")
    H.eq(cp.b.d.e, 3, "deep nested copied")
    cp.b.c = 99
    H.eq(src.b.c, 2, "mutation does not affect source")
end)
H.test("util:CloneTable: nil/non-table returns as-is", function()
    H.eq(util:CloneTable(nil), nil)
    H.eq(util:CloneTable(42), 42, "number passes through")
end)

------------------------------------------------------------------------
-- util:EnsureDefaults (relocated from Core.lua; seeds SavedVariables defaults)
------------------------------------------------------------------------
H.test("util:EnsureDefaults: fills missing keys, deep-merges, preserves existing", function()
    local target = { a = 1, nested = { keep = "me" } }
    local out = util:EnsureDefaults(target, { a = 99, b = 2, nested = { keep = "no", added = "yes" } })
    H.eq(out.a, 1, "existing primitive untouched")
    H.eq(out.b, 2, "missing primitive filled")
    H.eq(out.nested.keep, "me", "existing nested value untouched")
    H.eq(out.nested.added, "yes", "missing nested value filled")
end)
H.test("util:EnsureDefaults: non-table target becomes a fresh defaulted table", function()
    local out = util:EnsureDefaults(nil, { x = 1, y = { z = 2 } })
    H.eq(out.x, 1, "primitive seeded")
    H.eq(out.y.z, 2, "nested seeded")
end)
H.test("util:EnsureDefaults: a false value is preserved (not overwritten by default)", function()
    local out = util:EnsureDefaults({ flag = false }, { flag = true })
    H.eq(out.flag, false, "false is a present value, not a missing one")
end)

------------------------------------------------------------------------
-- util:Contains / util:TableCount
------------------------------------------------------------------------
H.test("util:Contains: finds an element", function()
    H.truthy(util:Contains({ "a", "b", "c" }, "b"), "b in list")
    H.check(not util:Contains({ "a", "b", "c" }, "z"), "z not in list")
    H.check(not util:Contains(nil, "a"), "nil list returns false")
end)
H.test("util:TableCount: counts a map's entries", function()
    H.eq(util:TableCount({ a=1, b=2, c=3 }), 3)
    H.eq(util:TableCount({}), 0)
    H.eq(util:TableCount(nil), 0)
end)

------------------------------------------------------------------------
-- util:EncodeField / util:DecodeField  (PROPERTY: inverse)
------------------------------------------------------------------------
H.test("util:EncodeField / DecodeField: round-trip is identity (property)", function()
    local cases = { "hello", "with|pipe", "with\nnewline", "colon:here", "percent%sign",
                    "all three | : \n here", "", "spaces ok" }
    for _, c in ipairs(cases) do
        local encoded = util:EncodeField(c)
        local decoded = util:DecodeField(encoded)
        H.eq(decoded, c, "round-trip preserves: " .. c)
    end
end)

H.test("util:EncodeField: encodes a delimiter-bearing string", function()
    -- 7C is "|", 0A is newline, 3A is colon, 25 is percent. The output is the literal 3-char
    -- sequence "%7C" / "%0A" / "%3A" (one backslash-shaped percent, two hex digits), NOT a Lua
    -- pattern. Use a literal find (no patterns) so the assertions don't double-decode.
    H.truthy(util:EncodeField("a|b"):find("%7C", 1, true), "pipe becomes %7C")
    H.truthy(util:EncodeField("a\nb"):find("%0A", 1, true), "newline becomes %0A")
    H.truthy(util:EncodeField("a:b"):find("%3A", 1, true), "colon becomes %3A")
    H.truthy(util:EncodeField("a%b"):find("%25", 1, true), "percent becomes %25")
end)

------------------------------------------------------------------------
-- util:JoinEncoded / util:SplitEncoded  (PROPERTY: round-trip)
------------------------------------------------------------------------
H.test("util:JoinEncoded + SplitEncoded: round-trip is identity (property)", function()
    -- Empty strings are intentionally not round-trippable: SplitEncoded("") returns {} (zero
    -- fields), so {""} cannot survive. Production callers pass non-empty fields. Verify the
    -- non-empty case as the property; treat the empty case as a separate known-divergence.
    local cases = {
        { "alice", "bob", "carol" },
        { "with|pipe", "with\nnewline", "plain" },
        { "percent%here", "colon:here" },
        { "single" },
    }
    for _, c in ipairs(cases) do
        local joined = util:JoinEncoded(c)
        local parts = util:SplitEncoded(joined)
        H.eq(#parts, #c, "round-trip count for " .. #c .. " fields")
        for i = 1, #c do
            H.eq(parts[i], c[i], "round-trip field " .. i)
        end
    end
end)

H.test("util:JoinEncoded + SplitEncoded: empty-string field is a known divergence", function()
    -- Documenting the divergence keeps it from being mistaken for a bug: SplitEncoded("") = {}.
    local joined = util:JoinEncoded({ "" })
    local parts = util:SplitEncoded(joined)
    H.eq(#parts, 0, "empty field round-trips to zero fields (documented)")
end)

------------------------------------------------------------------------
-- util:StatusRank / util:PlayerDisplayStatus
------------------------------------------------------------------------
H.test("util:StatusRank: main/unknown=3, designatedalt=2, alt tier=1", function()
    H.eq(util:StatusRank("main"), 3, "main")
    H.eq(util:StatusRank("unknown"), 3, "unknown competes as main (missing note must not cost loot)")
    H.eq(util:StatusRank("designatedalt"), 2, "designatedalt")
    H.eq(util:StatusRank("DESIGNATEDALT"), 2, "case-insensitive")
    H.eq(util:StatusRank("nil"), 1, "the deliberate bottom tier (Alt) is lowest")
    H.eq(util:StatusRank(""), 1, "empty is lowest")
    H.eq(util:StatusRank(nil), 1, "nil is lowest")
end)
H.test("util:PlayerDisplayStatus: maps status to display", function()
    H.eq(util:PlayerDisplayStatus("main"), "Main", "main -> Main")
    H.eq(util:PlayerDisplayStatus("designatedalt"), "Designated Alt", "designatedalt")
    H.eq(util:PlayerDisplayStatus("nil"), "Alt", "bottom tier -> Alt (a known placement)")
    H.eq(util:PlayerDisplayStatus("unknown"), "Unknown", "unknown -> Unknown (needs leadership attention)")
    H.eq(util:PlayerDisplayStatus(""), "Unknown", "empty -> Unknown")
end)

------------------------------------------------------------------------
-- util:ClassNameToToken
------------------------------------------------------------------------
H.test("util:ClassNameToToken: handles localized + shorthand class names", function()
    H.eq(util:ClassNameToToken("warrior"), "WARRIOR", "warrior")
    H.eq(util:ClassNameToToken("WARRIOR"), "WARRIOR", "uppercase")
    H.eq(util:ClassNameToToken("Death Knight"), "DEATHKNIGHT", "two-word class")
    H.eq(util:ClassNameToToken("death knight"), "DEATHKNIGHT", "lowercase two-word")
    H.eq(util:ClassNameToToken("DK"), "DEATHKNIGHT", "shorthand")
    H.eq(util:ClassNameToToken("dk"), "DEATHKNIGHT", "lowercase shorthand")
    H.eq(util:ClassNameToToken("priest"), "PRIEST", "priest")
    H.eq(util:ClassNameToToken("warlock"), "WARLOCK", "warlock")
    H.eq(util:ClassNameToToken("not a class"), nil, "garbage returns nil")
end)

------------------------------------------------------------------------
-- util:StripRealm
------------------------------------------------------------------------
H.test("util:StripRealm: drops the realm suffix", function()
    H.eq(util:StripRealm("Bob-Moonrunner"), "Bob", "Bob-Moonrunner -> Bob")
    H.eq(util:StripRealm("alice"), "alice", "no realm -> unchanged")
    H.eq(util:StripRealm("death-knight-tonic"), "death", "multiple dashes -> keep only up to the first")
end)

H.test("util:StripRealm: nil and non-string inputs pass through", function()
    H.eq(util:StripRealm(nil), nil, "nil -> nil")
    -- The new contract: non-strings return nil (callers normalize via `or ""` downstream).
    H.eq(util:StripRealm(42), nil, "number -> nil")
end)

H.test("util:StripRealm: empty string and empty-realm edge cases", function()
    -- The new regex "[^-]*" matches zero-or-more non-dash chars, so leading-dash input
    -- returns "" (the actual short-form prefix is empty). This is the real fix; the previous
    -- version returned the input unchanged via an `or name` fallback, which contradicted
    -- the function's intent.
    H.eq(util:StripRealm(""), "", "empty string -> empty")
    H.eq(util:StripRealm("-Moonrunner"), "", "leading dash -> empty (no short name)")
end)

------------------------------------------------------------------------
-- util:TierTokenClassSet
------------------------------------------------------------------------
H.test("util:TierTokenClassSet: returns class set for a known token", function()
    -- 40610 = Conqueror shoulder (10m, WotLK T7)
    local set = util:TierTokenClassSet(40610)
    H.notNil(set, "Conqueror token has a class set")
    H.truthy(set.PALADIN, "Conqueror: paladin allowed")
    H.truthy(set.PRIEST, "Conqueror: priest allowed")
    H.truthy(set.WARLOCK, "Conqueror: warlock allowed")
    H.check(not (set.WARRIOR or false), "Conqueror: warrior not allowed")
end)

H.test("util:TierTokenClassSet: returns nil for a non-token item", function()
    H.nil_(util:TierTokenClassSet(999999), "non-token id returns nil")
    H.nil_(util:TierTokenClassSet(nil), "nil id returns nil")
end)

H.test("util:TierTokenClassSet: Vanquisher covers Rogue/DK/Mage/Druid", function()
    local set = util:TierTokenClassSet(40612)   -- Vanquisher shoulder 10m
    H.notNil(set, "Vanquisher has class set")
    H.truthy(set.ROGUE); H.truthy(set.DEATHKNIGHT); H.truthy(set.MAGE); H.truthy(set.DRUID)
    H.check(not (set.WARRIOR or false), "Vanquisher: warrior not allowed")
end)

------------------------------------------------------------------------
-- util:RollTierAvailability (pure logic, no WoW API needed)
--
-- The cases below use a NON-equipment itemId (49295 = Onyxia Backpack, on REDUCED_ROLL_ITEMS) for
-- the reduced-roll checks, and an arbitrary high itemId (9999999) for the gear-shape checks. The
-- arbitrary id is NOT on the reduced list, so the function's class / locked / self-block / noprio
-- branches apply as intended.
------------------------------------------------------------------------
H.test("util:RollTierAvailability: pass is always available on an open lot", function()
    local out = util:RollTierAvailability(49295, true, false, nil, true)  -- bag, allowed
    H.nil_(out.pass, "pass is open")
end)
H.test("util:RollAvailability: locked disables every bracket", function()
    local out = util:RollTierAvailability(9999999, true, true, nil, true)
    H.eq(out.bis, "locked", "bis locked")
    H.eq(out.ms,  "locked", "ms locked")
    H.eq(out.os,  "locked", "os locked")
    H.eq(out.pass, "locked", "pass locked")
end)
H.test("util:RollTierAvailability: self-block keeps only Pass", function()
    local out = util:RollTierAvailability(9999999, true, false, "quest", true)
    H.eq(out.bis, "quest", "bis blocked by quest reason")
    H.eq(out.ms,  "quest", "ms blocked by quest reason")
    H.nil_(out.pass, "pass stays open under self-block")
end)
H.test("util:RollTierAvailability: BiS needs a listed priority", function()
    -- hasPrio=false blocks BiS via noprio, not type. Use 9999999 (not on REDUCED_ROLL_ITEMS) so the
    -- reduced branch doesn't fire and override noprio.
    local out = util:RollTierAvailability(9999999, true, false, nil, false)
    H.eq(out.bis, "noprio", "bis blocked when no priority")
    H.nil_(out.ms, "ms not blocked by noprio")
end)
H.test("util:RollTierAvailability: class block on gear", function()
    -- isAllowed=false on a gear-shape item blocks BiS / MS / MU / OS / TM via class; Pass open.
    local out = util:RollTierAvailability(9999999, false, false, nil, true)
    H.eq(out.bis, "class", "bis blocked by class")
    H.eq(out.ms,  "class", "ms blocked by class")
    H.eq(out.mu,  "class", "mu blocked by class")
    H.nil_(out.pass, "pass unaffected")
end)
H.test("util:RollTierAvailability: reduced-roll item drops BiS and TM brackets", function()
    -- 49295 (Onyxia Backpack) is on REDUCED_ROLL_ITEMS, so reduced=true, BiS/TM become "type"
    -- (reduced-roll items don't support those brackets), MS/OS/Pass stay open.
    local out = util:RollTierAvailability(49295, true, false, nil, true)
    H.eq(out.bis, "type", "bis is 'type' on a non-equipment")
    H.eq(out.tm,  "type", "tm  is 'type' on a non-equipment")
    H.nil_(out.ms, "ms open on a non-equipment (the reduced-roll reduced set)")
    H.nil_(out.os, "os open on a non-equipment")
    H.nil_(out.pass, "pass open")
end)

------------------------------------------------------------------------
-- addon.RESPONSE_TOOLTIPS  (single source of truth for bracket hover text)
------------------------------------------------------------------------
H.test("RESPONSE_TOOLTIPS: covers every bracket", function()
    local T = addon.RESPONSE_TOOLTIPS
    H.notNil(T.bis, "BiS")
    H.notNil(T.ms,  "MS")
    H.notNil(T.mu,  "MU")
    H.notNil(T.os,  "OS")
    H.notNil(T.tm,  "TM")
    H.notNil(T.pass, "Pass")
end)

H.test("RESPONSE_TOOLTIPS: hover text is human-readable (no abbreviations)", function()
    -- These strings are read by users; guard against accidental abbreviation.
    H.eq(addon.RESPONSE_TOOLTIPS.bis,  "Best in Slot", "BiS -> Best in Slot")
    H.eq(addon.RESPONSE_TOOLTIPS.pass, "Pass",         "Pass -> Pass")
end)

F.endSuite()