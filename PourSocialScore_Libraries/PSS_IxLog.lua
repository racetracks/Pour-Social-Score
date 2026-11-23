------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE LOG INDEXES (search-helper, STP-00243 and
-- STP-00247). Three indexes over what PSS logs and counts:
--   log      (event, gate logging) every blocked line (st chat.block) and every act (st act.<cmp>):
--            the outbox (resident), then the block log and the per-person keep (Logging, tier 1);
--            read through History only (History.Log, History.Keep, History.For), never per line copied
--   counts   (state) one row per owner and type from the counters (the same numbers the panes show)
--   pss      (event, always) PSS's own internal lines: pss.err, pss.upg, pss.start, pss.card, pss.filter;
--            the hot ring (PourSocialScoreDB.pssHot, resident) and the segment store PSS_LoggingDB.pss
--            (SAV-00079, cap 1,000 sealed lines; Logging, tier 1)
--   M.PSS_PssLine(st, rec)   a producer's line (M.PSS_IxPut("pss", ...))
--   M.PSS_IxOnLogging()      Logging loaded: the hot ring seals into the store
--   M.PSS_IxLogStats         { forCalls } (the harness proves the owner pushdown)
-- A secret value never reaches a row (the message reads as hidden, other
-- fields are left out). Loaded with Libraries. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, tostring, tonumber, setmetatable, rawget = type, pairs, ipairs, tostring, tonumber, setmetatable, rawget
local find, sub, lower = string.find, string.sub, string.lower

local History = M.PSS_History
local L = M.PSS_Line
local HIDDEN = "(message hidden by the client)"
M.PSS_IxLogStats = { forCalls = 0 }

local ALL = {}
for _, c in ipairs(History.ALL_CATS) do ALL[c] = true end

local isSecret = M.PSS_IsSecret
local function clean(v)
	if isSecret(v) or v == nil then return nil end
	return v
end

local ACTST = setmetatable({}, { __index = function(t, cat) local v = "act." .. tostring(cat); t[cat] = v; return v end })
local function stOf(h)
	local cat = h.cat
	if h.o == cat and not ALL[cat] then return ACTST[cat] end
	return "chat.block"
end

-- an entry into the (reused) row. Saved lines never hold a secret (a secret
-- message is replaced when the line is made, History.NewEntry); the fields a
-- chat event fills are still checked, on a client that has secrets
local function fill(h, r)
	local cat, o = h.cat, h.o
	local act = o == cat and not ALL[cat]
	local ch = rawget(h, "channel")
	local m, ev, mem = h.message, rawget(h, "event"), rawget(h, "member")
	if issecretvalue then
		if isSecret(m) then m = HIDDEN end
		if isSecret(ev) then ev = nil end
		if isSecret(mem) then mem = nil end
		if isSecret(o) then o = nil end
	end
	r.time, r.ent = h.ts or 0, 0
	if act then
		r.st, r.cat, r.owner, r.channel, r.label = ACTST[cat], nil, nil, nil, ch
	else
		r.st, r.cat, r.owner, r.channel, r.label = "chat.block", cat, o, ch, nil
	end
	r.event, r.member, r.rule, r.message = ev, mem, rawget(h, "r"), m
	r.guild = rawget(h, "gk") or (not act and type(o) == "string" and sub(o, 1, 2) == "G:" and sub(o, 3)) or nil
	return r
end

local function stWanted(pd, st)
	if pd.st and not pd.st[st] then return false end
	if pd.stPrefix and sub(st, 1, #pd.stPrefix) ~= pd.stPrefix then return false end
	return true
end

local function oneOwner(pd)
	if not pd.owner then return nil end
	local only
	for k in pairs(pd.owner) do if only then return nil end only = k end
	return only
end

local LOGFIELDS = { { "time", "t", "server time of the block or act" }, { "st", "k", "chat.block or act.<component>" },
	{ "ent", "e", "the receiving character (0 for old lines)" }, { "cat", "k", "the block type" }, { "event", "s", "the client event" },
	{ "owner", "d", "who it is counted on: p:<player> g:<member> G:<guild> f:<filter>" }, { "member", "s", "the sender when the owner is a guild" },
	{ "channel", "d", "the channel" }, { "rule", "s", "the guild rule tag" }, { "message", "s", "the line's text" },
	{ "label", "s", "an act's text" }, { "guild", "d", "the guild key" } }

M.PSS_IxDeclare({
	name = "log", kind = "event", textExact = true, owner = "social-manager", gate = "logging", residency = 1, needs = "Logging",
	loaded = function() return History.Loaded() end,
	fields = LOGFIELDS, dicts = { owner = "owner", channel = "channel", event = "evt" },
	pushdown = { "time", "st", "owner" },
	schemaKeys = { "logging.blockLog", "logging.blockKeep", "core.outbox", "core.recent", "core.session", "core.sessionStart" },
	doc = "every blocked line and every act PSS performed",
	cost = function()
		local n = History.Waiting()
		if History.Loaded() then n = n + #History.Log() end
		return n
	end,
	summary = function(r)
		if sub(r.st or "", 1, 4) == "act." then return tostring(r.label or r.st) .. ": " .. tostring(r.message or "") end
		return "Blocked " .. tostring(r.cat or "?") .. " from " .. tostring(r.owner or "?") .. ": " .. tostring(r.message or "")
	end,
	scan = function(pd, emit, ctx)
		local r, n = {}, 0
		local lo, hi = pd.lo, pd.hi
		local only = oneOwner(pd)
		local stf = pd.st or pd.stPrefix
		local words = pd.text
		local nw = words and #words or 0
		local sec = issecretvalue
		local function each(h)
			if type(h) ~= "table" then return true end
			if hi and (tonumber(h.ts) or 0) > hi then return true end
			if pd.owner and not pd.owner[h.o] then return true end
			if stf and not stWanted(pd, stOf(h)) then return true end
			-- skip before fill: the haystack holds exactly the predicate's text fields as fill gives them (message, event, member, rule, label), so a line lacking a word cannot pass; the secret check and act test run only where they can change a value
			if nw > 0 then
				local m, ev, mem, ru, ch = h.message, rawget(h, "event"), rawget(h, "member"), rawget(h, "r"), rawget(h, "channel")
				if sec then
					if isSecret(m) then m = HIDDEN end
					if isSecret(ev) then ev = nil end
					if isSecret(mem) then mem = nil end
				end
				local lb = nil
				if ch ~= nil and h.o == h.cat and not ALL[h.cat] then lb = ch end
				if m == nil then m = "" elseif type(m) ~= "string" then m = tostring(m) end
				if ev == nil then ev = "" elseif type(ev) ~= "string" then ev = tostring(ev) end
				if mem == nil then mem = "" elseif type(mem) ~= "string" then mem = tostring(mem) end
				if ru == nil then ru = "" elseif type(ru) ~= "string" then ru = tostring(ru) end
				if lb == nil then lb = "" elseif type(lb) ~= "string" then lb = tostring(lb) end
				local hay = lower(m .. "\1" .. ev .. "\1" .. mem .. "\1" .. ru .. "\1" .. lb)
				for k = 1, nw do if not find(hay, words[k], 1, true) then return true end end
			end
			n = n + 1
			return emit(fill(h, r)) ~= false
		end
		-- the outbox (newest first): lines waiting for Logging
		local ob = type(PourSocialScoreDB) == "table" and rawget(PourSocialScoreDB, "outbox")
		if type(ob) == "table" then
			for i = #ob, 1, -1 do
				local h = ob[i]
				if lo and type(h) == "table" and (tonumber(h.ts) or 0) < lo then break end
				if not each(h) then return n end
			end
		end
		if not (ctx.load and History.Loaded()) then return n end
		if only then
			M.PSS_IxLogStats.forCalls = M.PSS_IxLogStats.forCalls + 1
			for _, h in ipairs(History.For(only)) do
				if lo and (tonumber(h.ts) or 0) < lo then break end
				if not each(h) then return n end
			end
			return n
		end
		local log = History.Log()
		for i = #log, 1, -1 do
			local h = log[i]
			if lo and type(h) == "table" and (tonumber(h.ts) or 0) < lo then break end
			if not each(h) then return n end
		end
		for o, list in pairs(History.Keep()) do
			for i = #list, 1, -1 do
				local h = History.UnpackLine(o, list, list[i])
				if h then
					if lo and h.ts < lo then break end
					if not each(h) then return n end
				end
			end
		end
		return n
	end,
})

------------------------------------------------------------------------
-- counts: the counters, as the panes read them (PSS_TotalsQuery.lua)
------------------------------------------------------------------------
local function countRows(emit)
	local db = PourSocialScoreDB
	local r = {}
	local function owner(key, kind, c)
		if type(key) ~= "string" or type(c) ~= "table" then return true end
		local session, day = History.RecentCounts(key)
		for _, cat in ipairs(History.ALL_CATS) do
			local v = tonumber(c[cat]) or 0
			if v > 0 then
				r.owner, r.kind, r.type, r.total, r.last24h, r.session = key, kind, cat, v, nil, nil
				if emit(r) == false then return false end
			end
		end
		r.owner, r.kind, r.type, r.total, r.last24h, r.session = key, kind, "total", c.total, day, session
		return emit(r) ~= false
	end
	for _, entry in ipairs(db.list or {}) do
		local p = M.PSS_GetPlayerRecord(entry.name)
		if p then
			local c = M.PSS_GetPlayerBlockCounts(p)
			local t = { total = History.CountTotal(c) }
			for _, cat in ipairs(History.ALL_CATS) do t[cat] = c[cat] end
			if not owner(M.PSS_PlayerHistoryKey(p), "player", t) then return end
		end
	end
	for key, g in pairs(db.guildData or {}) do
		if type(g) == "table" then
			local c = M.PSS_GetGuildBlockCounts(key)
			local t = { total = History.CountTotal(c) }
			for _, cat in ipairs(History.ALL_CATS) do t[cat] = c[cat] end
			if not owner(History.GuildKey(key), "guild", t) then return end
		end
	end
	for i = 1, #(db.filterList or {}) do
		if not (M.PSS_IsGuildRuleFilter and M.PSS_IsGuildRuleFilter(i)) then
			local b = db.filterBlocked and db.filterBlocked[i]
			local c = type(b) == "table" and b.counts or {}
			local t = { total = History.CountTotal(c) }
			for _, cat in ipairs(History.ALL_CATS) do t[cat] = tonumber(c[cat]) or 0 end
			local gap = (tonumber(db.filterCount and db.filterCount[i]) or 0) - t.total
			if gap > 0 then t.total, t.unknown = t.total + gap, t.unknown + gap end		-- as the list's all time (PSS_TotalsQuery.lua)
			if not owner(M.PSS_FilterOwnerKey(i), "filter", t) then return end
		end
	end
end

M.PSS_IxDeclare({
	name = "counts", kind = "state", owner = "social-manager", residency = 0,
	fields = { { "owner", "d", "the owner key" }, { "kind", "k", "player, guild or filter" }, { "type", "k", "a block type or total" },
		{ "total", "n", "all time" }, { "last24h", "n", "the last 24 hours (total rows)" }, { "session", "n", "since login or reload (total rows)" } },
	dicts = { owner = "owner" }, pushdown = { "owner" },
	schemaKeys = { "players.playerData", "guilds.guildData", "counts.blockStats", "counts.filterBlocked", "counts.filterCount", "counts.builtinStats" },
	doc = "the block counters per owner and type",
	cost = function() local db = PourSocialScoreDB; return #(db.list or {}) + #(db.filterList or {}) end,
	scan = function(pd, emit)
		local n = 0
		countRows(function(r)
			if pd.owner and not pd.owner[r.owner] then return true end
			n = n + 1
			return emit(r)
		end)
		return n
	end,
})

------------------------------------------------------------------------
-- pss: the internal log
------------------------------------------------------------------------
local store = M.PSS_Seg("pss", { db = "PSS_LoggingDB", key = "pss", boundary = "none", cap = { lines = 1000 } })
M.PSS_PssStore = store

function M.PSS_PssLine(st, rec) return M.PSS_IxPut("pss", st, rec) end

-- the hot ring into the store, once Logging is loaded
function M.PSS_IxOnLogging()
	if not History.Loaded() then return 0 end
	local hot = M.PSS_IxHot("pss")
	local n = 0
	for i = 1, #hot do
		local st, rec = L.hotRecord(hot[i])
		if st and store:add(st, rec) then n = n + 1 end
	end
	M.PSS_IxHot("pss", true)
	return n
end

local PSSFIELDS = { { "time", "t", "server time" }, { "st", "k", "pss.err, pss.upg, pss.start, pss.card, pss.filter" },
	{ "ent", "e", "the character" }, { "code", "k", "an error code" }, { "service", "s", "the service that failed" },
	{ "message", "s", "the text" }, { "step", "s", "an upgrade or start-up step" }, { "ok", "b", "the step finished" },
	{ "ms", "n", "how long the step took" }, { "row", "s", "a trigger row" }, { "answer", "s", "the player's answer" },
	{ "event", "s", "the chat event a filter add failed for" } }

local function linesNewestFirst(body, base, fn, pd, r)
	-- body lines are oldest first: walk them from the end
	local starts = {}
	local pos = 1
	while pos <= #body do
		starts[#starts + 1] = pos
		local nl = find(body, "\n", pos, true)
		if not nl then break end
		pos = nl + 1
	end
	for i = #starts, 1, -1 do
		local s = starts[i]
		local e = (starts[i + 1] and starts[i + 1] - 2) or #body
		local line = sub(body, s, e)
		local t = L.time(line, base)
		if not (pd.hi and t and t > pd.hi) then
			if pd.lo and t and t < pd.lo then return true end
			local st = L.st(line)
			if st and stWanted(pd, st) then
				L.decode(line, base, r, store:dict())
				if fn(r) == false then return false end
			end
		end
	end
	return true
end

M.PSS_IxDeclare({
	name = "pss", kind = "event", owner = "search-helper", residency = 1, needs = "Logging",
	loaded = function() return History.Loaded() end,
	fields = PSSFIELDS, pushdown = { "time", "st" },
	schemaKeys = { "core.pssHot", "logging.pss" },
	doc = "PSS's own internal lines: errors, upgrades, start-up faults, decision cards, filter faults",
	newer = function() local T = store:tbl(); return T ~= nil and type(T.v) == "number" and T.v > 1 end,
	cost = function() return #M.PSS_IxHot("pss") + store:count() end,
	summary = function(r) return tostring(r.st) .. " " .. tostring(r.code or r.step or r.row or r.event or "") .. ": " .. tostring(r.message or r.answer or "") end,
	scan = function(pd, emit, ctx)
		local r, n = {}, 0
		local function out(row)
			n = n + 1
			return emit(row)
		end
		local hot = M.PSS_IxHot("pss")
		for i = #hot, 1, -1 do
			L.decodeHot(hot[i], r)
			local t = r.time or 0
			if not (pd.hi and t > pd.hi) and not (pd.lo and t < pd.lo) and stWanted(pd, r.st or "") then
				if out(r) == false then return n end
			end
		end
		if not (ctx.load and History.Loaded()) then return n end
		local stopped = false
		store:each(pd.lo, pd.hi, pd.st, function(body, base)
			if not stopped and not linesNewestFirst(body, base, out, pd, r) then stopped = true end
		end)
		return n
	end,
})

-- Logging already loaded when Libraries loads: seal what waits
if History.Loaded() then M.PSS_IxOnLogging() end
