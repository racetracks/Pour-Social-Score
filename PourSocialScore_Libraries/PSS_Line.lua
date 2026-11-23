------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE LINE CODEC (search-helper, STP-00233, DDS-00031
-- section 5). One line of an event index:
--   "<t36>\t<st>\t<ent>\t<field>\t<field>..."
-- t36 is the time as a base 36 delta from the segment's base (a leading "-"
-- when the clock moved back), st the source type, ent the entity id; then
-- the source type's fields by position, by kind: n c e i a base 10 number,
-- b "1" or empty, s escaped text (M.PSS_Codec), d a dictionary id (or "~"
-- and the escaped text without a dictionary), t a base 36 delta, k a code.
-- Trailing empty fields are dropped; a line is at most 1,024 bytes (the
-- longest text field is cut on a character boundary).
--   local L = M.PSS_Line
--   L.type(st, spec)                 spec = { index, fields = { { name, kind }, ... } }; true | nil, why
--   L.encode(st, rec, base, dict?)   -> line
--   L.decode(line, base, out, dict?) -> out (time, st, ent and the fields; an unknown st: raw)
--   L.time(line, base)  L.st(line)  L.hasText(line, lowerNeedle)
--   L.decodeHot(line, out)           a core hot line (PSS_IxPut.lua) into out
-- dict is { id = function(str) -> n, str = function(n) -> str }. Never raises
-- on decode. No frame, no event. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, tonumber, pairs, ipairs = type, tostring, tonumber, pairs, ipairs
local find, sub, lower, byte, gsub, char = string.find, string.sub, string.lower, string.byte, string.gsub, string.char
local concat, floor = table.concat, math.floor

local C = M.PSS_Codec
local esc, unesc = C.esc, C.unesc
local L = { types = {}, MAX = 1024 }
M.PSS_Line = L

local DIG = "0123456789abcdefghijklmnopqrstuvwxyz"
local digit = {}
for i = 1, 36 do digit[i - 1] = sub(DIG, i, i) end

local function b36(n)
	n = floor(n)
	if n == 0 then return "0" end
	local neg = n < 0
	if neg then n = -n end
	local out, i = {}, 0
	while n > 0 do
		i = i + 1
		out[i] = digit[n % 36]
		n = floor(n / 36)
	end
	local s = {}
	for k = i, 1, -1 do s[#s + 1] = out[k] end
	return (neg and "-" or "") .. concat(s)
end
L.b36 = b36

-- tonumber(s, 36) with a sign (Lua 5.1 reads "-x" in base 36 as unsigned)
local function un36(s)
	if s == nil or s == "" then return nil end
	if byte(s, 1) == 45 then
		local v = tonumber(sub(s, 2), 36)
		return v and -v
	end
	return tonumber(s, 36)
end
L.un36 = un36

local NUMK = { n = true, c = true, e = true, i = true }

function L.type(st, spec)
	if type(st) ~= "string" or not find(st, "^[a-z]+%.[a-z0-9]+$") then return nil, "name: a source type is <index>.<name> in lower case" end
	if #st > 16 then return nil, "name: longer than 16 bytes" end
	if type(spec) ~= "table" or type(spec.fields) ~= "table" or #spec.fields > 12 then return nil, "fields: a list of at most 12" end
	for _, f in ipairs(spec.fields) do
		if type(f[1]) ~= "string" or not M.PSS_IX_FKINDS[f[2]] then return nil, "fields: " .. tostring(f[1]) end
	end
	L.types[st] = spec
	return true
end

local function num(v)
	v = tonumber(v)
	if not v then return "" end
	if v == floor(v) then return tostring(floor(v)) end
	return tostring(v)
end

local function field(kind, v, base, dict)
	if v == nil then return "" end
	if NUMK[kind] then
		if type(v) == "number" then return num(v) end
		return "~" .. esc(v)		-- an item key or a name where a number was expected
	elseif kind == "b" then
		return (v and v ~= 0 and v ~= "") and "1" or ""
	elseif kind == "t" then
		v = tonumber(v)
		return v and b36(v - (base or 0)) or ""
	elseif kind == "d" then
		if dict then return tostring(dict.id(tostring(v))) end
		return "~" .. esc(v)
	end
	return esc(v)		-- s, k
end

-- cut s at most n bytes, never inside an escape (%XX) or a UTF-8 sequence
local function cutText(s, n)
	if #s <= n then return s end
	local at = n
	while at > 0 do
		local b = byte(s, at + 1)
		if b and b >= 128 and b < 192 then at = at - 1 else break end
	end
	return sub(s, 1, at)
end
L.cutText = cutText

function L.encode(st, rec, base, dict)
	local spec = L.types[st]
	base = base or 0
	local parts = { b36((rec.time or 0) - base), st, num(rec.ent or 0) }
	local fs = spec and spec.fields or {}
	local raw = {}
	for i = 1, #fs do
		local f = fs[i]
		local v = rec[f[1]]
		if f[2] == "s" and v ~= nil then v = tostring(v) end
		raw[i] = v
		parts[3 + i] = field(f[2], v, base, dict)
	end
	local last = #parts
	while last > 3 and parts[last] == "" do parts[last] = nil; last = last - 1 end
	local line = concat(parts, "\t")
	-- over the cap: cut the longest text field until it fits
	local guard = 0
	while #line > L.MAX and guard < 16 do
		guard = guard + 1
		local best, bl = nil, -1
		for i = 1, #fs do
			if fs[i][2] == "s" and raw[i] and #raw[i] > bl then best, bl = i, #raw[i] end
		end
		if not best then break end
		local over = #line - L.MAX
		local esc1 = parts[3 + best]
		local keep = #raw[best] - over - (#esc1 - #raw[best]) - 1
		if keep < 0 then keep = 0 end
		raw[best] = cutText(raw[best], keep)
		parts[3 + best] = field("s", raw[best], base, dict)
		line = concat(parts, "\t")
	end
	return line
end

local function value(kind, s, base, dict)
	if s == nil or s == "" then return nil end
	if (NUMK[kind] or kind == "d") and byte(s, 1) == 126 then return unesc(sub(s, 2)) end		-- "~": text kept without a dictionary
	if NUMK[kind] then return tonumber(s) end
	if kind == "b" then return 1 end
	if kind == "t" then local d = un36(s); return d and (base or 0) + d end
	if kind == "d" then
		local id = tonumber(s)
		if dict and id then return dict.str(id) end
		return id
	end
	return unesc(s)
end

-- fills out; the fields of the last source type decoded into it are cleared first
function L.decode(line, base, out, dict)
	out = out or {}
	local prev = out.__f
	if prev then for i = 1, #prev do out[prev[i][1]] = nil end end
	out.raw, out.__f = nil, nil
	if type(line) ~= "string" then out.time, out.st, out.ent = nil, nil, nil return out end
	local a = find(line, "\t", 1, true)
	local t = a and sub(line, 1, a - 1) or line
	local d = un36(t)
	out.time = d and (base or 0) + d or nil
	if not a then out.st, out.ent = nil, nil return out end
	local b = find(line, "\t", a + 1, true)
	out.st = sub(line, a + 1, (b or 0) - 1)
	if not b then out.ent = nil return out end
	local c = find(line, "\t", b + 1, true)
	out.ent = tonumber(sub(line, b + 1, (c or 0) - 1))
	local spec = L.types[out.st]
	if not spec then
		out.raw = c and unesc(sub(line, c + 1)) or nil
		return out
	end
	local fs = spec.fields
	out.__f = fs
	local pos, i = c, 0
	while pos and i < #fs do
		i = i + 1
		local nx = find(line, "\t", pos + 1, true)
		local s = sub(line, pos + 1, (nx or 0) - 1)
		out[fs[i][1]] = value(fs[i][2], s, base, dict)
		pos = nx
	end
	return out
end

function L.time(line, base)
	local a = find(line, "\t", 1, true)
	local d = un36(a and sub(line, 1, a - 1) or line)
	return d and (base or 0) + d
end

function L.st(line)
	local a = find(line, "\t", 1, true)
	if not a then return nil end
	local b = find(line, "\t", a + 1, true)
	return sub(line, a + 1, (b or 0) - 1)
end

function L.hasText(line, needle)
	return find(lower(line), needle, 1, true) ~= nil
end

-- a hot line from core: "<time>\t<st>\t<ent>\t<k>=<v>..." (absolute time, base 10)
local function hexOf(h) return char(tonumber(h, 16)) end
local function unhot(s) return (gsub(s, "%%(%x%x)", hexOf)) end
function L.decodeHot(line, out)
	out = out or {}
	local prev = out.__f
	if prev then for i = 1, #prev do out[prev[i][1]] = nil end end
	out.raw, out.__f = nil, nil
	local t, st, ent, rest = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
	out.time, out.st, out.ent = tonumber(t), st, tonumber(ent)
	local spec = st and L.types[st]
	local kinds = {}
	if spec then
		out.__f = spec.fields
		for _, f in ipairs(spec.fields) do kinds[f[1]] = f[2] end
	end
	for pair in (rest or ""):gmatch("[^\t]+") do
		local k, v = pair:match("^([^=]*)=(.*)$")
		if k then
			k, v = unhot(k), unhot(v)
			local kind = kinds[k]
			if kind and NUMK[kind] then v = tonumber(v) or v
			elseif kind == "b" then v = (v ~= "" and v ~= "false" and v ~= "0") and 1 or nil
			elseif kind == "t" then v = tonumber(v) end
			if kind then out[k] = v else out.raw = (out.raw and out.raw .. " " or "") .. k .. "=" .. tostring(v) end
		end
	end
	return out
end

-- the hot line as a record (for sealing it into a store with L.encode)
function L.hotRecord(line)
	local r = L.decodeHot(line, {})
	r.__f = nil
	return r.st, r
end

------------------------------------------------------------------------
-- The source types of phase A
------------------------------------------------------------------------
local ACT = { { "event", "s" }, { "label", "s" }, { "message", "s" } }
L.type("chat.block", { index = "log", counts = true, fields = { { "cat", "k" }, { "event", "s" }, { "owner", "d" }, { "member", "s" },
	{ "channel", "d" }, { "rule", "s" }, { "message", "s" }, { "guild", "d" } } })
for _, cmp in ipairs({ "dtt", "wh", "bag", "addons", "gfx", "macro", "upgrade" }) do L.type("act." .. cmp, { index = "log", fields = ACT }) end
L.type("pss.err", { index = "pss", fields = { { "code", "k" }, { "service", "s" }, { "message", "s" } } })
L.type("pss.upg", { index = "pss", fields = { { "step", "n" }, { "ok", "b" }, { "ms", "n" } } })
L.type("pss.start", { index = "pss", fields = { { "step", "s" }, { "message", "s" } } })
L.type("pss.card", { index = "pss", fields = { { "row", "s" }, { "answer", "s" } } })
L.type("pss.filter", { index = "pss", fields = { { "event", "s" }, { "message", "s" } } })
