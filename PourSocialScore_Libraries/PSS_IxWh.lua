------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE INVENTORY INDEXES (search-helper, STP-00244,
-- DEC-00322). The warehouse's stores as Spyglass indexes, read through
-- their own services (never the saved tables):
--   inv     one row per stack: ent cont kind tab slot item count bound loot expires flags seen hidden
--           one source type per container family (inv.<kind>, from M.PSS_WH_CONTAINERS: a new
--           container row is a new source type, no engine change); this character's containers
--           from item.live, every other holder's from wh.cont; pushdown on ent, kind / st and item
--           (item through the warehouse's summary index, wh.find)
--   invsum  item ent cont count (wh.find, the fast path for "who holds X")
--   cur     ent currency qty (wh.cur)      gold   ent copper seen (money.gold)
--   val     item vendor auction source (money.value)
--   ent     id kind name realm faction class race sex hidden (the entity dictionary; always on)
--   item    ref id name quality ilvl class link pending (held items and the client's item cache)
-- While the Warehouse is off they answer an empty set noted off and open no
-- store. Hidden and orphaned holders stay out unless the query says hidden=1
-- (W3-D5). Loaded with Libraries. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local find, match, sub = string.find, string.match, string.sub
local sort = table.sort

local L = M.PSS_Line
M.PSS_IxWhStats = { conts = 0, finds = 0 }

local function itemId(v)
	if type(v) == "number" then return v end
	return tonumber(match(tostring(v or ""), "^x?(%d+)"))
end

local function call(name, input, opts)
	if not M.PSS_ServiceInfo(name) then return nil end
	return M.PSS_Call(name, input, opts)
end

-- hidden: flagged h, or saved data whose entity has no row (an orphan, W3-D5)
local function hiddenOf(ent)
	if (M.PSS_EntityFlags(ent) or ""):find("h", 1, true) then return true end
	local r = M.PSS_Entity(ent)
	return not (r and r.n and r.n > 0)
end

local INVFIELDS = { { "st", "k", "inv.<container kind>" }, { "ent", "e", "the holder" }, { "cont", "k", "the container code" },
	{ "kind", "k", "the container family" }, { "tab", "n", "the tab or bag" }, { "slot", "n", "the slot" }, { "item", "i", "the item key" },
	{ "count", "n", "the stack size" }, { "bound", "b", "soulbound" }, { "loot", "b", "has loot" }, { "expires", "t", "mail and auctions" },
	{ "flags", "s", "the raw flags" }, { "seen", "t", "when the container was last read" }, { "hidden", "b", "a hidden or orphaned holder" } }

-- the source types of this client's container rows
local KINDOF = {}
for _, row in ipairs(M.PSS_WH_CONTAINERS or {}) do
	if row.has() then
		KINDOF[row.code] = row.kind
		L.type("inv." .. row.kind, { index = "inv", fields = { { "cont", "k" }, { "slot", "n" }, { "item", "i" }, { "count", "n" }, { "flags", "s" } } })
	end
end
M.PSS_IX_INV_KINDS = KINDOF

local function wantCode(pd, code)
	local kind = KINDOF[sub(code, 1, 1)]
	if not kind then return false end
	if pd.st and not pd.st["inv." .. kind] then return false end
	if pd.stPrefix and sub("inv." .. kind, 1, #pd.stPrefix) ~= pd.stPrefix then return false end
	return true
end

-- the holders and containers that hold the pushed down items (through the summary index)
local function holdersOf(items)
	local refs = {}
	if M.PSS_WhHolders then
		for _, ref in ipairs(M.PSS_WhHolders:keys()) do
			local key = M.PSS_ItemUnref(ref) or ref
			if items[itemId(key)] then refs[#refs + 1] = { ref } end
		end
	end
	M.PSS_IxWhStats.finds = M.PSS_IxWhStats.finds + 1
	local s = { cols = { "item" }, n = #refs }
	for i = 1, #refs do s[i] = refs[i] end
	local got = #refs > 0 and call("wh.find", s) or nil
	local by = {}
	for i = 1, got and got.n or 0 do
		local e, code = got[i][2], got[i][3]
		by[e] = by[e] or {}
		by[e][code] = true
	end
	return by
end

local function splitFlags(flags, r)
	r.bound = find(flags, "b", 1, true) and 1 or nil
	r.loot = find(flags, "l", 1, true) and 1 or nil
	r.expires = tonumber(match(flags, "t(%d+)"))
end

local function seenMap()
	local m = {}
	local s = call("wh.status")
	for i = 1, s and s.n or 0 do m[s[i][1]] = s[i][6] end
	return m
end

M.PSS_IxDeclare({
	name = "inv", kind = "state", owner = "warehouse-helper", gate = "items", residency = 0,
	fields = INVFIELDS, dicts = { item = "item", ent = "ent" }, pushdown = { "ent", "st", "kind", "item" },
	schemaKeys = { "wh.inv", "wh.seen", "wh.item", "wh.itemN", "wh.itemFree", "wh.bad", "wh.v" },
	doc = "every item stack in every container of every holder",
	cost = function()
		local s, n = call("wh.status"), 0
		for i = 1, s and s.n or 0 do n = n + (s[i][3] or 0) end
		return n
	end,
	scan = function(pd, emit)
		local ms = M.PSS_WhStore
		if not ms then return 0 end
		local me = M.PSS_Me and M.PSS_Me(false)
		local only = pd.item and holdersOf(pd.item)
		local ents = {}
		if pd.ent then for e in pairs(pd.ent) do ents[#ents + 1] = e end
		else ents = ms.Ents() end
		sort(ents)
		local seen = seenMap()
		local live = {}
		if me and (not pd.ent or pd.ent[me]) then
			local set = call("item.live", { cols = { "key" }, n = 1, { "*" } })
			if set then
				for i = 1, set.n do
					local row = set[i]
					local code = row[2]
					live[code] = live[code] or {}
					live[code][#live[code] + 1] = row
				end
				for code in pairs(set.conts or {}) do live[code] = live[code] or {} end
			end
		end
		local r, n = {}, 0
		local function out(ent, code, slot, item, count, flags, hidden)
			r.ent, r.cont, r.kind, r.tab, r.slot, r.item, r.count, r.flags = ent, code, KINDOF[sub(code, 1, 1)], tonumber(sub(code, 2)), slot, item, count, flags
			r.st, r.seen, r.hidden = "inv." .. tostring(r.kind), seen[ent], hidden and 1 or nil
			splitFlags(flags or "", r)
			n = n + 1
			return emit(r)
		end
		for _, ent in ipairs(ents) do
			local hidden = hiddenOf(ent)
			if (not hidden or pd.hidden) and not (only and not only[ent]) then
				local codes = {}
				for _, code in ipairs(ms.Codes(ent)) do codes[code] = true end
				if ent == me then for code in pairs(live) do codes[code] = true end end
				local list = {}
				for code in pairs(codes) do list[#list + 1] = code end
				sort(list)
				for _, code in ipairs(list) do
					if wantCode(pd, code) and not (only and not only[ent][code]) then
						M.PSS_IxWhStats.conts = M.PSS_IxWhStats.conts + 1
						local rows = ent == me and live[code]
						if rows then
							for i = 1, #rows do
								local x = rows[i]
								if out(ent, code, x[3], x[4], x[5], x[6], hidden) == false then return n end
							end
						else
							local str = ms.Get(ent, code)
							local set = { cols = { "ent", "cont", "slot", "item", "count", "flags" }, n = 0 }
							if str then M.PSS_WhUnpack(str, set, ent, code) end
							for i = 1, set.n do
								local x = set[i]
								if out(ent, code, x[3], x[4], x[5], x[6], hidden) == false then return n end
							end
						end
					end
				end
			end
		end
		return n
	end,
})

-- the held item refs (the summary index's keys), as items
local function heldItems(pd)
	local out = {}
	if M.PSS_WhHolders then
		for _, ref in ipairs(M.PSS_WhHolders:keys()) do
			local key = M.PSS_ItemUnref(ref) or ref
			if not pd.item or pd.item[itemId(key)] then out[#out + 1] = key end
		end
	end
	sort(out)
	return out
end

local function asSet(col, list)
	local s = { cols = { col }, n = #list }
	for i = 1, #list do s[i] = { list[i] } end
	return s
end

M.PSS_IxDeclare({
	name = "invsum", kind = "state", owner = "warehouse-helper", gate = "warehouse", residency = 0,
	fields = { { "item", "i", "the item key" }, { "ent", "e", "the holder" }, { "cont", "k", "the container" }, { "count", "n", "how many" } },
	dicts = { item = "item", ent = "ent" }, pushdown = { "item", "ent" },
	schemaKeys = { "wh.inv" }, doc = "how many of each item each holder keeps, per container",
	scan = function(pd, emit)
		local items = heldItems(pd)
		local got = call("wh.find", asSet("item", items))
		local r, n = {}, 0
		for i = 1, got and got.n or 0 do
			local x = got[i]
			if not pd.ent or pd.ent[x[2]] then
				r.item, r.ent, r.cont, r.count = x[1], x[2], x[3], x[4]
				n = n + 1
				if emit(r) == false then return n end
			end
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "cur", kind = "state", owner = "warehouse-helper", gate = "warehouse", residency = 0,
	fields = { { "ent", "e", "the holder" }, { "currency", "n", "the currency id" }, { "qty", "n", "how many" } },
	dicts = { ent = "ent" }, pushdown = { "ent" }, schemaKeys = { "wh.cur" }, doc = "every currency every holder has",
	scan = function(pd, emit)
		local ents = {}
		if pd.ent then for e in pairs(pd.ent) do ents[#ents + 1] = e end else ents = M.PSS_WhStore and M.PSS_WhStore.Ents() or {} end
		local all = {}
		for _, kind in ipairs({ "c", "g", "w" }) do for _, id in ipairs(M.PSS_EntityList(kind)) do all[id] = true end end
		for e in pairs(all) do if not pd.ent then ents[#ents + 1] = e end end
		local seen, list = {}, {}
		for _, e in ipairs(ents) do if not seen[e] then seen[e] = true; list[#list + 1] = e end end
		sort(list)
		local got = call("wh.cur", asSet("ent", list))
		local r, n = {}, 0
		for i = 1, got and got.n or 0 do
			r.ent, r.currency, r.qty = got[i][1], got[i][2], got[i][3]
			n = n + 1
			if emit(r) == false then return n end
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "gold", kind = "state", owner = "money-helper", gate = "warehouse", residency = 0,
	fields = { { "ent", "e", "the holder" }, { "copper", "c", "the gold, in copper" }, { "seen", "t", "when it was last read" } },
	dicts = { ent = "ent" }, pushdown = { "ent" }, schemaKeys = { "wh.gold" }, doc = "each holder's gold",
	scan = function(pd, emit)
		local got = call("money.gold", nil, { hidden = pd.hidden })
		local seen = seenMap()
		local r, n = {}, 0
		for i = 1, got and got.n or 0 do
			local e = got[i][1]
			if not pd.ent or pd.ent[e] then
				r.ent, r.copper, r.seen = e, got[i][2], seen[e]
				n = n + 1
				if emit(r) == false then return n end
			end
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "val", kind = "state", owner = "money-helper", gate = "warehouse", residency = 0,
	fields = { { "item", "i", "the item key" }, { "vendor", "c", "the vendor price" }, { "auction", "c", "the auction value" }, { "source", "k", "where the value comes from" } },
	dicts = { item = "item" }, pushdown = { "item" }, doc = "what each held item is worth",
	scan = function(pd, emit)
		local got = call("money.value", asSet("item", heldItems(pd)))
		local r, n = {}, 0
		for i = 1, got and got.n or 0 do
			r.item, r.vendor, r.auction, r.source = got[i][1], got[i][2], got[i][3], got[i][4]
			n = n + 1
			if emit(r) == false then return n end
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "ent", kind = "state", owner = "warehouse-helper", residency = 0,
	fields = { { "id", "e", "the entity id" }, { "kind", "k", "c character, g guild, w warband" }, { "name", "s", "its name" },
		{ "realm", "s", "its realm" }, { "faction", "k", "Alliance, Horde, Neutral" }, { "class", "k", "a character's class" },
		{ "race", "k", "a character's race" }, { "sex", "n", "a character's sex" }, { "hidden", "b", "hidden from tooltips and search" } },
	pushdown = {}, schemaKeys = { "options.ent", "wh.meta" }, doc = "every character, guild and the warband PSS knows",
	scan = function(pd, emit)
		local ids = {}
		for _, kind in ipairs({ "c", "g", "w" }) do for _, id in ipairs(M.PSS_EntityList(kind)) do ids[#ids + 1] = id end end
		sort(ids)
		local r, n = {}, 0
		for _, id in ipairs(ids) do
			local set = M.PSS_Entity(id)
			local x = set and set[1]
			if x then
				local hidden = (M.PSS_EntityFlags(id) or ""):find("h", 1, true) ~= nil
				if not hidden or pd.hidden then
					local secret = M.PSS_IsSecret
					r.id, r.kind, r.name, r.realm, r.faction, r.class, r.race, r.sex = x[1], x[2], x[3], x[4], x[5], x[6], x[7], x[8]
					if secret(r.name) then r.name = nil end
					if secret(r.realm) then r.realm = nil end
					r.hidden = hidden and 1 or nil
					n = n + 1
					if emit(r) == false then return n end
				end
			end
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "item", kind = "state", owner = "warehouse-helper", gate = "warehouse", residency = 0,
	fields = { { "ref", "i", "the item key" }, { "id", "n", "the item id" }, { "name", "s", "its name" }, { "quality", "n", "0 to 8" },
		{ "ilvl", "n", "item level" }, { "class", "k", "item class" }, { "link", "s", "the item link" }, { "pending", "b", "the client has not sent its data yet" } },
	pushdown = {}, doc = "every held item variant",
	scan = function(pd, emit)
		local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
		local r, n = {}, 0
		for _, key in ipairs(heldItems(pd)) do
			local id = itemId(key)
			local name, link, quality, ilvl, class
			if f and id then
				local _
				name, link, quality, ilvl, _, _, _, _, _, _, _, class = f(id)
			end
			if type(name) == "string" and M.PSS_IsSecret(name) then name = nil end
			r.ref, r.id, r.name, r.quality, r.ilvl, r.class, r.link = key, id, name, quality, ilvl, class, link
			r.pending = name == nil and 1 or nil
			n = n + 1
			if emit(r) == false then return n end
		end
		return n
	end,
})
