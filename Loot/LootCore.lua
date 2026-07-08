-- LootCore: the single owner of loot identity, group-roll responses, top-N resolution, and
-- per-copy disposition. The loot model has exactly ONE owner behind a small API so no other system
-- holds its own representation or identity scheme: Session/LiveRoll/Comm/Resolver are consumers that
-- read or command the truth through that one door. Multiple representations with disagreeing identity
-- are what produce accounting bugs (stale rolls, cross-drop bleed, won-copy-blocks-new); a single
-- owner makes that drift structurally impossible.
--
-- PURE: no frames, no SendCommMessage, no GetContainerItemInfo, no roster. Winner-picking is
-- delegated through an injected resolver. The core can be verified with a plain Lua interpreter
-- (see RunSelfChecks). Consumers feed it counts and read its projections by stable id. That
-- boundary is the whole point.
--
-- IDENTITY is the numeric ITEM ID, never the link or name. Item links embed a localized name and
-- client-specific data, so the same item can present different links/names across clients (and
-- random-suffix variants collapse to one lot). The caller parses the itemId out of the bag link
-- and feeds counts keyed by itemId; the core stores only itemId. Consumers render name/link/icon
-- on demand (GetItemInfo); sync carries itemId so every client renders its own localized name.
--
-- DATA MODEL. A Lot is the rollable unit -- one per itemId group, holding a single group-level
-- response set under a stable id. ONE roll per item, top-N winners (a player wins at most one);
-- on Resolve the resolver's ordered winners freeze onto per-copy AWARDS that each track their own
-- delivery fate.
--   Lot = { id="L:<seq>" (unique, NEVER reused), itemId, state, count,
--           responses={ [playerKey]=tier },            -- one group roll
--           awards=nil-until-resolve then array[count] of
--                  { winner=playerKey|nil, state=owed|resolved|delivered|removed, recipient, deliveredAt },
--           record }                                    -- resolver's full result, for UI/log
--
-- LOT STATE MACHINE: new -> idle -> pending -> rolling -> resolved, with skipped as a snooze that
-- resurfaces on the next surface pass. Cancel sends rolling -> pending; Unlock sends resolved ->
-- idle (drops awards + responses, to re-roll).
--   new      fresh loot this session; auto-surfaced to the ML
--   idle     present but not fresh (session-start / late-eligible); listed, not auto-surfaced
--   pending  a Start Roll / Skip popup is up
--   rolling  broadcast to the raid, collecting responses
--   resolved roll finished (winner or all-pass); enters per-copy disposition below
--   skipped  ML dismissed; resurfaces next pass (a snooze, not a decision)
--
-- PER-COPY DISPOSITION (award.state): where a copy actually went. The bag scan can see a copy
-- vanish but never which one or where, so physical fate is a RECORDED transition, never inferred.
--   owed      won by a non-ML player, awaiting delivery; still in the ledger and the ML's bags
--   resolved  self-win or no-winner: the ML already holds it
--   delivered TERMINAL: TradeDeliver completed the trade and reported it (the "where it went" audit)
--   removed   TERMINAL: left the bags with NO delivery reported (vendored/banked/mailed/etc.)
-- delivered/removed are the only true terminals; a resolved lot stays as the session loot log.
--
-- RECONCILIATION (bag reality -> ledger, ML only). Each pass takes eligible counts (itemId ->
-- tradeable count, from the bag scanner) and the fresh set (itemIds that just increased). For each
-- itemId: want>live mints (want-live) copies (state new if fresh else idle); want<live retires
-- (live-want) copies OUT of the live set, choosing the LEAST-committed first and NEVER a rolling
-- (or, with a trade open, an owed) copy -- order resolved-no-winner > owed(last). A retired copy is
-- delivered (if a report arrived) or removed (otherwise). Terminal copies stay as the loot log.
--
-- RESOLUTION delegates winner-picking to the injected resolver (Resolver.lua: bracket -> named ->
-- spec -> status -> roll, top-N by count). The core's only job is to hand the resolver exactly one
-- lot's responses by stable id, then freeze the ordered winners onto per-copy awards (surplus
-- copies get winner=nil, state resolved). Routing every resolve through ledger[id] is the
-- stale-roll fix expressed at the model layer.
--
-- INVARIANTS (the rules that prevent the bugs):
--   1. id is the only identity; no code matches loot by link.
--   2. ids are never reused.
--   3. a live copy's rolls live with the copy; on resolve they freeze onto the record.
--   4. resolved ends the roll; skipped resurfaces; delivered/removed are the only true terminals.
--   5. the ML owns the live ledger and runs all mutation; raiders hold a read-only mirror.
--   6. identity is on the eligible count, not on UI/comm/popup timing.
--   7. physical fate is a recorded transition (MarkDelivered or removed), never inferred from a drop.
--
-- INTERACTION (every consumer goes through this one door, by id):
--   Session (ML) feeds bag counts in via Reconcile and rebuilds the loot projection (addon.lootView)
--     on ledgerChanged; persists/restores the ledger via SaveTo/LoadFrom.
--   LiveRoll drives Surface/Skip/StartRoll/Cancel/SetResponse/Resolve and reacts to lotAdded/
--     ledgerChanged to show/close popups.
--   Comm serializes out (ML) / ApplyRemote in (raider mirror); owns the wire, the core owns the shape.
--   Payout/TradeDeliver listen to lotResolved (Owe) / lotUnlocked (Forgive) / awardRemoved
--     (Forgive), and report delivery back via MarkDeliveredFor -- the one back-channel into the core.
--   UI reads List/Resolved/State/Get and refreshes on ledgerChanged.
-- Events: lotAdded, lotResolved, lotDelivered, lotUnlocked, awardRemoved, ledgerChanged.

local addonName, addon = ...
if type(addon) ~= "table" then addon = WeirdLoot or {} end

local LootCore = {}

-- Lot states. A lot is "open" (can still absorb new copies / be surfaced) while in
-- new/idle/pending/skipped; rolling and resolved are committed.
local STATE = {
    NEW      = "new",      -- fresh loot this session; auto-surfaced to the ML
    IDLE     = "idle",     -- present but not fresh (or unlocked); listed, not auto-surfaced
    PENDING  = "pending",  -- a Start Roll / Skip popup is up
    ROLLING  = "rolling",  -- broadcast to the raid, collecting responses
    RESOLVED = "resolved", -- rolled; awards frozen (each award then disposes independently)
    SKIPPED  = "skipped",  -- ML dismissed; resurfaces next pass (a snooze, not a decision)
}
-- Per-copy award (disposition) states, set at resolve and after.
local AWARD = {
    OWED      = "owed",      -- won by a non-ML player, awaiting delivery
    RESOLVED  = "resolved",  -- self-win or no-winner: ML already holds this copy
    DELIVERED = "delivered", -- terminal: traded to recipient, recorded
    REMOVED   = "removed",   -- terminal: left bags with no delivery reported
}
LootCore.STATE = STATE
LootCore.AWARD = AWARD

local function isOpen(lot)
    return not lot.removed and (lot.state == STATE.NEW or lot.state == STATE.IDLE
        or lot.state == STATE.PENDING or lot.state == STATE.SKIPPED)
end

local function awardIsLive(a)
    return a.state == AWARD.OWED or a.state == AWARD.RESOLVED
end

-- How many physical copies of this lot are live. With a mlKey, count ONLY copies whose holder is
-- that ML: a held/owed award physically sits in the holder's bags, so after a loot-master handoff the
-- previous ML's copies must not count toward the NEW ML's bag reconcile (otherwise a fresh drop of the
-- same item is masked by the inherited copy and never surfaces). A nil holder (lot minted before
-- holders were tracked) or a nil mlKey counts as before, so display/unlock paths are unaffected.
local function liveCount(lot, mlKey)
    if lot.removed then return 0 end
    if lot.awards then
        local n = 0
        for i = 1, #lot.awards do
            local a = lot.awards[i]
            if awardIsLive(a) and (a.holder == nil or mlKey == nil or a.holder == mlKey) then n = n + 1 end
        end
        return n
    end
    return lot.count or 0
end

local function lotLive(lot)
    return not lot.removed and liveCount(lot) > 0
end

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepcopy(v) end
    return out
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function LootCore.New()
    local self = setmetatable({}, { __index = LootCore })
    self.lots = {}       -- id -> Lot (the authoritative map)
    self.order = {}      -- array of lot ids in mint order (drives List/Log ordering)
    self.seq = 0         -- monotonic; lot ids come from here and are NEVER reused
    self.handlers = {}   -- event name -> array of callbacks
    self._resolver = nil -- injected: function(lot) -> { winners = {orderedKeys}, ... }
    self._mlKey = nil    -- normalized key of the master looter
    self.dirty = {}      -- set of lot ids changed since the last DrainDirty (drives delta sync)
    return self
end

-- Mark a lot id changed so the ML can broadcast just the delta instead of the whole ledger.
function LootCore:markDirty(id) if id then self.dirty[id] = true end end

-- Return the changed ids since the last call and clear the set. Order follows mint order so
-- a delta applies in the same sequence the ML produced it.
function LootCore:DrainDirty()
    local ids = {}
    for i = 1, #self.order do
        if self.dirty[self.order[i]] then ids[#ids + 1] = self.order[i] end
    end
    self.dirty = {}
    return ids
end

-- wipe the ledger (new/cleared session). Keeps wiring (resolver/ML) intact.
function LootCore:Reset()
    -- A reset wipes the ledger and restarts lot ids at L:1 (e.g. Start Session over an
    -- existing one). Log it as a segment boundary so the trace checker knows ids legitimately
    -- restart here and does not read the reused ids as duplicates.
    self:log("reset")
    self.lots = {}
    self.order = {}
    self.dirty = {}
    self.seq = 0
    self:emit("ledgerChanged")
end

-- wiring set by consumers (kept out of the core's logic so it stays pure)
local function normName(s)
    if type(s) ~= "string" then return s end
    return string.lower((string.gsub(s, "^%s*(.-)%s*$", "%1")))
end
function LootCore:SetResolver(fn) self._resolver = fn end
-- Optional structured-trace sink. Default nil -> log() is a no-op, so the pure core and
-- the out-of-game test harness are unaffected. Debug.lua wires this in-game to persist a
-- machine-checkable trace of every command and transition (see tests/checklog.lua).
function LootCore:SetLogger(fn) self._log = fn end
-- Every lot transition routes through log() with the lot's id, so this is also where we queue
-- the lot for delta sync. Runs regardless of whether a trace sink is attached.
function LootCore:log(ev, data)
    if data and data.id then self:markDirty(data.id) end
    if self._log then self._log(ev, data) end
end
function LootCore:SetML(playerKey) self._mlKey = normName(playerKey) end
function LootCore:IsML(playerKey) return self._mlKey ~= nil and normName(playerKey) == self._mlKey end

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
function LootCore:On(event, handler)
    local list = self.handlers[event]
    if not list then list = {}; self.handlers[event] = list end
    list[#list + 1] = handler
end

function LootCore:emit(event, ...)
    local list = self.handlers[event]
    if not list then return end
    for i = 1, #list do list[i](...) end
end

-- ---------------------------------------------------------------------------
-- internal helpers (everything keyed by numeric itemId)
-- ---------------------------------------------------------------------------
local function readEligible(entry)
    -- an eligible entry is either a bare count or { count = N }.
    if type(entry) == "number" then return entry end
    if type(entry) == "table" then return entry.count or 0 end
    return 0
end

function LootCore:lotsForItem(itemId)
    local out = {}
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.itemId == itemId then out[#out + 1] = lot end
    end
    return out
end

function LootCore:openLotForItem(itemId)
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.itemId == itemId and isOpen(lot) then return lot end
    end
    return nil
end

-- Reconcile compares this against the CURRENT ML's bag scan, so it counts only copies this ML holds
-- (holder-aware): an inherited copy held by a previous ML is not in our bags and must not mask a drop.
function LootCore:liveCountForItem(itemId)
    local total = 0
    local lots = self:lotsForItem(itemId)
    for i = 1, #lots do total = total + liveCount(lots[i], self._mlKey) end
    return total
end

function LootCore:mint(itemId, count, fresh)
    self.seq = self.seq + 1
    local lot = {
        id = "L:" .. self.seq,
        itemId = itemId, -- the ONLY identity; name/link rendered on demand from this
        state = fresh and STATE.NEW or STATE.IDLE,
        count = count,
        responses = {},
        awards = nil,
        record = nil,
    }
    self.lots[lot.id] = lot
    self.order[#self.order + 1] = lot.id
    self:log("mint", { id = lot.id, itemId = itemId, count = count, fresh = fresh and true or false, state = lot.state })
    self:emit("lotAdded", lot)
    return lot
end

-- ---------------------------------------------------------------------------
-- reconciliation: bag reality -> ledger  [ML only]
--   eligible    : itemId -> count (or itemId -> { count = N })
--   freshLinks  : set of itemIds that just increased this bag delta (itemId -> true)
--   protectOwed : a trade is open, so do NOT retire OWED awards (the bag decrease is the
--                 trade in progress; the trade-complete callback records it delivered)
-- ---------------------------------------------------------------------------
function LootCore:Reconcile(eligible, freshLinks, protectOwed)
    eligible = eligible or {}
    freshLinks = freshLinks or {}
    local changed = false

    for itemId, entry in pairs(eligible) do
        if self:reconcileItem(itemId, readEligible(entry), freshLinks[itemId] and true or false, protectOwed) then
            changed = true
        end
    end

    -- items present in the ledger but no longer eligible at all -> drain to zero
    local seen = {}
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lotLive(lot) and not seen[lot.itemId] then
            seen[lot.itemId] = true
            if eligible[lot.itemId] == nil then
                if self:reconcileItem(lot.itemId, 0, false, protectOwed) then changed = true end
            end
        end
    end

    if changed then self:emit("ledgerChanged") end
end

function LootCore:reconcileItem(itemId, want, fresh, protectOwed)
    local live = self:liveCountForItem(itemId)
    if want == live then return false end

    if want > live then
        local diff = want - live
        local open = self:openLotForItem(itemId)
        if open and not open.awards then
            open.count = open.count + diff
            if fresh and open.state == STATE.SKIPPED then open.state = STATE.NEW end
            self:log("grow", { id = open.id, itemId = itemId, by = diff, count = open.count, state = open.state })
        else
            self:mint(itemId, diff, fresh)
        end
        return true
    end

    -- want < live: copies left the bags. Retire least-committed first, never a rolling lot.
    -- Returns whether anything was actually retired (protectOwed can leave owed copies in place).
    return self:retireFromItem(itemId, live - want, protectOwed) > 0
end

-- Retire `n` live copies for an itemId, least-committed first:
--   open-lot copies (idle/new/skipped/pending) > resolved no-winner awards > owed awards.
-- A rolling lot is mid-decision and is never touched. With protectOwed, OWED awards are also
-- left alone (a trade is open). Returns the number of copies actually retired.
function LootCore:retireFromItem(itemId, n, protectOwed)
    local remaining = n
    local retired = 0
    self:log("retire", { itemId = itemId, n = n })

    -- 1. shrink the open lot's pre-roll count
    local open = self:openLotForItem(itemId)
    if open and not open.awards and remaining > 0 then
        local take = math.min(remaining, open.count)
        open.count = open.count - take
        remaining = remaining - take
        retired = retired + take
        if open.count <= 0 then open.removed = true end
        self:log("shrink", { id = open.id, itemId = itemId, take = take, count = open.count, removed = open.removed and true or false })
    end

    -- 2. retire awards from resolved lots: no-winner (ML's own) before owed
    if remaining > 0 then
        local live = {}
        local lots = self:lotsForItem(itemId)
        for _, lot in ipairs(lots) do
            if lot.awards then
                for _, a in ipairs(lot.awards) do
                    -- protectOwed: while a trade is open, an owed copy leaving bags is the trade
                    -- itself; leave it owed so the trade-complete callback can mark it delivered.
                    if awardIsLive(a) and not (protectOwed and a.state == AWARD.OWED) then
                        live[#live + 1] = { a = a, id = lot.id }
                    end
                end
            end
        end
        table.sort(live, function(x, y)
            local rx = x.a.state == AWARD.RESOLVED and 1 or 2
            local ry = y.a.state == AWARD.RESOLVED and 1 or 2
            return rx < ry
        end)
        for i = 1, remaining do
            local entry = live[i]
            if not entry then break end
            local prev = entry.a.state
            entry.a.state = AWARD.REMOVED -- left bags, disposition unknown
            retired = retired + 1
            self:log("remove", { id = entry.id, itemId = itemId, winner = entry.a.winner, from = prev })
            -- An OWED copy that left the bags is no longer deliverable; tell consumers (payout) so
            -- their owe ledger does not drift from the core's accounting.
            if prev == AWARD.OWED and entry.a.winner then
                self:emit("awardRemoved", itemId, entry.a.winner, entry.id)
            end
        end
    end

    return retired
end

-- ---------------------------------------------------------------------------
-- lifecycle commands (ML)
-- ---------------------------------------------------------------------------
function LootCore:Surface(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.NEW or lot.state == STATE.IDLE or lot.state == STATE.SKIPPED then
        local from = lot.state
        lot.state = STATE.PENDING
        self:log("surface", { id = id, from = from, to = STATE.PENDING })
        self:emit("ledgerChanged")
        return true
    end
    return false
end

function LootCore:Skip(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.PENDING then
        lot.state = STATE.SKIPPED
        self:log("skip", { id = id, to = STATE.SKIPPED })
        self:emit("ledgerChanged")
        return true
    end
    return false
end

function LootCore:StartRoll(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.PENDING then
        -- Pre-roll loot-tab picks already on the lot carry INTO the roll (the resolver sees
        -- them). Responses are not cleared here: identity (a fresh lot per re-drop) and Unlock
        -- (which clears on re-roll) are what prevent stale responses, not clearing at start.
        lot.state = STATE.ROLLING
        self:log("startRoll", { id = id, to = STATE.ROLLING })
        self:emit("ledgerChanged")
        return true
    end
    return false
end

function LootCore:Cancel(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.ROLLING then
        lot.state = STATE.PENDING
        self:log("cancel", { id = id, to = STATE.PENDING })
        self:emit("ledgerChanged")
        return true
    end
    return false
end

-- Record one player's response (opaque value; in the addon a tier string). Allowed on any
-- non-resolved lot so the loot tab can pre-seed responses before a live roll begins.
function LootCore:SetResponse(id, player, value)
    local lot = self.lots[id]
    if not lot then
        self:log("response", { id = id, player = player, value = value, ok = false, reason = "nolot" })
        return false
    end
    if lot.state == STATE.RESOLVED or lot.removed then
        self:log("response", { id = id, player = player, value = value, ok = false, reason = "closed", state = lot.state })
        return false
    end
    lot.responses[player] = value
    self:log("response", { id = id, player = player, value = value, ok = true, state = lot.state })
    return true
end

function LootCore:GetResponse(id, player)
    local lot = self.lots[id]; if not lot then return nil end
    return lot.responses[player]
end

-- Resolve delegates winner-picking to the injected resolver, handing it exactly THIS lot's
-- responses by stable id. The resolver returns an ORDERED winners list (top-N already applied
-- to the lot's count). The core freezes those onto per-copy awards.
function LootCore:Resolve(id)
    local lot = self.lots[id]; if not lot then return nil end
    local record = self._resolver and self._resolver(lot) or {}
    local winners = record.winners
    if not winners and record.winner then winners = { record.winner } end
    winners = winners or {}

    lot.record = record
    record.resolvedAt = time()   -- second-granularity resolution stamp; drives the Results default sort
    lot.awards = {}
    for i = 1, lot.count do
        local w = winners[i]
        -- holder = the player physically custodying this copy, recorded by name (the resolving ML), so
        -- the disposition survives a loot-master handoff: "self-win" stops meaning "whoever is ML now"
        -- and becomes "this named player has it". owed = won by someone other than the holder.
        local award = { winner = w or nil, holder = self._mlKey }
        if w and not self:IsML(w) then
            award.state = AWARD.OWED
        else
            award.state = AWARD.RESOLVED -- self-win or no winner: the holder (ML) already has this copy
        end
        lot.awards[i] = award
    end
    lot.state = STATE.RESOLVED
    local awardSnap = {}
    for i, a in ipairs(lot.awards) do awardSnap[i] = { state = a.state, winner = a.winner } end
    self:log("resolve", { id = id, itemId = lot.itemId, count = lot.count, awards = awardSnap })
    self:emit("lotResolved", lot)
    self:emit("ledgerChanged")
    return record
end

-- resolved -> idle, dropping awards/responses so the lot can be re-rolled.
function LootCore:Unlock(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state ~= STATE.RESOLVED then return false end
    -- capture prior winners so consumers (payout) can retract owes before the awards vanish
    local priorWinners = {}
    for _, a in ipairs(lot.awards or {}) do
        if a.winner then priorWinners[#priorWinners + 1] = a.winner end
    end
    self:log("unlock", { id = id, itemId = lot.itemId, priorWinners = priorWinners })
    local live = liveCount(lot)
    lot.state = STATE.IDLE
    lot.count = live > 0 and live or lot.count
    lot.awards = nil
    lot.responses = {}
    lot.record = nil
    self:emit("lotUnlocked", lot, priorWinners)
    self:emit("ledgerChanged")
    return true
end

function LootCore:UnlockAll()
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.state == STATE.RESOLVED then self:Unlock(lot.id) end
    end
end

-- Mark one owed award delivered. Low-level: by lot id + award index.
function LootCore:MarkDelivered(id, awardIndex, recipient, when)
    local lot = self.lots[id]; if not lot or not lot.awards then return false end
    local a = lot.awards[awardIndex]
    if not a or a.state ~= AWARD.OWED then return false end
    a.state = AWARD.DELIVERED
    a.recipient = recipient or a.winner
    a.deliveredAt = when
    self:log("deliver", { id = id, itemId = lot.itemId, recipient = a.recipient, awardIndex = awardIndex })
    self:emit("lotDelivered", lot, a)
    self:emit("ledgerChanged")
    return true
end

-- The path TradeDeliver uses: a trade to `player` for `itemId` completed. Marks the oldest
-- matching owed award delivered (FIFO over that player's owed copies of the item).
function LootCore:MarkDeliveredFor(player, itemId, when)
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.awards and (itemId == nil or lot.itemId == itemId) then
            for idx = 1, #lot.awards do
                local a = lot.awards[idx]
                if a.state == AWARD.OWED and a.winner == player then
                    return self:MarkDelivered(lot.id, idx, player, when)
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------
function LootCore:Get(id) return self.lots[id] end
function LootCore:State(id) local l = self.lots[id]; return l and l.state or nil end
function LootCore:IsResolved(id) local l = self.lots[id]; return l ~= nil and l.state == STATE.RESOLVED end
function LootCore:LiveCount(id) local l = self.lots[id]; return l and liveCount(l) or 0 end

-- How many copies this player has WON but not yet received (state OWED). Drives the "you are owed
-- loot" minimap indicator; works on a raider's mirrored ledger since per-copy winner/state ride the wire.
function LootCore:OwedCountFor(player)
    if not player then return 0 end
    local n = 0
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.awards then
            for idx = 1, #lot.awards do
                local a = lot.awards[idx]
                if a.state == AWARD.OWED and a.winner == player then
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- The distinct items this player is owed, aggregated as { {itemId=, count=}, ... } in lot order.
-- Used to list owed loot in the minimap tooltip; the link/name is rendered locally from itemId.
function LootCore:OwedItemsFor(player)
    if not player then return {} end
    local out, index = {}, {}
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.awards then
            for idx = 1, #lot.awards do
                local a = lot.awards[idx]
                if a.state == AWARD.OWED and a.winner == player then
                    local id = lot.itemId
                    if index[id] then
                        out[index[id]].count = out[index[id]].count + 1
                    else
                        out[#out + 1] = { itemId = id, count = 1 }
                        index[id] = #out
                    end
                end
            end
        end
    end
    return out
end

function LootCore:List() -- live lots, mint order (the loot-tab projection)
    local out = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l and lotLive(l) then out[#out + 1] = l end
    end
    return out
end

function LootCore:Resolved() -- lots that have been rolled (the results-tab projection)
    local out = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l and l.state == STATE.RESOLVED then out[#out + 1] = l end
    end
    return out
end

function LootCore:Log() return self:Resolved() end -- session loot history (awards carry disposition)

function LootCore:All() -- every lot in mint order (for the snapshot wire)
    local out = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l then out[#out + 1] = l end
    end
    return out
end

-- Lots queued to be rolled: surfaced, pending, or snoozed (new/pending/skipped). Deliberately EXCLUDES
-- idle: idle is background bag content that is listed but never auto-surfaced -- loot baselined at
-- session start, or a copy re-derived from the bag scan on reload (e.g. an item the raid already rolled
-- and passed on, still sitting in the ML's bags) -- which is not a roll the raid still owes. Also
-- excludes rolling (here now) and resolved (done). Mint order. Feeds the "N more to roll" hint (which
-- then applies the viewer's own roll filters on top).
function LootCore:QueuedLots()
    local out = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l and not l.removed and (l.state == STATE.NEW or l.state == STATE.PENDING or l.state == STATE.SKIPPED) then
            out[#out + 1] = l
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- sync (core owns the snapshot shape; Comm owns the wire)
-- ---------------------------------------------------------------------------
function LootCore:Serialize()
    local lots = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l then lots[#lots + 1] = deepcopy(l) end
    end
    return { seq = self.seq, lots = lots }
end

function LootCore:ApplyRemote(snapshot)
    self.lots = {}
    self.order = {}
    self.dirty = {}
    self.seq = snapshot and snapshot.seq or 0
    if snapshot and snapshot.lots then
        for i = 1, #snapshot.lots do
            local l = deepcopy(snapshot.lots[i])
            self.lots[l.id] = l
            self.order[#self.order + 1] = l.id
        end
    end
    self:emit("ledgerChanged")
end

-- Persistence: the core owns its on-disk shape under a `lootCore` key inside a host-provided db
-- table (the session). The host just hands the core where to live; the snapshot format stays
-- internal. SaveTo refreshes the snapshot; LoadFrom restores it and returns whether a ledger was
-- actually present (so the host knows the award history was preserved across the reload).
function LootCore:SaveTo(db)
    if not db then return end
    db.lootCore = self:Serialize()
end

function LootCore:LoadFrom(db)
    if not db or not db.lootCore then return false end
    self:ApplyRemote(db.lootCore)
    return true
end

-- Apply one lot from a delta (raider mirror). Upserts by id, preserving mint order, and
-- advances seq. Does not go through log()/markDirty -- inbound state is never re-broadcast.
function LootCore:ApplyRemoteLot(lotData, seq)
    if not lotData or not lotData.id then return end
    if not self.lots[lotData.id] then
        self.order[#self.order + 1] = lotData.id
    end
    self.lots[lotData.id] = deepcopy(lotData)
    if seq and seq > (self.seq or 0) then self.seq = seq end
    self:emit("ledgerChanged")
end

-- ---------------------------------------------------------------------------
-- self-checks: exercise the core's identity/lifecycle/reconcile/resolve invariants with a plain
-- interpreter (luajit, 5.1 semantics). Run from the addon dir with:
--   luajit -e "local f=loadfile('Loot/LootCore.lua'); f('WeirdLoot', {}); WeirdLoot.LootCore.RunSelfChecks(true)"
-- Item ids below are arbitrary numbers standing in for parsed link itemIds.
-- ---------------------------------------------------------------------------
function LootCore.RunSelfChecks(verbose)
    local pass, fail = 0, 0
    local function ok(cond, label)
        if cond then pass = pass + 1; if verbose then print("  PASS " .. label) end
        else fail = fail + 1; print("  FAIL " .. label) end
    end
    -- fake resolver: active (non-pass) responses ranked by their numeric .roll, top `count` win.
    local function topN(lot)
        local ranked = {}
        for player, v in pairs(lot.responses) do
            if type(v) == "table" and v.tier ~= "pass" then ranked[#ranked + 1] = { player = player, roll = v.roll or 0 } end
        end
        table.sort(ranked, function(a, b) return a.roll > b.roll end)
        local winners = {}
        for i = 1, math.min(lot.count, #ranked) do winners[i] = ranked[i].player end
        return { winners = winners }
    end
    local function resp(t, r) return { tier = t, roll = r } end

    -- 1. mint: preexisting -> idle, fresh -> new
    do
        local c = LootCore.New()
        c:Reconcile({ [101] = 1 }, {})
        c:Reconcile({ [101] = 1, [102] = 1 }, { [102] = true })
        ok(c:openLotForItem(101).state == STATE.IDLE, "mint preexisting -> idle")
        ok(c:openLotForItem(102).state == STATE.NEW, "mint fresh -> new")
    end

    -- 2. a second copy before any roll GROWS the open lot (not a new lot)
    do
        local c = LootCore.New()
        c:Reconcile({ [200] = 1 }, { [200] = true })
        c:Reconcile({ [200] = 2 }, { [200] = true })
        ok(#c:lotsForItem(200) == 1, "pre-roll duplicate grows existing lot")
        ok(c:openLotForItem(200).count == 2, "open lot count == 2")
    end

    -- 3. a duplicate dropping AFTER the lot resolved mints a NEW lot (fresh id + responses)
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [300] = 1 }, { [300] = true })
        local first = c:openLotForItem(300)
        c:Surface(first.id); c:StartRoll(first.id)
        c:SetResponse(first.id, "ML", resp("ms", 50))
        c:Resolve(first.id)
        ok(c:State(first.id) == STATE.RESOLVED, "first lot resolved")
        c:Reconcile({ [300] = 2 }, { [300] = true }) -- one already-held + one fresh
        ok(#c:lotsForItem(300) == 2, "post-resolve duplicate mints a NEW lot")
        local newLot = c:openLotForItem(300)
        ok(newLot and newLot.id ~= first.id and newLot.state == STATE.NEW, "new lot is fresh with its own id")
        ok(next(newLot.responses) == nil, "new lot has empty responses (no bleed)")
    end

    -- 4. pre-roll loot-tab responses carry INTO the roll (StartRoll does not clear them)
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [400] = 1 }, { [400] = true })
        local id = c:openLotForItem(400).id
        c:SetResponse(id, "Bob", resp("ms", 10)) -- pre-roll loot-tab response
        c:Surface(id); c:StartRoll(id)
        ok(c:Get(id).responses["Bob"] ~= nil, "pre-roll response carries into the roll")
    end

    -- 5. top-N resolve: 2 copies, 3 rollers -> top 2 win one each, 3rd gets nothing
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [500] = 2 }, { [500] = true })
        local id = c:openLotForItem(500).id
        ok(c:Get(id).count == 2, "lot count 2")
        c:Surface(id); c:StartRoll(id)
        c:SetResponse(id, "Bob", resp("ms", 90))
        c:SetResponse(id, "Amy", resp("ms", 70))
        c:SetResponse(id, "Cy", resp("ms", 30))
        c:Resolve(id)
        local lot = c:Get(id)
        ok(#lot.awards == 2, "two awards for a 2x lot")
        ok(lot.awards[1].winner == "Bob" and lot.awards[2].winner == "Amy", "top 2 distinct rollers win")
        ok(lot.awards[1].state == AWARD.OWED and lot.awards[2].state == AWARD.OWED, "non-ML wins are owed")
    end

    -- 6. fewer rollers than copies: surplus copies resolve with no winner (ML keeps them)
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [600] = 2 }, { [600] = true })
        local id = c:openLotForItem(600).id
        c:Surface(id); c:StartRoll(id)
        c:SetResponse(id, "Bob", resp("ms", 90))
        c:Resolve(id)
        local lot = c:Get(id)
        ok(lot.awards[1].winner == "Bob" and lot.awards[1].state == AWARD.OWED, "the roller wins one copy (owed)")
        ok(lot.awards[2].winner == nil and lot.awards[2].state == AWARD.RESOLVED, "surplus copy has no winner, ML holds it")
    end

    -- 7. self-win stays resolved; non-ML win delivers via FIFO helper; both in the log
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [700] = 1 }, { [700] = true })
        local id = c:openLotForItem(700).id
        c:Surface(id); c:StartRoll(id); c:SetResponse(id, "ML", resp("ms", 80)); c:Resolve(id)
        ok(c:Get(id).awards[1].state == AWARD.RESOLVED, "self-win stays resolved (ML holds it)")
        c:Reconcile({ [701] = 1 }, { [701] = true })
        local eid = c:openLotForItem(701).id
        c:Surface(eid); c:StartRoll(eid); c:SetResponse(eid, "Bob", resp("ms", 80)); c:Resolve(eid)
        ok(c:MarkDeliveredFor("Bob", 701), "MarkDeliveredFor marks the owed copy delivered")
        ok(c:Get(eid).awards[1].state == AWARD.DELIVERED, "award is delivered")
        ok(#c:Log() == 2, "both rolled lots appear in the log")
    end

    -- 8. reconcile retire: drop a copy -> least-committed first, rolling never touched
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [800] = 1, [801] = 1 }, { [800] = true, [801] = true })
        local fid = c:openLotForItem(800).id
        c:Surface(fid); c:StartRoll(fid)         -- 800 is rolling (protected)
        c:Reconcile({ [800] = 1 }, {})           -- 801 gone entirely
        ok(c:State(fid) == STATE.ROLLING, "rolling lot survives reconcile")
        ok(not lotLive(c:openLotForItem(801) or {}), "the un-rolled (new) lot was retired")
    end

    -- 9. ids never reused after retire + re-drop
    do
        local c = LootCore.New()
        c:Reconcile({ [900] = 1 }, { [900] = true })
        local id1 = c:openLotForItem(900).id
        c:Reconcile({}, {})                       -- 900 gone -> retired
        ok(not lotLive(c:Get(id1)), "vanished un-rolled lot retired")
        c:Reconcile({ [900] = 1 }, { [900] = true })
        local id2 = c:openLotForItem(900).id
        ok(id1 ~= id2, "re-dropped lot gets a brand new id (no reuse)")
    end

    -- 10. serialize / applyRemote round-trip mirrors state exactly
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [1000] = 2 }, { [1000] = true })
        local id = c:openLotForItem(1000).id
        c:Surface(id); c:StartRoll(id)
        c:SetResponse(id, "Bob", resp("ms", 90)); c:SetResponse(id, "Amy", resp("ms", 50))
        c:Resolve(id)
        local mirror = LootCore.New()
        mirror:ApplyRemote(c:Serialize())
        ok(mirror.seq == c.seq, "seq mirrored")
        ok(mirror:State(id) == STATE.RESOLVED, "state mirrored")
        ok(mirror:Get(id).awards[1].winner == "Bob", "award winner mirrored")
        ok(mirror:Get(id).itemId == 1000, "itemId mirrored")
        ok(#mirror:List() == #c:List(), "live list count mirrored")
    end

    -- 11. unlock retracts a resolved lot back to idle for a re-roll
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [1100] = 1 }, { [1100] = true })
        local id = c:openLotForItem(1100).id
        c:Surface(id); c:StartRoll(id); c:SetResponse(id, "Bob", resp("ms", 60)); c:Resolve(id)
        ok(c:State(id) == STATE.RESOLVED, "resolved before unlock")
        c:Unlock(id)
        ok(c:State(id) == STATE.IDLE and c:Get(id).awards == nil, "unlock -> idle, awards cleared")
        ok(next(c:Get(id).responses) == nil, "unlock clears responses")
    end

    print(string.format("LootCore self-checks: %d passed, %d failed", pass, fail))
    return fail == 0
end

-- register the live instance on the addon namespace
addon.lootCore = LootCore.New()
addon.LootCore = LootCore -- the prototype/factory, for tests and New()
if not WeirdLoot then WeirdLoot = addon end
WeirdLoot.lootCore = addon.lootCore
WeirdLoot.LootCore = LootCore

return LootCore
