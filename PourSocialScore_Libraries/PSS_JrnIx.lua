------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE JOURNAL INDEX (journal-helper, STP-00259, build J1).
-- The Journal's lines as the Spyglass event index "jrn":
--   store   M.PSS_JrnStore   month segments in PSS_WarehouseDB.jrn (SAV-00082), dictionary encoded
--   types   jrn.sold jrn.bought jrn.post jrn.fail jrn.vend jrn.repair jrn.mailout jrn.mailin jrn.trade
--           jrn.taxi jrn.train jrn.quest jrn.loot (the Retail-only streams are not declared, DEC-00456)
--   writer  M.PSS_IxPut("jrn", st, rec) in core; M.PSS_IxFlush("jrn") seals its hot lines into the store
--   trim    M.PSS_JrnTrim()   months older than jrnMonths dropped, returns the segments dropped
--   item postings: index "jrn.item" (item -> segments), built on the first item query
-- With the Journal off nothing is opened or written (PSS_WarehouseDB.jrn stays as it is).
-- No frame, no event, no timer. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local find, sub, gmatch = string.find, string.sub, string.gmatch
local concat, sort = table.concat, table.sort

local L = M.PSS_Line
local C = M.PSS_Codec
local un36 = L.un36

local store = M.PSS_Seg("jrn", { db = "PSS_WarehouseDB", key = "jrn", boundary = "month", lines = 500, cap = { months = "jrnMonths" } })
M.PSS_JrnStore = store

-- the source types: name, fields { name, kind }
local TYPES = {
	{ "sold", "item i;count n;value c;deposit c;consignment c;buyer d" },
	{ "bought", "item i;count n;value c;seller d" },
	{ "post", "item i;count n;unit c;deposit c;duration n" },
	{ "fail", "item i;count n;kind k" },
	{ "vend", "item i;count n;unit c;kind k;currencies s;items s" },
	{ "repair", "copper c;guild b" },
	{ "mailout", "party d;copper c;cod c;items s;subject s" },
	{ "mailin", "party d;copper c;cod c;items s;subject s" },
	{ "trade", "party d;copperOut c;copperIn c;itemsOut s;itemsIn s" },
	{ "taxi", "copper c;from d;to d" },
	{ "train", "copper c;spell s" },
	{ "quest", "quest d;copper c;xp n;rep n;items s;currencies s" },
	{ "loot", "container i;copper c;items s;currencies s" },
}
local DOC = {
	item = "the item", count = "how many", value = "copper paid", deposit = "copper deposit", consignment = "copper consignment fee",
	buyer = "who bought", seller = "who sold", unit = "copper each", duration = "hours posted", kind = "sell, buy, buyback, refund, expired or cancelled",
	currencies = "currencies id:qty;...", items = "items id:qty;...", copper = "copper moved", guild = "paid by the guild",
	party = "the other player", cod = "copper cash on delivery", subject = "the mail's subject", copperOut = "copper given",
	copperIn = "copper received", itemsOut = "items given id:qty;...", itemsIn = "items received id:qty;...", from = "where from",
	to = "where to", spell = "the spell trained", quest = "the quest", xp = "experience", rep = "reputation", container = "the container item",
}
local FIELDS = { { "time", "t", "server time" }, { "st", "k", "jrn.<stream>" }, { "ent", "e", "the character" } }
local seen, stNames = {}, {}
for _, ty in ipairs(TYPES) do
	local fields = {}
	for name, kind in gmatch(ty[2], "(%w+) (%a)") do
		fields[#fields + 1] = { name, kind }
		if not seen[name] then seen[name] = true; FIELDS[#FIELDS + 1] = { name, kind, DOC[name] or name } end
	end
	L.type("jrn." .. ty[1], { index = "jrn", fields = fields })
	stNames[#stNames + 1] = "jrn." .. ty[1]
end

-- the hot lines (written before Libraries loaded, or waiting for a flush) into the store
function M.PSS_IxFlush(index)
	if index ~= "jrn" then return 0 end
	if not M.PSS_On("journal") then return 0 end
	local hot = M.PSS_IxHot("jrn")
	local n = 0
	for i = 1, #hot do
		local st, rec = L.hotRecord(hot[i])
		if st and store:add(st, rec) then n = n + 1 end
	end
	M.PSS_IxHot("jrn", true)
	return n
end

function M.PSS_JrnTrim()
	if not M.PSS_On("journal") then return 0 end
	return store:trim()
end

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

-- the lines of one body, newest first, through emit; false when emit stopped
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

-- item postings: item -> the segments (ids, or "open") that hold it
local post = {}
local postings = M.PSS_Index("jrn.item", {
	sourceVer = function() return store:ver() end,
	cap = 200000,
	units = function()
		post = {}
		local T = store:tbl()
		local list = {}
		if not T or type(T.v) == "number" and T.v > 1 then return list end
		for id = T.first or 1, T.seq or 0 do if type(T.seg and T.seg[id]) == "string" then list[#list + 1] = id end end
		if type(T.open) == "table" and #T.open > 0 then list[#list + 1] = "open" end
		return list
	end,
	each = function(unit, add)
		local T = store:tbl()
		local body, base
		if unit == "open" then body, base = concat(T.open, "\n"), T.openLo or 0
		else
			local s = T.seg[unit]
			local _, e, lo, _, _, _, hh = find(s, "^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);")
			body, base = sub(s, e + 1), un36(lo)
			if C.hash(body) ~= tonumber(hh) then return end
		end
		local r = {}
		for line in gmatch(body, "[^\n]+") do
			L.decode(line, base, r, store:dict())
			local it = r.item
			if type(it) == "number" then
				local refs = post[it]
				if not refs then refs = {}; post[it] = refs end
				if refs[#refs] ~= unit then refs[#refs + 1] = unit end
				add(it, refs)
			end
		end
	end,
})

local function readSeg(T, id)
	local s = T.seg[id]
	if type(s) ~= "string" then return nil end
	local _, e, lo, _, _, _, h = find(s, "^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);")
	if not e then store:quarantine(T, id, "seg") return nil end
	local body = sub(s, e + 1)
	if C.hash(body) ~= tonumber(h) then store:quarantine(T, id, "seg") return nil end
	return body, un36(lo)
end

M.PSS_IxDeclare({
	name = "jrn", kind = "event", owner = "journal-helper", gate = "journal", residency = 0,
	fields = FIELDS, dicts = { item = "item", ent = "ent" }, pushdown = { "time", "st", "ent", "item" },
	schemaKeys = { "wh.jrn" },
	doc = "the Journal: money and items that moved at vendors, mail, trades, taxis, trainers, quests, loot and the auction house",
	newer = function() local T = store:tbl(); return T ~= nil and type(T.v) == "number" and T.v > 1 end,
	cost = function() return #M.PSS_IxHot("jrn") + store:count() end,
	summary = function(r) return tostring(r.st) .. " " .. tostring(r.item or r.copper or "") end,
	scan = function(pd, emit)
		local r, counter = {}, { n = 0 }
		local hot = M.PSS_IxHot("jrn")
		for i = #hot, 1, -1 do
			L.decodeHot(hot[i], r)
			if wanted(pd, r.time, r.st) and keep(pd, r) then
				counter.n = counter.n + 1
				if emit(r) == false then return counter.n end
			end
		end
		local T = store:tbl()
		if not T or type(T.v) == "number" and T.v > 1 then return counter.n end
		if pd.item then
			local ids = {}
			for it in pairs(pd.item) do
				for _, ref in ipairs(postings:get(it) or {}) do ids[ref] = true end
			end
			if ids.open and type(T.open) == "table" and #T.open > 0 then
				if walk(concat(T.open, "\n"), T.openLo or 0, pd, r, emit, counter) == false then return counter.n end
			end
			local order = {}
			for ref in pairs(ids) do if ref ~= "open" then order[#order + 1] = ref end end
			sort(order, function(a, b) return a > b end)
			for _, id in ipairs(order) do
				local body, base = readSeg(T, id)
				if body and walk(body, base, pd, r, emit, counter) == false then break end
			end
			return counter.n
		end
		local stopped = false
		store:each(pd.lo, pd.hi, pd.st, function(body, base)
			if not stopped and walk(body, base, pd, r, emit, counter) == false then stopped = true end
		end)
		return counter.n
	end,
})

if M.PSS_DataDictExtend then
	M.PSS_DataDictExtend("journal-helper", { { index = "jrn", field = "st", kind = "k", values = concat(stNames, " "), doc = "jrn.<stream>" } })
end
