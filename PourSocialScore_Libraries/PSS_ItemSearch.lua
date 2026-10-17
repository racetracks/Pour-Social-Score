------------------------------------------------------------------------
-- POUR SOCIAL SCORE - ITEM SEARCH (warehouse-helper, one-build plan
-- STP-p12, Syndicator parity 1 to 9). The words, operators and numbers a
-- search box understands, written from the behaviour only:
--   words      a keyword (about 80, in groups; English always, the client's own
--              word where it gives one; a hyphen stands for a space), else part of
--              the item's name, else a line of its tooltip
--   operators  a & b   a | b   ~a   !a   ( )          (& binds tighter than |)
--   numbers    >400  <300  =415  400-420    item level
--              >10g  <=5s  5s-2g  1g50s     value (money.value: the price addon's, else the vendor's)
--   item.search   item?, opts { text, page, pageSize } -> item, match
--   item.keywords                                      -> keyword, group, english
-- The candidates are every item the Warehouse holds (or the set given). An item
-- the client has not told us about yet is asked for and the search goes on in
-- slices (M.PSS_Want class slice, no OnUpdate); M.PSS_ItemSearchDone(text) says
-- when it is complete and ITEM_SEARCH (text) fires when more results arrived.
-- A search is kept until WH_CHANGED. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("items") then return end

local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local lower, find, sub, match, gsub = string.lower, string.find, string.sub, string.match, string.gsub
local sort, concat, floor = table.sort, table.concat, math.floor

local PAGE = 100		-- results in a page
local BUDGET = 4		-- milliseconds a search works at a time (a slice)
local TIPCAP = 600		-- tooltips kept
local CACHECAP = 24		-- searches kept

------------------------------------------------------------------------
-- What an item is: its properties, from the client, once per key
------------------------------------------------------------------------
local props = {}
local nprops, ntips = 0, 0
local tips = {}

local function idOf(key)
	return M.PSS_ItemId and M.PSS_ItemId(key) or tonumber(match(tostring(key), "^(%d+)"))
end

local function keyOfRef(ref)
	if type(ref) ~= "string" then return nil end
	if sub(ref, 1, 1) == "x" then
		local d = rawget(_G, "PSS_WarehouseDB")
		return d and d.item and d.item[tonumber(sub(ref, 2))] or nil
	end
	return ref
end

local function info(id)
	local f = C_Item and C_Item.GetItemInfo or GetItemInfo
	if not f then return nil end
	return f(id)
end

-- the properties of one key, or nil when the client has not told us yet
local function propsOf(key)
	local p = props[key]
	if p then return p end
	local kind = sub(key, 1, 2)
	if kind == "p:" then
		local species, level, quality = match(key, "^p:(%d+):(%d+):(%d+)")
		p = { key = key, name = "", quality = tonumber(quality) or 1, ilvl = tonumber(level) or 1, class = 17, sub = 0, equip = "", bind = 0, price = 0, exp = 0, stack = 1, pet = true }
	elseif kind == "k:" then
		local _, lvl = match(key, "^k:(%d+):(%d+)")
		p = { key = key, name = "Mythic Keystone", quality = 4, ilvl = tonumber(lvl) or 0, class = 5, sub = 0, equip = "", bind = 1, price = 0, exp = 0, stack = 1, keystone = true }
	else
		local id = idOf(key)
		if not id then return nil end
		local name, link, quality, ilvl, _, _, _, stack, equip, _, price, class, subc, bind, exp = info(id)
		if not name then return nil end
		if GetDetailedItemLevelInfo then
			local il = GetDetailedItemLevelInfo(link or id)
			if type(il) == "number" and il > 0 then ilvl = il end
		end
		p = { key = key, id = id, name = name, link = link, quality = quality or 0, ilvl = ilvl or 0, class = class or 15, sub = subc or 0, equip = equip or "",
			bind = bind or 0, price = price or 0, exp = exp or 0, stack = stack or 1 }
	end
	if nprops >= 6000 then props, nprops = {}, 0 end
	props[key] = p
	nprops = nprops + 1
	return p
end

-- the lines of an item's tooltip, lower case; kept for a while
local function tipOf(p)
	local t = tips[p.key]
	if t ~= nil then return t end
	t = false
	local id = p.id
	if id and C_TooltipInfo and C_TooltipInfo.GetItemByID then
		local ok, data = pcall(C_TooltipInfo.GetItemByID, id)
		if ok and type(data) == "table" and type(data.lines) == "table" then
			local out = {}
			for _, l in ipairs(data.lines) do
				local txt = l.leftText
				if type(txt) == "string" and not (M.PSS_IsSecret and M.PSS_IsSecret(txt)) then out[#out + 1] = lower(txt) end
			end
			t = concat(out, "\n")
		end
	end
	if ntips >= TIPCAP then tips, ntips = {}, 0 end
	tips[p.key] = t
	ntips = ntips + 1
	return t
end

local function tipHas(p, word)
	local t = tipOf(p)
	return t and find(t, word, 1, true) ~= nil or false
end

------------------------------------------------------------------------
-- Keywords: { english, group, test, word } ; word gives the client's own word
------------------------------------------------------------------------
local function gs(name) local v = rawget(_G, name); return type(v) == "string" and v or nil end

-- the keywords are rows of data: { english, a, b, c } under a group whose matcher reads a, b and c
local function transmog(p, want)
	local T = C_TransmogCollection
	if p.equip == "" or not (T and T.PlayerHasTransmogByItemInfo) then return false end
	return (T.PlayerHasTransmogByItemInfo(p.link or p.id) and true or false) == want
end
local MATCH = {
	quality = function(p, a) return p.quality == a end,
	binding = function(p, a) return a:find(p.bind, 1, true) ~= nil end,
	slot = function(p, a, b, c) return p.equip == a or p.equip == b or p.equip == c end,
	armor = function(p, a) return p.class == 4 and p.sub == a end,
	class = function(p, a) return p.class == a end,
	consumable = function(p, a) return p.class == 0 and p.sub == a end,
	expansion = function(p, a) return p.exp == a and (a > 0 or p.id ~= nil) end,
	other = function(p, a)
		if a == "equipment" then return p.equip ~= "" end
		if a == "stackable" then return p.stack > 1 end
		if a == "sellable" then return p.price > 0 end
		if a == "novalue" then return p.price == 0 end
		if a == "crafted" then return tipHas(p, "crafted") or tipHas(p, "crafting quality") end
		if a == "engraving" then return tipHas(p, "engrav") end
		if a == "collected" then return transmog(p, true) end
		return transmog(p, false)
	end,
}
local GROUPS = {
	{ "quality", { { "poor", 0 }, { "common", 1 }, { "uncommon", 2 }, { "rare", 3 }, { "epic", 4 }, { "legendary", 5 }, { "artifact", 6 }, { "heirloom", 7 } } },
	{ "binding", { { "bop", "1" }, { "soulbound", "14" }, { "boe", "2" }, { "bou", "3" }, { "boa", "789" }, { "warbound", "89" }, { "unbound", "0" } } },
	{ "slot", { { "head", "INVTYPE_HEAD" }, { "neck", "INVTYPE_NECK" }, { "shoulder", "INVTYPE_SHOULDER" }, { "back", "INVTYPE_CLOAK" },
		{ "chest", "INVTYPE_CHEST", "INVTYPE_ROBE" }, { "shirt", "INVTYPE_BODY" }, { "tabard", "INVTYPE_TABARD" }, { "wrist", "INVTYPE_WRIST" },
		{ "hands", "INVTYPE_HAND" }, { "waist", "INVTYPE_WAIST" }, { "legs", "INVTYPE_LEGS" }, { "feet", "INVTYPE_FEET" },
		{ "ring", "INVTYPE_FINGER" }, { "trinket", "INVTYPE_TRINKET" }, { "onehand", "INVTYPE_WEAPON" }, { "twohand", "INVTYPE_2HWEAPON" },
		{ "mainhand", "INVTYPE_WEAPONMAINHAND" }, { "offhand", "INVTYPE_WEAPONOFFHAND", "INVTYPE_HOLDABLE" }, { "shield", "INVTYPE_SHIELD" },
		{ "ranged", "INVTYPE_RANGED", "INVTYPE_RANGEDRIGHT", "INVTYPE_THROWN" }, { "relic", "INVTYPE_RELIC" } } },
	{ "armor", { { "cloth", 1 }, { "leather", 2 }, { "mail", 3 }, { "plate", 4 } } },
	{ "class", { { "weapon", 2 }, { "armor", 4 }, { "consumable", 0 }, { "container", 1 }, { "gem", 3 }, { "tradegoods", 7 }, { "reagent", 7 }, { "recipe", 9 },
		{ "questitem", 12 }, { "miscellaneous", 15 }, { "battlepet", 17 }, { "profession", 19 }, { "glyph", 16 } } },
	{ "consumable", { { "potion", 1 }, { "elixir", 2 }, { "flask", 3 }, { "food", 5 }, { "bandage", 7 } } },
	{ "other", { { "equipment", "equipment" }, { "stackable", "stackable" }, { "sellable", "sellable" }, { "novalue", "novalue" }, { "crafted", "crafted" },
		{ "engraving", "engraving" }, { "collected", "collected" }, { "uncollected", "uncollected" } } },
	{ "expansion", { { "classic", 0 }, { "burningcrusade", 1 }, { "wrath", 2 }, { "cataclysm", 3 }, { "mists", 4 }, { "warlords", 5 }, { "legion", 6 }, { "battleforazeroth", 7 },
		{ "shadowlands", 8 }, { "dragonflight", 9 }, { "warwithin", 10 }, { "midnight", 11 } } },
}
local ROWS = {}
for _, g in ipairs(GROUPS) do
	for _, r in ipairs(g[2]) do ROWS[#ROWS + 1] = { en = r[1], group = g[1], a = r[2], b = r[3], c = r[4], test = MATCH[g[1]] } end
end

-- the client's own word for a keyword, where it gives one
local function localized(r)
	if r.group == "quality" then return gs("ITEM_QUALITY" .. r.a .. "_DESC") end
	if r.group == "slot" then return gs(r.a) end
	if r.group == "class" then return GetItemClassInfo and GetItemClassInfo(r.a) or nil end
end

local function norm(s)
	return (gsub(lower(s), "[%-_]", " "))
end

local words
local function wordTable()
	if words then return words end
	words = {}
	for _, r in ipairs(ROWS) do
		words[norm(r.en)] = r
		local w = localized(r)
		if type(w) == "string" and w ~= "" then words[norm(w)] = r end
	end
	return words
end

M.PSS_Provide("item.keywords", function()
	local out = { cols = { "keyword", "group", "english" }, n = 0 }
	for _, r in ipairs(ROWS) do
		local w = localized(r)
		out.n = out.n + 1
		out[out.n] = { type(w) == "string" and w ~= "" and w or r.en, r.group, r.en }
	end
	return out
end, { returns = { "keyword", "group", "english" }, doc = "the search keywords", cost = "O(keywords)", writes = false, onError = "default",
	default = { cols = { "keyword", "group", "english" }, n = 0 } })

------------------------------------------------------------------------
-- The query: text -> a test over an item's properties
------------------------------------------------------------------------
local function money(s)
	local total, any = 0, false
	for n, u in s:gmatch("(%d+)([gsc])") do
		any = true
		n = tonumber(n)
		total = total + n * (u == "g" and 10000 or u == "s" and 100 or 1)
	end
	local rest = gsub(gsub(s, "%d+[gsc]", ""), "%s", "")
	if not any or rest ~= "" then return nil end
	return total
end

local function valueOf(p)
	if p.value ~= nil then return p.value end
	local v = p.price
	if M.PSS_Call and M.PSS_Opt("whValueSource") ~= "" then
		local set = M.PSS_Call("money.value", { cols = { "item" }, n = 1, { p.key } })
		if set and set.n == 1 and type(set[1][3]) == "number" then v = set[1][3] end
	end
	p.value = v
	return v
end

local function atom(text)
	local raw = lower(text)
	raw = gsub(gsub(raw, "^%s+", ""), "%s+$", "")
	if raw == "" then return nil, "empty" end
	local t = norm(raw)
	-- item level: >400 <300 =415 400-420
	local op, n = match(raw, "^([<>=]=?)%s*(%d+)$")
	if op then
		n = tonumber(n)
		if op == "=" or op == "==" then return function(p) return p.ilvl == n end end
		if op == ">" then return function(p) return p.ilvl > n end end
		if op == "<" then return function(p) return p.ilvl < n end end
		if op == ">=" then return function(p) return p.ilvl >= n end end
		return function(p) return p.ilvl <= n end
	end
	local lo, hi = match(raw, "^(%d+)%s*%-%s*(%d+)$")
	if lo then lo, hi = tonumber(lo), tonumber(hi); return function(p) return p.ilvl >= lo and p.ilvl <= hi end end
	-- value: >10g  <=5s  5s-2g  1g50s
	local vop, rest = match(raw, "^([<>=]=?)%s*(.+)$")
	if vop and money(rest) then
		local c = money(rest)
		if vop == ">" then return function(p) return valueOf(p) > c end end
		if vop == "<" then return function(p) return valueOf(p) < c end end
		if vop == ">=" then return function(p) return valueOf(p) >= c end end
		if vop == "<=" then return function(p) return valueOf(p) <= c end end
		return function(p) return valueOf(p) == c end
	end
	local a, b = match(raw, "^(.-)%s*%-%s*(.+)$")
	if a and money(a) and money(b) then
		local x, y = money(a), money(b)
		if x > y then x, y = y, x end
		return function(p) local v = valueOf(p); return v >= x and v <= y end
	end
	if money(raw) then local c = money(raw); return function(p) return valueOf(p) == c end end
	local kw = wordTable()[t]
	if kw then
		local test, a, b, c = kw.test, kw.a, kw.b, kw.c
		return function(p) return test(p, a, b, c) end
	end
	return function(p)
		if p.name ~= "" and find(norm(p.name), t, 1, true) then return true end
		return #t >= 3 and tipHas(p, t)
	end
end

-- recursive descent: or -> and -> not -> atom | ( or )
local function compile(text)
	local pos, len = 1, #text
	local err
	local parseOr
	local function skip() while pos <= len and sub(text, pos, pos) == " " do pos = pos + 1 end end
	local function parseAtom()
		skip()
		local c = sub(text, pos, pos)
		if c == "(" then
			pos = pos + 1
			local f = parseOr()
			skip()
			if sub(text, pos, pos) ~= ")" then err = err or "missing )"; return f end
			pos = pos + 1
			return f
		end
		local from = pos
		while pos <= len do
			local ch = sub(text, pos, pos)
			if ch == "&" or ch == "|" or ch == "(" or ch == ")" then break end
			pos = pos + 1
		end
		local f, why = atom(sub(text, from, pos - 1))
		if not f then err = err or why; return function() return false end end
		return f
	end
	local function parseNot()
		skip()
		local c = sub(text, pos, pos)
		if c == "~" or c == "!" then
			pos = pos + 1
			local f = parseNot()
			return function(p) return not f(p) end
		end
		return parseAtom()
	end
	local function parseAnd()
		local f = parseNot()
		skip()
		while sub(text, pos, pos) == "&" do
			pos = pos + 1
			local g, h = f, parseNot()
			f = function(p) return g(p) and h(p) end
			skip()
		end
		return f
	end
	function parseOr()
		local f = parseAnd()
		skip()
		while sub(text, pos, pos) == "|" do
			pos = pos + 1
			local g, h = f, parseAnd()
			f = function(p) return g(p) or h(p) end
			skip()
		end
		return f
	end
	local f = parseOr()
	skip()
	if pos <= len and not err then err = "unexpected " .. sub(text, pos, pos) end
	if err then return nil, err end
	return f
end

------------------------------------------------------------------------
-- Candidates, the cache and the progressive search
------------------------------------------------------------------------
local cache, ncache = {}, 0
local stats = { computed = 0 }
function M.PSS_ItemSearchStats() return stats end

local function candidates(input)
	local keys = {}
	if input and input.n then		-- no input searches every held item; an empty set searches none
		local c = M.PSS_SetCol(input, "item") or M.PSS_SetCol(input, "key") or 1
		local seen = {}
		for i = 1, input.n do
			local k = input[i][c]
			if type(k) == "number" then k = tostring(k) end
			if type(k) == "string" and not seen[k] then seen[k] = true; keys[#keys + 1] = k end
		end
		return keys
	end
	if M.PSS_WhHolders and M.PSS_On("warehouse") then
		for _, ref in ipairs(M.PSS_WhHolders:keys()) do
			local k = keyOfRef(ref)
			if k then keys[#keys + 1] = k end
		end
	elseif M.PSS_Call then
		local set = M.PSS_Call("item.live", { cols = { "key" }, n = 1, { "*" } })
		local seen = {}
		for i = 1, set and set.n or 0 do
			local k = set[i][4]
			if type(k) == "string" and k ~= "" and not seen[k] then seen[k] = true; keys[#keys + 1] = k end
		end
	end
	return keys
end

local function judge(entry, key)
	local p = propsOf(key)
	if not p then return false end		-- not told yet
	if entry.fn(p) then entry.hits[#entry.hits + 1] = { key, p.name }; entry.sorted = nil end
	return true
end

-- milliseconds: the client's profiler clock where it has one
local function now()
	local T = M.PSS_Test
	if T and T.clock then return T.clock() end		-- the harness's real clock (its client clock is simulated)
	return debugprofilestop and debugprofilestop() or 0
end

local function finished(e) return e.pos > #e.todo and #e.retry == 0 end

local needId, wakeId = "item.search", "item.search.data"

-- something to do now: candidates not looked at yet, or (only retries left) the client answered everything it was
-- asked or 100 ms have passed since the last look
local function runnable(e)
	if finished(e) then return false end
	if e.pos <= #e.todo then return true end
	return (M.PSS_ItemPending and M.PSS_ItemPending() == 0) or now() - (e.lastRetry or -1e9) >= 100
end

-- judges candidates for about `budget` ms: the ones not looked at yet, then the ones the client had not told us about
local function work(e, budget)
	local t0, ask, before = now(), {}, #e.hits
	local todo, n = e.todo, #e.todo
	local i = e.pos
	while i <= n do
		local key = todo[i]
		i = i + 1
		if not judge(e, key) then
			e.retry[#e.retry + 1] = key
			local id = idOf(key)
			if id then ask[id] = true end
		end
		if i % 16 == 0 and now() - t0 > budget then break end
	end
	e.pos = i
	if e.pos > n and #e.retry > 0 and e.lastRetry ~= t0 then
		e.lastRetry = t0
		local again = e.retry
		e.retry = {}
		for _, key in ipairs(again) do
			if not judge(e, key) then
				e.retry[#e.retry + 1] = key
				local id = idOf(key)
				if id then ask[id] = true end
			end
		end
		-- items the client has answered about and still does not know are given up on (a search never waits for them)
		if #e.retry > 0 and M.PSS_ItemPending and M.PSS_ItemPending() == 0 and not next(ask) then e.retry = {} end
	end
	if M.PSS_ItemAwait and next(ask) then M.PSS_ItemAwait(ask) end
	if e.watch and (#e.hits ~= before or finished(e)) then
		for _, fn in ipairs(e.watch) do pcall(fn, e.text, finished(e)) end
	end
	if finished(e) and M.Events and M.Events.Fire and e.progressive then M.Events.Fire("ITEM_SEARCH", e.text) end
end

local wakeOn = false
local function arm()
	M.PSS_Unwant(needId)		-- one need for all searches
	M.PSS_Want({ id = needId, class = "slice", step = M.PSS_ItemSearchStep })
end
-- item data arrived: a search that was waiting for it runs again (the signal comes from PSS_ItemRead.lua)
local function wake()
	local any, waiting = false, false
	for _, e in pairs(cache) do
		if not finished(e) then
			if runnable(e) then any = true else waiting = true end
		end
	end
	if any then arm() end
	if not waiting then wakeOn = false; M.PSS_Unwant(wakeId) end
end
local function waitForData()
	if wakeOn or not M.PSS_Want then return end
	wakeOn = true
	M.PSS_Want({ id = wakeId, class = "coalesce", signal = "@item.data", fn = wake })
end

local function step()
	for _, e in pairs(cache) do
		if runnable(e) then
			work(e, BUDGET)
			if not finished(e) and e.pos > #e.todo then waitForData() end
			return false
		end
	end
	return true		-- nothing to do right now: the engine drops the need, the data signal brings it back
end
M.PSS_ItemSearchStep = step

function M.PSS_ItemSearchDebug(text) return cache[text] end

function M.PSS_ItemSearchDone(text)
	local e = cache[text]
	return e ~= nil and finished(e)
end

-- fn(text, done) is called when more results arrived; the window redraws from it
function M.PSS_ItemSearchWatch(text, fn)
	local e = cache[text]
	if not e or type(fn) ~= "function" then return end
	e.watch = e.watch or {}
	e.watch[#e.watch + 1] = fn
end

local function build(text, input)
	local fn, why = compile(text)
	if not fn then return nil, why end
	local entry = { text = text, fn = fn, hits = {}, todo = candidates(input), pos = 1, retry = {} }
	stats.computed = stats.computed + 1
	work(entry, BUDGET)
	if not finished(entry) then
		entry.progressive = true
		if M.PSS_Want then arm() end
		if entry.pos > #entry.todo then waitForData() end
	end
	return entry
end

M.Events.Register("WH_CHANGED", function() cache, ncache = {}, 0 end)

M.PSS_Provide("item.search", function(input, opts)
	local out = { cols = { "item", "match" }, n = 0 }
	local text = opts and opts.text
	if text == nil and type(input) == "table" and input.key ~= nil and not input.cols then text = input.key end
	if type(text) ~= "string" then return out end
	if M.PSS_IsSecret and M.PSS_IsSecret(text) then return out end
	if not find(text, "%S") then return out end
	local given = input and input.cols and input or nil
	local ck = given and nil or text
	local entry = ck and cache[ck]
	if not entry then
		local why
		entry, why = build(text, given)
		if not entry then
			if M.PSS_ErrNote then M.PSS_ErrNote("arg", "item.search", "bad search: " .. tostring(why)) end
			return out
		end
		if ck then
			if ncache >= CACHECAP then cache, ncache = {}, 0 end
			cache[ck] = entry
			ncache = ncache + 1
		end
	end
	if not entry.sorted then
		sort(entry.hits, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
		entry.sorted = true
	end
	local size = opts and tonumber(opts.pageSize) or PAGE
	local first = ((opts and tonumber(opts.page) or 1) - 1) * size
	for i = first + 1, first + size do
		local h = entry.hits[i]
		if not h then break end
		out.n = out.n + 1
		out[out.n] = { h[1], h[2] }
	end
	out.total = #entry.hits
	out.done = finished(entry)
	return out
end, { accepts = { "item" }, returns = { "item", "match" }, doc = "the items that fit a search text", cost = "O(items)", writes = false, onError = "empty", paged = true })
