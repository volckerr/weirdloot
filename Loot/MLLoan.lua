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

local LOAN_TIMEOUT = 180      -- seconds before an unfulfilled loan auto-cancels (owner side)
local READY_NAG_AFTER = 10    -- seconds without the borrower's LOANREADY before telling the owner to swap manually

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

-- True when `name` holds the ACTUAL WoW master-looter role, read raw from the API. Deliberately
-- bypasses the addon's resolved view: during a loan and the transit window that view answers the
-- loan's owner regardless of who really holds the role, and these callers need the real holder to
-- know whether the role ever moved (the swap is ack/human-gated, so a cancel often lands before
-- it ran). False when the holder cannot be read, so callers err toward acting.
local function rawWoWMasterLooterIs(name)
    local method, partyIdx, raidIdx = GetLootMethod()
    if method ~= "master" then return false end
    local holder
    if raidIdx and raidIdx > 0 then
        holder = GetRaidRosterInfo(raidIdx)
    elseif partyIdx == 0 then
        holder = UnitName("player")
    elseif partyIdx and partyIdx > 0 then
        holder = UnitName("party" .. partyIdx)
    end
    return holder ~= nil
        and util:NormalizeKey(util:StripRealm(holder)) == util:NormalizeKey(util:StripRealm(name or ""))
end

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
    elseif addon._loanAwaitingReady and not addon._loanReadyNagged
        and GetTime() - (addon._loanStartedAt or 0) > READY_NAG_AFTER then
        -- an older-version borrower never acks: fall back to the manual path that works on
        -- human latency (the snapshot has long since landed by the time a person reacts)
        addon._loanReadyNagged = true
        addon:Print(loan.borrower .. " has not confirmed the loan (older WeirdLoot?). Have the raid leader make them master looter by hand; they then loot the item normally.")
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
    self:LogCoreEvent("loan-start", { borrower = borrower, item = lot.itemId, lot = lotId })
    -- The role swap is GATED on the borrower's LOANREADY ack (OnLoanReadyMessage): SetLootMethod
    -- flips the roster near-instantly while the loan snapshot crawls the throttled comm lane, so
    -- swapping on a timer races the propagation -- a borrower whose roster flips first has no pin
    -- yet and seizes the session, minting the whole corpse as fresh drops. The ack is proof the
    -- pin is live on the one client where it matters.
    self._loanAwaitingReady = true
    self._loanReadyNagged = nil
    if self.phantomLoans and self.phantomLoans[lotId] then
        self.phantomLoans[lotId].target = borrower
    end
    self:AutoBroadcastSession(true)   -- loan rides the M line; force the full snapshot out NOW

    local _, link = util:ItemRender(lot.itemId)
    local shown = link or ("item " .. tostring(lot.itemId))
    if isSelfRaidLeader() then
        self:Print("Lending master loot to " .. borrower .. " for " .. shown .. ": waiting for their addon to confirm, then the role swaps automatically.")
    else
        self:Print("Loan set for " .. shown .. ": once " .. borrower .. " confirms, have the raid leader make them master looter (they will be prompted).")
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
    self._loanAwaitingReady = nil
    self._loanReadyNagged = nil
    loanTicker:Hide()
    self:AutoBroadcastSession(true)

    -- Only touch the role when it actually moved: a cancel before the ack/human-gated swap ran
    -- leaves master loot with the owner, so re-issuing SetLootMethod would churn a loot-method
    -- event for the whole raid and the "have the leader return it" print would be noise.
    local moved = not rawWoWMasterLooterIs(loan.owner)
    local swapped = false
    if moved then
        if isSelfRaidLeader() then
            if SetLootMethod then SetLootMethod("master", util:StripRealm(loan.owner)); swapped = true end
        else
            self:Print("Loan ended: have the raid leader return master loot to " .. loan.owner .. ".")
        end
    end
    self:LogCoreEvent("loan-end", { reason = reason or "done", borrower = loan.borrower,
        moved = moved and 1 or 0, swap = swapped and 1 or 0 })
    self:Print("Master-loot loan to " .. loan.borrower .. " ended (" .. (reason or "done") .. ").")
    if loan.lotId and self.ShowPhantomLoanCard then self:ShowPhantomLoanCard(loan.lotId) end
    if self.RefreshRollsLeftBanner then self:RefreshRollsLeftBanner() end
end

-- Owner: the borrower reports the loaned item landed in their bags. Verify it is really them,
-- record the phantom award delivered (receiver = borrower), and wrap the loan up.
--
-- A LOANDONE can legitimately arrive when it no longer matches the active loan: the borrower's
-- pickup racing a cancel/timeout (the loan cleared while the whisper was in flight), or a later
-- loan already running. The pending-loan registry (phantomLoans: minted at award time, cleared
-- only by a recorded delivery) still knows the lot, so settle off it instead of dropping the
-- whisper and stranding the award as owed forever. The registry path skips the authority gate
-- deliberately: after a cancel the 60s transit escape hatch may have handed the roster answer
-- back to the borrower, but the delivery record is local ML bookkeeping (disposition is never
-- wire-carried), and the registry only exists on the client that awarded the lot.
function addon:OnLoanDoneMessage(sender, fields)
    local itemId = tonumber(fields and fields[1])
    local senderKey = util:NormalizeKey(sender or "")
    local loan = self:ActiveMLLoan()

    if loan and senderKey == util:NormalizeKey(loan.borrower)
        and (not itemId or itemId == loan.itemId) then
        if not self:IsAuthorizedLootMaster() then return end
        self:LogCoreEvent("loan-done", { from = sender, item = itemId, via = "live" })
        local lotId = loan.lotId
        if lotId then
            self:MarkPhantomAwardDelivered(lotId, loan.borrower)
            if self.phantomLoans then self.phantomLoans[lotId] = nil end
            local lot = self.lootCore and self.lootCore:Get(lotId)
            local _, link = lot and util:ItemRender(lot.itemId)
            self:Print((link or "The item") .. " picked up by " .. loan.borrower .. "; loan fulfilled.")
        end
        self:EndMLLoan("delivered")
        return
    end

    -- No/other loan active: a registered pending loan whose target is the sender and whose item
    -- matches is the same proof of identity the live path uses. Settle that lot; never touch a
    -- different loan that may be running.
    for lotId, pending in pairs(self.phantomLoans or {}) do
        if pending.itemId == itemId and util:NormalizeKey(pending.target or "") == senderKey then
            self:LogCoreEvent("loan-done", { from = sender, item = itemId, via = "registry", lot = lotId })
            self:MarkPhantomAwardDelivered(lotId, pending.target)
            self.phantomLoans[lotId] = nil
            local _, link = util:ItemRender(itemId)
            self:Print((link or "The item") .. " picked up by " .. pending.target .. "; owed copy settled (the loan had already ended).")
            if self.ShowPhantomLoanCard then self:ShowPhantomLoanCard(lotId) end
            if self.RefreshRollsLeftBanner then self:RefreshRollsLeftBanner() end
            return
        end
    end
    self:LogCoreEvent("loan-done", { from = sender, item = itemId, via = "unmatched" })
end

-- ---------------------------------------------------------------------------
-- borrower side
-- ---------------------------------------------------------------------------

-- Loan-transition reactions on every client, called from RefreshLootAuthority (which runs on both
-- snapshot apply and roster events). Transition-tracked by the encoded loan string so re-applied
-- snapshots with the same loan never re-fire.
--   * BORROWER, loan appeared: whisper LOANREADY back to the owner. This ack is the swap gate:
--     it proves the authority pin is live on the borrower BEFORE the roster flips.
--   * RAID LEADER (not the owner), loan appeared/cleared: popup to perform the role swap /
--     restore (only the leader can SetLootMethod; the owner-is-leader case swaps automatically).
function addon:MaybePromptLeaderLoanSwap()
    local loan = self:ActiveMLLoan()
    local cur = loan and self:EncodeMLLoan(loan) or nil
    if cur == self._loanPrompted then return end
    local prevLoan = self._loanPrompted and self:DecodeMLLoan(self._loanPrompted) or nil
    self._loanPrompted = cur

    local me = util:NormalizeKey(util:GetPlayerName("player") or "")
    if loan and me == util:NormalizeKey(loan.borrower) then
        local _, link = util:ItemRender(loan.itemId)
        self:SendLargeMessage("LOANREADY", { tostring(loan.itemId) }, "WHISPER", loan.owner, "ALERT")
        self:Print("You are being lent master loot for " .. (link or "a quest drop") .. ". Loot it off the corpse once the role lands; it returns automatically.")
    end

    if not StaticPopup_Show or not isSelfRaidLeader() then return end
    if loan then
        if me == util:NormalizeKey(loan.owner) then return end
        local _, link = util:ItemRender(loan.itemId)
        local dialog = StaticPopup_Show("WEIRDLOOT_LOAN_SWAP", loan.borrower, link or "a quest drop")
        if dialog then dialog.data = util:StripRealm(loan.borrower) end
    elseif prevLoan then
        if me == util:NormalizeKey(prevLoan.owner) then return end
        StaticPopup_Hide("WEIRDLOOT_LOAN_SWAP")
        -- Prompt the restore only when the role actually moved: a loan cancelled before the
        -- leader ever performed the swap leaves master loot with the owner, and asking to
        -- "return master loot" to the person who holds it is a no-op prompt.
        if rawWoWMasterLooterIs(prevLoan.owner) then
            self:LogCoreEvent("loan-restore-prompt", { owner = prevLoan.owner, shown = 0 })
            return
        end
        self:LogCoreEvent("loan-restore-prompt", { owner = prevLoan.owner, shown = 1 })
        local dialog = StaticPopup_Show("WEIRDLOOT_LOAN_RESTORE", prevLoan.owner)
        if dialog then dialog.data = util:StripRealm(prevLoan.owner) end
    end
end

-- Owner: the borrower's client confirmed it holds the loan (the pin is live). NOW the role swap
-- is safe: perform it if we are the leader, and whisper the borrower their pickup instruction.
function addon:OnLoanReadyMessage(sender, fields)
    local loan = self:ActiveMLLoan()
    if not loan or not self:IsAuthorizedLootMaster() then return end
    if not self._loanAwaitingReady then return end
    if util:NormalizeKey(sender or "") ~= util:NormalizeKey(loan.borrower) then
        self:LogCoreEvent("loan-ready", { from = sender, ok = 0 })
        return
    end
    self._loanAwaitingReady = nil
    self:LogCoreEvent("loan-ready", { from = sender, ok = 1, swap = isSelfRaidLeader() and 1 or 0 })

    local lot = self.lootCore and loan.lotId and self.lootCore:Get(loan.lotId)
    local _, link = util:ItemRender((lot and lot.itemId) or loan.itemId)
    local shown = link or "the quest drop"
    if isSelfRaidLeader() then
        if SetLootMethod then SetLootMethod("master", util:StripRealm(loan.borrower)) end
        util:WhisperChat(loan.borrower, "You have been lent master loot: loot " .. shown .. " from the corpse now. The role returns automatically once you have it.")
        self:Print(loan.borrower .. " confirmed the loan; master loot handed over.")
    else
        util:WhisperChat(loan.borrower, "You are getting master loot to pick up " .. shown .. ": loot it from the corpse as soon as the leader swaps you in.")
        self:Print(loan.borrower .. " confirmed the loan; the raid leader can swap now (they are prompted).")
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
