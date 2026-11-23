------------------------------------------------------------------------
-- POUR SOCIAL SCORE - TERMS AND NAMES (search-helper, STP-00240 and
-- STP-00287). One search dialect: PSQL's #keyword is item.search's keyword,
-- tested through the same service (the bag search box, bag categories,
-- Search Everywhere and PSQL accept the same words).
--   M.PSS_Terms.resolve(keyword) -> tester(itemKey) -> true | false | "pending" | nil, why
--   M.PSS_Terms.names(words) -> { items = { id }, owners = { key }, ents = { id }, ambiguous = n }
--   M.PSS_Terms.itemIds()       the ids the item name index is built from (warehouse holders, live bags)
--   M.PSS_TermsDrop()           releases the name index (a GC request)
-- The item name index (an M.PSS_Index) maps a lower-case item name to its ids;
-- built on the first lazy search, dropped on a GC request. An item whose name
-- the client has not loaded yet is found by id only. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, tonumber, pairs, ipairs = type, tostring, tonumber, pairs, ipairs
local lower, gsub, match, sub, find = string.lower, string.gsub, string.match, string.sub, string.find
local sort = table.sort

local T = {}
M.PSS_Terms = T
local PREFIX_CAP = 50
T.PREFIX_CAP = PREFIX_CAP

local keywords
local function keywordSet()
	if keywords then return keywords end
	keywords = {}
	local set = M.PSS_Call and M.PSS_Call("item.keywords")
	for i = 1, set and set.n or 0 do
		keywords[lower(tostring(set[i][1]))] = true
		keywords[lower(tostring(set[i][3]))] = true
	end
	return keywords
end

function T.resolve(keyword)
	if type(keyword) ~= "string" or keyword == "" then return nil, "arg: an empty keyword" end
	local kw = lower(keyword)
	if not keywordSet()[kw] then return nil, "unknown keyword #" .. keyword end
	local memo, input = {}, { cols = { "item" }, n = 1, { false } }
	local opts = { text = kw, pageSize = 1 }
	return function(key)
		if key == nil then return false end
		local k = type(key) == "number" and tostring(key) or key
		local m = memo[k]
		if m ~= nil then return m end
		input[1][1] = k
		local out = M.PSS_Call("item.search", input, opts)
		if not out then return false end
		if out.n > 0 then m = true elseif out.done == false then return "pending" else m = false end
		memo[k] = m
		return m
	end
end

local function idOf(v)
	if type(v) == "number" then return v end
	return tonumber(match(tostring(v), "^x?(%d+)"))
end

local function itemName(id)
	local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local name = f and f(id)
	if type(name) ~= "string" or (M.PSS_IsSecret and M.PSS_IsSecret(name)) then return nil end
	return name
end

-- the ids the name index covers: held items (the warehouse's summary index) and the bags shown now
function T.itemIds()
	local ids, seen = {}, {}
	local function add(v)
		local id = idOf(v)
		if id and id > 0 and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
	end
	if M.PSS_WhHolders and M.PSS_On("warehouse") then
		for _, ref in ipairs(M.PSS_WhHolders:keys()) do add(M.PSS_ItemUnref and M.PSS_ItemUnref(ref) or ref) end
	end
	local live = M.PSS_On("warehouse") or M.PSS_On("bags")
	if live and M.PSS_Call then
		local set = M.PSS_Call("item.live", { cols = { "key" }, n = 1, { "*" } })
		for i = 1, set and set.n or 0 do add(set[i][4]) end
	end
	for _, id in ipairs(T.extraIds or {}) do add(id) end		-- the harness's item fixture, later the journal's items
	return ids
end

local nameIndex = M.PSS_Index("ix.itemNames", {
	sourceVer = function() return (M.PSS_WhStore and M.PSS_WhStore.Ver and M.PSS_WhStore.Ver() or 0) + (T.extraVer or 0) end,
	build = function(add)
		local by = {}
		for _, id in ipairs(T.itemIds()) do
			local name = itemName(id)
			if name then
				local k = lower(name)
				by[k] = by[k] or {}
				by[k][#by[k] + 1] = id
			end
		end
		for k, list in pairs(by) do sort(list); add(k, list) end
	end,
})
T.nameIndex = nameIndex

function M.PSS_TermsDrop() nameIndex:drop() end

local function trim(s) return (gsub(gsub(s, "^%s+", ""), "%s+$", "")) end

function T.names(words)
	local text = lower(trim(tostring(words or "")))
	local out = { items = {}, owners = {}, ents = {} }
	if text == "" then return out end
	local exact = nameIndex:get(text)
	local items = {}
	if exact then for _, id in ipairs(exact) do items[#items + 1] = id end end
	-- then names that start with the text (at most 51 looked at: more is ambiguous)
	local prefix, n = {}, 0
	for _, k in ipairs(nameIndex:keys()) do
		if k ~= text and sub(k, 1, #text) == text then
			for _, id in ipairs(nameIndex:get(k)) do n = n + 1; prefix[#prefix + 1] = id end
		end
	end
	if n + #items > PREFIX_CAP then
		out.ambiguous = n + #items
	else
		for _, id in ipairs(prefix) do items[#items + 1] = id end
	end
	out.items = items
	-- a player (p:<Name-Realm>), a guild (G:<key>) or an entity of that name
	local name = trim(tostring(words))
	if not find(name, "%s") or find(name, "%-") then
		local full = M.PSS_NormName and M.PSS_NormName(name) or name
		if full and M.PSS_History and M.PSS_History.PlayerKey then
			local key = M.PSS_History.PlayerKey(full)
			if key then out.owners[#out.owners + 1] = key end
		end
	end
	if M.PSS_FindGuildRule then
		local g = M.PSS_FindGuildRule(name)
		if type(g) == "string" then out.owners[#out.owners + 1] = "G:" .. g
		elseif type(g) == "table" and g.key then out.owners[#out.owners + 1] = "G:" .. g.key end
	end
	if M.PSS_EntityId then
		local n1, realm = match(name, "^([^%-]+)%-(.+)$")
		local id = M.PSS_EntityId("c", n1 or name, realm, false)
		if id then out.ents[#out.ents + 1] = id end
	end
	return out
end
