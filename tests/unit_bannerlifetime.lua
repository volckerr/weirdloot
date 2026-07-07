-- Loot banner close-button battery. Drives the REAL UI/LootBanner.lua win-row engine (loaded into a
-- mocked world via F.loadBanner) and asserts the manual-close (X) timing end to end. No production
-- code is stubbed for this -- only the frame mock now models Show/Hide/IsShown so a row's close
-- button state can be read. Covers:
--   * a normal auto-hiding row never shows the X and fades away,
--   * the loot master's never-auto-hide row shows the X immediately and never fades on its own,
--   * a held-open row on a client with auto-hide off shows the X only after the examine window +
--     fade margin, and stays alive,
--   * fresh loot extends the window and re-hides the X,
--   * clicking the X dismisses that one row.

local F = dofile("tests/_framework.lua").get()
F.beginSuite("loot banner close-button battery")
local test, eq, check = F.test, F.eq, F.check

local WON = {
    link = "|cffa335ee|Hitem:40005:0:0:0:0:0:0:0|h[Blade of Test]|h|r", icon = "x", quantity = 1,
    winners = { { name = "Alice", class = "Mage", roll = 50, section = "MS" } },
}

local function awarded(w) return w.env.WeirdLootAwardedBanner end

local function firstWonRow(w)
    for _, f in ipairs(awarded(w).LootFrames) do
        if f.alive and not f.rollDuration then return f end
    end
end

local function pumpN(w, dt, n)
    for _ = 1, (n or 1) do F.pump(w, dt) end
end

-- Add a win item and advance the (instant) intro state machine into LOOT_INSERT with negligible
-- time cost, so the row exists with its timer barely touched. Returns the row frame.
local function showWonRow(w)
    w.addon:AddLootBannerItem(WON)
    for _ = 1, 60 do
        F.pump(w, 0.001)
        if firstWonRow(w) then break end
    end
    return firstWonRow(w)
end

-- Instant animations (0-duration intro/fade) make the state machine deterministic under pump().
local function bannerWorld(isML, setup)
    local w = F.makeWorld(isML and "BannerML" or "BannerR", isML)
    F.loadBanner(w)
    local opt = w.addon.db.options
    opt.bannerInstant = true
    if setup then setup(opt) end
    return w
end

test("loot master never-auto-hide: the close button shows immediately and the row never auto-fades", function()
    local w = bannerWorld(true, function(opt)
        opt.forceKeepResultPopup = true
        opt.resultPopupAutoCloseEnabled = true
        opt.resultPopupAutoCloseSeconds = 10
    end)
    local row = showWonRow(w)
    check(row and row.holdOpen, "the ML's win row is held open")
    check(row.closeImmediate, "and flagged for immediate close")
    check(row.CloseButton:IsShown(), "the close button is shown right away, no examine wait")
    pumpN(w, 1.0, 15)   -- 15s, well past any examine window
    check(row.alive, "the held-open row does not auto-fade")
    check(row.CloseButton:IsShown(), "the close button stays shown")
end)

test("auto-hide off (non-ML): the close button appears only after the examine window + fade, row stays", function()
    local w = bannerWorld(false, function(opt)
        opt.resultPopupAutoCloseEnabled = false   -- held open, but not the ML-keep case
        opt.resultPopupAutoCloseSeconds = 10
    end)
    local row = showWonRow(w)
    check(row.holdOpen and not row.closeImmediate, "held open, not immediate")
    check(not row.CloseButton:IsShown(), "close button hidden during the examine window")
    pumpN(w, 1.0, 6)    -- ~6s: still inside the 10s window
    check(not row.CloseButton:IsShown(), "still hidden mid-window")
    pumpN(w, 1.0, 6)    -- ~12s: past window + fade margin
    check(row.alive, "the row is still alive (held open, no auto-fade)")
    check(row.CloseButton:IsShown(), "close button armed once the window + fade lapsed")
end)

test("normal auto-hide: no close button, the row fades and is removed", function()
    local w = bannerWorld(false, function(opt)
        opt.resultPopupAutoCloseEnabled = true
        opt.resultPopupAutoCloseSeconds = 5
    end)
    local row = showWonRow(w)
    check(not row.holdOpen, "a normal auto-hiding row is not held open")
    check(not row.CloseButton:IsShown(), "no close button while it counts down")
    pumpN(w, 1.0, 8)    -- past 5s + fade
    check(not row.alive, "the row auto-faded and was removed")
    check(not row.CloseButton:IsShown(), "still no close button")
end)

test("fresh loot extends the window and re-hides the close button", function()
    local w = bannerWorld(false, function(opt)
        opt.resultPopupAutoCloseEnabled = false
        opt.resultPopupAutoCloseSeconds = 10
    end)
    local row = showWonRow(w)
    pumpN(w, 1.0, 12)   -- past the window: X armed
    check(row.CloseButton:IsShown(), "close button armed after the window lapsed")
    w.addon:AddLootBannerItem(WON)   -- a new win lands (no key -> not deduped)
    pumpN(w, 0.02, 3)   -- process the insert + a lifetime tick
    check(row.timeLeft > 0, "the older row's window was extended back above zero")
    check(row.timeLeft <= 10, "the extension is capped at the examine window")
    check(not row.CloseButton:IsShown(), "the close button re-hid while re-examining")
end)

test("clicking the close button dismisses that row", function()
    local w = bannerWorld(true, function(opt)
        opt.forceKeepResultPopup = true
        opt.resultPopupAutoCloseEnabled = true
        opt.resultPopupAutoCloseSeconds = 10
    end)
    local row = showWonRow(w)
    check(row.CloseButton:IsShown(), "ML close button shown")
    local onClick = row.CloseButton:GetScript("OnClick")
    check(type(onClick) == "function", "the close button has an OnClick handler")
    onClick(row.CloseButton)
    pumpN(w, 0.05, 3)   -- instant fade -> removed
    check(not row.alive, "the row was dismissed and removed")
end)

test("no-winner card: shows a reroll button that fires its callback and dismisses the card", function()
    local w = bannerWorld(true, function(opt)
        opt.forceKeepResultPopup = true
        opt.resultPopupAutoCloseEnabled = true
        opt.resultPopupAutoCloseSeconds = 10
    end)
    local fired = false
    w.addon:AddLootBannerItem({
        link = WON.link, icon = "x", quantity = 1, noWinner = true,
        onReroll = function() fired = true end,
    })
    local row
    for _ = 1, 60 do
        F.pump(w, 0.001)
        row = firstWonRow(w)
        if row then break end
    end
    check(row, "the no-winner card was shown")
    check(row.RerollButton:IsShown(), "the reroll button is shown on a no-winner card")
    local onClick = row.RerollButton:GetScript("OnClick")
    check(type(onClick) == "function", "the reroll button has an OnClick handler")
    onClick(row.RerollButton)
    check(fired, "clicking reroll fired the callback")
    pumpN(w, 0.05, 3)   -- instant fade -> removed
    check(not row.alive, "the card dismissed itself after reroll")
end)

test("reused slot resets the won-card button alpha (stale-fade translucency guard)", function()
    -- A pooled slot whose previous life faded leaves its close/reroll button at a partial alpha.
    -- Every other button gets a SetAlpha(1) on reuse; these two must too, or they render translucent.
    local w = bannerWorld(true, function(opt)
        opt.forceKeepResultPopup = true
        opt.resultPopupAutoCloseEnabled = true
        opt.resultPopupAutoCloseSeconds = 10
    end)
    local row = showWonRow(w)
    check(row.CloseButton:IsShown(), "the ML win card shows its close button")
    -- simulate the stale fade alpha a prior occupant of this slot would leave behind
    row.CloseButton:SetAlpha(0.25)
    row.RerollButton:SetAlpha(0.25)
    -- dismiss it so the slot goes dead and is first in line for reuse
    row.CloseButton:GetScript("OnClick")(row.CloseButton)
    pumpN(w, 0.05, 3)
    check(not row.alive, "the slot was freed")
    check(row.CloseButton.__alpha < 1, "sanity: the freed slot still carries the stale button alpha")
    -- a fresh win reuses that dead slot
    w.addon:AddLootBannerItem(WON)
    pumpN(w, 0.01, 5)
    local reused = firstWonRow(w)
    check(reused == row, "the new win reused the freed slot")
    check(reused.CloseButton.__alpha == 1, "the close button alpha was reset to 1 on reuse")
    check(reused.RerollButton.__alpha == 1, "the reroll button alpha was reset to 1 on reuse")
end)

test("drops banner (roll cards) sits a clear band above the awarded banner (win cards)", function()
    -- The two banners overlap in one region (awarded pulled up into the drops footer). Regression
    -- for the cross-banner layering bug where a win card's bg tint covered a roll card's countdown
    -- bar: the drops banner must outrank the awarded banner by a wide enough margin that every roll
    -- row (and its child widgets) stays above every win row.
    local w = bannerWorld(true)
    local drops = w.env.WeirdLootDropsBanner:GetFrameLevel()
    local awarded = w.env.WeirdLootAwardedBanner:GetFrameLevel()
    check(drops > awarded + 30,
        "drops banner level (" .. drops .. ") outranks awarded (" .. awarded .. ") by a full band")
end)

F.endSuite()
