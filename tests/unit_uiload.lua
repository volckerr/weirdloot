-- UI-load smoke suite. The harness normally skips UI.lua (heavy FrameXML, irrelevant to loot
-- accounting), so a refactor that splits UI into modules could silently leave a method referencing
-- an out-of-scope file-local and nothing would catch it until in-game. This suite loads every UI
-- file into the mocked env and proves the presentation layer loads, InitializeUI builds the window,
-- and every tab build/refresh runs without error on an empty session.
--
-- Run from the addon dir:  luajit tests/unit_uiload.lua

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("ui load smoke battery")

local function uiWorld()
    local w = F.makeWorld("UISmoke", true)
    F.loadUI(w)
    return w
end

H.test("UI files load and define the expected entry points", function()
    local w = uiWorld()
    local expected = {
        "InitializeUI", "RefreshUI", "SelectTab", "ToggleMainFrame",
        "BuildLootTab", "BuildRaidersTab", "BuildResultsTab", "BuildMasterTab", "BuildOptionsTab",
        "RefreshLootTab", "RefreshRaidersTab", "RefreshResultsTab", "RefreshMasterTab", "RefreshOptionsTab",
    }
    for _, m in ipairs(expected) do
        H.eq(type(w.addon[m]), "function", m .. " is defined")
    end
end)

-- Minimap button placement: shape-aware orbit (LibDBIcon math), Shift+Right-drag detach, re-attach.
local function minimapWorld()
    local w = uiWorld()
    w.addon:InitializeUI()
    local btn = w.env.WeirdLootMinimapButton
    H.notNil(btn, "minimap button built")
    local last
    btn.SetPoint = function(_, point, rel, relPoint, x, y) last = { x = x, y = y } end
    w.env.Minimap.GetCenter = function() return 500, 500 end
    btn.GetCenter = function() return 420, 500 end            -- sitting at the left edge (-80, 0)
    return w, btn, function() return last end
end

H.test("minimap orbit: round map rides the circle, square map rides the edge", function()
    local w, btn, at = minimapWorld()
    w.addon.db.minimapButtonAngle = 30
    w.env.GetMinimapShape = nil
    w.addon:ReattachMinimapButton()                            -- repositions from the orbit
    H.check(math.abs(at().x - 69.28) < 0.1 and math.abs(at().y - 40) < 0.1, "round: 80 * (cos30, sin30)")
    w.env.GetMinimapShape = function() return "SQUARE" end
    w.addon:ReattachMinimapButton()
    H.check(math.abs(at().x - 80) < 0.01 and math.abs(at().y - 51.57) < 0.1, "square: clamped onto the right edge")
end)

H.test("minimap drag: Shift+Right-drag detaches to a free offset; plain drag re-attaches; Options re-attaches", function()
    local w, btn, at = minimapWorld()
    w.env.IsShiftKeyDown = function() return true end
    w.env.GetCursorPosition = function() return 100, 100 end
    btn:GetScript("OnDragStart")(btn)
    w.env.GetCursorPosition = function() return 130, 60 end    -- moved +30, -40
    btn:GetScript("OnUpdate")(btn)
    btn:GetScript("OnDragStop")(btn)
    H.eq(w.addon:IsMinimapButtonDetached(), true, "detached")
    H.check(math.abs(at().x - (-50)) < 0.01 and math.abs(at().y - (-40)) < 0.01, "free offset = start (-80,0) + delta")
    H.eq(w.addon.ui.optionsPanel.reattachBtn.__disabled, false, "re-attach button usable")

    w.env.IsShiftKeyDown = function() return false end
    w.env.GetCursorPosition = function() return 580, 500 end   -- due right of the center
    btn:GetScript("OnDragStart")(btn)
    btn:GetScript("OnUpdate")(btn)
    btn:GetScript("OnDragStop")(btn)
    H.eq(w.addon:IsMinimapButtonDetached(), false, "plain drag re-attached")
    H.check(math.abs(w.addon.db.minimapButtonAngle) < 0.01, "angle 0 = right side")

    w.addon.db.minimapButtonX, w.addon.db.minimapButtonY = 5, 5
    w.addon:ReattachMinimapButton()
    H.eq(w.addon:IsMinimapButtonDetached(), false, "Options re-attach clears the free offset")
end)

H.test("InitializeUI builds the window without error", function()
    local w = uiWorld()
    w.addon:InitializeUI()
    H.notNil(w.addon.ui, "addon.ui created")
end)

H.test("RefreshUI and SelectTab run across every tab on an empty session", function()
    local w = uiWorld()
    w.addon:InitializeUI()
    w.addon:RefreshUI()
    for _, tab in ipairs({ "loot", "results", "raiders", "master", "options" }) do
        w.addon:SelectTab(tab)
    end
    H.check(true, "no error through RefreshUI + SelectTab across all tabs")
end)

-- UI/Export.lua: the extracted export/import block. Defined + runnable means its re-localize header
-- resolved the shared widgets it needs from addon.UI.
H.test("export/import entry points are defined and run", function()
    local w = uiWorld()
    for _, m in ipairs({ "ExportWinners", "ExportLog", "BuildWinnersExportText", "BuildDetailedExportLogText", "ImportRoster", "ImportNamedItems" }) do
        H.eq(type(w.addon[m]), "function", m .. " is defined")
    end
    w.addon:InitializeUI()
    w.addon:ExportWinners()
    w.addon:ExportLog()
    H.check(true, "ExportWinners + ExportLog build their windows without error")
end)

-- UI/Minimap.lua: the extracted minimap button + owed-loot glow.
H.test("minimap entry points are defined and run", function()
    local w = uiWorld()
    for _, m in ipairs({ "BuildMinimapButton", "UpdateMinimapOwedGlow", "SetMinimapButtonShown", "CountLootOwedToMe" }) do
        H.eq(type(w.addon[m]), "function", m .. " is defined")
    end
    w.addon:InitializeUI()
    w.addon:BuildMinimapButton()
    w.addon:UpdateMinimapOwedGlow()
    w.addon:SetMinimapButtonShown(true)
    H.check(true, "minimap build + glow + toggle run without error")
end)

-- UI/Minimap.lua: the "ML is not accepting trades" red-X warning gating.
H.test("minimap trade-status warning gates on session + accepting-trades state", function()
    local w = uiWorld()
    w.addon:InitializeUI()
    w.addon:BuildMinimapButton()
    H.eq(type(w.addon.ShouldWarnMLNotAcceptingTrades), "function", "predicate defined")
    H.eq(type(w.addon.UpdateMinimapTradeStatus), "function", "updater defined")
    H.notNil(w.addon.ui.minimapButton.tradeX, "red-X texture created on the button")

    -- No session: never warn, even before payout exists.
    H.eq(w.addon:ShouldWarnMLNotAcceptingTrades(), false, "no session -> no warning")
    w.addon:UpdateMinimapTradeStatus()

    F.startSession(w)
    w.addon:StartPayout()
    H.eq(w.addon:ShouldWarnMLNotAcceptingTrades(), false, "session live + accepting -> no warning")
    w.addon:StopPayout()
    H.eq(w.addon:ShouldWarnMLNotAcceptingTrades(), true, "session live + payout paused -> warn")
    w.addon:UpdateMinimapTradeStatus()   -- runs without error with the warning active
    H.check(true, "UpdateMinimapTradeStatus ran through both states")
end)

-- UI/Minimap.lua: the icon desaturates when no loot master is in play.
H.test("minimap ML-active desaturation gates on a resolved loot master", function()
    local w = uiWorld()
    w.addon:InitializeUI()
    w.addon:BuildMinimapButton()
    H.eq(type(w.addon.IsLootMasterActive), "function", "predicate defined")
    H.eq(type(w.addon.UpdateMinimapMLActive), "function", "updater defined")
    H.notNil(w.addon.ui.minimapButton.icon, "icon kept on the button")

    w.addon.roster.lootMasterName = nil
    H.eq(w.addon:IsLootMasterActive(), false, "no loot master -> inactive")
    w.addon:UpdateMinimapMLActive()

    w.addon.roster.lootMasterName = "Masterlooter"
    H.eq(w.addon:IsLootMasterActive(), true, "loot master resolved -> active")
    w.addon:UpdateMinimapMLActive()
    H.check(true, "UpdateMinimapMLActive ran through both states")
end)

-- UI/Minimap.lua: the roster-attention alert repurposes the owed ring (red, pulsing) and
-- outranks the owed spin; only roster editors see it.
H.test("minimap attention mode gates on editability and outranks owed", function()
    local w = uiWorld()
    w.addon:InitializeUI()
    w.addon:BuildMinimapButton()
    local shine = w.addon.ui.minimapShine
    H.notNil(shine, "shine ring built")

    w.addon.roster.rosterDisplay = {
        { name = "zug", present = true, needsAttention = true, specName = "", status = "unknown", className = "warrior", source = "unconfigured" },
    }
    w.addon.CanEditRoster = function() return false end
    w.addon:RefreshMinimapShine()
    H.eq(shine.mode, nil, "non-editor never sees the attention state")

    w.addon.CanEditRoster = function() return true end
    w.addon:RefreshMinimapShine()
    H.eq(shine.mode, "attention", "editor with an unhandled member gets attention mode")

    w.addon.CountLootOwedToMe = function() return 2 end
    w.addon:RefreshMinimapShine()
    H.eq(shine.mode, "attention", "attention outranks owed while both apply")

    w.addon.roster.rosterDisplay = {}
    w.addon:RefreshMinimapShine()
    H.eq(shine.mode, "owed", "owed resumes once the roster is clean")

    w.addon.CountLootOwedToMe = function() return 0 end
    w.addon:RefreshMinimapShine()
    H.eq(shine.mode, nil, "ring idle with nothing to signal")
end)

-- UI/RaidersTab.lua: unhandled guests float to the top in every sort mode; the raid-only
-- toggle filters absent entries.
H.test("Raiders tab: guests sort first and raid-only filters", function()
    local w = uiWorld()
    w.addon:InitializeUI()
    w.addon.roster.rosterDisplay = {
        { name = "aaron", present = true, isGuest = false, needsAttention = false, className = "mage", specName = "fire", status = "main", source = "configured" },
        { name = "benched", present = false, isGuest = false, needsAttention = false, className = "rogue", specName = "combat", status = "main", source = "configured" },
        { name = "zug", present = true, isGuest = true, needsAttention = true, className = "warrior", specName = "", status = "unknown", source = "unconfigured" },
    }
    w.addon.db.ui.rosterSortMode = "name"
    w.addon.db.ui.rosterRaidOnly = false
    local sorted = w.addon:GetSortedRosterEntries()
    H.eq(sorted[1].name, "zug", "needs-attention member floats above alphabetical sort")
    H.eq(#sorted, 3, "no filter keeps every entry")

    w.addon.db.ui.rosterRaidOnly = true
    sorted = w.addon:GetSortedRosterEntries()
    H.eq(#sorted, 3, "raid-only is inert outside a raid: full guild view")

    -- The harness stubs GetAttendees to {} ("not in a group"); swap it locally to simulate
    -- a raid. Promote to a framework helper if more raid-dependent tests accumulate.
    local stubbedGetAttendees = w.addon.GetAttendees
    w.addon.GetAttendees = function() return { { name = "aaron" }, { name = "zug" } } end
    sorted = w.addon:GetSortedRosterEntries()
    H.eq(#sorted, 2, "raid-only drops absent entries when actually in a raid")
    H.eq(sorted[1].name, "zug", "needs-attention member still first")
    w.addon.GetAttendees = stubbedGetAttendees

    w.addon.db.ui.rosterRaidOnly = false
    w.addon:RefreshRaidersTab()
    H.check(true, "RefreshRaidersTab renders attention rows + tab alert without error")
end)

F.endSuite()
