------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PLAYER IGNORE LIST VIEW (for PourSocialScore_GUI)
--
-- What the window's Player Ignore List tab shows and does, worked out here
-- so the tab only draws: the list's sort and search, each column's text,
-- the detail pane's lines, the edits from its boxes and buttons, and the
-- Events specs of one player or of every listed player. Everything is read
-- and changed through the core (PSS_PlayerQuery.lua, the player setters).
--   local v = M.PSS_PlayerListNew()       the list's state
--   v:Resort()                            n shown, every entry, count text, empty text
--   v:SortBy(key)                         a header click: that column, or flip it
--   M.PSS_PlayerTypeText(r), M.PSS_PlayerExpireText(r), M.PSS_PlayerTotal(p)
--   M.PSS_PlayerHeading(r), M.PSS_PlayerTypeLine(r), M.PSS_PlayerAddedLine(r)
--   M.PSS_PlayerExpireNote(r), M.PSS_PlayerGuildLine(p), M.PSS_PlayerInviteLine(p)
--   M.PSS_PlayerTip(r), M.PSS_PlayerRemoveText(entry)
--   M.PSS_PlayerAddFromText(text)         adds a typed name (empty: your target); its entry or nil
--   M.PSS_PlayerTargetName()              your target's Name-Realm when it can be added
--   M.PSS_PlayerSearchFromText(text, onDone)   Player Search (/who) from the click
--   M.PSS_PlayerPickerItems(found, into), ...Title(n, query), ...Save(items)
--   M.PSS_PlayerNoneFound(query), M.PSS_PlayerAddAnyway(name)
--   M.PSS_PruneText(), M.PSS_PruneNote(days), M.PSS_PruneApply(days)
--   M.PSS_PlayerCommitExpiry(entry, text) / M.PSS_PlayerCommitNote(entry, text)
--   M.PSS_PlayerToggleAllowed(entry, field, allowed)
--   M.PSS_PlayerAddGuild(guild)           the player's guild onto the guild list
--   M.PSS_PlayerGuildState(p)             guild, listed (Add Guild button)
--   M.PSS_PlayerEventsSpec(entry), M.PSS_AllPlayersSpec()
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local L = addon.L

local type, tonumber, tostring, ipairs, setmetatable = type, tonumber, tostring, ipairs, setmetatable

------------------------------------------------------------------------
-- The list: sort, search and the order shown (positions in the list)
------------------------------------------------------------------------
local List = M.PSS_ListMixin({})
List.__index = List

function M.PSS_PlayerListNew()
	return setmetatable({ key = "name", asc = true, find = "", index = {}, count = 0, dirty = true }, List)
end

-- n shown; every entry on the list; the count line; the text for no rows
function List:Resort()
	local _, n = M.PSS_SortPlayers(self.key, self.asc, self.find, self.index)
	self.count, self.dirty = n, false
	local all = M.PSS_PlayerCount()
	local countText = self.find ~= "" and ("%d of %d"):format(n, all) or ("%d on the list"):format(all)
	local empty = all == 0 and "The list is empty. Add a player above." or "Nothing matches the search."
	return n, all, countText, empty
end

------------------------------------------------------------------------
-- Column and pane text (r: a row from M.PSS_PlayerRow; p: its record)
------------------------------------------------------------------------
function M.PSS_PlayerTypeText(r)
	if r.kind == "npc" then return "|cffffff99NPC|r" end
	if r.kind == "server" then return "|cffff66ccServer|r" end
	if r.faction == "Alliance" then return "|cff335effAlliance|r" end
	if r.faction == "Horde" then return "|cffe60000Horde|r" end
	return "Unknown"
end

function M.PSS_PlayerExpireText(r)
	if r.expire == 0 then return "|cff808080" .. L["EXP_NVR"] .. "|r" end
	if r.left <= 0 then return "|cffff6666" .. L["EXP_TDY"] .. "|r" end
	return r.left .. "d"
end

function M.PSS_PlayerTotal(p)
	return p and M.PSS_GetPlayerBlockCounts(p).total or 0
end

function M.PSS_PlayerTip(r)
	local text = r.entry
	if r.note and r.note ~= "" then text = text .. "\n\n" .. r.note end
	return text .. "\n\nClick for the details."
end

-- the pane's heading: the name in its class colour, NPC: / Server: first
function M.PSS_PlayerHeading(r)
	local p = r.record
	local cr, cg, cb = M.PSS_ClassColor(p and p.class)
	local title = (r.kind == "npc" and "NPC: ") or (r.kind == "server" and "Server: ") or ""
	local name = r.kind == "server" and r.server or r.name .. (r.server ~= "All" and ("-" .. r.server) or "")
	return title .. ("|cff%02x%02x%02x"):format(cr * 255, cg * 255, cb * 255) .. name .. "|r"
end

function M.PSS_PlayerTypeLine(r)
	local p = r.record
	local text = M.PSS_PlayerTypeText(r)
	if p and (p.className or p.class) then text = text .. "  " .. (p.className or p.class) end
	return text
end

function M.PSS_PlayerAddedLine(r)
	local ago = r.listed or 0
	if not r.added then return "Added |cff808080Unknown|r" end
	return ("Added %s  |cffaaaaaa(%d %s ago)|r"):format(r.added, ago, M.dayString(ago))
end

function M.PSS_PlayerExpireNote(r)
	if r.expire == 0 then return "days  |cff808080(never)|r" end
	if r.left <= 0 then return "days  |cffff6666(today)|r" end
	return ("days  |cffaaaaaa(%d left)|r"):format(r.left)
end

function M.PSS_PlayerGuildLine(p)
	local now, was = p.currentGuild or "", p.guildWhenBlocked or ""
	return "Guild " .. (now ~= "" and ("<" .. now .. ">") or "|cff808080none seen|r")
		.. ((was ~= "" and was ~= now) and ("  |cffaaaaaa(when added <" .. was .. ">)|r") or "")
end

function M.PSS_PlayerInviteLine(p)
	local last = p.lastBlockedInvite or ""
	return "Last blocked invite " .. (last ~= "" and last or "|cff808080never|r")
end

-- the player's current guild and whether the guild list has it (nil: none seen)
function M.PSS_PlayerGuildState(p)
	local now = p and p.currentGuild or ""
	if now == "" then return nil end
	return now, M.PSS_IsGuildListed(now)
end

function M.PSS_PlayerRemoveText(entry)
	local _, kind = M.PSS_PlayerEntry(M.PSS_PlayerPosition(entry))
	return ("Remove %s from the Player Ignore List?"):format(entry)
		.. (kind == "player" and "\n\nTheir note, settings and block history are deleted." or "")
end

------------------------------------------------------------------------
-- Edits (each through the core's setters; the core fires PLAYERS_CHANGED)
------------------------------------------------------------------------
-- Your target, when it is another player of your faction whose name can be
-- read (not secret): "Name-Realm" ("Name" on your realm), or nil.
function M.PSS_PlayerTargetName()
	local t = "target"
	if not (UnitExists(t) and UnitIsPlayer(t)) or UnitIsUnit(t, "player") then return nil end
	local mine, theirs = UnitFactionGroup("player"), UnitFactionGroup(t)
	if type(theirs) ~= "string" or M.PSS_IsSecret(theirs) or theirs ~= mine then return nil end
	return M.PSS_UnitFullName(t)
end

-- A typed Name or Name-Realm, or with the box empty your target: added; its
-- entry as stored, or nil.
function M.PSS_PlayerAddFromText(text)
	text = M.trim(text or "") or ""
	if text == "" then
		local target = M.PSS_PlayerTargetName()
		if not target then
			M.PSS_Say("Type a player name in the box (Name or Name-Realm), or target a player of your faction.")
			return nil
		end
		M.PSS_AddPlayer(target, "", 0, "target")
		text = target
	else
		M.PSS_AddPlayer(text)
	end
	local pos = M.PSS_PlayerPosition(M.Proper(M.addServer(text)))
	if pos > 0 then return (M.PSS_PlayerEntry(pos)) end
end

------------------------------------------------------------------------
-- Player Search: a /who for the name in the box, straight from the click
-- (it needs a hardware event); the players found come back to onDone(found,
-- query) for the results picker. true when it went out.
------------------------------------------------------------------------
function M.PSS_PlayerSearchFromText(text, onDone)
	if M.PSS_ScanBlockedMsg() then return false end
	text = M.trim(text or "") or ""
	if text == "" then
		M.PSS_Say("Type a player name in the box first.")
		return false
	end
	return M.PSS_PlayerSearch(text, onDone) and true or false
end

-- The picker's entries: { name, level, class, guild, listed, ticked }
function M.PSS_PlayerPickerItems(found, into)
	into = into or {}
	for i = #into, 1, -1 do into[i] = nil end
	for _, p in ipairs(found or {}) do
		into[#into + 1] = { name = p.name, level = p.level, class = p.class, guild = p.guild,
			listed = M.PSS_IsPlayerListed(p.name) and true or false }
	end
	return into
end

function M.PSS_PlayerPickerTitle(n, query)
	return ("Player Search: %d player(s) found for \"%s\". Click the players to add."):format(n, query or "")
end

-- one cell's text for a picker entry (level, class, guild)
function M.PSS_PlayerPickerCells(it, into)
	into.name = it.name or ""
	into.level = it.level and tostring(it.level) or ""
	into.class = it.class or ""
	into.guild = it.guild or ""
	return into
end

-- Add the ticked players; the number added
function M.PSS_PlayerPickerSave(items)
	local n = 0
	for _, it in ipairs(items) do
		if it.ticked and not it.listed then
			M.PSS_AddPlayer(it.name, "", 0)
			n = n + 1
		end
	end
	if n > 0 then M.PSS_Say(("%d player(s) added to the Player Ignore List."):format(n)) end
	return n
end

-- Nobody found: the question to ask and the name to add anyway (nil: none)
function M.PSS_PlayerNoneFound(query)
	local name = M.trim(((query or ""):gsub('"', ""))) or ""
	if name == "" then return nil end
	return ("No player named <%s> was found online.\n\nAdd them to the Player Ignore List anyway?"):format(name), name
end

function M.PSS_PlayerAddAnyway(name)
	M.PSS_AddPlayer(name, "", 0)
	M.PSS_Say(("<%s> added to the Player Ignore List."):format(name))
end

------------------------------------------------------------------------
-- Prune: remove the entries listed for a number of days or more
------------------------------------------------------------------------
M.PSS_PRUNE_DAYS = 365

function M.PSS_PruneText()
	return "Remove every entry on the Player Ignore List that was added this many days ago or more?\n\nThey go at once, with their notes, settings and block history."
end

-- the line under the days box: how many entries that would remove
function M.PSS_PruneNote(days)
	days = tonumber(days)
	if not days or days < 1 then return "Type a number of days (1 or more)." end
	local n = M.PruneIgnoreList(math.floor(days), false)
	return ("%d entr%s listed for %d day%s or more."):format(n, n == 1 and "y" or "ies", math.floor(days), math.floor(days) == 1 and "" or "s")
end

-- the number removed (the core prints how many)
function M.PSS_PruneApply(days)
	days = tonumber(days)
	if not days or days < 1 then return 0 end
	return M.PruneIgnoreList(math.floor(days), true)
end

-- the expiry box of entry (days, 0 = never); true if it changed
function M.PSS_PlayerCommitExpiry(entry, text)
	local pos, days = M.PSS_PlayerPosition(entry), tonumber(text)
	if pos <= 0 or not days then return false end
	local r = M.PSS_PlayerRow(pos, {})
	if r and days == r.expire then return false end
	M.PSS_SetExpiry(pos, days)
	M.PSS_PlayersChanged()
	return true
end

function M.PSS_PlayerCommitNote(entry, text)
	local pos = M.PSS_PlayerPosition(entry)
	text = M.trim(text or "") or ""
	if pos <= 0 then return false end
	local r = M.PSS_PlayerRow(pos, {})
	if r and text == (r.note or "") then return false end
	M.PSS_SetNote(pos, text)
	M.PSS_PlayersChanged()
	return true
end

-- W I G P C: ticked = allowed; the record stores "blocked"
-- a W I G P C tick: is it allowed (the record stores false for allowed)
function M.PSS_PlayerAllowed(p, field)
	return type(p) == "table" and p[field] == false
end

function M.PSS_PlayerToggleAllowed(entry, field, allowed)
	if not entry then return end
	M.PSS_SetPlayerSetting(entry, field, not allowed)
	M.PSS_PlayersChanged()
end

function M.PSS_PlayerAddGuild(guild)
	if type(guild) ~= "string" or guild == "" then return end
	M.PSS_AddGuild(guild)
	M.ShowMsg(("Added <%s> to the Guild Ignore List."):format(guild))
end

------------------------------------------------------------------------
-- Events specs: one player, or every listed player (the Events tab reads
-- them; nothing here loads PourSocialScore_Logging)
------------------------------------------------------------------------
local allPlayers

function M.PSS_AllPlayersSpec()
	if allPlayers then return allPlayers end
	allPlayers = {
		kind = "player", id = false, allText = "All Players", source = "players",
		label = function() return "All Players" end,
		read = M.PSS_ListedPlayerEvents,
		reset = M.PSS_ResetListedPlayerEvents,
	}
	return allPlayers
end

function M.PSS_PlayerEventsSpec(entry)
	return {
		kind = "player", id = entry, allText = "All Players", all = M.PSS_AllPlayersSpec,
		label = function(e) return M.PSS_PlayerPosition(e) > 0 and e or nil end,
		read = M.PSS_GetPlayerBlockHistory,
		reset = M.PSS_ResetPlayerBlockHistory,
		owner = M.PSS_PlayerHistoryKey, counts = M.PSS_GetPlayerBlockCounts,
	}
end
