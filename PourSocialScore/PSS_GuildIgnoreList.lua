------------------------------------------------------------
-- POUR SOCIAL SCORE - GUILD IGNORE LIST
--
-- Guild rules, their captured members (scans / invites / units seen),
-- per-member allow flags, block history, the guild tab and members window,
-- and the "guild" person source the core (PSS_ChatBlock.lua) uses.
------------------------------------------------------------

local addonName, addon = ...
local M = addon.M
local V = addon.V
local L = addon.L -- localization entries

local Whois = M.Whois	-- /who sending, cooldown and answers (PSS_Whois.lua)

local trim				= M.PSS_Trim
local normalizePlayer = M.PSS_NormalizePlayer
local displayPlayer		= M.PSS_DisplayPlayer

local function normalizeGuild(name)
	if type(name) ~= "string" then return nil end
	name = trim(name)
	if name == "" then return nil end
	return name:lower()
end
M.PSS_NormalizeGuild = normalizeGuild

-- A guild row is a match key. Scans send g-"<row name>" to /who, and every
-- result is then checked here against the member's actual guild name. The
-- match is a case-insensitive "contains" on purpose: a row named "Olympus"
-- captures Olympus Tycoons, Olympus III and so on. When a more specific row
-- also exists ("Olympus Tycoons"), PSS_BestGuildRowFor gives the member to
-- that row instead.
local function guildMatches(rowName, actualGuild)
	rowName = normalizeGuild(rowName)
	actualGuild = normalizeGuild(actualGuild)
	if not rowName or not actualGuild then return false end
	return actualGuild:find(rowName, 1, true) ~= nil
end

local canonPlayer = M.PSS_CanonPlayer
local canonGuild	= M.PSS_CanonGuild
local isSecret		= M.PSS_IsSecret
local nowString		= M.PSS_NowString

local function classTokenFromInfo(infoClass)
	if not infoClass then return "" end
	if RAID_CLASS_COLORS and RAID_CLASS_COLORS[infoClass] then return infoClass end
	if LOCALIZED_CLASS_NAMES_MALE then
		for token, localized in pairs(LOCALIZED_CLASS_NAMES_MALE) do
			if localized == infoClass then return token end
		end
	end
	if LOCALIZED_CLASS_NAMES_FEMALE then
		for token, localized in pairs(LOCALIZED_CLASS_NAMES_FEMALE) do
			if localized == infoClass then return token end
		end
	end
	return infoClass
end

local function ensureDB()
	PourSocialScoreDB = PourSocialScoreDB or {}
	PourSocialScoreDB.playerData = PourSocialScoreDB.playerData or {}
	PourSocialScoreDB.guildData = PourSocialScoreDB.guildData or {}
	PourSocialScoreDB.imported = PourSocialScoreDB.imported or false
end
M.PSS_EnsureGuildDB = ensureDB

-- Forward declaration: PSS_UpgradeLegacyData runs after the file loads, so this
-- must refer to the local cleanup function declared later in this file.
local cleanupLegacyGuildPlayers

-- Capture player/guild metadata from target, mouseover, nameplates and group units.
-- Older builds referenced scanUnit from the event handler but never defined it,
-- which caused the login/mouseover nil-call errors.
-- Each player is looked at no more than once every SEEN_TTL seconds (keyed
-- by GUID), and nothing is done in combat: nameplates and mouseover fire
-- constantly there, and this information can wait. In combat the mouseover
-- and nameplate events are not even listened to (see the frame below).
local SEEN_TTL, SEEN_MAX = 120, 600
local seenGUID, seenCount = {}, 0

local function inCombat()
	if InCombatLockdown and InCombatLockdown() then return true end
	return UnitAffectingCombat ~= nil and UnitAffectingCombat("player") == true
end

local function scanUnit(unit)
	if not unit or not UnitExists or not UnitExists(unit) then return end
	if UnitIsPlayer and not UnitIsPlayer(unit) then return end
	if inCombat() then return end
	local guid = UnitGUID and UnitGUID(unit)
	if type(guid) ~= "string" or isSecret(guid) then return end
	local now = GetTime()
	local last = seenGUID[guid]
	if last and now - last < SEEN_TTL then return end
	if not last then
		seenCount = seenCount + 1
		if seenCount > SEEN_MAX then seenGUID, seenCount = {}, 1 end
	end
	seenGUID[guid] = now

	-- In instances the client can hand addons "secret" names; those can't be
	-- compared or stored, so the unit is skipped.
	local name, realm = UnitName(unit)
	if type(name) ~= "string" or isSecret(name) or name == "" then return end
	if realm ~= nil and (type(realm) ~= "string" or isSecret(realm)) then return end

	local fullName = name
	if realm and realm ~= "" and (not GetNormalizedRealmName or realm ~= GetNormalizedRealmName()) then
		fullName = name .. "-" .. realm
	end

	local guild = GetGuildInfo and GetGuildInfo(unit) or ""
	if type(guild) ~= "string" or isSecret(guild) then guild = "" end
	M.PSS_UpdatePlayerUnit(fullName, unit, guild)
end

-- Player-list metadata for listed players (PSS_PlayerIgnoreList.lua)
local function setPlayerMeta(name, unit, guild)
	return M.PSS_SetPlayerMeta and M.PSS_SetPlayerMeta(name, unit, guild)
end

local function memberKey(name)
	return normalizePlayer(name)
end

-- Custom Scan Fields: one free-text /who filter sent with the guild name.
-- Older saves had separate Start/End Level values; carry them over once as
-- "start-end" so the custom scan behaves the same.
function M.PSS_MigrateCustomScan(g)
	if type(g) ~= "table" then return end
	if type(g.customScan) ~= "string" then
		local lo, hi = tonumber(g.levelStart), tonumber(g.levelEnd)
		if not (lo and hi) then
			lo, hi = tostring(g.levelBrackets or ""):match("^(%d+)%s*%-%s*(%d+)$")
			lo, hi = tonumber(lo), tonumber(hi)
		end
		g.customScan = (lo and hi) and ("%d-%d"):format(lo, hi) or M.PSS_DEFAULT_SCAN_FIELDS
	end
	g.levelStart, g.levelEnd, g.levelBrackets = nil, nil, nil
end

------------------------------------------------------------------------
-- W I G P C EXCLUSIONS (per guild rule, optionally per member)
--   W whisper, I partyInvite, G guildInvite, P partyRaid, C world
--   (C = chat channels such as Trade/General/LFG/communities, plus say,
--    yell and emotes).
--    Stored as BLOCKED; the tickboxes show the inverse (ticked = allowed).
-- Guild:  g.block[cat] = true/false
-- Member: m.block[cat] = true/false, or nil = use the guild's setting
-- g.enabled is kept as a derived flag ("this rule blocks something"), which
-- the member index and scan code use.
------------------------------------------------------------------------
-- Scan Fields a new guild rule starts with (sent after g-"Guild" by Custom).
M.PSS_DEFAULT_SCAN_FIELDS = "1-60"

local EXCL_CATS = {}
M.PSS_EXCL_INFO = {}
for _, e in ipairs(M.EXCL) do				-- order and wording: PSS_Globals.lua
	EXCL_CATS[#EXCL_CATS + 1] = e.cat
	M.PSS_EXCL_INFO[e.cat] = { letter = e.letter, label = e.label }
end
M.PSS_EXCL_CATS = EXCL_CATS

-- The guild's flags; converts the pre-2.0.4 Filter / Guild Inv / Group Inv
-- settings the first time a rule is seen.
local function guildBlock(g)
	if type(g.block) ~= "table" then
		local on = g.enabled ~= false
		g.block = {
			whisper = on,
			partyInvite = on and g.declineGroup ~= false,
			guildInvite = on and g.declineGuild ~= false,
			partyRaid = on and g.partyRaid ~= false,
			world = on,
		}
	end
	for _, c in ipairs(EXCL_CATS) do g.block[c] = g.block[c] == true end
	return g.block
end
M.PSS_GuildBlock = guildBlock

-- The member's own flags (nil entries inherit); converts the old
-- Allow Whispers / Allow Group Invites / Allow Guild Invites / Allow All Chat.
-- Most members never get a choice of their own, so reading one that has no
-- flags returns the shared NO_BLOCK (never written to) instead of storing an
-- empty table on every member. Writers use memberBlockW.
local NO_BLOCK = setmetatable({}, { __newindex = function() error("PSS: write to NO_BLOCK", 2) end })
local function memberBlock(m)
	if type(m.block) == "table" then return m.block end
	if m.excludedWhispers ~= true and m.excludedGroup ~= true and m.excludedGuildInvite ~= true and m.excludedChat ~= true then
		return NO_BLOCK
	end
	local b = {}
	if m.excludedWhispers == true then b.whisper = false end
	if m.excludedGroup == true then b.partyInvite = false end
	if m.excludedGuildInvite == true then b.guildInvite = false end
	if m.excludedChat == true then b.partyRaid = false; b.world = false end
	m.block = b
	m.excludedWhispers, m.excludedGroup, m.excludedGuildInvite, m.excludedChat = nil, nil, nil, nil
	return b
end
M.PSS_MemberBlock = memberBlock

-- the member's own flags, created to be written
local function memberBlockW(m)
	local b = memberBlock(m)
	if b == NO_BLOCK then b = {}; m.block = b end
	return b
end

-- Effective setting for a member (own flag, else the guild's).
local function memberBlocks(g, m, cat)
	local own = memberBlock(m)[cat]
	if own ~= nil then return own == true end
	return guildBlock(g)[cat] == true
end
M.PSS_MemberBlocks = memberBlocks

-- g.enabled = the rule blocks anything for anyone.
local function refreshGuildActive(g)
	if type(g) ~= "table" then return false end
	local any = false
	for _, c in ipairs(EXCL_CATS) do if guildBlock(g)[c] then any = true break end end
	if not any then
		for _, m in pairs(g.members or {}) do
			if type(m) == "table" and type(m.block) == "table" then
				for _, c in ipairs(EXCL_CATS) do if m.block[c] == true then any = true break end end
			end
			if any then break end
		end
	end
	g.enabled = any
	return any
end
M.PSS_RefreshGuildActive = refreshGuildActive

-- Does this guild rule block right now? A guild that belongs to a group with
-- a Chat Filters rule (the shipped influencer lists, and any guild rule group
-- added later) is linked to that rule: with the rule off, none of its guilds
-- block, neither the shipped members nor the ones found in game and stored
-- in SavedVariables (they live on the same guild row, g.managed).
local function guildRuleActive(g)
	if type(g) ~= "table" or not g.enabled then return false end
	if g.managed then return M.PSS_ManagedGroupActive ~= nil and M.PSS_ManagedGroupActive(g.managed) end
	return true
end
M.PSS_GuildRuleActive = guildRuleActive

local function ensureGuild(name)
	ensureDB()
	local key = normalizeGuild(name)
	if not key then return nil end
	local g = PourSocialScoreDB.guildData[key]
	if not g then
		-- Adding a guild opts it IN to blocking: everything from its members
		-- is blocked. The W I G P C boxes are exclusions and start unticked.
		g = {
			name = trim(name),
			enabled = true,
			declineGuild = true,
			declineGroup = true,
			partyRaid = true,
			block = { whisper = true, partyInvite = true, guildInvite = true, partyRaid = true, world = true },
			customScan = M.PSS_DEFAULT_SCAN_FIELDS,
			members = {},
			memberCount = 0,
		}
		PourSocialScoreDB.guildData[key] = g
	else
		g.name = g.name or trim(name)
		if g.enabled == nil then g.enabled = true end
		if g.declineGuild == nil then g.declineGuild = true end
		if g.declineGroup == nil then g.declineGroup = true end
		if g.partyRaid == nil then g.partyRaid = true end
		M.PSS_MigrateCustomScan(g)
		g.scan, g.scanTotal, g.scanBrackets = nil, nil, nil		-- the old Scan n/9 progress
		g.members = g.members or {}
		g.memberCount = tonumber(g.memberCount) or 0
	end
	-- Block history and counters live on the MEMBER records only (see the
	-- GUILD BLOCK RECORDING section), so they travel with a player whenever
	-- that player is moved to another guild rule.
	-- (memberCount is display only; the Guild Ignore List recounts when it
	-- draws. It is no longer recounted here on every call, which made each
	-- scan result / unit seen walk the whole member list.)
	guildBlock(g)
	refreshGuildActive(g)
	return g, key
end

function M.PSS_GetGuild(name)
	return ensureGuild(name)
end

local function findGuildForPlayer(name)
	local key = memberKey(name)
	if not key then return nil end
	for guildKey, g in pairs(PourSocialScoreDB.guildData or {}) do
		if g.members and g.members[key] then return g, guildKey, g.members[key] end
	end
	return nil
end

function M.PSS_UpdatePlayerUnit(name, unit, guild)
	local p = setPlayerMeta(name, unit, guild)
	if guild and guild ~= "" then
		-- IMPORTANT: merely seeing a player in the world must never create a
		-- new Guild Ignore rule.  The old code called PSS_UpdateGuildMember()
		-- here, which calls ensureGuild() and therefore created a guild entry
		-- for every guild encountered while targeting/mousing over/grouping.
		-- This was the source of the random guilds appearing after login.
		-- Only attach the player to an already-existing guild rule.  Guild
		-- scan results and the explicit "Add Guild" action are the only
		-- operations allowed to create/populate Guild Ignore rules.
		local guildKey = normalizeGuild(guild)
		local existing = guildKey and PourSocialScoreDB.guildData and PourSocialScoreDB.guildData[guildKey]
		if existing then
			-- a shipped member of a managed guild: already known, store nothing.
			-- Telling them apart needs the shipped lists, so seeing a member of
			-- a managed guild loads them (out of combat, like every unit scan).
			local ck = existing.managed and canonPlayer(name)
			if existing.managed and M.PSS_LoadManagedData then M.PSS_LoadManagedData() end
			if not (ck and M.PSS_IsManagedStaticMember and M.PSS_IsManagedStaticMember(guildKey, ck)) then
				M.PSS_UpdateGuildMember(guild, name, unit)
			end
		end
	end
	return p
end

function M.PSS_UpdateGuildMember(guildName, playerName, unit)
	local g, gkey = ensureGuild(guildName)
	local pkey = memberKey(playerName)
	if not g or not pkey then return end

	-- A new member stores only what is known about them. Everything else
	-- reads as its default when missing (Allow flags false, no block
	-- choices, no counts, no last invite), so a guild sweep that captures
	-- thousands of players keeps each one small (see compactMember).
	local isNew = g.members[pkey] == nil
	local m = g.members[pkey] or {
		name = displayPlayer(playerName),
		guild = g.name,
		whenBlocked = nowString(),
	}
	m.name = displayPlayer(playerName)
	m.guild = guildName
	if m.excludedGroup == true and m.excludedGuildInvite == nil then m.excludedGuildInvite = true end
	if not m.whenBlocked or m.whenBlocked == "" then m.whenBlocked = nowString() end
	if M.PSS_EnsureMemberBlockData then M.PSS_EnsureMemberBlockData(m) end
	if isNew and M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	if isNew and guildRuleActive(g) then
		local ck = canonPlayer(playerName)
		if ck then
			if M.PSS__purgeBatch then M.PSS__purgeBatch[ck] = true
			elseif M.PSS_PurgeChatFrom then M.PSS_PurgeChatFrom({ [ck] = true }) end
		end
		if M.PSS_PersonIdentified then M.PSS_PersonIdentified(playerName) end
	end
	if unit and UnitExists(unit) then
		local faction = UnitFactionGroup(unit)
		local _, classToken = UnitClass(unit)
		if classToken and not isSecret(classToken) then m.class = classToken end
		if faction and not isSecret(faction) then m.faction = faction end
	end
	g.members[pkey] = m
	if isNew then g.memberCount = (tonumber(g.memberCount) or 0) + 1 end
	return m, g, gkey
end

------------------------------------------------------------------------
-- GUILD BLOCK RECORDING
--
-- Categories tracked for the Guild Ignore List:
--   whisper     : CHAT_MSG_WHISPER / CHAT_MSG_BN_WHISPER (one bucket - they
--                 were previously split into "Whispers" / "Private Messages")
--   partyInvite : party/raid invites (PARTY_INVITE_REQUEST)
--   partyRaid   : party / raid / raid warning / instance chat
--   world       : every other chat type that is not specifically captured
--                 above (channels such as Trade/General/LFG, say, yell, emote)
--   guildInvite : guild invites (GUILD_INVITE_REQUEST)
--
-- Counters are stored on member records:
--   member.blockCounts  = { whisper=, partyInvite=, partyRaid=, world=, guildInvite= }
-- The lines themselves go into the shared block log (PSS_ChatHistory.lua),
-- owned by "g:<character>", so they follow a player who is moved to another
-- guild rule. A guild's history / totals are built from its members.
------------------------------------------------------------------------

-- Entries, categories, counts and the history UI: PSS_ChatHistory.lua
local History = M.PSS_History
local CAT_ORDER, CAT_LABEL, CAT_COLOR = History.CAT_ORDER, History.CAT_LABEL, History.CAT_COLOR
M.PSS_GUILD_BLOCK_CATEGORIES = CAT_ORDER
M.PSS_GUILD_BLOCK_LABELS = CAT_LABEL

-- Event categories and channel labels are shared with the core.
local eventCategory = M.PSS_EventCategory
M.PSS_GuildEventCategory = eventCategory
local channelLabel = M.PSS_ChannelLabel
local parseTimeString = History.ParseTime
local normalizeEntry = History.Normalize

local entrySig = History.Sig

-- Bring a member record to the current block-data format. Older counter
-- fields are folded in once (flag _blockV2). Old per-member history lists
-- are moved into the shared log by the 2.0.17 upgrade.
-- blockCounts is only kept by members that were blocked at least once: a
-- member without it reads as all zero (memberCounts). Pass create = true
-- before writing to it.
local LEGACY_COUNT_FIELDS = { "blockedWhispers", "blockedPrivateMessages", "privateMessagesBlocked", "blockedChatMessages",
								"chatMessagesBlocked", "blockedInvites", "partyInvitesBlocked", "partyRaidMessagesBlocked" }
local function hasLegacyBlockData(m)
	if type(m.blockHistory) == "table" and #m.blockHistory > 0 then return true end
	for _, f in ipairs(LEGACY_COUNT_FIELDS) do
		if m[f] ~= nil then return true end
	end
	return false
end

local function ensureMemberBlockData(m, create)
	if type(m) ~= "table" then return end
	if not m._blockV2 and hasLegacyBlockData(m) then
		m.blockCounts = History.EnsureCounts(m.blockCounts)
		if type(m.blockHistory) == "table" and #m.blockHistory > 0 then
			-- very old saves wrote a line once per chat window: collapse repeats
			local out, prev = {}, nil
			for _, h in ipairs(m.blockHistory) do
				if History.Normalize(h) then
					local sig = History.Sig(h)
					if sig ~= prev then
						h.member = h.member or m.name
						out[#out + 1] = h
						m.blockCounts[h.cat] = (m.blockCounts[h.cat] or 0) + 1
					end
					prev = sig
				end
			end
			m.blockHistory = out
		else
			m.blockCounts.whisper = m.blockCounts.whisper + (tonumber(m.blockedWhispers) or 0)
				+ (tonumber(m.blockedPrivateMessages) or tonumber(m.privateMessagesBlocked) or 0)
			m.blockCounts.partyRaid = m.blockCounts.partyRaid
				+ (tonumber(m.blockedChatMessages) or tonumber(m.chatMessagesBlocked) or 0)
			m.blockCounts.partyInvite = m.blockCounts.partyInvite
				+ (tonumber(m.blockedInvites) or tonumber(m.partyInvitesBlocked) or 0)
		end
		-- Old counter fields are superseded by blockCounts.
		for _, f in ipairs(LEGACY_COUNT_FIELDS) do m[f] = nil end
		m._blockV2 = true
	end
	if create or m.blockCounts ~= nil then m.blockCounts = History.EnsureCounts(m.blockCounts) end
end
M.PSS_EnsureMemberBlockData = ensureMemberBlockData

-- Drop every field a stored member holds at its default, so SavedVariables
-- (and the memory it is loaded into) only carry what is known about them.
-- Before 2.0.29 each member was saved with four Allow flags, an empty block
-- table, a zero blockCounts table and session-only /who details: about
-- 1.2 KB each, which full guild sweeps (2.0.19) multiplied by thousands.
local DROP_ALWAYS = { "online", "race", "className" }	-- never read for members
local ALLOW_FLAGS = { "excludedGroup", "excludedGuildInvite", "excludedWhispers", "excludedChat" }
local function compactMember(m)
	if type(m) ~= "table" then return end
	ensureMemberBlockData(m)
	if type(m.block) ~= "table" then memberBlock(m) end		-- folds true Allow flags into m.block
	for _, f in ipairs(ALLOW_FLAGS) do
		if m[f] ~= true then m[f] = nil end
	end
	if type(m.block) == "table" and next(m.block) == nil then m.block = nil end
	if m.lastBlockedInvite == "" then m.lastBlockedInvite = nil end
	local bc = m.blockCounts
	if type(bc) == "table" then
		local zero = (tonumber(bc.total) or 0) == 0
		for _, c in ipairs(History.ALL_CATS) do
			if (tonumber(bc[c]) or 0) ~= 0 then zero = false break end
		end
		if zero then m.blockCounts = nil end
	end
	if m._blockV2 and not hasLegacyBlockData(m) then m._blockV2 = nil end
	for _, f in ipairs(DROP_ALWAYS) do m[f] = nil end
end
M.PSS_CompactMember = compactMember

-- every stored member of every guild rule
local function compactAllMembers()
	local n = 0
	for _, g in pairs((PourSocialScoreDB and PourSocialScoreDB.guildData) or {}) do
		if type(g) == "table" and type(g.members) == "table" then
			for _, m in pairs(g.members) do
				if type(m) == "table" then compactMember(m); n = n + 1 end
			end
		end
	end
	return n
end
M.PSS_CompactAllMembers = compactAllMembers

-- forget a member's counts (Reset): no counts stored = all zero
local function clearMemberBlockData(m)
	m.blockHistory, m.blockCounts, m.lastBlockedInvite, m._blockV2 = nil, nil, nil, nil
	for _, f in ipairs(LEGACY_COUNT_FIELDS) do m[f] = nil end
end

-- Fields that must never be copied by reference between member records.
local BLOCK_FIELDS = {
	blockCounts = true, blockHistory = true, _blockV2 = true,
	blockedWhispers = true, blockedPrivateMessages = true, blockedChatMessages = true, blockedInvites = true,
	privateMessagesBlocked = true, chatMessagesBlocked = true, partyInvitesBlocked = true,
	partyRaidMessagesBlocked = true,
}

-- Merge src's blocked counts INTO dst (used whenever a player moves between
-- guild rules). Counts are summed (only one record is ever hit for a given
-- block); the history lines belong to the character and need no moving.
local function mergeBlockData(dst, src)
	if type(dst) ~= "table" or type(src) ~= "table" or dst == src then return end
	ensureMemberBlockData(dst)
	ensureMemberBlockData(src)
	if src.blockCounts then
		ensureMemberBlockData(dst, true)
		for _, c in ipairs(History.ALL_CATS) do
			dst.blockCounts[c] = (dst.blockCounts[c] or 0) + (src.blockCounts[c] or 0)
		end
		dst.blockCounts.total = (dst.blockCounts.total or 0) + (src.blockCounts.total or 0)
	end
	if (src.lastBlockedInvite or "") ~= "" and (dst.lastBlockedInvite or "") == "" then
		dst.lastBlockedInvite = src.lastBlockedInvite
	end
end
M.PSS_MergeMemberBlockData = mergeBlockData

------------------------------------------------------------------------
-- MANAGED (DEFAULT) GUILDS
--
-- The shipped lists are read-only groups of guilds ("Olympus")
-- with their members. Each group has a built-in rule on the Chat Filters tab
-- (InfluencerGuild=<Name>) that switches the whole group on or off, and a
-- collapsible entry on the Guild Ignore List.
--
-- Only the DELTA is saved in PourSocialScoreDB:
--   * the guild rule records themselves (settings, W I G P C, Scan Fields)
--   * members found by scans / invites that are NOT in the shipped list
--   * shipped members you changed (note, exclusions, overrides) or that have
--     block history - written at logout
--   * g.managedGone[canon] = true for shipped members that left the guild
--     (seen in another guild by /who) or that you removed
-- Every other shipped member is "virtual": built from the shipped list when
-- needed and never written to SavedVariables.
--
-- 3.0: PSS_Communities.lua in the core is only the manifest (groups,
-- guild names and member counts). The member lists and their index are in
-- the on-demand PourSocialScore_Communities addon (addon.MANAGED_DATA),
-- loaded when a group's rule is on (login or ticked) or when you work with
-- guild members (members window, scans, /who capture, removing, seeing a
-- member of a shipped guild in the world). Chat never loads it: with the
-- rule off, shipped guilds block nothing.
------------------------------------------------------------------------
local MANAGED = addon.MANAGED or { groups = {} }
local managed = nil				-- guild-level data, built on first use
local ensureManagedData			-- loads PourSocialScore_Communities (below)
-- canon -> record for shipped members looked at this session. Weak: a record
-- nobody uses any more is freed by the garbage collector. Records you
-- changed are also held in vkeep until they are saved at logout.
local vcache = setmetatable({}, { __mode = "v" })
local vkeep = {}

-- Guild-level data (cheap: one entry per guild). The per-member index
-- (canon key -> guild number * 65536 + position) ships prebuilt in
-- the data file (tools/PSS_BuildManaged.lua), so nothing is
-- built per member at login and every shipped member matches from the
-- first chat line. It is packed (3.0.0-dev17): buckets[realm key][first
-- two bytes of the name key] is one string "\n<name key>=<number>..."
-- searched with a plain find, and each guild's members are one string
-- ("Name-<realm number>\n..."), split only while a list is looked at.
local function buildManaged()
	if managed then return managed end
	local data = addon.MANAGED_DATA
	managed = { lists = {}, names = {}, groupOf = {}, guildName = {}, groups = {}, count = {}, dataLoaded = data ~= nil }
	for _, grp in ipairs(MANAGED.groups or {}) do
		managed.groups[grp.key] = grp
		local gdata = data and data[grp.key]
		local gkeys = {}
		for gi, entry in ipairs(grp.guilds or {}) do
			local gkey = normalizeGuild(entry.name)
			gkeys[gi] = gkey or false
			if gkey then
				managed.groupOf[gkey] = grp.key
				managed.guildName[gkey] = entry.name
				managed.count[gkey] = tonumber(entry.n) or 0
				local list = gdata and gdata.guilds and gdata.guilds[gi]
				if list and list.name == entry.name then managed.names[gkey] = { packed = list.members, realms = gdata.realms } end
			end
		end
		if gdata then managed.lists[#managed.lists + 1] = { buckets = gdata.buckets or {}, gkeys = gkeys } end
	end
	return managed
end

-- canon key -> shipped guild key, position in its list (nil if not shipped).
-- A character listed by two groups belongs to the first.
local find, byte, sub = string.find, string.byte, string.sub

-- the number after "\n<base>=" in a bucket string, or nil
local function bucketValue(bucket, base)
	local init, len = 1, #base
	while true do
		local s, e = find(bucket, base, init, true)
		if not s then return nil end
		if byte(bucket, s - 1) == 10 and byte(bucket, e + 1) == 61 then
			local v, i = 0, e + 2
			local c = byte(bucket, i)
			while c and c >= 48 and c <= 57 do
				v = v * 10 + c - 48
				i = i + 1
				c = byte(bucket, i)
			end
			return v
		end
		init = s + len
	end
end

local function shippedOf(ck)
	if not ck then return nil end
	local lists = (managed or buildManaged()).lists
	if #lists == 0 then return nil end
	local dash = find(ck, "-", 1, true)
	if not dash or dash < 2 then return nil end
	local realm, base = sub(ck, dash + 1), sub(ck, 1, dash - 1)
	local first = sub(base, 1, 2)
	for i = 1, #lists do
		local rb = lists[i].buckets[realm]
		local bucket = rb and rb[first]
		local v = bucket and bucketValue(bucket, base)
		if v then
			local gi = math.floor(v / 65536)
			local gkey = lists[i].gkeys[gi]
			if gkey then return gkey, v - gi * 65536 end
		end
	end
	return nil
end

-- A shipped guild's members as a list of names (split from its packed
-- string while someone holds it; weak, so the garbage collector frees it).
local splitCache = setmetatable({}, { __mode = "v" })
local function shippedNames(gkey)
	local entry = (managed or buildManaged()).names[gkey]
	if not entry then return nil end
	local list = splitCache[gkey]
	if list then return list end
	list = {}
	local realms = entry.realms or {}
	for n in (entry.packed or ""):gmatch("[^\n]+") do
		local b, r = n:match("^(.+)%-(%d+)$")
		list[#list + 1] = b and realms[tonumber(r)] and (b .. "-" .. realms[tonumber(r)]) or n
	end
	splitCache[gkey] = list
	return list
end
M.PSS_ShippedNames = shippedNames

-- numbers for /pss mem
function M.PSS_ManagedStats()
	local m = buildManaged()
	local shipped, indexed = 0, 0
	for _, n in pairs(m.count) do shipped = shipped + n end
	for _, l in ipairs(m.lists) do
		for _, rb in pairs(l.buckets) do
			for _, bucket in pairs(rb) do
				for _ in bucket:gmatch("\n") do indexed = indexed + 1 end
			end
		end
	end
	local kept, cached = 0, 0
	for _ in pairs(vkeep) do kept = kept + 1 end
	for _ in pairs(vcache) do cached = cached + 1 end
	return { shipped = shipped, indexed = indexed, kept = kept, cached = cached, loaded = m.dataLoaded }
end

function M.PSS_ManagedGroups() return buildManaged().groups end
function M.PSS_ManagedGroupOfGuild(gkey) return buildManaged().groupOf[gkey] end

-- shipped (static) guild rule? (those can't be removed)
local function isStaticGuild(gkey) return buildManaged().groupOf[gkey] ~= nil end
M.PSS_IsStaticManagedGuild = isStaticGuild

local function isGone(g, ck) return type(g) == "table" and type(g.managedGone) == "table" and g.managedGone[ck] == true end

-- the shipped guild a character belongs to (nil if none, or they left it)
local function staticGuildOf(ck)
	local gkey = shippedOf(ck)
	if not gkey then return nil end
	local g = PourSocialScoreDB and PourSocialScoreDB.guildData and PourSocialScoreDB.guildData[gkey]
	if not g or isGone(g, ck) then return nil end
	return gkey, g
end

local function isStaticMember(gkey, ck)
	if ck == nil then return false end
	return shippedOf(ck) == gkey
end
M.PSS_IsManagedStaticMember = isStaticMember

-- The record for a shipped member (one per character while in use).
local function vrec(ck, gkey)
	local r = vkeep[ck] or vcache[ck]
	if r and r._gkey == gkey then return r end
	local m = buildManaged()
	local gk, pos = shippedOf(ck)
	local names = gk == gkey and shippedNames(gkey)
	local name = names and names[pos]
	if not name then return nil end
	-- flags, counts and block choices are created when first set
	r = {
		name = displayPlayer(name), guild = m.guildName[gkey] or gkey, whenBlocked = "Managed list",
		_managed = true, _virtual = true, _canon = ck, _gkey = gkey,
		_playerKey = normalizePlayer(name),
	}
	vcache[ck] = r
	return r
end
M.PSS_ManagedRecord = vrec

-- A shipped member's record was changed: hold it until it is saved.
local function keepManaged(r)
	if type(r) == "table" and r._virtual and r._canon then vkeep[r._canon] = r end
end
M.PSS_KeepManaged = keepManaged

-- has the record got anything worth saving?
local function managedDirty(r)
	if type(r) ~= "table" then return false end
	if type(r.note) == "string" and r.note ~= "" then return true end
	if type(r.block) == "table" and next(r.block) ~= nil then return true end
	if type(r.opts) == "table" and next(r.opts) ~= nil then return true end
	if type(r.blockCounts) == "table" and (tonumber(r.blockCounts.total) or 0) > 0 then return true end
	if (r.lastBlockedInvite or "") ~= "" then return true end
	return false
end

-- A shipped member is no longer in that guild (seen elsewhere, or removed).
local function tombstone(gkey, ck)
	local g = PourSocialScoreDB.guildData[gkey]
	if not g then return end
	g.managedGone = type(g.managedGone) == "table" and g.managedGone or {}
	g.managedGone[ck] = true
	if vcache[ck] and vcache[ck]._gkey == gkey then vcache[ck] = nil end
	if vkeep[ck] and vkeep[ck]._gkey == gkey then vkeep[ck] = nil end
	local key
	for k, mm in pairs(g.members or {}) do
		if type(mm) == "table" and (canonPlayer(type(k) == "string" and k or nil) or canonPlayer(mm.name)) == ck then key = k break end
	end
	if key then g.members[key] = nil end
end
M.PSS_ManagedTombstone = tombstone

-- Members of a guild rule including shipped members:
-- fn(member, storedKey or nil, isVirtual)
--   includeUntouched = false: only shipped members that have a record this
--   session (only those can have counts / history) - cheap
--   includeUntouched = true : every shipped member (members window)
local function forEachMember(g, gkey, fn, includeUntouched)
	local seen = g.managed and {} or nil
	for k, m in pairs(g.members or {}) do
		if type(m) == "table" then
			if seen then
				local ck = canonPlayer(type(k) == "string" and k or nil) or canonPlayer(m.name)
				if ck then seen[ck] = true end
			end
			fn(m, k, false)
		end
	end
	if not g.managed then return end
	if includeUntouched then
		ensureManagedData()
		local mm = buildManaged()
		for _, name in ipairs(shippedNames(gkey) or {}) do
			local ck = canonPlayer(name)
			if ck and shippedOf(ck) == gkey and not seen[ck] and not isGone(g, ck) then
				seen[ck] = true
				local r = vrec(ck, gkey)
				if r then fn(r, nil, true) end
			end
		end
	else
		local done = {}
		for _, t in ipairs({ vkeep, vcache }) do
			for ck, r in pairs(t) do
				if r._gkey == gkey and not seen[ck] and not done[ck] and not isGone(g, ck) then
					done[ck] = true
					fn(r, nil, true)
				end
			end
		end
	end
end
M.PSS_ForEachGuildMember = forEachMember

-- Number of members, without building any records: stored members, plus
-- the shipped list minus those who left (simple arithmetic).
-- A managed guild's count is kept until a member changes anywhere (the
-- member index is marked dirty) or its stored / gone member counts change,
-- so a redraw does not re-key every stored member of every managed guild.
local memberCountGen = 0
local memberCountCache = setmetatable({}, { __mode = "k" })		-- g -> { gen, key, stored, gone, n }

-- "Left this guild" marks the shipped list no longer needs (3.0): a mark
-- only matters while the shipped list still has that character in that
-- guild. Once a new list has dropped or moved them, the mark is removed, so
-- the saved marks keep themselves small. Runs once per session, when the
-- lists are loaded (it needs them); a rule that stays off keeps its few
-- marks until then. Empty mark tables are not saved.
local marksPruned = false
local function pruneMarks()
	if marksPruned or not (managed and managed.dataLoaded) then return 0 end
	local gd = PourSocialScoreDB and PourSocialScoreDB.guildData
	if type(gd) ~= "table" then return 0 end
	marksPruned = true
	local n = 0
	for gkey, g in pairs(gd) do
		if type(g) == "table" and type(g.managedGone) == "table" then
			for ck in pairs(g.managedGone) do
				if shippedOf(ck) ~= gkey then
					g.managedGone[ck] = nil
					n = n + 1
				end
			end
			if next(g.managedGone) == nil then g.managedGone = nil end
		end
	end
	if n > 0 then memberCountGen = memberCountGen + 1 end
	return n
end
M.PSS_PruneManagedMarks = function() marksPruned = false return pruneMarks() end

-- Load the shipped member lists (PourSocialScore_Communities) if they are
-- not loaded yet. Returns true when they are available.
ensureManagedData = function()
	if managed and managed.dataLoaded then pruneMarks() return true end
	if not addon.MANAGED_DATA and not (M.PSS_Need and M.PSS_Need("Communities")) then return false end
	managed = nil
	memberCountGen = memberCountGen + 1
	local ok = buildManaged().dataLoaded
	if ok then pruneMarks() end
	return ok
end
M.PSS_LoadManagedData = ensureManagedData
function M.PSS_ManagedDataLoaded() return buildManaged().dataLoaded end

-- Login and ticking a rule: load the lists when any group's rule is on.
function M.PSS_LoadActiveManagedData()
	for key in pairs(buildManaged().groups) do
		if M.PSS_ManagedGroupActive and M.PSS_ManagedGroupActive(key) then return ensureManagedData() end
	end
	return false
end
function M.PSS_GuildMemberCount(g, gkey)
	if type(g) ~= "table" then return 0 end
	local n = 0
	if not g.managed then
		for _ in pairs(g.members or {}) do n = n + 1 end
		return n
	end
	local stored, gone = 0, 0
	for _ in pairs(g.members or {}) do stored = stored + 1 end
	for _ in pairs(g.managedGone or {}) do gone = gone + 1 end
	local c = memberCountCache[g]
	if c and c.gen == memberCountGen and c.key == gkey and c.stored == stored and c.gone == gone then return c.n end
	local m = buildManaged()
	if not m.dataLoaded then
		-- lists not loaded: shipped count from the manifest, minus those who
		-- left, plus stored members that are not shipped ones (a changed
		-- shipped member is saved with _managed)
		n = (m.count[gkey] or 0) - gone
		for _, mm in pairs(g.members or {}) do
			if not (type(mm) == "table" and mm._managed) then n = n + 1 end
		end
		n = math.max(0, n)
		c = c or {}
		c.gen, c.key, c.stored, c.gone, c.n = memberCountGen, gkey, stored, gone, n
		memberCountCache[g] = c
		return n
	end
	n = m.names[gkey] and (m.count[gkey] or 0) or 0
	for k, mm in pairs(g.members or {}) do
		local ck = canonPlayer(type(k) == "string" and k or nil) or (type(mm) == "table" and canonPlayer(mm.name))
		if not (ck and shippedOf(ck) == gkey) then n = n + 1 end
	end
	for ck in pairs(g.managedGone or {}) do
		if shippedOf(ck) == gkey then n = n - 1 end
	end
	n = math.max(0, n)
	c = c or {}
	c.gen, c.key, c.stored, c.gone, c.n = memberCountGen, gkey, stored, gone, n
	memberCountCache[g] = c
	return n
end

-- Create / tag the shipped guild rules (startup).
local function ensureManagedRules()
	local m = buildManaged()
	for gkey, groupKey in pairs(m.groupOf) do
		local g = ensureGuild(m.guildName[gkey])
		if g then
			g.managed = groupKey
			g.ruleOrigin = g.ruleOrigin or "managed"
			-- marks are created when needed (tombstone); empty ones are not saved
			if type(g.managedGone) ~= "table" or next(g.managedGone) == nil then g.managedGone = nil end
		end
	end
end
M.PSS_EnsureManagedRules = ensureManagedRules

-- Logout: keep only the delta. Changed shipped members are written into
-- the guild record; unchanged shipped members are dropped from it.
function M.PSS_FlushManaged()
	if not PourSocialScoreDB or not PourSocialScoreDB.guildData then return end
	for _, t in ipairs({ vkeep, vcache }) do
		for ck, r in pairs(t) do
			local g = PourSocialScoreDB.guildData[r._gkey]
			if g and not isGone(g, ck) and managedDirty(r) then
				g.members = g.members or {}
				local key = r._playerKey or normalizePlayer(r.name)
				if key and not g.members[key] then
					r._virtual = nil
					g.members[key] = r
				end
			end
		end
	end
	for gkey, g in pairs(PourSocialScoreDB.guildData) do
		if type(g) == "table" and g.managed and type(g.members) == "table" then
			local drop = {}
			for k, mm in pairs(g.members) do
				local ck = canonPlayer(type(k) == "string" and k or nil) or (type(mm) == "table" and canonPlayer(mm.name))
				if ck and isStaticMember(gkey, ck) and not managedDirty(mm) then drop[#drop + 1] = k end
			end
			for _, k in ipairs(drop) do g.members[k] = nil end
			g.memberCount = nil
		end
	end
	compactAllMembers()
end

------------------------------------------------------------------------
-- Member lookup index: canonical player key -> guild key, stored key.
-- Chat events arrive with several name spellings ("Name", "Name-Realm",
-- "Name-Aman'Thul", Proper-cased names from the core filter...). The index
-- uses canonPlayer() so all of them resolve to the stored member record.
------------------------------------------------------------------------
-- Two flat maps (ck -> guild key, ck -> stored key) rather than a small
-- table per member: no per-member allocation on each rebuild.
local memberIndexG, memberIndexK, memberIndexDirty, memberIndexBuilt = {}, {}, true, 0

local function markMemberIndexDirty()
	memberIndexDirty = true
	memberCountGen = memberCountGen + 1
end
M.PSS_MarkGuildIndexDirty = markMemberIndexDirty

local function rebuildMemberIndex()
	local idxG, idxK, score = {}, {}, {}
	local bestCache = {}
	for gkey, g in pairs((PourSocialScoreDB and PourSocialScoreDB.guildData) or {}) do
		if type(g) == "table" and type(g.members) == "table" then
			for storedKey, m in pairs(g.members) do
				if type(m) == "table" then
					local ck = canonPlayer(type(storedKey) == "string" and storedKey or nil)
						or canonPlayer(m._playerKey) or canonPlayer(m.name)
					if ck then
						-- Prefer an enabled rule, then the rule that best owns the
						-- member's actual guild (duplicates across rules).
						local actual = m.guild or ""
						local best = bestCache[actual]
						if best == nil then
							best = (M.PSS_BestGuildRowFor and M.PSS_BestGuildRowFor(actual)) or false
							bestCache[actual] = best
						end
						local s = (guildRuleActive(g) and 2 or 0) + ((best == gkey) and 1 or 0)
						if not idxG[ck] or s > score[ck] then
							idxG[ck], idxK[ck] = gkey, storedKey
							score[ck] = s
						end
					end
				end
			end
		end
	end
	memberIndexG, memberIndexK = idxG, idxK
	memberIndexDirty = false
	memberIndexBuilt = GetTime and GetTime() or 0
end

-- Returns g, gkey, member, storedKey for a canon key (PSS_CanonPlayer).
-- The chat core already has the key, so this is the per-line path.
local function lookupGuildMemberCanon(ck)
	if not ck or not PourSocialScoreDB or not PourSocialScoreDB.guildData then return nil end
	-- rebuilt only when members changed (stale hits are re-checked below)
	if memberIndexDirty then rebuildMemberIndex() end

	for attempt = 1, 2 do
		local hitG, hitK = memberIndexG[ck], memberIndexK[ck]
		if not hitG then
			-- a shipped member of a managed guild (not stored)
			local gkey, g = staticGuildOf(ck)
			if gkey and g.managed then
				local r = vrec(ck, gkey)
				if r then return g, gkey, r, nil end
			end
			return nil
		end
		local g = PourSocialScoreDB.guildData[hitG]
		local m = g and g.members and g.members[hitK]
		if m then return g, hitG, m, hitK end
		if attempt == 1 then rebuildMemberIndex() end	-- stale entry
	end
	return nil
end

-- Same, for any spelling of a player's name.
local function lookupGuildMember(name)
	if type(name) ~= "string" or name == "" or isSecret(name) then return nil end
	return lookupGuildMemberCanon(canonPlayer(name))
end
M.PSS_LookupGuildMember = lookupGuildMember

------------------------------------------------------------------------
-- Block counts changed: one GUILD_BLOCKS_CHANGED per 0.25 s at most (spam
-- can fire many blocks per second).
------------------------------------------------------------------------
local guildUIRefreshPending = false
local function requestGuildUIRefresh()
	if guildUIRefreshPending then return end
	guildUIRefreshPending = true
	local function run()
		guildUIRefreshPending = false
		M.Events.Fire("GUILD_BLOCKS_CHANGED")
	end
	if C_Timer and C_Timer.After then C_Timer.After(0.25, run) else run() end
end
M.PSS_RequestGuildUIRefresh = requestGuildUIRefresh

local function recordGuildBlock(g, m, cat, event, message, channel, gkey)
	keepManaged(m)
	ensureMemberBlockData(m, true)
	local entry = History.NewEntry(cat, event, message, channel, m.name)
	entry.gk = gkey			-- the rule at the time (used if they leave every rule)
	History.Add(History.MemberKey(m), m.blockCounts, entry)
	History.CountRecent(History.GuildKey(gkey), entry.ts, entry.cat)	-- the guild's own recent counts
	if entry.cat == "partyInvite" or entry.cat == "guildInvite" then
		m.lastBlockedInvite = entry.time
	end
	requestGuildUIRefresh()
	return entry
end

-- W I G P C setters.
-- Member: value true/false sets the member's own choice; nil = use the guild's.
function M.PSS_SetMemberBlock(g, member, cat, value)
	if type(member) ~= "table" or not M.PSS_EXCL_INFO[cat] then return false end
	local was = g and memberBlocks(g, member, cat)
	keepManaged(member)
	if value == nil then memberBlockW(member)[cat] = nil else memberBlockW(member)[cat] = value == true end
	if g then
		refreshGuildActive(g)
		-- newly blocked: clear their earlier lines from chat, decline an open invite
		if not was and memberBlocks(g, member, cat) then
			local ck = canonPlayer(member._playerKey) or canonPlayer(member.name)
			if ck and M.PSS_PurgeChatFrom then M.PSS_PurgeChatFrom({ [ck] = true }) end
			if M.PSS_PersonIdentified and member.name then M.PSS_PersonIdentified(member.name) end
		end
	end
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	return true
end

function M.PSS_SetGuildBlock(guildNameOrKey, cat, value)
	ensureDB()
	local g = PourSocialScoreDB.guildData[normalizeGuild(guildNameOrKey) or ""]
	if not g or not M.PSS_EXCL_INFO[cat] then return end
	guildBlock(g)[cat] = value == true
	refreshGuildActive(g)
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	M.Events.Fire("GUILDS_CHANGED")
end

-- "W I G P C" with blocked letters lit, for diagnostics.
function M.PSS_ExclusionText(g, m)
	local out = {}
	for _, c in ipairs(EXCL_CATS) do
		local on = m and memberBlocks(g, m, c) or (not m and guildBlock(g)[c])
		local L = M.PSS_EXCL_INFO[c].letter
		out[#out + 1] = on and ("|cffff5555" .. L .. "|r") or ("|cff666666" .. L:lower() .. "|r")
	end
	return table.concat(out, " ")
end

-- A guild rule's Custom Scan Fields (the free-text /who filter).
function M.PSS_SetGuildScanFields(g, text)
	if type(g) == "table" then g.customScan = text end
end

-- A member's note (the members window keeps it to 25 characters); an empty
-- note is removed. A shipped member with a changed note is kept in the save.
function M.PSS_SetMemberNote(member, text)
	if type(member) ~= "table" then return end
	if (member.note or "") ~= text then keepManaged(member) end
	member.note = (text ~= "") and text or nil
end

-- A player taken off the Player Ignore List who is also on a built-in guild
-- list stays there (those members ship with the addon and can't be edited
-- in its files): every W I G P C switch is blocked on them in that guild rule
-- and, if they have no member note yet, one says why (their old list note,
-- else REMOVED_NOTE). Returns true if they are on a built-in list.
local REMOVED_NOTE = "Removed from player list"
function M.PSS_KeepBlockedOnBuiltIn(name, note)
	local g, _, m = lookupGuildMember(name)
	if not g or not g.managed or type(m) ~= "table" then return false end
	for _, cat in ipairs(EXCL_CATS) do M.PSS_SetMemberBlock(g, m, cat, true) end
	if (m.note or "") == "" then
		note = type(note) == "string" and M.trim(note) or ""
		if #note > 25 then note = note:sub(1, 25):gsub("[\192-\255][\128-\191]*$", "") end	-- whole letters only
		M.PSS_SetMemberNote(m, note ~= "" and note or REMOVED_NOTE)
	end
	M.Events.Fire("GUILDS_CHANGED")
	return true
end

-- Could member m own block history lines? A line is only ever added with a
-- count, so a member never counted has none (older saves: the old fields).
local function memberMayHaveLines(m)
	if type(m) ~= "table" then return false end
	local c = m.blockCounts
	if type(c) == "table" and (tonumber(c.total) or 0) > 0 then return true end
	return hasLegacyBlockData(m)
end

function M.PSS_RemoveGuildMember(guildName, playerName, sourceGuildKey, storedKey)
	ensureDB()
	local g = (sourceGuildKey and PourSocialScoreDB.guildData[sourceGuildKey])
		or PourSocialScoreDB.guildData[normalizeGuild(guildName) or ""]
	if not g or type(g.members) ~= "table" then return false end

	local removed = false
	local rck = canonPlayer(playerName)
	if g.managed and rck then
		ensureManagedData()
		local gk = sourceGuildKey or normalizeGuild(guildName)
		if gk and isStaticMember(gk, rck) and not isGone(g, rck) then
			tombstone(gk, rck)
			removed = true
		end
	end
	local mayHaveLines = false
	if storedKey ~= nil and g.members[storedKey] then
		mayHaveLines = memberMayHaveLines(g.members[storedKey])
		g.members[storedKey] = nil
		removed = true
	else
		local ck = canonPlayer(playerName)
		local doomed = {}
		for k, m in pairs(g.members) do
			if ck and (canonPlayer(type(k) == "string" and k or nil) == ck or (type(m) == "table" and canonPlayer(m.name) == ck)) then
				doomed[#doomed + 1] = k
			end
		end
		for _, k in ipairs(doomed) do
			mayHaveLines = mayHaveLines or memberMayHaveLines(g.members[k])
			g.members[k] = nil
			removed = true
		end
	end
	if removed then
		g.memberCount = 0
		for _ in pairs(g.members) do g.memberCount = g.memberCount + 1 end
		markMemberIndexDirty()
		-- in no guild rule now: their block lines go too (counts went with the
		-- record). Never counted: no lines, and the block history (Logging)
		-- is not loaded for it.
		if rck and not lookupGuildMemberCanon(rck) then
			local owner = "g:" .. rck
			if History.Loaded() or mayHaveLines then
				History.Clear(function(h) return h.o == owner end)
			end
			History.ForgetRecent(owner)
		end
	end
	return removed
end

------------------------------------------------------------------------
-- Totals and history (guild = sum/merge of its members)
------------------------------------------------------------------------
local function emptyCounts() return History.EmptyCounts() end
-- a member's counts for reading (members never blocked keep none)
local NO_COUNTS = History.EmptyCounts()
local function memberCounts(m) return m.blockCounts or NO_COUNTS end

local function findGuildRecord(guildNameOrKey)
	if not PourSocialScoreDB or not PourSocialScoreDB.guildData then return nil end
	local key = normalizeGuild(guildNameOrKey)
	local g = key and PourSocialScoreDB.guildData[key]
	if g then return g, key end
	for k, cand in pairs(PourSocialScoreDB.guildData) do
		if type(cand) == "table" and normalizeGuild(cand.name) == key then return cand, k end
	end
	return nil
end
M.PSS_FindGuildRecord = findGuildRecord

-- Returns a counts table { whisper=, partyInvite=, partyRaid=, world=, guildInvite=, total= }.
-- With no argument, sums every guild rule.
function M.PSS_GetGuildBlockCounts(guildNameOrKey)
	local out = emptyCounts()
	local guilds = {}
	if guildNameOrKey then
		local g, k = findGuildRecord(guildNameOrKey)
		if g then guilds[1] = { g = g, key = k } end
	else
		for k, g in pairs((PourSocialScoreDB and PourSocialScoreDB.guildData) or {}) do
			if type(g) == "table" then guilds[#guilds + 1] = { g = g, key = k } end
		end
	end
	for _, gg in ipairs(guilds) do
		forEachMember(gg.g, gg.key, function(m)
			ensureMemberBlockData(m)
			local bc = memberCounts(m)
			for _, c in ipairs(History.ALL_CATS) do out[c] = out[c] + (bc[c] or 0) end
		end)
	end
	local total = 0
	for _, c in ipairs(History.ALL_CATS) do total = total + out[c] end
	out.total = total
	return out
end

function M.PSS_GetMemberBlockCounts(m)
	local out = emptyCounts()
	if type(m) ~= "table" then out.total = 0 return out end
	ensureMemberBlockData(m)
	local bc, total = memberCounts(m), 0
	for _, c in ipairs(History.ALL_CATS) do out[c] = bc[c] or 0; total = total + out[c] end
	out.total = total
	return out
end

-- Does a log line belong to guild rule gkey? A line is owned by a
-- character ("g:<canon>"); it shows under the rule that character is in now
-- (so it follows them when moved), or - if they are in no rule any more -
-- under the rule they were in when it was blocked.
local function guildLineMatcher(g, gkey)
	if g.managed then ensureManagedData() end
	local stored = {}
	for k, m in pairs(g.members or {}) do
		if type(m) == "table" then
			local ck = canonPlayer(type(k) == "string" and k or nil) or canonPlayer(m._playerKey) or canonPlayer(m.name)
			if ck then stored[ck] = true end
		end
	end
	local where = {}		-- ck -> in this rule (true) / not (false), per view
	return function(h)
		local o = h.o
		if type(o) ~= "string" or o:sub(1, 2) ~= "g:" then return false end
		local ck = o:sub(3)
		local w = where[ck]
		if w == nil then
			if stored[ck] or (g.managed and isStaticMember(gkey, ck) and not isGone(g, ck)) then
				w = true
			else
				w = (h.gk == gkey) and lookupGuildMember(ck) == nil
			end
			where[ck] = w
		end
		return w
	end
end

-- Newest-first history for one guild rule (or every rule when nil), from
-- the shared log.
function M.PSS_GetGuildBlockHistory(guildNameOrKey)
	local matchers = {}
	if guildNameOrKey then
		local g, gkey = findGuildRecord(guildNameOrKey)
		if not g then return {} end
		matchers[1] = { fn = guildLineMatcher(g, gkey), label = "Guild rule: " .. tostring(g.name or gkey) }
		return History.Collect(function(h)
			if matchers[1].fn(h) then History.SetSource(h, matchers[1].label) return true end
			return false
		end)
	end
	local label = {}		-- ck -> "Guild rule: X" / false
	return History.Collect(function(h)
		local o = h.o
		if type(o) ~= "string" or o:sub(1, 2) ~= "g:" then return false end
		local ck = o:sub(3)
		local l = label[ck]
		if l == nil then
			local g, gkey = lookupGuildMember(ck)
			l = g and ("Guild rule: " .. tostring(g.name or gkey)) or false
			label[ck] = l
		end
		if not l and h.gk then
			local g = PourSocialScoreDB.guildData[h.gk]
			if g then l = "Guild rule: " .. tostring(g.name or h.gk) end
		end
		if l then History.SetSource(h, l) end
		return true
	end)
end

function M.PSS_ResetGuildBlockHistory(guildNameOrKey)
	local g, gkey = findGuildRecord(guildNameOrKey)
	if not g then return end
	History.Clear(guildLineMatcher(g, gkey))
	forEachMember(g, gkey, function(m)
		History.ForgetRecent(History.MemberKey(m))
		clearMemberBlockData(m)
	end)
	History.ForgetRecent(History.GuildKey(gkey))
	g.blockHistory = nil
	requestGuildUIRefresh()
end

function M.PSS_GetMemberBlockHistory(member)
	local key = History.MemberKey(member)
	return key and History.For(key) or {}
end

function M.PSS_ResetMemberBlockHistory(member)
	if type(member) ~= "table" then return end
	local key = History.MemberKey(member)
	if key then
		History.Clear(function(h) return h.o == key end)
		History.ForgetRecent(key)
	end
	clearMemberBlockData(member)
	requestGuildUIRefresh()
end

-- Store one /who result under a guild rule. Returns "new" (not stored under
-- that rule before), "known", or nil (no rule / no guild).
local function addWhoResultToGuildMember(info, guildRowName, actualGuild)
	local fullName = info.fullName or info.name
	if type(fullName) ~= "string" or isSecret(fullName) or fullName == "" then return nil end

	actualGuild = actualGuild or info.fullGuildName or info.guild or ""
	if M.PSS_IsGuildExcluded(actualGuild) then return nil end	-- Guild Exclusion List
	ensureManagedData()		-- who is shipped, and who left a shipped guild
	-- WHO's lazy guild search means a scan for "Olympus" also returns members of
	-- "Olympus Tycoons". If a more specific saved guild rule matches this
	-- member's ACTUAL guild, the member belongs to that rule, not to the broad
	-- one that happened to catch them.
	local ownerKey, owner = M.PSS_BestGuildRowFor(actualGuild)
	if owner and ownerKey ~= normalizeGuild(guildRowName) then
		guildRowName = owner.name or guildRowName
	end

	local rowKey = normalizeGuild(guildRowName)
	local g = rowKey and PourSocialScoreDB.guildData and PourSocialScoreDB.guildData[rowKey]
	if not g then return nil end
	local pkey = normalizePlayer(fullName)
	local status = (pkey and g.members and g.members[pkey]) and "known" or "new"

	-- managed guild + shipped member: nothing is stored (it is in the shipped
	-- list); the session record just gets the fresh /who details
	local wck = canonPlayer(fullName)
	if g.managed and wck and isStaticMember(rowKey, wck) and not (pkey and g.members and g.members[pkey]) then
		local wasGone = isGone(g, wck)
		if wasGone then g.managedGone[wck] = nil end
		local r = vrec(wck, rowKey)
		if r then
			local moved = M.PSS_MoveOtherCopies and M.PSS_MoveOtherCopies(fullName, rowKey, r) or 0
			r.guild = actualGuild
			r.class = classTokenFromInfo(info.filename or info.classFileName or info.classFile or info.classStr or info.class) or r.class
			r.level = tonumber(info.level) or r.level
			markMemberIndexDirty()
			if moved > 0 then return "moved" end
			return wasGone and "new" or "known"
		end
	end

	local member = M.PSS_UpdateGuildMember(guildRowName, fullName)
	-- /who shows the player's guild NOW: if they are stored under any other
	-- guild rule (they changed guild, or a broad rule caught them), their
	-- record - settings, exclusions and block history - is merged into this
	-- rule and removed from the old one(s).
	if member and M.PSS_MoveOtherCopies and M.PSS_MoveOtherCopies(fullName, rowKey, member) > 0 and status == "new" then
		status = "moved"
	end
	if member then
		member.guild = actualGuild
		member.name = displayPlayer(fullName)
		member.class = classTokenFromInfo(
			info.filename or info.classFileName or info.classFile or
			info.classStr or info.class
		) or member.class or ""
		member.level = tonumber(info.level) or member.level
		-- Store the canonical player key on the member record. This makes the
		-- later exact-guild migration independent of display-name formatting,
		-- realm-name casing, or which broad guild filter originally captured it.
		member._playerKey = normalizePlayer(fullName)
	end

	-- Keep actual-guild metadata current for later explicit Add Guild promotion.
	local p = pkey and PourSocialScoreDB.playerData and PourSocialScoreDB.playerData[pkey]
	if p then
		p.currentGuild = actualGuild
		if member then
			p.class = member.class or p.class or ""
			p.className = info.classStr or info.className or p.className
		end
	end
	return member and status or nil
end

function M.PSS_ScanGuild(guildName, mode, restart)
	local g = ensureGuild(guildName)
	if not g then return false end
	if not g.ruleOrigin then g.ruleOrigin = "scan" end

	-- mode "custom": the guild plus its Scan Fields; anything else: the
	-- next search of the guild's sweep (PSS_WhoisHarvest.lua)
	mode = (mode == "custom") and "custom" or "sweep"
	local filter, bracket, step, sw, item
	if mode == "custom" then
		-- Custom Scan Fields text is sent as-is after the guild name,
		-- e.g. g-"Olympus" 80 c-"Mage"
		bracket = trim(g.customScan or "")
		filter = 'g-"' .. g.name:gsub('"', "") .. '"' .. (bracket ~= "" and (" " .. bracket) or "")
		filter = M.PSS_CapWhoFilter(filter)		-- Options: scan level cap
		bracket = filter:match('^g%-".-"%s*(.*)$') or ""
	else
		sw, item, filter = M.PSS_HarvestNext(g, restart)
		if not item then
			M.ShowMsg(("Scan <%s>: waiting for the answer to the last search."):format(g.name))
			return false
		end
		bracket = filter:match('^g%-".-"%s*(.*)$') or ""
		step = sw.sent + 1
	end

	local req = {
		kind = "guildScan",
		guildKey = normalizeGuild(g.name),
		guildName = g.name,
		bracket = bracket or "",
		filter = filter,
		mode = mode,
		step = step,
		sweep = sw,
		item = item,
		startedAt = GetTime(),
		seen = 0, matched = 0, added = 0, other = 0, moved = 0,
	}

	-- Mirrors OlympusMute's WhoScan(): the /who goes out straight from the
	-- button's OnClick with nothing UI-related having run first.  Cooldown,
	-- button state and list refresh all happen on the next frame, so the
	-- click handler never disables/hides/re-scripts the button it is running
	-- from before the protected call has been made.
	-- (Whois.Request starts the cooldown and the 5 s "nobody answered"
	-- timer itself, both after the /who has gone out.)
	if not Whois.Request(req) then return false end
	if sw then M.PSS_HarvestSent(sw, filter) end	-- only advance when the /who really went out
	C_Timer.After(0, function()
		M.Events.Fire("GUILDS_CHANGED")
	end)
	return true
end

------------------------------------------------------------------------
-- /who RESULTS (from PSS_Whois.lua)
--
-- Every /who answer - from a Scan, a Guild Search, a Player Search or your
-- own /who - is read here: each player is stored under the saved guild rule
-- that owns their guild. (A /who never CREATES a guild rule.) A guild Scan
-- or Guild Search request also keeps its own counts and results.
------------------------------------------------------------------------
-- one result; returns "new" / "known" / "moved" / nil
local function captureWho(info, req)
	local guild = info.fullGuildName or info.guild or ""
	if type(guild) ~= "string" or isSecret(guild) then guild = "" end
	local scan = (req and req.kind == "guildScan") and req or nil
	local search = (req and req.kind == "guildSearch") and req or nil
	if scan then scan.seen = scan.seen + 1 end

	if search and guild ~= "" then
		local gkey = normalizeGuild(guild)
		search.found = search.found or {}
		search.players = search.players or {}
		if gkey and not search.found[gkey] then search.found[gkey] = trim(guild) end
		-- remembered so the guilds you add from the results get these players
		local fn = info.fullName or info.name
		if gkey and type(fn) == "string" and not isSecret(fn) and fn ~= "" then
			local list = search.players[gkey] or {}
			search.players[gkey] = list
			list[#list + 1] = {
				fullName = fn, fullGuildName = guild, level = info.level,
				classStr = info.classStr, className = info.className, filename = info.filename,
				raceStr = info.raceStr or info.race,
			}
		end
	end

	if guild == "" then
		if scan then scan.other = scan.other + 1 end
		return nil
	end
	local res
	if scan and guildMatches(scan.guildName, guild) then
		scan.matched = scan.matched + 1
		res = addWhoResultToGuildMember(info, scan.guildName, guild)
	else
		if scan then scan.other = scan.other + 1 end
		local ownerKey, owner = M.PSS_BestGuildRowFor(guild)
		if owner then res = addWhoResultToGuildMember(info, owner.name or ownerKey, guild) end
	end
	if scan and res == "new" then scan.added = scan.added + 1 end
	if scan and res == "moved" then scan.moved = (scan.moved or 0) + 1 end
	if res then M.PSS__whoCaptured = true end
	return res
end

-- After a /who answer: show Guild Search results, move members to the most
-- specific rule, report what the scan did, refresh.
local function finishScan(req, numWhos, total, how)
	if M.PSS_RequestGC then M.PSS_RequestGC("who results") end
	local scan = (req and req.kind == "guildScan") and req or nil
	local searchState = (req and req.kind == "guildSearch") and req or nil
	local captured = M.PSS__whoCaptured
	M.PSS__whoCaptured = nil
	if searchState then
		local list = {}
		for _, name in pairs(searchState.found or {}) do list[#list + 1] = name end
		table.sort(list, function(a, b) return a:lower() < b:lower() end)
		-- temporary cache of who was seen in each guild (used by Save)
		M.PSS_GuildSearchCache = { at = GetTime(), byGuild = searchState.players or {} }
		C_Timer.After(0, function()
			M.Events.Fire("GUILD_SEARCH_RESULTS", list, searchState.query, searchState.mode, searchState.owner)
		end)
	end

	local moved = scan and scan.moved or 0
	if (scan or captured) and M.PSS_ReconcileGuildMembers then moved = moved + (M.PSS_ReconcileGuildMembers() or 0) end

	local split = scan and scan.sweep and M.PSS_HarvestAnswered(scan, numWhos, total) or 0

	if scan then
		local sw = scan.sweep
		local what = (scan.mode == "custom") and ("Custom (" .. (scan.bracket ~= "" and scan.bracket or "no fields") .. ")")
			or ("Scan %d/%d (%s)"):format(scan.step or 0, (sw and (sw.sent + #sw.queue)) or 0, scan.bracket ~= "" and scan.bracket or "whole guild")
		if scan.seen == 0 then
			M.ShowMsg(("%s for <%s>: /who found nobody. Only online players show in /who - try another bracket or Custom."):format(what, scan.guildName))
		else
			M.ShowMsg(("%s for <%s>: %d player(s) found, %d in a matching guild, %d newly captured%s%s."):format(
				what, scan.guildName, scan.seen, scan.matched, scan.added,
				moved > 0 and (", " .. moved .. " moved here from another guild rule") or "",
				scan.other > 0 and (", " .. scan.other .. " in other guilds skipped") or ""))
		end
		if split > 0 then
			M.ShowMsg(("|cffff9900/who capped at %d: split into %d narrower searches - keep clicking Scan.|r"):format(M.PSS_WHO_CAP, split))
		elseif sw and sw.done then
			M.ShowMsg(("|cff00ff00Sweep of <%s> complete|r: %d searches, %d players found, %d newly captured."):format(scan.guildName, sw.sent, sw.seen, sw.added))
		elseif not sw and tonumber(total) and tonumber(numWhos) and total > numWhos then
			M.ShowMsg(("|cffff9900/who shows at most %d players; this search matched %d. Narrow it with Custom and the Scan Fields (e.g. 85-90 or 90 c-\"Mage\") to reach the rest.|r"):format(numWhos, total))
		end
	elseif moved > 0 then
		M.ChatMsg(("PSS: %d member(s) belonged to a more specific saved guild and were moved there."):format(moved))
	end

	C_Timer.After(0, function() M.Events.Fire("GUILD_SCAN_DONE") end)
end

Whois.Listen({
	-- one chat-history sweep for everyone newly captured by this answer
	begin = function()
		M.PSS__purgeBatch = M.PSS__purgeBatch or {}
	end,
	info = function(info, req)
		captureWho(info, req)
	end,
	finish = function(req, numWhos, total, how)
		local batch = M.PSS__purgeBatch
		M.PSS__purgeBatch = nil
		if batch and next(batch) and M.PSS_PurgeChatFrom then pcall(M.PSS_PurgeChatFrom, batch) end
		finishScan(req, numWhos, total, how)
	end,
})

-- GUILD SEARCH ---------------------------------------------------------
-- Sends a normal /who and collects the distinct guild names in the results.
-- Plain text is wrapped as g-"text". Anything containing a double quote is
-- treated as a complete /who filter and sent untouched.
-- mode "exclude" (the Guild Exclusion List search): the text is always a
-- guild name, and the results picker adds to the exclusion list instead.
-- owner: who shows the results (the window: M.PSS_GUILD_SEARCH_OWNER).
function M.PSS_GuildSearch(text, mode, owner)
	text = trim(text or "")
	if text == "" then return false end

	local filter
	if mode ~= "exclude" and text:find('"', 1, true) then
		filter = text
	else
		filter = 'g-"' .. (text:gsub('"', "")) .. '"'
	end
	filter = M.PSS_CapWhoFilter(filter)		-- Options: scan level cap

	-- /who must go out straight from the click (hardware event)
	return Whois.Request({ kind = "guildSearch", filter = filter, query = text, mode = mode, owner = owner, found = {} })
end

local function guildSearchChat(msg)
	M.ChatMsg("PSS: " .. msg)
end

-- How long Guild Search results are kept for Save (seconds).
local GUILD_SEARCH_CACHE_TTL = 600

-- Saving Guild Search results (the picker is in PSS_GuildUI.lua):
--   M.PSS_SaveGuildSearch     : ticked guilds become guild rules, with the
--                               players the search saw in them as members
--   M.PSS_SaveGuildExclusions : ticked guilds go on the Guild Exclusion List
local function saveGuildSearch(names)
	local added, members, moved = 0, 0, 0
	local cache = M.PSS_GuildSearchCache
	-- the cache is only trusted for a while: players move guilds
	if cache and GetTime() - (cache.at or 0) > GUILD_SEARCH_CACHE_TTL then cache = nil end
	M.PSS__purgeBatch = M.PSS__purgeBatch or {}

	for _, name in ipairs(names) do
		M.PSS_AddGuild(name)
		added = added + 1
		-- everyone the search saw in this guild becomes a member of it
		local seen = cache and cache.byGuild[normalizeGuild(name)]
		for _, info in ipairs(seen or {}) do
			local res = addWhoResultToGuildMember(info, name, info.fullGuildName or name)
			if res == "new" then
				members = members + 1
			elseif res == "moved" then
				moved = moved + 1
				members = members + 1
			end
		end
	end

	M.PSS_GuildSearchCache = nil
	local batch = M.PSS__purgeBatch
	M.PSS__purgeBatch = nil
	if batch and next(batch) and M.PSS_PurgeChatFrom then pcall(M.PSS_PurgeChatFrom, batch) end
	if M.PSS_ReconcileGuildMembers then M.PSS_ReconcileGuildMembers() end
	guildSearchChat(("%d guild(s) added to the Guild Ignore List with %d member(s) seen by the search%s."):format(
		added, members, moved > 0 and (" (" .. moved .. " moved from another guild rule)") or ""))
	M.Events.Fire("GUILDS_CHANGED")
end

local function saveGuildExclusions(names)
	local added = 0
	for _, name in ipairs(names) do
		if M.PSS_AddGuildExclusion(name) then added = added + 1 end
	end
	guildSearchChat(("%d guild(s) added to the Guild Exclusion List."):format(added))
	M.Events.Fire("GUILDS_CHANGED")
end
M.PSS_SaveGuildSearch = saveGuildSearch
M.PSS_SaveGuildExclusions = saveGuildExclusions

local rosterScanQueued = false
local function handleUnitEvents(event, unit)
	if event == "PLAYER_TARGET_CHANGED" then
		scanUnit("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		scanUnit("mouseover")
	elseif event == "NAME_PLATE_UNIT_ADDED" and unit then
		scanUnit(unit)
	elseif event == "GROUP_ROSTER_UPDATE" then
		-- raids fire this in bursts: look once, 2 s after the last one
		if rosterScanQueued then return end
		rosterScanQueued = true
		C_Timer.After(2, function()
			rosterScanQueued = false
			if IsInRaid() then
				for i=1,GetNumGroupMembers() do scanUnit("raid"..i) end
			else
				for i=1,4 do scanUnit("party"..i) end
			end
		end)
	end
end

-- Mouseover and nameplates: listened to out of combat only, so no guild
-- discovery is attempted from them while fighting.
local function listenUnitScans(f, on)
	if on then
		f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
		f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	else
		f:UnregisterEvent("UPDATE_MOUSEOVER_UNIT")
		f:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, arg1, ...)
	if event == "PLAYER_LOGIN" then
		-- Do NOT create/upgrade the database here: on a fresh install the main
		-- addon has not built its default lists yet. The legacy upgrade runs
		-- from the main addon once it has finished loading (V.PSS_Loaded).
		self:UnregisterEvent("PLAYER_LOGIN")
		self:RegisterEvent("PLAYER_TARGET_CHANGED")
		self:RegisterEvent("GROUP_ROSTER_UPDATE")
		self:RegisterEvent("PLAYER_REGEN_DISABLED")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		listenUnitScans(self, not inCombat())
		if V.PSS_Loaded and M.PSS_UpgradeLegacyData then M.PSS_UpgradeLegacyData() end
	elseif event == "PLAYER_REGEN_DISABLED" then
		listenUnitScans(self, false)
	elseif event == "PLAYER_REGEN_ENABLED" then
		listenUnitScans(self, true)
	elseif event == "PLAYER_TARGET_CHANGED" or event == "UPDATE_MOUSEOVER_UNIT" or
			event == "NAME_PLATE_UNIT_ADDED" or event == "GROUP_ROSTER_UPDATE" then
		handleUnitEvents(event, arg1)
	end
end)

-- (Chat lines and invites are decided by PSS_ChatBlock.lua; this file
-- registers the "guild" person source further down.)

function M.PSS_UpgradeLegacyData()
	ensureDB()
	for i, name in ipairs(PourSocialScoreDB.ignoreList or {}) do
		local p = ((PourSocialScoreDB.typeList or {})[i] or "player") == "player" and M.PSS_GetPlayerPrefs and M.PSS_GetPlayerPrefs(name)
		if p then
		p.name = name
		p.whenBlocked = p.whenBlocked or PourSocialScoreDB.dateList[i] or nowString()
		-- (the note and expiry live in the list itself, not on the record)
		local fac = PourSocialScoreDB.factionList[i]
		if (p.faction or "") == "" and type(fac) == "string" and fac ~= "" then p.faction = fac end
		end
	end
	cleanupLegacyGuildPlayers()
	ensureManagedRules()
	-- 2.0.6: one block-history format for every list (PSS_ChatHistory.lua).
	-- Bring stored player and member history lines up to date once; fields
	-- that were never recorded become "Unknown". (Chat filter history is
	-- converted when the filters load.)
	if (tonumber(PourSocialScoreDB.historyFormat) or 0) < 2 then
		local function upgrade(owner, ownerName)
			if type(owner) ~= "table" then return end
			if type(owner.blockHistory) ~= "table" then owner.blockHistory = {} end
			local kept = {}
			for _, h in ipairs(owner.blockHistory) do
				if History.Normalize(h) then
					h.member = h.member or ownerName or History.UNKNOWN
					kept[#kept + 1] = h
				end
			end
			owner.blockHistory = kept
			owner.blockCounts = History.EnsureCounts(owner.blockCounts)
		end
		for key, p in pairs(PourSocialScoreDB.playerData or {}) do
			if type(p) == "table" then
				if M.PSS_GetPlayerBlockCounts then M.PSS_GetPlayerBlockCounts(p) end	-- counts from older saves
				upgrade(p, p.name or key)
			end
		end
		for _, g in pairs(PourSocialScoreDB.guildData or {}) do
			for key, m in pairs((type(g) == "table" and g.members) or {}) do
				if type(m) == "table" then
					ensureMemberBlockData(m)
					upgrade(m, m.name or key)
				end
			end
		end
		PourSocialScoreDB.historyFormat = 2
	end

	-- 2.0.17: ONE shared block log with a total cap instead of a list per
	-- player / member. Move every old list into it once (newest lines kept).
	if (tonumber(PourSocialScoreDB.historyFormat) or 0) < 3 then
		local sources = {}
		for key, p in pairs(PourSocialScoreDB.playerData or {}) do
			if type(p) == "table" then
				if M.PSS_GetPlayerBlockCounts then M.PSS_GetPlayerBlockCounts(p) end
				if type(p.blockHistory) == "table" and #p.blockHistory > 0 then
					sources[#sources + 1] = { list = p.blockHistory, owner = History.PlayerKey(p.name or key), member = p.name or key }
				end
				p.blockHistory = nil
			end
		end
		for gkey, g in pairs(PourSocialScoreDB.guildData or {}) do
			for key, m in pairs((type(g) == "table" and g.members) or {}) do
				if type(m) == "table" then
					ensureMemberBlockData(m)
					if type(m.blockHistory) == "table" and #m.blockHistory > 0 then
						local owner = History.MemberKey(m) or History.MemberKey({ name = key })
						for _, h in ipairs(m.blockHistory) do if type(h) == "table" then h.gk = gkey end end
						sources[#sources + 1] = { list = m.blockHistory, owner = owner, member = m.name or key }
					end
					m.blockHistory = nil
				end
			end
		end
		if #sources > 0 then History.Absorb(sources) end
		PourSocialScoreDB.historyFormat = 3
	end
	-- 2.0.37: every person keeps their newest 10 chat lines, 5 emotes,
	-- 5 party and 5 guild invites (PourSocialScoreDB.blockKeep) when lines
	-- leave the log. Lines are moved there, never copied or counted again.
	if (tonumber(PourSocialScoreDB.historyFormat) or 0) < 4 then
		History.Keep()
		PourSocialScoreDB.historyFormat = 4
	end
	-- keep the log within the setting (it may have been lowered); lines that
	-- leave it go to the per-player keep. (Not loaded yet: done when
	-- PourSocialScore_Logging loads.)
	if History.Loaded() then History.Trim(true) end

	-- 2.0.4: Filter / Guild Inv / Group Inv and the members' Allow boxes
	-- became W I G P C. Convert every rule and member once.
	for _, g in pairs(PourSocialScoreDB.guildData or {}) do
		if type(g) == "table" then
			guildBlock(g)
			for _, m in pairs(g.members or {}) do if type(m) == "table" then memberBlock(m) end end
			refreshGuildActive(g)
		end
	end
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end

	-- 2.0.10: Scan Fields default to 1-60. Fill the empty ones once (a value
	-- you typed yourself is kept; you can clear it again afterwards).
	if not PourSocialScoreDB.scanFieldsDefaultV1 then
		for _, g in pairs(PourSocialScoreDB.guildData or {}) do
			if type(g) == "table" and (g.customScan == nil or trim(tostring(g.customScan)) == "") then
				g.customScan = M.PSS_DEFAULT_SCAN_FIELDS
			end
		end
		PourSocialScoreDB.scanFieldsDefaultV1 = true
	end

	-- Guild block data v2: history/counters live on members only. Older builds
	-- also kept a duplicate copy on the guild record; drop it.
	for _, g in pairs(PourSocialScoreDB.guildData or {}) do
		if type(g) == "table" then
			for _, m in pairs(g.members or {}) do
				if type(m) == "table" then
					-- guild invites used to share the "Allow Group Invites" box
					if m.excludedGroup == true and m.excludedGuildInvite == nil then m.excludedGuildInvite = true end
					compactMember(m)
				end
			end
			g.blockHistory = nil
			g.blockedWhispers, g.blockedPrivateMessages, g.blockedChatMessages, g.blockedInvites = nil, nil, nil, nil
			M.PSS_MigrateCustomScan(g)
		end
	end
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
end

function M.PSS_AddGuild(guildName)
	local g = ensureGuild(guildName)
	if not g then return end
	g.ruleOrigin = "manual"
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	M.Events.Fire("GUILDS_CHANGED")
end

-- canonPlayer / canonGuild are defined near the top of this file.

local function recountGuildMembers()
	for _, g in pairs(PourSocialScoreDB.guildData or {}) do
		if type(g) == "table" then
			g.members = g.members or {}
			g.memberCount = 0
			for _ in pairs(g.members) do g.memberCount = g.memberCount + 1 end
		end
	end
end

-- Merge one stored member record into another (settings kept, allow-flags
-- OR-ed, counters take the highest value).
-- Block history and counts are merged (not copied by reference), so a moved
-- player's blocked chat history arrives intact in the new guild rule.
local MERGE_SKIP = {
	blockCounts = true, blockHistory = true, _blockV2 = true, block = true,
	blockedWhispers = true, blockedPrivateMessages = true, blockedChatMessages = true, blockedInvites = true,
	privateMessagesBlocked = true, chatMessagesBlocked = true, partyInvitesBlocked = true,
	partyRaidMessagesBlocked = true,
}
local function mergeMemberRecord(existing, m)
	if existing == m then return end
	-- Bring both records to the current block-data format first, so legacy
	-- counters are never double counted.
	if M.PSS_EnsureMemberBlockData then
		M.PSS_EnsureMemberBlockData(existing)
		M.PSS_EnsureMemberBlockData(m)
	end
	for field, value in pairs(m) do
		if not MERGE_SKIP[field] and (existing[field] == nil or existing[field] == "") then existing[field] = value end
	end
	-- (only true is stored: a missing flag means false)
	for _, f in ipairs({ "excludedGroup", "excludedGuildInvite", "excludedWhispers", "excludedChat" }) do
		if m[f] == true then existing[f] = true end
	end
	-- W I G P C: keep the existing record's own choices, fill the gaps from m
	local eb, mb = memberBlockW(existing), memberBlock(m)
	for _, c in ipairs(EXCL_CATS) do
		if eb[c] == nil and mb[c] ~= nil then eb[c] = mb[c] end
	end
	if M.PSS_MergeMemberBlockData then M.PSS_MergeMemberBlockData(existing, m) end
end

-- Move every copy of a player stored under a guild rule OTHER than keepKey
-- into target (that rule's record for them): settings, exclusions and block
-- history are merged, then the old copies are removed. Returns how many
-- copies were moved.
function M.PSS_MoveOtherCopies(playerName, keepKey, target)
	local ck = canonPlayer(playerName)
	if not ck or type(target) ~= "table" then return 0 end
	ensureManagedData()
	local moved = 0
	for gkey, g in pairs(PourSocialScoreDB.guildData or {}) do
		if gkey ~= keepKey and type(g) == "table" and type(g.members) == "table" then
			local doomed = {}
			for k, m in pairs(g.members) do
				if type(m) == "table" and m ~= target then
					local mk = canonPlayer(type(k) == "string" and k or nil) or canonPlayer(m._playerKey) or canonPlayer(m.name)
					if mk == ck then doomed[#doomed + 1] = k end
				end
			end
			for _, k in ipairs(doomed) do
				keepManaged(target)
				mergeMemberRecord(target, g.members[k])
				g.members[k] = nil
				moved = moved + 1
			end
			if #doomed > 0 then
				g.memberCount = 0
				for _ in pairs(g.members) do g.memberCount = g.memberCount + 1 end
				refreshGuildActive(g)
			end
		end
	end
	-- a shipped member of ANOTHER managed guild: they left it
	local sk = staticGuildOf(ck)
	if sk and sk ~= keepKey then
		local r = vkeep[ck] or vcache[ck]
		if r and r ~= target and r._gkey == sk then keepManaged(target); mergeMemberRecord(target, r) end
		tombstone(sk, ck)
		moved = moved + 1
	end
	if moved > 0 then markMemberIndexDirty() end
	return moved
end

-- GUILD EXCLUSION LIST
-- Exact guild names (case-insensitive) that no guild rule ever applies to:
-- a broad rule like "Olympus" would otherwise catch <Olympus Friends> too.
-- Their members are not blocked, not captured by scans, searches or invites,
-- and belong to no rule. Saved as PourSocialScoreDB.guildExclusions[canon] = display name.
local function exclusions()
	if type(PourSocialScoreDB) ~= "table" then return {} end
	if type(PourSocialScoreDB.guildExclusions) ~= "table" then PourSocialScoreDB.guildExclusions = {} end
	return PourSocialScoreDB.guildExclusions
end

function M.PSS_IsGuildExcluded(actualGuild)
	local ck = canonGuild(actualGuild)
	return ck ~= nil and exclusions()[ck] ~= nil
end

-- True when actualGuild is your own guild: a guild rule never blocks your
-- own guild's members (a Player Ignore List entry for one of them still
-- does; that is a different list). Read from the client each time, so a
-- guild change applies at once.
local ownName, ownCk
function M.PSS_IsOwnGuild(actualGuild)
	local mine = GetGuildInfo and GetGuildInfo("player")
	if type(mine) ~= "string" or mine == "" or isSecret(mine) then return false end
	if mine ~= ownName then ownName, ownCk = mine, canonGuild(mine) end
	return ownCk ~= nil and canonGuild(actualGuild) == ownCk
end

-- Sorted list of excluded guild names.
function M.PSS_GuildExclusions()
	local list = {}
	for _, name in pairs(exclusions()) do list[#list + 1] = tostring(name) end
	table.sort(list, function(a, b) return a:lower() < b:lower() end)
	return list
end

-- Returns true when added, false when already listed, nil for an empty name.
function M.PSS_AddGuildExclusion(name)
	local ck = canonGuild(name)
	if not ck then return nil end
	local ex = exclusions()
	if ex[ck] then return false end
	ex[ck] = trim(name):gsub("%s+", " ")
	markMemberIndexDirty()
	M.Events.Fire("GUILDS_CHANGED")
	return true
end

function M.PSS_RemoveGuildExclusion(name)
	local ck = canonGuild(name)
	local ex = exclusions()
	if not ck or not ex[ck] then return false end
	ex[ck] = nil
	markMemberIndexDirty()
	M.Events.Fire("GUILDS_CHANGED")
	return true
end

-- The saved guild rule that a given ACTUAL guild name belongs to: the rule with
-- the longest name contained in it (so "Olympus Tycoons" beats "Olympus" for a
-- member of <Olympus Tycoons>, and an exact match always wins).
function M.PSS_BestGuildRowFor(actualGuild)
	ensureDB()
	local ac = canonGuild(actualGuild)
	if not ac then return nil end
	if M.PSS_IsGuildExcluded(actualGuild) then return nil end	-- excluded guilds belong to no rule
	local bestKey, bestG, bestLen
	for key, g in pairs(PourSocialScoreDB.guildData or {}) do
		if type(g) == "table" then
			local rc = canonGuild(g.name or key)
			if rc and ac:find(rc, 1, true) and (not bestLen or #rc > bestLen) then
				bestKey, bestG, bestLen = key, g, #rc
			end
		end
	end
	return bestKey, bestG
end

-- Validate stored data: every member whose recorded actual guild belongs to a
-- different (more specific) saved rule is moved there and every stray copy is
-- removed. Members with no recorded guild are left alone. Returns moved count.
function M.PSS_ReconcileGuildMembers()
	ensureDB()
	local guilds = PourSocialScoreDB.guildData or {}
	local moves = {}
	for srcKey, src in pairs(guilds) do
		if type(src) == "table" and type(src.members) == "table" then
			for storedKey, m in pairs(src.members) do
				if type(m) == "table" and canonGuild(m.guild) then
					local bestKey = M.PSS_BestGuildRowFor(m.guild)
					if bestKey and bestKey ~= srcKey then
						moves[#moves + 1] = { srcKey = srcKey, storedKey = storedKey, dstKey = bestKey }
					end
				end
			end
		end
	end
	if #moves == 0 then return 0 end

	local dstIndex = {}		-- dstKey -> canon -> storedKey
	local function indexFor(dstKey)
		local idx = dstIndex[dstKey]
		if not idx then
			idx = {}
			for k, mm in pairs(guilds[dstKey].members) do
				local ck = canonPlayer(type(k) == "string" and k or nil) or (type(mm) == "table" and canonPlayer(mm.name))
				if ck then idx[ck] = k end
			end
			dstIndex[dstKey] = idx
		end
		return idx
	end

	local movedCanon, moved = {}, 0
	for _, mv in ipairs(moves) do
		local src, dst = guilds[mv.srcKey], guilds[mv.dstKey]
		local m = src and src.members and src.members[mv.storedKey]
		if m and dst then
			dst.members = dst.members or {}
			local ck = canonPlayer(type(mv.storedKey) == "string" and mv.storedKey or nil) or canonPlayer(m.name)
			local idx = indexFor(mv.dstKey)
			local tKey = ck and idx[ck]
			local existing = tKey and dst.members[tKey]
			if not existing then
				tKey = mv.storedKey
				existing = {}
				dst.members[tKey] = existing
				if ck then idx[ck] = tKey end
			end
			mergeMemberRecord(existing, m)
			existing._playerKey = existing._playerKey or normalizePlayer(existing.name or tKey) or tKey
			src.members[mv.storedKey] = nil
			if ck then movedCanon[ck] = mv.dstKey end
			moved = moved + 1
		end
	end

	-- Remove any remaining copy of a moved player from every rule except the
	-- one that now owns them.
	for srcKey, src in pairs(guilds) do
		if type(src) == "table" and type(src.members) == "table" then
			local doomed = {}
			for storedKey, mm in pairs(src.members) do
				local ck = canonPlayer(type(storedKey) == "string" and storedKey or nil)
					or (type(mm) == "table" and canonPlayer(mm.name))
				if ck and movedCanon[ck] and movedCanon[ck] ~= srcKey then doomed[#doomed + 1] = storedKey end
			end
			for _, k in ipairs(doomed) do src.members[k] = nil end
		end
	end

	recountGuildMembers()
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	return moved
end

-- Promote an exact guild name to its own guild rule.
--   ADD    : every player stored under ANY other saved guild rule whose actual
--            guild is `actualGuild` is copied into the new rule (settings and
--            counters preserved, whitelist flags OR-ed together).
--   REMOVE : every reference to those players is then deleted from ALL other
--            guild rules, and the result is re-checked.
-- Returns added, migrated, removedRefs, perSource, leftover
--   added      = players new to the target rule
--   migrated   = added + players the target already had
--   perSource  = { {name=, moved=} ... } per old guild rule
--   leftover   = references still present in other rules after cleanup (expected 0)
function M.PSS_AddCapturedGuild(actualGuild, fromGroup)
	ensureDB()
	actualGuild = trim(actualGuild or "")
	local targetKey = normalizeGuild(actualGuild)
	local targetCanon = canonGuild(actualGuild)
	if not targetKey or not targetCanon then return 0, 0, 0, {}, 0 end

	local target = ensureGuild(actualGuild)
	if not target then return 0, 0, 0, {}, 0 end
	target.ruleOrigin = "manual"
	-- promoted from a managed group's guild: it joins that group's list
	if fromGroup and not target.managed then target.managed = fromGroup end
	target.name = actualGuild
	target.members = target.members or {}

	local playerData = PourSocialScoreDB.playerData or {}

	---------------------------------------------------------------- collect
	-- Search every OTHER guild rule for players whose recorded actual guild
	-- (member.guild, or playerData.currentGuild as a fallback) is the target.
	local hits, order = {}, {}
	for sourceKey, source in pairs(PourSocialScoreDB.guildData or {}) do
		if sourceKey ~= targetKey and type(source) == "table" and type(source.members) == "table" then
			for storedKey, member in pairs(source.members) do
				if type(member) == "table" then
					local ck = canonPlayer(type(storedKey) == "string" and storedKey or nil)
						or canonPlayer(member._playerKey) or canonPlayer(member.name)
					if ck then
						local pd = playerData[storedKey] or (member._playerKey and playerData[member._playerKey])
						if canonGuild(member.guild) == targetCanon
							or (pd and canonGuild(pd.currentGuild) == targetCanon) then
							local rec = hits[ck]
							if not rec then
								rec = { canon = ck, list = {}, player = pd }
								hits[ck] = rec
								order[#order + 1] = rec
							end
							rec.list[#rec.list + 1] = { sourceKey = sourceKey, storedKey = storedKey, member = member }
						end
					end
				end
			end
		end
	end

	-- Existing target members, indexed canonically so we never create a
	-- second copy of a player the target rule already holds.
	local targetIndex = {}
	for storedKey, member in pairs(target.members) do
		if type(member) == "table" then
			local ck = canonPlayer(type(storedKey) == "string" and storedKey or nil) or canonPlayer(member.name)
			if ck then targetIndex[ck] = storedKey end
		end
	end

	------------------------------------------------------------------- add
	local added, alreadyThere = 0, 0
	local perSource = {}
	local movedCanon = {}

	for _, rec in ipairs(order) do
		local tKey = targetIndex[rec.canon]
		local existing = tKey and target.members[tKey]
		if existing then
			alreadyThere = alreadyThere + 1
		else
			tKey = rec.list[1].storedKey
			existing = {}
			target.members[tKey] = existing
			targetIndex[rec.canon] = tKey
			added = added + 1
		end

		for _, hit in ipairs(rec.list) do
			-- Settings kept, allow-flags OR-ed, and the player's blocked chat
			-- history + counts carried across into the new guild rule.
			mergeMemberRecord(existing, hit.member)
		end
		existing.name = displayPlayer(existing.name or tKey)
		existing._playerKey = existing._playerKey or normalizePlayer(existing.name) or tKey
		existing.guild = actualGuild
		if rec.player then
			rec.player.currentGuild = actualGuild
		end
		movedCanon[rec.canon] = true
	end

	---------------------------------------------------------------- remove
	-- Remove EVERY reference to every promoted player from EVERY other rule.
	local function purge()
		local removed = 0
		for sourceKey, source in pairs(PourSocialScoreDB.guildData or {}) do
			if sourceKey ~= targetKey and type(source) == "table" and type(source.members) == "table" then
				local doomed = {}
				for storedKey, member in pairs(source.members) do
					local ck = canonPlayer(type(storedKey) == "string" and storedKey or nil)
						or (type(member) == "table" and (canonPlayer(member._playerKey) or canonPlayer(member.name)))
					if ck and movedCanon[ck] then doomed[#doomed + 1] = storedKey end
				end
				for _, storedKey in ipairs(doomed) do
					source.members[storedKey] = nil
					removed = removed + 1
				end
				if #doomed > 0 then
					perSource[#perSource + 1] = { name = source.name or sourceKey, moved = #doomed }
				end
			end
		end
		return removed
	end

	local removedRefs = purge()

	-- Verify: a second pass must find nothing left behind.
	local leftover = 0
	for sourceKey, source in pairs(PourSocialScoreDB.guildData or {}) do
		if sourceKey ~= targetKey and type(source) == "table" and type(source.members) == "table" then
			for storedKey, member in pairs(source.members) do
				local ck = canonPlayer(type(storedKey) == "string" and storedKey or nil)
					or (type(member) == "table" and (canonPlayer(member._playerKey) or canonPlayer(member.name)))
				if ck and movedCanon[ck] then leftover = leftover + 1 end
			end
		end
	end

	recountGuildMembers()
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	table.sort(perSource, function(a, b) return (a.moved or 0) > (b.moved or 0) end)
	M.Events.Fire("GUILDS_CHANGED")
	return added, added + alreadyThere, removedRefs, perSource, leftover
end

function M.PSS_RemoveGuild(guildNameOrKey)
	ensureDB()
	local key = normalizeGuild(guildNameOrKey)
	local g = key and PourSocialScoreDB.guildData[key]
	if not g then return 0, 0, false end
	if isStaticGuild(key) then return 0, 0, false end	-- shipped guilds can't be removed

	local memberKeys = {}
	local memberCount = 0
	for memberKey in pairs(g.members or {}) do
		memberKeys[memberKey] = true
		memberCount = memberCount + 1
	end

	-- The Player Ignore List is NOT touched: players you ignored yourself
	-- stay ignored when a guild rule they were captured under is removed.
	-- (2.0.8 also deleted every Player Ignore List entry with a member's name.)
	local removedGlobal = 0

	PourSocialScoreDB.guildData[key] = nil
	History.ForgetRecent(History.GuildKey(key))
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	M.Events.Fire("GUILD_REMOVED", key)
	if PourSocialScoreDB.playerData then
		for memberKey in pairs(memberKeys) do
			-- Keep playerData if the player is still present elsewhere in the
			-- Pour Social Score; otherwise discard the guild-only metadata.
			if M.hasGlobalIgnored then
				local stillIgnored = false
				for _, ignoredName in ipairs(PourSocialScoreDB.ignoreList or {}) do
					if normalizePlayer(ignoredName) == memberKey then stillIgnored = true break end
				end
				if not stillIgnored then PourSocialScoreDB.playerData[memberKey] = nil end
			end
		end
	end

	-- block lines of members who are in no guild rule now go with it; not
	-- loaded yet: the tidy runs when PourSocialScore_Logging loads
	if M.PSS_TidyBlockHistory and History.Loaded() then M.PSS_TidyBlockHistory() end

	M.Events.Fire("GUILDS_CHANGED")
	M.Events.Fire("PLAYERS_CHANGED", true)
	return removedGlobal, memberCount, true
end

cleanupLegacyGuildPlayers = function()
	ensureDB()
	if PourSocialScoreDB.guildPlayerCleanupV3 then return end
	local guildMembers = {}
	for _, g in pairs(PourSocialScoreDB.guildData or {}) do
		for key, m in pairs(g.members or {}) do
			guildMembers[key] = guildMembers[key] or {}
			guildMembers[key][m.whenBlocked or ""] = true
		end
	end
	PourSocialScoreDB.ignoreList = PourSocialScoreDB.ignoreList or {}
	for i = #PourSocialScoreDB.ignoreList, 1, -1 do
		local name = PourSocialScoreDB.ignoreList[i]
		local key = normalizePlayer(name)
		local p = PourSocialScoreDB.playerData and PourSocialScoreDB.playerData[key]
		if key and p and guildMembers[key] and guildMembers[key][p.whenBlocked or ""] then
			table.remove(PourSocialScoreDB.ignoreList, i)
			table.remove(PourSocialScoreDB.factionList, i)
			table.remove(PourSocialScoreDB.dateList, i)
			table.remove(PourSocialScoreDB.notes, i)
			table.remove(PourSocialScoreDB.expList, i)
			table.remove(PourSocialScoreDB.typeList, i)
			table.remove(PourSocialScoreDB.syncInfo, i)
			PourSocialScoreDB.playerData[key] = nil
		end
	end
	PourSocialScoreDB.guildPlayerCleanupV3 = true
end

-- Chat output for the Guild Ignore List ("PSS: ...").
local function pssSay(msg)
	M.ChatMsg("PSS: " .. msg)
end
M.PSS_Say = pssSay

-- Remove a guild rule straight away (no confirmation) and report in chat.
function M.PSS_RemoveGuildNow(guildKey)
	local g = guildKey and PourSocialScoreDB.guildData[guildKey]
	if not g then return end
	if isStaticGuild(guildKey) then
		M.ShowMsg(("<%s> is part of the default guild list and can't be removed. Turn its rule off on the Chat Filters tab instead."):format(tostring(g.name or guildKey)))
		return
	end
	local name = g.name or guildKey
	local removedGlobal, memberCount = M.PSS_RemoveGuild(guildKey)
	M.ShowMsg(("Guild |cffffff00%s|r removed with its %d captured member(s). Your Player Ignore List was not changed.")
		:format(tostring(name), memberCount or 0))
end


------------------------------------------------------------------------
-- "guild" person source for the core (PSS_ChatBlock.lua)
--   W I G P C per guild rule, overridable per member (see EXCLUSIONS near
--   the top of this file). Guild chat of your own guild is never touched.
------------------------------------------------------------------------
local function gopt(key, e)
	local ctx = { person = e.m.opts, guild = e.g.opts }
	if M.PSS_Opt then return M.PSS_Opt(key, ctx) end
	return PourSocialScoreDB[key]
end

-- The lookup result of a listed member, kept for their next chat line
-- instead of a new table per line (checked against the current lookup, so
-- it is never stale). At most LOOKUP_KEEP people; then it starts over.
local LOOKUP_KEEP = 300
local lookupKept, lookupKeptCount = {}, 0

if M.PSS_RegisterBlockSource then
	M.PSS_RegisterBlockSource({
		id = "guild", order = 20, label = "Guild Ignore List",
		lookup = function(canon)
			local g, gkey, m, storedKey = lookupGuildMemberCanon(canon)
			if not g then return nil end
			local e = lookupKept[canon]
			if e and e.g == g and e.gkey == gkey and e.m == m and e.storedKey == storedKey then return e end
			e = { g = g, gkey = gkey, m = m, storedKey = storedKey }
			if lookupKept[canon] == nil then
				if lookupKeptCount >= LOOKUP_KEEP then lookupKept, lookupKeptCount = {}, 0 end
				lookupKeptCount = lookupKeptCount + 1
			end
			lookupKept[canon] = e
			return e
		end,
		decide = function(e, cat, ctx)
			local g, m = e.g, e.m
			-- a managed group blocks only while its Chat Filters rule is on
			if g.managed and not guildRuleActive(g) then return false end
			-- a guild on the Guild Exclusion List is never blocked by a guild rule
			if M.PSS_IsGuildExcluded(m.guild or g.name) then return false end
			-- nor is your own guild
			if M.PSS_IsOwnGuild(m.guild or g.name) then return false end
			if cat == "whisper" or cat == "partyInvite" or cat == "guildInvite" or cat == "partyRaid" or cat == "world" then
				return memberBlocks(g, m, cat)
			elseif cat == "duel" or cat == "trade" then
				-- only for members this rule blocks in some way
				local any = false
				for _, c in ipairs(EXCL_CATS) do if memberBlocks(g, m, c) then any = true break end end
				if not any then return false end
				return gopt(cat == "duel" and "declineDuel" or "declineTrade", e) ~= false
			end
			return false		-- guild/officer chat, achievements, notices
		end,
		record = function(e, cat, ctx)
			if cat == "duel" or cat == "trade" then return end
			local rc = (cat == "guildChat" or cat == "other") and "world" or cat
			-- counted once, here: a managed group's Chat Filters rule only
			-- switches it on or off and counts nothing itself
			recordGuildBlock(e.g, e.m, rc, ctx.event, ctx.msg,
				(cat == "partyInvite" or cat == "guildInvite") and CAT_LABEL[cat]
					or channelLabel(ctx.event, ctx.channelString, ctx.chNumber, ctx.chName), e.gkey)
		end,
		optionContext = function(e) return { person = e.m.opts, guild = e.g.opts } end,
		describe = function(e)
			return ("Guild Ignore List <%s> (%s), stored as %s, actual guild %s"):format(
				tostring(e.g.name), M.PSS_ExclusionText(e.g, e.m), tostring(e.storedKey), tostring(e.m.guild))
		end,
		-- A guild invite names the guild: capture an unscanned inviter of an
		-- ignored guild under the rule that owns that guild.
		inviteByGuild = function(inviter, guildName)
			if type(guildName) ~= "string" or guildName == "" then return nil end
			local bestKey, bestG = M.PSS_BestGuildRowFor(guildName)
			if not guildRuleActive(bestG) then return nil end
			local ick = canonPlayer(inviter)
			if bestG.managed and ick and isStaticMember(bestKey, ick) then
				-- shipped member: no stored record needed
				if isGone(bestG, ick) then bestG.managedGone[ick] = nil end
				local r = vrec(ick, bestKey)
				if r then r.guild = guildName; return { g = bestG, gkey = bestKey, m = r } end
			end
			local m = M.PSS_UpdateGuildMember(bestG.name or bestKey, inviter)
			if not m then return nil end
			m.guild = guildName
			m._playerKey = normalizePlayer(inviter)
			if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
			return { g = bestG, gkey = bestKey, m = m, storedKey = normalizePlayer(inviter) }
		end,
	})
end
