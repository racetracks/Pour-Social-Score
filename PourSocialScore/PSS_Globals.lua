local addonName, addon = ...
-- get a reference to localization entries
local L = addon.L
-- use this array to share variables between addon files
addon.V = {}
local V = addon.V
V.needSorted = true		-- the Player Ignore List needs sorting before it is drawn
-- use this to share methods between addon files
addon.M = {}
local M = addon.M

----------------------
-- SHARED FUNCTIONS --
----------------------

-- Strips leading and trailing whitespace; anything but a string gives "".
function M.trim (str)

	if type(str) ~= "string" then return "" end
	local n = str:find"%S"
	return n and str:match(".*%S", n) or ""

end
M.PSS_Trim = M.trim

-- Writes one line to the default chat frame, exactly as given.
function M.ChatMsg (text)
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(text) end
end

function M.dateToJulianDate (dateStr)

	if dateStr == nil then
		return 0
	end

	local monthList = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
	local words		= {}

	for word in dateStr:gmatch("%w+") do
		words[#words + 1] = word
	end

	local day	= tonumber(words[1])
	local year	= tonumber(words[3])
	local month = 0

	for key, value in pairs(monthList) do

		if value == words[2] then
			month = tonumber(key)

			break
		end
	end

	if (not month) or (not day) or (not year) or (month < 1) or (month > 12) or (day < 1) or (day > 31) or (year < 2014) then
		return 0
	end

	-- Whole day number (days since 1970). Midday avoids daylight-saving edges.
	-- 2.0.8 used a Julian-day formula with decimal division, so day counts
	-- could be one off around the end of a month.
	local t = time({ year = year, month = month, day = day, hour = 12 })
	if not t then return 0 end
	return math.floor(t / 86400)
end

function M.daysFromToday (dateStr)

	local addDate = M.dateToJulianDate(dateStr)
	local today		= M.dateToJulianDate(date("%d %b %Y"))

	if addDate == 0 then
		return -1
	else

		return math.abs(today - addDate)
	end
end

-- ASCII lower case (non-ASCII bytes unchanged) - same as string.lower in
-- the game's C locale. (The old version built the result a character at a
-- time.)
function M.strDown (str)
	return string.lower(str)
end

local properBuf = {}
function M.Proper (name, okSpaces)

	if name == nil then return nil end
	if name == "" then return nil end

	-- Character names can contain a space ("First Last-Realm"). For a
	-- "Name-Realm" string the spaces inside the name part are kept (single
	-- spaces, trimmed); spaces in the realm part are still removed, as before.
	local keepUntil = 0
	if okSpaces ~= true then
		local dash = string.find(name, "-", 1, true)
		if dash and dash > 1 then
			local base = string.sub(name, 1, dash - 1):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
			if string.find(base, " ", 1, true) then
				name = base .. string.sub(name, dash)
				keepUntil = strlen(base)
			end
		end
	end

	-- one pass over the bytes into a reused buffer, joined once (the old
	-- version appended to a string per character: quadratic garbage)
	local len		= #name
	local buf		= properBuf
	local n			= 0
	local needUp = true
	local gotOP		= false
	local byte, char, upper, lower = string.byte, string.char, string.upper, string.lower

	for count = 1, len do
		local c = byte(name, count)
		if c < 32 or c > 126 then
			n = n + 1; buf[n] = char(c)
			needUp = false
		elseif c ~= 32 or okSpaces == true or count <= keepUntil then
			n = n + 1
			buf[n] = needUp and upper(char(c)) or lower(char(c))
			gotOP	= (c == 40 or gotOP) and (c ~= 41)
			needUp = (c == 32 or c == 45 or gotOP == true)
		end
	end

	return table.concat(buf, "", 1, n)
end

-- Split "name [rest]" typed by the user. The name may contain a space:
--   "First Last-Realm note"   (a word with "-" within the first 3 words ends the name)
--   "\"First Last\" note"      (quotes; the name may then have no realm)
-- Anything else: the first word is the name, as before.
function M.PSS_SplitNameArg(str)
	str = M.trim(tostring(str or ""))
	if str == "" then return "", "" end
	local q, after = str:match('^"([^"]+)"%s*(.*)$')
	if q then return M.trim(q), after or "" end
	local words = {}
	for w in str:gmatch("%S+") do words[#words + 1] = w end
	local last = 1
	if not string.find(words[1], "-", 1, true) then
		for k = 2, math.min(3, #words) do
			if string.find(words[k], "-", 1, true) then last = k break end
		end
	end
	local name = table.concat(words, " ", 1, last)
	local rest = (#words > last) and table.concat(words, " ", last + 1) or ""
	return name, rest
end

-- Realm names as the game sends them (no spaces) -> display spelling.
-- Built on first use so the table costs no memory at load.
local REALM_PAIRS = {
	"Aeriepeak", "Aerie Peak",
	"Aggra(portugu\195\170s)", "Aggra (Portugu\195\170s)",
	"Ahn'qiraj", "Ahn'Qiraj",
	"Al'akir", "Al'Akir",
	"Altarofstorms", "Altar of Storms",
	"Alteracmountains", "Alterac Mountains",
	"Aman'thul", "Aman'Thul",
	"Arathibasin", "Arathi Basin",
	"Arcanitereaper", "Arcanite Reaper",
	"Area52", "Area 52",
	"Argentdawn", "Argent Dawn",
	"Arugal(au)", "Arugal (AU)",
	"Azjol-nerub", "Azjol-Nerub",
	"Blackdragonflight", "Black Dragonflight",
	"Blackwaterraiders", "Blackwater Raiders",
	"Blackwinglair", "Blackwing Lair",
	"Blade'sedge", "Blade's Edge",
	"Bleedinghollow", "Bleeding Hollow",
	"Bloodfurnace", "Blood Furnace",
	"Bloodsailbuccaneers", "Bloodsail Buccaneers",
	"Bootybay", "Booty Bay",
	"Boreantundra", "Borean Tundra",
	"Bronzedragonflight", "Bronze Dragonflight",
	"Burningblade", "Burning Blade",
	"Burninglegion", "Burning Legion",
	"Burningsteppes", "Burning Steppes",
	"Cenarioncircle", "Cenarion Circle",
	"Chamberofaspects", "Chamber of Aspects",
	"Chants\195\169ternels", "Chants \195\169ternels",
	"Chaosbolt", "Chaos Bolt",
	"Chillwindpoint", "Chillwind Point",
	"Chromie(ru)", "Chromie (RU)",
	"Colinaspardas", "Colinas Pardas",
	"Confr\195\169rieduthorium", "Confr\195\169rie du Thorium",
	"Conseildesombres", "Conseil des Ombres",
	"Crusaderstrike", "Crusader Strike",
	"Crystalpinestinger", "Crystalpine Stinger",
	"C'thun", "C'Thun",
	"Cultedelarivenoire", "Culte de la Rive noire",
	"Darkiron", "Dark Iron",
	"Darkmoonfaire", "Darkmoon Faire",
	"Daskonsortium", "Das Konsortium",
	"Dassyndikat", "Das Syndikat",
	"Dath'remar", "Dath'Remar",
	"Defiasbrotherhood", "Defias Brotherhood",
	"Defiaspillager", "Defias Pillager",
	"Demonfallcanyon", "Demon Fall Canyon",
	"Demonsoul", "Demon Soul",
	"Derabyssischerat", "Der abyssische Rat",
	"Dermithrilorden", "Der Mithrilorden",
	"Derratvondalaran", "Der Rat von Dalaran",
	"Deviatedelight", "Deviate Delight",
	"Diealdor", "Die Aldor",
	"Diearguswacht", "Die Arguswacht",
	"Dieewigewacht", "Die ewige Wacht",
	"Dienachtwache", "Die Nachtwache",
	"Diesilbernehand", "Die Silberne Hand",
	"Dietodeskrallen", "Die Todeskrallen",
	"Dragon'scall", "Dragon's Call",
	"Drak'tharon", "Drak'Tharon",
	"Drek'thar", "Drek'Thar",
	"Dunmodr", "Dun Modr",
	"Dunmorogh", "Dun Morogh",
	"Earthenring", "Earthen Ring",
	"Echoisles", "Echo Isles",
	"Eldre'thalas", "Eldre'Thalas",
	"Emeralddream", "Emerald Dream",
	"Fengus'ferocity", "Fengus' Ferocity",
	"Festungderst\195\188rme", "Festung der St\195\188rme",
	"Flamegor(ru)", "Flamegor (RU)",
	"Grimbatol", "Grim Batol",
	"Grizzlyhills", "Grizzly Hills",
	"Harbingerofdoom(ru)", "Harbinger of Doom (RU)",
	"Howlingfjord", "Howling Fjord",
	"Hydraxianwaterlords", "Hydraxian Waterlords",
	"Jubei'thos", "Jubei'Thos",
	"Kel'thuzad", "Kel'Thuzad",
	"Khazmodan", "Khaz Modan",
	"Kirintor", "Kirin Tor",
	"Krolblade", "Krol Blade",
	"Kultiras", "Kul Tiras",
	"Kultderverdammten", "Kult der Verdammten",
	"Lacroisade\195\169carlate", "La Croisade \195\169carlate",
	"Laughingskull", "Laughing Skull",
	"Lavalash", "Lava Lash",
	"Leishen", "Lei Shen",
	"Lesclairvoyants", "Les Clairvoyants",
	"Lessentinelles", "Les Sentinelles",
	"Lichking", "Lich King",
	"Lightning'sblade", "Lightning's Blade",
	"Light'shope", "Light's Hope",
	"Livingflame", "Living Flame",
	"Lonewolf", "Lone Wolf",
	"Loserrantes", "Los Errantes",
	"Maladath(au)", "Maladath (AU)",
	"Mal'ganis", "Mal'Ganis",
	"Mar\195\169cagedezangar", "Mar\195\169cage de Zangar",
	"Mirageraceway", "Mirage Raceway",
	"Mok'nathal", "Mok'Nathal",
	"Mol'dar'smoxie", "Mol'dar's Moxie",
	"Moonguard", "Moon Guard",
	"Nek'rosh", "Nek'Rosh",
	"Nethergardekeep", "Nethergarde Keep",
	"Oldblanchy", "Old Blanchy",
	"Ookook", "Ook Ook",
	"Orderofthecloudserpent", "Order of the Cloud Serpent",
	"Penance(au)", "Penance (AU)",
	"Penance(season)", "Penance (Season)",
	"Pozzodell'eternit\195\160", "Pozzo dell'Eternit\195\160",
	"Pyrewoodvillage", "Pyrewood Village",
	"Quel'thalas", "Quel'Thalas",
	"Remulos(au)", "Remulos (AU)",
	"Rhok'delar(ru)", "Rhok'delar (RU)",
	"Scarletcrusade", "Scarlet Crusade",
	"Scarshieldlegion", "Scarshield Legion",
	"Shadowcouncil", "Shadow Council",
	"Shadowstrike(au)", "Shadowstrike (AU)",
	"Shadowstrike(season)", "Shadowstrike (Season)",
	"Shatteredhalls", "Shattered Halls",
	"Shatteredhand", "Shattered Hand",
	"Shimmeringflats", "Shimmering Flats",
	"Silverhand", "Silver Hand",
	"Silverwinghold", "Silverwing Hold",
	"Sistersofelune", "Sisters of Elune",
	"Skullrock", "Skull Rock",
	"Slip'kik'ssavvy", "Slip'kik's Savvy",
	"Steamwheedlecartel", "Steamwheedle Cartel",
	"Sundownmarsh", "Sundown Marsh",
	"Tarrenmill", "Tarren Mill",
	"Templenoir", "Temple noir",
	"Tenstorms", "Ten Storms",
	"Theforgottencoast", "The Forgotten Coast",
	"Themaelstrom", "The Maelstrom",
	"Thescryers", "The Scryers",
	"Thesha'tar", "The Sha'tar",
	"Theunderbog", "The Underbog",
	"Theventureco", "The Venture Co",
	"Thoriumbrotherhood", "Thorium Brotherhood",
	"Throk'feroth", "Throk'Feroth",
	"Tolbarad", "Tol Barad",
	"Twilight'shammer", "Twilight's Hammer",
	"Twistingnether", "Twisting Nether",
	"Un'goro", "Un'Goro",
	"Wildgrowth", "Wild Growth",
	"Worldtree", "World Tree",
	"Wyrmrestaccord", "Wyrmrest Accord",
	"Wyrmthalak(ru)", "Wyrmthalak (RU)",
	"Yojamba(au)", "Yojamba (AU)",
	"Zandalartribe", "Zandalar Tribe",
	"Zealotblade", "Zealot Blade",
	"Zirkeldescenarius", "Zirkel des Cenarius",
}
local realmNames

local function realmDisplayName(name)
	if not realmNames then
		realmNames = {}
		for i = 1, #REALM_PAIRS, 2 do
			if realmNames[REALM_PAIRS[i]] == nil then realmNames[REALM_PAIRS[i]] = REALM_PAIRS[i + 1] end
		end
	end
	return realmNames[name]
end

-- Any other realm: a space before each capital or digit, up to the first
-- digit or "(".
local function spaceRealmName(origName)
	local len	= strlen(origName)
	local sb	= strbyte
	local char = string.char
	local c1
	local c
	local gotP = false
	local name = ""

	for count = 1, len do
		c	= sb(origName, count)
		c1 = sb(origName, count+1) or 32

		if ((c1 > 47 and c1 < 58) or (c1 > 64 and c1 < 91) or (c1 == 40)) and gotP == false then
			name = name .. char(c) .. " "

			if (c1 == 40) or (c1 > 47 and c1 < 58) then gotP = true end
		else
			name = name .. char(c)
		end
	end
	return name
end

function M.prettyServer (origName)

	if origName == nil then return nil end

	return realmDisplayName(origName) or spaceRealmName(origName)
end

function M.getServer (name, def)

	local index = string.find(name, "-", 1, true)

	if index ~= nil then
		return string.sub(name, index + 1, string.len(name))
	end

	if def then return def else return V.serverName end
end

function M.removeServer (name, strict)

	if name == nil then
		return nil
	end

	local result = name

	local index = string.find(name, "-", 1, true)

	if strict == nil then
		strict = false
	end

	if index ~= nil then
		local server = M.Proper(string.sub(name, index + 1, string.len(name)));

		if strict == true or server == M.Proper(V.serverName) then
			result = string.sub(name, 1, index - 1)
		end
	end

	return result
end

function M.addServer (name)

	if not name then return nil end

	if string.find(name, "-", 1, true) == nil then
		return name .. "-" .. V.serverName
	end

	return name
end

----------------------
-- SHARED VARIABLES --
----------------------

V.serverName		= M.Proper(GetRealmName())
V.playerName		= M.addServer(GetUnitName("player"), true)

-- Color yellow: ffff0000
-- Color white: ffffff00
-- Color red: 00ff0000
-- Color Horde red: ffe60000
-- Color Cyan: ff69CCF0

-- Client flavour. This package is built for the Mainline client (Interface
-- 120007); the Camelot TOC loads the same files. wowIsRetail is true only on
-- the real Mainline client, so Mainline-only extras (e.g. the addon
-- compartment) are skipped elsewhere; everything else checks that an API
-- exists before using it.
V.wowIsERA		= false
V.wowIsTBC		= false
V.wowIsWrath	= false
V.wowIsCata		= false
V.wowIsMOP		= false
V.wowIsRetail	= (WOW_PROJECT_ID == nil) or (WOW_PROJECT_MAINLINE ~= nil and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
V.wowIsClassic	= false
V.wowLongName	= V.wowIsRetail and "Mainline" or "Other"
V.wowName		= V.wowLongName

------------------------------------------------------------------------
-- Messages (shared by every module)
------------------------------------------------------------------------
function M.debugMsg (msg)
--	if PourSocialScoreDB.showIgnoreDebug == true then
		--print("|cffffff00Pour Social Score: " .. msg)
--	end
end

function M.ShowMsg (msg)
	print ("|cff33ff99Pour Social Score: |cffffffff" .. (msg or "Critical error"))
end

function M.dayString (value)
	if value == 1 then
		return L["DAY"]
	else
		return L["DAYS"]
	end
end

--------------------------
-- W I G P C CATEGORIES --
--------------------------

-- The five things a person or guild rule can be blocked from, in the order
-- every W I G P C header shows them: block category, header letter, the
-- player record field that stores "blocked", and the label.
M.EXCL = {
	{ cat = "whisper",		letter = "W", field = "whispersBlocked",		label = "Whispers" },
	{ cat = "partyInvite", letter = "I", field = "partyInvitesBlocked", label = "Party invites" },
	{ cat = "guildInvite", letter = "G", field = "guildInvitesBlocked", label = "Guild invites" },
	{ cat = "partyRaid",	letter = "P", field = "partyRaidBlocked",		label = "Party/Raid chat (incl. raid warnings)" },
	{ cat = "world",		letter = "C", field = "channelsBlocked",		label = "Chat channels (Trade, General, LFG, communities) and public chat (say, yell, emotes)" },
}
