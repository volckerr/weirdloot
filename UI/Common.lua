local addon = WeirdLoot
local UI = addon.UI

local createLabel = UI.createLabel
local createButton = UI.createButton
local createMultilineEditScroll = UI.createMultilineEditScroll
local elevateInteractiveFrame = UI.elevateInteractiveFrame
local getOptions = UI.getOptions

-- Shared builder for the Options tab's whitelist/blacklist preset managers. The two are identical apart
-- from the list they read/write, so everything is derived from `kind` ("whitelist"/"blacklist"): the
-- dropdown frame name, the Save/Delete popup ids, the GetXPresets getter, the saved option fields
-- (xText / xPresetName), and the addon:RefreshXPresetDropdown method. `anchorCB` is the checkbox the
-- "Preset:" label sits under; opts.note (optional) inserts a curated-presets caption between the dropdown
-- and the edit box. Returns the multiline edit box so the caller can anchor following widgets to it.
function UI.createPresetManager(panel, kind, anchorCB, opts)
    opts = opts or {}
    local cap          = kind:sub(1, 1):upper() .. kind:sub(2)   -- "Whitelist" / "Blacklist"
    local UPPER        = kind:upper()
    local dropdownName = "WeirdLoot" .. cap .. "PresetDropdown"
    local textField    = kind .. "Text"
    local nameField    = kind .. "PresetName"
    local function getPresets() return addon["Get" .. cap .. "Presets"](addon) end

    local presetLabel = createLabel(panel, "Preset:", "TOPLEFT", anchorCB, "BOTTOMLEFT", 4, -10)
    local presetDropdown = CreateFrame("Frame", dropdownName, panel, "UIDropDownMenuTemplate")
    elevateInteractiveFrame(presetDropdown, panel, 10)
    presetDropdown:SetPoint("LEFT", presetLabel, "RIGHT", -4, -2)
    UIDropDownMenu_SetWidth(presetDropdown, 160)
    UIDropDownMenu_JustifyText(presetDropdown, "LEFT")
    if UIDropDownMenu_EnableDropDown then
        UIDropDownMenu_EnableDropDown(presetDropdown)
    end
    local ddButton = _G[dropdownName .. "Button"]
    if ddButton then
        ddButton:SetFrameLevel((presetDropdown:GetFrameLevel() or 0) + 2)
        ddButton:Enable()
    end

    local saveBtn = createButton(panel, "Save as...", 80, 22)
    saveBtn:SetPoint("LEFT", presetDropdown, "RIGHT", 4, 2)
    saveBtn:SetScript("OnClick", function()
        StaticPopup_Show("WEIRDLOOT_SAVE_" .. UPPER .. "_PRESET")
    end)

    local deleteBtn = createButton(panel, "Delete", 60, 22)
    deleteBtn:SetPoint("LEFT", saveBtn, "RIGHT", 4, 0)
    deleteBtn:Disable()

    -- The edit box hangs under the dropdown, or under the optional curated note when one is present.
    local boxAnchor, boxX, boxY = presetDropdown, 16, -2
    if opts.note then
        local note = createLabel(panel, opts.note, "TOPLEFT", presetDropdown, "BOTTOMLEFT", 16, -6)
        note:SetWidth(560)
        note:SetJustifyH("LEFT")
        note:SetTextColor(0.85, 0.85, 0.85)
        boxAnchor, boxX, boxY = note, 0, -6
    end

    local box = createMultilineEditScroll(panel, 420, 110)
    box:SetPoint("TOPLEFT", boxAnchor, "BOTTOMLEFT", boxX, boxY)
    box.editBox:SetText(getOptions(addon)[textField] or "")

    -- Collapsible editor (opts.expand): idle, the list shows a one-line preview and the tall edit box
    -- is hidden; clicking the preview blooms the box to opts.expand size, raised over its neighbours on
    -- an opaque backing, and it collapses when the box loses focus. Keeps the Options tab compact.
    local updatePreview, collapse
    if opts.expand then
        local ex = opts.expand
        local preview = CreateFrame("Button", nil, panel)
        elevateInteractiveFrame(preview, panel, 6)
        preview:SetWidth(420)
        preview:SetHeight(20)
        preview:SetPoint("TOPLEFT", boxAnchor, "BOTTOMLEFT", boxX, boxY)
        preview:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 8,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        preview:SetBackdropColor(0, 0, 0, 0.35)
        preview:SetBackdropBorderColor(0.42, 0.34, 0.18, 0.8)
        local previewText = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        previewText:SetPoint("LEFT", preview, "LEFT", 8, 0)
        previewText:SetPoint("RIGHT", preview, "RIGHT", -8, 0)
        previewText:SetJustifyH("LEFT")

        updatePreview = function()
            local text = getOptions(addon)[textField] or ""
            local shown, n = {}, 0
            for line in text:gmatch("[^\r\n]+") do
                local t = line:gsub("^%s*(.-)%s*$", "%1")
                if t ~= "" then n = n + 1; if #shown < 3 then shown[#shown + 1] = t end end
            end
            if n == 0 then
                previewText:SetText("|cff8a8168(empty) - click to add items|r")
            else
                previewText:SetText(("|cffddd3c0%s%s|r  |cff8a8168%d item%s, click to edit|r"):format(
                    table.concat(shown, ", "), n > #shown and "..." or "", n, n == 1 and "" or "s"))
            end
        end

        collapse = function()
            box:Hide()
            preview:Show()
        end
        local function expand()
            preview:Hide()
            box:ClearAllPoints()
            box:SetPoint(ex.point or "TOPLEFT", ex.anchor or panel, ex.relPoint or "TOPLEFT", ex.x or 0, ex.y or 0)
            box:SetSize(ex.width, ex.height)
            box.editBox:SetWidth(ex.width - 36)
            box.editBox:SetHeight(ex.height - 12)
            local lvl = (panel:GetFrameLevel() or 0) + 40   -- above the sibling controls it covers
            box:SetFrameLevel(lvl)
            box.scroll:SetFrameLevel(lvl + 1)
            box.editBox:SetFrameLevel(lvl + 2)
            box:SetBackdropColor(0.05, 0.04, 0.02, 1)       -- opaque so neighbours do not bleed through
            box:Show()
            box.editBox:SetFocus()
        end

        preview:SetScript("OnClick", expand)
        box:Hide()          -- start collapsed
        updatePreview()
        box.preview = preview
    end

    box.editBox:SetScript("OnEditFocusLost", function(selfBox)
        addon:SetItemFilterText(kind, selfBox:GetText())
        if updatePreview then updatePreview() end
        if collapse then collapse() end
    end)

    -- Show a preset name in the dropdown and set the delete button for it WITHOUT touching the items;
    -- used both for a live selection and to restore the remembered name on load.
    local function showSelectedPreset(name)
        if not name or name == "" or name == "<none>" then
            UIDropDownMenu_SetText(presetDropdown, "<none>")
            deleteBtn.currentPresetName = nil
            deleteBtn:Disable()
            return
        end
        local builtin = true
        for _, p in ipairs(getPresets()) do
            if p.name == name then builtin = p.builtin; break end
        end
        UIDropDownMenu_SetText(presetDropdown, name)
        deleteBtn.currentPresetName = name
        deleteBtn.currentPresetBuiltin = builtin
        if builtin then deleteBtn:Disable() else deleteBtn:Enable() end
    end

    local function applyPreset(preset)
        if not preset then
            showSelectedPreset(nil)
            getOptions(addon)[nameField] = nil
            if updatePreview then updatePreview() end
            return
        end
        box.editBox:SetText(preset.text or "")
        addon:SetItemFilterText(kind, preset.text)
        -- Remember the chosen name across reloads; never re-apply its items on load (the saved text is
        -- authoritative and may have been edited since). The name is purely a "what I last picked" label.
        local chosen = preset.isNone and nil or preset.name
        getOptions(addon)[nameField] = chosen
        showSelectedPreset(chosen)
        if updatePreview then updatePreview() end
    end

    local function initDropdown()
        local noneInfo = UIDropDownMenu_CreateInfo()
        noneInfo.text = "<none>"
        noneInfo.value = ""
        noneInfo.func = function() applyPreset({ name = "<none>", text = "", builtin = true, isNone = true }) end
        UIDropDownMenu_AddButton(noneInfo)
        for _, preset in ipairs(getPresets()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = preset.builtin and preset.name or (preset.name .. " (custom)")
            info.value = preset.name
            info.func = function() applyPreset(preset) end
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(presetDropdown, initDropdown)
    showSelectedPreset(getOptions(addon)[nameField])

    deleteBtn:SetScript("OnClick", function()
        local name = deleteBtn.currentPresetName
        if not name or deleteBtn.currentPresetBuiltin then return end
        local dialog = StaticPopup_Show("WEIRDLOOT_DELETE_" .. UPPER .. "_PRESET", name)
        if dialog then dialog.data = name end
    end)

    addon["Refresh" .. cap .. "PresetDropdown"] = function(self, selectName)
        UIDropDownMenu_Initialize(presetDropdown, initDropdown)
        if selectName then
            for _, preset in ipairs(getPresets()) do
                if preset.name == selectName then
                    applyPreset(preset)
                    return
                end
            end
        end
        applyPreset(nil)
    end

    return box
end
