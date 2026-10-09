------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PLAYER LIST NOTICES (3.1)
--
-- The two small player list calls core itself makes (menu clicks). The rows,
-- sorting and removal for the windows are in PourSocialScore_Libraries
-- (PSS_PlayerRows.lua, 3.4.1 P6).
--   M.PSS_IsGuildListed(guild)            the guild is on the Guild Ignore List
--   M.PSS_PlayersChanged(forced)          the one refresh entry: every front
--                                         end that is loaded redraws its
--                                         players (forced: re-sort)
------------------------------------------------------------------------
local addonName, addon = ...
local M = addon.M

function M.PSS_IsGuildListed(guild)
	if type(guild) ~= "string" or guild == "" then return false end
	local data = PourSocialScoreDB.guildData
	local key = M.PSS_NormalizeGuild(guild)
	return (data and key and data[key]) and true or false
end

function M.PSS_PlayersChanged(forced)
	M.Events.Fire("PLAYERS_CHANGED", forced)
end

-- The rest of the list's calls are in Libraries (PSS_PlayerRows.lua). Only a
-- window or a command uses them; a caller that gets there first loads it.
for _, fname in ipairs({ "PSS_PlayerCount", "PSS_PlayerRow", "PSS_PlayerEntry", "PSS_PlayerPosition", "PSS_SortPlayers", "PSS_RemovePlayerAt" }) do
	M.PSS_Stub(fname, "Libraries")
end
