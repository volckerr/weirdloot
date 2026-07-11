local addon = WeirdLoot
local util = addon.util

-- MLLoan: an ITEM-SCOPED, temporary borrow of the WoW master-looter role. A quest-gated drop is
-- filtered out of an ineligible ML's loot window entirely, so the only way to collect it is for an
-- eligible player to hold the WoW ML role at the corpse. The loan makes that safe: the ADDON
-- session authority stays pinned to the loan's owner the whole time (RefreshLootAuthority reads
-- ActiveMLLoan), so the borrower never assumes the session, never reconciles bags into the ledger,
-- and never re-broadcasts the picked-up item as a fresh drop. The loan rides the session M-line
-- (snapshot-carried), so every current client agrees on owner/borrower while it is active.
--
-- Lifecycle: the invisible drop is rolled as a phantom lot; on resolve the ML's win card offers
-- "Loan master loot to <winner>". Clicking starts the loan: broadcast first, then (raid leader
-- only) SetLootMethod after a short delay so the flag lands on the borrower before the roster
-- flips. The borrower loots the item (their AutoLoot self-assigns ONLY the loaned itemId), their
-- client whispers LOANDONE on acquisition, and the owner records the phantom award delivered,
-- clears the loan, and takes the WoW role back. Backstops: a timeout, a borrower-left-raid check,
-- and "/wl loan cancel".

local LOAN_TIMEOUT = 300      -- seconds before an unfulfilled loan auto-cancels (owner side)
local SWAP_DELAY = 1.0        -- broadcast-to-SetLootMethod gap: let the loan flag outrun the roster flip

-- The current loan, from this client's session mirror (owner and raiders alike), or nil.
function addon:ActiveMLLoan()
    local session = self.GetCurrentSession and self:GetCurrentSession() or self.session
    if not session or not session.active then return nil end
    local loan = session.mlLoan
    if loan and loan.owner and loan.borrower and loan.itemId then return loan end
    return nil
end

-- Compact M-line field: "owner;borrower;itemId;lotId" ("" = no loan). Names never contain ';'.
function addon:EncodeMLLoan(loan)
    if not (loan and loan.owner and loan.borrower and loan.itemId) then return "" end
    return table.concat({ loan.owner, loan.borrower, tostring(loan.itemId), loan.lotId or "" }, ";")
end

function addon:DecodeMLLoan(text)
    if not text or text == "" then return nil end
    local owner, borrower, itemId, lotId = string.match(text, "^([^;]+);([^;]+);([^;]+);?(.*)$")
    itemId = tonumber(itemId)
    if not (owner and borrower and itemId) then return nil end
    return { owner = owner, borrower = borrower, itemId = itemId, lotId = (lotId ~= "" and lotId) or nil }
end

-- Only the raid LEADER may call SetLootMethod (assistants cannot change loot method).
local function isSelfRaidLeader()
    local me = util:NormalizeKey(util:GetPlayerName("player") or "")
    for i = 1, (GetNumRaidMembers() or 0) do
        local name, rank = GetRaidRosterInfo(i)
        if name and util:NormalizeKey(util:StripRealm(name)) == me then return rank == 2 end
    end
    return false
end

-- Delayed SetLootMethod: fires once, SWAP_DELAY after StartMLLoan, so the loan broadcast reaches
-- the borrower before PARTY_LOOT_METHOD_CHANGED does (a borrower whose roster flips before the
-- loan lands would seize the session, the exact failure the loan exists to prevent).
local swapTimer = CreateFrame("Frame")
swapTimer:Hide()
swapTimer:SetScript("OnUpdate", function(f)
    if not addon._loanSwapAt or GetTime() < addon._loanSwapAt then return end
    addon._loanSwapAt = nil
    f:Hide()
    local target = addon._loanSwapTo
    addon._loanSwapTo = nil
    if target and SetLootMethod then SetLootMethod("master", util:StripRealm(target)) end
end)

-- Owner backstop ticker: cancel a loan that never fulfills (timeout) or whose borrower left.
local loanTicker = CreateFrame("Frame")
loanTicker:Hide()
loanTicker:SetScript("OnUpdate", function(f, elapsed)
    f.accum = (f.accum or 0) + (elapsed or 1)
    if f.accum < 2 then return end
    f.accum = 0
    local loan = addon:ActiveMLLoan()
    if not loan or not addon:IsAuthorizedLootMaster() then f:Hide(); return end
    if GetTime() - (addon._loanStartedAt or 0) > LOAN_TIMEOUT then
        addon:EndMLLoan("timed out with no pickup")
    elseif addon.GetAttendee and not addon:GetAttendee(util:NormalizeKey(loan.borrower)) then
        addon:EndMLLoan(loan.borrower .. " left the raid")
    end
end)

-- Owner: lend the WoW ML role to `borrower` for one phantom lot's item. One loan at a time.
function addon:StartMLLoan(lotId, borrower)
    if not self:IsAuthorizedLootMaster() then return end
    if not borrower or borrower == "" then return end
    local existing = self:ActiveMLLoan()
    if existing then
        self:Print("A master-loot loan to " .. existing.borrower .. " is already active. /wl loan cancel first.")
        return
    end
    local lot = self.lootCore and self.lootCore:Get(lotId)
    if not lot or not lot.phantom then return end

    local session = self:GetCurrentSession()
    session.mlLoan = {
        owner = util:GetPlayerName("player"),
        borrower = borrower,
        itemId = lot.itemId,
        lotId = lotId,
    }
    self._loanStartedAt = GetTime()
    if self.phantomLoans and self.phantomLoans[lotId] then
        self.phantomLoans[lotId].target = borrower
    end
    self:AutoBroadcastSession(true)   -- loan rides the M line; force the full snapshot out NOW

    local _, link = util:ItemRender(lot.itemId)
    local shown = link or ("item " .. tostring(lot.itemId))
    if isSelfRaidLeader() then
        self._loanSwapAt = GetTime() + SWAP_DELAY
        self._loanSwapTo = borrower
        swapTimer:Show()
        self:Print("Lending master loot to " .. borrower .. " for " .. shown .. ". They loot it; the role comes back automatically.")
    else
        self:Print("Loan set for " .. shown .. ", but only the raid leader can swap the role: have them make " .. borrower .. " master looter now.")
    end
    loanTicker.accum = 0
    loanTicker:Show()
    if self.ShowPhantomLoanCard then self:ShowPhantomLoanCard(lotId) end
    if self.RefreshRollsLeftBanner then self:RefreshRollsLeftBanner() end
end

-- Owner: end the loan (fulfilled, cancelled, or backstopped) and take the WoW role back.
function addon:EndMLLoan(reason)
    local loan = self:ActiveMLLoan()
    if not loan then return end
    if not self:IsAuthorizedLootMaster() then return end

    local session = self:GetCurrentSession()
    session.mlLoan = nil
    self._loanStartedAt = nil
    self._loanSwapAt = nil
    self._loanSwapTo = nil
    loanTicker:Hide()
    self:AutoBroadcastSession(true)

    if isSelfRaidLeader() then
        if SetLootMethod then SetLootMethod("master", util:StripRealm(loan.owner)) end
    else
        self:Print("Loan ended: have the raid leader return master loot to " .. loan.owner .. ".")
    end
    self:Print("Master-loot loan to " .. loan.borrower .. " ended (" .. (reason or "done") .. ").")
    if loan.lotId and self.ShowPhantomLoanCard then self:ShowPhantomLoanCard(loan.lotId) end
    if self.RefreshRollsLeftBanner then self:RefreshRollsLeftBanner() end
end

-- Owner: the borrower reports the loaned item landed in their bags. Verify it is really them,
-- record the phantom award delivered (receiver = borrower), and wrap the loan up.
function addon:OnLoanDoneMessage(sender, fields)
    local loan = self:ActiveMLLoan()
    if not loan or not self:IsAuthorizedLootMaster() then return end
    if util:NormalizeKey(sender or "") ~= util:NormalizeKey(loan.borrower) then return end

    local lotId = loan.lotId
    if lotId then
        self:MarkPhantomAwardDelivered(lotId, loan.borrower)
        if self.phantomLoans then self.phantomLoans[lotId] = nil end
        local lot = self.lootCore and self.lootCore:Get(lotId)
        local _, link = lot and util:ItemRender(lot.itemId)
        self:Print((link or "The item") .. " picked up by " .. loan.borrower .. "; loan fulfilled.")
    end
    self:EndMLLoan("delivered")
end

-- ---------------------------------------------------------------------------
-- borrower side
-- ---------------------------------------------------------------------------

-- Leader-side popups: when the loan's owner is NOT the raid leader, only the leader can perform
-- the role swaps, so their client prompts on each loan TRANSITION: loan appeared -> "lend master
-- loot to <borrower>", loan cleared -> "return master loot to <owner>". The owner swaps
-- automatically (StartMLLoan/EndMLLoan) and is never prompted. Transition-tracked by the encoded
-- loan string so re-applied snapshots with the same loan never re-prompt. Called from
-- RefreshLootAuthority, which runs on both snapshot apply and roster events.
function addon:MaybePromptLeaderLoanSwap()
    local loan = self:ActiveMLLoan()
    local cur = loan and self:EncodeMLLoan(loan) or nil
    if cur == self._loanPrompted then return end
    local prevLoan = self._loanPrompted and self:DecodeMLLoan(self._loanPrompted) or nil
    self._loanPrompted = cur

    if not StaticPopup_Show or not isSelfRaidLeader() then return end
    local me = util:NormalizeKey(util:GetPlayerName("player") or "")
    if loan then
        if me == util:NormalizeKey(loan.owner) then return end
        local _, link = util:ItemRender(loan.itemId)
        local dialog = StaticPopup_Show("WEIRDLOOT_LOAN_SWAP", loan.borrower, link or "a quest drop")
        if dialog then dialog.data = util:StripRealm(loan.borrower) end
    elseif prevLoan then
        if me == util:NormalizeKey(prevLoan.owner) then return end
        StaticPopup_Hide("WEIRDLOOT_LOAN_SWAP")
        local dialog = StaticPopup_Show("WEIRDLOOT_LOAN_RESTORE", prevLoan.owner)
        if dialog then dialog.data = util:StripRealm(prevLoan.owner) end
    end
end

-- Am I the active loan's borrower (case-normalized)?
function addon:IsLoanBorrower(loan)
    loan = loan or self:ActiveMLLoan()
    if not loan then return false end
    return util:NormalizeKey(util:GetPlayerName("player") or "") == util:NormalizeKey(loan.borrower)
end

-- Borrower at the corpse: assign ONLY the loaned item to self; every other slot is untouched
-- (the borrower holds the WoW role, not the session, so general routing must not run).
function addon:BorrowerLoanPickup(loan)
    if not self:IsLoanBorrower(loan) then return end
    local selfIdx = self:FindMasterLootCandidate(UnitName("player"))
    if not selfIdx then return end
    for slot = 1, GetNumLootItems() do
        if LootSlotIsItem(slot) then
            local link = GetLootSlotLink(slot)
            local itemId = link and util:ItemIdFromLink(link)
            if itemId == loan.itemId then
                GiveMasterLoot(slot, selfIdx)
            end
        end
    end
end

-- Borrower acquisition watch (BAG_UPDATE): the loaned item is in our bags -> tell the owner once.
-- Also fires when the borrower picked the item up by plain (non-master) looting.
function addon:MaybeFulfillLoanPickup()
    local loan = self:ActiveMLLoan()
    if not loan or not self:IsLoanBorrower(loan) then
        self._loanDoneSent = nil
        return
    end
    if self._loanDoneSent == loan.itemId then return end
    if self:PlayerHoldsItem(loan.itemId) then
        self._loanDoneSent = loan.itemId
        self:SendLargeMessage("LOANDONE", { tostring(loan.itemId) }, "WHISPER", loan.owner, "ALERT")
        local _, link = util:ItemRender(loan.itemId)
        self:Print("You picked up " .. (link or "the loaned item") .. "; master loot returns to " .. loan.owner .. ".")
    end
end
