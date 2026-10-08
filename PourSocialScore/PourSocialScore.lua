----------------------------------
-- Pour Social Score Variables --
----------------------------------
local addonName, addon	= ...
local L = addon.L -- localization entries
local V = addon.V -- shared variables
local M = addon.M -- shared methods

V.PSS_Loaded			= false
V.PSS_SyncOK			= false
V.PSS_InSync			= false
V.lastFilterError		= false

-- Startup, saved-variable defaults/upgrades, one-time legacy import and
-- the group warning. Chat, invites, duels and trades are decided in
-- PSS_ChatBlock.lua; the lists live in PSS_PlayerIgnoreList.lua,
-- PSS_GuildIgnoreList.lua and PSS_ChatFilters.lua.
local PSSFRAME			= nil
local gotLoaded			= false
local gotUpdate			= false
local gotEntering		= false
local safeToLoad		= false
local gotGroup			= IsInGroup()
V.groupWarning			= {}

----------------------------------
-- Pour Social Score Functions --
----------------------------------

-- Post-upgrade tidy-up of the block history (every login): lines of players
-- no longer on the Player Ignore List, of guild members in no guild rule
-- (whose rule is gone too) and of chat filters that no longer exist are
-- dropped; rule tags that point at a removed rule are cleared. Block counts
-- are not changed. Returns the number of lines removed.
function M.PSS_TidyBlockHistory()
	local db = PourSocialScoreDB
	local History = M.PSS_History
	if type(db) ~= "table" or not History then return 0 end
	local alive = {}
	if type(db.ignoreList) == "table" and type(db.typeList) == "table" and M.PSS_PlayerHistoryKey then
		local listed = {}
		for i, name in ipairs(db.ignoreList) do
			if (db.typeList[i] or "player") == "player" then
				local k = M.PSS_PlayerHistoryKey(name)
				if k then listed[k] = true end
			end
		end
		alive.p = function(o) return listed[o] == true end
	end
	if type(db.guildData) == "table" and M.PSS_LookupGuildMember then
		local seen = {}
		alive.g = function(o, h)
			local v = seen[o]
			if v == nil then
				v = M.PSS_LookupGuildMember(o:sub(3)) ~= nil
				seen[o] = v
			end
			return v or (h.gk ~= nil and db.guildData[h.gk] ~= nil)
		end
		alive.guild = function(gkey) return db.guildData[gkey] ~= nil end
	end
	if type(db.filterList) == "table" and M.PSS_FilterOwnerKey then
		local keys, ids = {}, {}
		for i = 1, #db.filterList do
			keys[M.PSS_FilterOwnerKey(i)] = true
			local id = db.filterID[i]
			if id and id ~= "" then ids[id] = true end
		end
		alive.f = function(o) return keys[o] == true end
		alive.rule = function(id) return ids[id] == true end
	end
	return History.Tidy(alive)
end

local starting = false
local function ApplicationStartup(self)

	-- (loading an on-demand addon during startup fires ADDON_LOADED, which
	-- comes back here: run once)
	if V.PSS_Loaded == true or safeToLoad == false or starting then
		return
	end
	starting = true

	M.ShowMsg(L["LOAD_1"])

	V.faction = UnitFactionGroup("player")

	local fresh = PourSocialScoreDB == nil
	if fresh then
		M.PSS_ResetIgnoreDB()
	end
	-- the PourSocialScore_Options tables, routing of moved keys, and the move
	-- of a 2.0 save (upgrade steps 2 to 4). Without PourSocialScore_Options
	-- nothing can be read: stop here (the message says which folder).
	if not M.PSS_PrepareSavedData({ quiet = fresh, startup = true }) then starting = false return end

	-- Ensure all core list fields exist before any UI or upgrade code uses #field.
	PourSocialScoreDB.ignoreList = PourSocialScoreDB.ignoreList or {}
	PourSocialScoreDB.factionList = PourSocialScoreDB.factionList or {}
	PourSocialScoreDB.dateList = PourSocialScoreDB.dateList or {}
	PourSocialScoreDB.notes = PourSocialScoreDB.notes or {}
	PourSocialScoreDB.expList = PourSocialScoreDB.expList or {}
	PourSocialScoreDB.typeList = PourSocialScoreDB.typeList or {}
	PourSocialScoreDB.delList = PourSocialScoreDB.delList or {}
	PourSocialScoreDB.syncInfo = PourSocialScoreDB.syncInfo or {}
	PourSocialScoreDB.playerData = PourSocialScoreDB.playerData or {}
	PourSocialScoreDB.guildData = PourSocialScoreDB.guildData or {}
	if PourSocialScoreDB.imported == nil then PourSocialScoreDB.imported = false end

	-- Options keep only what differs from the default (PSS_Options.lua)
	if PourSocialScoreDB.defexpire ~= nil and not tonumber(PourSocialScoreDB.defexpire) then
		PourSocialScoreDB.defexpire = nil
	end
	M.PSS_ApplyOptionDefaults()

	-- saved data upgrades that run before the built-in filters are rebuilt
	-- (PSS_Upgrade.lua)
	M.PSS_RunUpgradeFields()

	-- Built-in rules come from code; SavedVariables only hold their on/off state.
	M.PSS_ExpandFilters()
	-- a shipped guild group's rule is on: load its member lists before chat
	-- starts (PourSocialScore_Communities)
	if M.PSS_LoadActiveManagedData then M.PSS_LoadActiveManagedData() end

	V.PSS_LoadedTime = GetTime()

	--M.SyncIgnoreList(PourSocialScoreDB.chatmsg == false)

	V.PSS_Loaded = true
	starting = false

	-- the rest of the upgrade steps, then the upgrade record
	M.PSS_RunUpgradeData(fresh)
	-- PourSocialScore_Logging was loaded for the upgrade: add the waiting
	-- lines, trim and tidy the history now
	local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	if isLoaded and isLoaded("PourSocialScore_Logging") and M.PSS_LoadLogging then M.PSS_LoadLogging() end

	M.PSS_HookFunctions()

	self:UnregisterEvent("IGNORELIST_UPDATE")
	self:UnregisterEvent("PLAYER_ENTERING_WORLD")
	self:UnregisterEvent("ADDON_LOADED")

	-- (The old "auto-update default chat filters" pass is gone: built-in rules
	-- are rebuilt from code on every load by M.PSS_ExpandFilters.)
end

-------------------
-- EVENT HANDLER --
-------------------

-- One-time import from a previous build's saved variables. PourSocialScore
-- uses its own SavedVariables (PourSocialScoreDB), so nothing is shared with
-- older builds. If an older build is enabled for one login alongside this one
-- (it loads first via OptionalDeps), its data is copied in here once.
-- Newest first. Names are split so the rebrand never rewrites them.
local LEGACY_DB_NAMES = {
	{ var = "Poor" .. "SocialScoreDB" },
	{ var = "Global" .. "IgnoreDB" },
}

local function deepCopy(v, seen)
	if type(v) ~= "table" then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local t = {}
	seen[v] = t
	for k, val in pairs(v) do t[deepCopy(k, seen)] = deepCopy(val, seen) end
	return t
end

function M.PSS_ImportLegacyDB()
	if PourSocialScoreDB ~= nil then return false end
	local old, from
	for _, src in ipairs(LEGACY_DB_NAMES) do
		if type(_G[src.var]) == "table" then old, from = _G[src.var], src break end
	end
	if not old then return false end
	PourSocialScoreDB = deepCopy(old)
	-- default chat filter IDs were renamed GILnnnn -> PSSnnnn
	if type(PourSocialScoreDB.filterID) == "table" then
		for i, id in ipairs(PourSocialScoreDB.filterID) do
			if type(id) == "string" then PourSocialScoreDB.filterID[i] = (id:gsub("^G" .. "IL", "PSS")) end
		end
	end
	PourSocialScoreDB.importedLegacyAt = date("%Y-%m-%d %H:%M:%S")
	PourSocialScoreDB.importedFrom = from.var
	-- (the source's old name is recorded in importedFrom, not shown)
	M.ShowMsg("Imported your ignore list, chat filters and guild rules from your previous version of this addon. You can now disable the old one.")
	return true
end

-- Warn about players on any list in the group (once per player per group).
local rosterCheckQueued, rosterCheckDeferred = false, false
local function CheckGroupForIgnored()
	rosterCheckQueued = false
	if not IsInGroup() or not PourSocialScoreDB then return end
	if M.PSS_Opt("listWarnings") == false then return end
	if InCombatLockdown and InCombatLockdown() then rosterCheckDeferred = true return end
	gotGroup = true
	local prefix	= IsInRaid() and "raid" or "party"
	local doWarn	= false
	for count = 1, GetNumGroupMembers() do
		local name = GetUnitName(prefix..count, true)
		-- O(1) lookups on the raw name (every list); the display name is
		-- only built for a player who is actually listed
		if type(name) == "string" and not M.PSS_IsSecret(name) and name ~= "" and M.PSS_PersonListed(name) then
			name = M.Proper(M.addServer(name))
			if M.hasGroupWarning(name) == 0 then
				doWarn = true
				V.groupWarning[#V.groupWarning + 1] = name
			end
		end
	end
	if doWarn then
		M.ShowMsg(format(L["CHAT_1"], #V.groupWarning, table.concat(V.groupWarning, "\n")))
		M.Events.Fire("GROUP_WARNING", V.groupWarning)
	end
end

local function EventHandler (self, event, sender, ...)

	--print ("DEBUG event=".. (event or "nil") .. " sender=" .. (sender or "nil"))

	--if (event == "CHANNEL_INVITE_REQUEST") then
	--	print ("DEBUG RECEIVED CHANNEL INVITE REQUEST")
	--end

	if event == "PLAYER_LOGOUT" then
		-- Fires on logout and /reload, before SavedVariables are written.
		M.PSS_CollapseFilters()
		-- managed guild lists: write only the delta
		if M.PSS_FlushManaged then pcall(M.PSS_FlushManaged) end
		-- this session's counts are not kept past it
		if M.PSS_History and M.PSS_History.EndSession then M.PSS_History.EndSession() end
		-- the log saved one group per person (3.2.0-dev007)
		if M.PSS_History and M.PSS_History.PackForSave then pcall(M.PSS_History.PackForSave) end
		return
	end

	if (event == "ADDON_LOADED") and (sender == "PourSocialScore") then
		M.PSS_ImportLegacyDB()
		gotLoaded = true
	end

	if event == "IGNORELIST_UPDATE" then
		gotUpdate = true
	end

	if event == "PLAYER_ENTERING_WORLD" then
		gotEntering = true
		-- sender = isInitialLogin, then isReloadingUi: a login or /reload starts
		-- a new session (a loading screen does not)
		if M.PSS_History then M.PSS_History.StartSession(sender, (...)) end
	end

	if event == "GROUP_ROSTER_UPDATE" then
		-- Raids fire this many times in a row: check once, 1 s after the
		-- last one, and never while in combat (checked when combat ends).
		if not IsInGroup() then
			gotGroup		= false
			V.groupWarning = {}
		elseif V.PSS_Loaded and PourSocialScoreDB and not rosterCheckQueued then
			rosterCheckQueued = true
			C_Timer.After(1, CheckGroupForIgnored)
		end
	end
	if event == "PLAYER_REGEN_ENABLED" and rosterCheckDeferred then
		rosterCheckDeferred = false
		CheckGroupForIgnored()
	end

	-- Party/guild invites, duels and trades: handled by PSS_ChatBlock.lua

	if gotLoaded == true and gotEntering == true then
		safeToLoad = true
	end

	if safeToLoad == true then
		ApplicationStartup(self)
	end
end

-----------------------------
-- Pour Social Score Main --
-----------------------------

PSSFRAME = CreateFrame("FRAME")

PSSFRAME:RegisterEvent("PLAYER_ENTERING_WORLD")
PSSFRAME:RegisterEvent("ADDON_LOADED")
PSSFRAME:RegisterEvent("IGNORELIST_UPDATE")
PSSFRAME:RegisterEvent("GROUP_ROSTER_UPDATE")
PSSFRAME:RegisterEvent("PLAYER_LOGOUT")
PSSFRAME:RegisterEvent("PLAYER_REGEN_ENABLED")

-- The command parser is in PourSocialScore_Libraries, loaded on the first
-- command (PSS_Commands.lua there replaces these stubs).
SLASH_PSS1		= "/pss"
SLASH_PSSGUILD1	= "/pssguild"
M.PSS_Stub("PSS_SlashPSS", "Libraries")
M.PSS_Stub("PSS_SlashGuild", "Libraries")
SlashCmdList["PSS"] = function(msg) M.PSS_SlashPSS(msg) end
SlashCmdList["PSSGUILD"] = function(msg) M.PSS_SlashGuild(msg) end

PSSFRAME:SetScript("OnEvent", EventHandler)

-------------
-- THE END --
-------------
