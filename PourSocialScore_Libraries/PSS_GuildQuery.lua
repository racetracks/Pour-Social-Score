------------------------------------------------------------------------
-- POUR SOCIAL SCORE - GUILD IGNORE LIST QUERIES (3.1)
--
-- What a front end needs to show the Guild Ignore List and a guild's
-- members (the PSS window, PourSocialScore_GUI). It is in
-- PourSocialScore_Libraries, which the window loads first, so none of it
-- is in memory until the window opens. No events, no timers, and every
-- table a query fills belongs to the caller (reused on every redraw).
--   M.PSS_GuildCount()                    guild rules on the list
--   M.PSS_GuildRows(key, asc, find, into)   the list in display order
--   M.PSS_GuildMembers(gkey, key, asc, find, into)  a rule's members, sorted
--   M.PSS_GuildGroupOpen(k) / M.PSS_SetGuildGroupOpen(k, on)
--                                         collapsible rows (managed groups,
--                                         M.PSS_GUILD_EXCL_OPEN = the Guild
--                                         Exclusion List), kept in the save;
--                                         M.PSS_GUILD_MANAGED_SHUT = the
--                                         Managed Communities row is closed
--   M.PSS_FindGuildRule(guildNameOrKey)   key, record of a guild rule
--   M.PSS_AddMembersGuild(gkey, actual)   Add Guild on a member: a rule for
--                                         the member's actual guild
--   M.PSS_ForgetGuildSearch()             Guild Search results closed: drop
--                                         the players it saw
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local lower, find = string.lower, string.find
local History = M.PSS_History

M.PSS_GUILD_EXCL_OPEN = "__exclusions"
-- stored only while the Managed Communities row is closed (open by default)
M.PSS_GUILD_MANAGED_SHUT = "__managedShut"

function M.PSS_GuildGroupOpen(k)
	PourSocialScoreDB.guildGroupOpen = type(PourSocialScoreDB.guildGroupOpen) == "table" and PourSocialScoreDB.guildGroupOpen or {}
	return PourSocialScoreDB.guildGroupOpen[k] == true
end

function M.PSS_SetGuildGroupOpen(k, on)
	M.PSS_GuildGroupOpen(k)
	PourSocialScoreDB.guildGroupOpen[k] = on and true or nil
end

-- The guild rule for a key or (older callers) a display name: key, record.
function M.PSS_FindGuildRule(guildNameOrKey)
	-- Prefer the exact persisted guild key. This avoids accidentally creating a
	-- new empty guild object when a UI row is opened after a scan.
	local normalizeGuild = M.PSS_NormalizeGuild
	local requestedKey = normalizeGuild(guildNameOrKey)
	local g = requestedKey and PourSocialScoreDB.guildData and PourSocialScoreDB.guildData[requestedKey]
	if not g then
		-- Compatibility: callers may still pass the display name.
		for key, candidate in pairs(PourSocialScoreDB.guildData or {}) do
			if normalizeGuild(candidate.name) == requestedKey then
				requestedKey, g = key, candidate
				break
			end
		end
	end
	return requestedKey, g
end

------------------------------------------------------------------------
-- The Guild Ignore List
------------------------------------------------------------------------
function M.PSS_GuildCount()
	local n = 0
	for _, g in pairs(PourSocialScoreDB.guildData or {}) do
		if type(g) == "table" then n = n + 1 end
	end
	return n
end

local function clearArray(t, from)
	for i = #t, from or 1, -1 do t[i] = nil end
end

-- Every guild rule as an item { key, g, bc }: the top-level ones in
-- into.list, each managed group's in into.groups[group key]. One item per
-- guild rule, kept in into.pool while the rule exists.
local function collectGuilds(into)
	local pool, list, groups = into.pool, into.list, into.groups
	clearArray(list)
	for k, items in pairs(groups) do clearArray(items) end
	for key in pairs(pool) do
		if not PourSocialScoreDB.guildData[key] then pool[key] = nil end
	end
	for key, g in pairs(PourSocialScoreDB.guildData or {}) do
		if type(g) == "table" then
			g.memberCount = M.PSS_GuildMemberCount(g, key)
			local item = pool[key] or {}
			pool[key] = item
			item.key, item.g, item.bc = key, g, M.PSS_GetGuildBlockCounts(key)
			item.inGroup, item.groupOn, item.sv, item.nv = nil, nil, nil, nil
			if g.managed then
				local items = groups[g.managed] or {}
				groups[g.managed] = items
				items[#items + 1] = item
			else
				list[#list + 1] = item
			end
		end
	end
	-- a group left with no guilds is not shown
	for k, items in pairs(groups) do
		if #items == 0 then groups[k] = nil end
	end
end

-- Sorts items in place; ties by guild name A-Z, then key.
local function sortGuildItems(items, sortKey, asc)
	local group, cat = sortKey:match("^(%a+):(%a+)$")
	local guildBlock = M.PSS_GuildBlock
	for _, item in ipairs(items) do
		local g, bc, v = item.g, item.bc, 0
		if group == "metric" then v = bc[cat] or 0
		elseif group == "excl" then v = (guildBlock(g)[cat] == true) and 0 or 1	-- by tick (allowed)
		elseif sortKey == "guild" then v = lower(g.name or item.key or "")
		elseif sortKey == "members" then v = g.memberCount or 0
		elseif sortKey == "scan" then v = M.PSS_GuildSweepSent(item.key)
		elseif sortKey == "fields" then v = lower(g.customScan or "")
		elseif sortKey == "custom" then v = ((g.customScan or "") ~= "") and 1 or 0
		end
		item.sv = v
		item.nv = lower(g.name or item.key or "")
	end
	table.sort(items, function(a, b)
		if a.sv ~= b.sv then
			if asc then return a.sv < b.sv else return a.sv > b.sv end
		end
		-- ties: always guild name A-Z (then key, so the order is stable)
		if a.nv ~= b.nv then return a.nv < b.nv end
		return tostring(a.key) < tostring(b.key)
	end)
end

-- The list in display order, written into into[1..n]:
--   managed groups first, each a header item { header, groupKey, name,
--   guilds, members, bc, open } with its guilds under it when open (guild
--   items get inGroup and groupOn = the group's rule is on); then the Guild
--   Exclusion List { exclHeader, count, open } with { exclItem, name } under
--   it when open; then the other guilds, as items { key, g, bc }.
-- find: text in the guild name (any case); a search lists only the guilds
-- that match, groups and exclusions left out (inGroup / groupOn still set).
-- into.nest = true (set by the caller, 3.2.0-dev005): the groups go under
-- one row { managedHeader, groups, guilds, members, bc, open } (open
-- unless M.PSS_GUILD_MANAGED_SHUT), and each group header gets nested.
-- key: guild, members, scan, fields, custom, "metric:<cat>", "excl:<cat>".
-- into: the caller's table, reused (nil = a new one). Returns into, n.
function M.PSS_GuildRows(sortKey, asc, findText, into)
	if M.PSS_EnsureGuildDB then M.PSS_EnsureGuildDB() end
	into = into or {}
	into.pool, into.list, into.groups = into.pool or {}, into.list or {}, into.groups or {}
	into.heads, into.excl, into.gkeys = into.heads or {}, into.excl or {}, into.gkeys or {}
	sortKey = sortKey or "guild"
	if asc == nil then asc = true end
	if findText == "" then findText = nil end
	if findText then findText = lower(findText) end

	collectGuilds(into)
	local n = 0
	local function put(item) n = n + 1; into[n] = item end

	if findText then
		local list = into.list
		for k, items in pairs(into.groups) do
			local on = M.PSS_ManagedGroupActive(k)
			for _, it in ipairs(items) do it.inGroup = true; it.groupOn = on; list[#list + 1] = it end
		end
		local keep = 0
		for i = 1, #list do
			local it = list[i]
			if find(lower(it.g.name or it.key or ""), findText, 1, true) then
				keep = keep + 1
				list[keep] = it
			end
		end
		clearArray(list, keep + 1)
		sortGuildItems(list, sortKey, asc)
		for _, it in ipairs(list) do put(it) end
		clearArray(into, n + 1)
		return into, n
	end

	local gkeys = into.gkeys
	clearArray(gkeys)
	for k in pairs(into.groups) do gkeys[#gkeys + 1] = k end
	table.sort(gkeys)
	-- the Managed Communities row: the groups added up, over them
	local nest = into.nest and #gkeys > 0
	local nestOpen = true
	if nest then
		nestOpen = not M.PSS_GuildGroupOpen(M.PSS_GUILD_MANAGED_SHUT)
		local mh = into.managedHead
		if mh then
			for c in pairs(mh.bc) do mh.bc[c] = 0 end
		else
			mh = { managedHeader = true, bc = History.EmptyCounts() }
			into.managedHead = mh
		end
		local guilds, members, bc = 0, 0, mh.bc
		for _, k in ipairs(gkeys) do
			for _, it in ipairs(into.groups[k]) do
				guilds = guilds + 1
				members = members + (it.g.memberCount or 0)
				for c, v in pairs(it.bc) do bc[c] = (bc[c] or 0) + (tonumber(v) or 0) end
			end
		end
		mh.groups, mh.guilds, mh.members, mh.open = #gkeys, guilds, members, nestOpen
		put(mh)
	end
	for _, k in ipairs(gkeys) do
		local items = into.groups[k]
		sortGuildItems(items, sortKey, asc)
		local grp = M.PSS_ManagedGroups()[k] or {}
		local h = into.heads[k]
		if h then
			for c in pairs(h.bc) do h.bc[c] = 0 end
		else
			h = { header = true, groupKey = k, bc = History.EmptyCounts() }
			into.heads[k] = h
		end
		local total, bc = 0, h.bc
		for _, it in ipairs(items) do
			total = total + (it.g.memberCount or 0)
			for c, v in pairs(it.bc) do bc[c] = (bc[c] or 0) + (tonumber(v) or 0) end
		end
		local open = M.PSS_GuildGroupOpen(k)
		h.name, h.guilds, h.members, h.open = grp.name or k, #items, total, open
		h.nested = nest or nil
		if nestOpen then put(h) end
		if open and nestOpen then
			local on = M.PSS_ManagedGroupActive(k)
			for _, it in ipairs(items) do it.inGroup = true; it.groupOn = on; put(it) end
		end
	end
	for k in pairs(into.heads) do
		if not into.groups[k] then into.heads[k] = nil end
	end

	-- then the Guild Exclusion List (always shown, so it can be found)
	local excluded = M.PSS_GuildExclusions()
	local exclOpen = M.PSS_GuildGroupOpen(M.PSS_GUILD_EXCL_OPEN)
	local eh = into.exclHead or { exclHeader = true }
	into.exclHead = eh
	eh.count, eh.open = #excluded, exclOpen
	put(eh)
	if exclOpen then
		for i, name in ipairs(excluded) do
			local e = into.excl[i] or { exclItem = true }
			into.excl[i] = e
			e.name = name
			put(e)
		end
	end
	clearArray(into.excl, (exclOpen and #excluded or 0) + 1)

	local list = into.list
	sortGuildItems(list, sortKey, asc)
	for _, it in ipairs(list) do put(it) end
	clearArray(into, n + 1)
	return into, n
end

------------------------------------------------------------------------
-- A guild rule's members
------------------------------------------------------------------------
local function memberSortValue(gg, baseGuild, m, key)
	local mcat = key:match("^metric:(.+)$")
	if mcat then return tonumber(M.PSS_GetMemberBlockCounts(m)[mcat]) or 0 end
	local cat = key:match("^excl:(.+)$")
	if cat then
		return (gg and M.PSS_MemberBlocks(gg, m, cat)) and 0 or 1		-- by tick (allowed)
	elseif key == "name" then return lower(m.name or "")
	elseif key == "guild" then return lower(m.guild or "")
	elseif key == "note" then return lower(m.note or "")
	elseif key == "added" then return History.ParseTime(m.whenBlocked) or 0
	elseif key == "addGuild" then
		-- members whose actual guild differs from this rule (Add Guild shown)
		local ag = M.PSS_NormalizeGuild(m.guild or "")
		return (ag and ag ~= "" and ag ~= baseGuild) and 1 or 0
	end
	return 0
end

-- The members stored under guild rule gkey (plus, for a managed guild,
-- its shipped members) matching find (name, guild or note, any case),
-- sorted by key (name, guild, note, added, addGuild, "metric:<cat>",
-- "excl:<cat>"); ties by name. into[1..n] = the member records;
-- into.stored[member] = its key in the rule's members (false for a shipped
-- member with no record of its own). into: the caller's table, reused (nil
-- = a new one). Returns into, n, and the number of members before the
-- search (nil n when there is no such rule).
function M.PSS_GuildMembers(gkey, sortKey, asc, findText, into)
	into = into or {}
	local stored = into.stored or {}
	local sv, nv = into.sv or {}, into.nv or {}
	into.stored, into.sv, into.nv = stored, sv, nv
	for k in pairs(stored) do stored[k] = nil end
	for k in pairs(sv) do sv[k] = nil end
	for k in pairs(nv) do nv[k] = nil end
	clearArray(into)
	local gg = gkey and PourSocialScoreDB.guildData[gkey]
	if not gg then return into, nil, 0 end
	if type(gg.members) ~= "table" then return into, 0, 0 end
	sortKey = sortKey or "name"
	if asc == nil then asc = true end
	if findText then findText = lower(findText) end
	local all = findText == nil or findText == ""

	local n, total = 0, 0
	M.PSS_ForEachGuildMember(gg, gkey, function(m, key)
		total = total + 1
		if not all then
			local hay = lower((m.name or "") .. " " .. (m.guild or "") .. " " .. (m.note or ""))
			if not find(hay, findText, 1, true) then return end
		end
		n = n + 1
		into[n] = m
		stored[m] = key or false
	end, true)

	local baseGuild = M.PSS_NormalizeGuild(gg.name or gkey)
	for i = 1, n do
		local m = into[i]
		sv[m] = memberSortValue(gg, baseGuild, m, sortKey)
		nv[m] = lower(m.name or "")
	end
	table.sort(into, function(a, b)
		if sv[a] ~= sv[b] then
			if asc then return sv[a] < sv[b] else return sv[a] > sv[b] end
		end
		return nv[a] < nv[b]		-- tie-break by name
	end)
	return into, n, total
end

-- Add Guild on a member row: a rule for the member's actual guild, with
-- every stored member of that guild moved to it (and a chat line saying
-- what moved). Returns true when a rule was added.
function M.PSS_AddMembersGuild(gkey, actual)
	local srcG = gkey and PourSocialScoreDB.guildData[gkey]
	local base = M.PSS_NormalizeGuild(srcG and srcG.name or gkey)
	if not (actual and actual ~= "" and M.PSS_NormalizeGuild(actual) ~= base and M.PSS_AddCapturedGuild) then return false end
	local added, migrated, removedRefs, perSource, leftover = M.PSS_AddCapturedGuild(actual, srcG and srcG.managed)
	local from = {}
	for _, s in ipairs(perSource or {}) do
		from[#from + 1] = ("%s (%d)"):format(s.name, s.moved)
	end
	M.ChatMsg(("PSS: Added guild %q. Added %d new member(s) (%d total matched). Removed %d old record(s)%s. Blocked history moved with them."):format(
		actual, added or 0, migrated or 0, removedRefs or 0,
		#from > 0 and (" from: " .. table.concat(from, ", ")) or ""))
	if (leftover or 0) > 0 then
		M.ChatMsg(("PSS: WARNING - %d old record(s) for %q could not be removed."):format(leftover, actual))
	end
	return true
end

function M.PSS_ForgetGuildSearch()
	M.PSS_GuildSearchCache = nil
end
