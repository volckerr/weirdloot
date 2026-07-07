-- WeirdLoot Options tab: result-popup / roll / auto-mode / filter (whitelist+blacklist) / minimap /
-- tooltip settings and the per-list preset dropdowns. Pure presentation; pulls shared widgets from addon.UI.
local addon = WeirdLoot
local util = addon.util
local UI = addon.UI
local createLabel = UI.createLabel
local createButton = UI.createButton
local elevateInteractiveFrame = UI.elevateInteractiveFrame
local getOptions = UI.getOptions
local createOptionsCheckbox = UI.createOptionsCheckbox
local bindExclusiveCheckboxes = UI.bindExclusiveCheckboxes
local createNumberEditBox = UI.createNumberEditBox
local createTextEditBox = UI.createTextEditBox
local createMultilineEditScroll = UI.createMultilineEditScroll
local createPresetManager = UI.createPresetManager

function addon:BuildOptionsTab()
    local scroll = CreateFrame("ScrollFrame", "WeirdLootOptionsScrollFrame", self.ui.content, "UIPanelScrollFrameTemplate")
    elevateInteractiveFrame(scroll, self.ui.content, 2)
    scroll:SetPoint("TOPLEFT", self.ui.content, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", self.ui.content, "BOTTOMRIGHT", -24, 0)
    self.ui.panels.options = scroll

    -- Show the drag placeholder (a stand-in at the banner's spot) only while this tab is visible so
    -- players can pre-position without a real drop. OnShow/OnHide fire on tab switch AND on the main
    -- window opening/closing (ancestor visibility propagates), so this one hook covers every case.
    scroll:HookScript("OnShow", function() if addon.SetLootBannerAnchorShown then addon:SetLootBannerAnchorShown(true) end end)
    scroll:HookScript("OnHide", function() if addon.SetLootBannerAnchorShown then addon:SetLootBannerAnchorShown(false) end end)

    local panel = CreateFrame("Frame", nil, scroll)
    elevateInteractiveFrame(panel, scroll, 1)
    panel:SetWidth(920)
    panel:SetHeight(1130)   -- includes the Loot Banner display section (header + 4 rows) before whitelist
    scroll:SetScrollChild(panel)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(selfFrame, delta)
        local current = selfFrame:GetVerticalScroll() or 0
        local max = selfFrame:GetVerticalScrollRange() or 0
        local step = 30
        local new = current - delta * step
        if new < 0 then new = 0 elseif new > max then new = max end
        selfFrame:SetVerticalScroll(new)
    end)
    self.ui.optionsPanel = panel

    local opt = getOptions(self)

    panel.title = createLabel(panel, "Options", "TOPLEFT", panel, "TOPLEFT", 12, -12)
    panel.title:SetFontObject(GameFontHighlightLarge)
    panel.title:SetTextColor(1, 0.82, 0)

    local titleDivider = panel:CreateTexture(nil, "ARTWORK")
    titleDivider:SetTexture("Interface\\Buttons\\WHITE8x8")
    titleDivider:SetVertexColor(0.5, 0.4, 0.1, 0.6)
    titleDivider:SetHeight(1)
    titleDivider:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -4)
    titleDivider:SetPoint("RIGHT", panel, "RIGHT", -40, 0)

    -- Winner banner hold time (the finished-loot toast; still keyed resultPopupAutoClose* for compat)
    local autoCloseCB = createOptionsCheckbox(panel, "Auto-hide the winner banner after")
    autoCloseCB:SetPoint("TOPLEFT", titleDivider, "BOTTOMLEFT", 0, -14)
    autoCloseCB:SetChecked(opt.resultPopupAutoCloseEnabled and true or false)

    local autoCloseSeconds = createNumberEditBox(panel, 40)
    autoCloseSeconds:SetPoint("LEFT", autoCloseCB.label or autoCloseCB, "RIGHT", 8, 0)
    autoCloseSeconds:SetText(tostring(opt.resultPopupAutoCloseSeconds or 15))
    autoCloseSeconds:SetScript("OnEditFocusLost", function(selfBox)
        local v = tonumber(selfBox:GetText())
        if v and v >= 0 then           -- 0 is valid: fade out immediately, no hold
            getOptions(addon).resultPopupAutoCloseSeconds = v
        else
            selfBox:SetText(tostring(getOptions(addon).resultPopupAutoCloseSeconds or 15))
        end
    end)
    local autoCloseLabel = createLabel(panel, "seconds", "LEFT", autoCloseSeconds, "RIGHT", 6, 0)

    local function applyAutoCloseColor()
        if autoCloseCB:GetChecked() then
            autoCloseSeconds:SetTextColor(1, 1, 1)
        else
            autoCloseSeconds:SetTextColor(0.5, 0.5, 0.5)
        end
    end
    autoCloseCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).resultPopupAutoCloseEnabled = selfCB:GetChecked() and true or false
        applyAutoCloseColor()
    end)
    applyAutoCloseColor()

    -- ============================================================
    -- Loot Master Options (anchored to the BOTTOM of the panel, after the blacklist box)
    -- ============================================================
    local lmHeader = createLabel(panel, "Loot Master Options", "TOPLEFT", panel, "TOPLEFT", 12, 0)
    lmHeader:SetFontObject(GameFontHighlightLarge)
    lmHeader:SetTextColor(1, 0.82, 0)

    local lmDivider = panel:CreateTexture(nil, "ARTWORK")
    lmDivider:SetTexture("Interface\\Buttons\\WHITE8x8")
    lmDivider:SetVertexColor(0.5, 0.4, 0.1, 0.6)
    lmDivider:SetHeight(1)
    lmDivider:SetPoint("TOPLEFT", lmHeader, "BOTTOMLEFT", 0, -4)
    lmDivider:SetPoint("RIGHT", panel, "RIGHT", -40, 0)

    -- Keep finished-loot winner popups open on the ML's screen so they can study the winners,
    -- ignoring the ML's own auto-close. ML-only: raiders always follow their personal setting.
    local keepResultCB = createOptionsCheckbox(panel, "Never auto-hide your own winner banners")
    keepResultCB:SetPoint("TOPLEFT", lmDivider, "BOTTOMLEFT", 0, -14)
    keepResultCB:SetChecked(opt.forceKeepResultPopup ~= false)   -- default ON
    keepResultCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).forceKeepResultPopup = selfCB:GetChecked() and true or false
    end)

    -- Roll duration (loot master)
    local rollDurLabel = createLabel(panel, "Roll duration (seconds):",
        "TOPLEFT", keepResultCB, "BOTTOMLEFT", 0, -14)
    local rollDurBox = createNumberEditBox(panel, 50)
    rollDurBox:SetPoint("LEFT", rollDurLabel, "RIGHT", 12, 0)
    rollDurBox:SetText(tostring(opt.rollDuration))
    rollDurBox:SetScript("OnEditFocusLost", function(selfBox)
        local v = tonumber(selfBox:GetText())
        if v and v > 0 then
            getOptions(addon).rollDuration = v
        else
            selfBox:SetText(tostring(getOptions(addon).rollDuration))
        end
    end)

    -- Start Rolls batch size (loot master)
    local batchLabel = createLabel(panel, "Start Rolls batch size (items rolled at once):",
        "TOPLEFT", rollDurLabel, "BOTTOMLEFT", 0, -20)
    local batchBox = createNumberEditBox(panel, 50)
    batchBox:SetPoint("LEFT", batchLabel, "RIGHT", 12, 0)
    batchBox:SetText(tostring(opt.rollBatchSize or 5))
    batchBox:SetScript("OnEditFocusLost", function(selfBox)
        local v = tonumber(selfBox:GetText())
        if v and v > 0 then
            getOptions(addon).rollBatchSize = v
        else
            selfBox:SetText(tostring(getOptions(addon).rollBatchSize or 5))
        end
    end)

    -- Three mutex auto-modes for new loot. Mirrors the slash commands /wl autoroll, /wl autostart,
    -- /wl autoskip. Picking one forces the other two off; all three off means the LM drives every
    -- roll manually from the Loot tab.
    local autoRollCB = createOptionsCheckbox(panel, "Auto-open the pending Start/Skip popup when new loot lands in bags")
    autoRollCB:SetPoint("TOPLEFT", batchLabel, "BOTTOMLEFT", 0, -16)
    autoRollCB:SetChecked(self.db.autoRoll == true)

    local autoStartCB = createOptionsCheckbox(panel, "Auto-start rolls when loot lands in bags (popups start already rolling)")
    autoStartCB:SetPoint("TOPLEFT", autoRollCB, "BOTTOMLEFT", 0, -8)
    autoStartCB:SetChecked(opt.autoStartRoll and true or false)

    local autoSkipCB = createOptionsCheckbox(panel, "Auto-skip a live roll when new loot lands in bags")
    autoSkipCB:SetPoint("TOPLEFT", autoStartCB, "BOTTOMLEFT", 0, -8)
    autoSkipCB:SetChecked(opt.autoSkipRoll and true or false)

    bindExclusiveCheckboxes({
        { cb = autoRollCB,
          get = function() return addon.db.autoRoll end,
          set = function(on) addon.db.autoRoll = on end,
          onToggle = function(on) addon:Print("Auto-roll (auto-open the Start/Skip pending popup) on new loot "
              .. (on and "ON." or "OFF (lots stay in the loot tab; start them manually).")) end },
        { cb = autoStartCB,
          get = function() return getOptions(addon).autoStartRoll end,
          set = function(on) getOptions(addon).autoStartRoll = on end,
          onToggle = function(on) addon:Print("Auto-start a live roll on new loot " .. (on
              and "ON (broadcasts the DROP immediately, no Start/Skip popup)." or "OFF.")) end },
        { cb = autoSkipCB,
          get = function() return getOptions(addon).autoSkipRoll end,
          set = function(on) getOptions(addon).autoSkipRoll = on end,
          onToggle = function(on) addon:Print("Auto-skip new loot "
              .. (on and "ON (new loot lands as Skipped; revisit from the loot tab)." or "OFF.")) end },
    })

    -- Designated disenchanter (loot master). Mirrors /wl deer <name>. Non-epic BoE items
    -- routed through Master Loot go to this player's bags via GiveMasterLoot.
    local deerLabel = createLabel(panel, "Designated disenchanter (non-epic BoE auto-routes here):",
        "TOPLEFT", autoSkipCB, "BOTTOMLEFT", 0, -16)
    local deerBox = createTextEditBox(panel, 160)
    deerBox:SetPoint("LEFT", deerLabel, "RIGHT", 12, 0)
    deerBox.editBox:SetText(self.db.deer or "")
    deerBox.editBox:SetScript("OnEditFocusLost", function(selfBox)
        local name = string.trim(selfBox:GetText() or "")
        if name == "" then
            addon.db.deer = nil
            addon:Print("Disenchanter cleared.")
        else
            addon.db.deer = name
            addon:Print("Disenchanter set to " .. name .. " (non-epic BoE auto-routes there).")
        end
    end)

    -- Explanation tooltips (e.g. roll-bracket descriptions on the popup + loot tab)
    local explanationTipsCB = createOptionsCheckbox(panel, "Show explanation tooltips (spell out the roll brackets, etc.)")
    explanationTipsCB:SetPoint("TOPLEFT", autoCloseCB, "BOTTOMLEFT", 0, -20)
    explanationTipsCB:SetChecked(opt.explanationTooltipsEnabled ~= false)
    explanationTipsCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).explanationTooltipsEnabled = selfCB:GetChecked() and true or false
    end)

    -- Hide rolls for items this player's class can't use (armor/weapon proficiency only; off by
    -- default). Unique-owned / quest-done items still show -- this is purely class equip-eligibility.
    local hideUnusableCB = createOptionsCheckbox(panel, "Hide rolls for items my class can't equip")
    hideUnusableCB:SetPoint("TOPLEFT", explanationTipsCB, "BOTTOMLEFT", 0, -20)
    hideUnusableCB:SetChecked(opt.hideUnusableRolls and true or false)
    hideUnusableCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).hideUnusableRolls = selfCB:GetChecked() and true or false
    end)

    -- Suppress the win banner for loot you did not roll on: items you passed, or whose roll prompt
    -- your white/black list or hide-unusable filter hid. Off by default.
    local hideUnrolledWinsCB = createOptionsCheckbox(panel, "Only show winners for loot I rolled on")
    hideUnrolledWinsCB:SetPoint("TOPLEFT", hideUnusableCB, "BOTTOMLEFT", 0, -20)
    hideUnrolledWinsCB:SetChecked(opt.hideUnrolledWins and true or false)
    hideUnrolledWinsCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).hideUnrolledWins = selfCB:GetChecked() and true or false
    end)

    -- Whitelist
    local whitelistCB = createOptionsCheckbox(panel, "Enable White List |cffff3030(Warning: You will ONLY see loot popups for items on this list)|r")
    whitelistCB:SetPoint("TOPLEFT", hideUnusableCB, "BOTTOMLEFT", 0, -24)   -- overridden in the final layout pass
    whitelistCB:SetChecked(opt.whitelistEnabled and true or false)
    -- OnClick is wired below via bindExclusiveCheckboxes, once blacklistCB also exists (mutually exclusive).

    local whitelistBox = createPresetManager(panel, "whitelist", whitelistCB)

    -- Blacklist
    local blacklistCB = createOptionsCheckbox(panel, "Enable Black List |cffff3030(Warning: you will ONLY see loot popups for items NOT on this list)|r")
    blacklistCB:SetPoint("TOP", whitelistBox, "BOTTOM", 0, -16)
    blacklistCB:SetPoint("LEFT", panel, "LEFT", 12, 0)
    blacklistCB:SetChecked(opt.blacklistEnabled and true or false)

    -- Whitelist and blacklist are mutually exclusive: an "only these" list and an "all but these"
    -- list contradict, so wire the pair as an exclusive group now that both checkboxes exist.
    bindExclusiveCheckboxes({
        { cb = whitelistCB, get = function() return getOptions(addon).whitelistEnabled end,
          set = function(on) getOptions(addon).whitelistEnabled = on end },
        { cb = blacklistCB, get = function() return getOptions(addon).blacklistEnabled end,
          set = function(on) getOptions(addon).blacklistEnabled = on end },
    })

    local blacklistBox = createPresetManager(panel, "blacklist", blacklistCB, {
        note = "Curated presets are shown below, select CLASS to see main and offspec pieces, or SPEC to see only items useful for that spec.",
    })

    -- Minimap button visibility -- sits above the whitelist section (re-anchored below to land
    -- above whitelistCB once that widget exists; see the re-anchor after explanationTipsCB).
    local minimapCB = createOptionsCheckbox(panel, "Show minimap button")
    minimapCB:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, 0)
    minimapCB:SetChecked(not (opt.minimapButtonHidden and true or false))
    minimapCB:SetScript("OnClick", function(selfCB)
        local checked = selfCB:GetChecked() and true or false
        getOptions(addon).minimapButtonHidden = not checked
        addon:SetMinimapButtonShown(checked)
    end)

    -- Roll result tooltip docking: where the result/roller hover tooltips appear relative to the
    -- popup. Defaults to the right of the popup; configurable since that can be wrong for some UIs.
    local anchorLabel = createLabel(panel, "Roll result tooltip docking:", "TOPLEFT", minimapCB, "BOTTOMLEFT", 0, -22)
    local ANCHOR_OPTIONS = {
        { value = "RIGHT",  text = "Right of popup" },
        { value = "LEFT",   text = "Left of popup" },
        { value = "TOP",    text = "Above popup" },
        { value = "BOTTOM", text = "Below popup" },
        { value = "CURSOR", text = "At cursor" },
    }
    local function anchorText(v)
        for _, o in ipairs(ANCHOR_OPTIONS) do if o.value == v then return o.text end end
        return ANCHOR_OPTIONS[1].text
    end
    local anchorDrop = CreateFrame("Frame", "WeirdLootTooltipAnchorDropdown", panel, "UIDropDownMenuTemplate")
    -- The dropdown (and its child Button) is created at the panel's BASE level, so on this elevated
    -- panel it renders dimmed under the +8 widgets and its button never catches clicks. Raise the
    -- frame AND the button child (raising the parent does not reliably cascade to children on 3.3.5a).
    elevateInteractiveFrame(anchorDrop, panel, 8)
    local anchorBtn = _G[anchorDrop:GetName() .. "Button"]
    if anchorBtn then elevateInteractiveFrame(anchorBtn, anchorDrop, 2) end
    anchorDrop:SetPoint("LEFT", anchorLabel, "RIGHT", -4, -2)
    UIDropDownMenu_SetWidth(anchorDrop, 120)
    UIDropDownMenu_Initialize(anchorDrop, function(_, level)
        for _, o in ipairs(ANCHOR_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = o.text
            info.value = o.value
            info.checked = (getOptions(addon).rollResultTooltipAnchor or "RIGHT") == o.value
            info.func = function()
                getOptions(addon).rollResultTooltipAnchor = o.value
                UIDropDownMenu_SetText(anchorDrop, o.text)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetText(anchorDrop, anchorText(opt.rollResultTooltipAnchor or "RIGHT"))

    -- ============================================================
    -- Loot Banner (display) -- the roll cards + winner toast. Section header, then the look toggles
    -- and the position controls. Anchored into the chain in the final layout pass below.
    -- ============================================================
    local bannerHeader = createLabel(panel, "Loot Banner", "TOPLEFT", panel, "TOPLEFT", 12, 0)
    bannerHeader:SetFontObject(GameFontHighlightLarge)
    bannerHeader:SetTextColor(1, 0.82, 0)
    local bannerDivider = panel:CreateTexture(nil, "ARTWORK")
    bannerDivider:SetTexture("Interface\\Buttons\\WHITE8x8")
    bannerDivider:SetVertexColor(0.5, 0.4, 0.1, 0.6)
    bannerDivider:SetHeight(1)
    bannerDivider:SetPoint("TOPLEFT", bannerHeader, "BOTTOMLEFT", 0, -4)
    bannerDivider:SetPoint("RIGHT", panel, "RIGHT", -40, 0)

    local bannerMinimalCB = createOptionsCheckbox(panel, "Minimalist look (per-card badge, no banner chrome)")
    bannerMinimalCB:SetChecked(opt.bannerMinimal and true or false)
    bannerMinimalCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).bannerMinimal = selfCB:GetChecked() and true or false
    end)

    local bannerInstantCB = createOptionsCheckbox(panel, "Snappy animations (skip the intro flourish and fades)")
    bannerInstantCB:SetChecked(opt.bannerInstant and true or false)
    bannerInstantCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).bannerInstant = selfCB:GetChecked() and true or false
    end)

    local bannerMLSideCB = createOptionsCheckbox(panel, "Loot master roll controls on the left of the card")
    bannerMLSideCB:SetChecked((opt.bannerMLSide or "RIGHT") == "LEFT")
    bannerMLSideCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).bannerMLSide = selfCB:GetChecked() and "LEFT" or "RIGHT"
    end)

    local bannerLockCB = createOptionsCheckbox(panel, "Lock banner position (disable dragging)")
    bannerLockCB:SetChecked(opt.bannerLocked and true or false)
    bannerLockCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).bannerLocked = selfCB:GetChecked() and true or false
        if addon.SetLootBannerAnchorShown then addon:SetLootBannerAnchorShown(true) end   -- refresh hint/drag
    end)

    local resetPosBtn = createButton(panel, "Reset position", 110, 22)
    resetPosBtn:SetScript("OnClick", function()
        if addon.ResetLootBannerPosition then addon:ResetLootBannerPosition() end
        addon:Print("Loot banner position reset to the default (top center).")
    end)

    -- ============================================================
    -- Final layout pass: positions widgets in the user-facing order
    -- regardless of the creation order above. Anchor chain (top -> bottom):
    --   Options title (already anchored to panel)
    --   autoCloseCB
    --   explanationTipsCB
    --   hideUnusableCB             (Hide rolls my class can't use)
    --   hideUnrolledWinsCB         (Don't show winners for loot I passed on or filtered out)
    --   anchorLabel + anchorDrop   (Roll result tooltip docking)
    --   minimapCB
    --   whitelistCB ... whitelistBox
    --   blacklistCB ... blacklistBox
    --   lmHeader + lmDivider       (Loot Master Options)
    --   rollDurLabel + batchLabel + autoRollCB + autoSkipCB + deerLabel
    -- The LM-section widgets keep their internal anchor chain; only the
    -- top-level lmHeader anchor moves so the whole block lands at the bottom.
    -- ============================================================
    explanationTipsCB:ClearAllPoints()
    explanationTipsCB:SetPoint("TOPLEFT", autoCloseCB, "BOTTOMLEFT", 0, -20)

    hideUnusableCB:ClearAllPoints()
    hideUnusableCB:SetPoint("TOPLEFT", explanationTipsCB, "BOTTOMLEFT", 0, -20)

    hideUnrolledWinsCB:ClearAllPoints()
    hideUnrolledWinsCB:SetPoint("TOPLEFT", hideUnusableCB, "BOTTOMLEFT", 0, -20)

    anchorLabel:ClearAllPoints()
    anchorLabel:SetPoint("TOPLEFT", hideUnrolledWinsCB, "BOTTOMLEFT", 0, -22)

    minimapCB:ClearAllPoints()
    minimapCB:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 0, -22)

    -- Loot Banner section between the display options and the filter lists
    bannerHeader:ClearAllPoints()
    bannerHeader:SetPoint("TOPLEFT", minimapCB, "BOTTOMLEFT", 0, -24)
    bannerMinimalCB:SetPoint("TOPLEFT", bannerDivider, "BOTTOMLEFT", 0, -12)
    bannerInstantCB:SetPoint("TOPLEFT", bannerMinimalCB, "BOTTOMLEFT", 0, -8)
    bannerMLSideCB:SetPoint("TOPLEFT", bannerInstantCB, "BOTTOMLEFT", 0, -8)
    bannerLockCB:SetPoint("TOPLEFT", bannerMLSideCB, "BOTTOMLEFT", 0, -8)
    resetPosBtn:SetPoint("LEFT", bannerLockCB.label or bannerLockCB, "RIGHT", 16, 0)

    whitelistCB:ClearAllPoints()
    whitelistCB:SetPoint("TOPLEFT", bannerLockCB, "BOTTOMLEFT", 0, -22)

    lmHeader:ClearAllPoints()
    lmHeader:SetPoint("TOP", blacklistBox, "BOTTOM", 0, -28)
    lmHeader:SetPoint("LEFT", panel, "LEFT", 12, 0)

    panel.autoCloseCB = autoCloseCB
    panel.autoCloseSeconds = autoCloseSeconds
    panel.rollDurBox = rollDurBox
    panel.rollBatchBox = batchBox
    panel.autoRollCB = autoRollCB
    panel.autoStartCB = autoStartCB
    panel.autoSkipCB = autoSkipCB
    panel.deerEditBox = deerBox
    panel.whitelistCB = whitelistCB
    panel.whitelistBox = whitelistBox
    panel.blacklistCB = blacklistCB
    panel.blacklistBox = blacklistBox
    panel.minimapCB = minimapCB
    panel.hideUnusableCB = hideUnusableCB
    panel.anchorDrop = anchorDrop
    panel.bannerMinimalCB = bannerMinimalCB
    panel.bannerInstantCB = bannerInstantCB
    panel.bannerMLSideCB = bannerMLSideCB
    panel.bannerLockCB = bannerLockCB
end

-- Re-sync the options-tab widgets from db state. Called from the slash-command handlers so a
-- toggle made on the command line is reflected in the open Options tab without a reload.
function addon:RefreshOptionsTab()
    local inner = self.ui and self.ui.optionsPanel
    if not inner then return end
    local opt = (self.db and self.db.options) or {}
    if inner.autoRollCB then
        inner.autoRollCB:SetChecked(self.db.autoRoll == true)
    end
    if inner.autoStartCB then
        inner.autoStartCB:SetChecked(opt.autoStartRoll and true or false)
    end
    if inner.autoSkipCB then
        inner.autoSkipCB:SetChecked(opt.autoSkipRoll and true or false)
    end
    if inner.deerEditBox and inner.deerEditBox.editBox then
        inner.deerEditBox.editBox:SetText(self.db.deer or "")
    end
end
