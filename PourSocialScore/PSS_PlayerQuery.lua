------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PLAYER IGNORE LIST QUERIES (3.1)
--
-- What a front end needs to show and change the Player Ignore List, so the
-- PSS window (PourSocialScore_GUI) never reads the saved tables itself.
--   M.PSS_PlayerCount()                   entries on the list
--   M.PSS_PlayerRow(i, out)               entry i as display values, written
--                                         into out (the caller's own table,
--                                         reused for every row: no table
--                                         per row)
--   M.PSS_SortPlayers(key, asc, find, into)  list positions in display order
--   M.PSS_PlayerEntry(i)                  entry i as stored, and its kind
--   M.PSS_PlayerPosition(entry)           position of an entry (0 = none)
--   M.PSS_ListedBlockTotals(sum)          block counts of every listed player
--   M.PSS_IsGuildListed(guild)            the guild is on the Guild Ignore List
--   M.PSS_RemovePlayerAt(i)               remove entry i (player, NPC, server)
--   M.PSS_PlayersChanged(forced)          the one refresh entry: every front
--                                         end that is loaded redraws its
--                                         players (forced: re-sort)
------------------------------------------------------------------------
local addonName, addon = ...
local M = addon.M
local V = addon.V

local find, sub, lower = string.find, string.sub, string.lower

local EXCL_BY_CAT = {}
for _, e in ipairs(M.EXCL) do EXCL_BY_CAT[e.cat] = e end

function M.PSS_PlayerCount()
	return #PourSocialScoreDB.ignoreList
end

-- out gets: entry (as stored), kind ("player", "npc", "server"), name,
-- server (both as shown: a server entry reads All / <server>), faction,
-- added (the date listed, as saved), listed (days on the list), expire (days after listing, 0 = never),
-- left (days until it expires), note, record (the player's settings and
-- counts; players only, else false). Returns out, or nil when there is no
-- entry i.
function M.PSS_PlayerRow(i, out)
	local db = PourSocialScoreDB
	local entry = db.ignoreList[i]
	if not entry then return nil end
	local kind = db.typeList[i] or "player"		-- (as RemoveFromList reads it)
	local name, server = entry, "All"
	local dash = find(entry, "-", 1, true)
	if dash then
		name = sub(entry, 1, dash - 1)
		server = M.prettyServer(sub(entry, dash + 1))
	end
	if kind ~= "player" and kind ~= "npc" then
		kind = "server"
		server = M.prettyServer(name)
		name = "All"
	end
	local listed = M.daysFromToday(db.dateList[i])
	local expire = db.expList[i] or 0
	out.entry, out.kind, out.name, out.server = entry, kind, name, server
	out.faction = db.factionList[i]
	out.added = db.dateList[i]
	out.listed, out.expire, out.left = listed, expire, expire - listed
	out.note = db.notes[i]
	out.record = kind == "player" and M.PSS_GetPlayerPrefs(entry) or false
	return out
end

function M.PSS_PlayerEntry(i)
	local db = PourSocialScoreDB
	local entry = db.ignoreList[i]
	if entry then return entry, db.typeList[i] end
end

function M.PSS_PlayerPosition(entry)
	if type(entry) ~= "string" then return 0 end
	return M.hasAnyIgnored(entry) or 0
end

function M.PSS_IsGuildListed(guild)
	if type(guild) ~= "string" or guild == "" then return false end
	local data = PourSocialScoreDB.guildData
	local key = M.PSS_NormalizeGuild(guild)
	return (data and key and data[key]) and true or false
end

-- sum: a table with the count keys to add up (total, whisper, ...), set to
-- the totals of every listed player. Players without a record add nothing.
function M.PSS_ListedBlockTotals(sum)
	local db = PourSocialScoreDB
	for k in pairs(sum) do sum[k] = 0 end
	for i, name in ipairs(db.ignoreList) do
		if db.typeList[i] == "player" and M.PSS_GetPlayerRecord(name) then
			local c = M.PSS_GetPlayerBlockCounts(name)
			for k in pairs(sum) do sum[k] = sum[k] + (c[k] or 0) end
		end
	end
	return sum
end

------------------------------------------------------------------------
-- Sorting: one key + direction. Keys: name, server, type, listed, expire,
-- note, "metric:<cat>" (block counts) and "excl:<cat>" (W I G P C, by
-- tick: allowed first when ascending). Blank values (empty notes; counts
-- and switches of NPC and server rows) always go last; ties fall back to
-- name A-Z, then server A-Z, then list order.
------------------------------------------------------------------------
local function elementName(i)
	local db = PourSocialScoreDB
	local kind = db.typeList[i]
	if kind == "player" or kind == "npc" then
		return M.removeServer(db.ignoreList[i], true)
	elseif kind == "server" then
		return "All"
	end
	return ""
end

local function elementServer(i)
	local db = PourSocialScoreDB
	local kind = db.typeList[i]
	if kind == "player" then
		return M.getServer(db.ignoreList[i])
	elseif kind == "server" then
		return db.ignoreList[i]
	elseif kind == "npc" then
		return "All"
	end
	return ""
end

local function elementType(i)
	local db = PourSocialScoreDB
	local kind = db.typeList[i]
	if kind == "player" then return db.factionList[i] end
	return kind
end

local function sortValue(i, key)
	local db = PourSocialScoreDB
	if key == "name" then return lower(elementName(i) or "")
	elseif key == "server" then return lower(elementServer(i) or "")
	elseif key == "type" then return lower(elementType(i) or "")
	elseif key == "listed" then return M.daysFromToday(db.dateList[i]) or 0
	elseif key == "expire" then
		local e = tonumber(db.expList[i]) or 0
		if e == 0 then return math.huge end				-- never expires: after everything
		return e - (M.daysFromToday(db.dateList[i]) or 0)
	elseif key == "note" then
		local n = lower(db.notes[i] or "")
		if n == "" then return nil end					-- empty notes go last
		return n
	end
	local mcat = key:match("^metric:(.+)$")
	if mcat then
		if db.typeList[i] ~= "player" then return nil end
		local p = M.PSS_GetPlayerRecord(db.ignoreList[i])
		return p and (tonumber(M.PSS_GetPlayerBlockCounts(p)[mcat]) or 0) or 0
	end
	local cat = key:match("^excl:(.+)$")
	local ex = cat and EXCL_BY_CAT[cat]
	if ex then
		if db.typeList[i] ~= "player" then return nil end
		local p = M.PSS_GetPlayerRecord(db.ignoreList[i])
		return (not p or p[ex.field] ~= false) and 0 or 1	-- ticked (allowed) = 1
	end
	return 0
end

-- find: text to look for in the name, server and note (any case; "" or nil
-- = every entry). into: the table to fill (emptied first; a new one when
-- nil). Returns into and the number of positions in it.
function M.PSS_SortPlayers(key, asc, findText, into)
	local db = PourSocialScoreDB
	into = into or {}
	for i = #into, 1, -1 do into[i] = nil end
	if findText == "" then findText = nil end
	if findText then findText = lower(findText) end

	local sv, nv, srv = {}, {}, {}
	local n = 0
	for i = 1, #db.ignoreList do
		local keep = true
		if findText then
			-- the server as stored ("Area52") and as shown ("Area 52")
			local entry = db.ignoreList[i]
			local dash = find(entry, "-", 1, true)
			local shown = M.prettyServer(dash and sub(entry, dash + 1) or entry) or ""
			keep = find(lower(entry), findText, 1, true) ~= nil
				or find(lower(shown), findText, 1, true) ~= nil
				or find(lower(db.notes[i] or ""), findText, 1, true) ~= nil
		end
		if keep then
			n = n + 1
			into[n] = i
			sv[i] = sortValue(i, key)
			nv[i] = lower(elementName(i) or "")
			srv[i] = lower(elementServer(i) or "")
		end
	end

	table.sort(into, function(a, b)
		local A, B = sv[a], sv[b]
		if A ~= B then
			if A == nil then return false end			-- blanks always last
			if B == nil then return true end
			if asc then return A < B else return A > B end
		end
		if nv[a] ~= nv[b] then return nv[a] < nv[b] end
		if srv[a] ~= srv[b] then return srv[a] < srv[b] end
		return a < b
	end)
	return into, n
end

------------------------------------------------------------------------
-- Changes
------------------------------------------------------------------------
-- Remove entry i straight away: a player (also from Blizzard's ignore
-- list), an NPC or a whole server.
function M.PSS_RemovePlayerAt(i)
	local kind = PourSocialScoreDB.typeList[i]
	V.needSorted = true
	if kind == "player" then
		M.PSS_DelIgnore(i, true)
	elseif kind == "npc" then
		M.AddOrDelNPC(i)
		M.PSS_PlayersChanged()
	elseif kind == "server" then
		M.AddOrDelServer(i)
		M.PSS_PlayersChanged()
	end
end

function M.PSS_PlayersChanged(forced)
	if forced == true then V.needSorted = true end
	M.Events.Fire("PLAYERS_CHANGED", forced)
end
