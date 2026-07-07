-- DBM-style loot toast banners. A faithful port of DBM-Core's BossBannerToast (itself a 3.3.5a
-- backport of retail's Blizzard_FrameXML/BossBannerToast), adapted into a reusable factory so the
-- same gold chrome + lightning intro can drive two banners in one screen region:
--   * the AWARDED banner (loot-bag medallion) -- passive, shows winners + mouseover roll breakdowns,
--   * the DROPS banner (dice medallion) -- the roll prompt (prototype: prio text; buttons are next).
-- They are independent instances and may coexist (rare, but handled); the region stacks drops above
-- awarded. Animation timings and atlas tex-coords are copied verbatim from DBM.

local addon = WeirdLoot
local util = addon.util

local tinsert = table.insert
local strformat = string.format
local strfind = string.find
local max = math.max
local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

local BANNER_TEXTURE = "Interface\\AddOns\\WeirdLoot\\Textures\\BossBanner"
local ICON_BORDER_TEXTURE = "Interface\\AddOns\\WeirdLoot\\Textures\\WhiteIconFrame"
local DICE_TEXTURE = "Interface\\Buttons\\UI-GroupLoot-Dice-Up"   -- drops-banner medallion (vs the bag)

local BB_EXPAND_TIME = 0.25         -- time to expand per item
local WON_ROW_H = 44                -- win card: icon + name + winner line
local DROP_ROW_H = 62               -- roll card is taller: name + prio line + bracket buttons
local ROW_GAP = 2                   -- vertical gap between stacked rows
local BADGE_SIZE = 20               -- minimalist per-card badge (dice/bag), a small top-left corner emblem
local MINIMAL_PAD = 6               -- minimalist top/bottom padding (no chrome to reserve)
local MINIMAL_BG_BOOST = 0.4        -- minimalist-only second pass of the row art: no dark chrome behind the
                                    -- cards, so thicken the colored background slightly (alpha of the extra layer)

-- Loot banner look/behavior, all read straight from db.options (the Options tab writes them; the
-- /wlbanner demo previews whatever they currently say):
--   * minimal: drop the header/footer chrome, turn the dice/bag medallion into a per-card badge.
--   * instant: every animation snaps (no intro flourish, per-card slide/glow, or fade-out).
--   * ML side: which card edge the loot-master End/Cancel rail hangs off (RIGHT/LEFT).
--   * locked: the banner cannot be dragged.
local function bannerMinimal()
    local o = addon.db and addon.db.options
    return (o and o.bannerMinimal) and true or false
end
local function bannerInstant()
    local o = addon.db and addon.db.options
    return (o and o.bannerInstant) and true or false
end
local function bannerMLSide()
    local o = addon.db and addon.db.options
    return (o and o.bannerMLSide) or "RIGHT"
end
local function bannerLocked()
    local o = addon.db and addon.db.options
    return (o and o.bannerLocked) and true or false
end

local BB_STATE_BANNER_IN = 1        -- banner is animating in
local BB_STATE_KILL_HOLD = 2        -- banner is holding with the headline
local BB_STATE_SWITCH = 3           -- banner is switching from headline to loot look
local BB_STATE_LOOT_EXPAND = 4      -- banner is expanding for loot items
local BB_STATE_LOOT_INSERT = 5      -- a loot item is being inserted
local BB_STATE_BANNER_OUT = 6       -- banner is animating out

-- Zero-delay scheduler. DBM defers a couple of PlayBanner calls one frame via DBM:Schedule(0, ...);
-- we drain our own one-shot queue from the banner's OnUpdate to get the same "next frame" behavior.
local scheduleQueue = {}
local function schedule0(fn, ...)
    scheduleQueue[#scheduleQueue + 1] = { fn = fn, args = { ... } }
end

------------------------------------------------------------------
-- math + animation helpers (verbatim from DBM)
local function round(value, dp)
    return tonumber(strformat("%." .. (dp or 14) .. "f", tostring(value)))
end

local function CreateScaleAnim(group, order, duration, scaleX, scaleY, delay, smoothing, endDelay, originPoint, originOffsetX, originOffsetY)
    local anim = group:CreateAnimation("Scale")
    anim:SetOrder(order)
    anim:SetDuration(duration)
    anim:SetScale(scaleX, scaleY)
    if delay then anim:SetStartDelay(delay) end
    if endDelay then anim:SetEndDelay(endDelay) end
    if smoothing then anim:SetSmoothing(smoothing) end
    if originPoint then anim:SetOrigin(originPoint, originOffsetX or 0, originOffsetY or 0) end
end

local function CreateAlphaAnim(group, order, duration, change, delay, smoothing, endDelay)
    local anim = group:CreateAnimation("Alpha")
    anim:SetOrder(order)
    anim:SetDuration(duration)
    anim:SetChange(change)
    if delay then anim:SetStartDelay(delay) end
    if endDelay then anim:SetEndDelay(endDelay) end
    if smoothing then anim:SetSmoothing(smoothing) end
end

local function CreateTranslationAnim(group, order, duration, xOffset, yOffset, delay, smoothing, endDelay)
    local anim = group:CreateAnimation("Translation")
    anim:SetOrder(order)
    anim:SetDuration(duration)
    anim:SetOffset(xOffset, yOffset)
    if delay then anim:SetStartDelay(delay) end
    if endDelay then anim:SetEndDelay(endDelay) end
    if smoothing then anim:SetSmoothing(smoothing) end
end

-- rarity color code (|cffXXXXXX) -> quality index, for items not yet in the GetItemInfo cache
local colorRarity = {
    ["ff9d9d9d"] = 0, ["ffffffff"] = 1, ["ff1eff00"] = 2, ["ff0070dd"] = 3,
    ["ffa335ee"] = 4, ["ffff8000"] = 5, ["ffe6cc80"] = 6,
}

local function findSetName(text)
    local pattern = "(.+)%s?%((%d+)/(%d+)%)$"
    local setName, current, total = text:match(pattern)
    if setName then
        return setName:trim(), tonumber(current), tonumber(total)
    end
    return nil
end

-- class-colored player name via the addon's shared helper, so the banner matches every other surface
-- (localized class names, "You" highlighting). className is the localized class (e.g. "Death Knight").
local function colorName(name, className)
    return util:ColorPlayerName(name, className)
end

------------------------------------------------------------------
-- atlas: a single texture sliced by tex coords (verbatim from DBM)
local AtlasInfo = {
    ["BossBanner-BottomFillagree"] = {66, 28, 0.865234, 0.994141, 0.314453, 0.369141},
    ["BossBanner-SkullCircle"]     = {44, 44, 0.865234, 0.951172, 0.134766, 0.220703},
    ["BossBanner-TopFillagree"]    = {176, 74, 0.244141, 0.587891, 0.576172, 0.720703},
    ["BossBanner-RedFlash"]        = {92, 92, 0.00195312, 0.181641, 0.810547, 0.990234},
    ["BossBanner-LeftFillagree"]   = {72, 40, 0.591797, 0.732422, 0.576172, 0.654297},
    ["BossBanner-RightFillagree"]  = {72, 40, 0.736328, 0.876953, 0.576172, 0.654297},
    ["BossBanner-SkullSpikes"]     = {50, 66, 0.865234, 0.962891, 0.00195312, 0.130859},
    ["BossBanner-BgBanner-Bottom"] = {440, 112, 0.00195312, 0.861328, 0.00195312, 0.220703},
    ["BossBanner-BgBanner-Top"]    = {440, 112, 0.00195312, 0.861328, 0.224609, 0.443359},
    ["LootBanner-IconGlow"]        = {40, 40, 0.865234, 0.943359, 0.447266, 0.525391},
    ["LootBanner-ItemBg"]          = {269, 41, 0.244141, 0.769531, 0.724609, 0.804688},
    ["LootBanner-LootBagCircle"]   = {44, 44, 0.865234, 0.951172, 0.224609, 0.310547},
    ["BossBanner-BgBanner-Mid"]    = {440, 64, 0.00195312, 0.861328, 0.447266, 0.572266},
    ["BossBanner-RedLightning"]    = {122, 118, 0.00195312, 0.240234, 0.576172, 0.806641},
}

local function SetAtlas(textureObject, atlasName, useAtlasSize)
    local atlas = AtlasInfo[atlasName]
    if textureObject and atlas then
        textureObject:SetTexture(BANNER_TEXTURE)
        textureObject:SetTexCoord(atlas[3], atlas[4], atlas[5], atlas[6])
        if useAtlasSize then
            textureObject:SetSize(atlas[1], atlas[2])
        end
        return textureObject
    end
end

------------------------------------------------------------------
-- Shared, stateless row helpers (do not reference a specific banner, so both instances share them).

-- How long a banner holds after the last row shows, mirroring the old result popup's lifetime: the
-- player's auto-close seconds, 0 for "close at once", or nil ("hold until dismissed") when auto-close
-- is off or the loot master opted to keep finished-loot popups open. Read per-client.
local function resultHoldSeconds()
    local opt = addon.db and addon.db.options
    if not opt then return nil end
    local mlKeepOpen = opt.forceKeepResultPopup and addon.IsAuthorizedLootMaster and addon:IsAuthorizedLootMaster()
    if opt.resultPopupAutoCloseEnabled and not mlKeepOpen then
        return tonumber(opt.resultPopupAutoCloseSeconds) or 0
    end
    return nil
end

-- The loot master who opted to keep their own finished-loot banners open sees the manual close (X)
-- immediately: they chose to hold the cards, so give them the control right away rather than making
-- them wait out the examine window like a held-open card on a client with auto-hide simply off.
local function resultCloseImmediate()
    local opt = addon.db and addon.db.options
    return opt and opt.forceKeepResultPopup and addon.IsAuthorizedLootMaster and addon:IsAuthorizedLootMaster()
end

-- The examine window used for the manual-close arm timer: the configured auto-hide seconds (so it
-- rides the same value and the same extension as the visible timers), with a floor so a held-open
-- card still has a real window to count down even when auto-hide seconds is 0 or unset.
local function resultExamineSeconds()
    local opt = addon.db and addon.db.options
    local secs = (opt and tonumber(opt.resultPopupAutoCloseSeconds)) or 10
    if secs <= 0 then secs = 10 end
    return secs
end

local function SetItemButtonQuality(button, quality)
    if button and button.IconBorder then
        button.IconBorder:SetTexture(ICON_BORDER_TEXTURE)
        local color = quality and ITEM_QUALITY_COLORS[quality]
        if color then
            button.IconBorder:SetVertexColor(color.r, color.g, color.b)
            button.IconBorder:Show()
        end
    end
end

-- Dock the roll-breakdown tooltip per the user's rollResultTooltipAnchor Options setting, the same
-- mapping the roll popup uses (addon:RollTooltipAnchorPoints). Returns having set the tooltip owner.
local function anchorBannerTooltip(owner)
    local point, relPoint, x, y = addon:RollTooltipAnchorPoints()
    if not point then
        GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")   -- CURSOR mode
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint(point, owner, relPoint, x, y)
end

-- Show/hide all of a banner's own chrome (medallion, header/footer art, glows, lightning, title). The
-- loot rows are child frames, not regions, so they are untouched. Minimalist mode hides all of it.
local function setChromeShown(banner, shown)
    for _, r in ipairs({ banner:GetRegions() }) do
        if shown then r:Show() else r:Hide() end
    end
end

-- Anchor a roll card's ML control rail (End/Cancel) off the card's edge per the current side
-- setting, stacking the buttons top-down. The minimalist corner badge pokes ~5px off the card's
-- left edge, so the left-side rail backs off a little further there to clear it.
local function anchorMLButtons(frame)
    local minimal = frame:GetParent().minimal
    local prev
    for _, btn in ipairs(frame.MLButtons) do
        btn:ClearAllPoints()
        if bannerMLSide() == "LEFT" then
            if prev then
                btn:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -3)
            else
                btn:SetPoint("TOPRIGHT", frame, "TOPLEFT", minimal and -10 or -6, -4)
            end
        else
            if prev then
                btn:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -3)
            else
                btn:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, -4)
            end
        end
        prev = btn
    end
end

-- roll card second line, shared by card creation and the dedupe re-assert; an item with no
-- listed priority shows the default bracket order, same as the roll popup did
local function rollPrioText(prio)
    return "|cffffffffPrio:|r " .. ((prio and prio ~= "") and prio or addon.DEFAULT_PRIO)
end

-- Apply a roll card's bracket-button availability (data.disabled: label -> reason string / true =
-- gray + hover reason) and its preselected bracket (data.selected). Shared by the initial row build
-- and the dedupe re-assert, so a restore-raced card recomputes its availability from the real prio
-- the moment the authoritative DROP lands (else a card built from an empty restore prio would keep
-- BiS wrongly disabled forever). Idempotent: safe to re-run on a live card.
local function applyRollButtons(frame, data)
    for _, btn in ipairs(frame.RollButtons) do
        btn:SetAlpha(1)   -- a reused slot may carry a stale fade alpha from its previous life
        btn:UnlockHighlight()
        -- explicit text color per state (deterministic, independent of Disable()'s font handling):
        -- gray for restricted brackets (mirrors the roll popup's styleButtonText), gold otherwise.
        local why = data.disabled and data.disabled[btn.bracket]
        if why then
            btn:Disable()
            btn:GetFontString():SetTextColor(0.5, 0.5, 0.5)
            btn:SetMotionScriptsWhileDisabled(true)   -- a disabled button still sees the mouse
            if type(why) == "string" then
                btn:SetScript("OnEnter", function(b)
                    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                    GameTooltip:SetText(why, 1, 0.3, 0.3, true)
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            else
                btn:SetScript("OnEnter", nil)
                btn:SetScript("OnLeave", nil)
            end
        else
            btn:Enable()
            btn:GetFontString():SetTextColor(1, 0.82, 0)
            btn:SetScript("OnEnter", nil)   -- a reused slot may carry a stale disabled tooltip
            btn:SetScript("OnLeave", nil)
        end
        btn:Show()
    end
    -- prior/authoritative pick: open with that bracket selected (never a disabled one)
    frame.selectedBracket = nil
    if data.selected then
        for _, btn in ipairs(frame.RollButtons) do
            if btn.bracket == data.selected and btn:GetButtonState() ~= "DISABLED" then
                btn:LockHighlight()
                btn:GetFontString():SetTextColor(0, 1, 0)
                frame.selectedBracket = data.selected
            end
        end
    end
end

local itemScanTooltip   -- single shared hidden scanning tooltip

-- Everything about a row that derives from the ITEM (name, rarity tints, icon, set line). Split
-- from ConfigureLootFrame so a card created on a cold item cache can re-render in place once the
-- item info arrives (RefreshRollBannerCard), without rebuilding the row's roll/winner state.
local function applyItemVisuals(lootFrame, itemLink, texture, fallbackName)
    local _, itemName, itemRarity, itemTexture, colorString, rarityColor, setName
    itemName, _, itemRarity, _, _, _, _, _, _, itemTexture = GetItemInfo(itemLink)

    if not itemTexture then -- uncached item: parse name/rarity from the link
        _, _, colorString, _, _, _, _, _, _, _, _, _, _, itemName = strfind(itemLink, "|?c?(%x*)|?H?([^:]*):?(%d+):?(%d*):?(%d*):?(%d*):?(%d*):?(%d*):?(%-?%d*):?(%-?%d*):?(%d*)|?h?%[?([^%[%]]*)%]?|?h?|?r?")
        itemRarity = colorRarity[colorString]
        itemTexture = texture
        if not itemName or itemName == "" then
            itemName = fallbackName   -- live feed on a cold cache passes a bare item:id link
        end
    end

    if IsDressableItem(itemLink) then -- gear: scan tooltip for a set name
        itemScanTooltip = itemScanTooltip or CreateFrame("GameTooltip", "WeirdLootBannerScanTooltip", nil, "GameTooltipTemplate")
        itemScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        itemScanTooltip:SetHyperlink(itemLink)
        for i = 2, itemScanTooltip:NumLines() do
            local text = _G["WeirdLootBannerScanTooltipTextLeft" .. i]:GetText()
            setName = findSetName(text)
            if setName then break end
        end
    end

    lootFrame.ItemName:SetText(itemName)
    rarityColor = ITEM_QUALITY_COLORS[itemRarity or 1]
    lootFrame.ItemName:SetTextColor(rarityColor.r, rarityColor.g, rarityColor.b)
    lootFrame.Background:SetVertexColor(rarityColor.r, rarityColor.g, rarityColor.b)
    lootFrame.Icon:SetTexture(itemTexture)

    SetItemButtonQuality(lootFrame.IconHitBox, itemRarity)

    if setName then
        lootFrame.ItemName:ClearAllPoints()
        lootFrame.ItemName:SetPoint("TOPLEFT", 56, -2)
        lootFrame.SetName:SetText(("Set: %s"):format(setName))
        lootFrame.SetName:Show()
        lootFrame.PlayerName:ClearAllPoints()
        lootFrame.PlayerName:SetPoint("TOPLEFT", lootFrame.SetName, "BOTTOMLEFT", 0, -2)
    else
        lootFrame.ItemName:ClearAllPoints()
        lootFrame.ItemName:SetPoint("TOPLEFT", 56, -7)
        lootFrame.SetName:Hide()
        lootFrame.PlayerName:ClearAllPoints()
        lootFrame.PlayerName:SetPoint("TOPLEFT", lootFrame.ItemName, "BOTTOMLEFT", 0, -2)
    end

    -- the minimal card's quality accents follow the item too
    if lootFrame:GetParent().minimal then
        lootFrame:SetBackdropBorderColor(rarityColor.r, rarityColor.g, rarityColor.b, 1)
        lootFrame.Background2:SetVertexColor(rarityColor.r, rarityColor.g, rarityColor.b)
    end

    lootFrame.itemLink = itemLink
    lootFrame.itemName = itemName
    lootFrame.itemRarity = itemRarity or 1
end

local function BossBanner_ConfigureLootFrame(lootFrame, data)
    -- data: { itemLink, texture, quantity, winner/winners/why, rolls } or a roll prompt { prompt }
    applyItemVisuals(lootFrame, data.itemLink, data.texture, data.fallbackName)

    if data.quantity and data.quantity > 1 then
        lootFrame.Count:Show()
        lootFrame.Count:SetText(data.quantity)
    else
        lootFrame.Count:Hide()
    end

    -- Second line. A roll prompt passes a pre-formatted `prompt` (prio + bracket options); an awarded
    -- item passes winner(s): a single winner reads "Name - roll N - Bracket", multiple read
    -- "Name (Bracket), ...". winnerKeys lets the roll tooltip highlight the winners.
    local winnerKeys = {}
    local nameText
    if data.rollDuration then
        -- roll card: the item's prio sits under the name (bracket buttons sit below it), mirroring
        -- the original roll popup's "Prio:" line.
        nameText = rollPrioText(data.prio)
    elseif data.prompt then
        nameText = data.prompt
    else
        local wins = data.winners
        if wins and #wins > 0 then
            -- "Name <roll> <bracket>" per winner, bracket gold; show the roll only for 1-2 winners
            -- (3+ would run too long), e.g. "Dremera 87 MS, Anagke 17 BiS".
            local showRolls = #wins <= 2
            local parts = {}
            for _, w in ipairs(wins) do
                winnerKeys[util:NormalizeKey(w.name)] = true
                local part = colorName(w.name, w.class)
                if showRolls and w.roll then part = part .. " " .. tostring(w.roll) end
                part = part .. " |cffffd200" .. (w.section or "?") .. "|r"
                parts[#parts + 1] = part
            end
            nameText = table.concat(parts, ", ")
        else
            -- legacy single-winner fields (no winners list)
            local name = data.winner
            if name then winnerKeys[util:NormalizeKey(name)] = true end
            nameText = colorName(name, data.winnerClass)
            if data.why and data.why ~= "" then
                nameText = nameText .. " |cffffd200" .. data.why .. "|r"
            end
        end
    end
    lootFrame.PlayerName:SetText(nameText)
    lootFrame.PlayerName:SetTextColor(1, 1, 1) -- base white; the name carries its own |c color code

    lootFrame.rolls = data.rolls
    lootFrame.winnerKeys = winnerKeys
    lootFrame.onChosen = data.onChosen

    -- Roll cards are taller (name + prio + buttons); win cards only need name + winner. Stretch the
    -- row background to the frame so the art fills either height.
    if data.rollDuration then
        lootFrame:SetHeight(DROP_ROW_H)
        lootFrame.rowHeight = DROP_ROW_H
        lootFrame.Background:SetSize(269, DROP_ROW_H - 3)
    else
        lootFrame:SetHeight(WON_ROW_H)
        lootFrame.rowHeight = WON_ROW_H
        lootFrame.Background:SetSize(269, 41)
    end

    -- The left badge and the quality-colored card border are minimalist-only (they replace the medallion
    -- and the missing chrome's contrast). Read the owning banner's flag (set at play time) so they never
    -- disagree with the chrome/layout.
    -- (applyItemVisuals already tinted the border/booster; this only flips their visibility)
    local minimal = lootFrame:GetParent().minimal
    if minimal then
        lootFrame.Badge:Show()
        lootFrame.IconHitBox.IconBorder:Hide()   -- the card's own quality border stands in for it
        lootFrame.Background2:Show()
    else
        lootFrame.Badge:Hide()
        lootFrame.Background2:Hide()
        lootFrame:SetBackdropBorderColor(0, 0, 0, 0)   -- hidden in full mode (SetItemButtonQuality shows the icon frame)
    end
end

local ROW_FADE_TIME = 0.4   -- seconds a row takes to fade out once its lifetime ends

-- "Players Rolling" hover: bracket priority order for the roller list, mirroring the roll popup's
-- count hover (rollerSort in LiveRoll): highest bracket first, then name.
local BRACKET_RANK = { BiS = 1, MS = 2, MU = 3, OS = 4, TM = 5, Pass = 6 }
local function sortedRollers(list)
    local out = {}
    for _, r in ipairs(list or {}) do out[#out + 1] = r end
    table.sort(out, function(a, b)
        local ra, rb = BRACKET_RANK[a.bracket] or 99, BRACKET_RANK[b.bracket] or 99
        if ra ~= rb then return ra < rb end
        return string.lower(a.name or "") < string.lower(b.name or "")
    end)
    return out
end

-- diagnostic: trace a drop row's lifecycle (add branch, dismiss, fade, revive, remove) into the
-- existing debug log so `/wl debug dump` shows the show/hide timeline. Gated on the log being on.
local function rbDbg(s)
    if WeirdLootDebugLog and WeirdLootDebugLog.enabled then
        addon:LogCoreEvent("rb", { id = s })
    end
end

------------------------------------------------------------------
-- Banner factory. Each call builds an independent banner frame (chrome + animations + methods).
-- medallionCfg = { atlas = "<atlasKey>" } or { texture = "<path>" } controls the intro medallion.
local function buildBanner(bannerName, medallionCfg)
    local BossBanner = CreateFrame("Frame", bannerName, UIParent)
    BossBanner:Hide()
    BossBanner:SetSize(128, 156)
    BossBanner:SetPoint("TOP", UIParent, 0, -120)   -- default; the region layout repositions both
    BossBanner:EnableMouse(true)
    BossBanner:SetAlpha(1)
    BossBanner.LootFrames = {}

    local bossBannerEffectiveScale = BossBanner:GetEffectiveScale()

    -- BORDER
    BossBanner.BannerTop = BossBanner:CreateTexture(nil, "BORDER")
    local BannerTop = BossBanner.BannerTop
    BannerTop:SetBlendMode("BLEND")
    BannerTop = SetAtlas(BannerTop, "BossBanner-BgBanner-Top", true)
    BannerTop:SetPoint("TOP", 0, -44)

    BossBanner.BannerTopGlow = BossBanner:CreateTexture(nil, "BORDER")
    local BannerTopGlow = BossBanner.BannerTopGlow
    BannerTopGlow:SetBlendMode("ADD")
    BannerTopGlow = SetAtlas(BannerTopGlow, "BossBanner-BgBanner-Top", true)
    BannerTopGlow:SetPoint("TOP", 0, -44)
    BannerTopGlow:SetAlpha(0)

    BossBanner.BannerBottom = BossBanner:CreateTexture(nil, "BORDER")
    local BannerBottom = BossBanner.BannerBottom
    BannerBottom:SetBlendMode("BLEND")
    BannerBottom = SetAtlas(BannerBottom, "BossBanner-BgBanner-Bottom", true)
    BannerBottom:SetPoint("BOTTOM", 0, 0)

    BossBanner.BannerBottomGlow = BossBanner:CreateTexture(nil, "BORDER")
    local BannerBottomGlow = BossBanner.BannerBottomGlow
    BannerBottomGlow:SetBlendMode("ADD")
    BannerBottomGlow = SetAtlas(BannerBottomGlow, "BossBanner-BgBanner-Bottom", true)
    BannerBottomGlow:SetPoint("BOTTOM", 0, 0)
    BannerBottomGlow:SetAlpha(0)

    -- BACKGROUND
    BossBanner.BannerMiddle = BossBanner:CreateTexture(nil, "BACKGROUND")
    local BannerMiddle = BossBanner.BannerMiddle
    BannerMiddle = SetAtlas(BannerMiddle, "BossBanner-BgBanner-Mid", true)
    BannerMiddle:SetBlendMode("BLEND")
    BannerMiddle:SetPoint("TOPLEFT", BannerTop, 0, -34)
    BannerMiddle:SetPoint("BOTTOMRIGHT", BannerBottom, 0, 25)

    BossBanner.BannerMiddleGlow = BossBanner:CreateTexture(nil, "BACKGROUND")
    local BannerMiddleGlow = BossBanner.BannerMiddleGlow
    BannerMiddleGlow = SetAtlas(BannerMiddleGlow, "BossBanner-BgBanner-Mid", true)
    BannerMiddleGlow:SetBlendMode("ADD")
    BannerMiddleGlow:SetPoint("TOPLEFT", BannerTop, 0, -34)
    BannerMiddleGlow:SetPoint("BOTTOMRIGHT", BannerBottom, 0, 25)
    BannerMiddleGlow:SetAlpha(0)

    -- OVERLAY
    BossBanner.SkullCircle = BossBanner:CreateTexture(nil, "OVERLAY")
    local SkullCircle = BossBanner.SkullCircle
    SkullCircle:SetBlendMode("BLEND")
    SkullCircle = SetAtlas(SkullCircle, "BossBanner-SkullCircle", true)
    SkullCircle:SetPoint("CENTER", BannerTop, 0, 36)

    BossBanner.LootCircle = BossBanner:CreateTexture(nil, "OVERLAY")
    local LootCircle = BossBanner.LootCircle
    LootCircle:SetBlendMode("BLEND")
    LootCircle = SetAtlas(LootCircle, "LootBanner-LootBagCircle", true)
    LootCircle:SetPoint("CENTER", BannerTop, 0, 36)

    -- ARTWORK
    BossBanner.BottomFillagree = BossBanner:CreateTexture(nil, "ARTWORK")
    local BottomFillagree = BossBanner.BottomFillagree
    BottomFillagree:SetBlendMode("BLEND")
    BottomFillagree = SetAtlas(BottomFillagree, "BossBanner-BottomFillagree", true)
    BottomFillagree:SetPoint("BOTTOM", 0, 8)

    BossBanner.SkullSpikes = BossBanner:CreateTexture(nil, "ARTWORK")
    local SkullSpikes = BossBanner.SkullSpikes
    SkullSpikes:SetBlendMode("BLEND")
    SkullSpikes = SetAtlas(SkullSpikes, "BossBanner-SkullSpikes", true)
    SkullSpikes:SetPoint("CENTER", SkullCircle, -1, 6)

    BossBanner.RightFillagree = BossBanner:CreateTexture(nil, "ARTWORK")
    local RightFillagree = BossBanner.RightFillagree
    RightFillagree:SetBlendMode("BLEND")
    RightFillagree = SetAtlas(RightFillagree, "BossBanner-RightFillagree", true)
    RightFillagree:SetPoint("CENTER", SkullCircle, 47, 6)

    BossBanner.LeftFillagree = BossBanner:CreateTexture(nil, "ARTWORK")
    local LeftFillagree = BossBanner.LeftFillagree
    LeftFillagree:SetBlendMode("BLEND")
    LeftFillagree = SetAtlas(LeftFillagree, "BossBanner-LeftFillagree", true)
    LeftFillagree:SetPoint("CENTER", SkullCircle, -47, 6)

    BossBanner.Title = BossBanner:CreateFontString(nil, "ARTWORK", "QuestFont_Large")
    local Title = BossBanner.Title
    Title:SetHeight(30)
    local titleFont, _, titleFlag = Title:GetFont()
    Title:SetFont(titleFont, 30, titleFlag)
    Title:SetText("")
    Title:SetPoint("TOP", BannerTop, 0, -47)
    Title:SetTextColor(1, 0, 0, 0)
    Title:SetAlpha(1)

    BossBanner.SubTitle = BossBanner:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    local SubTitle = BossBanner.SubTitle
    SubTitle:SetText("")
    SubTitle:SetPoint("TOP", BottomFillagree, "BOTTOM", 0, 0)
    SubTitle:SetTextColor(1, 0, 0, 0)
    SubTitle:SetAlpha(1)

    -- OVERLAY, texture sublevel 2
    BossBanner.FlashBurst = BossBanner:CreateTexture(nil, "OVERLAY", nil, 2)
    local FlashBurst = BossBanner.FlashBurst
    FlashBurst:SetBlendMode("ADD")
    FlashBurst = SetAtlas(FlashBurst, "BossBanner-RedLightning", true)
    FlashBurst:SetPoint("CENTER", SkullSpikes, 15, -4)
    FlashBurst:SetAlpha(0.01)

    BossBanner.FlashBurstLeft = BossBanner:CreateTexture(nil, "OVERLAY", nil, 2)
    local FlashBurstLeft = BossBanner.FlashBurstLeft
    FlashBurstLeft:SetBlendMode("ADD")
    FlashBurstLeft = SetAtlas(FlashBurstLeft, "BossBanner-RedLightning", true)
    FlashBurstLeft:SetPoint("CENTER", SkullSpikes, -15, -4)
    FlashBurstLeft:SetAlpha(0.01)

    -- OVERLAY, texture sublevel 3
    BossBanner.FlashBurstCenter = BossBanner:CreateTexture(nil, "OVERLAY", nil, 3)
    local FlashBurstCenter = BossBanner.FlashBurstCenter
    FlashBurstCenter:SetBlendMode("ADD")
    FlashBurstCenter = SetAtlas(FlashBurstCenter, "BossBanner-RedLightning", true)
    FlashBurstCenter:SetPoint("CENTER", SkullSpikes)
    FlashBurstCenter:SetAlpha(0.01)

    -- OVERLAY, texture sublevel 4
    BossBanner.RedFlash = BossBanner:CreateTexture(nil, "OVERLAY", nil, 4)
    local RedFlash = BossBanner.RedFlash
    RedFlash:SetBlendMode("ADD")
    RedFlash = SetAtlas(RedFlash, "BossBanner-RedFlash", true)
    RedFlash:SetPoint("CENTER", SkullSpikes, 1, -4)
    RedFlash:SetAlpha(0.01)

    --------------------------------------------------------------
    -- per-row tooltip (closes over this banner instance)
    local function BossBanner_OnLootItemEnter(self)
        if BossBanner.animState ~= BB_STATE_BANNER_OUT and not BossBanner.showingTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink(self:GetParent().itemLink)
            GameTooltip:Show()
            BossBanner.showingTooltip = true
        end
    end

    local function BossBanner_OnLootItemLeave()
        if BossBanner.showingTooltip or BossBanner.showingRollerTip then
            GameTooltip:Hide()
            BossBanner.showingTooltip = false
            BossBanner.showingRollerTip = false
        end
    end

    -- "Players Rolling" hover: any non-interactive spot on the banner (chrome or a roll card)
    -- lists every live roll's rollers, bracket-sorted, like the roll popup's count hover. Cards
    -- carry a getRollers thunk (demo data for now; the real feed will read the live registrants).
    -- Kept out of showingTooltip on purpose: the roll countdown must not pause under this hover.
    local function showRollersTooltip(owner)
        if BossBanner.animState == BB_STATE_BANNER_OUT or BossBanner.showingTooltip then return end
        -- hovering a roll card scopes the list to that item; banner chrome shows every live roll
        local cards = {}
        if owner.getRollers then
            if owner.alive and not owner.fading and owner.rollDuration then cards[1] = owner end
        else
            for _, f in ipairs(BossBanner.LootFrames) do
                if f.alive and not f.fading and f.rollDuration and f.getRollers then
                    cards[#cards + 1] = f
                end
            end
        end
        if #cards == 0 then
            -- the last roll card fell off while the hover was open: retire the stale tooltip
            if BossBanner.showingRollerTip then
                GameTooltip:Hide()
                BossBanner.showingRollerTip = false
            end
            return
        end
        anchorBannerTooltip(owner)
        GameTooltip:AddLine("Players Rolling", 1, 0.82, 0)
        for i, f in ipairs(cards) do
            if i > 1 then GameTooltip:AddLine(" ") end
            local q = ITEM_QUALITY_COLORS[f.itemRarity or 1]
            GameTooltip:AddLine(f.itemName or "", q.r, q.g, q.b)
            local entries = sortedRollers(f.getRollers())
            if #entries == 0 then
                GameTooltip:AddLine("No rollers yet", 0.6, 0.6, 0.6)
            else
                for _, e in ipairs(entries) do
                    local nameText = util:IsSelfName(e.name) and "You" or e.name
                    GameTooltip:AddLine(util:ColorPlayerText(e.name, e.class, nameText .. " - " .. (e.bracket or "?")), 1, 1, 1)
                end
            end
        end
        GameTooltip:Show()
        BossBanner.showingRollerTip = true
        owner.UpdateTooltip = showRollersTooltip   -- rollers keep arriving while the hover is open
    end

    local function BossBanner_OnRowEnter(self)
        if BossBanner.animState == BB_STATE_BANNER_OUT or BossBanner.showingTooltip then return end
        if self.rollDuration then return showRollersTooltip(self) end   -- roll card: who is in so far
        anchorBannerTooltip(self)
        local q = ITEM_QUALITY_COLORS[self.itemRarity or 1]
        GameTooltip:AddLine(self.itemName or "", q.r, q.g, q.b)
        local rolls = self.rolls
        if rolls and #rolls > 0 then
            local winnerKeys = self.winnerKeys or {}
            local prevGroup
            for _, r in ipairs(rolls) do
                local grp = r.group or r.section   -- separate on the bracket, so BiS Main/Alt tiers stay adjacent
                if prevGroup and grp ~= prevGroup then
                    GameTooltip:AddLine(" ")   -- slight gap between bracket groups (rolls come priority-ordered)
                end
                prevGroup = grp
                local right = r.roll and tostring(r.roll) or "-"
                if r.section and r.section ~= "" then right = right .. "  " .. r.section end
                if winnerKeys[util:NormalizeKey(r.name)] then
                    GameTooltip:AddDoubleLine(colorName(r.name, r.class), right, 1, 1, 1, 1, 0.82, 0)    -- winner: gold
                else
                    GameTooltip:AddDoubleLine(colorName(r.name, r.class), right, 1, 1, 1, 0.6, 0.6, 0.6)  -- did not win: gray
                end
            end
        elseif not self.rolls then
            return  -- a roll-prompt row has no breakdown yet; no tooltip
        else
            GameTooltip:AddLine("No rolls recorded", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
        BossBanner.showingTooltip = true
    end

    --------------------------------------------------------------
    -- loot row factory (verbatim from DBM, font-option logic dropped -> template fonts)
    local function createLootFrame(parent)
        local frame = CreateFrame("Frame", nil, parent)
        frame:SetSize(269, 44)
        frame:EnableMouse(true)
        frame:SetScript("OnEnter", BossBanner_OnRowEnter)
        frame:SetScript("OnLeave", BossBanner_OnLootItemLeave)
        -- rows blanket the banner and swallow its mouse, so they forward region dragging to the
        -- parent's hooks (set by enableRegionDrag, which runs after this factory); buttons and the
        -- loot icon capture their own mouse and stay non-draggy
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(self)
            local p = self:GetParent()
            if p.onRegionDragStart then p.onRegionDragStart() end
        end)
        frame:SetScript("OnDragStop", function(self)
            local p = self:GetParent()
            if p.onRegionDragStop then p.onRegionDragStop() end
        end)

        local effectiveScale = frame:GetEffectiveScale()

        frame.Background = frame:CreateTexture(nil, "BACKGROUND")
        local Background = frame.Background
        Background:SetBlendMode("BLEND")
        Background = SetAtlas(Background, "LootBanner-ItemBg", true)
        Background:SetPoint("CENTER")

        -- the opacity booster layer (minimalist only): the row art restacked on itself so the card
        -- reads denser without the banner chrome behind it. Tracks Background's size and tint.
        frame.Background2 = frame:CreateTexture(nil, "BACKGROUND")
        local Background2 = frame.Background2
        Background2:SetBlendMode("BLEND")
        Background2 = SetAtlas(Background2, "LootBanner-ItemBg", true)
        Background2:SetAllPoints(Background)
        Background2:SetAlpha(MINIMAL_BG_BOOST)
        Background2:Hide()

        frame.Icon = frame:CreateTexture(nil, "OVERLAY")
        local Icon = frame.Icon
        Icon:SetSize(37, 37)
        Icon:SetPoint("LEFT", 14, 0)
        Icon:SetTexture("Interface\\Icons\\inv_misc_bag_felclothbag")

        -- Minimalist per-card badge: the dice/bag emblem sits small in the card's top-left corner,
        -- poking a few px past the edge. That corner is left of the icon, so no overlap; 3.3.5a
        -- ignores texture SUBLEVELS, so layers order the stack: quality border (BORDER) < badge
        -- (ARTWORK) < loot icon (OVERLAY). Minimalist only.
        frame.Badge = frame:CreateTexture(nil, "ARTWORK")
        local Badge = frame.Badge
        Badge:SetSize(BADGE_SIZE, BADGE_SIZE)
        Badge:SetPoint("CENTER", frame, "TOPLEFT", 7, -7)
        -- badgeTexture overrides the per-card badge only; the full-chrome medallion keeps its atlas
        local badgeTex = medallionCfg and (medallionCfg.badgeTexture or medallionCfg.texture)
        if badgeTex then
            Badge:SetTexture(badgeTex)
            if medallionCfg.badgeFlipH then
                Badge:SetTexCoord(1, 0, 0, 1)   -- mirrored horizontally
            else
                Badge:SetTexCoord(0, 1, 0, 1)
            end
        else
            SetAtlas(Badge, (medallionCfg and medallionCfg.atlas) or "LootBanner-LootBagCircle", false)
        end
        Badge:Hide()

        -- Minimalist cards have no dark chrome behind them, so they can wash out against the world. A
        -- soft-cornered border in the item-quality color (the same tint as the row background) gives each
        -- card a crisp edge like the loot icon's frame. A backdrop edge keeps the corners from distorting
        -- on the wide card. Tinted/hidden per item in ConfigureLootFrame (minimal only).
        frame:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
        frame:SetBackdropBorderColor(1, 1, 1, 0)

        frame.Count = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")   -- above the raised icon
        local Count = frame.Count
        Count:SetJustifyH("RIGHT")
        Count:SetPoint("BOTTOMRIGHT", Icon, -5, 2)
        Count:Hide()

        frame.ItemName = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
        local ItemName = frame.ItemName
        ItemName:SetWordWrap(false)
        ItemName:SetJustifyH("LEFT")
        ItemName:SetSize(204, 0)
        ItemName:SetPoint("TOPLEFT", frame, 56, -7)

        frame.SetName = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        local SetName = frame.SetName
        SetName:SetWordWrap(false)
        SetName:SetJustifyH("LEFT")
        SetName:SetSize(204, 0)
        SetName:SetPoint("TOPLEFT", ItemName, "BOTTOMLEFT", 0, 0)
        SetName:SetTextColor(0, 1.0, 0)
        SetName:Hide()

        frame.PlayerName = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        local PlayerName = frame.PlayerName
        PlayerName:SetWordWrap(false)
        PlayerName:SetJustifyH("LEFT")
        PlayerName:SetSize(204, 0)
        PlayerName:SetPoint("TOPLEFT", ItemName, "BOTTOMLEFT", 0, 0)

        frame.IconHitBox = CreateFrame("Frame", nil, frame)
        local IconHitBox = frame.IconHitBox
        IconHitBox:SetSize(37, 37)
        IconHitBox:SetPoint("CENTER", Icon)
        IconHitBox:EnableMouse(true)

        IconHitBox.IconBorder = IconHitBox:CreateTexture(nil, "BORDER")
        local IconBorder = IconHitBox.IconBorder
        IconBorder:SetTexture(ICON_BORDER_TEXTURE)
        IconBorder:SetSize(37, 37)
        IconBorder:SetPoint("CENTER")
        IconBorder:Hide()

        IconHitBox.Glow = IconHitBox:CreateTexture(nil, "ARTWORK")
        local Glow = IconHitBox.Glow
        Glow:SetBlendMode("ADD")
        Glow = SetAtlas(Glow, "LootBanner-IconGlow", true)
        Glow:SetPoint("CENTER")
        Glow:SetVertexColor(0.63921568627451, 0.2078431372549, 0.93333333333333)
        Glow:SetAlpha(0)

        IconHitBox.GlowWhite = IconHitBox:CreateTexture(nil, "ARTWORK")
        local GlowWhite = IconHitBox.GlowWhite
        GlowWhite:SetBlendMode("ADD")
        GlowWhite = SetAtlas(GlowWhite, "LootBanner-IconGlow", true)
        GlowWhite:SetPoint("CENTER")
        GlowWhite:SetAlpha(0)

        IconHitBox.IconOverlay = IconHitBox:CreateTexture(nil, "OVERLAY", nil, 1)
        local IconOverlay = IconHitBox.IconOverlay
        IconOverlay:SetSize(37, 37)
        IconOverlay:SetPoint("CENTER")
        IconOverlay:Hide()

        IconHitBox.IconOverlay2 = IconHitBox:CreateTexture(nil, "OVERLAY", nil, 2)
        local IconOverlay2 = IconHitBox.IconOverlay2
        IconOverlay2:SetSize(37, 37)
        IconOverlay2:SetPoint("CENTER")
        IconOverlay2:Hide()

        -- roll-card roller count: a small dark rounded chip on the card's top-RIGHT corner,
        -- mirroring the minimal badge's top-left spot, with the live count inside. The backing is a
        -- baked flat-black rounded square (Textures/RollCountChip.blp, alpha in the art). Shown only
        -- while someone is in (an empty chip reads as clutter); hover gives the names.
        frame.RollCountChip = frame:CreateTexture(nil, "OVERLAY")
        frame.RollCountChip:SetSize(16, 16)
        frame.RollCountChip:SetPoint("CENTER", frame, "TOPRIGHT", -7, -7)
        frame.RollCountChip:SetTexture("Interface\\AddOns\\WeirdLoot\\Textures\\RollCountChip")
        frame.RollCountChip:SetAlpha(0.8)   -- on top of the art's own baked ~0.82
        frame.RollCountChip:Hide()
        -- bare antialiased digits: the stock small number font is monochrome+thick-outline (jagged
        -- by design), and the chip's own dark ground needs no outline or shadow for contrast
        frame.RollCount = frame:CreateFontString(nil, "OVERLAY")
        frame.RollCount:SetFont("Fonts\\ARIALN.TTF", 12, "")
        frame.RollCount:SetPoint("CENTER", frame.RollCountChip, "CENTER", -0.5, 0)
        frame.RollCount:SetText("")

        -- Manual close (X) for a WON row that is being held open past its examine window (the loot
        -- master's never-auto-hide banners, or any client with auto-hide off). The row's own timer
        -- arms it; clicking fades that one card. Hidden on normal auto-fading rows and roll cards.
        frame.CloseButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        frame.CloseButton:SetScale(0.7)
        frame.CloseButton:SetPoint("CENTER", frame, "TOPRIGHT", -5, -5)
        frame.CloseButton:SetScript("OnClick", function()
            frame.fading = true
            frame.fadeLeft = parent.instant and 0 or ROW_FADE_TIME
            frame.CloseButton:Hide()
        end)
        frame.CloseButton:Hide()

        tinsert(parent.LootFrames, frame)
        frame.__idx = #parent.LootFrames   -- stable id for diagnostics

        IconHitBox.UpdateTooltip = function(owner) BossBanner_OnLootItemEnter(owner) end
        IconHitBox:SetScript("OnEnter", BossBanner_OnLootItemEnter)
        IconHitBox:SetScript("OnLeave", BossBanner_OnLootItemLeave)

        -- Animations
        Background.animForAnim = Background:CreateAnimationGroup()
        Icon.animForAnim = Icon:CreateAnimationGroup()
        IconBorder.animForAnim = IconBorder:CreateAnimationGroup()
        IconOverlay.animForAnim = IconOverlay:CreateAnimationGroup()
        IconOverlay2.animForAnim = IconOverlay2:CreateAnimationGroup()
        Glow.animForAnim = Glow:CreateAnimationGroup()
        IconHitBox.animForAnim = IconHitBox:CreateAnimationGroup()
        GlowWhite.animForAnim = GlowWhite:CreateAnimationGroup()
        ItemName.animForAnim = ItemName:CreateAnimationGroup()
        PlayerName.animForAnim = PlayerName:CreateAnimationGroup()
        SetName.animForAnim = SetName:CreateAnimationGroup()

        CreateAlphaAnim(Background.animForAnim, 1, 0, -1)
        CreateAlphaAnim(Background.animForAnim, 1, 0.45, 1)

        CreateAlphaAnim(Icon.animForAnim, 1, 0, -1, 0.1)
        CreateAlphaAnim(Icon.animForAnim, 1, 0.25, 1, 0.1)

        CreateAlphaAnim(IconBorder.animForAnim, 1, 0, -1, 0.1)
        CreateAlphaAnim(IconBorder.animForAnim, 1, 0.25, 1, 0.1)

        CreateAlphaAnim(IconOverlay.animForAnim, 1, 0, -1, 0.1)
        CreateAlphaAnim(IconOverlay.animForAnim, 1, 0.25, 1, 0.1)

        CreateAlphaAnim(IconOverlay2.animForAnim, 1, 0, -1, 0)
        CreateAlphaAnim(IconOverlay2.animForAnim, 1, 0.25, 1, 0)

        CreateTranslationAnim(Icon.animForAnim, 1, 0, 110 * effectiveScale, 0)
        CreateTranslationAnim(Icon.animForAnim, 1, 0.4, -110 * effectiveScale, 0, 0.25, "OUT")

        CreateTranslationAnim(IconHitBox.animForAnim, 1, 0, 110 * effectiveScale, 0)
        CreateTranslationAnim(IconHitBox.animForAnim, 1, 0.4, -110 * effectiveScale, 0, 0.25, "OUT")

        CreateAlphaAnim(Glow.animForAnim, 1, 0, -1)
        CreateAlphaAnim(Glow.animForAnim, 1, 0.15, 1, nil, "IN")
        CreateAlphaAnim(Glow.animForAnim, 1, 0.10, 1, 0.15)
        CreateAlphaAnim(Glow.animForAnim, 1, 1, -1, 0.25)

        CreateAlphaAnim(GlowWhite.animForAnim, 1, 0, -1)
        CreateAlphaAnim(GlowWhite.animForAnim, 1, 0.25, 1, nil, "IN")
        CreateAlphaAnim(GlowWhite.animForAnim, 1, 0.25, -1, 0.25)
        CreateScaleAnim(GlowWhite.animForAnim, 1, 0.25, 1.25, 1.25, nil, "IN_OUT")

        CreateAlphaAnim(ItemName.animForAnim, 1, 0, -1, 0.4)
        CreateAlphaAnim(ItemName.animForAnim, 1, 0.25, 1, 0.4)

        CreateAlphaAnim(PlayerName.animForAnim, 1, 0, -1, 0.4)
        CreateAlphaAnim(PlayerName.animForAnim, 1, 0.25, 1, 0.4)

        CreateAlphaAnim(SetName.animForAnim, 1, 0, -1, 0.4)
        CreateAlphaAnim(SetName.animForAnim, 1, 0.25, 1, 0.4)

        frame.Anim = {}
        local Anim = frame.Anim
        Anim.Background = Background.animForAnim
        Anim.Icon = Icon.animForAnim
        Anim.IconBorder = IconBorder.animForAnim
        Anim.IconOverlay = IconOverlay.animForAnim
        Anim.IconOverlay2 = IconOverlay2.animForAnim
        Anim.Glow = Glow.animForAnim
        Anim.IconHitBox = IconHitBox.animForAnim
        Anim.GlowWhite = GlowWhite.animForAnim
        Anim.ItemName = ItemName.animForAnim
        Anim.PlayerName = PlayerName.animForAnim
        Anim.SetName = SetName.animForAnim

        Anim.Play = function(self)
            for _, anim in pairs(self) do
                if type(anim) == "table" then
                    anim:Stop()
                    anim:Play()
                end
            end
        end

        -- Roll countdown bar along the row's bottom edge (shown only for roll-prompt rows), styled like
        -- the interest popup's timer: shrinks and shifts green -> red as the roll time runs out.
        frame.RollTimer = CreateFrame("StatusBar", nil, frame)
        frame.RollTimer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 3)
        frame.RollTimer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 3)
        frame.RollTimer:SetHeight(3)
        frame.RollTimer:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        frame.RollTimer:SetMinMaxValues(0, 1)
        frame.RollTimer:SetValue(1)
        frame.RollTimer:Hide()

        -- Fade this roll card out now (bracket dismiss / ML End / ML Cancel / a wire-side close),
        -- hiding its interactive bits so they don't linger through the fade.
        frame.MLButtons = {}
        local function fadeOutRollRow()
            frame.fading = true
            frame.fadeLeft = BossBanner.instant and 0 or ROW_FADE_TIME
            frame.RollTimer:Hide()
            for _, b in ipairs(frame.RollButtons) do b:Hide() end
            for _, b in ipairs(frame.MLButtons) do b:Hide() end
        end
        frame.FadeOutNow = fadeOutRollRow   -- the live feed closes cards by key (WIN/CANCEL) via this

        -- Bracket buttons for roll-prompt rows (hidden on awarded rows). Clicking selects a bracket;
        -- the choice stays highlighted. (Wiring to the real roll response is the next step.)
        local BRACKETS = { { "BiS", 30 }, { "MS", 28 }, { "MU", 30 }, { "OS", 28 }, { "TM", 28 }, { "Pass", 40 } }
        frame.RollButtons = {}
        local bx = 56
        for _, b in ipairs(BRACKETS) do
            local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            btn:SetText(b[1])
            btn:SetWidth(b[2])
            btn:SetHeight(17)
            btn:SetPoint("TOPLEFT", frame, "TOPLEFT", bx, -38)   -- below the name + prio line on roll cards
            btn.bracket = b[1]
            btn:SetScript("OnClick", function(self)
                if frame.selectedBracket == self.bracket then
                    -- second click on the already-selected bracket: dismiss this roll (fade the row
                    -- out). NOT for the loot master: the ML drives the roll and its card never
                    -- auto-hides (same rule as the popup); a repeat click just stays selected.
                    if frame.isOwnerCard then return end
                    rbDbg(("DISMISS idx=%s rd=%s"):format(tostring(frame.__idx), tostring(frame.rollDuration)))
                    fadeOutRollRow()
                    if frame.onChosen then frame.onChosen(frame.selectedBracket) end
                    return
                end
                for _, b in ipairs(frame.RollButtons) do
                    if b:GetButtonState() ~= "DISABLED" then   -- leave disabled brackets grayed out
                        b:UnlockHighlight()
                        b:GetFontString():SetTextColor(1, 0.82, 0)   -- gold (default)
                    end
                end
                self:LockHighlight()
                self:GetFontString():SetTextColor(0, 1, 0)       -- selected: green
                frame.selectedBracket = self.bracket
                if frame.onPick then frame.onPick(self.bracket) end   -- live feed: send the pick to the ML
            end)
            btn:Hide()
            frame.RollButtons[#frame.RollButtons + 1] = btn
            bx = bx + b[2] + 2
        end

        -- Loot-master controls: the extra roll actions the live popup gives the ML (End = close the
        -- roll now and resolve, Cancel = abort it), stacked in a rail off the card's side (see
        -- anchorMLButtons; the side will become a lootmaster config option). Shown only on roll
        -- cards that carry the matching callback; future ML actions slot into this list.
        local ML_CONTROLS = {
            { label = "End",    width = 46, callbackKey = "onMLEnd" },
            { label = "Cancel", width = 56, callbackKey = "onMLCancel" },
        }
        for _, c in ipairs(ML_CONTROLS) do
            local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            btn:SetText(c.label)
            btn:SetWidth(c.width)
            btn:SetHeight(17)
            btn:SetScript("OnClick", function()
                rbDbg(("ML-%s idx=%s"):format(c.label, tostring(frame.__idx)))
                fadeOutRollRow()
                if frame[c.callbackKey] then frame[c.callbackKey]() end
            end)
            btn:Hide()
            frame.MLButtons[#frame.MLButtons + 1] = btn
        end

        return frame
    end

    --------------------------------------------------------------
    -- first loot row + banner-level animation groups
    local bossBannerLootFrame = createLootFrame(BossBanner)
    bossBannerLootFrame:Hide()
    bossBannerLootFrame:SetPoint("TOP", 0, -84)

    -- AnimationGroup: AnimIn
    SkullCircle.animForAnimIn = SkullCircle:CreateAnimationGroup()
    BannerTop.animForAnimIn = BannerTop:CreateAnimationGroup()
    BannerBottom.animForAnimIn = BannerBottom:CreateAnimationGroup()
    BannerMiddle.animForAnimIn = BannerMiddle:CreateAnimationGroup()
    BottomFillagree.animForAnimIn = BottomFillagree:CreateAnimationGroup()
    SkullSpikes.animForAnimIn = SkullSpikes:CreateAnimationGroup()
    RightFillagree.animForAnimIn = RightFillagree:CreateAnimationGroup()
    LeftFillagree.animForAnimIn = LeftFillagree:CreateAnimationGroup()
    BannerTopGlow.animForAnimIn = BannerTopGlow:CreateAnimationGroup()
    BannerBottomGlow.animForAnimIn = BannerBottomGlow:CreateAnimationGroup()
    BannerMiddleGlow.animForAnimIn = BannerMiddleGlow:CreateAnimationGroup()
    RedFlash.animForAnimIn = RedFlash:CreateAnimationGroup()
    FlashBurst.animForAnimIn = FlashBurst:CreateAnimationGroup()
    FlashBurstLeft.animForAnimIn = FlashBurstLeft:CreateAnimationGroup()
    FlashBurstCenter.animForAnimIn = FlashBurstCenter:CreateAnimationGroup()
    Title.animForAnimIn = Title:CreateAnimationGroup()
    SubTitle.animForAnimIn = SubTitle:CreateAnimationGroup()

    CreateScaleAnim(SkullCircle.animForAnimIn, 1, 0, 5, 5)
    CreateScaleAnim(SkullCircle.animForAnimIn, 1, 0.15, 0.2, 0.2)
    CreateAlphaAnim(SkullCircle.animForAnimIn, 1, 0, -1)
    CreateAlphaAnim(SkullCircle.animForAnimIn, 1, 0.1, 1)

    CreateAlphaAnim(BannerTop.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(BannerTop.animForAnimIn, 2, 0.25, 1, 0.2)
    CreateScaleAnim(BannerTop.animForAnimIn, 1, 0, 0.1, 1, 0.15)
    CreateScaleAnim(BannerTop.animForAnimIn, 2, 0.3, 10, 1, 0.1)

    CreateAlphaAnim(BannerBottom.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(BannerBottom.animForAnimIn, 2, 0.25, 1, 0.2)
    CreateScaleAnim(BannerBottom.animForAnimIn, 1, 0, 0.1, 1, 0.15)
    CreateScaleAnim(BannerBottom.animForAnimIn, 2, 0.3, 10, 1, 0.1)

    CreateAlphaAnim(BannerMiddle.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(BannerMiddle.animForAnimIn, 2, 0.25, 1, 0.2)
    CreateScaleAnim(BannerMiddle.animForAnimIn, 1, 0, 0.1, 1, 0.15)
    CreateScaleAnim(BannerMiddle.animForAnimIn, 2, 0.3, 10, 1, 0.1)

    CreateAlphaAnim(BottomFillagree.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(BottomFillagree.animForAnimIn, 2, 0.15, 1)

    CreateScaleAnim(SkullSpikes.animForAnimIn, 1, 0, 0.5, 0.5, 0.15)
    CreateScaleAnim(SkullSpikes.animForAnimIn, 2, 0.1, 2, 2, 0.1)
    CreateAlphaAnim(SkullSpikes.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(SkullSpikes.animForAnimIn, 2, 0.1, 1)

    CreateAlphaAnim(RightFillagree.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(RightFillagree.animForAnimIn, 2, 0.1, 1)
    CreateTranslationAnim(RightFillagree.animForAnimIn, 2, 0.15, 37 * bossBannerEffectiveScale, 0, 0.15)
    CreateScaleAnim(RightFillagree.animForAnimIn, 1, 0, 0.5, 0.5, 0.15, nil, nil, "BOTTOMLEFT")
    CreateScaleAnim(RightFillagree.animForAnimIn, 2, 0.15, 2, 2, 0.15, nil, nil, "BOTTOMLEFT")
    RightFillagree.animForAnimIn:SetScript("OnFinished", function()
        RightFillagree:SetPoint("CENTER", SkullCircle, "CENTER", 47, 6)
    end)

    CreateAlphaAnim(LeftFillagree.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(LeftFillagree.animForAnimIn, 2, 0.1, 1)
    CreateTranslationAnim(LeftFillagree.animForAnimIn, 2, 0.15, -37 * bossBannerEffectiveScale, 0, 0.15)
    CreateScaleAnim(LeftFillagree.animForAnimIn, 1, 0, 0.5, 0.5, 0.15, nil, nil, "BOTTOMRIGHT")
    CreateScaleAnim(LeftFillagree.animForAnimIn, 2, 0.15, 2, 2, 0.15, nil, nil, "BOTTOMRIGHT")
    LeftFillagree.animForAnimIn:SetScript("OnFinished", function()
        LeftFillagree:SetPoint("CENTER", SkullCircle, "CENTER", -47, 6)
    end)

    CreateAlphaAnim(BannerTopGlow.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(BannerTopGlow.animForAnimIn, 2, 0.25, 1, 0.9)
    CreateScaleAnim(BannerTopGlow.animForAnimIn, 1, 0, 0.5, 1, 0.15)
    CreateScaleAnim(BannerTopGlow.animForAnimIn, 2, 0.5, 3.2, 1, 0.9)
    CreateAlphaAnim(BannerTopGlow.animForAnimIn, 2, 0.6, -1, 1.1)

    CreateAlphaAnim(BannerBottomGlow.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(BannerBottomGlow.animForAnimIn, 2, 0.25, 1, 0.9)
    CreateScaleAnim(BannerBottomGlow.animForAnimIn, 1, 0, 0.5, 1, 0.15)
    CreateScaleAnim(BannerBottomGlow.animForAnimIn, 2, 0.5, 3.2, 1, 0.9)
    CreateAlphaAnim(BannerBottomGlow.animForAnimIn, 2, 0.6, -1, 1.1)

    CreateAlphaAnim(BannerMiddleGlow.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(BannerMiddleGlow.animForAnimIn, 2, 0.25, 1, 0.9)
    CreateScaleAnim(BannerMiddleGlow.animForAnimIn, 1, 0, 0.5, 1, 0.15)
    CreateScaleAnim(BannerMiddleGlow.animForAnimIn, 2, 0.5, 3.2, 1, 0.9)
    CreateAlphaAnim(BannerMiddleGlow.animForAnimIn, 2, 0.6, -1, 1.1)

    CreateAlphaAnim(Title.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(Title.animForAnimIn, 2, 0.25, 1, 0.2)

    CreateAlphaAnim(SubTitle.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(SubTitle.animForAnimIn, 1, 0.25, 1, 0.2)

    CreateAlphaAnim(RedFlash.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(RedFlash.animForAnimIn, 2, 0.1, 1)
    CreateScaleAnim(RedFlash.animForAnimIn, 1, 0, 2.5, 2.5, 0.15)
    CreateScaleAnim(RedFlash.animForAnimIn, 2, 0.25, 0.4, 0.4, nil, "IN")
    CreateAlphaAnim(RedFlash.animForAnimIn, 2, 0.5, -1, 0.25)

    CreateAlphaAnim(FlashBurst.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(FlashBurst.animForAnimIn, 2, 0.25, 1, 0.25)
    CreateScaleAnim(FlashBurst.animForAnimIn, 1, 0, 1, 0.75, 0.15, nil, nil, "LEFT")
    CreateScaleAnim(FlashBurst.animForAnimIn, 2, 0.4, 1.25, 1, 0.25, nil, nil, "LEFT")
    CreateTranslationAnim(FlashBurst.animForAnimIn, 2, 0.5, 10 * bossBannerEffectiveScale, 0, 0.25)
    CreateAlphaAnim(FlashBurst.animForAnimIn, 2, 0.4, -1, 0.25)

    CreateAlphaAnim(FlashBurstLeft.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(FlashBurstLeft.animForAnimIn, 2, 0.25, 1, 0.25)
    CreateScaleAnim(FlashBurstLeft.animForAnimIn, 1, 0, 1, 0.75, 0.15, nil, nil, "RIGHT")
    CreateScaleAnim(FlashBurstLeft.animForAnimIn, 2, 0.5, 1.25, 1, 0.25, nil, nil, "RIGHT")
    CreateTranslationAnim(FlashBurstLeft.animForAnimIn, 2, 0.5, -10 * bossBannerEffectiveScale, 0, 0.25)
    CreateAlphaAnim(FlashBurstLeft.animForAnimIn, 2, 0.5, -1, 0.25)

    CreateAlphaAnim(FlashBurstCenter.animForAnimIn, 1, 0, -1, nil, nil, 0.15)
    CreateAlphaAnim(FlashBurstCenter.animForAnimIn, 2, 0.25, 1, 0.25)
    CreateScaleAnim(FlashBurstCenter.animForAnimIn, 1, 0, 1, 1, 0.15)
    CreateScaleAnim(FlashBurstCenter.animForAnimIn, 2, 0.5, 1.25, 1.25, 0.25)
    CreateAlphaAnim(FlashBurstCenter.animForAnimIn, 2, 0.5, -1, 0.25)

    BossBanner.AnimIn = {}
    local AnimIn = BossBanner.AnimIn
    AnimIn.SkullCircle = SkullCircle.animForAnimIn
    AnimIn.BannerTop = BannerTop.animForAnimIn
    AnimIn.BannerBottom = BannerBottom.animForAnimIn
    AnimIn.BannerMiddle = BannerMiddle.animForAnimIn
    AnimIn.BottomFillagree = BottomFillagree.animForAnimIn
    AnimIn.SkullSpikes = SkullSpikes.animForAnimIn
    AnimIn.RightFillagree = RightFillagree.animForAnimIn
    AnimIn.LeftFillagree = LeftFillagree.animForAnimIn
    AnimIn.BannerTopGlow = BannerTopGlow.animForAnimIn
    AnimIn.BannerBottomGlow = BannerBottomGlow.animForAnimIn
    AnimIn.BannerMiddleGlow = BannerMiddleGlow.animForAnimIn
    AnimIn.RedFlash = RedFlash.animForAnimIn
    AnimIn.FlashBurst = FlashBurst.animForAnimIn
    AnimIn.FlashBurstLeft = FlashBurstLeft.animForAnimIn
    AnimIn.FlashBurstCenter = FlashBurstCenter.animForAnimIn
    AnimIn.Title = Title.animForAnimIn
    AnimIn.SubTitle = SubTitle.animForAnimIn

    AnimIn.Play = function(self)
        if BossBanner.AnimOut:IsPlaying() then
            BossBanner.AnimOut:Stop()
        end
        LeftFillagree:SetPoint("CENTER", SkullCircle, "CENTER", -10, 6)
        RightFillagree:SetPoint("CENTER", SkullCircle, "CENTER", 10, 6)
        SkullCircle:SetAlpha(1)
        LootCircle:SetAlpha(0)
        for _, anim in pairs(self) do
            if type(anim) == "table" then
                anim:Stop()
                anim:Play()
            end
        end
    end

    AnimIn.Stop = function(self)
        for _, anim in pairs(self) do
            if type(anim) == "table" then anim:Stop() end
        end
    end

    -- AnimationGroup: AnimSwitch (headline look -> loot look). Unused by our intro now, kept for parity.
    SkullCircle.animForAnimSwitch = SkullCircle:CreateAnimationGroup()
    Title.animForAnimSwitch = Title:CreateAnimationGroup()
    SubTitle.animForAnimSwitch = SubTitle:CreateAnimationGroup()
    LootCircle.animForAnimSwitch = LootCircle:CreateAnimationGroup()

    CreateAlphaAnim(SkullCircle.animForAnimSwitch, 1, 0, 1)
    CreateAlphaAnim(SkullCircle.animForAnimSwitch, 1, 0.5, -1)
    CreateAlphaAnim(Title.animForAnimSwitch, 1, 0, 1)
    CreateAlphaAnim(Title.animForAnimSwitch, 1, 0.25, -1)
    CreateAlphaAnim(SubTitle.animForAnimSwitch, 1, 0, 1)
    CreateAlphaAnim(SubTitle.animForAnimSwitch, 1, 0.25, -1)
    CreateAlphaAnim(LootCircle.animForAnimSwitch, 1, 0, 0)
    CreateAlphaAnim(LootCircle.animForAnimSwitch, 1, 0.5, 1)

    BossBanner.AnimSwitch = {}
    local AnimSwitch = BossBanner.AnimSwitch
    AnimSwitch.SkullCircle = SkullCircle.animForAnimSwitch
    AnimSwitch.Title = Title.animForAnimSwitch
    AnimSwitch.SubTitle = SubTitle.animForAnimSwitch
    AnimSwitch.LootCircle = LootCircle.animForAnimSwitch

    AnimSwitch.Play = function(self)
        SkullCircle:SetAlpha(0)
        Title:SetAlpha(0)
        SubTitle:SetAlpha(0)
        LootCircle:SetAlpha(1)
        for _, anim in pairs(self) do
            if type(anim) == "table" then
                anim:Stop()
                anim:Play()
            end
        end
    end

    AnimSwitch.Stop = function(self)
        for _, anim in pairs(self) do
            if type(anim) == "table" then anim:Stop() end
        end
    end

    --------------------------------------------------------------
    -- row engine + state machine (per-instance closures over BossBanner / textures)
    local relayoutAliveRows, aliveRowCount, addRow, updateRowLifetimes
    local BossBanner_OnAnimOutFinished, BossBanner_BeginAnims, fixTranslationAnim

    function relayoutAliveRows(self)
        local prev, count, rowsTotal = nil, 0, 0
        for _, f in ipairs(self.LootFrames) do
            if f.alive then
                count = count + 1
                rowsTotal = rowsTotal + (f.rowHeight or WON_ROW_H)
                f:ClearAllPoints()
                if prev then
                    f:SetPoint("TOP", prev, "BOTTOM", 0, -ROW_GAP)
                else
                    -- full mode reserves the medallion header (-84); minimalist starts near the top
                    f:SetPoint("TOP", self, "TOP", 0, self.minimal and -MINIMAL_PAD or -84)
                end
                prev = f
            end
        end
        local gaps = max(count - 1, 0) * ROW_GAP
        if self.minimal then
            -- no chrome: height is just the rows + a little padding top and bottom
            self:SetHeight(rowsTotal + gaps + MINIMAL_PAD * 2)
        else
            -- baseHeight reserves the chrome around one standard (won) row; swap that row's height out for
            -- the real per-row heights + gaps, so taller roll cards grow the banner by their extra height.
            self:SetHeight((self.baseHeight - WON_ROW_H) + rowsTotal + gaps)
        end
        return count
    end

    function aliveRowCount(self)
        local n = 0
        for _, f in ipairs(self.LootFrames) do
            if f.alive then n = n + 1 end
        end
        return n
    end

    function addRow(self, data)
        -- no row cap on either banner: rows come from a reuse pool (dead slots first, grow only on
        -- a new high-water mark), roll cards must all show (the ML decides how many go out), and
        -- won toasts drain themselves via resultHoldSeconds
        local additional = aliveRowCount(self) > 0   -- rows already shown => this is not the first item
        local frame, reused
        for _, f in ipairs(self.LootFrames) do
            if not f.alive and not f.fading then frame = f; reused = true; break end
        end
        if not frame then frame = createLootFrame(self) end
        BossBanner_ConfigureLootFrame(frame, data)
        frame.alive = true
        frame.fading = false
        frame.fadeLeft = 0
        frame:SetAlpha(1)
        frame:Show()
        if frame.Anim and not self.instant then frame.Anim:Play() end   -- instant: card just appears
        relayoutAliveRows(self)
        frame.holdOpen = nil            -- won-row hold state; set below for a held-open won row
        frame.closeImmediate = nil
        frame.CloseButton:Hide()        -- only a held-open won row shows it (armed below / by the timer)
        if data.rollDuration then
            -- roll-prompt row: a countdown of the roll timer + clickable bracket buttons. The live
            -- feed passes getTimeLeft (the roll's own deadline is the clock; self-correcting and
            -- pause-proof); plain data falls back to a local decrementing countdown, optionally
            -- starting partial via rollRemaining (mid-roll restore).
            frame.rollDuration = data.rollDuration
            frame.getTimeLeft = data.getTimeLeft
            frame.timeLeft = (data.getTimeLeft and data.getTimeLeft()) or data.rollRemaining or data.rollDuration
            frame.rowKey = data.key
            frame.isOwnerCard = data.isOwner
            frame.onPick = data.onPick
            frame.onExpired = data.onExpired
            frame.RollTimer:SetValue(max(frame.timeLeft, 0) / data.rollDuration)
            frame.RollTimer:SetStatusBarColor(0, 1, 0.1)
            frame.RollTimer:Show()
            frame.getRollers = data.getRollers
            frame.RollCount:SetText("")
            frame.RollCountChip:Hide()
            applyRollButtons(frame, data)   -- bracket availability + preselected pick
            -- ML rail: only a card given ML callbacks shows the controls (the real feed passes
            -- them only to the authorized loot master). Anchored per the current side each show.
            frame.onMLEnd = data.onMLEnd
            frame.onMLCancel = data.onMLCancel
            if data.onMLEnd or data.onMLCancel then
                anchorMLButtons(frame)
                for _, btn in ipairs(frame.MLButtons) do btn:SetAlpha(1); btn:Show() end
            else
                for _, btn in ipairs(frame.MLButtons) do btn:Hide() end
            end
            local b1 = frame.RollButtons[1]
            rbDbg(("add-DROP idx=%s reused=%s b_own=%.2f b_eff=%.2f f_own=%.2f f_eff=%.2f"):format(
                tostring(frame.__idx), tostring(reused), b1:GetAlpha(), b1:GetEffectiveAlpha(),
                frame:GetAlpha(), frame:GetEffectiveAlpha()))
            frame.__rbWatch = 0.35   -- one-shot re-check ~0.35s later
            return true
        end
        rbDbg(("add-WON idx=%s reused=%s rd=%s HIDE-buttons"):format(tostring(frame.__idx), tostring(reused), tostring(data.rollDuration)))
        frame.rollDuration = nil
        frame.getRollers = nil
        frame.getTimeLeft = nil
        frame.rowKey = nil
        frame.isOwnerCard = nil
        frame.onPick = nil
        frame.onExpired = nil
        frame.RollCount:SetText("")
        frame.RollCountChip:Hide()
        frame.RollTimer:Hide()
        for _, btn in ipairs(frame.RollButtons) do btn:Hide() end
        frame.onMLEnd, frame.onMLCancel = nil, nil
        for _, btn in ipairs(frame.MLButtons) do btn:Hide() end
        -- Won row lifetime. Every row runs the same examine countdown (the configured auto-hide
        -- seconds), and each additional drop EXTENDS the rows already shown by half (capped at the
        -- window), reviving any mid-fade, so earlier items linger to be read. A row whose client is
        -- NOT auto-hiding (loot master never-auto-hide, or auto-hide off) is "held open": at zero it
        -- does not fade -- it arms the manual close (X) instead and stays. The extension re-hides
        -- that X, so the close only reappears once fresh loot stops pushing the window out.
        local examine = resultExamineSeconds()
        frame.holdOpen = (resultHoldSeconds() == nil)
        frame.closeImmediate = frame.holdOpen and resultCloseImmediate()
        frame.timeLeft = examine
        if frame.closeImmediate then frame.CloseButton:Show() end   -- ML: no wait
        if additional then
            for _, f in ipairs(self.LootFrames) do
                if f.alive and f ~= frame and not f.rollDuration then
                    f.timeLeft = math.min(max(f.timeLeft, 0) + examine / 2, examine)
                    if f.fading then
                        rbDbg(("REVIVE idx=%s rd=%s (no button re-show)"):format(tostring(f.__idx), tostring(f.rollDuration)))
                        f.fading = false
                        f.fadeLeft = 0
                        f:SetAlpha(1)
                    end
                end
            end
        end
        return true
    end

    function updateRowLifetimes(self, elapsed)
        -- The reading pause holds WON rows only: a tooltip freezes their lifetime so the text can
        -- be read. Roll rows always tick; their clock is the raid's roll deadline, not the mouse.
        local paused = false
        if self.showingTooltip then
            self.hoveredThisVisit = true
            self.hoverGrace = nil
            paused = true
        elseif self.hoveredThisVisit then
            self.hoverGrace = (self.hoverGrace or 0.12) - elapsed
            if self.hoverGrace > 0 then
                paused = true
            else
                self.hoveredThisVisit = false
                self.hoverGrace = nil
                for _, f in ipairs(self.LootFrames) do
                    -- only auto-hiding won rows collapse to a 2s exit on mouse-off; a held-open row
                    -- keeps its window (it is meant to stay until manually closed)
                    if f.alive and not f.fading and not f.rollDuration and not f.holdOpen then f.timeLeft = 2 end
                end
            end
        end
        for _, f in ipairs(self.LootFrames) do
            if f.__rbWatch and f.alive then
                f.__rbWatch = f.__rbWatch - elapsed
                if f.__rbWatch <= 0 then
                    f.__rbWatch = nil
                    local b1 = f.RollButtons and f.RollButtons[1]
                    if b1 then
                        rbDbg(("watch-DROP idx=%s b_own=%.2f b_eff=%.2f f_own=%.2f f_eff=%.2f"):format(
                            tostring(f.__idx), b1:GetAlpha(), b1:GetEffectiveAlpha(),
                            f:GetAlpha(), f:GetEffectiveAlpha()))
                    end
                end
            end
        end
        local removed, stillCounting = false, 0
        for _, f in ipairs(self.LootFrames) do
            if f.alive then
                if paused and not f.rollDuration then
                    stillCounting = stillCounting + 1   -- won row held for reading: alive, not done
                elseif f.fading then
                    f.fadeLeft = f.fadeLeft - elapsed
                    if f.fadeLeft <= 0 then
                        rbDbg(("RM idx=%s rd=%s"):format(tostring(f.__idx), tostring(f.rollDuration)))
                        f.alive = false
                        f.fading = false
                        f:SetAlpha(1)   -- slot freed: restore base visual state for its next occupant
                        f:Hide()
                        if f.RollTimer then f.RollTimer:Hide() end
                        if f.RollCount then f.RollCount:SetText(""); f.RollCountChip:Hide() end
                        if f.RollButtons then for _, btn in ipairs(f.RollButtons) do btn:SetAlpha(1); btn:Hide() end end
                        if f.MLButtons then for _, btn in ipairs(f.MLButtons) do btn:SetAlpha(1); btn:Hide() end end
                        if f.CloseButton then f.CloseButton:Hide() end
                        removed = true
                    else
                        f:SetAlpha(f.fadeLeft / ROW_FADE_TIME)
                    end
                else
                    if f.getTimeLeft then
                        -- live feed: the roll's own deadline is the clock. Guard nil (a thunk whose
                        -- roll vanished) so a stray return can't crash the per-frame tick.
                        f.timeLeft = f.getTimeLeft() or 0
                    else
                        f.timeLeft = f.timeLeft - elapsed
                    end
                    if f.timeLeft <= 0 and f.holdOpen then
                        -- held open (never-auto-hide / auto-hide off): do not fade. Keep it alive and
                        -- arm the manual close -- immediately for the ML, else once the fade margin
                        -- past zero has elapsed (so it lines up with when a normal row would be gone).
                        stillCounting = stillCounting + 1
                        if f.closeImmediate or f.timeLeft <= -ROW_FADE_TIME then f.CloseButton:Show() end
                    elseif f.timeLeft <= 0 then
                        rbDbg(("FADE idx=%s rd=%s"):format(tostring(f.__idx), tostring(f.rollDuration)))
                        f.fading = true
                        f.fadeLeft = self.instant and 0 or ROW_FADE_TIME   -- instant: remove next tick, no fade
                        if f.rollDuration then f.RollTimer:Hide() end   -- roll time is up
                        if f.rollDuration and f.onExpired then
                            -- one-shot, deferred a frame: the callback resolves the roll (ML), which
                            -- closes cards and adds win rows; keep that out of this iteration
                            local cb = f.onExpired
                            f.onExpired = nil
                            schedule0(cb)
                        end
                    else
                        stillCounting = stillCounting + 1
                        if f.rollDuration then
                            local frac = max(f.timeLeft, 0) / f.rollDuration
                            f.RollTimer:SetValue(frac)
                            f.RollTimer:SetStatusBarColor(1 - frac, frac, 0.1)   -- green -> red
                            if f.getRollers then
                                local rollers = f.getRollers()
                                local n = rollers and #rollers or 0   -- guard a nil return
                                f.RollCount:SetText(n > 0 and n or "")
                                if n > 0 then f.RollCountChip:Show() else f.RollCountChip:Hide() end
                            end
                        elseif f.holdOpen and not f.closeImmediate then
                            f.CloseButton:Hide()   -- re-extended above zero by fresh loot: back in the window
                        end
                    end
                end
            end
        end
        if removed then relayoutAliveRows(self) end
        -- Start the whole-banner fade as soon as no row is still counting down (final item just began
        -- fading), so the chrome fades with it; the parent fade carries the still-fading rows out.
        if stillCounting == 0 then
            BossBanner.SetAnimState(self, BB_STATE_BANNER_OUT)
        end
    end

    -- state onStart funcs
    local function BossBanner_AnimBannerIn(self, entry)
        self.lootShown = 0
        if entry then
            -- instant: hand off to the rows this frame; minimal: skip the chrome flourish; full: 0.6s unfurl
            entry.duration = self.instant and 0 or (self.minimal and 0.05 or 0.6)
        end
        if not self.minimal and not self.instant then
            self.AnimIn:Play()
        end
    end
    local function BossBanner_AnimKillHold() end
    local function BossBanner_AnimSwitch(self, entry)
        entry.duration = 0   -- medallion is already the loot bag/dice; no crossfade
    end
    local function BossBanner_AnimLootExpand(self, entry)
        entry.duration = 0   -- height handled by relayoutAliveRows
    end
    local function BossBanner_AnimLootInsert(self, entry)
        while #self.pendingLoot > 0 do
            addRow(self, table.remove(self.pendingLoot, 1))
        end
        entry.duration = 86400
    end
    local function BossBanner_AnimBannerOut(self)
        rbDbg(("OUT-start %s alive=%d"):format(bannerName, aliveRowCount(self)))
        if self.instant then
            BossBanner_OnAnimOutFinished(self.AnimOut)   -- close immediately, no fade
            return true   -- redirected: don't enter the timed OUT state
        end
        self.AnimOut:Play()
    end

    local BB_ANIMATION_CONTROL = {
        -- unfurl/lightning groups run independently, so hand off to rows early (0.6s) and let the
        -- flourish finish behind the first item.
        [BB_STATE_BANNER_IN]   = { duration = 0.6,  onStartFunc = BossBanner_AnimBannerIn },
        [BB_STATE_KILL_HOLD]   = { duration = 0,    onStartFunc = BossBanner_AnimKillHold },
        [BB_STATE_SWITCH]      = { duration = nil,  onStartFunc = BossBanner_AnimSwitch },
        [BB_STATE_LOOT_EXPAND] = { duration = nil,  onStartFunc = BossBanner_AnimLootExpand },
        [BB_STATE_LOOT_INSERT] = { duration = nil,  onStartFunc = BossBanner_AnimLootInsert },
        [BB_STATE_BANNER_OUT]  = { duration = 5,    onStartFunc = BossBanner_AnimBannerOut },
    }

    function BossBanner_BeginAnims(self, animState)
        BossBanner.SetAnimState(self, animState or BB_STATE_BANNER_IN)
    end

    function BossBanner.SetAnimState(self, animState)
        local entry = BB_ANIMATION_CONTROL[animState]
        if entry then
            local redirected = entry.onStartFunc(self, entry)
            if not redirected then
                self.animState = animState
                self.animTimeLeft = entry.duration
            end
        else
            self.animState = nil
            self.animTimeLeft = nil
        end
    end

    function BossBanner_OnAnimOutFinished(animOut)
        local banner = animOut:GetParent()
        rbDbg(("OUT-done %s"):format(bannerName))
        banner.animState = nil
        if banner.showingTooltip or banner.showingRollerTip then GameTooltip:Hide() end
        banner.showingTooltip = false
        banner.showingRollerTip = false
        banner.hoveredThisVisit = false
        banner.hoverGrace = nil
        banner:Hide()
        banner:SetHeight(banner.baseHeight)
        for i = 1, #banner.LootFrames do
            local f = banner.LootFrames[i]
            f.alive = false
            f.fading = false
            f:SetAlpha(1)
            if f.RollTimer then f.RollTimer:Hide() end
            if f.RollButtons then for _, btn in ipairs(f.RollButtons) do btn:SetAlpha(1); btn:Hide() end end
            if f.MLButtons then for _, btn in ipairs(f.MLButtons) do btn:SetAlpha(1); btn:Hide() end end
            if f.CloseButton then f.CloseButton:Hide() end
            f:Hide()
        end
        banner:SetHeight(banner.baseHeight)
        wipe(banner.seenKeys)
        if banner.onLayoutChanged then banner.onLayoutChanged() end
    end

    -- AnimationGroup: AnimOut
    BossBanner.AnimOut = BossBanner:CreateAnimationGroup()
    CreateAlphaAnim(BossBanner.AnimOut, 1, 0, 1)
    CreateAlphaAnim(BossBanner.AnimOut, 1, 0.5, -1)
    BossBanner.AnimOut:SetScript("OnFinished", function(self)
        BossBanner_OnAnimOutFinished(self)
    end)

    -- 3.3.5a Translation animations don't account for UIScale; re-validate offsets against scale
    local defaultTranslationOffsetsTable = {
        ["RightFillagree-To"] = {37, 0},
        ["LeftFillagree-To"] = {-37, 0},
        ["FlashBurst-To"] = {10, 0},
        ["FlashBurstLeft-To"] = {-10, 0},
        ["LootFrame-Icon-From"] = {110, 0},
        ["LootFrame-Icon-To"] = {-110, 0},
    }
    local function validateOffsets(animation, defaultkey, effectiveScale)
        local xOffset, yOffset = animation:GetOffset()
        if round(xOffset, 0) ~= round((defaultTranslationOffsetsTable[defaultkey][1] * effectiveScale), 0) then
            xOffset = defaultTranslationOffsetsTable[defaultkey][1] * effectiveScale
        end
        if round(yOffset, 0) ~= round((defaultTranslationOffsetsTable[defaultkey][2] * effectiveScale), 0) then
            yOffset = defaultTranslationOffsetsTable[defaultkey][2] * effectiveScale
        end
        animation:SetOffset(xOffset, yOffset)
    end
    function fixTranslationAnim()
        local effectiveScale = BossBanner:GetEffectiveScale()
        local rightFillagreeTo = (select(3, BossBanner.RightFillagree.animForAnimIn:GetAnimations()))
        local leftFillagreeTo = (select(3, BossBanner.LeftFillagree.animForAnimIn:GetAnimations()))
        local flashBurstTo = (select(5, BossBanner.FlashBurst.animForAnimIn:GetAnimations()))
        local flashBurstLeftTo = (select(5, BossBanner.FlashBurstLeft.animForAnimIn:GetAnimations()))
        validateOffsets(rightFillagreeTo, "RightFillagree-To", effectiveScale)
        validateOffsets(leftFillagreeTo, "LeftFillagree-To", effectiveScale)
        validateOffsets(flashBurstTo, "FlashBurst-To", effectiveScale)
        validateOffsets(flashBurstLeftTo, "FlashBurstLeft-To", effectiveScale)
        for _, lootFrame in ipairs(BossBanner.LootFrames) do
            local from, to = select(3, lootFrame.Icon.animForAnim:GetAnimations())
            validateOffsets(from, "LootFrame-Icon-From", effectiveScale)
            validateOffsets(to, "LootFrame-Icon-To", effectiveScale)
            from, to = lootFrame.IconHitBox.animForAnim:GetAnimations()
            validateOffsets(from, "LootFrame-Icon-From", effectiveScale)
            validateOffsets(to, "LootFrame-Icon-To", effectiveScale)
        end
    end

    local function applyMedallion(self)
        if medallionCfg and medallionCfg.texture then
            self.SkullCircle:SetTexture(medallionCfg.texture)
            self.SkullCircle:SetTexCoord(0, 1, 0, 1)
            self.SkullCircle:SetSize(40, 40)
        else
            SetAtlas(self.SkullCircle, (medallionCfg and medallionCfg.atlas) or "LootBanner-LootBagCircle", true)
        end
    end

    local function BossBanner_Play(self, data)
        if not data then return end
        self.minimal = bannerMinimal()
        self.instant = bannerInstant()
        -- intro: keep the unfurl + lightning, show the medallion (bag or dice) right away, no title hold.
        -- Minimalist mode hides all chrome and skips the flourish; each card's left badge stands in.
        applyMedallion(self)
        self.LootCircle:SetAlpha(0)
        self.Title:Hide()
        self.SubTitle:Hide()
        self:SetAlpha(1)   -- a prior fade-out left the frame alpha low; instant mode never replays AnimIn to reset it
        setChromeShown(self, not self.minimal)
        if not self.minimal and not self.instant then fixTranslationAnim() end
        self:Show()
        BossBanner_BeginAnims(self)
        if self.onLayoutChanged then self.onLayoutChanged() end
    end

    local function BossBanner_Stop(self)
        self.AnimIn:Stop()
        self.AnimSwitch:Stop()
        self.AnimOut:Stop()
        self:Hide()
    end

    -- Add one item (or roll prompt). Inserts into a live banner, interrupts a fade, or unfurls fresh.
    -- Returns true when the banner took (or queued, or already shows) the item; false when it can't
    -- (zero hold time on a win toast) so a live feed can fall back instead of losing anything.
    local function BossBanner_AddItem(self, item)
        if not item or not item.link then return false end
        -- duration 0 means "no win toasts"; a roll prompt is not a toast and must still show
        if resultHoldSeconds() == 0 and not item.rollDuration then return false end
        if item.key then
            if self.seenKeys[item.key] then
                -- Already showing. For a roll card this means a ledger restore raced the DROP: the
                -- restore guessed the timing (local default duration) and prio, and the DROP now
                -- carries the ML's authoritative values. The popup path fixes this by re-binding
                -- its reused frame; the card equivalent is re-asserting timing + prio on the live
                -- row (callbacks already resolve the current roll by id, so they need no rebind).
                if item.rollDuration then
                    for _, f in ipairs(self.LootFrames) do
                        if f.alive and not f.fading and f.rowKey == item.key and f.rollDuration then
                            f.rollDuration = item.rollDuration   -- bar denominator
                            f.PlayerName:SetText(rollPrioText(item.prio))
                            -- recompute bracket availability from the authoritative feed: a card first
                            -- shown from a restore's guessed (empty) prio had BiS wrongly gated; the DROP
                            -- carries the real prio, so re-apply the disabled map + preselected pick here
                            applyRollButtons(f, item)
                            -- timing needs no re-assert: getTimeLeft reads the current roll's
                            -- deadline, which the newer feed already corrected
                            if not f.getTimeLeft then   -- plain-decrement path: keep the bar consistent
                                f.timeLeft = item.rollRemaining or item.rollDuration
                                f.RollTimer:SetValue(max(f.timeLeft, 0) / item.rollDuration)
                            end
                        end
                    end
                end
                return true   -- handled, not lost
            end
            self.seenKeys[item.key] = true
        end
        local data = {
            itemLink = item.link, texture = item.icon, quantity = item.quantity or 1,
            fallbackName = item.fallbackName, -- shown when the link is a bare item:id (cold cache)
            winner = item.winner, winnerClass = item.winnerClass, why = item.why,
            winners = item.winners, rolls = item.rolls, prompt = item.prompt, rollDuration = item.rollDuration,
            rollRemaining = item.rollRemaining, -- static seconds-left (demo/plain data; ignored with a thunk)
            getTimeLeft = item.getTimeLeft, -- live feed: per-tick seconds left from the roll's own deadline
            key = item.key,             -- roll card only: lets the live feed close/update the card by id
            disabled = item.disabled,   -- bracket label -> true or reason text (hover explains the dead button)
            selected = item.selected,   -- roll card only: bracket label to open pre-highlighted (prior pick)
            prio = item.prio,           -- roll card only: the item's listed priority, shown under the name
            isOwner = item.isOwner,     -- roll card only: the loot master's card never dismisses on repeat click
            onPick = item.onPick,       -- roll card only: fired with the bracket label on every selection
            onChosen = item.onChosen,   -- roll card only: fired with the chosen bracket when the card is dismissed
            onExpired = item.onExpired, -- roll card only: fired once when the countdown hits zero
            onMLEnd = item.onMLEnd,     -- roll card only: ML control; present = show the End button, fired on click
            onMLCancel = item.onMLCancel, -- roll card only: ML control; present = show the Cancel button
            getRollers = item.getRollers, -- roll card only: thunk returning { name, class, bracket } rollers for the hover
        }
        if self.animState == BB_STATE_LOOT_INSERT then
            local ok = addRow(self, data)
            if not ok and item.key then self.seenKeys[item.key] = nil end   -- row cap: not showing after all
            return ok
        elseif self.animState == BB_STATE_BANNER_OUT then
            rbDbg(("INTERRUPT %s alive=%d"):format(bannerName, aliveRowCount(self)))
            self.AnimOut:Stop()
            self:SetAlpha(1)
            self.animState = BB_STATE_LOOT_INSERT
            self.animTimeLeft = 86400
            local ok = addRow(self, data)
            if not ok and item.key then self.seenKeys[item.key] = nil end
            return ok
        elseif not self.animState then
            tinsert(self.pendingLoot, data)
            self:PlayBanner({ mode = "KILL" })
            return true
        else
            tinsert(self.pendingLoot, data)
            return true
        end
    end

    local function BossBanner_OnLoad(self)
        self.PlayBanner = BossBanner_Play
        self.StopBanner = BossBanner_Stop
        self.AddItem = BossBanner_AddItem
        self.pendingLoot = {}
        self.seenKeys = {}
        self.showingTooltip = false
        self.hoveredThisVisit = false
        self.hoverGrace = nil
        self.baseHeight = self:GetHeight()
    end

    local function BossBanner_OnUpdate(self, elapsed)
        if #scheduleQueue > 0 then
            local pending = scheduleQueue
            scheduleQueue = {}
            for _, item in ipairs(pending) do
                item.fn(unpack(item.args))
            end
        end
        if not self.animState then return end
        if self.animState == BB_STATE_LOOT_INSERT then
            updateRowLifetimes(self, elapsed)
            return
        end
        self.animTimeLeft = self.animTimeLeft - elapsed
        if self.animTimeLeft <= 0 then
            BossBanner.SetAnimState(self, self.animState + 1)
            if not self.animTimeLeft then
                self.animState = nil
            end
        end
    end

    BossBanner_OnLoad(BossBanner)
    BossBanner:SetScript("OnUpdate", BossBanner_OnUpdate)
    -- chrome hover (rows and buttons capture their own mouse): same roller list as a roll card
    BossBanner:SetScript("OnEnter", showRollersTooltip)
    BossBanner:SetScript("OnLeave", BossBanner_OnLootItemLeave)
    BossBanner:HookScript("OnShow", function() if BossBanner.onLayoutChanged then BossBanner.onLayoutChanged() end end)
    BossBanner:HookScript("OnHide", function() if BossBanner.onLayoutChanged then BossBanner.onLayoutChanged() end end)

    return BossBanner
end

------------------------------------------------------------------
-- Two banner instances stacked in one region: drops (dice) above, awarded (bag) below.
local awardedBanner = buildBanner("WeirdLootAwardedBanner",
    -- badge: the medallion's own pouch cluster cut free of its dark disc (Textures/LootPouches.blp,
    -- derived from the LootBagCircle atlas region)
    { atlas = "LootBanner-LootBagCircle", badgeTexture = "Interface\\AddOns\\WeirdLoot\\Textures\\LootPouches" })
local dropsBanner = buildBanner("WeirdLootDropsBanner", { texture = DICE_TEXTURE })

local REGION_TOP = -120
-- positive pulls the awarded banner UP into the drops banner's bottom chrome reserve, closing the
-- dead space between the last drop row and the awarded medallion. Tune to taste.
local REGION_OVERLAP = 34

-- One movable anchor owns the whole loot region: dragging either banner moves rolls + wins
-- together, and the spot persists (db.ui.lootBannerRegion). Default is top-center.
local bannerRegion = CreateFrame("Frame", "WeirdLootBannerRegion", UIParent)
bannerRegion:SetSize(1, 1)
bannerRegion:SetPoint("TOP", UIParent, "TOP", 0, REGION_TOP)
bannerRegion:SetMovable(true)

local function saveRegionPosition()
    if not (addon.db and addon.db.ui) then return end
    local point, _, relativePoint, x, y = bannerRegion:GetPoint()
    addon.db.ui.lootBannerRegion = { point = point, relativePoint = relativePoint, x = x, y = y }
end

-- lazy one-shot: the file loads before the saved variables do, so the first layout after the db
-- exists puts the region back where the player last dragged it
local regionRestored
local function restoreRegionPosition()
    if regionRestored or not (addon.db and addon.db.ui) then return end
    regionRestored = true
    local pos = addon.db.ui.lootBannerRegion
    if not pos or not pos.point then return end
    bannerRegion:ClearAllPoints()
    bannerRegion:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
end

local function enableRegionDrag(banner)
    local function dragStart() if not bannerLocked() then bannerRegion:StartMoving() end end
    local function dragStop()
        bannerRegion:StopMovingOrSizing()   -- harmless if StartMoving never fired (locked)
        saveRegionPosition()
    end
    banner:RegisterForDrag("LeftButton")
    banner:SetScript("OnDragStart", dragStart)
    banner:SetScript("OnDragStop", dragStop)
    -- the loot rows forward their drags here (they exist before the region anchor does)
    banner.onRegionDragStart = dragStart
    banner.onRegionDragStop = dragStop
end
enableRegionDrag(dropsBanner)
enableRegionDrag(awardedBanner)

local function layoutRegion()
    restoreRegionPosition()
    dropsBanner:ClearAllPoints()
    dropsBanner:SetPoint("TOP", bannerRegion, "TOP", 0, 0)
    awardedBanner:ClearAllPoints()
    if dropsBanner:IsShown() then
        -- full mode overlaps into the drops footer chrome; minimalist has none, so just leave a small gap
        local gap = bannerMinimal() and -MINIMAL_PAD or REGION_OVERLAP
        awardedBanner:SetPoint("TOP", dropsBanner, "BOTTOM", 0, gap)   -- moves as drops resizes
    else
        awardedBanner:SetPoint("TOP", bannerRegion, "TOP", 0, 0)
    end
end
dropsBanner.onLayoutChanged = layoutRegion
awardedBanner.onLayoutChanged = layoutRegion
layoutRegion()

local bannerAnchorPreview   -- the config-anchor placeholder (built lazily by SetLootBannerAnchorShown)

-- Options "Reset banner position": drop the saved spot and snap the region back to the default
-- (top-center), so a banner parked off-screen is recoverable without editing SavedVariables.
function addon:ResetLootBannerPosition()
    if addon.db and addon.db.ui then addon.db.ui.lootBannerRegion = nil end
    bannerRegion:ClearAllPoints()
    bannerRegion:SetPoint("TOP", UIParent, "TOP", 0, REGION_TOP)
    layoutRegion()
    if bannerAnchorPreview and bannerAnchorPreview:IsShown() then bannerAnchorPreview:ClearAllPoints()
        bannerAnchorPreview:SetPoint("TOP", bannerRegion, "TOP", 0, 0) end
end

-- Config anchor: a placeholder sitting exactly where the banners appear, shown while the Options
-- tab is open so the region can be dragged into place without waiting for a real loot drop. Built
-- lazily on first show; drags move the same region the live banners hang off (honoring the lock).
local ANCHOR_PREVIEW_ROLLS, ANCHOR_PREVIEW_WINS = 3, 3   -- footprint the placeholder simulates
local function buildBannerAnchorPreview()
    local PAD, ZONE_GAP = 8, 10
    local rollZoneH = ANCHOR_PREVIEW_ROLLS * DROP_ROW_H + (ANCHOR_PREVIEW_ROLLS - 1) * ROW_GAP
    local winZoneH  = ANCHOR_PREVIEW_WINS * WON_ROW_H + (ANCHOR_PREVIEW_WINS - 1) * ROW_GAP
    local totalH = PAD + rollZoneH + ZONE_GAP + winZoneH + PAD

    local f = CreateFrame("Frame", "WeirdLootBannerAnchorPreview", UIParent)
    f:SetSize(269, totalH)   -- the space three rolls + three wins occupy at once
    f:SetPoint("TOP", bannerRegion, "TOP", 0, 0)
    f:SetFrameStrata("MEDIUM")   -- one band below the HIGH main window, so it sits behind it
    f:EnableMouse(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.08, 0.08, 0.08, 0.82)
    f:SetBackdropBorderColor(1, 0.82, 0, 0.8)

    -- faint slot rectangles, roll-height then win-height, so the placeholder reads as the real stack.
    -- Recorded on f.slots so the locked state can desaturate them (tinted -> gray).
    f.slots = {}
    local function slot(y, h, r, g, b)
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetVertexColor(r, g, b, 0.16)
        t:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        t:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
        t:SetHeight(h)
        f.slots[#f.slots + 1] = { tex = t, r = r, g = g, b = b }
    end
    local y = -PAD
    for _ = 1, ANCHOR_PREVIEW_ROLLS do
        slot(y, DROP_ROW_H, 0.4, 0.7, 1.0)   -- roll slots: cool tint (dice)
        y = y - DROP_ROW_H - ROW_GAP
    end
    y = y + ROW_GAP - ZONE_GAP
    for _ = 1, ANCHOR_PREVIEW_WINS do
        slot(y, WON_ROW_H, 1.0, 0.82, 0.2)   -- win slots: gold tint (bag)
        y = y - WON_ROW_H - ROW_GAP
    end

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("CENTER", 0, 8)
    f.title:SetText("WeirdLoot Loot Banner")
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hint:SetPoint("CENTER", 0, -8)

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if not bannerLocked() then bannerRegion:StartMoving() end
    end)
    f:SetScript("OnDragStop", function()
        bannerRegion:StopMovingOrSizing()
        saveRegionPosition()
        f:ClearAllPoints()
        f:SetPoint("TOP", bannerRegion, "TOP", 0, 0)   -- follow the region to its dropped spot
    end)
    f:Hide()
    return f
end

-- Called by the tab system: show the placeholder while the Options tab is open, hide it otherwise.
function addon:SetLootBannerAnchorShown(shown)
    if not shown then
        if bannerAnchorPreview then bannerAnchorPreview:Hide() end
        return
    end
    local f = bannerAnchorPreview or buildBannerAnchorPreview()
    bannerAnchorPreview = f
    f:ClearAllPoints()
    f:SetPoint("TOP", bannerRegion, "TOP", 0, 0)

    -- Locked: fade the whole placeholder and desaturate its slots (gray), so it reads as inert.
    local locked = bannerLocked()
    f.hint:SetText(locked and "|cffff5555locked|r" or "drag to move")
    f:EnableMouse(not locked)
    f:SetAlpha(locked and 0.4 or 1)
    f:SetBackdropBorderColor(locked and 0.5 or 1, locked and 0.5 or 0.82, locked and 0.5 or 0, 0.8)
    for _, s in ipairs(f.slots) do
        if locked then
            local lum = 0.3 * s.r + 0.59 * s.g + 0.11 * s.b
            s.tex:SetVertexColor(lum, lum, lum, 0.16)
        else
            s.tex:SetVertexColor(s.r, s.g, s.b, 0.16)
        end
    end
    f:Show()
end

------------------------------------------------------------------
-- public API
function addon:AddLootBannerItem(item)
    awardedBanner:AddItem(item)
end

function addon:AddRollBannerItem(item)
    return dropsBanner:AddItem(item)
end

-- Close a live roll card by its key (the lot id): WIN, CANCEL, or any wire-side end of the roll.
-- Also clears the dedupe key so the same lot can roll again later (cancel -> re-roll).
function addon:CloseRollBannerCard(key)
    if not key then return end
    dropsBanner.seenKeys[key] = nil
    for _, f in ipairs(dropsBanner.LootFrames) do
        if f.alive and not f.fading and f.rowKey == key then
            f.rowKey = nil
            f.onExpired = nil
            f.FadeOutNow()
        end
    end
end

-- Re-render a card's item visuals in place once a cold item cache resolves (the live feed's name
-- ticker calls this with the real link); the roll state, buttons, and countdown are untouched.
function addon:RefreshRollBannerCard(key, link, icon)
    if not (key and link) then return end
    for _, f in ipairs(dropsBanner.LootFrames) do
        if f.alive and f.rowKey == key and f.rollDuration then
            applyItemVisuals(f, link, icon)
        end
    end
end

-- Reflect the local player's pick on an open roll card (loot-tab picks and the popup path both
-- route through ApplyLocalChoice); nil clears the highlight, mirroring the popup behavior.
function addon:SetRollBannerCardChoice(key, bracket)
    for _, f in ipairs(dropsBanner.LootFrames) do
        if f.alive and not f.fading and f.rowKey == key and f.rollDuration then
            for _, b in ipairs(f.RollButtons) do
                if b:GetButtonState() ~= "DISABLED" then
                    b:UnlockHighlight()
                    b:GetFontString():SetTextColor(1, 0.82, 0)
                    if bracket and b.bracket == bracket then
                        b:LockHighlight()
                        b:GetFontString():SetTextColor(0, 1, 0)
                    end
                end
            end
            f.selectedBracket = bracket
        end
    end
end

function addon:ShowLootBanner(opts)
    if not opts then return end
    for _, it in ipairs(opts.items or {}) do
        awardedBanner:AddItem(it)
    end
end

-- DEBUG preview: strip before commit. `/wlbanner` drives BOTH banners with sample data so the stacked
-- region (dice drops + bag awarded, both with the lightning intro) can be seen under realistic flow.
local wlbannerTimer = CreateFrame("Frame")

-- EXAMPLE ONLY: fire one-shot callbacks after a delay (used to show a chosen roll as a win a couple
-- seconds after it's dismissed). This is demo plumbing for /wlbanner, NOT real banner behavior.
local exampleDeferQueue = {}
local exampleDefer = CreateFrame("Frame")
exampleDefer:SetScript("OnUpdate", function(_, e)
    for i = #exampleDeferQueue, 1, -1 do
        local job = exampleDeferQueue[i]
        job.t = job.t - e
        if job.t <= 0 then table.remove(exampleDeferQueue, i); job.fn() end
    end
end)
local function exampleAfter(delay, fn)
    exampleDeferQueue[#exampleDeferQueue + 1] = { t = delay, fn = fn }
end

local function runBannerExample()
    local bases = {
        { link = "|cffa335ee|Hitem:40629:0:0:0:0:0:0:0:0|h[Gauntlets of the Lost Protector]|h|r", icon = "Interface\\Icons\\inv_gauntlets_28" },
        { link = "|cff0070dd|Hitem:40207:0:0:0:0:0:0:0:0|h[Gloves of the Lost Protector]|h|r", icon = "Interface\\Icons\\inv_gauntlets_25" },
        { link = "|cffa335ee|Hitem:40558:0:0:0:0:0:0:0:0|h[Leggings of the Lost Vanquisher]|h|r", icon = "Interface\\Icons\\inv_pants_plate_19" },
        { link = "|cff1eff00|Hitem:39071:0:0:0:0:0:0:0:0|h[Wending Cloak]|h|r", icon = "Interface\\Icons\\inv_misc_cape_19" },
        { link = "|cffff8000|Hitem:49623:0:0:0:0:0:0:0:0|h[Shadowmourne]|h|r", icon = "Interface\\Icons\\inv_axe_113" },
    }
    -- Example only (not real-use logic): hand out each base at most once so no two cards show the same
    -- item. A single card may still display a multi-copy quantity; we just never duplicate an item card.
    local basePool = {}
    for _, b in ipairs(bases) do basePool[#basePool + 1] = b end
    for i = #basePool, 2, -1 do local j = math.random(i); basePool[i], basePool[j] = basePool[j], basePool[i] end
    local function takeBase() return table.remove(basePool) end

    -- The player plus a few filler names. Drop any filler whose name collides with the player's (these
    -- are real alt names), or the same person would roll twice and "win" two copies in the example.
    local playerName = UnitName("player")
    local roster = { { n = playerName, c = (UnitClass("player")) } }
    for _, e in ipairs({
        { n = "Dremera", c = "Mage" }, { n = "Borgakh", c = "Warrior" },
        { n = "Anagke", c = "Paladin" }, { n = "Thordris", c = "Shaman" }, { n = "Veylin", c = "Priest" },
    }) do
        if e.n ~= playerName then roster[#roster + 1] = e end
    end
    local responses = { "bis", "ms", "mu", "os" }

    local LABEL = { bis = "BiS", ms = "MS", mu = "MU", os = "OS" }
    local statuses = { "main", "designatedalt", "nil" }

    local function buildWon(base, forceQty)
        local quantity = forceQty or ((math.random(3) == 1) and math.random(2, 3) or 1)
        local pool = {}
        for _, p in ipairs(roster) do pool[#pool + 1] = p end
        for i = #pool, 2, -1 do local j = math.random(i); pool[i], pool[j] = pool[j], pool[i] end
        local n = math.min(#pool, quantity + math.random(1, 4))

        -- rollers get a bracket, roll, raid status, and an occasional "named on the item" (LC prio) flag
        local details, classByName = {}, {}
        for i = 1, n do
            classByName[pool[i].n] = pool[i].c
            details[i] = {
                name = pool[i].n,
                responseType = responses[math.random(#responses)],
                roll = math.random(1, 100),
                status = statuses[math.random(#statuses)],
                isNamed = false,
            }
        end
        if math.random(2) == 1 then details[math.random(n)].isNamed = true end   -- ~half: one named roller

        -- Breakdown grouping mirrors the resolver's status gate: within BiS a Main beats any Alt
        -- regardless of roll, so BiS splits into a "BiS - Main" tier above a "BiS - Alt" tier. MS/MU/OS
        -- are pure roll (status only gates roster-vs-nil there, which the example glosses over). `group`
        -- is the bracket the tooltip separates on; `section` is the display label. Named rollers go under
        -- LC, their own top tier.
        local function groupOf(d) return d.isNamed and "LC" or (d.responseType == "bis" and "BiS" or LABEL[d.responseType]) end
        local function sectionOf(d)
            if d.isNamed then return "LC" end
            if d.responseType == "bis" then return (d.status == "main") and "BiS - Main" or "BiS - Alt" end
            return LABEL[d.responseType]
        end
        local priorityOrder = { "LC", "BiS - Main", "BiS - Alt", "MS", "MU", "OS" }
        local groups = {}
        for _, d in ipairs(details) do
            local sec = sectionOf(d)
            groups[sec] = groups[sec] or {}
            groups[sec][#groups[sec] + 1] = { name = d.name, class = classByName[d.name],
                roll = d.roll, section = sec, group = groupOf(d) }
        end
        local rolls = {}
        for _, sec in ipairs(priorityOrder) do
            local g = groups[sec]
            if g then
                table.sort(g, function(a, b) return (a.roll or 0) > (b.roll or 0) end)
                for _, m in ipairs(g) do rolls[#rolls + 1] = m end
            end
        end

        -- Winners are simply the first `quantity` of that priority-ordered, roll-sorted breakdown: named
        -- (LC) take copies first, then BiS Mains, then BiS Alts, then MS/MU/OS by roll. A copy never goes
        -- to a lower roll within the same tier. The winner line shows the short bracket, not the Main/Alt tier.
        local winners = {}
        for i = 1, math.min(quantity, #rolls) do
            local m = rolls[i]
            winners[i] = { name = m.name, class = m.class, roll = m.roll, section = m.group }
        end
        return { link = base.link, icon = base.icon, quantity = quantity, winners = winners, rolls = rolls }
    end
    local function wonItem(forceQty)
        local base = takeBase()
        if not base then return nil end   -- example pool exhausted: skip rather than repeat an item
        return buildWon(base, forceQty)
    end

    local samplePrios = { "DK > Warrior > MS", "MS > OS", "LC", "Healers > MS" }
    local function rollItem()
        local base = takeBase()
        if not base then return nil end   -- example pool exhausted: skip rather than repeat an item
        -- drop row: clickable bracket buttons + a roll countdown bar driven by the configured duration
        local rollDur = (addon.db and addon.db.options and tonumber(addon.db.options.rollDuration)) or 30
        local awarded = false
        -- EXAMPLE ONLY: rollers trickle in over the countdown's first half so the "Players Rolling"
        -- hover has live content. The real feed will read the roll's registrants instead.
        local rollers = {}
        local exampleBrackets = { "BiS", "MS", "MU", "OS", "TM" }
        local pool = {}
        for _, p in ipairs(roster) do pool[#pool + 1] = p end
        for i = #pool, 2, -1 do local j = math.random(i); pool[i], pool[j] = pool[j], pool[i] end
        for _ = 1, math.random(2, math.min(5, #pool)) do
            local p = table.remove(pool)
            exampleAfter(0.5 + math.random() * rollDur * 0.4, function()
                if not awarded then
                    rollers[#rollers + 1] = { name = p.n, class = p.c, bracket = exampleBrackets[math.random(#exampleBrackets)] }
                end
            end)
        end
        return { link = base.link, icon = base.icon, quantity = 1, rollDuration = rollDur,
            prio = samplePrios[math.random(#samplePrios)],
            getRollers = function() return rollers end,
            -- EXAMPLE ONLY: when the player dismisses this roll by selecting a bracket twice, drop the
            -- same item into the won section ~2s later, as if the roll resolved in their favor. Real
            -- banners get wins from the loot master's resolve, never from a local click; this only
            -- exists to demo the roll -> won flow in /wlbanner.
            onChosen = function(bracket)
                if awarded or bracket == "Pass" then return end
                awarded = true
                exampleAfter(2, function() addon:AddLootBannerItem(buildWon(base, 1)) end)
            end,
            -- EXAMPLE ONLY: ML controls on the roll card (the demo player acts as the ML). End
            -- resolves the roll now (same demo award as a dismissed pick); Cancel aborts it with
            -- no award. Real banners will pass these only for the authorized loot master.
            onMLEnd = function()
                if awarded then return end
                awarded = true
                exampleAfter(2, function() addon:AddLootBannerItem(buildWon(base, 1)) end)
            end,
            onMLCancel = function() awarded = true end }
    end

    -- DROPS banner: a couple of items up for roll (dice medallion).
    -- preview #1: standard disabled brackets, each with the popup's hover reason for its dead button
    local firstRoll = rollItem()
    if firstRoll then
        firstRoll.disabled = {
            MU = "Your class cannot use this item.",
            OS = "Not used for this item type.",
            TM = "You already have this unique item.",
        }
    end
    addon:AddRollBannerItem(firstRoll)
    addon:AddRollBannerItem(rollItem())

    -- AWARDED banner: a multi-copy win plus a few stragglers (bag medallion).
    addon:AddLootBannerItem(wonItem(math.random(2, 3)))
    local remaining = math.random(1, 3)
    local elapsed, nextAt = 0, 1 + math.random() * 2.5
    wlbannerTimer:SetScript("OnUpdate", function(self, e)
        elapsed = elapsed + e
        if elapsed >= nextAt then
            addon:AddLootBannerItem(wonItem())
            remaining = remaining - 1
            nextAt = elapsed + 0.8 + math.random() * 3
            if remaining <= 0 then self:SetScript("OnUpdate", nil) end
        end
    end)
end

-- `/wlbanner` previews the stacked banners (dice drops + bag awarded) with sample data, using the
-- current Options-tab look (minimal/instant/ML-side): toggle those in Options, then re-run to see it.
SLASH_WLBANNER1 = "/wlbanner"
SlashCmdList["WLBANNER"] = function() runBannerExample() end
