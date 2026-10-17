------------------------------------------------------------------------
-- POUR SOCIAL SCORE - ITEM KEYS AND THE ITEM DICTIONARY (warehouse-helper,
-- one-build plan STP-p08, DEC-00265, A02, A03). One grammar names an item
-- everywhere it is saved: a slot, a journal line, a bag category rule, a bag
-- profile.
--   M.PSS_ItemKey(link)     the key of an item, battle pet or keystone link, or nil
--                           "12345"             a plain item: its id (no enchant, gem,
--                                               suffix or bonus id)
--                           "12345:e:g:g:g:g:s:b:b"  a variant: id, enchant, four gems, suffix,
--                                               then the bonus ids (level, spec, unique id,
--                                               context and crafter left out)
--                           "p:species:level:quality"  a battle pet
--                           "k:map:level"       a keystone
--   M.PSS_ItemId(key)       the item id a key stands for (a keystone and a pet: their item)
--   M.PSS_ItemRef(key, create)   "12345" for a plain item, "x17" for a variant (the
--                           dictionary id, PSS_WarehouseDB.item[17] = key)
--   M.PSS_ItemUnref(ref)    the key of a ref, or nil
--   M.PSS_ItemRefs(name, { used = function(add), remap = function(map) -> commit })
--                           a saved structure that holds refs registers here, so a sweep
--                           frees an unused id and a compaction rewrites every holder
--   M.PSS_ItemSweep(force)  frees the ids nothing refers to, compacts past 25% free:
--                           freed, remapped, dropped  (verified before anything is swapped)
--   M.PSS_ItemOrphans()     top-level keys of the saved table that hold refs but are not
--                           registered (the harness fails on one)
-- A parsed link is remembered for the session (the cache is bounded). A
-- secret link is refused. The dictionary lives in PSS_WarehouseDB (plain
-- items are never in it), ids are never reused until a compaction, and a
-- newer layout is kept untouched. The file returns at the top while the
-- Warehouse and the Bag manager are both off.
-- Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not (M.PSS_On("warehouse") or M.PSS_On("bags")) then return end

local type, tonumber, tostring, pairs, ipairs = type, tonumber, tostring, pairs, ipairs
local find, match, sub, gsub = string.find, string.match, string.sub, string.gsub
local concat = table.concat

local cache, cached = {}, 0		-- link -> key
local CACHE_MAX = 4000
local parses = 0

local function none(v) return v == nil or v == "" or v == "0" end

-- the pieces of an "item:" string after the id, split on ":" (empty fields kept)
local function fields(rest)
	local f, n, from = {}, 0, 1
	while true do
		local at = find(rest, ":", from, true)
		n = n + 1
		if at then f[n] = sub(rest, from, at - 1); from = at + 1 else f[n] = sub(rest, from); break end
	end
	return f, n
end

local function parse(link)
	local id, rest = match(link, "item:(%d+):?([^|]*)")
	if id then
		local f = fields(rest)
		local nb = tonumber(f[12]) or 0
		if none(f[1]) and none(f[2]) and none(f[3]) and none(f[4]) and none(f[5]) and none(f[6]) and nb == 0 then return id end
		local parts = { id, f[1] ~= "" and f[1] or "0", f[2] ~= "" and f[2] or "0", f[3] ~= "" and f[3] or "0", f[4] ~= "" and f[4] or "0", f[5] ~= "" and f[5] or "0", f[6] ~= "" and f[6] or "0" }
		for i = 1, nb do parts[#parts + 1] = f[12 + i] or "0" end
		return concat(parts, ":")
	end
	local species, level, quality = match(link, "battlepet:(%d+):(%d+):(%d+)")
	if species then return "p:" .. species .. ":" .. level .. ":" .. quality end
	local _, map, lvl = match(link, "keystone:(%d+):(%d+):(%d+)")
	if map then return "k:" .. map .. ":" .. lvl end
	local plain = match(link, "^%d+$")
	return plain
end

function M.PSS_ItemKey(link)
	if type(link) == "number" then link = tostring(link) end
	if type(link) ~= "string" then return nil end
	if M.PSS_IsSecret and M.PSS_IsSecret(link) then
		if M.PSS_ErrNote then M.PSS_ErrNote("secret", "item.key", "secret link") end
		return nil
	end
	local k = cache[link]
	if k then return k end
	parses = parses + 1
	k = parse(link)
	if k then
		if cached >= CACHE_MAX then cache, cached = {}, 0 end
		cache[link] = k
		cached = cached + 1
	end
	return k
end

function M.PSS_ItemParses() return parses end

-- the item id a key stands for: a keystone and a pet cage have their own items
function M.PSS_ItemId(key)
	if type(key) ~= "string" then return nil end
	local id = match(key, "^(%d+)")
	if id then return tonumber(id) end
	if key:sub(1, 2) == "p:" then return 82800 end
	if key:sub(1, 2) == "k:" then return 180653 end
end

------------------------------------------------------------------------
-- The dictionary
------------------------------------------------------------------------
local dictVer = 0
local byKey = M.PSS_Index("item.byKey", {
	sourceVer = function() return dictVer end,
	build = function(add)
		local db = rawget(_G, "PSS_WarehouseDB")
		local item = db and db.item
		if type(item) == "table" then
			for id, key in pairs(item) do if key ~= "" then add(key, id) end end
		end
	end,
})

local function db(create)
	local d = rawget(_G, "PSS_WarehouseDB")
	if type(d) ~= "table" then
		if not create then return nil end
		d = { v = 1 }
		_G.PSS_WarehouseDB = d
	end
	return d
end

local function newer(d) return d ~= nil and type(d.v) == "number" and d.v > 1 end

function M.PSS_ItemRef(key, create)
	if type(key) ~= "string" then return nil end
	if match(key, "^%d+$") then return key end		-- plain: the id itself, never in the dictionary
	local id = byKey:get(key)
	if id then return "x" .. id end
	if not create then return nil end
	local d = db()
	if newer(d) then return nil, "newer: warehouse layout " .. tostring(d.v) .. " kept" end
	d = db(true)
	d.item = d.item or {}
	local n = (d.itemN or 0) + 1
	d.itemN = n
	d.item[n] = key
	dictVer = dictVer + 1
	byKey:put(key, n)
	return "x" .. n
end

function M.PSS_ItemUnref(ref)
	if type(ref) ~= "string" then return nil end
	if match(ref, "^%d+$") then return ref end
	local n = match(ref, "^x(%d+)$")
	if not n then return nil end
	local d = db()
	local key = d and d.item and d.item[tonumber(n)]
	if key == nil or key == "" then return nil end
	return key
end

------------------------------------------------------------------------
-- Referrers, sweep, compaction (A03)
------------------------------------------------------------------------
local referrers = {}
function M.PSS_ItemRefs(name, spec)
	referrers[name] = spec
end

local KNOWN = { v = true, item = true, itemN = true, itemFree = true, meta = true, cur = true, gold = true, seen = true, jrn = true }

-- keys of the saved table that carry refs but nobody registered
function M.PSS_ItemOrphans()
	local d = db()
	local out = {}
	if not d then return out end
	local function holds(v)
		if type(v) == "string" then return find(v, "%f[%w]x%d+") ~= nil end
		if type(v) == "table" then for _, x in pairs(v) do if holds(x) then return true end end end
		return false
	end
	for k, v in pairs(d) do
		if not KNOWN[k] and not referrers[k] and holds(v) then out[#out + 1] = tostring(k) end
	end
	table.sort(out)
	return out
end

function M.PSS_ItemFree()
	local d = db()
	return d and d.itemFree or 0, d and d.itemN or 0
end

-- frees the ids no registered holder uses; compacts when more than a quarter of the ids are free.
-- Returns freed, remapped (0 or the count), dropped. Nothing is assigned until every holder agreed.
function M.PSS_ItemSweep(force)
	local d = db()
	if not d or newer(d) or type(d.item) ~= "table" then return 0, 0, 0 end
	local used = {}
	for _, r in pairs(referrers) do
		if r.used then r.used(function(ref)
			local n = type(ref) == "string" and match(ref, "^x(%d+)$")
			if n then used[tonumber(n)] = true end
		end) end
	end
	local freed, N = 0, d.itemN or 0
	for id, key in pairs(d.item) do
		if key ~= "" and not used[id] then
			d.item[id] = ""
			d.itemFree = (d.itemFree or 0) + 1
			freed = freed + 1
		end
	end
	if freed > 0 then dictVer = dictVer + 1; byKey:drop() end
	local free = d.itemFree or 0
	local remapped = 0
	if (free > 0 and N > 0 and free / N > 0.25) or (force and free > 0) then
		local map, newItem, n = {}, {}, 0
		local ids = {}
		for id, key in pairs(d.item) do if key ~= "" then ids[#ids + 1] = id end end
		table.sort(ids)
		for _, id in ipairs(ids) do n = n + 1; map[id] = n; newItem[n] = d.item[id] end
		-- every holder plans its rewrite first; one that cannot stops the compaction
		local commits, ok = {}, true
		local T = M.PSS_Test
		for name, r in pairs(referrers) do
			if r.remap then
				local commit = (not (T and T.compactFail)) and r.remap(map) or false
				if not commit then ok = false break end
				commits[#commits + 1] = commit
			end
		end
		if ok then
			for i = 1, #commits do commits[i]() end
			d.item, d.itemN, d.itemFree = newItem, n, nil
			dictVer = dictVer + 1
			byKey:drop()
			remapped = n
		else
			M.PSS_ErrNote("integrity", "item.sweep", "compaction stopped: a holder could not be rewritten")
		end
	end
	return freed, remapped, 0
end

function M.PSS_ItemDictDrop()
	cache, cached = {}, 0
	byKey:drop()
end
