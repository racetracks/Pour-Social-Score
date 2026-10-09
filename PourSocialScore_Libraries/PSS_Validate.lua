-- Pour Social Score saved data check (/pss check), moved out of core with
-- P6 (3.4.1): it runs only for /pss check and when saved keys move at a
-- login (PSS_SavedData.lua), so core keeps stubs (PSS_Upgrade.lua).
local addon = PourSocialScore_NS
local M = addon.M
local L = addon.L
local V = addon.V

------------------------------------------------------------------------
-- VALIDATION REPORT
--
-- M.PSS_Validate() counts and type-checks every saved data set without
-- changing anything. report.n holds the numbers (the same keys before and
-- after a moving step, so they can be compared), report.problems lists
-- anything malformed. /pss check prints it.
------------------------------------------------------------------------
local FILTER_ARRAYS = M.PSS_FILTER_ARRAYS

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
	for _, k in ipairs({ "list", "ignoreList", "typeList", "notes", "expList", "dateList", "factionList", "syncInfo",
			"delList", "playerData", "guildData", "guildExclusions", "blockLog", "blockKeep", "blockStats",
			"builtinRules", "builtinStats", "upgrade" }) do
		if sv[k] ~= nil and type(sv[k]) ~= "table" then problem("%s is a %s, not a table", k, type(sv[k])) end
	end
	local function tbl(k) return type(sv[k]) == "table" and sv[k] or {} end

	-- Player Ignore List: entries per type, notes, records. One record each in
	-- sv.list (S2b); a save not upgraded yet (the parallel arrays) is read
	-- through a view of the same shape, so the numbers compare before and after.
	local list = tbl("list")
	if type(sv.list) ~= "table" and type(sv.ignoreList) == "table" then
		list = {}
		for i = 1, #sv.ignoreList do
			local note, exp = tbl("notes")[i], tbl("expList")[i]
			list[i] = { name = sv.ignoreList[i], kind = tbl("typeList")[i], note = note, exp = exp }
		end
	end
	n.list = #list
	n.listPlayer, n.listNpc, n.listServer, n.listOther = 0, 0, 0, 0
	local seen, dupes, notes = {}, 0, 0
	for i = 1, #list do
		local e = list[i]
		if type(e) ~= "table" then
			problem("list entry %d is a %s, not a record", i, type(e))
			e = {}
		end
		local name, kind = e.name, e.kind or "player"
		if type(name) ~= "string" or name == "" then problem("list entry %d has no name", i) end
		if kind == "player" then n.listPlayer = n.listPlayer + 1
		elseif kind == "npc" then n.listNpc = n.listNpc + 1
		elseif kind == "server" then n.listServer = n.listServer + 1
		else n.listOther = n.listOther + 1 end
		local key = tostring(kind) .. ":" .. tostring(name):lower()
		if seen[key] then dupes = dupes + 1 end
		seen[key] = true
		if e.note ~= nil and type(e.note) ~= "string" then problem("list entry %d: its note is a %s", i, type(e.note)) end
		if e.exp ~= nil and type(e.exp) ~= "number" then problem("list entry %d: its expiry is a %s", i, type(e.exp)) end
		if e.sync ~= nil and type(e.sync) ~= "table" then problem("list entry %d: its sync info is a %s", i, type(e.sync)) end
		if type(e.note) == "string" and e.note ~= "" then notes = notes + 1 end
	end
	n.listDuplicates = dupes
	if dupes > 0 then problem("%d duplicate entries on the Player Ignore List", dupes) end
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
		n[prefix .. "Total"] = (n[prefix .. "Total"] or 0) + M.PSS_History.CountTotal(c)
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
