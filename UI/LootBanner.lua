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

local itemScanTooltip   -- single shared hidden scanning tooltip
local function BossBanner_ConfigureLootFrame(lootFrame, data)
    -- data: { itemLink, texture, quantity, winner/winners/why, rolls } or a roll prompt { prompt }
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

    -- Second line. A roll prompt passes a pre-formatted `prompt` (prio + bracket options); an awarded
    -- item passes winner(s): a single winner reads "Name - roll N - Bracket", multiple read
    -- "Name (Bracket), ...". winnerKeys lets the roll tooltip highlight the winners.
    local winnerKeys = {}
    local nameText
    if data.prompt then
        nameText = data.prompt
    else
        local wins = data.winners
        if wins and #wins > 1 then
            local parts = {}
            for _, w in ipairs(wins) do
                winnerKeys[util:NormalizeKey(w.name)] = true
                parts[#parts + 1] = colorName(w.name, w.class) .. " |cffffd200" .. (w.section or "?") .. "|r"
            end
            nameText = table.concat(parts, ", ")
        else
            local w = wins and wins[1]
            local name = w and w.name or data.winner
            local class = w and w.class or data.winnerClass
            local why = data.why
            if w then
                why = w.roll and string.format("roll %s - %s", tostring(w.roll), w.section or "?") or w.section
            end
            if name then winnerKeys[util:NormalizeKey(name)] = true end
            nameText = colorName(name, class)
            if why and why ~= "" then
                nameText = nameText .. " |cffffffff- " .. why .. "|r"
            end
        end
    end
    lootFrame.PlayerName:SetText(nameText)
    lootFrame.PlayerName:SetTextColor(1, 1, 1) -- base white; the name carries its own |c color code

    lootFrame.itemLink = data.itemLink
    lootFrame.itemName = itemName
    lootFrame.itemRarity = itemRarity or 1
    lootFrame.rolls = data.rolls
    lootFrame.winnerKeys = winnerKeys
end

local ROW_FADE_TIME = 0.4   -- seconds a row takes to fade out once its lifetime ends

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
        if BossBanner.showingTooltip then
            GameTooltip:Hide()
            BossBanner.showingTooltip = false
        end
    end

    local function BossBanner_OnRowEnter(self)
        if BossBanner.animState == BB_STATE_BANNER_OUT or BossBanner.showingTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local q = ITEM_QUALITY_COLORS[self.itemRarity or 1]
        GameTooltip:AddLine(self.itemName or "", q.r, q.g, q.b)
        local rolls = self.rolls
        if rolls and #rolls > 0 then
            local winnerKeys = self.winnerKeys or {}
            for _, r in ipairs(rolls) do
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
        -- baseHeight already reserves the first row + bottom chrome; only rows beyond the first add height.
        self:SetHeight(self.baseHeight + max(count - 1, 0) * BB_EXPAND_HEIGHT)
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
        if aliveRowCount(self) >= BB_MAX_LOOT then return end
        local additional = aliveRowCount(self) > 0   -- rows already shown => this is not the first item
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
        if data.rollDuration then
            -- roll-prompt row: a fixed countdown of the roll timer, shown by its own bar. It does not
            -- extend or get extended (each roll runs its own clock).
            frame.rollDuration = data.rollDuration
            frame.timeLeft = data.rollDuration
            frame.RollTimer:SetValue(1)
            frame.RollTimer:SetStatusBarColor(0, 1, 0.1)
            frame.RollTimer:Show()
            return
        end
        frame.rollDuration = nil
        frame.RollTimer:Hide()
        -- Won row: full lifetime; each additional drop EXTENDS the (won) rows already shown by half
        -- (capped at full), reviving any that were mid-fade, so earlier items linger to be read.
        local full = resultHoldSeconds()
        frame.timeLeft = full or 86400
        if additional and full then
            for _, f in ipairs(self.LootFrames) do
                if f.alive and f ~= frame and not f.rollDuration then
                    f.timeLeft = math.min(max(f.timeLeft, 0) + full / 2, full)
                    if f.fading then
                        f.fading = false
                        f.fadeLeft = 0
                        f:SetAlpha(1)
                    end
                end
            end
        end
    end

    function updateRowLifetimes(self, elapsed)
        if self.showingTooltip then
            self.hoveredThisVisit = true
            self.hoverGrace = nil
            return
        end
        if self.hoveredThisVisit then
            self.hoverGrace = (self.hoverGrace or 0.12) - elapsed
            if self.hoverGrace > 0 then return end
            self.hoveredThisVisit = false
            self.hoverGrace = nil
            for _, f in ipairs(self.LootFrames) do
                -- roll rows keep their own clock; only won rows collapse to a 2s exit on mouse-off
                if f.alive and not f.fading and not f.rollDuration then f.timeLeft = 2 end
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
                        if f.rollDuration then f.RollTimer:Hide() end   -- roll time is up
                    else
                        stillCounting = stillCounting + 1
                        if f.rollDuration then
                            local frac = max(f.timeLeft, 0) / f.rollDuration
                            f.RollTimer:SetValue(frac)
                            f.RollTimer:SetStatusBarColor(1 - frac, frac, 0.1)   -- green -> red
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
    local function BossBanner_AnimBannerIn(self)
        self.lootShown = 0
        self.AnimIn:Play()
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
        fixTranslationAnim()
        -- intro: keep the unfurl + lightning, show the medallion (bag or dice) right away, no title hold
        applyMedallion(self)
        self.LootCircle:SetAlpha(0)
        self.Title:Hide()
        self.SubTitle:Hide()
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
    local function BossBanner_AddItem(self, item)
        if not item or not item.link then return end
        if resultHoldSeconds() == 0 then return end   -- duration 0: do not show the toast at all
        if item.key then
            if self.seenKeys[item.key] then return end
            self.seenKeys[item.key] = true
        end
        local data = {
            itemLink = item.link, texture = item.icon, quantity = item.quantity or 1,
            winner = item.winner, winnerClass = item.winnerClass, why = item.why,
            winners = item.winners, rolls = item.rolls, prompt = item.prompt, rollDuration = item.rollDuration,
        }
        if self.animState == BB_STATE_LOOT_INSERT then
            addRow(self, data)
        elseif self.animState == BB_STATE_BANNER_OUT then
            self.AnimOut:Stop()
            self:SetAlpha(1)
            self.animState = BB_STATE_LOOT_INSERT
            self.animTimeLeft = 86400
            addRow(self, data)
        elseif not self.animState then
            tinsert(self.pendingLoot, data)
            self:PlayBanner({ mode = "KILL" })
        else
            tinsert(self.pendingLoot, data)
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
    BossBanner:HookScript("OnShow", function() if BossBanner.onLayoutChanged then BossBanner.onLayoutChanged() end end)
    BossBanner:HookScript("OnHide", function() if BossBanner.onLayoutChanged then BossBanner.onLayoutChanged() end end)

    return BossBanner
end

------------------------------------------------------------------
-- Two banner instances stacked in one region: drops (dice) above, awarded (bag) below.
local awardedBanner = buildBanner("WeirdLootAwardedBanner", { atlas = "LootBanner-LootBagCircle" })
local dropsBanner = buildBanner("WeirdLootDropsBanner", { texture = DICE_TEXTURE })

local REGION_TOP = -120
local function layoutRegion()
    dropsBanner:ClearAllPoints()
    dropsBanner:SetPoint("TOP", UIParent, 0, REGION_TOP)
    awardedBanner:ClearAllPoints()
    if dropsBanner:IsShown() then
        awardedBanner:SetPoint("TOP", dropsBanner, "BOTTOM", 0, -14)   -- below drops; moves as it resizes
    else
        awardedBanner:SetPoint("TOP", UIParent, 0, REGION_TOP)
    end
end
dropsBanner.onLayoutChanged = layoutRegion
awardedBanner.onLayoutChanged = layoutRegion
layoutRegion()

------------------------------------------------------------------
-- public API
function addon:AddLootBannerItem(item)
    awardedBanner:AddItem(item)
end

function addon:AddRollBannerItem(item)
    dropsBanner:AddItem(item)
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
    local responses = { "bis", "ms", "mu", "os" }

    local LABEL = { bis = "BiS", ms = "MS", mu = "MU", os = "OS" }
    local bracketRank = { bis = 4, ms = 3, mu = 2, os = 1 }
    local statuses = { "main", "designatedalt", "nil" }
    local statusRank = { main = 3, designatedalt = 2, ["nil"] = 1 }

    local function wonItem(forceQty)
        local base = bases[math.random(#bases)]
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
                rollText = tostring(math.random(1, 100)),
                status = statuses[math.random(#statuses)],
                isNamed = false,
            }
        end
        if math.random(2) == 1 then details[math.random(n)].isNamed = true end   -- ~half: one named roller

        -- Breakdown (tooltip) via the REAL bracket sort; a named roller keeps its bracket spot but is
        -- labelled "LC Prio".
        local rolls = {}
        for _, s in ipairs(addon:SectionsFromResult({ allRollerDetails = details })) do
            for _, m in ipairs(s.members) do
                rolls[#rolls + 1] = { name = m.name, class = classByName[m.name], roll = m.roll,
                    section = m.isNamed and "LC Prio" or s.label }
            end
        end

        -- Winners by the resolver's actual priority: a named roller wins a copy regardless of rolls,
        -- then bracket (BiS>MS>MU>OS), then status (main>desAlt>nil), then roll.
        local ranked = {}
        for _, d in ipairs(details) do
            ranked[#ranked + 1] = { name = d.name, class = classByName[d.name], roll = tonumber(d.rollText),
                bracket = d.responseType, status = d.status, isNamed = d.isNamed }
        end
        table.sort(ranked, function(a, b)
            if a.isNamed ~= b.isNamed then return a.isNamed end
            if bracketRank[a.bracket] ~= bracketRank[b.bracket] then return bracketRank[a.bracket] > bracketRank[b.bracket] end
            if statusRank[a.status] ~= statusRank[b.status] then return statusRank[a.status] > statusRank[b.status] end
            return a.roll > b.roll
        end)
        local winners = {}
        for i = 1, math.min(quantity, #ranked) do
            local r = ranked[i]
            winners[i] = { name = r.name, class = r.class, roll = r.roll,
                section = r.isNamed and "LC Prio" or LABEL[r.bracket] }
        end
        return { link = base.link, icon = base.icon, quantity = quantity, winners = winners, rolls = rolls }
    end

    local function rollItem()
        local base = bases[math.random(#bases)]
        -- prototype drop row: prio + bracket options as text (real clickable buttons are the next step),
        -- and a roll countdown bar driven by the configured roll duration.
        local rollDur = (addon.db and addon.db.options and tonumber(addon.db.options.rollDuration)) or 20
        return { link = base.link, icon = base.icon, quantity = 1,
            prompt = "Roll:  |cffffd200BiS|r  MS  MU  OS  TM  Pass", rollDuration = rollDur }
    end

    -- DROPS banner: a couple of items up for roll (dice medallion).
    addon:AddRollBannerItem(rollItem())
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
