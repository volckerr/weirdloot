local addon = WeirdLoot
local util = addon.util

local ROLL_DURATION = 30        -- seconds raiders have to roll before it auto-resolves (default; user may override via Options tab)

-- Declared at file scope (not in the popup section below) so our early core-driven restore
-- path (RestoreRollPopup) can honor the configured duration without a forward-reference.
local function getOptions()
    addon.db = addon.db or {}
    addon.db.options = addon.db.options or {}
    return addon.db.options
end

local function getRollDuration()
    local v = tonumber(getOptions().rollDuration)
    if v and v > 0 then return v end
    return ROLL_DURATION
end

-- Where the roll-popup hover tooltips (result breakdown + rolling list) dock relative to the
-- popup. Configurable in Options because "right of the popup" can land off-screen or over other
-- UI depending on where the user parks the popup stack. Returns the SetPoint tuple (tooltip
-- corner, popup corner, x, y); CURSOR returns nil to signal ANCHOR_CURSOR. Method (not local) so
-- the mapping is unit-testable without a live GameTooltip.
function addon:RollTooltipAnchorPoints(mode)
    mode = mode or getOptions().rollResultTooltipAnchor or "RIGHT"
    if mode == "CURSOR" then return nil end
    if mode == "LEFT"   then return "TOPRIGHT", "TOPLEFT",     -2,  0 end
    if mode == "TOP"    then return "BOTTOMLEFT", "TOPLEFT",    0,  2 end
    if mode == "BOTTOM" then return "TOPLEFT", "BOTTOMLEFT",    0, -2 end
    return "TOPLEFT", "TOPRIGHT", 2, 0   -- RIGHT (default): dock snug to the popup's right edge
end

local function anchorRollTooltip(f)
    local point, relPoint, x, y = addon:RollTooltipAnchorPoints()
    if not point then
        GameTooltip:SetOwner(f, "ANCHOR_CURSOR")
        return
    end
    GameTooltip:SetOwner(f, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint(point, f, relPoint, x, y)
end

-- Live pick-list throttle (ML side). A recorded pick marks its rolling lot dirty; this ticker
-- flushes at most one RSTATE broadcast per lot per period, so a storm of picks collapses to one
-- message per second instead of one per pick. It self-arms on the first dirty mark and self-hides
-- once everything is flushed (a hidden frame fires no OnUpdate), so it costs nothing when idle.
local ROLL_STATE_PERIOD = 1.0
local rollStateTicker = CreateFrame("Frame")
rollStateTicker:Hide()
rollStateTicker.elapsed = 0
rollStateTicker:SetScript("OnUpdate", function(frame, dt)
    frame.elapsed = frame.elapsed + (dt or 0)
    if frame.elapsed < ROLL_STATE_PERIOD then return end
    frame.elapsed = 0
    addon:FlushRollState()
end)

function addon:MarkRollStateDirty(lotId)
    if not self:IsAuthorizedLootMaster() then return end
    self._rollStateDirty = self._rollStateDirty or {}
    self._rollStateDirty[lotId] = true
    rollStateTicker.elapsed = 0
    rollStateTicker:Show()
end

-- Broadcast the live pick list for every dirty lot that is still rolling, then clear and disarm.
-- A lot that resolved before the flush is skipped (no stale send). Re-armed by the next pick.
function addon:FlushRollState()
    local core = self.lootCore
    local dirty = self._rollStateDirty
    if not core or not dirty or not next(dirty) then rollStateTicker:Hide(); return end
    for lotId in pairs(dirty) do
        dirty[lotId] = nil
        local lot = core:Get(lotId)
        if lot and lot.state == core.STATE.ROLLING then
            self:BroadcastRollState(lotId, lot)
        end
    end
    rollStateTicker:Hide()
end

-- Live rolling system, coexisting with the batch flow.
--
-- Flow: a newly-collected item surfaces a *pending* popup to the loot master only
-- (Start Roll / Skip); nothing goes to the raid yet. When the ML presses Start Roll
-- (or right-clicks a loot row) -> DROP broadcast -> every raider gets an interest popup
-- with the priority brackets (BiS / MS / MU / OS / TM / Pass) -> RSP back to the ML ->
-- ML ends the roll -> the picks are already in session.responses, so it resolves through
-- the SAME engine as the batch flow (ResolveSessionItem: bracket -> named -> spec ->
-- status -> roll) -> WIN broadcast -> registrants get a result popup. The win goes through
-- the shared result/lock path and the winner is queued for payout.
--
-- The ML never receives its own addon messages (CHAT_MSG_ADDON ignores self), so the
-- ML drives its own popups locally and members react to DROP/WIN over comms.

function addon:InitializeLiveRoll()
    self.live = self.live or { rolls = {}, seq = 0, pool = {}, active = {} }
    self.live.rolls = self.live.rolls or {}
    self.live.seq = self.live.seq or 0
    self.live.pool = self.live.pool or {}
    self.live.active = self.live.active or {}

    if not self.live.anchor then
        local popupPos = self.db and self.db.ui and self.db.ui.liveRollPopups or nil
        local point = (popupPos and popupPos.point) or "TOP"
        local relativePoint = (popupPos and popupPos.relativePoint) or "TOP"
        local x = (popupPos and popupPos.x) or 260
        local y = (popupPos and popupPos.y) or -170
        -- Pure invisible positioning reference for the popup stack. It is intentionally NOT
        -- mouse-interactive: an always-shown EnableMouse frame would capture clicks over its
        -- rect even when no popups are visible. Dragging is driven by the popups, which call
        -- anchor:StartMoving() (that only needs SetMovable, not EnableMouse) and persist the
        -- position on their own OnDragStop.
        local anchor = CreateFrame("Frame", nil, UIParent)
        anchor:SetWidth(340)
        anchor:SetHeight(94)
        anchor:SetFrameStrata("DIALOG")
        anchor:SetMovable(true)
        anchor:SetClampedToScreen(true)
        anchor:SetPoint(point, UIParent, relativePoint, x, y)
        self.live.anchor = anchor
    end

    -- The core drives surfacing now: every ledger change reconciles the on-screen pending popups
    -- against the core, surfacing fresh loot and closing popups for lots that have moved on.
    if self.lootCore and not self._liveRollWired then
        self._liveRollWired = true
        self.lootCore:On("ledgerChanged", function() self:SyncPendingPopups(); self:SyncRollPopups() end)
    end

    -- Build the whitelist/blacklist name sets now that self.db is wired; thereafter they are rebuilt
    -- only on edit (SetItemFilterText), not re-parsed on every popup.
    self:RefreshItemFilters()
end

-- Stable-reorder a list of lot ids into three roll-out tiers, keeping the original (mint) order
-- within each tier: the explicit non-equipment list (bags/mounts) first, then any other non-gear
-- (tokens, consumables, etc. -- this groups tier tokens together), then equipment. Used by every
-- roll-start path so the quick non-gear rolls clear first, in the popups and the loot menu alike.
function addon:OrderLotIdsNonEquipFirst(ids)
    local decorated = {}
    for i, id in ipairs(ids) do
        local lot = self.lootCore:Get(id)
        local itemId = lot and lot.itemId
        local rank
        if itemId and util:IsKnownNonEquipment(itemId) then
            rank = 0        -- explicit list: roll out first
        elseif itemId and util:LacksEquipSlot(itemId) then
            rank = 1        -- general non-equipment: next (groups tier tokens)
        else
            rank = 2        -- equipment: last
        end
        decorated[i] = { id = id, idx = i, rank = rank }
    end
    table.sort(decorated, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.idx < b.idx                                      -- stable within each tier
    end)
    local out = {}
    for i, d in ipairs(decorated) do out[i] = d.id end
    return out
end

-- Reconcile pending popups against the core on any ledger change: surface fresh loot to PENDING,
-- show a popup for every live PENDING lot that lacks one, and close popups for lots that have left.
function addon:SyncPendingPopups()
    if not self:IsAuthorizedLootMaster() then return end
    -- Auto-start drives a whole debounced loot batch in one pass. Each StartLiveRoll mutates the
    -- ledger, and core:emit fires ledgerChanged synchronously, re-entering this function. Left
    -- unguarded the re-entry drains the rest of the batch depth-first BEFORE the current item's
    -- DROP is sent, so raiders receive the batch reversed. The flag makes those nested calls a
    -- no-op so the single outer loop dispatches the batch front-to-back in OrderLotIdsNonEquipFirst
    -- order (non-equipment first), matching what the ML rolls out.
    if self._autoStarting then return end
    local core = self.lootCore

    -- Surface fresh loot here, state-driven, NOT off a one-shot mint event. A re-dropped copy that
    -- GROWS an existing skipped/idle lot flips it back to NEW with no mint, so an event-only surface
    -- would miss it and the popup would never reappear for loot seen before. autoRoll off => the ML
    -- drives rolls from the loot tab, so do not auto-surface. SKIPPED/IDLE are deliberately left:
    -- Skip must stick until a real new drop re-freshens the lot (-> NEW), and IDLE is the not-fresh
    -- state. mint always rides a Reconcile -> ledgerChanged, so freshly minted lots land here too.
    -- Three mutually-exclusive auto modes for fresh (NEW) loot. Default (all off) leaves NEW lots
    -- in the loot tab so the ML drives every roll manually from there.
    --   autoRoll       -> Surface only (NEW -> PENDING). Opens the Start/Skip pending popup.
    --   autoStartRoll  -> StartLiveRoll (NEW -> ROLLING). Broadcasts the DROP immediately, no popup gate.
    --   autoSkipRoll   -> Surface + Skip (NEW -> SKIPPED). No popup; revisit from the loot tab later.
    local opt = (self.db and self.db.options) or {}
    local optAutoStart = opt.autoStartRoll
    local optAutoSkip = opt.autoSkipRoll
    if optAutoStart and not optAutoSkip then
        -- Collect the whole NEW batch first, order it, then hand it to the shared batch
        -- infrastructure (same one Start Rolls uses) so the Start-Rolls batch size caps how many
        -- rolls fire in parallel: e.g. 7 fresh lots with batchSize=5 -> 5 broadcast immediately,
        -- the remaining 2 dispatched as the current batch drains via NotifyRollBatchFinished ->
        -- AdvanceRollBatch. The _autoStarting guard neutralizes the ledgerChanged re-entry each
        -- StartLiveRoll causes, so the enqueue+drain happens before another re-entry hits.
        local toStart = {}
        for _, lot in ipairs(core:List()) do
            if lot.state == core.STATE.NEW then toStart[#toStart + 1] = lot.id end
        end
        toStart = self:OrderLotIdsNonEquipFirst(toStart)   -- non-equipment (bags/mounts) rolls first
        -- pcall so an EnqueueAutoStartLots error cannot leave _autoStarting latched true, which
        -- would silently disable every future auto-start until /reload. Re-raise so the error
        -- still shows.
        self._autoStarting = true
        local ok, err = pcall(function() self:EnqueueAutoStartLots(toStart) end)
        self._autoStarting = false
        if not ok then error(err, 0) end
    elseif self.db and self.db.autoRoll and not optAutoSkip then
        for _, lot in ipairs(core:List()) do
            if lot.state == core.STATE.NEW then core:Surface(lot.id) end
        end
    elseif optAutoSkip then
        for _, lot in ipairs(core:List()) do
            if lot.state == core.STATE.NEW then
                core:Surface(lot.id)
                core:Skip(lot.id)
            end
        end
    end

    local livePending = {}
    local toShow = {}
    for _, lot in ipairs(core:List()) do
        if lot.state == core.STATE.PENDING then
            livePending[lot.id] = true
            if not self:HasOpenPendingForLot(lot.id) then toShow[#toShow + 1] = lot.id end
        end
    end
    -- non-equipment (bags/mounts) gets its pending popup first so the ML starts those rolls first
    for _, lotId in ipairs(self:OrderLotIdsNonEquipFirst(toShow)) do
        local lot = core:Get(lotId)
        if lot then self:ShowPendingPopup(lot) end
    end

    -- Close any pending popup whose lot is no longer a live PENDING: rolled, skipped, or its copies
    -- all left the bags. A removed lot keeps state == PENDING (only the `removed` flag clears), so a
    -- state check alone would leave a dead popup up; List() already excludes non-live lots.
    for i = #self.live.active, 1, -1 do
        local f = self.live.active[i]
        if f.mode == "pending" and f.lotId and not livePending[f.lotId] then
            self:ClosePendingFrame(f)
        end
    end
end

-- Raider-side restore: the roll popup is normally created by the transient DROP message, which a
-- reloading raider misses. Reconcile against the core: show a roll popup for every ROLLING lot we
-- have no open roll for (rebuilt from the synced lot + the ML's remaining time), and close roll
-- popups whose lot has left ROLLING (resolved/cancelled/gone). The ML drives its own roll popups
-- via StartLiveRoll, so this is raider-only.
function addon:SyncRollPopups()
    if self:IsAuthorizedLootMaster() then return end
    local core = self.lootCore
    -- RESTORE ONLY. A raider's roll popup is opened by the DROP message and closed by the CANCEL or WIN
    -- message -- it is message-driven, never polled from ledger state. The ledger mirror legitimately
    -- passes through transient states during sync convergence: a freshly synced lot reads NEW/PENDING
    -- for an instant before its ROLLING delta lands, and a snapshot built pre-roll but delivered late
    -- (a reloading raider's resync answered from an early rev) shows the lots as NEW until the trailing
    -- deltas catch up. Polling those transients to close live popups made them vanish mid-roll and then
    -- re-open at a reset full-duration timer. So we no longer close here at all -- CANCEL (OnCancelMessage)
    -- and WIN (OnWinMessage) own the close. The restore side stays: a raider that missed the DROP (relog)
    -- gets a popup for any lot the ledger says is ROLLING and that has no open popup.
    -- Restore only a lot we have NO record of: a reloading raider lost self.live.rolls and must rebuild
    -- popups for whatever the ledger says is ROLLING. We must NOT restore a lot we already know about --
    -- in particular one whose WIN we already processed (roll.resolved = true). The ledger mirror can lag
    -- a resolve (the RESOLVED delta trails the WIN message, or a duplicate/coalesced lot stays ROLLING in
    -- the mirror a beat longer), so a "has a record and it is resolved" lot read as restorable would
    -- re-open a fresh roll popup AFTER the item was already awarded. A record that exists and is NOT
    -- resolved already has its popup open, so it is skipped here too.
    for _, lot in ipairs(core:List()) do
        if lot.state == core.STATE.ROLLING and not (self.live.rolls and self.live.rolls[lot.id]) then
            self:RestoreRollPopup(lot)
        end
    end
end

-- Reconstruct a roll record from a synced lot and re-show its popup. The remaining seconds the ML
-- stamped on the lot (stashed by Comm at decode) give an honest deadline; without one we fall back
-- to the full duration. Existing picks (from lot.responses) are reflected so the popup is accurate.
function addon:RestoreRollPopup(lot)
    local name, link, icon = util:ItemRender(lot.itemId)
    local remaining = (self._rollRemaining and self._rollRemaining[lot.id]) or getRollDuration()
    -- The ML's broadcast prio is not persisted on the synced lot, so a restore (relog, or the
    -- ROLLING delta racing ahead of the DROP) has no authoritative prio. Fall back to this client's
    -- own listed priority rather than "" -- an empty prio would wrongly gate BiS as "no priority".
    -- If the DROP then lands (the race), ShowRollBannerCard's dedupe re-assert corrects it to the
    -- ML's exact prio + availability.
    local prio = (name and self:GetLiveItemPrio({ name = name })) or ""
    local roll = {
        id = lot.id, itemId = lot.itemId, link = link,
        name = name or link or ("item:" .. tostring(lot.itemId)),
        icon = icon, prio = prio, owner = false, registrants = {}, resolved = false,
        quantity = lot.count or 1,
        duration = getRollDuration(),
        deadline = GetTime() + remaining,
    }
    for playerKey, tier in pairs(lot.responses or {}) do
        roll.registrants[util:NormalizeKey(playerKey)] = { name = playerKey, tier = tier }
    end
    self.live.rolls[lot.id] = roll
    self:ShowInterestPopup(roll)
end

function addon:HasOpenPendingForLot(lotId)
    for _, f in ipairs(self.live.active) do
        if f.mode == "pending" and f.lotId == lotId then return true end
    end
    return false
end

function addon:HasOpenRollForLot(lotId)
    local roll = self.live.rolls and self.live.rolls[lotId]
    return roll ~= nil and not roll.resolved
end

-- ---------------------------------------------------------------------------
-- popup frames (custom, stacking)
-- ---------------------------------------------------------------------------
local POPUP_W, POPUP_H = 340, 94
local POPUP_INTEREST_EMPTY_H = 64       -- floor height for a compact raider popup (one button row)
local POPUP_INTEREST_OWNER_H = 64       -- floor for the ML popup: End/Cancel live in the TOP-RIGHT corner, so the popup matches the raider's height
                                        -- the brackets, so the brackets push up; this keeps them clear
                                        -- of the item icon/name instead of overlapping (mis-clicks).
local RESPONSE_ORDER = { bis = 5, ms = 4, mu = 3, os = 2, tm = 1, pass = 0 }
-- Shown "Prio:" string for an item with no listed priority. BiS is omitted: a no-prio item cannot
-- roll BiS (see util:RollTierAvailability), so its default order starts at MS.
local DEFAULT_PRIO = "MS > MU > OS > TM"
addon.DEFAULT_PRIO = DEFAULT_PRIO   -- the banner roll cards show the same no-prio bracket order
-- Display labels for the rolling hover lists (live loot popup + loot tab row). The TM bracket
-- spells out "Tmog" here so the reader instantly knows what the roller wants, without conflating
-- it with the compact "TM" abbreviation used on the bracket buttons themselves.
local RESPONSE_LABELS = { bis = "BiS", ms = "MS", mu = "MU", os = "OS", tm = "Tmog", pass = "Pass" }
-- Hover text spelling out each roll-choice bracket abbreviation (shared with the loot tab).
local CHOICE_TOOLTIPS = addon.RESPONSE_TOOLTIPS
-- ROLL_DURATION / getOptions / getRollDuration are declared at the top of the file so the
-- core-driven restore path can reach them; the rest of the option helpers live here.
local function parseItemList(text)
    local set = {}
    if type(text) ~= "string" or text == "" then return set end
    for line in string.gmatch(text, "[^\r\n]+") do
        local trimmed = string.match(line, "^%s*(.-)%s*$") or ""
        if trimmed ~= "" then
            set[string.lower(trimmed)] = true
        end
    end
    return set
end

-- Cached parse of the whitelist/blacklist option text. parseItemList walks the whole string and
-- ShouldSuppressRollPopup runs on every popup, so the name sets are built once (RefreshItemFilters,
-- at init) and rebuilt only when a list is edited or a preset is loaded (SetItemFilterText), instead
-- of re-parsing on every check. Lazily builds on first read so a lookup before init still sees the
-- right set rather than nil.
local function itemFilterSet(self, kind)
    local filters = self.itemFilters
    if not filters then filters = {}; self.itemFilters = filters end
    if filters[kind] == nil then
        filters[kind] = parseItemList(getOptions()[kind .. "Text"])
    end
    return filters[kind]
end

-- Build both filter sets from the current option text. Called from InitializeLiveRoll (PLAYER_LOGIN,
-- after self.db is wired) so the sets are ready before the first popup.
function addon:RefreshItemFilters()
    local opt = getOptions()
    self.itemFilters = {
        whitelist = parseItemList(opt.whitelistText),
        blacklist = parseItemList(opt.blacklistText),
    }
end

-- Set one filter's option text (editor edit or preset load) and rebuild just that set, so the change
-- takes effect on the next popup without re-parsing every check. The SINGLE mutation path for the
-- list text, which is why the cache can never drift from opt[kind.."Text"].
function addon:SetItemFilterText(kind, text)
    text = text or ""
    getOptions()[kind .. "Text"] = text
    self.itemFilters = self.itemFilters or {}
    self.itemFilters[kind] = parseItemList(text)
end

-- Returns true if the (non-loot-master) popup should be suppressed for this item name.
-- Should a NON-ML raider's popup for this roll be hidden? (The ML always sees everything.) Covers the
-- whitelist/blacklist filters and the opt-in "hide rolls my class can't use" option (off by default).
function addon:ShouldSuppressRollPopup(roll)
    if self:IsAuthorizedLootMaster() then return false end
    local opt = getOptions()

    -- Opt-in: hide rolls for items this player's class can never equip, using the same equip-
    -- eligibility check as the roll self-block. Uncached items resolve as usable, so nothing is
    -- hidden while the item is still loading.
    if opt.hideUnusableRolls and roll and roll.itemId then
        local _, link = util:ItemRender(roll.itemId)
        if link and not util:IsItemUsableForPlayer(link) then
            return true
        end
    end

    local name = string.lower((roll and roll.name) or "")
    if name == "" then return false end

    if opt.whitelistEnabled then
        local set = itemFilterSet(self, "whitelist")
        if next(set) and not set[name] then
            return true
        end
    end
    if opt.blacklistEnabled then
        local set = itemFilterSet(self, "blacklist")
        if set[name] then
            return true
        end
    end
    return false
end
local popupBasePoint, savePopupBasePoint, layoutPopups

local function makeButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(18)
    b:SetText(text)
    return b
end

-- Attach a static hover tooltip to a button. Reusable for any button, not just roll choices.
local function setButtonTooltip(btn, text)
    if not btn or not text then return end
    btn:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function getPlayerDisplayName(self, playerKey)
    local attendee = self:GetAttendee(playerKey) or self:GetRosterProfile(playerKey)
    if attendee and attendee.name and attendee.name ~= "" then
        return attendee.name
    end
    return playerKey
end

local function getPlayerClassName(self, playerKey)
    local attendee = self:GetAttendee(playerKey) or self:GetRosterProfile(playerKey)
    if attendee and attendee.className and attendee.className ~= "" then
        return attendee.className
    end
    return ""
end

-- Order any roller list highest bracket first, then by name. Shared so the live registrant list
-- and the ledger-backed list come out in the same order on every surface.
local function rollerSort(left, right)
    local leftRank = RESPONSE_ORDER[left.tier] or 0
    local rightRank = RESPONSE_ORDER[right.tier] or 0
    if leftRank ~= rightRank then
        return leftRank > rightRank
    end
    return string.lower(left.name or "") < string.lower(right.name or "")
end

-- The live pick-list shows only who is in and their bracket. There is no live roll value: rolls are
-- not made as you go (a misclick would lock you into a wrong number), they are generated once when
-- the loot master resolves the lot. So entries carry no roll, and the list orders by bracket then name.
local function buildLiveRollEntries(self, roll)
    local entries = {}
    for playerKey, registrant in pairs(roll and roll.registrants or {}) do
        local tier = registrant.tier or "pass"
        if tier ~= "pass" then
            entries[#entries + 1] = {
                key = playerKey,
                name = registrant.name or getPlayerDisplayName(self, playerKey),
                className = registrant.className or getPlayerClassName(self, playerKey),
                tier = tier,
            }
        end
    end
    table.sort(entries, rollerSort)
    return entries
end

-- The one source for every "who is rolling" view: popup count + hover, loot-tab count + hover.
-- Returns normalized { name, className, tier } ordered by bracket then name. A raider trusts the
-- ML's live registrant push (RSTATE) while a roll is active, since its own ledger responses are
-- coalesced until resolve; the ML and any pre-roll read take the authoritative ledger, which
-- carries BOTH popup and loot-tab picks, so a prefired loot-tab pick counts before any registrant
-- exists. This is why a popup count that read only registrants showed "none" for prefired rolls.
function addon:ActiveRollers(lotId)
    if not lotId then return {} end
    local roll = self.live and self.live.rolls and self.live.rolls[lotId]
    if roll and not roll.resolved and not self:IsAuthorizedLootMaster() then
        return buildLiveRollEntries(self, roll)
    end
    local rollers = self:BuildRollerList(self.lootCore:Get(lotId)) or {}
    for _, r in ipairs(rollers) do r.tier = r.responseType end
    table.sort(rollers, rollerSort)
    return rollers
end

function addon:GetLiveRollEntriesForItem(item)
    if not item or not item.id then return nil end
    local roll = self:GetActiveLiveRollForItem(item)
    if not roll then return nil end
    return buildLiveRollEntries(self, roll)
end

function addon:GetResponseLabel(tier)
    return RESPONSE_LABELS[tier] or string.upper(tier or "")
end

local function ensureRollLinePool(f, count)
    f.rollLines = f.rollLines or {}
    while #f.rollLines < count do
        local line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetJustifyH("LEFT")
        line:SetWidth(POPUP_W - 20)
        if #f.rollLines == 0 then
            line:SetPoint("TOPLEFT", f.sub, "BOTTOMLEFT", 0, -6)
        else
            line:SetPoint("TOPLEFT", f.rollLines[#f.rollLines], "BOTTOMLEFT", 0, -2)
        end
        f.rollLines[#f.rollLines + 1] = line
    end
end

local function setPopupHeight(f, height)
    f:SetHeight(height)
end

local function getCompactPopupHeight(f)
    local nameHeight = math.ceil(f.name:GetStringHeight() or 0)
    local subHeight = math.ceil(f.sub:GetStringHeight() or 0)
    local floor = f.isOwner and POPUP_INTEREST_OWNER_H or POPUP_INTEREST_EMPTY_H
    return math.max(floor, 39 + nameHeight + subHeight)
end

local function showRollCountTooltip(self, f)
    local roll = f and f.roll
    if not f or not roll then
        return
    end

    anchorRollTooltip(f)
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Players Rolling", 1, 0.82, 0)

    local entries = self:ActiveRollers(roll.id)
    if #entries == 0 then
        GameTooltip:AddLine("No active rollers", 1, 1, 1)
    else
        for _, entry in ipairs(entries) do
            local nameText = util:IsSelfName(entry.name) and "You" or util:ColorPlayerName(entry.name, entry.className)
            local lineText = string.format("%s - %s", nameText, RESPONSE_LABELS[entry.tier] or string.upper(entry.tier or ""))
            GameTooltip:AddLine(util:ColorPlayerText(entry.name, entry.className, lineText), 1, 1, 1)
        end
    end

    GameTooltip:Show()
end

local function refreshPopupRollLines(self, roll)
    local f = roll and roll.popup
    if not f or f.mode ~= "interest" then
        return
    end

    if f.rollLines then
        for _, line in ipairs(f.rollLines) do
            line:SetText("")
            line:Hide()
        end
    end

    setPopupHeight(f, getCompactPopupHeight(f))
    layoutPopups(self)
end

-- roll-choice brackets, highest priority first: BiS > MS > MU > OS > TM (Pass
-- declines). Use the button's natural pressed visual to show the pick: the chosen button
-- locks in its down state; picking a different one pops the previous back up.
local function interestButtons(f)
    return { bis = f.bisBtn, ms = f.msBtn, mu = f.muBtn, os = f.osBtn, tm = f.tmBtn, pass = f.passBtn }
end
-- chosen button: bold (outlined) green label; others: normal gold label
local function styleButtonText(btn, chosen, disabled)
    local fs = btn:GetFontString()
    if not fs then return end
    local font, size = fs:GetFont()
    if disabled then
        fs:SetFont(font, size, "")
        fs:SetTextColor(0.5, 0.5, 0.5)
    elseif chosen then
        fs:SetFont(font, size, "OUTLINE")
        fs:SetTextColor(0.2, 1.0, 0.2)
    else
        fs:SetFont(font, size, "")
        fs:SetTextColor(1.0, 0.82, 0.0)
    end
end
local function resetInterestButtons(f)
    for _, btn in pairs(interestButtons(f)) do
        if btn then
            btn:SetButtonState("NORMAL")
            styleButtonText(btn, false, false)
        end
    end
end

local function isPlayerAllowedForRoll(self, roll, playerName)
    return self:IsPlayerAllowedForItem(roll and roll.itemId, (roll and roll.name) or "", playerName)
end

-- Hover text for a disabled bracket, by the reason util:RollTierAvailability returns.
local DISABLED_REASON_TEXT = {
    type = "Not used for this item type.",
    class = "Your class cannot use this item.",
    unique = "You already have this unique item.",
    quest = "You have already completed this quest.",
    noprio = "No priority is listed for this item.",
}

-- Banner roll cards label their bracket buttons BiS/MS/MU/OS/TM/Pass (compact "TM", unlike the
-- popup hover's spelled-out "Tmog"); these map tier keys to card labels and back.
local CARD_BRACKETS = { bis = "BiS", ms = "MS", mu = "MU", os = "OS", tm = "TM", pass = "Pass" }
local CARD_TIERS = {}
for tier, label in pairs(CARD_BRACKETS) do CARD_TIERS[label] = tier end

local function applyInterestButtonAvailability(self, f, roll)
    local playerName = util:GetPlayerName("player")
    local allowed = isPlayerAllowedForRoll(self, roll, playerName)
    local blockReason = self:RollSelfBlockReason(roll.itemId)
    -- ML authority: BiS availability follows the prio the ML broadcast (roll.prio), not this client's
    -- own list, so a raider with a different or stale prio table can't enable a BiS the ML did not
    -- grant. A no-prio item syncs as DEFAULT_PRIO; any other string means it has a listed priority.
    local hasPrio = roll.prio ~= nil and roll.prio ~= "" and roll.prio ~= DEFAULT_PRIO
    -- shared policy: a roll popup is always an open (never locked) lot
    local avail = util:RollTierAvailability(roll.itemId, allowed, false, blockReason, hasPrio)

    for key, btn in pairs(interestButtons(f)) do
        local reason = avail[key]
        local disabled = reason ~= nil
        if disabled then btn:Disable() else btn:Enable() end
        btn:SetAlpha(disabled and 0.45 or 1)
        styleButtonText(btn, false, disabled)
        -- A disabled bracket button is genuinely unclickable; explain why on hover so the player
        -- knows it is a restriction, not a bug. SetMotionScriptsWhileDisabled lets the OnEnter/OnLeave
        -- fire while the button is disabled. An enabled bracket instead spells out its abbreviation.
        -- Owned here (not at creation) so the two states never clobber each other.
        btn:SetMotionScriptsWhileDisabled(true)
        if disabled then
            -- The disabled hint always shows (it explains why the button is dead); only the
            -- bracket-name explanation honors the option toggle.
            local text = DISABLED_REASON_TEXT[reason] or ""
            btn:SetScript("OnEnter", function(b)
                GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                GameTooltip:SetText(text, 1, 0.3, 0.3, true)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        elseif not roll.owner then
            -- Every bracket dismisses the popup on a second click for a raider (the ML's never closes).
            -- The two-click dismiss is non-obvious, so this hint shows even with explanation tooltips off.
            -- Pass spells itself out; other brackets get their explanation only when those tips are on.
            local base = (key == "pass") and "Pass on this item."
                or (getOptions().explanationTooltipsEnabled and CHOICE_TOOLTIPS[key])
            setButtonTooltip(btn, (base and (base .. "\n") or "") .. "Click twice to dismiss the popup.")
        elseif getOptions().explanationTooltipsEnabled then
            setButtonTooltip(btn, CHOICE_TOOLTIPS[key])
        else
            btn:SetScript("OnEnter", nil)        -- clear a tooltip a prior open may have attached
            btn:SetScript("OnLeave", nil)
        end
    end
end

local function formatLootRuleEntry(entry)
    if not entry then
        return ""
    end
    if entry.isRest then
        return "Rest"
    end

    local colorCode = util:GetClassColorCode(entry.className) or "|cffffffff"
    local label = ""
    if entry.specName and entry.specName ~= "" then
        label = util:TitleCaseWords(entry.specName)
    elseif entry.className and entry.className ~= "" then
        label = util:TitleCaseWords(entry.className)
    else
        label = util:TitleCaseWords(entry.raw or "")
    end

    return colorCode .. label .. "|r"
end

local function formatLootRuleDisplay(rule)
    if not rule or not rule.tiers then
        return nil
    end

    local tiers = {}
    for _, tier in ipairs(rule.tiers) do
        local entries = {}
        for _, entry in ipairs(tier.entries or {}) do
            local formatted = formatLootRuleEntry(entry)
            if formatted ~= "" then
                entries[#entries + 1] = formatted
            end
        end
        if #entries > 0 then
            tiers[#tiers + 1] = table.concat(entries, " / ")
        end
    end

    if #tiers == 0 then
        return nil
    end

    return table.concat(tiers, " > ")
end

local function formatNamedRuleEntry(entry)
    if not entry then
        return ""
    end
    if entry.isLootCouncil then
        return "LC"
    end
    if entry.isRest then
        return "Rest"
    end

    local playerName = entry.raw or ""
    local profile = addon.GetRosterProfile and addon:GetRosterProfile(playerName) or nil
    local classColor = util:GetClassColorCode(profile and profile.className) or "|cffffffff"
    return classColor .. util:TitleCaseWords(playerName) .. "|r"
end

local function formatNamedRuleDisplay(rule)
    if not rule or not rule.tiers then
        return nil
    end

    local tiers = {}
    local hasLootCouncil = false
    for _, tier in ipairs(rule.tiers) do
        local entries = {}
        for _, entry in ipairs(tier.entries or {}) do
            if entry.isLootCouncil then
                hasLootCouncil = true
            end
            local formatted = formatNamedRuleEntry(entry)
            if formatted ~= "" and not entry.isLootCouncil then
                entries[#entries + 1] = formatted
            end
        end
        if #entries > 0 then
            tiers[#tiers + 1] = table.concat(entries, " / ")
        end
    end

    if hasLootCouncil then
        tiers[#tiers + 1] = "LC"
    end

    if #tiers == 0 then
        return nil
    end

    return table.concat(tiers, " > ")
end

local function highlightInterestButton(f, tier)
    for key, btn in pairs(interestButtons(f)) do
        if btn then
            local chosen = key == tier
            -- Lock the chosen button pushed; leave the rest in their normal (up) state. A bracket
            -- disabled by applyInterestButtonAvailability MUST keep its DISABLED state: SetButtonState
            -- ("NORMAL"/"PUSHED") resurrects it to a clickable state while the faded alpha stays, so it
            -- reads disabled but accepts a pick. Key off the button STATE, not IsEnabled() -- IsEnabled()
            -- returns truthy right after Disable() here, which is why the earlier guard did nothing.
            local isDisabled = btn:GetButtonState() == "DISABLED"
            if not isDisabled then
                btn:SetButtonState(chosen and "PUSHED" or "NORMAL", chosen)
            end
            styleButtonText(btn, chosen, isDisabled)
        end
    end
end

-- Reflect the local player's own pick on BOTH surfaces at once: the open roll popup and the loot
-- tab row. One path for both directions -- the popup buttons and a loot-tab pick (via
-- SetPlayerResponse) both route here -- so a choice made on either surface lights up the matching
-- button on the other, without waiting on the ledger (a raider's own pick is whispered to the ML
-- and is not in the local ledger until the snapshot returns). Pass is a real choice like any
-- bracket: it highlights the Pass button (it just carries no roll). nil clears the highlight.
function addon:ApplyLocalChoice(lotId, tier)
    local roll = self.live and self.live.rolls and self.live.rolls[lotId]
    if roll and not roll.resolved then
        roll.choice = tier
        if roll.popup then highlightInterestButton(roll.popup, roll.choice) end
        if self.SetRollBannerCardChoice then
            self:SetRollBannerCardChoice(lotId, tier and CARD_BRACKETS[tier] or nil)
        end
    end
    if self.MarkLocalLootChoice then self:MarkLocalLootChoice(lotId, tier) end
end

local function makePopup()
    local parent = (addon.live and addon.live.anchor) or UIParent
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(POPUP_W)
    f:SetHeight(POPUP_H)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetScript("OnDragStart", function()
        if addon.live and addon.live.anchor then
            addon.live.anchor:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function()
        if addon.live and addon.live.anchor then
            addon.live.anchor:StopMovingOrSizing()
            local point, _, relativePoint, x, y = addon.live.anchor:GetPoint()
            savePopupBasePoint(addon, point, relativePoint, x, y)
        end
    end)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetWidth(32)
    f.icon:SetHeight(32)
    f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)

    -- mouse-over the icon shows the item tooltip (same as the list UI). The link is set
    -- per popup via f.itemLink; the texture itself can't take mouse, so overlay a frame.
    f.iconHover = CreateFrame("Frame", nil, f)
    f.iconHover:SetAllPoints(f.icon)
    f.iconHover:EnableMouse(true)
    f.iconHover:SetScript("OnEnter", function(hover)
        if not f.itemLink or f.itemLink == "" then return end
        GameTooltip:SetOwner(hover, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(f.itemLink)
        GameTooltip:Show()
    end)
    f.iconHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 6, -1)
    f.name:SetWidth(POPUP_W - 56)
    f.name:SetJustifyH("LEFT")

    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -2)
    f.sub:SetWidth(POPUP_W - 56)
    f.sub:SetJustifyH("LEFT")

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -30)
    f.countHover = CreateFrame("Frame", nil, f)
    f.countHover:SetPoint("TOPLEFT", f.count, "TOPLEFT", -2, 2)
    f.countHover:SetPoint("BOTTOMRIGHT", f.count, "BOTTOMRIGHT", 2, -2)
    f.countHover:EnableMouse(true)
    f.countHover:SetScript("OnEnter", function() showRollCountTooltip(addon, f) end)
    f.countHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- choice brackets (bottom row): BiS > MS > MU > OS > TM > Pass. bisBtn anchors the row and the rest
    -- chain off it, so this one point places them all. (The ML End/Cancel controls live top-right.)
    f.bisBtn = makeButton(f, "BiS", 34)
    f.bisBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 10)
    f.msBtn = makeButton(f, "MS", 32)
    f.msBtn:SetPoint("LEFT", f.bisBtn, "RIGHT", 3, 0)
    f.muBtn = makeButton(f, "MU", 34)
    f.muBtn:SetPoint("LEFT", f.msBtn, "RIGHT", 3, 0)
    f.osBtn = makeButton(f, "OS", 32)
    f.osBtn:SetPoint("LEFT", f.muBtn, "RIGHT", 3, 0)
    f.tmBtn = makeButton(f, "TM", 32)
    f.tmBtn:SetPoint("LEFT", f.osBtn, "RIGHT", 3, 0)
    f.passBtn = makeButton(f, "Pass", 42)
    f.passBtn:SetPoint("LEFT", f.tmBtn, "RIGHT", 3, 0)
    -- The bracket hover tooltips are (re)attached per-open in applyInterestButtonAvailability,
    -- which owns each button's enabled/disabled state: an enabled bracket spells out its name, a
    -- disabled one explains the class restriction instead. Setting them here would be clobbered.

    -- Loot-master control row (compact): End/Start on the right, Cancel/Skip immediately to its
    -- left, both tucked into the popup's TOP-RIGHT corner so the bracket buttons can sit at the
    -- bottom of the frame (same layout as the raider's popup). OK is shown in result mode only and
    -- re-anchors to TOPRIGHT at show time.
    f.rollBtn = makeButton(f, "End", 40)
    f.rollBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    f.cancelBtn = makeButton(f, "Cancel", 46)
    f.cancelBtn:SetPoint("RIGHT", f.rollBtn, "LEFT", -4, 0)
    f.okBtn = makeButton(f, "OK", 60)
    f.okBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)

    -- countdown bar along the bottom edge; shrinks over the roll's duration
    f.timer = CreateFrame("StatusBar", nil, f)
    f.timer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 5, 4)
    f.timer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 4)
    f.timer:SetHeight(4)
    f.timer:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    f.timer:SetMinMaxValues(0, 1)
    f.timer:SetValue(1)

    f:Hide()
    return f
end

local function acquirePopup(self)
    local f = table.remove(self.live.pool)
    if not f then f = makePopup() end
    f.ownerAddon = self
    return f
end

popupBasePoint = function(self)
    if self.live and self.live.anchor then
        local point, _, relativePoint, x, y = self.live.anchor:GetPoint()
        return point or "TOP", relativePoint or point or "TOP", x or 260, y or -170
    end
    local ui = self.db and self.db.ui
    local pos = ui and ui.liveRollPopups
    return (pos and pos.point) or "TOP", (pos and pos.relativePoint) or (pos and pos.point) or "TOP", (pos and pos.x) or 260, (pos and pos.y) or -170
end

savePopupBasePoint = function(self, point, relativePoint, x, y)
    self.db.ui.liveRollPopups = self.db.ui.liveRollPopups or {}
    self.db.ui.liveRollPopups.point = point or "TOP"
    self.db.ui.liveRollPopups.relativePoint = relativePoint or point or "TOP"
    self.db.ui.liveRollPopups.x = x
    self.db.ui.liveRollPopups.y = y
end

-- Each popup keeps a fixed screen slot for its whole lifetime, so when one resolves or
-- its timer expires the others DON'T slide up to fill the gap (that shifting was
-- confusing). A closing popup frees its slot; the next new popup reuses the lowest free
-- one.
local POPUP_GAP = 3
layoutPopups = function(self)
    -- Stack by each popup's ACTUAL (compact) height in slot order, not a fixed POPUP_H pitch, so
    -- there is no dead space between the now-compact cards. Slot order keeps positions stable.
    local ordered = {}
    for _, f in ipairs(self.live.active) do ordered[#ordered + 1] = f end
    table.sort(ordered, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    local y = 0
    for _, f in ipairs(ordered) do
        f:ClearAllPoints()
        f:SetPoint("TOP", self.live.anchor or UIParent, "TOP", 0, y)
        y = y - ((f:GetHeight() or POPUP_H) + POPUP_GAP)
    end
end

local function addActivePopup(self, f, preferredSlot)
    -- Guard: a frame that is already in the active list (e.g. a pending popup transforming to
    -- interest in place) keeps its existing slot and is not double-appended.
    for _, existing in ipairs(self.live.active) do
        if existing == f then return end
    end
    local used = {}
    for _, other in ipairs(self.live.active) do
        if other.slot then used[other.slot] = true end
    end
    local slot = preferredSlot
    if slot == nil or used[slot] then       -- fall back to lowest free slot
        slot = 0
        while used[slot] do slot = slot + 1 end
    end
    f.slot = slot
    self.live.active[#self.live.active + 1] = f
end

local function removeActive(self, f)
    for i = #self.live.active, 1, -1 do
        if self.live.active[i] == f then table.remove(self.live.active, i) end
    end
    f.slot = nil
end

-- Close up the gaps: reassign slots 0..n-1 in current order and re-layout. Called only
-- when a popup is dismissed (OK / Pass / Skip / Cancel) -- the one case where shifting is
-- wanted. A timer expiring (interest -> result) keeps its slot and never triggers this.
local function compactPopups(self)
    local list = {}
    for _, f in ipairs(self.live.active) do list[#list + 1] = f end
    table.sort(list, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    for i, f in ipairs(list) do f.slot = i - 1 end
    layoutPopups(self)
end


local function closePopup(self, f)
    if not f then return end
    f:SetScript("OnUpdate", nil)        -- stop the countdown on a pooled frame
    resetInterestButtons(f)             -- clear any locked roll-choice highlight
    f:SetAlpha(1)                       -- clear any auto-close fade so a reused frame starts opaque
    f:Hide()
    removeActive(self, f)
    self.live.pool[#self.live.pool + 1] = f
    layoutPopups(self)
end

-- Late-bound method wrapper so the event handlers defined earlier (SyncPendingPopups) can
-- close a frame without a forward reference to the local closePopup.
function addon:ClosePendingFrame(f)
    closePopup(self, f)
    compactPopups(self)
end

local function formatRollItemLabel(link, name, quantity)
    local itemText = link ~= "" and link or name or "Item"
    if (quantity or 1) > 1 then
        itemText = string.format("%s x%d", itemText, quantity)
    end
    return itemText
end

-- ---------------------------------------------------------------------------
-- item-name resolution for popups
--
-- Popups render their label from the lot's itemId via util:ItemRender (GetItemInfo). On a
-- cache miss (an item the client has not cached yet -- always the case for raiders, who get
-- only the itemId over the wire, and often for the ML on a fresh drop) GetItemInfo returns
-- nil and the label freezes as "item:<id>". Unlike the Loot tab (rebuilt on every
-- ledgerChanged), a popup is built once, so without this it would never recover. We prime
-- the client cache and re-render on a ticker until the real name arrives.
-- ---------------------------------------------------------------------------

-- Force the client to fetch an item's data (3.3.5a has no GET_ITEM_INFO_RECEIVED event).
function addon:PrimeItemInfo(itemId)
    if not itemId then return end
    if not self._scanTip then
        self._scanTip = CreateFrame("GameTooltip", "WeirdLootScanTip", UIParent, "GameTooltipTemplate")
    end
    self._scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    self._scanTip:SetHyperlink("item:" .. tostring(itemId))
end

-- Is itemId a PURE Unique (carry-one) item? That is the only kind that blocks receiving a second; you
-- may hold many Unique-Equipped (only one EQUIPPED) and the counted Unique (%d) forms allow N. 3.3.5a
-- exposes none of this via GetItemInfo, so we scan the item tooltip for a BARE ITEM_UNIQUE line,
-- rejecting the -Equipped and counted variants.
local UNIQUE_LINE = ITEM_UNIQUE or "Unique"
local UNIQUE_EQUIP_LINE = ITEM_UNIQUE_EQUIPPABLE or "Unique-Equipped"
function addon:IsItemPureUnique(itemId)
    if not itemId then return false end
    if not self._scanTip then
        self._scanTip = CreateFrame("GameTooltip", "WeirdLootScanTip", UIParent, "GameTooltipTemplate")
    end
    self._scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    self._scanTip:ClearLines()
    self._scanTip:SetHyperlink("item:" .. tostring(itemId))
    for i = 2, self._scanTip:NumLines() do
        local fs = _G["WeirdLootScanTipTextLeft" .. i]
        local txt = fs and fs:GetText()
        if txt == UNIQUE_EQUIP_LINE then return false end   -- unique-equipped: not a carry-one limit
        if txt == UNIQUE_LINE then return true end          -- bare "Unique": carry-one
    end
    return false
end

-- Does the LOCAL player already physically hold itemId? Checks bag contents, equipped gear, the
-- equipped bags themselves (a Unique BAG like Dragon Hide Bag), AND the keyring (where quest-reward
-- keys live). Cannot see the bank.
function addon:PlayerHoldsItem(itemId)
    if not itemId then return false end
    local maxBag = NUM_BAG_SLOTS or 4
    for bag, slot in util:BagSlots() do                     -- bag contents (backpack 0 + bags 1..N)
        if GetContainerItemID(bag, slot) == itemId then return true end
    end
    for inv = 1, 19 do                                      -- equipped gear (head..tabard)
        if GetInventoryItemID("player", inv) == itemId then return true end
    end
    for bag = 1, maxBag do                                  -- the equipped bags themselves (Unique bags)
        local inv = ContainerIDToInventoryID and ContainerIDToInventoryID(bag)
        if inv and GetInventoryItemID("player", inv) == itemId then return true end
    end
    local keyring = KEYRING_CONTAINER or -2                 -- the keyring (quest-reward keys live here)
    local nKeys = (GetKeyRingSize and GetKeyRingSize()) or 0
    for slot = 1, nKeys do
        if GetContainerItemID(keyring, slot) == itemId then return true end
    end
    return false
end

-- Self-protection: you already hold a pure-Unique copy of itemId, so you can never receive another and
-- should not roll on it. Hold-check first (cheap, usually false -> skips the tooltip scan). Enforced
-- only on the rolling player's own client, like the class-token block: the ML can't see others' bags.
-- The ML is exempt: they always transiently hold the dropped copy during rolls (it sits in their bags
-- until handed out), so the hold-check would trip on the very item being rolled -- a false positive.
-- Other players only ever hold a copy that is genuinely theirs.
function addon:OwnsBlockingUnique(itemId)
    if self:IsAuthorizedLootMaster() then return false end
    return self:PlayerHoldsItem(itemId) and self:IsItemPureUnique(itemId)
end

-- Some drops start a one-time quest and are consumed doing so, so a held/unique check on the drop
-- itself can't tell you already did the quest. Instead we check for the quest's REWARD: if you hold it
-- you completed the quest and the drop is useless to you. Map: dropped itemId -> reward itemId. (Key
-- to the Focusing Iris: the dropped key 44569/44577 starts a quest whose reward is the permanent
-- keyring key 44582/44581.) Source: chromiecraft quest_template StartItem/RewardItem1.
addon.ROLL_REWARD_GATE = {
    [44569] = 44582,   -- Key to the Focusing Iris (normal)        -> reward keyring key 44582
    [44577] = 44581,   -- Heroic Key to the Focusing Iris (heroic) -> reward keyring key 44581
}

-- You already hold the quest reward this drop grants, so you finished the quest -> don't roll on it.
function addon:OwnsQuestReward(itemId)
    local reward = self.ROLL_REWARD_GATE[itemId]
    return reward ~= nil and self:PlayerHoldsItem(reward)
end

-- Combined self-block reason for rolling on itemId, or nil if you may roll. "quest" (you already did
-- the quest this drop starts) takes priority over "unique" (you already hold this pure-Unique item).
function addon:RollSelfBlockReason(itemId)
    if not itemId then return nil end
    if self:OwnsQuestReward(itemId) then return "quest" end
    if self:OwnsBlockingUnique(itemId) then return "unique" end
    -- Class equip-eligibility. IsItemUsableForPlayer matches GetItemInfo's localized subtype against
    -- English tables, i.e. it assumes an enUS client (ChromieCraft is enUS); item 31 tracks making the
    -- match locale-independent. Uncached items resolve as usable, so a still-loading item is never blocked.
    local _, link = util:ItemRender(itemId)
    if link and not util:IsItemUsableForPlayer(link) then return "class" end
    return nil
end

-- Re-render a popup's name/icon/link from its itemId. Returns true once the name resolves.
function addon:RefreshPopupItem(f)
    if not f or not f.itemId then return true end
    local name, link, icon = util:ItemRender(f.itemId)
    if not name then return false end
    f.itemLink = link
    f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.name:SetText(formatRollItemLabel(link, name, f.itemQuantity))
    if f.mode == "pending" then
        f.sub:SetText("|cffffffffPrio:|r " .. (self:GetLiveItemPrio({ name = name }) or DEFAULT_PRIO))
    end
    if f.roll then f.roll.name = name; f.roll.link = link; f.roll.icon = icon end
    return true
end

-- Drive a ~0.25s sweep over open popups, re-rendering any whose name has not resolved yet.
-- Self-stops when every popup has a real name, and re-arms when a new unresolved popup opens.
function addon:EnsureNameTicker()
    local anchor = self.live and self.live.anchor
    if not anchor or anchor.__nameTicker then return end
    anchor.__nameTicker = true
    anchor.__nameAccum = 0
    anchor:SetScript("OnUpdate", function(_, elapsed)
        anchor.__nameAccum = anchor.__nameAccum + (elapsed or 0)
        if anchor.__nameAccum < 0.25 then return end
        anchor.__nameAccum = 0
        local pending = 0
        for _, f in ipairs(self.live.active or {}) do
            if f.itemId and not f.itemResolved then
                if self:RefreshPopupItem(f) then
                    f.itemResolved = true
                else
                    pending = pending + 1
                end
            end
        end
        -- the loot list AND the results list share this resolve cycle: re-render both while any of
        -- their item names are still uncached (each re-warms and re-flags _lootNamesPending), then
        -- let it fall out once everything has resolved.
        if self._lootNamesPending then
            self._lootNamesPending = false
            if self.RefreshLootTab then self:RefreshLootTab() end
            if self.RefreshResultsTab then self:RefreshResultsTab() end
            if self._lootNamesPending then pending = pending + 1 end
        end
        -- banner roll cards created on a cold cache re-render in place once their item resolves
        -- (ItemRender always synthesizes a link; the NAME arriving is the resolve signal)
        for key, itemId in pairs(self._bannerNamesPending or {}) do
            local cardName, cardLink, cardIcon = util:ItemRender(itemId)
            if cardName then
                if self.RefreshRollBannerCard then self:RefreshRollBannerCard(key, cardLink, cardIcon) end
                self._bannerNamesPending[key] = nil
            else
                pending = pending + 1
            end
        end
        if pending == 0 then
            anchor:SetScript("OnUpdate", nil)
            anchor.__nameTicker = nil
        end
    end)
end

-- Record the itemId a popup is showing. If its name is not cached yet, prime the client and
-- start the resolve ticker; the creation-site render already shows the "item:<id>" fallback.
function addon:TrackPopupItem(f, itemId, quantity)
    f.itemId = itemId
    f.itemQuantity = quantity
    if itemId and util:ItemRender(itemId) then
        f.itemResolved = true
    else
        f.itemResolved = false
        self:PrimeItemInfo(itemId)
        self:EnsureNameTicker()
    end
end

-- Same cold-cache handling as the popups, but for the full loot list: prime every item whose
-- name is not cached yet (via the shared scan tooltip) and flag the shared resolve ticker so the
-- list re-renders once they arrive. Returns true while any name is still unresolved. Lives here
-- (not UI) so it reuses PrimeItemInfo directly and stays unit-testable.
function addon:WarmLootItemNames(items)
    self._lootNamesPending = false
    for _, it in ipairs(items or {}) do
        if it.itemId and not util:ItemRender(it.itemId) then
            self:PrimeItemInfo(it.itemId)
            self._lootNamesPending = true
        end
    end
    return self._lootNamesPending
end

-- ---------------------------------------------------------------------------
-- banner roll card: the drops banner is the roll surface; the interest popup below survives only
-- as the fallback when the banner can't take a card. The card applies the same policy as the
-- popup (bracket availability, prefired pick, honest deadline) and routes clicks back through the
-- same choice and ML paths. Roll cards are never capped (the ML decides how many rolls go out);
-- false falls back to the popup (roll already over, or a defensive banner refusal) so a roll is
-- never lost to the banner.
-- ---------------------------------------------------------------------------
function addon:ShowRollBannerCard(roll)
    if not self.AddRollBannerItem then return false end
    local remaining = (roll.deadline or (GetTime() + (roll.duration or ROLL_DURATION))) - GetTime()
    if remaining <= 0 then return false end

    -- ItemRender always synthesizes a link; a nil NAME is the cold-cache signal (as TrackPopupItem)
    local itemName, link, icon = util:ItemRender(roll.itemId)
    if not itemName then self:PrimeItemInfo(roll.itemId) end   -- cold cache: card shows item:id at first

    local playerName = util:GetPlayerName("player")
    local allowed = isPlayerAllowedForRoll(self, roll, playerName)
    local blockReason = self:RollSelfBlockReason(roll.itemId)
    -- same ML-authority rule as the popup: BiS follows the prio the ML broadcast, not local lists
    local hasPrio = roll.prio ~= nil and roll.prio ~= "" and roll.prio ~= DEFAULT_PRIO
    local avail = util:RollTierAvailability(roll.itemId, allowed, false, blockReason, hasPrio)
    local disabled = {}
    for tier, reason in pairs(avail) do
        local label = CARD_BRACKETS[tier]
        if label then disabled[label] = DISABLED_REASON_TEXT[reason] or true end
    end

    local mine = self:GetPlayerResponse(roll.id, playerName)
    roll.choice = mine
    roll.passed = (mine == "pass")   -- see ShowInterestPopup: default Pass counts for hideUnrolledWins

    -- Callbacks resolve the CURRENT roll object by id at click time, not the one captured now: a
    -- restore and the DROP can both build a roll for the same lot (sync delta lands first), and the
    -- banner keeps the first card (dedupe by key) while addon state moves to the newer object. The
    -- popup path rebinds its reused frame for the same reason.
    local rollId = roll.id
    local function liveRoll()
        return (self.live and self.live.rolls and self.live.rolls[rollId]) or roll
    end

    local item = {
        key = rollId,
        isOwner = roll.owner and true or nil,   -- the ML's card must never dismiss on repeat click
        link = link,   -- ItemRender synthesizes item:id when uncached; fallbackName covers the text
        fallbackName = roll.name,
        icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark",
        quantity = roll.quantity or 1,
        prio = (roll.prio and roll.prio ~= "") and roll.prio or nil,
        rollDuration = roll.duration or ROLL_DURATION,
        -- the card owns no clock: it asks per tick, and the answer tracks the CURRENT roll's
        -- deadline, so a restore-guessed deadline self-corrects the moment the DROP lands
        getTimeLeft = function()
            local r = liveRoll()
            if not r.deadline then return 0 end
            return r.deadline - GetTime()
        end,
        disabled = disabled,
        selected = mine and CARD_BRACKETS[mine] or nil,
        getRollers = function()
            local out = {}
            for _, e in ipairs(self:ActiveRollers(rollId)) do
                out[#out + 1] = { name = e.name, class = e.className, bracket = CARD_BRACKETS[e.tier] or e.tier }
            end
            return out
        end,
        onPick = function(label)
            local tier = CARD_TIERS[label]
            if tier then self:ChooseInterest(liveRoll(), tier) end
        end,
        onChosen = function(label)
            -- the card dismissed itself (repeat click): a real bracket keeps the interest already
            -- sent; Pass carries none, so dismissing it clears the local choice
            local r = liveRoll()
            if not r.owner and CARD_TIERS[label] == "pass" then r.choice = nil end
        end,
    }
    if roll.owner then
        item.onMLEnd = function() self:ResolveLiveRoll(rollId) end
        item.onMLCancel = function() self:CancelLiveRoll(rollId) end
        -- the popup's OnUpdate auto-resolves at the deadline; on a card that duty is onExpired
        item.onExpired = function() self:ResolveLiveRoll(rollId) end
    end
    local accepted = self:AddRollBannerItem(item) and true or false
    if accepted and not itemName then
        -- cold cache: the same resolve ticker the popups use re-renders the card in place once
        -- the item info arrives (the card went up with the bare item:id meanwhile)
        self._bannerNamesPending = self._bannerNamesPending or {}
        self._bannerNamesPending[rollId] = roll.itemId
        self:EnsureNameTicker()
    end
    return accepted
end

-- ---------------------------------------------------------------------------
-- interest popup
-- ---------------------------------------------------------------------------
function addon:ShowInterestPopup(roll, slot)
    if not roll.owner and self:ShouldSuppressRollPopup(roll) then
        return
    end
    if self:ShowRollBannerCard(roll) then
        -- the banner took the roll: drop any pending popup still holding this lot (the ML's
        -- Start Roll frame would otherwise linger) and skip the interest popup entirely
        for _, candidate in ipairs(self.live.active) do
            if candidate.lotId == roll.id or candidate.rollId == roll.id then
                closePopup(self, candidate)
                break
            end
        end
        compactPopups(self)
        return
    end
    -- Reuse-or-acquire: an existing popup tied to this lot id (either a pending popup
    -- transforming in place, or an earlier interest popup for the same roll) is reused so the
    -- Start/End button is the SAME visual button across the transition. Otherwise pull a fresh
    -- frame from the pool.
    local f
    for _, candidate in ipairs(self.live.active) do
        if candidate.lotId == roll.id or candidate.rollId == roll.id then
            f = candidate
            break
        end
    end
    if not f then
        f = acquirePopup(self)
    end
    f.roll = roll
    roll.popup = f
    f.mode = "interest"
    f.lotId = roll.id   -- keep both attributes consistent so the reuse lookup works either way

    -- seed the local player's prior pick: a prefired loot-tab choice lives on the lot before the
    -- roll starts, so the popup opens with that bracket already highlighted (RefreshInterestPopup
    -- re-asserts it below from roll.choice).
    local mine = self:GetPlayerResponse(roll.id, util:GetPlayerName("player"))
    roll.choice = mine   -- includes "pass": a prior pass opens with the Pass button highlighted
    -- Seed the Pass stance from the durable response (default is "pass"), so hideUnrolledWins treats
    -- anything left on the default Pass as passed. Derived from stored state so it survives a
    -- rebuild (duplicate DROP), a relog, or a prefire; a live bracket click updates it (ChooseInterest).
    roll.passed = (mine == "pass")
    f.icon:SetTexture(roll.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = roll.link
    f.name:SetText(formatRollItemLabel(roll.link, roll.name, roll.quantity))
    self:TrackPopupItem(f, roll.itemId, roll.quantity)
    f.sub:SetText("|cffffffffPrio:|r " .. ((roll.prio and roll.prio ~= "") and roll.prio or DEFAULT_PRIO))
    f.okBtn:Hide()

    f.bisBtn:Show(); f.msBtn:Show(); f.muBtn:Show(); f.osBtn:Show(); f.tmBtn:Show(); f.passBtn:Show()
    f.bisBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "bis") end)
    f.msBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "ms") end)
    f.muBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "mu") end)
    f.osBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "os") end)
    f.tmBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "tm") end)
    f.passBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "pass") end)
    resetInterestButtons(f)
    applyInterestButtonAvailability(self, f, roll)   -- disable brackets the player's class can't use

    if roll.owner then
        -- the ML keeps the popup to drive the roll: Cancel aborts, End resolves.
        -- Interest popup layout: End on the right, Cancel to its left.
        f.rollBtn:Show()
        f.rollBtn:SetWidth(40)
        f.rollBtn:SetText("End")
        f.rollBtn:ClearAllPoints()
        f.rollBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
        f.rollBtn:SetScript("OnClick", function() self:ResolveLiveRoll(roll.id) end)
        f.cancelBtn:Show()
        f.cancelBtn:SetWidth(24)
        f.cancelBtn:SetText("X")
        f.cancelBtn:ClearAllPoints()
        f.cancelBtn:SetPoint("RIGHT", f.rollBtn, "LEFT", -4, 0)
        f.cancelBtn:SetScript("OnClick", function() self:CancelLiveRoll(roll.id) end)
    else
        f.rollBtn:Hide()
        f.cancelBtn:Hide()
    end
    f.count:Show()
    f.countHover:Show()

    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)

    -- countdown: bar shrinks over the roll duration; the loot master auto-resolves at
    -- zero (clients just wait for the resulting WIN). The ML can still Roll! early.
    f.timer:Show()
    f.timer:SetValue(1)
    f.rollId = roll.id
    f.isOwner = roll.owner
    f.duration = roll.duration or ROLL_DURATION
    -- Deadline-based, not elapsed-accumulation: the bar tracks the ML's authoritative end time
    -- (reconstructed locally as now + the remaining seconds the ML sent), so a popup restored
    -- mid-roll shows the true time left and the ML still closes it at the real deadline.
    f.deadline = roll.deadline or (GetTime() + f.duration)
    f:SetScript("OnUpdate", function(bar, dt)
        local remaining = bar.deadline - GetTime()
        local frac = remaining / bar.duration
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        bar.timer:SetValue(frac)
        bar.timer:SetStatusBarColor(1 - frac, frac, 0.1)   -- green -> red as it drains
        if remaining <= 0 then
            bar:SetScript("OnUpdate", nil)
            if bar.isOwner then addon:ResolveLiveRoll(bar.rollId) end
        end
    end)

    addActivePopup(self, f)
    f:Show()
    layoutPopups(self)
    self:RefreshInterestPopup(roll)
end

function addon:RefreshInterestPopup(roll)
    local f = roll and roll.popup
    if not f or f.mode ~= "interest" then return end

    -- count and highlight share the one roller source (ActiveRollers), so the popup never disagrees
    -- with the loot tab; the local player's own pick is re-asserted from roll.choice, kept current
    -- by both the popup buttons and loot-tab picks (ApplyLocalChoice).
    local total = #self:ActiveRollers(roll.id)
    f.count:SetText(total > 0 and (total .. " rolling") or "")
    highlightInterestButton(f, roll.choice)
    refreshPopupRollLines(self, roll)
end

function addon:RefreshLiveRollCountForItem(lotId)
    local roll = lotId and self.live and self.live.rolls and self.live.rolls[lotId]
    if roll and not roll.resolved then
        self:RefreshInterestPopup(roll)
    end
end

function addon:CloseInterestPopup(roll)
    if not roll then return end
    -- one close path for both roll surfaces: every resolve/cancel/win site already calls this,
    -- so the banner card (keyed by the same lot id) rides along for free
    if self.CloseRollBannerCard then self:CloseRollBannerCard(roll.id) end
    if self._bannerNamesPending then self._bannerNamesPending[roll.id] = nil end
    if roll.popup then
        closePopup(self, roll.popup)
        roll.popup = nil
    end
end

-- choose MS/OS/TM/Pass on a popup. The popup stays open after a choice (so everyone
-- sees the roll's progress) and the chosen button is highlighted. The sole exception
-- is Pass for a non-ML roller, which dismisses the loot immediately; the ML never
-- auto-hides (it keeps the popup to drive the roll).
function addon:ChooseInterest(roll, tier)
    local playerName = util:GetPlayerName("player")
    if tier ~= "pass" and not isPlayerAllowedForRoll(self, roll, playerName) then
        self:Print("Your class cannot use that token. You may only pass.")
        return
    end
    -- Track the local player's Pass stance for the hideUnrolledWins option: set on a pass, cleared by
    -- any real bracket. Not cleared by the two-click dismiss below, so it survives to OnWinMessage.
    roll.passed = (tier == "pass")
    self:SendInterest(roll.id, tier)

    -- Two-click dismiss, any bracket: the first click selects and highlights a bracket; a SECOND click
    -- on the already-selected bracket dismisses the loot popup for a raider. The two-click guard stops a
    -- misclick from closing the popup outright. Pass carries no interest, so dismissing clears its choice;
    -- a real bracket KEEPS the interest it just (re)sent and only hides the window. The ML's popup never
    -- auto-hides: for the owner a repeat click just re-asserts the selection (no-op), it drives the roll.
    if not roll.owner and roll.choice == tier then
        if tier == "pass" then roll.choice = nil end
        self:CloseInterestPopup(roll)
        compactPopups(self)
        return
    end

    self:ApplyLocalChoice(roll.id, tier)
    if roll.owner then self:RefreshInterestPopup(roll) end
end

-- ---------------------------------------------------------------------------
-- pending popup (loot master only): a freshly-collected item, not yet broadcast.
-- The ML presses Start Roll to actually put it up for the raid, or Skip to dismiss.
-- ---------------------------------------------------------------------------
function addon:ShowPendingPopup(lot, slot)
    if not lot or not lot.id then return end
    local lotId = lot.id
    local name, link, icon = util:ItemRender(lot.itemId)
    name = name or link or ("item:" .. tostring(lot.itemId))
    local quantity = self.lootCore:LiveCount(lotId)

    local f = acquirePopup(self)
    f.mode = "pending"
    f:SetScript("OnUpdate", nil)        -- no countdown until the roll actually starts
    f.timer:Hide()
    f.lotId = lotId
    f.isOwner = true                    -- pending popups are ML-only; size to the owner floor now so
                                        -- starting the roll (interest popup, same floor) doesn't grow/shift

    f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = link
    f.name:SetText(formatRollItemLabel(link, name, quantity))
    self:TrackPopupItem(f, lot.itemId, quantity)
    f.sub:SetText("|cffffffffPrio:|r " .. (self:GetLiveItemPrio({ name = name }) or DEFAULT_PRIO))
    f.count:Hide()
    f.countHover:Hide()
    if f.rollLines then
        for _, line in ipairs(f.rollLines) do
            line:Hide()
        end
    end
    setPopupHeight(f, getCompactPopupHeight(f))

    f.bisBtn:Hide(); f.msBtn:Hide(); f.muBtn:Hide(); f.osBtn:Hide(); f.tmBtn:Hide(); f.passBtn:Hide(); f.okBtn:Hide()

    -- Pending popup layout: Skip on the right, Start to its left.
    f.cancelBtn:Show()
    f.cancelBtn:SetWidth(36)
    f.cancelBtn:SetText("Skip")
    f.cancelBtn:ClearAllPoints()
    f.cancelBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    f.cancelBtn:SetScript("OnClick", function()
        self.lootCore:Skip(lotId)       -- pending -> skipped; ledgerChanged closes this popup
    end)

    f.rollBtn:Show()
    f.rollBtn:SetWidth(40)
    f.rollBtn:SetText("Start")
    f.rollBtn:ClearAllPoints()
    f.rollBtn:SetPoint("RIGHT", f.cancelBtn, "LEFT", -4, 0)
    f.rollBtn:SetScript("OnClick", function()
        -- Transform this pending popup into an interest popup in place: flip f.mode BEFORE
        -- StartLiveRoll mutates the ledger so the ledgerChanged -> SyncPendingPopups close path
        -- (which only kills mode == "pending" frames) leaves this one alone. StartLiveRoll's
        -- ShowInterestPopup then finds the SAME frame via the lot-id lookup and re-skins it,
        -- so Start and End are the same physical button across the transition.
        f.mode = "interest"
        self:StartLiveRoll(lotId)
    end)

    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)

    addActivePopup(self, f, slot)        -- reuse a given slot (e.g. when a cancelled roll returns to pending)
    f:Show()
    layoutPopups(self)
end

-- ---------------------------------------------------------------------------
-- loot master: start / resolve
-- ---------------------------------------------------------------------------
local function nextRollId(self)
    self.live.seq = self.live.seq + 1
    return tostring(time()) .. "r" .. self.live.seq
end

function addon:GetLiveItemPrio(item)
    local itemName = item and item.name
    local namedRule = itemName and self:GetNamedRule(itemName)
    if namedRule and namedRule.raw and namedRule.raw ~= "" then
        local prioText = formatNamedRuleDisplay(namedRule)
        if not prioText or prioText == "" then
            prioText = namedRule.raw
            if self:RuleHasLootCouncil(namedRule) and not string.match(prioText, ">%s*[Ll][Cc]%s*$") then
                prioText = prioText .. " > LC"
            end
        end
        return prioText
    end

    local lootRule = itemName and self:GetLootRule(itemName)
    return formatLootRuleDisplay(lootRule) or DEFAULT_PRIO   -- no rule: no-prio default bracket order
end

-- Pending-popup restoration is driven by core events (SyncPendingPopups); this stays as the
-- entry point its callers (zone-in / authority-gained reconcile) use.
function addon:RestorePendingPopups()
    self:SyncPendingPopups()
end

-- Abort an open roll. For raiders the item disappears (CANCEL closes their popup). For
-- the ML the loot is NOT lost: we return to the pre-roll pending state (Start Roll / Skip)
-- in the same slot, so the ML can re-roll or skip it.
function addon:CancelLiveRoll(rollId)
    local roll = self.live.rolls[rollId]
    if not roll then return end
    roll.resolved = true
    self:SendLargeMessage("CANCEL", { rollId }, "RAID", nil, "ALERT")
    self.live.rolls[rollId] = nil

    self:CloseInterestPopup(roll)
    self.lootCore:Cancel(rollId)             -- rolling -> pending; SyncPendingPopups re-shows it
    self:Print("Roll cancelled: " .. (roll.name or "item") .. " (back to pending).")

    if self.NotifyRollBatchFinished then self:NotifyRollBatchFinished(rollId) end
end

function addon:OnCancelMessage(fields)
    local roll = self.live.rolls[fields[1]]
    if not roll then return end
    self:CloseInterestPopup(roll)
    compactPopups(self)
    self.live.rolls[fields[1]] = nil
end

-- Start a live roll for a lot id. The core lot is the single source of truth; the roll
-- object here is just the popup/wire wrapper, keyed by the SAME id as the lot.
function addon:StartLiveRoll(lotId)
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can put items up for roll.")
        return
    end
    -- Re-validate tradeability before broadcasting: a trade window can lapse with no bag event, so
    -- re-scan now. Count-aware (duplicates carry independent windows): we refuse only when EVERY
    -- copy of this lot has expired; if a tradeable copy remains, the reconcile shrinks the lot to
    -- that count and we roll it.
    self:ReconcileLootNow()
    local core = self.lootCore
    local lot = core:Get(lotId)
    if not lot then return end
    if core:LiveCount(lotId) <= 0 then
        local name = (util:ItemRender(lot.itemId)) or ("item:" .. tostring(lot.itemId))
        self:Print(name .. " can no longer be traded (its trade window expired); not putting it up for roll.")
        return
    end

    local name, link, icon = util:ItemRender(lot.itemId)
    name = name or link or ("item:" .. tostring(lot.itemId))

    if lot.state == core.STATE.RESOLVED then
        self:Print(name .. " was already rolled out. Use Unlock Roll to reroll it.")
        return
    end

    -- move the lot to rolling (surface first if it is still idle/new/skipped)
    if lot.state ~= core.STATE.PENDING then core:Surface(lotId) end
    if not core:StartRoll(lotId) then return end

    local prio = self:GetLiveItemPrio({ name = name })
    local quantity = core:LiveCount(lotId)
    local rollDuration = getRollDuration()       -- honors the ML's configured Options-tab duration
    local roll = {
        id = lotId, itemId = lot.itemId, link = link, name = name,
        icon = icon, prio = prio, owner = true, registrants = {}, resolved = false,
        duration = rollDuration, quantity = quantity,
        deadline = GetTime() + rollDuration,   -- authoritative end; sync carries the remaining
    }
    self.live.rolls[lotId] = roll

    -- the wire carries the itemId (not a link): every client renders its own localized name.
    -- field 4 is the REMAINING seconds (full duration at start); a client sets deadline = now + it.
    self:SendLargeMessage("DROP",
        { lotId, tostring(lot.itemId), prio or "", tostring(rollDuration), tostring(quantity) }, "RAID", nil, "ALERT")
    self:ShowInterestPopup(roll)
    self:Print("Put " .. name .. " up for roll. Press End Roll when ready.")
end

-- ---------------------------------------------------------------------------
-- loot-tab roll buttons routed through the core. Rolls are keyed by lot id
-- (roll.id == lot.id == item.id), so identity is the lot, never a link, and start/skip go
-- through the core's lifecycle commands. A link can't uniquely name a copy; the lot id can.
-- ---------------------------------------------------------------------------

-- The active (unresolved) live roll for a loot row, by lot id. No link fallback or scan: the
-- roll is stored under the lot id, which is the row's item.id.
function addon:GetActiveLiveRollForItem(item)
    if not item or not item.id then return nil end
    local roll = self.live and self.live.rolls and self.live.rolls[item.id]
    if roll and not roll.resolved then return roll end
    return nil
end

-- Start a roll straight from a loot row. StartLiveRoll surfaces the lot if needed and moves it
-- to rolling; the resulting ledgerChanged drives SyncPendingPopups to close any pending popup,
-- so there is nothing link-keyed to dismiss by hand.
function addon:StartLiveRollFromItem(item)
    if not item or not item.id then return end
    self:StartLiveRoll(item.id)
end

-- Skip a loot row (ML only): move the lot to SKIPPED through the core (Surface first if it is
-- not already pending). SKIPPED is a snooze that resurfaces on the next scan; SyncPendingPopups
-- closes its popup off the ledger change.
function addon:SkipLiveLootItem(item)
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can skip live loot items.")
        return
    end
    if not item or not item.id then return end
    local core = self.lootCore
    local lot = core:Get(item.id)
    if not lot then return end
    if lot.state ~= core.STATE.PENDING then core:Surface(item.id) end
    core:Skip(item.id)
end

function addon:ResolveLiveRoll(rollId)
    local roll = self.live.rolls[rollId]
    if not roll or roll.resolved then return end
    if not self:IsAuthorizedLootMaster() then return end
    roll.resolved = true

    -- Resolve through the core: it hands this lot's responses to ResolveSessionItem (bracket
    -- -> named -> spec -> status -> roll, top-N by count) and freezes the ordered winners onto
    -- per-copy awards. lotResolved fires here -> payout owes; ledgerChanged -> projection + sync.
    local record = self.lootCore:Resolve(rollId) or {}
    local winners = record.winners
    if not winners or #winners == 0 then
        winners = (record.winner and record.winner ~= "No winner") and { record.winner } or {}
    end
    local sections = self:SectionsFromResult(record)
    local winnersText = table.concat(winners, ",")

    -- the wire carries itemId (not a link) and the full winners list (top-N may be > 1)
    self:SendLargeMessage("WIN", {
        rollId, tostring(roll.itemId or 0), winnersText, "roll", "0", self:EncodeSections(sections),
    }, "RAID", nil, "ALERT")
    self:TriggerCallback("RESULTS_UPDATED")

    self:CloseInterestPopup(roll)
    if #winners > 0 then
        self:AddLootBannerItem(self:BannerItemFromResult(roll, winners, sections))
    end
    self.live.rolls[rollId] = nil   -- live-roll UI done; the core holds the truth

    if #winners == 0 then
        self:Print((roll.name or "item") .. " -> no rollers.")
    else
        self:Print(string.format("%s -> %s.", roll.name or "item", winnersText))
    end

    if self.NotifyRollBatchFinished then self:NotifyRollBatchFinished(rollId) end
end

-- Group a result record's rollers by bracket into the popup's section format
-- ({label, members={{name, roll}}}), highest bracket first, for the result popup breakdown.
local SECTION_ORDER = { "bis", "ms", "mu", "os", "tm" }
local SECTION_LABELS = { bis = "BiS", ms = "MS", mu = "MU", os = "OS", tm = "TM" }
local function sectionMemberSortValue(member)
    if member.auto or member.rollText == "AUTO" then
        return 101
    end
    return tonumber(member.roll) or tonumber(member.rollText) or -1
end

local function sortSectionMembers(entries)
    table.sort(entries, function(left, right)
        local leftRoll = sectionMemberSortValue(left)
        local rightRoll = sectionMemberSortValue(right)
        if leftRoll == rightRoll then
            return string.lower(left.name or "") < string.lower(right.name or "")
        end
        return leftRoll > rightRoll
    end)
end

function addon:SectionsFromResult(record)
    local buckets = {}
    for _, d in ipairs(record.allRollerDetails or {}) do
        local b = d.responseType or "pass"
        if b ~= "pass" then
            buckets[b] = buckets[b] or {}
            buckets[b][#buckets[b] + 1] = { name = d.name, roll = tonumber(d.rollText), isNamed = d.isNamed or false }
        end
    end
    local sections = {}
    for _, key in ipairs(SECTION_ORDER) do
        if buckets[key] then
            sortSectionMembers(buckets[key])
            sections[#sections + 1] = { label = SECTION_LABELS[key], members = buckets[key] }
        end
    end
    return sections
end

-- Build a loot-banner item (link/icon/winner/why/full roll list) from a resolved roll, for
-- addon:AddLootBannerItem. This is the win display that replaces the old result popup. The winner's
-- "why" is their own roll + bracket; rolls is every responder, class-colored on the row tooltip.
function addon:BannerItemFromResult(roll, winners, sections)
    local rolls = {}
    for _, s in ipairs(sections or {}) do
        for _, m in ipairs(s.members) do
            rolls[#rolls + 1] = {
                name = m.name,
                class = getPlayerClassName(self, util:NormalizeKey(m.name)),
                roll = m.roll,
                section = m.isNamed and "LC Prio" or s.label,
            }
        end
    end

    -- One winner entry per awarded copy, each enriched with their roll + bracket from the breakdown so a
    -- multi-copy drop shows every winner. winner/winnerClass/why mirror the first for single-winner use.
    local winnerList = {}
    for _, wname in ipairs(winners or {}) do
        local wkey = util:NormalizeKey(wname)
        local section, roll
        for _, r in ipairs(rolls) do
            if util:NormalizeKey(r.name) == wkey then
                section, roll = r.section, r.roll
                break
            end
        end
        winnerList[#winnerList + 1] = {
            name = wname,
            class = getPlayerClassName(self, wkey),
            section = section,
            roll = roll,
        }
    end

    local first = winnerList[1]
    local why = first and (first.roll and string.format("roll %s - %s", tostring(first.roll), first.section or "?") or first.section)

    return {
        key = roll.id,
        link = roll.link,
        icon = roll.icon,
        quantity = roll.quantity,
        winner = first and first.name,
        winnerClass = first and first.class,
        why = why,
        winners = winnerList,
        rolls = rolls,
    }
end

-- pack sections for WIN: "label~name=roll,name=roll" joined by ";"
function addon:EncodeSections(sections)
    local secParts = {}
    for _, s in ipairs(sections or {}) do
        local mem = {}
        for _, m in ipairs(s.members) do
            mem[#mem + 1] = m.name .. "=" .. (m.roll or 0) .. "=" .. ((m.isNamed and "1") or "0")
        end
        secParts[#secParts + 1] = (s.label or "") .. "~" .. table.concat(mem, ",")
    end
    return table.concat(secParts, ";")
end

function addon:DecodeSections(text)
    local sections = {}
    for _, secText in ipairs(util:Split(text or "", ";")) do
        local label, memText = string.match(secText, "^(.-)~(.*)$")
        local members = {}
        for memberText in string.gmatch((memText or "") .. ",", "([^,]*),") do
            local name, value, namedFlag = string.match(memberText, "^([^=,]+)=([^=,]+)=([^=,]+)$")
            if not name then
                name, value = string.match(memberText, "^([^=,]+)=([^=,]+)$")
            end
            if name then
                members[#members + 1] = { name = name, roll = tonumber(value), isNamed = namedFlag == "1" }
            end
        end
        sections[#sections + 1] = { label = label or "", members = members }
    end
    return sections
end

-- ---------------------------------------------------------------------------
-- interest send + register
-- ---------------------------------------------------------------------------
function addon:SendInterest(rollId, tier)
    if self:IsAuthorizedLootMaster() then
        self:RegisterInterest(rollId, util:GetPlayerName("player"), tier)
    else
        local lootMaster = self:GetLootMasterName()
        if lootMaster then
            self:SendLargeMessage("RSP", { rollId, tier }, "WHISPER", lootMaster, "ALERT")
        end
    end
end

function addon:RegisterInterest(rollId, name, tier)
    local roll = self.live.rolls[rollId]
    if not roll or roll.resolved then return end
    roll.registrants[util:NormalizeKey(name)] = { name = name, tier = tier }
    -- Record the pick on the core lot (rollId == lot id). Only the ML owns the lot; the
    -- snapshot sync carries it to raiders. SetPlayerResponse fires SESSION_UPDATED + count.
    if self:IsAuthorizedLootMaster() then
        self:SetPlayerResponse(rollId, name, tier)
    end
    self:RefreshInterestPopup(roll)
end

-- ---------------------------------------------------------------------------
-- incoming comm messages (dispatched from Comm.lua HandleCommMessage)
-- ---------------------------------------------------------------------------
function addon:OnDropMessage(fields)
    -- wire: { lotId, itemId, prio, duration, quantity }. Render display from itemId so each
    -- client shows its OWN localized name/link/icon.
    local lotId = fields[1]
    local itemId = tonumber(fields[2])

    -- Receive-side trace: when a roll-start reaches THIS raider and what the reliably-synced ledger
    -- already says about the lot. With the send-side `send` trace, the t timestamps tell us whether a
    -- DROP arrived inside its roll window or late (e.g. a batch flushed after a loading screen), which
    -- distinguishes a transport delay from the client never processing events during the roll.
    local core = self.lootCore
    local lot = core and core:Get(lotId)
    local coreState = lot and lot.state or "none"
    self:LogCoreEvent("recv-drop", { id = lotId, item = itemId, state = coreState, rem = tonumber(fields[4]) })

    -- A roll-start carries only RELATIVE remaining seconds, so a late one (lost DROP recovered slowly,
    -- or the client buffering messages through a loading screen) would open a "fresh" full-duration
    -- popup for a roll that is already over. Defer to the authoritative ledger: if the lot has already
    -- left ROLLING (resolved/removed), this DROP is stale, so ignore it: showing it would be a dead,
    -- un-rollable popup. A still-unknown or still-rolling lot shows normally.
    if lot and (lot.removed or coreState == core.STATE.RESOLVED) then
        return
    end
    -- We already awarded this lot but the core mirror still lags in ROLLING (its RESOLVED delta
    -- trails the WIN): a retransmitted/late DROP would otherwise rebuild a fresh unresolved roll and
    -- resurrect a zombie card for an item already won. OnWinMessage keeps the resolved roll on
    -- purpose so this guard can see it.
    local existing = self.live.rolls[lotId]
    if existing and existing.resolved then
        return
    end

    local name, link, icon = util:ItemRender(itemId)
    local roll = {
        id = lotId,
        itemId = itemId,
        link = link,
        name = name or link or ("item:" .. tostring(itemId)),
        icon = icon,
        prio = fields[3] or "",
        duration = ROLL_DURATION,
        deadline = GetTime() + (tonumber(fields[4]) or ROLL_DURATION),   -- field 4 = remaining seconds
        quantity = tonumber(fields[5]) or 1,
        owner = false, registrants = {}, resolved = false,
    }
    self.live.rolls[roll.id] = roll
    self:ShowInterestPopup(roll)
end

function addon:OnRspMessage(sender, fields)
    if not self:IsAuthorizedLootMaster() then return end
    self:RegisterInterest(fields[1], sender, fields[2])
end

function addon:OnWinMessage(fields)
    -- wire: { lotId, itemId, winnersText, "roll", "0", sectionsText }
    local rollId, itemId, winnersText, sectionsText = fields[1], tonumber(fields[2]), fields[3], fields[6]
    local roll = self.live.rolls[rollId]
    self:LogCoreEvent("recv-win", { id = rollId, item = itemId, hasPopup = (roll and roll.popup) ~= nil })
    if not roll then
        local name, link, icon = util:ItemRender(itemId)
        roll = { id = rollId, itemId = itemId, link = link, name = name or link, icon = icon }
    end
    roll.resolved = true

    local winners = {}
    for _, w in ipairs(util:Split(winnersText or "", ",")) do
        if w ~= "" then winners[#winners + 1] = w end
    end

    -- Raid-wide win display: every raider who receives the WIN gets the loot banner, regardless of
    -- whether they still had the interest popup open or already dismissed it. Close any lingering
    -- roll surface first (popup or banner card) so it does not sit behind the win.
    self:CloseInterestPopup(roll)
    -- Opt-out: with hideUnrolledWins on, a raider only sees win banners for loot they actually rolled
    -- on. That means suppressing the result when they passed (roll.passed, default Pass included) OR
    -- when their own filters would have hidden the roll prompt in the first place (white/black list,
    -- hide-unusable) -- evaluated live so a filtered item is caught even if no roll surface opened.
    -- Off by default; the ML always sees results (its own resolve path is ungated).
    local suppressed = getOptions().hideUnrolledWins and (roll.passed or self:ShouldSuppressRollPopup(roll))
    if #winners > 0 and not suppressed then
        local sections = self:DecodeSections(sectionsText)
        self:AddLootBannerItem(self:BannerItemFromResult(roll, winners, sections))
    end
end
