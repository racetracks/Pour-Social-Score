------------------------------------------------------------------------
-- POUR SOCIAL SCORE - LIST TOTALS (3.2)
--
-- One list's blocks added up, for a front end to show when nothing on that
-- list is selected: the Player Ignore List, the Guild Ignore List or the
-- Chat Filters. In PourSocialScore_Libraries (load on demand), so none of
-- it is in memory until a window opens. Reads the counters only: it never
-- loads PourSocialScore_Logging and never writes saved data.
--   M.PSS_ListTotals(kind, into, guildRows)
--     kind: "players", "guilds" or "filters"
--     into: the caller's table, reused: total and one count per block
--           type (History.ALL_CATS), plus session and day (this session,
--           last 24 hours)
--     guildRows: for "guilds", a table M.PSS_GuildRows already filled
--           (its counts are added up instead of read again); nil reads them
--   History.RecentByCat(owner, into, prefix) (3.2.0-dev010)
--     this session's and the last 24 hours' blocks by type of owner, or
--     with prefix set of every owner whose key starts with it:
--     into.session[cat], into.day[cat] (into and its tables reused)
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local History = M.PSS_History

local PREFIX = { players = "p:", guilds = "G:", filters = "f:" }

local function add(into, c)
	if type(c) ~= "table" then return end
	into.total = into.total + (tonumber(c.total) or 0)
	for _, cat in ipairs(History.ALL_CATS) do
		into[cat] = into[cat] + (tonumber(c[cat]) or 0)
	end
end

function M.PSS_ListTotals(kind, into, guildRows)
	into = into or {}
	into.total = 0
	for _, cat in ipairs(History.ALL_CATS) do into[cat] = 0 end
	local db = PourSocialScoreDB
	if kind == "players" then
		for _, name in ipairs(db.ignoreList or {}) do
			local p = M.PSS_GetPlayerRecord(name)
			if p then add(into, M.PSS_GetPlayerBlockCounts(p)) end
		end
	elseif kind == "guilds" then
		local pool = guildRows and guildRows.pool
		if pool then
			for _, item in pairs(pool) do add(into, item.bc) end
		else
			for key, g in pairs(db.guildData or {}) do
				if type(g) == "table" then add(into, M.PSS_GetGuildBlockCounts(key)) end
			end
		end
	elseif kind == "filters" then
		-- a guild rule's blocks are on the Guild Ignore List, not here; a
		-- filter that never blocked has no counts table (none is made). The
		-- total is the filter's row count (filterCount): blocks from before
		-- the counts by type (2.0.36) are in it only, so they count as
		-- unknown type (3.3.0-dev002; the list's all time read less than
		-- the rows added up).
		for i = 1, #(db.filterList or {}) do
			if not M.PSS_IsGuildRuleFilter(i) then
				local t = db.filterBlocked and db.filterBlocked[i]
				local before = into.total
				if type(t) == "table" then add(into, t.counts) end
				local gap = (tonumber(db.filterCount and db.filterCount[i]) or 0) - (into.total - before)
				if gap > 0 then into.total, into.unknown = into.total + gap, into.unknown + gap end
			end
		end
	end
	into.session, into.day = 0, 0
	if PREFIX[kind] and History.RecentTotals then
		into.session, into.day = History.RecentTotals(PREFIX[kind])
	end
	return into
end

local function zero(t)
	for k in pairs(t) do t[k] = nil end
	return t
end

function History.RecentByCat(owner, into, prefix)
	into = into or {}
	local se = zero(into.session or {})
	local dy = zero(into.day or {})
	into.session, into.day = se, dy
	local sessionCat, r = History.RecentByCatData()
	local function want(o)
		if prefix then return type(o) == "string" and string.find(o, prefix, 1, true) == 1 end
		return o == owner
	end
	for cat, owners in pairs(sessionCat) do
		if prefix then
			for o, n in pairs(owners) do if want(o) then se[cat] = (se[cat] or 0) + n end end
		elseif owner ~= nil and owners[owner] then
			se[cat] = owners[owner]
		end
	end
	if r and (prefix or r.day[owner]) then
		local slots = History.DAY_SLOTS
		local cur = math.floor(History.Now() / History.SLOT)
		for s = cur, cur - slots + 1, -1 do
			local t = r[s % slots + 1]
			if t then
				for cat, owners in pairs(t) do
					if prefix then
						for o, n in pairs(owners) do if want(o) then dy[cat] = (dy[cat] or 0) + n end end
					elseif owners[owner] then
						dy[cat] = (dy[cat] or 0) + owners[owner]
					end
				end
			end
		end
	end
	return into
end
