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
-- How long a borrow may wait for its GUILD_ROSTER_UPDATE before the watchdog returns the
-- player's filter anyway. Repeat GuildRoster() calls inside the server's ~10s throttle window
-- are silently eaten (login then session-start requests back-to-back), so a borrow can be
-- left with no reply ever coming.
local GUILD_SCAN_BORROW_TIMEOUT = 3

-- SetGuildRosterShowOffline dispatches GUILD_ROSTER_UPDATE SYNCHRONOUSLY (proven by an
-- in-game stack trace re-entering our handler mid-call), and that re-entrant scan sees stale
-- data and used to consume the borrow before its real reply. All writes go through here: the
-- flag is up only for the duration of the C call, so the handler can drop exactly the bogus
-- re-entrant dispatches and nothing else.
local function writeShowOffline(self, value)
    if not SetGuildRosterShowOffline then return end
    self._guildFilterWriting = true
    SetGuildRosterShowOffline(value)
    self._guildFilterWriting = nil
end

-- Close a borrow: put the player's roster filter back and clear the pending record.
local function closeGuildScanBorrow(self, why)
    local restore = self.guildScanRestore
    if not restore then return end
    self.guildScanRestore = nil
    local wroteOff = false
    if SetGuildRosterShowOffline and not restore.showOffline then
        writeShowOffline(self, false)
        wroteOff = true
    end
    self:LogCoreEvent("gshow", { op = "close", why = why or "?",
        captured = restore.showOffline and 1 or 0, wroteOff = wroteOff and 1 or 0 })
end

function addon:RefreshGuildRoster()
    if not (IsInGuild and IsInGuild()) then
        -- A transiently unreadable guild state must not strand a pending borrow with the
        -- player's filter flipped.
        closeGuildScanBorrow(self, "noguild")
        self.guildRoster = nil
        return
    end

    local canViewNotes = (CanViewOfficerNote and CanViewOfficerNote()) and true or false
    local members = {}
    local rankNames = {}
    -- No args in 3.3.5: whether offline members are listed follows the show-offline filter,
    -- which RequestGuildRoster borrows on (the filter is NOT synchronous: reads only reflect
    -- a change after the server's next roster update, so same-call flip-and-read captures
    -- the stale filtered list).
    local count = (GetNumGuildMembers and GetNumGuildMembers()) or 0

    -- A blind client substitutes the relayed note data (see the relay section below) so specs
    -- and overrides survive not having note permission; live reads always win when available.
    local cache = (not canViewNotes) and self:GetGuildNotesCache() or nil
    local cacheHits = 0

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
                cacheHits = cacheHits + 1
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
    -- show-offline filter on before requesting, so this listing provably includes offline
    -- members). Other scans may be running against the player's own online-only view, so
    -- they merge over the previous map instead of replacing it: offline members captured by
    -- the last full scan survive, flagged offline. Leavers drop on the next borrow.
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
        -- Completeness is a mechanical fact only this client knows: a borrow cycle closed,
        -- so the map provably covered the whole guild at least once. Carried across partial
        -- merges; declared on served payloads so a blind ML can stamp its need fulfilled on
        -- fresher information than its own (possibly stale) map count.
        hadFullScan = fullScan or (self.guildRoster and self.guildRoster.hadFullScan) or false,
    }

    -- map/spec are post-merge: map is what the Roster tab counts and what a GNOTES payload
    -- iterates; spec is exactly the entry count a payload built right now would carry.
    local mapCount, specCount = 0, 0
    for _, member in pairs(members) do
        mapCount = mapCount + 1
        if member.specName ~= "" or member.noteStatus then
            specCount = specCount + 1
        end
    end
    self:LogCoreEvent("gscan", { n = count, borrow = self.guildScanRestore and 1 or 0,
        raw = (GetGuildRosterShowOffline and GetGuildRosterShowOffline()) and 1 or 0,
        view = canViewNotes and 1 or 0, cachehits = cacheHits,
        map = mapCount, spec = specCount })

    -- End of a borrow cycle: put the player's roster view filter back the way it was.
    closeGuildScanBorrow(self, "scan")

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

-- Watchdog tick, also driven directly by tests. Returns true when there is nothing left to
-- watch (no borrow pending, or it just expired and was closed).
function addon:TickGuildScanBorrow(now)
    local restore = self.guildScanRestore
    if not restore then
        return true
    end
    now = now or ((GetTime and GetTime()) or 0)
    if restore.expiresAt and now >= restore.expiresAt then
        closeGuildScanBorrow(self, "watchdog")
        return true
    end
    return false
end

local function armGuildScanWatchdog(self)
    if not CreateFrame then return end   -- out-of-game harness: tests drive TickGuildScanBorrow directly
    if not self._guildScanWatchdog then
        local frame = CreateFrame("Frame")
        frame:Hide()   -- hidden frames get no OnUpdate; Show() arms, Hide() disarms
        frame:SetScript("OnUpdate", function()
            if addon:TickGuildScanBorrow() then
                frame:Hide()
            end
        end)
        self._guildScanWatchdog = frame
    end
    self._guildScanWatchdog:Show()
end

-- Ask the server for guild data (throttled server-side; the reply fires GUILD_ROSTER_UPDATE,
-- which is where the scan actually runs). Offline members must be included (absent raiders
-- still resolve profiles), but show-offline is the PLAYER'S roster view filter, so this is a
-- borrow: remember their setting, flip on for the capture, and RefreshGuildRoster restores it
-- once the reply lands -- or the watchdog does, if the throttle ate the request.
function addon:RequestGuildRoster()
    if not (IsInGuild and IsInGuild()) then
        return
    end
    if SetGuildRosterShowOffline and GetGuildRosterShowOffline then
        local fresh = not self.guildScanRestore
        if fresh then
            self.guildScanRestore = { showOffline = GetGuildRosterShowOffline() and true or false }
        end
        -- Locals captured BEFORE the write: the synchronous dispatch (see writeShowOffline)
        -- must not be able to consume state this function still reads.
        local captured = self.guildScanRestore.showOffline
        self.guildScanRestore.expiresAt = ((GetTime and GetTime()) or 0) + GUILD_SCAN_BORROW_TIMEOUT
        armGuildScanWatchdog(self)
        writeShowOffline(self, true)
        self:LogCoreEvent("gshow", { op = "borrow", fresh = fresh and 1 or 0,
            captured = captured and 1 or 0 })
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

-- The full member map as the officer sees it: note-derived fields (s/o) plus the public
-- identity fields (nm/c/r), so a blind receiver can create rows outright for members its
-- own scan never captured (a failed login borrow leaves the map thin). Rank travels as
-- index only: both sides share the guild's ladder, so the receiver resolves the name from
-- its own rankNames. nil when this client cannot read notes (nothing trustworthy to serve).
function addon:BuildGuildNotesPayload()
    local roster = self.guildRoster
    if not roster or not roster.canViewNotes then
        return nil
    end
    local notes, n = {}, 0
    for nameKey, member in pairs(roster.members) do
        notes[nameKey] = {
            s = member.specName ~= "" and member.specName or nil,
            o = member.noteStatus,
            nm = member.name,
            c = member.className,
            r = member.rankIndex,
        }
        n = n + 1
    end
    return notes, n, roster.hadFullScan and true or false
end

-- Officers are authoritative: fold a received payload straight into the member map,
-- creating rows for members our own scan never captured. The post-receive scan cannot be
-- trusted to do this -- its listing follows the player's own (usually online-only)
-- filter, so most members never pass through the substitution loop (proven live:
-- 87 entries delivered, 2 applied, because the listing held 3 names at that moment).
-- Created rows start offline; presence is volatile and the next scan corrects it.
function addon:ApplyGuildNotesToRoster(notes)
    local roster = self.guildRoster
    if not roster or roster.canViewNotes then return 0 end   -- live reads always win
    local applied = 0
    for nameKey, entry in pairs(notes) do
        local member = roster.members[nameKey]
        if not member and entry.nm then
            member = {
                name = entry.nm,
                className = entry.c or "",
                rankIndex = entry.r,
                rankName = entry.r ~= nil and roster.rankNames[entry.r] or nil,
                online = false,
            }
            roster.members[nameKey] = member
        end
        if member then
            member.specName = entry.s or ""
            member.noteStatus = entry.o
            member.status = entry.o or self:GuildRankStatus(member.rankIndex)
            member.noteDataAvailable = true
            applied = applied + 1
        end
    end
    return applied
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

-- Guild-wide BACKUP retry while the session need stands (the primary triggers stay: the
-- one-shot authority-gain request and the snapshot need-flag at officer join). The
-- need-flag paths reach only raid members; an officer outside the raid, or one who logged
-- in after the one-shot request, is reachable only on GUILD. 30s cadence (matches the
-- sync heartbeat); the REQ line is ~20 bytes and responders skip unchanged re-serves, so
-- the standing poll is nearly free. Fulfillment (the OnGuildNotesData stamp) stops it.
function addon:MaybeRepollGuildNotes()
    if not (self.session and self.session.active) then return end
    if not (self.IsAuthorizedLootMaster and self:IsAuthorizedLootMaster()) then return end
    if not (self.SyncNeedsNotes and self:SyncNeedsNotes()) then return end
    local now = (GetTime and GetTime()) or 0
    if self._gnotesPollAt and now < self._gnotesPollAt + 30 then return end
    self._gnotesPollAt = now
    self:RequestGuildNotes()
end

-- Self-driving tick for the repoll (coarse: the 60s throttle above does the real pacing).
if CreateFrame then
    local poller = CreateFrame("Frame")
    local acc = 0
    poller:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 5 then return end
        acc = 0
        if addon and addon.MaybeRepollGuildNotes then addon:MaybeRepollGuildNotes() end
    end)
end

function addon:OnGuildNotesRequest(sender)
    local payload, n, full = self:BuildGuildNotesPayload()
    if not payload or not self.comm then   -- blind ourselves: nothing to serve
        self:LogCoreEvent("gnotes_skip", { why = "blind", to = sender or "?" })
        return
    end
    -- Serve on first ask or on improvement: a polling ML re-asks every 30s while its
    -- need stands, and re-whispering an unchanged payload each poll is pure waste. Size +
    -- completeness is signature enough: a borrow completing or membership changing alters
    -- it, which are exactly the improvements that could newly fulfill the ML.
    local sig = tostring(n) .. (full and "+f" or "")
    local key = util:NormalizeKey(sender or "")
    self._gnotesServedSig = self._gnotesServedSig or {}
    if self._gnotesServedSig[key] == sig then
        self:LogCoreEvent("gnotes_skip", { why = "unchanged", to = sender or "?" })
        return
    end
    self._gnotesServedSig[key] = sig
    self.comm:Send({ "GNOTES", payload, full and 1 or 0 }, "WHISPER", sender, "BULK")
    self:LogCoreEvent("send", { cmd = "GNOTES", dist = "WHISPER", n = n, full = full and 1 or 0 })
end

function addon:OnGuildNotesData(sender, notes, full)
    if type(notes) ~= "table" then
        self:LogCoreEvent("gnotes_recv", { from = sender or "?", ok = 0, why = "type" })
        return
    end
    -- Note data must come from a guildmate: a non-member whisper can't be carrying officer
    -- notes we'd want. (Membership is the strongest check available remotely: note-READ
    -- permission itself isn't queryable for other players.)
    if not self:GetGuildMemberProfile(sender) then
        self:LogCoreEvent("gnotes_recv", { from = sender or "?", ok = 0, why = "notguild" })
        return
    end
    local n = 0
    for _ in pairs(notes) do n = n + 1 end
    -- Fulfillment yardstick, measured BEFORE the apply (which can grow the map): the merged
    -- map preserves the login full-scan count across online-filtered partial listings, so it
    -- is the initial roster size; listing counts are unusable for this.
    local mapCount = 0
    if self.guildRoster and self.guildRoster.members then
        for _ in pairs(self.guildRoster.members) do mapCount = mapCount + 1 end
    end
    self:StoreGuildNotesCache(notes, sender)
    local applied = self:ApplyGuildNotesToRoster(notes)
    -- Fulfillment: the sender's completeness declaration wins when present (its map came
    -- from a completed full borrow scan: fresher membership truth than our own count, which
    -- goes stale the moment someone leaves the guild). Without it, fall back to comparing
    -- against our own map: a smaller payload is a thin serve (the sender's scan raced), so
    -- apply what came but keep the session need flying for a fuller serve.
    local fullServe = (full == 1 or full == "1" or full == true) and 1 or 0
    local stamped = 0
    if self.session and self.session.active and (fullServe == 1 or n >= mapCount) then
        self._gnotesSessionId = self.session.id
        stamped = 1
    end
    -- The payload table rides in the record by reference (safe: it is only ever replaced
    -- whole, never mutated), so the log itself answers WHICH members were delivered.
    self:LogCoreEvent("gnotes_recv", { from = sender or "?", ok = 1, n = n, applied = applied,
        map = mapCount, full = fullServe, stamped = stamped, notes = notes })
    self:RefreshGuildRoster()
    if self.roster then
        self:RefreshRoster()
    end
end

-- Officer side of the session need-flag: a snapshot whose meta says the ML lacks note data
-- is an implicit request, so a note-reading receiver whispers the map unprompted. Served at
-- most once per session epoch, with a cooldown so a re-flagged snapshot (lost whisper) can
-- retry without spamming every resync.
function addon:MaybeServeGuildNotes(mlName, epoch)
    if not mlName or mlName == "" then return end
    local payload, n, full = self:BuildGuildNotesPayload()
    if not payload or not self.comm then
        self:LogCoreEvent("gnotes_skip", { why = "blind", to = mlName })
        return
    end
    local now = (GetTime and GetTime()) or 0
    if self._gnotesServedEpoch == epoch and self._gnotesServedAt and now < self._gnotesServedAt + 60 then
        self:LogCoreEvent("gnotes_skip", { why = "cooldown", to = mlName })
        return
    end
    self._gnotesServedEpoch = epoch
    self._gnotesServedAt = now
    -- Shared signature with the REQ path: a guild poll landing right after this join-time
    -- serve must not whisper the identical payload again.
    self._gnotesServedSig = self._gnotesServedSig or {}
    self._gnotesServedSig[util:NormalizeKey(mlName)] = tostring(n) .. (full and "+f" or "")
    self.comm:Send({ "GNOTES", payload, full and 1 or 0 }, "WHISPER", mlName, "BULK")
    self:LogCoreEvent("send", { cmd = "GNOTES", dist = "WHISPER", why = "needflag", n = n, full = full and 1 or 0 })
end

function addon:GUILD_ROSTER_UPDATE()
    -- A dispatch arriving while one of our own filter writes is mid-call is the synchronous
    -- re-entrant kind: it describes the PRE-write list and consuming it would close the
    -- borrow before its real reply. Queued events arrive with the flag down.
    if self._guildFilterWriting then return end
    self:RefreshGuildRoster()
    -- Attendee profiles resolve through GetRosterProfile, which prefers guild data: a rank or
    -- note edit must re-derive the raid roster, not wait for the next RAID_ROSTER_UPDATE.
    if self.roster then
        self:RefreshRoster()
    end
end
