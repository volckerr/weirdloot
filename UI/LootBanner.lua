-- DBM-style "loot awarded" toast. This is a faithful port of DBM-Core's BossBannerToast (itself a
-- 3.3.5a backport of retail's Blizzard_FrameXML/BossBannerToast) adapted to announce WeirdLoot roll
-- results: a gold banner animates in with a skull/loot-bag medallion, then per-item rows slide in
-- showing the item icon (rarity-bordered), name, and the winning player.
--
-- The animation timings and atlas texture coordinates are copied verbatim from DBM so the look and
-- feel matches the boss-kill banner raiders already know. What changed are the seams: the frame is
-- renamed (WeirdLootBanner) so it never collides with DBM's own global BossBanner frame, textures
-- load from our own Textures folder, all DBM-internal hooks (encounter sync, debug, font options)
-- are removed, and loot is fed in directly via addon:ShowLootBanner instead of scraped from the
-- loot window.

local addon = WeirdLoot
local util = addon.util

local tinsert = table.insert
local strformat = string.format
local strfind = string.find
local max = math.max
local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

local BANNER_TEXTURE = "Interface\\AddOns\\WeirdLoot\\Textures\\BossBanner"
local ICON_BORDER_TEXTURE = "Interface\\AddOns\\WeirdLoot\\Textures\\WhiteIconFrame"

local BB_EXPAND_TIME = 0.25         -- time to expand per item
local BB_EXPAND_HEIGHT = 50         -- pixels to expand per item
local BB_MAX_LOOT = 8

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
-- the banner frame (renamed from DBM's "BossBanner" to avoid colliding with DBM's own global)
local BossBanner = CreateFrame("Frame", "WeirdLootBanner", UIParent)
BossBanner:Hide()
BossBanner:SetSize(128, 156)
BossBanner:SetPoint("TOP", UIParent, 0, -120)
BossBanner:EnableMouse(true)
BossBanner:SetAlpha(1)
BossBanner.LootFrames = {}

local bossBannerEffectiveScale = BossBanner:GetEffectiveScale()

-- BORDER
BossBanner.BannerTop = BossBanner:CreateTexture("WeirdLootBannerTop", "BORDER")
local BannerTop = BossBanner.BannerTop
BannerTop:SetBlendMode("BLEND")
BannerTop = SetAtlas(BannerTop, "BossBanner-BgBanner-Top", true)
BannerTop:SetPoint("TOP", 0, -44)

BossBanner.BannerTopGlow = BossBanner:CreateTexture("WeirdLootBannerTopGlow", "BORDER")
local BannerTopGlow = BossBanner.BannerTopGlow
BannerTopGlow:SetBlendMode("ADD")
BannerTopGlow = SetAtlas(BannerTopGlow, "BossBanner-BgBanner-Top", true)
BannerTopGlow:SetPoint("TOP", 0, -44)
BannerTopGlow:SetAlpha(0)

BossBanner.BannerBottom = BossBanner:CreateTexture("WeirdLootBannerBottom", "BORDER")
local BannerBottom = BossBanner.BannerBottom
BannerBottom:SetBlendMode("BLEND")
BannerBottom = SetAtlas(BannerBottom, "BossBanner-BgBanner-Bottom", true)
BannerBottom:SetPoint("BOTTOM", 0, 0)

BossBanner.BannerBottomGlow = BossBanner:CreateTexture("WeirdLootBannerBottomGlow", "BORDER")
local BannerBottomGlow = BossBanner.BannerBottomGlow
BannerBottomGlow:SetBlendMode("ADD")
BannerBottomGlow = SetAtlas(BannerBottomGlow, "BossBanner-BgBanner-Bottom", true)
BannerBottomGlow:SetPoint("BOTTOM", 0, 0)
BannerBottomGlow:SetAlpha(0)

-- BACKGROUND
BossBanner.BannerMiddle = BossBanner:CreateTexture("WeirdLootBannerMiddle", "BACKGROUND")
local BannerMiddle = BossBanner.BannerMiddle
BannerMiddle = SetAtlas(BannerMiddle, "BossBanner-BgBanner-Mid", true)
BannerMiddle:SetBlendMode("BLEND")
BannerMiddle:SetPoint("TOPLEFT", BannerTop, 0, -34)
BannerMiddle:SetPoint("BOTTOMRIGHT", BannerBottom, 0, 25)

BossBanner.BannerMiddleGlow = BossBanner:CreateTexture("WeirdLootBannerMiddleGlow", "BACKGROUND")
local BannerMiddleGlow = BossBanner.BannerMiddleGlow
BannerMiddleGlow = SetAtlas(BannerMiddleGlow, "BossBanner-BgBanner-Mid", true)
BannerMiddleGlow:SetBlendMode("ADD")
BannerMiddleGlow:SetPoint("TOPLEFT", BannerTop, 0, -34)
BannerMiddleGlow:SetPoint("BOTTOMRIGHT", BannerBottom, 0, 25)
BannerMiddleGlow:SetAlpha(0)

-- OVERLAY
BossBanner.SkullCircle = BossBanner:CreateTexture("WeirdLootBannerSkullCircle", "OVERLAY")
local SkullCircle = BossBanner.SkullCircle
SkullCircle:SetBlendMode("BLEND")
SkullCircle = SetAtlas(SkullCircle, "BossBanner-SkullCircle", true)
SkullCircle:SetPoint("CENTER", BannerTop, 0, 36)

BossBanner.LootCircle = BossBanner:CreateTexture("WeirdLootBannerLootCircle", "OVERLAY")
local LootCircle = BossBanner.LootCircle
LootCircle:SetBlendMode("BLEND")
LootCircle = SetAtlas(LootCircle, "LootBanner-LootBagCircle", true)
LootCircle:SetPoint("CENTER", BannerTop, 0, 36)

-- ARTWORK
BossBanner.BottomFillagree = BossBanner:CreateTexture("WeirdLootBannerBottomFillagree", "ARTWORK")
local BottomFillagree = BossBanner.BottomFillagree
BottomFillagree:SetBlendMode("BLEND")
BottomFillagree = SetAtlas(BottomFillagree, "BossBanner-BottomFillagree", true)
BottomFillagree:SetPoint("BOTTOM", 0, 8)

BossBanner.SkullSpikes = BossBanner:CreateTexture("WeirdLootBannerSkullSpikes", "ARTWORK")
local SkullSpikes = BossBanner.SkullSpikes
SkullSpikes:SetBlendMode("BLEND")
SkullSpikes = SetAtlas(SkullSpikes, "BossBanner-SkullSpikes", true)
SkullSpikes:SetPoint("CENTER", SkullCircle, -1, 6)

BossBanner.RightFillagree = BossBanner:CreateTexture("WeirdLootBannerRightFillagree", "ARTWORK")
local RightFillagree = BossBanner.RightFillagree
RightFillagree:SetBlendMode("BLEND")
RightFillagree = SetAtlas(RightFillagree, "BossBanner-RightFillagree", true)
RightFillagree:SetPoint("CENTER", SkullCircle, 47, 6)

BossBanner.LeftFillagree = BossBanner:CreateTexture("WeirdLootBannerLeftFillagree", "ARTWORK")
local LeftFillagree = BossBanner.LeftFillagree
LeftFillagree:SetBlendMode("BLEND")
LeftFillagree = SetAtlas(LeftFillagree, "BossBanner-LeftFillagree", true)
LeftFillagree:SetPoint("CENTER", SkullCircle, -47, 6)

BossBanner.Title = BossBanner:CreateFontString("WeirdLootBannerTitle", "ARTWORK", "QuestFont_Large")
local Title = BossBanner.Title
Title:SetHeight(30)
local titleFont, _, titleFlag = Title:GetFont()
Title:SetFont(titleFont, 30, titleFlag)
Title:SetText("")
Title:SetPoint("TOP", BannerTop, 0, -47)
Title:SetTextColor(1, 0, 0, 0)
Title:SetAlpha(1)

BossBanner.SubTitle = BossBanner:CreateFontString("WeirdLootBannerSubTitle", "ARTWORK", "GameFontNormalLarge")
local SubTitle = BossBanner.SubTitle
SubTitle:SetText("")
SubTitle:SetPoint("TOP", BottomFillagree, "BOTTOM", 0, 0)
SubTitle:SetTextColor(1, 0, 0, 0)
SubTitle:SetAlpha(1)

-- OVERLAY, texture sublevel 2
BossBanner.FlashBurst = BossBanner:CreateTexture("WeirdLootBannerFlashBurst", "OVERLAY", nil, 2)
local FlashBurst = BossBanner.FlashBurst
FlashBurst:SetBlendMode("ADD")
FlashBurst = SetAtlas(FlashBurst, "BossBanner-RedLightning", true)
FlashBurst:SetPoint("CENTER", SkullSpikes, 15, -4)
FlashBurst:SetAlpha(0.01)

BossBanner.FlashBurstLeft = BossBanner:CreateTexture("WeirdLootBannerFlashBurstLeft", "OVERLAY", nil, 2)
local FlashBurstLeft = BossBanner.FlashBurstLeft
FlashBurstLeft:SetBlendMode("ADD")
FlashBurstLeft = SetAtlas(FlashBurstLeft, "BossBanner-RedLightning", true)
FlashBurstLeft:SetPoint("CENTER", SkullSpikes, -15, -4)
FlashBurstLeft:SetAlpha(0.01)

-- OVERLAY, texture sublevel 3
BossBanner.FlashBurstCenter = BossBanner:CreateTexture("WeirdLootBannerFlashBurstCenter", "OVERLAY", nil, 3)
local FlashBurstCenter = BossBanner.FlashBurstCenter
FlashBurstCenter:SetBlendMode("ADD")
FlashBurstCenter = SetAtlas(FlashBurstCenter, "BossBanner-RedLightning", true)
FlashBurstCenter:SetPoint("CENTER", SkullSpikes)
FlashBurstCenter:SetAlpha(0.01)

-- OVERLAY, texture sublevel 4
BossBanner.RedFlash = BossBanner:CreateTexture("WeirdLootBannerRedFlash", "OVERLAY", nil, 4)
local RedFlash = BossBanner.RedFlash
RedFlash:SetBlendMode("ADD")
RedFlash = SetAtlas(RedFlash, "BossBanner-RedFlash", true)
RedFlash:SetPoint("CENTER", SkullSpikes, 1, -4)
RedFlash:SetAlpha(0.01)

------------------------------------------------------------------
-- per-row tooltip
local function BossBanner_OnLootItemEnter(self)
    if BossBanner.animState ~= BB_STATE_BANNER_OUT and not BossBanner.showingTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(self:GetParent().itemLink)
        GameTooltip:Show()
        BossBanner.showingTooltip = true
    end
end

local function BossBanner_OnLootItemLeave()
    if BossBanner.showingTooltip then
        GameTooltip:Hide()
        BossBanner.showingTooltip = false
    end
end

-- Hovering the row (anywhere but the icon, which IconHitBox covers with the item tooltip) lists every
-- roll cast on that item, so the ML can see who else was in the running and why the winner took it.
local function BossBanner_OnRowEnter(self)
    if BossBanner.animState == BB_STATE_BANNER_OUT or BossBanner.showingTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    local q = ITEM_QUALITY_COLORS[self.itemRarity or 1]
    GameTooltip:AddLine(self.itemName or "", q.r, q.g, q.b)
    local rolls = self.rolls
    if rolls and #rolls > 0 then
        for _, r in ipairs(rolls) do
            local right = r.roll and tostring(r.roll) or "-"
            if r.section and r.section ~= "" then right = right .. "  " .. r.section end
            GameTooltip:AddDoubleLine(colorName(r.name, r.class), right, 1, 1, 1, 0.85, 0.85, 0.85)
        end
    else
        GameTooltip:AddLine("No rolls recorded", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
    BossBanner.showingTooltip = true
end

------------------------------------------------------------------
-- loot row factory (verbatim from DBM, font-option logic dropped -> template fonts)
local function createLootFrame(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(269, 44)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", BossBanner_OnRowEnter)
    frame:SetScript("OnLeave", BossBanner_OnLootItemLeave)

    local effectiveScale = frame:GetEffectiveScale()

    frame.Background = frame:CreateTexture(nil, "BACKGROUND")
    local Background = frame.Background
    Background:SetBlendMode("BLEND")
    Background = SetAtlas(Background, "LootBanner-ItemBg", true)
    Background:SetPoint("CENTER")

    frame.Icon = frame:CreateTexture(nil, "BORDER")
    local Icon = frame.Icon
    Icon:SetSize(37, 37)
    Icon:SetPoint("LEFT", 14, 0)
    Icon:SetTexture("Interface\\Icons\\inv_misc_bag_felclothbag")

    frame.Count = frame:CreateFontString(nil, "ARTWORK", "NumberFontNormal")
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

    -- DBM uses this for the boss name; we use it for the winning player.
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

    tinsert(parent.LootFrames, frame)

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

    return frame
end

------------------------------------------------------------------
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

-- AnimationGroup: AnimSwitch (headline look -> loot look)
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

------------------------------------------------------------------
-- top banner manager: serializes banner playback, queues extras
local TopBannerMgr = {}
local TopBannerQueue = {}
local TopBannerManager_BannerFinished

local function TopBannerManager_Show(frame, data, isExclusiveQueued)
    local banner = { frame = frame, data = data }
    if TopBannerMgr.currentBanner then
        if isExclusiveQueued then
            for _, queuedBanner in pairs(TopBannerQueue) do
                if isExclusiveQueued(banner, queuedBanner) then return end
            end
        end
        tinsert(TopBannerQueue, banner)
    else
        TopBannerMgr.currentBanner = banner
        frame:PlayBanner(data)
    end
end

TopBannerManager_BannerFinished = function()
    if #TopBannerQueue > 0 then
        TopBannerMgr.currentBanner = table.remove(TopBannerQueue, 1)
        schedule0(TopBannerMgr.currentBanner.frame.PlayBanner, TopBannerMgr.currentBanner.frame, TopBannerMgr.currentBanner.data)
    else
        if TopBannerMgr.currentBanner and next(TopBannerMgr.currentBanner.frame.pendingLoot) then
            TopBannerMgr.currentBanner.data.mode = "LOOT"
            schedule0(TopBannerMgr.currentBanner.frame.PlayBanner, TopBannerMgr.currentBanner.frame, TopBannerMgr.currentBanner.data)
        else
            TopBannerMgr.currentBanner = nil
        end
    end
end

local function BossBanner_OnAnimOutFinished(self)
    local banner = self:GetParent()
    banner.animState = nil
    if banner.showingTooltip then GameTooltip:Hide() end
    banner.showingTooltip = false
    banner.hoveredThisVisit = false
    banner.hoverGrace = nil
    banner:Hide()
    banner:SetHeight(banner.baseHeight)
    for i = 1, #banner.LootFrames do
        local f = banner.LootFrames[i]
        f.alive = false
        f.fading = false
        f:SetAlpha(1)
        f:Hide()
    end
    banner:SetHeight(banner.baseHeight)
    wipe(banner.seenKeys)
    TopBannerManager_BannerFinished()
end

-- AnimationGroup: AnimOut
BossBanner.AnimOut = BossBanner:CreateAnimationGroup()
CreateAlphaAnim(BossBanner.AnimOut, 1, 0, 1)
CreateAlphaAnim(BossBanner.AnimOut, 1, 0.5, -1)
BossBanner.AnimOut:SetScript("OnFinished", function(self)
    BossBanner_OnAnimOutFinished(self)
end)

------------------------------------------------------------------
-- state machine: animation control
local function BossBanner_AnimBannerIn(self)
    self.lootShown = 0
    self.AnimIn:Play()
end

local function BossBanner_AnimKillHold() end

local function BossBanner_AnimSwitch(self, entry)
    if next(self.pendingLoot) then
        self.AnimSwitch:Play()
        entry.duration = 0.5
    else
        entry.duration = 0
    end
end

local function BossBanner_AnimLootExpand(self, entry)
    entry.duration = 0   -- height is handled by relayoutAliveRows now; just pass through to LOOT_INSERT
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

local itemScanTooltip
local function BossBanner_ConfigureLootFrame(lootFrame, data)
    -- data: { itemLink, texture, quantity, winner, winnerClass }
    local _, itemName, itemRarity, itemTexture, colorString, rarityColor, setName
    itemName, _, itemRarity, _, _, _, _, _, _, itemTexture = GetItemInfo(data.itemLink)

    if not itemTexture then -- uncached item: parse name/rarity from the link
        _, _, colorString, _, _, _, _, _, _, _, _, _, _, itemName = strfind(data.itemLink, "|?c?(%x*)|?H?([^:]*):?(%d+):?(%d*):?(%d*):?(%d*):?(%d*):?(%d*):?(%-?%d*):?(%-?%d*):?(%d*)|?h?%[?([^%[%]]*)%]?|?h?|?r?")
        itemRarity = colorRarity[colorString]
        itemTexture = data.texture
    end

    if IsDressableItem(data.itemLink) then -- gear: scan tooltip for a set name
        itemScanTooltip = itemScanTooltip or CreateFrame("GameTooltip", "WeirdLootBannerScanTooltip", nil, "GameTooltipTemplate")
        itemScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        itemScanTooltip:SetHyperlink(data.itemLink)
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

    if data.quantity and data.quantity > 1 then
        lootFrame.Count:Show()
        lootFrame.Count:SetText(data.quantity)
    else
        lootFrame.Count:Hide()
    end

    if setName then
        lootFrame.ItemName:ClearAllPoints()
        lootFrame.ItemName:SetPoint("TOPLEFT", 56, -2)
        lootFrame.SetName:SetText(("Set: %s"):format(setName))
        lootFrame.SetName:Show()
        lootFrame.PlayerName:ClearAllPoints()
        lootFrame.PlayerName:SetPoint("TOPLEFT", lootFrame.SetName, "BOTTOMLEFT", 0, 0)
    else
        lootFrame.ItemName:ClearAllPoints()
        lootFrame.ItemName:SetPoint("TOPLEFT", 56, -7)
        lootFrame.SetName:Hide()
        lootFrame.PlayerName:ClearAllPoints()
        lootFrame.PlayerName:SetPoint("TOPLEFT", lootFrame.ItemName, "BOTTOMLEFT", 0, 0)
    end

    -- class-colored winner, with the winning reason ("- BiS", "- roll 98 - MS") trailing in white
    local nameText = colorName(data.winner, data.winnerClass)
    if data.why and data.why ~= "" then
        nameText = nameText .. " |cffffffff- " .. data.why .. "|r"
    end
    lootFrame.PlayerName:SetText(nameText)
    lootFrame.PlayerName:SetTextColor(1, 1, 1) -- base white; the name carries its own |c color code

    lootFrame.itemLink = data.itemLink
    lootFrame.itemName = itemName
    lootFrame.itemRarity = itemRarity or 1
    lootFrame.rolls = data.rolls
end

-- How long the banner holds after the last row shows, mirroring the old result popup's lifetime:
-- the player's auto-close seconds, 0 for "close at once", or nil ("hold until dismissed") when
-- auto-close is off or the loot master opted to keep finished-loot popups open. Read per-client, so
-- each raider follows their own setting and the ML can keep theirs up.
local function resultHoldSeconds()
    local opt = addon.db and addon.db.options
    if not opt then return nil end
    local mlKeepOpen = opt.forceKeepResultPopup and addon.IsAuthorizedLootMaster and addon:IsAuthorizedLootMaster()
    if opt.resultPopupAutoCloseEnabled and not mlKeepOpen then
        return tonumber(opt.resultPopupAutoCloseSeconds) or 0
    end
    return nil
end

local ROW_FADE_TIME = 0.4   -- seconds a row takes to fade out once its lifetime ends

-- Re-anchor the alive rows top-to-bottom and size the banner to them, so it grows as rows arrive and
-- shrinks as they expire. Called on every add and on every removal.
local function relayoutAliveRows(self)
    local prev, count = nil, 0
    for _, f in ipairs(self.LootFrames) do
        if f.alive then
            count = count + 1
            f:ClearAllPoints()
            if prev then
                f:SetPoint("TOP", prev, "BOTTOM", 0, -6)
            else
                f:SetPoint("TOP", self, "TOP", 0, -84)
            end
            prev = f
        end
    end
    -- baseHeight already reserves the first row plus the bottom chrome; only rows beyond the first add
    -- height. (Using count here left a phantom empty slot at the bottom.)
    self:SetHeight(self.baseHeight + max(count - 1, 0) * BB_EXPAND_HEIGHT)
    return count
end

local function aliveRowCount(self)
    local n = 0
    for _, f in ipairs(self.LootFrames) do
        if f.alive then n = n + 1 end
    end
    return n
end

-- Add one item as a row with its own lifetime, reusing a freed row frame or growing the pool.
local function addRow(self, data)
    if aliveRowCount(self) >= BB_MAX_LOOT then return end
    local frame
    for _, f in ipairs(self.LootFrames) do
        if not f.alive and not f.fading then frame = f; break end
    end
    if not frame then frame = createLootFrame(self) end
    BossBanner_ConfigureLootFrame(frame, data)
    frame.alive = true
    frame.fading = false
    frame.fadeLeft = 0
    frame:SetAlpha(1)
    frame:Show()
    if frame.Anim then frame.Anim:Play() end
    relayoutAliveRows(self)
    -- A new drop refreshes every shown row back to a full lifetime (reviving any that were mid-fade or
    -- collapsing from a hover), so the player gets time to look over everything that just dropped
    -- instead of losing earlier items. nil setting => effectively never auto-expire.
    local full = resultHoldSeconds() or 86400
    for _, f in ipairs(self.LootFrames) do
        if f.alive then
            f.timeLeft = full
            if f.fading then
                f.fading = false
                f.fadeLeft = 0
                f:SetAlpha(1)
            end
        end
    end
end

-- Per-row lifetime controller, run every frame while the banner is showing (BB_STATE_LOOT_INSERT).
-- Each row counts down and fades itself out independently; a hover (icon or row tooltip) freezes every
-- row, and once the cursor really leaves (a short grace absorbs row-to-row moves) all shown rows are
-- collapsed to a 2s exit. When the last row is gone the chrome fades out.
local function updateRowLifetimes(self, elapsed)
    if self.showingTooltip then
        self.hoveredThisVisit = true
        self.hoverGrace = nil
        return
    end
    if self.hoveredThisVisit then
        self.hoverGrace = (self.hoverGrace or 0.12) - elapsed
        if self.hoverGrace > 0 then return end   -- still in grace: treat as continued hover
        self.hoveredThisVisit = false
        self.hoverGrace = nil
        for _, f in ipairs(self.LootFrames) do
            if f.alive and not f.fading then f.timeLeft = 2 end
        end
    end
    local removed, stillCounting = false, 0
    for _, f in ipairs(self.LootFrames) do
        if f.alive then
            if f.fading then
                f.fadeLeft = f.fadeLeft - elapsed
                if f.fadeLeft <= 0 then
                    f.alive = false
                    f.fading = false
                    f:Hide()
                    removed = true
                else
                    f:SetAlpha(f.fadeLeft / ROW_FADE_TIME)
                end
            else
                f.timeLeft = f.timeLeft - elapsed
                if f.timeLeft <= 0 then
                    f.fading = true
                    f.fadeLeft = ROW_FADE_TIME
                else
                    stillCounting = stillCounting + 1
                end
            end
        end
    end
    if removed then relayoutAliveRows(self) end
    -- Start the whole-banner fade as soon as no row is still counting down (the final item has just
    -- begun fading), so the chrome fades with it rather than lingering empty. The parent fade then
    -- carries the still-fading rows out together.
    if stillCounting == 0 then
        BossBanner.SetAnimState(self, BB_STATE_BANNER_OUT)
    end
end

local function BossBanner_AnimLootInsert(self, entry)
    -- show every queued item as its own row, then park here: updateRowLifetimes drives the per-row fades
    while #self.pendingLoot > 0 do
        addRow(self, table.remove(self.pendingLoot, 1))
    end
    entry.duration = 86400
end

local function BossBanner_AnimBannerOut(self)
    self.AnimOut:Play()
end

local BB_ANIMATION_CONTROL = {
    [BB_STATE_BANNER_IN]   = { duration = 1.85, onStartFunc = BossBanner_AnimBannerIn },
    [BB_STATE_KILL_HOLD]   = { duration = 2,    onStartFunc = BossBanner_AnimKillHold },
    [BB_STATE_SWITCH]      = { duration = nil,  onStartFunc = BossBanner_AnimSwitch },
    [BB_STATE_LOOT_EXPAND] = { duration = nil,  onStartFunc = BossBanner_AnimLootExpand },
    [BB_STATE_LOOT_INSERT] = { duration = nil,  onStartFunc = BossBanner_AnimLootInsert },
    [BB_STATE_BANNER_OUT]  = { duration = 5,    onStartFunc = BossBanner_AnimBannerOut },
}

local function BossBanner_BeginAnims(self, animState)
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

-- 3.3.5a Translation animations don't account for UIScale; re-validate offsets against scale
local defaultTranslationOffsetsTable = {
    ["RightFillagree-To"] = {37, 0},
    ["LeftFillagree-To"] = {-37, 0},
    ["FlashBurst-To"] = {10, 0},
    ["FlashBurstLeft-To"] = {-10, 0},
    ["LootFrame-Icon-From"] = {110, 0},
    ["LootFrame-Icon-To"] = {-110, 0},
}

local xOffset, yOffset
local function validateOffsets(animation, defaultkey, effectiveScale)
    xOffset, yOffset = animation:GetOffset()
    if round(xOffset, 0) ~= round((defaultTranslationOffsetsTable[defaultkey][1] * effectiveScale), 0) then
        xOffset = defaultTranslationOffsetsTable[defaultkey][1] * effectiveScale
    end
    if round(yOffset, 0) ~= round((defaultTranslationOffsetsTable[defaultkey][2] * effectiveScale), 0) then
        yOffset = defaultTranslationOffsetsTable[defaultkey][2] * effectiveScale
    end
    animation:SetOffset(xOffset, yOffset)
end

local function fixTranslationAnim()
    local effectiveScale = BossBanner:GetEffectiveScale()
    local rightFillagreeTranslationAnimTo = (select(3, BossBanner.RightFillagree.animForAnimIn:GetAnimations()))
    local leftFillagreeTranslationAnimTo = (select(3, BossBanner.LeftFillagree.animForAnimIn:GetAnimations()))
    local flashBurstTranslationAnimTo = (select(5, BossBanner.FlashBurst.animForAnimIn:GetAnimations()))
    local flashBurstLeftTranslationAnimTo = (select(5, BossBanner.FlashBurstLeft.animForAnimIn:GetAnimations()))

    local lootFrameIconTranslationAnimFrom, lootFrameIconTranslationAnimTo

    validateOffsets(rightFillagreeTranslationAnimTo, "RightFillagree-To", effectiveScale)
    validateOffsets(leftFillagreeTranslationAnimTo, "LeftFillagree-To", effectiveScale)
    validateOffsets(flashBurstTranslationAnimTo, "FlashBurst-To", effectiveScale)
    validateOffsets(flashBurstLeftTranslationAnimTo, "FlashBurstLeft-To", effectiveScale)

    for _, lootFrame in ipairs(BossBanner.LootFrames) do
        lootFrameIconTranslationAnimFrom, lootFrameIconTranslationAnimTo = select(3, lootFrame.Icon.animForAnim:GetAnimations())
        validateOffsets(lootFrameIconTranslationAnimFrom, "LootFrame-Icon-From", effectiveScale)
        validateOffsets(lootFrameIconTranslationAnimTo, "LootFrame-Icon-To", effectiveScale)

        lootFrameIconTranslationAnimFrom, lootFrameIconTranslationAnimTo = lootFrame.IconHitBox.animForAnim:GetAnimations()
        validateOffsets(lootFrameIconTranslationAnimFrom, "LootFrame-Icon-From", effectiveScale)
        validateOffsets(lootFrameIconTranslationAnimTo, "LootFrame-Icon-To", effectiveScale)
    end
end

local function BossBanner_Play(self, data)
    if data then
        fixTranslationAnim()
        if data.mode == "KILL" then
            self.Title:SetAlpha(1)
            self.SubTitle:SetAlpha(1)
            self.Title:SetText(data.name or "")
            self.SubTitle:SetText(data.subtitle or "")
            self.SubTitle:Show()
            self.Title:Show()
            self:Show()
            BossBanner_BeginAnims(self)
        elseif data.mode == "LOOT" then
            self.BannerTop:SetAlpha(1)
            self.BannerBottom:SetAlpha(1)
            self.BannerMiddle:SetAlpha(1)
            self.RightFillagree:SetAlpha(1)
            self.LeftFillagree:SetAlpha(1)
            self.BottomFillagree:SetAlpha(1)
            self.SkullSpikes:SetAlpha(1)
            self.SkullCircle:SetAlpha(0)
            self.LootCircle:SetAlpha(1)
            self.Title:Hide()
            self.SubTitle:Hide()
            self:Show()
            BossBanner_BeginAnims(self, BB_STATE_LOOT_EXPAND)
        end
    end
end

local function BossBanner_Stop(self)
    self.AnimIn:Stop()
    self.AnimSwitch:Stop()
    self.AnimOut:Stop()
    self:Hide()
end

local function BossBanner_IsExclusiveQueued()
    return true
end

local function BossBanner_OnLoad(self)
    self.PlayBanner = BossBanner_Play
    self.StopBanner = BossBanner_Stop
    self.pendingLoot = {}
    self.seenKeys = {} -- roll ids already added this banner cycle, to ignore duplicate/echoed wins
    self.showingTooltip = false
    self.hoveredThisVisit = false
    self.hoverGrace = nil
    self.baseHeight = self:GetHeight()
end

local function BossBanner_OnUpdate(self, elapsed)
    -- drain any next-frame scheduled calls
    if #scheduleQueue > 0 then
        local pending = scheduleQueue
        scheduleQueue = {}
        for _, item in ipairs(pending) do
            item.fn(unpack(item.args))
        end
    end

    if not self.animState then return end
    if self.animState == BB_STATE_LOOT_INSERT then
        updateRowLifetimes(self, elapsed)   -- per-row countdowns drive the showing phase
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

local function BossBanner_OnMouseDown(frame, button)
    if button == "RightButton" then
        BossBanner_Stop(frame)
        wipe(frame.pendingLoot)
        BossBanner_OnAnimOutFinished(frame.AnimOut)
    end
end

BossBanner_OnLoad(BossBanner)
BossBanner:SetScript("OnUpdate", BossBanner_OnUpdate)
BossBanner:SetScript("OnMouseDown", BossBanner_OnMouseDown)

------------------------------------------------------------------
-- public entry: announce one or more awarded items.
-- opts = { title = "...", subtitle = "...", items = { { link=, icon=, quantity=, winner=, winnerClass= }, ... } }
function addon:ShowLootBanner(opts)
    if not opts then return end
    local items = opts.items or {}
    wipe(BossBanner.pendingLoot)
    wipe(BossBanner.seenKeys)
    for _, it in ipairs(items) do
        if it.link then
            tinsert(BossBanner.pendingLoot, {
                itemLink = it.link,
                texture = it.icon,
                quantity = it.quantity or 1,
                winner = it.winner,
                winnerClass = it.winnerClass,
                why = it.why,
                rolls = it.rolls,
            })
        end
    end
    if not next(BossBanner.pendingLoot) then return end
    TopBannerManager_Show(BossBanner, { name = opts.title or "Loot Awarded", subtitle = opts.subtitle, mode = "KILL" }, BossBanner_IsExclusiveQueued)
end

-- Announce a single won item. If a banner is already on screen the item inserts as a new row; if not,
-- a fresh banner unfurls. item.key (the roll id) dedupes duplicate/echoed wins within one banner cycle.
function addon:AddLootBannerItem(item)
    if not item or not item.link then return end
    if item.key then
        if BossBanner.seenKeys[item.key] then return end
        BossBanner.seenKeys[item.key] = true
    end
    local data = {
        itemLink = item.link,
        texture = item.icon,
        quantity = item.quantity or 1,
        winner = item.winner,
        winnerClass = item.winnerClass,
        why = item.why,
        rolls = item.rolls,
    }
    if BossBanner.animState == BB_STATE_LOOT_INSERT then
        -- banner is showing: drop the new item straight in as its own row
        addRow(BossBanner, data)
    elseif BossBanner.animState == BB_STATE_BANNER_OUT then
        -- banner is fading out: interrupt the fade and resume showing with this item
        BossBanner.AnimOut:Stop()
        BossBanner:SetAlpha(1)
        BossBanner.animState = BB_STATE_LOOT_INSERT
        BossBanner.animTimeLeft = 86400
        addRow(BossBanner, data)
    elseif not BossBanner.animState then
        -- nothing showing: unfurl a fresh banner (the item is drained when it reaches LOOT_INSERT)
        tinsert(BossBanner.pendingLoot, data)
        TopBannerManager_Show(BossBanner, { name = item.title or "Loot Awarded", mode = "KILL" }, BossBanner_IsExclusiveQueued)
    else
        -- mid-intro: queue; shown when the banner reaches LOOT_INSERT
        tinsert(BossBanner.pendingLoot, data)
    end
end

-- DEBUG preview: strip before commit. `/wlbanner` streams random won items into the banner over a few
-- seconds, so the insert/expand animation, batching, and hold-then-fade can be seen under realistic
-- conditions (items resolving at different times). A persistent timer frame drives the staggered adds.
local wlbannerTimer = CreateFrame("Frame")
SLASH_WLBANNER1 = "/wlbanner"
SlashCmdList["WLBANNER"] = function()
    local bases = {
        { link = "|cffa335ee|Hitem:40629:0:0:0:0:0:0:0:0|h[Gauntlets of the Lost Protector]|h|r", icon = "Interface\\Icons\\inv_gauntlets_28" },
        { link = "|cff0070dd|Hitem:40207:0:0:0:0:0:0:0:0|h[Gloves of the Lost Protector]|h|r", icon = "Interface\\Icons\\inv_gauntlets_25" },
        { link = "|cffa335ee|Hitem:40558:0:0:0:0:0:0:0:0|h[Leggings of the Lost Vanquisher]|h|r", icon = "Interface\\Icons\\inv_pants_plate_19" },
        { link = "|cff1eff00|Hitem:39071:0:0:0:0:0:0:0:0|h[Wending Cloak]|h|r", icon = "Interface\\Icons\\inv_misc_cape_19" },
        { link = "|cffff8000|Hitem:49623:0:0:0:0:0:0:0:0|h[Shadowmourne]|h|r", icon = "Interface\\Icons\\inv_axe_113" },
    }
    local roster = {
        { n = UnitName("player"), c = (UnitClass("player")) }, { n = "Dremera", c = "Mage" },
        { n = "Borgakh", c = "Warrior" }, { n = "Anagke", c = "Paladin" },
        { n = "Thordris", c = "Shaman" }, { n = "Veylin", c = "Priest" },
    }
    local brackets = { "BiS", "MS", "MU", "OS" }
    local rank = { BiS = 4, MS = 3, MU = 2, OS = 1 }

    local function randomItem()
        local base = bases[math.random(#bases)]
        local pool = {}
        for _, p in ipairs(roster) do pool[#pool + 1] = p end
        for i = #pool, 2, -1 do local j = math.random(i); pool[i], pool[j] = pool[j], pool[i] end
        local n = math.random(2, 4)
        local rolls, best = {}, nil
        for i = 1, n do
            local bracket = brackets[math.random(#brackets)]
            local r = { name = pool[i].n, class = pool[i].c, roll = math.random(1, 100), section = bracket }
            rolls[#rolls + 1] = r
            if not best or rank[bracket] > rank[best.section] or (rank[bracket] == rank[best.section] and r.roll > best.roll) then
                best = r
            end
        end
        return {
            link = base.link, icon = base.icon,
            quantity = (math.random(5) == 1) and math.random(2, 3) or 1,
            winner = best.name, winnerClass = best.class,
            why = string.format("roll %d - %s", best.roll, best.section),
            rolls = rolls,
        }
    end

    addon:AddLootBannerItem(randomItem())               -- first item starts the banner
    local remaining = math.random(2, 5)                  -- how many more will trickle in
    local elapsed, nextAt = 0, 1 + math.random() * 2.5
    wlbannerTimer:SetScript("OnUpdate", function(self, e)
        elapsed = elapsed + e
        if elapsed >= nextAt then
            addon:AddLootBannerItem(randomItem())
            remaining = remaining - 1
            nextAt = elapsed + 0.8 + math.random() * 3    -- staggered, sometimes during the hold
            if remaining <= 0 then self:SetScript("OnUpdate", nil) end
        end
    end)
end
