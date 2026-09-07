-- WeirdLoot minimap button + the circular "loot owed to you" sparkle glow. Pure presentation;
-- pulls getOptions from the addon.UI namespace defined in UI.lua.
local addon = WeirdLoot
local util = addon.util
local UI = addon.UI
local getOptions = UI.getOptions

-- Circular sparkle orbit for the "loot owed to you" minimap glow. Self-contained (no AutoCastShine,
-- which orbits the square button edge, and no WeakAuras/LibCustomGlow, whose sparkle path is also
-- rectangular and whose texture ships under the WeakAuras addon). We place N sparkles on a CIRCLE via
-- cos/sin and spin the ring; each sparkle twinkles in size/alpha. Sparkle art is the Blizzard autocast
-- shine sub-region of UI-ItemSockets, always present.
local SHINE_TEXTURE = "Interface\\ItemSocketingFrame\\UI-ItemSockets"
local SHINE_TCOORD  = { 0.3984375, 0.4453125, 0.40234375, 0.44921875 }
local SHINE_COUNT   = 10
local SHINE_COLOR   = { 0.95, 0.9, 0.35 }   -- warm gold ("loot")
local ATTENTION_COLOR = { 1, 0.25, 0.25 }   -- red ("roster needs fixing")
local SHINE_REV_PER_SEC = 0.32              -- ring spin speed (owed mode)
local ATTENTION_PULSE_PER_SEC = 0.9         -- ring breathe speed (attention mode)
local TWO_PI = math.pi * 2

-- Two modes on the one ring: "owed" spins the sparkles around the button (the loot signal);
-- "attention" holds them at fixed angles and breathes the whole ring larger/smaller (roster
-- data needs fixing -- deliberately a different motion so the two states read differently
-- at a glance even in the same color-blind palette).
local function shineOnUpdate(shine, elapsed)
    local now = (GetTime and GetTime()) or 0
    local n = #shine.sparkles
    local baseRadius = (shine:GetWidth() or 31) / 2 + 1

    if shine.mode == "attention" then
        local breathe = math.sin(now * ATTENTION_PULSE_PER_SEC * TWO_PI)
        local radius = baseRadius + 2.5 * breathe
        local sz = 8 + 3 * (0.5 + 0.5 * breathe)
        for i = 1, n do
            local a = (i - 1) * (TWO_PI / n)
            local s = shine.sparkles[i]
            s:SetPoint("CENTER", shine, "CENTER", math.cos(a) * radius, math.sin(a) * radius)
            s:SetAlpha(0.6 + 0.4 * (0.5 + 0.5 * breathe))
            s:SetWidth(sz); s:SetHeight(sz)
        end
        return
    end

    shine.angle = (shine.angle + elapsed * SHINE_REV_PER_SEC * TWO_PI) % TWO_PI
    for i = 1, n do
        local a = shine.angle + (i - 1) * (TWO_PI / n)
        local s = shine.sparkles[i]
        s:SetPoint("CENTER", shine, "CENTER", math.cos(a) * baseRadius, math.sin(a) * baseRadius)
        local tw = 0.5 + 0.5 * math.sin(now * 3 + i)   -- per-sparkle twinkle
        s:SetAlpha(0.35 + 0.65 * tw)
        local sz = 7 + 4 * tw
        s:SetWidth(sz); s:SetHeight(sz)
    end
end

-- The angle is ACCOUNT-wide (like Outfitter's), so alts share one spot instead of each starting at
-- the default. Carries over an angle saved under the older per-character options once.
local function minimapAngle()
    local db = addon.db
    if db.minimapButtonAngle == nil then
        db.minimapButtonAngle = tonumber(getOptions(addon).minimapButtonAngle)
    end
    return tonumber(db.minimapButtonAngle) or 200
end

local function positionMinimapButton(button)
    local angle = minimapAngle()
    local rad = math.rad(angle)
    local radius = 80
    local x = math.cos(rad) * radius
    local y = math.sin(rad) * radius
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function addon:BuildMinimapButton()
    if self.ui.minimapButton then return end
    if not Minimap then return end

    -- Parented to MinimapBackdrop, not Minimap (Outfitter's choice): minimap addons that collect,
    -- hide or re-anchor "addon buttons" do it by iterating Minimap's child Buttons, and a button one
    -- level up is left alone. Anchoring is still to Minimap's center, so it follows a moved/resized map.
    local button = CreateFrame("Button", "WeirdLootMinimapButton", MinimapBackdrop or Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    button:SetWidth(31)
    button:SetHeight(31)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("RightButton")    -- left-click trades (when owed) else toggles; right-click toggles; right-drag repositions
    button:SetMovable(true)

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)

    -- BORDER layer (below ARTWORK) so the not-accepting-trades X, which lives on ARTWORK, draws
    -- cleanly ABOVE the icon. Same-layer ordering is creation-order and unreliable in 3.3.5a, so we
    -- separate them by layer instead: icon (BORDER) < X (ARTWORK) < tracking border (OVERLAY).
    local icon = button:CreateTexture(nil, "BORDER")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetTexture("Interface\\AddOns\\WeirdLoot\\Textures\\weirdloot")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)
    icon:SetTexCoord(0, 1, 0, 1)
    button.icon = icon   -- kept so UpdateMinimapMLActive can desaturate it when no ML is in play

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints(button)

    button:SetScript("OnClick", function(selfBtn, mouseButton)
        -- Attention state: the button is an alarm, so the click is the shortcut to the fix --
        -- a LEFT-click jumps straight to the Roster tab. Outranks the owed-trade and
        -- trade-toggle left-clicks while red (those resume once the roster is clean); the
        -- state only exists for people who can edit (see RefreshMinimapShine), so the jump
        -- always lands somewhere actionable. Right-click keeps the plain window toggle.
        local shine = addon.ui.minimapShine
        if mouseButton == "LeftButton" and shine and shine.mode == "attention" then
            addon:SelectTab("raiders", true)
            if not (addon.ui.frame and addon.ui.frame:IsShown()) then
                addon:ToggleMainFrame()
            end
            return
        end

        -- Owed raiders: a LEFT-click drives the whole delivery in two presses and never opens the window
        -- (use a right-click for that). First press opens the trade with the loot master (their side
        -- auto-fills the owed loot); a second press, once the trade window is up, ACCEPTS it. AcceptTrade
        -- needs a hardware event -- an OnClick is one -- so the second minimap click completes the trade
        -- where a timer never could. We can't target by name on 3.3.5a, but InitiateTrade takes a unit
        -- (the ML's loot-method unit). The ML never gets this path (they hold the loot).
        if mouseButton == "LeftButton"
           and not addon:IsAuthorizedLootMaster() and (addon:CountLootOwedToMe() or 0) > 0 then
            if TradeFrame and TradeFrame:IsShown() then
                -- only accept when the open trade is actually with the ML, so the loot button never
                -- accidentally confirms some other trade.
                if util:NormalizeKey(UnitName("NPC") or "") == util:NormalizeKey(addon:GetLootMasterName() or "") then
                    AcceptTrade()
                end
            else
                local mlUnit = addon:GetLootMasterUnit()
                if mlUnit and CheckInteractDistance(mlUnit, 2) then   -- 2 = trade range
                    InitiateTrade(mlUnit)
                end
            end
            return   -- owed left-click is trade-only; do NOT fall through to the window toggle
        end

        -- Loot master mirror of the owed-raider left-click: while a session is live, a LEFT-click
        -- toggles incoming trades (auto-decline on/off) instead of toggling the window. The window is
        -- still one right-click away. Payout mode is untouched -- that lives on the master tab.
        if mouseButton == "LeftButton" and addon:IsAuthorizedLootMaster() then
            local session = addon:GetCurrentSession()
            if session and session.active then
                addon:ToggleAllowAllTrades()
                -- the pointer is still over the button, so rebuild the (already-open) tooltip in place
                -- to reflect the flipped state; otherwise it stays stale and the ML misses the change.
                if GameTooltip:IsOwned(selfBtn) then selfBtn:GetScript("OnEnter")(selfBtn) end
                return
            end
        end

        -- Right-click, or a left-click with nothing owed: toggle the window. Opening with loot owed jumps
        -- straight to Loot Results; otherwise open the last-used tab. Read the remembered tab (db) for the
        -- non-owed case so a prior owed jump (which uses a transient select) never becomes the "last" tab.
        if not (addon.ui.frame and addon.ui.frame:IsShown()) then
            local target = ((addon:CountLootOwedToMe() or 0) > 0) and "results"
                or (addon.db.ui.selectedTab or "loot")
            addon:SelectTab(target, true)
        end
        addon:ToggleMainFrame()
    end)

    button:SetScript("OnEnter", function(selfBtn)
        -- Pin the tooltip's top to the button's bottom-left so a growing owed-items list extends
        -- DOWNWARD (and to the left, where there's room for a top-right minimap) instead of creeping up.
        GameTooltip:SetOwner(selfBtn, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPRIGHT", selfBtn, "BOTTOMLEFT", 0, 0)
        GameTooltip:AddLine("WeirdLoot " .. tostring(addon.version or "?"), 1, 0.82, 0)

        if not addon:IsLootMasterActive() then
            GameTooltip:AddLine("No active loot master", 0.6, 0.6, 0.6)
        end

        if addon:ShouldWarnMLNotAcceptingTrades() then
            GameTooltip:AddLine("ML is not accepting trades", 1, 0.2, 0.2)
        end

        -- Roster attention: shown only to people who can fix it, naming exactly what's
        -- missing per member so the hover answers "why is my button red?" completely.
        if addon.CanEditRoster and addon:CanEditRoster() then
            local attention = addon:GetRosterAttentionList()
            if #attention > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Roster needs attention:", 1, 0.3, 0.3)
                local shown = math.min(#attention, 8)
                for i = 1, shown do
                    local a = attention[i]
                    local missing = {}
                    if a.missingSpec then missing[#missing + 1] = "set spec" end
                    if a.unknownStatus then missing[#missing + 1] = "unknown status" end
                    GameTooltip:AddLine("  " .. util:TitleCaseWords(a.name or "?") .. " - " .. table.concat(missing, ", "), 1, 0.5, 0.5)
                end
                if #attention > shown then
                    GameTooltip:AddLine(string.format("  ...and %d more", #attention - shown), 1, 0.5, 0.5)
                end
            end
        end

        local owed = addon:GetLootOwedToMe()
        local ml = addon:GetLootMasterName()
        local session = addon:GetCurrentSession()
        local canTrade = owed and #owed > 0 and ml and ml ~= "" and not addon:IsAuthorizedLootMaster()
        local mlManagesTrades = addon:IsAuthorizedLootMaster() and session and session.active
        if mlManagesTrades then
            -- the loot master's left-click toggles incoming trades; the window is a right-click.
            if addon:IsAllowAllTrades() then
                GameTooltip:AddLine("Left-click to decline incoming trades.", 0.6, 1, 0.6)
            else
                GameTooltip:AddLine("Left-click to allow incoming trades.", 0.6, 1, 0.6)
            end
            GameTooltip:AddLine("Right-click to toggle the main window.", 0.8, 0.8, 0.8)
        elseif canTrade then
            -- when owed, the click trades the ML for your loot; show that instead of the toggle/reposition
            -- hints, for compactness. Color the ML name by their class.
            local mlName = ml
            local mlUnit = addon:GetLootMasterUnit()
            if mlUnit then
                -- capture UnitClass's 2nd return (the class token) in its own statement; an `and` guard
                -- here would truncate the multi-return to one value and lose the token.
                local _, classToken = UnitClass(mlUnit)
                local c = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
                if c then
                    mlName = string.format("|cff%02x%02x%02x%s|r",
                        math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5), ml)
                end
            end
            GameTooltip:AddLine("Move near " .. mlName .. " and left-click to trade.", 0.6, 1, 0.6)
            GameTooltip:AddLine("Press again to accept the trade.", 0.6, 1, 0.6)
        else
            GameTooltip:AddLine("Click to toggle the main window.", 1, 1, 1)
            GameTooltip:AddLine("Right-drag to reposition.", 0.8, 0.8, 0.8)
        end

        if owed and #owed > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Owed to you:", 1, 0.82, 0)
            for _, entry in ipairs(owed) do
                local name, link = GetItemInfo(entry.itemId)
                local label = link or name or ("item:" .. tostring(entry.itemId))
                if entry.count > 1 then label = label .. " x" .. entry.count end
                GameTooltip:AddLine(label, 1, 1, 1)
            end
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    button:SetScript("OnDragStart", function(selfBtn)
        selfBtn.isDragging = true
        selfBtn:SetScript("OnUpdate", function(s)
            local mx, my = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = Minimap:GetCenter()
            mx, my = mx / scale, my / scale
            local angle = math.deg(math.atan2(my - cy, mx - cx))
            addon.db.minimapButtonAngle = angle
            positionMinimapButton(s)
        end)
    end)
    button:SetScript("OnDragStop", function(selfBtn)
        selfBtn.isDragging = false
        selfBtn:SetScript("OnUpdate", nil)
    end)

    self.ui.minimapButton = button
    -- "Loot owed to you" indicator: a circular sparkle orbit (see shineOnUpdate), hidden until the
    -- mirrored ledger shows a copy we won but have not yet received.
    local shine = CreateFrame("Frame", nil, button)
    shine:SetAllPoints(button)
    shine:SetFrameLevel((button:GetFrameLevel() or 0) + 1)
    shine.angle = 0
    shine.sparkles = {}
    for i = 1, SHINE_COUNT do
        local s = shine:CreateTexture(nil, "OVERLAY")
        s:SetTexture(SHINE_TEXTURE)
        s:SetTexCoord(SHINE_TCOORD[1], SHINE_TCOORD[2], SHINE_TCOORD[3], SHINE_TCOORD[4])
        s:SetBlendMode("ADD")
        s:SetVertexColor(SHINE_COLOR[1], SHINE_COLOR[2], SHINE_COLOR[3])
        s:SetWidth(6); s:SetHeight(6)
        s:Hide()
        shine.sparkles[i] = s
    end
    self.ui.minimapShine = shine

    -- "ML is not accepting trades" warning: a red X over the button, shown while a session is live
    -- but the loot master has payout off or is auto-declining trades. On the ARTWORK layer, which sits
    -- ABOVE the icon (dropped to BORDER for this) and BELOW the OVERLAY tracking border, so the X
    -- nestles inside the button's rim over the icon. Layer separation, not same-layer creation order,
    -- is what guarantees this (3.3.5a has no draw-sublevel arg).
    local tradeX = button:CreateTexture(nil, "ARTWORK")
    tradeX:SetTexture(READY_CHECK_NOT_READY_TEXTURE)   -- stock ready-check red X (Interface\RaidFrame\ReadyCheck-NotReady)
    tradeX:SetWidth(24)
    tradeX:SetHeight(24)
    tradeX:SetPoint("CENTER", button, "CENTER", 0.5, 0)
    tradeX:SetAlpha(0.8)
    tradeX:Hide()
    button.tradeX = tradeX

    positionMinimapButton(button)

    local opt = getOptions(self)
    if opt.minimapButtonHidden then
        button:Hide()
    else
        button:Show()
    end
    self:UpdateMinimapOwedGlow()
    self:UpdateMinimapTradeStatus()
    self:UpdateMinimapMLActive()
end

-- The loot master is not currently accepting trades (payout off or incoming trades auto-declined)
-- while a session is live. Only meaningful during a session: no warning when nothing is being looted.
function addon:ShouldWarnMLNotAcceptingTrades()
    local session = self:GetCurrentSession()
    if not (session and session.active) then return false end
    return not self:IsLootMasterAcceptingTrades()
end

function addon:UpdateMinimapTradeStatus()
    local btn = self.ui and self.ui.minimapButton
    if not btn or not btn.tradeX then return end
    if self:ShouldWarnMLNotAcceptingTrades() then
        btn.tradeX:Show()
    else
        btn.tradeX:Hide()
    end
end

-- Grey out the minimap icon while in a raid with no loot master in play, so WeirdLoot reads as idle
-- at a glance. Only in a raid: outside one there is nothing to coordinate, so the icon stays normal.
function addon:UpdateMinimapMLActive()
    local btn = self.ui and self.ui.minimapButton
    if not btn or not btn.icon then return end
    local inRaid = (GetNumRaidMembers() or 0) > 0
    btn.icon:SetDesaturated(inRaid and not self:IsLootMasterActive())
end

-- Copies the local player has won but not yet received, from the (raider-mirrored) ledger.
function addon:CountLootOwedToMe()
    if not self.lootCore then return 0 end
    return self.lootCore:OwedCountFor(util:GetPlayerName("player"))
end

-- Aggregated { itemId, count } the local player is owed, for the minimap tooltip.
function addon:GetLootOwedToMe()
    if not self.lootCore then return {} end
    return self.lootCore:OwedItemsFor(util:GetPlayerName("player"))
end

-- One refresh for the ring + icon tint. Attention (roster data missing, visible only to
-- people who can fix it) outranks the owed-loot spin: it's the pre-pull signal, and owed
-- loot re-surfaces the moment the roster is clean.
function addon:RefreshMinimapShine()
    local shine = self.ui and self.ui.minimapShine
    local button = self.ui and self.ui.minimapButton
    if not shine then return end

    local attentionCount = 0
    if self.CanEditRoster and self:CanEditRoster() and self.GetRosterAttentionList then
        attentionCount = #self:GetRosterAttentionList()
    end

    local mode
    if attentionCount > 0 then
        mode = "attention"
    elseif (self:CountLootOwedToMe() or 0) > 0 then
        mode = "owed"
    end
    shine.mode = mode

    if button and button.icon then
        if mode == "attention" then
            button.icon:SetVertexColor(1, 0.3, 0.3)
        else
            button.icon:SetVertexColor(1, 1, 1)
        end
    end

    if mode then
        local color = mode == "attention" and ATTENTION_COLOR or SHINE_COLOR
        for _, s in ipairs(shine.sparkles) do
            s:SetVertexColor(color[1], color[2], color[3])
            s:Show()
        end
        shine:SetScript("OnUpdate", shineOnUpdate)
    else
        shine:SetScript("OnUpdate", nil)
        for _, s in ipairs(shine.sparkles) do s:Hide() end
    end
end

function addon:UpdateMinimapOwedGlow()
    self:RefreshMinimapShine()
end

function addon:SetMinimapButtonShown(shown)
    if not self.ui or not self.ui.minimapButton then return end
    if shown then
        self.ui.minimapButton:Show()
    else
        self.ui.minimapButton:Hide()
    end
end
