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
local gotEntering		= false
local safeToLoad		= false
V.groupWarning			= {}

----------------------------------
-- Pour Social Score Functions --
----------------------------------

-- Post-upgrade tidy-up of the block history (every login): lines of players
-- no longer on the Player Ignore List, of guild members in no guild rule
-- (whose rule is gone too) and of chat filters that no longer exist are
-- dropped; rule tags that point at a removed rule are cleared. Block counts
-- are not changed. A line of a kind of owner this version does not make is
-- kept. Returns the number of lines removed.
function M.PSS_TidyBlockHistory()
	local db = PourSocialScoreDB
	local History = M.PSS_History
	if type(db) ~= "table" or not History then return 0 end
	local alive = {}
	if type(db.list) == "table" and M.PSS_PlayerHistoryKey then
		local listed = {}
		for _, e in ipairs(db.list) do
			if (e.kind or "player") == "player" then
				local k = M.PSS_PlayerHistoryKey(e.name)
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
			if id and id ~= "" then
				ids[id] = true
				-- lines still under the filter's text (S3: a filter saved by an older
				-- version after it was given its id) are kept
				keys[M.PSS_History.FilterKey("", db.filterList[i])] = true
			end
		end
		-- an owner or rule tag of a form this version does not make (a newer
		-- version's) is kept (U3); a number id is this version's (S3)
		alive.f = function(o) return keys[o] == true or not (o:find("^f:t:") or o:find("^f:PSS%d+$") or o:find("^f:%d+$")) end
		alive.rule = function(id) return ids[id] == true or not tostring(id):find("^PSS%d+$") end
	end
	return History.Tidy(alive)
end

-- A start-up stage that fails prints one red line naming it and the error, is kept for /pssguild chat, and never stops
-- the stages after it (W-8: one throw used to leave the chat filter unregistered without a word). Returns ok, result.
-- M.PSS_Test.fault = "start:<name>" makes a stage fail in the harness.
M.PSS_StartFaults = {}
local function stage(name, f, ...)
	local T = M.PSS_Test
	if T and T.fault == "start:" .. name then f = function() error("injected fault", 0) end end
	local ok, res = pcall(f, ...)
	if ok then return true, res end
	M.PSS_StartFaults[#M.PSS_StartFaults + 1] = name .. ": " .. tostring(res)
	M.ChatMsg("|cffff5555Pour Social Score: start-up stage " .. name .. " failed (" .. tostring(res) .. ")|r")
	return false
end

local starting = false
local startFailed = false
local filterEnsured = false
local function ApplicationStartup(self)

	-- (loading an on-demand addon during startup fires ADDON_LOADED, which
	-- comes back here: run once)
	if V.PSS_Loaded == true or safeToLoad == false or starting or startFailed then
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
	local okp, ready = stage("prepare", M.PSS_PrepareSavedData, { quiet = fresh, startup = true })
	if not ready then startFailed = not okp; starting = false return end

	-- Ensure all core list fields exist before any UI or upgrade code uses #field.
	PourSocialScoreDB.list = PourSocialScoreDB.list or {}
	PourSocialScoreDB.delList = PourSocialScoreDB.delList or {}
	PourSocialScoreDB.playerData = PourSocialScoreDB.playerData or {}
	PourSocialScoreDB.guildData = PourSocialScoreDB.guildData or {}
	if PourSocialScoreDB.imported == nil then PourSocialScoreDB.imported = false end

	-- Options keep only what differs from the default (PSS_Options.lua)
	if PourSocialScoreDB.defexpire ~= nil and not tonumber(PourSocialScoreDB.defexpire) then
		PourSocialScoreDB.defexpire = nil
	end
	local _, defaults = stage("defaults", M.PSS_ApplyOptionDefaults)

	-- saved data upgrades that run before the built-in filters are rebuilt
	-- (PSS_Upgrade.lua), then the built-in rules, which come from code
	-- (SavedVariables only hold their on/off state). A fault in either leaves the
	-- lists unready: the filter must not decide lines on them (PSS_Loaded stays
	-- false), and the red line says which stage.
	if not stage("upgradefields", M.PSS_RunUpgradeFields, fresh, defaults or 0) or not stage("expand", M.PSS_ExpandFilters) then
		startFailed = true
		starting = false
		return
	end
	-- a shipped guild group's rule is on: load its member lists before chat
	-- starts (PourSocialScore_Communities)
	if M.PSS_LoadActiveManagedData then stage("managed", M.PSS_LoadActiveManagedData) end

	V.PSS_LoadedTime = GetTime()

	--M.SyncIgnoreList(PourSocialScoreDB.chatmsg == false)

	V.PSS_Loaded = true
	starting = false

	-- the rest of the upgrade steps, then the upgrade record
	stage("upgradedata", M.PSS_RunUpgradeData, fresh)
	-- entries past their expiry go now (N40), then once a day after combat
	stage("expire", M.PSS_ExpireEntries)
	-- the lists are in their final form: hear unit and /who captures only if they can be used (P3)
	if M.PSS_ApplyCapture then stage("capture", M.PSS_ApplyCapture) end
	if PourSocialScoreDB.gfxPending and M.PSS_Need("Libraries") and M.PSS_GfxAsk then stage("gfx", M.PSS_GfxAsk) end	-- the graphics keep prompt (PSS_Graphics.lua)
	-- PourSocialScore_Logging was loaded for the upgrade: add the waiting
	-- lines, trim and tidy the history now
	local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	if isLoaded and isLoaded("PourSocialScore_Logging") and M.PSS_LoadLogging then stage("logging", M.PSS_LoadLogging) end

	stage("hooks", M.PSS_HookFunctions)

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
-- The list is rebuilt from the roster on each check, so a player who left
-- is not named again; the warning shows when someone new joins (N47).
local rosterCheckQueued, rosterCheckDeferred = false, false
local function CheckGroupForIgnored()
	rosterCheckQueued = false
	if not IsInGroup() or not PourSocialScoreDB then return end
	if M.PSS_Opt("listWarnings") == false then return end
	if InCombatLockdown and InCombatLockdown() then rosterCheckDeferred = true return end
	local prefix	= IsInRaid() and "raid" or "party"
	local doWarn	= false
	local inGroup = {}
	for count = 1, GetNumGroupMembers() do
		local name = GetUnitName(prefix..count, true)
		-- O(1) lookups on the raw name (every list); the display name is
		-- only built for a player who is actually listed
		if type(name) == "string" and not M.PSS_IsSecret(name) and name ~= "" and M.PSS_PersonListed(name) then
			name = M.Proper(M.addServer(name))
			if M.hasGroupWarning(name) == 0 then doWarn = true end
			inGroup[#inGroup + 1] = name
		end
	end
	V.groupWarning = inGroup
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
		-- the player records are saved sparse (S3)
		if M.PSS_CompactPlayers then pcall(M.PSS_CompactPlayers) end
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
		M.PSS_StartComponents()
		gotLoaded = true
	end

	if event == "PLAYER_ENTERING_WORLD" then
		gotEntering = true
		-- the world is up: an event the client refused at start-up is added once more (W-8; once, no timer)
		if M.PSS_RetryFilter and not filterEnsured then
			filterEnsured = true
			stage("retry", M.PSS_RetryFilter)
		end
		-- sender = isInitialLogin, then isReloadingUi: a login or /reload starts
		-- a new session (a loading screen does not)
		if M.PSS_History then M.PSS_History.StartSession(sender, (...)) end
	end

	if event == "GROUP_ROSTER_UPDATE" and M.PSS_On("filtering") then
		-- (the party warning belongs to Social Filtering, issue 181)
		-- Raids fire this many times in a row: check once, 1 s after the
		-- last one, and never while in combat (checked when combat ends).
		if not IsInGroup() then
			V.groupWarning = {}
		elseif V.PSS_Loaded and PourSocialScoreDB and not rosterCheckQueued then
			rosterCheckQueued = true
			C_Timer.After(1, CheckGroupForIgnored)
		end
	end
	if event == "PLAYER_REGEN_ENABLED" then
		if rosterCheckDeferred then
			rosterCheckDeferred = false
			CheckGroupForIgnored()
		end
		-- a quiet moment: entries that expired since the last check (N40)
		if V.PSS_Loaded then M.PSS_ExpireEntries(false, true) end
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
-- /acp is /pss acp (the AddOns tab, 3.6.0), under our own key and only when
-- no other addon owns /acp (the client runs the first it finds)
-- Enabled components (issue 181): read once at ADDON_LOADED. What starts at
-- file load for a component is started here, only when it is on, and a
-- change applies after a reload (hooks cannot be removed).
function M.PSS_StartComponents()
	stage("snap", M.PSS_SnapComponents)
	stage("watch", M.PSS_WatchStart)
	if M.PSS_On("filtering") then
		if M.PSS_StartBlocking then stage("blocking", M.PSS_StartBlocking) end
		if M.PSS_StartIgnoreSync then stage("ignoresync", M.PSS_StartIgnoreSync) end
	end
	stage("compartment", M.PSS_StartCompartment, M.PSS_On("addons"), M.PSS_On("dtt"))
	stage("components", function()
		if M.PSS_On("addons") then
			-- /acp is /pss acp (the AddOns tab, 3.6.0), under our own key and only
			-- when no other addon owns /acp (the client runs the first it finds)
			local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
			if SlashCmdList["ACP"] == nil and not (isLoaded and isLoaded("ACP")) then
				SLASH_PSSACP1 = "/acp"
				SlashCmdList["PSSACP"] = function(msg) M.PSS_SlashPSS("acp " .. (msg or "")) end
			else
				M.PSS_ACPTaken = true
			end
		else
			BINDING_NAME_PSS_OPEN_ADDONS = "Open Addon Manager (Addon Manager off)"
		end
		-- PSS Drop Cheapest Thing (money-helper): only the lines that start it;
		-- every function is in Libraries, loaded now only when it is on
		if M.PSS_On("dtt") then
			if M.PSS_Need("Libraries") and M.PSS_DttStart then M.PSS_DttStart() end
			local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
			if SlashCmdList["DROPTHECHEAPESTTHING"] == nil and not (isLoaded and isLoaded("DropTheCheapestThing")) then
				SLASH_PSSDTT1 = "/dropcheap"
				SLASH_PSSDTT2 = "/dtct"
				SlashCmdList["PSSDTT"] = function(msg) M.PSS_SlashPSS("dtt " .. (msg or "")) end
			else
				M.PSS_DTTTaken = true
			end
		else
			BINDING_NAME_PSS_DTT = "Drop the cheapest thing (PSS Drop Cheapest Thing off)"
		end
		-- The Warehouse and the shared item layer (warehouse-helper): everything is in
		-- Libraries; with both switches off nothing loads and nothing is registered.
		-- It starts at PLAYER_LOGIN, when every addon has loaded (it steps aside for Syndicator).
		if M.PSS_On("warehouse") or M.PSS_On("bags") then
			M.PSS_Trigger({ id = "whboot", on = { "PLAYER_LOGIN" }, settle = "now", run = "wh.boot" })
		end
	end)
end

PSSFRAME:SetScript("OnEvent", EventHandler)

-------------
-- THE END --
-------------
