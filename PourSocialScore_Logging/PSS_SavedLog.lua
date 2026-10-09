------------------------------------------------------------------------
-- THE SAVED LOG (3.2.0-dev007)
--
-- In play the log is an array of entry tables and the keep is packed per
-- person (above). At logout (and /reload) both are saved together, one
-- group per owner, so a person's name, guild rule and Chat Filters rule
-- are stored once however many lines they have:
--   blockLog = { v = 2, [owner] = {
--       m = name (a person's group: only when it is not the owner key's form,
--           false for none, core uplift S3), n = { other names } (a chat filter's other senders),
--       gk = guild rule key, r = rule tag, c = the group's usual channel,
--       k = how many of the lines are kept lines (they come first),
--       [1..] = "<type><time>\t<event>\t<channel>\t<who>\t<message>" } }
--   type    one letter (LOG_CODE)
--   time    the server time for the group's first line, then "+<seconds
--           after the line before>"
--   event   one letter for the usual events (KEPT_EVENTS), else the name
--   channel empty: the event's usual label; "~": the group's c
--   who     empty: m, gk and r of the group; else "<index in n>" and, when
--           they differ, "\1<gk>\1<r>"
--   message the rest of the line, as it was ("\2": the same as the line
--           before; one starting with "\2" gets another in front)
-- When Logging loads, the log and the keep are rebuilt from it. Nothing
-- here runs unless Logging was loaded this session.
-- A log saved by a newer version (v above 2) is kept as it is (core uplift
-- U3): this session's lines are counted as always but not added to it.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local L = addon.L
local History = M.PSS_History
local EVENT_LETTER, LETTER_EVENT = History.EventLetter, History.LetterEvent
local usualChannel, pack, unpackLine = History.UsualChannel, History.PackLine, History.UnpackLine

local LOG_CODE = { whisper = "w", partyRaid = "p", partyInvite = "i", guildInvite = "g",
	world = "c", guildChat = "u", unknown = "x" }
local LOG_CAT = {}
for cat, code in pairs(LOG_CODE) do LOG_CAT[code] = cat end
local SAME = "\2"

local function flat(v) return (tostring(v):gsub("[\t\1\2]", " ")) end

-- entry -> its line in group g (prev: the line before's ts and message)
local function saveLine(h, g, prevTs, prevMsg)
	local ts = math.floor(tonumber(h.ts) or 0)
	local t = prevTs and ("+" .. (ts - prevTs)) or tostring(ts)
	local ev = h.event
	ev = type(ev) == "string" and (EVENT_LETTER[ev] or flat(ev)) or ""
	local ch = h.channel
	if type(ch) ~= "string" or ch == usualChannel(h.cat, h.event) then ch = ""
	elseif ch == g.c then ch = "~"
	else ch = flat(ch) end
	local who = ""
	local name = h.member
	if name ~= g.m then
		g.n = g.n or {}
		local idx
		for i = 1, #g.n do if g.n[i] == name then idx = i break end end
		if not idx and type(name) == "string" then g.n[#g.n + 1] = name; idx = #g.n end
		who = idx and tostring(idx) or "0"
	end
	if h.gk ~= g.gk or h.r ~= g.r then
		who = who .. "\1" .. (h.gk ~= nil and flat(h.gk) or "") .. "\1" .. (h.r ~= nil and flat(h.r) or "")
	end
	local msg = tostring(h.message or "")
	local out = (LOG_CODE[h.cat] or "x") .. t .. "\t" .. ev .. "\t" .. ch .. "\t" .. who .. "\t"
		.. (msg == prevMsg and SAME or (msg:byte(1) == 2 and SAME .. msg) or msg)
	return out, ts, msg
end

local newerLog, newerKeep	-- a newer version's saved log, put back at logout

-- A person's name as the owner key gives it ("p:<canon>", "g:<canon>"): a
-- group whose m is that is saved without m (S3).
local function ownerName(o)
	local a, b = o:byte(1, 2)
	if b ~= 58 or (a ~= 112 and a ~= 103) then return nil end
	local d = M.PSS_DisplayPlayer(o:sub(3))
	return d ~= "" and d or nil
end

-- the log and the keep -> blockLog v2 (at logout, only if Logging loaded)
function History.PackForSave()
	if not History.Loaded() then return end
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return end
	if newerLog then
		db.blockLog, db.blockKeep = newerLog, newerKeep
		return
	end
	local log = db.blockLog
	if type(log) ~= "table" or log.v == 2 then return end
	local keep = db.blockKeep
	local out, last = { v = 2 }, {}
	local function group(o, first)
		local g = out[o]
		if not g then
			g = { k = 0 }
			out[o] = g
			g.m, g.gk, g.r = first.member, first.gk, first.r
			last[o] = {}
		end
		return g
	end
	local function add(o, h)
		local g = group(o, h)
		local l = last[o]
		local line
		line, l.ts, l.msg = saveLine(h, g, l.ts, l.msg)
		g[#g + 1] = line
	end
	-- the usual channel of each owner's lines: the most frequent one
	local chans = {}
	local function seen(o, h)
		local ch = h.channel
		if type(ch) == "string" and ch ~= usualChannel(h.cat, h.event) then
			local c = chans[o] or {}
			chans[o] = c
			c[ch] = (c[ch] or 0) + 1
		end
	end
	local kept = {}
	if type(keep) == "table" then
		for o, list in pairs(keep) do
			if type(list) == "table" then
				local hs = {}
				for i = 1, #list do
					local h = type(list[i]) == "string" and unpackLine(o, list, list[i])
					if h then hs[#hs + 1] = h; seen(o, h) end
				end
				kept[o] = hs
			end
		end
	end
	for i = 1, #log do
		local h = log[i]
		if type(h) == "table" and type(h.o) == "string" then seen(h.o, h) end
	end
	local function setChan(o, g)
		local c, most = nil, 1
		for ch, n in pairs(chans[o] or {}) do if n > most then c, most = ch, n end end
		g.c = c
	end
	for o, hs in pairs(kept) do
		if #hs > 0 then
			local g = group(o, hs[#hs])
			setChan(o, g)
			for i = 1, #hs do add(o, hs[i]) end
			g.k = #hs
		end
	end
	for i = 1, #log do
		local h = log[i]
		if type(h) == "table" and type(h.o) == "string" then
			if not out[h.o] then setChan(h.o, group(h.o, h)) end
			add(h.o, h)
		end
	end
	for o, g in pairs(out) do
		if type(g) == "table" then
			if g.k == 0 then g.k = nil end
			-- a person's group: m is saved only when it is not the key's own form
			-- (false: the lines have no name at all)
			local own = ownerName(o)
			if own then
				if g.m == own then g.m = nil elseif g.m == nil then g.m = false end
			end
		end
	end
	db.blockLog = out
	db.blockKeep = nil
end

-- blockLog v2 -> the log (entries, oldest first) and the keep
function History.UnpackSaved()
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return end
	local saved = db.blockLog
	if type(saved) == "table" and type(saved.v) == "number" and saved.v > 2 then
		newerLog, newerKeep = saved, db.blockKeep
		db.blockLog, db.blockKeep = {}, {}
		M.ShowMsg(L["NEWER_LOG"])
		return
	end
	if type(saved) ~= "table" or saved.v ~= 2 then return end
	local log, keep, n = {}, {}, 0
	local order = {}
	for o, g in pairs(saved) do
		if type(o) == "string" and type(g) == "table" then
			local ts, msg = nil, ""
			local k = tonumber(g.k) or 0
			local gm = g.m
			if gm == nil then gm = ownerName(o) elseif gm == false then gm = nil end
			local list
			for i = 1, #g do
				local s = g[i]
				local code, t, ev, ch, who, m
				if type(s) == "string" then code, t, ev, ch, who, m = s:match("^(.)([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$") end
				if code then
					if t:sub(1, 1) == "+" then ts = (ts or 0) + (tonumber(t:sub(2)) or 0) else ts = tonumber(t) or 0 end
					if m ~= SAME then msg = m:byte(1) == 2 and m:sub(2) or m end
					local cat = LOG_CAT[code] or "unknown"
					ev = LETTER_EVENT[ev] or ev
					local h = { ts = ts, cat = cat, event = ev ~= "" and ev or nil, message = msg, o = o,
						member = gm, gk = g.gk, r = g.r }
					if ch == "~" then h.channel = g.c elseif ch ~= "" then h.channel = ch
					else h.channel = usualChannel(cat, h.event) end
					if who ~= "" then
						local idx, gk, r = who:match("^([^\1]*)\1([^\1]*)\1(.*)$")
						if not idx then idx = who end
						if idx ~= "" then h.member = idx == "0" and nil or (type(g.n) == "table" and g.n[tonumber(idx)]) end
						if gk then h.gk = gk ~= "" and gk or nil; h.r = r ~= "" and r or nil end
					end
					setmetatable(h, History.EntryMT)
					if i <= k then
						if not list then list = {}; keep[o] = list end
						local p = pack(h, list)
						if p then list[#list + 1] = p end
					else
						n = n + 1
						log[n] = h
						order[h] = n
					end
				end
			end
		end
	end
	-- oldest first; one owner's lines keep their order
	table.sort(log, function(a, b)
		local x, y = a.ts, b.ts
		if x ~= y then return x < y end
		return order[a] < order[b]
	end)
	db.blockLog = log
	db.blockKeep = keep
	History.KeepChanged()
end

-- Saves of 3.2.0-dev3 to dev006 kept people's lines out of the log: put
-- them back in it (by time), once, then trim it; what is trimmed settles
-- into the keep again. Returns how many lines went back.
function History.KeepToLog()
	local db = PourSocialScoreDB
	local keep = type(db) == "table" and rawget(db, "blockKeep")
	local n = 0
	if type(keep) == "table" and next(keep) ~= nil then
		local log = History.Log()
		for o, list in pairs(keep) do
			if type(list) == "table" then
				for i = 1, #list do
					local h = type(list[i]) == "string" and unpackLine(o, list, list[i])
					if h then n = n + 1; log[#log + 1] = h end
				end
			end
		end
		rawset(db, "blockKeep", nil)
		History.KeepChanged()
		if n > 0 then
			-- oldest first; ties keep their order (log lines first)
			local pos = {}
			for i = 1, #log do pos[log[i]] = i end
			table.sort(log, function(a, b)
				local x, y = tonumber(a.ts) or 0, tonumber(b.ts) or 0
				if x ~= y then return x < y end
				return pos[a] < pos[b]
			end)
		end
	end
	rawset(db, "logAllV1", true)
	if n > 0 then History.Trim(true) end
	return n
end
