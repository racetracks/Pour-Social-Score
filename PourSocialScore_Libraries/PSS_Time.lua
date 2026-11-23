------------------------------------------------------------------------
-- POUR SOCIAL SCORE - TIME (search-helper, STP-00237). Server seconds
-- throughout (GetServerTime, as History.Now); calendar arithmetic on the
-- date table, never 30 * 86400.
--   local T = M.PSS_Time
--   T.now()
--   T.parse(text, now) -> seconds | nil, pos, msg   forms: now, -15m, -24h, -7d, -2w, -3mon, -1y,
--                         any of them with @s|@m|@h|@d|@w|@mon|@y (snap), @d @w @mon @y @session,
--                         YYYY-MM-DD, YYYY-MM-DDTHH:MM
--   T.span(text) -> seconds | "mon" | nil      "1h" "1d" "1w" "1mon" "15m"
--   T.bucket(t, span) -> start of t's bucket (1d at midnight, 1w on Monday, "mon" on the 1st)
--   T.weekday(t) 1 Monday .. 7 Sunday   T.hour(t)   T.month(t) -> YYYYMM
--   T.fmt(t, "short" | "day" | "month") -> local text ("" for nil)
-- History.FormatTime and History.ParseTime stay as they are. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tonumber, tostring, floor = type, tonumber, tostring, math.floor
local find, sub, match = string.find, string.sub, string.match
local date, time = date or os.date, time or os.time

local T = {}
M.PSS_Time = T

function T.now() return GetServerTime and GetServerTime() or time() end

local SECS = { s = 1, m = 60, h = 3600, d = 86400, w = 604800 }

local function dim(y, m)
	local d = ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
	if m == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then d = 29 end
	return d
end

local function mk(y, mo, d, h, mi, s)
	return time({ year = y, month = mo, day = d, hour = h or 0, min = mi or 0, sec = s or 0, isdst = false })
end

-- t moved k months, the day clamped to the month's length (31 Mar - 1mon = 28 Feb)
local function addMonths(t, k)
	local d = date("*t", t)
	local m = d.month + k
	local y = d.year + floor((m - 1) / 12)
	m = (m - 1) % 12 + 1
	local day = d.day
	local last = dim(y, m)
	if day > last then day = last end
	return mk(y, m, day, d.hour, d.min, d.sec)
end

local function snap(t, unit)
	local d = date("*t", t)
	if unit == "s" then return t end
	if unit == "m" then return mk(d.year, d.month, d.day, d.hour, d.min, 0) end
	if unit == "h" then return mk(d.year, d.month, d.day, d.hour, 0, 0) end
	if unit == "d" then return mk(d.year, d.month, d.day) end
	if unit == "w" then
		local back = (d.wday + 5) % 7		-- days since Monday
		return mk(d.year, d.month, d.day - back)
	end
	if unit == "mon" then return mk(d.year, d.month, 1) end
	if unit == "y" then return mk(d.year, 1, 1) end
	return nil
end

local UNITS = { s = true, m = true, h = true, d = true, w = true, mon = true, y = true }

function T.parse(text, now)
	if type(text) ~= "string" or text == "" then return nil, 1, "a time is needed" end
	now = now or T.now()
	if text == "now" then return now end
	if text == "@session" then
		local s = M.PSS_History and M.PSS_History.SessionStart and M.PSS_History.SessionStart() or 0
		return s
	end
	local y, mo, d, rest = match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
	if y then
		y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
		if mo < 1 or mo > 12 then return nil, 6, "month 1 to 12" end
		if d < 1 or d > dim(y, mo) then return nil, 9, "no such day" end
		if rest == "" then return mk(y, mo, d) end
		local h, mi = match(rest, "^T(%d%d):(%d%d)$")
		if not h then return nil, 11, "time of day as THH:MM" end
		h, mi = tonumber(h), tonumber(mi)
		if h > 23 or mi > 59 then return nil, 12, "no such time of day" end
		return mk(y, mo, d, h, mi)
	end
	local t, pos = now, 1
	local sign, n, unit, after = match(text, "^([%-%+])(%d+)(%a+)(.*)$")
	if sign then
		if not UNITS[unit] then return nil, 2 + #n, "unit s, m, h, d, w, mon or y" end
		n = tonumber(n) * (sign == "-" and -1 or 1)
		if unit == "mon" then t = addMonths(now, n)
		elseif unit == "y" then t = addMonths(now, 12 * n)
		else t = now + n * SECS[unit] end
		pos = 2 + #tostring(math.abs(n)) + #unit
		text = after
	end
	if text == "" then return t end
	local u = match(text, "^@(%a+)$")
	if not u or not UNITS[u] then return nil, pos, "snap @s, @m, @h, @d, @w, @mon or @y" end
	return snap(t, u)
end

function T.span(text)
	if type(text) ~= "string" then return nil end
	local n, unit = match(text, "^(%d*)(%a+)$")
	if not unit or not UNITS[unit] then return nil end
	n = tonumber(n ~= "" and n or "1")
	if n < 1 then return nil end
	if unit == "mon" then return n == 1 and "mon" or nil end
	if unit == "y" then return nil end
	return n * SECS[unit]
end

function T.bucket(t, span)
	if span == "mon" then return snap(t, "mon") end
	if span == 604800 then return snap(t, "w") end
	if span >= 86400 and span % 86400 == 0 then
		local d0 = snap(t, "d")
		local days = span / 86400
		if days == 1 then return d0 end
		local epoch = mk(1970, 1, 5)		-- a Monday: multi-day buckets line up the same way every time
		return d0 - ((floor((d0 - epoch) / 86400 + 0.5)) % days) * 86400
	end
	local d0 = snap(t, "d")
	return d0 + floor((t - d0) / span) * span
end

-- the start of the bucket after the one starting at t0
function T.nextBucket(t0, span)
	if span == "mon" then return addMonths(t0, 1) end
	if span >= 86400 then local d = date("*t", t0); return mk(d.year, d.month, d.day + span / 86400) end
	return t0 + span
end

function T.weekday(t) local d = date("*t", t); return (d.wday + 5) % 7 + 1 end
function T.hour(t) return date("*t", t).hour end
function T.month(t) local d = date("*t", t); return d.year * 100 + d.month end

local FMT = { short = "%Y-%m-%d %H:%M", day = "%Y-%m-%d", month = "%Y-%m" }
function T.fmt(t, how)
	if type(t) ~= "number" then return "" end
	return date(FMT[how] or FMT.short, t)
end

T.addMonths, T.snap, T.dim = addMonths, snap, dim
