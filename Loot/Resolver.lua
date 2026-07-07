local addon = WeirdLoot
local util = addon.util

-- Module-local helpers used by FilterByStatus (defined here so the function-local upvalue
-- exists by the time FilterByStatus' body executes).
local function effectiveStatusRank(status, mergeMainAndAlt)
    local r = util:StatusRank(status)
    if mergeMainAndAlt and r == 3 then return 2 end
    return r
end

-- Human-readable label for a status rank: 3 -> "Main", 2 -> "Designated Alt", else "Nil".
-- "Nil" (not "Unknown") is the wording the result record + log have always used for rank 1.
local function statusTierTextForRank(rank)
    if rank == 3 then return "Main" end
    if rank == 2 then return "Designated Alt" end
    return "Nil"
end

function addon:InitializeResolver()
    -- the core delegates winner-picking here, handing us exactly one lot's responses by id.
    if self.lootCore then
        self.lootCore:SetResolver(function(lot) return self:ResolveSessionItem(lot) end)
    end
end

-- Build the roller list from a lot's group-level responses (playerKey -> tier string).
function addon:BuildRollerList(lot)
    local rollers = {}
    local responses = lot and lot.responses or {}
    -- gate-tokens-by-class: tier tokens resolve by itemId (authoritative table); the name is the
    -- fallback for any note-gated non-token item.
    local itemId = lot and lot.itemId or nil
    local itemName = itemId and select(1, util:ItemRender(itemId)) or nil

    for playerKey, choice in pairs(responses) do
        if self:IsResponseActive(choice) and self:IsPlayerAllowedForItem(itemId, itemName, playerKey) then
            local attendee = self:GetAttendee(playerKey) or self:GetRosterProfile(playerKey)
            rollers[#rollers + 1] = {
                name = attendee and attendee.name or playerKey,
                className = attendee and attendee.className or "",
                specName = attendee and attendee.specName or "",
                status = attendee and attendee.status or "unknown",
                descriptor = util:NormalizeKey(((attendee and attendee.className) or "") .. " " .. ((attendee and attendee.specName) or "")),
                responseType = choice,
            }
        end
    end

    util:SortByName(rollers, "name")
    return rollers
end

function addon:FindMatchingTier(rule, candidates, matcher)
    if not rule or not rule.tiers then
        return nil, candidates
    end

    local unmatched = util:CloneTable(candidates)
    for _, tier in ipairs(rule.tiers) do
        local survivors = {}
        local matchedKeys = {}
        local hasRest = false

        for _, entry in ipairs(tier.entries) do
            if entry.isRest then
                hasRest = true
            else
                for _, candidate in ipairs(candidates) do
                    if not matchedKeys[candidate.name] and matcher(entry, candidate) then
                        survivors[#survivors + 1] = candidate
                        matchedKeys[candidate.name] = true
                    end
                end
            end
        end

        if #survivors > 0 then
            return tier, survivors
        end

        if hasRest then
            return tier, unmatched
        end
    end

    return nil, candidates
end

-- mergeMainAndAlt: collapses Main (3) and DesignatedAlt (2) to the same effective rank so they
-- compete equally. Used for non-BiS responses (MS/MU/OS/TM), where status is only meant to gate
-- "raider on the roster" vs "nil". For BiS, Mains still outrank DesignatedAlts.
function addon:FilterByStatus(candidates, mergeMainAndAlt)
    local highestEffective = 0
    local survivors = {}
    local highestActual = 0

    for _, candidate in ipairs(candidates) do
        highestEffective = math.max(highestEffective, effectiveStatusRank(candidate.status, mergeMainAndAlt))
    end

    for _, candidate in ipairs(candidates) do
        if effectiveStatusRank(candidate.status, mergeMainAndAlt) == highestEffective then
            survivors[#survivors + 1] = candidate
            highestActual = math.max(highestActual, util:StatusRank(candidate.status))
        end
    end

    return survivors, highestActual
end

function addon:RollCandidates(candidates, rollAssignments)
    local rolls = {}
    for _, candidate in ipairs(candidates) do
        local assigned = rollAssignments and rollAssignments[util:NormalizeKey(candidate.name)]
        rolls[#rolls + 1] = {
            name = (assigned and assigned.name) or candidate.name,
            roll = (assigned and assigned.roll) or math.random(1, 100),
            auto = assigned and assigned.auto or false,
        }
    end

    table.sort(rolls, function(left, right)
        if left.roll == right.roll then
            return string.lower(left.name) < string.lower(right.name)
        end
        return left.roll > right.roll
    end)

    return rolls
end

local function sortRollsDescending(rolls)
    table.sort(rolls, function(left, right)
        if left.roll == right.roll then
            return string.lower(left.name) < string.lower(right.name)
        end
        return left.roll > right.roll
    end)
end

local function formatCandidateSummary(candidate)
    local nameText = (util:GetClassColorCode(candidate.className) or "|cffffffff") .. (candidate.name or "Unknown") .. "|r"
    local parts = {
        nameText,
        util:TitleCaseWords(string.trim((candidate.className or "") .. " " .. (candidate.specName or ""))),
        util:PlayerDisplayStatus(candidate.status),
    }

    return table.concat(parts, " - ")
end

local function winnerPriorityLabel(winner)
    if winner and winner.isNamed then
        return "LC Prio"
    end
    return nil
end

local RESULT_RESPONSE_GROUPS = {
    { key = "bis", label = "BiS Rollers:" },
    { key = "ms", label = "MS Rollers:" },
    { key = "mu", label = "MU Rollers:" },
    { key = "os", label = "OS Rollers:" },
    { key = "tm", label = "TM Rollers:" },
}

local function rollerSortValue(candidate)
    if candidate.auto or candidate.rollText == "AUTO" then
        return 101
    end
    return tonumber(candidate.roll) or tonumber(candidate.rollText) or -1
end

local function sortGroupedRollers(entries)
    table.sort(entries, function(left, right)
        local leftRoll = rollerSortValue(left)
        local rightRoll = rollerSortValue(right)
        if leftRoll == rightRoll then
            return string.lower(left.name or "") < string.lower(right.name or "")
        end
        return leftRoll > rightRoll
    end)
end

local function appendGroupedRollers(lines, candidates)
    local grouped = {}
    for _, group in ipairs(RESULT_RESPONSE_GROUPS) do
        grouped[group.key] = {}
    end

    for _, candidate in ipairs(candidates or {}) do
        local choice = candidate.responseType or "pass"
        if choice ~= "pass" then
            grouped[choice] = grouped[choice] or {}
            grouped[choice][#grouped[choice] + 1] = candidate
        end
    end

    local renderedGroups = 0
    for _, group in ipairs(RESULT_RESPONSE_GROUPS) do
        local entries = grouped[group.key] or {}
        if #entries > 0 then
            sortGroupedRollers(entries)
            if renderedGroups > 0 then
                lines[#lines + 1] = ""
            end

            lines[#lines + 1] = group.label
            for _, candidate in ipairs(entries) do
                local rollText = candidate.rollText and (" - (" .. candidate.rollText .. ")") or ""
                lines[#lines + 1] = formatCandidateSummary(candidate) .. rollText
            end
            renderedGroups = renderedGroups + 1
        end
    end

    if renderedGroups > 0 then
        lines[#lines + 1] = ""
    end
end

function addon:IsCandidateNamedForItem(namedRule, candidateName)
    if not namedRule or not namedRule.tiers then
        return false
    end

    local candidateKey = util:NormalizeKey(candidateName or "")
    for _, tier in ipairs(namedRule.tiers) do
        for _, entry in ipairs(tier.entries or {}) do
            if not entry.isRest and entry.playerKey == candidateKey then
                return true
            end
        end
    end

    return false
end

function addon:FindMatchingNamedTier(rule, candidates)
    if not rule or not rule.tiers then
        return nil, candidates, false
    end

    for _, tier in ipairs(rule.tiers) do
        local survivors = {}
        local matchedKeys = {}
        local hasLootCouncil = false

        for _, entry in ipairs(tier.entries or {}) do
            if entry.isLootCouncil then
                hasLootCouncil = true
            elseif not entry.isRest then
                for _, candidate in ipairs(candidates or {}) do
                    local candidateKey = util:NormalizeKey(candidate.name)
                    if not matchedKeys[candidateKey] and entry.playerKey == candidateKey then
                        survivors[#survivors + 1] = candidate
                        matchedKeys[candidateKey] = true
                    end
                end
            end
        end

        if #survivors > 0 then
            return tier, survivors, false
        end

        if hasLootCouncil then
            return tier, candidates, true
        end
    end

    return nil, candidates, false
end

local function formatPlainCandidateNames(candidates)
    local names = {}
    for _, candidate in ipairs(candidates or {}) do
        if candidate.name and candidate.name ~= "" then
            names[#names + 1] = candidate.name
        end
    end

    if #names == 0 then
        return "none"
    end

    return table.concat(names, ", ")
end

local function formatSpecPriorityDisplay(specPriorityText)
    local normalized = string.trim(specPriorityText or "")
    if normalized == "" then
        return "none"
    end

    local tiers = {}
    for _, tierText in ipairs(util:Split(normalized, ">")) do
        tierText = string.trim(tierText)
        if tierText ~= "" then
            if string.find(tierText, "/", 1, true) then
                local formattedEntries = {}
                for _, entryText in ipairs(util:Split(tierText, "/")) do
                    entryText = string.trim(entryText)
                    formattedEntries[#formattedEntries + 1] = util:NormalizeKey(entryText) == "lc" and "LC" or util:TitleCaseWords(entryText)
                end
                tiers[#tiers + 1] = table.concat(formattedEntries, " / ")
            else
                tiers[#tiers + 1] = util:NormalizeKey(tierText) == "lc" and "LC" or util:TitleCaseWords(tierText)
            end
        end
    end

    if #tiers == 0 then
        return "none"
    end

    return table.concat(tiers, "\n---\n")
end

function addon:RuleHasLootCouncil(rule)
    if not rule or not rule.tiers then
        return false
    end

    for _, tier in ipairs(rule.tiers) do
        for _, entry in ipairs(tier.entries or {}) do
            if entry.isLootCouncil then
                return true
            end
        end
    end

    return false
end

function addon:BuildResultDetail(result)
    local lines = {}
    local quantityText = (result.quantity or 1) > 1 and string.format(" x%d", result.quantity or 1) or ""
    local lcNamesText = string.trim(result.lcNamesText or "")
    local hasLcNames = lcNamesText ~= "" and lcNamesText ~= "none"
    lines[#lines + 1] = "Item: " .. (result.itemName or "") .. quantityText
    lines[#lines + 1] = ""
    appendGroupedRollers(lines, result.allRollerDetails or {})

    if hasLcNames then
        lines[#lines + 1] = "LC Names:"
        lines[#lines + 1] = lcNamesText
        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "Spec Priority:"
    lines[#lines + 1] = formatSpecPriorityDisplay(result.specPriorityText)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Prioritized Rolls:"
    if #(result.rollDetails or {}) == 0 then
        lines[#lines + 1] = "none"
    else
        for _, roll in ipairs(result.rollDetails or {}) do
            local rollValue = roll.auto and "AUTO" or tostring(roll.roll or "")
            local namedText = roll.isNamed and " - LC" or ""
            lines[#lines + 1] = string.format("%s - (%s)%s", formatCandidateSummary(roll), rollValue, namedText)
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Winner:"
    if result.isLootCouncil then
        lines[#lines + 1] = "Loot Council"
    elseif #(result.winnerDetails or {}) == 0 then
        lines[#lines + 1] = "No winner"
    else
        for _, winner in ipairs(result.winnerDetails or {}) do
            local rollValue = winner.auto and "AUTO" or tostring(winner.roll or "")
            local winnerName = (util:GetClassColorCode(winner.className) or "|cffffffff") .. (winner.name or "Unknown") .. "|r"
            local priorityText = winnerPriorityLabel(winner)
            lines[#lines + 1] = string.format("%s (%s)%s", winnerName, rollValue, priorityText and (" - " .. priorityText) or "")
        end
    end
    return table.concat(lines, "\n")
end

-- A name that is still the bare "item:<id>" fallback util:ItemRender hands back while GetItemInfo is
-- cold (see Util.lua). A resolved record built in that window bakes this into itemName/itemLink.
local function isFallbackItemName(name)
    return (not name) or name == "" or string.find(name, "^item:%d+$") ~= nil
end

-- The real (40194-style) item id for a result record. A record's own itemId field is the LOT key
-- ("L:<seq>"), not the item id; the item id lives on the lot (lootCore identity) and, on raider
-- records, also on realItemId. Fall back to the id embedded in the stored itemLink ("item:40194",
-- present even when cold) so a record whose lot has been pruned still resolves.
function addon:ResultRealItemId(result)
    if not result then return nil end
    if result.realItemId then return result.realItemId end
    local lot = self.lootCore and self.lootCore:Get(result.itemId)
    if lot and lot.itemId then return lot.itemId end
    return tonumber(string.match(result.itemLink or "", "item:(%d+)"))
end

-- Heal a result that resolved while its item was cold: it baked the "item:<id>" fallback into the
-- record's itemName/itemLink/icon/summary/detailText. Once the client has the data, rewrite those
-- stored fields in place so every Results surface shows the real name and it sticks across renders and
-- saves. While still cold, prime the client and flag the shared name ticker to retry. No-op once real.
function addon:RehydrateResult(result)
    if not result or not isFallbackItemName(result.itemName) then return end
    local realId = self:ResultRealItemId(result)
    if not realId then return end
    local name, link, icon = util:ItemRender(realId)
    if not name then
        self:PrimeItemInfo(realId)
        self._lootNamesPending = true
        return
    end
    result.itemName, result.itemLink, result.itemIcon = name, link, icon
    local winnersText = result.winnersText or result.winner or "No winner"
    result.summary = (result.quantity or 1) >= 2
        and string.format("%s x%d -> %s", name, result.quantity or 1, winnersText)
        or string.format("%s -> %s", name, winnersText)
    result.detailText = self:BuildResultDetail(result)
end

function addon:SelectWinningRolls(rolls, quantity)
    -- top-N: one distinct winner per copy (was hard-capped at 2; the core supports any N)
    local winnerCount = math.min(quantity or 1, #rolls)

    local winners = {}
    for index = 1, winnerCount do
        if rolls[index] then
            winners[#winners + 1] = rolls[index].name
        end
    end

    return winners
end

function addon:CollectPriorityWinnerCandidates(rule, candidates, matcher, quantity, allRollByName, mergeMainAndAlt)
    local orderedCandidates = {}
    local chosen = {}
    local maxCount = quantity or 1

    local function rollOf(name)
        local rec = allRollByName[util:NormalizeKey(name)]
        return rec and rec.roll or 0
    end

    -- Within a spec tier, walk status tiers (Main → DesAlt → nil) for BiS, or (Main+DesAlt → nil)
    -- for non-BiS. A 2x BiS lot with one Main and one DesAlt roller awards the first copy to the
    -- Main and the second to the DesAlt; previously FilterByStatus dropped the DesAlt entirely.
    local function appendSortedCandidates(tierCandidates)
        local groups = {}
        for _, candidate in ipairs(tierCandidates) do
            local rank = effectiveStatusRank(candidate.status, mergeMainAndAlt)
            groups[rank] = groups[rank] or {}
            groups[rank][#groups[rank] + 1] = candidate
        end

        for _, statusRank in ipairs({ 3, 2, 1 }) do
            local group = groups[statusRank]
            if group then
                table.sort(group, function(left, right)
                    local leftRoll = rollOf(left.name)
                    local rightRoll = rollOf(right.name)
                    if leftRoll == rightRoll then
                        return string.lower(left.name or "") < string.lower(right.name or "")
                    end
                    return leftRoll > rightRoll
                end)
                for _, candidate in ipairs(group) do
                    local candidateKey = util:NormalizeKey(candidate.name)
                    if not chosen[candidateKey] then
                        orderedCandidates[#orderedCandidates + 1] = candidate
                        chosen[candidateKey] = true
                        if #orderedCandidates >= maxCount then
                            return true
                        end
                    end
                end
            end
        end

        return false
    end

    for _, tier in ipairs(rule and rule.tiers or {}) do
        local tierCandidates = {}
        local hasRest = false

        for _, entry in ipairs(tier.entries or {}) do
            if entry.isRest then
                hasRest = true
            else
                for _, candidate in ipairs(candidates or {}) do
                    local candidateKey = util:NormalizeKey(candidate.name)
                    if not chosen[candidateKey] and matcher(entry, candidate) then
                        tierCandidates[#tierCandidates + 1] = candidate
                    end
                end
            end
        end

        if #tierCandidates == 0 and hasRest then
            for _, candidate in ipairs(candidates or {}) do
                local candidateKey = util:NormalizeKey(candidate.name)
                if not chosen[candidateKey] then
                    tierCandidates[#tierCandidates + 1] = candidate
                end
            end
        end

        if #tierCandidates > 0 and appendSortedCandidates(tierCandidates) then
            break
        end
    end

    return orderedCandidates
end

function addon:BuildResultRecord(item, allRollerNames, allRollerDetails, lcNamesText, specPriorityText, statusRank, prioritizedNames, rolls, rollDetails, winnerDetails)
    local winners = {}
    for _, winner in ipairs(winnerDetails or {}) do
        winners[#winners + 1] = winner.name
    end
    if #winners == 0 then
        winners = self:SelectWinningRolls(rolls, item.quantity or 1)
    end
    local winnersText = #winners > 0 and table.concat(winners, ", ") or "No winner"
    local result = {
        itemId = item.id,
        itemName = item.name,
        itemLink = item.link,
        itemIcon = item.icon,
        quantity = item.quantity or 1,
        allRollers = allRollerNames,
        allRollerDetails = allRollerDetails or {},
        lcNamesText = lcNamesText,
        specPriorityText = specPriorityText,
        statusTierText = statusTierTextForRank(statusRank),
        prioritizedNames = prioritizedNames,
        finalRolls = rolls,
        rollDetails = rollDetails or {},
        winnerDetails = winnerDetails or {},
        winners = winners,
        winnersText = winnersText,
        winner = winners[1] or "No winner",
        locked = true,
    }

    if (item.quantity or 1) >= 2 then
        result.summary = string.format("%s x%d -> %s", item.name or "Item", item.quantity or 1, winnersText)
    else
        result.summary = string.format("%s -> %s", item.name or "Item", winnersText)
    end
    result.detailText = self:BuildResultDetail(result)
    return result
end

function addon:BuildLootCouncilResultRecord(item, allRollerNames, allRollerDetails, lcNamesText, specPriorityText, statusRank, prioritizedNames)
    local result = {
        itemId = item.id,
        itemName = item.name,
        itemLink = item.link,
        itemIcon = item.icon,
        quantity = item.quantity or 1,
        allRollers = allRollerNames,
        allRollerDetails = allRollerDetails or {},
        lcNamesText = lcNamesText,
        specPriorityText = specPriorityText,
        statusTierText = statusTierTextForRank(statusRank),
        prioritizedNames = prioritizedNames or {},
        finalRolls = {},
        rollDetails = {},
        winnerDetails = {},
        winners = {},
        winnersText = "Loot Council",
        winner = "No winner",
        locked = true,
        isLootCouncil = true,
    }

    if (item.quantity or 1) >= 2 then
        result.summary = string.format("%s x%d -> Loot Council", item.name or "Item", item.quantity or 1)
    else
        result.summary = string.format("%s -> Loot Council", item.name or "Item")
    end
    result.detailText = self:BuildResultDetail(result)
    return result
end

-- Resolve a single session item through the shared bracket -> named -> spec -> status
-- engine (used by both batch ProcessLoot and the live-roll flow). Returns the standard
-- result record. Does NOT lock or append -- the caller does that.
-- Resolve one lot. `lot` is a LootCore lot: identity is lot.itemId, count is lot.count, and
-- the responses live on lot.responses. Display fields are rendered from itemId on demand.
-- Response tiers in priority order. "pass" is intentionally absent (passers don't win), which is
-- exactly util.WinTiers.
local RESPONSE_TIER_ORDER = util.WinTiers

local function rollersForResponseType(rollers, responseType)
    local out = {}
    for _, roller in ipairs(rollers) do
        if (roller.responseType or "pass") == responseType then
            out[#out + 1] = roller
        end
    end
    return out
end

local function topResponseTierRollers(rollers)
    for _, key in ipairs(RESPONSE_TIER_ORDER) do
        local tierRollers = rollersForResponseType(rollers, key)
        if #tierRollers > 0 then
            return key, tierRollers
        end
    end
    return nil, {}
end

function addon:ResolveSessionItem(lot)
    local _name, _link, _icon = util:ItemRender(lot.itemId)
    local item = {
        id = lot.id,
        itemId = lot.itemId,
        name = _name or ("item:" .. tostring(lot.itemId)),
        link = _link,
        icon = _icon,
        quantity = lot.count or 1,
    }
    local rollers = self:BuildRollerList(lot)
    local allRollerNames = {}
    local allRollerDetails = {}
    local namedRule = self:GetNamedRule(item.name)
    for _, roller in ipairs(rollers) do
        allRollerNames[#allRollerNames + 1] = roller.name
        allRollerDetails[#allRollerDetails + 1] = {
            name = roller.name,
            className = roller.className,
            specName = roller.specName,
            status = roller.status,
            responseType = roller.responseType,
            isNamed = self:IsCandidateNamedForItem(namedRule, roller.name),
        }
    end

    local allRolls = self:RollCandidates(rollers, item.liveRollAssignments)
    local allRollByName = {}
    for _, roll in ipairs(allRolls) do
        allRollByName[util:NormalizeKey(roll.name)] = roll
    end
    for _, detail in ipairs(allRollerDetails) do
        local matchedRoll = allRollByName[util:NormalizeKey(detail.name)]
        detail.rollText = matchedRoll and (matchedRoll.auto and "AUTO" or tostring(matchedRoll.roll)) or nil
    end
    local lootRule = self:GetLootRule(item.name)
    local defaultSpecPriorityText = lootRule and lootRule.raw or (self:RuleHasLootCouncil(namedRule) and "LC" or nil)

    local specMatcher = function(entry, candidate)
        local keyA = util:NormalizeKey((candidate.className or "") .. " " .. (candidate.specName or ""))
        local keyB = util:NormalizeKey((candidate.specName or "") .. " " .. (candidate.className or ""))
        for _, key in ipairs(entry.matchKeys or {}) do
            if key ~= "" and (key == keyA or key == keyB) then
                return true
            end
        end
        return false
    end
    local namedMatcher = function(entry, candidate)
        return entry.playerKey == util:NormalizeKey(candidate.name)
    end

    -- LC short-circuits the whole item. Original semantics: LC is decided against the highest
    -- response tier with any rollers -- if none of its rollers match a named entry, the named
    -- rule's "rest" position falls through to LC and the council picks every copy.
    local topKey, topRollers = topResponseTierRollers(rollers)
    if topKey then
        local mergeMainAndAlt = topKey ~= "bis"
        local _, prioritized, isLootCouncil = self:FindMatchingNamedTier(namedRule, topRollers)
        if isLootCouncil then
            local councilCandidates = prioritized
            local displaySpecPriorityText = defaultSpecPriorityText or "LC"

            if lootRule then
                local _, filtered = self:FindMatchingTier(lootRule, councilCandidates, specMatcher)
                councilCandidates = filtered
            end

            local rank
            councilCandidates, rank = self:FilterByStatus(councilCandidates, mergeMainAndAlt)
            local prioritizedNames = {}
            for _, player in ipairs(councilCandidates) do
                prioritizedNames[#prioritizedNames + 1] = player.name
            end

            return self:BuildLootCouncilResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                formatPlainCandidateNames(councilCandidates),
                displaySpecPriorityText,
                rank,
                prioritizedNames
            )
        end
    end

    -- Non-LC path: walk response tiers in priority order, accumulating winners until the lot's
    -- quantity is met. A 2x lot with one MS roller and one OS roller awards one copy to each;
    -- previously the lower tier was discarded entirely by FilterByResponsePriority.
    local quantity = item.quantity or 1
    local winnerDetails = {}
    local rollDetails = {}
    local prioritizedNames = {}
    local rolls = {}
    local seenSurvivor = {}
    local rank = 0
    local firstNamedTier = nil

    for _, responseKey in ipairs(RESPONSE_TIER_ORDER) do
        if #winnerDetails >= quantity then break end

        local tierRollers = rollersForResponseType(rollers, responseKey)
        if #tierRollers > 0 then
            local mergeMainAndAlt = responseKey ~= "bis"
            -- isLootCouncil at non-top tiers is ignored: LC was decided above. A lower tier
            -- whose rollers didn't match the named rule simply gets treated as spec-tier rollers.
            local namedTier, prioritized = self:FindMatchingNamedTier(namedRule, tierRollers)

            if namedTier and firstNamedTier == nil then
                firstNamedTier = namedTier
            end

            local activeRule, activeMatcher
            if namedTier then
                activeRule, activeMatcher = namedRule, namedMatcher
            elseif lootRule then
                local _, filtered = self:FindMatchingTier(lootRule, prioritized, specMatcher)
                prioritized = filtered
                activeRule, activeMatcher = lootRule, specMatcher
            end

            -- Show every spec-survivor in priority order. Status fall-through means a Main beats
            -- a DesAlt for BiS but the DesAlt can still claim a second copy, so both belong in
            -- "Prioritized Rolls" even though only the Main wins for 1x.
            local statusSorted = {}
            for _, p in ipairs(prioritized) do statusSorted[#statusSorted + 1] = p end
            table.sort(statusSorted, function(left, right)
                local leftRank = effectiveStatusRank(left.status, mergeMainAndAlt)
                local rightRank = effectiveStatusRank(right.status, mergeMainAndAlt)
                if leftRank ~= rightRank then return leftRank > rightRank end
                local leftKey = util:NormalizeKey(left.name)
                local rightKey = util:NormalizeKey(right.name)
                local leftRoll = allRollByName[leftKey] and allRollByName[leftKey].roll or 0
                local rightRoll = allRollByName[rightKey] and allRollByName[rightKey].roll or 0
                if leftRoll ~= rightRoll then return leftRoll > rightRoll end
                return string.lower(left.name or "") < string.lower(right.name or "")
            end)

            for _, player in ipairs(statusSorted) do
                local actual = util:StatusRank(player.status)
                if actual > rank then rank = actual end
                local key = util:NormalizeKey(player.name)
                if not seenSurvivor[key] then
                    seenSurvivor[key] = true
                    prioritizedNames[#prioritizedNames + 1] = player.name
                    local matchedRoll = allRollByName[key]
                    if matchedRoll then
                        rolls[#rolls + 1] = {
                            name = matchedRoll.name,
                            roll = matchedRoll.roll,
                            auto = matchedRoll.auto,
                        }
                    end
                    rollDetails[#rollDetails + 1] = {
                        name = player.name,
                        className = player.className,
                        specName = player.specName,
                        status = player.status,
                        roll = matchedRoll and matchedRoll.roll or nil,
                        auto = matchedRoll and matchedRoll.auto or false,
                        isNamed = self:IsCandidateNamedForItem(namedRule, player.name),
                    }
                end
            end

            local remaining = quantity - #winnerDetails
            local tierWinnerCandidates = {}
            if activeRule then
                tierWinnerCandidates = self:CollectPriorityWinnerCandidates(activeRule, tierRollers, activeMatcher, remaining, allRollByName, mergeMainAndAlt)
            end
            if #tierWinnerCandidates == 0 then
                -- No-rule fallback: pick by (status desc, roll desc). The sorted display order
                -- already encodes that priority, so the top N entries are the next N winners.
                for index = 1, math.min(remaining, #statusSorted) do
                    tierWinnerCandidates[#tierWinnerCandidates + 1] = statusSorted[index]
                end
            end

            for _, winnerCandidate in ipairs(tierWinnerCandidates) do
                if #winnerDetails >= quantity then break end
                local winnerName = winnerCandidate.name
                local matchedRoll = allRollByName[util:NormalizeKey(winnerName)]
                winnerDetails[#winnerDetails + 1] = {
                    name = winnerName,
                    className = winnerCandidate.className,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                    isNamed = self:IsCandidateNamedForItem(namedRule, winnerName),
                }
            end
        end
    end

    sortRollsDescending(rolls)

    return self:BuildResultRecord(
        item,
        allRollerNames,
        allRollerDetails,
        firstNamedTier and firstNamedTier.raw or nil,
        defaultSpecPriorityText,
        rank,
        prioritizedNames,
        rolls,
        rollDetails,
        winnerDetails
    )
end

-- ProcessLoot (the "Start Rolls" button): kick off live rolls in batches. The first
-- N lots from the loot list go up for roll in parallel; as each batch finishes (every
-- roll resolved or cancelled), the next N start. This replaces the old instant
-- bulk-resolve behavior so the raid actually gets to roll on each item.
function addon:ProcessLoot()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can process loot.")
        return
    end

    local core = self.lootCore
    local queue = {}
    for _, lot in ipairs(core:List()) do
        if lot.state ~= core.STATE.ROLLING and lot.state ~= core.STATE.RESOLVED then
            queue[#queue + 1] = lot.id
        end
    end

    if #queue == 0 then
        self:Print("No unrolled loot to start. Unlock a result to reroll it.")
        return
    end

    queue = self:OrderLotIdsNonEquipFirst(queue)   -- roll non-equipment (bags/mounts) out first

    local batchSize = tonumber(self.db and self.db.options and self.db.options.rollBatchSize) or 5
    if batchSize < 1 then batchSize = 1 end

    self._rollBatch = { queue = queue, batchSize = batchSize, active = {} }
    self:Print(string.format("Starting rolls in batches of %d (%d items queued).", batchSize, #queue))
    self:AdvanceRollBatch()
end

-- Pull the next slice from the queue and StartLiveRoll on each. Called once by ProcessLoot
-- and again every time the active set drains.
function addon:AdvanceRollBatch()
    local batch = self._rollBatch
    if not batch then return end
    while #batch.queue > 0 and self:CountActiveRollBatch() < batch.batchSize do
        local lotId = table.remove(batch.queue, 1)
        local lot = self.lootCore:Get(lotId)
        if lot and lot.state ~= self.lootCore.STATE.ROLLING and lot.state ~= self.lootCore.STATE.RESOLVED then
            batch.active[lotId] = true
            self:StartLiveRoll(lotId)
        end
    end
    if #batch.queue == 0 and self:CountActiveRollBatch() == 0 then
        self:FinishRollBatch()
    end
end

function addon:CountActiveRollBatch()
    local batch = self._rollBatch
    if not batch then return 0 end
    local n = 0
    for _ in pairs(batch.active) do n = n + 1 end
    return n
end

-- Called from ResolveLiveRoll / CancelLiveRoll: drop the lot from the active set and,
-- if the batch has fully drained, advance to the next slice.
function addon:NotifyRollBatchFinished(lotId)
    local batch = self._rollBatch
    if not batch or not batch.active[lotId] then return end
    batch.active[lotId] = nil
    self:AdvanceRollBatch()
end

-- Auto-start path: feed fresh NEW lot ids into the same batch infrastructure used by Start Rolls
-- so the configured Start-Rolls batch size caps how many rolls fire in parallel. Creates a silent
-- batch (no history snapshot / no RAID_WARNING on completion -- background drips shouldn't
-- masquerade as a full Start-Rolls run). If a batch is already running, appends to its queue.
function addon:EnqueueAutoStartLots(lotIds)
    if not lotIds or #lotIds == 0 then return end
    local batchSize = tonumber(self.db and self.db.options and self.db.options.rollBatchSize) or 5
    if batchSize < 1 then batchSize = 1 end
    if not self._rollBatch then
        self._rollBatch = { queue = {}, batchSize = batchSize, active = {}, silent = true }
    end
    for _, id in ipairs(lotIds) do
        self._rollBatch.queue[#self._rollBatch.queue + 1] = id
    end
    self:AdvanceRollBatch()
end

function addon:FinishRollBatch()
    local session = self:GetCurrentSession()
    local silent = self._rollBatch and self._rollBatch.silent
    self._rollBatch = nil

    if silent then
        self:BroadcastSession()
        self:TriggerCallback("RESULTS_UPDATED")
        return
    end

    self.sessionDb.history = self.sessionDb.history or {}
    self.sessionDb.history[#self.sessionDb.history + 1] = {
        sessionId = session.id,
        timestamp = time(),
        results = util:CloneTable(self.lootView.results or {}),
    }

    local text = "All loot rolls finished, check the Results tab."
    local ctl = _G.ChatThrottleLib
    if ctl then
        ctl:SendChatMessage("ALERT", self.prefix, text, "RAID_WARNING")
    else
        SendChatMessage(text, "RAID_WARNING")
    end

    self:BroadcastSession()
    self:TriggerCallback("RESULTS_UPDATED")
    self:Print("Rolls complete.")
end
