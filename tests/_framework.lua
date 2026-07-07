-- Shared test framework for the WeirdLoot battery.
--
-- Every test file is a Lua script that calls TestHarness():register/run and adds its tests.
-- tests/run.lua is the orchestrator: it requires this framework plus the unit/integration files
-- in order, runs them all, and prints the final tally. Splitting tests by module keeps each file
-- focused and makes regressions easier to localise (a util failure does not get lost in a 3000-line
-- battery).
--
-- What lives here:
--   * pass/fail/check/eq/test  -- the tiny assertion harness, exposed as methods on the harness.
--   * ADDON_FILES              -- the canonical .lua load order (matches WeirdLoot.toc minus UI).
--   * ITEMS, linkFor           -- a fake item table used by the integration tests.
--   * makeWorld(name, isML)    -- builds a mocked WoW env, loads the addon, returns {addon, env, ...}.
--   * drivers                  -- setBag / bagUpdate / startSession / flushWireTo / clearWire /
--                                syncView / putBag / runTrade / runManualTrade / resolveOwedTo /
--                                fireEvent / pump / setPartner / fillBagsExcept.
--
-- Files that need these call TestHarness() to obtain the harness, then call methods on it.
-- Each suite reports its own counts back to the harness so the orchestrator can sum everything.

local M = {}
local self = {}

-- ---------------------------------------------------------------------------
-- assertions
-- ---------------------------------------------------------------------------
-- pass/fail count SCENARIOS (test() blocks), not individual assertions: a property test that loops
-- over hundreds of random inputs is one scenario, pass or fail, not hundreds of "tests". check()
-- only records assertion failures (the FAIL line + the per-scenario failed flag); test() tallies one
-- pass or fail per block. Assertion failures outside any test() block still count directly.
self.pass, self.fail, self.failures = 0, 0, {}
self.current = "?"
self._inTest = false
self._curFailed = false
function self.check(cond, label)
    if cond then return end
    print("  FAIL " .. label)
    self.failures[#self.failures + 1] = self.current .. ": " .. label
    if self._inTest then self._curFailed = true else self.fail = self.fail + 1 end
end
function self.eq(a, b, label)
    self.check(a == b, (label or "") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end
function self.ne(a, b, label)
    self.check(a ~= b, (label or "") .. " (both " .. tostring(a) .. ")")
end
function self.truthy(v, label) self.check(v and true or false, label) end
function self.nil_(v, label) self.check(v == nil, label) end
function self.notNil(v, label) self.check(v ~= nil, label) end
function self.matches(haystack, needle, label)
    -- pure substring match; tests pass strings as needle when they don't want regex
    self.check(type(haystack) == "string" and type(needle) == "string" and haystack:find(needle, 1, true) ~= nil, label)
end

function self.test(name, fn)
    self.current = name
    self._inTest = true
    self._curFailed = false
    print("[" .. name .. "]")
    local ok, err = pcall(fn)
    self._inTest = false
    if not ok then
        self._curFailed = true
        self.failures[#self.failures + 1] = name .. ": ERROR " .. tostring(err)
        print("  ERROR " .. tostring(err))
    end
    if self._curFailed then self.fail = self.fail + 1 else self.pass = self.pass + 1 end
end

function self.report(suiteName)
    print(string.format("=== %s: %d passed, %d failed ===", suiteName, self.pass, self.fail))
    return self.fail == 0
end

-- Each unit suite calls this at entry to print its OWN subtotal (rather than the cumulative
-- pass count, which keeps growing as the orchestrator moves through suites).
function self.beginSuite(suiteName)
    print(string.format("\n--- %s ---", suiteName))
    self._suiteName = suiteName
    self._suitePass = self.pass
    self._suiteFail = self.fail
end
function self.endSuite()
    local pass = self.pass - self._suitePass
    local fail = self.fail - self._suiteFail
    print(string.format("=== %s: %d passed, %d failed ===", self._suiteName or "suite", pass, fail))
    return fail == 0
end

-- ---------------------------------------------------------------------------
-- shared wire (addon-channel transport) between simulated clients. WeirdComm rides on top of
-- SendAddonMessage and chunks under the server's hard 255-byte per-message ceiling. Chat traffic
-- (whispers, RAID_WARNING) is paced separately by ChatThrottleLib, NOT this wire.
-- ---------------------------------------------------------------------------
self.WIRE = {}        -- queue of { prefix, value, dist, target, sender, prio }
-- CLOCK: the mutable harness clock. Tests advance it (CLOCK = CLOCK + n); makeWorld reads it.
self.CLOCK = 1000
-- A thin setter so tests can do F.advanceClock(6) without poking F.CLOCK directly. Keeps the
-- mutable-clock pattern visible (and greppable) at the call site.
function self.advanceClock(n) self.CLOCK = self.CLOCK + (n or 0) end

-- ---------------------------------------------------------------------------
-- a fake fixed item database: itemId -> name. Links embed the itemId (3.3.5 format).
-- ---------------------------------------------------------------------------
self.ITEMS = {
    [40001] = "Mantle of Test", [40002] = "Helm of Test", [40003] = "Ring of Test",
    [40004] = "Token of Test",  [40005] = "Blade of Test",
}
function self.linkFor(itemId)
    return "|cffa335ee|Hitem:" .. itemId .. ":0:0:0:0:0:0:0|h[" .. (self.ITEMS[itemId] or ("Item" .. itemId)) .. "]|h|r"
end

-- ---------------------------------------------------------------------------
-- build a fresh mocked environment + load the addon into it
-- ---------------------------------------------------------------------------
function self.makeWorld(playerName, isML)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.__onUpdates = {}    -- captured OnUpdate handlers, driven by pump()
    env.__closeTrade = 0    -- count of CloseTrade() calls (autoCancel assertions)

    -- frame mock: methods are chainable no-ops EXCEPT SetScript/GetScript (real, so we can
    -- drive OnUpdate timers + OnEvent) and NumLines (numeric, so tooltip scans don't blow up).
    local function newFrame()
        local f = { __scripts = {} }
        return setmetatable(f, { __index = function(self, k)
            if k == "SetScript" then
                return function(_, st, fn) self.__scripts[st] = fn; if st == "OnUpdate" then env.__onUpdates[self] = fn end end
            elseif k == "GetScript" then
                return function(_, st) return self.__scripts[st] end
            elseif k == "NumLines" then
                return function() return 0 end
            elseif k == "GetStringHeight" or k == "GetHeight" or k == "GetWidth"
                or k == "GetFrameLevel" or k == "GetNumPoints" or k == "GetID" then
                -- measurement / numeric getters feed arithmetic (e.g. frame-level + offset,
                -- math.ceil in the popup-height helpers); return a number, not the chainable frame.
                return function() return 0 end
            elseif k == "GetEffectiveScale" or k == "GetScale" or k == "GetAlpha"
                or k == "GetEffectiveAlpha" then
                -- scale/alpha getters also feed arithmetic (banner row layout, fade math); return 1.
                return function() return 1 end
            elseif k == "Show" then
                return function(s) s.__shown = true; return s end
            elseif k == "Hide" then
                return function(s) s.__shown = false; return s end
            elseif k == "IsShown" or k == "IsVisible" then
                -- track real shown state so banner-row tests can assert a close button / row is
                -- shown or hidden. Unset defaults to shown (WoW's default for a fresh frame).
                return function(s) if s.__shown == nil then return true end return s.__shown end
            elseif k == "GetFrameStrata" then
                return function() return "DIALOG" end
            elseif k == "GetName" then
                return function(s) return s.__name end
            elseif k == "Enable" then
                return function(s) s.__disabled = false; return s end
            elseif k == "Disable" then
                return function(s) s.__disabled = true; return s end
            elseif k == "IsEnabled" then
                return function(s) return not s.__disabled end
            end
            -- WoW frame methods are CamelCase; the addon's data fields are lowercase. Return a
            -- chainable no-op for methods, but nil for an UNSET data field (e.g. frame.elapsed),
            -- so `(frame.elapsed or 0) + dt` doesn't try arithmetic on a function.
            if type(k) == "string" and k:match("^%u") then return function(s) return s end end
            return nil
        end })
    end
    env.__newFrame = newFrame

    -- deterministic-ish rng (seeded per world); resolution asserts are invariant-based anyway
    local seed = 0
    for i = 1, #playerName do seed = seed + string.byte(playerName, i) end
    local function rng(m, n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        local r = seed / 2147483648
        if m and n then return m + math.floor(r * (n - m + 1)) end
        return r
    end

    -- Scan-tooltip mock for the TradeDeliver lib's hidden GameTooltip. A bag item may declare
    -- { bound = true, win = secs }; SetBagItem then exposes the matching ITEM_SOULBOUND / trade-window
    -- lines so the engine's isSoulbound / tradeWindowSeconds read real data (default: no extra lines).
    -- globalPrefix names the TextLeftN globals this tooltip exposes, matching what the scanning code
    -- reads (TradeDeliver reads TradeDeliverScanTipTextLeftN; Session's eligible-loot scan reads
    -- WeirdLootScanTooltipTextLeftN). Both engines scrape the SAME line shapes, so one mock serves both.
    local function newScanTip(globalPrefix)
        local tip, cur = newFrame(), nil
        local function rebuild()
            local lines
            if cur and cur.lines then
                lines = cur.lines                       -- verbatim real tooltip (see tooltip_fixtures.lua)
            else
                lines = { "ItemName" }
                if cur and cur.bound then lines[#lines + 1] = env.ITEM_SOULBOUND end
                if cur and cur.win   then lines[#lines + 1] = string.format(env.BIND_TRADE_TIME_REMAINING, cur.win .. " sec") end
            end
            tip.__lines = lines
            for i = 1, 32 do
                env[globalPrefix .. "TextLeft" .. i] = (lines[i] and lines[i] ~= "") and { GetText = function() return lines[i] end } or nil
            end
        end
        tip.ClearLines = function() end
        tip.SetBagItem = function(_, bag, slot) cur = env.__bags[bag] and env.__bags[bag][slot]; rebuild() end
        tip.SetHyperlink = function() cur = nil; rebuild() end
        tip.NumLines = function() return tip.__lines and #tip.__lines or 0 end
        rebuild()
        return tip
    end

    -- ---- WoW API stubs ----
    local SCAN_TIP_NAMES = { TradeDeliverScanTip = true, WeirdLootScanTooltip = true }
    env.CreateFrame = function(_, name)
        local f = SCAN_TIP_NAMES[name] and newScanTip(name) or newFrame()
        if name then env[name] = f; f.__name = name end
        return f
    end
    env.UIParent = newFrame()
    env.WorldFrame = newFrame()
    env.GameTooltip = newFrame()
    env.IsDressableItem = function() return false end   -- banner set-name scan: no set line in tests
    env.SetItemButtonQuality = function() end
    env.DEFAULT_CHAT_FRAME = setmetatable({ AddMessage = function() end }, { __index = function() return function() end end })
    env.GetTime = function() return self.CLOCK end
    env.time = function() return self.CLOCK end
    env.random = rng
    env.randomseed = function() end
    env.math = setmetatable({ random = rng }, { __index = math })
    env.UnitName = function(unit) if unit == "NPC" then return env.__tradePartner end return playerName end
    env.GetUnitName = function() return playerName end
    env.UnitGUID = function() return "Player-0-000000" .. tostring(#playerName) end
    env.GetRealmName = function() return "TestRealm" end
    -- player class is settable per world (default Warrior) so class-gated behavior is testable;
    -- UnitClass returns (localizedName, token) like the real API.
    env.__playerClassName = "Warrior"
    env.__playerClassToken = "WARRIOR"
    env.UnitClass = function() return env.__playerClassName, env.__playerClassToken end
    env.GetNumRaidMembers = function() return 5 end
    env.GetNumPartyMembers = function() return 0 end
    -- index 1 is the loot master so a peer's roster-aware sync (isInRaid(authority)) can see it;
    -- every other slot reports the running player. Self is matched by name regardless.
    env.GetRaidRosterInfo = function(i)
        if i == 1 then return "Masterlooter", 2 end
        return playerName, (isML and 2 or 0)
    end
    env.GetLootMethod = function() return "master", 0, 1 end
    env.IsPartyLeader = function() return isML end
    env.UnitIsRaidLeader = function(unit) return unit == "player" and isML end
    env.UnitIsRaidOfficer = function(unit) return unit == "player" and isML end
    -- Mirror the client's addon metadata: read the real `## Version:` from the .toc so addon.version in
    -- tests matches what ships (the addon pulls its version from here too). cwd is the addon root.
    env.GetAddOnMetadata = function(_, key)
        if key ~= "Version" then return nil end
        local f = io.open("WeirdLoot.toc", "r")
        if not f then return nil end
        local v
        for line in f:lines() do v = line:match("^## Version:%s*(.-)%s*$"); if v then break end end
        f:close()
        return v
    end
    env.SendChatMessage = function() end
    env.SendAddonMessage = function() end
    env.ChatThrottleLib = { SendChatMessage = function() end }
    env.ITEM_QUALITY_COLORS = { [4] = { hex = "|cffa335ee" } }
    env.ITEM_SOULBOUND = "Soulbound"
    env.ITEM_BIND_ON_EQUIP = "Binds when equipped"
    env.ERR_TRADE_COMPLETE = "Trade complete."
    -- This client emits the unique-count pair backwards: the GIVER (the ML running the addon) sees
    -- ERR_TRADE_MAX_COUNT_EXCEEDED even though it's the recipient who holds the dupe.
    env.ERR_TRADE_MAX_COUNT_EXCEEDED = "You have too many of a unique item."
    env.ERR_TRADE_TARGET_MAX_COUNT_EXCEEDED = "Your trade partner has too many of a unique item."
    env.ERR_TRADE_TARGET_BAG_FULL = "Trade failed, target doesn't have enough space."
    env.ERR_TRADE_NOT_ON_TAPLIST = "You may only trade bound items to players that were originally eligible to loot the item."
    env.UI_INFO_MESSAGE = "UI_INFO_MESSAGE"
    env.MAX_TRADABLE_ITEMS = 6
    env.CloseTrade = function() env.__closeTrade = env.__closeTrade + 1 end
    env.AcceptTrade = function() end
    env.__tradePlaced = {}     -- slot -> { id, count }: what the ML hand-placed in the trade window
    env.GetTradePlayerItemLink = function(slot) local it = env.__tradePlaced[slot]; return it and self.linkFor(it.id) or nil end
    env.GetTradePlayerItemInfo = function(slot)
        local it = env.__tradePlaced[slot]
        if not it then return nil end
        return "Item" .. it.id, "Interface\\Icons\\inv_test", it.count or 1
    end
    env.GetItemInfo = function(idOrLink)
        local id = tonumber(idOrLink) or tonumber(string.match(tostring(idOrLink), "item:(%d+)"))
        if not id then return nil end
        local name = self.ITEMS[id] or ("Item" .. id)
        -- name, link, quality, ilvl, reqLevel, class, subclass, stack, equipLoc, texture, sell
        return name, self.linkFor(id), 4, 200, 80, "Armor", "Cloth", 1, "INVTYPE_SHOULDER", "Interface\\Icons\\inv_test", 0
    end
    -- ---- bag + trade-window model (drives the real TradeDeliver engine) ----
    env.__bags = {}                                  -- [bag] = { size=N, [slot]={id,count,link} }
    for b = 0, 4 do env.__bags[b] = { size = 16 } end
    -- equipped slots (gear 1..19, equipped bags 20..23) + keyring for the roll-block checks
    env.NUM_BAG_SLOTS = 4
    env.__equipped = {}                              -- [invSlot] = itemId
    env.GetInventoryItemID = function(_, slot) return env.__equipped[slot] end
    env.ContainerIDToInventoryID = function(bag) return 19 + bag end   -- bag1->20 .. bag4->23
    env.KEYRING_CONTAINER = -2
    env.__keyring = {}                               -- [slot] = itemId (reward keys live here)
    env.GetKeyRingSize = function() return 12 end
    env.__cursor = nil                               -- item held on the cursor
    env.__tradePartner = nil                         -- UnitName("NPC")
    env.__tradeSlots = 0                             -- placed trade slots this window
    -- real 3.3.5a/ChromieCraft wording (captured in-game): one %s, the remaining duration
    env.BIND_TRADE_TIME_REMAINING = "You may trade this item with players that were also eligible to loot this item for the next %s."

    env.GetContainerNumSlots = function(bag) local B = env.__bags[bag]; return B and B.size or 0 end
    env.GetContainerItemID = function(bag, slot)
        if bag == env.KEYRING_CONTAINER then return env.__keyring[slot] end
        local it = env.__bags[bag] and env.__bags[bag][slot]; return it and it.id or nil
    end
    env.GetContainerItemInfo = function(bag, slot)
        local it = env.__bags[bag] and env.__bags[bag][slot]
        if not it then return nil end
        return "Interface\\Icons\\inv_test", it.count, nil, 4   -- texture, count, locked, quality
    end
    env.GetContainerItemLink = function(bag, slot) local it = env.__bags[bag] and env.__bags[bag][slot]; return it and (it.link or self.linkFor(it.id)) or nil end
    env.GetContainerNumFreeSlots = function(bag)
        local B = env.__bags[bag]; if not B then return 0, 0 end
        local used = 0; for s = 1, B.size do if B[s] then used = used + 1 end end
        return B.size - used, 0
    end
    env.ClearCursor = function() env.__cursor = nil end
    env.SplitContainerItem = function(bag, slot, qty)
        local it = env.__bags[bag] and env.__bags[bag][slot]
        if not it then return end
        env.__cursor = { id = it.id, count = qty, link = it.link }
        it.count = it.count - qty
        if it.count <= 0 then env.__bags[bag][slot] = nil end
    end
    env.PickupContainerItem = function(bag, slot)
        if env.__cursor then env.__bags[bag][slot] = env.__cursor; env.__cursor = nil
        else env.__cursor = env.__bags[bag] and env.__bags[bag][slot]; if env.__bags[bag] then env.__bags[bag][slot] = nil end end
    end
    env.TradeFrame_GetAvailableSlot = function() if env.__tradeSlots >= 6 then return nil end; env.__tradeSlots = env.__tradeSlots + 1; return env.__tradeSlots end
    -- the held item moves into trade slot `tslot`; record it so GetTradePlayerItemLink residency reads
    -- reflect reality (the engine's taplist-retry detects a bounce by a slot going empty).
    env.ClickTradeButton = function(tslot) env.__tradePlaced[tslot] = env.__cursor; env.__cursor = nil end
    env.SlashCmdList = {}
    env.StaticPopupDialogs = {}
    env.StaticPopup_Show = function() return newFrame() end
    env.StaticPopup_Hide = function() end
    env.PlaySound = function() end
    env.IsInInstance = function() return false, "none" end
    env.GetInstanceInfo = function() return "none", "none" end
    env.InCombatLockdown = function() return false end

    -- ---- UI globals (only consumed when a suite loads UI.lua; harmless otherwise) ----
    env.tinsert = table.insert
    env.tremove = table.remove
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.format = string.format
    env.Minimap = newFrame()
    env.UISpecialFrames = {}
    env.GetCursorPosition = function() return 0, 0 end
    env.FauxScrollFrame_Update = function() end
    env.FauxScrollFrame_GetOffset = function() return 0 end
    env.FauxScrollFrame_OnVerticalScroll = function() end
    env.UIDropDownMenu_Initialize = function() end
    env.UIDropDownMenu_CreateInfo = function() return {} end
    env.UIDropDownMenu_AddButton = function() end
    env.UIDropDownMenu_SetText = function() end
    env.UIDropDownMenu_SetWidth = function() end
    env.UIDropDownMenu_JustifyText = function() end
    env.UIDropDownMenu_EnableDropDown = function() end
    env.UIDropDownMenu_DisableDropDown = function() end

    -- ---- LibStub + libs ----
    local libs = {}
    -- Fake WeirdComm: pass-through transport for the WeirdSync (WLSYNC) lane. Records the logical
    -- VALUE on the wire (deep-copied to mimic serialize-on-send). The real codec/chunk/pace is
    -- covered by tests/weirdcomm.lua; the real-lib seam by tests/integration.lua.
    local function wcDeepcopy(v)
        if type(v) ~= "table" then return v end
        local o = {}; for k, val in pairs(v) do o[k] = wcDeepcopy(val) end; return o
    end
    libs["WeirdComm-1.0"] = {
        NewChannel = function(_, prefix, opts)
            return {
                Send = function(_, value, dist, target, prio)
                    self.WIRE[#self.WIRE + 1] = { prefix = prefix, value = wcDeepcopy(value), dist = dist, target = target, sender = playerName, prio = prio }
                end,
                Tick = function() end,
            }
        end,
    }
    local LibStub = setmetatable({
        NewLibrary = function(_, name) libs[name] = libs[name] or {}; return libs[name] end,
        GetLibrary = function(_, name) return libs[name] end,
    }, { __call = function(_, name) return libs[name] end })
    env.LibStub = LibStub

    -- ---- load the addon files into this env ----
    local private = {}
    for _, file in ipairs(self.ADDON_FILES) do
        local chunk = assert(loadfile(file))
        setfenv(chunk, env)
        chunk("WeirdLoot", private)
    end

    if os.getenv("WLDEBUG") then
        env.DEFAULT_CHAT_FRAME = setmetatable({ AddMessage = function(_, m) io.stderr:write(tostring(m) .. "\n") end }, { __index = function() return function() end end })
    end
    local addon = env.WeirdLoot
    addon.InitializeUI = function() end       -- UI not loaded in the harness
    -- LootBanner.lua (the win display) is excluded from the harness: it builds animation frames at
    -- load time that the lightweight CreateFrame stub does not model. Stub the entry points the
    -- resolve path calls, recording items so resolution tests can assert the banner payload.
    addon._bannerItems = {}
    addon.AddLootBannerItem = function(_, item) addon._bannerItems[#addon._bannerItems + 1] = item end
    addon.ShowLootBanner = function() end
    -- roll cards (the drops banner): record adds/closes/choice-syncs so the live-wiring tests can
    -- assert them. The banner is the default roll surface in-game; the harness default REFUSES
    -- cards so the long-standing popup battery keeps exercising the fallback popup path unchanged.
    -- Card-path tests opt in with _rollBannerAccept = true.
    addon._rollBannerItems = {}
    addon._rollBannerClosed = {}
    addon._rollBannerChoices = {}
    addon._rollBannerAccept = false
    addon.AddRollBannerItem = function(_, item)
        if not addon._rollBannerAccept then return false end
        addon._rollBannerItems[#addon._rollBannerItems + 1] = item
        return true
    end
    addon.CloseRollBannerCard = function(_, key)
        addon._rollBannerClosed[#addon._rollBannerClosed + 1] = key
    end
    addon._rollBannerRefreshes = {}
    addon.RefreshRollBannerCard = function(_, key, link, icon)
        addon._rollBannerRefreshes[#addon._rollBannerRefreshes + 1] = { key = key, link = link, icon = icon }
    end
    addon.SetRollBannerCardChoice = function(_, key, bracket)
        addon._rollBannerChoices[#addon._rollBannerChoices + 1] = { key = key, bracket = bracket }
    end
    addon:PLAYER_LOGIN()
    if os.getenv("WLDEBUG") then env.WeirdLootDB.payoutDebug = true end
    local shippedDefaults = {
        rollDuration = addon.db and addon.db.options and addon.db.options.rollDuration,
        resultPopupAutoCloseEnabled = addon.db and addon.db.options and addon.db.options.resultPopupAutoCloseEnabled,
        resultPopupAutoCloseSeconds = addon.db and addon.db.options and addon.db.options.resultPopupAutoCloseSeconds,
        autoStartRoll = addon.db and addon.db.options and addon.db.options.autoStartRoll,
    }

    -- ---- force the loot-authority + scan into a deterministic test state ----
    addon.roster = addon.roster or {}
    addon.roster.isLootMaster = isML
    addon.roster.lootMasterName = "Masterlooter"
    addon.lootCore:SetML("Masterlooter")
    addon.bagSettleAt = 0                     -- bags considered settled
    addon.db.autoRoll = true
    addon.db.options = addon.db.options or {}
    addon.db.options.autoStartRoll = false    -- harness baseline: fresh loot stays pending unless a test opts in

    -- inject eligible bag counts directly (skip tooltip scraping)
    addon.__bag = {}                          -- itemId -> count (test-controlled)
    local function bagLinkCounts(self2)
        local out = {}
        for id, n in pairs(self2.__bag) do if n > 0 then out[self.linkFor(id)] = n end end
        return out
    end
    -- Keep the REAL bag scans reachable for the bag-walk suite (unit_bagslots) so the iterator
    -- conversion is characterized against actual GetContainerItemLink/tooltip walking, not the
    -- injected shortcut. The default world still uses the shortcut for everything else.
    addon._realBuildBagSnapshot = addon.BuildBagSnapshot
    addon._realBuildTradeableEpicCounts = addon.BuildTradeableEpicCounts
    addon.BuildTradeableEpicCounts = bagLinkCounts
    addon.BuildBagSnapshot = bagLinkCounts
    addon.BuildManualScanCounts = bagLinkCounts

    -- give every responder a 'main' roster profile so resolution is pure roll (no status cut).
    -- Responses are keyed by normalized (lowercase) name; the real roster maps that back to a
    -- display name, so we capitalize here to mirror that (winners come out proper-cased).
    local function cap(s) return (tostring(s):gsub("^%l", string.upper)) end
    addon.GetRosterProfile = function(_, name) return { name = cap(name), className = "Warrior", specName = "Arms", status = "main" } end
    addon.GetAttendee = function(_, name) return { name = cap(name), className = "Warrior", specName = "Arms", status = "main" } end
    addon.GetAttendees = function() return {} end

    return { addon = addon, env = env, player = playerName, shippedDefaults = shippedDefaults }
end

-- ---------------------------------------------------------------------------
-- the canonical .lua load order, grouped by folder to mirror WeirdLoot.toc. Omits the UI tabs
-- (heavy FrameXML, loaded by the UI smoke suite via UI_FILES) and Debug.lua (the harness provides its
-- own LogCoreEvent stub). Popups.lua is the one UI-folder file the core battery loads (lightweight
-- StaticPopupDialogs registration, no parse-time deps).
-- ---------------------------------------------------------------------------
self.ADDON_FILES = {
    "Libs/WeirdSync-1.0/WeirdSync-1.0.lua",
    "Core.lua",
    "Core/Util.lua", "Core/Config.lua", "Core/Comm.lua", "Core/Roster.lua", "Core/GuildRoster.lua",
    "Data/BlacklistPresets.lua",
    "Data/BlacklistPresets/Priest.lua", "Data/BlacklistPresets/Mage.lua",
    "Data/BlacklistPresets/Warrior.lua", "Data/BlacklistPresets/DeathKnight.lua",
    "Data/BlacklistPresets/Hunter.lua", "Data/BlacklistPresets/Rogue.lua",
    "Data/BlacklistPresets/Shaman.lua", "Data/BlacklistPresets/Druid.lua",
    "Data/BlacklistPresets/Paladin.lua", "Data/BlacklistPresets/Warlock.lua",
    "Data/ItemInfo.lua", "Data/LootPrios.lua",
    "Loot/LootCore.lua", "Loot/Resolver.lua", "Loot/Session.lua", "Loot/LiveRoll.lua", "Loot/AutoLoot.lua",
    "Trade/TradeDeliver.lua", "Trade/Payout.lua",
    "UI/Popups.lua",
}

-- UI is normally omitted (heavy FrameXML, irrelevant to loot accounting), but the UI-load smoke
-- suite loads it into the same mocked env to prove it loads + InitializeUI runs. Keep this list in
-- the toc's UI load order; when UI.lua is split into UI/<tab>.lua files, list them all here.
self.UI_FILES = { "UI/UI.lua", "UI/Common.lua", "UI/Export.lua", "UI/Minimap.lua", "UI/RaidersTab.lua", "UI/ResultsTab.lua", "UI/MasterTab.lua", "UI/OptionsTab.lua", "UI/LootTab.lua", "UI/GuildSpec.lua" }

function self.loadUI(w)
    for _, path in ipairs(self.UI_FILES) do
        local chunk = assert(loadfile(path), "loadfile failed: " .. path)
        setfenv(chunk, w.env)
        chunk()
    end
end

-- Load the real UI/LootBanner.lua into a world so its win-row engine (addRow / updateRowLifetimes,
-- close-button timing) can be driven and asserted directly, rather than stubbed. The banners are
-- named frames, reachable as w.env.WeirdLootAwardedBanner / WeirdLootDropsBanner.
function self.loadBanner(w)
    local chunk = assert(loadfile("UI/LootBanner.lua"), "loadfile failed: UI/LootBanner.lua")
    setfenv(chunk, w.env)
    chunk()
end

-- ---------------------------------------------------------------------------
-- drivers shared across the integration tests
-- ---------------------------------------------------------------------------
function self.setBag(w, itemId, count) w.addon.__bag[itemId] = count end
-- set the world's player class (token like "DRUID"); drives UnitClass for class-gated behavior
function self.setClass(w, token, name) w.env.__playerClassToken = token; w.env.__playerClassName = name or token end
function self.bagUpdate(w) w.addon:OnBagUpdate() end

function self.startSession(w) w.addon:StartLootSession() end

function self.lotsFor(w, itemId) return w.addon.lootCore:lotsForItem(itemId) end
function self.openLot(w, itemId) return w.addon.lootCore:openLotForItem(itemId) end

function self.owedCount(w)
    local n = 0
    local owed = w.addon.payout and w.addon.payout.db and w.addon.payout.db.owed or {}
    for _, entry in pairs(owed) do for _, it in ipairs(entry.items or {}) do n = n + (it.count or 0) end end
    return n
end

-- deliver the shared wire from one world to another (raider mirror). All WeirdLoot traffic (session
-- mirror + live roll) now rides ONE WeirdComm channel as a decoded VALUE; the addon's RouteComm
-- dispatcher routes by tag (sync -> WeirdSync, else -> live-roll). Honour WHISPER targeting.
function self.flushWireTo(target, fromSender)
    local msgs = self.WIRE; self.WIRE = {}
    for _, m in ipairs(msgs) do
        if m.value and m.sender ~= target.player then
            local sender = m.sender or fromSender or "Masterlooter"
            if m.dist ~= "WHISPER" or m.target == target.player then
                target.addon:RouteComm(m.value, sender, m.dist or "RAID")
            end
        end
    end
end
function self.clearWire() self.WIRE = {} end

-- canonical "what a client should see" view of the synced ledger: every lot the ML would
-- broadcast (resolved or live, not removed), as id|itemId|state|liveCount|responses|winners.
-- The ML reads its authoritative awards/LiveCount; a raider reads the fields it received.
function self.syncView(w)
    local core = w.addon.lootCore
    local isML = w.addon:IsAuthorizedLootMaster()
    local rows = {}
    for _, lot in ipairs(core:All()) do
        local live = isML and core:LiveCount(lot.id) or (lot.count or 0)
        if (not lot.removed) and (lot.state == core.STATE.RESOLVED or live > 0) then
            local resp = {}
            for k, v in pairs(lot.responses or {}) do resp[#resp + 1] = k .. "=" .. v end
            table.sort(resp)
            local winners = {}
            if isML then
                for _, a in ipairs(lot.awards or {}) do if a.winner then winners[#winners + 1] = a.winner end end
            elseif lot.record then
                for _, win in ipairs(lot.record.winners or {}) do winners[#winners + 1] = win end
            end
            rows[#rows + 1] = table.concat({ lot.id, tostring(lot.itemId), lot.state, tostring(live),
                table.concat(resp, ","), table.concat(winners, ",") }, "|")
        end
    end
    table.sort(rows)
    return table.concat(rows, "\n")
end

-- deterministic, reproducible PRNG for the fuzz sequence (independent of any world's rng)
function self.makeRng(seed)
    return function(m, n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        local r = seed / 2147483648
        if m and n then return m + math.floor(r * (n - m + 1)) end
        return r
    end
end

-- physical bag (drives TradeDeliver), distinct from the eligible-count model (drives reconcile)
-- opts (optional): drive the scan-tooltip mock for this slot. { bound = true, win = secs } synthesizes
-- soulbound / trade-window lines; { lines = {...} } supplies a verbatim real tooltip (tooltip_fixtures).
-- Default: a plain tradeable item.
function self.putBag(w, bag, slot, id, count, opts)
    -- elig (optional): a { [partnerName]=true } set marking the ONLY players the server recorded as
    -- eligible to loot THIS copy. nil means eligible to everyone. flushTaplistBounces reads it to mimic
    -- the server bouncing an ineligible BoP copy out of the trade window. The engine never sees it (no
    -- client API exposes the taplist), exactly as in-game.
    w.env.__bags[bag][slot] = { id = id, count = count, link = self.linkFor(id),
                                bound = opts and opts.bound, win = opts and opts.win,
                                lines = opts and opts.lines, elig = opts and opts.elig }
end
function self.fillBagsExcept(w)             -- occupy every empty slot so no split target exists
    for b = 0, 4 do local B = w.env.__bags[b]; for s = 1, B.size do if not B[s] then B[s] = { id = 99999, count = 1, link = self.linkFor(99999) } end end end
end
function self.fireEvent(w, event, arg1, arg2)
    local fr = w.addon.payout and w.addon.payout.frame
    local fn = fr and fr.__scripts and fr.__scripts.OnEvent
    if fn then fn(fr, event, arg1, arg2) end
end
function self.pump(w, dt) for f, fn in pairs(w.env.__onUpdates) do fn(f, dt or 1.0) end end
function self.setPartner(w, name) w.env.__tradePartner = name; w.env.__tradeSlots = 0; w.env.__tradePlaced = {} end

-- Mimic the server bouncing every taplist-ineligible BoP copy out of the open trade window. Models the
-- REAL packet ordering that broke the first in-game attempt: the UI_ERROR lands FIRST, while the copy is
-- still resident in the slot, and the eviction (slot clears, copy returns to bags) arrives a frame
-- later. A synchronous residency check at error time would therefore still see the copy and never retry;
-- the engine defers its scan past the eviction. Loops until no ineligible copy remains in the window.
function self.flushTaplistBounces(w)
    local env = w.env
    for _ = 1, 32 do                                   -- guard against a pathological non-convergence
        local hitSlot, hitItem
        for slot, it in pairs(env.__tradePlaced) do
            if it and it.elig and not it.elig[env.__tradePartner] then hitSlot, hitItem = slot, it; break end
        end
        if not hitSlot then return end
        self.fireEvent(w, "UI_ERROR_MESSAGE", env.ERR_TRADE_NOT_ON_TAPLIST)  -- error first: copy still resident
        env.__tradePlaced[hitSlot] = nil               -- a frame later: the bounced copy leaves the slot
        for b = 0, 4 do                                -- and returns to the first free bag slot
            local B = env.__bags[b]; local placed = false
            for s = 1, B.size do if not B[s] then B[s] = hitItem; placed = true break end end
            if placed then break end
        end
        self.pump(w, 0.3)   -- now the engine's deferred scan fires, sees the empty slot, places the next copy
    end
end

-- full trade sequence the engine reacts to: partner opens trade -> (bag updates for any splits)
-- -> settle timer fires the fill -> the trade completes.
function self.runTrade(w, partner)
    self.setPartner(w, partner)
    self.fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do self.fireEvent(w, "BAG_UPDATE", b) end   -- satisfy any split's wait
    self.pump(w, 1.0)                                         -- SETTLE/FALLBACK -> finalize + place
    self.fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)
end

-- a manual hand-trade: partner opens, the ML drags the item in itself (no auto-fill), both accept,
-- the trade completes. Mirrors what happens when the ML trades an owed item by hand.
function self.runManualTrade(w, partner, itemId, count)
    self.setPartner(w, partner)
    self.fireEvent(w, "TRADE_SHOW")
    w.env.__tradePlaced = { { id = itemId, count = count or 1 } }
    self.fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    self.fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)
    w.env.__tradePlaced = {}
end

-- resolve a single-copy lot to a non-ML winner and return its lot id (commonly-needed setup)
function self.resolveOwedTo(w, itemId, winner)
    self.setBag(w, itemId, 1); self.bagUpdate(w)
    local lot = self.openLot(w, itemId)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, winner, "ms")
    w.addon:ResolveLiveRoll(lot.id)
    return lot.id
end

-- Return the harness to the calling suite.
-- Cache M in a global so successive dofile()s of this file share ONE harness (pass/fail
-- accumulate across the integration battery and all unit suites). Without this, every suite
-- would get a fresh M and the orchestrator's final tally would only see the last suite.
if _G.__WL_TEST_HARNESS == nil then
    _G.__WL_TEST_HARNESS = setmetatable({ get = function() return self end }, { __call = function() return self end })
end
M = _G.__WL_TEST_HARNESS

return _G.__WL_TEST_HARNESS