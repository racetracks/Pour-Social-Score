------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE SCHEMA MAP (core uplift U3, 3.4.1.47)
--
-- Data only: every field PSS saves, so a save written by a newer version
-- works in an older one and the reverse (10_CORE_UPLIFT.md 2.3).
--   * The top-level keys are LAYOUT (PSS_SavedData.lua: which table holds
--     each), every option in M.PSS_OPTIONS, and "core" below (the keys
--     PourSocialScoreDB keeps itself).
--   * Each record kind lists its fields as "name", "name=default" or
--     "name@reader" (the function that reads it, when it is not read
--     straight off the record); "old" lists the fields older versions saved
--     that this one still reads once to convert, and never writes.
--   * A field nobody lists is a newer version's: readers ignore it, nothing
--     deletes it (only RETIRED keys are ever dropped, PSS_Upgrade.lua), and
--     the export copies it. A guild rule holding one is not applied and is
--     reported (M.PSS_UnusableRules).
-- tools/check_schema.lua fails a field the code writes that is not here.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

M.PSS_SCHEMA = {
	-- PourSocialScoreDB's own keys (the rest are routed, LAYOUT)
	core = "upgrade outbox purge recent session sessionStart revision imported importedFrom importedLegacyAt logAllV1",
	-- PourSocialScoreDB.upgrade
	upgrade = "step=0 version at",
	-- PSS_PlayersDB.list[i], one record per listed player, NPC or server
	-- (S2b; the arrays ignoreList, typeList, factionList, dateList, notes,
	-- expList and syncInfo are read once by the upgrade and dropped)
	entry = "name date kind=player faction note exp=0 sync",
	-- PSS_PlayersDB.playerData[key] (a W I G P C switch is saved only when it is
	-- false; a missing one blocks, 3.4.1.52)
	player = "name nickname faction class className whenBlocked currentGuild guildWhenBlocked lastBlockedInvite"
		.. " whispersBlocked=true partyInvitesBlocked=true guildInvitesBlocked=true partyRaidBlocked=true channelsBlocked=true"
		.. " blizzardIgnore=false blockCounts@PSS_GetPlayerBlockCounts opts@PSS_Opt",
	playerOld = "note expireDays online blockHistory blockedWhispers blockedInvites blockedWhisperMessages"
		.. " blockedPrivateMessages blockedChatMessages",
	-- PSS_GuildsDB.guildData[key]
	guild = "name enabled=true declineGuild=true declineGroup=true partyRaid=true block@PSS_GuildBlock"
		.. " customScan@PSS_MigrateCustomScan members managed managedGone ruleOrigin opts@PSS_Opt",
	-- (memberCount: worked out by M.PSS_GuildMemberCount since 3.4.1.52, no longer saved)
	guildOld = "memberCount levelStart levelEnd levelBrackets scan scanTotal scanBrackets blockHistory blockedWhispers"
		.. " blockedPrivateMessages blockedChatMessages blockedInvites",
	-- PSS_GuildsDB.guildData[key].members[key] (saved sparse since 3.4.1.52:
	-- name, guild and whenBlocked only when the key, the rule and the shipped
	-- list do not give them; every reader goes through the M.PSS_Member*
	-- accessors, S2; the _ fields are runtime fields older builds saved)
	member = "name@PSS_MemberName guild@PSS_MemberGuildName whenBlocked@PSS_MemberWhenBlocked note class faction level lastBlockedInvite block@PSS_MemberBlock"
		.. " blockCounts@PSS_EnsureMemberBlockData opts@PSS_Opt excludedGroup=false excludedGuildInvite=false"
		.. " excludedWhispers=false excludedChat=false _blockV2",
	memberOld = "_playerKey _canon _gkey _managed _virtual online race className blockHistory blockedWhispers blockedPrivateMessages privateMessagesBlocked"
		.. " blockedChatMessages chatMessagesBlocked blockedInvites partyInvitesBlocked partyRaidMessagesBlocked",
	-- W I G P C (guild and member .block; true = blocked, a member's nil = its guild's)
	block = "whisper=true partyInvite=true guildInvite=true partyRaid=true world=true",
	-- every .blockCounts / .counts (History.EnsureCounts: a missing type is
	-- 0; History.CountTotal: total is never less than the types added up)
	counts = "total@CountTotal whisper=0 partyInvite=0 guildInvite=0 partyRaid=0 world=0 guildChat=0 unknown=0",
	-- PSS_CountsDB.filterBlocked[i] and builtinStats[id]
	filterStat = "counts@PSS_FilterCounts",
	builtinStat = "count=0 blocked blockedLast=0",
	-- a block history line (PSS_LoggingDB.blockLog[i], blockKeep[o][i], outbox[i])
	line = "o ts cat event channel member message gk r",
	lineOld = "time kind",
	-- a saved log group (blockLog[o] from 3.2.0-dev007; lines in its array part;
	-- m only when it is not the owner key's own form, 3.4.1.52)
	logGroup = "c gk m n k r",
}
