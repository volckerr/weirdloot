-- Out-of-game battery for WeirdSync-1.0 (the reliable state-sync library), standalone.
-- Loads the REAL Libs/WeirdSync-1.0/WeirdSync-1.0.lua into a mocked env and drives the sync +
-- reliability mechanics (the contract is documented in the lib's header). No WeirdLoot code is
-- involved: the host is a
-- tiny in-memory line store, so this proves the library on its own before Comm.lua is rewired.
--
-- Run from the addon dir:  luajit tests/weirdsync.lua

-- ---------------------------------------------------------------------------
-- tiny test framework (same shape as tests/run.lua)
-- ---------------------------------------------------------------------------
local pass, fail, failures = 0, 0, {}
local current = "?"
local function check(cond, label)
    if cond then pass = pass + 1
    else fail = fail + 1; failures[#failures + 1] = current .. ": " .. label; print("  FAIL " .. label) end
end
local function eq(a, b, label)
    check(a == b, (label or "") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end
local function test(name, fn)
    current = name
    print("[" .. name .. "]")
    local ok, err = pcall(fn)
    if not ok then fail = fail + 1; failures[#failures + 1] = name .. ": ERROR " .. tostring(err); print("  ERROR " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- shared wire + clock + a router that fans messages to all registered channels
-- ---------------------------------------------------------------------------
local WIRE = {}
local CLOCK = 1000
local CHANNELS = {}            -- me -> channel (for the router)

local function clearWire() WIRE = {} end

-- message type tag of a wire message (value[1])
local function firstField(m) return m.value and m.value[1] end

-- Deliver everything currently on the wire to every channel it is addressed to, in order.
-- A WHISPER reaches only its target; anything else reaches all non-senders. Returns nothing;
-- call repeatedly to let request/response settle. To simulate a DROP, clearWire() first.
local function deliver()
    local msgs = WIRE; WIRE = {}
    for _, m in ipairs(msgs) do
        for me, ch in pairs(CHANNELS) do
            if m.sender ~= me then
                if m.dist == "WHISPER" then
                    if m.target == me then ch:OnReceive(m.sender, m.value) end
                else
                    ch:OnReceive(m.sender, m.value)
                end
            end
        end
    end
end

-- Deliver repeatedly until the wire drains (a full request -> response -> ack settles over
-- several hops because messages produced during a deliver land in the next round). Bounded so a
-- live-lock can't hang the test. Use only where you WANT convergence (not in drop scenarios).
local function settle(maxRounds)
    for _ = 1, (maxRounds or 20) do
        if #WIRE == 0 then break end
        deliver()
    end
end

-- ---------------------------------------------------------------------------
-- load the library once into a mocked env
-- ---------------------------------------------------------------------------
local libs = {}
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepcopy(val) end
    return out
end
-- Fake WeirdComm: a pass-through transport. Send records the logical VALUE on the wire (deep-copied
-- to mimic the real lib's serialize-on-send, so later host mutation can't alias the captured msg).
-- The real WeirdComm's codec/chunk/pace/reassembly is covered by tests/weirdcomm.lua, and the
-- real-lib-over-real-lib seam by tests/integration.lua; here we isolate WeirdSync's reliability logic.
local weirdComm = {
    NewChannel = function(_, prefix, opts)
        return {
            Send = function(_, value, dist, target, prio)
                WIRE[#WIRE + 1] = { prefix = prefix, value = deepcopy(value), dist = dist, target = target, sender = opts.selfName, prio = prio }
            end,
            Tick = function() end,
        }
    end,
}
libs["WeirdComm-1.0"] = weirdComm
local LibStub = setmetatable({
    NewLibrary = function(_, name) libs[name] = libs[name] or {}; return libs[name] end,
    GetLibrary = function(_, name) return libs[name] end,
}, { __call = function(_, name) return libs[name] end })

local env = setmetatable({}, { __index = _G })
env._G = env
env.LibStub = LibStub
env.GetTime = function() return CLOCK end
env.UnitName = function() return "?" end
env.CreateFrame = nil  -- no self-driving frame in tests; we call Tick() explicitly
do
    local chunk = assert(loadfile("Libs/WeirdSync-1.0/WeirdSync-1.0.lua"))
    setfenv(chunk, env)
    chunk()
end
local WeirdSync = libs["WeirdSync-1.0"]
assert(WeirdSync and WeirdSync.NewChannel, "WeirdSync failed to load")

-- ---------------------------------------------------------------------------
-- a minimal host: an in-memory line store keyed by the line's first field (the id).
-- A "line" is { id, value } (an opaque array of strings to the lib).
-- ---------------------------------------------------------------------------
local function makeHost(name, isML, opts)
    opts = opts or {}
    local host = {
        name = name,
        store = {},     -- id -> line
        log = {},       -- captured trace records
        roster = opts.roster or { [name] = true },
        authority = opts.authority or "ML",  -- settable, so a test can model a late-resolving LM
    }
    local cb = {
        selfName = name,
        -- transport seam: record the logical VALUE on the wire (deep-copied to mimic serialize-on-send)
        send = function(value, dist, target, prio)
            WIRE[#WIRE + 1] = { value = deepcopy(value), dist = dist, target = target, sender = name, prio = prio }
        end,
        isAuthority = function() return isML end,
        authorityName = function() return host.authority or "" end,
        rosterContains = function(n) return host.roster[n] == true end,
        epoch = function() return opts.epoch or "S1" end,
        buildSnapshot = function(emit)
            -- emit in a stable order so snapshots are deterministic
            local ids = {}
            for id in pairs(host.store) do ids[#ids + 1] = id end
            table.sort(ids)
            for _, id in ipairs(ids) do emit(host.store[id]) end
        end,
        applySnapshot = function(lines)
            host.store = {}
            for _, line in ipairs(lines) do host.store[line[1]] = line end
        end,
        applyLine = function(line) host.store[line[1]] = line end,
        log = function(ev, data)
            host.log[#host.log + 1] = { ev = ev, data = data or {} }
        end,
        deltaMax = opts.deltaMax or 8,
        backoffBase = opts.backoffBase or 2.0,
        backoffMul = opts.backoffMul or 2.0,
        maxAttempts = opts.maxAttempts or 4,
    }
    host.chan = WeirdSync:NewChannel(opts.prefix or "WST", cb)
    CHANNELS[name] = host.chan
    return host
end

local function reset()
    clearWire(); CLOCK = 1000
    for k in pairs(CHANNELS) do CHANNELS[k] = nil end
end

-- canonical view of a store for convergence comparison
local function view(host)
    local rows = {}
    for id, line in pairs(host.store) do
        rows[#rows + 1] = id .. "=" .. table.concat(line, ",")
    end
    table.sort(rows)
    return table.concat(rows, "\n")
end

-- authority helpers
local function setLine(host, id, value)
    host.store[id] = { id, value }
    return host.store[id]
end
local function deltaChange(host, id, value)
    local line = setLine(host, id, value)
    host.chan:NotifyChanged({ line })
    host.chan:Broadcast(false)
end

-- count captured log events of a kind
local function countEv(host, ev, predicate)
    local n = 0
    for _, r in ipairs(host.log) do
        if r.ev == ev and (not predicate or predicate(r.data)) then n = n + 1 end
    end
    return n
end

-- ===========================================================================
-- BATTERY
-- ===========================================================================

test("baseline snapshot mirrors authority -> peer and sets lastRev", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    setLine(ml, "L1", "pending")
    setLine(ml, "L2", "rolling")
    ml.chan:Broadcast(true)        -- forced full snapshot
    deliver()
    eq(view(rd), view(ml), "peer mirrored the authority's store")
    check(rd.chan.lastRev ~= nil, "peer set lastRev from the snapshot")
    eq(rd.chan.lastRev, ml.chan.rev, "peer rebaselined to the authority's current rev")
end)

test("a single change sends a delta (D), not a snapshot, and applies", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.chan:Broadcast(true); deliver()              -- baseline
    clearWire()
    deltaChange(ml, "L1", "rolling")
    local snaps, deltas = 0, 0
    for _, m in ipairs(WIRE) do
        local t = firstField(m)
        if t == "SNAP" then snaps = snaps + 1 end
        if t == "D" then deltas = deltas + 1 end
    end
    eq(snaps, 0, "no snapshot for a single change")
    check(deltas >= 1, "a delta was sent")
    deliver()
    eq(view(rd), view(ml), "peer applied the delta")
end)

test("more than deltaMax changes falls back to a full snapshot", function()
    reset()
    local ml = makeHost("ML", true, { deltaMax = 3 })
    local rd = makeHost("Raider", false, { deltaMax = 3 })
    ml.chan:Broadcast(true); deliver()
    clearWire()
    for i = 1, 5 do setLine(ml, "L" .. i, "v") end
    ml.chan:NotifyChanged({ ml.store.L1, ml.store.L2, ml.store.L3, ml.store.L4, ml.store.L5 })
    ml.chan:Broadcast(false)
    local sawSB = false
    for _, m in ipairs(WIRE) do if firstField(m) == "SNAP" then sawSB = true end end
    check(sawSB, "fell back to a snapshot for a large change set")
    deliver()
    eq(view(rd), view(ml), "peer converged via the fallback snapshot")
end)

test("dropped delta -> gap detected -> peer requests sync -> converges (+ ack)", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.chan:Broadcast(true); deliver()
    eq(view(rd), view(ml), "synced at baseline")

    ml.roster = { ML = true, Raider = true }
    -- DROP a delta: change state on the ML but never deliver it.
    deltaChange(ml, "L9", "rolling")
    clearWire()                                  -- the delta is lost
    -- a following delta now arrives with a rev gap
    deltaChange(ml, "L9", "resolved")
    deliver()                                    -- deliver the gap delta; raider whispers RQ
    check(rd.chan.pendingRequest ~= nil, "peer flagged a pending sync after the gap")
    check(countEv(rd, "recv-gap") >= 1, "peer logged the gap")
    settle()                                     -- RQ -> targeted snapshot -> apply + ack -> clear
    eq(view(rd), view(ml), "peer converged to authority truth after gap + resync")
    eq(rd.chan.pendingRequest, nil, "peer cleared its pending request on the snapshot")
    check(countEv(ml, "ack") >= 1, "authority received the peer's ack")
    eq(next(ml.chan.outstanding), nil, "authority cleared the outstanding targeted send")
end)

test("targeted snapshot does NOT bump the shared rev (no phantom gap for others)", function()
    reset()
    local ml = makeHost("ML", true)
    local r1 = makeHost("R1", false)
    local r2 = makeHost("R2", false)
    ml.chan:Broadcast(true); deliver()
    local revBefore = ml.chan.rev

    -- R1 asks for a resync; ML answers with a WHISPER snapshot.
    r1.chan:RequestSync(); deliver(); deliver()
    eq(ml.chan.rev, revBefore, "a targeted (whispered) snapshot did not advance the shared rev")

    -- now a normal delta to everyone must still be contiguous for R2 (no gap).
    clearWire()
    deltaChange(ml, "L1", "rolling")
    deliver()
    eq(r2.chan.lastRev, ml.chan.rev, "R2 stayed contiguous")
    eq(countEv(r2, "recv-gap"), 0, "R2 never saw a phantom gap")
    eq(view(r2), view(ml), "R2 applied the delta normally")
end)

test("default backoff is front-loaded (base 0.5, mul 1.5, 8 attempts)", function()
    -- created with no backoff opts -> exercises the lib's own defaults (makeHost pins 2.0 for the
    -- math tests, so assert the production defaults directly here).
    local ch = WeirdSync:NewChannel("WSDEFAULT", { selfName = "X" })
    eq(ch.cfg.backoffBase, 0.5, "default base is a fast 0.5s")
    eq(ch.cfg.backoffMul, 1.5, "default mul is a gentle 1.5x")
    eq(ch.cfg.maxAttempts, 8, "default maxAttempts is 8")
    eq(ch:_backoff(1), 0.5, "first retry at 0.5s")
    eq(ch:_backoff(2), 0.75, "second at 0.75s (gentle growth)")
end)

test("requester retry: a dropped request is re-sent on exponential backoff, then gives up", function()
    reset()
    local ml = makeHost("ML", true, { maxAttempts = 3 })
    local rd = makeHost("Raider", false, { maxAttempts = 3 })
    -- peer requests, but the ML is "gone": drop every RQ so nothing is ever answered.
    -- maxAttempts=3 => initial send + 2 resends (at 2s, 6s), give up on the tick after the 3rd.
    rd.chan:RequestSync()
    clearWire()
    eq(rd.chan.pendingRequest.attempts, 1, "first request sent")
    local firstNext = rd.chan.pendingRequest.nextAttempt
    eq(firstNext - 1000, 2, "first retry scheduled at base backoff (2s)")

    -- not yet due
    CLOCK = 1001; rd.chan:Tick(CLOCK)
    eq(rd.chan.pendingRequest.attempts, 1, "no retry before the backoff elapses")

    -- due: 2s -> retry (attempt 2), next at +4s
    CLOCK = 1002; rd.chan:Tick(CLOCK); clearWire()
    eq(rd.chan.pendingRequest.attempts, 2, "retried at 2s")
    eq(rd.chan.pendingRequest.nextAttempt - CLOCK, 4, "next backoff is 4s")

    -- due: +4s -> attempt 3, next at +8s
    CLOCK = 1006; rd.chan:Tick(CLOCK); clearWire()
    eq(rd.chan.pendingRequest.attempts, 3, "retried at 6s")
    eq(rd.chan.pendingRequest.nextAttempt - CLOCK, 8, "next backoff is 8s")

    -- due: +8s -> attempts now at max (4) -> give up
    CLOCK = 1014; rd.chan:Tick(CLOCK)
    eq(rd.chan.pendingRequest, nil, "gave up after maxAttempts")
    check(countEv(rd, "give-up", function(d) return d.kind == "request" and d.reason == "max" end) == 1, "logged a request give-up")
    eq(countEv(rd, "resend", function(d) return d.kind == "request" end), 2, "exactly two resends before give-up")
end)

test("requester retry stops as soon as the snapshot actually arrives", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    setLine(ml, "L1", "pending")
    rd.chan:RequestSync()
    clearWire()                              -- first RQ dropped
    CLOCK = 1002; rd.chan:Tick(CLOCK)        -- resend RQ (attempt 2)
    deliver()                                -- this time ML hears it and answers
    deliver()                                -- raider applies snapshot (+acks)
    eq(rd.chan.pendingRequest, nil, "pending request cleared once state arrived")
    eq(view(rd), view(ml), "peer converged")
end)

test("ack retry: an unacked targeted snapshot is re-sent, then gives up", function()
    reset()
    local ml = makeHost("ML", true, { maxAttempts = 2 })
    local rd = makeHost("Raider", false, { maxAttempts = 2 })
    ml.roster = { ML = true, Raider = true } -- the peer is genuinely present (drops are network, not a leave)
    setLine(ml, "L1", "pending")
    -- peer requests; ML answers, but every reply (and thus the ack) is dropped.
    -- maxAttempts=2 => initial targeted send + 1 resend (at 2s), give up on the tick after.
    rd.chan:RequestSync(); deliver()         -- ML gets RQ, sends targeted snapshot, records outstanding
    local reqId = next(ml.chan.outstanding)
    check(reqId ~= nil, "authority tracked an outstanding targeted send")
    clearWire()                              -- drop the snapshot (no ack will come)

    CLOCK = 1002; ml.chan:Tick(CLOCK); clearWire()  -- resend (attempt 2)
    eq(ml.chan.outstanding[reqId].attempts, 2, "authority resent the targeted snapshot")
    CLOCK = 1006; ml.chan:Tick(CLOCK)               -- attempts at max (2) reached on next due
    eq(ml.chan.outstanding[reqId], nil, "authority gave up after maxAttempts")
    check(countEv(ml, "give-up", function(d) return d.kind == "ack" and d.reason == "max" end) == 1, "logged an ack give-up")
end)

test("ack retry stops immediately when the target leaves the roster", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.roster = { ML = true, Raider = true }
    setLine(ml, "L1", "pending")
    rd.chan:RequestSync(); deliver()
    local reqId = next(ml.chan.outstanding)
    check(reqId ~= nil, "outstanding recorded")
    clearWire()
    ml.roster.Raider = nil                   -- the peer logged out / left the raid
    CLOCK = 1002; ml.chan:Tick(CLOCK)
    eq(ml.chan.outstanding[reqId], nil, "stopped retrying a peer that left")
    check(countEv(ml, "give-up", function(d) return d.reason == "left" end) == 1, "logged a roster-leave give-up")
end)

test("request with no authority is a no-op and the lib never polls for one", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    rd.authority = ""                         -- host has not resolved the authority yet
    rd.chan:RequestSync()
    eq(countEv(rd, "req"), 0, "no request sent while the authority is unknown")
    eq(rd.chan.pendingRequest, nil, "no pending state: the lib does not hold a deferred request")
    CLOCK = 1002; rd.chan:Tick(CLOCK)
    eq(countEv(rd, "req"), 0, "Tick does not poll the host's authority resolver")

    -- the HOST owns the timing: it re-requests once it knows the authority
    rd.authority = "ML"
    rd.chan:RequestSync()
    eq(countEv(rd, "req"), 1, "request fires when the host re-requests with an authority known")
    deliver(); deliver()
    eq(view(rd), view(ml), "peer converged")
end)

test("reqIds stay unique across channel lifetimes (reload) via the nonce", function()
    reset()
    local function freshRaider(nonce)
        return WeirdSync:NewChannel("WST", {
            selfName = "Raider", nonce = nonce,
            isAuthority = function() return false end,
            authorityName = function() return "ML" end,
        })
    end
    local a = freshRaider("100"); a:RequestSync()
    local b = freshRaider("200"); b:RequestSync()   -- a "reload": reqSeq resets to 1, nonce differs
    local idA, idB = a.pendingRequest.reqId, b.pendingRequest.reqId
    check(idA ~= idB, "two lifetimes mint distinct reqIds (got " .. tostring(idA) .. " vs " .. tostring(idB) .. ")")
    check(idA == "Raider:100.1" and idB == "Raider:200.1", "reqId embeds nonce + per-life seq")
end)

test("zone-in triggers a sync request", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    rd.chan:NotifyZoneIn()
    check(rd.chan.pendingRequest ~= nil, "zone-in issued a sync request")
    eq(countEv(rd, "req"), 1, "exactly one request on zone-in")
    rd.chan:NotifyZoneIn()                   -- a second zone-in while pending is a no-op
    eq(countEv(rd, "req"), 1, "no duplicate request while one is pending")
end)

test("a channel ignores its OWN echoed broadcast (but not another sender's)", function()
    reset()
    local ml = makeHost("ML", true)
    setLine(ml, "L1", "pending")
    ml.chan:Broadcast(true)                    -- ML broadcasts a snapshot
    local own = {}
    for _, m in ipairs(WIRE) do own[#own + 1] = m end
    -- feed the ML its own messages back (as a self-echoing server would)
    for _, m in ipairs(own) do ml.chan:OnReceive("ML", m.value) end
    eq(countEv(ml, "recv-snap"), 0, "ML did not apply its own echoed snapshot")
    eq(ml.chan.lastRev, nil, "ML's receive baseline untouched by self-echo")
    -- a DIFFERENT sender's message is still processed
    local rd = makeHost("Raider", false)
    for _, m in ipairs(own) do rd.chan:OnReceive("ML", m.value) end
    eq(countEv(rd, "recv-snap"), 1, "a peer still applies the ML's snapshot")
end)

test("duplicate / stale delta is ignored (idempotent, no double-apply)", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.chan:Broadcast(true); deliver()
    deltaChange(ml, "L1", "rolling")
    local snapshot = {}
    for _, m in ipairs(WIRE) do snapshot[#snapshot + 1] = m end
    deliver()                                -- apply once
    local applied = countEv(rd, "recv-lot")
    -- replay the same delta bytes again
    for _, m in ipairs(snapshot) do rd.chan:OnReceive(m.sender, m.value) end
    eq(countEv(rd, "recv-lot"), applied, "a replayed stale delta was ignored")
    eq(view(rd), view(ml), "store unchanged by the replay")
end)

test("two peers, one drops a delta, both converge", function()
    reset()
    local ml = makeHost("ML", true)
    local r1 = makeHost("R1", false)
    local r2 = makeHost("R2", false)
    ml.roster = { ML = true, R1 = true, R2 = true }
    ml.chan:Broadcast(true); deliver()
    -- a delta that only R1 receives (R2's copy is dropped). Model by delivering to R1 only.
    deltaChange(ml, "L1", "rolling")
    do
        local msgs = WIRE; WIRE = {}
        for _, m in ipairs(msgs) do if m.sender == "ML" then r1.chan:OnReceive(m.sender, m.value) end end
    end
    deltaChange(ml, "L1", "resolved")        -- R2 will see this with a gap
    deliver()                                -- R1 contiguous; R2 gaps -> RQ
    settle()                                 -- resync round-trips until the wire drains
    eq(view(r1), view(ml), "R1 converged")
    eq(view(r2), view(ml), "R2 converged after gap-triggered resync")
end)

test("heartbeat heals a peer that missed the last delta in a quiet session", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.roster = { ML = true, Raider = true }
    ml.chan:Broadcast(true); deliver()           -- synced at baseline
    eq(view(rd), view(ml), "synced at baseline")

    -- DROP the only delta and let the session go quiet: gap detection can never trigger because no
    -- future delta arrives to reveal the miss.
    deltaChange(ml, "L9", "resolved")
    clearWire()
    check(rd.chan.lastRev < ml.chan.rev, "peer is behind the authority's rev")

    -- the authority's heartbeat announces the current rev; the behind peer resyncs off it.
    CLOCK = CLOCK + 31
    ml.chan:Tick()
    deliver()
    check(countEv(rd, "recv-hb-gap") >= 1, "peer detected it was behind from the heartbeat")
    settle()
    eq(view(rd), view(ml), "peer converged via heartbeat-triggered resync")
end)

test("an in-sync peer ignores the heartbeat", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.roster = { ML = true, Raider = true }
    ml.chan:Broadcast(true); deliver()
    eq(rd.chan.lastRev, ml.chan.rev, "peer at authority's rev")

    CLOCK = CLOCK + 31
    ml.chan:Tick()
    deliver()
    eq(rd.chan.pendingRequest, nil, "in-sync peer did not request a resync")
    eq(countEv(rd, "recv-hb-gap"), 0, "in-sync peer logged no heartbeat gap")
end)

test("a stale, backlogged snapshot does not regress a peer that rode deltas past it", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.roster = { ML = true, Raider = true }
    setLine(ml, "L1", "v1")
    ml.chan:Broadcast(true); deliver()                 -- baseline: rd mirrors {L1=v1}, appliedEpoch set

    -- Peer asks for a resync; let the RQ reach the ML so it emits a TARGETED snapshot, but capture
    -- that snapshot off the wire BEFORE it reaches the peer (models a slow ChatThrottleLib delivery).
    rd.chan:RequestSync()
    deliver()                                          -- RQ -> ML; ML enqueues a snapshot onto the wire
    local held = {}
    for _, m in ipairs(WIRE) do held[#held + 1] = m end
    clearWire()
    local staleRev = ml.chan.rev

    -- Meanwhile the authority advances with deltas; the peer rides them forward past the snapshot's rev.
    deltaChange(ml, "L1", "v2"); deliver()
    deltaChange(ml, "L2", "v3"); deliver()
    local aheadRev = rd.chan.lastRev
    check(aheadRev > staleRev, "peer advanced past the stale snapshot's rev via deltas")

    -- The backlogged snapshot finally lands. It must NOT drag the peer (or its ledger) backward.
    for _, m in ipairs(held) do
        if m.dist ~= "WHISPER" or m.target == "Raider" then rd.chan:OnReceive(m.sender, m.value) end
    end
    eq(rd.chan.lastRev, aheadRev, "stale snapshot did not regress lastRev")
    eq(view(rd), view(ml), "peer kept the newer ledger; stale snapshot ignored")
    check(countEv(rd, "recv-snap-stale") >= 1, "the stale snapshot was logged as rejected")
end)

test("authority sends ONE snapshot per peer in flight, ignoring a flood of repeat requests", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.roster = { ML = true, Raider = true }
    setLine(ml, "L1", "rolling")

    -- The peer floods requests (retries on the same reqId, plus re-requests with new reqIds after it
    -- gives up) while a snapshot is still draining. The authority must emit exactly one snapshot and
    -- ignore the rest, or it backlogs faster than the wire drains.
    local function rq(reqId) return { "RQ", "Raider", reqId } end
    ml.chan:OnReceive("Raider", rq("r1"))            -- first request -> one snapshot
    ml.chan:OnReceive("Raider", rq("r1"))            -- retry, same reqId, snapshot still in flight
    ml.chan:OnReceive("Raider", rq("r2"))            -- new reqId after a "give-up", still in flight
    ml.chan:OnReceive("Raider", rq("r3"))

    local snaps = 0
    for _, m in ipairs(WIRE) do if firstField(m) == "SNAP" then snaps = snaps + 1 end end
    eq(snaps, 1, "only one snapshot emitted despite four requests")
end)

test("a peer ignores ledger state from a sender that is not its authority (no foreign loot)", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)                 -- its authority is "ML"
    setLine(ml, "L1", "real")
    ml.chan:Broadcast(true); deliver()
    eq(view(rd), view(ml), "peer synced from its real authority")

    -- Another group's loot master (a different sender) pushes its own snapshot AND a delta. The peer
    -- must ignore both: it is not bound to this authority, so the foreign ledger never leaks in.
    local foreign = makeHost("OtherML", true)
    setLine(foreign, "X9", "foreign")
    foreign.chan:Broadcast(true)                          -- foreign full snapshot
    deltaChange(foreign, "X9", "foreign2")                -- foreign delta
    deliver()
    eq(view(rd), view(ml), "peer kept its own ledger; foreign snapshot + delta ignored")
    check(countEv(rd, "drop-foreign") >= 1, "foreign state was logged as dropped")

    -- The real authority can still drive the peer (binding is by identity, not a blanket block).
    deltaChange(ml, "L1", "real2"); deliver()
    eq(view(rd), view(ml), "the real authority still updates the peer")
end)

test("a snapshot from an OLDER session (smaller epoch) is rejected; a newer one is adopted", function()
    reset()
    -- Same authority name, but its epoch (session id) is mutable, modelling a session restart.
    local epoch = "2000"
    local ml = makeHost("ML", true)
    ml.chan.cb.epoch = function() return epoch end          -- override the fixed-epoch stub
    local rd = makeHost("Raider", false)
    setLine(ml, "NEW", "current")
    ml.chan:Broadcast(true); deliver()
    eq(rd.chan.appliedEpoch, "2000", "peer adopted the current session epoch")
    eq(view(rd), view(ml), "peer mirrors the current session")

    -- A stale OLD session (smaller epoch) snapshot lands late -- e.g. a restored long-lived session
    -- that even sits at a higher rev. It must NOT drag the peer back to that dead session.
    epoch = "1000"
    ml.store = { ["OLD"] = { "OLD", "stale" } }
    ml.chan.rev = 999                                        -- old session sits at a far higher rev
    ml.chan:Broadcast(true); deliver()
    eq(rd.chan.appliedEpoch, "2000", "peer stayed on the newer session; older epoch rejected")
    check(rd.store["OLD"] == nil, "the stale session's lot did not leak in")
    check(countEv(rd, "recv-snap-stale", function(d) return d.reason == "epoch" end) >= 1,
        "older-epoch snapshot logged as rejected")

    -- A genuinely NEWER session (larger epoch) is adopted, replacing the ledger.
    epoch = "3000"
    ml.chan.rev = 0
    ml.store = { ["FRESH"] = { "FRESH", "new session" } }
    ml.chan:Broadcast(true); deliver()
    eq(rd.chan.appliedEpoch, "3000", "peer adopted the newer session")
    check(rd.store["FRESH"] ~= nil and rd.store["NEW"] == nil, "ledger replaced by the new session")
end)

test("every received heartbeat is logged with its verdict (in-sync vs behind)", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("R", false)
    -- bring the peer fully in sync
    setLine(ml, "A", "v1")
    ml.chan:Broadcast(true); settle()

    -- an in-sync heartbeat takes no action but MUST still leave a record, so that "received and
    -- ignored" is distinguishable from "never arrived" (a dead inbound leaves no recv-hb at all).
    ml.chan:Tick(1030); deliver()
    check(countEv(rd, "recv-hb", function(d) return d.verdict == "in-sync" end) >= 1, "in-sync heartbeat logged with verdict in-sync")
    eq(countEv(rd, "recv-hb-gap"), 0, "an in-sync heartbeat triggers no resync")

    -- advance the authority and DROP the delta, so only the heartbeat can reveal the peer is behind
    setLine(ml, "B", "v2")
    ml.chan:NotifyChanged({ ml.store["B"] }); ml.chan:Broadcast(false)
    clearWire()                                   -- the delta is lost on the wire
    ml.chan:Tick(1070); deliver()                 -- next heartbeat carries the higher rev
    check(countEv(rd, "recv-hb", function(d) return d.verdict == "behind" end) >= 1, "behind heartbeat logged with verdict behind")
    check(countEv(rd, "recv-hb-gap") >= 1, "a behind heartbeat drives the resync path")
end)

test("a NEWER generation at the same epoch (rev reset) rebaselines the peer instead of rejecting", function()
    reset()
    local ml = makeHost("ML", true, { epoch = "S1" })
    local rd = makeHost("R", false, { epoch = "S1" })
    ml.chan.nonce = "1000"                          -- generations are wall-clock stamps: numeric, ordered

    -- get the peer in sync and up to a high rev via a snapshot then deltas
    setLine(ml, "K1", "v1")
    ml.chan:Broadcast(true); settle()
    for i = 2, 6 do deltaChange(ml, "K" .. i, "v" .. i) end
    settle()
    eq(rd.chan.appliedEpoch, "S1", "peer synced to S1")
    eq(rd.chan.appliedGen, "1000", "peer recorded the authority's generation")
    local highRev = rd.chan.lastRev
    check(highRev and highRev >= 6, "peer is at a high rev before the restart (" .. tostring(highRev) .. ")")

    -- ML reloads: rev restarts at 0, SAME session epoch, NEWER generation, a fresh ledger
    ml.chan.rev = 0
    ml.chan.nonce = "2000"
    ml.store = { ["FRESH"] = { "FRESH", "post-reload" } }
    ml.chan:Broadcast(true); deliver()

    eq(rd.chan.lastRev, 1, "peer rebaselined to the restarted authority's low rev")
    eq(rd.chan.appliedGen, "2000", "peer adopted the new generation")
    check(rd.store["FRESH"] ~= nil and rd.store["K1"] == nil, "peer took the restarted authority's ledger")
    check(countEv(rd, "gen-restart") >= 1, "logged the generation restart")
    eq(countEv(rd, "recv-snap-stale"), 0, "the restarted authority's low-rev snapshot was NOT rejected as stale")
end)

test("a same-generation lower-rev snapshot is still rejected as a stale backslide", function()
    reset()
    local ml = makeHost("ML", true, { epoch = "S1" })
    local rd = makeHost("R", false, { epoch = "S1" })
    ml.chan.nonce = "1000"

    setLine(ml, "K1", "v1")
    ml.chan:Broadcast(true); settle()
    for i = 2, 5 do deltaChange(ml, "K" .. i, "v" .. i) end
    settle()
    local high = rd.chan.lastRev

    -- a backlogged snapshot built at a LOWER rev but the SAME generation must NOT rebaseline us
    ml.chan.rev = 1
    ml.chan:Broadcast(true); deliver()
    eq(rd.chan.lastRev, high, "peer did not regress on a same-generation lower-rev snapshot")
    check(countEv(rd, "recv-snap-stale") >= 1, "same-generation backslide still rejected as stale")
    eq(countEv(rd, "gen-restart"), 0, "no false generation-restart on the same generation")
end)

test("a backlogged snapshot from an OLDER generation is rejected (no regression)", function()
    reset()
    local ml = makeHost("ML", true, { epoch = "S1" })
    local rd = makeHost("R", false, { epoch = "S1" })

    -- peer is synced to the CURRENT load (generation 2000) at a low rev after a restart
    ml.chan.nonce = "2000"
    ml.chan.rev = 0
    ml.store = { ["CUR"] = { "CUR", "current" } }
    ml.chan:Broadcast(true); deliver()
    eq(rd.chan.appliedGen, "2000", "peer is on the current generation")
    local curRev = rd.chan.lastRev

    -- a straggler snapshot from the PREVIOUS load (generation 1000) arrives late at a HIGH rev. Its rev
    -- is ABOVE the peer's freshly-rebaselined rev, so the rev guard would NOT catch it; only generation
    -- ordering rejects it. Without that, it would regress the peer to the pre-reload ledger.
    ml.chan.nonce = "1000"
    ml.chan.rev = 62
    ml.store = { ["OLD"] = { "OLD", "pre-reload" } }
    ml.chan:Broadcast(true); deliver()

    eq(rd.chan.lastRev, curRev, "peer did not regress to the older generation's rev")
    eq(rd.chan.appliedGen, "2000", "peer kept the current generation")
    check(rd.store["CUR"] ~= nil and rd.store["OLD"] == nil, "peer kept the current ledger, ignored the straggler")
    check(countEv(rd, "recv-snap-stale", function(d) return d.reason == "gen" end) >= 1,
        "older-generation snapshot rejected on the generation")
end)

-- ===========================================================================
print("")
print(string.format("=== WeirdSync battery: %d passed, %d failed ===", pass, fail))
if fail > 0 then
    print("FAILURES:")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
end
