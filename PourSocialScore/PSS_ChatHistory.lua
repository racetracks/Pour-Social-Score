------------------------------------------------------------------------
-- POUR SOCIAL SCORE - BLOCK HISTORY (one module for every list)
--
-- The Player Ignore List, the Guild Ignore List (per member) and the Chat
-- Filters (per filter) all keep their block history the same way:
--
--   history = { entry, entry, ... }        newest first, capped
--   counts  = { whisper=, partyInvite=, guildInvite=, partyRaid=, world=,
--               guildChat=, unknown=, total= }
--   entry   = { ts      = server time (number, 0 = unknown),
--               time    = "02 Oct 2026 14:31:05" or "Unknown",
--               cat     = whisper | partyInvite | guildInvite | partyRaid |
--                         world | guildChat | unknown,
--               kind    = label of cat ("Whisper", "World Chat", ...),
--               member  = sender ("Name-Realm") or "Unknown",
--               event   = CHAT_MSG_* / PARTY_INVITE / GUILD_INVITE or nil,
--               channel = "2. Trade - City", "Whisper", ... or "Unknown",
--               message = text ("" for invites) }
--
-- and show it the same way: the block history table (sortable Who-style
-- columns, right-click a line for options), the in-place Block History
-- panel used by each tab (All / Reset / Close on the bar) and the Block
-- History popup window.
--
-- Older data is migrated when it is read: entries from earlier builds get
-- their category, timestamp and channel filled in, and anything that was
-- never recorded is set to "Unknown". The chat filters' old 50-slot ring
-- buffer ({ m, s, t, c, n }) is converted to the list above once.
------------------------------------------------------------------------
local addonName, addon = ...
local M = addon.M
local V = addon.V
local L = addon.L

local History = {}
M.PSS_History = History

local UNKNOWN = "Unknown"
History.UNKNOWN = UNKNOWN
-- Categories shown in counts (in this order) and their labels/colours.
History.CAT_ORDER = { "whisper", "partyInvite", "partyRaid", "world", "guildInvite" }
History.CAT_LABEL = {
	whisper = "Whisper", partyInvite = "Party Invite", partyRaid = "Party/Raid",
	world = "World Chat", guildInvite = "Guild Invite", guildChat = "Guild Chat", unknown = UNKNOWN,
}
History.CAT_COLOR = {
	whisper = "ffffff00", partyInvite = "ffff9933", partyRaid = "ff66ccff",
	world = "ff99ff99", guildInvite = "ffcc99ff", guildChat = "ff40ff40", unknown = "ff9d9d9d",
}
local CAT_LABEL, CAT_COLOR, CAT_ORDER = History.CAT_LABEL, History.CAT_COLOR, History.CAT_ORDER
local ALL_CATS = { "whisper", "partyInvite", "guildInvite", "partyRaid", "world", "guildChat", "unknown" }
History.ALL_CATS = ALL_CATS

-- entry -> where it came from ("Guild rule: X", "Filter: Y"); tooltips only,
-- weak keys, never saved
History.sourceLabel = setmetatable({}, { __mode = "k" })
function History.SetSource(h, label) if type(h) == "table" then History.sourceLabel[h] = label end end

------------------------------------------------------------------------
-- Time
------------------------------------------------------------------------
local TIME_FMT = "%d %b %Y %H:%M:%S"
local MONTHS = { Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6, Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12 }

function History.Now() return GetServerTime and GetServerTime() or time() end
function History.FormatTime(ts)
	ts = tonumber(ts)
	if not ts or ts <= 0 then return UNKNOWN end
	return date(TIME_FMT, ts)
end

-- "02 Oct 2026 14:31:05" (current) or "2026.10.02 14:31:05" (old chat
-- filter history) -> server time, or nil.
function History.ParseTime(s)
	if type(s) ~= "string" or not time then return nil end
	local d, mon, y, hh, mm, ss = s:match("^(%d+) (%a+) (%d+) (%d+):(%d+):(%d+)")
	if d and MONTHS[mon] then
		return time({ year = tonumber(y), month = MONTHS[mon], day = tonumber(d), hour = tonumber(hh), min = tonumber(mm), sec = tonumber(ss) })
	end
	local Y, Mo, D, H, Mi, S = s:match("^(%d+)%.(%d+)%.(%d+) (%d+):(%d+):(%d+)")
	if Y then
		return time({ year = tonumber(Y), month = tonumber(Mo), day = tonumber(D), hour = tonumber(H), min = tonumber(Mi), sec = tonumber(S) })
	end
	return nil
end
M.PSS_ParseTimeString = History.ParseTime

------------------------------------------------------------------------
-- Entries
------------------------------------------------------------------------
local KIND_TO_CAT = {
	["Whisper"] = "whisper", ["Private Message"] = "whisper",
	["Group Invite"] = "partyInvite", ["Party Invite"] = "partyInvite",
	["Guild Invite"] = "guildInvite",
	["Party/Raid"] = "partyRaid",
	["World Chat"] = "world", ["Other"] = "world",
	["Guild Chat"] = "guildChat",
	[UNKNOWN] = "unknown",
}

-- Counting bucket for a core category (achievements, notices... count as
-- world chat, as before).
function History.Bucket(cat)
	if cat == "other" then return "world" end
	if CAT_LABEL[cat] then return cat end
	return "unknown"
end

-- Fill in everything a history line needs. Idempotent; used to migrate
-- entries written by older builds (which only had kind/event/time).
function History.Normalize(h)
	if type(h) ~= "table" then return nil end
	if not h.cat or not CAT_LABEL[h.cat] then
		local cat = KIND_TO_CAT[h.kind]
		if not cat and h.event and M.PSS_EventCategory then cat = M.PSS_EventCategory(h.event) end
		h.cat = History.Bucket(cat)
	end
	h.ts = tonumber(h.ts) or History.ParseTime(rawget(h, "time")) or 0
	-- "time" and "kind" are worked out from ts / cat when shown (see EntryMT);
	-- not stored, which saves two strings per line
	h.time, h.kind = nil, nil
	setmetatable(h, History.EntryMT)
	if type(h.channel) ~= "string" or h.channel == "" then
		if h.cat == "partyInvite" then h.channel = "Party Invite"
		elseif h.cat == "guildInvite" then h.channel = "Guild Invite"
		elseif type(h.event) == "string" and h.event ~= "" and M.PSS_ChannelLabel then h.channel = M.PSS_ChannelLabel(h.event)
		else h.channel = UNKNOWN end
	end
	if type(h.member) ~= "string" or h.member == "" then h.member = nil end		-- caller may know the owner
	h.message = tostring(h.message or "")
	return h
end
M.PSS_NormalizeBlockEntry = History.Normalize

-- A new line. cat: core category; channel: label (built from the event when nil).
function History.NewEntry(cat, event, message, channel, member)
	if M.PSS_IsSecret and M.PSS_IsSecret(message) then message = "(message hidden by the client)" end
	local ts = History.Now()
	local h = {
		ts = ts,
		cat = History.Bucket(cat), event = event,
		channel = channel, member = member,
		message = tostring(message or ""),
	}
	return History.Normalize(h)
end

function History.EmptyCounts()
	local c = { total = 0 }
	for _, k in ipairs(ALL_CATS) do c[k] = 0 end
	return c
end

function History.EnsureCounts(c)
	if type(c) ~= "table" then c = {} end
	for _, k in ipairs(ALL_CATS) do c[k] = tonumber(c[k]) or 0 end
	-- total is never less than the categories added up (older member
	-- counters were saved with total = 0)
	local sum = 0
	for _, k in ipairs(ALL_CATS) do sum = sum + c[k] end
	c.total = math.max(tonumber(c.total) or 0, sum)
	return c
end

------------------------------------------------------------------------
-- THE SHARED BLOCK LOG
--
-- Every blocked line is ONE entry in one list, PourSocialScoreDB.blockLog
-- (oldest first), capped at the Options setting "Block history lines kept
-- in total" (default 2,000). However many people get blocked, the history
-- never grows past that. Each entry names its owner:
--   o = "p:<key>"   Player Ignore List entry
--   o = "g:<key>"   guild member (by character, so it follows them when they
--                   are moved to another guild rule)
--   o = "f:<id>"    chat filter (built-in id, or "f:t:<filter text>")
--   r = "<id>"      also counted on this guild rule (managed guild groups)
-- Views (a player, a guild, a member, a filter, "all ...") are filtered
-- from the log and the per-player keep (below). The per-type blocked COUNTS
-- stay on each owner and are totals: they are never cut, and no history
-- line (log or keep) is ever counted again.
------------------------------------------------------------------------
History.DEFAULT_TOTAL, History.MIN_TOTAL, History.MAX_TOTAL = 2000, 100, 20000

function History.Cap()
	local v = tonumber(M.PSS_Opt and M.PSS_Opt("historyTotal"))
	if not v then return History.DEFAULT_TOTAL end
	v = math.floor(v)
	if v < History.MIN_TOTAL then return History.MIN_TOTAL end
	if v > History.MAX_TOTAL then return History.MAX_TOTAL end
	return v
end
History.Max = History.Cap		-- (older name)

-- time / kind are worked out when read
History.EntryMT = { __index = function(h, k)
	if k == "time" then return History.FormatTime(rawget(h, "ts"))
	elseif k == "kind" then return CAT_LABEL[rawget(h, "cat") or "unknown"] or UNKNOWN end
end }

------------------------------------------------------------------------
-- ON DEMAND (3.0): the log and the keep are saved by
-- PourSocialScore_Logging, which is not loaded at login. History.Log and
-- History.Keep load it first. A block only adds a line: until Logging is
-- loaded the line waits in PourSocialScoreDB.outbox (the counts are always
-- loaded, so they are counted at once). When Logging loads, the waiting
-- lines join the log, the log is trimmed to the setting and the history is
-- tidied. With many lines waiting, Logging loads by itself at a quiet moment
-- (out of combat, outside instances).
------------------------------------------------------------------------
local OUTBOX_LOAD = 200		-- waiting lines that make Logging load
local ready = false
local keepsOwner		-- (PER-PLAYER KEEP below)

function History.Loaded() return ready end
M.PSS_LoggingReady = History.Loaded

function History.Waiting()
	local ob = type(PourSocialScoreDB) == "table" and rawget(PourSocialScoreDB, "outbox")
	return type(ob) == "table" and #ob or 0
end

function M.PSS_LoadLogging()
	if ready then return true end
	if not (M.PSS_Need and M.PSS_Need("Logging")) then return false end
	ready = true
	-- route its keys, move any PourSocialScoreDB still holds (a 2.0 save)
	if M.PSS_PrepareSavedData then M.PSS_PrepareSavedData() end
	local db = PourSocialScoreDB
	local ob = type(db) == "table" and rawget(db, "outbox")
	-- the saved log (3.2.0-dev007) back into the log and the keep, and
	-- saves of 3.2.0-dev3 to dev006: people's kept lines back in the log
	-- (once), so it holds the newest lines of everyone again (both in
	-- PourSocialScore_Logging/PSS_SavedLog.lua, loaded with the data)
	if History.UnpackSaved then History.UnpackSaved() end
	if History.KeepToLog and type(db) == "table" and not rawget(db, "logAllV1") then History.KeepToLog() end
	if type(ob) == "table" then
		local log = History.Log()
		for i = 1, #ob do
			local e = ob[i]
			if type(e) == "table" then
				setmetatable(e, History.EntryMT)
				log[#log + 1] = e
			end
		end
		rawset(db, "outbox", nil)
	end
	History.CapKeep(true)
	History.Trim(true)
	if M.PSS_TidyBlockHistory then M.PSS_TidyBlockHistory() end
	return true
end

local loadQueued = false
local function loadWhenQuiet()
	if ready then loadQueued = false return end
	if (InCombatLockdown and InCombatLockdown()) or (IsInInstance and IsInInstance()) then
		C_Timer.After(30, loadWhenQuiet)
		return
	end
	loadQueued = false
	M.PSS_LoadLogging()
end

local attached = setmetatable({}, { __mode = "k" })
function History.Log()
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return {} end
	if not ready and not M.PSS_LoadLogging() then return {} end
	local log = db.blockLog
	if type(log) ~= "table" then log = {}; db.blockLog = log end
	if not attached[log] then
		-- saved entries come back without their metatable
		for i = 1, #log do if type(log[i]) == "table" then setmetatable(log[i], History.EntryMT) end end
		attached[log] = true
	end
	return log
end

------------------------------------------------------------------------
-- PER-PLAYER KEEP (3.2)
--
-- Every blocked line goes in the shared log first (3.2.0-dev007, as before
-- 3.2.0-dev3): players, guild members, chat filters, world and guild chat
-- too, the newest History.Cap() (2,000) of them. When a listed player's or
-- guild member's line (owner "p:" / "g:", managed default lists included)
-- is trimmed off the log, their newest
--   10 whispers and party / raid / instance / battleground lines,
--   5 party invites, 5 guild invites
-- move to PourSocialScoreDB.blockKeep; the rest (world chat, guild chat
-- ...) is let go. The whole keep holds at most KEEP_TOTAL (2000) lines:
-- past that the oldest go first, whoever they belong to. A line is in
-- exactly ONE place (log or keep); the block counters live on the owners
-- and are never worked out from lines.
--
-- Packed (3.2): one string a line, the person's name and guild once a list:
--   blockKeep = { ["p:<key>" | "g:<key>"] = {
--       m = name, gk = guild rule key, r = Chat Filters rule tag,
--       [1..n] = "<type><ts>\t<event>\t<channel>\t<message>" (oldest first) } }
--   type: w whisper, p party/raid, i party invite, g guild invite
--   event: one letter for the usual events (KEPT_EVENTS), else the name
--   channel: empty when it is the event's usual label
-- About a third of the memory of a table a line (bench in check_growth's
-- notes: 2000 lines 285 KB against 960 KB). Lines are unpacked into entry
-- tables only to be shown (History.For / Collect / KeptLines).
-- Saves of 3.2.0-dev3 to dev006 (people's lines kept out of the log) are
-- put back when Logging loads (History.KeepToLog, once, in
-- PourSocialScore_Logging/PSS_SavedLog.lua), then the log is trimmed and
-- what leaves it settles into the keep. How the log and the keep are
-- saved: the same file.
------------------------------------------------------------------------
History.KEEP = { text = 10, party = 5, guild = 5 }
History.KEEP_TOTAL = 2000
-- every blocked line is stored (in the log) until it is trimmed (3.2.0-dev007)
History.LOG_ALL = true
local KEEP = History.KEEP
local KEEP_KIND = { whisper = "text", partyRaid = "text", partyInvite = "party", guildInvite = "guild" }
local CAT_CODE = { whisper = "w", partyRaid = "p", partyInvite = "i", guildInvite = "g" }
local CODE_CAT = { w = "whisper", p = "partyRaid", i = "partyInvite", g = "guildInvite" }
-- kind of a packed line by its first byte
local BYTE_KIND = {}
for cat, code in pairs(CAT_CODE) do BYTE_KIND[code:byte()] = KEEP_KIND[cat] end
-- append only: the letters are saved
local KEPT_EVENTS = {
	"CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
	"CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
	"CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
	"CHAT_MSG_BATTLEGROUND", "CHAT_MSG_BATTLEGROUND_LEADER", "PARTY_INVITE", "GUILD_INVITE",
	-- 3.2.0-dev007: the other blocked events, for the saved log
	"CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
	"CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_COMMUNITIES_CHANNEL", "CHAT_MSG_WHISPER_INFORM",
	"CHAT_MSG_AFK", "CHAT_MSG_DND",
}
local EVENT_LETTER, LETTER_EVENT = {}, {}
for i, e in ipairs(KEPT_EVENTS) do
	local c = string.char(64 + i)
	EVENT_LETTER[e], LETTER_EVENT[c] = c, e
end
local keepTotal			-- lines in the keep (nil: count them again)
-- for the saved log (PourSocialScore_Logging/PSS_SavedLog.lua)
History.EventLetter, History.LetterEvent = EVENT_LETTER, LETTER_EVENT
function History.KeepChanged() keepTotal = nil end

-- text | party | guild, nil: never kept (world chat, guild chat, ...)
function History.KeepKind(h)
	return KEEP_KIND[h.cat]
end
local keepKind = History.KeepKind

-- "p:..." or "g:..." (a person); byte compare, no new strings
function keepsOwner(o)
	if type(o) ~= "string" then return false end
	local a, b = o:byte(1, 2)
	return b == 58 and (a == 112 or a == 103)
end
History.KeepsOwner = keepsOwner

-- the label shown when a line stores none
local function usualChannel(cat, event)
	if cat == "partyInvite" then return "Party Invite" end
	if cat == "guildInvite" then return "Guild Invite" end
	if type(event) == "string" and event ~= "" and M.PSS_ChannelLabel then return M.PSS_ChannelLabel(event) end
	return UNKNOWN
end

-- entry -> packed line (nil: a kind never kept); the name / guild / rule
-- go on the list
local function pack(h, list)
	local code = CAT_CODE[h.cat]
	if not code then return nil end
	local ev = h.event
	ev = type(ev) == "string" and (EVENT_LETTER[ev] or ev:gsub("\t", " ")) or ""
	local ch = h.channel
	if type(ch) ~= "string" or ch == usualChannel(h.cat, h.event) then ch = "" else ch = ch:gsub("\t", " ") end
	if list then
		if type(h.member) == "string" then list.m = h.member end
		if h.gk ~= nil then list.gk = h.gk end
		if h.r ~= nil then list.r = h.r end
	end
	return code .. math.floor(tonumber(h.ts) or 0) .. "\t" .. ev .. "\t" .. ch .. "\t" .. tostring(h.message or "")
end
History.PackLine = pack
History.UsualChannel = usualChannel

-- packed line -> a new entry table (for showing)
local function unpackLine(o, list, s)
	local code, ts, ev, ch, msg = s:match("^(.)(%d*)\t([^\t]*)\t([^\t]*)\t(.*)$")
	if not code then return nil end
	local cat = CODE_CAT[code] or "unknown"
	ev = LETTER_EVENT[ev] or ev
	return setmetatable({
		ts = tonumber(ts) or 0, cat = cat, event = ev,
		channel = ch ~= "" and ch or usualChannel(cat, ev), message = msg,
		member = list.m, o = o, gk = list.gk, r = list.r,
	}, History.EntryMT)
end
History.UnpackLine = unpackLine

-- the time of a packed line
local function lineTs(s)
	local t = s:find("\t", 2, true)
	return t and tonumber(s:sub(2, t - 1)) or 0
end

function History.Keep()
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return {} end
	if not ready and not M.PSS_LoadLogging() then return {} end
	local keep = db.blockKeep
	if type(keep) ~= "table" then keep = {}; db.blockKeep = keep end
	if not attached[keep] then
		for o, list in pairs(keep) do
			if type(list) ~= "table" or not keepsOwner(o) then
				keep[o] = nil
			else
				-- older builds kept entry tables: packed here; lines of a
				-- kind no longer kept are let go
				local j = 0
				for i = 1, #list do
					local h = list[i]
					list[i] = nil
					if type(h) == "table" then h = pack(h, list)
					elseif type(h) ~= "string" or not BYTE_KIND[h:byte(1) or 0] then h = nil end
					if h then j = j + 1; list[j] = h end
				end
				if j == 0 then keep[o] = nil end
			end
		end
		attached[keep] = true
		History.CapKeep(true)
	end
	return keep
end

-- A person's kept lines as entries, oldest first (for showing).
function History.KeptLines(o)
	local list = o and History.Keep()[o]
	local out = {}
	if list then
		for i = 1, #list do out[#out + 1] = unpackLine(o, list, list[i]) end
	end
	return out
end

-- At most KEEP_TOTAL kept lines: the oldest go first. Done in batches (when
-- the keep is 5 % over, or always with force) like the log.
function History.CapKeep(force)
	local keep = PourSocialScoreDB.blockKeep
	if type(keep) ~= "table" then keepTotal = 0 return 0 end
	local cap, n = History.KEEP_TOTAL, 0
	for _, list in pairs(keep) do n = n + #list end
	keepTotal = n
	if n <= cap or (not force and n <= cap + math.floor(cap / 20)) then return 0 end
	-- lines older than the cut go (and enough of those at the cut)
	local ts, k = {}, 0
	for _, list in pairs(keep) do
		for i = 1, #list do k = k + 1; ts[k] = lineTs(list[i]) end
	end
	table.sort(ts)
	local drop = n - cap
	local cut = ts[drop]			-- the newest time that goes
	local atCut = 0				-- how many lines at exactly `cut` go
	for i = drop, 1, -1 do if ts[i] == cut then atCut = atCut + 1 else break end end
	for o, list in pairs(keep) do
		local j, m = 0, #list
		for i = 1, m do
			local s = list[i]
			local t = lineTs(s)
			local go = t < cut
			if t == cut and atCut > 0 then go = true; atCut = atCut - 1 end
			if not go then j = j + 1; list[j] = s end
		end
		for i = m, j + 1, -1 do list[i] = nil end
		if j == 0 then keep[o] = nil end
	end
	keepTotal = cap
	return drop
end

-- Store a person's line in their keep: their newest lines of each kind
-- (KEEP), the oldest of that kind goes. Nothing for a kind never kept.
function History.KeepAdd(h)
	local k = KEEP_KIND[h.cat]
	if not k then return false end
	local keep = History.Keep()
	local o = h.o
	local list = keep[o]
	if not list then list = {}; keep[o] = list end
	list[#list + 1] = pack(h, list)
	local have, first = 0, nil
	for i = #list, 1, -1 do
		if BYTE_KIND[list[i]:byte(1)] == k then have = have + 1; first = i end
	end
	if not keepTotal then History.CapKeep() end
	if have > KEEP[k] then
		table.remove(list, first)
	else
		keepTotal = keepTotal + 1
		if keepTotal > History.KEEP_TOTAL + math.floor(History.KEEP_TOTAL / 20) then History.CapKeep(true) end
	end
	return true
end

-- Older saves: people's lines leave the log for their keep (newest of each
-- kind kept, the rest let go). Returns how many lines left the log.
function History.MovePeople()
	local log = History.Log()
	local moved, owners, n, j = {}, nil, 0, 0
	for i = 1, #log do
		local h = log[i]
		if keepsOwner(h.o) then
			n = n + 1; moved[n] = h
			owners = owners or {}; owners[h.o] = true
		else
			j = j + 1; log[j] = h
		end
	end
	for i = #log, j + 1, -1 do log[i] = nil end
	if owners then History.SettleKeep(owners, moved, n) end
	return n
end

-- Work out the keep of `owners` (set of owner keys) again: their kept lines
-- plus `dropped` (entries taken off the log), newest first, as long as the
-- person has room for that kind once their log lines are counted.
-- Everything else is let go.
function History.SettleKeep(owners, dropped, n)
	local keep, log = History.Keep(), History.Log()
	local used, cand = {}, {}
	for o in pairs(owners) do
		used[o] = {}
		local list = keep[o]
		if not list then list = {}; keep[o] = list end
		local c = {}
		for i = 1, #list do c[i] = list[i] end
		cand[o] = c
	end
	for i = 1, #log do
		local h = log[i]
		local u = used[h.o]
		if u then
			local k = keepKind(h)
			if k then u[k] = (u[k] or 0) + 1 end
		end
	end
	for i = 1, (n or 0) do
		local h = dropped[i]
		local c = cand[h.o]
		if c then
			local s = pack(h, keep[h.o])
			if s then c[#c + 1] = s end
		end
	end
	for o, c in pairs(cand) do
		-- oldest first (kept and moved lines can interleave); stable
		local pos = {}
		for i = 1, #c do pos[c[i]] = pos[c[i]] or i end
		table.sort(c, function(a, b)
			local x, y = lineTs(a), lineTs(b)
			if x ~= y then return x < y end
			return pos[a] < pos[b]
		end)
		local u, out = used[o], {}
		for i = #c, 1, -1 do
			local s = c[i]
			local k = BYTE_KIND[s:byte(1)]
			local have = k and u[k] or 0
			if k and have < KEEP[k] then u[k] = have + 1; out[#out + 1] = s end
		end
		local list, m = keep[o], #out
		for i = #list, 1, -1 do list[i] = nil end
		if m == 0 then
			keep[o] = nil
		else
			for i = 1, m do list[i] = out[m - i + 1] end
		end
	end
	keepTotal = nil
end

-- Settle every kept person (after a tidy-up or a cleared history).
function History.SettleAllKeep()
	local owners
	for o in pairs(History.Keep()) do owners = owners or {}; owners[o] = true end
	if owners then History.SettleKeep(owners) end
end

-- Number of kept lines and people.
function History.KeepSize()
	local lines, people = 0, 0
	for _, list in pairs(History.Keep()) do lines = lines + #list; people = people + 1 end
	return lines, people
end

-- fn(entry) for every line, log first (oldest first), then the keep (kept
-- lines unpacked; a change of r / gk is written back to the person's list).
function History.Each(fn)
	local log = History.Log()
	for i = 1, #log do fn(log[i]) end
	for o, list in pairs(History.Keep()) do
		for i = 1, #list do
			local h = unpackLine(o, list, list[i])
			if h then
				fn(h)
				if h.r ~= list.r then list.r = h.r end
				if h.gk ~= list.gk then list.gk = h.gk end
			end
		end
	end
end

-- Keep the newest `cap` lines. Done in batches (when the log is 5 % over)
-- so adding a line never shifts the whole list.
function History.Trim(force)
	local log = History.Log()
	local cap = History.Cap()
	local n = #log
	if n <= cap or (not force and n <= cap + math.max(20, math.floor(cap / 20))) then return 0 end
	local drop = n - cap
	local dropped, owners = {}, nil
	for i = 1, drop do
		local h = log[i]
		dropped[i] = h
		if keepsOwner(h.o) then owners = owners or {}; owners[h.o] = true end
	end
	for i = 1, cap do log[i] = log[i + drop] end
	for i = cap + 1, n do log[i] = nil end
	-- a player's newest lines move to the keep (not copied)
	if owners then History.SettleKeep(owners, dropped, drop); History.CapKeep() end
	-- no cleanup request here: about 100 lines (~30 KB) leave at a time, and
	-- a busy channel trims often; a cycle walks the whole game heap
	return drop
end
History.TrimAll = function() return History.Trim(true) end
M.PSS_TrimAllHistory = History.TrimAll

-- Add a line for an owner, count it on `counts`. Returns the entry.
function History.Add(owner, counts, entry, ruleTag)
	entry.o = owner
	if ruleTag then entry.r = ruleTag end
	if counts then
		counts[entry.cat] = (tonumber(counts[entry.cat]) or 0) + 1
		counts.total = (tonumber(counts.total) or 0) + 1
	end
	History.CountRecent(owner, entry.ts, entry.cat)
	if not ready then
		-- Logging is not loaded: the line waits (never loads it per line)
		local db = PourSocialScoreDB
		if type(db) ~= "table" then return entry end
		local ob = rawget(db, "outbox")
		if type(ob) ~= "table" then ob = {}; rawset(db, "outbox", ob) end
		ob[#ob + 1] = entry
		-- never more waiting than the log holds (the oldest would be trimmed)
		if #ob > History.Cap() then table.remove(ob, 1) end
		if #ob >= OUTBOX_LOAD and not loadQueued then
			loadQueued = true
			C_Timer.After(1, loadWhenQuiet)
		end
		return entry
	end
	local log = History.Log()
	log[#log + 1] = entry
	History.Trim(false)
	return entry
end

------------------------------------------------------------------------
-- RECENT COUNTS (3.2): blocks per owner in this session and in the last
-- 24 hours, for the Summary pie, without PourSocialScore_Logging (the
-- lines themselves stay in the log). Kept in PourSocialScoreDB next to the
-- outbox, so a /reload keeps them:
--   recent  = { v = 2, last = newest slot,
--               day  = { [owner] = blocks in the last 24 hours },
--               [1..144] = { [cat] = { [owner] = blocks } } }
--             a slot is 10 minutes of server time; slot s is kept at
--             s % 144 + 1, its blocks by type (cat: whisper, partyInvite,
--             ...) and owner. When the time moves on, the slots that left
--             the day are taken off `day` and emptied, once per 10 minutes.
--             A slot table exists only while something was blocked in it, a
--             type only while it has blocks, and an owner is in it once
--             however often it blocked.
--             A lookup is one index (day[owner]).
--   session = { [owner] = count }, emptied at each login and /reload and
--   not saved past logout (3.2.0-dev006); sessionStart = when it began
-- A guild rule is counted on its members and on History.GuildKey(gkey).
------------------------------------------------------------------------
local SLOT = 600
local DAY_SLOTS = 144
local UNKNOWN_CAT = "unknown"
History.SLOT, History.DAY_SLOTS = SLOT, DAY_SLOTS

function History.GuildKey(gkey) return gkey and ("G:" .. tostring(gkey)) or nil end

-- Take one slot off the day and empty it.
local function drop(r, day, i)
	local t = r[i]
	if not t then return end
	for _, owners in pairs(t) do
		for owner, c in pairs(owners) do
			local n = (day[owner] or 0) - c
			day[owner] = n > 0 and n or nil
		end
	end
	r[i] = nil
end

-- The recent table, brought up to slot cur (create: made when missing).
local function recent(cur, create)
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return nil end
	local r = rawget(db, "recent")
	if type(r) ~= "table" or type(r.day) ~= "table" or r.v ~= 2 then
		-- none yet, or the untyped layout of 3.2.0-dev1 (a day of test data)
		if type(r) == "table" then rawset(db, "recent", nil) end
		if not create then return nil end
		r = { v = 2, last = cur, day = {} }
		rawset(db, "recent", r)
		return r
	end
	local last = tonumber(r.last) or cur
	if cur > last then
		local day = r.day
		if cur - last >= DAY_SLOTS then
			for i = 1, DAY_SLOTS do r[i] = nil end
			r.day = {}
		else
			for s = last + 1, cur do drop(r, day, s % DAY_SLOTS + 1) end
		end
		r.last = cur
	end
	return r
end

-- this session's blocks by type and owner: sessionCat[cat][owner] (never
-- saved, like the session; by type first, so an owner blocked once costs
-- one key, not a table)
local sessionCat = {}

-- One block of type cat for owner at server time ts (now when unknown).
function History.CountRecent(owner, ts, cat)
	if owner == nil then return end
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return end
	local se = rawget(db, "session")
	if type(se) ~= "table" then se = {}; rawset(db, "session", se) end
	ts = tonumber(ts) or 0
	-- the session counts its own blocks (a line from before it is not)
	if ts <= 0 or ts >= History.SessionStart() then
		se[owner] = (se[owner] or 0) + 1
		local k = cat or UNKNOWN_CAT
		local c = sessionCat[k]
		if not c then c = {}; sessionCat[k] = c end
		c[owner] = (c[owner] or 0) + 1
	end
	local cur = math.floor(History.Now() / SLOT)
	local slot = math.floor(ts / SLOT)
	if slot <= 0 or slot > cur then slot = cur end
	if slot <= cur - DAY_SLOTS then return end
	local r = recent(cur, true)
	local i = slot % DAY_SLOTS + 1
	local t = r[i]
	if not t then t = {}; r[i] = t end
	cat = cat or UNKNOWN_CAT
	local owners = t[cat]
	if not owners then owners = {}; t[cat] = owners end
	owners[owner] = (owners[owner] or 0) + 1
	r.day[owner] = (r.day[owner] or 0) + 1
end

-- This session's and the last 24 hours' blocks of owner.
function History.RecentCounts(owner)
	if owner == nil then return 0, 0 end
	local db = PourSocialScoreDB
	local se = type(db) == "table" and rawget(db, "session")
	local r = recent(math.floor(History.Now() / SLOT), false)
	return type(se) == "table" and se[owner] or 0, r and r.day[owner] or 0
end

-- This session's and the last 24 hours' blocks of every owner whose key
-- starts with prefix ("p:" players, "G:" guilds, "f:" chat filters), added
-- up. Walks the owners once; for showing, not per block.
function History.RecentTotals(prefix)
	if type(prefix) ~= "string" then return 0, 0 end
	local db = PourSocialScoreDB
	local se = type(db) == "table" and rawget(db, "session")
	local r = recent(math.floor(History.Now() / SLOT), false)
	local s, d = 0, 0
	if type(se) == "table" then
		for owner, n in pairs(se) do
			if type(owner) == "string" and string.find(owner, prefix, 1, true) == 1 then s = s + n end
		end
	end
	if r then
		for owner, n in pairs(r.day) do
			if type(owner) == "string" and string.find(owner, prefix, 1, true) == 1 then d = d + n end
		end
	end
	return s, d
end

-- For History.RecentByCat (PourSocialScore_Libraries, PSS_TotalsQuery.lua):
-- this session's blocks by type and owner, and the recent table brought up
-- to now (nil: none). Read only.
function History.RecentByCatData()
	return sessionCat, recent(math.floor(History.Now() / SLOT), false)
end

-- The last day's blocks of owner by 10 minutes and type, newest first:
-- out[n] = { ts = start of the 10 minutes, cat = type, n = blocks } (a new
-- array, for showing). Nothing when owner has no block in the day.
function History.RecentSlots(owner)
	local out = {}
	if owner == nil then return out end
	local cur = math.floor(History.Now() / SLOT)
	local r = recent(cur, false)
	if not (r and r.day[owner]) then return out end
	for s = cur, cur - DAY_SLOTS + 1, -1 do
		local t = r[s % DAY_SLOTS + 1]
		if t then
			for cat, owners in pairs(t) do
				local c = owners[owner]
				if c then out[#out + 1] = { ts = s * SLOT, cat = cat, n = c } end
			end
		end
	end
	return out
end

-- Where owner's lines are: in the log, in the keep (a person's own lines
-- after they left the log) and waiting for Logging (the outbox). The log and
-- the keep are only known once Logging is loaded (nil before; this never
-- loads it). Walks the log: for showing one entry, not per block.
function History.Where(owner)
	local db = PourSocialScoreDB
	local waiting = 0
	local ob = type(db) == "table" and rawget(db, "outbox")
	if type(ob) == "table" then
		for i = 1, #ob do if type(ob[i]) == "table" and ob[i].o == owner then waiting = waiting + 1 end end
	end
	if not ready then return nil, nil, waiting end
	local log, inLog = History.Log(), 0
	for i = 1, #log do if log[i].o == owner then inLog = inLog + 1 end end
	local kept = History.Keep()[owner]
	return inLog, kept and #kept or 0, waiting
end

-- The server time this session started (its blocks are the ones since).
function History.SessionStart()
	local db = PourSocialScoreDB
	return type(db) == "table" and tonumber(rawget(db, "sessionStart")) or 0
end

-- Forget owner's recent counts (its block history or count was reset).
function History.ForgetRecent(owner)
	if owner == nil then return end
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return end
	local se = rawget(db, "session")
	if type(se) == "table" then se[owner] = nil end
	for _, c in pairs(sessionCat) do c[owner] = nil end
	local r = rawget(db, "recent")
	if type(r) ~= "table" or type(r.day) ~= "table" or not r.day[owner] then return end
	r.day[owner] = nil
	for i = 1, DAY_SLOTS do
		local t = r[i]
		if t then
			for cat, owners in pairs(t) do
				if owners[owner] then
					owners[owner] = nil
					if next(owners) == nil then t[cat] = nil end
				end
			end
			if next(t) == nil then r[i] = nil end
		end
	end
end

-- At login or /reload a new session starts (3.2.0-dev006); a loading
-- screen keeps it. The day is brought up to now and dropped when empty.
function History.StartSession(initialLogin, reloading)
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return end
	if initialLogin or reloading or not tonumber(rawget(db, "sessionStart")) then
		rawset(db, "session", nil)
		sessionCat = {}
		rawset(db, "sessionStart", History.Now())
	end
	local r = recent(math.floor(History.Now() / SLOT), false)
	if r and next(r.day) == nil then rawset(db, "recent", nil) end
end

-- Logout or /reload: the session ends, so its counts are not saved (the
-- next load starts a new one).
function History.EndSession()
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return end
	rawset(db, "session", nil)
	rawset(db, "sessionStart", nil)
	sessionCat = {}
end

-- Newest-first list of the lines where pred(entry) is true (a new array:
-- for showing, not for keeping).
-- Kept lines come after the log lines (they are older).
local function byTimeDesc(a, b)
	if (a.ts or 0) ~= (b.ts or 0) then return (a.ts or 0) > (b.ts or 0) end
	return tostring(a.o or "") < tostring(b.o or "")
end
function History.Collect(pred)
	local log, out = History.Log(), {}
	for i = #log, 1, -1 do
		local h = log[i]
		if h and pred(h) then out[#out + 1] = h end
	end
	local older, owners = nil, 0
	for o, list in pairs(History.Keep()) do
		local hit = false
		for i = #list, 1, -1 do
			local h = unpackLine(o, list, list[i])
			if h and pred(h) then older = older or {}; older[#older + 1] = h; hit = true end
		end
		if hit then owners = owners + 1 end
	end
	if older then
		local mixed = #out > 0
		if owners > 1 and not mixed then table.sort(older, byTimeDesc) end
		for i = 1, #older do out[#out + 1] = older[i] end
		-- log and kept lines interleave in time since 3.2
		if mixed then table.sort(out, byTimeDesc) end
	end
	return out
end
function History.For(owner)
	local log, out = History.Log(), {}
	for i = #log, 1, -1 do
		local h = log[i]
		if h.o == owner then out[#out + 1] = h end
	end
	local kept = owner and History.Keep()[owner]
	if kept then
		for i = #kept, 1, -1 do
			local h = unpackLine(owner, kept, kept[i])
			if h then out[#out + 1] = h end
		end
	end
	return out
end
function History.CountFor(owner)
	local log, n = History.Log(), 0
	for i = 1, #log do if log[i].o == owner then n = n + 1 end end
	local kept = owner and History.Keep()[owner]
	return n + (kept and #kept or 0)
end

-- Remove the lines where pred(entry) is true.
function History.Clear(pred)
	local log = History.Log()
	local j, n = 0, #log
	for i = 1, n do
		local h = log[i]
		if not pred(h) then j = j + 1; log[j] = h end
	end
	for i = j + 1, n do log[i] = nil end
	local removed = n - j
	local keep = History.Keep()
	for o, list in pairs(keep) do
		local k, m = 0, #list
		for i = 1, m do
			local s = list[i]
			local h = unpackLine(o, list, s)
			if h and not pred(h) then k = k + 1; list[k] = s end
		end
		for i = k + 1, m do list[i] = nil end
		if k == 0 then keep[o] = nil end
		removed = removed + m - k
	end
	keepTotal = nil
	if removed > 0 and M.PSS_RequestGC then M.PSS_RequestGC("history cleared") end
	return removed
end

-- owner keys
function History.PlayerKey(name)
	local c = M.PSS_CanonPlayer and M.PSS_CanonPlayer(name)
	return c and ("p:" .. c) or nil
end
function History.MemberKey(m)
	if type(m) ~= "table" then return nil end
	local c = M.PSS_CanonPlayer and (M.PSS_CanonPlayer(m._playerKey) or M.PSS_CanonPlayer(m.name))
	return c and ("g:" .. c) or nil
end
function History.FilterKey(id, text)
	if type(id) == "string" and id ~= "" then return "f:" .. id end
	return "f:t:" .. tostring(text or "")
end

-- Approximate memory of the log (for /pss mem): bytes.
local EST_KEYS = { "message", "channel", "member", "event", "o", "r" }
function History.EstimateBytes()
	local bytes, lines = 0, 0
	local log = History.Log()
	for i = 1, #log do
		local h = log[i]
		lines = lines + 1
		bytes = bytes + 120		-- table + 6-8 fields
		for j = 1, #EST_KEYS do
			local v = rawget(h, EST_KEYS[j])
			if type(v) == "string" then bytes = bytes + 24 + #v end
		end
	end
	-- kept lines: one string each (and a slot), the list once a person
	for _, list in pairs(History.Keep()) do
		bytes = bytes + 80
		for i = 1, #list do lines = lines + 1; bytes = bytes + 16 + 24 + #list[i] end
	end
	return bytes, #log, lines
end

------------------------------------------------------------------------
-- Tidy-up (every login, after the upgrades): drop lines whose owner is no
-- longer part of the addon, and tags that point at something gone.
--   alive.p / alive.g / alive.f (o, h) -> true while that listed player /
--                       guild member / chat filter still exists
--   alive.rule(id)    -> true while that Chat Filters rule exists (h.r)
--   alive.guild(gkey) -> true while that guild rule exists (h.gk)
-- A kind of owner with no check is left alone. Counters are not touched.
------------------------------------------------------------------------
function History.Tidy(alive)
	local removed = History.Clear(function(h)
		if type(h) ~= "table" or type(h.o) ~= "string" then return true end
		local t = h.o:sub(1, 1)
		local check = alive[t]
		return check ~= nil and not check(h.o, h)
	end)
	History.Each(function(h)
		if h.r ~= nil and alive.rule and not alive.rule(h.r) then h.r = nil end
		if h.gk ~= nil and alive.guild and not alive.guild(h.gk) then h.gk = nil end
		-- fields of older builds (worked out when shown)
		if rawget(h, "time") ~= nil or rawget(h, "kind") ~= nil then h.time, h.kind = nil, nil end
	end)
	History.SettleAllKeep()
	return removed
end

------------------------------------------------------------------------
-- One-time move of the old per-person / per-filter lists into the log.
-- sources = { { list = {...}, owner = "p:..." , member = name }, ... }
------------------------------------------------------------------------
function History.Absorb(sources)
	local log = History.Log()
	local all = {}
	for i = 1, #log do all[#all + 1] = log[i] end
	for _, src in ipairs(sources) do
		for _, h in ipairs(src.list or {}) do
			if type(h) == "table" and History.Normalize(h) then
				h.o = h.o or src.owner
				h.member = h.member or src.member
				all[#all + 1] = h
			end
		end
	end
	-- oldest first; stable for equal times
	local pos = {}
	for i, h in ipairs(all) do pos[h] = i end
	table.sort(all, function(a, b)
		if (a.ts or 0) ~= (b.ts or 0) then return (a.ts or 0) < (b.ts or 0) end
		return pos[a] < pos[b]
	end)
	PourSocialScoreDB.blockLog = all
	attached[all] = true
	History.Trim(true)
	return #PourSocialScoreDB.blockLog
end

-- Counts rebuilt from a list (migration).
function History.CountList(list)
	local c = History.EmptyCounts()
	for _, h in ipairs(list or {}) do
		if History.Normalize(h) then c[h.cat] = c[h.cat] + 1; c.total = c.total + 1 end
	end
	return c
end

function History.Sig(h)
	return tostring(h.ts or 0) .. "\1" .. tostring(h.time or "") .. "\1" .. tostring(h.event or "") ..
			"\1" .. tostring(h.message or "") .. "\1" .. tostring(h.cat or "")
end

-- Union of two lists, de-duplicated (copies), newest first, capped.
function History.MergeLists(a, b)
	local max = History.Max()
	local seen, merged = {}, {}
	for _, list in ipairs({ a or {}, b or {} }) do
		for _, h in ipairs(list) do
			local sig = History.Sig(h)
			if not seen[sig] then
				seen[sig] = true
				local copy = {}
				for k, v in pairs(h) do copy[k] = v end
				merged[#merged + 1] = copy
			end
		end
	end
	table.sort(merged, function(x, y) return (x.ts or 0) > (y.ts or 0) end)
	while #merged > max do table.remove(merged) end
	return merged
end

-- Several lists -> one newest-first list (for "all players / guilds /
-- filters" views). sourceFn(list) gives the tooltip label, ownerName the
-- sender when a line does not name one.
function History.Combine(parts)
	local out = {}
	for _, p in ipairs(parts) do
		for _, h in ipairs(p.list or {}) do
			if History.Normalize(h) then
				h.member = h.member or p.owner or UNKNOWN
				if p.source then History.SetSource(h, p.source) end
				out[#out + 1] = h
			end
		end
	end
	table.sort(out, function(a, b)
		if (a.ts or 0) ~= (b.ts or 0) then return (a.ts or 0) > (b.ts or 0) end
		return tostring(a.member or "") < tostring(b.member or "")
	end)
	return out
end

-- "Whispers: 3  Party Invites: 0 ..." summary line.
function History.FormatCounts(c)
	c = c or {}
	local function part(cat, label)
		return "|cffaaaaaa" .. label .. ":|r |c" .. CAT_COLOR[cat] .. (c[cat] or 0) .. "|r"
	end
	local s = part("whisper", "Whispers") .. "    " .. part("partyInvite", "Party Invites") .. "    " ..
				part("partyRaid", "Party/Raid") .. "    " .. part("world", "World Chat")
	if (c.guildInvite or 0) > 0 then s = s .. "    " .. part("guildInvite", "Guild Invites") end
	if (c.guildChat or 0) > 0 then s = s .. "    " .. part("guildChat", "Guild Chat") end
	if (c.unknown or 0) > 0 then s = s .. "    " .. part("unknown", UNKNOWN) end
	return s
end
M.PSS_FormatGuildCounts = History.FormatCounts
M.PSS_FormatBlockCounts = History.FormatCounts

------------------------------------------------------------------------
-- Chat filter history migration
------------------------------------------------------------------------
-- old: ring buffer of { m = message, s = sender, t = "YYYY.MM.DD HH:MM:SS",
--                       c = channel number, n = channel/event name }
-- with filterBlockedLast = index of the newest slot.
local OLD_CHANNEL_CAT = {
	WHISPER = "whisper", BN_WHISPER = "whisper",
	PARTY = "partyRaid", PARTY_LEADER = "partyRaid", RAID = "partyRaid", RAID_LEADER = "partyRaid",
	RAID_WARNING = "partyRaid", INSTANCE_CHAT = "partyRaid", INSTANCE_CHAT_LEADER = "partyRaid",
	BATTLEGROUND = "partyRaid", BATTLEGROUND_LEADER = "partyRaid",
	SAY = "world", YELL = "world", EMOTE = "world", TEXT_EMOTE = "world", CHANNEL = "world",
	COMMUNITIES_CHANNEL = "world", AFK = "world", DND = "world",
	GUILD = "guildChat", OFFICER = "guildChat",
}

local function isOldFilterEntry(e)
	return type(e) == "table" and e.cat == nil and (e.m ~= nil or e.s ~= nil or e.t ~= nil)
end

function History.MigrateOldFilterEntry(e)
	local chNum = tonumber(e.c) or 0
	local name = type(e.n) == "string" and e.n ~= "" and e.n or nil
	local cat, channel, event
	if chNum > 0 then
		cat = "world"
		channel = name and (chNum .. ". " .. name) or (chNum .. ". " .. UNKNOWN)
		event = "CHAT_MSG_CHANNEL"
	elseif name then
		local key = name:upper()
		cat = OLD_CHANNEL_CAT[key] or "unknown"
		event = OLD_CHANNEL_CAT[key] and ("CHAT_MSG_" .. key) or nil
		channel = (event and M.PSS_ChannelLabel and M.PSS_ChannelLabel(event)) or name
	else
		cat, channel = "unknown", UNKNOWN
	end
	local ts = History.ParseTime(e.t) or 0
	return History.Normalize({
		ts = ts, time = ts > 0 and History.FormatTime(ts) or UNKNOWN,
		cat = cat, event = event, channel = channel,
		member = (type(e.s) == "string" and e.s ~= "") and e.s or UNKNOWN,
		message = tostring(e.m or ""),
	})
end

-- Returns the filter's history in the current format (a list with a
-- .counts table), converting the old ring buffer when needed.
-- lists already in the current format this session (weak: no leak)
local migratedLists = setmetatable({}, { __mode = "k" })

function History.MigrateFilterList(list, last)
	if type(list) ~= "table" then list = {} end
	-- checked once per session, not on every blocked line
	if migratedLists[list] and type(list.counts) == "table" then return list end
	local old = false
	for _, e in ipairs(list) do if isOldFilterEntry(e) then old = true break end end
	if not old then
		list.counts = History.EnsureCounts(list.counts)
		if list.counts.total == 0 and #list > 0 then list.counts = History.CountList(list) end
		migratedLists[list] = true
		return list
	end
	-- ring order: newest at `last`, going backwards, then wrapping
	local total = #list
	last = tonumber(last) or total
	if last < 1 or last > total then last = total end
	local order = {}
	for i = last, 1, -1 do order[#order + 1] = i end
	for i = total, last + 1, -1 do order[#order + 1] = i end
	local out = {}
	for _, i in ipairs(order) do
		local e = list[i]
		if isOldFilterEntry(e) then out[#out + 1] = History.MigrateOldFilterEntry(e)
		elseif type(e) == "table" and History.Normalize(e) then out[#out + 1] = e end
	end
	-- keep newest first even where old timestamps were readable
	local pos = {}
	for i, h in ipairs(out) do pos[h] = i end
	table.sort(out, function(a, b)
		if a.ts > 0 and b.ts > 0 and a.ts ~= b.ts then return a.ts > b.ts end
		return pos[a] < pos[b]
	end)
	out.counts = History.CountList(out)
	migratedLists[out] = true
	return out
end
