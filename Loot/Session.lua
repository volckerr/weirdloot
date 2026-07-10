local addon = WeirdLoot
local util = addon.util

-- Runtime-only loot projection: NEVER persisted. items/results are derived views of the lootCore
-- ledger, rebuilt on every ledgerChanged. Keeping them on this addon-scoped table (not on
-- self.session, which IS the persisted record) makes it structurally impossible to write a second,
-- drift-prone copy of loot state to the SavedVariables. The core is the one persisted source of truth.
addon.lootView = addon.lootView or { items = {}, results = {} }

local SCAN_TOOLTIP_NAME = "WeirdLootScanTooltip"
local tradeScanTooltip

local function buildSessionState(ownerKey)
    return {
        id = nil,
        active = false,
        ownerKey = ownerKey,
        startedAt = nil,
        startSnapshot = {},
        currentSnapshot = {},
        scanMode = "delta",
        responses = {},
        lockedItems = {},
        pendingLinks = {},
        attendees = {},
        itemIdsByLink = {},
        nextItemSeq = 0,
        itemOrderByLink = {},
        nextItemOrder = 0,
        resolvedHeldByLink = {},
    }
end

-- Quality from the item link's colour code. ALWAYS prefer this: the link colour is consistent,
-- whereas GetContainerItemInfo's quality field is unreliable on 3.3.5a -- it spuriously returns
-- -1 even for known, fully-cached items (observed on tier tokens AND Hearthstone, which is always
-- cached), so it is NOT just a cache-miss sentinel, the API simply returns garbage at times.
-- The API value is only used as a last resort when there's no link to read a colour from.
local qualityByHex
local function resolveQuality(link, apiQuality)
    if link then
        if not qualityByHex then
            qualityByHex = {}
            if ITEM_QUALITY_COLORS then
                -- poor(0) through legendary(5) only; artifact/heirloom aren't raid loot.
                for quality, info in pairs(ITEM_QUALITY_COLORS) do
                    if quality >= 0 and quality <= 5 and info and info.hex then
                        qualityByHex[string.lower(info.hex)] = quality
                    end
                end
            end
        end
        local hex = string.match(link, "^(|c%x%x%x%x%x%x%x%x)")
        local q = hex and qualityByHex[string.lower(hex)]
        if q then return q end
    end
    return apiQuality
end

local function getTradeScanTooltip()
    if not tradeScanTooltip then
        local owner = WorldFrame or UIParent
        tradeScanTooltip = CreateFrame("GameTooltip", SCAN_TOOLTIP_NAME, owner, "GameTooltipTemplate")
        tradeScanTooltip:SetOwner(owner, "ANCHOR_NONE")

        for index = 1, 30 do
            if not _G[SCAN_TOOLTIP_NAME .. "TextLeft" .. index] then
                local left = tradeScanTooltip:CreateFontString(SCAN_TOOLTIP_NAME .. "TextLeft" .. index, nil, "GameTooltipText")
                local right = tradeScanTooltip:CreateFontString(SCAN_TOOLTIP_NAME .. "TextRight" .. index, nil, "GameTooltipText")
                tradeScanTooltip:AddFontStrings(left, right)
            end
        end
    end

    return tradeScanTooltip
end

local function normalizeResponseChoice(choice)
    if choice == true then
        return "ms"
    end
    if choice == false or choice == nil then
        return "pass"
    end

    choice = util:NormalizeKey(choice)
    if choice == "bis" then
        return "bis"
    end
    if choice == "ms" or choice == "main spec" or choice == "mainspec" or choice == "roll" then
        return "ms"
    end
    if choice == "mu" or choice == "minor upgrade" or choice == "minorupgrade" then
        return "mu"
    end
    if choice == "os" or choice == "off spec" or choice == "offspec" then
        return "os"
    end
    if choice == "tm" or choice == "transmog" then
        return "tm"
    end

    return "pass"
end

local function tooltipHasLine(tooltip, exactText, partialText)
    local lineCount = tooltip:NumLines() or 0
    for index = 1, lineCount do
        local regions = {
            _G[SCAN_TOOLTIP_NAME .. "TextLeft" .. index],
            _G[SCAN_TOOLTIP_NAME .. "TextRight" .. index],
        }

        for _, region in ipairs(regions) do
            local text = region and region:GetText()
            if text and text ~= "" then
                if exactText and text == exactText then
                    return true
                end

                if partialText and string.find(string.lower(text), string.lower(partialText), 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

local function getBagItemCountAndQuality(bag, slot, link)
    local _, count, _, quality = GetContainerItemInfo(bag, slot)
    quality = resolveQuality(link, quality)
    if not quality and link and link ~= "" then
        quality = select(3, GetItemInfo(link))
    end
    return count or 0, quality
end

local function getItemNameFromLink(link)
    if not link or link == "" then
        return nil
    end

    local itemName = GetItemInfo(link)
    if itemName and itemName ~= "" then
        return itemName
    end

    return string.match(link, "%[(.+)%]")
end

function addon:InitializeSession()
    local ownerKey = self:GetSessionOwnerKey()
    self.sessionDb.activeSessions = self.sessionDb.activeSessions or {}

    local session = self.sessionDb.activeSessions[ownerKey]
    if not session then
        session = buildSessionState(ownerKey)
        self.sessionDb.activeSessions[ownerKey] = session
    end

    self.session = session
    self.session.ownerKey = ownerKey
    self.session.lockedItems = self.session.lockedItems or {}
    self.session.pendingLinks = self.session.pendingLinks or {}

    -- Seed the epoch high-water from our own restored session id so a later mint lands above it (and,
    -- during the upgrade from time()-stamp epochs, above the legacy scale). A disk-restored session is
    -- NOT a live mirror: clear the runtime flag so a takeover never rebroadcasts stale leftover loot.
    self:ObserveEpoch(self.session.id)
    self._mirrorActive = false

    -- self.session is the persisted record, so it must not carry the loot projection: that would
    -- write loot state to disk a second time, beside the authoritative ledger. Keep it absent.
    self.session.items = nil
    self.session.results = nil

    -- Persistence: the core owns a `lootCore` snapshot under the session so its accounting -- awards
    -- and their disposition (owed/delivered/removed) -- survives a reload instead of being lost and
    -- rebuilt empty from the current bags. Restore it BEFORE wiring the ledgerChanged handler so the
    -- apply is silent (no broadcast/re-persist during init). The ML restores its authoritative
    -- ledger; a raider restores a mirror that sync then corrects.
    if self.lootCore then self.lootCore:LoadFrom(self.session) end

    -- The LootCore owns loot truth; the loot projection is a derived view rebuilt from it.
    -- Subscribe once: any ledger change re-projects, persists the ledger, refreshes the UI, syncs.
    if self.lootCore and not self._lootCoreWired then
        self._lootCoreWired = true
        -- Send and persist the authoritative ledger BEFORE the presentation work. The broadcast reads
        -- only the core (BuildLotValue off each lot's own fields), never the loot projection or any UI,
        -- so running it first means an error later while rebuilding projections or refreshing the UI can
        -- never skip the sync send that keeps raiders current. Projections are rebuilt just before the UI
        -- callback, since the tabs render from them.
        self.lootCore:On("ledgerChanged", function()
            if self:IsAuthorizedLootMaster() then self:AutoBroadcastSession() end
            self.lootCore:SaveTo(self.session)   -- keep the persisted ledger current
            self:RebuildLootProjections()
            self:TriggerCallback("SESSION_UPDATED")
        end)
    end
    self:RebuildLootProjections()
end

-- Rebuild the runtime loot projection (addon.lootView.items / .results) from the core ledger.
-- Runs on both the ML (after Reconcile/Resolve) and raiders (after ApplyRemote), so both render
-- from one source of truth (the core), and the projection itself is never persisted. Names/
-- links/icons are rendered on demand from itemId.
function addon:RebuildLootProjections()
    local core = self.lootCore
    if not core then return end
    local view = self.lootView

    local items = {}
    for _, lot in ipairs(core:List()) do
        local name, link, icon = util:ItemRender(lot.itemId)
        items[#items + 1] = {
            id = lot.id,
            itemId = lot.itemId,
            link = link,
            name = name or link or ("item:" .. tostring(lot.itemId)),
            icon = icon,
            quantity = core:LiveCount(lot.id),
            state = lot.state,
            responses = lot.responses,          -- playerKey -> tier string
            locked = lot.state == core.STATE.RESOLVED,
        }
    end
    view.items = items

    local results = {}
    for _, lot in ipairs(core:Resolved()) do
        if lot.record then results[#results + 1] = lot.record end
    end
    view.results = results
end

function addon:BuildBagSnapshot()
    local snapshot = {}
    local minQuality = (self.db and self.db.testMode) and 0 or 4   -- test mode: any item

    for bag, slot in util:BagSlots() do
        local link = GetContainerItemLink(bag, slot)
        local count, quality = getBagItemCountAndQuality(bag, slot, link)
        if link and count > 0 and quality and quality >= minQuality then
            snapshot[link] = (snapshot[link] or 0) + count
        end
    end

    return snapshot
end

function addon:HasAddedEpicLoot(currentSnapshot)
    local session = self:GetCurrentSession()
    local previousSnapshot = session.currentSnapshot or {}

    for link, count in pairs(currentSnapshot or {}) do
        if count > (previousSnapshot[link] or 0) then
            return true
        end
    end

    return false
end

-- Remaining trade-window seconds parsed from an ALREADY-OPEN scan tooltip (no extra SetBagItem), so
-- the bag scan can note the soonest-to-expire windowed item in the same pass. nil = no window line.
local TRADE_TIME_PREFIX
local function tradeTimePrefix()
    if TRADE_TIME_PREFIX == nil then
        local s = BIND_TRADE_TIME_REMAINING or "You may trade this item with players that were also eligible to loot it for the next %s."
        TRADE_TIME_PREFIX = s:match("^(.-)%%s") or s
    end
    return TRADE_TIME_PREFIX
end

local function parseTradeDuration(text)
    if not text then return nil end
    local secs, found = 0, false
    for num, unit in text:gmatch("(%d+)%s*(%a+)") do
        unit = unit:lower()
        if unit:find("day") then secs = secs + num * 86400; found = true
        elseif unit:find("ho") or unit == "hr" or unit == "hrs" then secs = secs + num * 3600; found = true
        elseif unit:find("min") then secs = secs + num * 60; found = true
        elseif unit:find("sec") then secs = secs + num; found = true end
    end
    return found and secs or nil
end

local function tooltipTradeWindowSeconds(tooltip)
    local prefix = tradeTimePrefix()
    if not prefix or prefix == "" then return nil end
    for i = 1, (tooltip:NumLines() or 0) do
        local fs = _G[SCAN_TOOLTIP_NAME .. "TextLeft" .. i]
        local txt = fs and fs:GetText()
        if txt and txt:find(prefix, 1, true) then
            return parseTradeDuration(txt:sub(#prefix + 1)) or 0
        end
    end
    return nil
end

function addon:BuildTradeableEpicCounts()
    local counts = {}
    local soonest                        -- soonest trade-window expiry (s) among counted windowed items
    local loading = false                -- a slot whose item data has not arrived yet (cold cache)
    local testMode = self.db and self.db.testMode
    local minQuality = testMode and 0 or 4
    local tooltip = getTradeScanTooltip()

    for bag, slot in util:BagSlots() do
        local link = GetContainerItemLink(bag, slot)
        local count, quality = getBagItemCountAndQuality(bag, slot, link)
        -- Cold cache: a freshly-looted item can sit in the bag before its template data (quality,
        -- name) has arrived from the server. GetItemInfo is nil until then, so the eligibility test
        -- below cannot classify it and it would not surface until the next loot or the 60s reconcile.
        -- The call also nudges the client to fetch it; OnBagUpdate re-scans shortly (see loading).
        local itemId = GetContainerItemID(bag, slot)
        if itemId and not GetItemInfo(itemId) then loading = true end
        if testMode and link and count > 0 and quality and quality >= minQuality then
            -- city testing: any bag item is eligible EXCEPT soulbound ones (those
            -- can't be traded). A trade-window item is soulbound but tradeable, so
            -- still allow it.
            tooltip:ClearLines()
            tooltip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
            tooltip:SetBagItem(bag, slot)
            tooltip:Show()
            local soulbound = tooltipHasLine(tooltip, ITEM_SOULBOUND, "soulbound")
            local tradeWindow = tooltipHasLine(tooltip, nil, "you may trade this item")
            if (not soulbound) or tradeWindow then
                counts[link] = (counts[link] or 0) + count
                if tradeWindow then
                    local rem = tooltipTradeWindowSeconds(tooltip)
                    if rem and (not soonest or rem < soonest) then soonest = rem end
                end
            end
        elseif link and count > 0 and quality and quality >= minQuality then
            -- 3.3.5a GetItemInfo exposes no bind type (only the tooltip lines below do), so bind-on-
            -- equip is read from the tooltip, not the item info.
            local isBindOnEquip = false
            local isTemporarilyTradeable = false
            local isSoulbound = false
            local windowSecs

            tooltip:ClearLines()
            tooltip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
            tooltip:SetBagItem(bag, slot)
            tooltip:Show()
            if tooltipHasLine(tooltip, nil, "you may trade this item") then
                isTemporarilyTradeable = true
                windowSecs = tooltipTradeWindowSeconds(tooltip)   -- read now, before SetHyperlink overwrites the tooltip
            end
            if tooltipHasLine(tooltip, ITEM_SOULBOUND, "soulbound") then
                isSoulbound = true
            end
            if tooltipHasLine(tooltip, ITEM_BIND_ON_EQUIP, "binds when equipped") then
                isBindOnEquip = true
            end

            tooltip:ClearLines()
            tooltip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
            tooltip:SetHyperlink(link)
            tooltip:Show()
            if tooltipHasLine(tooltip, ITEM_BIND_ON_EQUIP, "binds when equipped") then
                isBindOnEquip = true
            end

            if isTemporarilyTradeable or (isBindOnEquip and not isSoulbound) then
                counts[link] = (counts[link] or 0) + count
                if windowSecs and (not soonest or windowSecs < soonest) then soonest = windowSecs end
            end
        end
    end

    tooltip:Hide()
    self._soonestLootExpiry = soonest    -- nil if nothing windowed; drives the expiry re-scan timer
    self._sawLoadingItem = loading       -- a cold-cache item was present; OnBagUpdate arms a re-scan
    return counts
end

-- Session epochs used to be tostring(time()), so a non-ML client that had started a session LATER
-- than the current ML held a higher epoch and could win WeirdSync's "newest epoch" race (poisoning
-- the raid on relog). Epochs are now a monotonic generation counter persisted account-wide: it only
-- ever increases, and a fresh epoch is minted on session start AND on loot-master handoff, so the
-- current ML always holds the newest epoch by construction, independent of any client's wall clock.
function addon:NextEpoch()
    local high = (self.sessionDb.epochHigh or 0) + 1
    self.sessionDb.epochHigh = high
    return tostring(high)
end

-- Raise the high-water to any epoch we have seen (our own restored id, or a peer/ML snapshot). Seeding
-- from observed legacy time()-stamp epochs also lifts the counter above the old scale, so a peer still
-- holding a time-based epoch is not out-ranked by a small generation number during the upgrade.
function addon:ObserveEpoch(epoch)
    local g = tonumber(epoch)
    if g and g > (self.sessionDb.epochHigh or 0) then
        self.sessionDb.epochHigh = g
    end
end

-- Called when we gain confirmed loot-master authority (Roster:RefreshLootAuthority, false->true) while
-- a session is already LIVE and we were mirroring it as a raider. Continue that session instead of
-- wiping it: the core ledger we mirrored IS the state, so we only re-stamp a fresh (higher) epoch and
-- force a full snapshot, and the raid rebaselines onto us.
--
-- Two guards keep this safe:
--   * _mirrorActive: only a session received from the wire THIS play-session qualifies. A disk-restored
--     leftover (active=true from a past raid) is never rebroadcast as if it were the current one.
--   * payout is NOT auto-resumed. Owed/delivered disposition is not carried on the wire and the items
--     sit in the previous ML's bags, so re-whispering already-paid winners would be worse than a manual
--     resume. The new ML turns payout on deliberately.
function addon:AssumeLootMasterSession()
    if not self.session or not self.session.active then return end
    if not self._mirrorActive then return end          -- not a live mirror: do not rebroadcast stale loot
    self.session.id = self:NextEpoch()
    self.session.ownerKey = self:GetSessionOwnerKey()
    self.lootCore:SaveTo(self.session)
    self:AutoBroadcastSession(true)                    -- full snapshot at the new epoch; raiders rebaseline
    self:TriggerCallback("SESSION_UPDATED")
    self:Print("Loot master role assumed; continuing the active loot session.")
end

function addon:StartLootSession()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can start a loot session.")
        return
    end

    -- Session start is the moment fresh note data matters most: re-query the guild and, if
    -- this ML can't read officer notes itself, ask an officer for the relayed map.
    self:RequestGuildRoster()
    self:RequestGuildNotes()

    local sessionId = self:NextEpoch()
    self.session.id = sessionId
    self.session.active = true
    self.session.ownerKey = self:GetSessionOwnerKey()
    self.session.startedAt = time()
    self.session.startSnapshot = self:BuildBagSnapshot()
    self.session.currentSnapshot = util:CloneTable(self.session.startSnapshot)
    self.session.scanMode = "delta"
    self.session.responses = {}
    self.session.lockedItems = {}
    self.session.pendingLinks = {}
    self.session.attendees = util:CloneTable(self:GetAttendees())
    self.lootView = { items = {}, results = {} }    -- runtime projection; rebuilt by the Reconcile below
    self.session.itemIdsByLink = {}
    self.session.nextItemSeq = 0
    self.session.itemOrderByLink = {}
    self.session.nextItemOrder = 0
    self.session.resolvedHeldByLink = {}

    -- Wipe the ledger and baseline the loot already in bags as idle (not fresh drops), so a
    -- session started mid-bag does not auto-roll everything the ML is already carrying.
    self.lootCore:Reset()
    local eligible = self:ItemIdCounts(self:BuildTradeableEpicCounts())
    self.session.prevEligible = eligible
    self.lootCore:Reconcile(eligible, {})

    self.sessionDb.history = self.sessionDb.history or {}

    -- A fresh session starts with a fresh payout ledger: drop any owes carried over from
    -- a prior session so they aren't re-whispered/re-delivered here.
    if self.payout then self.payout:ClearOwed() end

    -- Payout mode is on for the duration of the session: as live-roll winners get
    -- owed, a winner opening a trade with the ML auto-fills.
    self:ResumePayoutMode()

    -- A new session is a new epoch, so force a full snapshot: raiders must rebaseline to it to
    -- activate the session (session.active is set only when a snapshot is applied, never by a delta,
    -- and deltas do not carry the epoch). Without this a raider whose last sync predates the session
    -- applies the new lots as plain deltas and never activates, until the heartbeat catches the epoch
    -- change up to ~30s later.
    self:AutoBroadcastSession(true)

    self:TriggerCallback("SESSION_UPDATED")
    self:Print("Loot session started. Payout mode ON.")
end

function addon:ClearSession()
    self.session.active = false
    self.session.ownerKey = self:GetSessionOwnerKey()
    self.session.scanMode = "delta"
    self.session.responses = {}
    self.session.lockedItems = {}
    self.session.pendingLinks = {}
    self.session.prevEligible = {}
    self.session.lcOverrides = {}        -- temporary LC priorities die with the session
    self.lootView = { items = {}, results = {} }
    self.lootCore:Reset()
    self:TriggerCallback("SESSION_UPDATED")
end

-- Session-scoped LC priority override for a single item. Parsed through the same machinery as
-- the persistent namedRules, so the Resolver consumes it identically. Stored on self.session
-- (not self.config) so it wipes when ClearSession runs. Authoritative on the ML; raiders don't
-- need the rule because resolution is computed ML-side.
function addon:SetSessionLCOverride(itemName, prioText)
    if not itemName or itemName == "" then return false end
    self.session.lcOverrides = self.session.lcOverrides or {}
    local key = util:NormalizeKey(itemName)
    prioText = string.trim(prioText or "")
    if prioText == "" then
        self.session.lcOverrides[key] = nil
        self:Print("LC override cleared for " .. itemName .. ".")
        self:TriggerCallback("SESSION_UPDATED")
        return true
    end
    -- Reuse ParseTieredRuleText by synthesizing the standard "ItemName, prio" line. The parsed
    -- rule has the same shape as a config.namedRules entry, so GetNamedRule can return it
    -- transparently and the Resolver branches on it without special-casing.
    local synthetic = itemName .. ", " .. prioText
    local parsed = self:ParseTieredRuleText(synthetic, self.ParseNamedToken)
    local rule = parsed[key]
    if not rule or #rule.tiers == 0 then
        self:Print("Could not parse LC priority: " .. prioText)
        return false
    end
    self.session.lcOverrides[key] = rule
    self:Print(string.format("LC override set for %s: %s", itemName, rule.raw))
    self:TriggerCallback("SESSION_UPDATED")
    return true
end

function addon:GetSessionLCOverride(itemName)
    if not self.session or not self.session.lcOverrides then return nil end
    return self.session.lcOverrides[util:NormalizeKey(itemName or "")]
end

function addon:ClearSessionLCOverride(itemName)
    return self:SetSessionLCOverride(itemName, "")
end

function addon:GetCurrentSession()
    return self.session
end

-- Convert a link-keyed count map (from the bag scans) into an itemId-keyed one. Two links
-- that share an itemId (e.g. random-suffix variants) collapse into one lot.
function addon:ItemIdCounts(linkCounts)
    local out = {}
    for link, count in pairs(linkCounts or {}) do
        local itemId = util:ItemIdFromLink(link)
        if itemId then out[itemId] = (out[itemId] or 0) + count end
    end
    return out
end

function addon:BuildSessionItemList(includeAllEpics)
    local session = self:GetCurrentSession()
    if not session.active then
        return {}
    end

    local currentSnapshot = includeAllEpics and self:BuildTradeableEpicCounts() or self:BuildBagSnapshot()
    -- Do NOT clobber the delta baseline here. At login the bags may not be fully loaded,
    -- so storing this partial scan as session.currentSnapshot makes the next BAG_UPDATE
    -- diff the real bag against an empty baseline and auto-roll already-present loot. The
    -- baseline is owned by StartLootSession (init) and OnBagUpdate (delta); only prime it
    -- if it has never been set.
    if session.currentSnapshot == nil then
        session.currentSnapshot = currentSnapshot
    end

    local tradeableCounts = self:BuildTradeableEpicCounts()
    self:AssignPickupOrder(currentSnapshot, tradeableCounts, includeAllEpics)
    session.resolvedHeldByLink = session.resolvedHeldByLink or {}
    for link in pairs(session.resolvedHeldByLink) do
        local currentEligibleCount = includeAllEpics and (currentSnapshot[link] or 0) or (tradeableCounts[link] or 0)
        if currentEligibleCount <= 0 then
            session.resolvedHeldByLink[link] = nil
        elseif session.resolvedHeldByLink[link] > currentEligibleCount then
            session.resolvedHeldByLink[link] = currentEligibleCount
        end
    end
    local sortedLinks = {}
    for link, totalCount in pairs(currentSnapshot) do
        local eligibleCount = includeAllEpics and totalCount or (tradeableCounts[link] or 0)
        if eligibleCount > 0 then
            local heldResolved = math.min(eligibleCount, session.resolvedHeldByLink[link] or 0)
            session.resolvedHeldByLink[link] = heldResolved > 0 and heldResolved or nil
            local unresolvedCount = eligibleCount - heldResolved
            if unresolvedCount > 0 then
                local itemName, _, _, _, _, _, _, _, _, texture = GetItemInfo(link)
                sortedLinks[#sortedLinks + 1] = {
                    link = link,
                    count = unresolvedCount,
                    name = itemName or link,
                    icon = texture or "Interface\\Icons\\INV_Misc_QuestionMark",
                }
            end
        end
    end

    table.sort(sortedLinks, function(left, right)
        local leftOrder = session.itemOrderByLink[left.link] or math.huge
        local rightOrder = session.itemOrderByLink[right.link] or math.huge
        if leftOrder == rightOrder then
            return left.link < right.link
        end
        return leftOrder < rightOrder
    end)

    local items = {}
    for _, entry in ipairs(sortedLinks) do
        local currentId = session.itemIdsByLink[entry.link]
        if not currentId or self:IsItemLocked(currentId) then
            currentId = self:NextSessionItemId()
            session.itemIdsByLink[entry.link] = currentId
        end
        items[#items + 1] = {
            id = currentId,
            link = entry.link,
            name = entry.name,
            icon = entry.icon,
            quantity = entry.count,
        }
    end

    return items
end

function addon:RefreshSessionItems(forceRefresh)
    local session = self:GetCurrentSession()
    if not session.active and not forceRefresh then
        self:RebuildLootProjections()
        return
    end
    if not session.active and forceRefresh then
        self:StartLootSession()
        session = self:GetCurrentSession()
    end

    if forceRefresh and self:IsAuthorizedLootMaster() then
        -- manual Scan Bags: pick up all eligible loot and surface every open lot to the ML.
        local eligible = self:ItemIdCounts(self:BuildTradeableEpicCounts())
        local fresh = {}
        for itemId in pairs(eligible) do fresh[itemId] = true end
        session.prevEligible = eligible
        local core = self.lootCore
        core:Reconcile(eligible, fresh)
        for _, lot in ipairs(core:List()) do
            if lot.state == core.STATE.IDLE or lot.state == core.STATE.NEW or lot.state == core.STATE.SKIPPED then
                core:Surface(lot.id)
            end
        end
    end

    session.attendees = util:CloneTable(self:GetAttendees())
    self:RebuildLootProjections()
    self:TriggerCallback("SESSION_UPDATED")
end

function addon:OnBagUpdate()
    local session = self:GetCurrentSession()
    if not session.active then
        return false
    end
    -- Only the ML reconciles bag reality into the ledger; raiders mirror via the snapshot.
    if not self:IsAuthorizedLootMaster() then
        return false
    end

    local eligible = self:ItemIdCounts(self:BuildTradeableEpicCounts())

    -- Post-login settle window: bags load in STAGES after a login/reload. While inside it we
    -- still reconcile (to baseline counts) but mark nothing fresh, so staged-loading items are
    -- never mistaken for fresh drops and auto-surfaced.
    local settled = self.bagSettleAt and (GetTime() >= self.bagSettleAt)
    local prev = session.prevEligible or {}
    local fresh = {}
    if settled then
        for itemId, count in pairs(eligible) do
            if count > (prev[itemId] or 0) then fresh[itemId] = true end
        end
    end
    session.prevEligible = eligible

    -- While a trade window is open, a dropping count is the payout trade handing an owed item
    -- over: protect owed awards so the trade-complete callback records delivery, not removal.
    local protectOwed = self.payout and self.payout.IsTradeOpen and self.payout:IsTradeOpen()
    self.lootCore:Reconcile(eligible, fresh, protectOwed) -- ledgerChanged -> projections + auto-surface (LiveRoll)

    -- Reconcile the payout owe ledger against the same bag truth: an owe we can no longer back with
    -- a held copy is nothing to owe. Only once bags have settled (so staged-loading items are not
    -- read as gone) and no trade is mid-flight (an owed copy in the trade window is mid-delivery).
    if settled and not protectOwed and self.ReconcilePayoutAgainstBags then
        self:ReconcilePayoutAgainstBags(eligible)
    end

    -- A trade window lapsing fires no game event, so schedule a single re-scan for just after the
    -- soonest-to-expire item lapses; that pass drops it from the list, syncs raiders, and re-arms.
    self:ArmTradeExpiryTimer(self._soonestLootExpiry)

    -- This scan saw an item whose data had not loaded yet, so it could not be classified/surfaced.
    -- Re-scan shortly (the scan above already nudged the fetch) so it pops the moment the data lands,
    -- instead of waiting for the next loot or the 60s reconcile. A clean scan resets the retry budget.
    -- Only once settled: during the post-login bag load the whole bag reads cold, and surfacing is
    -- suppressed there anyway, so retrying then is pure churn. In a raid bags are long settled, so the
    -- genuine case (a fresh drop whose data lags) is unaffected.
    if settled and self._sawLoadingItem then
        self:ScheduleLoadRetry()
    else
        self._loadRetries = 0
    end
    return true
end

-- One-shot re-scan timer for the next trade-window lapse. We fire 5s AFTER the soonest item lapses:
-- the buffer absorbs latency and coalesces a batch of items looted together into ONE check (we only
-- ever track the single soonest expiry, never a per-item schedule). The re-scan drains the now-
-- untradeable item and broadcasts to raiders; OnBagUpdate then re-arms for the next soonest.
local tradeExpiryTimer = CreateFrame("Frame")
tradeExpiryTimer:Hide()
tradeExpiryTimer:SetScript("OnUpdate", function()
    local at = addon._tradeExpiryAt
    if not at then tradeExpiryTimer:Hide(); return end
    if GetTime() >= at and not (InCombatLockdown and InCombatLockdown()) then
        addon._tradeExpiryAt = nil
        tradeExpiryTimer:Hide()
        addon:ReconcileLootNow()
    end
end)

function addon:ArmTradeExpiryTimer(seconds)
    if seconds then
        self._tradeExpiryAt = GetTime() + seconds + 5
        tradeExpiryTimer:Show()
    else
        self._tradeExpiryAt = nil
        tradeExpiryTimer:Hide()
    end
end

-- Looting a corpse fires a burst of BAG_UPDATE events (one or more per item entering the bags), and a
-- full OnBagUpdate is expensive on the ML: BuildTradeableEpicCounts renders a GameTooltip per epic in
-- the bags to read its bind/trade lines, then projections rebuild and the session broadcasts. Running
-- that whole pipeline once per event in the burst is the loot-time frame hitch. Coalesce it: each
-- BAG_UPDATE just re-arms a short trailing deadline, and the scan runs ONCE after the bags go quiet.
-- One scan against the pre-burst baseline is also exact for freshness, where partial mid-burst scans
-- would smear the net-new set.
local BAG_SETTLE = 0.20
local bagDebounce = CreateFrame("Frame")
bagDebounce:Hide()
bagDebounce:SetScript("OnUpdate", function()
    if not addon._bagReconcileAt or GetTime() < addon._bagReconcileAt then return end
    addon._bagReconcileAt = nil
    bagDebounce:Hide()
    if addon:OnBagUpdate() then addon:AutoBroadcastSession(false) end
end)

-- Arm/re-arm the coalesced bag reconcile. Trailing debounce: the deadline pushes forward on every new
-- BAG_UPDATE so the scan lands BAG_SETTLE after the last event, draining the whole loot sweep at once.
function addon:ScheduleBagReconcile()
    self._bagReconcileAt = GetTime() + BAG_SETTLE
    bagDebounce:Show()
end

-- Re-scan a beat after a scan that saw a still-loading (cold-cache) item, so it surfaces as soon as
-- its data arrives rather than on the next loot or the 60s reconcile. Capped: an item that never
-- resolves must not spin the scan forever -- the periodic reconcile stays the backstop. A clean scan
-- (no loading item) resets the budget in OnBagUpdate, so a later cold item gets a fresh allowance.
local LOAD_RETRY = 0.5
local LOAD_RETRY_MAX = 10
function addon:ScheduleLoadRetry()
    self._loadRetries = (self._loadRetries or 0) + 1
    if self._loadRetries > LOAD_RETRY_MAX then return end
    self._bagReconcileAt = GetTime() + LOAD_RETRY
    bagDebounce:Show()
end

-- Re-scan bags and reconcile the ledger NOW (then broadcast any change), driven by triggers other
-- than BAG_UPDATE: opening the loot tab, Start Roll, a periodic out-of-combat tick, and zone-in. A
-- BoP trade window expiring fires no game event -- the item stays in bags, only its tooltip changes
-- -- so without an out-of-band re-scan a now-untradeable item lingers on the list as rollable. The
-- scan already excludes expired-window items; this just makes the reconcile actually run. No-op for
-- raiders or when no session is active.
function addon:ReconcileLootNow()
    if self:OnBagUpdate() then self:AutoBroadcastSession(false) end
end

function addon:SetPlayerResponse(lotId, playerName, choice)
    if self:IsItemLocked(lotId) then
        return false
    end
    choice = normalizeResponseChoice(choice)
    -- Mirror the local player's own pick onto both surfaces (popup + loot tab) immediately, on any
    -- client: a choice made from the loot tab reflects on the popup just as a popup click reflects
    -- on the loot tab. The guard keeps a raider's relayed pick (recorded under their name on the ML)
    -- from hijacking the ML's own highlighted button.
    if self.ApplyLocalChoice
        and util:NormalizeKey(playerName) == util:NormalizeKey(util:GetPlayerName("player")) then
        self:ApplyLocalChoice(lotId, choice)
    end
    -- Only the ML mutates the authoritative ledger. A raider sends its pick to the ML and
    -- waits for the snapshot to reflect it (mutating the local mirror would be overwritten).
    if not self:IsAuthorizedLootMaster() then
        self:SendSelection(lotId, choice)
        return true
    end
    local applied = self.lootCore:SetResponse(lotId, util:NormalizeKey(playerName), choice)
    if applied then
        self:TriggerCallback("SESSION_UPDATED")
        if self.RefreshLiveRollCountForItem then
            self:RefreshLiveRollCountForItem(lotId)
        end
        if self.MarkRollStateDirty then
            self:MarkRollStateDirty(lotId)   -- throttled RSTATE -> raiders see the live pick list
        end
        -- Coalesced: a pick is NOT broadcast on its own (per-pick sends flood the wire during a
        -- live roll). SetResponse marked the lot dirty in the core, so the pick rides the lot's
        -- next LOTD: its resolve, or any other ledger change that flushes the delta. N picks on a
        -- lot collapse into one message. The ML drives the live-roll count locally meanwhile.
    end
    return applied
end

function addon:GetPlayerResponse(lotId, playerName)
    return normalizeResponseChoice(self.lootCore:GetResponse(lotId, util:NormalizeKey(playerName)))
end

function addon:IsResponseActive(choice)
    choice = normalizeResponseChoice(choice)
    return choice ~= "pass"
end

function addon:GetItemById(lotId)
    for _, item in ipairs(self.lootView.items or {}) do
        if item.id == lotId then
            return item
        end
    end
    return nil
end

-- Lock state lives in the core: a lot is "locked" once it has been resolved.
function addon:IsItemLocked(lotId)
    return self.lootCore:IsResolved(lotId)
end

function addon:GetResultByItemId(lotId)
    for _, result in ipairs(self.lootView.results or {}) do
        if result.itemId == lotId then
            return result
        end
    end
    return nil
end

function addon:HasLockedItems()
    return #self.lootCore:Resolved() > 0
end

-- Unlock a single resolved lot for reroll. Goes through the core's per-lot Unlock so the
-- ledger change retracts any owe (payout) and broadcasts via the normal ledgerChanged path.
-- Retract a roll from the raid when the ML unlocks a resolved lot for reroll. After a win each raider
-- keeps its roll record with resolved = true (OnWinMessage, on purpose, to reject late/duplicate
-- DROPs), so a re-DROP for the same lot is dropped by OnDropMessage's resolved guard and
-- SyncRollPopups won't restore it (a record still exists). The reroll would then be invisible to the
-- raid: no fresh popup, no one can respond, and End resolves with no rollers. CANCEL is the signal
-- that clears that record (OnCancelMessage), exactly as the manual Cancel + Start does; the following
-- DROP then opens a fresh popup. Clear our own record too, since a client never receives its own RAID
-- message. Both unlock paths (single reroll and Unlock-All) route through here so raiders stay in step.
function addon:RetractRollForReroll(lotId)
    if self.live and self.live.rolls then self.live.rolls[lotId] = nil end
    self:SendLargeMessage("CANCEL", { lotId }, "RAID", nil, "ALERT")
end

function addon:UnlockSessionRoll(lotId)
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can unlock rolled loot.")
        return false
    end
    if not self.lootCore:Unlock(lotId) then
        self:Print("That item is not in a resolved state; nothing to reroll.")
        return false
    end
    self:RetractRollForReroll(lotId)
    self:TriggerCallback("RESULTS_UPDATED")
    self:Print("Unlocked for reroll.")
    return true
end

function addon:UnlockAllRolls()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can unlock rolled loot.")
        return false
    end

    if not self:HasLockedItems() then
        self:Print("Loot is already unlocked.")
        return false
    end

    -- Capture the lots being unlocked BEFORE UnlockAll clears their resolved state, so each gets its
    -- retract CANCEL (see RetractRollForReroll). Otherwise Unlock-All would leave every raider holding
    -- a stale resolved record and re-rolling any of those lots afterward would be invisible to the raid.
    local unlocked = {}
    for _, lot in ipairs(self.lootCore:Resolved()) do unlocked[#unlocked + 1] = lot.id end
    self.lootCore:UnlockAll() -- ledgerChanged -> projections + snapshot broadcast
    for _, lotId in ipairs(unlocked) do self:RetractRollForReroll(lotId) end
    self:TriggerCallback("RESULTS_UPDATED")
    self:Print("All loot unlocked for reroll.")
    return true
end
