------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE CODEC (service-bus-helper, one-build plan STP-p02,
-- DEC-00275). The one way a new packed format is written and read:
--   local C = M.PSS_Codec
--   C.esc(s) / C.unesc(s)      a string with no ; , . = newline or tab in it (and back, every byte)
--   C.list(t, sep) / C.unlist  an array of strings joined by sep (default ",")
--   C.rec(t) / C.unrec         a record: fields joined by "."
--   C.map(t) / C.unmap         { k = v } as "k=v;k=v", keys sorted (the same table gives the same text)
--   C.layout(s)                "2;x" -> 2, "x"; a string with no digit prefix is layout 0
--   C.withLayout(v, body)      "v;body"
--   C.hash(s)                  a number below 2147483629 that changes with any byte or its place
--   C.header(body, n, sum)     "1;n;sum;hash;body" (the integrity header)
--   C.check(str)               ok, n, sum, body  or  false, "integrity: ..." (never raises)
-- and the export envelope (io.*, one-build plan A08):
--   M.PSS_IoPack(kind, v, body)  "PSSIO;kind;v;hash;body"
--   M.PSS_IoUnpack(text)         kind, v, body  or  nil, "integrity: ..."
--   M.PSS_IoKinds[kind] = true   a kind this version reads; an unknown kind is
--                                kept by the caller and reported, never dropped
-- Only new formats use it; the ent store keeps its own layout (DEC-00275).
-- Loaded with Libraries. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, tonumber, pairs = type, tostring, tonumber, pairs
local byte, char, gsub, find, format, sub = string.byte, string.char, string.gsub, string.find, string.format, string.sub
local concat, sort = table.concat, table.sort

local C = {}
M.PSS_Codec = C

local P = 2147483629		-- prime below 2^31: h * 31 + 255 stays exact in a double

local function hexOf(c) return format("%%%02X", byte(c)) end
local function charOf(h) return char(tonumber(h, 16)) end

function C.esc(s)
	return (gsub(tostring(s), "[%%;,%.=\n\t]", hexOf))
end

function C.unesc(s)
	return (gsub(s, "%%(%x%x)", charOf))
end

local esc, unesc = C.esc, C.unesc

function C.list(t, sep)
	sep = sep or ","
	local out = {}
	for i = 1, #t do out[i] = esc(t[i]) end
	return concat(out, sep)
end

function C.unlist(s, sep)
	sep = sep or ","
	local out, n = {}, 0
	if s == nil or s == "" then return out end
	local pos = 1
	while true do
		local at = find(s, sep, pos, true)
		n = n + 1
		if at then
			out[n] = unesc(sub(s, pos, at - 1))
			pos = at + 1
		else
			out[n] = unesc(sub(s, pos))
			break
		end
	end
	return out
end

function C.rec(t) return C.list(t, ".") end
function C.unrec(s) return C.unlist(s, ".") end

function C.map(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local out = {}
	for i = 1, #keys do out[i] = esc(keys[i]) .. "=" .. esc(t[keys[i]]) end
	return concat(out, ";")
end

function C.unmap(s)
	local out = {}
	if s == nil or s == "" then return out end
	for pair in (s .. ";"):gmatch("([^;]*);") do
		local k, v = pair:match("^([^=]*)=(.*)$")
		if k then out[unesc(k)] = unesc(v) end
	end
	return out
end

function C.layout(s)
	local v, body = s:match("^(%d+);(.*)$")
	if v then return tonumber(v), body end
	return 0, s
end

function C.withLayout(v, body)
	return v .. ";" .. body
end

-- a polynomial hash over the bytes: one changed byte, or two bytes swapped,
-- changes it. h = (h * 31 + byte) % P, four bytes per modulo, sixteen per call (the product stays
-- far below 2^53, so the result is the same as one byte at a time)
function C.hash(s)
	local h, n = 0, #s
	local i = 1
	while i + 15 <= n do
		local a, b, c, d, e, f, g, k, l, m, o, p, q, r, t, u = byte(s, i, i + 15)
		h = (h * 923521 + a * 29791 + b * 961 + c * 31 + d) % P
		h = (h * 923521 + e * 29791 + f * 961 + g * 31 + k) % P
		h = (h * 923521 + l * 29791 + m * 961 + o * 31 + p) % P
		h = (h * 923521 + q * 29791 + r * 961 + t * 31 + u) % P
		i = i + 16
	end
	while i <= n do
		h = (h * 31 + byte(s, i)) % P
		i = i + 1
	end
	return h
end

local hash = C.hash

local function count(body)
	if body == "" then return 0 end
	local _, c = gsub(body, ",", "")
	return c + 1
end

function C.header(body, n, sum)
	return "1;" .. n .. ";" .. sum .. ";" .. hash(body) .. ";" .. body
end

function C.check(str)
	if type(str) ~= "string" then return false, "integrity: not a string" end
	local v, n, sum, h, body = str:match("^(%d+);(%d+);(%d+);(%d+);(.*)$")
	if not v then return false, "integrity: no header" end
	if v ~= "1" then return false, "newer: layout " .. v end
	n, sum, h = tonumber(n), tonumber(sum), tonumber(h)
	if hash(body) ~= h then return false, "integrity: hash" end
	if count(body) ~= n then return false, "integrity: count" end
	return true, n, sum, body
end

M.PSS_IoKinds = M.PSS_IoKinds or {}

function M.PSS_IoPack(kind, v, body)
	return "PSSIO;" .. esc(kind) .. ";" .. v .. ";" .. hash(body) .. ";" .. body
end

function M.PSS_IoUnpack(text)
	if type(text) ~= "string" then return nil, "integrity: not a string" end
	local kind, v, h, body = text:match("^PSSIO;([^;]*);(%d+);(%d+);(.*)$")
	if not kind then return nil, "integrity: no envelope" end
	if hash(body) ~= tonumber(h) then return nil, "integrity: hash" end
	return unesc(kind), tonumber(v), body
end
