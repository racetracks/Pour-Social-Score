------------------------------------------------------------------------
-- POUR SOCIAL SCORE - SLASH COMMANDS
--
-- The chat front end: /pss (the Player Ignore List from chat, help and
-- options) and /pssguild (guild list diagnostics). Both only read and
-- print; the work is done by the core functions they call
-- (PSS_PlayerIgnoreList.lua, PSS_GuildIgnoreList.lua, PSS_ChatBlock.lua).
-- In PourSocialScore_Libraries: the core registers /pss and /pssguild and
-- loads this addon on the first command (PourSocialScore.lua).
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local L = addon.L
local V = addon.V
local M = addon.M

local RemoveFromList		= M.PSS_RemoveFromList
local isServerMatch			= M.PSS_IsServerMatch
local ResetIgnoreDB			= M.PSS_ResetIgnoreDB
local ResetBlizzardIgnore	= M.PSS_ResetBlizzardIgnore
local trim					= M.PSS_Trim
local canonPlayer			= M.PSS_CanonPlayer
local lookupGuildMember		= M.PSS_LookupGuildMember
local ensureDB				= M.PSS_EnsureGuildDB

local firstClear		= false

-------------------
-- /pss          --
-------------------

local function OnOff (value)
	if value == nil or value == false then
		return "|cffffff00" .. L["OFF"] .. "|cffffffff"
	elseif value == true then
		return "|cffffff00" .. L["ON"] .. "|cffffffff"
	else
		return "|cffff0000nil"
	end
end

local function ShowIgnoreList (param)
	-- the list shown has no expired entries (N40)
	M.PSS_ExpireEntries()
	local days		= tonumber(param)
	local sName		= ""

	if not days then

		days	= 0
		sName = param

		if not sName then
			sName = ""
		end
	end

	if days > 0 then
		M.ShowMsg("|cffffff00" .. format(L["LIST_1"], days))
	else
		if sName ~= "" then
			sName = M.Proper(sName)

			if sName == "Npc" then
				M.ShowMsg("|cffffff00".. L["LIST_2"])
			else
				if sName == "Server" then
					sName = V.serverName
				end

				M.ShowMsg("|cffffff00" .. format(L["LIST_3"], sName))
			end
		else
			M.ShowMsg("|cffffff00" .. L["LIST_4"])
		end
	end

	local count = 0

	for key,entry in ipairs(PourSocialScoreDB.list) do

		local ok	= true
		local type = "P"
		local value = entry.name

		if entry.kind == "npc" then
			type = "N"
		elseif entry.kind == "server" then
			type = "S"
		end

		if days > 0 then
			ok = M.daysFromToday(entry.date) >= days
		elseif sName ~= "" then
			ok = (type == "N" and sName == "Npc") or (type == "P" and isServerMatch(sName, M.getServer(value))) or (type == "S" and isServerMatch(sName, value))
		end

		if ok then
			local str = "  (" .. key .. ") [" .. type.. "] " .. value .. " (" .. (entry.faction or "Unknown") .. ") " .. "[".. M.daysFromToday(entry.date) .. " "..L["DAYS"] .. "]"

			-- older saves and the legacy import can have no note (N48);
			-- (type is the entry's letter here, not the function)
			local note = entry.note
			if note ~= nil and note ~= "" then
				str = str .." (" .. tostring(note) .. ")"
			end

			M.ShowMsg(str)

			count = count + 1
		end

	end

	M.ShowMsg("|cffffff00" .. format(L["LIST_5"], count))
end

-- /pss on its own opens (or closes) the window; these words are the same
-- command (Dan, 2026-10-08). Every other word is a command of its own, and
-- one /pss does not know (/pss help) lists them.
local OPEN = { gui = true, ui = true, eui = true }

function M.PSS_SlashPSS (msg)

	-- Keywords are matched in lower case; everything after the command word
	-- (names, notes) keeps the case it was typed in (2.0.8 lowercased notes).
	local raw = M.trim(msg or "")
	msg = M.strDown(raw)

	local args, rawArgs = {}, {}
	for w in msg:gmatch("%S+") do args[#args + 1] = w end
	for w in raw:gmatch("%S+") do rawArgs[#rawArgs + 1] = w end
	local argStr = (#rawArgs >= 2) and table.concat(rawArgs, " ", 2) or ""
	msg = table.concat(args, " ")

	if not args[1] or OPEN[args[1]] then

		M.PSS_OpenUI()

	elseif args[1] == "clear" then

		if firstClear and args[2] ~= nil and args[2] == "confirm" then
			ResetIgnoreDB()
			ResetBlizzardIgnore()
			M.ShowMsg(L["CMD_2"])
			--M.SyncIgnoreList(M.PSS_Opt("chatmsg") == false)
			firstClear = false
		else
			M.ShowMsg("|cffff0000" .. L["CMD_1"])
			firstClear = true
		end

	elseif args[1] == "defexpire" then

		if tonumber(args[2]) then
			M.PSS_SetOpt("defexpire", "global", tonumber(args[2]))

			M.ShowMsg (format(L["CMD_3"], M.PSS_Opt("defexpire"), M.dayString(M.PSS_Opt("defexpire"))))
		end

	elseif msg == "asknote true" or msg == "asknote on" then

		M.PSS_SetOpt("asknote", "global", true)
		M.ShowMsg (L["CMD_4"])

	elseif msg == "asknote false" or msg == "asknote off" then

		M.PSS_SetOpt("asknote", "global", false)
		M.ShowMsg (L["CMD_5"])

	elseif msg == "showmsg true" or msg == "showmsg on" then

		M.PSS_SetOpt("chatmsg", "global", true)
		M.ShowMsg (L["CMD_6"])

	elseif msg == "showmsg false" or msg == "showmsg off" then

		M.PSS_SetOpt("chatmsg", "global", false)
		M.ShowMsg (L["CMD_7"])

	elseif msg == "sameserver true" or msg == "sameserver on" then

		M.PSS_SetOpt("sameserver", "global", true)
		M.ShowMsg(L["CMD_10"])

	elseif msg == "sameserver false" or msg == "sameserver off" then

		M.PSS_SetOpt("sameserver", "global", false)
		M.ShowMsg(L["CMD_11"])

	elseif args[1] == "list" then

		ShowIgnoreList(argStr)

	elseif (args[1] == "add" or args[1] == "ignore") then

		M.ignoreFromCmd(argStr)

	elseif (args[1] == "remove" or args[1] == "delete") and args[2] ~= nil and args[2] ~= "" then

		if tonumber(argStr) then
			-- by list position, whatever the entry type (player, NPC or server)
			local index = tonumber(argStr)
			local str = PourSocialScoreDB.list[index] and (PourSocialScoreDB.list[index].kind or "player")

			if str == "npc" then
				M.AddOrDelNPC(index)
			elseif str == "server" then
				M.AddOrDelServer(index)
			elseif str == "player" then
				M.PSS_DelIgnore(index, true)
			end
			M.PSS_PlayersChanged(true)
		else
			argStr = M.Proper(argStr, true)

			local npcIndex = M.hasNPCIgnored(argStr)

			if npcIndex > 0 then
				M.ShowMsg (format(L["CMD_12"], argStr))
				RemoveFromList(npcIndex)
				M.PSS_PlayersChanged(true)
			else
				M.PSS_DelIgnore ((M.PSS_SplitNameArg(argStr)), true)
			end
		end

	elseif (args[1] == "server" or args[1] == "addserver") and args[2] ~= nil and args[2] ~= "" then

		M.AddOrDelServer(argStr)
		M.PSS_PlayersChanged(true)

	elseif (args[1] == "npc" or args[1] == "addnpc") then

		M.AddOrDelNPC(argStr)
		M.PSS_PlayersChanged(true)

	elseif args[1] == "expire" and #args >= 3 and tonumber(args[#args]) then
		-- "/pss expire First Last-Realm 30" or "/pss expire \"First Last\" 30"
		local days = args[#args]
		args[2] = M.PSS_SplitNameArg((argStr:gsub("%s*%S+$", "")))
		args[3] = days

		if tonumber(args[2]) then
			local index = tonumber(args[2])

			if (index > 0) and (PourSocialScoreDB.list[index]) then

				M.PSS_SetExpiry(index, tonumber(args[3]))
				M.ShowMsg(format(L["CMD_14"], PourSocialScoreDB.list[index].name, tonumber(args[3])))
			end

		else
			local name			= M.Proper(M.addServer(args[2]))
			local playerIndex = M.hasGlobalIgnored(name)
			if playerIndex > 0 then name = PourSocialScoreDB.list[playerIndex].name end

			if playerIndex > 0 then
				M.PSS_SetExpiry(playerIndex, tonumber(args[3]))
				M.ShowMsg(format(L["CMD_14"], name, tonumber(args[3])))
			end
		end

	elseif args[1] == "mem" or args[1] == "memory" then

		if M.PSS_MemReport then M.PSS_MemReport(args[2] == "full") end

	elseif args[1] == "check" then

		M.PSS_PrintValidation()

	elseif msg == "export unused" then

		-- the saved rules this version cannot use, to keep outside the game
		-- (core uplift U3); the window's copy box, the window stays closed
		local text = M.PSS_UnusedExportText()
		if not text then
			M.ShowMsg(L["UNUSED_NONE"])
		elseif M.PSS_Need("GUI") and M.PSS_CopyTextBox then
			M.PSS_CopyTextBox("Rules Not Used", ("Copy the string below (%d characters) and keep it: a version that knows these rules imports it"):format(#text), text)
		end

	elseif args[1] == "sync" then

		M.SyncIgnoreList(false)

	elseif args[1] == "dellist" then

		for count = 1, #PourSocialScoreDB.delList do
			print(PourSocialScoreDB.delList[count])
		end

	elseif args[1] == "prune" then

		-- "/pss prune 90" removes straight away (no confirmation)
		if args[2] == nil or tonumber(args[2]) == nil then
			M.ShowMsg(L["CMD_15"])
		else
			M.PruneIgnoreList(tonumber(args[2]), true)
		end

	else
		M.ShowMsg (L["HELP_1"])
		M.ShowMsg ("")
		M.ShowMsg ("  " .. L["HELP_2"])
		M.ShowMsg ("  " .. L["HELP_3"])
		M.ShowMsg ("  " .. L["HELP_4"])
		M.ShowMsg ("  " .. L["HELP_5"])
		M.ShowMsg ("  " .. L["HELP_6"])
		M.ShowMsg ("  " .. L["HELP_7"])
		M.ShowMsg ("  " .. L["HELP_8"])
		M.ShowMsg ("  " .. L["HELP_15"])
		M.ShowMsg ("  " .. L["HELP_16"])
		M.ShowMsg ("  " .. L["HELP_17"])
		M.ShowMsg ("  " .. L["HELP_18"])
		M.ShowMsg ("  " .. L["HELP_19"])
		M.ShowMsg ("  " .. L["HELP_9"])
		M.ShowMsg ("")
		M.ShowMsg ("  " .. format(L["HELP_10"], OnOff(M.PSS_Opt("chatmsg"))))
		M.ShowMsg ("  " .. format(L["HELP_11"], OnOff(M.PSS_Opt("sameserver"))))
		M.ShowMsg ("  " .. format(L["HELP_12"], M.PSS_Opt("defexpire")))
		M.ShowMsg ("  " .. format(L["HELP_13"], OnOff(M.PSS_Opt("asknote"))))
		M.ShowMsg ("")
		M.ShowMsg (L["HELP_14"])
	end
end

------------------------------------------------------------------------
-- DIAGNOSTICS: /pssguild [status | test | chat | debug [all] | check]
------------------------------------------------------------------------
local function gp(msg) M.ChatMsg("|cff33ff99PSS guild:|r " .. msg) end

function M.PSS_SlashGuild (msg)
	msg = trim(msg or "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()
	ensureDB()
	local stats, dbg = M.PSS_CoreStats or {}, M.PSS_CoreDebug or {}

	if cmd == "debug" then
		if rest:lower() == "all" then
			dbg.allUntil = GetTime() + 120
			gp("debug ALL for 2 minutes: every chat line checked is reported, listed or not.")
			return
		end
		dbg.on = not dbg.on
		dbg.allUntil = 0
		gp("debug " .. (dbg.on and "ON - every line from a listed player or guild member is reported." or "OFF"))
		return
	end

	if cmd == "test" then
		-- Dry run across EVERY list (player + guild). Nothing is recorded.
		local name = rest
		if name == "" and UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target") then
			name = M.PSS_UnitFullName("target")
		end
		if not name or name == "" then gp("usage: /pssguild test Name-Realm   (or target the player and type /pssguild test)") return end
		local ex = M.PSS_ExplainPerson(name)
		gp(("test %q -> lookup key %q"):format(name, tostring(ex.canon)))
		if #ex.sources == 0 then
			gp("|cffff5555NOT BLOCKED|r: not on the Player Ignore List and not stored under any guild rule.")
			gp("Guild rules only block characters captured by a guild Scan (or a guild invite). Run Scan (or Scan All) / Custom Scan on the guild, then /pssguild check " .. name)
			return
		end
		local labels = { whisper = "Whispers", partyRaid = "Party/Raid", world = "World chat", guildChat = "Guild chat",
						partyInvite = "Party invite", guildInvite = "Guild invite", duel = "Duel", trade = "Trade" }
		local order = ex.order
		local any = {}
		for _, row in ipairs(ex.sources) do
			gp("listed: " .. tostring(row.describe or row.src.label))
			for _, cat in ipairs(order) do if row.blocked[cat] then any[cat] = true end end
		end
		for _, cat in ipairs(order) do
			gp(("  %-13s %s"):format(labels[cat], any[cat] and "|cff00ff00BLOCKED|r" or "|cffff5555shown|r"))
		end
		gp("A message is hidden if ANY list blocks it. If this says BLOCKED but you still see it, run /pssguild chat.")
		return
	end

	if cmd == "chat" then
		local CFU = type(ChatFrameUtil) == "table" and ChatFrameUtil or nil
		local getFilters = (CFU and CFU.GetMessageEventFilters) or ChatFrame_GetMessageEventFilters
		gp(("filter registration API: %s"):format(M.PSS_FilterAvailable and "found" or "|cffff5555MISSING - chat blocking cannot work|r"))
		for _, ev in ipairs({ "CHAT_MSG_WHISPER", "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_PARTY" }) do
			local list = getFilters and getFilters(ev)
			local ours, n = false, 0
			if type(list) == "table" then
				for _, fn in pairs(list) do n = n + 1; if fn == M.PSS_CoreFilter then ours = true end end
			end
			local frames, shown = 0, 0
			for i = 1, (tonumber(NUM_CHAT_WINDOWS) or 10) do
				local cf = _G["ChatFrame" .. i]
				if type(cf) == "table" and cf.IsEventRegistered and cf:IsEventRegistered(ev) then
					frames = frames + 1
					if cf:IsShown() then shown = shown + 1 end
				end
			end
			gp(("  %-17s filters: %s, ours: %s | Blizzard chat windows listening: %d (%d shown)"):format(
				ev, getFilters and tostring(n) or "?", getFilters and (ours and "|cff00ff00yes|r" or "|cffff5555NO|r") or "?", frames, shown))
		end
		local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
		local found = {}
		if isLoaded then
			for _, a in ipairs({ "Chattynator", "Prat-3.0", "Glass", "Chatter", "WIM", "ElvUI", "EllesmereUI", "BasicChatMods", "OlympusMute", "Asmonmute", "AsmonMute" }) do
				if isLoaded(a) then found[#found + 1] = a end
			end
		end
		gp("chat addons loaded: " .. (#found > 0 and table.concat(found, ", ") or "none detected"))
		gp("If Blizzard chat windows show 0 listening, another addon is drawing chat itself. Messages only disappear if that addon applies Blizzard's chat filters.")
		local lc = stats.lastChecked
		if lc and lc.event then gp(("last line checked: %s from %s, %d s ago"):format(lc.event, tostring(lc.name), math.floor(GetTime() - lc.at))) end
		return
	end

	if cmd == "check" then
		if rest == "" then gp("usage: /pssguild check Name-Realm") return end
		local ck = canonPlayer(rest)
		gp(("check %q -> lookup key %q"):format(rest, tostring(ck)))
		local g, gkey, m, storedKey = lookupGuildMember(rest)
		if g then
			local c = M.PSS_GetMemberBlockCounts(m)
			gp(("FOUND under rule <%s>, stored as %q, actual guild %q"):format(
				tostring(g.name), tostring(storedKey), tostring(M.PSS_MemberGuildName(m, g))))
			gp(("exclusions (red = blocked): %s   guild: %s | blocked: W %d, PI %d, P/R %d, World %d, GI %d"):format(
				M.PSS_ExclusionText(g, m), M.PSS_ExclusionText(g), c.whisper, c.partyInvite, c.partyRaid, c.world, c.guildInvite))
		else
			gp("NOT FOUND in any guild rule. Stored members with the same character name:")
			local base = (rest:match("^([^%-]+)") or rest):lower()
			local n = 0
			for gk, gg in pairs(PourSocialScoreDB.guildData or {}) do
				for k, mm in pairs((type(gg) == "table" and gg.members) or {}) do
					if type(k) == "string" and k:match("^([^%-]+)") == base then
						n = n + 1
						gp(("  <%s> key %q name %q -> lookup key %q"):format(tostring(gg.name or gk), k,
							tostring(type(mm) == "table" and M.PSS_MemberName(mm, k)), tostring(canonPlayer(k))))
					end
				end
			end
			if n == 0 then gp("  none - this character has not been captured by a scan or invite yet.") end
		end
		if M.PSS_IsPlayerListed and M.PSS_IsPlayerListed(rest) then gp("also on the Player Ignore List.") end
		return
	end

	-- status (default)
	local bySrc = {}
	for id, n in pairs(stats.bySource or {}) do bySrc[#bySrc + 1] = id .. " " .. n end
	gp(("chat filter: %s | this session: %d lines checked, %d from listed people, %d hidden (%s), %d errors | all-time hidden: %d"):format(
		M.PSS_FilterAvailable and "registered" or "|cffff5555MISSING|r", stats.checked or 0, stats.personHits or 0, stats.hidden or 0,
		#bySrc > 0 and table.concat(bySrc, ", ") or "-", stats.errors or 0, tonumber(PourSocialScoreDB.hiddenTotal) or 0))
	if stats.lastError then gp("last error: " .. stats.lastError) end
	local le = M.Events.errors
	if le and le.count > 0 then gp(("listener errors: %d | last: %s"):format(le.count, tostring(le.last))) end
	local gcs = M.PSS_GCState
	if gcs then
		local heap = (pcall(collectgarbage, "count") and collectgarbage("count") or 0) / 1024
		gp(("memory cleanup: %s, %d cycle(s) this session%s | game Lua heap (all addons): %.1f MB"):format(
			(M.PSS_Opt("gcEnabled") == false and "off") or (gcs.supported and (gcs.running and "running now" or "idle") or "not supported by this client"),
			gcs.cycles or 0, gcs.lastReason and (", last: " .. gcs.lastReason) or "", heap))
	end
	local list = {}
	for k, g in pairs(PourSocialScoreDB.guildData or {}) do if type(g) == "table" then list[#list + 1] = { k = k, g = g } end end
	table.sort(list, function(a, b) return tostring(a.g.name or a.k) < tostring(b.g.name or b.k) end)
	if #list == 0 then gp("no guild rules.") end
	for _, it in ipairs(list) do
		local n = 0
		for _ in pairs(it.g.members or {}) do n = n + 1 end
		local c = M.PSS_GetGuildBlockCounts(it.k)
		gp(("<%s> %s, %d members | W %d, PI %d, P/R %d, World %d, GI %d"):format(
			tostring(it.g.name or it.k), M.PSS_ExclusionText(it.g), n,
			c.whisper, c.partyInvite, c.partyRaid, c.world, c.guildInvite))
	end
	gp("commands: /pssguild test Name-Realm  |  /pssguild chat  |  /pssguild debug [all]  |  /pssguild check Name-Realm")
end
