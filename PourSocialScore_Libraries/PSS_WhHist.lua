------------------------------------------------------------------------
-- POUR SOCIAL SCORE - WAREHOUSE HISTORY (journal-helper, STP-00262, build J1).
-- What the warehouse alone does not keep, as the Spyglass event index "whh":
--   whh.d    ent item delta where   an item's net change of one settle window (a move between containers nets 0)
--   whh.g    ent copper             a character's gold, the last value of each hour
--   whh.day  ent item net           a closed day's whh.d lines folded into one per item
--   store    M.PSS_WhHistStore      month segments in PSS_WarehouseDB.whh, trimmed by jrnMonths
--   hooks    M.PSS_WhHistDelta (PSS_WhStore.lua), M.PSS_WhHistGold (PSS_Money.lua), both only with the Journal on
-- With the Journal off nothing is written and PSS_WarehouseDB.whh stays as it is. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local floor, date = math.floor, date
local gmatch, sub = string.gmatch, string.sub
local concat, sort = table.concat, table.sort

local L = M.PSS_Line

local store = M.PSS_Seg("whh", { db = "PSS_WarehouseDB", key = "whh", boundary = "month", lines = 500, cap = { months = "jrnMonths" } })
M.PSS_WhHistStore = store

local TYPES = {
	{ "d", { { "item", "i" }, { "delta", "n" }, { "where", "k" } } },
	{ "g", { { "copper", "c" } } },
	{ "day", { { "item", "i" }, { "net", "n" } } },
}
local FIELDS = {
	{ "time", "t", "server time" }, { "st", "k", "whh.<line>" }, { "ent", "e", "the character" },
	{ "item", "i", "the item" }, { "delta", "n", "net change in one settle window" }, { "where", "k", "container letter" },
	{ "net", "n", "net change over a day" }, { "copper", "c", "copper held" },
}
local stNames = {}
for _, ty in ipairs(TYPES) do
	L.type("whh." .. ty[1], { index = "whh", fields = ty[2] })
	stNames[#stNames + 1] = "whh." .. ty[1]
end

local function dayOf(t) return date("%Y-%m-%d", t) end

-- the open segment's lines of the closed day: its whh.d lines become one whh.day line per item, its whh.g lines
-- keep only the last per character
local function compact(prev)
	store:rewriteOpen(function(lines, base)
		local dict = store:dict()
		local day, nets, order, lastG, other, otherT, firstT = {}, {}, {}, {}, {}, {}, nil
		for i = 1, #lines do
			local r = {}
			L.decode(lines[i], base, r, dict)
			if r.time and dayOf(r.time) == prev and (r.st == "whh.d" or r.st == "whh.g" or r.st == "whh.day") then
				firstT = firstT or r.time
				if r.st == "whh.g" then lastG[r.ent] = r
				else
					local k = r.ent .. "\t" .. tostring(r.item)
					if not nets[k] then nets[k] = { ent = r.ent, item = r.item, net = 0 }; order[#order + 1] = k end
					nets[k].net = nets[k].net + (r.delta or r.net or 0)
				end
			else
				other[#other + 1] = lines[i]
				otherT[#otherT + 1] = r.time
			end
		end
		local out = {}
		local later = {}
		for i = 1, #other do
			if firstT and otherT[i] and otherT[i] >= firstT then later[#later + 1] = other[i] else out[#out + 1] = other[i] end
		end
		for _, k in ipairs(order) do
			out[#out + 1] = L.encode("whh.day", { time = firstT, ent = nets[k].ent, item = nets[k].item, net = nets[k].net }, base, dict)
		end
		local gl = {}
		for _, r in pairs(lastG) do gl[#gl + 1] = r end
		sort(gl, function(a, b) return a.time < b.time end)
		for _, r in ipairs(gl) do out[#out + 1] = L.encode("whh.g", { time = r.time, ent = r.ent, copper = r.copper }, base, dict) end
		for i = 1, #later do out[#out + 1] = later[i] end
		return out
	end)
end

-- chained, never replaced: J1I's flush serves "jrn", this one "whh"
local prevFlush = M.PSS_IxFlush
function M.PSS_IxFlush(index)
	if index ~= "whh" then return prevFlush and prevFlush(index) or 0 end
	if not M.PSS_On("journal") then return 0 end
	local hot = M.PSS_IxHot("whh")
	local n = 0
	for i = 1, #hot do
		local st, rec = L.hotRecord(hot[i])
		if st and rec.time then
			local T = store:tbl(true)
			local day = dayOf(rec.time)
			if T and type(T.v) == "number" and T.v <= 1 then
				if T.day and T.day ~= day then compact(T.day) end
				T.day = day
			end
			if store:add(st, rec) then n = n + 1 end
		end
	end
	M.PSS_IxHot("whh", true)
	return n
end

------------------------------------------------------------------------
-- Items: nets per entity and settle window
------------------------------------------------------------------------
local net, where = {}, {}

local function add(n, w, set, sign, cont)
	if type(set) ~= "table" then return end
	local letter = cont:match("^%a+") or cont
	for i = 1, (set.n or #set) do
		local r = set[i]
		local k = r[4]
		n[k] = (n[k] or 0) + sign * (r[5] or 1)
		w[k] = letter
	end
end

local function flushNets()
	if not M.PSS_On("journal") then net, where = {}, {}; return end
	for ent, n in pairs(net) do
		for ref, d in pairs(n) do
			if d ~= 0 then M.PSS_IxPut("whh", "whh.d", { ent = ent, item = ref, delta = d, where = where[ent][ref] }) end
		end
	end
	net, where = {}, {}
end

function M.PSS_WhHistDelta(ent, cont, old, new)
	if not M.PSS_On("journal") or not ent or type(cont) ~= "string" then return end
	local n, w = net[ent], where[ent]
	if not n then n, w = {}, {}; net[ent] = n; where[ent] = w end
	add(n, w, old, -1, cont); add(n, w, new, 1, cont)
end

------------------------------------------------------------------------
-- Gold: the last value of each hour, put when a later hour starts or at logout
------------------------------------------------------------------------
local pend = {}

local function putGold(ent, p)
	M.PSS_IxPut("whh", "whh.g", { time = p.t, ent = ent, copper = p.copper })
end

function M.PSS_WhHistGold(ent, copper)
	if not M.PSS_On("journal") or not ent or type(copper) ~= "number" then return end
	local t = GetServerTime()
	local h = floor(t / 3600)
	local p = pend[ent]
	if p and p.hour ~= h then putGold(ent, p) end
	pend[ent] = { hour = h, copper = copper, t = t }
end

function M.PSS_WhHistTrim()
	if not M.PSS_On("journal") then return 0 end
	return store:trim()
end

-- the one seal rule: every hot line into its store, the open hour's gold at logout, then the month cap on both stores
function M.PSS_JrnSeal(reason)
	if not M.PSS_On("journal") then return end
	flushNets()
	if reason == "logout" then
		for ent, p in pairs(pend) do putGold(ent, p) end
		pend = {}
	end
	M.PSS_IxFlush("jrn")
	M.PSS_IxFlush("whh")
	if M.PSS_JrnTrim then M.PSS_JrnTrim() end
	M.PSS_WhHistTrim()
end

if M.PSS_Provide and M.PSS_Trigger then
	M.PSS_Provide("whh.flush", function()
		flushNets()
		return { cols = { "n" }, n = 0 }
	end)
	M.PSS_Provide("jrn.seal", function()
		M.PSS_JrnSeal("logout")
		return { cols = { "n" }, n = 0 }
	end)
end

-- the rows are made with the warehouse start chain (the pattern of PSS_Money.lua), only with the Journal on
local prevStart = M.PSS_WhStartMore
local started
function M.PSS_WhStartMore(warehouse)
	if prevStart then prevStart(warehouse) end
	if not warehouse or started or not M.PSS_On("journal") or not M.PSS_Trigger then return end
	started = true
	M.PSS_Trigger({ id = "whh.net", gate = "journal", on = { "BAG_UPDATE_DELAYED" }, settle = "now", run = "whh.flush" })
	M.PSS_Trigger({ id = "jrn.seal", gate = "journal", on = { "PLAYER_LOGOUT" }, settle = "now", run = "jrn.seal" })
	M.PSS_JrnSeal("login")
end

------------------------------------------------------------------------
-- The index
------------------------------------------------------------------------
local function wanted(pd, t, st)
	if pd.hi and t and t > pd.hi then return false end
	if pd.lo and t and t < pd.lo then return false end
	if st and pd.st and not pd.st[st] then return false end
	return true
end

local function keep(pd, r)
	if pd.ent and not pd.ent[r.ent] then return false end
	if pd.item and not pd.item[r.item] then return false end
	return true
end

local function walk(body, base, pd, r, emit, counter)
	local lines = {}
	for line in gmatch(body, "[^\n]+") do lines[#lines + 1] = line end
	for i = #lines, 1, -1 do
		local line = lines[i]
		if wanted(pd, L.time(line, base), L.st(line)) then
			L.decode(line, base, r, store:dict())
			if keep(pd, r) then
				counter.n = counter.n + 1
				if emit(r) == false then return false end
			end
		end
	end
	return true
end

M.PSS_IxDeclare({
	name = "whh", kind = "event", owner = "journal-helper", gate = "journal", residency = 0,
	fields = FIELDS, dicts = { item = "item", ent = "ent" }, pushdown = { "time", "ent", "item" },
	schemaKeys = { "wh.whh" },
	doc = "the Warehouse history: what each character's items and gold changed by, per settle window and per hour",
	newer = function() local T = store:tbl(); return T ~= nil and type(T.v) == "number" and T.v > 1 end,
	cost = function() return #M.PSS_IxHot("whh") + store:count() end,
	summary = function(r) return tostring(r.st) .. " " .. tostring(r.item or r.copper or "") end,
	scan = function(pd, emit)
		local r, counter = {}, { n = 0 }
		for ent, p in pairs(pend) do
			r.st, r.time, r.ent, r.copper, r.item, r.delta = "whh.g", p.t, ent, p.copper, nil, nil
			if wanted(pd, r.time, r.st) and keep(pd, r) then
				counter.n = counter.n + 1
				if emit(r) == false then return counter.n end
			end
		end
		local hot = M.PSS_IxHot("whh")
		for i = #hot, 1, -1 do
			L.decodeHot(hot[i], r)
			if wanted(pd, r.time, r.st) and keep(pd, r) then
				counter.n = counter.n + 1
				if emit(r) == false then return counter.n end
			end
		end
		local stopped = false
		store:each(pd.lo, pd.hi, pd.st, function(body, base)
			if not stopped and walk(body, base, pd, r, emit, counter) == false then stopped = true end
		end)
		return counter.n
	end,
})
