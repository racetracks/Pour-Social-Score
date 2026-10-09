------------------------------------------------------------------------
-- POUR SOCIAL SCORE - CHAT BLOCK CORE
--
-- Every chat line, invite, duel and trade request is decided here, once.
-- The design follows OlympusMute (the most trusted model for this addon):
--   * ONE function on the chat filter hook for every chat event
--     (ChatFrameUtil.AddMessageEventFilter first, the old global as fallback)
--   * the decision for a chat line is made once and reused by every chat
--     window that shows it (keyed by the line ID the game sends)
--   * the sender is identified by character ID (GUID) first, then by name,
--     and the name is normalised only once per sender
--   * each step is error-guarded; your own lines are never hidden by person
--     rules, and GM/Blizzard staff lines are never hidden by text filters
--
-- Decision order for a chat line (first that blocks wins):
--   1. system / NPC handlers      (registered by the player ignore list)
--   2. PEOPLE                      (every registered source, merged: the
--                                   player ignore list and every guild rule's
--                                   members). Each source has an O(1) lookup
--                                   and its own per-person settings:
--                                   whisper / partyInvite / guildInvite /
--                                   partyRaid (incl. raid warnings) / world
--   3. realm handlers              (ignored servers)
--   4. text handlers               (chat filters: custom logic)
--
-- Sources and handlers are registered by:
--   PSS_PlayerIgnoreList.lua, PSS_GuildIgnoreList.lua, PSS_ChatFilters.lua
------------------------------------------------------------------------

local addonName, addon = ...
local M = addon.M
local V = addon.V
local L = addon.L

------------------------------------------------------------------------
-- Shared helpers (used by every module)
------------------------------------------------------------------------
local function isSecret(v)
	return v ~= nil and issecretvalue ~= nil and issecretvalue(v) == true
end
M.PSS_IsSecret = isSecret

local trim = M.trim

local realmCache
local function ownRealm()
	if not realmCache then
		local r = GetNormalizedRealmName and GetNormalizedRealmName()
		if (not r or r == "") and GetRealmName then
			r = GetRealmName()
			if r then r = r:gsub("[%s%-]", "") end
		end
		if r and r ~= "" then realmCache = r end
	end
	return realmCache or ""
end
M.PSS_OwnRealm = ownRealm

-- A unit on your own realm has no realm to give, so a second value from
-- UnitName is a surname: Camelot's "First Last" characters arrive as
-- ("First", "Last") with UnitRealmRelationship 1 (confirmed in game,
-- 2026-10-08). Clients without the API keep the value as a realm.
-- Your own character is always on your own realm, so its second value is
-- always a surname.
local REALM_SAME = LE_REALM_RELATION_SAME or 1
local function isSurname(unit)
	if unit == "player" then return true end
	if not unit or not UnitRealmRelationship then return false end
	local rel = UnitRealmRelationship(unit)
	return not isSecret(rel) and rel == REALM_SAME
end

-- The one place a name and a realm are joined: "Name" / "Name-Realm" as
-- given, or name and realm from a unit API (unit given: the surname rule
-- above, "First Last-<own realm>"). nil when secret or empty.
local function joinName(name, realm, unit)
	if type(name) ~= "string" or isSecret(name) then return nil end
	name = trim(name)
	if name == "" then return nil end
	if type(realm) == "string" and not isSecret(realm) then
		realm = trim(realm)
		if realm ~= "" then
			if isSurname(unit) then return name .. " " .. realm .. "-" .. ownRealm() end
			return name .. "-" .. realm
		end
	end
	return name
end

-- Storage key: "Name" / "Name-Realm" / "Name-Aerie Peak" -> "name-realm" as
-- chat writes it.
local function keyOf(name)
	local dash = name:find("-", 1, true)
	if not dash then
		name = name .. "-" .. ownRealm()
	elseif name:find("[%s%-]", dash + 1) then
		name = name:sub(1, dash) .. name:sub(dash + 1):gsub("[%s%-]", "")
	end
	return name:lower()
end

-- Matching key: like the above, but the realm is also stripped of
-- apostrophes, so "Aman'Thul" / "AmanThul" / "Area 52" / "Area52" all match.
local function canonOf(name)
	local base, realm = name:match("^([^%-]+)%-(.+)$")
	if not base then base, realm = name, ownRealm() end
	base = trim(base):gsub("%s+", " ")			-- "First  Last" == "First Last"
	realm = (realm or ""):gsub("[%s%-']", "")
	return (base .. "-" .. realm):lower()
end

local function displayOf(name)
	if M.Proper then return M.Proper(M.addServer and M.addServer(name) or name) end
	return name
end

-- M.PSS_NormName(name [, realm [, unit]]) -> display, key, canon, or nil when
-- secret or empty. Every name builder goes through it (core uplift N1).
function M.PSS_NormName(name, realm, unit)
	local full = joinName(name, realm, unit)
	if not full then return nil end
	return displayOf(full), keyOf(full), canonOf(full)
end

-- A unit's "Name-Realm" ("Name" on your own realm, "First Last-Realm" for a
-- surname), or nil when there is no such unit or its name is secret (Retail
-- 12.x, while restricted).
function M.PSS_UnitFullName(unit)
	local name, server = UnitName(unit)
	return joinName(name, server, unit)
end

-- Your own character's "Name-Realm" display ("First Last-Realm" with a
-- surname), the same shape as M.Proper(M.addServer(name)).
function M.PSS_PlayerDisplayName()
	if not UnitName then return nil end
	local n, r = UnitName("player")
	return (M.PSS_NormName(n, r, "player"))
end

-- A "First-Last" name handed to a hook (Blizzard's Ignore from a unit menu)
-- is "First Last-<own realm>" when a unit the player can be acting on has
-- that name and surname; anything else is returned as it is. Hook paths only.
local FIX_UNITS = { "target", "mouseover", "focus" }
local function unitHasSurname(u, base, rest)
	if not UnitExists or not UnitExists(u) then return false end
	local n, r = UnitName(u)
	if type(n) ~= "string" or type(r) ~= "string" or isSecret(n) or isSecret(r) then return false end
	return n == base and r == rest and isSurname(u)
end
function M.PSS_FixUnitName(name)
	if type(name) ~= "string" or isSecret(name) or not UnitName then return name end
	local base, rest = name:match("^([^%s%-]+)%-([^%s%-]+)$")
	if not base then return name end
	for _, u in ipairs(FIX_UNITS) do
		if unitHasSurname(u, base, rest) then return base .. " " .. rest .. "-" .. ownRealm() end
	end
	if IsInGroup and IsInGroup() and GetNumGroupMembers then
		local prefix = IsInRaid and IsInRaid() and "raid" or "party"
		for i = 1, GetNumGroupMembers() do
			if unitHasSurname(prefix .. i, base, rest) then return base .. " " .. rest .. "-" .. ownRealm() end
		end
	end
	return name
end

function M.PSS_NormalizePlayer(name)
	local full = joinName(name)
	return full and keyOf(full)
end

function M.PSS_CanonPlayer(name)
	local full = joinName(name)
	return full and canonOf(full)
end
local canonPlayer = M.PSS_CanonPlayer

function M.PSS_CanonRealm(realm)
	if type(realm) ~= "string" or isSecret(realm) then return nil end
	realm = realm:gsub("[%s%-']", ""):lower()
	return realm ~= "" and realm or nil
end

-- guild name -> canon, for the names seen on chat lines (P4, N28): a small
-- table that starts over when it fills
local guildCanons, guildCanonCount = {}, 0
function M.PSS_CanonGuild(name)
	if type(name) ~= "string" or isSecret(name) then return nil end
	local c = guildCanons[name]
	if c ~= nil then return c or nil end
	local n = trim(name):gsub("%s+", " ")
	c = n ~= "" and n:lower() or false
	if guildCanonCount >= 500 then guildCanons, guildCanonCount = {}, 0 end
	guildCanons[name] = c
	guildCanonCount = guildCanonCount + 1
	return c or nil
end

function M.PSS_NowString()
	return date("%d %b %Y %H:%M:%S", GetServerTime())
end

function M.PSS_DisplayPlayer(name)
	local full = joinName(name)
	if not full then return "" end
	return displayOf(full)
end

------------------------------------------------------------------------
-- Event categories
------------------------------------------------------------------------
-- whisper    : whispers (+ Battle.net whispers)
-- partyRaid  : party, raid, raid warning, instance, battleground
-- world      : channels (Trade/General/LFG/custom), say, yell, emotes,
--              AFK/DND auto-replies, community channels
-- guildChat  : guild and officer chat
-- other      : achievements, channel join/leave/notice, channel invites
-- npc        : NPC speech (MONSTER_*)
-- system     : system messages
-- (outgoing whispers - *_INFORM - are never touched)
local EVENT_CATEGORY = {
	CHAT_MSG_WHISPER = "whisper", CHAT_MSG_BN_WHISPER = "whisper",
	CHAT_MSG_PARTY = "partyRaid", CHAT_MSG_PARTY_LEADER = "partyRaid",
	CHAT_MSG_RAID = "partyRaid", CHAT_MSG_RAID_LEADER = "partyRaid", CHAT_MSG_RAID_WARNING = "partyRaid",
	CHAT_MSG_INSTANCE_CHAT = "partyRaid", CHAT_MSG_INSTANCE_CHAT_LEADER = "partyRaid",
	CHAT_MSG_BATTLEGROUND = "partyRaid", CHAT_MSG_BATTLEGROUND_LEADER = "partyRaid",
	CHAT_MSG_CHANNEL = "world", CHAT_MSG_SAY = "world", CHAT_MSG_YELL = "world",
	CHAT_MSG_EMOTE = "world", CHAT_MSG_TEXT_EMOTE = "world",
	CHAT_MSG_AFK = "world", CHAT_MSG_DND = "world",
	CHAT_MSG_COMMUNITIES_CHANNEL = "world",
	CHAT_MSG_GUILD = "guildChat", CHAT_MSG_OFFICER = "guildChat",
	CHAT_MSG_ACHIEVEMENT = "other", CHAT_MSG_GUILD_ACHIEVEMENT = "other",
	CHAT_MSG_CHANNEL_JOIN = "other", CHAT_MSG_CHANNEL_LEAVE = "other",
	CHAT_MSG_CHANNEL_NOTICE_USER = "other", CHANNEL_INVITE_REQUEST = "other",
	CHAT_MSG_MONSTER_EMOTE = "npc", CHAT_MSG_MONSTER_PARTY = "npc", CHAT_MSG_MONSTER_SAY = "npc",
	CHAT_MSG_MONSTER_WHISPER = "npc", CHAT_MSG_MONSTER_YELL = "npc",
	CHAT_MSG_SYSTEM = "system",
}
function M.PSS_EventCategory(event) return EVENT_CATEGORY[event] end

-- Categories chat filters (custom text logic) may act on.
local TEXT_CATEGORIES = { whisper = true, partyRaid = true, world = true, guildChat = true }

-- Labels for history/UI: History's categories and words, plus the extra kinds.
M.PSS_BLOCK_LABELS = { other = "Other", duel = "Duel", trade = "Trade" }
for cat, label in pairs(M.PSS_History.CAT_LABEL) do
	if cat ~= "unknown" then M.PSS_BLOCK_LABELS[cat] = label end
end

local EVENT_CHANNEL = {
	CHAT_MSG_WHISPER = "Whisper", CHAT_MSG_BN_WHISPER = "Battle.net Whisper",
	CHAT_MSG_SAY = "Say", CHAT_MSG_YELL = "Yell",
	CHAT_MSG_EMOTE = "Emote", CHAT_MSG_TEXT_EMOTE = "Emote",
	CHAT_MSG_PARTY = "Party", CHAT_MSG_PARTY_LEADER = "Party Leader",
	CHAT_MSG_RAID = "Raid", CHAT_MSG_RAID_LEADER = "Raid Leader", CHAT_MSG_RAID_WARNING = "Raid Warning",
	CHAT_MSG_INSTANCE_CHAT = "Instance", CHAT_MSG_INSTANCE_CHAT_LEADER = "Instance Leader",
	CHAT_MSG_BATTLEGROUND = "Battleground", CHAT_MSG_BATTLEGROUND_LEADER = "Battleground Leader",
	CHAT_MSG_CHANNEL = "Channel", CHAT_MSG_GUILD = "Guild", CHAT_MSG_OFFICER = "Officer",
	CHAT_MSG_AFK = "AFK", CHAT_MSG_DND = "DND", CHAT_MSG_COMMUNITIES_CHANNEL = "Community",
}

function M.PSS_ChannelLabel(event, channelString, chNumber, chName)
	if event == "CHAT_MSG_CHANNEL" then
		if type(channelString) == "string" and channelString ~= "" and not isSecret(channelString) then
			return channelString
		end
		if type(chName) == "string" and chName ~= "" and not isSecret(chName) then
			local n = tonumber(chNumber)
			return (n and n > 0) and (n .. ". " .. chName) or chName
		end
		return "Channel"
	end
	if event == "PARTY_INVITE" then return "Party Invite" end
	if event == "GUILD_INVITE" then return "Guild Invite" end
	if type(event) == "string" then
		return EVENT_CHANNEL[event] or (event:gsub("^CHAT_MSG_", ""):gsub("_", " "))
	end
	return ""
end

------------------------------------------------------------------------
-- Options (resolved by PSS_Options.lua; plain global value as fallback)
------------------------------------------------------------------------
local function opt(key, ctx)
	if M.PSS_Opt then return M.PSS_Opt(key, ctx) end
	return PourSocialScoreDB and PourSocialScoreDB[key]
end

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------
-- Person source:
--   { id, order, label,
--     lookup(canon, ctx)        -> entry or nil   (must be O(1))
--     (The tickboxes in the UI are the inverse: ticked = allowed = decide
--      returns false. Sources keep their settings as "blocked" values.)
--     decide(entry, cat, ctx)   -> true to block  (cat: whisper, partyRaid,
--                                  world, guildChat, other, partyInvite,
--                                  guildInvite, duel, trade)
--     record(entry, cat, ctx)                      (stats/history)
--     optionContext(entry)      -> { person = tbl, guild = tbl }
--     describe(entry)           -> short text for diagnostics
--     inviteByGuild(inviter, guildName) -> entry or nil (optional) }
local sources = {}
local handlers = { system = {}, npc = {}, realm = {}, text = {} }

function M.PSS_RegisterBlockSource(def)
	for i = #sources, 1, -1 do if sources[i].id == def.id then table.remove(sources, i) end end
	sources[#sources + 1] = def
	table.sort(sources, function(a, b) return (a.order or 50) < (b.order or 50) end)
end


-- kind: "system", "npc", "realm", "text"; fn(ctx) -> blocked[, info]
function M.PSS_RegisterBlockHandler(kind, id, fn)
	local list = handlers[kind]
	if not list then return end
	for i = #list, 1, -1 do if list[i].id == id then table.remove(list, i) end end
	list[#list + 1] = { id = id, fn = fn }
end

------------------------------------------------------------------------
-- Stats / diagnostics
------------------------------------------------------------------------
local stats = { checked = 0, personHits = 0, hidden = 0, errors = 0, lastError = nil, lastChecked = { at = 0 }, bySource = {} }
M.PSS_CoreStats = stats
local debug = { on = false, allUntil = 0 }
M.PSS_CoreDebug = debug

-- Debug output. Callers check debugActive() FIRST so the message text is
-- never built while debug is off (it used to be formatted for every line).
local function debugActive(all)
	return (debug.on and not all) or (debug.allUntil > 0 and GetTime() < debug.allUntil)
end
local function dprint(text, all)
	if debugActive(all) then M.ChatMsg("|cff33ff99PSS:|r " .. text) end
end

local function noteError(err)
	stats.errors = stats.errors + 1
	if not stats.lastError then
		M.ChatMsg("|cffff5555Pour Social Score chat block error (shown once, see /pssguild status):|r " .. tostring(err))
	end
	stats.lastError = tostring(err)
end

------------------------------------------------------------------------
-- People lookup (merged across sources)
------------------------------------------------------------------------
local playerGUID, playerCanon
-- guid -> canon for recent senders (saves rebuilding the key for every line).
-- Kept small: it is only a shortcut, and is dropped when it fills.
local guidCanon = {}
local guidCanonCount = 0

local function senderCanon(author, guid)
	if guid and guid ~= "" then
		local c = guidCanon[guid]
		if c then return c end
	end
	local c = canonPlayer(author)
	if c and guid and guid ~= "" then
		if guidCanonCount >= 1500 then guidCanon = {}; guidCanonCount = 0 end
		guidCanon[guid] = c
		guidCanonCount = guidCanonCount + 1
	end
	return c
end

local function isSelf(canon, guid)
	if not playerGUID then playerGUID = UnitGUID and UnitGUID("player") end
	if not playerCanon and UnitName then
		local n, r = UnitName("player")
		playerCanon = select(3, M.PSS_NormName(n, r, "player"))
	end
	return (guid and playerGUID and guid == playerGUID) or (canon and canon == playerCanon)
end

-- All entries for a person, one per source that knows them.
-- scratch (chat lines only): reuse its tables instead of making new ones
-- for every line from a listed person. The result is only valid until the
-- next chat line, like the shared ctx below.
local function lookupPeople(canon, ctx, scratch)
	local found, n = nil, 0
	for _, src in ipairs(sources) do
		local ok, entry = pcall(src.lookup, canon, ctx)
		if ok and entry then
			n = n + 1
			if scratch then
				found = scratch.found
				local w = scratch.pool[n]
				if not w then w = {}; scratch.pool[n] = w end
				w.src, w.entry = src, entry
				found[n] = w
			else
				found = found or {}
				found[n] = { src = src, entry = entry }
			end
		elseif not ok then
			noteError(entry)
		end
	end
	if scratch then
		local f = scratch.found
		for i = n + 1, #f do f[i] = nil end
	end
	return found
end

-- Which sources block this person for this category.
local function personHits(canon, cat, ctx, scratch)
	local found = lookupPeople(canon, ctx, scratch)
	if not found then return nil, nil end
	local hits, n = nil, 0
	for _, f in ipairs(found) do
		local ok, blocked = pcall(f.src.decide, f.entry, cat, ctx)
		if ok and blocked then
			n = n + 1
			hits = hits or (scratch and scratch.hits) or {}
			hits[n] = f
		elseif not ok then
			noteError(blocked)
		end
	end
	if scratch then
		local h = scratch.hits
		for i = n + 1, #h do h[i] = nil end
	end
	return hits, found
end
-- chat lines: one set of tables, reused (see lookupPeople)
local chatScratch = { found = {}, hits = {}, pool = {} }
M.PSS_PersonHits = function(name, cat, ctx)
	return personHits(canonPlayer(name), cat, ctx or {})
end

local function recordHits(hits, cat, ctx)
	for _, h in ipairs(hits) do
		stats.bySource[h.src.id] = (stats.bySource[h.src.id] or 0) + 1
		if h.src.record then
			local ok, err = pcall(h.src.record, h.entry, cat, ctx)
			if not ok then noteError(err) end
		end
	end
end

-- Option context of the first blocking source (player list before guilds).
local function hitOptionContext(hits)
	local h = hits and hits[1]
	if h and h.src.optionContext then
		local ok, c = pcall(h.src.optionContext, h.entry)
		if ok and c then return c end
	end
	return {}
end

------------------------------------------------------------------------
-- Chat line decision
------------------------------------------------------------------------
local function runHandlers(list, ctx)
	for _, h in ipairs(list) do
		local ok, blocked, info = pcall(h.fn, ctx)
		if not ok then
			noteError(blocked)
		elseif blocked then
			return true, h.id, info
		end
	end
	return false
end

local STAFF_FLAGS = { GM = true, DEV = true }

local function evaluate(ctx)
	local cat = ctx.cat
	if cat == "system" then
		return (runHandlers(handlers.system, ctx))
	end
	if not V.PSS_Loaded then return false end
	if cat == "npc" then
		return (runHandlers(handlers.npc, ctx))
	end

	local author = ctx.author
	if type(author) ~= "string" or author == "" then return false end
	stats.checked = stats.checked + 1
	local lc = stats.lastChecked			-- one table, reused
	lc.name, lc.event, lc.at = author, ctx.event, GetTime()

	local canon = senderCanon(author, ctx.guid)
	ctx.canon = canon
	ctx.isSelf = isSelf(canon, ctx.guid)

	if not ctx.isSelf and canon then
		-- 2. people (player list + guild members, merged)
		local hits, found = personHits(canon, cat, ctx, chatScratch)
		if found then stats.personHits = stats.personHits + 1 end
		if hits then
			ctx.hits = hits
			recordHits(hits, cat, ctx)
			if debugActive() then dprint(("BLOCKED %s from %s (%s)"):format(M.PSS_BLOCK_LABELS[cat] or cat, author, hits[1].src.label or hits[1].src.id)) end
			return true
		elseif found then
			if debugActive() then dprint(("%s from %s: listed (%s) but allowed for this message type"):format(
				M.PSS_BLOCK_LABELS[cat] or cat, author, found[1].src.label or found[1].src.id)) end
		elseif debugActive(true) then
			dprint(("%s from %s (key %s): not on any list"):format(M.PSS_BLOCK_LABELS[cat] or cat, author, tostring(canon)), true)
		end

		-- 3. ignored realms
		local rb, rid, rinfo = runHandlers(handlers.realm, ctx)
		if rb then
			ctx.realmBlock = rinfo or true
			if debugActive() then dprint(("BLOCKED %s from %s (ignored server)"):format(M.PSS_BLOCK_LABELS[cat] or cat, author)) end
			return true
		end
	end

	-- 4. chat filters (custom text logic). Staff messages are never text-filtered.
	if TEXT_CATEGORIES[cat] and not (ctx.flag and STAFF_FLAGS[ctx.flag]) and not isSecret(ctx.msg) then
		local tb = runHandlers(handlers.text, ctx)
		if tb then
			ctx.textBlock = true
			return true
		end
	end
	return false
end

-- "You are being ignored" auto-reply: at most once per sender every
-- REPLY_PER_SENDER seconds and at most one reply every REPLY_GLOBAL seconds
-- in total, so a spammer cannot make you spam back (2.0.8 replied to every
-- blocked whisper).
local REPLY_PER_SENDER, REPLY_GLOBAL = 300, 2
local lastReplyTo, lastReplyAny = {}, -1000
local function replyAllowed(key)
	local now = GetTime()
	if now - lastReplyAny < REPLY_GLOBAL then return false end
	if key and lastReplyTo[key] and now - lastReplyTo[key] < REPLY_PER_SENDER then return false end
	lastReplyAny = now
	if key then lastReplyTo[key] = now end
	return true
end

-- After a line is hidden (runs once per line).
local function afterBlock(ctx)
	stats.hidden = stats.hidden + 1
	if PourSocialScoreDB then PourSocialScoreDB.hiddenTotal = (tonumber(PourSocialScoreDB.hiddenTotal) or 0) + 1 end
	-- Auto-reply to a blocked whisper (person rules or ignored server).
	if ctx.event == "CHAT_MSG_WHISPER" and (ctx.hits or ctx.realmBlock) then
		local octx = ctx.hits and hitOptionContext(ctx.hits) or {}
		if opt("ignoreResponse", octx) == true and replyAllowed(ctx.canon or ctx.author) then
			local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
			if send then pcall(send, L["MSG_1"], "WHISPER", nil, ctx.author) end
		end
	end
end

-- Decision cache: the game calls the filter once per chat window per line.
-- Keyed by the line ID (a number - no string is built per call), in a fixed
-- ring of CACHE_SIZE slots, so it never grows and never shifts.
local CACHE_SIZE = 256
local decisionCache, ringKeys, ringPos = {}, {}, 0
local function cacheGet(key) return decisionCache[key] end
local function cachePut(key, value)
	if decisionCache[key] == nil then
		ringPos = ringPos % CACHE_SIZE + 1
		local old = ringKeys[ringPos]
		if old ~= nil then decisionCache[old] = nil end
		ringKeys[ringPos] = key
	end
	decisionCache[key] = value
end

-- One context table, reused for every line (the decision is made and used
-- synchronously, nothing keeps a reference to it).
local ctx = {}
local function resetCtx(c)
	for k in pairs(c) do c[k] = nil end
	return c
end

-- Chat event args: msg, author, language, channelString, target, flag,
-- zoneChannelID, channelIndex, channelBaseName, languageID, lineID, guid
local function CoreFilter(_, event, msg, author, language, channelString, target, flag,
							zoneChannelID, channelIndex, channelBaseName, languageID, lineID, guid)
	local cat = EVENT_CATEGORY[event]
	if not cat then return false end
	if isSecret(author) or isSecret(guid) then return false end
	if isSecret(flag) or type(flag) ~= "string" then flag = nil end
	-- channel args reach the filter tags ([chname], [channel]): drop secret ones
	if isSecret(channelString) then channelString = nil end
	if isSecret(channelIndex) then channelIndex = nil end
	if isSecret(channelBaseName) then channelBaseName = nil end

	local key
	if type(lineID) == "number" and not isSecret(lineID) and lineID ~= 0 then
		key = lineID					-- unique per chat line
	else
		local m = isSecret(msg) and "" or tostring(msg or "")
		key = event .. "\1" .. tostring(author) .. "\1" .. m .. "\1" .. math.floor(GetTime() * 2)
	end
	local cached = cacheGet(key)
	if cached ~= nil then return cached end

	resetCtx(ctx)
	ctx.event, ctx.cat, ctx.msg, ctx.author, ctx.flag, ctx.guid = event, cat, msg, author, flag, guid
	ctx.lineID, ctx.channelString, ctx.chNumber, ctx.chName = lineID, channelString, channelIndex, channelBaseName
	local ok, hit = pcall(evaluate, ctx)
	if not ok then
		noteError(hit)
		return false		-- not cached: the next window tries again
	end
	hit = hit == true
	cachePut(key, hit)
	if hit then
		local ok2, err = pcall(afterBlock, ctx)
		if not ok2 then noteError(err) end
	end
	return hit
end
M.PSS_CoreFilter = CoreFilter

-- Dry-run explanation for diagnostics: { {source=, listed=true, blocked={cat=bool}} }
local EXPLAIN_ORDER = { "whisper", "partyRaid", "world", "guildChat", "partyInvite", "guildInvite", "duel", "trade" }
function M.PSS_ExplainPerson(name)
	local canon = canonPlayer(name)
	local out = { canon = canon, sources = {}, order = EXPLAIN_ORDER }
	if not canon then return out end
	local found = lookupPeople(canon, {})
	for _, f in ipairs(found or {}) do
		local row = { src = f.src, entry = f.entry, blocked = {} }
		for _, cat in ipairs(EXPLAIN_ORDER) do
			local ok, b = pcall(f.src.decide, f.entry, cat, {})
			row.blocked[cat] = ok and b == true
		end
		if f.src.describe then
			local ok, d = pcall(f.src.describe, f.entry)
			row.describe = ok and d or nil
		end
		out.sources[#out.sources + 1] = row
	end
	return out
end

------------------------------------------------------------------------
-- Remove already-shown chat lines from people who just got blocked
-- (OlympusMute's history purge). keys: set of canonical names.
------------------------------------------------------------------------
local function chatFrames()
	local list = {}
	if type(CHAT_FRAMES) == "table" then
		for _, f in ipairs(CHAT_FRAMES) do
			if type(f) == "string" then f = _G[f] end
			if type(f) == "table" then list[#list + 1] = f end
		end
	end
	if #list == 0 then
		for i = 1, (tonumber(NUM_CHAT_WINDOWS) or 10) do
			local f = _G["ChatFrame" .. i]
			if type(f) == "table" then list[#list + 1] = f end
		end
	end
	return list
end

function M.PSS_PurgeChatFrom(keys)
	if type(keys) ~= "table" or not next(keys) then return end
	if opt("purgeHistory", {}) == false then return end
	local function predicate(msg)
		if type(msg) == "table" then msg = msg.message end
		if type(msg) ~= "string" or isSecret(msg) then return false end
		for target in msg:gmatch("|Hplayer:([^:|]+)") do
			if keys[canonPlayer(target)] then return true end
		end
		return false
	end
	for _, frame in ipairs(chatFrames()) do
		if frame.RemoveMessagesByPredicate then pcall(frame.RemoveMessagesByPredicate, frame, predicate) end
	end
end

------------------------------------------------------------------------
-- Invites, duels, trades
------------------------------------------------------------------------
local pendingInvite = nil	-- canon of an unidentified party inviter
local lastGuildDecline, lastGuildEvent = 0, 0

local function declineMsg(fmtKey, name, octx)
	if opt("showDeclines", octx) == true and L[fmtKey] then
		M.ShowMsg(format(L[fmtKey], tostring(name)))
	end
end

local function declineParty(name, hits, ctx)
	pendingInvite = nil
	if DeclineGroup then DeclineGroup() end
	if StaticPopup_Hide then StaticPopup_Hide("PARTY_INVITE") end
	recordHits(hits, "partyInvite", ctx)
	declineMsg("MSG_2", name, hitOptionContext(hits))
end

local function handlePartyInvite(inviter, ...)
	if not V.PSS_Loaded or type(inviter) ~= "string" or isSecret(inviter) then return end
	local guid = select(6, ...)
	if isSecret(guid) then guid = nil end
	local canon = senderCanon(inviter, guid)
	local ctx = { event = "PARTY_INVITE", cat = "partyInvite", author = inviter, guid = guid, canon = canon, msg = "" }
	local hits = canon and personHits(canon, "partyInvite", ctx)
	if hits then
		declineParty(inviter, hits, ctx)
	else
		-- not known yet: if they are identified while the invite is open, decline then
		pendingInvite = canon
	end
end

-- Called by sources when a person is newly added/identified.
function M.PSS_PersonIdentified(name)
	local canon = canonPlayer(name)
	if not canon or canon ~= pendingInvite then return end
	if StaticPopup_Visible and not StaticPopup_Visible("PARTY_INVITE") then pendingInvite = nil return end
	local ctx = { event = "PARTY_INVITE", cat = "partyInvite", author = name, canon = canon, msg = "" }
	local hits = personHits(canon, "partyInvite", ctx)
	if hits then declineParty(name, hits, ctx) end
end

local function guildInviteVisible()
	local f = _G.GuildInviteFrame
	if type(f) == "table" and f.IsShown and f:IsShown() then return true end
	return StaticPopup_Visible and StaticPopup_Visible("GUILD_INVITE") and true or false
end

local function declineGuildInvite()
	-- the API only (PSS 02 10.3): never press or hide Blizzard's invite
	-- window. Blizzard's GuildInviteFrame closes on GUILD_INVITE_CANCEL or
	-- after its own 60 s; clients that use a GUILD_INVITE popup close it here.
	if DeclineGuild then
		DeclineGuild()
	elseif C_GuildInfo and C_GuildInfo.DeclineGuild then
		C_GuildInfo.DeclineGuild()
	end
	if StaticPopup_Hide then StaticPopup_Hide("GUILD_INVITE") end
end

local function handleGuildInvite(inviter, guildName)
	lastGuildEvent = GetTime()
	if not V.PSS_Loaded or type(inviter) ~= "string" or isSecret(inviter) then return end
	if isSecret(guildName) then guildName = nil end
	local canon = senderCanon(inviter)
	local ctx = { event = "GUILD_INVITE", cat = "guildInvite", author = inviter, canon = canon, guildName = guildName,
					msg = guildName and ("Invited you to <" .. guildName .. ">") or "" }
	local hits = canon and personHits(canon, "guildInvite", ctx)
	if not hits and guildName then
		-- the invite names the guild: a guild rule may own it even if the
		-- inviter was never captured
		for _, src in ipairs(sources) do
			if src.inviteByGuild then
				local ok, entry = pcall(src.inviteByGuild, inviter, guildName)
				if ok and entry then
					local okd, b = pcall(src.decide, entry, "guildInvite", ctx)
					if okd and b then hits = { { src = src, entry = entry } } break end
				end
			end
		end
	end
	if not hits then return end
	declineGuildInvite()
	if C_Timer and C_Timer.After then
		C_Timer.After(0.2, function() if guildInviteVisible() then pcall(declineGuildInvite) end end)
	end
	recordHits(hits, "guildInvite", ctx)
	if GetTime() - lastGuildDecline > 2 then declineMsg("MSG_4", inviter, hitOptionContext(hits)) end
	lastGuildDecline = GetTime()
end

local function handleDuel(challenger)
	if not V.PSS_Loaded or type(challenger) ~= "string" or isSecret(challenger) then return end
	local ctx = { event = "DUEL", cat = "duel", author = challenger }
	local hits = personHits(canonPlayer(challenger), "duel", ctx)
	if not hits then return end
	if CancelDuel then CancelDuel() end
	if StaticPopup_Hide then StaticPopup_Hide("DUEL_REQUESTED") end
	declineMsg("MSG_3", challenger, hitOptionContext(hits))
end

local function handleTrade(name)
	if not V.PSS_Loaded then return end
	if type(name) ~= "string" then
		name = UnitName and UnitName("NPC")
		if type(name) ~= "string" then return end
	end
	if isSecret(name) then return end
	local ctx = { event = "TRADE", cat = "trade", author = name }
	local hits = personHits(canonPlayer(name), "trade", ctx)
	if not hits then return end
	if CancelTrade then CancelTrade() end
	if StaticPopup_Hide then StaticPopup_Hide("TRADE") end
	declineMsg("MSG_5", name, hitOptionContext(hits))
end

------------------------------------------------------------------------
-- Alerts: listed players in your group, whispers you send to them
------------------------------------------------------------------------
-- Any list: the Player Ignore List always counts; a guild member counts
-- only while their guild rule blocks them in some way (a rule that is off,
-- or a guild on the Guild Exclusion List, does not).
local LISTED_CATS = { "other", "whisper", "partyRaid", "world", "partyInvite", "guildInvite" }
local listedCtx = {}	-- read only: no new table per group member checked

function M.PSS_PersonListed(name)
	local canon = canonPlayer(name)
	if not canon then return false end
	local found = lookupPeople(canon, listedCtx)
	if not found then return false end
	for _, f in ipairs(found) do
		for _, cat in ipairs(LISTED_CATS) do
			local ok, b = pcall(f.src.decide, f.entry, cat, listedCtx)
			if ok and b then return true end
		end
	end
	return false
end

-- Whispers you send: one alert per player per session, and only when a
-- list blocks their whispers (W ticked = allowed = no alert).
local whisperWarned = {}

local function handleWhisperSent(target)
	if not V.PSS_Loaded or type(target) ~= "string" or target == "" or isSecret(target) then return end
	if opt("listWarnings", {}) == false then return end
	local canon = canonPlayer(target)
	if not canon or whisperWarned[canon] then return end
	local hits = personHits(canon, "whisper", { event = "CHAT_MSG_WHISPER_INFORM", cat = "whisper", author = target })
	if not hits then return end
	whisperWarned[canon] = true
	local name = M.PSS_DisplayPlayer(target)
	local label = hits[1].src.label or ""
	M.ShowMsg(format(L["WARN_WHISPER"], name, label))
	M.Events.Fire("WHISPER_WARNING", name, label)
end

------------------------------------------------------------------------
-- Registration with the game
------------------------------------------------------------------------
local CFU = type(ChatFrameUtil) == "table" and ChatFrameUtil or nil
local AddFilter = (CFU and CFU.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
M.PSS_FilterAvailable = type(AddFilter) == "function"
if M.PSS_FilterAvailable then
	for event in pairs(EVENT_CATEGORY) do AddFilter(event, CoreFilter) end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PARTY_INVITE_REQUEST")
ev:RegisterEvent("PARTY_INVITE_CANCEL")
ev:RegisterEvent("GUILD_INVITE_REQUEST")
ev:RegisterEvent("DUEL_REQUESTED")
ev:RegisterEvent("TRADE_SHOW")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
pcall(ev.RegisterEvent, ev, "TRADE_REQUEST")	-- not on every client
ev:SetScript("OnEvent", function(_, event, arg1, ...)
	local ok, err = true, nil
	if event == "PARTY_INVITE_REQUEST" then
		local n = select("#", ...)
		local args = { arg1, ... }
		ok, err = pcall(function() handlePartyInvite(unpack(args, 1, n + 1)) end)
	elseif event == "GUILD_INVITE_REQUEST" then
		local guildName = ...
		ok, err = pcall(handleGuildInvite, arg1, guildName)
	elseif event == "DUEL_REQUESTED" then
		ok, err = pcall(handleDuel, arg1)
	elseif event == "TRADE_REQUEST" then
		ok, err = pcall(handleTrade, arg1)
	elseif event == "TRADE_SHOW" then
		ok, err = pcall(handleTrade, nil)
	elseif event == "CHAT_MSG_WHISPER_INFORM" then
		local target = ...
		ok, err = pcall(handleWhisperSent, target)
	elseif event == "PARTY_INVITE_CANCEL" or event == "GROUP_ROSTER_UPDATE" then
		pendingInvite = nil
	end
	if not ok then noteError(err) end
end)

-- Test hooks for an offline test harness (used only by tools/harness).
M.PSS__CoreTest = {
	handlePartyInvite = handlePartyInvite, handleGuildInvite = handleGuildInvite,
	handleDuel = handleDuel, handleTrade = handleTrade, handleWhisperSent = handleWhisperSent,
	resetWhisperWarned = function() whisperWarned = {} end,
	resetCache = function() decisionCache, ringKeys, ringPos = {}, {}, 0 end,
}
