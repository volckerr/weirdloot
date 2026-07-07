-- Core: the addon's bootstrap and event hub. It owns the event frame and fans WoW events out to
-- the modules; loot accounting itself lives in LootCore (see LootCore.lua's header for the model).
--
-- Event entry points (this file registers and dispatches them):
--   BAG_UPDATE                         -> OnBagUpdate (the single hinge: ALL loot enters the model
--                                         only through the bag. AutoLoot routes master loot into the
--                                         ML's bags and stops; the resulting BAG_UPDATE is what the
--                                         scanner observes. Only the ML reconciles bag reality into
--                                         the ledger; raiders mirror via the synced snapshot.)
--   RAID_ROSTER_UPDATE / PARTY_*       -> RefreshRoster + RefreshLootAuthority (who is the ML)
--   PLAYER_LOGIN / ENTERING_WORLD      -> init, restore the session, recheck authority once data settles
--   CHAT_MSG_ADDON                     -> WeirdComm reassembles -> Comm.lua RouteComm (live-roll / WeirdSync)
--   LOOT_OPENED / LOOT_BIND_CONFIRM    -> AutoLoot;   TRADE_SHOW / bag deltas -> TradeDeliver
--
-- Authority: the ML owns the live ledger and runs all mutation (reconcile/resolve/payout); raiders
-- hold a read-only mirror. RefreshLootAuthority resolves ML status from GetLootMethod + the raid
-- roster; everything downstream gates on IsAuthorizedLootMaster.

local addonName, addon = ...

WeirdLoot = WeirdLoot or {}
addon = WeirdLoot

addon.name = addonName or "WeirdLoot"
addon.prefix = "WeirdLoot"
-- The .toc `## Version:` is the single source of truth; pull it at load instead of duplicating the
-- string here (which drifted from the toc and had to be bumped in lockstep). Debug.lua already reads
-- it the same way. Fallback keeps a non-nil string if the metadata API is ever absent.
addon.version = (GetAddOnMetadata and GetAddOnMetadata(addon.name, "Version")) or "dev"
addon.callbacks = {}
addon.events = CreateFrame("Frame")

-- Optional structured trace sink. Debug.lua replaces this with the real recorder when loaded;
-- without it (the test harness, or a client with debug off-by-file) it stays a no-op so comm and
-- core callers can log unconditionally without guarding.
function addon:LogCoreEvent() end

SLASH_WEIRDLOOT1 = "/weirdloot"
SLASH_WEIRDLOOT2 = "/wl"
SlashCmdList.WEIRDLOOT = function(msg)
    if WeirdLoot and WeirdLoot.HandleSlashCommand then
        WeirdLoot:HandleSlashCommand(msg)
    end
end

local defaultRosterImportText = ""

-- PresetRegistry: the 6 functions GetWhitelistPresets / SaveCustomWhitelistPreset /
-- DeleteCustomWhitelistPreset + the same 3 for blacklists differ only in which built-in
-- table they read from and which SavedVariable sub-table they write to. Build all 6 from one
-- helper to keep the wiring in one place; new kinds (e.g. "watchlist") are one line.
local function installPresetRegistry(kind)
    local cap          = kind:sub(1, 1):upper() .. kind:sub(2)   -- "Whitelist" / "Blacklist"
    local builtinKey   = kind .. "Presets"                       -- self.whitelistPresets / self.blacklistPresets
    local customField  = "custom" .. cap .. "Presets"            -- db.options.customWhitelistPresets / customBlacklistPresets

    -- Get(kind)Presets: union of built-in presets (from the data files) and user-saved
    -- custom presets, sorted case-insensitively by name.
    addon["Get" .. cap .. "Presets"] = function(self)
        local list = {}
        local playerClass = select(2, UnitClass("player"))   -- "DRUID"; class token gates built-ins
        for _, preset in ipairs(self[builtinKey] or {}) do
            -- Class-gated: a built-in tagged with a class only shows for that class (a personal
            -- filter, so a Druid is never offered Mage presets). Classless built-ins always show.
            if not preset.class or preset.class == playerClass then
                -- Built-ins hold their item names as an array (`items`); join to the newline string
                -- the editor expects here, at the single boundary that consumes it. Tolerate a legacy
                -- `text` field too so a built-in defined either way still renders.
                local text = preset.text or table.concat(preset.items or {}, "\n")
                list[#list + 1] = { name = preset.name, text = text, builtin = true }
            end
        end
        local custom = (self.db and self.db.options and self.db.options[customField]) or {}
        for name, text in pairs(custom) do
            list[#list + 1] = { name = name, text = text or "", builtin = false }
        end
        table.sort(list, function(a, b) return string.lower(a.name or "") < string.lower(b.name or "") end)
        return list
    end

    -- SaveCustom(kind)Preset: validates the name, refuses to overwrite a built-in, writes
    -- to the custom field, and prints a confirmation. Returns true on success.
    addon["SaveCustom" .. cap .. "Preset"] = function(self, name, text)
        if type(name) ~= "string" or name == "" then return false end
        self.db.options = self.db.options or {}
        self.db.options[customField] = self.db.options[customField] or {}
        for _, preset in ipairs(self[builtinKey] or {}) do
            if preset.name == name then
                self:Print("Cannot overwrite built-in preset: " .. name)
                return false
            end
        end
        self.db.options[customField][name] = text or ""
        self:Print("Saved " .. kind .. " preset: " .. name)
        return true
    end

    -- DeleteCustom(kind)Preset: refuses to delete a missing or empty entry. Returns true on
    -- success.
    addon["DeleteCustom" .. cap .. "Preset"] = function(self, name)
        if type(name) ~= "string" or name == "" then return false end
        self.db.options = self.db.options or {}
        self.db.options[customField] = self.db.options[customField] or {}
        if self.db.options[customField][name] == nil then return false end
        self.db.options[customField][name] = nil
        self:Print("Deleted " .. kind .. " preset: " .. name)
        return true
    end
end

installPresetRegistry("whitelist")
installPresetRegistry("blacklist")

local function onEvent(self, event, ...)
    if addon[event] then
        addon[event](addon, ...)
    end
end

function addon:RegisterCallback(eventName, handler)
    if type(handler) ~= "function" then
        return
    end

    self.callbacks[eventName] = self.callbacks[eventName] or {}
    table.insert(self.callbacks[eventName], handler)
end

function addon:TriggerCallback(eventName, ...)
    local handlers = self.callbacks[eventName]
    if not handlers then
        return
    end

    for _, handler in ipairs(handlers) do
        handler(...)
    end
end

function addon:Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffWeirdLoot|r: " .. tostring(message))
end

function addon:GetSessionOwnerKey()
    -- The two pieces are normalized separately so the format is stable even if the canonical
    -- form ever shifts (e.g. trimming more chars). util:NormalizeKey is the single normalizer.
    local util = self.util
    local playerName = UnitName("player") or "unknown"
    local realmName = GetRealmName and GetRealmName() or "realm"
    return string.format("%s-%s", util:NormalizeKey(playerName), util:NormalizeKey(realmName))
end

function addon:RefreshAll()
    self:RefreshRoster()
    self:RefreshLootAuthority()
    self:RefreshSessionItems()
    self:TriggerCallback("STATE_UPDATED")
end

function addon:PLAYER_LOGIN()
    WeirdLootDB = addon.util:EnsureDefaults(WeirdLootDB, {
        testMode = false,        -- in-city testing: treat ANY bag item as session loot
        autoRoll = false,        -- newly-looted/traded-in items auto-start a live roll (default OFF)
        config = {
            rosterImportText = defaultRosterImportText,
            rosterEntries = {},   -- guest/override layer only; guild data is the roster source
            lootPriorityText = addon.defaultLootPriorityText,
            namedItemsText = addon.defaultNamedItemsText,
            roster = {},
            lootRules = {},
            namedRules = {},
            revision = 0,
        },
    })

    -- Options + UI state are PER-CHARACTER: different characters want different filters, popup
    -- positions, and sort prefs. They live in WeirdLootCharDB (## SavedVariablesPerCharacter); the
    -- self.db proxy below routes .options/.ui here, so the rest of the addon still reads
    -- self.db.options / self.db.ui unchanged. config + session stay account-wide (see PLAYER_LOGIN).
    WeirdLootCharDB = addon.util:EnsureDefaults(WeirdLootCharDB, {
        options = {
            resultPopupAutoCloseEnabled = true,
            resultPopupAutoCloseSeconds = 10,
            forceKeepResultPopup = true,   -- LM only: finished-loot winner popups stay open for the
                                           -- whole raid, overriding each player's own auto-close setting.
            rollDuration = 30,
            rollBatchSize = 5,
            autoStartRoll = true,  -- LM only; mutex with db.autoRoll and autoSkipRoll. New loot
                                    -- broadcasts the DROP immediately (NEW -> ROLLING, no popup gate).
            autoSkipRoll = false,   -- LM only; mutex with db.autoRoll and autoStartRoll. New loot
                                    -- moves straight to SKIPPED (auto-resurfaces on the next scan).
            hideUnusableRolls = false,   -- raider opt-in: hide roll popups for items your CLASS can't use
                                         -- (armor/weapon proficiency only; unique-owned/quest-done still show)
            hidePassedWins = false,      -- raider opt-in: suppress the win banner for items you explicitly
                                         -- passed on (you already opted out, so skip the result). Off by default.
            whitelistEnabled = false,
            whitelistText = "",
            blacklistEnabled = false,
            blacklistText = "",
            customBlacklistPresets = {},
            customWhitelistPresets = {},
            minimapButtonHidden = false,
            minimapButtonAngle = 200,
            rollResultTooltipAnchor = "RIGHT",   -- where roll-popup hover tooltips dock: RIGHT/LEFT/TOP/BOTTOM/CURSOR
            explanationTooltipsEnabled = true,   -- hover tooltips that spell things out (e.g. the roll brackets, popup + loot tab)
            bannerMinimal = false,               -- loot banner look: minimalist (per-card badge, no chrome) vs full
            bannerInstant = false,               -- loot banner animations: snappy (instant) vs smooth
            bannerMLSide = "RIGHT",              -- which card edge the ML roll controls (End/Cancel) hang off: RIGHT/LEFT
            bannerLocked = false,                -- lock the loot banner in place (drag disabled)
        },
        ui = {
            selectedTab = "loot",
            lootSortMode = "recent",       -- "recent" = mint order, newest first; name/type/slot/info via header click
            lootSortDir = "asc",           -- header cycle: asc -> desc -> recent (off)
            lootSortRecentApplied = true,  -- fresh installs already start on the recent default; see migration
            rosterSortMode = "name",
            rosterRaidOnly = true,         -- Raiders tab defaults to the raid view; the full guild is a toggle away
            resultsSortMode = "default",   -- "default" = resolution time, newest first; "name" or "winner" via header click
            resultsSortDir = "asc",        -- header cycle: asc -> desc -> default (off)

            lootUsabilitySort = false,
            liveRollPopups = {
                point = "TOP",
                relativePoint = "TOP",
                x = 260,
                y = -170,
            },
            frame = {
                x = 0,
                y = 0,
            },
        },
    })

    -- Older versions stored options/ui account-wide. They are per-character now (fresh defaults, no
    -- migration), so drop any legacy account-side copy rather than re-serialize it into the account
    -- WTF forever. After this, options/ui touch the per-character file ONLY.
    WeirdLootDB.options = nil
    WeirdLootDB.ui = nil

    WeirdLootSessionDB = addon.util:EnsureDefaults(WeirdLootSessionDB, {
        activeSession = nil,
        activeSessions = {},
        history = {},
        epochHigh = 0,   -- monotonic session-epoch high-water (see NextEpoch); makes handoff ordering clock-proof
    })

    if WeirdLootDB and WeirdLootDB.config then
        -- Prio lists ship as code defaults and the ML is authoritative, so updates to them must reach
        -- characters that already have a saved config. A character's saved prio text is never empty
        -- after first run, so a plain "copy the defaults in" either never updates them or clobbers a
        -- deliberate manual edit on every login. The stamp breaks the tie: we remember the default
        -- text we last wrote, and re-apply only when the current default differs from it. Unchanged
        -- defaults leave a manually edited list untouched; a changed default (or a fresh install,
        -- stamp nil) re-seeds once.
        if WeirdLootDB.config.appliedLootDefault ~= addon.defaultLootPriorityText then
            WeirdLootDB.config.lootPriorityText  = addon.defaultLootPriorityText
            WeirdLootDB.config.appliedLootDefault = addon.defaultLootPriorityText
        end
        if WeirdLootDB.config.appliedNamedDefault ~= addon.defaultNamedItemsText then
            WeirdLootDB.config.namedItemsText     = addon.defaultNamedItemsText
            WeirdLootDB.config.appliedNamedDefault = addon.defaultNamedItemsText
        end

        if type(WeirdLootDB.config.rosterEntries) == "table" then
            for _, entry in ipairs(WeirdLootDB.config.rosterEntries) do
                if string.lower(string.trim(entry.name or "")) == "volcker"
                    and string.lower(string.trim(entry.className or "")) == "warlock"
                    and string.lower(string.trim(entry.specName or "")) == "affliction" then
                    entry.specName = "demonology"
                end
            end
        end

        if type(WeirdLootDB.config.rosterImportText) == "string" and WeirdLootDB.config.rosterImportText ~= "" then
            WeirdLootDB.config.rosterImportText = string.gsub(
                WeirdLootDB.config.rosterImportText,
                "([Vv][Oo][Ll][Cc][Kk][Ee][Rr]%s*,%s*[Ww][Aa][Rr][Ll][Oo][Cc][Kk]%s+)[Aa][Ff][Ff][Ll][Ii][Cc][Tt][Ii][Oo][Nn]",
                "%1demonology"
            )
        end

        -- One-time wipe of the legacy shipped roster: the guild IS the roster source (rank ->
        -- status, officer note -> spec; see Core/GuildRoster.lua) and the old saved entries were
        -- shipped defaults, not user data. Unconditional at load -- deliberately independent of
        -- guild data, which is not available yet and must never gate a deletion. Entries added
        -- AFTER the stamp (guests via the Raiders tab) persist as the guest layer.
        if not WeirdLootDB.config.rosterLegacyWipeApplied then
            WeirdLootDB.config.rosterEntries = {}
            WeirdLootDB.config.rosterImportText = ""
            WeirdLootDB.config.rosterLegacyWipeApplied = true
        end
    end

    -- One-time flip to newest-mint-first Loot ordering for characters created before it existed
    -- (their saved lootSortMode is "name"). Stamp so a later manual header click is not re-clobbered
    -- each login; fresh installs ship with the stamp already set.
    if WeirdLootCharDB.ui and not WeirdLootCharDB.ui.lootSortRecentApplied then
        WeirdLootCharDB.ui.lootSortMode = "recent"
        WeirdLootCharDB.ui.lootSortDir = "asc"
        WeirdLootCharDB.ui.lootSortRecentApplied = true
    end

    -- self.db reads account fields (testMode/autoRoll/config) straight through, but routes .options
    -- and .ui to the per-character WeirdLootCharDB. Keeping the field names means every existing
    -- self.db.options / self.db.ui access is unchanged, and the account DB never carries an options/ui
    -- copy (no stale duplicate). config/session stay account-wide.
    self.db = setmetatable({}, {
        __index = function(_, k)
            if k == "options" or k == "ui" then return WeirdLootCharDB[k] end
            return WeirdLootDB[k]
        end,
        __newindex = function(_, k, v)
            if k == "options" or k == "ui" then WeirdLootCharDB[k] = v else WeirdLootDB[k] = v end
        end,
    })
    self.sessionDb = WeirdLootSessionDB
    self.bagSettleAt = GetTime() + 5   -- ignore bag deltas (staged loading) until bags settle this login

    if self.sessionDb.activeSession ~= nil then
        local legacySession = self.sessionDb.activeSession
        local legacyOwnerKey = legacySession and legacySession.ownerKey
        self.sessionDb.activeSessions = self.sessionDb.activeSessions or {}
        if legacyOwnerKey and legacyOwnerKey ~= "" and self.sessionDb.activeSessions[legacyOwnerKey] == nil then
            self.sessionDb.activeSessions[legacyOwnerKey] = legacySession
        end
        self.sessionDb.activeSession = nil
    end

    local guidSeed = tonumber(string.match(UnitGUID("player") or "0", "(%d+)$")) or 0
    if type(randomseed) == "function" then
        randomseed(time() + guidSeed)
    elseif math and type(math.randomseed) == "function" then
        math.randomseed(time() + guidSeed)
    end

    if self.InitializeDebug then self:InitializeDebug() end  -- wire the core trace sink before anything touches the ledger (optional module)
    self:InitializeConfig()
    self:InitializeRoster()
    self:InitializeSession()
    self:InitializeComm()
    self:InitializeResolver()
    self:InitializePayout()
    self:InitializeLiveRoll()
    self:InitializeUI()

    self.events:RegisterEvent("RAID_ROSTER_UPDATE")
    self.events:RegisterEvent("PARTY_MEMBERS_CHANGED")
    self.events:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
    self.events:RegisterEvent("PLAYER_ENTERING_WORLD")
    self.events:RegisterEvent("BAG_UPDATE")
    self.events:RegisterEvent("PLAYER_REGEN_ENABLED")
    self.events:RegisterEvent("LOOT_OPENED")
    self.events:RegisterEvent("LOOT_BIND_CONFIRM")
    self.events:RegisterEvent("GUILD_ROSTER_UPDATE")
    self:RequestGuildRoster()

    self:RefreshAll()
    self:ResumePayoutMode()      -- a session restored from SavedVariables keeps payout mode on
    self:Print("Loaded. Use /weirdloot to open the window.")
end

-- Zone-in prompt (RCLootCouncil model): on entering a raid instance as the loot
-- master with no session running, offer to start one. Declining is remembered until
-- we leave the raid, so it isn't re-asked on every loading screen inside the instance.

function addon:MaybePromptStartSession()
    self.raidPrompt = self.raidPrompt or { declined = false }
    local _, instanceType = IsInInstance()
    if instanceType ~= "raid" then
        self.raidPrompt.declined = false       -- reset once we've left the raid
        return
    end
    if self.session.active then return end
    if not self:IsAuthorizedLootMaster() then return end
    if self.raidPrompt.declined then return end
    StaticPopup_Show("WEIRDLOOT_START_SESSION")
end

-- Delayed loot-master re-check (RCLootCouncil's NewMLCheck pattern). At login the client
-- hasn't received the loot method / raid roster yet, so a single check can miss ML status,
-- and PARTY_LOOT_METHOD_CHANGED won't re-fire if nothing actually changed. 3.3.5 has no
-- C_Timer, so we drive a few re-checks off an OnUpdate frame over the first few seconds.
local AUTH_RETRY_TIMES = { 0.5, 1.0, 1.5, 3.0, 6.0, 9.0, 12.0, 15.0 }   -- re-check: fast early, then every 3s, over the first ~15s
local authRetry = CreateFrame("Frame")
authRetry:Hide()
authRetry:SetScript("OnUpdate", function(frame, dt)
    frame.elapsed = (frame.elapsed or 0) + dt
    -- Fire a payout resume that deferred because bags were still loading; ResumePayoutMode no-ops
    -- until bags settle, then runs once (reconcile owes against bags, re-whisper). Cheap: a boolean
    -- in the common case, and this frame only runs in the ~15s login/zone window before it hides.
    if addon._payoutResumePending then addon:ResumePayoutMode() end
    local target = AUTH_RETRY_TIMES[frame.index or 1]
    if not target then frame:Hide(); return end
    if frame.elapsed >= target then
        frame.index = (frame.index or 1) + 1
        addon:RecheckLootAuthority()
    end
end)

function addon:ScheduleAuthorityRecheck()
    authRetry.elapsed = 0
    authRetry.index = 1
    authRetry:Show()
end

-- Periodic eligible-loot reconcile. A BoP trade window expiring fires no game event, so without a
-- timed re-scan an item that lapsed while idle stays on the list as rollable. Out of combat only --
-- tooltip scans + ledger churn shouldn't run mid-fight; we just wait for the next period.
local RECONCILE_PERIOD = 60
local reconcileTicker = CreateFrame("Frame")
reconcileTicker.elapsed = 0
reconcileTicker:SetScript("OnUpdate", function(frame, dt)
    frame.elapsed = (frame.elapsed or 0) + dt
    if frame.elapsed < RECONCILE_PERIOD then return end
    frame.elapsed = 0
    if InCombatLockdown and InCombatLockdown() then return end
    addon:ReconcileLootNow()        -- no-op unless ML with an active session
end)

-- Re-evaluate authority; if we only NOW resolve as ML (data finally arrived), run the
-- ML-on-login work the early PLAYER_ENTERING_WORLD check skipped.
function addon:RecheckLootAuthority()
    local was = self.roster.isLootMaster
    local hadML = self.roster.lootMasterName
    self:RefreshLootAuthority()
    if self.roster.isLootMaster and not was then
        self:AutoBroadcastSession(true)
        self:ResumePayoutMode()
        self:RestorePendingPopups()
        self:MaybePromptStartSession()
    elseif not self.roster.isLootMaster and not hadML and self.roster.lootMasterName then
        -- Raider: the loot master only just resolved (the client had no loot-method / roster data
        -- at login). Now that we know who to ask, request the session. This is the post-load
        -- authority timing the sync library deliberately does not own; we drive it from here.
        self:RequestSessionSync()
    end
end

function addon:PLAYER_ENTERING_WORLD()
    self:RefreshAll()
    if self:IsAuthorizedLootMaster() then
        self:OnBagUpdate()              -- drop items whose trade window lapsed while away, before broadcasting
        self:AutoBroadcastSession(true)
        self:RestorePendingPopups()     -- re-show pending items the ML hadn't decided on
    else
        self:RequestSessionSync()
    end
    self:MaybePromptStartSession()
    self:ScheduleAuthorityRecheck()     -- catch ML status that lands after the data settles
end

-- Coalesce roster events. RAID_ROSTER_UPDATE / PARTY_MEMBERS_CHANGED fire in bursts (and more of them
-- the larger the raid), and each one re-runs a full roster rebuild + loot-master re-resolution. Running
-- that per event during churn is wasteful and, worse, a mid-burst GetRaidRosterInfo read can transiently
-- misresolve the ML, which flaps authority and fires spurious sync requests / forced snapshots. Debounce
-- onto a trailing deadline so the pipeline runs ONCE after the roster settles (also when the reads are
-- consistent). The window is deliberately wider than the bag debounce: roster bursts run longer and this
-- path is not latency-sensitive (nothing protected runs here).
local ROSTER_SETTLE = 0.5
local rosterDebounce = CreateFrame("Frame")
rosterDebounce:Hide()
rosterDebounce:SetScript("OnUpdate", function()
    if not addon._rosterRefreshAt or GetTime() < addon._rosterRefreshAt then return end
    addon._rosterRefreshAt = nil
    rosterDebounce:Hide()
    addon:RunRosterRefresh()
end)

-- Arm/re-arm the coalesced roster refresh. The deadline pushes forward on every new roster event, so the
-- refresh lands ROSTER_SETTLE after the LAST event in a burst.
function addon:ScheduleRosterRefresh()
    self._rosterRefreshAt = GetTime() + ROSTER_SETTLE
    rosterDebounce:Show()
end

-- The roster pipeline, run once per settled burst.
function addon:RunRosterRefresh()
    self:RefreshRoster()
    self:RefreshLootAuthority()
    self:MaybeRecheckOnJoin()
    self:TriggerCallback("ROSTER_UPDATED")
end

function addon:RAID_ROSTER_UPDATE()
    self:ScheduleRosterRefresh()
end

function addon:PARTY_MEMBERS_CHANGED()
    self:ScheduleRosterRefresh()
end

-- Being added to a raid mid-session does NOT fire PLAYER_ENTERING_WORLD, so the post-login auth-recheck
-- retry loop never starts. If the raid roster name cache lags on the join event, the ML never resolves
-- and the raider silently never syncs. Kick the same retry loop on a join while we are a non-ML in a
-- master-loot raid with the ML still unresolved -- it re-reads the roster until the name lands, then the
-- resolution transition in RefreshLootAuthority requests the session.
function addon:MaybeRecheckOnJoin()
    if self.roster.isLootMaster or self.roster.lootMasterName then return end
    local method = GetLootMethod()
    if method == "master" then
        self:ScheduleAuthorityRecheck()
    end
end

function addon:PARTY_LOOT_METHOD_CHANGED()
    self:RefreshLootAuthority()
    self:TriggerCallback("AUTHORITY_UPDATED")
    self:MaybePromptStartSession()      -- becoming ML in a raid offers a session too
end

function addon:BAG_UPDATE()
    -- Coalesce the loot-time BAG_UPDATE burst into one scan; see ScheduleBagReconcile. Out-of-band
    -- triggers (loot tab open, Start Roll, expiry timer) still run OnBagUpdate synchronously.
    self:ScheduleBagReconcile()
end

function addon:PLAYER_REGEN_ENABLED()
    self:TriggerCallback("STATE_UPDATED")
end

function addon:HandleSlashCommand(msg)
    local command = string.lower(string.trim(msg or ""))
    if command == "start" then
        self:StartLootSession()
    elseif command == "winners" or command == "winner" or command == "export winners" or command == "export winner" then
        self:ExportWinners()
    elseif command == "log" or command == "export log" then
        self:ExportLog()
    elseif command == "end" or command == "stop" or command == "clear" then
        self:ClearSession()
        self:Print("Loot session ended.")
    elseif command == "scan" then
        self:RefreshSessionItems(true)
    elseif command == "payout" then
        self:StartPayout()
    elseif command == "payout stop" or command == "payout off" then
        self:StopPayout()
    elseif command == "payout clear" then
        if self.payout then
            self.payout:StopPayout()
            self.payout:ClearOwed()
            self:Print("Payout ledger cleared.")
            if self.ui and self.ui.masterPanel then self:RefreshMasterTab() end
        end
    elseif command == "test" then
        self.db.testMode = not self.db.testMode
        self:Print("Test mode " .. (self.db.testMode
            and "ON - every item in your bags counts as session loot (city testing)."
            or "OFF - only tradable epics count."))
        self:RefreshSessionItems(true)
    elseif command == "guild" then
        self:RequestGuildRoster()
        local roster = self.guildRoster
        if not roster then
            self:Print("Guild roster: not in a guild (or no data yet; try again in a moment).")
        else
            local withSpec, total = 0, 0
            for _, member in pairs(roster.members) do
                total = total + 1
                if member.specName ~= "" then withSpec = withSpec + 1 end
            end
            self:Print(string.format("Guild roster: %d members, officer notes %s, %d with a spec token.",
                total, roster.canViewNotes and "readable" or "NOT readable (relay needed)", withSpec))
            if not roster.canViewNotes then
                local cache = self:GetGuildNotesCache()
                if cache and next(cache.notes or {}) then
                    local entries = 0
                    for _ in pairs(cache.notes) do entries = entries + 1 end
                    local ageMinutes = math.floor(((time() or 0) - (cache.at or 0)) / 60)
                    self:Print(string.format("  using relayed notes from %s (%d entries, %dm old); re-requesting.",
                        tostring(cache.from), entries, ageMinutes))
                else
                    self:Print("  no relayed note data yet; requesting from online officers.")
                end
                self:RequestGuildNotes()
            end
            for rankIndex = 0, 9 do
                local rankName = roster.rankNames[rankIndex]
                if rankName then
                    self:Print(string.format("  rank %d: %s -> %s", rankIndex, rankName,
                        self:GuildRankStatus(rankIndex)))
                end
            end
        end
    elseif command == "debug" or string.sub(command, 1, 6) == "debug " then
        local rest = string.match(string.trim(msg or ""), "^%S+%s*(.*)$")
        self:HandleDebugCommand(rest)
    elseif command == "autoroll" then
        self.db.autoRoll = not self.db.autoRoll
        if self.db.autoRoll then
            self.db.options.autoStartRoll = false  -- mutex with auto-start (also enforced in the Options UI)
            self.db.options.autoSkipRoll = false   -- mutex with auto-skip
        end
        self:Print("Auto-roll (auto-open the Start/Skip pending popup) on new loot "
            .. (self.db.autoRoll and "ON." or "OFF (lots stay in the loot tab; start them manually)."))
        if self.RefreshOptionsTab then self:RefreshOptionsTab() end
    elseif command == "autostart" then
        self.db.options.autoStartRoll = not self.db.options.autoStartRoll
        if self.db.options.autoStartRoll then
            self.db.autoRoll = false               -- mutex with auto-roll
            self.db.options.autoSkipRoll = false   -- mutex with auto-skip
        end
        self:Print("Auto-start a live roll on new loot " .. (self.db.options.autoStartRoll
            and "ON (broadcasts the DROP immediately, no Start/Skip popup)." or "OFF."))
        if self.RefreshOptionsTab then self:RefreshOptionsTab() end
    elseif command == "autoskip" then
        self.db.options.autoSkipRoll = not self.db.options.autoSkipRoll
        if self.db.options.autoSkipRoll then
            self.db.autoRoll = false               -- mutex with auto-roll
            self.db.options.autoStartRoll = false  -- mutex with auto-start
        end
        self:Print("Auto-skip new loot " .. (self.db.options.autoSkipRoll
            and "ON (new loot lands as Skipped; revisit from the loot tab)."
            or "OFF."))
        if self.RefreshOptionsTab then self:RefreshOptionsTab() end
    elseif command == "deer" or string.sub(command, 1, 5) == "deer " then
        local name = string.match(string.trim(msg or ""), "^%S+%s+(.+)$")
        if name and string.trim(name) ~= "" then
            self.db.deer = string.trim(name)
            self:Print("Disenchanter set to " .. self.db.deer .. " (non-epic BoE auto-routes there).")
        else
            self.db.deer = nil
            self:Print("Disenchanter cleared.")
        end
        if self.RefreshOptionsTab then self:RefreshOptionsTab() end
    else
        self:ToggleMainFrame()
    end
end

addon.events:SetScript("OnEvent", onEvent)
addon.events:RegisterEvent("PLAYER_LOGIN")
