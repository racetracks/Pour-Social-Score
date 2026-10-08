------------------------------------------------------------------------
-- POUR SOCIAL SCORE - DETAIL AND PIE MATHS (for PourSocialScore_GUI)
--
-- What the window's pies and detail panes show, worked out here so the
-- window only draws (moved from the port's pane code; the numbers come from
-- the same core counts: History.RecentCounts, History.RecentByCat and
-- M.PSS_ListTotals).
--
-- Periods: this session, the last 24 hours, all time. The ticks on the
-- period pies and the type pies are shared by every pane while the window
-- is loaded: all time starts unticked (it holds the others and dwarfs
-- them), every type starts ticked.
--   M.PSS_PERIODS                         { key, text, r, g, b } x 3
--   M.PSS_PeriodOn(key) / M.PSS_SetPeriodOn(key, on)
--   M.PSS_TypeOff(cat) / M.PSS_SetTypeOff(cat, off) / M.PSS_AnyTypeOff()
--   M.PSS_WidestPeriodOn()                "day", "session" or nil (all time)
--   M.PSS_TypesOn()                       { [cat] = true } of the ticked, nil if all
--   M.PSS_SummaryValues(spec, into)       into.session / day / all
--   M.PSS_PeriodSlices(v, slices, map, pool)   the ticked periods as slices
--   M.PSS_PeriodTip(title, slice, click, typed)
--   M.PSS_TypeSlices(counts, slices [, max])   all time by type as slices
--   M.PSS_TotalsView(kind, into, guildRows)    a whole list's counts
--   M.PSS_CountsText(c)                   "Blocked 12:  Whispers 3  ..."
--   M.PSS_OVERRIDE_SHORT
--   M.PSS_OverrideOptions(), M.PSS_OverrideValue(target, key)
--   Exceptions (3.4.0.22, Dan): M.PSS_ExceptionState(target, key [, parentOpts])
--   -> happens, isException, default; M.PSS_SetException(target, scope, key,
--   happens [, parentOpts]), M.PSS_ToggleException(target, scope, key
--   [, parentOpts]); M.PSS_ExceptionText(opt, isException),
--   M.PSS_ExceptionTip(opt, who, default), M.PSS_ExceptionHeading(who)
--   M.PSS_ClassColor(class)               r, g, b (white if unknown)
--   M.PSS_HistHidden(type) / M.PSS_SetHistHidden(type, hidden)   the block
--                                         history lists' type ticks
--   M.PSS_HistFilter(all, out)            the lines of the ticked types; n
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local History = M.PSS_History

local ipairs, pairs, next, tonumber, tostring, max, min = ipairs, pairs, next, tonumber, tostring, math.max, math.min

M.PSS_PERIODS = {
	{ key = "session", text = "This session", r = 0.31, g = 0.76, b = 0.97 },
	{ key = "day", text = "Last 24 hours", r = 1.00, g = 0.72, b = 0.30 },
	{ key = "all", text = "All time", r = 0.58, g = 0.46, b = 0.80 },
}

local periodOn = { session = true, day = true, all = false }
local typeOff = {}

function M.PSS_PeriodOn(key) return periodOn[key] == true end
function M.PSS_SetPeriodOn(key, on) periodOn[key] = on and true or false end
function M.PSS_TypeOff(cat) return typeOff[cat] == true end
function M.PSS_SetTypeOff(cat, off) typeOff[cat] = off and true or nil end
function M.PSS_AnyTypeOff() return next(typeOff) ~= nil end

function M.PSS_WidestPeriodOn()
	if periodOn.all then return nil end
	if periodOn.day then return "day" end
	if periodOn.session then return "session" end
	return nil
end

function M.PSS_TypesOn()
	if next(typeOff) == nil then return nil end
	local on = {}
	for _, cat in ipairs(History.ALL_CATS or {}) do if not typeOff[cat] then on[cat] = true end end
	return on
end

-- This session / last 24 hours / all time for a pane. spec:
--   owner        the core's owner key (History.PlayerKey ...)
--   allTime      the entry's all-time count
--   counts       all time by type (a pane with a type pie: the type ticks
--                then count the ticked types only)
--   recent       { session =, day = } counted elsewhere (a default guild
--                list, a whole list), with prefix (owners whose key starts
--                with it) or recentByCat(into) for the same by type
local byCat = { session = {}, day = {} }

local function ReadByCat(spec)
	if not History.RecentByCat then return false end
	if spec.recentByCat then
		spec.recentByCat(byCat)
	elseif spec.prefix then
		History.RecentByCat(nil, byCat, spec.prefix)
	elseif spec.owner then
		History.RecentByCat(spec.owner, byCat)
	else
		return false
	end
	return true
end

function M.PSS_SummaryValues(spec, into)
	local s, d
	local all = spec.allTime or 0
	if spec.counts and next(typeOff) ~= nil and ReadByCat(spec) then
		-- some types unticked: the ticked ones only
		s, d = M.PSS_SumCats(byCat.session, typeOff), M.PSS_SumCats(byCat.day, typeOff)
		all = M.PSS_SumCats(spec.counts, typeOff)
	elseif spec.recent then
		s, d = spec.recent.session or 0, spec.recent.day or 0
	elseif spec.owner and History.RecentCounts then
		s, d = History.RecentCounts(spec.owner)
	else
		s, d = 0, 0
	end
	into.session, into.day, into.all = s or 0, d or 0, all
	return into
end

-- The ticked periods as slices. They are nested (the last 24 hours hold
-- this session, all time holds both), so each slice draws only what the
-- smaller ticked ones before it do not hold: the overlap is drawn once, in
-- the smaller slice, and lit with the bigger one on hover (within).
-- v: { session, day, all }; map[i]: the period of slice i; pool: the slice
-- tables, reused. Returns how many.
function M.PSS_PeriodSlices(v, slices, map, pool)
	for i = #slices, 1, -1 do slices[i] = nil end
	local n, inner = 0, 0
	for _, per in ipairs(M.PSS_PERIODS) do
		if periodOn[per.key] then
			n = n + 1
			local sl = pool[n] or { within = {} }
			pool[n] = sl
			local value = v[per.key] or 0
			sl.value, sl.r, sl.g, sl.b, sl.text = value, per.r, per.g, per.b, per.text
			sl.draw = max(0, value - inner)
			sl.inner = min(inner, value)
			for i in pairs(sl.within) do sl.within[i] = nil end
			for i = 1, n - 1 do sl.within[i] = true end
			sl.innerText = n > 1 and slices[n - 1].text or nil
			slices[n] = sl
			map[n] = per.key
			inner = max(inner, value)
		end
	end
	return n
end

function M.PSS_PeriodTip(title, sl, click, typed)
	local t = ("%s\n%s: %d blocked"):format(title or "", sl.text, sl.value or 0)
	if typed and next(typeOff) ~= nil then t = t .. "\n|cffaaaaaa(the types ticked below only)|r" end
	if sl.innerText and (sl.inner or 0) > 0 then
		t = t .. ("\n|cffaaaaaa%d of them also in %s (lit with it)|r"):format(sl.inner, string.lower(sl.innerText))
	end
	if click then t = t .. "\n\n|cffaaaaaaClick: these events in the Events tab.|r" end
	return t
end

local function HexColor(hex)
	hex = tostring(hex or "ffffffff")
	return (tonumber(hex:sub(3, 4), 16) or 255) / 255, (tonumber(hex:sub(5, 6), 16) or 255) / 255,
		(tonumber(hex:sub(7, 8), 16) or 255) / 255
end
M.PSS_HexColor = HexColor

-- All time by type as slices, in the core's type order, at most max (7)
-- types with a count. A type unticked draws nothing (draw = 0) but keeps
-- its count. Returns how many; slices past it are cleared.
function M.PSS_TypeSlices(counts, slices, maxN)
	maxN = maxN or 7
	local n = 0
	for _, cat in ipairs(History.ALL_CATS or {}) do
		local v = tonumber(counts and counts[cat]) or 0
		if v > 0 and n < maxN then
			n = n + 1
			local sl = slices[n] or {}
			slices[n] = sl
			sl.r, sl.g, sl.b = HexColor(History.CAT_COLOR[cat])
			sl.value, sl.text, sl.cat = v, History.CAT_LABEL[cat] or cat, cat
			sl.draw = typeOff[cat] and 0 or nil
			sl.off = typeOff[cat] == true
		end
	end
	for i = n + 1, #slices do
		local sl = slices[i]
		sl.value, sl.draw, sl.cat, sl.off = 0, nil, nil, nil
	end
	return n
end

-- A whole list's totals (a pane with nothing selected): M.PSS_ListTotals
-- plus what the summary pie needs (recent, the owners' prefix).
local LIST_PREFIX = { players = "p:", guilds = "G:", filters = "f:" }

function M.PSS_TotalsView(kind, into, guildRows)
	into = into or {}
	into.counts = M.PSS_ListTotals(kind, into.counts or {}, guildRows)
	into.recent = into.recent or {}
	into.recent.session, into.recent.day = into.counts.session, into.counts.day
	into.prefix = LIST_PREFIX[kind]
	into.total = into.counts.total or 0
	into.info = ("Blocked |cffffff00%d|r in all.  |cffaaaaaaSelect an entry to see its own.|r"):format(into.total)
	return into
end

local function Count(n, cat)
	return "|c" .. (History.CAT_COLOR[cat] or "ffffffff") .. n .. "|r"
end

function M.PSS_CountsText(c)
	return ("Blocked %d:  Whispers %s  Invites %s  Party %s  Chat %s"):format(c.total or 0,
		Count(c.whisper or 0, "whisper"), Count((c.partyInvite or 0) + (c.guildInvite or 0), "partyInvite"),
		Count(c.partyRaid or 0, "partyRaid"), Count(c.world or 0, "world"))
end

-- Per-person and per-guild exceptions to the target options: their short
-- names.
M.PSS_OVERRIDE_SHORT = {
	ignoreResponse = "Send ignore response",
	showDeclines = "Show declines",
	declineDuel = "Decline duels",
	declineTrade = "Decline trades",
}

-- The Options a player, guild or member can override (tick boxes marked
-- target), in M.PSS_OPTIONS order; one list, made on first use
local overrideOpts
function M.PSS_OverrideOptions()
	if not overrideOpts then
		overrideOpts = {}
		for _, o in ipairs(M.PSS_OPTIONS) do
			if o.target and o.kind == "bool" then overrideOpts[#overrideOpts + 1] = o end
		end
	end
	return overrideOpts
end

-- a record's override of option key (nil: the Options tab's own value)
function M.PSS_OverrideValue(target, key)
	local opts = type(target) == "table" and target.opts
	if type(opts) ~= "table" then return nil end
	return opts[key]
end

------------------------------------------------------------------------
-- Exceptions (3.4.0.22, Dan): what the Options tab sets is what happens
-- for every listed player and guild (by default: no ignore response, no
-- decline messages, duels and trades declined); a player, guild or member
-- can be an exception to any of it. A tick box shows what happens for that
-- entry (ticked = it happens); ticking it away from the default makes an
-- exception, ticking it back removes it. A member's default is its guild's
-- (parentOpts: the guild's opts). Stored as before: opts[key] = the
-- exception's value, nil = the default.
------------------------------------------------------------------------
local function Default(key, parentOpts)
	return M.PSS_Opt(key, parentOpts and { guild = parentOpts } or nil) == true
end

function M.PSS_ExceptionState(target, key, parentOpts)
	local base = Default(key, parentOpts)
	local v = M.PSS_OverrideValue(target, key)
	if v == nil or v == base then return base, false, base end
	return v == true, true, base
end

function M.PSS_SetException(target, scope, key, happens, parentOpts)
	if type(target) ~= "table" then return end
	local base = Default(key, parentOpts)
	happens = happens and true or false
	-- an Off exception is stored as false (and/or would turn it to nil)
	local v
	if happens ~= base then v = happens end
	M.PSS_SetOpt(key, scope, v, target)
end

-- a menu's tick: the other way round from what happens now
function M.PSS_ToggleException(target, scope, key, parentOpts)
	if type(target) ~= "table" then return end
	M.PSS_SetException(target, scope, key, not M.PSS_ExceptionState(target, key, parentOpts), parentOpts)
end

-- who: "this player", "this guild", "this member"
function M.PSS_ExceptionHeading(who)
	return "For " .. who .. ":  |cffaaaaaaticked = it happens|r"
end

function M.PSS_ExceptionText(opt, isException)
	return (M.PSS_OVERRIDE_SHORT[opt.key] or opt.key) .. (isException and "  |cffffd100(exception)|r" or "")
end

-- who: "this player", "this guild", "this member"
function M.PSS_ExceptionTip(opt, who, base)
	return (M.PSS_OVERRIDE_SHORT[opt.key] or opt.key) .. "\n\nTicked: it happens for " .. who .. ". For blocked players and guilds it is "
		.. (base and "|cff00ff00On|r" or "|cffff5555Off|r") .. " by default (the Options tab).\n\nChange the tick to make "
		.. who .. " an exception; set it back to remove the exception."
end

function M.PSS_ClassColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

-- The block history lists' type ticks (whisper, invite, ...), shared by
-- every list while the window is loaded: an unticked type hides its lines.
local histHidden = {}

function M.PSS_HistHidden(t) return histHidden[t] == true end
function M.PSS_SetHistHidden(t, hidden) histHidden[t] = hidden and true or nil end

function M.PSS_HistFilter(all, out)
	local n = 0
	for i = 1, #all do
		local h = all[i]
		if not histHidden[M.PSS_EventType(h)] then
			n = n + 1
			out[n] = h
		end
	end
	for i = #out, n + 1, -1 do out[i] = nil end
	return n
end
