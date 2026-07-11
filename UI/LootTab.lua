-- WeirdLoot Loot tab: the collected-loot list with per-row roll-bracket choice buttons, the loot
-- master Start/Skip controls, sorting, and the item info/usability columns. Pure presentation;
-- pulls shared widgets from the addon.UI namespace defined in UI.lua.
local addon = WeirdLoot
local util = addon.util
local UI = addon.UI
local createLabel = UI.createLabel
local createButton = UI.createButton
local createScrollList = UI.createScrollList
local elevateInteractiveFrame = UI.elevateInteractiveFrame
local getOptions = UI.getOptions

local GROUP_LOOT_TEXTURES = {
    glow = "Interface\\Buttons\\UI-ActionButton-Border",
}

-- Hover text comes from the shared addon.RESPONSE_TOOLTIPS (keyed by `key`), so the loot tab and
-- the live popup never spell the brackets out differently.
local RESPONSE_BUTTONS = {
    { key = "bis", label = "BiS", width = 30 },
    { key = "ms", label = "MS", width = 26 },
    { key = "mu", label = "MU", width = 26 },
    { key = "os", label = "OS", width = 26 },
    { key = "tm", label = "TM", width = 26 },
    { key = "pass", label = "Pass", width = 34 },
}

-- Equip-eligibility lives in Util (pure logic, needed by the headless tests and LiveRoll's roll
-- self-block). This file-local alias keeps the usable-sort callers below unchanged.
local function isItemUsableForPlayer(itemLink)
    return util:IsItemUsableForPlayer(itemLink)
end

local function getLootItemColumns(itemLink)
    local _, _, _, _, _, itemType, itemSubType, _, equipLoc = GetItemInfo(itemLink or "")
    local normalizedType = util:NormalizeKey(itemType or "")
    local normalizedSubType = util:NormalizeKey(itemSubType or "")
    local normalizedEquipLoc = util:NormalizeKey(equipLoc or "")

    local slotByEquipLoc = {
        invtype_head = "Head",
        invtype_neck = "Neck",
        invtype_shoulder = "Shoulder",
        invtype_body = "Shirt",
        invtype_chest = "Chest",
        invtype_robe = "Chest",
        invtype_waist = "Waist",
        invtype_legs = "Legs",
        invtype_feet = "Feet",
        invtype_wrist = "Wrist",
        invtype_hand = "Hands",
        invtype_finger = "Finger",
        invtype_trinket = "Trinket",
        invtype_cloak = "Back",
        invtype_weapon = "Weapon",
        invtype_2hweapon = "Two-Hand",
        invtype_weaponmainhand = "Main Hand",
        invtype_weaponoffhand = "Off Hand",
        invtype_holdable = "Off Hand",
        invtype_shield = "Shield",
        invtype_ranged = "Ranged",
        invtype_rangedright = "Ranged",
        invtype_thrown = "Thrown",
        invtype_relic = "Relic",
        invtype_tabard = "Tabard",
    }

    local slotText = slotByEquipLoc[normalizedEquipLoc] or util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or normalizedType)
    if normalizedEquipLoc == "invtype_relic" then
        slotText = util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or "Relic")
    end

    local typeText = ""
    if normalizedType == "armor" then
        typeText = util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or "Armor")
    elseif normalizedType == "weapon" then
        typeText = util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or "Weapon")
    else
        typeText = util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or normalizedType)
    end

    return typeText, slotText
end

local function getLootItemLookupName(item)
    if not item then
        return ""
    end

    local resolvedName = item.link and GetItemInfo(item.link)
    if resolvedName and resolvedName ~= "" then
        return resolvedName
    end

    if item.link and item.link ~= "" then
        local linkedName = string.match(item.link, "%[(.+)%]")
        if linkedName and linkedName ~= "" then
            return linkedName
        end
    end

    return item.name or ""
end

local function getLootItemInfoText(item)
    local lookupName = getLootItemLookupName(item)
    local entry = addon.defaultItemInfo and addon.defaultItemInfo[util:NormalizeKey(lookupName)]
    if not entry then
        return ""
    end

    local note = string.trim(entry.note or "")
    local role = string.trim(entry.role or "")
    if note ~= "" and role ~= "" then
        return string.format("%s, %s", note, role)
    end

    return note ~= "" and note or role
end

local function isPlayerAllowedForLootItem(item, playerName)
    local lookupName = getLootItemLookupName(item)
    return addon:IsPlayerAllowedForItem(item and item.itemId, lookupName, playerName)
end

local function createLootChoiceButton(parent, label, width)
    local button = CreateFrame("Button", nil, parent)
    elevateInteractiveFrame(button, parent, 8)
    button:SetWidth(width or 28)
    button:SetHeight(18)
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    button:SetBackdropColor(0.2, 0.06, 0.06, 0.95)
    button:SetBackdropBorderColor(0.55, 0.38, 0.12, 0.9)
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.text:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.text:SetText(label or "")
    button.glow = button:CreateTexture(nil, "OVERLAY")
    button.glow:SetTexture(GROUP_LOOT_TEXTURES.glow)
    button.glow:SetBlendMode("ADD")
    button.glow:SetAlpha(0.2)
    button.glow:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.glow:SetWidth((width or 28) + 22)
    button.glow:SetHeight(34)
    button.glow:Hide()
    button:SetScript("OnDisable", function(selfButton)
        selfButton:SetAlpha(0.45)
    end)
    button:SetScript("OnEnable", function(selfButton)
        selfButton:SetAlpha(1)
    end)
    return button
end

local function setLootChoiceButtonState(button, selected)
    if not button then
        return
    end

    if selected then
        button.glow:Show()
        button:SetBackdropColor(0.42, 0.12, 0.12, 0.95)
        button:SetBackdropBorderColor(1, 0.82, 0.18, 1)
        button.text:SetTextColor(1, 0.95, 0.7)
    else
        button.glow:Hide()
        button:SetBackdropColor(0.2, 0.06, 0.06, 0.95)
        button:SetBackdropBorderColor(0.55, 0.38, 0.12, 0.9)
        button.text:SetTextColor(1, 0.82, 0)
    end
end

local function updateLootChoiceButtons(row, selectedChoice)
    for _, option in ipairs(RESPONSE_BUTTONS) do
        setLootChoiceButtonState(row.choiceButtons and row.choiceButtons[option.key], selectedChoice == option.key)
    end
end

local function updateLootMasterControlButtons(row, isVisible, activeRoll, isLocked)
    if not row.startStopButton or not row.skipCancelButton then
        return
    end

    if isVisible then
        row.startStopButton:Show()
        row.skipCancelButton:Show()
        row.startStopButton.text:SetText(activeRoll and "End" or "Start")
        row.skipCancelButton.text:SetText(activeRoll and "Cancel" or "Skip")
        if activeRoll or not isLocked then
            row.startStopButton:Enable()
            row.skipCancelButton:Enable()
        else
            row.startStopButton:Disable()
            row.skipCancelButton:Disable()
        end
    else
        row.startStopButton:Hide()
        row.skipCancelButton:Hide()
    end
end

local function applyLootChoiceAvailability(row, isLocked, isAllowed, itemLink, itemName, isPhantom)
    -- Same policy as the roll popup (util:RollTierAvailability), rendered as plain enable/disable.
    local itemId = itemLink and util:ItemIdFromLink(itemLink)
    local blockReason = itemId and addon:RollSelfBlockReason(itemId, isPhantom)
    local hasPrio = addon:ItemHasPriority(itemName)
    local avail = util:RollTierAvailability(itemLink, isAllowed, isLocked, blockReason, hasPrio)
    for _, option in ipairs(RESPONSE_BUTTONS) do
        local button = row.choiceButtons[option.key]
        if avail[option.key] then button:Disable() else button:Enable() end
    end
end

function addon:BuildLootTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.loot = panel

    local header = createLabel(panel, "Session items", "TOPLEFT", panel, "TOPLEFT", 4, -4)
    header:SetFontObject(GameFontHighlight)

    local usabilityButton = createButton(panel, "Usable: Off", 110, 22)
    usabilityButton:SetPoint("LEFT", header, "RIGHT", 12, 0)
    usabilityButton:SetScript("OnClick", function()
        addon:ToggleLootUsabilitySort()
    end)
    panel.usabilityButton = usabilityButton

    local headerName = createButton(panel, "Name", 80, 18)
    headerName:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 24, -12)
    headerName:SetScript("OnClick", function()
        addon:SetLootSortMode("name")
    end)
    headerName.baseLabel = "Name"
    panel.headerName = headerName

    local headerChoice = createButton(panel, "Roll Type", 204, 18)
    headerChoice:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 228, -12)
    headerChoice:SetScript("OnClick", function() end)
    panel.headerChoice = headerChoice

    local headerType = createButton(panel, "Type", 54, 18)
    headerType:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 490, -12)
    headerType:SetScript("OnClick", function()
        addon:SetLootSortMode("type")
    end)
    headerType.baseLabel = "Type"
    panel.headerType = headerType

    local headerSlot = createButton(panel, "Slot", 54, 18)
    headerSlot:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 548, -12)
    headerSlot:SetScript("OnClick", function()
        addon:SetLootSortMode("slot")
    end)
    headerSlot.baseLabel = "Slot"
    panel.headerSlot = headerSlot

    local headerInfo = createButton(panel, "Info", 70, 18)
    headerInfo:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 608, -12)
    headerInfo:SetScript("OnClick", function()
        addon:SetLootSortMode("info")
    end)
    headerInfo.baseLabel = "Info"
    panel.headerInfo = headerInfo

    local headerRollers = createButton(panel, "Rollers", 80, 18)
    headerRollers:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 760, -12)
    headerRollers:SetScript("OnClick", function() end)
    panel.headerRollers = headerRollers

    local list = createScrollList(panel, "WeirdLootLootList", 19, function(row)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(18)
        row.icon:SetHeight(18)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

        row.name = createLabel(row, "", "LEFT", row.icon, "RIGHT", 8, 0)
        row.name:SetWidth(176)

        row.startStopButton = createLootChoiceButton(row, "Start", 42)
        row.startStopButton:SetPoint("LEFT", row, "LEFT", 210, 0)
        row.startStopButton:SetScript("OnClick", function()
            if not row.item or not addon:IsAuthorizedLootMaster() then
                return
            end

            local activeRoll = addon:GetActiveLiveRollForItem(row.item)
            if activeRoll then
                addon:ResolveLiveRoll(activeRoll.id)
            else
                addon:StartLiveRollFromItem(row.item)
            end
        end)
        row.startStopButton:Hide()

        row.skipCancelButton = createLootChoiceButton(row, "Skip", 46)
        row.skipCancelButton:SetPoint("LEFT", row.startStopButton, "RIGHT", 2, 0)
        row.skipCancelButton:SetScript("OnClick", function()
            if not row.item or not addon:IsAuthorizedLootMaster() then
                return
            end

            local activeRoll = addon:GetActiveLiveRollForItem(row.item)
            if activeRoll then
                addon:CancelLiveRoll(activeRoll.id)
            else
                addon:SkipLiveLootItem(row.item)
            end
        end)
        row.skipCancelButton:Hide()

        row.choiceButtons = {}
        local previousButton
        for _, option in ipairs(RESPONSE_BUTTONS) do
            local responseButton = createLootChoiceButton(row, option.label, option.width)
            responseButton:SetScript("OnEnter", function(b)
                -- A disabled bracket (locked item / class-disallowed) shows nothing; only an
                -- available one spells itself out. Plain Buttons drop mouse scripts while disabled
                -- anyway, but guard explicitly so intent does not hinge on that default.
                if not b:IsEnabled() then return end
                -- getOptions (declared later in this file) is not in scope here; read directly. The
                -- key is seeded true by ensureDefaults, so a missing value never reads as "off".
                local opts = addon.db and addon.db.options
                if opts and not opts.explanationTooltipsEnabled then return end
                GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                GameTooltip:SetText(addon.RESPONSE_TOOLTIPS[option.key], 1, 0.82, 0, true)
                GameTooltip:Show()
            end)
            responseButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
            if not previousButton then
                responseButton:SetPoint("LEFT", row.skipCancelButton, "RIGHT", 4, 0)
            else
                responseButton:SetPoint("LEFT", previousButton, "RIGHT", 2, 0)
            end
            responseButton:SetScript("OnClick", function()
                if not row.item then
                    return
                end
                if addon:IsItemLocked(row.item.id) then
                    addon:Print("That loot is locked. Ask the loot master to unlock it before changing rolls.")
                    return
                end

                local playerName = util:GetPlayerName("player")
                if option.key ~= "pass" and not isPlayerAllowedForLootItem(row.item, playerName) then
                    addon:Print("Your class cannot use that token. You may only pass.")
                    return
                end
                -- row.item.itemId, not row.item.id: the row id is the LOT id ("L:n"), and the
                -- hold/quest checks match on the numeric item id
                local blockReason = option.key ~= "pass" and addon:RollSelfBlockReason(row.item.itemId, row.item.phantom)
                if blockReason == "quest" then
                    addon:Print("You have already completed that quest. You may only pass.")
                    return
                elseif blockReason == "unique" then
                    addon:Print("You already have that unique item. You may only pass.")
                    return
                end
                -- SetPlayerResponse routes itself: the ML writes the core (delta syncs out),
                -- a raider whispers the pick to the ML. The loot tab and the live roll share the
                -- lot's responses, so a loot-tab pick already reflects on the roll. No separate
                -- per-pick broadcast path is needed here.
                if not addon:SetPlayerResponse(row.item.id, playerName, option.key) then
                    return
                end
                updateLootChoiceButtons(row, option.key)
            end)
            row.choiceButtons[option.key] = responseButton
            previousButton = responseButton
        end

        row.itemType = createLabel(row, "", "LEFT", row, "LEFT", 490, 0)
        row.itemType:SetWidth(52)

        row.itemSlot = createLabel(row, "", "LEFT", row, "LEFT", 548, 0)
        row.itemSlot:SetWidth(54)

        row.info = createLabel(row, "", "LEFT", row, "LEFT", 608, 0)
        row.info:SetWidth(140)

        row.state = createLabel(row, "", "LEFT", row, "LEFT", 760, 0)
        row.state:SetWidth(70)
        row.state:SetJustifyH("LEFT")
        row.stateHitbox = CreateFrame("Frame", nil, row)
        elevateInteractiveFrame(row.stateHitbox, row, 10)
        row.stateHitbox:SetPoint("TOPLEFT", row.state, "TOPLEFT", -4, 4)
        row.stateHitbox:SetPoint("BOTTOMRIGHT", row.state, "BOTTOMRIGHT", 4, -4)
        row.stateHitbox:EnableMouse(true)
        row.stateHitbox:SetScript("OnEnter", function()
            GameTooltip:Hide()
            if not row.item then
                return
            end

            GameTooltip:SetOwner(row.stateHitbox, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("TOPLEFT", row.stateHitbox, "BOTTOMLEFT", 0, -4)
            GameTooltip:ClearLines()
            GameTooltip:AddLine("Players Rolling", 1, 0.82, 0)

            -- Same one source as the count and the popup: the live pick-list while a roll is active,
            -- else the ledger responses. No roll number is shown (rolls happen at resolution).
            local entries = addon:ActiveRollers(row.item.id)
            if #entries == 0 then
                GameTooltip:AddLine("No active rollers", 1, 1, 1)
            else
                for _, entry in ipairs(entries) do
                    local nameText = util:IsSelfName(entry.name) and "You" or util:ColorPlayerName(entry.name, entry.className)
                    local lineText = string.format("%s - %s", nameText, addon:GetResponseLabel(entry.tier))
                    GameTooltip:AddLine(util:ColorPlayerText(entry.name, entry.className, lineText), 1, 1, 1)
                end
            end

            GameTooltip:Show()
        end)
        row.stateHitbox:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Reroll button (loot master only, shown when the lot is locked/resolved). Sits at the
        -- right edge of the row, to the right of "N rolling". Opens a confirmation popup that
        -- previews the item's tooltip; YES routes through addon:UnlockSessionRoll.
        row.rerollButton = createLootChoiceButton(row, "Reroll", 52)
        elevateInteractiveFrame(row.rerollButton, row, 10)
        -- Right-anchored to the row so the button sits flush against the right edge regardless of
        -- the state column width. Leaves a small margin for the scrollbar gutter.
        row.rerollButton:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.rerollButton:Hide()
        row.rerollButton:SetScript("OnClick", function()
            local item = row.item
            if not item or not item.id then return end
            local dialog = StaticPopup_Show("WEIRDLOOT_REROLL_ITEM", item.link or item.name or "this item")
            if dialog then
                dialog.data = { lotId = item.id, itemLink = item.link }
            end
        end)

        -- LC button (loot master only): set a session-scoped Loot Council priority for THIS item.
        -- Sits immediately to the left of Reroll. The chosen priority overrides the persistent
        -- named-items rule for the rest of the session; the LM still clicks Reroll to apply it.
        -- Selected-state glow lights up while an override is set so the row reads at a glance.
        row.lcButton = createLootChoiceButton(row, "LC", 28)
        elevateInteractiveFrame(row.lcButton, row, 10)
        row.lcButton:SetPoint("RIGHT", row.rerollButton, "LEFT", -4, 0)
        row.lcButton:Hide()
        row.lcButton:SetScript("OnClick", function()
            local item = row.item
            if not item or not item.name then return end
            local rule = addon:GetSessionLCOverride(item.name)
            local current = (rule and rule.raw) or ""
            local dialog = StaticPopup_Show("WEIRDLOOT_SET_LC_OVERRIDE", item.link or item.name)
            if dialog then
                dialog.data = { itemName = item.name, itemLink = item.link, current = current }
            end
        end)

        -- The item tooltip and item-link clicks (ctrl preview, shift link-insert, ML right-click to
        -- start a roll) belong to the icon + name, not the whole row: hovering a button or an empty
        -- column should not pop the item tooltip. A hitbox spanning the icon/name up to the Start
        -- button carries them. Because it captures the mouse over that area it must also carry the
        -- clicks -- a bare hover frame would swallow them from the row underneath.
        local function showItemTooltip(anchor)
            local item = row.item
            if not item or not item.link or item.link == "" then
                return
            end
            GameTooltip:SetOwner(anchor, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink(item.link)
            GameTooltip:Show()
        end

        local function handleItemClick(button)
            local item = row.item
            if not item or not item.link or item.link == "" then
                return
            end

            if button == "RightButton" then
                if addon:IsAuthorizedLootMaster() then
                    addon:StartLiveRollFromItem(item)
                end
                return
            end

            if button ~= "LeftButton" then
                return
            end

            if IsShiftKeyDown() and ChatEdit_GetActiveWindow() then
                ChatEdit_InsertLink(item.link)
                return
            end

            -- Plain click does nothing; ctrl+click previews in the dressing room, matching
            -- the standard modified-click behavior of item links everywhere else.
            if IsModifiedClick("DRESSUP") then
                if DressUpItemLink then
                    DressUpItemLink(item.link)
                else
                    GameTooltip:SetOwner(row, "ANCHOR_NONE")
                    GameTooltip:ClearAllPoints()
                    GameTooltip:SetPoint("TOPRIGHT", row, "TOPLEFT", -8, 0)
                    GameTooltip:SetHyperlink(item.link)
                    GameTooltip:Show()
                end
            end
        end

        row.itemHitbox = CreateFrame("Button", nil, row)
        elevateInteractiveFrame(row.itemHitbox, row, 10)
        row.itemHitbox:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        -- left edge + full row height from the row; right edge stops just before the Start button
        row.itemHitbox:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        row.itemHitbox:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        row.itemHitbox:SetPoint("RIGHT", row.startStopButton, "LEFT", -2, 0)
        row.itemHitbox:SetScript("OnEnter", function(selfBox) showItemTooltip(selfBox) end)
        row.itemHitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.itemHitbox:SetScript("OnClick", function(_, button) handleItemClick(button) end)

        -- The row keeps the clicks for the area OUTSIDE the item hitbox (so ML right-click-to-start
        -- still works across the wider row), but no longer owns the tooltip.
        row:SetScript("OnClick", function(_, button) handleItemClick(button) end)
    end)
    list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -28)
    list:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    self.ui.lootList = list
end

function addon:ToggleLootSortMode()
    self.db.ui.lootSortMode = self.db.ui.lootSortMode == "gear" and "name" or "gear"
    self:RefreshLootTab()
end

-- Header click is tri-state (same as the Results tab): first click on a column sorts it ascending,
-- second flips to descending, third turns the column sort off and falls back to the "recent"
-- default (mint order, newest first). Clicking a different column starts it fresh at ascending.
function addon:SetLootSortMode(mode)
    local ui = self.db.ui
    if ui.lootSortMode ~= mode then
        ui.lootSortMode = mode
        ui.lootSortDir = "asc"
    elseif ui.lootSortDir ~= "desc" then
        ui.lootSortDir = "desc"
    else
        ui.lootSortMode = "recent"
        ui.lootSortDir = "asc"
    end
    self:RefreshLootTab()
end

function addon:ToggleLootUsabilitySort()
    self.db.ui.lootUsabilitySort = not self.db.ui.lootUsabilitySort
    self:RefreshLootTab()
end

function addon:GetSortedLootItems()
    local items = {}
    for i, item in ipairs(self.lootView.items or {}) do
        item._mint = i   -- source arrives in mint order (oldest first); used by the "recent" sort
        items[#items + 1] = item
    end

    local sortMode = self.db.ui.lootSortMode or "recent"
    local desc = self.db.ui.lootSortDir == "desc"

    -- Ascending comparator for the active column. Direction and the usable-first grouping are
    -- applied uniformly in the table.sort wrapper below, so each mode only states its own key.
    local keyCmp
    if sortMode == "gear" then
        keyCmp = function(left, right)
            local leftInfo = util:GetLootSortInfo(left.link)
            local rightInfo = util:GetLootSortInfo(right.link)
            if leftInfo.order ~= rightInfo.order then return leftInfo.order < rightInfo.order end
            if leftInfo.subtype ~= rightInfo.subtype then return leftInfo.subtype < rightInfo.subtype end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end
    elseif sortMode == "type" then
        keyCmp = function(left, right)
            local leftType = util:NormalizeKey(select(1, getLootItemColumns(left.link)))
            local rightType = util:NormalizeKey(select(1, getLootItemColumns(right.link)))
            if leftType ~= rightType then return leftType < rightType end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end
    elseif sortMode == "slot" then
        keyCmp = function(left, right)
            local leftSlot = util:NormalizeKey(select(2, getLootItemColumns(left.link)))
            local rightSlot = util:NormalizeKey(select(2, getLootItemColumns(right.link)))
            if leftSlot ~= rightSlot then return leftSlot < rightSlot end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end
    elseif sortMode == "info" then
        keyCmp = function(left, right)
            local leftInfo = util:NormalizeKey(getLootItemInfoText(left))
            local rightInfo = util:NormalizeKey(getLootItemInfoText(right))
            if leftInfo ~= rightInfo then return leftInfo < rightInfo end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end
    elseif sortMode == "name" then
        keyCmp = function(left, right)
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end
    else
        -- "recent": mint order, newest first (higher mint index on top). This is the default and the
        -- tri-state "off" state; the header cycle never lands here with desc set, so it stays newest-first.
        keyCmp = function(left, right) return left._mint > right._mint end
    end

    table.sort(items, function(left, right)
        if self.db.ui.lootUsabilitySort then
            local leftUsable = isItemUsableForPlayer(left.link)
            local rightUsable = isItemUsableForPlayer(right.link)
            if leftUsable ~= rightUsable then return leftUsable end
        end
        if desc then return keyCmp(right, left) end   -- swapping args reverses the ordering, ties included
        return keyCmp(left, right)
    end)

    return items
end

-- Show which column is sorting and which way: "^" ascending, "v" descending, nothing when the
-- column is off (the recent default, which highlights no header).
function addon:UpdateLootHeaderLabels()
    local panel = self.ui.panels and self.ui.panels.loot
    if not panel then return end
    local mode = (self.db.ui and self.db.ui.lootSortMode) or "recent"
    local arrow = (self.db.ui and self.db.ui.lootSortDir == "desc") and " v" or " ^"
    local headers = {
        name = panel.headerName, type = panel.headerType,
        slot = panel.headerSlot, info = panel.headerInfo,
    }
    for key, header in pairs(headers) do
        if header and header.baseLabel then
            header:SetText(header.baseLabel .. (mode == key and arrow or ""))
        end
    end
end

function addon:RefreshLootTab()
    self:UpdateLootHeaderLabels()
    local items = self:GetSortedLootItems()
    local playerName = util:GetPlayerName("player")
    if self.ui.panels and self.ui.panels.loot and self.ui.panels.loot.usabilityButton then
        local usabilityLabel = self.db.ui.lootUsabilitySort and "Usable: On" or "Usable: Off"
        self.ui.panels.loot.usabilityButton:SetText(usabilityLabel)
    end
    -- Cold cache: warm any uncached item names via the same scan-tooltip primer the roll popups
    -- use, so a freshly-dropped item does not sit in the list as a stale "item:<id>".
    self:WarmLootItemNames(items)
    self.ui.lootList.update(#items, function(row, index)
        local item = items[index]
        row.item = item
        if not item then
            row:Hide()
            return
        end

        row:Show()
        -- Re-resolve from itemId so a name the client cached AFTER the projection was built shows
        -- here instead of the stale fallback the cold-cache projection stored.
        local rName, rLink, rIcon = util:ItemRender(item.itemId)
        row.icon:SetTexture(rIcon or item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local itemText = (rLink and rLink ~= "" and rLink)
            or (item.link and item.link ~= "" and item.link)
            or rName or item.name or ""
        if (item.quantity or 1) > 1 then
            itemText = string.format("%s x%d", itemText, item.quantity)
        end
        row.name:SetText(itemText)

        local responseChoice = self:GetPlayerResponse(item.id, playerName)
        updateLootChoiceButtons(row, responseChoice)
        local locked = self:IsItemLocked(item.id)
        local allowedForPlayer = isPlayerAllowedForLootItem(item, playerName)
        row.icon:SetDesaturated(locked)        -- grey out the item icon once it's been rolled out
        applyLootChoiceAvailability(row, locked, allowedForPlayer, item.link, rName or item.name, item.phantom)
        updateLootMasterControlButtons(row, self:IsAuthorizedLootMaster(), self:GetActiveLiveRollForItem(item), locked)
        local typeText, slotText = getLootItemColumns(item.link)
        row.itemType:SetText(typeText)
        row.itemSlot:SetText(slotText)
        row.info:SetText(getLootItemInfoText(item))

        -- ActiveRollers is the one roller source (shared with the hover tooltip and both popup
        -- displays), so the count never disagrees across surfaces.
        row.state:SetText(string.format("%d rolling", #self:ActiveRollers(item.id)))

        if row.rerollButton then
            if locked and self:IsAuthorizedLootMaster() then
                row.rerollButton:Show()
            else
                row.rerollButton:Hide()
            end
        end
        if row.lcButton then
            if self:IsAuthorizedLootMaster() then
                row.lcButton:Show()
                local hasOverride = self:GetSessionLCOverride(item.name) ~= nil
                setLootChoiceButtonState(row.lcButton, hasOverride)
            else
                row.lcButton:Hide()
            end
        end
    end)
    -- arm the shared resolve ticker if any name was still cold; it re-renders this list as the
    -- client caches them, then self-stops (same machinery the popups use).
    if self._lootNamesPending then self:EnsureNameTicker() end
end

-- Press the local player's chosen bracket on the visible loot row for a lot, without a full
-- RefreshLootTab. This is what lets a popup pick light up the loot tab immediately even on a
-- raider, whose own pick is whispered to the ML and is not in the local ledger (which is all
-- RefreshLootTab can read) until the snapshot returns. ApplyLocalChoice drives both surfaces.
function addon:MarkLocalLootChoice(lotId, tier)
    local list = self.ui and self.ui.lootList
    if not list or not list.rows then return end
    for _, row in ipairs(list.rows) do
        if row.item and row.item.id == lotId and row.choiceButtons then
            updateLootChoiceButtons(row, tier)
            return
        end
    end
end

