-- WeirdComm-1.0 test battery.
--
-- Exercises the transport against a mock server that enforces ChromieCraft's REAL limits
-- (255B/message hard reject, ~99 msgs/sec -> 10s mute, counted per sent message, RAID fan-out
-- vs WHISPER targeting). Deliberately adversarial: out-of-order / duplicate / lost chunks,
-- interleaved messages, same msgId from different senders, payload-size boundaries,
-- incompressible-fallback, byte-hostile payloads, malformed / corrupt / foreign input, the
-- pacer staying under the mute, and priority preemption.
--
-- Run from the addon dir:  luajit tests/weirdcomm.lua   (exit 1 on any failure)

strmatch = string.match; strfind = string.find; strsub = string.sub; strlen = string.len
strrep = string.rep; strchar = string.char; strbyte = string.byte; format = string.format
gsub = string.gsub; gmatch = string.gmatch; tinsert = table.insert; tremove = table.remove
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

local function loadlib(p) return assert(loadfile(p))() end
loadlib("Libs/LibStub/LibStub.lua")
loadlib("Libs/LibDeflate/LibDeflate.lua")
loadlib("Libs/LibSerialize/LibSerialize.lua")
local WeirdComm = loadlib("Libs/WeirdComm-1.0/WeirdComm-1.0.lua")

-- ---------------------------------------------------------------------------
-- tiny test framework
-- ---------------------------------------------------------------------------
local pass, fail = 0, 0
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL " .. tostring(label)) end
end
local function test(name, fn)
    print("[" .. name .. "]")
    local good, err = pcall(fn)
    if not good then fail = fail + 1; print("  ERROR " .. tostring(err)) end
end
local function deepeq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deepeq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- ---------------------------------------------------------------------------
-- mock server: real-limit model (see WEIRDCOMM_PLAN.md / reference_chromiecraft_addon_traffic_limits)
-- ---------------------------------------------------------------------------
local function newServer()
    local S = {
        now = 1000, clients = {}, sendLog = {},
        rejects = 0, mutes = 0, muteUntil = {}, sec = {},
        maxPerSecObserved = {},   -- name -> peak messages seen in any single integer second
        echoSelf = true,          -- RAID delivers to sender too (real WoW often does)
    }
    function S:register(name, ch) self.clients[name] = ch end
    function S:sendFn(name)
        return function(prefix, text, dist, target)
            if #prefix + #text > 255 then self.rejects = self.rejects + 1; return end
            if self.muteUntil[name] and self.now < self.muteUntil[name] then return end
            local isec = math.floor(self.now)
            local s = self.sec[name]
            if not s or s.isec ~= isec then s = { isec = isec, n = 0 }; self.sec[name] = s end
            s.n = s.n + 1
            self.maxPerSecObserved[name] = math.max(self.maxPerSecObserved[name] or 0, s.n)
            if s.n >= 100 then self.muteUntil[name] = self.now + 10; self.mutes = self.mutes + 1; return end
            self.sendLog[#self.sendLog + 1] = { name = name, dist = dist }
            if dist == "WHISPER" then
                local c = self.clients[target]
                if c then c:OnReceive(prefix, text, dist, name) end
            else
                for cname, c in pairs(self.clients) do
                    if self.echoSelf or cname ~= name then c:OnReceive(prefix, text, dist, name) end
                end
            end
        end
    end
    return S
end

local PREFIX = "WLSYNC"
-- build a channel for player `name` on server S, recording delivered messages
local function newClient(S, name, opts)
    opts = opts or {}
    local inbox = {}
    local ch = WeirdComm:NewChannel(PREFIX, {
        send = S:sendFn(name),
        getTime = function() return S.now end,
        onMessage = function(value, sender, dist) inbox[#inbox + 1] = { value = value, sender = sender, dist = dist } end,
        selfName = opts.selfName,
        rate = opts.rate, burst = opts.burst,
        compressMin = opts.compressMin, partialTimeout = opts.partialTimeout,
        log = opts.log,
    })
    S:register(name, ch)
    return ch, inbox
end

-- deterministic INCOMPRESSIBLE bytes via xorshift32 (LCG low bits compress; xorshift's do not).
-- Used to force genuinely multi-frame messages and to test the raw-vs-deflate fallback.
local bit = require("bit")
local function rndBytes(n, seed)
    local x = bit.band(seed or 0x2545F491, 0xFFFFFFFF)
    if x == 0 then x = 0x1 end
    local out = {}
    for i = 1, n do
        x = bit.band(bit.bxor(x, bit.lshift(x, 13)), 0xFFFFFFFF)
        x = bit.bxor(x, bit.rshift(x, 17))
        x = bit.band(bit.bxor(x, bit.lshift(x, 5)), 0xFFFFFFFF)
        out[i] = string.char(bit.band(x, 0xFF))
    end
    return table.concat(out)
end

local FP = WeirdComm.WIRE_MAX - #PREFIX - WeirdComm.HEADER_LEN - 1   -- frame payload capacity

-- ===========================================================================
test("round-trips a rich table ML->raider over RAID", function()
    local S = newServer()
    local ml = newClient(S, "Masterlooter")
    local _, rinbox = newClient(S, "Raider")
    local snap = { epoch = "1700", rev = 4, lots = { { id = 1, link = "|cffa335ee|Hitem:40001|h[X]|h|r", awards = { { winner = "Raider", state = "owed" } } } } }
    ml:Send(snap, "RAID")
    ok(#rinbox == 1, "raider received exactly one message")
    ok(deepeq(rinbox[1].value, snap), "payload deep-equals original")
    ok(rinbox[1].sender == "Masterlooter", "sender preserved")
    ok(S.rejects == 0, "no frame exceeded the 255B cap")
end)

test("every reassembled inbound message logs one transport recv", function()
    local S = newServer()
    local events = {}
    local ml = newClient(S, "Masterlooter")
    local _, rinbox = newClient(S, "Raider", { log = function(ev, data) events[#events + 1] = { ev = ev, data = data or {} } end })
    ml:Send({ "H", "S1", "7" }, "RAID")                                  -- single-frame
    ml:Send({ "SNAP", "S1", "8", "", { blob = rndBytes(3 * FP, 5) } }, "RAID")  -- multi-frame (incompressible)
    S.now = S.now + 1; ml:Tick(S.now)                                    -- drain the pacer
    local recvs = {}
    for _, e in ipairs(events) do if e.ev == "recv" then recvs[#recvs + 1] = e.data end end
    ok(#recvs == 2, "one recv per COMPLETE message, not per frame (got " .. #recvs .. ")")
    ok(recvs[1].tag == "H" and recvs[1].sender == "Masterlooter" and recvs[1].dist == "RAID", "recv carries tag/sender/dist")
    ok((recvs[2].bytes or 0) > FP, "multi-frame message logs one recv with the summed byte count")
    ok(#rinbox == 2, "both messages still delivered to onMessage")
end)

test("a decode failure logs recv-decode-fail, not a recv", function()
    local S = newServer()
    local events = {}
    local _, inbox = newClient(S, "R", { log = function(ev, data) events[#events + 1] = { ev = ev, data = data or {} } end })
    local R = S.clients["R"]
    R:OnReceive(PREFIX, "00" .. "01" .. "01" .. "0" .. "!!garbage!!", "RAID", "X")  -- valid header, corrupt body
    local recv, fail = 0, 0
    for _, e in ipairs(events) do
        if e.ev == "recv" then recv = recv + 1 elseif e.ev == "recv-decode-fail" then fail = fail + 1 end
    end
    ok(fail == 1 and recv == 0, "a corrupt message logs the failure and never a success recv")
    ok(#inbox == 0, "nothing delivered upstream")
end)

test("WHISPER reaches only the target, not the whole raid", function()
    local S = newServer()
    local a = newClient(S, "A")
    local _, binbox = newClient(S, "B")
    local _, cinbox = newClient(S, "C")
    a:Send({ msg = "for B only" }, "WHISPER", "B")
    ok(#binbox == 1 and deepeq(binbox[1].value, { msg = "for B only" }), "B got it")
    ok(#cinbox == 0, "C did not")
end)

test("self-echo dropped when selfName is set", function()
    local S = newServer()
    local ml, mlinbox = newClient(S, "Masterlooter", { selfName = "Masterlooter" })
    ml:Send({ x = 1 }, "RAID")
    ok(#mlinbox == 0, "own RAID broadcast not delivered back to self")
end)

test("payload-size sweep: every chunk fits, all sizes round-trip", function()
    local S = newServer()
    local sender = newClient(S, "S")
    local _, inbox = newClient(S, "R")
    local worst = 0
    for n = 0, 3 * FP + 5 do
        -- incompressible so size n actually spans the intended number of frames (covers boundaries)
        local payload = rndBytes(n, 100 + n)
        sender:Send({ p = payload }, "RAID")
        S.now = S.now + 1                            -- refill the pacer so no message is starved
        sender:Tick(S.now)
        local got = inbox[#inbox]
        if not (got and got.value.p == payload) then ok(false, "size " .. n .. " round-trip"); return end
        worst = n
    end
    ok(true, "all sizes 0.." .. worst .. " round-tripped")
    ok(S.rejects == 0, "no oversize frame across the whole sweep")
end)

test("EncodeFrames respects the frame budget and chunk math", function()
    -- direct codec: assert non-final chunks are exactly full, all <= budget, count = ceil
    local payload = { blob = rndBytes(5 * FP, 7) }   -- incompressible -> genuinely multi-chunk
    local frames = WeirdComm.EncodeFrames(payload, 0, FP, 96)
    ok(#frames >= 2, "multi-chunk payload produced multiple frames")
    local okSizes = true
    for i, f in ipairs(frames) do
        if #f > WeirdComm.HEADER_LEN + FP then okSizes = false end
        if i < #frames and #f ~= WeirdComm.HEADER_LEN + FP then okSizes = false end
    end
    ok(okSizes, "non-final frames are exactly full, none over budget")
    local good, back = WeirdComm.DecodeFrames(frames)
    ok(good and deepeq(back, payload), "direct decode round-trips")
end)

test("out-of-order chunk arrival still reassembles", function()
    local S = newServer()
    local _, inbox = newClient(S, "R")
    local blob = rndBytes(4 * FP, 11)
    local frames = WeirdComm.EncodeFrames({ blob = blob }, 0, FP, 96)
    ok(#frames >= 3, "have several chunks")
    local R = S.clients["R"]
    -- deliver reversed
    for i = #frames, 1, -1 do R:OnReceive(PREFIX, frames[i], "RAID", "X") end
    ok(#inbox == 1 and inbox[1].value.blob == blob, "reassembled despite reverse order")
end)

test("duplicate chunks are ignored, message delivered once", function()
    local S = newServer()
    local _, inbox = newClient(S, "R")
    local frames = WeirdComm.EncodeFrames({ blob = rndBytes(3 * FP, 22) }, 0, FP, 96)
    ok(#frames >= 2, "multi-chunk")
    local R = S.clients["R"]
    -- interleave each chunk with an immediate duplicate (in-flight dup), then resend the whole
    -- message again (whole-message dup): both must collapse to a single delivery.
    for _, f in ipairs(frames) do R:OnReceive(PREFIX, f, "RAID", "X"); R:OnReceive(PREFIX, f, "RAID", "X") end
    for _, f in ipairs(frames) do R:OnReceive(PREFIX, f, "RAID", "X") end
    ok(#inbox == 1, "delivered exactly once despite full duplication")
end)

test("a lost chunk: never delivered, partial evicted after timeout", function()
    local S = newServer()
    local R, inbox = newClient(S, "R", { partialTimeout = 20 })
    local frames = WeirdComm.EncodeFrames({ blob = rndBytes(3 * FP, 33) }, 0, FP, 96)
    ok(#frames >= 2, "multi-chunk")
    for i = 1, #frames - 1 do R:OnReceive(PREFIX, frames[i], "RAID", "X") end   -- drop last
    ok(#inbox == 0, "incomplete message not delivered")
    ok(R.rx["X"] ~= nil, "partial buffer present before timeout")
    S.now = S.now + 25
    R:Tick(S.now)
    ok(R.rx["X"] == nil, "partial buffer evicted after timeout")
    ok(#inbox == 0, "still not delivered")
end)

test("interleaved messages from one sender reassemble independently", function()
    local S = newServer()
    local R, inbox = newClient(S, "R")
    local fa = WeirdComm.EncodeFrames({ tag = "A", blob = rndBytes(2 * FP, 44) }, 0, FP, 96)
    local fb = WeirdComm.EncodeFrames({ tag = "B", blob = rndBytes(2 * FP, 55) }, 1, FP, 96)
    -- interleave A and B frames
    local maxn = math.max(#fa, #fb)
    for i = 1, maxn do
        if fa[i] then R:OnReceive(PREFIX, fa[i], "RAID", "X") end
        if fb[i] then R:OnReceive(PREFIX, fb[i], "RAID", "X") end
    end
    ok(#inbox == 2, "both messages delivered")
    local tags = {}
    for _, m in ipairs(inbox) do tags[m.value.tag] = true end
    ok(tags.A and tags.B, "both A and B reassembled correctly")
end)

test("same msgId from different senders does not cross-contaminate", function()
    local S = newServer()
    local R, inbox = newClient(S, "R")
    -- identical msgId 0, different content, different senders, interleaved
    local fa = WeirdComm.EncodeFrames({ who = "alice", blob = rndBytes(2 * FP, 66) }, 0, FP, 96)
    local fb = WeirdComm.EncodeFrames({ who = "bob", blob = rndBytes(2 * FP, 77) }, 0, FP, 96)
    for i = 1, math.max(#fa, #fb) do
        if fa[i] then R:OnReceive(PREFIX, fa[i], "RAID", "Alice") end
        if fb[i] then R:OnReceive(PREFIX, fb[i], "RAID", "Bob") end
    end
    ok(#inbox == 2, "both delivered")
    local byWho = {}
    for _, m in ipairs(inbox) do byWho[m.value.who] = m.sender end
    ok(byWho.alice == "Alice" and byWho.bob == "Bob", "kept separate by sender")
end)

test("compression decisions: tiny=raw, repetitive=deflate, random=raw-fallback", function()
    local tiny = WeirdComm.EncodeFrames("hi", 0, FP, 96)
    ok(string.sub(tiny[1], 7, 7) == "0", "tiny payload sent raw (no deflate)")

    local repetitive = WeirdComm.EncodeFrames({ s = string.rep("ABCD", 200) }, 0, FP, 96)
    ok(string.sub(repetitive[1], 7, 7) == "1", "repetitive payload deflated")

    local random = WeirdComm.EncodeFrames({ s = rndBytes(800, 99) }, 0, FP, 96)
    ok(string.sub(random[1], 7, 7) == "0", "incompressible payload fell back to raw")

    -- all three still round-trip
    local _, t1 = WeirdComm.DecodeFrames(tiny)
    local _, t2 = WeirdComm.DecodeFrames(repetitive)
    local _, t3 = WeirdComm.DecodeFrames(random)
    ok(t1 == "hi", "raw tiny decodes")
    ok(t2 and #t2.s == 800, "deflated decodes")
    ok(t3 and #t3.s == 800, "raw-fallback decodes")
end)

test("byte-hostile payload survives (|, NUL, newlines, separators)", function()
    local S = newServer()
    local sender = newClient(S, "S")
    local _, inbox = newClient(S, "R")
    local nasty = {
        link = "|cffa335ee|Hitem:40001:0:0|h[Item|with|pipes]|h|r",
        ctrl = string.char(0) .. string.char(10) .. string.char(13) .. string.char(30) .. string.char(124) .. string.char(37),
        nested = { [1] = "tab\there", ["key=with,sep"] = "v" },
        num = -3.5, big = 2 ^ 31,
    }
    sender:Send(nasty, "RAID")
    ok(#inbox == 1 and deepeq(inbox[1].value, nasty), "all hostile bytes round-tripped intact")
    ok(S.rejects == 0, "still channel-safe (no oversize/illegal frame)")
end)

test("structural edges: empty table, shared reference, deep nesting", function()
    local S = newServer()
    local sender = newClient(S, "S")
    local _, inbox = newClient(S, "R")

    sender:Send({}, "RAID")
    ok(deepeq(inbox[#inbox].value, {}), "empty table round-trips")

    local shared = { name = "dup" }
    local withRefs = { a = shared, b = shared, list = { shared, shared } }
    sender:Send(withRefs, "RAID")
    local got = inbox[#inbox].value
    ok(deepeq(got, withRefs), "shared-reference table round-trips (dedup-safe)")

    local deep = {}
    local cur = deep
    for i = 1, 50 do cur.child = { i = i }; cur = cur.child end
    sender:Send(deep, "RAID")
    ok(deepeq(inbox[#inbox].value, deep), "50-deep nesting round-trips")
end)

test("malformed / corrupt / foreign inbound is ignored, never crashes", function()
    local S = newServer()
    local R, inbox = newClient(S, "R")
    R:OnReceive("OTHERADDON", "whatever", "RAID", "X")          -- foreign prefix
    R:OnReceive(PREFIX, "x", "RAID", "X")                       -- too short for header
    R:OnReceive(PREFIX, "!!badhdr!!rest", "RAID", "X")          -- non-base62 header
    R:OnReceive(PREFIX, "0001zz1garbagepayload", "RAID", "X")   -- header ok, payload garbage
    -- a single-frame message whose payload is not valid encoded/serialized data
    local frames = WeirdComm.EncodeFrames({ real = true }, 5, FP, 96)
    local mangled = string.sub(frames[1], 1, WeirdComm.HEADER_LEN) .. "!!!notvalid!!!"
    R:OnReceive(PREFIX, mangled, "RAID", "X")
    ok(#inbox == 0, "nothing delivered from any malformed input")
    ok(true, "no error raised on any malformed input")
end)

test("header claims idx>cnt or idx<1 -> rejected", function()
    local S = newServer()
    local R, inbox = newClient(S, "R")
    -- craft header: id=00, idx=05, cnt=02 (idx>cnt) then junk
    R:OnReceive(PREFIX, "0005020payload", "RAID", "X")
    -- idx=00 (idx<1)
    R:OnReceive(PREFIX, "0000010payload", "RAID", "X")
    ok(#inbox == 0, "implausible chunk indices rejected")
end)

test("PACER stays under the 99/sec mute under a flood, delivers everything", function()
    local S = newServer()
    local ml = newClient(S, "Masterlooter", { rate = 50, burst = 10 })
    local _, inbox = newClient(S, "Raider")
    -- 60 large multi-chunk messages enqueued instantly = hundreds of frames
    local sent = {}
    for i = 1, 60 do
        local v = { i = i, blob = string.rep("x", 3 * FP) }
        sent[i] = v
        ml:Send(v, "RAID")
    end
    -- drive time forward in 0.05s ticks until everything drains (cap iterations)
    local guard = 0
    repeat
        S.now = S.now + 0.05
        ml:Tick(S.now)
        guard = guard + 1
    until (#ml._hi == 0 and #ml._lo == 0) or guard > 100000
    ok(#inbox == 60, "all 60 messages eventually delivered (" .. #inbox .. ")")
    ok(S.mutes == 0, "never tripped the server mute")
    ok((S.maxPerSecObserved["Masterlooter"] or 0) < 100, "peak " .. (S.maxPerSecObserved["Masterlooter"] or 0) .. " msgs/sec < 100")
end)

test("ALERT preempts queued BULK", function()
    local S = newServer()
    -- tight budget so frames drain slowly and ordering is observable
    local ml = newClient(S, "ML", { rate = 4, burst = 2 })
    local _, inbox = newClient(S, "R")
    -- a big BULK message (many frames) enqueued first
    ml:Send({ tag = "bulk", blob = rndBytes(6 * FP, 88) }, "RAID", nil, "BULK")
    ml:_pump(S.now)                       -- send the first couple frames (burst)
    ml:Send({ tag = "alert", x = 1 }, "RAID", nil, "ALERT")   -- urgent, single frame
    -- drain
    local guard = 0
    repeat S.now = S.now + 0.1; ml:Tick(S.now); guard = guard + 1
    until (#ml._hi == 0 and #ml._lo == 0) or guard > 100000
    ok(#inbox == 2, "both delivered")
    local alertIdx, bulkIdx
    for i, m in ipairs(inbox) do
        if m.value.tag == "alert" then alertIdx = i elseif m.value.tag == "bulk" then bulkIdx = i end
    end
    ok(alertIdx and bulkIdx and alertIdx < bulkIdx, "ALERT delivered before the still-draining BULK")
end)

test("clock going backwards does not refund tokens or stall", function()
    local S = newServer()
    local ml = newClient(S, "ML", { rate = 5, burst = 2 })
    local _, inbox = newClient(S, "R")
    for i = 1, 4 do ml:Send({ i = i }, "RAID") end
    ml:_pump(S.now)
    S.now = S.now - 5          -- clock jumps backward
    ml:_pump(S.now)            -- must not crash or grant negative-dt tokens
    -- advance normally and drain
    local guard = 0
    repeat S.now = S.now + 0.3; ml:Tick(S.now); guard = guard + 1
    until (#ml._hi == 0 and #ml._lo == 0) or guard > 100000
    ok(#inbox == 4, "all delivered despite a backward clock jump")
end)

test("oversize-by-construction value is reported, not silently dropped", function()
    -- a payload so large its frame count would exceed 2-char (base62) addressing
    local huge = string.rep("u", (62 * 62 + 5) * FP)   -- > 3844 chunks
    local frames, err = WeirdComm.EncodeFrames({ s = huge }, 0, FP, 999999999)  -- force raw (no deflate)
    ok(frames == nil and err ~= nil, "encode refuses an unaddressable payload with an error")
end)

test("mute-risk canary warns once per second when our own send rate nears the limit", function()
    local S = newServer()
    local warns = {}
    local ch = WeirdComm:NewChannel(PREFIX, {
        send = S:sendFn("ML"), getTime = function() return S.now end,
        burst = 500, rate = 50, muteWarn = 10,           -- big burst: force many sends in one second
        warn = function(n) warns[#warns + 1] = n end,
    })
    S:register("ML", ch)
    for i = 1, 15 do ch:Send({ i = i }, "RAID") end       -- 15 in the SAME integer-second
    ok(#warns == 1, "warned exactly once in the second (got " .. #warns .. ")")
    ok(warns[1] and warns[1] >= 10, "warn reported the over-threshold count")
    S.now = S.now + 1                                     -- new second resets the canary
    for i = 1, 12 do ch:Send({ i = i }, "RAID") end
    ok(#warns == 2, "canary reset on the new second and warned again")
end)

test("mute-risk canary stays silent under normal pacing", function()
    local S = newServer()
    local warns = {}
    local ch = WeirdComm:NewChannel(PREFIX, {
        send = S:sendFn("ML"), getTime = function() return S.now end,
        rate = 50, burst = 10, warn = function(n) warns[#warns + 1] = n end,
    })
    S:register("ML", ch)
    for i = 1, 40 do ch:Send({ i = i, blob = string.rep("x", 3 * FP) }, "RAID") end
    local guard = 0
    repeat S.now = S.now + 0.05; ch:Tick(S.now); guard = guard + 1
    until (#ch._hi == 0 and #ch._lo == 0) or guard > 100000
    ok(#warns == 0, "no mute-risk warning under the default pacer (peak stayed below muteWarn)")
end)

print(string.format("\n=== WeirdComm battery: %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
