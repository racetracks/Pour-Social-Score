------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PLAYER IGNORE LIST ROWS AND SORT (3.4.1, core uplift P6)
--
-- What a front end needs to show and change the Player Ignore List, so the
-- PSS window (PourSocialScore_GUI) never reads the saved tables itself.
-- Moved out of core (it only runs while a window or a command needs it,
-- PSS 02 section 5); core keeps M.PSS_PlayersChanged and M.PSS_IsGuildListed
-- (PSS_PlayerQuery.lua).
--   M.PSS_PlayerCount()                   entries on the list
--   M.PSS_PlayerRow(i, out)               entry i as display values, written
--                                         into out (the caller's own table,
--                                         reused for every row: no table
--                                         per row)
--   M.PSS_SortPlayers(key, asc, find, into)  list positions in display order
--   M.PSS_PlayerEntry(i)                  entry i as stored, and its kind
--   M.PSS_PlayerPosition(entry)           position of an entry (0 = none)
--   M.PSS_RemovePlayerAt(i)               remove entry i (player, NPC, server)
--   M.prettyServer(name)                  a realm as shown ("Area 52")
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local V = addon.V

local find, sub, lower = string.find, string.sub, string.lower
local strlen, strbyte = string.len, string.byte

local EXCL_BY_CAT = {}
for _, e in ipairs(M.EXCL) do EXCL_BY_CAT[e.cat] = e end

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

function M.PSS_PlayerCount()
	return #M.PSS_List()
end

-- out gets: entry (as stored), kind ("player", "npc", "server"), name,
-- server (both as shown: a server entry reads All / <server>), faction,
-- added (the date listed, as saved), listed (days on the list), expire (days after listing, 0 = never),
-- left (days until it expires), note, record (the player's settings and
-- counts; players only, else false). Returns out, or nil when there is no
-- entry i.
function M.PSS_PlayerRow(i, out)
	local e = M.PSS_List()[i]
	local entry = e and e.name
	if not entry then return nil end
	local kind = e.kind or "player"		-- (as RemoveFromList reads it)
	local name, server = entry, "All"
	local dash = find(entry, "-", 1, true)
	if dash then
		name = sub(entry, 1, dash - 1)
		server = M.prettyServer(sub(entry, dash + 1))
	end
	if kind ~= "player" and kind ~= "npc" then
		kind = "server"
		server = M.prettyServer(name)
		name = "All"
	end
	local listed = M.daysFromToday(e.date)
	local expire = e.exp or 0
	out.entry, out.kind, out.name, out.server = entry, kind, name, server
	out.faction = e.faction
	out.added = e.date
	out.listed, out.expire, out.left = listed, expire, expire - listed
	out.note = e.note or ""
	out.record = kind == "player" and M.PSS_GetPlayerPrefs(entry) or false
	return out
end

function M.PSS_PlayerEntry(i)
	local entry = M.PSS_EntryName(i)
	if entry then return entry, M.PSS_EntryKind(i) end
end

function M.PSS_PlayerPosition(entry)
	if type(entry) ~= "string" then return 0 end
	return M.hasAnyIgnored(entry) or 0
end

------------------------------------------------------------------------
-- Sorting: one key + direction. Keys: name, server, type, listed, expire,
-- note, "metric:<cat>" (block counts) and "excl:<cat>" (W I G P C, by
-- tick: allowed first when ascending). Blank values (empty notes; counts
-- and switches of NPC and server rows) always go last; ties fall back to
-- name A-Z, then server A-Z, then list order.
------------------------------------------------------------------------
local function elementName(i)
	local kind = M.PSS_EntryKind(i)
	if kind == "player" or kind == "npc" then
		return M.removeServer(M.PSS_EntryName(i), true)
	elseif kind == "server" then
		return "All"
	end
	return ""
end

local function elementServer(i)
	local kind = M.PSS_EntryKind(i)
	if kind == "player" then
		return M.getServer(M.PSS_EntryName(i))
	elseif kind == "server" then
		return M.PSS_EntryName(i)
	elseif kind == "npc" then
		return "All"
	end
	return ""
end

local function elementType(i)
	local kind = M.PSS_EntryKind(i)
	if kind == "player" then return M.PSS_List()[i].faction end
	return kind
end

local function sortValue(i, key)
	local e = M.PSS_List()[i]
	if key == "name" then return lower(elementName(i) or "")
	elseif key == "server" then return lower(elementServer(i) or "")
	elseif key == "type" then return lower(elementType(i) or "")
	elseif key == "listed" then return M.daysFromToday(e.date) or 0
	elseif key == "expire" then
		local x = tonumber(e.exp) or 0
		if x == 0 then return math.huge end				-- never expires: after everything
		return x - (M.daysFromToday(e.date) or 0)
	elseif key == "note" then
		local n = lower(e.note or "")
		if n == "" then return nil end					-- empty notes go last
		return n
	end
	local mcat = key:match("^metric:(.+)$")
	if mcat then
		if (e.kind or "player") ~= "player" then return nil end
		local p = M.PSS_GetPlayerRecord(e.name)
		return p and (tonumber(M.PSS_GetPlayerBlockCounts(p)[mcat]) or 0) or 0
	end
	local cat = key:match("^excl:(.+)$")
	local ex = cat and EXCL_BY_CAT[cat]
	if ex then
		if (e.kind or "player") ~= "player" then return nil end
		local p = M.PSS_GetPlayerRecord(e.name)
		return (not p or p[ex.field] ~= false) and 0 or 1	-- ticked (allowed) = 1
	end
	return 0
end

-- find: text to look for in the name, server and note (any case; "" or nil
-- = every entry). into: the table to fill (emptied first; a new one when
-- nil). Returns into and the number of positions in it.
function M.PSS_SortPlayers(key, asc, findText, into)
	local list = M.PSS_List()
	into = into or {}
	for i = #into, 1, -1 do into[i] = nil end
	if findText == "" then findText = nil end
	if findText then findText = lower(findText) end

	local sv, nv, srv = {}, {}, {}
	local n = 0
	for i = 1, #list do
		local keep = true
		if findText then
			-- the server as stored ("Area52") and as shown ("Area 52")
			local entry = list[i].name
			local dash = find(entry, "-", 1, true)
			local shown = M.prettyServer(dash and sub(entry, dash + 1) or entry) or ""
			keep = find(lower(entry), findText, 1, true) ~= nil
				or find(lower(shown), findText, 1, true) ~= nil
				or find(lower(list[i].note or ""), findText, 1, true) ~= nil
		end
		if keep then
			n = n + 1
			into[n] = i
			sv[i] = sortValue(i, key)
			nv[i] = lower(elementName(i) or "")
			srv[i] = lower(elementServer(i) or "")
		end
	end

	table.sort(into, function(a, b)
		local A, B = sv[a], sv[b]
		if A ~= B then
			if A == nil then return false end			-- blanks always last
			if B == nil then return true end
			if asc then return A < B else return A > B end
		end
		if nv[a] ~= nv[b] then return nv[a] < nv[b] end
		if srv[a] ~= srv[b] then return srv[a] < srv[b] end
		return a < b
	end)
	return into, n
end

------------------------------------------------------------------------
-- Changes
------------------------------------------------------------------------
-- Remove entry i straight away: a player (also from Blizzard's ignore
-- list), an NPC or a whole server.
function M.PSS_RemovePlayerAt(i)
	local kind = M.PSS_EntryKind(i)
	if kind == "player" then
		M.PSS_DelIgnore(i, true)
	elseif kind == "npc" then
		M.AddOrDelNPC(i)
		M.PSS_PlayersChanged()
	elseif kind == "server" then
		M.AddOrDelServer(i)
		M.PSS_PlayersChanged()
	end
end
