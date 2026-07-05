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

-- UI/RaidersTab.lua: unhandled guests float to the top in every sort mode; the raid-only
-- toggle filters absent entries.
H.test("Raiders tab: guests sort first and raid-only filters", function()
    local w = uiWorld()
    w.addon:InitializeUI()
    w.addon.roster.rosterDisplay = {
        { name = "aaron", present = true, isGuest = false, className = "mage", specName = "fire", status = "main", source = "configured" },
        { name = "benched", present = false, isGuest = false, className = "rogue", specName = "combat", status = "main", source = "configured" },
        { name = "zug", present = true, isGuest = true, className = "warrior", specName = "", status = "main", source = "unconfigured" },
    }
    w.addon.db.ui.rosterSortMode = "name"
    w.addon.db.ui.rosterRaidOnly = false
    local sorted = w.addon:GetSortedRosterEntries()
    H.eq(sorted[1].name, "zug", "guest floats above alphabetical sort")
    H.eq(#sorted, 3, "no filter keeps every entry")

    w.addon.db.ui.rosterRaidOnly = true
    sorted = w.addon:GetSortedRosterEntries()
    H.eq(#sorted, 2, "raid-only drops absent entries")
    H.eq(sorted[1].name, "zug", "guest still first")

    w.addon.db.ui.rosterRaidOnly = false
    w.addon:RefreshRaidersTab()
    H.check(true, "RefreshRaidersTab renders guest rows without error")
end)

F.endSuite()
