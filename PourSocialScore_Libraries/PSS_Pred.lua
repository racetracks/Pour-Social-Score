------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PREDICATES AND PUSHDOWN (search-helper, STP-00238,
-- DDS-00031 section 7). A search's terms as a tree of closures, built once
-- per plan (no closure, no table per row):
--   local P = M.PSS_Pred
--   P.compile(ast, F) -> pred | nil, { code, pos, msg }
--     ast nodes: { k = "and" | "or", ... }  { k = "not", node }  { k = "cmp", field, op, value, pos }
--                { k = "in", field, set }   { k = "like", field, value }   { k = "text", value }
--                { k = "term", value, pos } (#keyword)   { k = "lazy", words, items, owners, ents }
--     F = { kind = function(field) -> kind, textFields = { ... } }
--   pred.fn(row, proven) -> bool  (proven: the scan proved every pushed top-level text word; a pushed node then returns true unread)
--   pred:test(row) -> bool      (row keyed by field name)
--   pred:pushdown() -> pd = { lo, hi, st = set, stPrefix, ent = set, item = set, owner = set, text = { words } }
--   pred:forCols(cols) -> a pred over positional rows (q.where's record sets)
-- Comparisons are typed by the field's kind (numbers as numbers, text
-- case-insensitive, entities and items by name or id); realm, faction and
-- class are virtual fields of any index with ent, compiled to an entity set.
-- Only the top-level AND is pushed down (nothing under OR or NOT).
-- Loaded with Libraries. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tonumber, tostring, pairs, ipairs, next, pcall, error, setmetatable = type, tonumber, tostring, pairs, ipairs, next, pcall, error, setmetatable
local find, lower, gsub, match = string.find, string.lower, string.gsub, string.match
local date = date or os.date

local P = {}
M.PSS_Pred = P
local PMT = { __index = P }
local NUM = { n = true, c = true, t = true, e = true }
local VIRTUAL = { realm = 4, faction = 5, class = 6 }		-- column of wh.ent / M.PSS_Entity
P.VIRTUAL = VIRTUAL

local function fail(node, code, msg) error({ code = code, pos = node and node.pos or 1, msg = msg }, 0) end

-- the item id of a row value: a number, an item key "21877:..." or nil
local function itemId(v)
	if type(v) == "number" then return v end
	if type(v) == "string" then return tonumber(match(v, "^x?(%d+)")) end
	return nil
end
P.itemId = itemId

local function truthy(v) return v ~= nil and v ~= false and v ~= 0 and v ~= "" end

-- the entity ids whose realm, faction or class equals want (case-insensitive)
local function entSet(field, want)
	local set = {}
	want = lower(tostring(want))
	local list = {}
	if M.PSS_EntityList then
		for _, kind in ipairs({ "c", "g", "w" }) do for _, id in ipairs(M.PSS_EntityList(kind) or {}) do list[#list + 1] = id end end
	end
	for _, id in ipairs(list) do
		local r = M.PSS_Entity and M.PSS_Entity(id)
		local v = r and r[1] and r[1][VIRTUAL[field]]
		if v and lower(tostring(v)) == want then set[id] = true end
	end
	return set
end
P.entSet = entSet

local function entOfName(v)
	if type(v) == "number" then return v end
	local n = tonumber(v)
	if n then return n end
	if not M.PSS_EntityId then return nil end
	local name, realm = match(tostring(v), "^([^%-]+)%-(.+)$")
	return M.PSS_EntityId("c", name or v, realm, false)
end

local cmpOps = {
	["="] = function(x, v) return x == v end,
	["!="] = function(x, v) return x ~= v end,
	["<"] = function(x, v) return x < v end,
	["<="] = function(x, v) return x <= v end,
	[">"] = function(x, v) return x > v end,
	[">="] = function(x, v) return x >= v end,
}

local function likePattern(v)
	local p = gsub(lower(v), "[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
	p = gsub(p, "%*", ".-")
	return "^" .. p .. "$"
end
P.likePattern = likePattern

-- like on a time field: "stamp", pattern (digits of the stamp yyyymmddhhmmss, a prefix) or "text", needle (the shown text)
function P.timeLike(value)
	local v = tostring(value)
	local bare = gsub(v, "[%-:/ Tt]", "")
	local star = find(bare, "*", 1, true)
	if star or (#bare >= 4 and find(bare, "^%d+$")) then
		return "stamp", likePattern(star and bare or (bare .. "*"))
	end
	return "text", lower((gsub(v, "^%s+", "")):gsub("%s+$", ""))
end

local compile

local function cmpNode(node, F, key)
	local field, op, v = node.field, node.op, node.value
	local kind = F.kind(field)
	if VIRTUAL[field] and F.kind("ent") and not kind then
		if op ~= "=" and op ~= "!=" then fail(node, "arg", field .. " takes = or !=") end
		local set, k = entSet(field, v), key("ent")
		node.entSet = set
		if op == "=" then return function(r) return set[r[k]] == true end end
		return function(r) return set[r[k]] ~= true end
	end
	if not kind then fail(node, "field", "unknown field " .. tostring(field)) end
	local k = key(field)
	local f = cmpOps[op]
	if not f then fail(node, "arg", "unknown operator " .. tostring(op)) end
	if kind == "i" then
		local id = itemId(v)
		if not id and type(v) == "string" and M.PSS_Terms and M.PSS_Terms.names then
			local got = M.PSS_Terms.names(v)
			local set = {}
			for _, ref in ipairs(got.items or {}) do set[itemId(ref) or ref] = true end
			node.itemSet = set
			if op == "=" then return function(r) return set[itemId(r[k])] == true end end
			if op == "!=" then return function(r) return set[itemId(r[k])] ~= true end end
			fail(node, "arg", "an item name takes = or !=")
		end
		if not id then fail(node, "arg", "not an item: " .. tostring(v)) end
		node.typed = id
		return function(r) local x = itemId(r[k]); return x ~= nil and f(x, id) end
	end
	if kind == "e" then
		local id = entOfName(v)
		if not id then id = -1 end		-- a name nobody has: matches nothing
		node.typed = id
		return function(r) local x = r[k]; return x ~= nil and f(x, id) end
	end
	if kind == "b" then
		local want = truthy(v) and v ~= "0" and lower(tostring(v)) ~= "false"
		if op == "=" then return function(r) return truthy(r[k]) == want end end
		if op == "!=" then return function(r) return truthy(r[k]) ~= want end end
		fail(node, "arg", "a yes/no field takes = or !=")
	end
	if NUM[kind] then
		local n = tonumber(v)
		if not n and kind == "t" and type(v) == "string" and M.PSS_Time then n = M.PSS_Time.parse(v) end
		if not n then fail(node, "arg", field .. " compares with a number, not " .. tostring(v)) end
		node.typed = n
		return function(r) local x = tonumber(r[k]); return x ~= nil and f(x, n) end
	end
	local lv = lower(tostring(v))
	node.typed = tostring(v)
	return function(r) local x = r[k]; return x ~= nil and f(lower(tostring(x)), lv) end
end

function compile(node, F, key)
	local k = node.k
	if k == "and" or k == "or" then
		local list = {}
		for i = 1, #node do list[i] = compile(node[i], F, key) end
		local n = #list
		if n == 0 then return function() return true end end
		if n == 1 then return list[1] end
		if k == "and" then
			return function(r, proven) for i = 1, n do if not list[i](r, proven) then return false end end return true end
		end
		return function(r) for i = 1, n do if list[i](r) then return true end end return false end
	elseif k == "not" then
		local f = compile(node[1], F, key)
		return function(r) return not f(r) end
	elseif k == "cmp" then
		return cmpNode(node, F, key)
	elseif k == "like" then
		if not F.kind(node.field) then fail(node, "field", "unknown field " .. tostring(node.field)) end
		local fk = key(node.field)
		local neg = node.op == "!="
		if F.kind(node.field) == "t" then		-- a time stamp yyyymmddhhmmss: the raw seconds never match
			local mode, tpat = P.timeLike(node.value)
			local memoMin, memoText
			return function(r)
				local x = tonumber(r[fk])
				local hit = false
				if x ~= nil and mode == "stamp" then
					hit = find(date("%Y%m%d%H%M%S", x), tpat) ~= nil
				elseif x ~= nil then
					local mn = math.floor(x / 60)
					if mn ~= memoMin then memoMin, memoText = mn, lower(date(M.PSS_TIME_SHOW, x)) end
					hit = find(memoText, tpat, 1, true) ~= nil
				end
				if neg then return not hit end
				return hit
			end
		end
		local pat = likePattern(node.value)
		return function(r) local x = r[fk]; local hit = x ~= nil and find(lower(tostring(x)), pat) ~= nil; if neg then return not hit end return hit end
	elseif k == "text" then
		local w = lower(tostring(node.value))
		local fields = {}
		for i, f in ipairs(F.textFields or {}) do fields[i] = key(f) end
		local wild = find(w, "*", 1, true)
		if wild then
			local pat = gsub(likePattern(w), "^%^", "")
			pat = gsub(pat, "%$$", "")
			return function(r)
				for i = 1, #fields do local x = r[fields[i]]; if x and find(lower(tostring(x)), pat) then return true end end
				return false
			end
		end
		if node.pushed then
			return function(r, proven)
				if proven then return true end
				for i = 1, #fields do local x = r[fields[i]]; if x and find(lower(tostring(x)), w, 1, true) then return true end end
				return false
			end
		end
		return function(r)
			for i = 1, #fields do local x = r[fields[i]]; if x and find(lower(tostring(x)), w, 1, true) then return true end end
			return false
		end
	elseif k == "in" then
		local set, fk = node.set, key(node.field)
		if node.field == "item" then return function(r) return set[itemId(r[fk])] == true end end
		return function(r) return set[r[fk]] == true end
	elseif k == "term" then
		if not F.kind("item") then fail(node, "arg", "#" .. tostring(node.value) .. " needs an index with items") end
		local tester, why = M.PSS_Terms and M.PSS_Terms.resolve(node.value)
		if not tester then fail(node, "arg", why or ("unknown keyword #" .. tostring(node.value))) end
		local fk, holder = key("item"), F
		return function(r)
			local res = tester(r[fk])
			if res == "pending" then holder.pending = true return false end
			return res == true
		end
	elseif k == "lazy" then
		local w = node.words and lower(node.words) or nil
		local fields = {}
		for i, f in ipairs(F.textFields or {}) do fields[i] = key(f) end
		local items, owners, ents = node.items or {}, node.owners or {}, node.ents or {}
		local needles = {}
		for id in pairs(items) do needles[#needles + 1] = "|hitem:" .. tostring(id) .. ":" end
		local ik, ok_, ek = F.kind("item") and key("item"), F.kind("owner") and key("owner"), F.kind("ent") and key("ent")
		local mk = F.kind("message") and key("message")
		return function(r)
			if ik and items[itemId(r[ik])] then return true end
			if ok_ and r[ok_] ~= nil and owners[r[ok_]] then return true end
			if ek and r[ek] ~= nil and ents[r[ek]] then return true end
			if mk and #needles > 0 then
				local m = r[mk]
				if m then
					local lm = lower(tostring(m))
					for i = 1, #needles do if find(lm, needles[i], 1, true) then return true end end
				end
			end
			if w then
				for i = 1, #fields do local x = r[fields[i]]; if x and find(lower(tostring(x)), w, 1, true) then return true end end
			end
			return false
		end
	end
	fail(node, "parse", "unknown node " .. tostring(k))
end

-- the pushdown of the top-level AND
local function pushdown(ast)
	local pd = {}
	local top = (ast and ast.k == "and") and ast or { ast }
	local function add(name, v)
		pd[name] = pd[name] or {}
		pd[name][v] = true
	end
	for i = 1, #top do
		local n = top[i]
		if n and n.k == "cmp" then
			local f, op, v = n.field, n.op, n.typed ~= nil and n.typed or n.value
			if f == "time" and type(v) == "number" then
				if op == ">" or op == ">=" then pd.lo = (pd.lo and pd.lo > v) and pd.lo or v end
				if op == "<" or op == "<=" then pd.hi = (pd.hi and pd.hi < v) and pd.hi or v end
			elseif op == "=" and (f == "st" or f == "owner") then add(f, tostring(v))
			elseif op == "=" and f == "ent" and type(v) == "number" then add("ent", v)
			elseif op == "=" and f == "hidden" then pd.hidden = truthy(v) and v ~= "0"
			elseif op == "=" and f == "item" and n.itemSet then for id in pairs(n.itemSet) do add("item", id) end
			elseif op == "=" and f == "item" and type(v) == "number" then add("item", v)
			elseif op == "=" and n.entSet then
				pd.ent = pd.ent or {}
				for id in pairs(n.entSet) do pd.ent[id] = true end
				if not next(n.entSet) then pd.none = true end
			end
		elseif n and n.k == "like" and n.field == "st" and n.op ~= "!=" then
			local pre = match(n.value, "^([^%*]*)%*$")
			if pre and pre ~= "" then pd.stPrefix = lower(pre) end
		elseif n and n.k == "in" and (n.field == "ent" or n.field == "item" or n.field == "owner") then
			pd[n.field] = pd[n.field] or {}
			for v in pairs(n.set) do pd[n.field][v] = true end
		elseif n and n.k == "text" then
			pd.text = pd.text or {}
			pd.text[#pd.text + 1] = lower(tostring(n.value))
		end
	end
	return pd
end

local function byName(f) return f end

function P.compile(ast, F)
	if ast == nil then ast = { k = "and" } end
	local top = (ast and ast.k == "and") and ast or { ast }
	for i = 1, #top do
		local n = top[i]
		if n and n.k == "text" and not find(lower(tostring(n.value)), "*", 1, true) then n.pushed = true end
	end
	local ok, fn = pcall(compile, ast, F, byName)
	if not ok then
		if type(fn) == "table" then return nil, fn end
		return nil, { code = "parse", pos = 1, msg = tostring(fn) }
	end
	local p = setmetatable({ fn = fn, ast = ast, F = F, byCols = setmetatable({}, { __mode = "k" }) }, PMT)
	p.pd = pushdown(ast)
	return p
end

function P:test(row) return self.fn(row) end
function P:pushdown() return self.pd end

-- the same predicate over positional rows of a record set with these columns
function P:forCols(cols)
	local c = self.byCols[cols]
	if c then return c end
	local at = {}
	for i = 1, #cols do at[cols[i]] = i end
	local F = self.F
	local G = { kind = function(f) return at[f] and (F.kind(f) or "s") or nil end, textFields = F.textFields }
	local ok, fn = pcall(compile, self.ast, G, function(f) return at[f] or f end)
	if not ok then error(type(fn) == "table" and (fn.code .. ": " .. fn.msg) or fn, 0) end
	c = { fn = fn }
	self.byCols[cols] = c
	return c
end
