local addon = WeirdLoot

-- ---------------------------------------------------------------------------
-- Core trace logger
--
-- LootCore emits a structured record for every command and state transition through a
-- nil-safe sink (LootCore:SetLogger). This module wires that sink in-game and persists
-- the records to the WeirdLootDebugLog SavedVariable, so an in-game test run leaves a
-- machine-checkable trace behind. After a scenario, /reload (or log out) to flush the
-- SavedVariable, then run `luajit tests/checklog.lua <path-to-WeirdLoot.lua>` to assert
-- the trace against the core's intended behaviors.
--
-- Record shape (flat, one table per event):
--   { seq, t, ev, ... event fields }
-- ev is one of the core transitions: session, mark, reset, mint, grow, retire, shrink, remove,
--   surface, skip, startRoll, cancel, response, resolve, unlock, deliver; or the comm trace:
--   send (every outgoing message: cmd/bytes/prio), recv-snap / recv-lot / recv-gap (a raider
--   applying a full snapshot / a delta / detecting a dropped delta). The comm events make the
--   wire load (delta vs snapshot, coalescing, priority lane, drift) verifiable from the log.
-- See tests/checklog.lua for the field set each ev carries and the invariants checked.
-- ---------------------------------------------------------------------------

local DEFAULT_MAX = 5000
local ALERT_THROTTLE = 5   -- seconds between repeat chat alerts of the same kind (anti-spam)

local function ensureLog()
    WeirdLootDebugLog = WeirdLootDebugLog or {}
    local log = WeirdLootDebugLog
    if log.enabled == nil then log.enabled = false end   -- opt-in: trace only after /wl debug on
    log.max = log.max or DEFAULT_MAX
    log.seq = log.seq or 0
    log.records = log.records or {}
    return log
end

-- Pure: map a trace record to a human alert string, or nil if the event is not an anomaly worth
-- surfacing. Kept free of Print/throttle/frame state so it is unit-testable and so both the live
-- LogCoreEvent path and any future consumer classify identically. The set is deliberately curated to
-- events that each signal a REAL sync fault, not routine traffic.
function addon:ClassifySyncAnomaly(ev, d)
    d = d or {}
    if ev == "give-up" then
        return string.format("sync recovery gave up (%s/%s) -- your view may be stale",
            tostring(d.kind or "?"), tostring(d.reason or "?"))
    elseif ev == "drop-foreign" then
        return string.format("dropped inbound %s from %s (loot master not resolved to that sender)",
            tostring(d.t), tostring(d.from))
    elseif ev == "recv-snap-stale" then
        return string.format("rejected a stale snapshot (rev %s, holding %s)",
            tostring(d.rev), tostring(d.lastRev))
    elseif ev == "evict-partial" then
        return "an inbound message never fully arrived (a frame was lost)"
    elseif ev == "recv-decode-fail" then
        return "an inbound message arrived corrupt / undecodable"
    elseif ev == "deliver-cb" and d.ok == false then
        return string.format("a delivered item matched no owed award (itemId %s)", tostring(d.itemId))
    elseif ev == "loan-done" and d.via == "unmatched" then
        return string.format("a loan pickup report from %s matched no loan or pending phantom (itemId %s)",
            tostring(d.from), tostring(d.item))
    end
    return nil
end

-- Print a throttled, colored anomaly line the MOMENT a bad case occurs, so the user knows to grab
-- logs instead of finding out later from a dump. Per-key throttle keeps a burst (e.g. repeated
-- drop-foreign) from flooding chat. Gated on debug + alerts (alerts default ON whenever debug is on;
-- a nil alerts field means on, only an explicit `alerts off` mutes it).
function addon:SyncAlert(key, text)
    local log = WeirdLootDebugLog
    if not log or not log.enabled or log.alerts == false then return end
    self._alertAt = self._alertAt or {}
    local now = (GetTime and GetTime()) or 0
    if self._alertAt[key] and (now - self._alertAt[key]) < ALERT_THROTTLE then return end
    self._alertAt[key] = now
    self:Print("|cffff5050[WeirdLoot]|r " .. text .. " |cff808080-- /reload and have the logs checked.|r")
end

-- Append one record. data fields are merged in flat. Tables passed in (awards,
-- priorWinners) are freshly built by the core per call, so storing them by reference is
-- safe -- the core never mutates them after emitting.
function addon:LogCoreEvent(ev, data)
    local log = WeirdLootDebugLog
    if not log or not log.enabled then return end

    log.seq = (log.seq or 0) + 1
    local rec = { seq = log.seq, t = (GetTime and GetTime()) or 0, ev = ev }
    if data then
        for k, v in pairs(data) do rec[k] = v end
    end

    local r = log.records
    r[#r + 1] = rec

    -- Ring buffer: trim in batches so we are not O(n) on every append.
    local max = log.max or DEFAULT_MAX
    if #r > max + 512 then
        local keep = {}
        local first = #r - max + 1
        for i = first, #r do keep[#keep + 1] = r[i] end
        log.records = keep
    end

    -- Inbound liveness: the transport logs a "recv" for every COMPLETE message that arrives, so the
    -- last recv time is the heartbeat-of-life for our inbound channel (CheckInboundStall reads it). A
    -- recv also clears a standing stall alert so a recovered inbound re-arms a fresh warning later.
    if ev == "recv" then
        self._lastInbound = rec.t
        self._lastStallAlert = nil
    end

    -- Live anomaly alerts (option 1): a bad case announces itself in chat the moment it is logged.
    if log.alerts ~= false then
        local text = self:ClassifySyncAnomaly(ev, rec)
        if text then self:SyncAlert(ev, text) end
    end

    if log.verbose then
        self:Print("|cff888888[core]|r " .. ev .. (data and data.id and (" " .. tostring(data.id)) or ""))
    end
end

-- Inbound-silence watchdog (option 2): alerts can only fire on events that HAPPEN, but a dead inbound
-- is the ABSENCE of events. A healthy raider hears an authority heartbeat every 30s, so if we hold an
-- active session with a resolved loot master yet have received nothing for STALL_AFTER, the inbound is
-- almost certainly stalled. Only meaningful for a raider (the ML sends, it does not receive).
local STALL_AFTER = 60          -- 2 missed heartbeats (heartbeat is 30s)
function addon:CheckInboundStall()
    local log = WeirdLootDebugLog
    if not log or not log.enabled or log.alerts == false then return end
    if self:IsAuthorizedLootMaster() then return end                 -- the ML sends; it does not receive
    local session = self.session
    if not (session and session.active) then return end              -- only while we actually hold a session
    local ml = self:GetLootMasterName()
    if not ml or ml == "" then return end                            -- and only once the ML is resolved
    local now = (GetTime and GetTime()) or 0
    local last = self._lastInbound or now
    if (now - last) <= STALL_AFTER then return end
    if self._lastStallAlert and (now - self._lastStallAlert) < STALL_AFTER then return end
    self._lastStallAlert = now
    self:SyncAlert("stall", string.format(
        "no inbound from the loot master in %ds (heartbeat is 30s) -- inbound looks stalled; /reload to recover",
        math.floor(now - last)))
end

-- Drive the watchdog off a light periodic tick (self-contained; the whole check is a cheap no-op
-- unless debug + alerts are on and we are a raider holding a session).
local WATCH_PERIOD = 5
local watchFrame = CreateFrame and CreateFrame("Frame")
if watchFrame then
    watchFrame.elapsed = 0
    watchFrame:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + (dt or 0)
        if self.elapsed < WATCH_PERIOD then return end
        self.elapsed = 0
        addon:CheckInboundStall()
    end)
end

-- Insert a labeled marker. Use before each in-game test scenario to delimit it:
--   /wl debug mark drop-2x
function addon:MarkDebugLog(label)
    local log = ensureLog()
    if not log.enabled then return end
    self:LogCoreEvent("mark", { label = label or "" })
end

function addon:ClearDebugLog()
    local log = ensureLog()
    log.records = {}
    log.seq = 0
    self:LogCoreEvent("session", {
        reason = "clear",
        epoch = (time and time()) or 0,
        player = (UnitName and UnitName("player")) or "?",
        ml = self.lootCore and self.lootCore._mlKey or nil,
        version = (GetAddOnMetadata and GetAddOnMetadata("WeirdLoot", "Version")) or nil,
    })
end

-- Wire the core sink. Call early in PLAYER_LOGIN, before any module touches the core.
function addon:InitializeDebug()
    local log = ensureLog()
    -- Seed the inbound clock so the stall watchdog measures from now, not from epoch 0 (which would
    -- false-alarm on the very first tick before any traffic).
    self._lastInbound = (GetTime and GetTime()) or 0
    if not self.lootCore then return end

    if log.enabled then
        self.lootCore:SetLogger(function(ev, data) addon:LogCoreEvent(ev, data) end)
    else
        self.lootCore:SetLogger(nil)
    end

    -- a fresh session marker each login so the checker can segment runs
    self:LogCoreEvent("session", {
        reason = "login",
        epoch = (time and time()) or 0,
        player = (UnitName and UnitName("player")) or "?",
        ml = self.lootCore._mlKey or nil,
        version = (GetAddOnMetadata and GetAddOnMetadata("WeirdLoot", "Version")) or nil,
    })
end

-- Fault injection (test only): swallow the next N outgoing sync messages so a delta is lost and
-- the receiver hits a real rev gap, or a whole response cycle is dropped to force a resend/give-up.
-- This wraps the WeirdSync channel's transport in the HOST rather than putting any drop logic in
-- the library. The revision still advances on a dropped send, so the receiver sees the gap.
function addon:EnsureSyncDropHook()
    local chan = self.syncChannel
    if not chan or not chan.cb or chan.__dropHooked then return end
    chan.__dropHooked = true
    -- WeirdSync is transport-agnostic: it sends via chan.cb.send. Wrap that to swallow the next N
    -- outgoing sync messages. The revision still advances on a dropped send, so the receiver hits a
    -- real rev gap and resyncs -- exactly the lost-message path, with no drop logic in the library.
    local orig = chan.cb.send
    chan.cb.send = function(value, dist, target, prio)
        if (addon._syncDropCount or 0) > 0 then
            addon._syncDropCount = addon._syncDropCount - 1
            return -- simulate a lost addon message
        end
        return orig(value, dist, target, prio)
    end
end

-- Routed from Core:HandleSlashCommand for "debug ..." subcommands.
function addon:HandleDebugCommand(rest)
    local log = ensureLog()
    rest = string.trim(rest or "")
    local verb, arg = string.match(rest, "^(%S+)%s*(.*)$")
    verb = verb and string.lower(verb) or ""

    if verb == "" then
        self:Print("Core debug trace (off by default; turn it on once and the setting persists). Commands:")
        self:Print("  on / off: start or stop tracing.   status: state and record count.   alerts on/off: live chat warnings on bad cases (default on with debug).")
        self:Print("  mark <label>: insert a marker for easier log chasing.   dump [n]: show last n records (default 12).   clear: wipe it.")
        self:Print("  sync: force a session sync.   drop <n>: (test) drop the next N sync sends.")
        self:Print("  banner: preview the loot banners with sample data (uses the current Options look).")
    elseif verb == "banner" then
        if self.RunBannerDemo then
            self:RunBannerDemo()
        else
            self:Print("The banner UI is not loaded.")
        end
    elseif verb == "status" then
        local drop = self._syncDropCount or 0
        self:Print(string.format("Core debug log: %s, alerts %s, %d record(s), seq %d, cap %d.%s",
            log.enabled and "ON" or "OFF", (log.alerts == false) and "OFF" or "ON",
            #log.records, log.seq or 0, log.max or DEFAULT_MAX,
            drop > 0 and (" Dropping next " .. drop .. " sync msg(s).") or ""))
        if self._lastInbound then
            local age = math.floor(((GetTime and GetTime()) or 0) - self._lastInbound)
            self:Print(string.format("Last inbound sync message: %ds ago (a raider should hear a heartbeat every 30s).", age))
        end
        if self.comm and self.comm.SendRate then
            self:Print(string.format("WeirdComm send rate: %d msg this second (mute risk >= %d, server limit 100).",
                self.comm:SendRate(), self.comm.muteWarn or 80))
        end
    elseif verb == "alerts" then
        local a = string.lower(arg or "")
        if a == "off" then
            log.alerts = false
            self:Print("Live sync alerts OFF (tracing continues).")
        else
            log.alerts = nil   -- nil == default on when debug is enabled
            self:Print("Live sync alerts ON: bad cases print in chat as they happen.")
        end
    elseif verb == "on" then
        log.enabled = true
        self:InitializeDebug()
        self:Print("Core debug log ON. /reload to flush the SavedVariable after a test.")
    elseif verb == "off" then
        log.enabled = false
        if self.lootCore then self.lootCore:SetLogger(nil) end
        self:Print("Core debug log OFF.")
    elseif verb == "clear" then
        self:ClearDebugLog()
        self:Print("Core debug log cleared.")
    elseif verb == "mark" then
        self:MarkDebugLog(arg)
        self:Print("Marked: " .. (arg ~= "" and arg or "(unlabeled)"))
    elseif verb == "drop" then
        local n = tonumber(arg) or 0
        self._syncDropCount = n
        self:EnsureSyncDropHook()
        self:Print(string.format("Sync fault injection: dropping the next %d outgoing sync message(s).", n))
    elseif verb == "sync" then
        self:RequestSessionSync()
        self:Print("Forced a session sync request.")
    elseif verb == "dump" then
        local r = log.records
        local n = math.min(#r, tonumber(arg) or 12)
        self:Print(string.format("Last %d of %d record(s):", n, #r))
        for i = #r - n + 1, #r do
            local rec = r[i]
            if rec then
                self:Print(string.format("  %d %s %s", rec.seq or 0, rec.ev or "?", rec.id or rec.label or ""))
            end
        end
    else
        self:Print("Unknown debug command '" .. verb .. "'. Type /wl debug for options.")
    end
end
