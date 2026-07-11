local addon = WeirdLoot
local util = addon.util

function addon:InitializeRoster()
    self.roster = {
        attendees = {},
        attendeesByName = {},
        rosterDisplay = {},
        isLootMaster = false,
        lootMasterName = nil,
    }
end

function addon:RefreshRoster()
    local attendees = {}
    local attendeesByName = {}
    local count = GetNumRaidMembers() or 0

    for index = 1, count do
        local name, _, _, _, classLocalized, classFileName = GetRaidRosterInfo(index)
        name = name and string.match(name, "^[^-]+") or name
        if name then
            local profile = self:GetRosterProfile(name) or {}
            local className = profile.className or self:NormalizeClassName(classFileName or classLocalized or "")
            local specName = profile.specName or ""
            -- No profile anywhere (not guild, not guest layer) = an unhandled guest: status is
            -- genuinely unknown, distinct from the deliberate bottom tier ("nil" = Alt).
            local status = profile.status or "unknown"

            local attendee = {
                index = index,
                name = name,
                className = className,
                specName = specName,
                status = status,
                descriptor = util:NormalizeKey((className or "") .. " " .. (specName or "")),
            }
            attendees[#attendees + 1] = attendee
            attendeesByName[util:NormalizeKey(name)] = attendee
        end
    end

    util:SortByName(attendees, "name")

    self.roster.attendees = attendees
    self.roster.attendeesByName = attendeesByName
    self.roster.rosterDisplay = self:BuildRosterDisplay(attendeesByName)

    self:TriggerCallback("ROSTER_UPDATED")
end

function addon:BuildRosterDisplay(attendeesByName)
    local display = {}
    local seen = {}

    -- The guild IS the roster: every guild member gets a row, showing the same merged profile
    -- resolution uses (rank/note-derived status and spec, configured spec filling a blank
    -- note), so what the tab shows is what the resolver would do.
    local guildMembers = (self.guildRoster and self.guildRoster.members) or {}
    for key, member in pairs(guildMembers) do
        local profile = self:GetRosterProfile(member.name) or member
        display[#display + 1] = {
            name = member.name,
            className = profile.className,
            specName = profile.specName,
            status = profile.status,
            present = attendeesByName[key] ~= nil,
            descriptor = util:NormalizeKey((profile.className or "") .. " " .. (profile.specName or "")),
            source = "guild",
            overriddenSpec = profile.overriddenSpec,
            overriddenStatus = profile.overriddenStatus,
        }
        seen[key] = true
    end

    -- Configured entries that aren't guildies: the guest/override layer.
    for _, entry in ipairs(self:GetRosterEntries()) do
        local key = util:NormalizeKey(entry.name)
        if not seen[key] then
            local attendee = attendeesByName[key]
            display[#display + 1] = {
                name = entry.name,
                className = entry.className,
                specName = entry.specName,
                status = entry.status,
                present = attendee ~= nil,
                descriptor = entry.descriptor,
                source = "configured",
            }
            seen[key] = true
        end
    end

    for key, attendee in pairs(attendeesByName or {}) do
        if not seen[key] then
            display[#display + 1] = {
                name = attendee.name,
                className = attendee.className,
                specName = attendee.specName,
                status = attendee.status or "nil",
                present = true,
                descriptor = attendee.descriptor,
                source = "unconfigured",
            }
        end
    end

    -- A guest is a present player the guild doesn't know with no spec assigned yet: the
    -- entries leadership still has to handle. The Raiders tab floats them to the top until a
    -- spec lands (via the add flow or a GUEST_UPSERT), at which point they sort normally.
    for _, entry in ipairs(display) do
        entry.isGuest = entry.present
            and not (self.GetGuildMemberProfile and self:GetGuildMemberProfile(entry.name))
            and (entry.specName or "") == ""
        -- Underspecified RAID member: blank spec silently drops them out of spec-prio tiers
        -- (exact-key matcher) and unknown status means nobody assigned them. The tab floats,
        -- tints, and badges these until leadership fills the data (the chosen alternative to
        -- softening the resolver).
        entry.needsAttention = (entry.present
            and (entry.status == "unknown" or (entry.specName or "") == "")) and true or false
    end

    table.sort(display, function(left, right)
        if left.present ~= right.present then
            return left.present
        end
        if left.source ~= right.source then
            return left.source == "configured"
        end
        return util:NormalizeKey(left.name) < util:NormalizeKey(right.name)
    end)

    return display
end

function addon:GetAttendees()
    return self.roster.attendees or {}
end

function addon:GetAttendee(name)
    return self.roster.attendeesByName[util:NormalizeKey(name or "")]
end

function addon:GetRosterDisplayList()
    return self.roster.rosterDisplay or {}
end

-- Determine the master looter's name and whether *we* drive WeirdLoot, robustly across
-- every group shape (mirrors RCLootCouncil's GetML): raid master-loot, party master-loot,
-- raid leader/assistant, party leader, and solo. The leadership fallback only applies when
-- no master looter is set, matching RCLootCouncil (under master loot, only the ML runs it).
function addon:RefreshLootAuthority()
    local playerName = util:GetPlayerName("player")
    local method, partyMasterIndex, raidMasterIndex = GetLootMethod()
    local numRaid = GetNumRaidMembers() or 0
    local numParty = GetNumPartyMembers() or 0

    -- 1) who is the master looter?
    local lootMasterName
    if method == "master" then
        -- Raid takes the master-looter index from the raid roster. The party-ML fallback below is
        -- gated on numParty > 0 AND numRaid == 0 so it ONLY fires in an actual 5-man party, never
        -- during the post-relog raid race where the API transiently reports partyMasterIndex == 0
        -- before the raid roster loads (in that race numRaid is also 0 but so is numParty -- we
        -- have no group at all -- which the gate rejects, blocking the ex-ML self-claim).
        if raidMasterIndex and raidMasterIndex > 0 then
            lootMasterName = util:StripRealm(GetRaidRosterInfo(raidMasterIndex))   -- ML in raid
        elseif numRaid == 0 and numParty > 0 then
            if partyMasterIndex == 0 then
                lootMasterName = playerName                                        -- we are party ML
            elseif partyMasterIndex and partyMasterIndex > 0 then
                lootMasterName = util:StripRealm(UnitName("party" .. partyMasterIndex)) -- party member ML
            end
        end
    end

    -- 2) are we leadership (or solo)?
    local isLeader = false
    if numRaid > 0 then
        for index = 1, numRaid do
            local name, rank = GetRaidRosterInfo(index)
            if playerName and name and util:NormalizeKey(util:StripRealm(name)) == util:NormalizeKey(playerName) then
                isLeader = (rank == 2) or (rank == 1)    -- raid leader or assistant
                break
            end
        end
    elseif numParty > 0 then
        isLeader = IsPartyLeader() and true or false     -- party leader
    else
        -- Solo: only act as loot master in explicit test mode (city testing). Otherwise a
        -- normal member logged in alone would wrongly think they're the ML and could
        -- whisper / auto-trade raiders.
        isLeader = (self.db and self.db.testMode) and true or false
    end

    -- 3) resolve authority
    local isLootMaster = false
    if lootMasterName and playerName then
        isLootMaster = util:NormalizeKey(lootMasterName) == util:NormalizeKey(playerName)
    end

    -- Leadership fallback, TEST MODE ONLY. WeirdLoot's job is trading out master-looted BoP, so the
    -- only loot method it has authority over is "master". Under group / round-robin / free-for-all /
    -- need-before-greed, loot goes straight to individuals and the leader has nothing to distribute, so
    -- treating the leader as master looter there is a false positive. The only legitimate non-master
    -- case is city/buddy testing (testMode), where there is no real ML but we still drive a session.
    local testMode = self.db and self.db.testMode
    if not isLootMaster and isLeader and method ~= "master" and testMode then
        isLootMaster = true
    end

    if not lootMasterName and isLeader and testMode then
        lootMasterName = playerName
    end

    -- ML LOAN pin: while an item-scoped loan is active (MLLoan.lua), the WoW roster names the
    -- BORROWER as master looter, but the addon session must stay with the loan's OWNER: authority
    -- and the displayed ML both pin to the owner. This is what keeps the borrower from assuming
    -- the session (the false->true transition below never fires for them) and keeps every raider
    -- from seeing an ML change at all. Older clients without the loan field degrade to following
    -- the roster.
    local loan = self.ActiveMLLoan and self:ActiveMLLoan() or nil
    if loan then
        lootMasterName = loan.owner
        isLootMaster = playerName ~= nil and util:NormalizeKey(loan.owner) == util:NormalizeKey(playerName)
    end

    -- "Roster unreadable": master loot is on with partyMasterIndex == 0 (the API flags US as ML), but
    -- GetRaidRosterInfo cannot name our raid index yet, so the name-match above cannot confirm us and
    -- isLootMaster stays false. We flag and warn on this, but never self-grant from it: partyMasterIndex
    -- == 0 cannot tell the real ML from a relogging ex-ML, and raid-leader/assistant is a different role
    -- from master-looter (the ML can be a plain member). Authority stays on the roster name-match alone.
    local nameAtML = (raidMasterIndex and raidMasterIndex > 0) and GetRaidRosterInfo(raidMasterIndex) or nil

    local wasLootMaster = self.roster.isLootMaster
    local prevMasterName = self.roster.lootMasterName
    self.roster.lootMasterName = lootMasterName
    self.roster.isLootMaster = isLootMaster
    self.roster.mlRosterUnreadable = self:RosterUnreadableForML(method, partyMasterIndex, raidMasterIndex, nameAtML)

    if self.roster.mlRosterUnreadable then
        -- The unreadable flag is true on EVERY login for a moment (the roster simply hasn't arrived
        -- yet), so suppress the warning until bags settle (~5s) -- by then a normal login has recovered
        -- and the flag is gone. If it is STILL set past settle, the server has genuinely failed to send
        -- our roster row this session (rare). There is no API to re-request the member roster, so the
        -- only repair is /reload, which reconnects the UI and pulls a fresh roster. Hence the message.
        local settled = self.bagSettleAt and (GetTime() >= self.bagSettleAt)
        if settled and not self._rosterReloadWarned then
            self._rosterReloadWarned = true
            self:Print("|cffff4040The raid roster failed to load; loot-master controls are disabled until you /reload.|r")
        end
    else
        self._rosterReloadWarned = nil
    end

    -- the core needs the ML identity to decide self-win (resolved) vs owed at resolve time
    if self.lootCore then self.lootCore:SetML(lootMasterName) end

    -- Gaining confirmed loot-master authority over a session we were mirroring: continue it under a
    -- fresh epoch so the current ML always holds the newest epoch (a stale/older session can never
    -- out-rank us). Only a false->true transition fires it, so the event/retry re-runs do not re-mint.
    if isLootMaster and not wasLootMaster then
        self:AssumeLootMasterSession()
        -- A blind ML needs the officer-note map (spec/status tokens) for resolution; ask the
        -- guild the moment authority lands, so a mid-raid ML swap doesn't wait for the next
        -- session start. No-op for note-readers and non-guildies (guards in RequestGuildNotes).
        if self.RequestGuildNotes then
            self:RequestGuildNotes()
        end
    end

    -- A raider that just learned (or changed) who the loot master is -- e.g. the raid roster finally
    -- loaded a beat after a fresh login -- must pull the session at once. Without this it sits idle
    -- until the ML's next heartbeat (up to the ~30s heartbeat period) reveals it is behind. Only the
    -- nil/changed transition fires it, so steady re-resolves on roster churn do not re-request.
    if not isLootMaster and lootMasterName and lootMasterName ~= ""
        and util:NormalizeKey(lootMasterName) ~= util:NormalizeKey(prevMasterName or "") then
        self:RequestSessionSync()
    end

    -- ML loan popups for the raid leader (no-op for everyone else; transition-tracked inside)
    if self.MaybePromptLeaderLoanSwap then self:MaybePromptLeaderLoanSwap() end

    self:TriggerCallback("AUTHORITY_UPDATED")
end

-- Pure predicate (unit-testable): the loot method points at a raid master looter that the
-- (unloaded, post-relog) raid roster cannot name, while the API still flags US as that ML.
function addon:RosterUnreadableForML(method, partyMasterIndex, raidMasterIndex, nameAtRaidML)
    return method == "master"
        and raidMasterIndex ~= nil and raidMasterIndex > 0
        and nameAtRaidML == nil
        and partyMasterIndex == 0
end

function addon:IsAuthorizedLootMaster()
    return self.roster.isLootMaster
end

-- Roster-edit authority: guild leadership (officer ranks) ONLY. Deliberately narrower than
-- loot authority -- the ML is often not an officer and asks one to fix roster data; raid
-- leadership confers nothing here. The single source for every edit surface (Raiders tab
-- menus, minimap attention alert) and mirrored by the comm receive gates.
function addon:CanEditRoster()
    return self:IsGuildLeadership(util:GetPlayerName("player"))
end

-- The raid members whose roster data still needs leadership attention, with WHAT is missing
-- broken out (feeds the minimap tooltip and any future nag surface).
function addon:GetRosterAttentionList()
    local list = {}
    for _, entry in ipairs(self:GetRosterDisplayList()) do
        if entry.needsAttention then
            list[#list + 1] = {
                name = entry.name,
                className = entry.className,
                missingSpec = (entry.specName or "") == "",
                unknownStatus = entry.status == "unknown",
            }
        end
    end
    return list
end

function addon:GetLootMasterName()
    return self.roster.lootMasterName
end

-- Is there a loot master in play at all? True when the group is on master loot with a resolved ML
-- (or a session snapshot has named one). False means no one is managing loot -- the minimap icon
-- desaturates to signal WeirdLoot is idle.
function addon:IsLootMasterActive()
    local ml = self.roster.lootMasterName
    return ml ~= nil and ml ~= ""
end

-- The master looter's UNIT token, straight from the loot method. 3.3.5a can't target by name from addon
-- code (TargetByName removed, TargetUnit protected), but InitiateTrade / UnitClass take a unit, so this
-- is how we trade or read the ML. nil unless the group is on master loot.
function addon:GetLootMasterUnit()
    local method, partyML, raidML = GetLootMethod()
    if method ~= "master" then return nil end
    if raidML and raidML > 0 then return "raid" .. raidML end   -- raid: ML's raid index
    if partyML == 0 then return "player" end                    -- party: 0 means we are the ML
    if partyML and partyML > 0 then return "party" .. partyML end
    return nil
end

function addon:GetPlayerDescriptor(playerName)
    local attendee = self:GetAttendee(playerName) or self:GetRosterProfile(playerName)
    if not attendee then
        return ""
    end

    local className = attendee.className or ""
    local specName = attendee.specName or ""
    return util:NormalizeKey(className .. " " .. specName)
end
