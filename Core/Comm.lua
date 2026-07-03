local addon = WeirdLoot
local util = addon.util

-- Is a player still in our group? Drives WeirdSync's roster-aware give-up: a targeted re-send
-- stops the moment its recipient genuinely leaves (rather than retrying a phantom).
local function isInRaid(name)
    if not name or name == "" then return false end
    local key = util:NormalizeKey(name)
    if key == util:NormalizeKey((UnitName and UnitName("player")) or "") then return true end
    local raid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    for i = 1, raid do
        local rn = GetRaidRosterInfo(i)
        if rn and util:NormalizeKey(rn) == key then return true end
    end
    local party = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    for i = 1, party do
        local pn = UnitName("party" .. i)
        if pn and util:NormalizeKey(pn) == key then return true end
    end
    return false
end

-- A lot on the wire is a structured value tagged "L" with NAMED fields (not a positional array):
-- see addon:BuildLotValue / addon:DecodeLotValue below. The tag lets a mixed snapshot (meta /
-- attendee / lot lines) be demultiplexed on apply; deltas reuse the same shape. WeirdSync treats
-- the whole value as opaque and never inspects it; LibSerialize+LibDeflate carry it.

-- Stash the ML's roll countdown for a lot so the raider's roll-popup restore (SyncRollPopups, run
-- on ledgerChanged) can show the true remaining time. Must be set BEFORE the apply that emits
-- ledgerChanged. Kept off the core lot to keep the core free of UI/timing state.
function addon:StashRollRemaining(lot, remaining)
    self._rollRemaining = self._rollRemaining or {}
    if lot.state == self.lootCore.STATE.ROLLING and remaining then
        self._rollRemaining[lot.id] = remaining
    else
        self._rollRemaining[lot.id] = nil
    end
end

-- inbound tags that belong to the WeirdSync reliability layer; everything else is live-roll.
local SYNC_TAGS = { SNAP = true, D = true, H = true, RQ = true, AK = true }

function addon:InitializeComm()
    self.syncPrefix = "WLSYNC"  -- retained only as the WeirdSync registry key (not a wire prefix now)

    local WeirdComm = LibStub and LibStub("WeirdComm-1.0", true)
    local WeirdSync = LibStub and LibStub("WeirdSync-1.0", true)
    if not (WeirdComm and WeirdComm.NewChannel and WeirdSync and WeirdSync.NewChannel) then
        self:Print("WeirdComm/WeirdSync not found; raid sync disabled.")
        return
    end

    -- ONE transport for ALL of WeirdLoot's traffic (session mirror + live roll). WeirdComm sends each
    -- logical message as a Lua VALUE: serialize -> compress -> chunk <=255B -> pace by message count
    -- under ChromieCraft's per-player mute -> reassemble. A single shared pacer keeps our TOTAL addon
    -- output under the mute (the server counts every prefix together), and the priority queue lets an
    -- ALERT roll popup preempt a BULK ledger sync. Inbound is routed by message tag (RouteComm).
    self.comm = WeirdComm:NewChannel(self.prefix, {
        send       = function(p, text, dist, target) if SendAddonMessage then SendAddonMessage(p, text, dist, target) end end,
        onMessage  = function(value, sender, dist) self:RouteComm(value, sender, dist) end,
        getTime    = function() return (GetTime and GetTime()) or 0 end,
        selfName   = util:GetPlayerName("player"),
        log        = function(ev, data) self:LogCoreEvent(ev, data) end,
        -- Debug-mode notification: the server gives no signal for an addon-flood mute (it only silences
        -- our REGULAR chat + winner-whispers), so the only place we can warn is our own send rate.
        warn       = function(n)
            if WeirdLootDebugLog and WeirdLootDebugLog.enabled then
                self:Print(string.format("|cffff5555[WeirdComm]|r mute risk: %d addon msgs this second (server limit 100; would silence chat/whispers).", n))
            end
        end,
    })

    -- The reliable session mirror is delegated to WeirdSync: it owns the revision, snapshot/delta
    -- framing, gap detection + resync, request retry, targeted-send ack, and give-up. It is transport
    -- agnostic: we hand it cb.send (route to the shared channel) and feed inbound via RouteComm.
    self.syncChannel = WeirdSync:NewChannel(self.syncPrefix, {
        -- Generation for this load: a wall-clock stamp, unique per client load (a reload/relog is always
        -- seconds apart and time() never resets), so a raider can tell an ML that just reloaded (rev back
        -- to 0, same session epoch) from a stale message, and rebaselines instead of rejecting it.
        nonce          = tostring((time and time()) or (GetTime and GetTime()) or 0),
        send           = function(value, dist, target, prio) self.comm:Send(value, dist, target, prio) end,
        isAuthority    = function() return self:IsAuthorizedLootMaster() end,
        authorityName  = function() return self:GetLootMasterName() end,
        rosterContains = function(name) return isInRaid(name) end,
        epoch          = function() return self:GetCurrentSession().id or "" end,
        buildSnapshot  = function(emit) self:SyncBuildSnapshot(emit) end,
        applySnapshot  = function(lines, ep) self:SyncApplySnapshot(lines, ep) end,
        applyLine      = function(fields) self:SyncApplyLine(fields) end,
        log            = function(ev, data) self:LogCoreEvent(ev, data) end,
        -- Retry schedule: flatter than a steep exponential so a resync after a gap/reload recovers on a
        -- steady cadence. 1.0s first resend lets a message land before we retry; 1.3x growth keeps a
        -- ~24s give-up horizon. Heartbeat re-announces rev every 30s so a quiet-session miss self-heals.
        backoffBase    = 1.0,
        backoffMul     = 1.3,
        maxAttempts    = 8,
        heartbeat      = 30,
    })

    -- (WeirdComm self-wires CHAT_MSG_ADDON receive + self-drives its pacer Tick; WeirdSync drives
    -- its own retry Tick. Nothing more to wire here.)
end

-- Route a reassembled inbound value to the right handler. WeirdComm already drops our exact self-echo;
-- the normName check here also covers a realm-suffixed echo. Sync tags go to WeirdSync; the rest are
-- live-roll messages.
function addon:RouteComm(value, sender, distribution)
    if type(value) ~= "table" then return end
    if util:NormalizeKey(util:GetPlayerName("player") or "") == util:NormalizeKey(sender or "") then return end
    if SYNC_TAGS[value[1]] then
        self.syncChannel:OnReceive(sender, value)
    else
        self:HandleCommMessage(sender, value)
    end
end

-- Live-roll send. The message is a VALUE { command, arg1, arg2, ... } carried by the shared WeirdComm
-- channel over SendAddonMessage (no manual string codec, no separate addon-channel lane). Args are
-- stringified to preserve the string semantics the handlers were written against.
function addon:SendLargeMessage(command, values, distribution, target, prio)
    if not self.comm then return end
    local value = { command }
    for _, v in ipairs(values or {}) do value[#value + 1] = tostring(v) end
    self.comm:Send(value, distribution, target, prio or "BULK")
    self:LogCoreEvent("send", { cmd = command, prio = prio or "BULK", dist = distribution })
end

-- responses map <-> compact string. Player keys are normalized (no '|'/':'/','/'='), so a
-- "player=tier" list joined by ',' rides safely inside one encoded field.
local function encodeResponses(responses)
    local parts = {}
    for player, tier in pairs(responses or {}) do
        parts[#parts + 1] = tostring(player) .. "=" .. tostring(tier)
    end
    return table.concat(parts, ",")
end

local function decodeResponses(str)
    local out = {}
    for pair in string.gmatch(str or "", "[^,]+") do
        local player, tier = string.match(pair, "^(.-)=(.+)$")
        if player then out[player] = tier end
    end
    return out
end

-- Render a received resolved lot's result record LOCALLY from its itemId + winner names. The
-- wire never carries rendered text or links (the core's rule): name/link/icon come from this
-- client's GetItemInfo, and summary/detail are formatted here. Winner names are the only
-- non-derivable data, so they ride the wire; everything else is local.
local function renderRemoteRecord(lotId, itemId, count, winners)
    local name, link, icon = util:ItemRender(itemId)
    name = name or link or ("item:" .. tostring(itemId))
    local qty = count or 1
    local winnersText = #winners > 0 and table.concat(winners, ", ") or "No winner"
    local summary = qty >= 2
        and string.format("%s x%d -> %s", name, qty, winnersText)
        or string.format("%s -> %s", name, winnersText)
    local lines = { "Item: " .. name .. (qty >= 2 and string.format(" x%d", qty) or ""), "", "Winner(s):" }
    if #winners == 0 then
        lines[#lines + 1] = "No winner"
    else
        for _, w in ipairs(winners) do lines[#lines + 1] = w end
    end
    return {
        itemId = lotId, realItemId = itemId,
        itemName = name, itemLink = link, itemIcon = icon, quantity = qty,
        winners = winners, winnersText = winnersText, winner = winners[1] or "No winner",
        summary = summary, detailText = table.concat(lines, "\n"), locked = true,
    }
end

-- The result BREAKDOWN (who rolled which bracket and what, the prioritized roll-off, the winners
-- with their rolls, plus the spec-priority / LC context) is built by the ML; the raider can't derive
-- it, so it rides the wire as a nested table on the lot value. Only the non-derivable pieces (names,
-- responses, rolls, spec/LC text) cross: class/spec/status come from the synced roster and item text
-- from local GetItemInfo, so no rendered text/links go on the wire. LibSerialize dedups the names
-- (which recur heavily across rollers/winners/lots); no manual delimiters, no positional fields.
function addon:BuildRecordValue(record)
    if not record then return nil end
    local function rows(list, pick)
        local out = {}
        for _, d in ipairs(list or {}) do out[#out + 1] = pick(d) end
        return out
    end
    return {
        allRollerDetails = rows(record.allRollerDetails, function(d)
            return { name = d.name, responseType = d.responseType, rollText = d.rollText, isNamed = d.isNamed or nil }
        end),
        rollDetails = rows(record.rollDetails, function(d)
            return { name = d.name, roll = d.roll, auto = d.auto or nil, isNamed = d.isNamed or nil }
        end),
        winnerDetails = rows(record.winnerDetails, function(d)
            return { name = d.name, roll = d.roll, auto = d.auto or nil, isNamed = d.isNamed or nil }
        end),
        specPriorityText = record.specPriorityText,
        lcNamesText = record.lcNamesText,
        isLootCouncil = record.isLootCouncil or nil,
    }
end

-- Rebuild a full result record (raider side) from the minimal record plus the breakdown table. Names
-- ride the wire; class/spec/status are filled from this client's roster, and the detail text is
-- rendered here through the SAME BuildResultDetail the ML uses, so the two read identically.
local function renderRemoteRecordFull(self, lotId, itemId, count, winners, rv)
    local record = renderRemoteRecord(lotId, itemId, count, winners)
    local function profile(name)
        return self:GetAttendee(name) or self:GetRosterProfile(name) or {}
    end

    record.allRollerDetails = {}
    for _, d in ipairs(rv.allRollerDetails or {}) do
        local prof = profile(d.name)
        record.allRollerDetails[#record.allRollerDetails + 1] = {
            name = d.name, responseType = d.responseType, rollText = d.rollText, isNamed = d.isNamed or false,
            className = prof.className, specName = prof.specName, status = prof.status,
        }
    end

    record.rollDetails = {}
    for _, d in ipairs(rv.rollDetails or {}) do
        local prof = profile(d.name)
        record.rollDetails[#record.rollDetails + 1] = {
            name = d.name, roll = d.roll, auto = d.auto or false, isNamed = d.isNamed or false,
            className = prof.className, specName = prof.specName, status = prof.status,
        }
    end

    record.winnerDetails = {}
    for _, d in ipairs(rv.winnerDetails or {}) do
        record.winnerDetails[#record.winnerDetails + 1] = {
            name = d.name, roll = d.roll, auto = d.auto or false, isNamed = d.isNamed or false, className = profile(d.name).className,
        }
    end

    record.specPriorityText = rv.specPriorityText
    record.lcNamesText = rv.lcNamesText
    record.isLootCouncil = rv.isLootCouncil or false
    if record.isLootCouncil then
        record.winnersText = "Loot Council"
    end
    record.detailText = self:BuildResultDetail(record)
    return record
end

-- Seconds left on a rolling lot's countdown, from the ML's authoritative roll deadline. Sent so a
-- raider restoring a roll popup shows the true time remaining (the ML closes it at the real end),
-- not a fresh full duration. "" for non-rolling lots or when no deadline is known.
function addon:RollRemaining(lot)
    if lot.state ~= self.lootCore.STATE.ROLLING then return "" end
    local roll = self.live and self.live.rolls and self.live.rolls[lot.id]
    if not roll or not roll.deadline then return "" end
    return tostring(math.max(0, roll.deadline - ((GetTime and GetTime()) or 0)))
end

-- Structured encoding of one lot (shared by the full snapshot and deltas), tagged "L": ids + state +
-- live count + responses map + winner NAMES + removed flag + roll remaining + the resolved breakdown.
-- Named fields, not positional; no rendered text/links (the raider derives those locally).
function addon:BuildLotValue(lot)
    local winners = {}
    for _, a in ipairs(lot.awards or {}) do
        if a.winner then winners[#winners + 1] = a.winner end
    end
    -- Per-copy disposition is AUTHORITATIVE ledger state, not derivable from itemId, so it rides the
    -- wire alongside the breakdown: every client (including a freshly promoted ML) then holds the same
    -- owed/holder truth. Compact positional triple {winner|false, state, holder|false}; false (not nil)
    -- so the array has no holes. LibSerialize dedups the repeated names.
    local awards
    if lot.awards then
        awards = {}
        for i, a in ipairs(lot.awards) do
            awards[i] = { a.winner or false, a.state, a.holder or false }
        end
    end
    local v = {
        "L",
        id = lot.id,
        itemId = lot.itemId or 0,
        state = lot.state,
        count = self.lootCore:LiveCount(lot.id),
        responses = lot.responses,                  -- map sent directly (dedups across lots)
        winners = winners,
        awards = awards,
        removed = lot.removed or nil,
        seq = self.lootCore.seq or 0,               -- used by deltas; ignored in a full snapshot
        rollRemaining = tonumber(self:RollRemaining(lot)),   -- number for a rolling lot, else nil
    }
    if lot.state == self.lootCore.STATE.RESOLVED and lot.record then
        v.record = self:BuildRecordValue(lot.record)
    end
    return v
end

-- Rebuild a lot table (core's shape) from a structured wire value; rendering the record locally.
-- Returns lot, seq, rollRemaining (the last two drive delta seq tracking + roll-popup restore).
function addon:DecodeLotValue(v)
    local lot = {
        id = v.id,
        itemId = v.itemId,
        state = v.state,
        count = v.count or 0,
        responses = v.responses or {},
        removed = v.removed or nil,
    }
    -- Rebuild the authoritative award disposition so a mirror's liveCount is holder-aware (a copy held
    -- by another ML is not in OUR bags) and a promoted ML inherits the owed map directly.
    if v.awards then
        lot.awards = {}
        for i, a in ipairs(v.awards) do
            lot.awards[i] = { winner = a[1] or nil, state = a[2], holder = a[3] or nil }
        end
    end
    if lot.state == self.lootCore.STATE.RESOLVED then
        local winners = v.winners or {}
        if v.record then
            lot.record = renderRemoteRecordFull(self, lot.id, lot.itemId, lot.count, winners, v.record)
        else
            lot.record = renderRemoteRecord(lot.id, lot.itemId, lot.count, winners)
        end
    end
    return lot, v.seq or 0, v.rollRemaining
end

-- Host snapshot builder for WeirdSync. Emits one line per piece of state: an "M" meta line
-- (loot-master name + core seq), an "A" line per attendee, and an "L" line per live/resolved
-- lot. WeirdSync frames these as SB -> lines -> SD and carries them reliably.
function addon:SyncBuildSnapshot(emit)
    local session = self:GetCurrentSession()
    local core = self.lootCore
    -- 4th field: the ML's accepting-trades flag, so raiders can show a "not accepting trades"
    -- warning on the minimap button. Additive; older raiders ignore the extra field.
    emit({ "M", self:GetLootMasterName() or "", tostring(core.seq or 0),
        self:IsLootMasterAcceptingTrades() and "1" or "0" })
    for _, attendee in ipairs(session.attendees or {}) do
        emit({ "A", attendee.name or "", attendee.className or "", attendee.specName or "", attendee.status or "nil" })
    end
    for _, lot in ipairs(core:All()) do
        if lot.state == core.STATE.RESOLVED or core:LiveCount(lot.id) > 0 then
            emit(self:BuildLotValue(lot))
        end
    end
end

-- Host snapshot applier (raider). Rebuilds session context + attendees from the lines and
-- applies the lots atomically via core:ApplyRemote (-> ledgerChanged -> projections + UI).
function addon:SyncApplySnapshot(lines, epoch)
    -- An empty epoch means the authority has no active session (it answered a request with an
    -- empty snapshot). Don't fabricate a session: mark inactive rather than show a phantom one.
    self.session.id = epoch
    self.session.active = epoch ~= nil and epoch ~= ""
    -- Track the epoch so our next mint stays above it, and remember that this session is a LIVE mirror
    -- received from the authority (not a disk-restored leftover) so an ML handoff may safely continue it.
    self:ObserveEpoch(epoch)
    self._mirrorActive = self.session.active
    self.session.attendees = {}
    if self.ui then self.ui.selectedResult = nil end

    local lots, seq = {}, 0
    for _, f in ipairs(lines) do
        local tag = f[1]
        if tag == "M" then
            local mlName = f[2]
            if mlName and mlName ~= "" then self.roster.lootMasterName = mlName end
            seq = math.max(seq, tonumber(f[3]) or 0)
            -- A missing 4th field (older ML) defaults to accepting, so we never warn on stale data.
            self._mlAcceptingTrades = (f[4] == nil) or (f[4] == "1")
        elseif tag == "A" then
            self.session.attendees[#self.session.attendees + 1] = {
                name = f[2], className = f[3], specName = f[4], status = f[5],
            }
        elseif tag == "L" then
            local lot, lotSeq, remaining = self:DecodeLotValue(f)
            lots[#lots + 1] = lot
            seq = math.max(seq, lotSeq)
            self:StashRollRemaining(lot, remaining)   -- before ApplyRemote -> ledgerChanged -> SyncRollPopups
        end
    end
    self.lootCore:ApplyRemote({ seq = seq, lots = lots })
    -- reflect the ML's freshly-synced accepting-trades flag + loot-master presence (guarded: the
    -- minimap UI may not be loaded)
    if self.UpdateMinimapTradeStatus then self:UpdateMinimapTradeStatus() end
    if self.UpdateMinimapMLActive then self:UpdateMinimapMLActive() end
end

-- Host delta applier (raider): one lot upsert.
function addon:SyncApplyLine(fields)
    if fields[1] ~= "L" then return end
    local lot, lotSeq, remaining = self:DecodeLotValue(fields)
    self:StashRollRemaining(lot, remaining)   -- before ApplyRemoteLot -> ledgerChanged -> SyncRollPopups
    self.lootCore:ApplyRemoteLot(lot, lotSeq)
end

-- Full session snapshot to the raid. WeirdSync owns the framing/revision; we just hand it the
-- snapshot and drop the core's pending deltas (the snapshot already carried everything).
function addon:BroadcastSession()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can broadcast the session.")
        return
    end
    local session = self:GetCurrentSession()
    if not session.active then
        self:Print("Start a loot session first.")
        return
    end
    if not self.syncChannel then return end
    self.syncChannel:Broadcast(true)
    self.lootCore:DrainDirty()
end

-- Called on every ledgerChanged (ML only). Hands the changed lots to WeirdSync, which decides
-- delta-vs-snapshot (its deltaMax) and sends reliably. force routes to a full snapshot.
function addon:AutoBroadcastSession(force)
    local session = self:GetCurrentSession()
    if not self:IsAuthorizedLootMaster() or not session.active then return end
    if not self.syncChannel then return end
    if force then
        self:BroadcastSession()
        return
    end
    local core = self.lootCore
    local ids = core:DrainDirty()
    if #ids == 0 then return end
    local lines = {}
    for _, id in ipairs(ids) do
        local lot = core:Get(id)
        if lot then lines[#lines + 1] = self:BuildLotValue(lot) end
    end
    self.syncChannel:NotifyChanged(lines)
    self.syncChannel:Broadcast(false)
end

function addon:SendSelection(itemId, choice)
    local session = self:GetCurrentSession()
    if not session.id then
        return
    end

    local playerName = util:GetPlayerName("player")
    local lootMasterName = self:GetLootMasterName()
    if not lootMasterName then
        return
    end

    if util:NormalizeKey(playerName or "") == util:NormalizeKey(lootMasterName or "") then
        return
    end

    self:SendLargeMessage("SELECTION", {
        session.id,
        itemId,
        playerName or "",
        choice or "pass",
    }, "WHISPER", lootMasterName, "ALERT")
end

function addon:RequestSessionSync()
    if self:IsAuthorizedLootMaster() then
        self:BroadcastSession()
        return
    end
    if not self.syncChannel then return end
    -- WeirdSync defers the request if the loot master is not resolved yet (common right after a
    -- reload, before loot-method/roster data settles) and fires it the moment it is, so a
    -- reloading raider always ends up requesting a sync instead of silently giving up.
    self.syncChannel:RequestSync()
end

-- Push the ML's named-item priority list (named-player reservations, e.g. "Item, A > B / C > LC")
-- to the raid. Gated both ways: only the loot master sends, and raiders accept it only from the ML.
--
-- It is unclear who this push actually serves. Roll prio already rides the DROP wire (the ML computes
-- GetLiveItemPrio and sends the rendered string), so raiders never consult these rules for a roll; the
-- only raider-side use of the saved rules is the "Loot Council" label on a no-winner result. So today
-- this is near-vestigial. The intended future direction may be the inverse: let leadership/officers
-- push updated rosters and named priorities TO the ML for it to adopt, which would need the opposite
-- gating (an authorized officer sends, the ML accepts and uses it). Until that exists, this is just the
-- ML mirroring its own config outward.
function addon:BroadcastNamedItems()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can broadcast named items.")
        return
    end

    self:SendLargeMessage("NAMED_ITEMS_SYNC", {
        self:GetLootMasterName() or "",
        self.config.namedItemsText or "",
    }, "RAID")

    self:Print("Broadcast named items sent to raid.")
end

function addon:BroadcastRoster()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can broadcast the roster.")
        return
    end

    self:SendLargeMessage("ROSTER_SYNC", {
        self:GetLootMasterName() or "",
        self.config.rosterImportText or "",
    }, "RAID")

    self:Print("Broadcast roster sent to raid.")
end

-- Live pick list for a rolling lot, pushed ML -> raid as an EPHEMERAL, display-only signal so
-- raiders can see who is rolling in real time. Picks are otherwise coalesced (they do not sync
-- until the roll resolves), so without this a raider's popup would show a frozen ~0 count. This
-- never touches the authoritative ledger: it is a best-effort, throttled (one per lot per second,
-- see FlushRollState) snapshot of the lot's CURRENT active (non-pass) responders. A dropped one
-- self-heals on the next tick. className is derived on the raider from its own roster, not sent.
function addon:BroadcastRollState(lotId, lot)
    if not self:IsAuthorizedLootMaster() then return end
    local core = self.lootCore
    lot = lot or (core and core:Get(lotId))
    if not core or not lot or lot.state ~= core.STATE.ROLLING then return end
    local active = {}
    for key, choice in pairs(lot.responses or {}) do
        if self:IsResponseActive(choice) then active[key] = choice end
    end
    self:SendLargeMessage("RSTATE", { tostring(lotId), encodeResponses(active) }, "RAID", nil, "BULK")
end

-- Raider side: apply a live pick list to the open roll popup. Display-only -- it rebuilds the
-- roll's registrants (a full replace, so a MS->Pass change or a leaver just drops out) and never
-- writes the ledger. The hover list reads registrants on mouseover; RefreshInterestPopup updates
-- the count. Ignored if we have no (unresolved, non-owner) roll for this lot.
function addon:OnRollStateMessage(fields)
    local lotId = fields[1]
    local roll = self.live and self.live.rolls and self.live.rolls[lotId]
    if not roll or roll.resolved or roll.owner then return end
    local registrants = {}
    for key, tier in pairs(decodeResponses(fields[2] or "")) do
        registrants[util:NormalizeKey(key)] = { tier = tier }
    end
    roll.registrants = registrants
    self:RefreshInterestPopup(roll)
end

-- Live-roll message handler. Reached via RouteComm (the shared WeirdComm channel's dispatcher) for
-- any non-sync tag; the value is { command, arg1, ... } and fields below are the args after command.
-- We never receive our own RAID/PARTY messages (the client drops them); keep the self-skip
-- defensively in case of a self-WHISPER echo.
function addon:HandleCommMessage(sender, value)
    if type(value) ~= "table" then return end
    local command = value[1]
    local fields = {}
    for i = 2, #value do fields[#fields + 1] = value[i] end

    if command == "SELECTION" then
        if not self:IsAuthorizedLootMaster() then
            return
        end
        self:SetPlayerResponse(fields[2], fields[3], fields[4]) -- ML core write; snapshot syncs back
    elseif command == "NAMED_ITEMS_SYNC" then
        local expectedLootMaster = util:NormalizeKey(self:GetLootMasterName() or "")
        local senderKey = util:NormalizeKey(sender or "")
        if expectedLootMaster ~= "" and senderKey ~= expectedLootMaster then
            return
        end
        self:SaveNamedItemsText(fields[2] or "", true)
        self:Print("Named items updated from " .. ((fields[1] ~= "" and fields[1]) or sender or "loot master") .. ".")
    elseif command == "ROSTER_SYNC" then
        local expectedLootMaster = util:NormalizeKey(self:GetLootMasterName() or "")
        local senderKey = util:NormalizeKey(sender or "")
        if expectedLootMaster ~= "" and senderKey ~= expectedLootMaster then
            return
        end
        self:SaveRosterText(fields[2] or "", true)
        self:Print("Roster updated from " .. ((fields[1] ~= "" and fields[1]) or sender or "loot master") .. ".")
    elseif command == "DROP" then
        self:OnDropMessage(fields)
    elseif command == "RSP" then
        self:OnRspMessage(sender, fields)
    elseif command == "WIN" then
        self:OnWinMessage(fields)
    elseif command == "CANCEL" then
        self:OnCancelMessage(fields)
    elseif command == "RSTATE" then
        self:OnRollStateMessage(fields)
    end
end
