-- Unit tests for Core/GuildRoster.lua: officer-note spec tokens, the rank -> status mapping,
-- and the guild scan (note visibility gating, realm stripping, unmapped-rank default).
--
-- Run from the addon dir:  luajit tests/unit_guildroster.lua
-- (or just `luajit tests/run.lua` to run the whole battery).

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("guild roster unit battery")

-- Minimal env: same skeleton as unit_config (Core + Util + Config ahead of GuildRoster).
local env = setmetatable({}, { __index = _G })
env._G = env
env.WeirdLoot = env.WeirdLoot or {}
env.LibStub = setmetatable({}, { __call = function(_, _) return nil end, __index = function() return nil end })
env.CreateFrame = function()
    local f = { __scripts = {} }
    local mt = { __index = function(t, k)
        if k == "RegisterEvent" then return function() end end
        if k == "Hide" then return function() end end
        if k == "Show" then return function() end end
        if k == "SetScript" then return function(_, _, fn) end end
        if k == "GetScript" then return function() return nil end end
        return function() return t end
    end }
    return setmetatable(f, mt)
end
env.GetTime = function() return 0 end
env.UnitGUID = function() return "Player-0-00000001" end
env.UnitClass = function() return "Warrior", "WARRIOR" end
env.UnitName = function() return "Tester" end
env.GetRealmName = function() return "TestRealm" end
env.time = function() return 0 end
env.math = setmetatable({}, { __index = math })
env.StaticPopupDialogs = {}
env.DEFAULT_CHAT_FRAME = setmetatable({ AddMessage = function() end }, { __index = function() return function() end end })
env.SlashCmdList = {}
env.StaticPopup_Show = function()
    local box = {
        SetText = function() end, SetFocus = function() end, HighlightText = function() end,
        GetText = function() return "" end,
    }
    return {
        button1 = { Click = function() end },
        editBox = box,
        GetParent = function() return { Hide = function() end } end,
        Hide = function() end,
        SetOwner = function() end, ClearAllPoints = function() end, SetPoint = function() end,
        SetHyperlink = function() end, Show = function() end,
    }
end
local private = {}

-- Roster/Comm need raid-roster and party APIs at call time; quiet stubs (no group).
env.GetNumRaidMembers = function() return 0 end
env.GetNumPartyMembers = function() return 0 end
env.GetRaidRosterInfo = function() return nil end

for _, file in ipairs({ "Core.lua", "Data/LootPrios.lua", "Core/Util.lua", "Core/Config.lua", "Core/Roster.lua", "Core/Comm.lua", "Core/GuildRoster.lua" }) do
    local chunk = assert(loadfile(file))
    setfenv(chunk, env)
    chunk("WeirdLoot", private)
end

local addon = env.WeirdLoot
addon.config = {}

-- ParseOfficerNote returns (specName, statusOverride); tiny wrappers keep assertions readable.
local function noteSpec(note, class)
    local spec = addon:ParseOfficerNote(note, class)
    return spec
end
local function noteStatus(note, class)
    local _, status = addon:ParseOfficerNote(note, class)
    return status
end

------------------------------------------------------------------------
-- ParseOfficerNote: spec tokens
------------------------------------------------------------------------
H.test("ParseOfficerNote: bare 3-letter token", function()
    H.eq(noteSpec("aff", "warlock"), "affliction", "aff -> affliction")
    H.eq(noteSpec("ele", "shaman"), "elemental", "ele -> elemental")
    H.eq(noteSpec("bst", "hunter"), "beast mastery", "bst -> beast mastery")
end)

H.test("ParseOfficerNote: token is a TRAILING comma field, rest of note is free text", function()
    H.eq(noteSpec("raid lead,aff", "warlock"), "affliction", "text before comma ignored")
    H.eq(noteSpec("a,b,ret", "paladin"), "retribution", "last of several fields")
    H.eq(noteSpec("recruited 2026,pro", "warrior"), "protection", "free text preserved")
end)

H.test("ParseOfficerNote: case and whitespace tolerant", function()
    H.eq(noteSpec("raid lead, AFF ", "warlock"), "affliction", "spaces + caps")
    H.eq(noteSpec(" RET", "paladin"), "retribution", "leading space, caps")
end)

H.test("ParseOfficerNote: cross-class token collisions resolve by class", function()
    H.eq(noteSpec("hol", "paladin"), "holy", "hol on paladin")
    H.eq(noteSpec("hol", "priest"), "holy", "hol on priest")
    H.eq(noteSpec("fro", "death knight"), "frost", "fro on DK")
    H.eq(noteSpec("fro", "mage"), "frost", "fro on mage")
    H.eq(noteSpec("res", "shaman"), "restoration", "res on shaman")
    H.eq(noteSpec("res", "druid"), "restoration", "res on druid")
end)

H.test("ParseOfficerNote: class aliases resolve via NormalizeClassName", function()
    H.eq(noteSpec("unh", "DK"), "unholy", "dk alias")
    H.eq(noteSpec("unh", "Death Knight"), "unholy", "two-word class")
end)

H.test("ParseOfficerNote: invalid tokens read as no spec", function()
    H.eq(noteSpec("aff", "mage"), "", "valid token, wrong class")
    H.eq(noteSpec("lol", "warlock"), "", "not a token")
    H.eq(noteSpec("affliction", "warlock"), "", "full spec names rejected: 3-letter only")
    H.eq(noteSpec("raid lead,", "warlock"), "", "trailing comma, empty field")
    H.eq(noteSpec("", "warlock"), "", "empty note")
    H.eq(noteSpec(nil, "warlock"), "", "nil note")
    H.eq(noteSpec("aff", "not a class"), "", "unknown class")
    H.eq(noteSpec("aff", nil), "", "nil class")
end)

------------------------------------------------------------------------
-- ParseOfficerNote: status overrides
------------------------------------------------------------------------
H.test("ParseOfficerNote: status override alongside spec, either order", function()
    local spec, status = addon:ParseOfficerNote("my officer note,dalt,blo", "death knight")
    H.eq(spec, "blood", "spec from trailing fields")
    H.eq(status, "designatedalt", "dalt override")
    spec, status = addon:ParseOfficerNote("my officer note,blo,dalt", "death knight")
    H.eq(spec, "blood", "order-flexible: spec first")
    H.eq(status, "designatedalt", "order-flexible: status last")
end)

H.test("ParseOfficerNote: status override alone", function()
    H.eq(noteStatus("note text,dalt", "warlock"), "designatedalt", "dalt")
    H.eq(noteStatus("note text,alt", "warlock"), "nil", "alt = bottom tier")
    H.eq(noteStatus("note text,main", "warlock"), "main", "explicit main")
    H.eq(noteStatus("dalt", "warlock"), "designatedalt", "bare status token")
end)

H.test("ParseOfficerNote: no override when absent or invalid", function()
    H.eq(noteStatus("raid lead,aff", "warlock"), nil, "spec only -> no override")
    H.eq(noteStatus("plain note", "warlock"), nil, "free text -> no override")
    H.eq(noteStatus("a,b,c,dalt,blo", "death knight"), "designatedalt", "only last two fields examined")
    H.eq(noteStatus("dalt,other,text", "warlock"), nil, "status token outside trailing fields ignored")
end)

------------------------------------------------------------------------
-- SplitOfficerNote / ComposeOfficerNote / reverse token lookups
-- (the dropdown writer's contract: free text survives token edits)
------------------------------------------------------------------------
H.test("SplitOfficerNote: free text preserved byte-for-byte", function()
    local free, spec, status = addon:SplitOfficerNote("my officer note,dalt,blo", "death knight")
    H.eq(free, "my officer note", "free text")
    H.eq(spec, "blood", "spec consumed")
    H.eq(status, "designatedalt", "status consumed")

    free, spec, status = addon:SplitOfficerNote("raid lead,aff", "warlock")
    H.eq(free, "raid lead", "spec-only note")
    H.eq(spec, "affliction", "spec")
    H.eq(status, nil, "no override")

    free = addon:SplitOfficerNote("a,b,ret", "paladin")
    H.eq(free, "a,b", "inner commas kept in free text")

    free, spec = addon:SplitOfficerNote("blo", "death knight")
    H.eq(free, "", "bare token: empty free text")
    H.eq(spec, "blood", "bare token parsed")

    free, spec, status = addon:SplitOfficerNote("plain note", "warlock")
    H.eq(free, "plain note", "tokenless note is all free text")
    H.eq(spec, "", "no spec")
    H.eq(status, nil, "no status")

    free = addon:SplitOfficerNote("raid lead,", "warlock")
    H.eq(free, "raid lead,", "trailing comma preserved")

    free = addon:SplitOfficerNote("", "warlock")
    H.eq(free, "", "empty note")
end)

H.test("ComposeOfficerNote: canonical order, inverse of the splitter", function()
    H.eq(addon:ComposeOfficerNote("my officer note", "dalt", "blo"), "my officer note,dalt,blo", "full form")
    H.eq(addon:ComposeOfficerNote("", nil, "ele"), "ele", "spec only, no leading comma")
    H.eq(addon:ComposeOfficerNote("", "dalt", nil), "dalt", "status only")
    H.eq(addon:ComposeOfficerNote("note", nil, nil), "note", "free text only")
    H.eq(addon:ComposeOfficerNote(nil, nil, nil), "", "nothing")
    -- round trip
    local free, spec, status = addon:SplitOfficerNote(addon:ComposeOfficerNote("x", "alt", "fro"), "mage")
    H.eq(free, "x", "round-trip free text")
    H.eq(spec, "frost", "round-trip spec")
    H.eq(status, "nil", "round-trip status")
end)

H.test("SpecTokenFor / StatusTokenFor: reverse lookups", function()
    H.eq(addon:SpecTokenFor("shaman", "elemental"), "ele", "spec name -> token")
    H.eq(addon:SpecTokenFor("Death Knight", "beast mastery"), nil, "wrong class -> nil")
    H.eq(addon:SpecTokenFor("hunter", "beast mastery"), "bst", "two-word spec")
    H.eq(addon:SpecTokenFor("shaman", ""), nil, "blank spec -> nil")
    H.eq(addon:StatusTokenFor("designatedalt"), "dalt", "designatedalt -> dalt")
    H.eq(addon:StatusTokenFor("nil"), "alt", "bottom tier -> alt")
    H.eq(addon:StatusTokenFor("main"), "main", "main -> main")
    H.eq(addon:StatusTokenFor("bogus"), nil, "unknown -> nil")
end)

------------------------------------------------------------------------
-- GuildRankStatus (0-based rank index; Alt and DAlt indices from config)
------------------------------------------------------------------------
H.test("GuildRankStatus: default indices (Alt=7, Main=6, DAlt=5, OfficerAlt=2)", function()
    addon.config = {}
    H.eq(addon:GuildRankStatus(7), "nil", "Alt rank -> bottom tier")
    H.eq(addon:GuildRankStatus(2), "nil", "officer alts -> bottom tier (note overrides if not)")
    H.eq(addon:GuildRankStatus(6), "main", "Raider -> main")
    H.eq(addon:GuildRankStatus(5), "designatedalt", "DAlt rank")
    H.eq(addon:GuildRankStatus(0), "unknown", "guild master: no note -> unknown")
    H.eq(addon:GuildRankStatus(9), "unknown", "Trial -> unknown")
    H.eq(addon:GuildRankStatus(nil), "unknown", "no rank index -> unknown")
end)

H.test("GuildRankStatus: indices come from config", function()
    -- A ladder reshuffle sets all four indices; alt checks run first, so a main index that
    -- collides with a leftover alt default would read as alt (hence: configure the set).
    addon.config = { guildAltRankIndex = 6, guildOfficerAltRankIndex = 4, guildDesignatedAltRankIndex = 1, guildMainRankIndex = 2 }
    H.eq(addon:GuildRankStatus(6), "nil", "configured Alt index")
    H.eq(addon:GuildRankStatus(4), "nil", "configured officer-alt index")
    H.eq(addon:GuildRankStatus(1), "designatedalt", "configured DAlt index")
    H.eq(addon:GuildRankStatus(2), "main", "configured Main index")
    H.eq(addon:GuildRankStatus(7), "unknown", "built-in default replaced by config, not merged")
    addon.config = {}
end)

------------------------------------------------------------------------
-- RefreshGuildRoster
------------------------------------------------------------------------
local guildFixture = {
    -- name, rank, rankIndex, level, classLoc, zone, note, officerNote, online, status, classFileName
    -- rank indices mirror the live ladder: 5 = DAlt, 6 = Raider, 7 = Alt, 9 = Trial
    { "Uzragol-ChromieCraft", "Raider",       6, 80, "Shaman",       "Dalaran", "", "raid lead,ele",         true,  "", "SHAMAN" },
    { "Achera",               "Alt",          7, 80, "Death Knight", "Dalaran", "", "fro",                   false, "", "DEATHKNIGHT" },
    { "Newguy",               "Trial",        9, 80, "Mage",         "Dalaran", "", "no spec set",           true,  "", "MAGE" },
    { "Bosslady",             "Guild Master", 0, 80, "Death Knight", "Dalaran", "", "my officer note,dalt,blo", true, "", "DEATHKNIGHT" },
}

-- Models the client's show-offline filter: with it off, GetNumGuildMembers/GetGuildRosterInfo
-- only expose online members, exactly like the real roster listing.
local showOffline = true
local function visibleFixture()
    if showOffline then return guildFixture end
    local visible = {}
    for _, m in ipairs(guildFixture) do
        if m[9] then visible[#visible + 1] = m end
    end
    return visible
end

local function installGuildApi(canViewNotes)
    env.IsInGuild = function() return true end
    env.CanViewOfficerNote = function() return canViewNotes end
    env.GetGuildRosterShowOffline = function() return showOffline end
    env.SetGuildRosterShowOffline = function(on) showOffline = on and true or false end
    env.GuildRoster = function() end
    env.GetNumGuildMembers = function() return #visibleFixture() end
    env.GetGuildRosterInfo = function(index)
        local m = visibleFixture()[index]
        if not m then return nil end
        return m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]
    end
    showOffline = true
end

H.test("RefreshGuildRoster: not in a guild clears the roster", function()
    env.IsInGuild = function() return false end
    addon.guildRoster = { members = {} }
    addon:RefreshGuildRoster()
    H.eq(addon.guildRoster, nil, "no guild -> nil roster")
end)

H.test("RefreshGuildRoster: full scan with readable notes", function()
    installGuildApi(true)
    addon:RefreshGuildRoster()
    local roster = addon.guildRoster
    H.eq(roster.canViewNotes, true, "notes readable")
    H.eq(roster.memberCount, 4, "member count")
    H.eq(roster.rankNames[0], "Guild Master", "rank ladder recorded")
    H.eq(roster.rankNames[7], "Alt", "rank ladder recorded by index")

    local uzragol = addon:GetGuildMemberProfile("Uzragol")
    H.eq(uzragol.name, "Uzragol", "realm suffix stripped")
    H.eq(uzragol.className, "shaman", "class from classFileName")
    H.eq(uzragol.specName, "elemental", "spec from officer note trailing field")
    H.eq(uzragol.status, "main", "Raider rank -> main")
    H.eq(uzragol.online, true, "online flag")

    local achera = addon:GetGuildMemberProfile("achera")
    H.eq(achera.status, "nil", "Alt rank index maps below the rest")
    H.eq(achera.specName, "frost", "bare token note")
    H.eq(achera.online, false, "offline member scanned")

    local newguy = addon:GetGuildMemberProfile("NEWGUY")
    H.eq(newguy.specName, "", "note without a token -> no spec")
    H.eq(newguy.status, "unknown", "Trial rank, no note -> unknown (resolves as main, flagged for leadership)")

    local bosslady = addon:GetGuildMemberProfile("Bosslady")
    H.eq(bosslady.status, "designatedalt", "note dalt overrides GM rank status")
    H.eq(bosslady.specName, "blood", "spec parsed alongside the override")
end)

H.test("RefreshGuildRoster: unreadable notes leave specs and overrides blank", function()
    installGuildApi(false)
    addon:RefreshGuildRoster()
    H.eq(addon.guildRoster.canViewNotes, false, "flagged for relay")
    H.eq(addon:GetGuildMemberProfile("Uzragol").specName, "", "spec not trusted from blank read")
    H.eq(addon:GetGuildMemberProfile("Achera").status, "nil", "rank mapping still applies (rank is public)")
    H.eq(addon:GetGuildMemberProfile("Bosslady").status, "unknown", "dalt override unavailable without notes; GM rank alone is unknown")
end)

------------------------------------------------------------------------
-- GetRosterProfile: guild-first resolution with the configured roster as
-- guest layer and transition spec-fill
------------------------------------------------------------------------
H.test("GetRosterProfile: guild profile wins over a configured entry", function()
    installGuildApi(true)
    addon:RefreshGuildRoster()
    addon.config.roster = {
        uzragol = { name = "uzragol", className = "shaman", specName = "restoration", status = "nil" },
    }
    local profile = addon:GetRosterProfile("Uzragol")
    H.eq(profile.specName, "elemental", "note spec beats configured spec")
    H.eq(profile.status, "main", "rank status beats configured status")
end)

H.test("GetRosterProfile: configured spec fills a blank note, guild status kept", function()
    installGuildApi(true)
    addon:RefreshGuildRoster()
    addon.config.roster = {
        newguy = { name = "newguy", className = "mage", specName = "fire", status = "designatedalt" },
    }
    local profile = addon:GetRosterProfile("Newguy")
    H.eq(profile.specName, "fire", "spec filled from configured entry")
    H.eq(profile.status, "unknown", "status still rank-derived (Trial=unknown), not configured")
    H.eq(profile.className, "mage", "class from guild")
end)

H.test("GetRosterProfile: no spec fill across a class mismatch", function()
    installGuildApi(true)
    addon:RefreshGuildRoster()
    addon.config.roster = {
        newguy = { name = "newguy", className = "warrior", specName = "fury", status = "main" },
    }
    local profile = addon:GetRosterProfile("Newguy")
    H.eq(profile.className, "mage", "guild class wins")
    H.eq(profile.specName, "", "stale entry for a rerolled name cannot graft its spec")
end)

H.test("GetRosterProfile: guests fall through to the configured roster", function()
    installGuildApi(true)
    addon:RefreshGuildRoster()
    addon.config.roster = {
        puggo = { name = "puggo", className = "rogue", specName = "combat", status = "main" },
    }
    local profile = addon:GetRosterProfile("Puggo")
    H.eq(profile.specName, "combat", "non-guildie resolves from configured roster")
    H.eq(addon:GetRosterProfile("Nobody"), nil, "unknown everywhere -> nil")
    addon.config.roster = {}
end)

H.test("GetGuildMemberProfile: nil-safe", function()
    H.eq(addon:GetGuildMemberProfile(nil), nil, "nil name")
    addon.guildRoster = nil
    H.eq(addon:GetGuildMemberProfile("Uzragol"), nil, "no roster data")
end)

------------------------------------------------------------------------
-- BuildRosterDisplay: guild members are rows, configured layer covers
-- guests only, rows show the merged (resolution) profile
------------------------------------------------------------------------
H.test("BuildRosterDisplay: guild-first with guest layer and live pugs", function()
    installGuildApi(true)
    addon.config = {
        rosterEntries = {
            { name = "puggo", className = "rogue", specName = "combat", status = "main" },
            { name = "newguy", className = "mage", specName = "fire", status = "designatedalt" },
        },
        roster = {},
        rosterImportText = "", lootPriorityText = "", namedItemsText = "",
        lootRules = {}, namedRules = {}, revision = 0,
    }
    addon.config.roster = addon:BuildRosterMap(addon.config.rosterEntries)
    addon:RefreshGuildRoster()

    local pug = { name = "Randomer", className = "warrior", specName = "", status = "nil", descriptor = "warrior" }
    local display = addon:BuildRosterDisplay({ randomer = pug })

    local byName = {}
    for _, entry in ipairs(display) do byName[entry.name] = entry end

    H.eq(#display, 6, "4 guild + 1 guest + 1 live pug")
    H.eq(byName.Uzragol.source, "guild", "guild member sourced from guild")
    H.eq(byName.Uzragol.specName, "elemental", "note spec shown")
    H.eq(byName.Achera.status, "nil", "rank-derived status shown")
    H.eq(byName.Newguy.source, "guild", "configured guildie not duplicated into guest layer")
    H.eq(byName.Newguy.specName, "fire", "row shows the merged profile (configured spec fills blank note)")
    H.eq(byName.Newguy.status, "unknown", "rank status (Trial=unknown) wins over configured status")
    H.eq(byName.puggo.source, "configured", "non-guildie configured entry = guest layer")
    H.eq(byName.Randomer.source, "unconfigured", "live pug row kept")
    H.eq(byName.Randomer.isGuest, true, "present tokenless non-guildie flagged guest")
    H.eq(byName.puggo.isGuest, false, "absent guest-layer entry not flagged")
    H.eq(byName.Randomer.needsAttention, true, "present blank-spec member needs attention")
    H.eq(byName.puggo.needsAttention, false, "absent entries never flagged for attention")
    H.eq(byName.Achera.needsAttention, false, "absent guildie not flagged even with data")
end)

local function fullConfig()
    return {
        rosterEntries = {},
        roster = {},
        rosterImportText = "",
        lootPriorityText = "",
        namedItemsText = "",
        lootRules = {},
        namedRules = {},
        revision = 0,
    }
end

------------------------------------------------------------------------
-- Roster overrides: the click-a-cell layer beats note/rank per-field,
-- persists in config, clears back to durable sources, comm-gated
------------------------------------------------------------------------
H.test("SetRosterOverride/GetRosterProfile: override beats note and rank per-field", function()
    installGuildApi(true)
    addon.config = fullConfig()
    addon:InitializeRoster()
    addon:RefreshGuildRoster()

    addon:SetRosterOverride("Uzragol", "restoration", "")
    local profile = addon:GetRosterProfile("Uzragol")
    H.eq(profile.specName, "restoration", "spec override beats the note's elemental")
    H.eq(profile.status, "main", "status untouched: rank still decides")
    H.eq(profile.overriddenSpec, true, "spec flagged as overridden")
    H.eq(profile.overriddenStatus, nil, "status not flagged")

    addon:SetRosterOverride("Uzragol", "restoration", "designatedalt")
    profile = addon:GetRosterProfile("Uzragol")
    H.eq(profile.status, "designatedalt", "status override beats rank")

    addon:SetRosterOverride("Bosslady", "", "main")
    profile = addon:GetRosterProfile("Bosslady")
    H.eq(profile.status, "main", "override beats the note's dalt token")
    H.eq(profile.specName, "blood", "note spec kept when only status is overridden")

    addon:SetRosterOverride("Uzragol", "", "")
    profile = addon:GetRosterProfile("Uzragol")
    H.eq(profile.specName, "elemental", "clearing restores the note spec")
    H.eq(profile.status, "main", "clearing restores the rank status")
    H.eq(addon:GetRosterOverride("Uzragol"), nil, "empty override record removed")
end)

H.test("AutoClearMatchedOverrides: per-field clear when durable sources catch up", function()
    installGuildApi(true)
    addon.config = fullConfig()
    addon:InitializeRoster()
    addon:RefreshGuildRoster()

    -- spec matches the note (elemental), status does not (Raider rank -> main)
    addon:SetRosterOverride("Uzragol", "elemental", "designatedalt")
    addon:RefreshGuildRoster()
    local override = addon:GetRosterOverride("Uzragol")
    H.eq(override.specName, nil, "matching spec field cleared")
    H.eq(override.status, "designatedalt", "non-matching status field kept")

    addon:SetRosterOverride("Uzragol", "", "main")   -- now matches the rank derivation
    addon:RefreshGuildRoster()
    H.eq(addon:GetRosterOverride("Uzragol"), nil, "fully matching record removed")
end)

H.test("AutoClearMatchedOverrides: blind clients never clear without note data", function()
    installGuildApi(false)
    addon.config = fullConfig()
    addon.db = nil                                   -- no relay cache either
    addon:InitializeRoster()
    addon:RefreshGuildRoster()

    -- Achera: note says fro (invisible to us), Alt rank -> durable status "nil" locally.
    -- Both fields would "match" a blind derivation; neither may clear on rank evidence alone.
    addon:SetRosterOverride("Achera", "frost", "nil")
    addon:RefreshGuildRoster()
    local override = addon:GetRosterOverride("Achera")
    H.eq(override.specName, "frost", "spec kept: no note data")
    H.eq(override.status, "nil", "status kept: rank match alone is not evidence")

    -- A relay-cache hit counts as note data: now both fields clear.
    addon.db = { guildNotesCache = { at = 0, from = "Officer", notes = { achera = { s = "frost" } } } }
    addon:RefreshGuildRoster()
    H.eq(addon:GetRosterOverride("Achera"), nil, "cache-backed derivation clears the record")
    addon.db = nil
end)

H.test("OnRosterOverride: same authority gate as guest upsert, clear converges", function()
    installGuildApi(true)
    addon.config = fullConfig()
    addon:InitializeRoster()
    addon:RefreshGuildRoster()
    addon.roster.lootMasterName = "Onaqui"

    addon:OnRosterOverride("Achera", { "Uzragol", "restoration", "" })
    H.eq(addon:GetRosterOverride("Uzragol"), nil, "Alt-rank sender refused")

    addon:OnRosterOverride("Bosslady", { "Uzragol", "restoration", "" })
    H.eq(addon:GetRosterOverride("Uzragol").specName, "restoration", "leadership sender accepted")

    addon:OnRosterOverride("Onaqui", { "Uzragol", "", "" })
    H.eq(addon:GetRosterOverride("Uzragol"), nil, "ML-sent clear removes the record")
end)

------------------------------------------------------------------------
-- Show-offline borrow: request flips it on, refresh restores the player's
-- setting, and offline-hidden rescans merge instead of clobbering
------------------------------------------------------------------------
H.test("RequestGuildRoster: borrows show-offline and refresh restores it", function()
    installGuildApi(true)
    showOffline = false                     -- player runs with offline hidden
    addon.guildRoster = nil
    addon:RequestGuildRoster()
    H.eq(showOffline, true, "flipped on for the capture")
    addon:RefreshGuildRoster()              -- the reply lands: full scan
    H.eq(showOffline, false, "player's setting restored after the scan")
    H.eq(addon:GetGuildMemberProfile("Achera").online, false, "offline member captured")
    H.eq(addon.guildScanRestore, nil, "borrow cycle closed")
end)

H.test("RefreshGuildRoster: offline-hidden rescan merges over the full map", function()
    installGuildApi(true)
    addon.guildRoster = nil
    addon:RefreshGuildRoster()              -- full scan (show-offline on)
    H.eq(addon:GetGuildMemberProfile("Achera").specName, "frost", "offline member in full map")

    showOffline = false                     -- player's own view: online only
    addon:RefreshGuildRoster()
    local achera = addon:GetGuildMemberProfile("Achera")
    H.eq(achera.specName, "frost", "offline member survives the partial rescan")
    H.eq(achera.online, false, "absent from an online-only listing = offline")
    H.eq(addon:GetGuildMemberProfile("Uzragol").online, true, "online members refreshed")
    showOffline = true
end)

------------------------------------------------------------------------
-- Guest upsert: local write, leadership gate, comm handler
------------------------------------------------------------------------
H.test("UpsertRosterEntry: appends, then replaces by name", function()
    addon.config = fullConfig()
    addon:InitializeRoster()
    H.eq(addon:UpsertRosterEntry({ name = "puggo", className = "mage", specName = "frost", status = "main" }), true, "add accepted")
    H.eq(addon.config.roster.puggo.specName, "frost", "entry queryable via roster map")
    addon:UpsertRosterEntry({ name = "Puggo", className = "mage", specName = "fire", status = "main" })
    H.eq(#addon.config.rosterEntries, 1, "replace, not duplicate (case-insensitive name)")
    H.eq(addon.config.roster.puggo.specName, "fire", "replacement took")
    H.eq(addon:UpsertRosterEntry({ name = "" }), false, "empty name refused")
    H.eq(addon:UpsertRosterEntry(nil), false, "nil refused")
end)

H.test("IsGuildLeadership: rank index at or above the configured cutoff", function()
    installGuildApi(true)
    addon.config = fullConfig()
    addon:RefreshGuildRoster()
    H.eq(addon:IsGuildLeadership("Bosslady"), true, "GM (index 0) is leadership")
    H.eq(addon:IsGuildLeadership("Uzragol"), false, "Raider (index 6) is not")
    H.eq(addon:IsGuildLeadership("Puggo"), false, "non-guildie is not")
    addon.config.guildLeadershipMaxRankIndex = 6
    H.eq(addon:IsGuildLeadership("Uzragol"), true, "cutoff is configurable")
    addon.config.guildLeadershipMaxRankIndex = nil
end)

H.test("OnGuestUpsert: accepted from ML or leadership, refused otherwise", function()
    installGuildApi(true)
    addon.config = fullConfig()
    addon:InitializeRoster()
    addon:RefreshGuildRoster()
    addon.roster.lootMasterName = "Onaqui"

    addon:OnGuestUpsert("Achera", { "puggo", "mage", "frost", "main" })
    H.eq(addon.config.roster.puggo, nil, "Alt-rank sender refused")

    addon:OnGuestUpsert("Bosslady", { "puggo", "mage", "frost", "main" })
    H.eq(addon.config.roster.puggo.specName, "frost", "leadership sender accepted")

    addon:OnGuestUpsert("Onaqui", { "puggo", "mage", "fire", "" })
    H.eq(addon.config.roster.puggo.specName, "fire", "ML sender accepted (not in guild fixture)")

    addon:OnGuestUpsert("Bosslady", { "", "mage", "frost", "main" })
    H.eq(#addon.config.rosterEntries, 1, "empty name ignored")
end)

H.test("IsRaidLeadership / comm gates: raid leader and assistant qualify by raid rank", function()
    installGuildApi(true)
    addon.config = fullConfig()
    addon:InitializeRoster()
    addon:RefreshGuildRoster()
    addon.roster.lootMasterName = nil

    -- Simulate a raid: Leadguy leads (rank 2), Helper assists (rank 1), Grunt is a member.
    env.GetNumRaidMembers = function() return 3 end
    env.GetRaidRosterInfo = function(index)
        if index == 1 then return "Leadguy", 2 end
        if index == 2 then return "Helper", 1 end
        if index == 3 then return "Grunt", 0 end
    end

    H.eq(addon:IsRaidLeadership("Leadguy"), true, "raid leader")
    H.eq(addon:IsRaidLeadership("HELPER"), true, "assistant, case-insensitive")
    H.eq(addon:IsRaidLeadership("Grunt"), false, "plain member")
    H.eq(addon:IsRaidLeadership("Stranger"), false, "not in the raid")

    addon:OnGuestUpsert("Grunt", { "puggo", "mage", "frost", "main" })
    H.eq(addon.config.roster.puggo, nil, "plain member refused")
    addon:OnGuestUpsert("Leadguy", { "puggo", "mage", "frost", "main" })
    H.eq(addon.config.roster.puggo.specName, "frost", "raid leader accepted (no ML, no guild rank)")
    addon:OnRosterOverride("Helper", { "Uzragol", "restoration", "" })
    H.eq(addon:GetRosterOverride("Uzragol").specName, "restoration", "assistant accepted for overrides")
    addon:SetRosterOverride("Uzragol", "", "")

    -- restore the no-group stubs other tests rely on
    env.GetNumRaidMembers = function() return 0 end
    env.GetRaidRosterInfo = function() return nil end
end)

------------------------------------------------------------------------
-- Officer-note relay: payload, cache harvest, blind-client substitution,
-- request/reply handlers
------------------------------------------------------------------------
H.test("BuildGuildNotesPayload: noted members only; nil when blind", function()
    installGuildApi(true)
    addon.db = {}
    addon:RefreshGuildRoster()
    local payload = addon:BuildGuildNotesPayload()
    H.eq(payload.uzragol.s, "elemental", "spec carried")
    H.eq(payload.uzragol.o, nil, "no override for plain members")
    H.eq(payload.bosslady.s, "blood", "override member spec carried")
    H.eq(payload.bosslady.o, "designatedalt", "status override carried")
    H.eq(payload.newguy, nil, "tokenless member omitted")

    installGuildApi(false)
    addon.db = nil
    addon:RefreshGuildRoster()
    H.eq(addon:BuildGuildNotesPayload(), nil, "blind client serves nothing")
end)

H.test("RefreshGuildRoster: note-readers never write the cache", function()
    installGuildApi(true)
    addon.db = {}
    addon:RefreshGuildRoster()
    H.eq(addon:GetGuildNotesCache(), nil, "sighted scan leaves the cache untouched (requester-only writes)")
end)

H.test("RefreshGuildRoster: blind client substitutes cached notes", function()
    installGuildApi(false)
    addon.db = { guildNotesCache = { at = 0, from = "Officer", notes = {
        uzragol = { s = "restoration" },
        bosslady = { o = "designatedalt" },
    } } }
    addon:RefreshGuildRoster()
    H.eq(addon:GetGuildMemberProfile("Uzragol").specName, "restoration", "cached spec applied")
    H.eq(addon:GetGuildMemberProfile("Bosslady").status, "designatedalt", "cached override applied")
    H.eq(addon:GetGuildMemberProfile("Achera").specName, "", "member absent from cache stays blank")
    H.eq(addon:GetGuildMemberProfile("Achera").status, "nil", "rank status intact for uncached")
    addon.db = nil
end)

H.test("relay handlers: request answered only by note-readers, data applies + persists", function()
    local sent = {}
    addon.comm = { Send = function(_, value, dist, target, prio)
        sent[#sent + 1] = { value = value, dist = dist, target = target, prio = prio }
    end }

    installGuildApi(true)
    addon.db = {}
    addon:RefreshGuildRoster()
    addon:OnGuildNotesRequest("Blindml")
    H.eq(#sent, 1, "reader replies")
    H.eq(sent[1].value[1], "GNOTES", "reply tag")
    H.eq(sent[1].dist, "WHISPER", "whispered back")
    H.eq(sent[1].target, "Blindml", "to the requester")
    H.eq(sent[1].value[2].uzragol.s, "elemental", "payload is the structured map")

    installGuildApi(false)
    addon:RefreshGuildRoster()
    addon:OnGuildNotesRequest("Blindml")
    H.eq(#sent, 1, "blind client stays silent")

    addon:RequestGuildNotes()
    H.eq(sent[2].value[1], "GNOTES_REQ", "blind client requests")
    H.eq(sent[2].dist, "GUILD", "on the guild channel")

    installGuildApi(true)
    addon:RefreshGuildRoster()
    addon:RequestGuildNotes()
    H.eq(#sent, 2, "note-reader never requests")

    installGuildApi(false)
    addon.db = {}
    addon:OnGuildNotesData("Stranger", { uzragol = { s = "enhancement" } })
    H.eq(addon.db.guildNotesCache, nil, "non-guildie sender rejected")
    addon:OnGuildNotesData("Bosslady", { uzragol = { s = "enhancement" } })
    H.eq(addon.db.guildNotesCache.from, "Bosslady", "guildmate sender cached, source recorded")
    H.eq(addon:GetGuildMemberProfile("Uzragol").specName, "enhancement", "roster re-derived from new data")
    addon:OnGuildNotesData("Bosslady", "garbage")
    H.eq(addon.db.guildNotesCache.notes.uzragol.s, "enhancement", "non-table payload ignored")

    addon.comm = nil
    addon.db = nil
end)

------------------------------------------------------------------------
-- Legacy roster wipe: unconditional one-time delete at login (Core.lua),
-- deliberately independent of guild data
------------------------------------------------------------------------
H.test("legacy roster wipe: fires once at login, post-stamp guests persist", function()
    local w = F.makeWorld("Wiper", true)
    H.eq(w.env.WeirdLootDB.config.rosterLegacyWipeApplied, true, "stamp set on first login")

    -- Simulate a pre-branch SV arriving at login: legacy entries present, stamp absent.
    w.env.WeirdLootDB.config.rosterEntries = {
        { name = "seme", className = "druid", specName = "restoration", status = "designatedalt" },
    }
    w.env.WeirdLootDB.config.rosterLegacyWipeApplied = nil
    w.addon:PLAYER_LOGIN()
    H.eq(#w.env.WeirdLootDB.config.rosterEntries, 0, "legacy entries wiped at login, no guild data needed")
    H.eq(w.env.WeirdLootDB.config.rosterLegacyWipeApplied, true, "stamp re-set")

    -- Entries added AFTER the stamp are user data and survive subsequent logins.
    w.addon:UpsertRosterEntry({ name = "puggo", className = "rogue", specName = "combat", status = "main" })
    w.addon:PLAYER_LOGIN()
    H.eq(w.env.WeirdLootDB.config.roster.puggo.specName, "combat", "post-stamp guest survives a relog")
end)

------------------------------------------------------------------------
-- Gaining ML authority requests the note relay (mid-raid ML swap)
------------------------------------------------------------------------
H.test("RefreshLootAuthority: false->true ML transition requests guild notes", function()
    -- Framework worlds resolve "Masterlooter" as the raid's ML; being named that is how a
    -- world self-resolves authority through the real RefreshLootAuthority path.
    local w = F.makeWorld("Masterlooter", true)
    local requests = 0
    w.addon.RequestGuildNotes = function() requests = requests + 1 end

    w.addon.roster.isLootMaster = false          -- force a fresh authority transition
    w.addon:RefreshLootAuthority()
    H.eq(w.addon.roster.isLootMaster, true, "world resolves us as ML")
    H.eq(requests, 1, "transition fires one relay request")

    w.addon:RefreshLootAuthority()               -- steady re-resolve: no transition
    H.eq(requests, 1, "no re-request without a transition")
end)

------------------------------------------------------------------------
-- Override catch-up rides the session snapshot: in-raid overrides only,
-- upsert-only on the receiver
------------------------------------------------------------------------
H.test("session snapshot carries in-raid overrides; upsert-only, raid-scoped", function()
    local ml = F.makeWorld("Masterlooter", true)
    local raider = F.makeWorld("Raiderlate", false)
    F.startSession(ml)

    -- Worlds stub live attendance to empty; place one attendee in the session directly.
    local attendee = { name = "Innraid", className = "druid", specName = "", status = "main" }
    ml.addon.session.attendees = { attendee }

    -- ML overrides: one for the attendee, one for someone not in the session.
    ml.addon:SetRosterOverride(attendee.name, "restoration", "designatedalt")
    ml.addon:SetRosterOverride("Absentee", "fire", "")

    -- Raider's pre-existing local override for a third player must survive untouched.
    raider.addon:SetRosterOverride("Thirdguy", "arcane", "")

    F.clearWire()
    ml.addon:BroadcastSession()
    F.flushWireTo(raider)

    local got = raider.addon:GetRosterOverride(attendee.name)
    H.eq(got and got.specName, "restoration", "attendee override arrived via snapshot")
    H.eq(got and got.status, "designatedalt", "both fields carried")
    H.eq(raider.addon:GetRosterOverride("Absentee"), nil, "non-attendee override NOT transmitted")
    H.eq(raider.addon:GetRosterOverride("Thirdguy").specName, "arcane", "unrelated local override untouched")
end)

F.endSuite()
