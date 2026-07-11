local addon = WeirdLoot
local util = addon.util

-- Auto-loot routing. While a loot session is active and we are
-- the master looter, each item in an opened loot window is assigned by type:
--   * Bind-on-Pickup (any quality)  -> the loot master (held for rolling)
--   * epic Bind-on-Equip            -> the loot master
--   * non-epic Bind-on-Equip        -> the designated disenchanter (WeirdLootDB.deer)
-- Items the ML keeps land in the ML's bags, where the bag delta auto-starts a live
-- roll; DE trash goes straight to the disenchanter's bags.
--
-- Requirements / caveats (verified against the MasterLoot addon + 3.3.5a FrameXML):
--   * Group must be in Master Loot with us as master looter (GiveMasterLoot only
--     works for the master looter; LootSlot can't hand loot to another player).
--   * GiveMasterLoot silently no-ops on items below the group's loot threshold, so
--     set the threshold to Uncommon for green/blue BoE to route to the DE'er.
--   * Assigning a BoP to ourselves raises the "will bind to you" popup
--     (LOOT_BIND_CONFIRM); we auto-confirm it below.

local BOP = ITEM_BIND_ON_PICKUP or "Binds when picked up"
local BOE = ITEM_BIND_ON_EQUIP or "Binds when equipped"

local scanTip
local function lootScanner()
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "WeirdLootAutoLootTip", UIParent, "GameTooltipTemplate")
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    end
    return scanTip
end

-- "bop" / "boe" / nil for a loot slot, by scanning its tooltip
function addon:LootSlotBindType(slot)
    local tip = lootScanner()
    tip:ClearLines()
    tip:SetLootItem(slot)
    for i = 1, tip:NumLines() do
        local fs = _G["WeirdLootAutoLootTipTextLeft" .. i]
        local text = fs and fs:GetText()
        if text then
            if string.find(text, BOP, 1, true) then return "bop" end
            if string.find(text, BOE, 1, true) then return "boe" end
        end
    end
    return nil
end

-- are we the actual WoW master looter (required for GiveMasterLoot to work)
function addon:IsMasterLooter()
    local method, partyIdx, raidIdx = GetLootMethod()
    if method ~= "master" then return false end
    if raidIdx and raidIdx > 0 then
        return UnitIsUnit("raid" .. raidIdx, "player")
    end
    return partyIdx == 0
end

function addon:FindMasterLootCandidate(name)
    if not name then return nil end
    local want = util:NormalizeKey(name)
    for i = 1, 40 do
        local cand = GetMasterLootCandidate(i)
        if cand and util:NormalizeKey(cand) == want then return i end
    end
    return nil
end

function addon:LOOT_OPENED()
    local session = self:GetCurrentSession()
    if not session.active or not self:IsMasterLooter() then return end

    -- ML loan: we hold the WoW role only as the loan's BORROWER (session authority stays with the
    -- owner). Pick up ONLY the loaned item; none of the general routing below may run on a
    -- borrower, or the borrower would master-loot the raid's drops into the wrong bags.
    local loan = self.ActiveMLLoan and self:ActiveMLLoan()
    if loan and not self:IsAuthorizedLootMaster() then
        self:BorrowerLoanPickup(loan)
        return
    end

    -- Snapshot the window (source mob + every slot) and fire the observer's checks BEFORE any
    -- routing assigns below start clearing slots (LootObserver: quest-drop-missing warning +
    -- pending phantom sends, which may assign their slots first).
    self:ObserveLootOpened()

    local selfIdx = self:FindMasterLootCandidate(UnitName("player"))
    local deerIdx = self.db.deer and self:FindMasterLootCandidate(self.db.deer) or nil

    for slot = 1, GetNumLootItems() do
        -- a slot the observer just assigned to a phantom-send target is spoken for
        if LootSlotIsItem(slot) and not (self.lootObs and self.lootObs.assigning[slot]) then
            local _, _, _, quality = GetLootSlotInfo(slot)
            local bind = self:LootSlotBindType(slot)
            local target
            if bind == "bop" then
                -- A pure-Unique we already hold cannot be self-assigned: GiveMasterLoot silently
                -- no-ops and the item despawns with the corpse. Leave the slot and let the
                -- observer warn + phantom-roll it (sent to the winner off the corpse instead).
                local link = GetLootSlotLink(slot)
                local itemId = link and util:ItemIdFromLink(link)
                if itemId and self:LootSlotIsBlockedUnique(itemId) then
                    self:OnUniqueBlockedSlot(slot, itemId, link)
                else
                    target = selfIdx                              -- BoP -> ML
                end
            elseif bind == "boe" then
                target = ((quality or 0) >= 4) and selfIdx or deerIdx  -- epic BoE -> ML; else DE'er
            end
            if target then
                GiveMasterLoot(slot, target)
            end
        end
    end
end

-- auto-confirm the "this item will bind to you" popup raised when we assign a BoP to
-- ourselves. Deferred a tick (mirrors WeirdChromie) so we don't race the popup setup.
local bindQueue = {}
local bindDispatcher = CreateFrame("Frame")
bindDispatcher:Hide()
bindDispatcher:SetScript("OnUpdate", function(self)
    for slot in pairs(bindQueue) do
        ConfirmLootSlot(slot)
        StaticPopup_Hide("LOOT_BIND")
        bindQueue[slot] = nil
    end
    self:Hide()
end)

function addon:LOOT_BIND_CONFIRM(slot)
    local session = self:GetCurrentSession()
    if not session.active or not self:IsMasterLooter() then return end
    -- a loan borrower only ever self-assigns the loaned item; confirm nothing else for them
    local loan = self.ActiveMLLoan and self:ActiveMLLoan()
    if loan and not self:IsAuthorizedLootMaster() then
        local link = slot and GetLootSlotLink(slot)
        if not link or util:ItemIdFromLink(link) ~= loan.itemId then return end
    end
    if slot then
        bindQueue[slot] = true
        bindDispatcher:Show()
    end
end
