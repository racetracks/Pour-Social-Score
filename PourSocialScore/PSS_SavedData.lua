------------------------------------------------------------------------
-- POUR SOCIAL SCORE - SAVED DATA (3.0)
--
-- The saved data is split over three addons:
--   PourSocialScore          PourSocialScoreDB: the upgrade record,
--                            bookkeeping, the outbox (block lines waiting
--                            for PourSocialScore_Logging, PSS_ChatHistory.lua)
--                            and the recent counts (this session, last 24
--                            hours; 3.2)
--   PourSocialScore_Options  PSS_OptionsDB    options that differ from their
--                                             default, window sizes, places
--                                             and column widths
--   (always loaded,          PSS_PlayersDB    the Player Ignore List
--    data only)              PSS_GuildsDB     the Guild Ignore List
--                            PSS_RulesDB      chat rules and built-in on/off
--                            PSS_CountsDB     hourly stats, totals, chat rule
--                                             counts and format markers
--   PourSocialScore_Logging  PSS_LoggingDB    block history and kept lines
--   (on demand, data only)
-- The block counts of each player and guild member stay on their record.
-- Every count is always loaded, so a block is counted without loading
-- PourSocialScore_Logging; only the lines wait in the outbox.
-- Code keeps reading and writing PourSocialScoreDB.<key>. A key listed in
-- LAYOUT lives in one of the Options tables: PourSocialScoreDB gets a
-- metatable that sends reads and writes of keys it does not hold to that
-- table. Keys it still holds are read directly.
--
-- The split (upgrade steps 2 and 3) moves a routed key that
-- PourSocialScoreDB still holds (a 2.0 save, a fresh or reset save, a legacy
-- import) to its table: check, count, move, validate, clean. It moves table references, so
-- nothing is copied. If the counts after the move differ, the move is undone
-- and retried at the next login.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

-- group -> saved table (global), and the addon that saves it
local GROUPS = {
	options	= "PSS_OptionsDB",
	players	= "PSS_PlayersDB",
	guilds	= "PSS_GuildsDB",
	rules	= "PSS_RulesDB",
	counts	= "PSS_CountsDB",
	logging	= "PSS_LoggingDB",
}
M.PSS_SV_GROUPS = GROUPS
local OWNER = {
	options	= "PourSocialScore_Options",
	players	= "PourSocialScore_Options",
	guilds	= "PourSocialScore_Options",
	rules	= "PourSocialScore_Options",
	counts	= "PourSocialScore_Options",
	logging	= "PourSocialScore_Logging",
}
-- addons that load on demand: not loaded at startup is normal
local ON_DEMAND = { PourSocialScore_Logging = "Logging" }

-- group -> the PourSocialScoreDB keys it holds. The options in
-- M.PSS_OPTIONS (PSS_Options.lua) are added to "options".
-- Retired keys stay listed so an upgrade step can still clear them in
-- PSS_OptionsDB (charOptions, optionsV2012; euiIntegration, no longer an
-- option from 3.4.0.25; blizzardSync, a per-player tick from 3.4.1.35; the
-- seven parallel player arrays at the end of "players", replaced by "list"
-- in 3.4.1.51).
local LAYOUT = {
	options	= { "showIgnoreDebug", "windowSizes", "windowPoints", "columnWidths", "charOptions", "optionsV2012",
				"euiIntegration", "blizzardSync", "gfxSets", "gfxPending" },
	players	= { "list", "delList", "playerData",
				"ignoreList", "typeList", "factionList", "dateList", "notes", "expList", "syncInfo" },
	guilds	= { "guildData", "guildExclusions", "guildGroupOpen", "scanFieldsDefaultV1", "guildPlayerCleanupV3" },
	rules	= { "filterList", "filterDesc", "filterActive", "filterID", "builtinRules", "filterFormat",
				"optInFiltersV1", "nextFilterId" },
	counts	= { "blockStats", "historyFormat", "hiddenTotal", "filterTotal", "filterWhisperTotal",
				"filterPrivateTotal", "filterCount", "filterBlocked", "filterBlockedLast", "builtinStats",
				"guildRuleCountsV1" },
	logging	= { "blockLog", "blockKeep" },
}

-- PourSocialScoreDB key -> group
local ROUTE = {}
M.PSS_SV_ROUTE = ROUTE

local function buildRoute()
	for g, keys in pairs(LAYOUT) do
		for _, k in ipairs(keys) do ROUTE[k] = g end
	end
	for _, o in ipairs(M.PSS_OPTIONS or {}) do ROUTE[o.key] = "options" end
end

-- addon -> loaded (its tables are saved). A key is routed only while the
-- addon that saves its table is loaded; otherwise it stays in
-- PourSocialScoreDB. (The block history is only read through
-- M.PSS_History.Log / Keep, which load PourSocialScore_Logging first.)
local active = {}

local function groupTable(key)
	local g = ROUTE[key]
	return g and active[OWNER[g]] and _G[GROUPS[g]]
end

local router = {
	__index = function(_, key)
		local t = groupTable(key)
		if t then return t[key] end
	end,
	__newindex = function(db, key, value)
		local t = groupTable(key)
		if t then t[key] = value else rawset(db, key, value) end
	end,
}

local function loaded(name)
	local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	return f ~= nil and f(name) and true or false
end

-- The saved data check is in Libraries (PSS_Validate.lua, 3.4.1 P6): it loads
-- for /pss check and at the one login where saved keys move.
M.PSS_Stub("PSS_Validate", "Libraries")
M.PSS_Stub("PSS_PrintValidation", "Libraries")

local function counts()
	return M.PSS_Validate and M.PSS_Validate().n or {}
end

-- the keys whose numbers differ ("" when none)
local function compare(before, after)
	local bad = {}
	for k, v in pairs(before) do if after[k] ~= v then bad[#bad + 1] = k end end
	for k in pairs(after) do if before[k] == nil then bad[#bad + 1] = k end end
	table.sort(bad)
	return table.concat(bad, ", ")
end

local warned = {}
local split = {}		-- addon -> its data is split

-- The Options tables exist, PourSocialScoreDB routes its moved keys, and
-- any routed key PourSocialScoreDB still holds is moved. Run at startup,
-- whenever PourSocialScoreDB is replaced (a reset) and when
-- PourSocialScore_Logging loads. opts.wipe empties the tables first (a
-- reset); opts.quiet prints nothing (a new save); opts.startup: the login
-- pass. Returns false when PourSocialScore_Options is missing (nothing can
-- be read; startup stops).
function M.PSS_PrepareSavedData(opts)
	opts = opts or {}
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return false end
	buildRoute()
	if getmetatable(db) ~= router then setmetatable(db, router) end

	-- Load PourSocialScore_Logging at this login when its data has to move:
	-- a 2.0 save (the history is still in PourSocialScoreDB) or a
	-- 3.0.0-dev14 save (the counts are in PSS_LoggingDB, upgrade step 3), so
	-- the whole upgrade happens at once. A reset also empties it.
	local rec = rawget(db, "upgrade")
	local need = opts.wipe or (opts.startup and type(rec) == "table" and rec.step == 3)
	if opts.startup then
		for _, k in ipairs(LAYOUT.logging) do if rawget(db, k) ~= nil then need = true end end
	end
	if need and M.PSS_LoadLogging then
		-- (PSS_LoadLogging comes back here once it is loaded)
		if not loaded("PourSocialScore_Logging") and M.PSS_Need then M.PSS_Need("Logging") end
	end

	-- check: the data addons are loaded, so their tables will be saved
	local ok = true
	for g, name in pairs(GROUPS) do
		local owner = OWNER[g]
		active[owner] = loaded(owner)
		split[owner] = active[owner]
		if active[owner] then
			if type(_G[name]) ~= "table" then _G[name] = {} end
			if opts.wipe then for k in pairs(_G[name]) do _G[name][k] = nil end end
		elseif ON_DEMAND[owner] then
			-- not loaded yet: split while PourSocialScoreDB holds none of its keys
			local none = true
			for _, k in ipairs(LAYOUT[g]) do if rawget(db, k) ~= nil then none = false end end
			split[owner] = none
		else
			ok = false
			if not warned[owner] then
				warned[owner] = true
				M.ShowMsg("|cffff3333" .. owner .. " is not loaded:|r Pour Social Score can't read your settings and lists. Install every folder from the zip.")
			end
		end
	end
	if not ok then return false end

	-- a key saved in a table it no longer belongs to moves to its own
	-- (3.0.0-dev15: the counts, from PSS_LoggingDB to PSS_CountsDB)
	for g, name in pairs(GROUPS) do
		local t = active[OWNER[g]] and _G[name]
		if t then
			for k, v in pairs(t) do
				local want = ROUTE[k]
				if want and want ~= g and active[OWNER[want]] then
					local to = _G[GROUPS[want]]
					if to[k] == nil then to[k] = v end
					t[k] = nil
				end
			end
		end
	end

	local keys, movedTo = {}, {}
	for k, g in pairs(ROUTE) do
		if active[OWNER[g]] and rawget(db, k) ~= nil then
			keys[#keys + 1] = k
			movedTo[OWNER[g]] = true
		end
	end
	if #keys == 0 then return true end

	-- count, move (a key PourSocialScoreDB holds wins: it is what code reads
	-- today), validate (not for a new or reset save: nothing to lose, and the
	-- check is in Libraries)
	local before = not (opts.wipe or (opts.quiet and opts.startup)) and counts() or nil
	local old = {}
	for _, k in ipairs(keys) do
		local t = _G[GROUPS[ROUTE[k]]]
		old[k] = t[k]
		t[k] = rawget(db, k)
		rawset(db, k, nil)
	end
	local diff = before and compare(before, counts()) or ""
	if diff ~= "" then
		-- undo: put every key back; the step is not recorded, so it runs again
		-- at the next login
		for _, k in ipairs(keys) do
			local t = _G[GROUPS[ROUTE[k]]]
			rawset(db, k, t[k])
			t[k] = old[k]
		end
		for owner in pairs(movedTo) do split[owner] = false end
		M.ShowMsg("|cffff3333Saved data not moved|r (counts differ: " .. diff .. "). Nothing was changed; it tries again at the next login.")
		return true
	end

	if not opts.quiet then
		local n = before
		if movedTo.PourSocialScore_Options then
			M.ShowMsg(("Saved data moved to PourSocialScore_Options: %d Player Ignore List entries (%d notes), %d guild rules (%d members), %d custom chat rules, %d options changed from default."):format(
				n.list or 0, n.listNotes or 0, n.guildRules or 0, n.membersStored or 0, n.filters or 0, n.optionsChanged or 0))
		end
		if movedTo.PourSocialScore_Logging then
			M.ShowMsg(("Saved data moved to PourSocialScore_Logging: %d block history lines, %d kept lines for %d people."):format(
				n.logLines or 0, n.keptLines or 0, n.keptPeople or 0))
		end
	end
	return true
end

-- the data saved by that addon is split (upgrade step 2: Options, step 3:
-- Logging)
function M.PSS_SavedDataSplit(owner) return split[owner] == true end
