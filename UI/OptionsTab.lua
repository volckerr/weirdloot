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
    panel:SetHeight(720)   -- two columns + full-width filters; slack lets a bloomed list editor scroll into view
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

    -- Two-column layout: left column = General + Loot Banner (per-raider display), right column =
    -- Loot Master; Loot Filters spans full width below. RCOL_X starts the right column; the divider
    -- right-edge offsets keep each column's rule within its own column.
    local RCOL_X = 476
    local LCOL_DIV_R, FULL_DIV_R = -468, -36   -- divider RIGHT offset from panel RIGHT (left col / full width)

    -- Section header + gold divider, one source so General/Filters/Banner/Master never drift. Caller
    -- positions the header and sets the divider's right edge (columns differ).
    local function makeSectionHeader(text)
        local h = createLabel(panel, text, "TOPLEFT", panel, "TOPLEFT", 0, 0)
        h:SetFontObject(GameFontHighlightLarge)
        h:SetTextColor(1, 0.82, 0)
        local d = panel:CreateTexture(nil, "ARTWORK")
        d:SetTexture("Interface\\Buttons\\WHITE8x8")
        d:SetVertexColor(0.5, 0.4, 0.1, 0.6)
        d:SetHeight(1)
        d:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
        return h, d
    end
    local generalHeader, generalDivider = makeSectionHeader("General")
    local bannerHeader, bannerDivider = makeSectionHeader("Loot Banner")
    local lmHeader, lmDivider = makeSectionHeader("Loot Master")
    local filtersHeader, filtersDivider = makeSectionHeader("Loot Filters")

    -- The white/black list editors bloom to fill this region (raised over their neighbours) on focus.
    local listsRegion = CreateFrame("Frame", nil, panel)
    local LIST_EXPAND = { anchor = listsRegion, point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = 0, width = 880, height = 180 }

    -- Filter warning: rides the Loot Filters header, red, and only appears while a list is actually
    -- enabled (they are mutually exclusive), spelling out what that list hides.
    local filterWarning = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    filterWarning:SetPoint("LEFT", filtersHeader, "RIGHT", 14, 0)
    filterWarning:SetTextColor(1, 0.19, 0.19)
    local function updateFilterWarning()
        local o = getOptions(addon)
        if o.whitelistEnabled then
            filterWarning:SetText("Warning: you will ONLY see loot for items on the White List")
        elseif o.blacklistEnabled then
            filterWarning:SetText("Warning: you will ONLY see loot for items NOT on the Black List")
        else
            filterWarning:SetText("")
        end
    end

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

    -- Loot Master block (right column; lmHeader/lmDivider are created up top). These widgets keep their
    -- own top-down chain rooted at lmDivider, so positioning lmHeader lands the whole block.
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
    local batchLabel = createLabel(panel, "Start Rolls batch size:",
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
    local autoRollCB = createOptionsCheckbox(panel, "Auto-open the Start/Skip popup on new loot")
    autoRollCB:SetPoint("TOPLEFT", batchLabel, "BOTTOMLEFT", 0, -16)
    autoRollCB:SetChecked(self.db.autoRoll == true)

    local autoStartCB = createOptionsCheckbox(panel, "Auto-start rolls when loot lands")
    autoStartCB:SetPoint("TOPLEFT", autoRollCB, "BOTTOMLEFT", 0, -8)
    autoStartCB:SetChecked(opt.autoStartRoll and true or false)

    local autoSkipCB = createOptionsCheckbox(panel, "Auto-skip a live roll on new loot")
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
    local deerLabel = createLabel(panel, "Designated disenchanter:",
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
    local whitelistCB = createOptionsCheckbox(panel, "Enable White List")
    whitelistCB:SetPoint("TOPLEFT", hideUnusableCB, "BOTTOMLEFT", 0, -24)   -- overridden in the final layout pass
    whitelistCB:SetChecked(opt.whitelistEnabled and true or false)
    -- OnClick is wired below via bindExclusiveCheckboxes, once blacklistCB also exists (mutually exclusive).

    local whitelistBox = createPresetManager(panel, "whitelist", whitelistCB, { expand = LIST_EXPAND })

    -- Blacklist
    local blacklistCB = createOptionsCheckbox(panel, "Enable Black List")
    blacklistCB:SetPoint("TOP", whitelistBox, "BOTTOM", 0, -16)
    blacklistCB:SetPoint("LEFT", panel, "LEFT", 12, 0)
    blacklistCB:SetChecked(opt.blacklistEnabled and true or false)

    -- Whitelist and blacklist are mutually exclusive: an "only these" list and an "all but these"
    -- list contradict, so wire the pair as an exclusive group now that both checkboxes exist.
    bindExclusiveCheckboxes({
        { cb = whitelistCB, get = function() return getOptions(addon).whitelistEnabled end,
          set = function(on) getOptions(addon).whitelistEnabled = on end,
          onToggle = function() updateFilterWarning() end },
        { cb = blacklistCB, get = function() return getOptions(addon).blacklistEnabled end,
          set = function(on) getOptions(addon).blacklistEnabled = on end,
          onToggle = function() updateFilterWarning() end },
    })

    local blacklistBox = createPresetManager(panel, "blacklist", blacklistCB, { expand = LIST_EXPAND })

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
    local anchorLabel = createLabel(panel, "Roller preview tooltip docking:", "TOPLEFT", minimapCB, "BOTTOMLEFT", 0, -22)
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

    -- Loot Banner (display) block: the look toggles + position controls. bannerHeader/bannerDivider are
    -- created up top; these widgets are positioned in the final layout pass (left column).
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
    -- Final layout pass: two columns. Left = General + Loot Banner (per-raider display); right = Loot
    -- Master; Loot Filters spans the full width below, its two list editors side by side. Section
    -- headers/dividers are created up top; here each is positioned and its divider right-edge set.
    -- ============================================================
    -- LEFT COLUMN: General
    generalHeader:ClearAllPoints()
    generalHeader:SetPoint("TOPLEFT", titleDivider, "BOTTOMLEFT", 0, -14)
    generalDivider:SetPoint("RIGHT", panel, "RIGHT", LCOL_DIV_R, 0)
    minimapCB:ClearAllPoints()
    minimapCB:SetPoint("TOPLEFT", generalDivider, "BOTTOMLEFT", 0, -12)
    explanationTipsCB:ClearAllPoints()
    explanationTipsCB:SetPoint("TOPLEFT", minimapCB, "BOTTOMLEFT", 0, -8)

    -- LEFT COLUMN: Loot Banner
    bannerHeader:ClearAllPoints()
    bannerHeader:SetPoint("TOPLEFT", explanationTipsCB, "BOTTOMLEFT", 0, -22)
    bannerDivider:SetPoint("RIGHT", panel, "RIGHT", LCOL_DIV_R, 0)
    bannerMinimalCB:ClearAllPoints()
    bannerMinimalCB:SetPoint("TOPLEFT", bannerDivider, "BOTTOMLEFT", 0, -12)
    bannerInstantCB:ClearAllPoints()
    bannerInstantCB:SetPoint("TOPLEFT", bannerMinimalCB, "BOTTOMLEFT", 0, -8)
    autoCloseCB:ClearAllPoints()
    autoCloseCB:SetPoint("TOPLEFT", bannerInstantCB, "BOTTOMLEFT", 0, -8)
    anchorLabel:ClearAllPoints()
    anchorLabel:SetPoint("TOPLEFT", autoCloseCB, "BOTTOMLEFT", 0, -14)
    bannerLockCB:ClearAllPoints()
    bannerLockCB:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 0, -12)
    resetPosBtn:ClearAllPoints()
    resetPosBtn:SetPoint("LEFT", bannerLockCB.label or bannerLockCB, "RIGHT", 16, 0)

    -- RIGHT COLUMN: Loot Master. keepResultCB already roots to lmDivider (its x follows lmHeader);
    -- insert MLside after it, then reroot the roll-mechanics chain onto MLside.
    lmHeader:ClearAllPoints()
    lmHeader:SetPoint("TOPLEFT", generalHeader, "TOPLEFT", RCOL_X - 12, 0)   -- same top as the left column, in the right column
    lmDivider:SetPoint("RIGHT", panel, "RIGHT", FULL_DIV_R, 0)
    bannerMLSideCB:ClearAllPoints()
    bannerMLSideCB:SetPoint("TOPLEFT", keepResultCB, "BOTTOMLEFT", 0, -12)
    rollDurLabel:ClearAllPoints()
    rollDurLabel:SetPoint("TOPLEFT", bannerMLSideCB, "BOTTOMLEFT", 0, -14)

    -- LOOT FILTERS: full width, below the taller (right) column. Nudge the -26 if a column grows.
    -- Full width below the taller (right) column: anchor to its last widget (deerLabel) and pull x back
    -- to the left margin, so the gap tracks the real column height instead of a guessed offset.
    filtersHeader:ClearAllPoints()
    filtersHeader:SetPoint("TOPLEFT", deerLabel, "BOTTOMLEFT", -(RCOL_X - 12), -24)
    filtersDivider:SetPoint("RIGHT", panel, "RIGHT", FULL_DIV_R, 0)

    hideUnusableCB:ClearAllPoints()
    hideUnusableCB:SetPoint("TOPLEFT", filtersDivider, "BOTTOMLEFT", 0, -12)
    hideUnrolledWinsCB:ClearAllPoints()
    hideUnrolledWinsCB:SetPoint("TOPLEFT", hideUnusableCB, "TOPLEFT", RCOL_X - 12, 0)   -- right half, same row

    -- White List (left) and Black List (right), side by side; each editor collapses to one line.
    whitelistCB:ClearAllPoints()
    whitelistCB:SetPoint("TOPLEFT", hideUnusableCB, "BOTTOMLEFT", 0, -16)
    blacklistCB:ClearAllPoints()
    blacklistCB:SetPoint("TOPLEFT", whitelistCB, "TOPLEFT", RCOL_X - 12, 0)   -- right half, same row

    -- The region both editors bloom into (full width, rooted at the collapsed preview row).
    listsRegion:ClearAllPoints()
    listsRegion:SetPoint("TOPLEFT", whitelistCB, "BOTTOMLEFT", 4, -44)
    listsRegion:SetSize(880, 180)

    updateFilterWarning()   -- reflect the saved white/black-list state on open

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
