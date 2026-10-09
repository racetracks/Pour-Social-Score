------------------------------------------------------------------------
-- POUR SOCIAL SCORE - CHAT FILTERS
--
-- Text-based blocking with custom logic (the filter language below:
-- [word=], [contains=], [item=], [link], ...). Built-in rules are defined in
-- code and read only; custom rules are stored in SavedVariables.
-- The core (PSS_ChatBlock.lua) calls the registered "text" handler for
-- whisper / party-raid / world / guild chat AFTER person and realm rules,
-- so a line already hidden by an ignore list is never counted here.
------------------------------------------------------------------------
local addonName, addon = ...
local L = addon.L
local V = addon.V
local M = addon.M

V.lastFilterError		= false

local filterDefDesc		= {}
local filterDefFilter = {}
local filterDefActive = {}
local filterDefID		= {}
local pssFloodSize		= 50

------------------------------------------------------------------------
-- Built-in (default) rules
------------------------------------------------------------------------
-- Set filter defaults. Every built-in filter starts OFF (opt in): tick the
-- ones you want on the Chat Filters tab.

filterDefDesc[#filterDefDesc + 1]		= "Filter \"Anal\" Spammers"
filterDefFilter[#filterDefFilter + 1] = "([word=anal] or [contains=analan]) and ([link] or [words=2])"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0001"

filterDefDesc[#filterDefDesc + 1]		= "Filter Thunderfury linking"
filterDefFilter[#filterDefFilter + 1] = "[item=19019]"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0002"

filterDefDesc[#filterDefDesc + 1]		= "Filter Mythic+/Raid Sellers"
filterDefFilter[#filterDefFilter + 1] = "([contains=WTS] or [contains=sell] or [contains=offer] or [contains=cheap] or [word=starting]) and ([contains=m+] or [contains=boost] or [contains=carry] or [contains=raid] or [contains=mythic] or [contains=keys] or [contains=gold\\ only] or [achievement] or [journal] or [contains=afk])"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0003"

filterDefDesc[#filterDefDesc + 1]		= "Filter Tradeskill Sellers"
filterDefFilter[#filterDefFilter + 1] = "([contains=LFW] or [word=trade] or [contains=order] or [contains=tip] or [contains=%] or [contains=max] or [word=free] or [contains=craft] or [word=mats] or [contains=pay]) and ([trade] or [item])"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0013"

filterDefDesc[#filterDefDesc + 1]		= "Filter Power Leveling Sellers"
filterDefFilter[#filterDefFilter + 1] = "([contains=wts] or [contains=service] or [contains=sell] or [word=fast] or [contains=afk]) and (([contains=power] or [contains=pwr]) and ([contains=level] or [contains=lvl]))"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0014"

filterDefDesc[#filterDefDesc + 1]		= "Filter Guild Recruitment"
--filterDefFilter[#filterDefFilter + 1] = "(([contains=<] and [contains=>]) or ([contains=\\[] and [contains=\\]]) or ([contains=\\(] and [contains=\\)])) and ([contains=recruit] or [contains=progress] or [contains=raid] or [contains=guild] or [contains=seek] or [contains=mythic])"
filterDefFilter[#filterDefFilter + 1] = "(([guild] or ([contains=<] and [contains=>]) or ([contains=\\[] and [contains=\\]]) or ([contains=\\(] and [contains=\\)])) and ([contains=recruit] or [contains=progress] or [contains=raid] or [contains=guild] or [contains=seek] or [contains=mythic])) or ([contains=guild] and [contains=recruit])"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0008"

filterDefDesc[#filterDefDesc + 1]		= "Filter Community Recruitment"
filterDefFilter[#filterDefFilter + 1] = "[community]"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0009"

filterDefDesc[#filterDefDesc + 1]		= "Filter WTS"
filterDefFilter[#filterDefFilter + 1] = "[contains=WTS] or [contains=WTB]"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0010"

filterDefDesc[#filterDefDesc + 1]		= "Filter Chinese/Korean/Japanese"
filterDefFilter[#filterDefFilter + 1] = "[nonlatin]"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0011"

filterDefDesc[#filterDefDesc + 1]		= "Filter American Politics"
filterDefFilter[#filterDefFilter + 1] = "[contains=trump] or [contains=communist] or [contains=communism] or [word=president] or [contains=biden] or [word=hillary] or [word=hilary] or [contains=democrat] or [contains=republican] or [contains=liberals] or [word=maga] or [word=libs] or [contains=conservatives] or [contains=libtard] or [word=pelosi] or [word=epstein] or [word=AOC] or [word=putin] or [contains=right\\ wing] or [word=dems] or [word=socialism]"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0012"

filterDefDesc[#filterDefDesc + 1]		= "Filter Asmon"
filterDefFilter[#filterDefFilter + 1] = "[contains=asmon]"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0015"

filterDefDesc[#filterDefDesc + 1]		= "Filter Olympus"
filterDefFilter[#filterDefFilter + 1] = "[word=olympus]"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0016"

filterDefDesc[#filterDefDesc + 1]		= "Filter Cyrillic (Russian etc.)"
filterDefFilter[#filterDefFilter + 1] = "[cyrillic]"
filterDefActive[#filterDefActive + 1] = false
filterDefID[#filterDefID + 1]		= "PSS0017"

-- Default GUILD rules ("InfluencerGuild=<Name>"), one per group in
-- PSS_Communities.lua. They are read-only built-ins like the text
-- filters above, start off, and switch the whole group of guilds (shown as a
-- collapsible entry on the Guild Ignore List) on or off. The text engine
-- below never evaluates them; the guild block source does.
for _, grp in ipairs((addon.MANAGED and addon.MANAGED.groups) or {}) do
	filterDefDesc[#filterDefDesc + 1]		= grp.rule
	filterDefFilter[#filterDefFilter + 1] = grp.filter
	filterDefActive[#filterDefActive + 1] = false
	filterDefID[#filterDefID + 1]			= grp.id
end

-- When adding new defaults, make sure to assign a unique filter ID that has never been used before


------------------------------------------------------------------------
-- Storage helpers
------------------------------------------------------------------------
-- Block history: the shared block log (PSS_ChatHistory.lua). A filter's
-- lines are the log entries owned by it; filterBlocked[i].counts holds its
-- per-type totals; filterCount[i] stays the total blocked.
-- (filterBlockedLast is no longer used; it is kept as 0 for older code.)
local History = M.PSS_History

function M.PSS_FilterOwnerKey(filterNum)
	local db = PourSocialScoreDB
	return History.FilterKey(db.filterID[filterNum], db.filterList[filterNum])
end

-- the filter's per-type counts (a table, created when missing)
function M.PSS_FilterCounts(filterNum)
	local db = PourSocialScoreDB
	if not filterNum or not db.filterList[filterNum] then return nil end
	local t = db.filterBlocked[filterNum]
	if type(t) ~= "table" then t = {}; db.filterBlocked[filterNum] = t end
	t.counts = History.EnsureCounts(t.counts)
	return t.counts
end

-- the filter's lines, newest first (a guild rule has none: its blocks are
-- on the Guild Ignore List)
function M.PSS_FilterHistory(filterNum)
	local db = PourSocialScoreDB
	if not filterNum or not db.filterList[filterNum] then return nil end
	if M.PSS_IsGuildRuleText(db.filterList[filterNum]) then return {} end
	return History.For(M.PSS_FilterOwnerKey(filterNum))
end

function M.PSS_ResetFilterHistory(filterNum)
	local db = PourSocialScoreDB
	if not filterNum or not db.filterList[filterNum] then return end
	local key = M.PSS_FilterOwnerKey(filterNum)
	History.ClearOwner(key)
	History.ForgetRecent(key)
	db.filterBlocked[filterNum] = { counts = History.EmptyCounts() }
	db.filterBlockedLast[filterNum] = 0
	M.Events.Fire("FILTER_HISTORY_CHANGED", filterNum)
end

local function AddToBlockHistory (filterNum, ctx, from, chNumber, chName)
	local counts = M.PSS_FilterCounts(filterNum)
	if not counts then return end
	local channel = M.PSS_ChannelLabel and M.PSS_ChannelLabel(ctx.event, ctx.channelString, chNumber, chName) or nil
	local entry = History.NewEntry(ctx.cat, ctx.event, ctx.msg, channel, from)
	History.Add(M.PSS_FilterOwnerKey(filterNum), counts, entry)
	M.Events.Fire("FILTER_HISTORY_CHANGED", filterNum)
end

-- Guild rules ("InfluencerGuild=<Name>", and any later guild rule) only
-- switch their guilds on or off. Their blocks are guild blocks: counted once,
-- on the Guild Ignore List (the shipped list and the members found in game
-- are one list there). They never count as a chat filter block, so the Chat
-- Filters tab shows n/a for them.
-- Could filter index own block history lines? Lines are only ever added
-- with a count (an old save's per-filter list counts too).
local function filterMayHaveLines(index)
	local db = PourSocialScoreDB
	if (tonumber(db.filterCount[index]) or 0) > 0 then return true end
	local t = db.filterBlocked[index]
	if type(t) ~= "table" then return false end
	if History.CountTotal(t.counts) > 0 then return true end
	return #t > 0
end

-- The parallel arrays of the custom filters, kept in step by position.
local FILTER_ARRAYS = { "filterList", "filterDesc", "filterActive", "filterID", "filterCount", "filterBlocked", "filterBlockedLast" }
M.PSS_FILTER_ARRAYS = FILTER_ARRAYS

function M.RemoveChatFilter (index)
	if PourSocialScoreDB.filterList[index] then
		-- with nothing counted there are no saved lines; the block history
		-- (Logging) is never loaded for it (History.ClearOwner)
		local key = M.PSS_FilterOwnerKey(index)
		History.ClearOwner(key, filterMayHaveLines(index))
		History.ForgetRecent(key)
		for _, k in ipairs(FILTER_ARRAYS) do table.remove(PourSocialScoreDB[k], index) end
		M.Events.Fire("FILTERS_CHANGED")
	end
end

local function isDefFilterID (id)

	-- (a custom filter: no id, or a newer version's number id, kept)
	if (id == nil or id == "" or type(id) == "number") then return -1 end

	for count = 1, #filterDefID do
		if filterDefID[count] == id then
			return count
		end
	end

	return 0
end

function M.ResetSpamFilters()
	PourSocialScoreDB.filterList			= {}
	PourSocialScoreDB.filterDesc			= {}
	PourSocialScoreDB.filterCount			= {}
	PourSocialScoreDB.filterActive			= {}
	PourSocialScoreDB.filterID				= {}
	PourSocialScoreDB.filterBlocked		= {}
	PourSocialScoreDB.filterBlockedLast	= {}

	PourSocialScoreDB.invertSpam = nil		-- (their defaults)
	PourSocialScoreDB.spamFilter = nil
	PourSocialScoreDB.builtinRules = {}
	PourSocialScoreDB.builtinStats = {}

	for count = 1, #filterDefDesc do
		PourSocialScoreDB.filterDesc[count]		= filterDefDesc[count]
		PourSocialScoreDB.filterList[count]		= filterDefFilter[count]
		PourSocialScoreDB.filterActive[count]		= filterDefActive[count]
		PourSocialScoreDB.filterID[count]			= filterDefID[count]
		PourSocialScoreDB.filterCount[count]		= 0
		PourSocialScoreDB.filterBlocked[count]		= {}
		PourSocialScoreDB.filterBlockedLast[count]	= 0
	end
	M.Events.Fire("FILTERS_CHANGED")
end

------------------------------------------------------------------------
-- BUILT-IN vs CUSTOM CHAT FILTERS
--
-- Built-in (default) rules are defined in code (filterDef* above) and are
-- read-only. SavedVariables only record, per built-in rule ID:
--     PourSocialScoreDB.builtinRules[id] = true | false        (enabled state)
-- plus its blocked count / history in builtinStats[id] (statistics, not rule
-- configuration). The filterList/filterDesc/... arrays in SavedVariables hold
-- CUSTOM rules only.
--
-- At runtime the arrays are expanded (built-ins first, in code order, then
-- custom rules) so all existing index-based code keeps working; they are
-- collapsed back on PLAYER_LOGOUT (which also fires on /reload) before the
-- client writes SavedVariables.
------------------------------------------------------------------------
local FILTER_FORMAT = 2
local filtersExpanded = false


function M.PSS_IsBuiltinFilterID(id)
	if type(id) ~= "string" or id == "" then return false end
	for count = 1, #filterDefID do
		if filterDefID[count] == id then return true end
	end
	return false
end

-- "InfluencerGuild=Olympus": a guild rule, not a text filter.
-- Worked out once per filter text: this runs for every active filter on
-- every chat line, and lower() + match each time cost more than the filters.
local guildRuleText, guildRuleCount = {}, 0
function M.PSS_IsGuildRuleText(text)
	if type(text) ~= "string" then return false end
	local r = guildRuleText[text]
	if r == nil then
		r = text:lower():match("^%s*influencerguild%s*=") ~= nil
		if guildRuleCount > 300 then guildRuleText, guildRuleCount = {}, 0 end		-- edited filters leave old texts behind
		guildRuleText[text] = r
		guildRuleCount = guildRuleCount + 1
	end
	return r
end

function M.PSS_IsGuildRuleFilter(index)
	local db = PourSocialScoreDB
	return db and db.filterList and M.PSS_IsGuildRuleText(db.filterList[index]) or false
end

local groupIndexCache = {}
local groupIds = {}		-- group key -> its filter id (P4, N28: not a walk per line)
local function groupFilterIndex(groupKey)
	local db = PourSocialScoreDB
	if not db or not db.filterID then return nil end
	local id = groupIds[groupKey]
	if not id then
		for _, grp in ipairs((addon.MANAGED and addon.MANAGED.groups) or {}) do
			if grp.key == groupKey then id = grp.id break end
		end
		if not id then return nil end
		groupIds[groupKey] = id
	end
	local i = groupIndexCache[id]
	if i and db.filterID[i] == id then return i end
	for n = 1, #db.filterID do
		if db.filterID[n] == id then groupIndexCache[id] = n return n end
	end
	return nil
end
M.PSS_ManagedGroupFilterIndex = groupFilterIndex

-- Is the Chat Filters rule of a managed guild group switched on?
function M.PSS_ManagedGroupActive(groupKey)
	local i = groupFilterIndex(groupKey)
	return i ~= nil and PourSocialScoreDB.filterActive[i] == true
end

function M.PSS_SetManagedGroupActive(groupKey, on)
	local i = groupFilterIndex(groupKey)
	if i then PourSocialScoreDB.filterActive[i] = on == true end
	-- switched on: load the shipped member lists (PourSocialScore_Communities)
	if on and M.PSS_LoadActiveManagedData then M.PSS_LoadActiveManagedData() end
	M.Events.Fire("FILTERS_CHANGED")
	if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
end

function M.PSS_IsBuiltinFilter(index)
	return PourSocialScoreDB and PourSocialScoreDB.filterID and M.PSS_IsBuiltinFilterID(PourSocialScoreDB.filterID[index]) or false
end

local function appendFilter(t, desc, list, active, id, count, blocked, blockedLast)
	local i = #t.filterList + 1
	t.filterList[i]			= list
	t.filterDesc[i]			= desc
	t.filterActive[i]		= active == true
	t.filterID[i]			= id or ""
	t.filterCount[i]		= tonumber(count) or 0
	t.filterBlocked[i]		= type(blocked) == "table" and blocked or {}
	t.filterBlockedLast[i] = tonumber(blockedLast) or 0
	return i
end

-- SavedVariables -> runtime arrays (built-ins from code + custom rules).
function M.PSS_ExpandFilters()
	local db = PourSocialScoreDB
	for _, k in ipairs(FILTER_ARRAYS) do db[k] = db[k] or {} end
	db.builtinRules = type(db.builtinRules) == "table" and db.builtinRules or {}
	db.builtinStats = type(db.builtinStats) == "table" and db.builtinStats or {}

	-- 2.0.10: chat filters are opt in. 2.0.9 shipped "Filter Asmon" and
	-- "Filter Olympus" switched on; switch them off once. Every other saved
	-- on/off choice is kept.
	if not db.optInFiltersV1 then
		db.builtinRules["PSS0015"] = nil
		db.builtinRules["PSS0016"] = nil
		for i = 1, #db.filterList do
			if db.filterID[i] == "PSS0015" or db.filterID[i] == "PSS0016" then db.filterActive[i] = false end
		end
		db.optInFiltersV1 = true
	end

	local custom = {}
	for _, k in ipairs(FILTER_ARRAYS) do custom[k] = {} end

	for i = 1, #db.filterList do
		local id = db.filterID[i] or ""
		local defIdx = isDefFilterID(id)
		if defIdx > 0 then
			-- Older format stored the built-in rule in full. Keep its state and
			-- statistics. If the user had changed the built-in's text, keep
			-- their version as a custom rule so nothing they wrote is lost.
			db.builtinRules[id] = db.filterActive[i] == true
			db.builtinStats[id] = { count = tonumber(db.filterCount[i]) or 0, blocked = db.filterBlocked[i] or {}, blockedLast = tonumber(db.filterBlockedLast[i]) or 0 }
			if db.filterList[i] ~= filterDefFilter[defIdx] then
				appendFilter(custom, (db.filterDesc[i] or filterDefDesc[defIdx]) .. " (custom)", db.filterList[i],
					db.filterActive[i], "", 0, {}, 0)
				db.builtinRules[id] = false
			end
		elseif defIdx == 0 then
			-- ID of a built-in that no longer exists: drop it (old auto-update did the same)
		else
			appendFilter(custom, db.filterDesc[i] or "Custom Filter", db.filterList[i] or "", db.filterActive[i],
				id, db.filterCount[i], db.filterBlocked[i], db.filterBlockedLast[i])
		end
	end

	local runtime = {}
	for _, k in ipairs(FILTER_ARRAYS) do runtime[k] = {} end
	for count = 1, #filterDefID do
		local id = filterDefID[count]
		local active = db.builtinRules[id]
		if active == nil then active = filterDefActive[count] end
		local st = type(db.builtinStats[id]) == "table" and db.builtinStats[id] or {}
		appendFilter(runtime, filterDefDesc[count], filterDefFilter[count], active, id, st.count, st.blocked, st.blockedLast)
	end
	for i = 1, #custom.filterList do
		appendFilter(runtime, custom.filterDesc[i], custom.filterList[i], custom.filterActive[i], custom.filterID[i],
			custom.filterCount[i], custom.filterBlocked[i], custom.filterBlockedLast[i])
	end
	for _, k in ipairs(FILTER_ARRAYS) do db[k] = runtime[k] end
	db.filterFormat = FILTER_FORMAT
	filtersExpanded = true
	-- block history in the shared format (converts the old ring buffer once;
	-- unknown fields become "Unknown")
	-- 2.0.17: the lines move into the shared block log; only the per-type
	-- counts stay on the filter
	local sources = {}
	for i = 1, #db.filterList do
		local list = History.MigrateFilterList(db.filterBlocked[i], db.filterBlockedLast[i])
		if #list > 0 then sources[#sources + 1] = { list = list, owner = M.PSS_FilterOwnerKey(i) } end
		local stat = { counts = History.EnsureCounts(list.counts) }
		-- a field this version does not know stays (U3)
		local old = db.filterBlocked[i]
		if type(old) == "table" then
			for k, v in pairs(old) do
				if type(k) == "string" and k ~= "counts" and not M.PSS_SchemaKnows("filterStat", k) then stat[k] = v end
			end
		end
		db.filterBlocked[i] = stat
		db.filterBlockedLast[i] = 0
	end
	if #sources > 0 then History.Absorb(sources) end
end

-- a rule's counts as saved (S3): no zero types, no total the types give
local function sparseStat(b)
	if type(b) == "table" and type(b.counts) == "table" and not History.CompactCounts(b.counts) then b.counts = nil end
	return b
end

-- runtime arrays -> SavedVariables (custom rules only + built-in states).
function M.PSS_CollapseFilters()
	if not filtersExpanded or type(PourSocialScoreDB) ~= "table" then return end
	local db = PourSocialScoreDB
	local custom = {}
	for _, k in ipairs(FILTER_ARRAYS) do custom[k] = {} end
	local rules, stats = {}, {}
	-- a built-in rule this version does not have (a newer version's) keeps
	-- its saved state (U3)
	for id, v in pairs(type(db.builtinRules) == "table" and db.builtinRules or {}) do
		if not M.PSS_IsBuiltinFilterID(id) then rules[id] = v end
	end
	for id, v in pairs(type(db.builtinStats) == "table" and db.builtinStats or {}) do
		if not M.PSS_IsBuiltinFilterID(id) then stats[id] = v end
	end
	for i = 1, #(db.filterList or {}) do
		local id = db.filterID[i] or ""
		if M.PSS_IsBuiltinFilterID(id) then
			rules[id] = db.filterActive[i] == true
			-- a guild rule counts nothing itself: no statistics to save
			if not M.PSS_IsGuildRuleText(db.filterList[i]) then stats[id] = { count = tonumber(db.filterCount[i]) or 0, blocked = sparseStat(db.filterBlocked[i]) or {}, blockedLast = tonumber(db.filterBlockedLast[i]) or 0 } end
		else
			appendFilter(custom, db.filterDesc[i], db.filterList[i], db.filterActive[i], type(id) == "number" and id or "",
				db.filterCount[i], sparseStat(db.filterBlocked[i]), db.filterBlockedLast[i])
		end
	end
	for _, k in ipairs(FILTER_ARRAYS) do db[k] = custom[k] end
	db.builtinRules = rules
	db.builtinStats = stats
	db.filterFormat = FILTER_FORMAT
	filtersExpanded = false
end

-- 2.0.39: guild rule blocks were counted twice, once on the guild (Guild
-- Ignore List) and again on the guild rule's Chat Filters row, its tab total
-- and the filter session / 24 hour counts. They are guild blocks only now.
-- Once: take the rule's count back out of the Chat Filters total and the
-- 24 hour counts, zero the rule's own counts and clear the rule tag (h.r)
-- from the block history lines. Runs after the block history upgrade and
-- before the block stats upgrade (which would otherwise seed from h.r).
-- Returns the number of guild rules whose counts were taken back.
function M.PSS_UnlinkGuildRuleCounts()
	local db = PourSocialScoreDB
	if type(db) ~= "table" or db.guildRuleCountsV1 then return 0 end
	local rules = 0
	for i = 1, #(db.filterList or {}) do
		if M.PSS_IsGuildRuleText(db.filterList[i]) then
			rules = rules + 1
			local n = tonumber(db.filterCount[i]) or 0
			db.filterTotal = math.max(0, (tonumber(db.filterTotal) or 0) - n)
			db.filterCount[i] = 0
			db.filterBlocked[i] = { counts = History.EmptyCounts() }
			db.filterBlockedLast[i] = 0
		end
	end
	History.Each(function(h)
		if type(h) == "table" and h.r ~= nil then
			h.r = nil
		end
	end)
	db.guildRuleCountsV1 = true
	return rules
end

-- A custom filter's id (core uplift S3): a number that is never used twice.
-- nextFilterId only goes up (saved with the chat rules); it also stays above
-- any number id a newer version made. History and recent counts key on
-- "f:<id>", so editing a filter keeps its history and a copy starts its own.
function M.PSS_NewFilterId()
	local db = PourSocialScoreDB
	local n = math.floor(tonumber(db.nextFilterId) or 0)
	for _, id in ipairs(db.filterID or {}) do
		if type(id) == "number" and id > n then n = math.floor(id) end
	end
	n = n + 1
	db.nextFilterId = n
	return n
end

-- Upgrade step 10: every custom filter without an id gets one, and its lines
-- and recent counts move from the filter's text ("f:t:<text>") to "f:<id>".
-- Two filters with the same text shared one owner: the first one takes it.
-- Logging is loaded first when a filter may have lines (they are in its
-- file); returns false when it cannot load (the step tries again at the next
-- login). Returns how many filters were given an id.
function M.PSS_AssignCustomFilterIds()
	local db = PourSocialScoreDB
	if type(db) ~= "table" or type(db.filterID) ~= "table" then return 0 end
	local todo, needLog = {}, false
	for i = 1, #db.filterList do
		local id = db.filterID[i]
		if (id == nil or id == "") and type(db.filterList[i]) == "string" and not M.PSS_IsGuildRuleText(db.filterList[i]) then
			todo[#todo + 1] = i
			if filterMayHaveLines(i) then needLog = true end
		end
	end
	if #todo == 0 then return 0 end
	if needLog and not History.Loaded() and not (M.PSS_LoadLogging and M.PSS_LoadLogging()) then return false end
	local moved = {}
	for _, i in ipairs(todo) do
		local text = db.filterList[i]
		local from = History.FilterKey("", text)
		local id = M.PSS_NewFilterId()
		db.filterID[i] = id
		if not moved[from] then
			moved[from] = true
			History.RenameOwner(from, History.FilterKey(id, text))
		end
	end
	return #todo
end

-- Copy any rule (built-in or custom) into a new, editable custom rule.
-- The copy starts disabled so it doesn't double-block alongside the original.
function M.PSS_CopyChatFilter(index)
	local db = PourSocialScoreDB
	if not db or not db.filterList or not db.filterList[index] then return nil end
	if M.PSS_IsGuildRuleText(db.filterList[index]) then return nil end		-- guild rules can't be copied
	local desc = db.filterDesc[index] or "Chat Filter"
	local i = appendFilter(db, "Copy of " .. desc, db.filterList[index], false, M.PSS_NewFilterId(), 0, {}, 0)
	M.Events.Fire("FILTERS_CHANGED")
	return i
end

function M.PSS_AddCustomFilter(desc, filter, active)
	local db = PourSocialScoreDB
	if not db or type(filter) ~= "string" or filter == "" then return nil end
	local i = appendFilter(db, desc or "Chat Filter", filter, active == true, M.PSS_NewFilterId(), 0, {}, 0)
	M.Events.Fire("FILTERS_CHANGED")
	return i
end

function M.PSS_SetFilterActive(index, active)
	local db = PourSocialScoreDB
	if not (db and db.filterActive and db.filterList[index]) then return end
	db.filterActive[index] = active == true
	-- a guild rule switches its guilds (shipped and found in game) with it
	if M.PSS_IsGuildRuleText(db.filterList[index]) then
		if active and M.PSS_LoadActiveManagedData then M.PSS_LoadActiveManagedData() end
		if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	end
	M.Events.Fire("FILTERS_CHANGED")
end

-- An edited custom chat filter: its description and filter text.
function M.PSS_SaveChatFilter(index, desc, filter)
	local db = PourSocialScoreDB
	if not (db and db.filterList and db.filterList[index]) then return end
	db.filterDesc[index] = desc
	db.filterList[index] = filter
	M.Events.Fire("FILTERS_CHANGED")
end

-- The filter's blocked count starts again from 0 (its lines are kept).
function M.PSS_ResetFilterCount(index)
	local db = PourSocialScoreDB
	if not (db and db.filterList and db.filterList[index]) then return end
	db.filterCount[index] = 0
	History.ForgetRecent(M.PSS_FilterOwnerKey(index))
	M.Events.Fire("FILTERS_CHANGED")
end


-- Very old saves had no filter IDs: match them to built-ins by description.
function M.PSS_AssignLegacyFilterIDs()
	PourSocialScoreDB.filterID = {}
	for count = 1, #PourSocialScoreDB.filterDesc do
		PourSocialScoreDB.filterID[count] = ""
		for count2 = 1, #filterDefDesc do
			if PourSocialScoreDB.filterDesc[count] == filterDefDesc[count2] then
				PourSocialScoreDB.filterID[count] = filterDefID[count2]
			end
		end
	end
end

------------------------
-- SPAM FILTER ENGINE --
------------------------

------------------------------------------------------------------------
-- COMPILED FILTER ENGINE
--
-- Each filter is compiled ONCE into a small tree and cached by its text;
-- every chat line is then checked against the trees. (Up to 2.0.14 every
-- active filter was re-parsed character by character for every chat line,
-- which cost ~0.5 ms and ~20 KB of garbage per line.)
--
-- Language (unchanged): tags in square brackets, "not", "and" (or two tags
-- side by side), "or", brackets. "not" first, then "and", then "or".
-- A backslash makes the next character literal (\  \( \) \[ \] \\).
------------------------------------------------------------------------
local sub, find, lower, byte, char, gmatch, gsub =
	string.sub, string.find, string.lower, string.byte, string.char, string.gmatch, string.gsub

local KNOWN_TAGS = {
	["[word]"] = true, ["[contains]"] = true, ["[chname]"] = true, ["[channel]"] = true, ["[words]"] = true,
	["[item]"] = true, ["[spell]"] = true, ["[achievement]"] = true, ["[icon]"] = true, ["[pet]"] = true,
	["[link]"] = true, ["[trade]"] = true, ["[guild]"] = true, ["[outfit]"] = true, ["[journal]"] = true,
	["[mount]"] = true, ["[community]"] = true, ["[nonlatin]"] = true, ["[talent]"] = true,
	["[cyrillic]"] = true,
}

-- text -> list of tokens: "(", ")", "!", "|", { tag, data } ; nil on error
local function tokenize(text)
	local tokens, buf, n = {}, {}, 0
	local function flush()
		if n == 0 then return true end
		local token = table.concat(buf, "", 1, n)
		n = 0
		local data = ""
		local eq = find(token, "=", 1, true)
		if eq then
			data = sub(token, eq + 1, -2)
			token = sub(token, 1, eq - 1) .. "]"
		end
		token = token:match("^%s*(.-)%s*$")
		if token == "not" then tokens[#tokens + 1] = "!"
		elseif token == "and" then -- implicit
		elseif token == "or" then tokens[#tokens + 1] = "|"
		elseif KNOWN_TAGS[token] then tokens[#tokens + 1] = { token, data }
		elseif token ~= "" then return false
		end
		return true
	end
	local i, len, escaped = 1, #text, false
	while i <= len do
		local c = byte(text, i)
		if escaped then
			n = n + 1; buf[n] = lower(char(c)); escaped = false
		elseif c == 92 then
			escaped = true
		elseif c == 32 or c == 40 or c == 41 then
			if not flush() then return nil end
			if c == 40 then tokens[#tokens + 1] = "(" elseif c == 41 then tokens[#tokens + 1] = ")" end
		else
			n = n + 1
			buf[n] = (c < 32 or c > 126) and char(c) or lower(char(c))
		end
		i = i + 1
	end
	if not flush() then return nil end
	return tokens
end

-- tokens -> tree. node = { "or", ... } | { "and", ... } | { "not", node } | { "tag", name, data }
local function parse(tokens)
	local pos = 1
	local parseExpr
	local function parseFactor()
		local t = tokens[pos]
		if t == "!" then
			pos = pos + 1
			local f = parseFactor()
			return f and { "not", f } or nil
		elseif t == "(" then
			pos = pos + 1
			local e = parseExpr()
			if tokens[pos] == ")" then pos = pos + 1 end
			return e or { "and" }				-- "()" is false (empty AND => see eval)
		elseif type(t) == "table" then
			pos = pos + 1
			return { "tag", t[1], t[2] }
		end
		return nil
	end
	local function parseTerm()
		local node = { "and" }
		while true do
			local t = tokens[pos]
			if t == nil or t == "|" or t == ")" then break end
			local f = parseFactor()
			if not f then pos = pos + 1 else node[#node + 1] = f end
		end
		return node
	end
	parseExpr = function()
		local node = { "or" }
		while true do
			local term = parseTerm()
			if #term > 1 then node[#node + 1] = term end
			if tokens[pos] == "|" then pos = pos + 1 else break end
		end
		return node
	end
	local tree = parseExpr()
	return tree
end

local compiled, compiledCount = {}, 0
-- filter text -> tree, or false when the filter has an error
local function compileFilter(text)
	local c = compiled[text]
	if c ~= nil then return c end
	local tokens = tokenize("( " .. text .. " )")
	c = tokens and parse(tokens) or false
	if compiledCount > 300 then compiled, compiledCount = {}, 0 end		-- edited filters leave old texts behind
	compiled[text] = c
	compiledCount = compiledCount + 1
	return c
end
M.PSS_CompileFilter = compileFilter

------------------------------------------------------------------------
-- Message features: worked out once per chat line, only when a filter asks.
------------------------------------------------------------------------
local ICON_CODES = { "{x}", "{star}", "{coin}", "{moon}", "{cross}", "{skull}", "{square}", "{circle}", "{diamond}", "{triangle}" }

-- One feature table (and its sub-tables), reused for every line: the
-- result is only used while that line is checked.
local Fbuf = { itemID = {}, spellID = {}, achieveID = {}, petID = {}, talentID = {}, wordSet = {}, wordCount = 0 }
local function clear(t) for k in pairs(t) do t[k] = nil end end

local function analyse(chatStr)
	local F = Fbuf
	clear(F.itemID); clear(F.spellID); clear(F.achieveID); clear(F.petID); clear(F.talentID)
	F.talents, F.icons, F.words, F.chNumber, F.chName = 0, 0, nil, nil, nil
	local pos1, pos2, pos3
	-- links and colour codes are only present when there is a "|"
	if find(chatStr, "|", 1, true) then
		repeat
			pos1 = find(chatStr, "|htalent:", 1, true)
			if not pos1 then break end
			pos2 = find(chatStr, "|h|r", pos1 + 9, true)
			if not pos2 then break end
			F.talents = F.talents + 1
			F.talentID[sub(chatStr, pos1 + 9, (find(chatStr, ":", pos1 + 9, true) or pos2) - 1)] = true
			chatStr = sub(chatStr, 1, pos1 - 1) .. " " .. sub(chatStr, pos2 + 4, -1)
		until false
		repeat
			pos1 = find(chatStr, "|cniq", 1, true)
			if not pos1 then break end
			pos2 = find(chatStr, "item:", pos1 + 6, true)
			if not pos2 then break end
			pos3 = find(chatStr, "|r", pos2, true)
			if not pos3 then break end
			F.itemID[sub(chatStr, pos2 + 5, (find(chatStr, ":", pos2 + 5, true) or pos3) - 1)] = true
			chatStr = sub(chatStr, 1, pos1 - 1) .. sub(chatStr, pos3 + 2)
		until false
		repeat
			pos1 = find(chatStr, "|c", 1, true)
			if not pos1 then break end
			chatStr = sub(chatStr, 1, pos1 - 1) .. sub(chatStr, pos1 + 10, -1)
		until false
		repeat
			pos1 = find(chatStr, "|hbattlepet:", 1, true)
			if not pos1 then break end
			pos2 = find(chatStr, "|h|r", pos1 + 12, true)
			if not pos2 then break end
			F.petID[sub(chatStr, pos1 + 12, (find(chatStr, ":", pos1 + 13, true) or pos2) - 1)] = true
			chatStr = sub(chatStr, 1, pos1 - 1) .. " " .. sub(chatStr, pos2 + 4, -1)
		until false
		repeat
			pos1 = find(chatStr, "|hitem:", 1, true)
			if not pos1 then break end
			pos2 = find(chatStr, "|h|r", pos1 + 8, true) or find(chatStr, "|r|h", pos1 + 8, true)
			if not pos2 then break end
			F.itemID[sub(chatStr, pos1 + 7, (find(chatStr, ":", pos1 + 7, true) or find(chatStr, "[", pos1 + 8, true) or pos2) - 1)] = true
			chatStr = sub(chatStr, 1, pos1 - 1) .. " " .. sub(chatStr, pos2 + 4, -1)
		until false
		repeat
			pos1 = find(chatStr, "|hspell:", 1, true)
			if not pos1 then break end
			pos2 = find(chatStr, "|h|r", pos1 + 8, true)
			if not pos2 then break end
			pos3 = find(chatStr, ":", pos1 + 9, true)
			if not pos3 then break end
			F.spellID[sub(chatStr, pos1 + 8, pos3 - 1)] = true
			chatStr = sub(chatStr, 1, pos1 - 1) .. " " .. sub(chatStr, pos2 + 4, -1)
		until false
		repeat
			pos1 = find(chatStr, "|hachievement:", 1, true)
			if not pos1 then break end
			pos2 = find(chatStr, "|h|r", pos1 + 14, true)
			if not pos2 then break end
			F.achieveID[sub(chatStr, pos1 + 14, (find(chatStr, ":", pos1 + 15, true) or pos2) - 1)] = true
			chatStr = sub(chatStr, 1, pos1 - 1) .. " " .. sub(chatStr, pos2 + 4, -1)
		until false
	end
	-- raid icons
	if find(chatStr, "{", 1, true) then
		local n
		chatStr, n = gsub(chatStr, "{rt%d}", " ")
		F.icons = F.icons + n
		for _, code in ipairs(ICON_CODES) do
			local s1 = find(chatStr, code, 1, true)
			while s1 do
				F.icons = F.icons + 1
				chatStr = sub(chatStr, 1, s1 - 1) .. " " .. sub(chatStr, s1 + #code)
				s1 = find(chatStr, code, 1, true)
			end
		end
	end
	F.text = chatStr
	F.hasGuild		= find(chatStr, "|hclubfinder:", 1, true) ~= nil
	F.hasTrade		= find(chatStr, "|htrade:", 1, true) ~= nil
	F.hasJournal = find(chatStr, "|hjournal:", 1, true) ~= nil
	F.hasMount		= find(chatStr, "|hmount:", 1, true) ~= nil
	F.hasOutfit		= find(chatStr, "|houtfit:", 1, true) ~= nil
	return F
end

-- the words of the line (punctuation at either end ignored), built on demand
local function words(F)
	local w = F.words
	if w then return w end
	w = F.wordSet
	clear(w)
	local count = 0						-- kept outside the set: a word may be "n"
	for word in gmatch(F.text, "%S+") do
		if find(word, "%p") then word = gsub(gsub(word, "[%p]+$", ""), "^[%p]+", "") end
		if word ~= "" then w[word] = true; count = count + 1 end
	end
	F.words, F.wordCount = w, count
	return w
end

local CYR = "[\208-\211][\128-\191]"
local function anyKey(t) return next(t) ~= nil end
local function hasKey(t, k) return t[k] == true end

local TAG = {
	-- a word of the line is always part of its text, so the plain find
	-- skips building the word list on most lines (same result)
	["[word]"]		= function(F, d) return find(F.text, d, 1, true) ~= nil and words(F)[d] == true end,
	["[contains]"] = function(F, d) return find(F.text, d, 1, true) ~= nil end,
	["[chname]"]	= function(F, d) return (F.chName and lower(F.chName) or "none") == d end,
	["[channel]"]	= function(F, d) return tonumber(d) == F.chNumber end,
	["[words]"]		= function(F, d) words(F); return tonumber(d) == F.wordCount end,
	["[item]"]		= function(F, d) if d == "" then return anyKey(F.itemID) end return hasKey(F.itemID, d) end,
	["[spell]"]		= function(F, d) if d == "" then return anyKey(F.spellID) end return hasKey(F.spellID, d) end,
	["[achievement]"] = function(F, d) if d == "" then return anyKey(F.achieveID) end return hasKey(F.achieveID, d) end,
	["[pet]"]		= function(F, d) if d == "" then return anyKey(F.petID) end return hasKey(F.petID, d) end,
	-- the Chat Filters tab's link converter makes [talent=N] (N42)
	["[talent]"]	= function(F, d) if d == "" then return F.talents > 0 end return hasKey(F.talentID, d) end,
	["[icon]"]		= function(F, d) if d == "" then return F.icons > 0 end return F.icons >= (tonumber(d) or 0) end,
	["[link]"]		= function(F) return anyKey(F.itemID) or anyKey(F.spellID) or anyKey(F.achieveID) or anyKey(F.petID)
						or F.talents > 0 or F.hasJournal or F.hasGuild or F.hasTrade or F.hasOutfit or F.hasMount end,
	["[trade]"]		= function(F) return F.hasTrade end,
	["[guild]"]		= function(F) return F.hasGuild end,
	["[outfit]"]	= function(F) return F.hasOutfit end,
	["[journal]"]	= function(F) return F.hasJournal end,
	["[mount]"]		= function(F) return F.hasMount end,
	["[community]"] = function(F) return find(F.text, "|hclubticket:", 1, true) ~= nil end,
	["[nonlatin]"] = function(F) return find(F.text, "[\227-\237]") ~= nil end,
	-- Cyrillic letters (U+0400-U+04FF: Russian, Ukrainian, Belarusian,
	-- Bulgarian, Serbian, Kazakh ...): in UTF-8 a lead byte 0xD0-0xD3.
	-- [cyrillic] = any; [cyrillic=N] = at least N of them (lets a stray
	-- lookalike letter through)
	["[cyrillic]"] = function(F, d)
		local need = tonumber(d) or 1
		if need <= 1 then return find(F.text, CYR) ~= nil end
		local n = 0
		for _ in gmatch(F.text, CYR) do n = n + 1; if n >= need then return true end end
		return false
	end,
}

-- tree -> function(F) returning true / false. Built once per filter text,
-- so a chat line runs plain function calls instead of walking the tree
-- (the walk was about half of the time spent on each line).
local function never() return false end
local buildNode
local function buildList(node)
	local list = {}
	for i = 2, #node do list[#list + 1] = buildNode(node[i]) end
	return list
end
buildNode = function(node)
	local kind = node[1]
	if kind == "tag" then
		local tag, d = node[2], node[3]
		if tag == "[contains]" then					-- most common: one call less
			return function(F) return find(F.text, d, 1, true) ~= nil end
		end
		local fn = TAG[tag]
		return function(F) return fn(F, d) == true end
	elseif kind == "not" then
		local inner = buildNode(node[2])
		return function(F) return not inner(F) end
	end
	local list = buildList(node)
	local n = #list
	if n == 0 then return never end				-- "()" and empty groups are false
	if n == 1 then return list[1] end
	if kind == "and" then
		return function(F)
			for i = 1, n do if not list[i](F) then return false end end
			return true
		end
	end
	return function(F)							-- or
		for i = 1, n do if list[i](F) then return true end end
		return false
	end
end

-- the filter list and its switches, read from PSS_RulesDB without the
-- router (P4, N26; a table PourSocialScoreDB still holds wins, as through it)
local function ruleLists()
	local db = PourSocialScoreDB
	local r = PSS_RulesDB
	local list, active = rawget(db, "filterList"), rawget(db, "filterActive")
	if r then list, active = list or r.filterList, active or r.filterActive end
	return list or db.filterList, active or db.filterActive
end

local runnable, runnableCount = {}, 0
-- filter text -> function(F), or false when the filter has an error
local function filterFn(text)
	local fn = runnable[text]
	if fn ~= nil then return fn end
	local tree = compileFilter(text)
	fn = tree and buildNode(tree) or false
	if runnableCount > 300 then runnable, runnableCount = {}, 0 end		-- edited filters leave old texts behind
	runnable[text] = fn
	runnableCount = runnableCount + 1
	return fn
end

-- true, filterNumber when the line should be hidden.
--   filterStr given : test only that filter (editor Test button); sets
--                     V.lastFilterError when the filter can't be read
--   filterStr nil   : every active text filter, in list order
-- chatStr must already be lower case.
function M.filterComplex (filterStr, chatStr, chNumber, chName)
	V.lastFilterError = false
	local F
	if filterStr ~= nil then
		local fn = filterFn(filterStr)
		if not fn then V.lastFilterError = true return false end
		F = analyse(chatStr); F.chNumber, F.chName = chNumber, chName
		if fn(F) then return true, 0 end
		return false
	end
	local list, active = ruleLists()
	for i = 1, #list do
		if active[i] == true then
			local text = list[i]
			if not M.PSS_IsGuildRuleText(text) then
				local fn = filterFn(text)
				if fn then
					if not F then F = analyse(chatStr); F.chNumber, F.chName = chNumber, chName end
					if fn(F) then return true, i end
				end
			end
		end
	end
	return false
end

-- any text filter switched on? (cheap: no tables, no strings)
local function anyTextFilterOn()
	local list, active = ruleLists()
	for i = 1, #list do
		if active[i] == true and not M.PSS_IsGuildRuleText(list[i]) then return true end
	end
	return false
end


------------------------------------------------------------------------
-- Text handler for the core. ctx: event, cat, msg, author, chNumber,
-- chName, isSelf ... Runs once per chat line (the core caches decisions).
------------------------------------------------------------------------
local function opt(key) if M.PSS_Opt then return M.PSS_Opt(key) end return PourSocialScoreDB[key] end

-- duplicate (flood) filter: the last pssFloodSize lines, as a ring + set
local floodRing, floodSet, floodPos = {}, {}, 0

function M.PSS_ChatFilters_Evaluate(ctx)
	if opt("spamFilter") ~= true then return false end
	local cat, event = ctx.cat, ctx.event
	if opt("skipGuild") == true and cat == "guildChat" then return false end
	if opt("skipParty") == true and cat == "partyRaid" then return false end
	if opt("skipPrivate") == true and (event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER") then return false end
	if opt("skipYourself") == true and ctx.isSelf then return false end
	if type(ctx.msg) ~= "string" then return false end

	local flood = tonumber(opt("floodFilter")) or 0
	local invert = opt("invertSpam") == true
	-- nothing to do: don't even lower-case the line
	if flood == 0 and not invert and not anyTextFilterOn() then return false end

	local newMsg = lower(ctx.msg)

	if flood > 0 then
		local text = (flood == 1) and ((ctx.canon or ctx.author or "") .. "\1" .. newMsg) or newMsg
		if floodSet[text] then return true end
		floodPos = floodPos % pssFloodSize + 1
		local old = floodRing[floodPos]
		if old then
			floodSet[old] = floodSet[old] - 1
			if floodSet[old] <= 0 then floodSet[old] = nil end
		end
		floodRing[floodPos] = text
		floodSet[text] = (floodSet[text] or 0) + 1
	end

	local chNumber, chName = ctx.chNumber, ctx.chName
	if not chNumber or chNumber == 0 then
		chNumber = 0
		chName = sub(event, 10)
	end

	local result, filterNum = M.filterComplex(nil, newMsg, chNumber, chName)
	if result == true then
		if invert then return false end
		PourSocialScoreDB.filterTotal = (PourSocialScoreDB.filterTotal or 0) + 1
		PourSocialScoreDB.filterCount[filterNum] = (PourSocialScoreDB.filterCount[filterNum] or 0) + 1
		if event == "CHAT_MSG_WHISPER" then
			PourSocialScoreDB.filterWhisperTotal = (PourSocialScoreDB.filterWhisperTotal or 0) + 1
		elseif event == "CHAT_MSG_BN_WHISPER" then
			PourSocialScoreDB.filterPrivateTotal = (PourSocialScoreDB.filterPrivateTotal or 0) + 1
		end
		-- the sender's display name is only built for a hidden line
		local from = M.Proper(M.addServer(ctx.author or _G.UNKNOWN))
		-- FILTER_HISTORY_CHANGED (fired there) says the counts changed
		AddToBlockHistory(filterNum, ctx, from, chNumber, chName)
		return true, filterNum
	end
	if invert then
		PourSocialScoreDB.filterTotal = (PourSocialScoreDB.filterTotal or 0) + 1
		return true
	end
	return false
end

if M.PSS_RegisterBlockHandler then
	M.PSS_RegisterBlockHandler("text", "chatFilters", function(ctx) return M.PSS_ChatFilters_Evaluate(ctx) end)
end
