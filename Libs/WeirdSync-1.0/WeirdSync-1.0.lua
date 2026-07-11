-- WeirdSync-1.0
--
-- A small reliable state-synchronization library for 3.3.5a addons.
-- One authority (e.g. the loot master) replicates an evolving table of state to many peers
-- (the raid) and guarantees a peer that missed traffic while zoning/dead/disconnected
-- converges back to the authority's state without a human noticing.
--
-- The library owns DELIVERY: a monotonic revision, snapshot/delta framing, gap detection +
-- resync, reliable request/response, targeted-send acknowledgement, retry/backoff, give-up.
-- The host owns ALL payload semantics: a snapshot or delta "line" is an opaque VALUE (array or
-- table) the library relays and stamps but never interprets. This keeps the lib data-agnostic
-- and reusable across addons.
--
-- Transport-agnostic: the host provides cb.send(value, dist, target, prio) and feeds inbound
-- decoded values to channel:OnReceive(sender, value). WeirdLoot runs this over WeirdComm-1.0 (one
-- shared channel + pacer for ALL its traffic, so the server's per-player message mute is respected
-- across sync AND live-roll), where a whole snapshot ships as ONE message (a SNAP value holding
-- every line) instead of SB + N*SE + SD. But WeirdSync never touches bytes or the transport itself.
--
-- Delivery semantics: at-least-once with eventual convergence. Not exactly-once, not ordered.
-- Duplicate or reordered messages are harmless because the host's apply is idempotent.
--
-- Contract (the full design lives in these comments, not a separate doc):
--   * Message tags (value[1]):  SNAP = full snapshot (carries every line),  D = delta line,
--     RQ = peer's sync request,  AK = peer's ack of a targeted snapshot. See OnReceive/Tick.
--   * Revision: every broadcast carries a rev; a peer that sees a gap (rev > lastRev+1) requests
--     a full resync rather than applying out of order. Targeted (whispered) snapshots carry the
--     CURRENT rev and must NOT bump it, or other peers see a phantom gap.
--   * Reliability: a peer's RQ and an authority's targeted snapshot are both retried on backoff
--     (see _backoff) until acked/applied or maxAttempts; the authority abandons a target the
--     instant rosterContains(target) is false (genuinely left, not a drop).
--   * Self-skip: a channel ignores messages whose sender normalizes to its own name (echo guard).
--   * reqId carries a per-instance nonce so ids stay unique across /reload.
--   * Authority TIMING is the host's concern: RequestSync no-ops without a resolved authority;
--     the host re-requests when its authority appears (the lib never polls for one).

local MAJOR, MINOR = "WeirdSync-1.0", 1
assert(LibStub, MAJOR .. " requires LibStub")
local WeirdSync = LibStub:NewLibrary(MAJOR, MINOR)
if not WeirdSync then return end -- already loaded a newer or equal version

WeirdSync.channels = WeirdSync.channels or {}

-- ---------------------------------------------------------------------------
-- channel
-- ---------------------------------------------------------------------------
local Channel = {}
Channel.__index = Channel

local function noop() end

local function now()
    return (GetTime and GetTime()) or 0
end

-- normalize a player name for self-comparison: strip the realm and lowercase.
local function normName(name)
    if not name or name == "" then return "" end
    return (name:match("^[^-]+") or name):lower()
end

function Channel:_backoff(attempt)
    -- exponential: base * mul^(attempt-1) -> 0.5, 0.75, 1.1, 1.7, 2.5, 3.8, ... with the defaults.
    -- Front-loaded (small base) so a dropped message is retried fast; gentle mul keeps growth slow.
    return self.cfg.backoffBase * (self.cfg.backoffMul ^ (attempt - 1))
end

-- Hand one logical message (a Lua value; value[1] is the type tag) to the host's transport. The
-- transport (WeirdComm in WeirdLoot) serializes/compresses/chunks/paces; we never touch bytes.
function Channel:_send(value, dist, target, prio)
    self.cb.send(value, dist, target, prio or "BULK")
    self.cb.log("send", { cmd = value[1], prio = prio or "BULK", dist = dist, target = target })
end

-- Emit a full snapshot as ONE message. A RAID broadcast bumps the shared revision so every peer
-- rebaselines to it. A targeted (WHISPER) snapshot carries the authority's CURRENT revision and
-- must NOT bump it: bumping would advance the shared rev without the rest of the raid seeing the
-- snapshot, making everyone else's next delta look like a gap (a resync storm). Every state line
-- the host emits is collected into one SNAP value, so the whole snapshot is a single WeirdComm
-- message regardless of roster/ledger size.
function Channel:_emitSnapshot(dist, target, reqId)
    local rev
    if target then
        rev = self.rev
    else
        self.rev = self.rev + 1
        rev = self.rev
    end
    local lines = {}
    self.cb.buildSnapshot(function(lineFields)
        lines[#lines + 1] = lineFields
    end)
    -- The 6th field is our GENERATION (this process instance's nonce). Epoch says WHICH session;
    -- generation says WHICH load of the authority produced it. rev resets to 0 on every reload/relog
    -- while the epoch is restored unchanged, so a peer holding a higher rev would reject the restarted
    -- authority's lower-rev snapshot as a same-epoch backslide forever. Carrying the generation lets the
    -- peer tell "the authority restarted its counter" from "this is a stale old message" and rebaseline.
    self:_send({ "SNAP", self.cb.epoch(), tostring(rev), reqId or "", lines, self.nonce }, dist, target)
    self._pending = {} -- a snapshot supersedes any queued deltas
end

function Channel:_sendDeltas(lines)
    for _, line in ipairs(lines) do
        self.rev = self.rev + 1
        self:_send({ "D", tostring(self.rev), line }, "RAID")
    end
end

-- Authority: queue changed lines (each an opaque value) for the next Broadcast.
function Channel:NotifyChanged(lines)
    self._pending = self._pending or {}
    for _, l in ipairs(lines or {}) do
        self._pending[#self._pending + 1] = l
    end
end

-- Authority: flush. force, or more than deltaMax queued changes, sends a full snapshot
-- (cheaper than N deltas and re-baselines anyone who missed an earlier one); otherwise the
-- queued lines go out as individual deltas.
function Channel:Broadcast(force)
    if not self.cb.isAuthority() then return end
    if force then
        self:_emitSnapshot("RAID", nil)
        return
    end
    local pending = self._pending or {}
    if #pending == 0 then return end
    if #pending > self.cfg.deltaMax then
        self:_emitSnapshot("RAID", nil)
        return
    end
    self:_sendDeltas(pending)
    self._pending = {}
end

-- internal: mint and send a request to a known authority, marking it in-flight for Tick.
function Channel:_sendRequest(auth)
    self.reqSeq = (self.reqSeq or 0) + 1
    -- reqId carries the per-channel nonce so it stays unique across reloads: a fresh channel
    -- resets reqSeq to 1, so without the nonce two reload lifetimes would both mint "<me>:1" and a
    -- stale ack from the prior life could clear the new request's outstanding entry.
    local reqId = self.me .. ":" .. self.nonce .. "." .. self.reqSeq
    self.pendingRequest = { reqId = reqId, attempts = 1, nextAttempt = now() + self:_backoff(1) }
    self:_send({ "RQ", self.me, reqId }, "WHISPER", auth, "NORMAL")
    self.cb.log("req", { reqId = reqId, attempt = 1 })
end

-- Peer: ask the authority for the current full state (reliable; retried by Tick). The authority
-- calling this just broadcasts. Only one request is in flight at a time. If no authority is known
-- yet, this is a no-op: the library does NOT poll the host's authority resolver (that timing is a
-- host concern). The host re-calls RequestSync when its authority resolves; the in-flight guard
-- then collapses repeat calls to a single request.
function Channel:RequestSync()
    if self.cb.isAuthority() then
        self:Broadcast(true)
        return
    end
    if self.pendingRequest then return end -- one request in flight at a time
    local auth = self.cb.authorityName()
    if not auth or auth == "" then return end -- no authority to ask; host re-requests when one resolves
    self:_sendRequest(auth)
end

-- Peer: call on PLAYER_ENTERING_WORLD. A reload/zone-in pulls fresh state, covering a peer
-- that missed deltas while out of the world.
function Channel:NotifyZoneIn()
    if self.cb.isAuthority() then return end
    if self.pendingRequest then return end
    self:RequestSync()
end

-- Routed incoming message. WeirdComm reassembles a complete logical message and hands us the
-- decoded VALUE (value[1] is the type tag). In tests the host calls this directly.
function Channel:OnReceive(sender, value)
    -- Ignore our OWN echoed broadcasts (some servers deliver a sender its own RAID messages).
    -- Only self is dropped: a different sender (a secondary authority, leadership pushing updates)
    -- is still processed, so peer->authority flows remain open.
    if normName(sender) == self.meKey then return end
    if type(value) ~= "table" then return end

    local f = value
    local t = f[1]

    -- Authority binding: state messages (SNAP, delta D, heartbeat H) carry ledger state, and we
    -- trust them ONLY from the current authority -- the peer's own loot master. A state message from
    -- anyone else (a stale ML, or another group's loot master whose targeted snapshot crosses group
    -- boundaries) would be applied and leak a foreign ledger into ours: the raider then mirrors loot
    -- from a group/session it is not in. Drop it. The request/ack handshake (RQ/AK) is left open --
    -- each is already gated by isAuthority -- so peer<->authority flows work.
    if t == "SNAP" or t == "D" or t == "H" then
        local auth = self.cb.authorityName()
        if not auth or auth == "" or normName(sender) ~= normName(auth) then
            -- carry the foreign state's epoch (SNAP/H field 2) so the host can lift its epoch
            -- high-water: a stray seized session must not permanently out-rank the real
            -- authority's NEXT session just because the authority refused to apply it
            self.cb.log("drop-foreign", { from = sender, t = t, epoch = (t ~= "D") and f[2] or nil })
            return
        end
    end

    if t == "SNAP" then
        local inc = {
            epoch = f[2],
            rev = tonumber(f[3]) or 0,
            reqId = (f[4] ~= "" and f[4]) or nil,
            lines = f[5] or {},
            gen = f[6],
        }
        -- Epoch monotonicity: never adopt an OLDER session. Epochs are time()-stamped session ids, so
        -- a smaller epoch is a stale session -- an authority that restored a long-lived old session, or
        -- a leftover/backlogged broadcast from one. Adopting it sets appliedEpoch backward, which makes
        -- every heartbeat from the CURRENT session read as an epoch mismatch (endless resync), and also
        -- defeats the same-epoch rev guard below, because an old long-lived session can sit at a far
        -- HIGHER rev than a fresh one (so rev comparison across epochs is meaningless). Reject a strictly
        -- older epoch outright; equal or newer proceeds. Non-numeric epochs are never compared (accept).
        local incE, curE = tonumber(inc.epoch), tonumber(self.appliedEpoch)
        if incE and curE and incE < curE then
            self.pendingRequest = nil
            self.cb.log("recv-snap-stale", { reason = "epoch", epoch = inc.epoch, curEpoch = self.appliedEpoch })
            if inc.reqId then self:_send({ "AK", inc.reqId }, "WHISPER", sender, "ALERT") end
            return
        end
        -- Never let a stale, backlogged snapshot move us BACKWARD. A snapshot is built at the authority's
        -- rev when it answers a request; if it is delivered late (chunked + paced), deltas may have
        -- already carried us past it. Applying it then would regress lastRev AND replace the ledger with
        -- older state, re-tripping gap detection on the next delta: a self-sustaining resync storm. Drop a
        -- same-epoch snapshot whose rev is older than what we hold; still clear our request and ack so the
        -- authority stops retrying. A NEW epoch (session rebaseline) or a first-ever sync (lastRev == nil)
        -- always applies -- only a same-epoch backslide is rejected.
        local sameEpoch = (self.appliedEpoch ~= nil and inc.epoch == self.appliedEpoch)
        -- Generation ORDERING within an epoch. The generation is a wall-clock time() minted per load, and
        -- within a single epoch the authority is always the same client (a real handoff mints a NEW epoch),
        -- so that client's generation only ever increases across its own reloads. Compare numerically:
        --   newer gen (>) -> the authority reloaded and restarted rev at 0; rebaseline even past a lower
        --                    rev, otherwise the stale-rev guard would refuse it until the PEER reloads.
        --   older gen (<) -> a backlogged message from a SUPERSEDED load (e.g. a snapshot the ML sent just
        --                    before relogging, delivered late). It must be REJECTED, or it regresses us to
        --                    the pre-reload state at its high rev (which the stale-rev guard would not catch,
        --                    since that rev is ABOVE our freshly-rebaselined one).
        --   same gen      -> normal rev handling (the stale-rev backslide guard below).
        -- The epoch guard above still protects against genuinely stale OLD sessions (different epoch); this
        -- only orders the loads of one authority within one epoch. Non-numeric gens (legacy/absent) fall
        -- through to plain rev handling, so it degrades safely.
        local ig, ag = tonumber(inc.gen), tonumber(self.appliedGen)
        local genRestart = sameEpoch and ig and ag and ig > ag
        local genStale   = sameEpoch and ig and ag and ig < ag
        if genStale then
            self.pendingRequest = nil
            self.cb.log("recv-snap-stale", { reason = "gen", gen = inc.gen, curGen = self.appliedGen })
            if inc.reqId then self:_send({ "AK", inc.reqId }, "WHISPER", sender, "ALERT") end
            return
        end
        if sameEpoch and not genRestart and self.lastRev ~= nil and inc.rev < self.lastRev then
            self.pendingRequest = nil
            self.cb.log("recv-snap-stale", { rev = inc.rev, lastRev = self.lastRev })
            if inc.reqId then self:_send({ "AK", inc.reqId }, "WHISPER", sender, "ALERT") end
            return
        end
        local prevGen = self.appliedGen
        self.cb.applySnapshot(inc.lines, inc.epoch)
        self.lastRev = inc.rev      -- a snapshot re-baselines the revision
        self.appliedEpoch = inc.epoch
        self.appliedGen = inc.gen or self.appliedGen   -- remember the authority's generation for restart detection
        self.pendingRequest = nil   -- our outstanding request (if any) is satisfied
        if genRestart then
            self.cb.log("gen-restart", { epoch = inc.epoch, rev = inc.rev, was = prevGen, now = inc.gen })
        end
        self.cb.log("recv-snap", { rev = inc.rev, lines = #inc.lines })
        if inc.reqId then
            -- confirm a TARGETED snapshot was applied so the authority can stop retrying.
            self:_send({ "AK", inc.reqId }, "WHISPER", sender, "ALERT")
        end
    elseif t == "D" then
        local rev = tonumber(f[2]) or 0
        local last = self.lastRev
        if last == nil or rev > last + 1 then
            -- never synced, or a delta was dropped: pull a fresh snapshot once.
            self.cb.log("recv-gap", { rev = rev, lastRev = last })
            if not self.pendingRequest then self:RequestSync() end
            return
        end
        if rev <= last then return end -- stale / duplicate
        self.cb.applyLine(f[3])
        self.lastRev = rev
        self.cb.log("recv-lot", { rev = rev })
    elseif t == "RQ" then
        if not self.cb.isAuthority() then return end
        local reqId = f[3]
        -- Coalesce per target: at most ONE snapshot in flight to a given peer. A peer retries the same
        -- reqId (and re-requests with a fresh reqId after give-up) on backoff. Emitting a full snapshot
        -- for every RQ while one is already outstanding to this peer just backlogs the wire; our own Tick
        -- ack-retry redelivers the in-flight one, and applying ANY snapshot clears the peer's request.
        for _, o in pairs(self.outstanding) do
            if o.target == sender then return end
        end
        self:_emitSnapshot("WHISPER", sender, reqId)
        self.outstanding[reqId] = { target = sender, reqId = reqId, attempts = 1, nextAttempt = now() + self:_backoff(1) }
    elseif t == "AK" then
        if not self.cb.isAuthority() then return end
        local reqId = f[2]
        if self.outstanding[reqId] then
            self.outstanding[reqId] = nil
            self.cb.log("ack", { reqId = reqId })
        end
    elseif t == "H" then
        -- Heartbeat: the authority's current epoch + rev. A peer that is behind (missed the last
        -- delta, never synced, or is on a different epoch) requests a snapshot. In-sync peers ignore
        -- it. This is the only thing that heals a peer when the ledger has gone quiet, since gap
        -- detection otherwise needs a future delta to notice the miss.
        if self.cb.isAuthority() then return end
        local epoch = f[2]
        local rev = tonumber(f[3]) or 0
        local gen = f[4]
        -- Epoch monotonicity (mirrors the SNAP guard): a heartbeat from an OLDER session is a stale
        -- authority -- ignore it, never resync backward. A newer epoch is a fresh session we have not
        -- adopted (we ARE behind, pull it). Same epoch: behind only if its rev has moved past ours.
        local incE, curE = tonumber(epoch), tonumber(self.appliedEpoch)
        local ig, ag = tonumber(gen), tonumber(self.appliedGen)
        local sameEpoch = (epoch == self.appliedEpoch)
        local staleEpoch = incE and curE and incE < curE
        local epochChanged = epoch and epoch ~= "" and epoch ~= self.appliedEpoch
        -- Generation ordering (mirrors the SNAP handler). A NEWER generation at the same epoch means the
        -- authority reloaded and its rev is now below ours, so the rev test would read "in-sync" and never
        -- heal -- treat it as behind so we pull a rebaselining snapshot. An OLDER generation is a heartbeat
        -- from a superseded load; ignore it (like an older epoch) so a late straggler cannot bounce us.
        local staleGen = sameEpoch and ig and ag and ig < ag
        local genRestart = sameEpoch and ig and ag and ig > ag
        local behind = self.lastRev == nil or rev > self.lastRev or epochChanged or genRestart
        -- Log EVERY heartbeat we actually receive, with its verdict, so an in-sync heartbeat (which
        -- takes no action) is not silent in the trace. Without this, "peer received the heartbeat and
        -- ignored it as in-sync" and "peer never received the heartbeat (dead inbound)" are identical
        -- in the log -- both leave no record -- which is exactly the ambiguity a stall diagnosis needs
        -- resolved. recv-hb present + no recv-hb-gap == in-sync; recv-hb absent == never arrived.
        self.cb.log("recv-hb", { rev = rev, lastRev = self.lastRev, epoch = epoch,
            verdict = staleEpoch and "stale-epoch" or staleGen and "stale-gen" or genRestart and "gen-restart"
                or (behind and (self.pendingRequest and "behind-pending" or "behind") or "in-sync") })
        if staleEpoch or staleGen then return end
        if behind and not self.pendingRequest then
            self.cb.log("recv-hb-gap", { rev = rev, lastRev = self.lastRev, epoch = epoch })
            self:RequestSync()
        end
    end
end

-- Drive retries. The lib also self-drives this off an OnUpdate frame in-game; tests call it
-- directly with an explicit clock value.
function Channel:Tick(t)
    t = t or now()

    -- authority: heartbeat the current epoch + rev to the raid every cfg.heartbeat seconds, so a
    -- peer that missed the last delta heals itself even when the ledger has gone quiet (no future
    -- delta to trip gap detection). Only fires with an active epoch; in-sync peers ignore it.
    if self.cfg.heartbeat > 0 and self.cb.isAuthority() then
        local epoch = self.cb.epoch()
        if epoch and epoch ~= "" and t >= (self._nextHeartbeat or 0) then
            self:_send({ "H", epoch, tostring(self.rev), self.nonce }, "RAID")   -- 4th field: generation (see _emitSnapshot)
            self._nextHeartbeat = t + self.cfg.heartbeat
        end
    end

    -- authority: re-send targeted snapshots that have not been acked.
    for reqId, o in pairs(self.outstanding) do
        if t >= o.nextAttempt then
            if not self.cb.rosterContains(o.target) then
                self.outstanding[reqId] = nil
                self.cb.log("give-up", { kind = "ack", reqId = reqId, reason = "left" })
            elseif o.attempts >= self.cfg.maxAttempts then
                self.outstanding[reqId] = nil
                self.cb.log("give-up", { kind = "ack", reqId = reqId, reason = "max" })
            else
                o.attempts = o.attempts + 1
                self:_emitSnapshot("WHISPER", o.target, reqId)
                o.nextAttempt = t + self:_backoff(o.attempts)
                self.cb.log("resend", { kind = "ack", reqId = reqId, attempt = o.attempts })
            end
        end
    end

    -- peer: re-send a sync request that has not been answered.
    local pr = self.pendingRequest
    if pr and t >= pr.nextAttempt then
        if pr.attempts >= self.cfg.maxAttempts then
            self.pendingRequest = nil
            self.cb.log("give-up", { kind = "request", reqId = pr.reqId, reason = "max" })
        else
            pr.attempts = pr.attempts + 1
            local auth = self.cb.authorityName()
            if auth and auth ~= "" then
                self:_send({ "RQ", self.me, pr.reqId }, "WHISPER", auth, "NORMAL")
                self.cb.log("resend", { kind = "request", reqId = pr.reqId, attempt = pr.attempts })
            else
                -- No authority resolves this tick: skip the whisper (a nil/empty target throws "missing
                -- target player"). The attempt still counts, so retries stay bounded by maxAttempts; a
                -- later tick resends if an authority resolves in time (target is read fresh, not cached).
                self.cb.log("defer", { kind = "request", reqId = pr.reqId, attempt = pr.attempts })
            end
            pr.nextAttempt = t + self:_backoff(pr.attempts)
        end
    end
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
-- cb (host callbacks / config):
--   isAuthority()            -> bool   am I the source of truth
--   authorityName()          -> string whom a peer whispers for resync
--   rosterContains(name)     -> bool   roster-aware give-up (defaults true)
--   epoch()                  -> string rebaseline key (e.g. session id; defaults "")
--   send(value,dist,target,prio)  REQUIRED transport: deliver one logical value (host owns bytes)
--   buildSnapshot(emit)      authority emits every state line: emit(value)
--   applySnapshot(lines, ep) peer replaces local state from a full snapshot's line list
--   applyLine(value)         peer upserts one delta line
--   log(ev, data)            trace sink (defaults to no-op)
--   selfName                 OPTIONAL explicit player name (else UnitName("player"))
--   deltaMax/backoffBase/backoffMul/maxAttempts/heartbeat  OPTIONAL tuning
-- The host feeds inbound decoded values to channel:OnReceive(sender, value).
function WeirdSync:NewChannel(prefix, cb)
    assert(type(prefix) == "string" and prefix ~= "", "WeirdSync:NewChannel requires a prefix")
    cb = cb or {}

    local ch = setmetatable({}, Channel)
    ch.prefix = prefix
    ch.cb = {
        send = cb.send or noop,   -- host transport; without it the channel is inert (logs only)
        isAuthority = cb.isAuthority or function() return false end,
        authorityName = cb.authorityName or function() return "" end,
        rosterContains = cb.rosterContains or function() return true end,
        epoch = cb.epoch or function() return "" end,
        buildSnapshot = cb.buildSnapshot or noop,
        applySnapshot = cb.applySnapshot or noop,
        applyLine = cb.applyLine or noop,
        log = cb.log or noop,
    }
    ch.cfg = {
        deltaMax = cb.deltaMax or 8,
        backoffBase = cb.backoffBase or 0.5,   -- seconds to first retry (fast: recover a drop quickly)
        backoffMul = cb.backoffMul or 1.5,     -- gentle exponential factor (0.5,0.75,1.1,1.7,2.5,...)
        maxAttempts = cb.maxAttempts or 8,     -- ~25s total horizon before give-up (covers a load screen)
        heartbeat = cb.heartbeat or 30,        -- authority re-announces rev every N seconds; 0 disables
    }
    ch.rev = 0
    ch.lastRev = nil
    ch.appliedEpoch = nil   -- peer: the epoch of the last applied snapshot (session identity)
    ch.appliedGen = nil     -- peer: the generation (authority process instance) of the last applied snapshot
    ch.outstanding = {}     -- authority: reqId -> { target, attempts, nextAttempt }
    ch.pendingRequest = nil -- peer: { reqId, attempts, nextAttempt }
    ch._pending = {}        -- authority: queued changed lines awaiting Broadcast
    ch.reqSeq = 0
    ch.me = cb.selfName or (UnitName and UnitName("player")) or "?"
    ch.meKey = normName(ch.me)
    -- per-channel-instance nonce, distinct for every load of this client. Two jobs: it keeps reqIds
    -- unique across reloads, and it is the GENERATION stamped on SNAP/H so a peer can tell that the
    -- authority restarted (and reset its rev) rather than that a message is stale. It only has to
    -- DIFFER between two loads, not be ordered -- a peer compares gen ~= appliedGen. The host injects a
    -- wall-clock time() (never resets, and two loads of one client are always seconds apart, so it is
    -- unique per load); the GetTime fallback keeps it working out-of-game and in tests.
    ch.nonce = cb.nonce or tostring(math.floor(now()))

    -- Transport is the host's (cb.send + feeding OnReceive); WeirdSync does not own a channel.

    -- self-driving retry tick (no AceTimer on 3.3.5a; drive off an OnUpdate frame).
    if CreateFrame then
        local fr = CreateFrame("Frame")
        ch._frame = fr
        local acc = 0
        fr:SetScript("OnUpdate", function(_, dt)
            acc = acc + (dt or 0)
            if acc >= 0.5 then acc = 0; ch:Tick() end
        end)
    end

    WeirdSync.channels[prefix] = ch
    return ch
end
