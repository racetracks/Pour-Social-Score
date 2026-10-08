------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PLAYER IGNORE LIST
--
-- The account-wide ignore list (players, NPCs, servers), its sync with
-- Blizzard's ignore list, the /pss command, per-player block settings and
-- history, and the "player" person source + system / NPC / realm handlers
-- the core (PSS_ChatBlock.lua) uses.
------------------------------------------------------------------------
local addonName, addon = ...
local L = addon.L
local V = addon.V
local M = addon.M

local doLoginIgnore		= true
local maxIgnoreSize		= 50
local maxSyncTries		= 3
local maxHistorySize	= 250

local BlizzardAddIgnore			= nil
local BlizzardDelIgnore			= nil
local BlizzardDelIgnoreByIndex = nil

-- faction is learned at startup (V.faction)
local function currentFaction() return V.faction or (UnitFactionGroup and UnitFactionGroup("player")) end

local function hasDeleted (name)

	if not name then return 0 end

	for count = 1, #PourSocialScoreDB.delList do
		--M.debugMsg("Comparing " .. PourSocialScoreDB.delList[count] .. " to " .. name)

		if PourSocialScoreDB.delList[count] == name then
			M.debugMsg("Has deleted TRUE for " .. name)
			return count
		end
	end

	M.debugMsg("Has deleted false for " .. name)

	return 0
end

local function addDeleted (name)

	local idx = hasDeleted(name)

	M.debugMsg("addDeleted: hasDeleted " .. idx)

	if idx == 0 then
		if #PourSocialScoreDB.delList >= maxHistorySize then
			table.remove(PourSocialScoreDB.delList, 1)
		end

		M.debugMsg("Adding " .. name .. " (".. idx .. ") to delete list")

		PourSocialScoreDB.delList[#PourSocialScoreDB.delList + 1] = name
	end
end

local function removeDeleted (name)
	local idx = hasDeleted(name)

	if idx > 0 then
		M.debugMsg("Removing " .. name .. " (".. idx .. ") from delete list")
		table.remove(PourSocialScoreDB.delList, idx)

		local idx = hasDeleted(name)
		M.debugMsg("After removal idx " .. idx)
	end
end

-- W I G P C switches on a player record (stored as "blocked").
local BLOCK_FIELDS = { "whispersBlocked", "partyInvitesBlocked", "guildInvitesBlocked", "partyRaidBlocked", "channelsBlocked" }

local function anyBlocked(p)
	if type(p) ~= "table" then return false end
	for _, f in ipairs(BLOCK_FIELDS) do if p[f] == true then return true end end
	return false
end
M.PSS_PlayerBlocksAnything = anyBlocked

-- Adding someone to the list opts them IN to blocking: everything from them
-- is blocked. The W I G P C boxes are per-player EXCLUSIONS and start
-- unticked; tick one to let that one thing through.
local function AddToList(newname, newfaction, newnote, newtype)

	local index = #PourSocialScoreDB.ignoreList+1

	PourSocialScoreDB.ignoreList[index] = newname
	PourSocialScoreDB.factionList[index] = newfaction
	PourSocialScoreDB.dateList[index] = date("%d %b %Y")
	PourSocialScoreDB.notes[index] = (newnote or "")
	PourSocialScoreDB.expList[index] = M.PSS_Opt("defexpire")
	PourSocialScoreDB.typeList[index] = (newtype or "player")
	PourSocialScoreDB.syncInfo[index] = {}

	local p
	if newtype == nil or newtype == "player" then
		if M.PSS_GetPlayerPrefs then
			p = M.PSS_GetPlayerPrefs(newname)
			if p then
				-- a fresh listing blocks everything (no exclusions), even if an
				-- older record for this name is still stored from an earlier listing
				for _, f in ipairs(BLOCK_FIELDS) do p[f] = true end
			end
		end
	end

	removeDeleted(newname)
	if M.PSS_MarkIgnoreIndexDirty then M.PSS_MarkIgnoreIndexDirty() end
	if (newtype == nil or newtype == "player") and M.PSS_CanonPlayer and anyBlocked(p) then
		-- hide what they already said (OlympusMute-style), and decline an
		-- invite from them that is still open
		local c = M.PSS_CanonPlayer(newname)
		if c and M.PSS__purgeBatch then M.PSS__purgeBatch[c] = true
		elseif c and M.PSS_PurgeChatFrom then M.PSS_PurgeChatFrom({ [c] = true }) end
		if M.PSS_PersonIdentified then M.PSS_PersonIdentified(newname) end
	end

	M.PSS_LFG_Refresh()
end

local function RemoveFromList (index)
	local name = PourSocialScoreDB.ignoreList[index]
	if name then
		addDeleted(name)
		if (PourSocialScoreDB.typeList[index] or "player") == "player" and M.PSS_ForgetPlayer then
			M.PSS_ForgetPlayer(name, PourSocialScoreDB.notes[index])
		end

		table.remove(PourSocialScoreDB.ignoreList, index)
		table.remove(PourSocialScoreDB.factionList, index)
		table.remove(PourSocialScoreDB.dateList, index)
		table.remove(PourSocialScoreDB.notes, index)
		table.remove(PourSocialScoreDB.expList, index)
		table.remove(PourSocialScoreDB.typeList, index)
		table.remove(PourSocialScoreDB.syncInfo, index)
		if M.PSS_MarkIgnoreIndexDirty then M.PSS_MarkIgnoreIndexDirty() end
	end
end
M.PSS_RemoveFromList = RemoveFromList


-- Import/Export entry points (PSS_ImportExport.lua)
function M.PSS_ImportListEntry(name, faction, note, ltype, dateStr, exp)
	AddToList(name, faction ~= "" and faction or nil, note, ltype)
	local i = #PourSocialScoreDB.ignoreList
	if type(dateStr) == "string" and dateStr ~= "" then PourSocialScoreDB.dateList[i] = dateStr end
	if tonumber(exp) then PourSocialScoreDB.expList[i] = tonumber(exp) end
	return i
end

function M.PSS_RemoveListEntryAt(index)
	RemoveFromList(index)
end

local function getSyncValue (index)
	-- value, index of syncInfo data

	local info = PourSocialScoreDB.syncInfo[index]
	if type(info) ~= "table" then return 0, 0 end

	for c = 1, #info do
		local s = info[c]
		local p = type(s) == "string" and string.find(s, "@", 1, true)

		if p then
			local v = tonumber(string.sub(s, p + 1)) or 0
			if V.playerName == string.sub(s, 1, p - 1) then
				return v, c
			end
		end
	end

	return 0, 0
end

local function setSyncValue (name, index)

	if type(PourSocialScoreDB.syncInfo[index]) ~= "table" then PourSocialScoreDB.syncInfo[index] = {} end
	local val,idx = getSyncValue(index)

	if idx == 0 then
		idx = #PourSocialScoreDB.syncInfo[index] + 1
	end

	val = val + 1

	--M.debugMsg("Setting "..name.. " failed add attempts to "..val)

	PourSocialScoreDB.syncInfo[index][idx] = V.playerName .. "@" .. val
end

local function isServerMatch (server1, server2)

	return M.Proper(server1) == M.Proper(server2)
end
M.PSS_IsServerMatch = isServerMatch


local function hasIgnored (name)

	local result = 0

	name = M.Proper(M.addServer(name))

	for count = 1, C_FriendList.GetNumIgnores() do

		if name == M.Proper(M.addServer(C_FriendList.GetIgnoreName(count))) then
			result = count

			break
		end
	end

	return result
end

function M.hasNPCIgnored (name)

	if not name then return 0 end

	for count = 1, #PourSocialScoreDB.ignoreList do
		if PourSocialScoreDB.ignoreList[count] == name and PourSocialScoreDB.typeList[count] == "npc" then
			return count
		end
	end

	return 0
end

local function hasServerIgnored (name)

	if not name then return 0 end

	for count = 1, #PourSocialScoreDB.ignoreList do
		if PourSocialScoreDB.ignoreList[count] == name and PourSocialScoreDB.typeList[count] == "server" then
			return count
		end
	end

	return 0
end

function M.hasGroupWarning (name)

	if not name then return 0 end

	for count = 1, #(V.groupWarning or {}) do
		if V.groupWarning[count] == name then
			return count
		end
	end

	return 0
end

function M.hasGlobalIgnored (name)

	if not name then return 0 end

	for count = 1, #PourSocialScoreDB.ignoreList do
		if PourSocialScoreDB.ignoreList[count] == name and PourSocialScoreDB.typeList[count] == "player" then
			return count
		end
	end

	-- same player written differently ("Area 52" / "Area52", case, a doubled
	-- space): the lookup index, keyed the same way chat blocking keys people
	-- (O(1); this used to rebuild the key of every list entry on each call)
	local canon = M.PSS_CanonPlayer and M.PSS_CanonPlayer(name)
	if canon and M.PSS_ListedPosition then return M.PSS_ListedPosition(canon) or 0 end

	return 0
end

function M.hasAnyIgnored (name)

	if not name then return 0 end

	for count = 1, #PourSocialScoreDB.ignoreList do

		if PourSocialScoreDB.ignoreList[count] == name then
			return count
		end
	end

	return 0
end

local function ResetBlizzardIgnore()
	-- backwards: removing an entry moves every later one up a place
	for count = C_FriendList.GetNumIgnores(), 1, -1 do
		BlizzardDelIgnoreByIndex(count)
	end
end
M.PSS_ResetBlizzardIgnore = ResetBlizzardIgnore

local function ResetIgnoreDB()

	-- (options are not listed: no saved value is the default, PSS_Options.lua)
	PourSocialScoreDB = {
		ignoreList			= {},
		factionList			= {},
		dateList			= {},
		notes				= {},
		expList				= {},
		typeList			= {},
		delList				= {},
		syncInfo			= {},
		filterTotal			= 0,
		filterCount			= {},
		filterDesc			= {},
		filterList			= {},
		filterID			= {},
		filterBlocked		= {},
		filterBlockedLast	= {},
		filterWhisperTotal	= 0,
		filterPrivateTotal	= 0,
		showIgnoreDebug		= false,
		playerData		= {},
		guildData		= {},
		imported			= false
	}

	PourSocialScoreDB.imported = false
	if M.PSS_MarkIgnoreIndexDirty then M.PSS_MarkIgnoreIndexDirty() end

	M.ResetSpamFilters()
	-- a reset empties the PourSocialScore_Options tables too
	if M.PSS_PrepareSavedData then M.PSS_PrepareSavedData({ wipe = true, quiet = true }) end
end

local function isValidList()

	if C_FriendList.GetNumIgnores() > 0 then
		local str
		local found = 0

		for count = 1, C_FriendList.GetNumIgnores() do
			str = M.removeServer(C_FriendList.GetIgnoreName(count), true)

			if str ~= nil and str ~= _G.UNKNOWN then
				break
			end

			found = found + 1
		end

		if str == nil or str == _G.UNKNOWN then
			if M.PSS_Opt("showWarning") == true then
				M.ShowMsg(format(L["LOAD_5"], found, _G.UNKNOWN))
			end

			return false
		end
	end

	return true
end

function M.SyncIgnoreList (silent)

	if silent == nil then
		silent = false
	end

	M.ShowMsg(L["LOAD_4"])

	if isValidList() == false then
		M.debugMsg ("Invalid ignore list")
		return
	end

	V.PSS_InSync = true

	-- import ignore list if first time sync

	if PourSocialScoreDB.imported ~= true then

		local ignores = C_FriendList.GetNumIgnores()
		local added		= 0
		local name

		if (ignores > 0) and (silent == false) then
			M.ShowMsg(L["LOAD_2"])
		end

		M.debugMsg ("First time import, ignore size ".. ignores)

		for count = 1, ignores do

			name = C_FriendList.GetIgnoreName(count)

			if name ~= nil then

				local tmp = M.removeServer(name, true)

				if (tmp ~= "") and (tmp ~= _G.UNKNOWN) then
					name = M.Proper(M.addServer(C_FriendList.GetIgnoreName(count)))

					if M.hasGlobalIgnored(name) == 0 then
						added = added + 1

						AddToList(name, currentFaction())

						if silent == false then
							M.ShowMsg (format(L["LOAD_3"], name))
						end
					end
				end
			end
		end

		PourSocialScoreDB.imported = true
	end

	-- first remove broken and expired entries. Backwards, by position, so a
	-- removal never shifts an entry we have not looked at yet and an entry
	-- that is not a player (NPC / server) is removed too. (2.0.8 restarted the
	-- loop after each expiry and could only remove players, so an expired NPC
	-- or server entry made it loop forever.)

	for count = #PourSocialScoreDB.ignoreList, 1, -1 do
		local entry = PourSocialScoreDB.ignoreList[count]
		local tmp = type(entry) == "string" and M.removeServer(entry, true) or ""

		if tmp == "" then
			M.debugMsg ("Blank character name found in position " .. count)
			RemoveFromList(count)
		else
			local exp = tonumber(PourSocialScoreDB.expList[count]) or 0
			if exp > 0 and M.daysFromToday(PourSocialScoreDB.dateList[count]) >= exp then
				M.debugMsg ("Removing " .. entry .. " due to expiration date")
				if PourSocialScoreDB.typeList[count] == "player" then
					M.PSS_DelIgnore(count, true)
				else
					RemoveFromList(count)
				end
			end
		end
	end

	-- find account ignores that aren't on Pour Social Score and do things
	-- (backwards: removing an entry moves the later ones up a place)

	for count = C_FriendList.GetNumIgnores(), 1, -1 do

		local rawName = C_FriendList.GetIgnoreName(count)

		if rawName == nil or rawName == "" then
			M.debugMsg("Removing blank name on Blizzard ignore list")
			BlizzardDelIgnoreByIndex(count)
		else
			local short = M.removeServer(rawName, true)

			if short ~= "" and short ~= _G.UNKNOWN then
				local name		= M.Proper(M.addServer(rawName))
				local globIdx = M.hasGlobalIgnored(name)

				if globIdx == 0 then
					if M.PSS_Opt("trackChanges") == true and hasDeleted(name) == 0 then
						-- ignored with Blizzard's own UI: take it on (it is
						-- already on Blizzard's list, so it is not added again)
						M.debugMsg ("New player "..name.. " found on character, adding to Pour Social Score")
						AddToList(name, currentFaction())
						if not silent then M.ShowMsg (format(L["LOAD_3"], name)) end
					else
						if not silent then
							M.ShowMsg (format(L["SYNC_1"], name))
						end
						M.debugMsg ("Removing "..name.." from character ignore because they are not on Pour Social Score")
						BlizzardDelIgnoreByIndex(count)
					end
				else
					PourSocialScoreDB.syncInfo[globIdx] = {}
				end
			end
		end
	end

	-- move qualified players to account wide ignore if there is room for it.
	-- A player Blizzard refused maxSyncTries times on this character (wrong
	-- realm group, renamed, deleted...) is no longer retried here; they stay
	-- on Pour Social Score, which blocks them anyway. (2.0.8 meant to delete
	-- them from the list after 3 tries, but that loop never ran.)

	local ignoreCount = C_FriendList.GetNumIgnores()

	if ignoreCount < maxIgnoreSize and M.PSS_Opt("blizzardSync") == true then

		M.debugMsg("Moving characters from PSS to Ignore")

		for key = 1, #PourSocialScoreDB.ignoreList do
			local value = PourSocialScoreDB.ignoreList[key]

			if PourSocialScoreDB.typeList[key] == "player" and getSyncValue(key) < maxSyncTries then

				local name = M.Proper(M.addServer(value))

				if hasIgnored(name) == 0 then
					local ok = (PourSocialScoreDB.factionList[key] == currentFaction()) or (M.PSS_Opt("samefaction") == false)

					if ok then
						ok = (isServerMatch(V.serverName, M.getServer(name))) or (M.PSS_Opt("sameserver") == false)
					end

					if ok then
						ignoreCount = ignoreCount + 1

						setSyncValue(name, key)

						if not silent then
							M.ShowMsg (format(L["SYNC_2"], name))
						end

						BlizzardAddIgnore(name)
					end
				end
			end

			if ignoreCount >= maxIgnoreSize then
				break
			end
		end
	end

	V.PSS_InSync = false
	V.PSS_SyncOK = true
	M.Events.Fire("PLAYERS_CHANGED", true)
end

function M.PruneIgnoreList (days, doit)

	if days == nil or days <= 0 then
		return 0
	end

	local targets = 0
	local count		= 0

	while count < #PourSocialScoreDB.dateList do
		count = count + 1

		if M.daysFromToday(PourSocialScoreDB.dateList[count]) >= days then
			targets = targets + 1

			local name = M.addServer(PourSocialScoreDB.ignoreList[count])

			--if doit ~= true then
			--	M.ShowMsg("Prune will remove: "..name)
			--end

			if doit == true then
				local before = #PourSocialScoreDB.ignoreList
				if PourSocialScoreDB.typeList[count] == "player" then
					M.PSS_DelIgnore(count, true)	-- by position: always the right entry
				else
					RemoveFromList(count)
				end
				if #PourSocialScoreDB.ignoreList >= before then
					-- could not be removed: skip it instead of looping forever
				else
					count = count - 1
				end
			end
		end
	end

	if doit == true then
		V.needSorted = true
		M.ShowMsg(("Pruned %d entr%s listed for %d or more days."):format(targets, targets == 1 and "y" or "ies", days))
		M.Events.Fire("PLAYERS_CHANGED", true)
	end

	return targets
end


-------------------
-- CHAT COMMANDS --
-------------------

function M.ignoreFromCmd (argStr)
	-- not Proper()-ed here: that would glue the note onto the name. The name
	-- part is split off and normalised by PSS_AddIgnore.
	argStr = M.trim(argStr or "")
	if argStr == "" then
		argStr = M.PSS_UnitFullName("target") or ""
		if argStr ~= "" and not UnitPlayerControlled("target") then
			argStr = ""
		end
	end

	if argStr ~= "" then
		M.PSS_AddIgnore (argStr)
	end
end

-----------------------------
-- MAINLINE API INTEGRATION --
-----------------------------

-- Keep Blizzard's C_* APIs untouched. Older PSS versions replaced these
-- functions directly, which can taint protected UI code on mainline.
-- These are the ORIGINAL functions, captured before the hooks below are
-- installed, so calling them never runs our own hooks.
BlizzardAddIgnore			= C_FriendList.AddIgnore
BlizzardDelIgnore			= C_FriendList.DelIgnore
BlizzardDelIgnoreByIndex	= C_FriendList.DelIgnoreByIndex
local pssHookGuard = false

-- name: "Name[-Realm] [days] [note]" as typed, or with exactName = true the
-- whole string is the character name (it may contain a space).
M.PSS_AddIgnore = function(name, noNote, exactName)

	local okDisplay = true

	if (V.PSS_InSync == true and M.PSS_Opt("chatmsg") == false) then
		okDisplay = false
	end

	--print("DEBUG: Info sent to C_FriendList.AddIgnore name="..(name or "nil") .. " note="..(noNote or "nil"))
	if (not name or name == "") then
		name = M.PSS_UnitFullName("target")
	end

	if (not name or name == "") then
		return
	end

	local note	= ""
	local days	= M.PSS_Opt("defexpire")
	local space

	if not exactName then
		-- the name itself may contain a space: see M.PSS_SplitNameArg
		name, note = M.PSS_SplitNameArg(name)
	end

	if note ~= "" then
		space = string.find(note, " ")

		if space then
			if tonumber(string.sub(note, 0, space - 1)) then
				days = tonumber(string.sub(note, 0, space - 1))
				note = string.sub(note, space + 1)
			end
		else
			if tonumber(note) then
				days = tonumber(note)
				note = ""
			end
		end
	end

	V.needSorted = true
	name		= M.Proper(M.addServer(name))

	local tmp = M.removeServer(name, true)
	if (tmp == "") or (tmp == _G.UNKNOWN) then return end

	if M.Proper(M.addServer(UnitName("player"))) ~= name then

		local index = M.hasGlobalIgnored(name)

		if index == 0 then
			AddToList(name, currentFaction(), note)
			-- "/pss add Name 30 note": the days were parsed but never saved
			local newIndex = M.hasGlobalIgnored(name)
			if newIndex > 0 and tonumber(days) then PourSocialScoreDB.expList[newIndex] = tonumber(days) end

			if M.PSS_Opt("asknote") == true and not noNote then

				M.Events.Fire("ASK_NOTE", name)
			end

			if okDisplay == true then
				M.ShowMsg(format(L["ADD_2"], name))
			end

			-- Blizzard's ignore list blocks everything, so it is only used when
			-- you opt in to it (Options > "Also put listed players on
			-- Blizzard's ignore list")
			if M.PSS_Opt("blizzardSync") == true and hasIgnored(name) == 0 and C_FriendList.GetNumIgnores() < maxIgnoreSize then
				pssHookGuard = true; BlizzardAddIgnore(M.removeServer(name)); pssHookGuard = false
			end
		else
			if hasIgnored(name) > 0 then
				if okDisplay == true then
					M.ShowMsg(format(L["ADD_1"], name))
				end
			elseif M.PSS_Opt("blizzardSync") == true and C_FriendList.GetNumIgnores() < maxIgnoreSize then
				pssHookGuard = true; BlizzardAddIgnore(M.removeServer(name)); pssHookGuard = false
			end
		end

		--removeDeleted(name)

		M.Events.Fire("PLAYERS_CHANGED")
	else
		if okDisplay == true then
			M.ShowMsg(L["ADD_3"])
		end
	end
end

-- "Add Player" button / dialog: add with an optional note and expiry.
function M.PSS_AddPlayer(name, note, days, unit)
	if type(name) ~= "string" then return end
	name = name:gsub('^%s*"?', ""):gsub('"?%s*$', ""):gsub("%s+", " ")
	if name == "" then return end
	M.PSS_AddIgnore(name, true, true)	-- the whole text is the name (spaces allowed)
	local full = M.Proper(M.addServer(name))
	local idx = M.hasGlobalIgnored(full)
	if idx and idx > 0 then
		if type(note) == "string" and note ~= "" then PourSocialScoreDB.notes[idx] = note end
		if tonumber(days) and tonumber(days) > 0 then PourSocialScoreDB.expList[idx] = tonumber(days) end
		if unit and M.PSS_SetPlayerMeta then M.PSS_SetPlayerMeta(full, unit) end
	end
	V.needSorted = true
	M.Events.Fire("PLAYERS_CHANGED", true)
end

-- Player Search: a /who for a player name (PSS_Whois.lua). Core only - the
-- caller gets the players found and decides what to show:
--   M.PSS_PlayerSearch("Bob-Realm", function(players, query) ... end) -> sent?
--   players = { { name = "Bob-Realm", level =, class =, guild = }, ... }, A-Z
-- /who can't filter by realm, so only the name part is searched for.
function M.PSS_PlayerSearch(text, onDone)
	local query = (text or ""):gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", "")
	local name = query:gsub("%-.*$", "")
	if name == "" then return false end

	local found, seen = {}, {}
	return M.Whois.Request({
		kind	= "playerSearch",
		filter = 'n-"' .. name .. '"',
		query	= query,
		onInfo = function(info)
			local full = info.fullName or info.name
			if type(full) ~= "string" or full == "" or (M.PSS_IsSecret and M.PSS_IsSecret(full)) then return end
			if seen[full] then return end
			seen[full] = true
			found[#found + 1] = {
				name	= full,
				level = info.level,
				class = info.classStr or info.className or info.class,
				guild = info.fullGuildName or info.guild,
			}
		end,
		onFinish = function(req)
			table.sort(found, function(x, y) return x.name:lower() < y.name:lower() end)
			if onDone then onDone(found, req.query) end
		end,
	})
end

-- Remove a player from Pour Social Score (and Blizzard's ignore list).
--   isPSS + number : that exact position on the Pour Social Score list. An
--                    NPC or server entry at that position is removed too.
--   isPSS + name   : the player with that name.
--   otherwise      : a Blizzard ignore list position or a name.
M.PSS_DelIgnore = function(idxpos, isPSS)

	local okDisplay = true

	if (V.PSS_InSync == true and M.PSS_Opt("chatmsg") == false) then
		okDisplay = false
	end

	local name, index = nil, 0

	if isPSS and tonumber(idxpos) ~= nil then
		index = tonumber(idxpos)
		name = PourSocialScoreDB.ignoreList[index]
		if name == nil then return end
		if PourSocialScoreDB.typeList[index] ~= "player" then
			-- NPC / server entry: no Blizzard ignore to touch
			RemoveFromList(index)
			V.needSorted = true
			M.Events.Fire("PLAYERS_CHANGED")
			return
		end
	elseif isPSS then
		name = idxpos
	elseif tonumber(idxpos) ~= nil then
		name = C_FriendList.GetIgnoreName(tonumber(idxpos))
	else
		name = idxpos
	end

	if type(name) ~= "string" or name == "" then
		return
	end

	V.needSorted = true
	name = M.Proper(M.addServer(name))
	if index == 0 then index = M.hasGlobalIgnored(name) end

	if index > 0 then
		if okDisplay == true then
			M.ShowMsg(format(L["REM_1"], name))
		end
		RemoveFromList(index)
	end

	-- and from Blizzard's list, if it is there
	local blizIdx = hasIgnored(name)
	if blizIdx > 0 then
		pssHookGuard = true; BlizzardDelIgnoreByIndex(blizIdx); pssHookGuard = false
	end

	M.Events.Fire("PLAYERS_CHANGED")
end

M.PSS_AddOrDelIgnore = function(name)

	--print ("DEBUG C_FriendList.AddOrDel called with: "..(name or "nil"))
	if (not name or name == "") then
		name = M.PSS_UnitFullName("target")
	end

	if type(name) ~= "string" or M.PSS_IsSecret(name) or name == "" then return end		-- no name and no target

	local find = string.find
	local sub	= string.sub

	-- try to resolve server if there isn't one due to Blizzard bugs

	if not find(name, "-", nil, true) then
		local pServers = {}
		local pServer	= ""
		local tempName, count

		-- check group for a name

		if IsInGroup() then
			local prefix = IsInRaid() and "raid" or "party"

			for count = 1, GetNumGroupMembers() do
				tempName = GetUnitName(prefix..count, true)

				if type(tempName) == "string" and not M.PSS_IsSecret(tempName) then
					if M.removeServer(tempName, true) == name then
						pServer = M.Proper(M.getServer(tempName), "")
						--print ("DEBUG matched name: "..name)

						if pServer ~= "" then
							--print ("DEBUG adding possible server by group="..pServer)
							pServers[#pServers + 1] = pServer
						end
					end
				end
			end
		end

		-- check chat history for a name

		for count = 1, 20 do
			local frameName = "ChatFrame"..count

			local hb = _G[frameName] and _G[frameName].historyBuffer
			if hb and hb.GetNumElements and hb.GetEntryAtIndex then
				local msg, pos

				for c = 1, hb:GetNumElements() do
					local e = hb:GetEntryAtIndex(hb:GetNumElements() - c + 1)
					msg = e and e.message
					if type(msg) ~= "string" or (M.PSS_IsSecret and M.PSS_IsSecret(msg)) then msg = "" end
					pos = find(msg, "|Hplayer:", 1, true)
					--t = string.gsub(msg, "|", "!")

					if pos then
						--print("RAW="..t);
						--tempName = sub(msg, pos + 9, find(msg, ":", pos + 10, true) - 1, true)
						tempName = sub(msg, pos + 9, (find(msg, ":", pos + 9, true) or (find(msg, "|", pos + 10, true))) - 1)


						if M.removeServer(tempName, true) == name then
							--print ("DEBUG matched name: "..name)

							pServer = M.Proper(M.getServer(tempName), "")

							if pServer ~= "" then
								--print("DEBUG Adding possible server name by chat="..pServer)
								pServers[#pServers + 1] = pServer
							end
						end
					end
				end
			end
		end

		if pServer ~= "" then
			name = name .. "-" .. pServer
		end

		--print("FINAL="..pServer.. " name="..name)
		--M.ShowMsg (L["ADD_4"])
	end

	if (not name or name == "") then
		return
	end

	name = M.Proper(M.addServer(name))

	if M.removeServer(name, true) == _G.UNKNOWN then return end

	local index = M.hasGlobalIgnored(name)

	if index == 0 then
		--print("DEBUG calling AddIgnore="..(name or "nil"))

		M.PSS_AddIgnore(name, nil, true)	-- a name, not "name note"
	else
		M.PSS_DelIgnore(index, true)
		--print("DEBUG calling DelIgnore="..(index or "nil"))

	end
end


-- Observe Blizzard ignore changes so /ignore, the right-click "Ignore" in
-- Blizzard's menus and "Unignore" in the Friends window stay in step with
-- PSS, without replacing any C_FriendList function (hooksecurefunc only).
--   AddIgnore(name)          -> add to PSS
--   DelIgnore(name)          -> remove from PSS
--   AddOrDelIgnore(name)     -> toggles; the result is read on the next
--                               IGNORELIST_UPDATE (the server answers later)
--   DelIgnoreByIndex(index)  -> the name comes from the copy of Blizzard's
--                               list taken at the last IGNORELIST_UPDATE
local blizzSnapshot = {}
local pendingToggle = nil	-- { name =, at = }

local function takeBlizzSnapshot()
	local t = {}
	for i = 1, C_FriendList.GetNumIgnores() do t[i] = C_FriendList.GetIgnoreName(i) end
	blizzSnapshot = t
end

-- Blizzard's list already has them: only add to PSS, never call AddIgnore again
-- (2.0.8 did, which printed "already ignored").
local function addFromBlizzard(name)
	if not V.PSS_Loaded or type(name) ~= "string" or M.PSS_IsSecret(name) or name == "" then return end
	local full = M.Proper(M.addServer(name))
	local short = M.removeServer(full, true)
	if short == "" or short == _G.UNKNOWN then return end
	if M.hasGlobalIgnored(full) > 0 then return end
	if M.Proper(M.addServer(UnitName("player"))) == full then return end
	AddToList(full, currentFaction())
	V.needSorted = true
	if M.PSS_Opt("chatmsg") ~= false then M.ShowMsg(format(L["ADD_2"], full)) end
	M.Events.Fire("PLAYERS_CHANGED", true)
end

local function removeFromBlizzard(name)
	if not V.PSS_Loaded or type(name) ~= "string" or M.PSS_IsSecret(name) or name == "" then return end
	local index = M.hasGlobalIgnored(M.Proper(M.addServer(name)))
	if index > 0 then
		RemoveFromList(index)
		V.needSorted = true
		M.Events.Fire("PLAYERS_CHANGED", true)
	end
end

local function PSS_IgnoreAdded(name)
	if pssHookGuard then return end
	addFromBlizzard(name)
end

local function PSS_IgnoreRemoved(name)
	if pssHookGuard then return end
	removeFromBlizzard(name)
end

local function PSS_IgnoreToggled(name)
	if pssHookGuard or type(name) ~= "string" or M.PSS_IsSecret(name) or name == "" then return end
	pendingToggle = { name = name, at = GetTime() }
end

local function PSS_IgnoreRemovedByIndex(index)
	if pssHookGuard then return end
	removeFromBlizzard(blizzSnapshot[tonumber(index) or 0])
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("IGNORELIST_UPDATE")
hookFrame:RegisterEvent("PLAYER_LOGIN")
hookFrame:SetScript("OnEvent", function(self, event)
	if event == "IGNORELIST_UPDATE" and pendingToggle then
		local pt = pendingToggle
		pendingToggle = nil
		if GetTime() - pt.at < 10 then
			if hasIgnored(pt.name) > 0 then addFromBlizzard(pt.name) else removeFromBlizzard(pt.name) end
		end
	end
	takeBlizzSnapshot()
end)

if hooksecurefunc then
	if C_FriendList.AddIgnore then hooksecurefunc(C_FriendList, "AddIgnore", PSS_IgnoreAdded) end
	if C_FriendList.DelIgnore then hooksecurefunc(C_FriendList, "DelIgnore", PSS_IgnoreRemoved) end
	if C_FriendList.AddOrDelIgnore then hooksecurefunc(C_FriendList, "AddOrDelIgnore", PSS_IgnoreToggled) end
	if C_FriendList.DelIgnoreByIndex then hooksecurefunc(C_FriendList, "DelIgnoreByIndex", PSS_IgnoreRemovedByIndex) end
end

M.AddOrDelNPC = function (argStr)

	if tonumber(argStr) then

		local nIndex = tonumber(argStr)

		if (nIndex > 0) and (PourSocialScoreDB.ignoreList[nIndex]) and (PourSocialScoreDB.typeList[nIndex] == "npc") then

			M.ShowMsg (format(L["CMD_12"], PourSocialScoreDB.ignoreList[nIndex]))
			RemoveFromList(nIndex)
		end
	else

		if argStr ~= "" then
			argStr = (M.trim(M.Proper(argStr, true)) or "")
		end

		if argStr == "" then
			local t = M.PSS_UnitFullName("target")
			argStr = t and M.Proper(t, true)

			if argStr == nil or UnitPlayerControlled("target") then
				argStr = ""
			end
		end

		if argStr ~= "" then

			local npcIndex = M.hasNPCIgnored(argStr)

			if npcIndex > 0 then
				local name = PourSocialScoreDB.ignoreList[npcIndex]

				M.ShowMsg (format(L["CMD_12"], name))
				RemoveFromList(npcIndex)
			else
				M.ShowMsg (format(L["CMD_13"], argStr))
				AddToList(argStr, currentFaction(), "", "npc")
			end
		end
	end
end

M.AddOrDelServer = function (sName)

	if not sName then return end

	if tonumber(sName) then

		local sIndex = tonumber(sName)

		if (sIndex > 0) and (PourSocialScoreDB.ignoreList[sIndex]) and (PourSocialScoreDB.typeList[sIndex] == "server") then

			M.ShowMsg(format(L["CMD_19"], PourSocialScoreDB.ignoreList[sIndex]))
			RemoveFromList(sIndex)
		end

	else

		sName = M.Proper(sName)

		local sIndex = hasServerIgnored(sName)

		if sIndex > 0 then

			M.ShowMsg(format(L["CMD_19"], sName))
			RemoveFromList(sIndex)

		else

			M.ShowMsg(format(L["CMD_18"], sName))
			AddToList(sName, currentFaction(), "", "server")
		end
	end
end

M.PSS_ResetIgnoreDB = ResetIgnoreDB

------------------------------------------------------------------------
-- Per-player settings and history
------------------------------------------------------------------------
local normalizePlayer = M.PSS_NormalizePlayer
local displayPlayer		= M.PSS_DisplayPlayer
local nowString			= M.PSS_NowString
local canonPlayer		= M.PSS_CanonPlayer

local function opt(key, ctx)
	if M.PSS_Opt then return M.PSS_Opt(key, ctx) end
	return PourSocialScoreDB and PourSocialScoreDB[key]
end

-- Block history: PSS_ChatHistory.lua (same entries/counts as guilds and filters)
local History = M.PSS_History

local function ensureDB()
	PourSocialScoreDB = PourSocialScoreDB or {}
	PourSocialScoreDB.playerData = PourSocialScoreDB.playerData or {}
	PourSocialScoreDB.guildData = PourSocialScoreDB.guildData or {}
end

local function ensurePlayer(name)
	ensureDB()
	local key = normalizePlayer(name)
	if not key then return nil end
	local p = PourSocialScoreDB.playerData[key]
	if not p then
		-- only what is known; empty text and zero counters are not stored
		p = {
			name = displayPlayer(name), whenBlocked = nowString(),
			whispersBlocked = true, partyInvitesBlocked = true, guildInvitesBlocked = true, partyRaidBlocked = true,
			channelsBlocked = true,
		}
		PourSocialScoreDB.playerData[key] = p
	else
		p.name = p.name or displayPlayer(name)
		p.whenBlocked = p.whenBlocked or nowString()
		if p.whispersBlocked == nil then p.whispersBlocked = true end
		if p.partyInvitesBlocked == nil then p.partyInvitesBlocked = true end
		-- guild invites used to share the party-invite setting
		if p.guildInvitesBlocked == nil then p.guildInvitesBlocked = p.partyInvitesBlocked end
		if p.partyRaidBlocked == nil then p.partyRaidBlocked = true end
		-- C (chat channels / public chat) was always blocked before it became a switch
		if p.channelsBlocked == nil then p.channelsBlocked = true end
	end
	return p, key
end

function M.PSS_GetPlayerPrefs(name) return ensurePlayer(name) end

-- Existing record only (never creates one).
function M.PSS_GetPlayerRecord(name)
	local key = normalizePlayer(name)
	return key and PourSocialScoreDB and PourSocialScoreDB.playerData and PourSocialScoreDB.playerData[key]
end

-- Could p own block history lines? Counted blocks, or the counters and
-- lines of older saves.
local OLD_COUNTERS = { "blockedWhispers", "blockedWhisperMessages", "blockedPrivateMessages", "blockedChatMessages", "blockedInvites" }
local function mayHaveLines(p)
	if type(p) ~= "table" then return false end
	local c = p.blockCounts
	if type(c) == "table" and (tonumber(c.total) or 0) > 0 then return true end
	if type(p.blockHistory) == "table" and next(p.blockHistory) ~= nil then return true end
	for _, f in ipairs(OLD_COUNTERS) do
		if (tonumber(p[f]) or 0) > 0 then return true end
	end
	return false
end

-- A player left the Player Ignore List: nothing about them stays saved (their
-- record and block history lines). If they are on a built-in guild list
-- they stay blocked there, see M.PSS_KeepBlockedOnBuiltIn.
function M.PSS_ForgetPlayer(name, note)
	local key = normalizePlayer(name)
	local p = key and PourSocialScoreDB.playerData and PourSocialScoreDB.playerData[key]
	if M.PSS_KeepBlockedOnBuiltIn then M.PSS_KeepBlockedOnBuiltIn(p and p.name or name, note) end
	local owner = History.PlayerKey(p and p.name or name)
	-- a line is only ever added with a count, so with nothing counted for
	-- them there is nothing to clear and the block history (Logging) is
	-- not loaded for it
	if owner and (History.Loaded() or mayHaveLines(p)) then
		History.Clear(function(h) return h.o == owner end)
	end
	History.ForgetRecent(owner)
	if p then PourSocialScoreDB.playerData[key] = nil end
end

-- Fields older builds stored on every player record: copies of the list's
-- note and expiry, a nickname equal to the name, the "seen online" flag and
-- the counters that p.blockCounts replaced. Empty text is not stored.
local DROPPED_FIELDS = { "note", "expireDays", "online", "blockedWhispers", "blockHistory",
						"blockedInvites", "blockedWhisperMessages", "blockedPrivateMessages", "blockedChatMessages" }
local EMPTY_FIELDS = { "guildWhenBlocked", "currentGuild", "lastBlockedInvite", "class", "faction", "className" }

-- Login tidy-up (after the upgrades): a record of a player no longer on the
-- Player Ignore List is removed (left by builds before 2.0.43; one on a
-- built-in guild list stays blocked there first), and the records that stay
-- lose the fields above. Returns the number of records removed.
function M.PSS_TidyPlayerData()
	ensureDB()
	local db = PourSocialScoreDB
	local listed = {}
	for i, name in ipairs(db.ignoreList or {}) do
		if (db.typeList[i] or "player") == "player" then
			local k = normalizePlayer(name)
			if k then listed[k] = true end
		end
	end
	local gone = {}
	for key, p in pairs(db.playerData) do
		if not listed[key] or type(p) ~= "table" then gone[#gone + 1] = key end
	end
	for _, key in ipairs(gone) do
		-- (their block lines go in the history tidy that runs next)
		local p = db.playerData[key]
		if type(p) == "table" and M.PSS_KeepBlockedOnBuiltIn then M.PSS_KeepBlockedOnBuiltIn(p.name or key, p.note) end
		db.playerData[key] = nil
	end
	for _, p in pairs(db.playerData) do
		-- older counters are folded into p.blockCounts first (once)
		if type(p.blockCounts) ~= "table" and ((tonumber(p.blockedInvites) or 0) + (tonumber(p.blockedWhisperMessages) or 0)
			+ (tonumber(p.blockedPrivateMessages) or 0) + (tonumber(p.blockedChatMessages) or 0)) > 0 then
			M.PSS_GetPlayerBlockCounts(p)
		end
		if p.nickname == p.name then p.nickname = nil end
		for _, f in ipairs(DROPPED_FIELDS) do p[f] = nil end
		for _, f in ipairs(EMPTY_FIELDS) do
			if p[f] == "" then p[f] = nil end
		end
	end
	return #gone
end

-- The note of list entry index.
function M.PSS_SetNote(index, note)
	if not PourSocialScoreDB.ignoreList[index] then return end
	PourSocialScoreDB.notes[index] = note
end

-- Days after the date added that list entry index expires (0 = never).
function M.PSS_SetExpiry(index, days)
	if not PourSocialScoreDB.ignoreList[index] then return end
	PourSocialScoreDB.expList[index] = days
end

-- Per-player block parameters
local PLAYER_FIELDS = { whispersBlocked = true, partyInvitesBlocked = true, guildInvitesBlocked = true, partyRaidBlocked = true, channelsBlocked = true }
function M.PSS_SetPlayerSetting(name, field, value)
	local p = ensurePlayer(name)
	if not p or not PLAYER_FIELDS[field] then return end
	local was = p[field] == true
	p[field] = value == true
	if p[field] and not was then
		-- newly blocked: clear what they already said (whisper / chat
		-- switches) and decline an invite from them that is still open
		if field == "whispersBlocked" or field == "partyRaidBlocked" or field == "channelsBlocked" then
			local c = canonPlayer(name)
			if c and M.PSS_PurgeChatFrom then M.PSS_PurgeChatFrom({ [c] = true }) end
		end
		if M.PSS_PersonIdentified then M.PSS_PersonIdentified(name) end
	end
end

-- Keep metadata of LISTED players current when they are seen (target,
-- mouseover, group...). Unlisted players are not stored.
function M.PSS_SetPlayerMeta(name, unit, guild)
	local p = M.PSS_GetPlayerRecord(name)
	if not p then return end
	local sec = M.PSS_IsSecret
	if unit and UnitExists and UnitExists(unit) then
		local fac = UnitFactionGroup(unit)
		local className, classToken = UnitClass(unit)
		if fac and not sec(fac) then p.faction = fac end
		if classToken and not sec(classToken) then p.class = classToken end
		if className and not sec(className) then p.className = className end
	end
	guild = guild or (unit and GetGuildInfo and GetGuildInfo(unit)) or ""
	if type(guild) ~= "string" or sec(guild) then guild = "" end
	if guild ~= "" then
		p.currentGuild = guild
		if (p.guildWhenBlocked or "") == "" then p.guildWhenBlocked = guild end
	end
	return p
end

-- cat: core category (whisper, partyRaid, world, guildChat, other); invites use inviteKind
function M.PSS_RecordPlayerBlock(name, event, message, inviteKind, cat)
	local p = ensurePlayer(name)
	if not p then return end
	M.PSS_GetPlayerBlockCounts(p)	-- make sure counters exist (seeded from older data once)
	local ccat = inviteKind and (inviteKind == "guild" and "guildInvite" or "partyInvite")
		or cat or (M.PSS_EventCategory and M.PSS_EventCategory(event)) or "other"
	if ccat ~= "whisper" and ccat ~= "partyInvite" and ccat ~= "guildInvite" and ccat ~= "partyRaid" then ccat = "world" end
	if not event and inviteKind then event = (inviteKind == "guild") and "GUILD_INVITE" or "PARTY_INVITE" end
	-- one line in the shared block log (capped in total, see PSS_ChatHistory)
	local entry = History.Add(History.PlayerKey(p.name or name), p.blockCounts,
		History.NewEntry(ccat, event or "", message, M.PSS_ChannelLabel and M.PSS_ChannelLabel(event or "") or nil, p.name or name))
	-- (the counts are in p.blockCounts and the lines in the block history)
	if inviteKind then p.lastBlockedInvite = entry.time end
	-- the window is redrawn at most a few times a second, not once per line
	M.Events.Fire("PLAYER_BLOCKED")
end

-- Per-player counters by type (totals; not limited by the history cap).
-- Accepts a name or a player record. Keys: total, whisper, partyInvite,
-- guildInvite, partyRaid, world (world = everything else that was hidden).
function M.PSS_GetPlayerBlockCounts(nameOrRecord)
	local p = type(nameOrRecord) == "table" and nameOrRecord or M.PSS_GetPlayerRecord(nameOrRecord)
	if not p then return History.EmptyCounts() end
	if type(p.blockCounts) ~= "table" then
		-- first use on an older record: rebuild from the old counters
		local c = History.EmptyCounts()
		c.whisper = (tonumber(p.blockedWhisperMessages) or 0) + (tonumber(p.blockedPrivateMessages) or 0)
		c.world = tonumber(p.blockedChatMessages) or 0
		c.partyInvite = tonumber(p.blockedInvites) or 0
		c.total = c.whisper + c.world + c.partyInvite
		p.blockCounts = c
	end
	p.blockCounts = History.EnsureCounts(p.blockCounts)
	return p.blockCounts
end

-- total, whispers, chat messages, invites
function M.PSS_GetPlayerBlockTotals(name)
	local p = M.PSS_GetPlayerRecord(name)
	if not p then return 0, 0, 0, 0 end
	local c = M.PSS_GetPlayerBlockCounts(p)
	return c.total, c.whisper, c.partyRaid + c.world, c.partyInvite + c.guildInvite
end

-- Log key of a listed player (record or name).
function M.PSS_PlayerHistoryKey(nameOrRecord)
	if type(nameOrRecord) == "table" then return History.PlayerKey(nameOrRecord.name) end
	local p = M.PSS_GetPlayerRecord(nameOrRecord)
	return History.PlayerKey(p and p.name or nameOrRecord)
end

-- Newest-first history of one listed player (from the shared log).
function M.PSS_GetPlayerBlockHistory(name)
	local key = M.PSS_PlayerHistoryKey(name)
	if not key then return {} end
	return History.For(key)
end

function M.PSS_ResetPlayerBlockHistory(name)
	local p = ensurePlayer(name)
	if p then
		local key = History.PlayerKey(p.name or name)
		History.Clear(function(h) return h.o == key end)
		History.ForgetRecent(key)
		p.blockHistory = nil
		p.blockedWhispers, p.blockedWhisperMessages, p.blockedPrivateMessages = nil, nil, nil
		p.blockedChatMessages, p.blockedInvites = nil, nil
		p.blockCounts = History.EmptyCounts()
		M.Events.Fire("PLAYERS_CHANGED")
	end
end

------------------------------------------------------------------------
-- Lookup index (players / NPCs / servers) - O(1) for every chat line.
-- Rebuilt when the list changes (AddToList / RemoveFromList mark it dirty;
-- size changes and a 30 s age limit catch anything else).
------------------------------------------------------------------------
local idx = { players = {}, pos = {}, npcs = {}, servers = {}, count = -1, builtAt = -1000, dirty = true }

function M.PSS_MarkIgnoreIndexDirty() idx.dirty = true end

local function rebuildIndex()
	local players, pos, npcs, servers = {}, {}, {}, {}
	local list = PourSocialScoreDB and PourSocialScoreDB.ignoreList or {}
	local types = PourSocialScoreDB and PourSocialScoreDB.typeList or {}
	for i, name in ipairs(list) do
		local t = types[i] or "player"
		if type(name) == "string" then
			if t == "player" then
				local c = canonPlayer(name)
				if c then players[c] = name; pos[c] = i end
			elseif t == "npc" then
				npcs[name:lower()] = name
			elseif t == "server" then
				local c = M.PSS_CanonRealm(name)
				if c then servers[c] = name end
			end
		end
	end
	idx.players, idx.pos, idx.npcs, idx.servers = players, pos, npcs, servers
	idx.count = #list
	idx.builtAt = GetTime()
	idx.dirty = false
end

local function ensureIndex()
	local n = PourSocialScoreDB and PourSocialScoreDB.ignoreList and #PourSocialScoreDB.ignoreList or 0
	-- rebuilt only when the list changed (no timed rebuilds)
	if idx.dirty or n ~= idx.count then rebuildIndex() end
end

-- name on the list for this canonical key, verified against the list
local function listedName(canon)
	ensureIndex()
	local name = idx.players[canon]
	if not name then return nil end
	if PourSocialScoreDB.ignoreList[idx.pos[canon]] ~= name then
		rebuildIndex()
		name = idx.players[canon]
	end
	return name
end

function M.PSS_IsPlayerListed(name)
	local c = canonPlayer(name)
	return c and listedName(c) ~= nil
end

-- position on the list for a canonical key (or nil)
function M.PSS_ListedPosition(canon)
	if not canon or not listedName(canon) then return nil end
	return idx.pos[canon]
end

------------------------------------------------------------------------
-- "player" person source for the core
------------------------------------------------------------------------
if M.PSS_RegisterBlockSource then
	M.PSS_RegisterBlockSource({
		id = "player", order = 10, label = "Player Ignore List",
		lookup = function(canon)
			local name = listedName(canon)
			if not name then return nil end
			return { name = name, p = ensurePlayer(name) }
		end,
		decide = function(e, cat, ctx)
			local p = e.p
			if cat == "whisper" then return p.whispersBlocked == true
			elseif cat == "partyRaid" then return p.partyRaidBlocked == true
			elseif cat == "partyInvite" then return p.partyInvitesBlocked == true
			elseif cat == "guildInvite" then return p.guildInvitesBlocked == true
			elseif cat == "world" then return p.channelsBlocked ~= false	-- C: channels, say, yell, emotes
			elseif cat == "duel" then return opt("declineDuel", { person = p.opts }) ~= false
			elseif cat == "trade" then return opt("declineTrade", { person = p.opts }) ~= false
			end
			return true			-- guild chat, achievements, channel notices
		end,
		record = function(e, cat, ctx)
			if cat == "duel" or cat == "trade" then return end
			local inviteKind = (cat == "partyInvite" and "group") or (cat == "guildInvite" and "guild") or nil
			M.PSS_RecordPlayerBlock(e.name, ctx.event, ctx.msg, inviteKind, cat)
		end,
		optionContext = function(e) return { person = e.p.opts } end,
		describe = function(e) return "Player Ignore List (" .. tostring(e.name) .. ")" end,
	})
end

------------------------------------------------------------------------
-- NPC, realm and system handlers for the core
------------------------------------------------------------------------
local fileLoadTime = GetTime()

local function escapePattern(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end
local function buildPattern(fmt, firstCapture)
	if type(fmt) ~= "string" then return nil end
	local parts, n = {}, 0
	local out = escapePattern(fmt):gsub("%%%%s", function()
		n = n + 1
		return (n == 1) and firstCapture or ".-"
	end)
	return "^" .. out .. "$"
end
local LOGOFF_PATTERN = buildPattern(ERR_FRIEND_OFFLINE_S, "(.+)")
local LOGON_PATTERN		= buildPattern(ERR_FRIEND_ONLINE_SS, "([^|]+)")

if M.PSS_RegisterBlockHandler then
	M.PSS_RegisterBlockHandler("npc", "npcIgnore", function(ctx)
		if type(ctx.author) ~= "string" or ctx.author == "" then return false end
		ensureIndex()
		if not next(idx.npcs) then return false end
		local n = M.Proper(ctx.author, true)
		return n ~= nil and idx.npcs[n:lower()] ~= nil
	end)

	M.PSS_RegisterBlockHandler("realm", "serverIgnore", function(ctx)
		ensureIndex()
		if not next(idx.servers) then return false end
		local realm = ctx.author:match("%-(.+)$") or M.PSS_OwnRealm()
		local c = M.PSS_CanonRealm(realm)
		if c and idx.servers[c] then return true, { server = idx.servers[c] } end
		return false
	end)

	M.PSS_RegisterBlockHandler("system", "ignoreList", function(ctx)
		local message = ctx.msg
		if type(message) ~= "string" or M.PSS_IsSecret(message) then return false end
		if message == ERR_IGNORE_FULL then return true end

		-- hide the noise from syncing Blizzard's ignore list at login / during sync
		local since = GetTime() - (V.PSS_LoadedTime or fileLoadTime)
		if doLoginIgnore and V.PSS_Loaded and since > 90 then doLoginIgnore = false end
		if doLoginIgnore or (V.PSS_InSync == true and PourSocialScoreDB and M.PSS_Opt("chatmsg") == false) then
			if message == ERR_IGNORE_NOT_FOUND or message == ERR_FRIEND_ERROR then return true end
			for _, fmt in ipairs({ ERR_IGNORE_ADDED_S, ERR_IGNORE_REMOVED_S, ERR_IGNORE_ALREADY_S }) do
				if type(fmt) == "string" and message:find((fmt:gsub("%%s", "")), 1, true) then return true end
			end
		end

		-- "<Name> has come online / gone offline" for listed players and servers
		if not V.PSS_Loaded then return false end
		local name = (LOGOFF_PATTERN and message:match(LOGOFF_PATTERN)) or (LOGON_PATTERN and message:match(LOGON_PATTERN))
		if not name then return false end
		local c = canonPlayer(name)
		if c and listedName(c) then return true end
		local realm = name:match("%-(.+)$")
		local rc = realm and M.PSS_CanonRealm(realm)
		return rc ~= nil and idx.servers[rc] ~= nil
	end)
end
