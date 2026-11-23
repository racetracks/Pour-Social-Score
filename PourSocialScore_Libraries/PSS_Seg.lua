------------------------------------------------------------------------
-- POUR SOCIAL SCORE - SEGMENT STORES (search-helper, STP-00234, SAV-00078).
-- An event index keeps its lines in segments: the open one (an array of
-- lines) and closed ones, each one string with a header that lets a query
-- skip it without splitting it:
--   seg[id] = "<lo36>;<hi36>;<n>;<st,st>;<hash>;<body>"   body = lines joined by newline
--   local S = M.PSS_Seg(name, { db = "PSS_LoggingDB", key = "pss", boundary = "month" | "none",
--                               lines = 500, cap = { lines = n } | { months = n | optionKey } })
--   S:append(line, time)       true | nil, "newer" | "early"   (seals at `lines` and at a new month)
--   S:seal()   S:trim()        S:each(lo, hi, stset, fn(body, base, id)) -> segments read, newest first
--   S:pin(key, lines)          a pinned segment, never trimmed
--   S:dictId(str) S:dictStr(id)   this store's dictionary (reverse map built lazily)
--   S:ver() S:count() S:size() S:drop()
-- Nothing is created until the first append (a declared store costs one
-- small table). A table with v above 1 is kept untouched: append refuses and
-- each answers nothing. A segment whose hash does not match moves to bad and
-- is noted once (integrity). No frame, no event, no timer. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tonumber, tostring, pairs, ipairs, select, setmetatable, rawget = type, tonumber, tostring, pairs, ipairs, select, setmetatable, rawget
local find, sub, gmatch = string.find, string.sub, string.gmatch
local concat, sort = table.concat, table.sort
local date, time = date or os.date, time or os.time

local C = M.PSS_Codec
local L = M.PSS_Line
local b36, un36 = L.b36, L.un36
local hash = C.hash

local S = {}
local SMT = { __index = S }
M.PSS_SegStats = { splits = 0 }		-- bodies split by each (a header skip splits none)

function M.PSS_Seg(name, spec)
	spec = spec or {}
	return setmetatable({ name = name, db = spec.db, key = spec.key, boundary = spec.boundary or "none", lines = spec.lines or 500,
		cap = spec.cap or {}, v = 0, rev = nil }, SMT)
end

function S:tbl(create)
	local db = rawget(_G, self.db)
	if type(db) ~= "table" then return nil end
	local T = rawget(db, self.key)
	if type(T) ~= "table" then
		if not create then return nil end
		T = { v = 1, seq = 0, seg = {}, open = {} }
		db[self.key] = T
	end
	return T
end

local function month(t)
	local d = date("*t", t)
	return d.year * 100 + d.month
end

local function newer(T) return type(T.v) == "number" and T.v > 1 end

function S:append(line, t)
	local T = self:tbl(true)
	if not T then return nil, "early" end
	if newer(T) then return nil, "newer" end
	T.open = T.open or {}
	if self.boundary == "month" and T.openLo and t and #T.open > 0 and month(t) ~= month(T.openLo) then self:seal() end
	if not T.openLo then T.openLo = t end
	local open = T.open
	open[#open + 1] = line
	if #open >= self.lines then self:seal() end
	self.v = self.v + 1
	return true
end

-- the base a line for time t is written against (seals the open segment first at a new month)
function S:base(t)
	local T = self:tbl(true)
	if not T then return t end
	if self.boundary == "month" and T.openLo and t and type(T.open) == "table" and #T.open > 0 and month(t) ~= month(T.openLo) then self:seal() end
	return T.openLo or t
end

-- encode a record against the open segment's base, with this store's dictionary, and append it
function S:add(st, rec)
	local T = self:tbl(true)
	if not T then return nil, "early" end
	if newer(T) then return nil, "newer" end
	local base = self:base(rec.time)
	return self:append(L.encode(st, rec, base, self:dict()), rec.time)
end

-- first and last time and the source types of a list of lines
local function scanHeader(lines, base)
	local lo, hi, sts, list = nil, nil, {}, {}
	for i = 1, #lines do
		local t = L.time(lines[i], base)
		if t then
			if not lo or t < lo then lo = t end
			if not hi or t > hi then hi = t end
		end
		local st = L.st(lines[i])
		if st and not sts[st] then sts[st] = true; list[#list + 1] = st end
	end
	sort(list)
	return lo or base or 0, hi or base or 0, concat(list, ",")
end

local function pack(lines, base)
	local body
	local lo, hi, stset = scanHeader(lines, base)
	-- the lines keep their deltas from base: the header's lo is the base a reader adds back
	local rebased = {}
	for i = 1, #lines do
		local t = L.time(lines[i], base)
		local a = find(lines[i], "\t", 1, true)
		rebased[i] = (t and b36(t - lo) or "0") .. (a and sub(lines[i], a) or "")
	end
	body = concat(rebased, "\n")
	return b36(lo) .. ";" .. b36(hi) .. ";" .. #lines .. ";" .. stset .. ";" .. hash(body) .. ";" .. body
end

function S:seal()
	local T = self:tbl()
	if not T or newer(T) or type(T.open) ~= "table" or #T.open == 0 then return end
	T.seq = (T.seq or 0) + 1
	T.first = T.first or T.seq
	T.seg = T.seg or {}
	T.seg[T.seq] = pack(T.open, T.openLo or 0)
	T.open, T.openLo = {}, nil
	self.v = self.v + 1
	self:trim()
end

local function header(s)
	local _, stop, a, b, n, sts, h = find(s, "^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);")
	if not stop then return nil end
	return stop, un36(a), un36(b), tonumber(n), sts, tonumber(h)
end

local function startOfMonthsBack(k, now)
	local d = date("*t", now)
	local m = d.month - k
	local y = d.year
	while m < 1 do m = m + 12; y = y - 1 end
	return time({ year = y, month = m, day = 1, hour = 0, min = 0, sec = 0 })
end

function S:trim()
	local T = self:tbl()
	if not T or newer(T) or type(T.seg) ~= "table" then return 0 end
	local dropped = 0
	local cap = self.cap
	if cap.lines then
		local total = 0
		for id = T.first or 1, T.seq or 0 do
			local s = T.seg[id]
			if s then local _, _, _, n = header(s); total = total + (n or 0) end
		end
		local id = T.first or 1
		while total > cap.lines and id <= (T.seq or 0) do
			local s = T.seg[id]
			if s then
				local _, _, _, n = header(s)
				T.seg[id] = nil		-- one reference dropped
				total = total - (n or 0)
				dropped = dropped + 1
			end
			id = id + 1
			T.first = id
		end
	end
	if cap.months then
		local k = cap.months
		if type(k) == "string" then k = tonumber(M.PSS_Opt and M.PSS_Opt(k)) end
		if k and k > 0 then
			local edge = startOfMonthsBack(k, GetServerTime and GetServerTime() or time())
			local id = T.first or 1
			while id <= (T.seq or 0) do
				local s = T.seg[id]
				local hi
				if s then hi = select(3, header(s)) end
				if hi and hi >= edge then break end
				if s then T.seg[id] = nil; dropped = dropped + 1 end
				id = id + 1
				T.first = id
			end
		end
	end
	if dropped > 0 then self.v = self.v + 1 end
	return dropped
end

function S:quarantine(T, id, where)
	T.bad = T.bad or {}
	T.bad[#T.bad + 1] = T[where][id]
	T[where][id] = nil
	self.v = self.v + 1
	if M.PSS_ErrNote then M.PSS_ErrNote("integrity", "seg." .. tostring(self.name), "a segment failed its hash check and was set aside") end
end

local function overlap(sts, want)
	if not want then return true end
	for st in gmatch(sts, "[^,]+") do if want[st] then return true end end
	return false
end

local function visit(self, T, where, id, s, lo, hi, want, fn)
	local stop, slo, shi, n, sts, h = header(s)
	if not stop or not slo or not shi or not h then self:quarantine(T, id, where) return 0, nil end
	if (hi and slo > hi) or (lo and shi < lo) or not overlap(sts, want) then return 0, shi end
	local body = sub(s, stop + 1)
	M.PSS_SegStats.splits = M.PSS_SegStats.splits + 1
	if hash(body) ~= h then self:quarantine(T, id, where) return 0, shi end
	fn(body, slo, id)
	return 1, shi
end

-- newest first: the open segment, then closed ones from the newest, then pins
function S:each(lo, hi, want, fn)
	local T = self:tbl()
	if not T or newer(T) then return 0 end
	local read = 0
	if type(T.open) == "table" and #T.open > 0 then
		local base = T.openLo or 0
		local lines = T.open
		local tlo, thi = L.time(lines[1], base), L.time(lines[#lines], base)
		if not ((hi and tlo and tlo > hi) or (lo and thi and thi < lo)) then
			fn(concat(lines, "\n"), base, "open")
			read = 1
		end
	end
	if type(T.seg) == "table" then
		for id = T.seq or 0, T.first or 1, -1 do
			local s = T.seg[id]
			if type(s) == "string" then
				local r, shi = visit(self, T, "seg", id, s, lo, hi, want, fn)
				read = read + r
				if lo and shi and shi < lo then break end		-- older segments are older still
			elseif s ~= nil then
				self:quarantine(T, id, "seg")
			end
		end
	end
	if type(T.pin) == "table" then
		for key, s in pairs(T.pin) do
			if type(s) == "string" then read = read + visit(self, T, "pin", key, s, lo, hi, want, fn) end
		end
	end
	return read
end

-- the open part's lines replaced by fn(lines, base) (a list in the same encoding); closed segments stay as they are
function S:rewriteOpen(fn)
	local T = self:tbl()
	if not T or newer(T) or type(T.open) ~= "table" then return nil end
	local out = fn(T.open, T.openLo or 0)
	if type(out) ~= "table" then return nil end
	T.open = out
	if #out == 0 then T.openLo = nil end
	self.v = self.v + 1
	return true
end

function S:pin(key, lines)
	local T = self:tbl(true)
	if not T or newer(T) then return nil, "newer" end
	T.pin = T.pin or {}
	if not lines or #lines == 0 then T.pin[key] = nil else T.pin[key] = pack(lines, 0) end		-- pinned lines carry absolute times
	self.v = self.v + 1
	return true
end

function S:dictId(str)
	local T = self:tbl(true)
	if not T then return 0 end
	T.dict = T.dict or {}
	local rev = self.rev
	if not rev then
		rev = {}
		for id, s in pairs(T.dict) do rev[s] = id end
		self.rev = rev
	end
	local id = rev[str]
	if not id then
		T.dn = (T.dn or 0) + 1
		id = T.dn
		T.dict[id] = str
		rev[str] = id
	end
	return id
end

function S:dictStr(id)
	local T = self:tbl()
	return T and T.dict and T.dict[id]
end

-- the dictionary object L.encode / L.decode take
function S:dict()
	local me = self
	self.dobj = self.dobj or { id = function(s) return me:dictId(s) end, str = function(n) return me:dictStr(n) end }
	return self.dobj
end

function S:ver() return self.v end

function S:count()
	local T = self:tbl()
	if not T then return 0 end
	local n = type(T.open) == "table" and #T.open or 0
	for _, s in pairs(T.seg or {}) do
		if type(s) == "string" then local _, _, _, k = header(s); n = n + (k or 0) end
	end
	return n
end

function S:size()
	local T = self:tbl()
	if not T then return 0 end
	local n = 0
	for _, l in ipairs(T.open or {}) do n = n + #l + 1 end
	for _, s in pairs(T.seg or {}) do if type(s) == "string" then n = n + #s end end
	return n
end

function S:drop() self.rev = nil end
