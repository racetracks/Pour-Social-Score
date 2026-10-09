------------------------------------------------------------------------
-- POUR SOCIAL SCORE - EVENTS
--
-- A tiny register / fire list, so the core (data, /who) can say
-- "something changed" without knowing which UI is loaded. Any UI - this
-- addon's own windows or another addon - listens with Register.
--
--   local id = M.Events.Register("WHOIS_COOLDOWN", function(active) ... end)
--   M.Events.Unregister("WHOIS_COOLDOWN", id)
--   M.Events.Fire("WHOIS_COOLDOWN", true)
--
-- Events fired so far:
--   WHOIS_COOLDOWN (active)      the shared /who cooldown started (true) or ended (false)
--   WHOIS_ANSWERED (req)         a /who answer (or a timeout) was handled; req may be nil
--   ASK_NOTE (name)              a player was just listed and Options asks for a note
--   GROUP_WARNING (names)        listed players are in your group (list of names)
--   WHISPER_WARNING (name, list) you whispered a player whose whispers a list blocks
--   PLAYERS_CHANGED (forced)     the Player Ignore List changed (forced: re-sort)
--   PLAYER_BLOCKED               a listed player's block counts went up
--   FILTERS_CHANGED              chat filters or their counts changed
--   FILTER_HISTORY_CHANGED (n)   chat filter n blocked a line or was reset
--   GUILDS_CHANGED               guild rules or members changed
--   GUILD_BLOCKS_CHANGED         guild block counts changed (at most 4 a second)
--   GUILD_SCAN_DONE              a /who answer was stored under the guild rules
--   GUILD_REMOVED (key)          a guild rule was removed
--   GUILD_SEARCH_RESULTS (list, query, mode, owner)  Guild Search found these guilds
--   OPTION_CHANGED (key)         an option was set (any scope)
------------------------------------------------------------------------
local addonName, addon = ...
local M = addon.M

local Events = {}
M.Events = Events

local listeners = {}	-- [event] = { [id] = fn }
local nextId = 0

function Events.Register(event, fn)
	nextId = nextId + 1
	listeners[event] = listeners[event] or {}
	listeners[event][nextId] = fn
	return nextId
end

function Events.Unregister(event, id)
	if listeners[event] then listeners[event][id] = nil end
end

-- A listener (or /who handler) that errors is reported in chat the first
-- time for each event name, and counted for /pssguild status (N46).
local errors = { count = 0, last = nil, shown = {} }
Events.errors = errors

function M.PSS_NoteListenerError(where, err)
	errors.count = errors.count + 1
	errors.last = where .. ": " .. tostring(err)
	if not errors.shown[where] then
		errors.shown[where] = true
		M.ChatMsg("|cffff5555Pour Social Score error in " .. where .. " (shown once, see /pssguild status):|r " .. tostring(err))
	end
end

-- A listener that errors does not stop the others.
function Events.Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for _, fn in pairs(list) do
		local ok, err = pcall(fn, ...)
		if not ok then M.PSS_NoteListenerError(event, err) end
	end
end
