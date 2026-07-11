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
-- CRUDE: the roster contains only `name` + the running player, so with a loan active this also
-- exercises owner-left voiding. Use mockRoster/RAID3 when the whole group must stay present.
local function flipWoWMLTo(w, name)
    local player = w.player
    w.env.GetRaidRosterInfo = function(i)
        if i == 1 then return name, (name == player) and 2 or 0 end
        return player, 2
    end
    w.addon:RefreshLootAuthority()
end

-- A realistic 3-member roster whose master-looter index the test controls: members is an array of
-- { name, rank }, mlIndex points at the current WoW master looter. Applies + re-resolves.
local function mockRoster(w, members, mlIndex)
    w.env.GetNumRaidMembers = function() return #members end
    w.env.GetRaidRosterInfo = function(i)
        local m = members[i]
        if not m then return nil end
        return m.name, m.rank or 0
    end
    w.env.GetLootMethod = function() return "master", 0, mlIndex end
    w.addon:RefreshLootAuthority()
end
local RAID3 = { { name = "Masterlooter", rank = 2 }, { name = "Gorgarg" }, { name = "Saelinen" } }

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

H.test("invisible phantom resolve: pending loan, no corpse send, ONE loan candidate (the winner)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lot = w.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    w.addon:RegisterInterest(lot.id, "Lexissa", "os")   -- a losing roller must NOT appear as a loan choice
    local captured
    local orig = w.addon.AddLootBannerItem
    w.addon.AddLootBannerItem = function(self, item) captured = item; return orig(self, item) end
    w.addon:ResolveLiveRoll(lot.id)
    w.addon.AddLootBannerItem = orig

    H.check(w.addon.phantomLoans and w.addon.phantomLoans[lot.id] ~= nil, "pending loan registered")
    H.eq(w.addon.phantomLoans[lot.id].target, "Gorgarg", "loan targets the winner")
    H.check(not (w.addon.phantomSends and w.addon.phantomSends[lot.id]), "no corpse send for an invisible drop")
    H.check(w.addon:ActiveMLLoan() == nil, "the loan does NOT auto-start: the card click triggers it")
    H.check(captured ~= nil and captured.loanSend == true, "loan card shown with the loan action")
    H.eq(#(captured.candidates or {}), 1, "exactly one loan row: who was decided by the roll")
    H.eq(captured.candidates[1].name, "Gorgarg", "and it is the winner")
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

    -- clearing the loan enters ROLE IN TRANSIT: the owner keeps authority (continuity: heartbeats
    -- and resolves never stop during the swap-back) until the roster settles on them again
    w.addon:GetCurrentSession().mlLoan = nil
    w.addon:RefreshLootAuthority()
    H.check(w.addon:IsAuthorizedLootMaster(), "in transit: the owner retains authority until the roster settles")
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
    mockRoster(borrower, RAID3, 2)     -- the game names the borrower ML; the owner stays in raid
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

H.test("role swap is gated on the borrower's LOANREADY ack (the propagation-race fix)", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local borrower = makeWorld("Gorgarg", false)
    startSession(ml)
    local lot = ml.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    ml.addon:ResolveLiveRoll(lot.id)

    local swaps = {}
    ml.env.SetLootMethod = function(method, name) swaps[#swaps + 1] = { method = method, name = name } end
    local whispers = {}
    ml.env.ChatThrottleLib = nil
    ml.env.SendChatMessage = function(msg, _, _, target) whispers[#whispers + 1] = { msg = msg, target = target } end

    ml.addon:StartMLLoan(lot.id, "Gorgarg")
    H.eq(#swaps, 0, "NO swap at loan start: SetLootMethod must not race the snapshot")
    H.check(ml.addon._loanAwaitingReady ~= nil, "owner is waiting for the borrower's ack")

    ml.addon:OnLoanReadyMessage("Lexissa", { tostring(KEY_ID) })
    H.eq(#swaps, 0, "an imposter's ack is ignored")

    clearWire(); ml.addon:BroadcastSession(); flushWireTo(borrower)   -- loan lands -> borrower acks
    flushWireTo(ml)                                                   -- ack reaches the owner
    H.eq(#swaps, 1, "swap fired only after the borrower confirmed the loan")
    H.eq(swaps[1].name, "Gorgarg", "role handed to the borrower")
    H.eq(#whispers, 1, "borrower whispered their pickup instruction")
    H.check(whispers[1].target == "Gorgarg" and whispers[1].msg:find("master loot", 1, true) ~= nil,
        "whisper tells them to loot the item")
    H.check(not ml.addon._loanAwaitingReady, "ack consumed")
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

-- owner (ml world) + a synced bystander with a loan taken through start AND clear
local function bystanderThroughLoanClear()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local bystander = makeWorld("Saelinen", false)
    startSession(ml)
    local lot = ml.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    ml.addon:ResolveLiveRoll(lot.id)
    ml.addon:StartMLLoan(lot.id, "Gorgarg")
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(bystander)   -- loan seen: pin active
    mockRoster(bystander, RAID3, 2)          -- WoW role sits with the borrower, as in a real loan
    ml.addon:EndMLLoan("delivered")
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(bystander)   -- clear seen: transit armed
    return ml, bystander
end

H.test("role-in-transit: after the clear, only the owner's return is believed", function()
    local _, bystander = bystanderThroughLoanClear()

    -- clear applied while the roster still names the borrower: guard holds the script's answer
    H.eq(bystander.addon:GetLootMasterName(), "Masterlooter", "in transit: still answers the owner")
    H.check(not bystander.addon:IsAuthorizedLootMaster(), "in transit: no authority")

    -- the 3.3.5 transient: mid-shuffle the roster suddenly names the BYSTANDER themselves
    local epochBefore = bystander.addon.session.id
    mockRoster(bystander, RAID3, 3)
    H.check(not bystander.addon:IsAuthorizedLootMaster(), "poisoned self-read refused while in transit")
    H.eq(bystander.addon:GetLootMasterName(), "Masterlooter", "surprise authority not adopted")
    H.eq(bystander.addon.session.id, epochBefore, "no assume: no divergent epoch minted")

    -- the DISARM EVENT: the roster confirms the owner took the role back
    mockRoster(bystander, RAID3, 1)
    H.eq(bystander.addon:GetLootMasterName(), "Masterlooter", "restore landed")
    H.check(not bystander.addon:IsAuthorizedLootMaster(), "bystander is of course not the ML")

    -- guard is gone: a LATER genuine handoff to the bystander lands normally
    mockRoster(bystander, RAID3, 3)
    H.check(bystander.addon:IsAuthorizedLootMaster(), "a real promotion after the transit gains normally")
end)

H.test("owner leaving the raid voids an ACTIVE loan on every client", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Saelinen", false)
    startSession(ml)
    local lot = ml.addon.lootCore:MintPhantom(KEY_ID, 1)
    lot.invisibleToML = true
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:RegisterInterest(lot.id, "Gorgarg", "ms")
    ml.addon:ResolveLiveRoll(lot.id)
    ml.addon:StartMLLoan(lot.id, "Gorgarg")
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(raider)
    H.check(raider.addon:ActiveMLLoan() ~= nil, "loan mirrored")

    -- the owner drops from the raid; the raider's own roster observation voids the loan
    mockRoster(raider, { { name = "Gorgarg" }, { name = "Saelinen" } }, 1)
    H.check(raider.addon:ActiveMLLoan() == nil, "loan voided locally: no absent-owner pin")
end)

H.test("owner leaving during TRANSIT disarms the guard so manual recovery works", function()
    local _, bystander = bystanderThroughLoanClear()
    H.check(not bystander.addon:IsAuthorizedLootMaster(), "sanity: in transit, guard holding")

    -- owner gone AND the leader hands ML to the bystander: recovery must not be fought
    mockRoster(bystander, { { name = "Gorgarg" }, { name = "Saelinen", rank = 2 } }, 2)
    H.check(bystander.addon:IsAuthorizedLootMaster(), "guard disarmed on owner departure: recovery lands")
end)

H.test("a foreign seized epoch lifts the real ML's high-water (self-heal on next session)", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local seizer = makeWorld("Saelinen", false)
    startSession(ml)
    clearWire(); ml.addon:BroadcastSession(); flushWireTo(seizer)   -- live mirror on the seizer

    flipWoWMLTo(seizer, "Saelinen")                                  -- simulated pre-fix seizure
    H.check(seizer.addon:IsAuthorizedLootMaster(), "sanity: seizer became authority (no loan grace armed)")
    local seizedEpoch = tonumber(seizer.addon.session.id)
    H.check(seizedEpoch ~= nil, "sanity: seized session has a numeric epoch")

    clearWire(); seizer.addon:BroadcastSession(); flushWireTo(ml)    -- ml REJECTS it as foreign...
    H.eq(ml.addon:GetLootMasterName(), "Masterlooter", "ml did not adopt the foreign session")
    H.check((ml.addon.sessionDb.epochHigh or 0) >= seizedEpoch,
        "...but observed its epoch: the ml's next session out-ranks the seizure")
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
