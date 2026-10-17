-----------------------------------
-- Pour Social Score Upgrade Steps --
-----------------------------------
local addonName, addon	= ...
local M = addon.M -- shared methods
local L = addon.L -- localization entries
local V = addon.V -- runtime state

-- Saved data upgrades as numbered steps (the Questie model):
--   * STEPS[1..N] run first to last; each has its id (its place, the number
--     recorded) and its parts. Append new steps at the end; never reorder,
--     renumber or change a step once it has been released.
--   * PourSocialScoreDB.upgrade = { step = N, version = "3.0.0", at = time }
--     records how many steps this save has had, the addon version that last
--     upgraded it and when (server time). Older versions ignore it.
--   * At login a step runs when the save has not had it yet. A step marked
--     "always" also runs at every login: step 1 is the 2.0 login pass (its
--     one-time conversions are guarded by a nil check or a format marker).
--   * Every step must be safe to run twice.
-- A step's parts run in the order listed (step 1's order is 2.0's). A part
-- has a feature (FEATURES, the upgrade report's groups) and up to two
-- functions: "fields" runs before the built-in chat filters are rebuilt from
-- code (M.PSS_ExpandFilters), "data" after it. A function returning false
-- pauses its step and every later one for this login (not recorded).
-- Keys nothing reads any more are named once in RETIRED and dropped at every
-- login, after the data parts (a step may still read one first).

local db	-- PourSocialScoreDB while a pass runs
local blocked	-- first step whose part returned false this login (not recorded)
local out	-- counts per feature, only on a login that reports (see tally)
local oldFolders	-- folders the window no longer uses, named on the cleanup line
local newer	-- the save's version when it is newer than this one (a downgrade)
M.PSS_UNDO_CAP = 1048576		-- an undo copy larger than this is not kept (PB-10)
local snap	-- the stores as they were before a due step ran (the guard restores them; the undo slot keeps them)
local skipSnap	-- a new save: nothing to keep
local failed	-- { step, feature, code, text } when a step part raised or failed its check this login
local retryAt	-- the step to try again once this session
local retrying	-- a retry is running

-- The report's groups, in print order.
local FEATURES = { "filters", "players", "guilds", "managed", "history", "options", "addons", "cleanup" }
M.PSS_UPGRADE_FEATURES = FEATURES

-- Adds n to out[feature][key]. Nothing is counted (or built) on a login
-- that does not report.
local function tally(feature, key, n)
	if not out or not n or n == 0 then return end
	local f = out[feature]
	if not f then
		f = {}
		out[feature] = f
	end
	f[key] = (f[key] or 0) + n
end

-- Keys nothing reads any more, dropped at every login (step 1 dropped the
-- first seven, steps 1, 5, 7, 8, 9 and 10 the rest, each in its own place). Only
-- keys named here are ever deleted, so a newer version's fields are kept.
local RETIRED = {
	"autoIgnore", "autoUpdate", "autoCount", "autoTime", "attachFriends",	-- never used (2.0)
	"syncList", "filterHistory",	-- 2.0 alpha data
	"blockStats",		-- the hourly session / 24 hour counts (3.3.0-dev002: History.Recent*)
	"optionsV2012", "charOptions",	-- 2.0.12 marker, per-character overrides (step 5)
	"historySize",		-- never read (historyTotal is the setting)
	"euiIntegration", "windowSizes", "columnWidths",	-- the old windows (3.4.0.25, step 7)
	"blizzardSync",		-- a per-player tick from 3.4.1.35 (step 8 reads it first)
	"ignoreList", "typeList", "factionList", "dateList", "notes", "expList", "syncInfo",	-- one record each in db.list (S2b, step 9 reads them first)
	"showIgnoreDebug",	-- nothing read it (S3, step 10)
}
M.PSS_UPGRADE_RETIRED = RETIRED

local function dropRetired()
	for i = 1, #RETIRED do
		local k = RETIRED[i]
		if db[k] ~= nil then
			db[k] = nil
			tally("cleanup", "retired", 1)
		end
	end
end

------------------------------------------------------------------------
-- FORWARD COMPATIBILITY (core uplift U3, 10_CORE_UPLIFT.md 2.3)
--
-- The schema map (PSS_Schema.lua) names every field this version knows. A
-- saved rule this version cannot use is not applied and stays in the save
-- unchanged, so a version that knows it applies it again:
--   * a custom chat filter that does not compile (a tag added later)
--   * a guild rule of a shipped list this version does not have, or with a
--     field the map does not name
--   * an option this version does not have
-- After a version change (either way) the upgrade report names them and
-- /pss export unused copies them out.
------------------------------------------------------------------------
local knownSets = {}	-- record kind -> { field = true }, built on first use

-- Does this version know field of a record kind (its fields or old ones)?
function M.PSS_SchemaKnows(kind, field)
	local set = knownSets[kind]
	if not set then
		set = {}
		local schema = M.PSS_SCHEMA or {}
		for _, k in ipairs({ kind, kind .. "Old" }) do
			for word in (schema[k] or ""):gmatch("[%a_][%w_]*[^%s]*") do set[word:match("^[%a_][%w_]*")] = true end
		end
		knownSets[kind] = set
	end
	return set[field] == true
end

local function shippedGroup(key)
	for _, grp in ipairs((addon.MANAGED and addon.MANAGED.groups) or {}) do
		if grp.key == key then return true end
	end
	return false
end

-- A guild rule this version cannot use: a shipped list it does not have,
-- or a field the map does not name (the _ fields are runtime fields).
function M.PSS_GuildRuleUnusable(g)
	if type(g) ~= "table" then return false end
	if g.managed and not shippedGroup(g.managed) then return true end
	for k in pairs(g) do
		if type(k) ~= "string" or (k:sub(1, 1) ~= "_" and not M.PSS_SchemaKnows("guild", k)) then return true end
	end
	return false
end

-- The saved rules and settings this version cannot use:
-- { filters = { index, ... }, guilds = { key, ... }, options = { key, ... } }
function M.PSS_UnusableRules()
	local sv = PourSocialScoreDB
	local u = { filters = {}, guilds = {}, options = {} }
	if type(sv) ~= "table" then return u end
	local list = type(sv.filterList) == "table" and sv.filterList or {}
	for i = 1, #list do
		local text = list[i]
		if not M.PSS_IsBuiltinFilter(i) and type(text) == "string" and not M.PSS_IsGuildRuleText(text)
			and M.PSS_CompileFilter(text) == false then
			u.filters[#u.filters + 1] = i
		end
	end
	for key, g in pairs(type(sv.guildData) == "table" and sv.guildData or {}) do
		if M.PSS_GuildRuleUnusable(g) then u.guilds[#u.guilds + 1] = key end
	end
	table.sort(u.guilds, function(a, b) return tostring(a) < tostring(b) end)
	local route = M.PSS_SV_ROUTE or {}
	local retired = {}
	for i = 1, #RETIRED do retired[RETIRED[i]] = true end
	for key in pairs(type(PSS_OptionsDB) == "table" and PSS_OptionsDB or {}) do
		if type(key) ~= "string" or (not route[key] and not retired[key]) then u.options[#u.options + 1] = key end
	end
	table.sort(u.options, function(a, b) return tostring(a) < tostring(b) end)
	return u
end

-- a parallel list of n entries: each one value, or each a new table
local function fill(n, value)
	local t = {}
	for i = 1, n do t[i] = value end
	return t
end

local function fillTables(n)
	local t = {}
	for i = 1, n do t[i] = {} end
	return t
end


-- Step 10: is this a Camelot save (the client, and its realm)? The name
-- repair only runs on one: a Retail realm has the same name shapes.
local function isCamelot()
	local iface = GetBuildInfo and select(4, GetBuildInfo())
	if type(iface) ~= "number" or iface >= 20000 then return false end
	local realm = M.PSS_CanonRealm(M.PSS_OwnRealm())
	return realm ~= nil and realm:find("^classicbetapvp") ~= nil
end

-- anything saved that carries a name (worth loading the repair for)
local function hasNames()
	local sv = PourSocialScoreDB
	if type(sv.list) == "table" and #sv.list > 0 then return true end
	if type(sv.delList) == "table" and #sv.delList > 0 then return true end
	for _, g in pairs(type(sv.guildData) == "table" and sv.guildData or {}) do
		if type(g) == "table" and type(g.members) == "table" and next(g.members) ~= nil then return true end
	end
	return false
end

-- Step 10's Camelot name repair (PourSocialScore_Libraries, PSS_Camelot.lua)
local function camelotRepair()
	if not (isCamelot() and hasNames()) then return end
	if not (M.PSS_Need and M.PSS_Need("Libraries") and M.PSS_RepairCamelotNames) then return false end
	local members, players, maybe = M.PSS_RepairCamelotNames()
	tally("guilds", "camelot", members)
	tally("players", "camelot", players)
	if #maybe > 0 then M.ShowMsg(L["UPG_CAMELOT_MAYBE"]:format(#maybe, table.concat(maybe, ", "))) end
end

-- Step 11's move of PSS_CharDB (3.6.x, this character's addon profiles) into the
-- account-wide owned keys (PourSocialScore_Libraries, PSS_AddonsQuery.lua)
local retryDeclared = false
local function moveCharDB()
	local c = _G["PSS_CharDB"]
	if type(c) ~= "table" then return end
	if next(c) ~= nil then
		local loaded = M.PSS_Need and M.PSS_Need("Libraries")
		if not (loaded and M.PSS_AddonCharMove) then
			-- Libraries cannot load now (issue 224, DEC-00238): one trigger row retries on the
			-- next moment the load can succeed, runs once and takes itself down; PSS_CharDB is
			-- untouched until the move completes, and the next login still retries
			-- (Libraries loaded without the move: the addon manager is off, nothing to wait for)
			if not loaded and not retryDeclared and M.PSS_Trigger then
				retryDeclared = true
				M.PSS_Trigger({ id = "charmove", on = { "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA" },
					settle = "now", run = "upg.charmove" })
			end
			return
		end
		local moved, kept = M.PSS_AddonCharMove(c)
		tally("addons", "moved", moved)
		tally("addons", "kept", kept)
	end
	if next(c) == nil then _G["PSS_CharDB"] = nil end
end

local STEPS = {
	-- 1: everything 2.0 did at login, split by feature.
	{
		id = 1,
		always = true,
		parts = {
			{
				feature = "players",
				fields = function()
					if db.delList == nil then
						db.delList = {}
						tally("players", "lists", 1)
					end
					-- The parallel arrays only exist in a save before step 9 (a 2.0
					-- save may lack some: step 9 reads a missing one as its default,
					-- so these backfills are only for the report's count).
					local names = db.ignoreList
					local legacy = type(names) == "table" and not (type(db.list) == "table" and #db.list > 0)
					local n = legacy and #names or 0
					if legacy then
						if db.expList == nil then
							db.expList = fill(n, 0)
							tally("players", "lists", 1)
						end
						if db.syncInfo == nil then
							db.syncInfo = fillTables(n)
							tally("players", "lists", 1)
						end
						if db.typeList == nil then
							db.typeList = fill(n, "player")
							tally("players", "lists", 1)
						end
					end
					if db.revision == nil then
						db.revision = 1
						local renamed = 0
						if legacy then
							for count = 1, n do
								names[count] = M.Proper(names[count])
							end
							renamed = n
						elseif type(db.list) == "table" then
							for count = 1, #db.list do
								local e = db.list[count]
								if type(e) == "table" and type(e.name) == "string" then e.name = M.Proper(e.name) end
							end
							renamed = #db.list
						end
						tally("players", "renamed", renamed)
					end
				end,
			},
			{
				feature = "filters",
				fields = function()
					if db.filterTotal == nil then
						db.filterTotal = 0
					end

					if db.filterList == nil or db.filterDesc == nil or db.filterCount == nil then
						M.ResetSpamFilters()
						tally("filters", "reset", 1)
					end

					local n = #db.filterDesc
					if db.filterActive == nil then
						db.filterActive = fill(n, true)
						tally("filters", "lists", 1)
					end

					if db.filterID == nil then
						M.PSS_AssignLegacyFilterIDs()
						tally("filters", "ids", n)
					end

					if db.filterBlocked == nil then
						db.filterBlocked = fillTables(n)
						tally("filters", "lists", 1)
					end

					if db.filterBlockedLast == nil then
						db.filterBlockedLast = fill(n, 0)
						tally("filters", "lists", 1)
					end

					db.filterWhisperTotal = tonumber(db.filterWhisperTotal) or 0
					db.filterPrivateTotal = tonumber(db.filterPrivateTotal) or 0
				end,
			},
			{
				-- player records, guild rules and members, shipped rules and
				-- the block history format (guild module), now that the core
				-- lists exist; it counts into each feature itself
				feature = "guilds",
				data = function()
					if M.PSS_UpgradeLegacyData then M.PSS_UpgradeLegacyData(tally) end
				end,
			},
			{
				feature = "filters",
				data = function()
					-- guild rule blocks are guild blocks only (2.0.39): undo the second count
					if M.PSS_UnlinkGuildRuleCounts then tally("filters", "unlinked", M.PSS_UnlinkGuildRuleCounts()) end
				end,
			},
			{
				feature = "players",
				data = function()
					-- records of players no longer listed, and fields records no longer keep
					if M.PSS_TidyPlayerData then tally("players", "tidied", M.PSS_TidyPlayerData()) end
				end,
			},
			{
				feature = "history",
				data = function()
					-- then tidy the block history (lines of things that are gone); not
					-- loaded yet: done when PourSocialScore_Logging loads
					if M.PSS_LoggingReady and M.PSS_LoggingReady() then
						local tidied = M.PSS_TidyBlockHistory()
						tally("history", "tidied", tidied)
						if tidied > 0 and M.PSS_RequestGC then M.PSS_RequestGC("history tidied") end
					end
				end,
			},
		},
	},
	-- 2: options, players, guilds and rules live in PourSocialScore_Options.
	-- The move itself runs before any other startup code reads the data
	-- (M.PSS_PrepareSavedData, PSS_SavedData.lua); this records it, and
	-- returns false (step not recorded) when it did not happen.
	{
		id = 2,
		parts = {
			{ feature = "options", fields = function() return M.PSS_SavedDataSplit("PourSocialScore_Options") end },
		},
	},
	-- 3: the block history, kept lines, hourly stats, totals and chat rule
	-- counts live in PourSocialScore_Logging (moved the same way)
	{
		id = 3,
		parts = {
			{ feature = "history", fields = function() return M.PSS_SavedDataSplit("PourSocialScore_Logging") end },
		},
	},
	-- 4: PourSocialScore_Logging loads on demand: the counts and format
	-- markers live in PSS_CountsDB (PourSocialScore_Options) and only the
	-- lines in PSS_LoggingDB. M.PSS_PrepareSavedData moves them at login.
	{
		id = 4,
		parts = {
			{ feature = "options", fields = function() return M.PSS_SavedDataSplit("PourSocialScore_Options") end },
		},
	},
	-- 5: minimal settings. Options equal to their default are not saved
	-- (M.PSS_ApplyOptionDefaults drops them at every login). A 2.0 save from
	-- before 2.0.12 (no optionsV2012) gets the 2.0.12 switch-off of
	-- ignoreResponse and blizzardSync, as 2.0 did at login. (optionsV2012,
	-- charOptions and historySize are in RETIRED.)
	{
		id = 5,
		parts = {
			{
				feature = "options",
				fields = function()
					if type(db.upgrade) ~= "table" and not db.optionsV2012 then
						if db.ignoreResponse ~= nil or db.blizzardSync ~= nil then tally("options", "switchedOff", 1) end
						db.ignoreResponse, db.blizzardSync = nil, nil
					end
				end,
			},
		},
	},
	-- 6 (3.4.0.22): decline messages are Off by default for listed players
	-- and guilds (Dan). Show declines was On by default, so a saved On is
	-- a leftover (2.0 saved every option), never a choice: drop it.
	{
		id = 6,
		parts = {
			{
				feature = "players",
				fields = function()
					if db.showDeclines == true then
						db.showDeclines = nil
						tally("players", "declines", 1)
					end
				end,
			},
		},
	},
	-- 7 (3.4.0.25, D2): one window. The old window's places are gone (the
	-- new window keeps only its own place and tab in windowPoints; the EUI
	-- option, sizes and widths are in RETIRED). Says once if a folder the
	-- window no longer uses is still in the AddOns folder.
	{
		id = 7,
		parts = {
			{
				feature = "options",
				fields = function()
					local points = db.windowPoints
					if type(points) == "table" then
						for key in pairs(points) do
							if key ~= "PSS_Window" and key ~= "PSS_WindowTab" then
								points[key] = nil
								tally("options", "places", 1)
							end
						end
						if next(points) == nil then db.windowPoints = nil end
					end
				end,
			},
			{
				feature = "cleanup",
				data = function()
					local exists = C_AddOns and C_AddOns.DoesAddOnExist
					if not exists then return end
					local left = {}
					for _, name in ipairs({ "PourSocialScore_EllesmereUI", "PourSocialScore_UI" }) do
						if exists(name) then left[#left + 1] = name end
					end
					if #left > 0 then
						-- on the cleanup line when this login reports, else said now
						if out then
							oldFolders = table.concat(left, ", ")
						else
							M.ShowMsg(L["OLD_FOLDERS"]:format(table.concat(left, ", ")))
						end
						tally("cleanup", "oldFolders", #left)
					end
				end,
			},
		},
	},
	-- 8 (3.4.1.35, B1): "Also put listed players on Blizzard's ignore list"
	-- is a tick for each player now (PSS is authoritative). A save with the
	-- global option on ticks every listed player Blizzard's list has, then
	-- the global key goes (RETIRED). Blizzard's list may not have arrived
	-- yet at login, so the first list update ticks again (V.PSS_TickOnSync).
	{
		id = 8,
		parts = {
			{
				feature = "players",
				data = function()
					if db.blizzardSync == true then
						if M.PSS_TickBlizzardIgnored then M.PSS_TickBlizzardIgnored() end
						V.PSS_TickOnSync = true
						tally("players", "blizzardTicks", 1)
					end
				end,
			},
		},
	},
	-- 9 (3.4.1.51, S2b): one record for each listed entry. The parallel
	-- arrays (ignoreList, typeList, factionList, dateList, notes, expList,
	-- syncInfo; delList stays as it is) become db.list, one sparse record per
	-- entry in the same order: name, date, and only when set kind (not
	-- "player"), faction, note, exp (days, over 0) and sync.
	-- ORDER, on purpose: every "fields" part runs before any "data" part, so
	-- this is a fields part. Step 1's fields (the 2.0-era array backfills and
	-- the capitals) run first, on the arrays; this zips them next; then every
	-- data part (step 1's guild module, player tidy and history tidy, which
	-- run at every login, and step 8's Blizzard ticks) reads db.list only, on
	-- an old save and on a migrated one alike. The arrays are in RETIRED and
	-- go after the data parts. Safe to run twice: with the arrays gone it
	-- changes nothing, and a list that already holds records wins over arrays
	-- an older version left (they are only dropped).
	{
		id = 9,
		parts = {
			{
				feature = "players",
				fields = function()
					local names = db.ignoreList
					if type(db.list) ~= "table" then db.list = {} end
					if type(names) ~= "table" or #db.list > 0 then return end
					local list, seen, dupes = db.list, {}, 0
					local function arr(k) return type(db[k]) == "table" and db[k] or {} end
					local types, factions, dates = arr("typeList"), arr("factionList"), arr("dateList")
					local notes, exps, syncs = arr("notes"), arr("expList"), arr("syncInfo")
					for i = 1, #names do
						local name = names[i]
						if type(name) == "string" and name ~= "" then
							local kind = types[i]
							if type(kind) ~= "string" or kind == "" then kind = "player" end
							local key = kind .. ":" .. name:lower()
							if seen[key] then
								dupes = dupes + 1
							else
								seen[key] = true
								local e = { name = name }
								if type(dates[i]) == "string" and dates[i] ~= "" then e.date = dates[i] end
								if kind ~= "player" then e.kind = kind end
								if type(factions[i]) == "string" and factions[i] ~= "" then e.faction = factions[i] end
								if type(notes[i]) == "string" and notes[i] ~= "" then e.note = notes[i] end
								local days = tonumber(exps[i])
								if days and days > 0 then e.exp = days end
								if type(syncs[i]) == "table" and #syncs[i] > 0 then e.sync = syncs[i] end
								list[#list + 1] = e
							end
						end
					end
					tally("players", "listRecords", #list)
					tally("players", "listDuplicates", dupes)
				end,
			},
		},
	},
	-- 10 (3.4.1.52, S3): "SavedVariables performance cleanup". Everything a
	-- save keeps that the key, the rule or the code gives back is not saved
	-- any more, and the data is bounded and repaired (Dan's OK, D9):
	--   * Camelot saves: "first-last" names built from a unit are repaired
	--   * guild members: found members of managed rules get a date (so a
	--     record with none only ever means a shipped member), at most 1500
	--     stored members a rule, records saved sparse (no runtime fields, no
	--     name, guild or "Managed list" date the key and rule give, no zero
	--     counts), the rule's memberCount gone
	--   * players: the W I G P C switches that block are not saved
	--   * custom chat filters get a never-reused id; their history and recent
	--     counts move from the filter's text to it
	-- showIgnoreDebug is in RETIRED. Every part is safe to run twice, and the
	-- records are also saved sparse at logout, so a version that writes full
	-- records changes nothing here.
	{
		id = 10,
		parts = {
			{ feature = "guilds", data = camelotRepair },
			{
				feature = "guilds",
				data = function()
					tally("guilds", "capped", M.PSS_CapAllMembers())
				end,
			},
			{
				feature = "cleanup",
				data = function()
					M.PSS_StampFoundMembers()
					tally("cleanup", "sparse", M.PSS_CompactAllMembers())
				end,
			},
			{
				feature = "players",
				data = function()
					tally("players", "flags", M.PSS_CompactPlayers(true))
				end,
			},
			{
				feature = "filters",
				data = function()
					local n = M.PSS_AssignCustomFilterIds()
					if n == false then return false end
					tally("filters", "customIds", n)
				end,
			},
		},
	},
	-- 11 (3.7.0.102, S2b): this character's addon profiles (PSS_CharDB, 3.6.x)
	-- move into the account-wide owned keys under its entity id (SAV-00036). A
	-- per-character file is read only when that character logs in, so the
	-- step runs at every login (one type check when there is nothing to move);
	-- a slot that already holds data wins and its old value stays; newer fields
	-- stay in PSS_CharDB. Safe to run twice; nothing is in RETIRED.
	{
		id = 11,
		always = true,
		parts = {
			{ feature = "addons", data = moveCharDB },
		},
	},
}

M.PSS_UPGRADE_STEPS = #STEPS
M.PSS_UPGRADE_REGISTRY = STEPS	-- read only (the harness checks its shape)

local function addonVersion()
	local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	local v = get and get(addonName, "Version")
	return type(v) == "string" and v or "?"
end

-- Steps this save has had (0 for any 2.0 save).
local function stepsDone()
	local rec = type(PourSocialScoreDB) == "table" and PourSocialScoreDB.upgrade
	return type(rec) == "table" and tonumber(rec.step) or 0
end

-- Orders two versions: -1 when a is older than b, 0 the same, 1 newer; nil
-- when either is not a version. X.Y.Z.B orders by its numbers (build
-- numbers never reset); any older name (2.0.44, 3.3.1, 3.4.0-dev008_4) is
-- older than every X.Y.Z.B, and among them X.Y.Z-devN is older than X.Y.Z.
local function numbers(v)
	local t = {}
	for d in v:gmatch("%d+") do t[#t + 1] = tonumber(d) end
	return t
end

local function compareLists(a, b, n)
	for i = 1, n do
		local x, y = a[i] or 0, b[i] or 0
		if x ~= y then return x < y and -1 or 1 end
	end
	return 0
end

function M.PSS_VersionOrder(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then return nil end
	if not a:match("^%d+%.%d+") or not b:match("^%d+%.%d+") then return nil end
	if a == b then return 0 end
	local fa = a:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
	local fb = b:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
	local na, nb = numbers(a), numbers(b)
	if fa and fb then return compareLists(na, nb, 4) end
	if fa ~= fb then return fa and 1 or -1 end
	local o = compareLists(na, nb, 3)
	if o ~= 0 then return o end
	local devA, devB = a:find("dev", 1, true) ~= nil, b:find("dev", 1, true) ~= nil
	if devA ~= devB then return devA and -1 or 1 end
	return compareLists(na, nb, math.max(#na, #nb))
end

------------------------------------------------------------------------
-- THE GUARD (one-build plan STP-p06, ISS-p02, A13). A step part runs inside a
-- pcall; before the first part of a due step that is not "always" the stores
-- it may change are copied (take), and a part that raises, or whose optional
-- `check` fails, puts them back (put): the step and every later one wait, the
-- record says so (upgrade.fail), one retry runs this session, and the player
-- sees a plain line, never a Lua error. After a clean pass the copy is packed
-- into upgrade.undo (one slot) for /pss upgrade undo; the next login with
-- nothing due drops it.
------------------------------------------------------------------------
local STORES = { "PourSocialScoreDB", "PSS_OptionsDB", "PSS_PlayersDB", "PSS_GuildsDB", "PSS_RulesDB", "PSS_CountsDB", "PSS_CharDB" }

local function copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = copy(x) end
	return c
end

local function take()
	local s = {}
	for i = 1, #STORES do
		local name = STORES[i]
		local t = rawget(_G, name)
		if type(t) == "table" then
			local c = {}
			for k, x in pairs(t) do
				if not (name == "PourSocialScoreDB" and k == "upgrade") then c[k] = copy(x) end
			end
			s[name] = c
		end
	end
	return s
end

local function put(s)
	for name, c in pairs(s) do
		local t = rawget(_G, name)
		if type(t) == "table" then
			local keep = name == "PourSocialScoreDB" and rawget(t, "upgrade") or nil
			for k in pairs(t) do t[k] = nil end
			for k, x in pairs(c) do rawset(t, k, copy(x)) end
			if keep then rawset(t, "upgrade", keep) end
		end
	end
end

-- a compact text of the stores: "{" entries "}", s<len>:<bytes>, n<number>;, t, f
local function pack(v, out)
	local t = type(v)
	if t == "table" then
		out[#out + 1] = "{"
		for k, x in pairs(v) do pack(k, out); pack(x, out) end
		out[#out + 1] = "}"
	elseif t == "string" then
		out[#out + 1] = "s" .. #v .. ":" .. v
	elseif t == "number" then
		out[#out + 1] = ("n%.17g;"):format(v)
	elseif t == "boolean" then
		out[#out + 1] = v and "t" or "f"
	else
		out[#out + 1] = "f"
	end
end

local function unpack_(str, pos)
	local c = str:sub(pos, pos)
	if c == "{" then
		local t = {}
		pos = pos + 1
		while str:sub(pos, pos) ~= "}" do
			if pos > #str then error("truncated", 0) end
			local k, v
			k, pos = unpack_(str, pos)
			v, pos = unpack_(str, pos)
			t[k] = v
		end
		return t, pos + 1
	elseif c == "s" then
		local len, colon = str:match("^s(%d+):()", pos)
		len = tonumber(len)
		return str:sub(colon, colon + len - 1), colon + len
	elseif c == "n" then
		local num, after = str:match("^n([^;]*);()", pos)
		return tonumber(num), after
	elseif c == "t" then
		return true, pos + 1
	elseif c == "f" then
		return false, pos + 1
	end
	error("bad token at " .. pos, 0)
end

function M.PSS_UpgradePack(s)
	local out = {}
	pack(s, out)
	return table.concat(out)
end

function M.PSS_UpgradeUnpack(str)
	local ok, t = pcall(unpack_, str, 1)
	if ok and type(t) == "table" then return t end
	return nil
end

local function guard(i, p, part, f)
	local T = M.PSS_Test
	local ok, res, code
	if T and T.fault and (T.fault == "*" or T.fault == "upg" .. i) then
		ok, res = false, "injected fault"
	else
		ok, res = pcall(f)
	end
	if ok and res ~= false and p.check then
		local cok, good = pcall(p.check)
		if not cok or good == false then ok, res, code = false, cok and "its check failed" or good, "integrity" end
	end
	if ok then
		if res == false then blocked = i return false end		-- the part paused itself (as before)
		return true
	end
	failed = { step = i, feature = p.feature, code = code or "fail", text = tostring(res) }
	if snap then put(snap) end
	blocked = i
	if M.PSS_ErrFail then M.PSS_ErrFail("upgrade", failed.code .. ": step " .. i .. ": " .. failed.text) end
	return false
end

local function runPart(part)
	db = PourSocialScoreDB
	if type(db) ~= "table" then return end
	local done = stepsDone()
	for i = 1, #STEPS do
		local step = STEPS[i]
		if blocked and i >= blocked then break end
		if i > done or step.always then
			if i > done and not step.always and not snap and not skipSnap then snap = take() end
			local parts = step.parts
			for j = 1, #parts do
				local f = parts[j][part]
				if f and not guard(i, parts[j], part, f) then break end
			end
		end
	end
	db = nil
end

------------------------------------------------------------------------
-- THE UPGRADE REPORT (core uplift U2, issue #45)
--
-- Printed all at once at the end of M.PSS_RunUpgradeData on a login that
-- reports: a head line, a line for each feature that changed, the cleanup
-- line (always), then "Saved data upgraded to X (step N)." (or the paused
-- line). The phrases for each feature's counts are L["UPG_<feature>_<key>"],
-- in the order listed here; nothing is built on a login that does not report.
------------------------------------------------------------------------
local PHRASES = {
	filters = { "reset", "lists", "ids", "customIds", "unlinked", "unusable" },
	players = { "lists", "renamed", "camelot", "listRecords", "listDuplicates", "toGuilds", "tidied", "declines", "blizzardTicks", "flags" },
	guilds = { "scanFields", "camelot", "capped", "unusable" },
	managed = { "rules" },
	history = { "formats", "tidied" },
	options = { "switchedOff", "places", "unusable" },
	addons = { "moved", "kept" },
	cleanup = { "defaults", "retired", "sparse" },
}
M.PSS_UPGRADE_PHRASES = PHRASES	-- read only (the harness checks every count has a phrase)

-- 12480 -> "12,480"
local function fmtNum(n)
	local s, k = tostring(math.floor(n))
	repeat s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

-- "3 records of players no longer listed removed, 2 names given capitals"
local function resultText(feature, counts)
	local parts, keys = {}, PHRASES[feature]
	for i = 1, #keys do
		local n = counts and counts[keys[i]]
		if n then parts[#parts + 1] = L["UPG_" .. feature .. "_" .. keys[i]]:format(fmtNum(n)) end
	end
	return table.concat(parts, ", ")
end

-- a line for each feature with counts (not the cleanup line)
local function printFeatures(c)
	for i = 1, #FEATURES - 1 do
		local f = FEATURES[i]
		local text = c[f] and resultText(f, c[f]) or ""
		if text ~= "" then M.ShowMsg("  " .. L["UPG_" .. f] .. ": " .. text .. ".") end
	end
end

-- the rules this version cannot use, counted on c (after a version change)
local function countUnusable(c)
	local u = M.PSS_UnusableRules()
	for f, list in pairs(u) do
		if #list > 0 then
			c[f] = c[f] or {}
			c[f].unusable = #list
		end
	end
end

local function printReport(c)
	M.ShowMsg(L["UPG_HEAD"]:format(c.from or L["UPG_OLD"], c.to))
	printFeatures(c)
	if c.gfxOff then M.ShowMsg("  Graphics Settings Exporter is now off by default: Options, Enabled components.") end
	local text = resultText("cleanup", c.cleanup)
	if text == "" then text = L["UPG_NOTHING"] end
	text = "  " .. L["UPG_cleanup"] .. ": " .. text .. "."
	if oldFolders then text = text .. " " .. L["OLD_FOLDERS"]:format(oldFolders) end
	M.ShowMsg(text)
	if c.paused and failed then
		M.ShowMsg("|cffff3333" .. L["UPG_PAUSED_FEATURE"]:format(L["UPG_" .. (failed.feature or "cleanup")] or "saved data", failed.step) .. "|r")
	elseif c.paused then
		M.ShowMsg("|cffff3333" .. L["UPG_PAUSED"]:format(c.paused) .. "|r")
	else
		M.ShowMsg(L["UPG_DONE"]:format(c.to, c.step))
	end
end

-- The "fields" parts. fresh: a new save built this login (nothing to
-- report); defaults: options M.PSS_ApplyOptionDefaults dropped just before.
-- A login reports when the save is not new and a step is due or the
-- version changed; only then are the counts kept (out). A save from a
-- newer version (a downgrade) does not report: it gets one line and keeps
-- its version in the record.
function M.PSS_RunUpgradeFields(fresh, defaults)
	local sv = PourSocialScoreDB
	out, oldFolders, newer = nil, nil, nil
	snap, failed, skipSnap = nil, nil, fresh == true
	if not fresh and type(sv) == "table" then
		local rec = type(sv.upgrade) == "table" and sv.upgrade or nil
		local from = rec and rec.version
		local version = addonVersion()
		if M.PSS_VersionOrder(from, version) == 1 then
			newer = from
		elseif stepsDone() < #STEPS or from ~= version then
			out = { from = type(from) == "string" and from or nil, done = stepsDone() }
			tally("cleanup", "defaults", defaults)
			-- Graphics Settings Exporter became an opt-in component in 3.6.0.69 (issue 181):
			-- a save that holds graphics sets from before is told once
			if sv.gfxSets ~= nil and M.PSS_Opt("useGfx") ~= true
				and (not from or M.PSS_VersionOrder(from, "3.6.0.69") == -1) then
				out.gfxOff = true
			end
		end
	end
	runPart("fields")
end

-- The "data" parts, the retired keys, then the record. fresh: a new save
-- built this login (nothing to report). Returns the counts of a login that
-- reports (out: from, to, done, step, and a table per feature), else nil.
function M.PSS_RunUpgradeData(fresh)
	runPart("data")
	local sv = PourSocialScoreDB
	if type(sv) ~= "table" then
		out, snap = nil, nil
		return
	end
	db = sv
	dropRetired()
	db = nil
	local done = stepsDone()
	local reached = blocked and blocked - 1 or #STEPS
	local paused = blocked
	blocked = nil
	local rec = type(sv.upgrade) == "table" and sv.upgrade or {}
	sv.upgrade = rec
	local version = addonVersion()
	local priorVersion = rec.version
	if done < reached or (rec.version ~= version and not newer) then
		rec.step = math.max(done, reached)
		if not newer then rec.version = version end
		rec.at = (GetServerTime and GetServerTime()) or time()
	end
	-- the failure record and the undo slot (one slot; a login with nothing due drops it)
	if failed then
		rec.fail = failed.step .. ":" .. failed.code
		retryAt = retryAt == nil and failed.step or retryAt
		M.PSS_UpgradeRetryRow()
	else
		rec.fail = nil
		if snap and not skipSnap and done < reached then
			local blob = M.PSS_UpgradePack(snap)
			if #blob <= M.PSS_UNDO_CAP then
				rec.undo = { at = rec.at, step = done, version = priorVersion, blob = blob }
			else
				rec.undo = nil
				M.ShowMsg(L["UPG_NO_UNDO_SIZE"])		-- the copy would double a large save
			end
		elseif not snap and rec.undo and not retrying then
			rec.undo = nil
		end
	end
	snap = nil
	if newer then
		-- a downgrade: one line, then what this version cannot use
		M.ShowMsg(L["UPG_NEWER"]:format(version, newer))
		local c = {}
		countUnusable(c)
		printFeatures(c)
	end
	local counts = out
	out, newer = nil, nil
	if counts then
		counts.to, counts.step, counts.paused = version, math.max(done, reached), paused
		countUnusable(counts)
		printReport(counts)
	elseif failed then		-- a login that does not report still tells the player
		M.ShowMsg("|cffff3333" .. L["UPG_PAUSED_FEATURE"]:format(L["UPG_" .. (failed.feature or "cleanup")] or "saved data", failed.step) .. "|r")
	end
	oldFolders = nil
	return counts
end

-- one retry per session, on the next moment the work can run (generalises the
-- charmove row of step 11): a trigger row that runs the service upg.retry
function M.PSS_UpgradeRetryRow()
	if retryAt and M.PSS_Trigger and not retrying then
		M.PSS_Trigger({ id = "upgretry", on = { "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA" },
			settle = "now", run = "upg.retry" })
	end
end

-- the retry: out of combat, every due step again (the others stay done), once
function M.PSS_UpgradeRetry()
	if not retryAt or retrying then return false end
	if InCombatLockdown and InCombatLockdown() then return false end		-- the row stays and tries at the next event
	retrying = true
	retryAt = nil
	if M.PSS_TriggerOff then M.PSS_TriggerOff("upgretry") end
	snap, failed, blocked = nil, nil, nil
	runPart("fields")
	runPart("data")
	local sv = PourSocialScoreDB
	local rec = type(sv) == "table" and sv.upgrade
	if type(rec) ~= "table" then retrying = false return false end
	if failed then
		rec.fail = failed.step .. ":" .. failed.code
		M.ShowMsg("|cffff3333" .. L["UPG_PAUSED_FEATURE"]:format(L["UPG_" .. (failed.feature or "cleanup")] or "saved data", failed.step) .. "|r")
		blocked, snap, retrying = nil, nil, false
		return false
	end
	local reached = blocked and blocked - 1 or #STEPS
	local prior = rec.step
	if (tonumber(prior) or 0) < reached then
		rec.step = reached
		rec.at = (GetServerTime and GetServerTime()) or time()
		if snap then
			local blob = M.PSS_UpgradePack(snap)
			if #blob <= M.PSS_UNDO_CAP then rec.undo = { at = rec.at, step = prior, version = rec.version, blob = blob } else rec.undo = nil end
		end
	end
	rec.fail = nil
	M.ShowMsg(L["UPG_RETRY_DONE"]:format(rec.step))
	blocked, snap, retrying = nil, nil, false
	return true
end

-- the steps and what each would do, read only: { step, feature, state } rows
function M.PSS_UpgradePlan()
	local done = stepsDone()
	local rows = {}
	for i = 1, #STEPS do
		local step = STEPS[i]
		local state = step.always and "always" or (i <= done and "done" or "due")
		for j = 1, #step.parts do
			rows[#rows + 1] = { i, step.parts[j].feature or "", state }
		end
	end
	return rows
end

-- /pss status: the upgrade in one plain line
function M.PSS_UpgradeStatusLine()
	local rec = type(PourSocialScoreDB) == "table" and PourSocialScoreDB.upgrade
	if type(rec) ~= "table" then return "Upgrade: none yet." end
	local fail = rec.fail and ("failed at step " .. tostring(rec.fail) .. (retryAt and ", one retry waits" or "")) or "no failure"
	return ("Upgrade: step %s of %d, version %s, %s%s."):format(tostring(rec.step), #STEPS, tostring(rec.version), fail,
		rec.undo and ", an undo copy is kept until the next clean login" or "")
end

-- /pss upgrade undo: the stores as they were before the last upgrade
function M.PSS_UpgradeUndo()
	local rec = type(PourSocialScoreDB) == "table" and PourSocialScoreDB.upgrade
	if type(rec) ~= "table" or type(rec.undo) ~= "table" then M.ShowMsg(L["UPG_NO_UNDO"]) return false end
	if InCombatLockdown and InCombatLockdown() then M.ShowMsg(L["UPG_UNDO_COMBAT"]) return false end
	local s = M.PSS_UpgradeUnpack(rec.undo.blob)
	if not s then M.ShowMsg(L["UPG_NO_UNDO"]) return false end
	local u = rec.undo
	put(s)
	rec = rawget(PourSocialScoreDB, "upgrade")
	if type(rec) ~= "table" then rec = {}; rawset(PourSocialScoreDB, "upgrade", rec) end
	rec.undo, rec.fail = nil, nil
	rec.step = u.step or 0
	rec.version = u.version
	M.ShowMsg(L["UPG_UNDONE"]:format(tostring(u.version or "?")))
	return true
end

-- /pss upgrade [plan | undo]
function M.PSS_UpgradeCommand(args)
	if args[2] == "undo" then
		M.PSS_UpgradeUndo()
	elseif args[2] == "plan" then
		for _, r in ipairs(M.PSS_UpgradePlan()) do M.ShowMsg(("  step %d  %s  %s"):format(r[1], r[2], r[3])) end
	else
		M.ShowMsg(M.PSS_UpgradeStatusLine())
	end
end

-- For /pss mem: "step 1, version 3.0.0-dev4, 04 Oct 2026 07:40".
function M.PSS_UpgradeText()
	local rec = type(PourSocialScoreDB) == "table" and PourSocialScoreDB.upgrade
	if type(rec) ~= "table" then return "none yet" end
	local at = tonumber(rec.at)
	return ("step %s of %d, version %s, %s"):format(tostring(rec.step), #STEPS, tostring(rec.version),
		at and date("%d %b %Y %H:%M", at) or "time unknown")
end
