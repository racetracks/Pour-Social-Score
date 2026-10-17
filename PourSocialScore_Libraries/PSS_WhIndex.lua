------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE WAREHOUSE SUMMARY INDEX (warehouse-helper,
-- one-build plan STP-p10, W4a; Syndicator parity 15, connected realms).
-- Who holds an item, how many, where: one table read, never a scan.
--   index wh.holders     item ref -> "ent.code.count,ent.code.count"   built on the first
--                        lookup from the saved containers, patched per entity from the
--                        change set (M.PSS_IndexDirty), released on a GC request
--   index wh.curHolders  currency id -> "ent.quantity,ent.quantity"
-- Services (record sets):
--   wh.ent   kind?, realm?, faction?, shown? -> ent, kind, name, realm, faction, class, race, sex, hidden
--   wh.sum   item -> item, ent, bags, bank, reagent, mail, equipped, void, auctions, guild, warband, total
--   wh.find  key | item -> item, ent, cont, count          opts { realms = {set}, faction, hidden }
--   wh.cur   currency | ent -> ent, currency, quantity
-- A hidden entity is left out unless opts.hidden. opts.realms is a set of realm names (the
-- player's connected realms: M.PSS_ConnectedRealms()); opts.faction keeps one faction.
-- The file returns at the top while the Warehouse is off. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local concat, sort = table.concat, table.sort
local find, sub, match, gmatch = string.find, string.sub, string.match, string.gmatch

local ms = M.PSS_WhStore
local C = M.PSS_Codec

local KINDCOL = { b = "bags", y = "bags", k = "bank", r = "reagent", w = "warband", e = "equipped", m = "mail", v = "void", a = "auctions", t = "guild" }
local KINDAT = { b = 3, y = 3, k = 4, r = 5, m = 6, e = 7, v = 8, a = 9, t = 10, w = 11 }		-- the wh.sum column of a container family
local SUMCOLS = { "item", "ent", "bags", "bank", "reagent", "mail", "equipped", "void", "auctions", "guild", "warband", "total" }

local function db() return rawget(_G, "PSS_WarehouseDB") end

------------------------------------------------------------------------
-- wh.holders
------------------------------------------------------------------------
local contrib = {}		-- ["ent.code"] = { [ref] = true }: what one container adds to the index (for a partial rebuild)

-- adds the refs of one container into `acc[ref] = { ["ent.code"] = count }`
local function addContainer(ent, code, acc)
	local str = ms.Get(ent, code)
	if not str then return end
	local tag = ent .. "." .. code
	local mine = {}
	contrib[tag] = mine
	local body = str:match("^%d+;%d+;%d+;%d+;(.*)$") or ""
	for ref, count in gmatch(body, "%d+%.([^.,]+)%.?(%d*)") do
		local a = acc[ref]
		if not a then a = {}; acc[ref] = a end
		a[tag] = (a[tag] or 0) + (count ~= "" and tonumber(count) or 1)
		mine[ref] = true
	end
end

local function packAcc(a)
	local list = {}
	for tag, n in pairs(a) do list[#list + 1] = tag .. "." .. n end
	sort(list)
	return concat(list, ",")
end

local holders = M.PSS_Index("wh.holders", {
	sourceVer = function() return ms.Ver() end,
	build = function(add)
		contrib = {}
		local acc = {}
		for _, ent in ipairs(ms.Ents()) do
			for _, code in ipairs(ms.Codes(ent)) do addContainer(ent, code, acc) end
		end
		for ref, a in pairs(acc) do add(ref, packAcc(a)) end
	end,
	partial = function(add, drop, ids, data)
		-- ids: the "ent.code" tags that were written. Take their share out of every ref they were in, then add what they hold now
		local touched, acc = {}, {}
		for tag in pairs(ids) do
			for ref in pairs(contrib[tag] or {}) do touched[ref] = true end
			contrib[tag] = nil
			local ent, code = match(tag, "^(%d+)%.(.+)$")
			if ent then addContainer(tonumber(ent), code, acc) end
		end
		for ref in pairs(acc) do touched[ref] = true end
		for ref in pairs(touched) do
			local keep = {}
			local old = data[ref]
			if old then
				for e, code, n in gmatch(old, "(%d+)%.([^.,]+)%.(%d+)") do
					local tag = e .. "." .. code
					if not ids[tag] then keep[tag] = tonumber(n) end
				end
			end
			for tag, n in pairs(acc[ref] or {}) do keep[tag] = n end
			if next(keep) then add(ref, packAcc(keep)) else drop(ref) end
		end
	end,
})

M.PSS_WhHolders = holders

------------------------------------------------------------------------
-- Entity facts: hidden, kind, realm, faction
------------------------------------------------------------------------
local factsCache, factsVer = {}, -1
local function facts(ent)
	local v = M.PSS_EntityVer()
	if v ~= factsVer then factsCache, factsVer = {}, v end
	local f = factsCache[ent]
	if f ~= nil then return f or nil end
	local set = M.PSS_Entity(ent)
	if not set or set.n == 0 then factsCache[ent] = false return nil end
	local r = set[1]
	f = { kind = r[2], name = r[3], realm = r[4], faction = r[5], class = r[6], race = r[7], sex = r[8], hidden = (M.PSS_EntityFlags(ent) or ""):find("h", 1, true) ~= nil }
	factsCache[ent] = f
	return f
end

local function allowed(ent, opts, cache)
	local f = cache[ent]
	if f == nil then f = facts(ent) or false; cache[ent] = f end
	if not f then return false end
	if f.hidden and not (opts and opts.hidden) then return false end
	if opts and opts.faction and f.kind == "c" and f.faction ~= opts.faction then return false end
	if opts and opts.realms and f.kind == "c" and not opts.realms[f.realm] then return false end
	return true
end

------------------------------------------------------------------------
-- Services
------------------------------------------------------------------------
M.PSS_Provide("wh.ent", function(input, opts)
	local out = { cols = { "ent", "kind", "name", "realm", "faction", "class", "race", "sex", "hidden" }, n = 0 }
	local want = input and input.cols and input.cols[1] == "ent"		-- no input lists everyone; an empty set lists no one
	local ids = {}
	if want then
		for i = 1, input.n do ids[#ids + 1] = input[i][1] end
	else
		for _, kind in ipairs({ "c", "g", "w" }) do for _, id in ipairs(M.PSS_EntityList(kind)) do ids[#ids + 1] = id end end
	end
	sort(ids)
	for _, id in ipairs(ids) do
		local f = facts(id)
		if f and (not opts or not opts.kind or opts.kind == f.kind) and (not opts or not opts.realm or opts.realm == f.realm)
			and (not opts or not opts.faction or opts.faction == f.faction) and (not opts or opts.shown ~= true or not f.hidden)
			and (not opts or not opts.realms or f.kind ~= "c" or opts.realms[f.realm]) then
			out.n = out.n + 1
			out[out.n] = { id, f.kind, f.name, f.realm, f.faction, f.class, f.race, f.sex, f.hidden }
		end
	end
	return out
end, { accepts = { "ent" }, returns = { "ent", "kind", "name", "realm", "faction", "class", "race", "sex", "hidden" }, doc = "the entities, filtered", cost = "O(entities)",
	writes = false, onError = "last", ver = function() return ms.Ver() end })

-- the refs an input row names: an item key, or a ref already
local function refOf(v)
	if type(v) == "number" then v = tostring(v) end
	if type(v) ~= "string" then return nil end
	return M.PSS_ItemRef(v) or (match(v, "^x?%d+$") and v) or nil
end

local function itemCol(input)
	local c = M.PSS_SetCol(input, "item") or M.PSS_SetCol(input, "key") or 1
	return c
end

M.PSS_Provide("wh.sum", function(input, opts)
	local out = { cols = SUMCOLS, n = 0 }
	local c = itemCol(input)
	local cache = {}
	for i = 1, input.n do
		local item = input[i][c]
		local ref = refOf(item)
		local packed = ref and holders:get(ref)
		if packed then
			local byEnt, order = {}, {}
			for e, code, n in gmatch(packed, "(%d+)%.([^.,]+)%.(%d+)") do
				do
					e = tonumber(e)
					if allowed(e, opts, cache) then
						local row = byEnt[e]
						if not row then
							row = { item, e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
							byEnt[e] = row
							order[#order + 1] = e
						end
						local k = KINDAT[sub(code, 1, 1)]
						n = tonumber(n)
						if k then row[k] = row[k] + n end
						row[12] = row[12] + n
					end
				end
			end
			sort(order)
			for _, e in ipairs(order) do out.n = out.n + 1; out[out.n] = byEnt[e] end
		end
	end
	return out
end, { accepts = { "item" }, returns = SUMCOLS, doc = "how many of an item each entity holds, by place", cost = "O(holders)", writes = false, onError = "last",
	ver = function() return ms.Ver() end })

M.PSS_Provide("wh.find", function(input, opts)
	local out = { cols = { "item", "ent", "cont", "count" }, n = 0 }
	local c = itemCol(input)
	local cache = {}
	for i = 1, input.n do
		local item = input[i][c]
		local ref = refOf(item)
		local packed = ref and holders:get(ref)
		if packed then
			for entry in (packed .. ","):gmatch("([^,]*),") do
				local e, code, n = match(entry, "^(%d+)%.([^.]+)%.(%d+)$")
				if e and allowed(tonumber(e), opts, cache) then
					out.n = out.n + 1
					out[out.n] = { item, tonumber(e), code, tonumber(n) }
				end
			end
		end
	end
	return out
end, { accepts = { "item" }, returns = { "item", "ent", "cont", "count" }, doc = "where an item is, container by container", cost = "O(holders)", writes = false,
	onError = "last", ver = function() return ms.Ver() end })

------------------------------------------------------------------------
-- Currencies
------------------------------------------------------------------------
local curHolders = M.PSS_Index("wh.curHolders", {
	sourceVer = function() return M.PSS_WhCurVer and M.PSS_WhCurVer() or 0 end,
	build = function(add)
		local d = db()
		local by = {}
		for ent, str in pairs(d and d.cur or {}) do
			for id, q in pairs(M.PSS_WhCurUnpack(str)) do
				by[id] = by[id] or {}
				by[id][#by[id] + 1] = ent .. "." .. q
			end
		end
		for id, list in pairs(by) do sort(list); add(id, concat(list, ",")) end
	end,
})

M.PSS_Provide("wh.cur", function(input, opts)
	local out = { cols = { "ent", "currency", "quantity" }, n = 0 }
	local cache = {}
	local ids = {}
	local ci = M.PSS_SetCol(input, "currency")
	if ci then
		for i = 1, input.n do ids[#ids + 1] = tonumber(input[i][ci]) end
	elseif input.cols[1] == "key" then
		for i = 1, input.n do ids[#ids + 1] = tonumber(input[i][1]) end
	end
	local entCol = M.PSS_SetCol(input, "ent")
	if entCol and not ci then
		local d = db()
		for i = 1, input.n do
			local ent = input[i][entCol]
			if d and d.cur and d.cur[ent] and allowed(ent, opts, cache) then
				local map = M.PSS_WhCurUnpack(d.cur[ent])
				local list = {}
				for id in pairs(map) do list[#list + 1] = id end
				sort(list)
				for _, id in ipairs(list) do out.n = out.n + 1; out[out.n] = { ent, id, map[id] } end
			end
		end
		return out
	end
	for _, id in ipairs(ids) do
		local packed = curHolders:get(id)
		if packed then
			for entry in (packed .. ","):gmatch("([^,]*),") do
				local e, q = match(entry, "^(%d+)%.(%d+)$")
				if e and allowed(tonumber(e), opts, cache) then
					out.n = out.n + 1
					out[out.n] = { tonumber(e), id, tonumber(q) }
				end
			end
		end
	end
	return out
end, { accepts = { "currency" }, returns = { "ent", "currency", "quantity" }, doc = "who holds a currency, or what an entity holds", cost = "O(holders)", writes = false,
	onError = "last", ver = function() return ms.Ver() end })

-- the realms the player's character is connected to (Retail), as a set; nil where the client has no such thing
function M.PSS_ConnectedRealms()
	local list = GetAutoCompleteRealms and GetAutoCompleteRealms()
	if type(list) ~= "table" or #list == 0 then return nil end
	local set = {}
	for _, r in ipairs(list) do set[r] = true end
	set[GetRealmName()] = true
	return set
end
