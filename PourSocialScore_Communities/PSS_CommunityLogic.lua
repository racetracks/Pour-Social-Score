-- POUR SOCIAL SCORE - MANAGED COMMUNITIES: LOGIC (DEC-00443). Loaded on demand, after the member lists.
local addon = PourSocialScore_NS
local M = addon.M
local G = M.PSS_GuildCore
local P = {}
-- canon -> record for shipped members looked at this session. Weak: a record
-- nobody uses any more is freed by the garbage collector. Records you
-- changed are also held in vkeep until they are saved at logout.
local vcache = setmetatable({}, { __mode = "v" })
local vkeep = {}

-- The member lists and the index of the guild-level table G.guildLevel()
-- (rebuilt when core drops that table, as the data file loads). The index
-- (canon key -> guild number * 65536 + position) ships prebuilt in the data
-- file (tools/PSS_BuildManaged.lua). It is packed (3.0.0-dev17):
-- buckets[realm key][first two bytes of the name key] is one string
-- "\n<name key>=<number>..." searched with a plain find, and each guild's
-- members are one string ("Name-<realm number>\n..."), split only while a
-- list is looked at.
local pm, pmFor
local function state()
	local m = G.guildLevel()
	if pmFor ~= m then
		pmFor = m
		local data = m.data
		pm = { lists = {}, names = {}, dataLoaded = data ~= nil }
		for _, grp in ipairs((addon.MANAGED or {}).groups or {}) do
			local gdata = data and data[grp.key]
			local gkeys = m.gkeys[grp.key]
			for gi, entry in ipairs(grp.guilds or {}) do
				local gkey = gkeys[gi]
				if gkey then
					local list = gdata and gdata.guilds and gdata.guilds[gi]
					if list and list.name == entry.name then pm.names[gkey] = { packed = list.members, realms = gdata.realms } end
				end
			end
			if gdata then pm.lists[#pm.lists + 1] = { buckets = gdata.buckets or {}, gkeys = gkeys } end
		end
	end
	return pm
end
function P.Build() return state().dataLoaded end
function P.Loaded() return state().dataLoaded end

-- canon key -> shipped guild key, position in its list (nil if not shipped).
-- A character listed by two groups belongs to the first.
local find, byte, sub = string.find, string.byte, string.sub

-- the number after "\n<base>=" in a bucket string, or nil
local function bucketValue(bucket, base)
	local init, len = 1, #base
	while true do
		local s, e = find(bucket, base, init, true)
		if not s then return nil end
		if byte(bucket, s - 1) == 10 and byte(bucket, e + 1) == 61 then
			local v, i = 0, e + 2
			local c = byte(bucket, i)
			while c and c >= 48 and c <= 57 do
				v = v * 10 + c - 48
				i = i + 1
				c = byte(bucket, i)
			end
			return v
		end
		init = s + len
	end
end

function P.ShippedOf(ck)
	if not ck then return nil end
	local lists = state().lists
	if #lists == 0 then return nil end
	local dash = find(ck, "-", 1, true)
	if not dash or dash < 2 then return nil end
	local realm, base = sub(ck, dash + 1), sub(ck, 1, dash - 1)
	local first = sub(base, 1, 2)
	for i = 1, #lists do
		local rb = lists[i].buckets[realm]
		local bucket = rb and rb[first]
		local v = bucket and bucketValue(bucket, base)
		if v then
			local gi = math.floor(v / 65536)
			local gkey = lists[i].gkeys[gi]
			if gkey then return gkey, v - gi * 65536 end
		end
	end
	return nil
end

-- A shipped guild's members as a list of names (split from its packed
-- string while someone holds it; weak, so the garbage collector frees it).
local splitCache = setmetatable({}, { __mode = "v" })
function P.ShippedNames(gkey)
	local entry = state().names[gkey]
	if not entry then return nil end
	local list = splitCache[gkey]
	if list then return list end
	list = {}
	local realms = entry.realms or {}
	for n in (entry.packed or ""):gmatch("[^\n]+") do
		local b, r = n:match("^(.+)%-(%d+)$")
		list[#list + 1] = b and realms[tonumber(r)] and (b .. "-" .. realms[tonumber(r)]) or n
	end
	splitCache[gkey] = list
	return list
end

function P.Stats()
	local m = G.guildLevel()
	local st = state()
	local shipped, indexed = 0, 0
	for _, n in pairs(m.count) do shipped = shipped + n end
	for _, l in ipairs(st.lists) do
		for _, rb in pairs(l.buckets) do
			for _, bucket in pairs(rb) do
				for _ in bucket:gmatch("\n") do indexed = indexed + 1 end
			end
		end
	end
	local kept, cached = 0, 0
	for _ in pairs(vkeep) do kept = kept + 1 end
	for _ in pairs(vcache) do cached = cached + 1 end
	return { shipped = shipped, indexed = indexed, kept = kept, cached = cached, loaded = st.dataLoaded }
end

-- The record for a shipped member (one per character while in use).
function P.Record(ck, gkey)
	local r = vkeep[ck] or vcache[ck]
	if r and G.shippedRule(r) == gkey then return r end
	local m = G.guildLevel()
	local gk, pos = P.ShippedOf(ck)
	local names = gk == gkey and P.ShippedNames(gkey)
	local name = names and names[pos]
	if not name then return nil end
	-- flags, counts and block choices are created when first set
	r = G.newShippedRecord(name, m.guildName[gkey] or gkey, ck, gkey)
	vcache[ck] = r
	return r
end

-- The record kept or cached for a character (nil if none).
function P.Held(ck) return vkeep[ck] or vcache[ck] end

-- A shipped member's record was changed: hold it until it is saved.
function P.Keep(r)
	if G.shippedOnly(r) and G.shippedCanon(r) then vkeep[G.shippedCanon(r)] = r end
end

-- A shipped member is no longer in that guild (seen elsewhere, or removed).
function P.Tombstone(gkey, ck)
	local g = PourSocialScoreDB.guildData[gkey]
	if not g then return end
	g.managedGone = type(g.managedGone) == "table" and g.managedGone or {}
	g.managedGone[ck] = true
	if vcache[ck] and G.shippedRule(vcache[ck]) == gkey then vcache[ck] = nil end
	if vkeep[ck] and G.shippedRule(vkeep[ck]) == gkey then vkeep[ck] = nil end
	local key
	for k, mm in pairs(g.members or {}) do
		if type(mm) == "table" and (G.memberCanon(mm, k)) == ck then key = k break end
	end
	if key then g.members[key] = nil end
end

-- every shipped member of a guild not in seen: fn(record, nil, true)
function P.EachShipped(g, gkey, fn, seen, includeUntouched)
	if includeUntouched then
		for _, name in ipairs(P.ShippedNames(gkey) or {}) do
			local ck = G.canonPlayer(name)
			if ck and P.ShippedOf(ck) == gkey and not seen[ck] and not G.isGone(g, ck) then
				seen[ck] = true
				local r = P.Record(ck, gkey)
				if r then fn(r, nil, true) end
			end
		end
	else
		local done = {}
		for _, t in ipairs({ vkeep, vcache }) do
			for ck, r in pairs(t) do
				if G.shippedRule(r) == gkey and not seen[ck] and not done[ck] and not G.isGone(g, ck) then
					done[ck] = true
					fn(r, nil, true)
				end
			end
		end
	end
end

-- "Left this guild" marks the shipped list no longer needs (3.0): a mark
-- only matters while the shipped list still has that character in that
-- guild. Runs once per session (force resets that), when the lists are
-- loaded; empty mark tables are not saved.
local marksPruned = false
function P.PruneMarks(force)
	if force then marksPruned = false end
	if marksPruned or not P.Loaded() then return 0 end
	local gd = PourSocialScoreDB and PourSocialScoreDB.guildData
	if type(gd) ~= "table" then return 0 end
	marksPruned = true
	local n = 0
	for gkey, g in pairs(gd) do
		if type(g) == "table" and type(g.managedGone) == "table" then
			for ck in pairs(g.managedGone) do
				if P.ShippedOf(ck) ~= gkey then
					g.managedGone[ck] = nil
					n = n + 1
				end
			end
			if next(g.managedGone) == nil then g.managedGone = nil end
		end
	end
	if n > 0 then G.bumpMemberCount() end
	return n
end

-- member count of a managed guild whose lists are loaded
function P.Count(g, gkey)
	local m = G.guildLevel()
	local n = state().names[gkey] and (m.count[gkey] or 0) or 0
	for k, mm in pairs(g.members or {}) do
		local ck = G.memberCanon(mm, k)
		if not (ck and P.ShippedOf(ck) == gkey) then n = n + 1 end
	end
	for ck in pairs(g.managedGone or {}) do
		if P.ShippedOf(ck) == gkey then n = n - 1 end
	end
	return math.max(0, n)
end

-- Logout: changed shipped members are written into the guild record;
-- unchanged shipped members are dropped from it.
function P.Flush()
	for _, t in ipairs({ vkeep, vcache }) do
		for ck, r in pairs(t) do
			local g = PourSocialScoreDB.guildData[G.shippedRule(r)]
			if g and not G.isGone(g, ck) and G.managedDirty(r) then
				g.members = g.members or {}
				local key = G.memberPlayerKey(r)
				if key and not g.members[key] then
					-- saved sparse: the runtime fields and what the key and the rule
					-- give back are rebuilt when the lists load (S3)
					g.members[key] = r
					G.sparseMember(r, key, g)
				end
			end
		end
	end
	for gkey, g in pairs(PourSocialScoreDB.guildData) do
		if type(g) == "table" and g.managed and type(g.members) == "table" then
			local drop = {}
			for k, mm in pairs(g.members) do
				local ck = G.memberCanon(mm, k)
				if ck and P.ShippedOf(ck) == gkey and not G.managedDirty(mm) then drop[#drop + 1] = k end
			end
			for _, k in ipairs(drop) do g.members[k] = nil end
		end
	end
end
M.PSS_Community = P
