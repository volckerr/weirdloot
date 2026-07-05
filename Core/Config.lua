local addon = WeirdLoot
local util = addon.util

local configClassAliases = {
    ["death knight"] = "death knight",
    deathknight = "death knight",
    dk = "death knight",
    druid = "druid",
    hunter = "hunter",
    mage = "mage",
    paladin = "paladin",
    priest = "priest",
    rogue = "rogue",
    shaman = "shaman",
    warlock = "warlock",
    warrior = "warrior",
}

local orderedClassNames = {
    "death knight",
    "paladin",
    "priest",
    "warlock",
    "warrior",
    "hunter",
    "shaman",
    "druid",
    "rogue",
    "mage",
}

-- addon.defaultItemInfo (the per-item note/role/allowed-class lookup table) lives in ItemInfo.lua,
-- which is now wired into the .toc load order. Config reads it via self.defaultItemInfo; do not
-- re-declare it here -- there used to be a duplicate copy in this file, and it caused confusion
-- about which copy was authoritative (whichever loaded second won). ItemInfo.lua is the one
-- source of truth for the data; this file owns the parsing/normalization logic over it.


function addon:InitializeConfig()
    self.config = self.db.config
    self:NormalizeAllConfig()
end

function addon:NormalizeClassName(value)
    local normalized = util:NormalizeKey(value)
    return configClassAliases[normalized] or normalized
end

function addon:NormalizeStatus(value)
    local normalized = util:NormalizeKey(value)
    if normalized == "alt" or normalized == "designated alt" then
        normalized = "designatedalt"
    end
    if normalized ~= "main" and normalized ~= "designatedalt" then
        normalized = "nil"
    end
    return normalized
end

function addon:ParseClassSpecToken(token)
    token = util:NormalizeKey(token)
    if token == "" or token == "rest" then
        return {
            isRest = true,
            raw = "rest",
        }
    end

    local className
    local specName = ""

    for _, candidateClass in ipairs(orderedClassNames) do
        local prefix = candidateClass .. " "
        local suffix = " " .. candidateClass

        if token == candidateClass then
            className = candidateClass
            specName = ""
            break
        elseif string.sub(token, 1, string.len(prefix)) == prefix then
            className = candidateClass
            specName = string.sub(token, string.len(prefix) + 1)
            break
        elseif string.sub(token, -string.len(suffix)) == suffix then
            className = candidateClass
            specName = string.sub(token, 1, string.len(token) - string.len(suffix))
            break
        end
    end

    specName = util:NormalizeKey(specName)

    return {
        raw = token,
        className = className,
        specName = specName,
        matchKeys = {
            util:NormalizeKey((className or "") .. " " .. (specName or "")),
            util:NormalizeKey((specName or "") .. " " .. (className or "")),
        },
    }
end

function addon:ParseRosterImport(text)
    local rosterEntries = {}
    for _, line in ipairs(util:SplitLines(text)) do
        local parts = util:Split(line, ",")
        local rawName = string.trim(parts[1] or "")
        local descriptor = string.trim(parts[2] or "")
        local status = self:NormalizeStatus(parts[3] or "")
        if rawName ~= "" then
            local parsed = self:ParseClassSpecToken(descriptor)
            rosterEntries[#rosterEntries + 1] = {
                name = rawName,
                className = parsed.className,
                specName = parsed.specName,
                status = status,
                descriptor = descriptor,
            }
        end
    end
    return rosterEntries
end

function addon:NormalizeRosterEntries(entries)
    local normalizedEntries = {}
    local seen = {}

    for _, entry in ipairs(entries or {}) do
        local name = string.trim(entry.name or "")
        if name ~= "" then
            local key = util:NormalizeKey(name)
            if not seen[key] then
                local className = self:NormalizeClassName(entry.className or "")
                local specName = util:NormalizeKey(entry.specName or "")
                local status = self:NormalizeStatus(entry.status or "")
                normalizedEntries[#normalizedEntries + 1] = {
                    name = name,
                    className = className,
                    specName = specName,
                    status = status,
                    descriptor = util:NormalizeKey((className or "") .. " " .. (specName or "")),
                }
                seen[key] = true
            end
        end
    end

    table.sort(normalizedEntries, function(left, right)
        return util:NormalizeKey(left.name) < util:NormalizeKey(right.name)
    end)

    return normalizedEntries
end

function addon:BuildRosterMap(entries)
    local roster = {}
    for _, entry in ipairs(entries or {}) do
        roster[util:NormalizeKey(entry.name)] = {
            name = entry.name,
            className = entry.className,
            specName = entry.specName,
            status = entry.status,
            descriptor = entry.descriptor or util:NormalizeKey((entry.className or "") .. " " .. (entry.specName or "")),
        }
    end
    return roster
end

function addon:SerializeRosterEntries(entries)
    local lines = {}
    for _, entry in ipairs(entries or {}) do
        local status = entry.status == "designatedalt" and "designatedAlt" or (entry.status == "main" and "main" or "unknown")
        local descriptor = string.trim((entry.className or "") .. " " .. (entry.specName or ""))
        lines[#lines + 1] = string.format("%s, %s, %s", entry.name or "", descriptor, status)
    end
    return table.concat(lines, "\n")
end

function addon:ParseTieredRuleText(text, parser)
    local rules = {}

    for _, line in ipairs(util:SplitLines(text)) do
        local parts = util:Split(line, ",")
        local itemName = string.trim(parts[1] or "")
        local ruleText = string.trim(parts[2] or "")
        if itemName ~= "" and ruleText ~= "" then
            local tiers = {}

            for tierIndex, tierText in ipairs(util:Split(ruleText, ">")) do
                local entries = {}
                tierText = string.trim(tierText)
                for _, token in ipairs(util:Split(tierText, "/")) do
                    local parsed = parser(self, token)
                    if parsed then
                        if parsed.isRest then
                            table.insert(entries, {
                                raw = "rest",
                                isRest = true,
                            })
                        else
                            table.insert(entries, parsed)
                        end
                    end
                end

                if #entries > 0 then
                    tiers[#tiers + 1] = {
                        index = tierIndex,
                        raw = tierText,
                        entries = entries,
                    }
                end
            end

            local key = util:NormalizeKey(itemName)
            rules[key] = {
                itemName = itemName,
                tiers = tiers,
                raw = ruleText,
                key = key,
            }
        end
    end

    return rules
end

function addon:ParseNamedToken(token)
    token = util:NormalizeKey(token)
    if token == "" then
        return nil
    end
    if token == "lc" or token == "loot council" then
        return {
            isLootCouncil = true,
            raw = "LC",
        }
    end
    if token == "rest" then
        return {
            isRest = true,
            raw = "rest",
        }
    end
    return {
        raw = token,
        playerKey = util:NormalizeKey(token),
    }
end

function addon:NormalizeAllConfig()
    local rosterEntries = self.config.rosterEntries

    -- The saved entries are the guest/override layer beneath the guild-derived roster (see
    -- GetRosterProfile); there is no shipped default to fall back to. If they're missing/empty
    -- (fresh install, or a roster nuked by hand), reparse the saved import text; an empty
    -- roster is a valid state (guild data carries the raiders).
    if type(rosterEntries) ~= "table" or #rosterEntries == 0 then
        local rosterImportText = self.config.rosterImportText or ""
        if rosterImportText ~= "" then
            rosterEntries = self:ParseRosterImport(rosterImportText)
        end
        if type(rosterEntries) ~= "table" then
            rosterEntries = {}
        end
    end

    self.config.rosterEntries = self:NormalizeRosterEntries(rosterEntries)
    self.config.roster = self:BuildRosterMap(self.config.rosterEntries)
    self.config.rosterImportText = self:SerializeRosterEntries(self.config.rosterEntries)
    self.config.lootRules = self:ParseTieredRuleText(self.config.lootPriorityText or "", self.ParseClassSpecToken)
    self.config.namedRules = self:ParseTieredRuleText(self.config.namedItemsText or "", self.ParseNamedToken)
end

function addon:GetItemInfoEntry(itemName)
    local key = util:NormalizeKey(itemName or "")
    if key == "" then
        return nil
    end

    return (self.defaultItemInfo or {})[key]
end

function addon:GetItemInfoText(itemName)
    local entry = self:GetItemInfoEntry(itemName)
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

function addon:GetItemAllowedClasses(itemName)
    local entry = self:GetItemInfoEntry(itemName)
    if not entry then
        return nil
    end

    local note = string.trim(entry.note or "")
    if note == "" then
        return nil
    end

    local allowed = {}
    for _, token in ipairs(util:Split(note, ",")) do
        local normalized = util:NormalizeKey(token)
        local className = configClassAliases[normalized]
        if className then
            allowed[className] = true
        end
    end

    return next(allowed) and allowed or nil
end

function addon:IsClassAllowedForItem(itemId, itemName, className)
    -- Tier set tokens: the allowed classes come from the authoritative item-id table, not the
    -- per-name ItemInfo note. Non-token items still fall back to the note.
    local tokenSet = itemId and util:TierTokenClassSet(itemId)
    if tokenSet then
        local token = util:ClassNameToToken(className)
        if not token then return true end          -- unknown class: do not gate
        return tokenSet[token] == true
    end

    local allowed = self:GetItemAllowedClasses(itemName)
    if not allowed then
        return true
    end

    local normalizedClass = configClassAliases[util:NormalizeKey(className or "")]
    if not normalizedClass then
        return true
    end

    return allowed[normalizedClass] == true
end

function addon:IsPlayerAllowedForItem(itemId, itemName, playerName)
    if not itemId and (not itemName or itemName == "") then
        return true
    end

    local playerKey = util:NormalizeKey(playerName or "")
    local localPlayerKey = util:NormalizeKey(util:GetPlayerName("player") or "")
    local className

    if playerKey ~= "" and playerKey == localPlayerKey then
        local localizedClass = select(2, UnitClass("player"))
        if localizedClass and localizedClass ~= "" then
            className = string.gsub(string.lower(localizedClass), "deathknight", "death knight")
        end
    end

    if not className or className == "" then
        local attendee = self.GetAttendee and self:GetAttendee(playerName)
        local rosterProfile = self.GetRosterProfile and self:GetRosterProfile(playerName)
        className = (attendee and attendee.className) or (rosterProfile and rosterProfile.className) or ""
    end

    return self:IsClassAllowedForItem(itemId, itemName, className)
end

function addon:SaveImports(rosterText, lootText, namedText)
    if rosterText ~= nil then
        self.config.rosterEntries = self:ParseRosterImport(rosterText or "")
        self.config.rosterImportText = rosterText or ""
    end
    self.config.lootPriorityText = lootText or self.config.lootPriorityText or ""
    self.config.namedItemsText = namedText or self.config.namedItemsText or ""
    self.config.revision = (self.config.revision or 0) + 1
    self:NormalizeAllConfig()
    self:RefreshRoster()
    self:TriggerCallback("CONFIG_UPDATED")
    self:Print("Configuration saved.")
end

function addon:SaveRosterText(rosterText, suppressPrint)
    self.config.rosterEntries = self:ParseRosterImport(rosterText or "")
    self.config.rosterImportText = rosterText or ""
    self.config.revision = (self.config.revision or 0) + 1
    self:NormalizeAllConfig()
    self:RefreshRoster()
    self:TriggerCallback("CONFIG_UPDATED")
    if not suppressPrint then
        self:Print("Roster saved.")
    end
end

-- Add or replace ONE roster entry by name: the guest layer's on-the-fly write. Used by the
-- Raiders tab add flow and the GUEST_UPSERT comm handler, so an edit made by any authorized
-- client converges everywhere without a full-roster broadcast.
function addon:UpsertRosterEntry(entry)
    if type(entry) ~= "table" or (entry.name or "") == "" then
        return false
    end
    local key = util:NormalizeKey(entry.name)
    local entries = self.config.rosterEntries or {}
    local replaced = false
    for index, existing in ipairs(entries) do
        if util:NormalizeKey(existing.name or "") == key then
            entries[index] = entry
            replaced = true
            break
        end
    end
    if not replaced then
        entries[#entries + 1] = entry
    end
    self.config.rosterEntries = entries
    self.config.revision = (self.config.revision or 0) + 1
    self:NormalizeAllConfig()
    self:RefreshRoster()
    self:TriggerCallback("CONFIG_UPDATED")
    return true
end

function addon:SaveNamedItemsText(namedText, suppressPrint)
    self.config.namedItemsText = namedText or ""
    self.config.revision = (self.config.revision or 0) + 1
    self:NormalizeAllConfig()
    self:RefreshRoster()
    self:TriggerCallback("CONFIG_UPDATED")
    if not suppressPrint then
        self:Print("Named items saved.")
    end
end

function addon:GetRosterProfile(playerName)
    if not playerName then
        return nil
    end
    local configured = self.config.roster[util:NormalizeKey(playerName)]

    -- Guild data is authoritative for guild members: rank (plus any officer-note override)
    -- decides status, the note token decides spec. The configured roster stays the source for
    -- guests, and fills in a spec the note doesn't provide yet, so an unpopulated officer note
    -- degrades to the configured spec instead of blanking it. Spec fill only when the classes
    -- agree: a stale configured entry for a rerolled name must not graft a foreign spec.
    local profile
    local guildProfile = self.GetGuildMemberProfile and self:GetGuildMemberProfile(playerName)
    if not guildProfile then
        profile = configured
    elseif guildProfile.specName ~= ""
        or not configured
        or (configured.specName or "") == ""
        or configured.className ~= guildProfile.className then
        profile = guildProfile
    else
        profile = {
            name = guildProfile.name,
            className = guildProfile.className,
            specName = configured.specName,
            status = guildProfile.status,
            rankName = guildProfile.rankName,
            rankIndex = guildProfile.rankIndex,
            online = guildProfile.online,
        }
    end

    -- The on-the-fly override layer beats everything: a Raiders-tab pick must win over a
    -- stale officer note until it is cleared. Per-field, so a status-only override leaves the
    -- note's spec alone. Flags let the tab mark overridden cells.
    local override = self.GetRosterOverride and self:GetRosterOverride(playerName)
    if not override or not profile then
        return profile
    end
    return {
        name = profile.name,
        className = profile.className,
        specName = override.specName or profile.specName,
        status = override.status or profile.status,
        rankName = profile.rankName,
        rankIndex = profile.rankIndex,
        online = profile.online,
        overriddenSpec = override.specName and true or nil,
        overriddenStatus = override.status and true or nil,
    }
end

-- Persistent per-player override layer, written by the Raiders tab dropdowns ("stored for
-- next time": survives reloads in SavedVariables). Used for guild members, whose durable
-- sources (rank, officer note) the clicker may not be able to edit; non-guildies write their
-- guest-layer entry directly instead, since that entry is already wholly ours. Passing both
-- fields empty clears the record. Broadcast is the caller's job (SendRosterOverride).
function addon:SetRosterOverride(playerName, specName, status)
    if not playerName or playerName == "" then
        return false
    end
    local key = util:NormalizeKey(playerName)
    self.config.rosterOverrides = self.config.rosterOverrides or {}
    if (specName or "") == "" and (status or "") == "" then
        self.config.rosterOverrides[key] = nil
    else
        self.config.rosterOverrides[key] = {
            name = playerName,
            specName = (specName or "") ~= "" and util:NormalizeKey(specName) or nil,
            status = (status or "") ~= "" and status or nil,
        }
    end
    self.config.revision = (self.config.revision or 0) + 1
    self:RefreshRoster()
    self:TriggerCallback("CONFIG_UPDATED")
    return true
end

function addon:GetRosterOverride(playerName)
    local overrides = self.config and self.config.rosterOverrides
    return overrides and overrides[util:NormalizeKey(playerName or "")] or nil
end

function addon:GetLootRule(itemName)
    return self.config.lootRules[util:NormalizeKey(itemName or "")]
end

function addon:GetNamedRule(itemName)
    -- Session-scoped LC override wins when present: lets the loot master assign a one-off
    -- priority on-the-fly (named raiders all absent, e.g.) without editing the persistent
    -- named-items list. The override is wiped by ClearSession.
    local override = self.GetSessionLCOverride and self:GetSessionLCOverride(itemName)
    if override then return override end
    return self.config.namedRules[util:NormalizeKey(itemName or "")]
end

function addon:ItemHasPriority(itemName)
    -- "Listed priority" means the item appears in the spec-priority list (lootRules) or the
    -- named-items list (namedRules, incl. a session LC override). BiS is only offered for such
    -- items; a generic drop in neither list has no priority to roll BiS against. Keyed by item
    -- name today; an item-id index is the planned successor.
    if not itemName or itemName == "" then return false end
    return (self:GetLootRule(itemName) or self:GetNamedRule(itemName)) and true or false
end

function addon:GetRosterEntries()
    return self.config.rosterEntries or {}
end
