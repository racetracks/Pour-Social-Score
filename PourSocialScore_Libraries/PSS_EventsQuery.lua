------------------------------------------------------------------------
-- POUR SOCIAL SCORE - EVENTS QUERY (3.3)
--
-- The block history logic every front end shares (issue #77): what type a
-- line is, the counted lines no longer stored, which lines a query shows,
-- and the list-wide reads and resets. In PourSocialScore_Libraries (load on
-- demand), so none of it is in memory until a window opens. Draws nothing.
--   M.PSS_EVENT_TYPES             the type words, in filter order
--   M.PSS_EventType(h)            a line's type word ("other": unknown)
--   M.PSS_ParseEventTime(text)    "YYYY-MM-DD[ HH:MM]" -> server seconds
--   M.PSS_AddExpiredEvents(lines, counts, slots, person)
--                                 adds the counted lines not in lines
--   M.PSS_PeriodSince(key)        first second of "session" / "day"
--   M.PSS_EventRange(q)           first and last second a query shows
--   M.PSS_EventMatches(q, h, find, since, upto)
--   M.PSS_SumCats(t, off)         counts by type, types in off skipped
--   M.PSS_StoredText(owner, total, who)   "Stored: ..." for a summary
--   M.PSS_GroupGuilds(k)          guild keys of a default list (or all)
--   M.PSS_GroupEvents(k)          those guilds' lines, counted rows merged
--   M.PSS_ResetGroupEvents(k)
--   M.PSS_GroupRecent(items, into)          session / day totals
--   M.PSS_GroupRecentByCat(items, into, one) the same by type
--   M.PSS_ListedPlayerEvents()    every listed player's lines
--   M.PSS_ResetListedPlayerEvents()
--   M.PSS_ResetAllGuildEvents()
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local History = M.PSS_History

local DAY = 86400

M.PSS_EVENT_TYPES = { "whisper", "invite", "party", "raid", "BG", "world", "guild" }
local CAT_TYPE = {
	whisper = "whisper",
	partyInvite = "invite",
	guildInvite = "invite",
	world = "world",
	guildChat = "guild",
}
local CHANNEL_TYPE = {
	["Raid"] = "raid", ["Raid Leader"] = "raid", ["Raid Warning"] = "raid",
	["Battleground"] = "BG", ["Battleground Leader"] = "BG",
	["Instance"] = "BG", ["Instance Leader"] = "BG",
}

-- party / raid lines split by their channel; other: an unknown category
function M.PSS_EventType(h)
	local t = CAT_TYPE[h.cat]
	if t then return t end
	if h.cat == "partyRaid" then return CHANNEL_TYPE[h.channel] or "party" end
	return "other"
end

-- "2026-10-05 13:20" -> server seconds (nil: not a date)
function M.PSS_ParseEventTime(text)
	local y, mo, d, hh, mm = tostring(text or ""):match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s+(%d%d?):(%d%d)%s*$")
	if not y then
		y, mo, d = tostring(text or ""):match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s*$")
		hh, mm = 0, 0
	end
	if not y then return nil end
	return time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
		hour = tonumber(hh), min = tonumber(mm), sec = 0 })
end

-- Blocks counted for one entry but no longer in its lines: a line per
-- type and 10 minutes for the last day (History.RecentSlots), then a line
-- per type of time unknown. Added to lines (the array read for the view).
-- person: a player / guild / member, whose world and guild chat the core
-- counts but never stores (3.2-dev3 to dev006): those say so instead of
-- "expired". From core 3.2.0-dev007 (History.LOG_ALL) they are stored.
local EXPIRED = "|cff888888Data expired from logs|r"
local NOT_STORED = "|cff888888Counted, not stored (only whispers, party / raid and invites are kept)|r"
function M.PSS_AddExpiredEvents(lines, counts, slots, person)
	local SLOT = History.SLOT or 600
	local found, foundAt = {}, {}
	for i = 1, #lines do
		local h = lines[i]
		local cat = h.cat or "unknown"
		found[cat] = (found[cat] or 0) + 1
		local s = math.floor((tonumber(h.ts) or 0) / SLOT)
		local k = cat .. "\001" .. s
		foundAt[k] = (foundAt[k] or 0) + 1
	end
	local n = #lines
	local recentGone = {}
	local function add(ts, cat, count)
		n = n + 1
		local never = person and History.KeepKind and not History.KeepKind({ cat = cat })
		local text = never and NOT_STORED or EXPIRED
		lines[n] = setmetatable({ ts = ts, cat = cat, member = "", channel = never and "Not stored" or "Expired",
			message = count > 1 and (text .. ("  |cff888888x%d|r"):format(count)) or text, expired = count,
			text = text, slotEnd = ts > 0 and ts + SLOT or nil },
			History.EntryMT)
	end
	for _, x in ipairs(slots or {}) do
		local k = x.cat .. "\001" .. math.floor(x.ts / SLOT)
		local have = foundAt[k] or 0
		local gone = x.n - have
		foundAt[k] = have > x.n and have - x.n or 0
		if gone > 0 then
			add(x.ts, x.cat, gone)
			recentGone[x.cat] = (recentGone[x.cat] or 0) + gone
		end
	end
	for _, cat in ipairs(History.ALL_CATS or {}) do
		local rest = (tonumber(counts[cat]) or 0) - (found[cat] or 0) - (recentGone[cat] or 0)
		if rest > 0 then add(0, cat, rest) end
	end
end

-- the first server second of a period (nil: all time)
function M.PSS_PeriodSince(key)
	if key == "session" then return History.SessionStart and History.SessionStart() or nil end
	if key == "day" then return History.Now() - DAY end
	return nil
end

-- the first and last second shown (nil: open ended). q.period: "session",
-- "day", "custom" (q.from, q.to) or nil (all time)
function M.PSS_EventRange(q)
	if q.period == "custom" then return q.from, q.to end
	if q.period then return M.PSS_PeriodSince(q.period), nil end
	return nil, nil
end

-- q.cats: { [cat] = true } (nil: every type); find: lower case ("": any)
function M.PSS_EventMatches(q, h, find, since, upto)
	if q.cats and not q.cats[h.cat or "unknown"] then return false end
	-- a counted row stands for its 10 minutes: in the period if they end in it
	local t = tonumber(h.slotEnd or h.ts) or 0
	if since and t < since then return false end
	if upto and (tonumber(h.ts) or 0) > upto then return false end
	if find == "" then return true end
	return string.find(string.lower(h.member or ""), find, 1, true)
		or string.find(string.lower(h.channel or ""), find, 1, true)
		or string.find(string.lower(h.message or ""), find, 1, true)
end

-- counts by type added up, the types set in off left out
function M.PSS_SumCats(t, off)
	local n = 0
	if type(t) ~= "table" then return 0 end
	for _, cat in ipairs(History.ALL_CATS or {}) do
		if not off[cat] then n = n + (tonumber(t[cat]) or 0) end
	end
	return n
end

-- "Stored: 8 kept for this player, 1 waiting, 3 not stored or expired":
-- where owner's counted blocks are (History.Where, 3.2). A filter's lines
-- are in the 2000-line log, a person's in their kept lines (3.2-dev3);
-- world chat of a person is counted, never stored. From core
-- 3.2.0-dev007 (History.LOG_ALL) every line is in the log again and a
-- person's newest are kept once trimmed off it. Before the block
-- history is loaded only the waiting lines are known.
function M.PSS_StoredText(owner, total, who)
	if not (owner and History.Where) or (total or 0) == 0 then return "" end
	local inLog, kept, waiting = History.Where(owner)
	if not inLog then
		return ("Stored: %d waiting, the rest in the block history (not loaded)."):format(waiting)
	end
	local parts = {}
	if inLog > 0 then parts[#parts + 1] = ("%d in the log"):format(inLog) end
	if kept > 0 then parts[#parts + 1] = ("%d kept for %s"):format(kept, who or "this player") end
	if waiting > 0 then parts[#parts + 1] = ("%d waiting"):format(waiting) end
	local gone = total - inLog - kept - waiting
	if gone > 0 then
		local person = History.KeepsOwner and History.KeepsOwner(owner) and History.KEEP_TOTAL and not History.LOG_ALL
		parts[#parts + 1] = ("|cffaaaaaa%d %s|r"):format(gone, person and "not stored or expired" or "expired from logs")
	end
	if #parts == 0 then return "Stored: nothing." end
	return "Stored: " .. table.concat(parts, ", ") .. "."
end

-- the guild keys of a default guild list (k = "__managed": every one)
local MANAGED = "__managed"
function M.PSS_GroupGuilds(k)
	local out = {}
	for key, g in pairs(PourSocialScoreDB.guildData or {}) do
		if type(g) == "table" and g.managed and (k == MANAGED or g.managed == k) then out[#out + 1] = key end
	end
	return out
end

-- each guild's lines and, as in a guild's own view, its blocks counted but
-- not stored (world and guild chat) or expired; the counted rows of every
-- guild merged per type and 10 minutes
function M.PSS_GroupEvents(k)
	local out, merged = {}, {}
	local keep = History.KEEP_TOTAL ~= nil and not History.LOG_ALL
	for _, key in ipairs(M.PSS_GroupGuilds(k)) do
		local lines = M.PSS_GetGuildBlockHistory(key) or {}
		local counts = M.PSS_GetGuildBlockCounts(key)
		if counts then
			M.PSS_AddExpiredEvents(lines, counts,
				History.RecentSlots and History.GuildKey and History.RecentSlots(History.GuildKey(key)), keep)
		end
		for _, h in ipairs(lines) do
			if h.expired then
				local mk = h.cat .. "\001" .. tostring(h.ts) .. "\001" .. h.channel
				local same = merged[mk]
				if same then
					same.expired = same.expired + h.expired
					same.message = same.text .. ("  |cff888888x%d|r"):format(same.expired)
				else
					merged[mk] = h
					out[#out + 1] = h
				end
			else
				out[#out + 1] = h
			end
		end
	end
	return out
end

function M.PSS_ResetGroupEvents(k)
	for _, key in ipairs(M.PSS_GroupGuilds(k)) do M.PSS_ResetGuildBlockHistory(key) end
end

-- A default guild list's session and 24 hour counts: its guilds' own
-- (History.GuildKey) added up. items: { { key = guild key }, ... }; into: reused.
function M.PSS_GroupRecent(items, into)
	into.session, into.day = 0, 0
	if not (History.RecentCounts and History.GuildKey) then return into end
	for i = 1, #items do
		local s, d = History.RecentCounts(History.GuildKey(items[i].key))
		into.session, into.day = into.session + (s or 0), into.day + (d or 0)
	end
	return into
end

-- the same by type: into.session[cat], into.day[cat]; one: a scratch table
local NONE = {}
function M.PSS_GroupRecentByCat(items, into, one)
	items = items or NONE
	for _, t in ipairs({ into.session, into.day }) do for k in pairs(t) do t[k] = 0 end end
	for i = 1, #items do
		History.RecentByCat(History.GuildKey(items[i].key), one)
		for cat, n in pairs(one.session) do into.session[cat] = (into.session[cat] or 0) + n end
		for cat, n in pairs(one.day) do into.day[cat] = (into.day[cat] or 0) + n end
	end
end

-- every listed player's lines, from the shared log
function M.PSS_ListedPlayerEvents()
	local keys = {}
	for i = 1, M.PSS_PlayerCount() do
		local e, kind = M.PSS_PlayerEntry(i)
		local k = kind == "player" and M.PSS_PlayerHistoryKey(e)
		if k then keys[k] = true end
	end
	return History.Collect(function(h) return keys[h.o] == true end)
end

function M.PSS_ResetListedPlayerEvents()
	for i = 1, M.PSS_PlayerCount() do
		local e, kind = M.PSS_PlayerEntry(i)
		if kind == "player" and M.PSS_GetPlayerRecord(e) then M.PSS_ResetPlayerBlockHistory(e) end
	end
end

function M.PSS_ResetAllGuildEvents()
	for k in pairs(PourSocialScoreDB.guildData or {}) do M.PSS_ResetGuildBlockHistory(k) end
end
