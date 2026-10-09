------------------------------------------------------------------------
-- POUR SOCIAL SCORE - WHOIS (/who service)
--
-- Core module, no UI: sending a /who, the shared cooldown, and reading the
-- answer. Every search goes through here: guild Scan / Scan All / Custom,
-- Guild Search, the exclusion search and Player Search.
--
-- Sending
--   M.Whois.Request(req) -> true when the /who went out
--     req.filter   the /who text, e.g. g-"Olympus" 1-80 or n-"Bob"
--     req.kind     who asked: "guildScan", "guildSearch", "playerSearch" ...
--     req.onInfo   optional function(info, req)  for every player in the answer
--     req.onFinish optional function(req, numWhos, total, how)  once, at the end
--     (any other fields are kept, for the requester's own use)
--   Call it straight from a click: the game only sends a /who from a
--   hardware event, so nothing UI-related may run before it.
--
-- Listening to every answer (also /who you type yourself)
--   M.Whois.Listen({ begin = fn(req), info = fn(info, req), finish = fn(req, numWhos, total, how) })
--   req is nil for a /who this module did not send.
--
-- Cooldown: Whois.CooldownActive(), CooldownRemaining(), BlockedMsg().
-- Events (PSS_Events.lua): WHOIS_COOLDOWN (active), WHOIS_ANSWERED (req).
------------------------------------------------------------------------
local addonName, addon = ...
local M = addon.M

local Whois = {}
M.Whois = Whois

-- Seconds every search waits after a /who (Scan, Scan All, Custom, Guild Search, Player Search).
Whois.COOLDOWN = 6
-- No answer within this many seconds: nobody online matched.
Whois.ANSWER_WAIT = 5
-- A request this old is given up on when the next answer arrives.
Whois.EXPIRE = 30
-- The same filter twice within this many seconds is refused.
local REPEAT_WINDOW = 3

local pending = nil				-- the request waiting for its answer
local listeners = {}
local cooldownUntil = 0
local cooldownTimer = nil
local lastFilter, lastTime = nil, 0

local function isSecret(v) return M.PSS_IsSecret and M.PSS_IsSecret(v) end

------------------------------------------------------------------------
-- cooldown
------------------------------------------------------------------------
function Whois.CooldownRemaining()
	return math.max(0, cooldownUntil - GetTime())
end

function Whois.CooldownActive()
	return Whois.CooldownRemaining() > 0
end

function Whois.StartCooldown()
	cooldownUntil = GetTime() + Whois.COOLDOWN
	M.Events.Fire("WHOIS_COOLDOWN", true)
	if cooldownTimer and cooldownTimer.Cancel then cooldownTimer:Cancel() end
	cooldownTimer = C_Timer.NewTimer(Whois.COOLDOWN, function()
		cooldownUntil = 0
		cooldownTimer = nil
		M.Events.Fire("WHOIS_COOLDOWN", false)
	end)
end

-- true (and says so in chat) while a click has to wait for the cooldown
function Whois.BlockedMsg()
	if not Whois.CooldownActive() then return false end
	M.ShowMsg(("/who is cooling down - try again in %d s."):format(math.ceil(Whois.CooldownRemaining())))
	return true
end

-- the request waiting for its answer, or nil
function Whois.Pending()
	return pending
end

------------------------------------------------------------------------
-- sending
------------------------------------------------------------------------
-- Proven path retained from the original 12.1.8 build: a plain
-- C_FriendList.SendWho(filter) straight from the click, no FriendsFrame
-- event manipulation, secure delegates or SetWhoToUi.
local function send(filter)
	if not filter or filter == "" then return false end
	local now = GetTime()
	if filter == lastFilter and now - lastTime < REPEAT_WINDOW then
		M.ShowMsg("That /who was just sent - wait a few seconds before repeating it.")
		return false
	end
	lastFilter, lastTime = filter, now

	if C_FriendList and C_FriendList.SendWho then
		C_FriendList.SendWho(filter)
		return true
	elseif SendWho then
		SendWho(filter)
		return true
	end
	return false
end

local finish, applyEvents

function Whois.Request(req)
	if not send(req.filter) then return false end
	req.startedAt = GetTime()
	pending = req
	applyEvents()

	-- after the /who: cooldown on the next frame, give up if nobody answers
	C_Timer.After(0, Whois.StartCooldown)
	C_Timer.After(Whois.ANSWER_WAIT, function()
		if pending == req then finish(nil, nil, "timeout") end
	end)
	return true
end

function Whois.Listen(handler)
	listeners[#listeners + 1] = handler
end

------------------------------------------------------------------------
-- answers
--
-- The game delivers /who results in one of two ways (Blizzard_FriendsFrame):
--   * WHO_LIST_UPDATE + C_FriendList.GetWhoInfo  - when the Who window is
--     open (it calls SetWhoToUi(true)) or the result is large
--   * one CHAT_MSG_SYSTEM line per player (WHO_LIST_GUILD_FORMAT) - when the
--     Who window is closed and the result is small
-- Both are read.
------------------------------------------------------------------------
local inAnswer = false

local function call(stage, ...)
	for _, h in ipairs(listeners) do
		if h[stage] then
			local ok, err = pcall(h[stage], ...)
			if not ok then M.PSS_NoteListenerError("whois " .. stage, err) end
		end
	end
end

local function begin()
	if inAnswer then return end
	inAnswer = true
	if pending and GetTime() - (pending.startedAt or 0) > Whois.EXPIRE then pending = nil end
	call("begin", pending)
end

local function info(i)
	local req = pending
	call("info", i, req)
	if req and req.onInfo then pcall(req.onInfo, i, req) end
end

finish = function(numWhos, total, how)
	local req = pending
	pending = nil
	inAnswer = false
	applyEvents()
	call("finish", req, numWhos, total, how)
	if req and req.onFinish then pcall(req.onFinish, req, numWhos, total, how) end
	M.Events.Fire("WHOIS_ANSWERED", req)
end

-- the Who list (WHO_LIST_UPDATE)
local function readWhoList()
	local getNum, getInfo
	if C_FriendList and C_FriendList.GetNumWhoResults and C_FriendList.GetWhoInfo then
		getNum, getInfo = C_FriendList.GetNumWhoResults, C_FriendList.GetWhoInfo
	elseif GetNumWhoResults and GetWhoInfo then
		getNum, getInfo = GetNumWhoResults, GetWhoInfo
	else
		return
	end

	local numWhos, total = getNum()
	if type(numWhos) == "table" then numWhos = numWhos[1] end
	numWhos = tonumber(numWhos) or 0
	total = tonumber(total) or numWhos

	begin()
	for i = 1, numWhos do
		local first = getInfo(i)
		local entry
		if type(first) == "table" then
			entry = first
		else
			local a, b, c, d, e, f, g, h = getInfo(i)
			entry = { fullName = a, fullGuildName = b, level = c, race = d, classStr = e, zone = f, filename = g, sex = h }
		end
		info(entry)
	end
	finish(numWhos, total, "list")
end

-- Who chat lines: patterns built from the client's own format strings, so
-- they follow the game language.
local linePatterns
local function buildLinePatterns()
	linePatterns = {}
	for _, gname in ipairs({ "WHO_LIST_GUILD_FORMAT", "WHO_LIST_GUILD_TIMERUNNING_FORMAT" }) do
		local fmt = _G[gname]
		if type(fmt) == "string" and fmt:find("<", 1, true) then
			local specs, argN = {}, 0
			local pat = ""
			local i = 1
			while i <= #fmt do
				local n, t, len
				local s1, e1, num, typ = fmt:find("^%%(%d+)%$([sd])", i)
				if s1 then
					n, t, len = tonumber(num), typ, e1 - i + 1
				else
					local s2, e2, typ2 = fmt:find("^%%([sd])", i)
					if s2 then
						argN = argN + 1
						n, t, len = argN, typ2, e2 - i + 1
					end
				end
				if n then
					specs[#specs + 1] = { arg = n, kind = t, inGuild = fmt:sub(i - 1, i - 1) == "<" }
					pat = pat .. (t == "d" and "(%d+)" or "(.-)")
					i = i + len
				else
					local c = fmt:sub(i, i)
					if c == "%" and fmt:sub(i + 1, i + 1) == "%" then
						c = "%"
						i = i + 1
					end
					pat = pat .. c:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
					i = i + 1
				end
			end
			local nameCap, guildCap, levelCap
			for ci, sp in ipairs(specs) do
				if sp.arg == 1 then nameCap = ci end
				if sp.inGuild then guildCap = ci end
				if sp.kind == "d" and not levelCap then levelCap = ci end
			end
			if nameCap and guildCap then
				linePatterns[#linePatterns + 1] = { pat = "^" .. pat .. "$", name = nameCap, guild = guildCap, level = levelCap }
			end
		end
	end
end

local function parseLine(msg)
	if type(msg) ~= "string" or isSecret(msg) or not msg:find("|Hplayer:", 1, true) then return nil end
	if not linePatterns then buildLinePatterns() end
	for _, p in ipairs(linePatterns) do
		local caps = { msg:match(p.pat) }
		if caps[1] then
			return { fullName = caps[p.name], fullGuildName = caps[p.guild], level = p.level and tonumber(caps[p.level]) }
		end
	end
	-- language-neutral fallback, only while one of our own /who is pending:
	-- "|Hplayer:Name-Realm|h[Name]|h: ... 80 ... <Guild> - Zone"
	if pending then
		local name, level, guild = msg:match("^|Hplayer:([^:|]+)[^|]*|h%[.-%]|h: %D-(%d+).-<(.-)>")
		if name then return { fullName = name, fullGuildName = guild, level = tonumber(level) } end
	end
	return nil
end

local chatFinishQueued = false
local function onChatLine(msg)
	local entry = parseLine(msg)
	if not entry then return end
	begin()
	info(entry)
	if not chatFinishQueued then
		-- the lines arrive one per player; wrap up shortly after the last one
		chatFinishQueued = true
		C_Timer.After(1, function()
			chatFinishQueued = false
			finish(nil, nil, "chat")
		end)
	end
end

-- The answer events are heard only while a /who of ours is waiting
-- (pending), or while the guild source wants /who results typed by hand
-- (Whois.SetCapture; it asks only when a guild rule or listed player can
-- use them). Nothing is registered otherwise (core uplift P3, 3.4.1.52).
local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "CHAT_MSG_SYSTEM" then
		-- /who results printed in chat (Who window closed)
		pcall(onChatLine, arg1)
	elseif event == "WHO_LIST_UPDATE" then
		pcall(readWhoList)
	end
end)

local capture, listening = false, false
applyEvents = function()
	local on = pending ~= nil or capture
	if on == listening then return end
	listening = on
	if on then
		frame:RegisterEvent("WHO_LIST_UPDATE")
		frame:RegisterEvent("CHAT_MSG_SYSTEM")
	else
		frame:UnregisterEvent("WHO_LIST_UPDATE")
		frame:UnregisterEvent("CHAT_MSG_SYSTEM")
	end
end

function Whois.SetCapture(on)
	capture = on == true
	applyEvents()
end

------------------------------------------------------------------------
-- names used across the addon
------------------------------------------------------------------------
M.PSS_ScanCooldownActive	= Whois.CooldownActive
M.PSS_ScanBlockedMsg		= Whois.BlockedMsg
function M.PSS_WhoPending() return pending ~= nil end

------------------------------------------------------------------------
-- The scan planner (PSS_WhoisHarvest.lua) is in Libraries (3.4.1 P6): a
-- scan starts from the window, a command or the key binding, and loads it
-- by its first call.
------------------------------------------------------------------------
M.PSS_WHO_CAP = 50
for _, fname in ipairs({ "PSS_HarvestNext", "PSS_HarvestSent", "PSS_HarvestAnswered", "PSS_CapWhoFilter", "PSS_ScanAll" }) do
	M.PSS_Stub(fname, "Libraries")
end

-- Key binding (Bindings.xml): Key Bindings > AddOns > Pour Social Score.
BINDING_HEADER_POURSOCIALSCORE = "Pour Social Score"
BINDING_NAME_PSS_SCAN_ALL = "Scan All: next guild /who"
function PSS_ScanAllBinding() M.PSS_ScanAll() end
