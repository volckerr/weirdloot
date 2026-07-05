-- GuildRoster: derives roster data from the live guild instead of the shipped defaults, so
-- leadership edits rosters in-game (promote a rank, edit an officer note) and every client
-- converges without an addon update.
--
-- Status comes from the guild rank INDEX (0-based, as GetGuildRosterInfo reports it):
-- config.guildAltRankIndex is the Alt rank (bottom tier), config.guildDesignatedAltRankIndex
-- the designated-alt rank; every other rank, and every non-guildie guest, counts as main.
-- Trial has no precedence tier of its own yet, so it lands on main like the rest.
--
-- The officer note carries per-member data in its TRAILING comma fields; everything before
-- them stays free text. Two kinds of token, in either order, each optional:
--   spec:   exactly 3 letters, validated against the member's class ("raid lead,aff")
--   status: dalt / alt / main -- overrides the rank-derived status, for members whose rank
--           can't express it (a guild master or loot-council rank who is actually somebody's
--           designated alt: "my officer note,dalt,blo")
-- Only the last two fields are examined and tokens must validate, so ordinary note text can
-- never false-positive. Officer-note READ access is rank-gated client-side; the scan records
-- canViewNotes so a non-officer ML knows to request the note data from an online officer over
-- comms instead of trusting its own blank reads.

local addon = WeirdLoot
local util = addon.util

-- 3-letter spec tokens, unique within class (cross-class collisions like pro/hol/fro/res are
-- fine: the class always comes from the guild roster). Values are the full spec names the
-- roster and prio matchers already use, so a parsed token feeds matchKeys unchanged.
addon.specTokens = {
    ["warrior"]      = { arm = "arms", fur = "fury", pro = "protection" },
    ["paladin"]      = { hol = "holy", pro = "protection", ret = "retribution" },
    ["hunter"]       = { bst = "beast mastery", mrk = "marksmanship", srv = "survival" },
    ["rogue"]        = { ass = "assassination", com = "combat", sub = "subtlety" },
    ["priest"]       = { dis = "discipline", hol = "holy", sha = "shadow" },
    ["death knight"] = { blo = "blood", fro = "frost", unh = "unholy" },
    ["shaman"]       = { ele = "elemental", enh = "enhancement", res = "restoration" },
    ["mage"]         = { arc = "arcane", fir = "fire", fro = "frost" },
    ["warlock"]      = { aff = "affliction", dem = "demonology", des = "destruction" },
    ["druid"]        = { bal = "balance", fer = "feral", res = "restoration" },
}

-- Status-override tokens. "alt" here means the bottom tier (the Alt-rank equivalent), unlike
-- the roster-import wording where "alt" reads as designatedalt; officers write dalt for that.
local statusTokens = {
    dalt = "designatedalt",
    alt  = "nil",
    main = "main",
}
addon.noteStatusTokens = statusTokens

-- Split a note into (freeText, specName, statusOverride) by consuming validated tokens from
-- the END, at most one of each kind, stopping at the first non-token field. Everything not
-- consumed is the free text, byte-preserved, which is what lets the dropdown writer edit
-- tokens without touching whatever leadership keeps in the note.
function addon:SplitOfficerNote(officerNote, className)
    local tokens = self.specTokens[self:NormalizeClassName(className or "")]
    local fields = util:Split(officerNote or "", ",")
    local specName, statusOverride = "", nil
    local consumed = 0

    for i = #fields, math.max(1, #fields - 1), -1 do
        local key = util:NormalizeKey(fields[i])
        if tokens and tokens[key] and specName == "" then
            specName = tokens[key]
            consumed = consumed + 1
        elseif statusTokens[key] and statusOverride == nil then
            statusOverride = statusTokens[key]
            consumed = consumed + 1
        else
            break
        end
    end

    local freeText = table.concat(fields, ",", 1, #fields - consumed)
    return freeText, specName, statusOverride
end

-- Token read: full spec name ("" when absent; such a member behaves like a guest and matches
-- only class-only and rest prio tiers) plus the status override (nil when absent).
function addon:ParseOfficerNote(officerNote, className)
    local _, specName, statusOverride = self:SplitOfficerNote(officerNote, className)
    return specName, statusOverride
end

-- Canonical writer: free text first, then status, then spec ("my officer note,dalt,blo").
-- Inverse of SplitOfficerNote for any tokens it would consume.
function addon:ComposeOfficerNote(freeText, statusToken, specToken)
    local parts = {}
    if (freeText or "") ~= "" then parts[#parts + 1] = freeText end
    if statusToken and statusToken ~= "" then parts[#parts + 1] = statusToken end
    if specToken and specToken ~= "" then parts[#parts + 1] = specToken end
    return table.concat(parts, ",")
end

-- Reverse lookups for the dropdown UI: current parsed values -> the tokens that produce them.
function addon:SpecTokenFor(className, specName)
    local tokens = self.specTokens[self:NormalizeClassName(className or "")]
    local wanted = util:NormalizeKey(specName or "")
    if not tokens or wanted == "" then
        return nil
    end
    for token, name in pairs(tokens) do
        if name == wanted then
            return token
        end
    end
    return nil
end

function addon:StatusTokenFor(statusValue)
    for token, value in pairs(statusTokens) do
        if value == statusValue then
            return token
        end
    end
    return nil
end

-- Rank index -> status. 0-based as the API reports it (0 = guild master). The special
-- indices come from config so a ladder reshuffle is a settings edit, not a code change.
-- Defaults match the guild's live ladder: 2 = officer alts (Alt tier), 5 = Designated Alt,
-- 6 = Raider (main), 7 = Alt. Every other rank (GM, officers, loot council, Trial, ...) is
-- "unknown" unless the officer note carries an explicit status token; a note override always
-- wins over the rank.
function addon:GuildRankStatus(rankIndex)
    local cfg = self.config or {}
    local altIndex = tonumber(cfg.guildAltRankIndex) or 7
    local officerAltIndex = tonumber(cfg.guildOfficerAltRankIndex) or 2
    local daltIndex = tonumber(cfg.guildDesignatedAltRankIndex) or 5
    local mainIndex = tonumber(cfg.guildMainRankIndex) or 6
    if rankIndex == altIndex or rankIndex == officerAltIndex then
        return "nil"
    elseif rankIndex == daltIndex then
        return "designatedalt"
    elseif rankIndex == mainIndex then
        return "main"
    end
    return "unknown"
end

-- Scan the guild roster into name -> { name, className, specName, status, rankName, rankIndex,
-- online }. Kept separate from self.roster (raid attendance): this is the candidate pool the
-- profile lookup will draw from, refreshed on GUILD_ROSTER_UPDATE. Also records the observed
-- rank ladder (index -> name) so /wl guild can show it for verifying the two config indices.
function addon:RefreshGuildRoster()
    if not (IsInGuild and IsInGuild()) then
        self.guildRoster = nil
        return
    end

    local canViewNotes = (CanViewOfficerNote and CanViewOfficerNote()) and true or false
    local members = {}
    local rankNames = {}
    -- No args in 3.3.5: whether offline members are counted follows SetGuildRosterShowOffline
    -- (set true in RequestGuildRoster).
    local count = (GetNumGuildMembers and GetNumGuildMembers()) or 0

    -- A blind client substitutes the relayed note data (see the relay section below) so specs
    -- and overrides survive not having note permission; live reads always win when available.
    local cache = (not canViewNotes) and self:GetGuildNotesCache() or nil

    for index = 1, count do
        local name, rankName, rankIndex, _, classLocalized, _, _, officerNote, online, _, classFileName = GetGuildRosterInfo(index)
        if name then
            name = string.match(name, "^[^-]+") or name
            local nameKey = util:NormalizeKey(name)
            local className = self:NormalizeClassName(classFileName or classLocalized or "")
            local specName, statusOverride = "", nil
            local noteDataAvailable = canViewNotes
            if canViewNotes then
                specName, statusOverride = self:ParseOfficerNote(officerNote, className)
            elseif cache and cache.notes and cache.notes[nameKey] then
                specName = cache.notes[nameKey].s or ""
                statusOverride = cache.notes[nameKey].o
                noteDataAvailable = true
            end
            members[nameKey] = {
                noteDataAvailable = noteDataAvailable,   -- gates override auto-clear: rank alone is never evidence enough
                name = name,
                className = className,
                specName = specName,
                noteStatus = statusOverride,   -- kept apart from status: the relay payload sends overrides, not rank-derived values
                status = statusOverride or self:GuildRankStatus(rankIndex),
                rankName = rankName,
                rankIndex = rankIndex,
                online = online and true or false,
            }
            if rankIndex ~= nil then
                rankNames[rankIndex] = rankName
            end
        end
    end

    -- A scan is FULL only when it belongs to one of our own borrow cycles (we forced the
    -- show-offline filter on before requesting, so the listing provably includes offline
    -- members). The getter cannot be trusted as the signal: flipping the Blizzard checkbox
    -- fires GUILD_ROSTER_UPDATE mid-transition, and misreading a filtered list as full
    -- wholesale-drops every offline member. Non-borrow scans always merge; members who left
    -- the guild are dropped by the next borrow (login, session start, /wl guild).
    local fullScan = self.guildScanRestore ~= nil
    if not fullScan and self.guildRoster and self.guildRoster.members then
        for nameKey, existing in pairs(self.guildRoster.members) do
            if not members[nameKey] then
                existing.online = false
                members[nameKey] = existing
            end
        end
        for rankIndex, rankName in pairs(self.guildRoster.rankNames or {}) do
            if rankNames[rankIndex] == nil then
                rankNames[rankIndex] = rankName
            end
        end
    end

    self.guildRoster = {
        members = members,
        canViewNotes = canViewNotes,
        memberCount = count,
        rankNames = rankNames,
    }

    -- End of a borrow cycle: put the player's roster view filter back the way it was.
    if self.guildScanRestore then
        local restore = self.guildScanRestore
        self.guildScanRestore = nil
        if SetGuildRosterShowOffline and not restore.showOffline then
            SetGuildRosterShowOffline(false)
        end
    end

    self:AutoClearMatchedOverrides()
    -- Note-readers never write the cache: they serve requests straight from the live scan
    -- and are never blind themselves. Only a requester receiving GNOTES persists it
    -- (OnGuildNotesData) -- one writer, so the cache always means "what the relay last sent
    -- ME", not whatever client happened to scan last (which muddied a shared-SV multibox).
    self:TriggerCallback("GUILD_ROSTER_REFRESHED")
end

-- Overrides exist to correct the durable sources until they catch up; once rank+note derive
-- the same value, the override is pure liability (it would silently outvote the NEXT note or
-- rank change). Auto-clear per-field after each scan, but only for members whose scan carried
-- actual note data (live read or a relay-cache hit): a blind rank-only derivation could
-- coincidentally match while a hidden note token disagrees. No broadcast: every client that
-- sees the matching note computes the same clear; a blind client keeps the override, which is
-- behaviorally identical while the values match and converges on its next relay.
function addon:AutoClearMatchedOverrides()
    local overrides = self.config and self.config.rosterOverrides
    if not overrides or not (self.guildRoster and self.guildRoster.members) then
        return
    end

    local cleared = 0
    for nameKey, override in pairs(overrides) do
        local member = self.guildRoster.members[nameKey]
        if member and member.noteDataAvailable then
            local keepSpec = override.specName
            local keepStatus = override.status
            if keepSpec and member.specName == keepSpec then
                keepSpec = nil
            end
            -- member.status is the durable derivation (note token, else rank).
            if keepStatus and member.status == keepStatus then
                keepStatus = nil
            end
            if keepSpec ~= override.specName or keepStatus ~= override.status then
                cleared = cleared + 1
                if not keepSpec and not keepStatus then
                    overrides[nameKey] = nil
                else
                    overrides[nameKey] = { name = override.name, specName = keepSpec, status = keepStatus }
                end
            end
        end
    end

    if cleared > 0 then
        self.config.revision = (self.config.revision or 0) + 1
        self:TriggerCallback("CONFIG_UPDATED")
        self:Print(string.format("Roster: %d override%s cleared (now matching note/rank).",
            cleared, cleared == 1 and "" or "s"))
    end
end

-- Roster-edit authority beyond the ML: guild rank at or above (numerically at or below)
-- config.guildLeadershipMaxRankIndex. Default 4 = everything above the Designated Alt rank
-- (index 5), so GM/officer/loot-council ranks qualify without listing them.
function addon:IsGuildLeadership(playerName)
    local profile = self:GetGuildMemberProfile(playerName)
    if not profile or profile.rankIndex == nil then
        return false
    end
    local maxIndex = tonumber(self.config and self.config.guildLeadershipMaxRankIndex) or 4
    return profile.rankIndex <= maxIndex
end

function addon:GetGuildMemberProfile(playerName)
    local roster = self.guildRoster
    if not roster or not playerName then
        return nil
    end
    return roster.members[util:NormalizeKey(playerName)]
end

-- Ask the server for guild data (throttled server-side; the reply fires GUILD_ROSTER_UPDATE,
-- which is where the scan actually runs). Offline members must be included (absent raiders
-- still resolve profiles), but show-offline is the PLAYER'S roster view filter, so this is a
-- borrow: remember their setting, flip on for the capture, and RefreshGuildRoster restores it
-- once the reply lands.
function addon:RequestGuildRoster()
    if not (IsInGuild and IsInGuild()) then
        return
    end
    if SetGuildRosterShowOffline and GetGuildRosterShowOffline then
        if not self.guildScanRestore then
            self.guildScanRestore = { showOffline = GetGuildRosterShowOffline() and true or false }
        end
        SetGuildRosterShowOffline(true)
    end
    if GuildRoster then
        GuildRoster()
    end
end

-- ---- officer-note relay ----
-- Note READ permission is rank-gated, and only some clients (officers) have it. Instead of
-- loosening guild permissions, a blind client asks the guild: GNOTES_REQ goes out on the GUILD
-- channel, and any online member who can read notes whispers back GNOTES with the parsed
-- name -> { s = spec, o = status-override } map. The reply lands in an account-wide
-- SavedVariables cache consumed by RefreshGuildRoster, so with no officer online a session
-- degrades to the cached (possibly stale) data instead of blank specs. Multiple repliers are
-- fine: payloads are identical, last write wins.

-- The relayable subset of the current scan: members whose note carries a spec or an override.
-- nil when this client cannot read notes (nothing trustworthy to serve).
function addon:BuildGuildNotesPayload()
    local roster = self.guildRoster
    if not roster or not roster.canViewNotes then
        return nil
    end
    local notes = {}
    for nameKey, member in pairs(roster.members) do
        if member.specName ~= "" or member.noteStatus then
            notes[nameKey] = {
                s = member.specName ~= "" and member.specName or nil,
                o = member.noteStatus,
            }
        end
    end
    return notes
end

function addon:StoreGuildNotesCache(notes, from)
    if not self.db then return end
    self.db.guildNotesCache = {
        at = (time and time()) or 0,
        from = from,
        notes = notes or {},
    }
end

function addon:GetGuildNotesCache()
    return self.db and self.db.guildNotesCache or nil
end

function addon:RequestGuildNotes()
    if not self.comm then return end
    if not self.guildRoster or self.guildRoster.canViewNotes then return end
    self.comm:Send({ "GNOTES_REQ" }, "GUILD", nil, "BULK")
    self:LogCoreEvent("send", { cmd = "GNOTES_REQ", dist = "GUILD" })
end

function addon:OnGuildNotesRequest(sender)
    local payload = self:BuildGuildNotesPayload()
    if not payload or not self.comm then return end   -- blind ourselves: nothing to serve
    self.comm:Send({ "GNOTES", payload }, "WHISPER", sender, "BULK")
    self:LogCoreEvent("send", { cmd = "GNOTES", dist = "WHISPER" })
end

function addon:OnGuildNotesData(sender, notes)
    if type(notes) ~= "table" then return end
    -- Note data must come from a guildmate: a non-member whisper can't be carrying officer
    -- notes we'd want. (Membership is the strongest check available remotely: note-READ
    -- permission itself isn't queryable for other players.)
    if not self:GetGuildMemberProfile(sender) then return end
    self:StoreGuildNotesCache(notes, sender)
    self:RefreshGuildRoster()
    if self.roster then
        self:RefreshRoster()
    end
end

function addon:GUILD_ROSTER_UPDATE()
    self:RefreshGuildRoster()
    -- Attendee profiles resolve through GetRosterProfile, which prefers guild data: a rank or
    -- note edit must re-derive the raid roster, not wait for the next RAID_ROSTER_UPDATE.
    if self.roster then
        self:RefreshRoster()
    end
end
