-- Per-character storage routing (Core.lua PLAYER_LOGIN). options + ui live in WeirdLootCharDB
-- (## SavedVariablesPerCharacter); testMode/autoRoll/config stay in the account WeirdLootDB. self.db
-- is a proxy that routes by key, so the rest of the addon reads self.db.options / self.db.ui /
-- self.db.config unchanged, and the account DB never carries a stale options/ui copy.
--
-- Run from the addon dir:  luajit tests/unit_perchar.lua

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("per-character storage battery")

H.test("options writes route to WeirdLootCharDB, not the account DB", function()
    local w = H.makeWorld("Char", true)
    w.addon.db.options.blacklistText = "Wand"
    H.eq(w.env.WeirdLootCharDB.options.blacklistText, "Wand", "options write lands in WeirdLootCharDB")
    H.eq(w.env.WeirdLootDB.options, nil, "account DB carries no options copy")
end)

H.test("ui writes route to WeirdLootCharDB, not the account DB", function()
    local w = H.makeWorld("Char", true)
    w.addon.db.ui.lootSortMode = "name"
    H.eq(w.env.WeirdLootCharDB.ui.lootSortMode, "name", "ui write lands in WeirdLootCharDB")
    H.eq(w.env.WeirdLootDB.ui, nil, "account DB carries no ui copy")
end)

H.test("account fields (testMode/autoRoll/config) stay in WeirdLootDB", function()
    local w = H.makeWorld("Char", true)
    w.addon.db.testMode = true
    w.addon.db.autoRoll = true
    H.eq(w.env.WeirdLootDB.testMode, true, "testMode lands in WeirdLootDB")
    H.eq(w.env.WeirdLootDB.autoRoll, true, "autoRoll lands in WeirdLootDB")
    H.eq(w.env.WeirdLootCharDB.testMode, nil, "testMode does NOT leak into WeirdLootCharDB")
    H.eq(w.env.WeirdLootCharDB.autoRoll, nil, "autoRoll does NOT leak into WeirdLootCharDB")
end)

H.test("config reads/writes through the proxy hit the account DB", function()
    local w = H.makeWorld("Char", true)
    H.notNil(w.addon.db.config, "config readable via proxy")
    H.eq(w.addon.db.config, w.env.WeirdLootDB.config, "proxy.config IS the account config table")
    w.addon.db.config.revision = 7
    H.eq(w.env.WeirdLootDB.config.revision, 7, "config write lands in WeirdLootDB")
end)

H.test("per-character defaults are present after login", function()
    local w = H.makeWorld("Char", true)
    -- a couple of representative option + ui defaults moved verbatim from the old account block
    H.eq(w.addon.db.options.rollDuration, 30, "option default present in per-char DB")
    H.eq(w.addon.db.ui.selectedTab, "loot", "ui default present in per-char DB")
end)

H.test("legacy account-wide options/ui are dropped on load (never re-saved to the account WTF)", function()
    local w = H.makeWorld("Char", true)
    -- simulate an account WTF written by an older version that stored options/ui account-wide
    w.env.WeirdLootDB.options = { blacklistText = "Legacy", rollDuration = 99 }
    w.env.WeirdLootDB.ui = { selectedTab = "old" }
    w.addon:PLAYER_LOGIN()   -- reload with the new code
    H.eq(w.env.WeirdLootDB.options, nil, "legacy account options dropped")
    H.eq(w.env.WeirdLootDB.ui, nil, "legacy account ui dropped")
    -- and the legacy values did NOT leak into the per-character store (fresh defaults, no migration)
    H.eq(w.addon.db.options.rollDuration, 30, "per-char option keeps its default, not legacy 99")
    H.eq(w.addon.db.options.blacklistText, "", "per-char blacklist is the default, not legacy text")
end)

F.endSuite()
