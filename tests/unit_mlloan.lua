-- Unit tests for the ML LOAN (Loot/MLLoan.lua + the Roster.lua authority pin): an item-scoped
-- borrow of the WoW master-looter role so an eligible player can collect a quest-gated drop the
-- ML cannot see. Pins:
--   * while a loan is active the ADDON authority stays with the loan's OWNER even though the WoW
--     roster names the borrower (the whole reason the loan exists);
--   * the BORROWER never assumes the session when their WoW role flips (no epoch seizure, no
--     ledger reconcile, no false new-drop broadcast);
--   * the loan rides the session M-line: a synced raider mirrors it and pins the same owner;
--   * an invisible phantom resolve registers the pending loan; StartMLLoan stamps the session and
--     re-targets the pending loan; LOANDONE from the borrower (and ONLY the borrower) records the
--     phantom award delivered and ends the loan;
--   * the borrower's acquisition watch whispers LOANDONE exactly once, end to end over the wire.
--
-- Run from the addon dir:  luajit tests/unit_mlloan.lua

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("ML loan battery")

local makeWorld, startSession = F.makeWorld, F.startSession
local flushWireTo, clearWire = F.flushWireTo, F.clearWire

local KEY_ID = 44569   -- Key to the Focusing Iris (the canonical invisible drop)

-- Flip a world's WoW roster so `name` is the master looter at raid index 1 (rank keeps the
-- original leader semantics: the running player stays raid leader so SetLootMethod paths run).
local function flipWoWMLTo(w, name)
    local player = w.player
    w.env.GetRaidRosterInfo = function(i)
        if i == 1 then return name, (name == player) and 2 or 0 end
        return player, 2
    end
    w.addon:RefreshLootAuthority()
end

-- Owner world with an active session and a resolved invisible phantom owed to `winner`.
local function ownerWithInvisiblePhantom(winner)
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lot = w.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, winner, "ms")
    w.addon:ResolveLiveRoll(lot.id)
    return w, lot
end

H.test("invisible phantom resolve registers a pending loan, not a corpse send", function()
    local w, lot = ownerWithInvisiblePhantom("Gorgarg")
    H.check(w.addon.phantomLoans and w.addon.phantomLoans[lot.id] ~= nil, "pending loan registered")
    H.eq(w.addon.phantomLoans[lot.id].target, "Gorgarg", "loan targets the winner")
    H.check(not (w.addon.phantomSends and w.addon.phantomSends[lot.id]), "no corpse send for an invisible drop")
end)

H.test("StartMLLoan stamps the session; owner keeps authority when the WoW roster flips", function()
    local w, lot = ownerWithInvisiblePhantom("Gorgarg")
    w.addon:StartMLLoan(lot.id, "Gorgarg")
    local loan = w.addon:ActiveMLLoan()
    H.check(loan ~= nil, "loan active")
    H.eq(loan.owner, "Masterlooter", "owner recorded")
    H.eq(loan.borrower, "Gorgarg", "borrower recorded")
    H.eq(loan.itemId, KEY_ID, "itemId recorded")

    flipWoWMLTo(w, "Gorgarg")   -- the game role moves to the borrower
    H.check(w.addon:IsAuthorizedLootMaster(), "owner STAYS addon-authorized during the loan")
    H.eq(w.addon:GetLootMasterName(), "Masterlooter", "displayed ML stays the owner")

    -- and WITHOUT the loan the same flip would have dropped authority (the pin is the difference)
    w.addon:GetCurrentSession().mlLoan = nil
    w.addon:RefreshLootAuthority()
    H.check(not w.addon:IsAuthorizedLootMaster(), "sanity: same roster without the loan = no authority")
end)

H.test("borrower never assumes the session when their WoW role flips mid-loan", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local borrower = makeWorld("Gorgarg", false)
    startSession(ml)
    local lot = ml.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    ml.addon:ResolveLiveRoll(lot.id)
    ml.addon:StartMLLoan(lot.id, "Gorgarg")

    clearWire(); ml.addon:BroadcastSession(); flushWireTo(borrower)
    local mirrored = borrower.addon:ActiveMLLoan()
    H.check(mirrored ~= nil, "loan crossed the wire on the M line")
    H.eq(mirrored.owner, "Masterlooter", "owner mirrored")

    local epochBefore = borrower.addon.session.id
    flipWoWMLTo(borrower, "Gorgarg")   -- now the game names the borrower master looter
    H.check(not borrower.addon:IsAuthorizedLootMaster(), "borrower is NOT addon-authorized")
    H.eq(borrower.addon:GetLootMasterName(), "Masterlooter", "borrower still shows the owner as ML")
    H.eq(borrower.addon.session.id, epochBefore, "no session seizure: the epoch is untouched")
end)

H.test("LOANDONE from the borrower records the phantom delivery and ends the loan", function()
    local w, lot = ownerWithInvisiblePhantom("Gorgarg")
    w.addon:StartMLLoan(lot.id, "Gorgarg")

    -- an imposter's LOANDONE is ignored
    w.addon:OnLoanDoneMessage("Lexissa", { tostring(KEY_ID) })
    H.check(w.addon:ActiveMLLoan() ~= nil, "a non-borrower cannot fulfill the loan")

    w.addon:OnLoanDoneMessage("Gorgarg", { tostring(KEY_ID) })
    H.check(w.addon:ActiveMLLoan() == nil, "loan ended")
    local core = w.addon.lootCore
    local a = core:Get(lot.id).awards[1]
    H.eq(a.state, core.AWARD.DELIVERED, "phantom award delivered")
    H.eq(a.recipient, "Gorgarg", "actual recipient recorded")
    H.check(not (w.addon.phantomLoans and w.addon.phantomLoans[lot.id]), "pending loan cleared")
end)

H.test("borrower acquisition watch whispers LOANDONE once, end to end", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local borrower = makeWorld("Gorgarg", false)
    startSession(ml)
    local lot = ml.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    ml.addon:ResolveLiveRoll(lot.id)
    ml.addon:StartMLLoan(lot.id, "Gorgarg")
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(borrower)

    -- the loaned item lands in the borrower's bags
    borrower.addon.PlayerHoldsItem = function(self, id) return id == KEY_ID end
    clearWire()
    borrower.addon:MaybeFulfillLoanPickup()
    borrower.addon:MaybeFulfillLoanPickup()   -- a second BAG_UPDATE must not re-send
    flushWireTo(ml)

    H.check(ml.addon:ActiveMLLoan() == nil, "owner's loan fulfilled over the wire")
    local core = ml.addon.lootCore
    H.eq(core:Get(lot.id).awards[1].state, core.AWARD.DELIVERED, "delivery recorded on the owner")
    H.eq(borrower.addon._loanDoneSent, KEY_ID, "borrower marked the report sent (no re-send)")
end)

H.test("only one loan at a time; /wl loan cancel path clears it", function()
    local w, lot = ownerWithInvisiblePhantom("Gorgarg")
    w.addon:StartMLLoan(lot.id, "Gorgarg")
    local lot2 = w.addon.lootCore:MintPhantom(50505, 1)
    lot2.invisibleToML = true
    w.addon:StartMLLoan(lot2.id, "Lexissa")
    H.eq(w.addon:ActiveMLLoan().borrower, "Gorgarg", "second loan refused while one is active")

    w.addon:EndMLLoan("cancelled")
    H.check(w.addon:ActiveMLLoan() == nil, "cancel clears the loan")
end)

H.test("raid leader (not the owner) is prompted to swap on loan start and restore on loan end", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local leader = makeWorld("Leadguy", true)   -- rank 2 in the roster mock, but not the ML
    startSession(ml)
    local lot = ml.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    ml.addon:ResolveLiveRoll(lot.id)

    local shows = {}
    leader.env.StaticPopup_Show = function(which, a1) shows[#shows + 1] = { which = which, arg = a1 }; return {} end

    ml.addon:StartMLLoan(lot.id, "Gorgarg")
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(leader)
    H.eq(#shows, 1, "one popup on loan start")
    H.eq(shows[1].which, "WEIRDLOOT_LOAN_SWAP", "it is the swap prompt")
    H.eq(shows[1].arg, "Gorgarg", "prompting to lend to the borrower")

    clearWire(); ml.addon:BroadcastSession(); flushWireTo(leader)
    H.eq(#shows, 1, "same loan re-synced: no duplicate prompt")

    ml.addon:OnLoanDoneMessage("Gorgarg", { tostring(KEY_ID) })
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(leader)
    H.eq(#shows, 2, "one popup on loan end")
    H.eq(shows[2].which, "WEIRDLOOT_LOAN_RESTORE", "it is the restore prompt")
    H.eq(shows[2].arg, "Masterlooter", "prompting to return the role to the owner")
end)

H.test("LC-ruled phantom: the council award engages the pickup machinery (loan or send)", function()
    -- invisible phantom + LC rule: awarding via the LC flyout must register the pending LOAN
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lot = w.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    local itemName = (w.addon.util:ItemRender(KEY_ID))
    H.check(w.addon:SetSessionLCOverride(itemName, "lc"), "LC override set on the item")
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    H.check(lot.record and lot.record.isLootCouncil, "sanity: the lot resolved as loot council")
    H.check(not (w.addon.phantomLoans and w.addon.phantomLoans[lot.id]), "no loan before the council picks")

    w.addon:AwardLootCouncilCopy(lot.id, "Gorgarg")
    H.check(w.addon.phantomLoans and w.addon.phantomLoans[lot.id] ~= nil, "council pick registered the pending loan")
    H.eq(w.addon.phantomLoans[lot.id].target, "Gorgarg", "loan targets the council's pick")

    -- visible phantom + LC rule: the same award registers a corpse SEND instead
    local w2 = makeWorld("Masterlooter", true)
    startSession(w2)
    local lot2 = w2.addon.lootCore:MintPhantom(50510, 1)
    local itemName2 = (w2.addon.util:ItemRender(50510))
    H.check(w2.addon:SetSessionLCOverride(itemName2, "lc"), "LC override set on the unique")
    w2.addon:StartLiveRoll(lot2.id)
    w2.addon:RegisterInterest(lot2.id, "Lexissa", "ms")
    w2.addon:ResolveLiveRoll(lot2.id)
    w2.addon:AwardLootCouncilCopy(lot2.id, "Lexissa")
    H.check(w2.addon.phantomSends and w2.addon.phantomSends[lot2.id] ~= nil, "council pick registered the corpse send")
    H.check(not (w2.addon.phantomLoans and w2.addon.phantomLoans[lot2.id]), "no loan for a visible phantom")
end)

H.test("loan encode/decode round-trips (including no-loan and older-client absence)", function()
    local w = makeWorld("Masterlooter", true)
    local loan = { owner = "Masterlooter", borrower = "Gorgarg", itemId = KEY_ID, lotId = "L:7" }
    local decoded = w.addon:DecodeMLLoan(w.addon:EncodeMLLoan(loan))
    H.eq(decoded.owner, "Masterlooter", "owner round-trips")
    H.eq(decoded.borrower, "Gorgarg", "borrower round-trips")
    H.eq(decoded.itemId, KEY_ID, "itemId round-trips")
    H.eq(decoded.lotId, "L:7", "lotId round-trips")
    H.eq(w.addon:EncodeMLLoan(nil), "", "no loan encodes empty")
    H.eq(w.addon:DecodeMLLoan(""), nil, "empty decodes to no loan")
    H.eq(w.addon:DecodeMLLoan(nil), nil, "missing field (older ML) decodes to no loan")
end)

F.endSuite()
