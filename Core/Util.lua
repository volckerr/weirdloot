local addon = WeirdLoot

addon.util = {}
local util = addon.util

-- Canonical hover text for each roll-choice bracket abbreviation. One source so the live-roll
-- popup and the loot tab spell out the same thing and never drift apart.
-- TODO: these are user-facing English strings; move them into a proper localization module
-- (alongside the other display strings) when one exists, instead of hard-coding them here.
addon.RESPONSE_TOOLTIPS = {
    bis = "Best in Slot",
    ms = "Main Spec Upgrade",
    mu = "Minor Upgrade",
    os = "Off Spec",
    tm = "Transmog",
    pass = "Pass",
}

function string.trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

-- The numeric item id is the canonical loot identity (links/names vary across clients).
-- Parse it out of any item link or itemString.
function util:ItemIdFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("|Hitem:(%d+)") or link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

-- Render display fields from an itemId on demand. The link is force-cached by GetItemInfo;
-- if the client hasn't cached it yet, fields may be nil until a later refresh.
function util:ItemRender(itemId)
    if not itemId then return nil end
    local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
    return name, link or ("item:" .. itemId), icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

function util:Split(value, delimiter)
    local results = {}
    if value == nil or value == "" then
        return results
    end

    delimiter = delimiter or ","
    local startIndex = 1

    while true do
        local foundIndex = string.find(value, delimiter, startIndex, true)
        if not foundIndex then
            table.insert(results, string.sub(value, startIndex))
            break
        end

        table.insert(results, string.sub(value, startIndex, foundIndex - 1))
        startIndex = foundIndex + string.len(delimiter)
    end

    return results
end

function util:SplitLines(value)
    local lines = {}
    value = string.gsub(value or "", "\r\n", "\n")
    value = string.gsub(value, "\r", "\n")

    for line in string.gmatch(value, "([^\n]+)") do
        line = string.trim(line)
        if line ~= "" then
            table.insert(lines, line)
        end
    end

    return lines
end

function util:NormalizeKey(value)
    value = string.lower(string.trim(value or ""))
    value = string.gsub(value, "%s+", " ")
    return value
end

function util:CloneTable(source)
    if type(source) ~= "table" then
        return source
    end

    local copy = {}
    for key, value in pairs(source) do
        copy[key] = self:CloneTable(value)
    end
    return copy
end

-- Recursively fill missing keys in `target` from `defaults` (deep for nested tables), leaving any
-- existing value untouched. Used to seed SavedVariables defaults on login.
function util:EnsureDefaults(target, defaults)
    if type(target) ~= "table" then
        target = {}
    end
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = self:EnsureDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

function util:Contains(list, expected)
    if type(list) ~= "table" then
        return false
    end

    for _, value in ipairs(list) do
        if value == expected then
            return true
        end
    end

    return false
end

function util:TableCount(map)
    local count = 0
    if type(map) ~= "table" then
        return count
    end

    for _ in pairs(map) do
        count = count + 1
    end
    return count
end

function util:SortByName(list, field)
    table.sort(list, function(left, right)
        local leftName = field and left[field] or left.name or left
        local rightName = field and right[field] or right.name or right
        leftName = leftName or ""
        rightName = rightName or ""
        return string.lower(leftName) < string.lower(rightName)
    end)
end

function util:EncodeField(value)
    value = tostring(value or "")
    value = string.gsub(value, "%%", "%%25")
    value = string.gsub(value, "|", "%%7C")
    value = string.gsub(value, "\n", "%%0A")
    value = string.gsub(value, ":", "%%3A")
    return value
end

function util:DecodeField(value)
    value = tostring(value or "")
    value = string.gsub(value, "%%3A", ":")
    value = string.gsub(value, "%%0A", "\n")
    value = string.gsub(value, "%%7C", "|")
    value = string.gsub(value, "%%25", "%%")
    return value
end

function util:JoinEncoded(values)
    local encoded = {}
    for index, value in ipairs(values or {}) do
        encoded[index] = self:EncodeField(value)
    end
    return table.concat(encoded, "|")
end

function util:SplitEncoded(payload)
    local fields = self:Split(payload, "|")
    for index, value in ipairs(fields) do
        fields[index] = self:DecodeField(value)
    end
    return fields
end

function util:PlayerDisplayStatus(status)
    local normalized = self:NormalizeKey(status)
    if normalized == "main" then
        return "Main"
    elseif normalized == "designatedalt" then
        return "Designated Alt"
    elseif normalized == "nil" then
        -- The bottom tier is a KNOWN placement (Alt rank or an explicit ,alt note), distinct
        -- from "unknown" = a rank the mapping doesn't cover with no note, or an off-roster guest.
        return "Alt"
    end

    return "Unknown"
end

function util:TitleCaseWords(value)
    local normalized = string.trim(value or "")
    if normalized == "" then
        return ""
    end

    return string.gsub(normalized, "(%a)([%w']*)", function(first, rest)
        return string.upper(first) .. string.lower(rest)
    end)
end

function util:StatusRank(status)
    local normalized = self:NormalizeKey(status)
    -- "unknown" (unmapped rank with no note, or an off-roster guest) competes as a main:
    -- nobody should lose loot to a missing officer note. It still DISPLAYS as Unknown so
    -- leadership can spot who needs role/spec info assigned.
    if normalized == "main" or normalized == "unknown" then
        return 3
    elseif normalized == "designatedalt" then
        return 2
    end

    return 1
end

function util:GetPlayerName(unit)
    local name = UnitName(unit)
    if not name then
        return nil
    end

    return util:StripRealm(name)
end

-- Drop the "-RealmName" suffix from a player-realm string ("Bob-Moonrunner" -> "Bob"). Pure:
-- does not call UnitName. Use when you already have the name in hand (e.g. from
-- GetRaidRosterInfo / UnitName / chat-message sender) and just want the short form.
--
-- The regex "[^-]*" matches zero-or-more non-dash chars, so it returns the empty string for
-- edge inputs like "-Moonrunner" or "" (where there's no short form to keep) instead of the
-- original input. Callers normalize downstream via NormalizeKey(name or ""), which treats ""
-- identically to nil, so this is a no-op for real input but more honest about intent.
function util:StripRealm(name)
    if type(name) ~= "string" then return nil end
    return string.match(name, "^[^-]*")
end

function util:GetUnitTokenByPlayerName(playerName)
    local expected = self:NormalizeKey(playerName or "")
    if expected == "" then
        return nil
    end

    if self:NormalizeKey(self:GetPlayerName("player") or "") == expected then
        return "player"
    end

    local raidCount = GetNumRaidMembers() or 0
    for index = 1, raidCount do
        local unit = "raid" .. index
        if self:NormalizeKey(self:GetPlayerName(unit) or "") == expected then
            return unit
        end
    end

    local partyCount = GetNumPartyMembers() or 0
    for index = 1, partyCount do
        local unit = "party" .. index
        if self:NormalizeKey(self:GetPlayerName(unit) or "") == expected then
            return unit
        end
    end

    if self:NormalizeKey(self:GetPlayerName("target") or "") == expected then
        return "target"
    end

    return nil
end

function util:GetClassColorCode(className)
    local normalized = self:NormalizeKey(className)
    local tokenByName = {
        ["death knight"] = "DEATHKNIGHT",
        druid = "DRUID",
        hunter = "HUNTER",
        mage = "MAGE",
        paladin = "PALADIN",
        priest = "PRIEST",
        rogue = "ROGUE",
        shaman = "SHAMAN",
        warlock = "WARLOCK",
        warrior = "WARRIOR",
    }

    local classToken = tokenByName[normalized]
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local color = classToken and colors and colors[classToken]
    if not color then
        return "|cffffffff"
    end

    return string.format("|cff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
end

-- "You" rendering. Any name that resolves to the local player is shown as a special-colored
-- "You" instead of the literal character name, so you instantly spot your own line in roll
-- tooltips, the result popup, and Loot Results. Export text deliberately keeps literal names
-- (it is shared with others, for whom "You" is meaningless).
local YOU_COLOR = "|cff00ffcc"   -- aqua: distinct from every class color

function util:IsSelfName(name)
    if not name or name == "" then
        return false
    end
    return self:NormalizeKey(name) == self:NormalizeKey(self:GetPlayerName("player") or "")
end

-- Color-coded display string for a player name: special "You" for the local player, otherwise the
-- name in its class color. className is only used for the non-self color.
function util:ColorPlayerName(name, className)
    if self:IsSelfName(name) then
        return YOU_COLOR .. "You|r"
    end
    return (self:GetClassColorCode(className) or "|cffffffff") .. tostring(name or "Unknown") .. "|r"
end

function util:ColorPlayerText(name, className, text)
    if self:IsSelfName(name) then
        return YOU_COLOR .. tostring(text or "You") .. "|r"
    end
    return tostring(text or self:ColorPlayerName(name, className))
end

-- Tier set tokens (turned in for set pieces) are class-restricted by the server's AllowableClass
-- mask, captured here as item id -> the classes that can use it, ordered by tier. Sourced from
-- item_template; 10- and 25-man are distinct ids, so each tier contributes several. The group
-- class-sets: Conqueror/Protector/Vanquisher are the WotLK + TBC-T6 scheme (TBC-T6 Vanquisher
-- predates Death Knights, hence no DK); Champion/Defender/Hero are TBC T4-T5.
-- Coverage: TBC T4-T6, WotLK Naxxramas (T7), Ulduar (T8). NOT yet covered: WotLK ToC (T9) and ICC
-- (T10) -- the ICC "X's Mark of Sanctification" tokens (ids ~52000) are absent from our item_template
-- dump, so they need a complete source before they can be added.
local CONQUEROR      = { PALADIN = true, PRIEST = true, WARLOCK = true }
local PROTECTOR      = { WARRIOR = true, HUNTER = true, SHAMAN = true }
local VANQUISHER     = { ROGUE = true, DEATHKNIGHT = true, MAGE = true, DRUID = true }
local VANQUISHER_TBC = { ROGUE = true, MAGE = true, DRUID = true }
local DEFENDER       = { WARRIOR = true, PRIEST = true, DRUID = true }
local CHAMPION       = { PALADIN = true, ROGUE = true, SHAMAN = true }
local HERO           = { HUNTER = true, MAGE = true, WARLOCK = true }

local tierTokenClasses = {}
local function token(classSet, ...)
    for _, id in ipairs({ ... }) do tierTokenClasses[id] = classSet end
end

-- ===== TBC Tier 4: Karazhan / Gruul / Magtheridon =====
token(CHAMPION,       -- Paladin, Rogue, Shaman
    29754, 29757, 29760, 29763, 29766)
token(DEFENDER,       -- Warrior, Priest, Druid
    29753, 29758, 29761, 29764, 29767)
token(HERO,           -- Hunter, Mage, Warlock
    29755, 29756, 29759, 29762, 29765)

-- ===== TBC Tier 5: Serpentshrine Cavern / Tempest Keep =====
token(CHAMPION,       -- Paladin, Rogue, Shaman
    30236, 30239, 30242, 30245, 30248)
token(DEFENDER,       -- Warrior, Priest, Druid
    30237, 30240, 30243, 30246, 30249)
token(HERO,           -- Hunter, Mage, Warlock
    30238, 30241, 30244, 30247, 30250)

-- ===== TBC Tier 6: Hyjal / Black Temple / Sunwell =====
token(CONQUEROR,      -- Paladin, Priest, Warlock
    31089, 31092, 31097, 31098, 31101, 34848, 34853, 34856)
token(PROTECTOR,      -- Warrior, Hunter, Shaman
    31091, 31094, 31095, 31100, 31103, 34851, 34854, 34857)
token(VANQUISHER_TBC, -- Rogue, Mage, Druid
    31090, 31093, 31096, 31099, 31102, 34852, 34855, 34858)

-- ===== WotLK Tier 7: Naxxramas / Obsidian Sanctum =====
token(CONQUEROR,      -- Paladin, Priest, Warlock
    40610, 40613, 40616, 40619, 40622,   -- 10-man
    40625, 40628, 40631, 40634, 40637)   -- 25-man
token(PROTECTOR,      -- Warrior, Hunter, Shaman
    40611, 40614, 40617, 40620, 40623,   -- 10-man
    40626, 40629, 40632, 40635, 40638)   -- 25-man
token(VANQUISHER,     -- Rogue, Death Knight, Mage, Druid
    40612, 40615, 40618, 40621, 40624,   -- 10-man
    40627, 40630, 40633, 40636, 40639)   -- 25-man

-- ===== WotLK Tier 8: Ulduar =====
token(CONQUEROR,      -- Paladin, Priest, Warlock
    45635, 45644, 45647, 45650, 45659,   -- 10-man
    45632, 45638, 45641, 45653, 45656)   -- 25-man
token(PROTECTOR,      -- Warrior, Hunter, Shaman
    45636, 45645, 45648, 45651, 45660,   -- 10-man
    45633, 45639, 45642, 45654, 45657)   -- 25-man
token(VANQUISHER,     -- Rogue, Death Knight, Mage, Druid
    45637, 45646, 45649, 45652, 45661,   -- 10-man
    45634, 45640, 45643, 45655, 45658)   -- 25-man

-- The class set (token -> true) a tier token is restricted to, or nil if itemId is not a known
-- token. This is the authoritative source for "who may roll a token", replacing per-name notes.
function util:TierTokenClassSet(itemId)
    return itemId and tierTokenClasses[itemId] or nil
end

-- Map a class NAME in any form ("Death Knight" / "deathknight" / "dk") to its uppercase class token.
local CLASS_NAME_TO_TOKEN = {
    ["death knight"] = "DEATHKNIGHT", deathknight = "DEATHKNIGHT", dk = "DEATHKNIGHT",
    druid = "DRUID", hunter = "HUNTER", mage = "MAGE", paladin = "PALADIN", priest = "PRIEST",
    rogue = "ROGUE", shaman = "SHAMAN", warlock = "WARLOCK", warrior = "WARRIOR",
}
function util:ClassNameToToken(className)
    return CLASS_NAME_TO_TOKEN[self:NormalizeKey(className or "")]
end

-- Equip-eligibility: can the LOCAL player's class use this item at all? Pure logic (GetItemInfo +
-- UnitClass), so it lives here (loaded headless) and is shared by the Loot-tab usable sort and the
-- roll self-block. The class->weapon sets are validated 1:1 against the client's
-- SkillRaceClassInfo.dbc; armor uses cloth<leather<mail<plate, allowing every type AT OR BELOW the
-- class (a plate class can wear cloth). NOTE: matches GetItemInfo's localized itemType/subType
-- against English keys, i.e. assumes an enUS client (ChromieCraft is enUS; item 31 tracks locale
-- independence). Uncached items resolve as usable, so a roll is never false-blocked while loading.
function util:IsItemUsableForPlayer(itemLink)
    if not itemLink or itemLink == "" then
        return false
    end
    local _, classToken = UnitClass("player")
    if not classToken then
        return false
    end

    -- Tier set tokens: class-restricted by item id (id-based, so it resolves even before the item's
    -- data is cached). Class-restricted tokens are treated exactly like gear your class can't use.
    local itemId = tonumber(string.match(itemLink, "item:(%d+)"))
    if itemId and tierTokenClasses[itemId] then
        return tierTokenClasses[itemId][classToken] and true or false
    end

    local _, _, _, _, _, itemType, itemSubType, _, equipLoc = GetItemInfo(itemLink)
    if not itemType then
        return true   -- uncached/unknown item: never claim unusable
    end
    local normalizedType = util:NormalizeKey(itemType or "")
    local normalizedSubType = util:NormalizeKey(itemSubType or "")
    local normalizedEquipLoc = util:NormalizeKey(equipLoc or "")

    local armorByClass = {
        DEATHKNIGHT = "plate", DRUID = "leather", HUNTER = "mail", MAGE = "cloth", PALADIN = "plate",
        PRIEST = "cloth", ROGUE = "leather", SHAMAN = "mail", WARLOCK = "cloth", WARRIOR = "plate",
    }

    local weaponByClass = {
        DEATHKNIGHT = { ["one-handed axes"] = true, ["two-handed axes"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, ["one-handed swords"] = true, ["two-handed swords"] = true, polearms = true, sigils = true },
        DRUID = { daggers = true, ["fist weapons"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, polearms = true, staves = true, idols = true },
        HUNTER = { ["one-handed axes"] = true, ["two-handed axes"] = true, daggers = true, ["fist weapons"] = true, polearms = true, staves = true, ["one-handed swords"] = true, ["two-handed swords"] = true, bows = true, guns = true, crossbows = true, thrown = true },
        MAGE = { daggers = true, ["one-handed swords"] = true, staves = true, wands = true },
        PALADIN = { ["one-handed axes"] = true, ["two-handed axes"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, polearms = true, ["one-handed swords"] = true, ["two-handed swords"] = true, shields = true, librams = true },
        PRIEST = { daggers = true, ["one-handed maces"] = true, staves = true, wands = true },
        ROGUE = { ["one-handed axes"] = true, daggers = true, ["fist weapons"] = true, ["one-handed maces"] = true, ["one-handed swords"] = true, bows = true, guns = true, crossbows = true, thrown = true },
        SHAMAN = { ["one-handed axes"] = true, ["two-handed axes"] = true, daggers = true, ["fist weapons"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, staves = true, shields = true, totems = true },
        WARLOCK = { daggers = true, ["one-handed swords"] = true, staves = true, wands = true },
        WARRIOR = { ["one-handed axes"] = true, ["two-handed axes"] = true, daggers = true, ["fist weapons"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, polearms = true, staves = true, ["one-handed swords"] = true, ["two-handed swords"] = true, bows = true, guns = true, crossbows = true, thrown = true, shields = true },
    }

    if normalizedType == "armor" then
        if normalizedSubType == "cloak"
            or normalizedSubType == "miscellaneous"
            or normalizedEquipLoc == "invtype_neck"
            or normalizedEquipLoc == "invtype_finger"
            or normalizedEquipLoc == "invtype_trinket"
            or normalizedEquipLoc == "invtype_holdable"
            or normalizedEquipLoc == "invtype_shield"
            or normalizedEquipLoc == "invtype_relic" then
            if normalizedEquipLoc == "invtype_shield" then
                return weaponByClass[classToken] and weaponByClass[classToken].shields or false
            end
            if normalizedEquipLoc == "invtype_relic" then
                if normalizedSubType == "idol" or normalizedSubType == "idols" then
                    return classToken == "DRUID"
                elseif normalizedSubType == "libram" or normalizedSubType == "librams" then
                    return classToken == "PALADIN"
                elseif normalizedSubType == "totem" or normalizedSubType == "totems" then
                    return classToken == "SHAMAN"
                elseif normalizedSubType == "sigil" or normalizedSubType == "sigils" then
                    return classToken == "DEATHKNIGHT"
                end
            end
            return true
        end

        -- Body armor: a class can equip its own type and every lighter type, so only HEAVIER armor is
        -- truly unequippable (option a: strict can't-equip, not "off your intended type").
        local armorRank = { cloth = 1, leather = 2, mail = 3, plate = 4 }
        local classRank = armorRank[armorByClass[classToken]]
        local itemArmorRank = armorRank[normalizedSubType]
        if not itemArmorRank then return true end    -- unknown armor subtype: do not block
        if not classRank then return false end
        return itemArmorRank <= classRank
    end

    if normalizedType == "weapon" then
        local allowed = weaponByClass[classToken]
        if not allowed then
            return false
        end
        return allowed[normalizedSubType] and true or false
    end

    -- Only armor and weapons carry a class equip-proficiency gate. Anything else (containers,
    -- consumables, quest items, gems, recipes, ...) has no class restriction, so it is always usable.
    return true
end

-- Stateless iterator over every (bag, slot) coordinate in the player's carried bags: the backpack
-- (container 0) plus the equipped bags (1 .. NUM_BAG_SLOTS). Yields raw coordinates only; the caller
-- reads the link/id/count it needs and decides whether to skip empty slots or stop early. A `break`
-- or early `return` in the loop body works, since this is an ordinary Lua for-iterator. Centralizes
-- the bag range so the scans that used to hardcode `0, 4` / MAX_BAG_ID / NUM_BAG_SLOTS share one
-- definition and cannot drift. Does NOT cover equipped gear, the equipped bags, or the keyring.
--   Usage:  for bag, slot in util:BagSlots() do ... end
function util:BagSlots()
    local maxBag = NUM_BAG_SLOTS or 4
    local bag, slot, slots = 0, 0, GetContainerNumSlots(0) or 0
    return function()
        while bag <= maxBag do
            if slot < slots then
                slot = slot + 1
                return bag, slot
            end
            bag = bag + 1
            slot = 0
            slots = (bag <= maxBag) and (GetContainerNumSlots(bag) or 0) or 0
        end
        return nil
    end
end

function util:FindBagItemByLink(itemLink)
    if not itemLink or itemLink == "" then
        return nil
    end

    for bag, slot in self:BagSlots() do
        if GetContainerItemLink(bag, slot) == itemLink then
            return bag, slot
        end
    end

    return nil
end

function util:GetLootSortInfo(itemLink)
    local itemName, _, _, _, _, itemType, itemSubType, _, equipLoc = GetItemInfo(itemLink or "")
    local normalizedType = self:NormalizeKey(itemType or "")
    local normalizedSubType = self:NormalizeKey(itemSubType or "")
    local normalizedEquipLoc = self:NormalizeKey(equipLoc or "")

    if normalizedType == "armor" then
        local armorOrder = {
            cloth = 1,
            leather = 2,
            mail = 3,
            plate = 4,
        }
        local bucket = armorOrder[normalizedSubType]
        if bucket then
            return {
                order = bucket,
                label = normalizedSubType,
                subtype = normalizedSubType,
                itemName = itemName or "",
            }
        end
    end

    if normalizedType == "weapon"
        or string.find(normalizedEquipLoc, "weapon", 1, true)
        or normalizedSubType == "bows"
        or normalizedSubType == "guns"
        or normalizedSubType == "crossbows"
        or normalizedSubType == "thrown"
        or normalizedSubType == "wands"
        or normalizedSubType == "fishing poles"
        or normalizedSubType == "shields"
        or normalizedEquipLoc == "invtype_holdable"
        or normalizedEquipLoc == "invtype_relic" then
        return {
            order = 5,
            label = "weapon",
            subtype = normalizedSubType ~= "" and normalizedSubType or normalizedEquipLoc,
            itemName = itemName or "",
        }
    end

    return {
        order = 6,
        label = normalizedType ~= "" and normalizedType or "other",
        subtype = normalizedSubType,
        itemName = itemName or "",
    }
end

-- Items that roll on the reduced MS(need)/OS(greed)/Pass set and are rolled out first: things that
-- are not gear and carry no class restriction (bags, mounts, containers, ...). This is an EXPLICIT
-- itemId list, not a property heuristic: tier tokens look like non-equipment by item type but turn
-- into gear and must keep the full bracket set and class rules, so a heuristic would wrongly reduce
-- them. Non-equipment is the rarer case, so listing it is safer than a general rule. Add itemIds here.
util.REDUCED_ROLL_ITEMS = {
    -- Epic non-equipment raid drops (mounts and bags), seeded from the ChromieCraft item_template +
    -- loot tables, grouped by raid. Excludes 5-mans, world drops, and PvP rewards.
    -- Onyxia's Lair
    [49295] = true,  -- Enlarged Onyxia Hide Backpack
    [49636] = true,  -- Reins of the Onyxian Drake
    -- Zul'Gurub
    [19872] = true,  -- Swift Razzashi Raptor
    [19902] = true,  -- Swift Zulian Tiger
    -- Karazhan
    [30480] = true,  -- Fiery Warhorse's Reins
    -- Magtheridon's Lair
    [34845] = true,  -- Pit Lord's Satchel
    -- Tempest Keep
    [32458] = true,  -- Ashes of Al'ar
    -- The Obsidian Sanctum
    [43345] = true,  -- Dragon Hide Bag
    [43346] = true,  -- Large Satchel of Spoils (25m bonus bag)
    [43347] = true,  -- Satchel of Spoils (10m bonus bag)
    [43954] = true,  -- Reins of the Twilight Drake
    [43986] = true,  -- Reins of the Black Drake
    -- The Eye of Eternity
    [43952] = true,  -- Reins of the Azure Drake
    [43953] = true,  -- Reins of the Blue Drake
    -- Vault of Archavon
    [43959] = true,  -- Reins of the Grand Black War Mammoth
    [44083] = true,  -- Reins of the Grand Black War Mammoth
    -- Ulduar
    [45693] = true,  -- Mimiron's Head
    -- Trial of the Crusader (Tribute Chest)
    [49044] = true,  -- Swift Alliance Steed
    [49046] = true,  -- Swift Horde Wolf
    -- Icecrown Citadel
    [50818] = true,  -- Invincible's Reins
}

-- True if the item (a link or an itemId) is on the explicit non-equipment list.
function util:IsKnownNonEquipment(item)
    local id = type(item) == "number" and item or self:ItemIdFromLink(item)
    return id ~= nil and self.REDUCED_ROLL_ITEMS[id] == true
end

-- Property heuristic: does the item lack a real equip slot? Used ONLY for roll-OUT ordering, a
-- harmless grouping, NEVER for the bracket set: tier tokens read as non-equipment here but must keep
-- the full set, so the button policy keys off the explicit list above instead. `item` is a link or
-- itemId; an uncached item reads as gear so it just orders later.
function util:LacksEquipSlot(item)
    if not item then return false end
    local name, _, _, _, _, _, _, _, equipLoc = GetItemInfo(item)
    if not name then return false end
    if not equipLoc or equipLoc == "" then return true end
    if equipLoc == "INVTYPE_BAG" then return true end
    return false
end

local ROLL_TIERS = { "bis", "ms", "mu", "os", "tm", "pass" }
local NONEQUIP_TIERS = { ms = true, os = true, pass = true }   -- reduced-roll items get MS/OS(greed)/Pass

-- Single source of truth for the roll brackets shared across the roll popup, banner cards, loot tab,
-- result sections and the resolver. Every consumer derives its own view (label map, rank, per-tier
-- widths, pass-excluded order) from these instead of re-listing the tiers, so the set can never drift.
-- The compact "TM" here is deliberate; the hover lists use a spelled-out "Tmog" (RESPONSE_LABELS in
-- LiveRoll), the one intentional label variant.
util.RollTiers = ROLL_TIERS                              -- ordered tier keys, highest bracket first
util.BracketLabels = { bis = "BiS", ms = "MS", mu = "MU", os = "OS", tm = "TM", pass = "Pass" }
util.RollTierRank = {}                                   -- tier key -> 1..N position (bis = 1 .. pass = 6)
util.BracketRank = {}                                    -- label -> rank, for surfaces that carry the display label
util.WinTiers = {}                                       -- tier order minus pass (passers never win / get a section)
for i, key in ipairs(ROLL_TIERS) do
    util.RollTierRank[key] = i
    util.BracketRank[util.BracketLabels[key]] = i
    if key ~= "pass" then util.WinTiers[#util.WinTiers + 1] = key end
end

-- Single source of truth for which roll brackets (BiS/MS/MU/OS/TM/Pass) an item offers, so the roll
-- popup and the loot tab (mirrors of each other) never drift. They differ only in how they render the
-- result. Returns a map bracket -> disable reason ("locked" / "quest" / "unique" / "type" / "class" /
-- "noprio") or nil when the bracket is available. blockReason: a self-only reason the local player
-- can't use this drop at all (already did the quest / already hold the unique), so only Pass is
-- allowed. Self-only, like the class block; the ML cannot see others' bags. hasPrio: whether the item
-- has a listed priority (see addon:ItemHasPriority); BiS is offered only for such items.
function util:RollTierAvailability(item, isAllowed, isLocked, blockReason, hasPrio)
    local reduced = self:IsKnownNonEquipment(item)
    local out = {}
    for _, key in ipairs(ROLL_TIERS) do
        local reason
        if isLocked then
            reason = "locked"                              -- a locked (rolled-out) lot disables every bracket
        elseif key == "pass" then
            reason = nil                                   -- pass is always available on an open lot
        elseif blockReason then
            reason = blockReason                           -- self-block (quest done / own the unique); only Pass remains
        elseif reduced then
            -- reduced-roll item (bag/mount/etc.): MS/OS/Pass only, and no class restriction applies
            reason = (not NONEQUIP_TIERS[key]) and "type" or nil
        elseif not isAllowed then
            reason = "class"                               -- gear (incl. tier tokens) honors class rules
        end
        -- BiS is only meaningful for an item with a listed priority. Lowest-precedence reason: it
        -- fires only when BiS would otherwise be available, so it never overrides a more specific
        -- block (locked/class/type/self-block) and never touches the other brackets.
        if reason == nil and key == "bis" and not hasPrio then
            reason = "noprio"
        end
        out[key] = reason
    end
    return out
end
