-- WeirdComm-1.0
-- A message-paced addon transport that sends arbitrary Lua VALUES (tables/strings/
-- numbers) over the WoW addon channel, replacing AceComm-3.0 + ChatThrottleLib for
-- WeirdLoot's session sync. WeirdSync-1.0 sits on top for rev/epoch/reliability and
-- just hands WeirdComm tables; WeirdComm owns the bytes.
--
-- Why this exists (see WeirdLoot/WEIRDCOMM_PLAN.md):
--   * ChromieCraft/AzerothCore throttles addon traffic by MESSAGE COUNT (~99 msgs/sec
--     before a 10s mute), 255 bytes/message, no packet-level cap. ChatThrottleLib paces
--     by BYTES at a 30x-too-conservative 800 B/s, and we fragmented state into dozens of
--     tiny messages. WeirdComm paces by message count (matching the real limit) and sends
--     state as one serialized+compressed blob chunked across the fewest frames.
--
-- Pipeline (send):  value -> LibSerialize -> (LibDeflate if it shrinks) ->
--                   our own channel codec -> chunk across <=255B frames -> token-bucket pace.
-- Pipeline (recv):  reassemble frames by (sender,msgId) -> channel codec decode ->
--                   (DecompressDeflate) -> LibSerialize:Deserialize -> deliver value.
--
-- WeirdComm is transport only: it does NOT retry, ack, or detect gaps. Reliability is the
-- consumer's job (WeirdSync). A dropped/lost frame just means the message is never delivered;
-- WeirdComm guarantees it will never deliver a partial or corrupt one.
--
-- Ordering: ChromieCraft/AzerothCore delivers a single sender's messages IN ORDER (boost::asio
-- TCP + per-session FIFO processing + a synchronous Group::BroadcastPacket loop), corroborated by
-- WeakAuras relying on AceComm's ordered FIRST/NEXT/LAST reassembly working in-game. So we do NOT
-- depend on the network reordering. We still address chunks by explicit (msgId, idx, cnt) rather
-- than AceComm's positional FIRST/NEXT/LAST, because our OWN priority pacer interleaves an ALERT
-- message's frames between a BULK message's frames from the same sender -- AceComm forbids that by
-- serializing per queue; we allow it, so reassembly must be keyed, not positional. Frames CAN still
-- be lost (recipient out of range, the 10s mute window, best-effort addon channel); that is what
-- WeirdSync's resync/heartbeat recovers.

local MAJOR, MINOR = "WeirdComm-1.0", 1
local LibStub = _G.LibStub
local WeirdComm = LibStub and LibStub:NewLibrary(MAJOR, MINOR)
if not WeirdComm then return end   -- already loaded a same-or-newer copy

local LibDeflate = LibStub:GetLibrary("LibDeflate", true)
local LibSerialize = LibStub:GetLibrary("LibSerialize", true)
assert(LibDeflate, "WeirdComm-1.0 requires LibDeflate")
assert(LibSerialize, "WeirdComm-1.0 requires LibSerialize")

-- Our own channel codec instead of LibDeflate:EncodeForWoWAddonChannel.
-- LibDeflate is a LibStub global, so whichever copy in the user's AddOns folder registers the
-- highest minor wins for everyone -- and its built-in addon-channel codec is NOT stable across
-- versions: 1.0.0 reserves "\000\124" (escapes the pipe), 1.0.2 reserves only "\000" (pipe rides
-- raw). Two raiders on different LibDeflate versions therefore disagree on the wire, and the
-- 1.0.0 -> 1.0.2 direction does not even fail loudly: the orphaned escape byte is dropped and
-- LibSerialize happily deserializes the mangled bytes. Building the codec ourselves pins the
-- format to WeirdComm regardless of which LibDeflate answers. CreateCodec's output is identical
-- across versions (tests/weirdcomm.lua pins it against both).
-- Pipe stays reserved: the server does not sanitise addon messages (lang == LANG_ADDON skips the
-- validity block in ChatHandler.cpp), but escaping it costs ~1/256 of payload and keeps the
-- bytes safe for anything client-side that treats "|" as an escape.
local CODEC = LibDeflate:CreateCodec("\000\124", "\001", "")

-- ---------------------------------------------------------------------------
-- frame budget
-- The wire ceiling is prefix+text <= 254 (AceComm's safe value; the server hard-rejects
-- >255, ChatHandler.cpp:279). Our text = fixed 7-byte header + payload chunk. With the
-- default 6-byte prefix that leaves 254-6-7 = 241; we use 240 for a 1-byte cushion.
-- Constructed per channel from the real prefix length so a longer prefix still fits.
-- ---------------------------------------------------------------------------
local WIRE_MAX = 254
local HEADER_LEN = 7              -- msgId(2) + idx(2) + cnt(2) + comp(1), fixed width base62

-- base62 fixed-width int<->string. Output is plain alphanumerics: always addon-channel
-- safe, and fixed width means no delimiter can be confused with payload bytes.
local B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local B62REV = {}
for i = 1, #B62 do B62REV[string.sub(B62, i, i)] = i - 1 end
local B62_MAX2 = 62 * 62 - 1      -- 3843: max value a 2-char field can hold

local function toB62(n, width)
    local s = ""
    for _ = 1, width do
        local d = n % 62
        s = string.sub(B62, d + 1, d + 1) .. s
        n = math.floor(n / 62)
    end
    return s
end

local function fromB62(s)
    local n, ok = 0, true
    for i = 1, #s do
        local d = B62REV[string.sub(s, i, i)]
        if not d then ok = false; break end
        n = n * 62 + d
    end
    return ok and n or nil
end

-- ---------------------------------------------------------------------------
-- pure codec: value <-> ordered list of frame texts (each ready to hand to SendAddonMessage)
-- ---------------------------------------------------------------------------

-- Encode a value into frame texts under msgId. compressMin gates deflate (tiny payloads
-- deflate to LARGER output, so they ride raw); we also fall back to raw whenever deflate
-- failed to shrink. Returns frames (list of strings) or nil,err.
function WeirdComm.EncodeFrames(value, msgId, framePayload, compressMin)
    local ser = LibSerialize:Serialize(value)
    local comp = "0"
    local body = ser
    if #ser >= (compressMin or 0) then
        local deflated = LibDeflate:CompressDeflate(ser)
        if deflated and #deflated < #ser then
            comp, body = "1", deflated
        end
    end
    local wire = CODEC:Encode(body)

    local total = #wire
    local nChunks = (total == 0) and 1 or math.ceil(total / framePayload)
    if nChunks > B62_MAX2 + 1 then
        return nil, "payload too large (" .. total .. "B exceeds frame addressing)"
    end

    local frames = {}
    local idHdr = toB62(msgId % (B62_MAX2 + 1), 2)
    local cntHdr = toB62(nChunks, 2)
    for i = 1, nChunks do
        local from = (i - 1) * framePayload + 1
        local chunk = string.sub(wire, from, from + framePayload - 1)
        frames[i] = idHdr .. toB62(i, 2) .. cntHdr .. comp .. chunk
    end
    return frames
end

-- Decode an ordered, COMPLETE list of frame texts back to the value. Returns ok,value.
-- ok=false on any malformation (bad header, missing chunk, decode/decompress/deserialize
-- failure). Never errors.
function WeirdComm.DecodeFrames(frames)
    if type(frames) ~= "table" or #frames == 0 then return false, "no frames" end
    local comp, parts = nil, {}
    local cnt
    for _, f in ipairs(frames) do
        if type(f) ~= "string" or #f < HEADER_LEN then return false, "short frame" end
        local idx = fromB62(string.sub(f, 3, 4))
        local fcnt = fromB62(string.sub(f, 5, 6))
        local fcomp = string.sub(f, 7, 7)
        if not idx or not fcnt then return false, "bad header" end
        cnt = cnt or fcnt
        comp = comp or fcomp
        if fcnt ~= cnt then return false, "inconsistent count" end
        parts[idx] = string.sub(f, HEADER_LEN + 1)
    end
    for i = 1, cnt do
        if parts[i] == nil then return false, "missing chunk " .. i end
    end
    local wire = table.concat(parts, "", 1, cnt)

    local decoded = CODEC:Decode(wire)
    if not decoded then return false, "channel decode failed" end
    local raw = decoded
    if comp == "1" then
        raw = LibDeflate:DecompressDeflate(decoded)
        if not raw then return false, "inflate failed" end
    end
    return LibSerialize:Deserialize(raw)   -- ok,value (pcall-safe inside LibSerialize)
end

-- ---------------------------------------------------------------------------
-- channel: stateful send pacing + receive reassembly
-- ---------------------------------------------------------------------------
local Channel = {}
local ChannelMeta = { __index = Channel }

-- The server mutes a player's REGULAR chat (not its addon traffic) at this many addon messages in
-- one second (CONFIG_CHATFLOOD_ADDON_MESSAGE_COUNT). We never want to approach it; muteWarn is the
-- canary threshold. NOTE: we can only count THIS channel's sends -- other addons add to the real
-- server tally too -- so our count is a lower bound, which is exactly why the warn sits well below 100.
local MUTE_LIMIT = 100

local DEFAULTS = {
    rate = 50,            -- messages/sec sustained (well under the mute)
    burst = 10,           -- token-bucket capacity (max messages back-to-back after idle)
    compressMin = 96,     -- only attempt deflate at/above this serialized size
    partialTimeout = 20,  -- seconds before an incomplete reassembly buffer is evicted
    muteWarn = 80,        -- warn (debug) if our own sends in one second reach this (mute risk)
}

-- opts: send(prefix,text,dist,target) [required], onMessage(value,sender,dist),
--       getTime()->seconds, log(ev,data), selfName, rate, burst, compressMin, partialTimeout,
--       muteWarn, warn(sentThisSecond) [debug notification when send rate nears the mute]
function WeirdComm:NewChannel(prefix, opts)
    assert(type(prefix) == "string" and #prefix > 0, "WeirdComm: prefix required")
    opts = opts or {}
    assert(type(opts.send) == "function", "WeirdComm: opts.send required")
    local c = setmetatable({}, ChannelMeta)
    c.prefix = prefix
    c.opts = opts
    c.rate = opts.rate or DEFAULTS.rate
    c.burst = opts.burst or DEFAULTS.burst
    c.compressMin = opts.compressMin or DEFAULTS.compressMin
    c.partialTimeout = opts.partialTimeout or DEFAULTS.partialTimeout
    c.muteWarn = opts.muteWarn or DEFAULTS.muteWarn
    c._sendSec, c._sendCount, c._warnedSec = -1, 0, -1   -- per-integer-second send-rate canary
    c.framePayload = WIRE_MAX - #prefix - HEADER_LEN - 1   -- -1 byte cushion
    assert(c.framePayload > 0, "WeirdComm: prefix too long for the wire budget")
    c.getTime = opts.getTime or function() return 0 end
    c._nextId = 0
    c._hi, c._lo = {}, {}        -- FIFO frame queues (ALERT, BULK)
    c._tokens = c.burst
    c._lastPump = c.getTime()
    c.rx = {}                    -- rx[sender][msgId] = {cnt,parts,got,seen}
    c.seenComplete = {}          -- seenComplete[sender][msgId] = expiry; drops duplicate whole messages

    -- In-game self-wiring: catch CHAT_MSG_ADDON (3.3.5a args: prefix, message, channel, sender) for
    -- our prefix and drive the pacer drain + reassembly-buffer eviction off OnUpdate. Guarded by
    -- CreateFrame so out-of-game harnesses (no CreateFrame) instead feed OnReceive and call Tick
    -- directly. OnReceive itself filters by prefix, so catching all addon traffic is fine.
    if CreateFrame then
        local fr = CreateFrame("Frame")
        c._frame = fr
        local acc = 0
        fr:RegisterEvent("CHAT_MSG_ADDON")
        fr:SetScript("OnEvent", function(_, _event, prefix2, text, channel, sender)
            c:OnReceive(prefix2, text, channel, sender)
        end)
        fr:SetScript("OnUpdate", function(_, dt)
            acc = acc + (dt or 0)
            if acc >= 0.1 then acc = 0; c:Tick() end
        end)
    end
    return c
end

function Channel:_log(ev, data)
    if self.opts.log then self.opts.log(ev, data) end
end

-- enqueue a value; frames go out as the pacer allows (immediately if tokens are free)
function Channel:Send(value, distribution, target, prio)
    local id = self._nextId
    self._nextId = (self._nextId + 1) % (B62_MAX2 + 1)
    local frames, err = WeirdComm.EncodeFrames(value, id, self.framePayload, self.compressMin)
    if not frames then
        self:_log("encode-fail", { err = err })
        return false, err
    end
    local q = (prio == "ALERT") and self._hi or self._lo
    for _, f in ipairs(frames) do
        q[#q + 1] = { text = f, dist = distribution, target = target }
    end
    self:_log("queue", { frames = #frames, prio = prio or "BULK", dist = distribution })
    self:_pump(self.getTime())
    return true
end

-- refill the token bucket and drain queued frames (ALERT before BULK) while tokens allow.
function Channel:_pump(now)
    now = now or self.getTime()
    local dt = now - (self._lastPump or now)
    if dt < 0 then dt = 0 end                       -- clock went backwards: don't refund
    self._lastPump = now
    self._tokens = math.min(self.burst, self._tokens + dt * self.rate)
    local isec = math.floor(now)
    while self._tokens >= 1 do
        local frame = table.remove(self._hi, 1) or table.remove(self._lo, 1)
        if not frame then break end
        self._tokens = self._tokens - 1
        self.opts.send(self.prefix, frame.text, frame.dist, frame.target)
        self:_log("send", { bytes = #self.prefix + #frame.text, dist = frame.dist })

        -- mute-risk canary: count our own sends per integer-second (the same window the server uses)
        -- and warn ONCE per second if we near the limit. The pacer caps us well below muteWarn, so a
        -- warning means a pacing bug or another path bypassing us -- a real signal, not routine noise.
        if isec ~= self._sendSec then self._sendSec, self._sendCount = isec, 0 end
        self._sendCount = self._sendCount + 1
        if self._sendCount >= self.muteWarn and self._warnedSec ~= isec then
            self._warnedSec = isec
            self:_log("mute-risk", { sent = self._sendCount, limit = MUTE_LIMIT })
            if self.opts.warn then self.opts.warn(self._sendCount) end
        end
    end
end

-- current second's send count (for /wl debug status); cheap read of the canary counter.
function Channel:SendRate()
    return (math.floor(self.getTime()) == self._sendSec) and self._sendCount or 0
end

-- periodic tick: drive the pacer and evict stale partial reassemblies. Call from OnUpdate.
function Channel:Tick(now)
    now = now or self.getTime()
    self:_pump(now)
    for sender, byId in pairs(self.rx) do
        for id, buf in pairs(byId) do
            if now - buf.seen > self.partialTimeout then
                byId[id] = nil
                self:_log("evict-partial", { sender = sender, id = id, got = buf.got, cnt = buf.cnt })
            end
        end
        if next(byId) == nil then self.rx[sender] = nil end
    end
    for sender, byId in pairs(self.seenComplete) do
        for id, expiry in pairs(byId) do
            if now > expiry then byId[id] = nil end
        end
        if next(byId) == nil then self.seenComplete[sender] = nil end
    end
end

-- send everything queued right now, ignoring the pacer (logout/teardown, or tests).
function Channel:Flush()
    for _, q in ipairs({ self._hi, self._lo }) do
        while #q > 0 do
            local frame = table.remove(q, 1)
            self.opts.send(self.prefix, frame.text, frame.dist, frame.target)
        end
    end
end

-- feed a raw inbound addon message. Ignores foreign prefixes and (if selfName set) our own
-- echo. On the final chunk of a message, decodes and calls onMessage(value,sender,dist).
function Channel:OnReceive(prefix, text, distribution, sender)
    if prefix ~= self.prefix then return end
    if self.opts.selfName and sender == self.opts.selfName then return end
    if type(text) ~= "string" or #text < HEADER_LEN then
        self:_log("recv-bad", { reason = "short", sender = sender }); return
    end
    local id = fromB62(string.sub(text, 1, 2))
    local idx = fromB62(string.sub(text, 3, 4))
    local cnt = fromB62(string.sub(text, 5, 6))
    if not id or not idx or not cnt or idx < 1 or cnt < 1 or idx > cnt then
        self:_log("recv-bad", { reason = "header", sender = sender }); return
    end

    local now = self.getTime()

    -- single-frame fast path: no buffering
    if cnt == 1 then
        return self:_complete(id, { text }, sender, distribution, now)
    end

    self.rx[sender] = self.rx[sender] or {}
    local buf = self.rx[sender][id]
    if not buf or buf.cnt ~= cnt then
        buf = { cnt = cnt, parts = {}, got = 0, seen = now }
        self.rx[sender][id] = buf
    end
    if buf.parts[idx] == nil then          -- ignore duplicate chunk within an in-flight reassembly
        buf.parts[idx] = text
        buf.got = buf.got + 1
    end
    if buf.got == cnt then
        self.rx[sender][id] = nil
        if next(self.rx[sender]) == nil then self.rx[sender] = nil end
        local frames = {}
        for i = 1, cnt do frames[i] = buf.parts[i] end
        return self:_complete(id, frames, sender, distribution, now)
    end
end

-- a fully-assembled message: drop it if this (sender,msgId) already completed recently
-- (a duplicated whole message, e.g. a server RAID echo), otherwise decode and deliver.
function Channel:_complete(id, frames, sender, distribution, now)
    local s = self.seenComplete[sender]
    if s and s[id] and now <= s[id] then
        self:_log("recv-dup", { sender = sender, id = id }); return
    end
    self.seenComplete[sender] = self.seenComplete[sender] or {}
    self.seenComplete[sender][id] = now + self.partialTimeout
    return self:_deliver(frames, sender, distribution)
end

function Channel:_deliver(frames, sender, distribution)
    local ok, value = WeirdComm.DecodeFrames(frames)
    if not ok then
        self:_log("recv-decode-fail", { sender = sender, err = value })
        return
    end
    -- Symmetric with the per-frame "send" log in _pump: record every fully-reassembled inbound
    -- message so the trace shows what actually ARRIVED (tag/sender/size), not only what a higher layer
    -- chose to act on. This is the single fact that distinguishes a dead inbound (no recv records at
    -- all) from traffic that arrived and was then ignored upstream.
    local bytes = 0
    for i = 1, #frames do bytes = bytes + #frames[i] end
    self:_log("recv", { tag = (type(value) == "table" and value[1]) or nil, sender = sender, dist = distribution, bytes = bytes })
    if self.opts.onMessage then self.opts.onMessage(value, sender, distribution) end
end

-- expose for tests/benchmarks
WeirdComm.WIRE_MAX = WIRE_MAX
WeirdComm.HEADER_LEN = HEADER_LEN

return WeirdComm
