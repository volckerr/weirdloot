-- Unit tests for the debug alert layer (Core/Debug.lua). Focus on the pure classifier
-- (ClassifySyncAnomaly): which trace events raise a live chat alert and which stay quiet. The
-- throttle, chat print, and stall watchdog are I/O/timer glue and are exercised in-game.
--
-- Run from the addon dir:  luajit tests/unit_debug.lua
--   (or `luajit tests/run.lua` for the whole battery).

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("debug alerts unit battery")

-- Debug.lua only needs a WeirdLoot table, CreateFrame (its watchdog frame), and GetTime at load.
local env = setmetatable({}, { __index = _G })
env._G = env
env.WeirdLoot = {}
env.CreateFrame = function()
    return setmetatable({}, { __index = function() return function() end end })
end
env.GetTime = function() return 0 end

local chunk = assert(loadfile("Core/Debug.lua"))
setfenv(chunk, env)
chunk("WeirdLoot", {})
local addon = env.WeirdLoot

H.test("debug command: the banner verb runs the demo (a debug surface, not a root slash command)", function()
    -- string.trim ships from Core/Util.lua (not loaded in this standalone suite); match its behavior
    if not string.trim then function string.trim(s) return (tostring(s):gsub("^%s*(.-)%s*$", "%1")) end end
    addon.Print = addon.Print or function() end
    local ran = 0
    addon.RunBannerDemo = function() ran = ran + 1 end
    addon:HandleDebugCommand("banner")
    H.eq(ran, 1, "banner verb dispatched to the demo")
    addon.RunBannerDemo = nil
    addon:HandleDebugCommand("banner")   -- banner UI not loaded: message, no error
    H.eq(ran, 1, "no demo without the banner UI loaded")
end)

H.test("ClassifySyncAnomaly flags real sync faults", function()
    H.notNil(addon:ClassifySyncAnomaly("give-up", { kind = "request", reason = "max" }), "recovery give-up")
    H.notNil(addon:ClassifySyncAnomaly("drop-foreign", { t = "H", from = "ML" }), "foreign-dropped inbound")
    H.notNil(addon:ClassifySyncAnomaly("recv-snap-stale", { rev = 3, lastRev = 9 }), "stale snapshot rejected")
    H.notNil(addon:ClassifySyncAnomaly("evict-partial", { sender = "ML", id = 4 }), "lost frame / partial")
    H.notNil(addon:ClassifySyncAnomaly("recv-decode-fail", { sender = "ML" }), "corrupt inbound")
    H.notNil(addon:ClassifySyncAnomaly("deliver-cb", { ok = false, itemId = 40001 }), "delivery matched no owed award")
    H.notNil(addon:ClassifySyncAnomaly("loan-done", { via = "unmatched", from = "Gorgarg", item = 44569 }), "loan pickup report matched nothing")
end)

H.test("ClassifySyncAnomaly stays quiet on routine traffic", function()
    H.nil_(addon:ClassifySyncAnomaly("deliver-cb", { ok = true, itemId = 40001 }), "a successful delivery is not an anomaly")
    H.nil_(addon:ClassifySyncAnomaly("recv", { tag = "H", sender = "ML" }), "a normal inbound recv is not an anomaly")
    H.nil_(addon:ClassifySyncAnomaly("recv-hb", { verdict = "in-sync" }), "an in-sync heartbeat is not an anomaly")
    H.nil_(addon:ClassifySyncAnomaly("recv-lot", { rev = 12 }), "a normal delta apply is not an anomaly")
    H.nil_(addon:ClassifySyncAnomaly("mint", { id = "L:1" }), "a core mint is not an anomaly")
    H.nil_(addon:ClassifySyncAnomaly("send", { cmd = "D" }), "an outgoing send is not an anomaly")
    H.nil_(addon:ClassifySyncAnomaly("loan-done", { via = "live", from = "Gorgarg", item = 44569 }), "a matched loan pickup is not an anomaly")
end)

F.report("debug alerts unit battery")
