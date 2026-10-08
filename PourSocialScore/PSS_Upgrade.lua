-----------------------------------
-- Pour Social Score Upgrade Steps --
-----------------------------------
local addonName, addon	= ...
local M = addon.M -- shared methods
local L = addon.L -- localization entries

-- Saved data upgrades as numbered steps (the Questie model):
--   * STEPS[1..N] run first to last. Append new steps at the end; never
--     reorder, renumber or change a step once it has been released.
--   * PourSocialScoreDB.upgrade = { step = N, version = "3.0.0", at = time }
--     records how many steps this save has had, the addon version that last
--     upgraded it and when (server time). Older versions ignore it.
--   * At login a step runs when the save has not had it yet. A step marked
--     "always" also runs at every login: step 1 is the 2.0 login pass, which
--     still mixes one-time conversions with per-login work (index rebuild,
--     log trim, block-count prune, tidy-ups); those are separated when the
--     upgrade code moves out of the core.
--   * Every step must be safe to run twice.
-- A step has up to two parts: "fields" runs before the built-in chat filters
-- are rebuilt from code (M.PSS_ExpandFilters), "data" runs after it.

local db	-- PourSocialScoreDB while a pass runs
local blocked	-- first step whose part returned false this login (not recorded)

local STEPS = {
	-- 1: everything 2.0 did at login, moved here unchanged.
	{
		always = true,
		fields = function()
			if db.showIgnoreDebug == nil then
				db.showIgnoreDebug = false
			end

			if db.filterTotal == nil then
				db.filterTotal = 0
			end

			-- (autoIgnore / autoUpdate / autoCount / autoTime / attachFriends were
			-- never used; they are dropped from saved settings.)
			db.autoIgnore, db.autoUpdate = nil, nil
			db.autoCount, db.autoTime = nil, nil
			db.attachFriends = nil

			if db.filterList == nil or db.filterDesc == nil or db.filterCount == nil then
				M.ResetSpamFilters()
			end

			if db.delList == nil then
				db.delList = {}
			end

			if db.expList == nil then
				db.expList = {}

				for count = 1, #db.ignoreList do
					db.expList[count] = 0
				end
			end

			if db.syncList then
				db.syncList = nil
			end

			if db.syncInfo == nil then
				db.syncInfo = {}

				for count = 1, #db.ignoreList do
					db.syncInfo[count] = {}
				end
			end

			if db.typeList == nil then
				db.typeList = {}

				for count = 1, #db.ignoreList do
					db.typeList[count] = "player"
				end
			end

			if db.revision == nil then
				db.revision = 1

				for count = 1, #db.ignoreList do
					db.ignoreList[count] = M.Proper(db.ignoreList[count])
				end
			end

			if db.filterActive == nil then
				db.filterActive = {}

				for count = 1, #db.filterDesc do
					db.filterActive[count] = true
				end
			end

			if db.filterID == nil then
				M.PSS_AssignLegacyFilterIDs()
			end

			-- Erase some old alpha data that could be out there
			if db.filterHistory ~= nil then
				db.filterHistory = nil
			end

			if db.filterBlocked == nil then
				db.filterBlocked = {}

				for count = 1, #db.filterDesc do
					db.filterBlocked[count] = {}
				end
			end

			if db.filterBlockedLast == nil then
				db.filterBlockedLast = {}

				for count = 1, #db.filterDesc do
					db.filterBlockedLast[count] = 0
				end
			end

			db.filterWhisperTotal = tonumber(db.filterWhisperTotal) or 0
			db.filterPrivateTotal = tonumber(db.filterPrivateTotal) or 0
		end,
		data = function()
			-- Player/guild data upgrade (guild module), now that the core lists exist.
			if M.PSS_UpgradeLegacyData then M.PSS_UpgradeLegacyData() end
			-- guild rule blocks are guild blocks only (2.0.39): undo the second count
			if M.PSS_UnlinkGuildRuleCounts then M.PSS_UnlinkGuildRuleCounts() end
			-- the old hourly session / last 24 hours counts (PSS_BlockStats.lua,
			-- retired in 3.3.0-dev002: both windows read History.Recent*)
			if PourSocialScoreDB.blockStats ~= nil then PourSocialScoreDB.blockStats = nil end
			-- records of players no longer listed, and fields records no longer keep
			if M.PSS_TidyPlayerData then M.PSS_TidyPlayerData() end
			-- then tidy the block history (lines of things that are gone); not
			-- loaded yet: done when PourSocialScore_Logging loads
			if M.PSS_LoggingReady and M.PSS_LoggingReady() then
				local tidied = M.PSS_TidyBlockHistory()
				if tidied > 0 and M.PSS_RequestGC then M.PSS_RequestGC("history tidied") end
			end
		end,
	},
	-- 2: options, players, guilds and rules live in PourSocialScore_Options.
	-- The move itself runs before any other startup code reads the data
	-- (M.PSS_PrepareSavedData, PSS_SavedData.lua); this records it, and
	-- returns false (step not recorded) when it did not happen.
	{
		fields = function() return M.PSS_SavedDataSplit("PourSocialScore_Options") end,
	},
	-- 3: the block history, kept lines, hourly stats, totals and chat rule
	-- counts live in PourSocialScore_Logging (moved the same way)
	{
		fields = function() return M.PSS_SavedDataSplit("PourSocialScore_Logging") end,
	},
	-- 4: PourSocialScore_Logging loads on demand: the counts and format
	-- markers live in PSS_CountsDB (PourSocialScore_Options) and only the
	-- lines in PSS_LoggingDB. M.PSS_PrepareSavedData moves them at login.
	{
		fields = function() return M.PSS_SavedDataSplit("PourSocialScore_Options") end,
	},
	-- 5: minimal settings. Options equal to their default are not saved
	-- (M.PSS_ApplyOptionDefaults drops them at every login); this drops the
	-- keys nothing reads any more. A 2.0 save from before 2.0.12 (no
	-- optionsV2012) gets the 2.0.12 switch-off of ignoreResponse and
	-- blizzardSync first, as 2.0 did at login.
	{
		fields = function()
			if type(db.upgrade) ~= "table" and not db.optionsV2012 then
				db.ignoreResponse, db.blizzardSync = nil, nil
			end
			db.optionsV2012 = nil
			db.charOptions = nil		-- per-character overrides, gone since 2.0.12
			db.historySize = nil		-- not read by any code (historyTotal is the setting)
		end,
	},
	-- 6 (3.4.0.22): decline messages are Off by default for listed players
	-- and guilds (Dan). Show declines was On by default, so a saved On is
	-- a leftover (2.0 saved every option), never a choice: drop it.
	{
		fields = function()
			if db.showDeclines == true then db.showDeclines = nil end
		end,
	},
	-- 7 (3.4.0.25, D2): one window. The EllesmereUI integration option and
	-- the old window's sizes, column widths and places are gone (the new
	-- window keeps only its own place and tab in windowPoints). Says once if
	-- a folder the window no longer uses is still in the AddOns folder.
	{
		fields = function()
			db.euiIntegration = nil
			db.windowSizes = nil
			db.columnWidths = nil
			local points = db.windowPoints
			if type(points) == "table" then
				for key in pairs(points) do
					if key ~= "PSS_Window" and key ~= "PSS_WindowTab" then points[key] = nil end
				end
				if next(points) == nil then db.windowPoints = nil end
			end
		end,
		data = function()
			local exists = C_AddOns and C_AddOns.DoesAddOnExist
			if not exists then return end
			local left = {}
			for _, name in ipairs({ "PourSocialScore_EllesmereUI", "PourSocialScore_UI" }) do
				if exists(name) then left[#left + 1] = name end
			end
			if #left > 0 then M.ShowMsg(L["OLD_FOLDERS"]:format(table.concat(left, ", "))) end
		end,
	},
}

M.PSS_UPGRADE_STEPS = #STEPS

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

local function runPart(part)
	db = PourSocialScoreDB
	if type(db) ~= "table" then return end
	local done = stepsDone()
	for i = 1, #STEPS do
		local step = STEPS[i]
		if blocked and i >= blocked then break end
		if step[part] and (i > done or step.always) and step[part]() == false then blocked = i end
	end
	db = nil
end

function M.PSS_RunUpgradeFields() runPart("fields") end

-- The "data" parts, then the record. fresh: a new save built this login
-- (nothing to report).
function M.PSS_RunUpgradeData(fresh)
	runPart("data")
	local sv = PourSocialScoreDB
	if type(sv) ~= "table" then return end
	local done = stepsDone()
	local reached = blocked and blocked - 1 or #STEPS
	blocked = nil
	local rec = type(sv.upgrade) == "table" and sv.upgrade or {}
	sv.upgrade = rec
	local version = addonVersion()
	if done < reached or rec.version ~= version then
		rec.step = math.max(done, reached)
		rec.version = version
		rec.at = (GetServerTime and GetServerTime()) or time()
	end
	if done < reached and not fresh then
		M.ShowMsg(("Saved data upgraded to %s (step %d)."):format(version, reached))
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

------------------------------------------------------------------------
-- VALIDATION REPORT
--
-- M.PSS_Validate() counts and type-checks every saved data set without
-- changing anything. report.n holds the numbers (the same keys before and
-- after a moving step, so they can be compared), report.problems lists
-- anything malformed. /pss check prints it.
------------------------------------------------------------------------
local LIST_ARRAYS = { "typeList", "notes", "expList", "dateList", "factionList", "syncInfo" }
local FILTER_ARRAYS = { "filterList", "filterDesc", "filterActive", "filterID", "filterCount", "filterBlocked", "filterBlockedLast" }

local function size(t)
	local n = 0
	if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
	return n
end

function M.PSS_Validate()
	local sv = PourSocialScoreDB
	local n, problems = {}, {}
	local report = { n = n, problems = problems }
	local function problem(fmt, ...) problems[#problems + 1] = fmt:format(...) end
	if type(sv) ~= "table" then problem("no saved data") return report end
	local cats = (M.PSS_History and M.PSS_History.ALL_CATS) or {}

	-- the type of every table the rest of the report reads
	for _, k in ipairs({ "ignoreList", "typeList", "notes", "expList", "dateList", "factionList", "syncInfo",
			"delList", "playerData", "guildData", "guildExclusions", "blockLog", "blockKeep", "blockStats",
			"builtinRules", "builtinStats", "upgrade" }) do
		if sv[k] ~= nil and type(sv[k]) ~= "table" then problem("%s is a %s, not a table", k, type(sv[k])) end
	end
	local function tbl(k) return type(sv[k]) == "table" and sv[k] or {} end

	-- Player Ignore List: entries per type, parallel lists, notes, records
	local list, types = tbl("ignoreList"), tbl("typeList")
	n.list = #list
	n.listPlayer, n.listNpc, n.listServer, n.listOther = 0, 0, 0, 0
	local seen, dupes = {}, 0
	for i = 1, #list do
		local name, kind = list[i], types[i] or "player"
		if type(name) ~= "string" or name == "" then problem("list entry %d has no name", i) end
		if kind == "player" then n.listPlayer = n.listPlayer + 1
		elseif kind == "npc" then n.listNpc = n.listNpc + 1
		elseif kind == "server" then n.listServer = n.listServer + 1
		else n.listOther = n.listOther + 1 end
		local key = kind .. ":" .. tostring(name):lower()
		if seen[key] then dupes = dupes + 1 end
		seen[key] = true
	end
	n.listDuplicates = dupes
	if dupes > 0 then problem("%d duplicate entries on the Player Ignore List", dupes) end
	for _, k in ipairs(LIST_ARRAYS) do
		for i in pairs(tbl(k)) do
			if type(i) ~= "number" or i < 1 or i > #list or i % 1 ~= 0 then
				problem("%s has an entry (%s) beyond the list's %d entries", k, tostring(i), #list)
				break
			end
		end
	end
	local notes = 0
	for i = 1, #list do
		local note = tbl("notes")[i]
		if type(note) == "string" and note ~= "" then notes = notes + 1 end
	end
	n.listNotes = notes
	n.playerRecords = size(sv.playerData)
	n.deleted = #tbl("delList")

	-- Guild Ignore List: rules, members, member notes, exclusions
	n.guildRules, n.guildRulesShipped, n.membersStored, n.membersShown, n.memberNotes = 0, 0, 0, 0, 0
	n.leftMarks = 0		-- shipped members marked "left this guild"
	for gkey, g in pairs(tbl("guildData")) do
		if type(g) ~= "table" then
			problem("guild rule %s is not a table", tostring(gkey))
		else
			n.guildRules = n.guildRules + 1
			if g.managed then n.guildRulesShipped = n.guildRulesShipped + 1 end
			n.leftMarks = n.leftMarks + size(g.managedGone)
			if g.members ~= nil and type(g.members) ~= "table" then problem("guild rule %s: members is not a table", tostring(gkey)) end
			for key, m in pairs(type(g.members) == "table" and g.members or {}) do
				n.membersStored = n.membersStored + 1
				if type(m) ~= "table" then
					problem("guild rule %s: member %s is not a table", tostring(gkey), tostring(key))
				elseif type(m.note) == "string" and m.note ~= "" then
					n.memberNotes = n.memberNotes + 1
				end
			end
			n.membersShown = n.membersShown + (M.PSS_GuildMemberCount and M.PSS_GuildMemberCount(g, gkey) or size(g.members))
		end
	end
	n.guildExclusions = size(sv.guildExclusions)

	-- Chat Filters (in memory the built-in rules sit in the same arrays)
	local flist = tbl("filterList")
	n.filters = #flist
	for _, k in ipairs(FILTER_ARRAYS) do
		if sv[k] ~= nil and #tbl(k) ~= #flist then problem("%s has %d entries, filterList has %d", k, #tbl(k), #flist) end
	end
	n.filtersCustom, n.filtersBuiltinOn, n.filtersCustomOn = 0, 0, 0
	local ids = {}
	for i = 1, #flist do
		local id = tbl("filterID")[i]
		local on = tbl("filterActive")[i] == true
		if type(id) == "string" and id ~= "" then
			if ids[id] then problem("chat filter ID %s is used twice", id) end
			ids[id] = true
			if on then n.filtersBuiltinOn = n.filtersBuiltinOn + 1 end
		else
			n.filtersCustom = n.filtersCustom + 1
			if on then n.filtersCustomOn = n.filtersCustomOn + 1 end
		end
		if type(flist[i]) ~= "string" then problem("chat filter %d has no text", i) end
	end

	-- block history: log lines and lines kept per person
	n.logLines = #tbl("blockLog")
	n.keptLines, n.keptPeople = 0, 0
	-- the saved log of 3.2.0-dev007: one group per person, kept lines first
	if tbl("blockLog").v == 2 then
		for o, g in pairs(tbl("blockLog")) do
			if type(g) == "table" then
				local k = tonumber(g.k) or 0
				n.logLines = n.logLines + #g - k
				if k > 0 then n.keptLines, n.keptPeople = n.keptLines + k, n.keptPeople + 1 end
			elseif o ~= "v" then
				problem("saved log lines of %s are not a table", tostring(o))
			end
		end
	end
	for o, l in pairs(tbl("blockKeep")) do
		if type(l) ~= "table" then
			problem("kept lines of %s are not a table", tostring(o))
		else
			n.keptLines = n.keptLines + #l
			n.keptPeople = n.keptPeople + 1
		end
	end

	-- block counts: the sum of every counter per source and category
	local function addCounts(prefix, c)
		if type(c) ~= "table" then return end
		n[prefix .. "Total"] = (n[prefix .. "Total"] or 0) + (tonumber(c.total) or 0)
		for _, cat in ipairs(cats) do
			n[prefix .. "." .. cat] = (n[prefix .. "." .. cat] or 0) + (tonumber(c[cat]) or 0)
		end
	end
	n.playerCountsTotal, n.memberCountsTotal, n.filterCountsTotal = 0, 0, 0
	for _, p in pairs(tbl("playerData")) do if type(p) == "table" then addCounts("playerCounts", p.blockCounts) end end
	for _, g in pairs(tbl("guildData")) do
		for _, m in pairs(type(g) == "table" and type(g.members) == "table" and g.members or {}) do
			if type(m) == "table" then addCounts("memberCounts", m.blockCounts) end
		end
	end
	for i = 1, #flist do
		local b = tbl("filterBlocked")[i]
		addCounts("filterCounts", type(b) == "table" and b.counts)
	end
	n.filterTotal = tonumber(sv.filterTotal) or 0
	n.filterWhisperTotal = tonumber(sv.filterWhisperTotal) or 0
	n.filterPrivateTotal = tonumber(sv.filterPrivateTotal) or 0
	local rowSum = 0
	for i = 1, #flist do rowSum = rowSum + (tonumber(tbl("filterCount")[i]) or 0) end
	n.filterRowCounts = rowSum

	-- options: how many differ from their default (only those are saved
	-- since 3.0)
	n.optionsChanged = 0
	for _, o in ipairs(M.PSS_OPTIONS or {}) do
		if sv[o.key] ~= nil and sv[o.key] ~= o.default then n.optionsChanged = n.optionsChanged + 1 end
	end
	return report
end

-- /pss check
function M.PSS_PrintValidation()
	if M.PSS_LoadLogging then M.PSS_LoadLogging() end
	local r = M.PSS_Validate()
	local n = r.n
	local out = M.ShowMsg
	local function v(k) return tostring(n[k] or 0) end
	out("|cffff99ffSaved data check|r")
	out(("  Player Ignore List: %s entries (%s players, %s NPCs, %s servers%s), %s notes, %s player records, %s on the deleted list"):format(
		v("list"), v("listPlayer"), v("listNpc"), v("listServer"),
		(n.listOther or 0) > 0 and (", " .. v("listOther") .. " other") or "", v("listNotes"), v("playerRecords"), v("deleted")))
	out(("  Guild Ignore List: %s guilds (%s from shipped lists), %s members shown, %s stored, %s member notes, %s excluded guilds, %s shipped members marked as left"):format(
		v("guildRules"), v("guildRulesShipped"), v("membersShown"), v("membersStored"), v("memberNotes"), v("guildExclusions"), v("leftMarks")))
	out(("  Chat Filters: %s rules (%s custom), %s built-in on, %s custom on"):format(
		v("filters"), v("filtersCustom"), v("filtersBuiltinOn"), v("filtersCustomOn")))
	out(("  Block history: %s log lines, %s kept lines for %s people"):format(v("logLines"), v("keptLines"), v("keptPeople")))
	out(("  Block counts: players %s, guild members %s, chat filters %s (tab total %s, whispers %s, Battle.net %s)"):format(
		v("playerCountsTotal"), v("memberCountsTotal"), v("filterRowCounts"), v("filterTotal"), v("filterWhisperTotal"), v("filterPrivateTotal")))
	out(("  Last 24 hours: players %s, guilds %s, filters %s"):format(v("stats24h.player"), v("stats24h.guild"), v("stats24h.filter")))
	out(("  Options: %s changed from default"):format(v("optionsChanged")))
	out("  Upgrade: " .. M.PSS_UpgradeText())
	if #r.problems == 0 then
		out("  |cff33ff33No problems found.|r")
	else
		out(("  |cffff3333%d problem(s):|r"):format(#r.problems))
		for i = 1, math.min(#r.problems, 20) do out("    " .. r.problems[i]) end
		if #r.problems > 20 then out(("    ... and %d more"):format(#r.problems - 20)) end
	end
	return r
end
