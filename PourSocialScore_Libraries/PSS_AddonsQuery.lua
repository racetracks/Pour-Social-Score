------------------------------------------------------------------------
-- POUR SOCIAL SCORE - ADDON MANAGER, THE LOGIC (/pss acp, 3.6.0)
--
-- Everything the AddOns tab and /pss acp do, written for this addon from
-- scratch documents/features/addon-helper/05_Detailed_Design.md (clean room: no code, names or
-- texts of any other addon manager). The tab only draws; every call into
-- the client's addon API is here.
--
-- The list is built per call as plain arrays of addon indexes (no table per
-- addon); a row's state is read from the client when it is drawn. Nothing
-- is kept on M, in an upvalue or in a frame between calls except the small
-- lock list cache, dropped by M.PSS_AddonRelease (the window's close).
-- No events are registered: the tab hears ADDONS_CHANGED while it shows.
--
-- Saved (only what the player chose, packed, capped, pruned): presets and
-- protected addons per character (PSS_CharDB) and for all characters
-- (PSS_OptionsDB addonSets, addonLock), and the list view (addonView).
--   M.PSS_AddonCan(what)               the client has the API for what
--   M.PSS_AddonCount()                 addons installed
--   M.PSS_AddonList(who, view, search) the list, grouped (who "me" / "all")
--   M.PSS_AddonRow(i, who, out)        one addon's state, drawn live
--   M.PSS_AddonTick(i, on, who, deps)  enable or disable (deps: its required ones)
--   M.PSS_AddonTickMany(L, a, b, on, who, deps)   a group, protected spared
--   M.PSS_AddonLoad(i)                 load a load-on-demand addon
--   M.PSS_AddonAll(on, who)            Enable All / Disable All
--   M.PSS_AddonUndo()  M.PSS_AddonPending(who)  M.PSS_AddonReload()
--   M.PSS_AddonDeps(i, who)            required and optional, with state
--   M.PSS_AddonPresets(), M.PSS_AddonSlots(who) and ...PresetSave / Load / Add / Remove / Rename / Delete
--                                      (the addon profiles; "presets" in code)
--   M.PSS_AddonProfileSelect(id, on, who)  M.PSS_AddonProfileSelected(id, who)
--   M.PSS_AddonProfileUnion(who)       the names selected profiles and hand picks want on
--   M.PSS_AddonLock(name, on, who)  M.PSS_AddonLocked(name)
--   M.PSS_AddonViewMode(v)  M.PSS_AddonLoadOld(on)
--   M.PSS_AddonPrune()  M.PSS_AddonRelease()  M.PSS_AddonCommand(args, raw)
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
if not M.PSS_On("addons") then return end	-- the Addon Manager is off: nothing of it is loaded (issue 181)

local type, tonumber, tostring, pcall, select = type, tonumber, tostring, pcall, select
local pairs, ipairs, next = pairs, ipairs, next
local sort, concat = table.sort, table.concat
local format, lower, sub, find, byte, gsub = string.format, string.lower, string.sub, string.find, string.byte, string.gsub
local floor = math.floor
local tremove = table.remove
local InCombatLockdown, UnitGUID, UnitClass = InCombatLockdown, UnitGUID, UnitClass

local iface = select(4, GetBuildInfo())
local DIGIT = (type(iface) == "number" and iface < 20000) and "2" or "1"	-- the client in a set: 1 Retail, 2 Camelot
local PRESETS_MAX = 25
local CORE_MAX = 5	-- places 1 to 5 are the Core Addon Profiles, the rest Layered
local NAME_MAX = 32
local NL = "\n"

-- the client's addon API, once (C_AddOns on current clients, the old
-- globals where it is missing)
local function api(n) return (C_AddOns and C_AddOns[n]) or _G[n] end
local GetNumAddOns, GetAddOnInfo, GetAddOnMetadata = api("GetNumAddOns"), api("GetAddOnInfo"), api("GetAddOnMetadata")
local EnableAddOn, DisableAddOn = api("EnableAddOn"), api("DisableAddOn")
local EnableAllAddOns, DisableAllAddOns = api("EnableAllAddOns"), api("DisableAllAddOns")
local GetDeps, GetOptDeps = api("GetAddOnDependencies"), api("GetAddOnOptionalDependencies")
local IsLoaded, IsLoD, LoadAddOn = api("IsAddOnLoaded"), api("IsAddOnLoadOnDemand"), api("LoadAddOn")
local SaveAddOns, ResetAddOns = api("SaveAddOns"), api("ResetAddOns")
local GetVersionCheck, SetVersionCheck = api("IsAddonVersionCheckEnabled"), api("SetAddonVersionCheck")
-- GetAddOnEnableState(name, character) on 11.0 and later, (character, name) before
local stateNew = C_AddOns and C_AddOns.GetAddOnEnableState
local stateOld = (not stateNew) and _G.GetAddOnEnableState
local NONE = (Enum and Enum.AddOnEnableState and Enum.AddOnEnableState.None) or 0

-- the chat texts (English, inline as the other Libraries files)
local T = {
	noApi = "The AddOn list is not available on this client.",
	noChar = "This character could not be told apart: nothing was changed.",
	combat = "Not in combat.",
	reload = " Reload to apply.",
	unknown = "No addon called \"%s\".",
	pss = "Pour Social Score cannot be turned off here.",
	notLod = "%s does not load on demand.",
	loadFail = "%s did not load: %s.",
	loaded = "%s loaded.",
	on = "%s is on for %s.",
	off = "%s is off for %s.",
	needs = " Needs %s, which is not installed.",
	alsoOn = " Also turned on: %s.",
	allOn = "Every addon is on for %s.",
	allOff = "Every addon is off for %s (Pour Social Score and protected addons stay on).",
	undone = "Back to the addons as at login.",
	noUndo = "This client cannot undo.",
	me = "this character",
	everyone = "all characters",
	listHead = "%d addons, %d on for %s:",
	listRow = "  %s: %s",
	presetUsage = "Addon profiles: /pss acp profile <1-25 or your class> [char|all] save [name] | load | enable | disable | select | deselect | rename <name> | delete",
	presetNone = "No addon profiles saved yet.",
	presetHead = "Addon profiles (* selected):",
	presetRow = "  %s%s %s (%s): %d addons",
	presetSaved = "Addon profile %s saved: %d addons.",
	presetLoaded = "Addon profile %s: %d on, %d not installed.",
	presetEnabled = "Addon profile %s: %d enabled, %d not installed.",
	presetDisabled = "Addon profile %s: %d disabled, %d not installed.",
	presetEmpty = "Addon profile %s has no installed addon.",
	presetAdded2 = "Addon profile %s now holds %s.",
	presetDeleted = "Addon profile %s deleted.",
	presetRenamed = "Addon profile %s renamed.",
	presetSelected = "Addon profile %s selected: %d on, %d not installed.",
	presetDeselected = "Addon profile %s deselected: %d off, %d kept by others.",
	presetNo = "There is no addon profile %s here.",
	presetBadId = "\"%s\" is not an addon profile: use 1 to %d or your class.",
	presetOther = "Addon profile %s was saved by a newer version and is left alone.",
	nameEmpty = "Give the addon profile a name.",
	nameLong = "That name is too long: at most %d letters.",
	nameDup = "Another addon profile here is already called \"%s\".",
	lockOn = "%s is protected.",
	lockOff = "%s is not protected any more.",
	lockPss = "Pour Social Score is always protected.",
	apiHave = "Addon API present: %s.",
	apiLack = "Addon API missing: %s.",
	apiNone = "none",
	help = "/pss acp: list [filter] | on <name> | off <name> | load <name> | all on|off | undo | profiles | profile <id> ... | lock <name> | unlock <name> | api",
}
M.PSS_AddonText = T

-- the checks the tab and commands make before they offer a feature
local CAN = {
	list = function() return GetNumAddOns and GetAddOnInfo and (stateNew or stateOld) end,
	tick = function() return EnableAddOn and DisableAddOn end,
	all = function() return EnableAllAddOns and DisableAllAddOns end,
	load = function() return LoadAddOn end,
	undo = function() return ResetAddOns end,
	loadold = function() return GetVersionCheck and SetVersionCheck end,
}
function M.PSS_AddonCan(what)
	local f = CAN[what]
	return f and f() and true or false
end

local function count()
	return GetNumAddOns and GetNumAddOns() or 0
end
function M.PSS_AddonCount() return count() end

-- (the full API list for /pss acp api: label, present)
local API_NAMES = { "GetNumAddOns", "GetAddOnInfo", "GetAddOnMetadata", "EnableAddOn", "DisableAddOn", "EnableAllAddOns",
	"DisableAllAddOns", "GetAddOnDependencies", "GetAddOnOptionalDependencies", "IsAddOnLoaded", "IsAddOnLoadOnDemand",
	"LoadAddOn", "SaveAddOns", "ResetAddOns",
	"IsAddonVersionCheckEnabled", "SetAddonVersionCheck" }

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
local function guid()
	local g = UnitGUID and UnitGUID("player")
	if type(g) ~= "string" or M.PSS_IsSecret(g) then return nil end
	return g
end

-- the character argument: this character's GUID, or nil for all of them
-- (false when this character cannot be told: nothing may be written)
local function charArg(who)
	if who == "all" then return nil end
	return guid() or false
end

local function plain(s)
	s = gsub(s, "|c%x%x%x%x%x%x%x%x", "")
	s = gsub(s, "|r", "")
	return (gsub(s, "|T[^|]*|t", ""))
end

local function isPSS(name)
	return name == "PourSocialScore" or sub(name, 1, 16) == "PourSocialScore_"
end

local function meta(i, field)
	if not GetAddOnMetadata then return nil end
	local ok, v = pcall(GetAddOnMetadata, i, field)
	if ok and type(v) == "string" and v ~= "" then return v end
end

-- name, title, notes, loadable, reason (a table on a client that returns one)
local function info(i)
	local a, b, c, d, e = GetAddOnInfo(i)
	if type(a) == "table" then return a.name, a.title, a.notes, a.loadable, a.reason end
	return a, b, c, d, e
end

local function enableState(i, who)
	local c = charArg(who)
	if c == false then return 0 end
	local s
	if stateNew then s = stateNew(i, c) elseif stateOld then s = stateOld(c, i) end
	return tonumber(s) or 0
end

local function fire()
	M.Events.Fire("ADDONS_CHANGED")
end

local function save()
	if SaveAddOns then SaveAddOns() end
end

local function whoText(who)
	return who == "all" and T.everyone or T.me
end

-- name -> index, for one command (never kept)
local function nameMap()
	local map = {}
	for i = 1, count() do
		local n = info(i)
		if type(n) == "string" then map[n] = i end
	end
	return map
end

local function hidden(name)
	return sub(name, 1, 9) == "Blizzard_"
end

------------------------------------------------------------------------
-- Saved data: protected addons and presets, per character (PSS_CharDB) and
-- for all characters (PSS_OptionsDB), packed as strings
--   addonLock   account: { [client] = "NameA\nNameB" }, character: "NameA\nNameB"
--   addonPick   the same shape: the addons ticked by hand in the tab
--   addonSel    account: { [client] = "1 3 WARRIOR" }, character: "1 3 WARRIOR":
--               the addon profiles selected (a number, or the class token)
--   addonSets   account: { [1..25 or CLASS] = "<client><name>\nAddonA\nAddonB" }
--               character: { [1..25] = "<name>\nAddonA\nAddonB" }
-- A key goes back to nil when it is empty, so an unused character writes
-- nothing. Names never hold a newline, so the packing is exact.
------------------------------------------------------------------------
local function acct()
	local db = PourSocialScoreDB
	return type(db) == "table" and db or nil
end

-- This character's keys are account-wide owned keys from 3.7.0.102 (SAV-00036):
-- addonSetsOf, addonLockOf, addonSelOf and addonPickOf in PSS_OptionsDB, a packed
-- string under this character's entity id (M.PSS_Owned). chr() decodes them
-- into one table with the old PSS_CharDB shape (addonSets a table), kept
-- until tidyChar() writes it back, so the code below reads and writes as before.
local CHAR = { addonSets = "addonSetsOf", addonLock = "addonLockOf", addonSel = "addonSelOf", addonPick = "addonPickOf" }
local RS, US = "\30", "\31"	-- between profiles, between a number and its string
local view, viewId, viewRaw, viewOther

-- { [number] = string } to one string; nil when it holds anything else
local function packSets(t)
	local keys = {}
	for k, v in pairs(t) do
		if type(k) ~= "number" or type(v) ~= "string" or v:find(RS, 1, true) or v:find(US, 1, true) then return nil end
		keys[#keys + 1] = k
	end
	sort(keys)
	for i = 1, #keys do keys[i] = keys[i] .. US .. t[keys[i]] end
	return concat(keys, RS)
end

local function unpackSets(s)
	local t = {}
	for part in (s .. RS):gmatch("(.-)" .. RS) do
		local k, v = part:match("^(%d+)" .. US .. "(.*)$")
		if k then t[tonumber(k)] = v end
	end
	return t
end

local function slot(key)
	return M.PSS_Owned and M.PSS_Owned(CHAR[key])
end

local function chr(create)
	if not M.PSS_Me then return nil end
	local id = M.PSS_Me(create and true or nil)
	if not id then return nil end
	local stale = view == nil or viewId ~= id
	local raw = {}
	for key in pairs(CHAR) do
		local o = slot(key)
		raw[key] = o and o:Get(id) or nil
		if viewRaw and raw[key] ~= viewRaw[key] then stale = true end
	end
	if stale then
		view, viewId, viewRaw, viewOther = {}, id, raw, {}
		for key, v in pairs(raw) do
			if type(v) ~= "string" then
				viewOther[key] = true	-- another shape (a newer version's): never read, never replaced
			elseif key == "addonSets" then
				view[key] = unpackSets(v)
			else
				view[key] = v
			end
		end
	end
	return view
end

-- write the character's table back to the owned keys (and drop the empty ones)
local function tidyChar()
	if not view then return end
	for key in pairs(CHAR) do
		if not viewOther[key] then
			local v, str = view[key], nil
			if key == "addonSets" then
				if type(v) == "table" and next(v) ~= nil then
					str = packSets(v)
					if not str then str = viewRaw[key] end
				end
			elseif type(v) == "string" and v ~= "" then
				str = v
			end
			local o = slot(key)
			if o and str ~= viewRaw[key] and o:Set(viewId, str) then viewRaw[key] = str end
		end
	end
end

-- upgrade step 11: move the four keys of a 3.6.x PSS_CharDB c under this
-- character; a slot that already holds data wins (that key stays in c);
-- returns the keys moved and the keys kept
function M.PSS_AddonCharMove(c)
	local id = M.PSS_Me and M.PSS_Me(true)
	if not id or type(c) ~= "table" then return 0, 0 end
	local moved, kept = 0, 0
	for key in pairs(CHAR) do
		local v, o = c[key], slot(key)
		if v ~= nil and o then
			local str = type(v) == "string" and v or (type(v) == "table" and packSets(v)) or nil
			if str and str ~= "" then
				if o:Get(id) ~= nil then
					kept = kept + 1
				elseif o:Set(id, str) then
					c[key] = nil
					moved = moved + 1
				end
			elseif type(v) == "table" and next(v) == nil then
				c[key] = nil
			end
		end
	end
	view = nil
	return moved, kept
end

-- the retry of upgrade step 11 (issue 224): called by the core trigger row "charmove"
-- once Libraries has loaded; moves what can move, then takes the row down
M.PSS_Provide("upg.charmove", function()
	local c = _G["PSS_CharDB"]
	if type(c) == "table" and M.PSS_Me and M.PSS_Me(true) then
		if next(c) ~= nil then M.PSS_AddonCharMove(c) end
		if next(c) == nil then _G["PSS_CharDB"] = nil end
		if M.PSS_TriggerOff then M.PSS_TriggerOff("charmove") end
	elseif type(c) ~= "table" and M.PSS_TriggerOff then
		M.PSS_TriggerOff("charmove")
	end
	return M.PSS_Set({ "moved" })
end, { returns = { "moved" }, doc = "step 11 retry: move PSS_CharDB into the owned keys" })

-- "a\nb\nc" from a sorted list
local function packNames(list)
	sort(list)
	return concat(list, NL)
end

-- the names in str from position pos
local function eachName(str, pos, fn)
	if not pos or pos > #str then return end
	for n in str:sub(pos):gmatch("[^\n]+") do fn(n) end
end

local lockCache
local function lockSet()
	if lockCache then return lockCache end
	lockCache = {}
	local db = acct()
	local a = db and type(db.addonLock) == "table" and db.addonLock[DIGIT]
	if type(a) == "string" then eachName(a, 1, function(n) lockCache[n] = true end) end
	local c = chr()
	local s = c and c.addonLock
	if type(s) == "string" then eachName(s, 1, function(n) lockCache[n] = true end) end
	return lockCache
end

function M.PSS_AddonLocked(name)
	if type(name) ~= "string" then return false end
	M.PSS_AddonPrune()
	return isPSS(name) or lockSet()[name] == true
end

local function lockStrings()
	local db = acct()
	local a = db and type(db.addonLock) == "table" and db.addonLock[DIGIT]
	local c = chr()
	return type(a) == "string" and a or nil, c and type(c.addonLock) == "string" and c.addonLock or nil
end

local function setLockList(scope, list)
	local str = #list > 0 and packNames(list) or nil
	if scope == "all" then
		local db = acct()
		if not db then return end
		local t = type(db.addonLock) == "table" and db.addonLock or {}
		t[DIGIT] = str
		db.addonLock = next(t) ~= nil and t or nil
	else
		local c = chr(str ~= nil)
		if c then c.addonLock = str end
		tidyChar()
	end
end

local function listOf(str)
	local l = {}
	if str then eachName(str, 1, function(n) l[#l + 1] = n end) end
	return l
end

-- who "all": the account-wide list; "me": this character's. Unlock leaves
-- both. PSS's own folders are always protected and never stored.
function M.PSS_AddonLock(name, on, who)
	M.PSS_AddonPrune()
	if type(name) ~= "string" or name == "" or find(name, NL, 1, true) then return false end
	if isPSS(name) then return false, T.lockPss end
	local a, c = lockStrings()
	local scope = who == "all" and "all" or "me"
	if on then
		local l
		if scope == "all" then l = listOf(a) else l = listOf(c) end
		for _, n in ipairs(l) do if n == name then return true end end
		if #l >= count() and count() > 0 then return false end
		l[#l + 1] = name
		setLockList(scope, l)
	else
		for _, sc in ipairs({ "all", "me" }) do
			local l, out
			if sc == "all" then l = listOf(a) else l = listOf(c) end
			out = {}
			for _, n in ipairs(l) do if n ~= name then out[#out + 1] = n end end
			if #out ~= #l then setLockList(sc, out) end
		end
	end
	lockCache = nil
	fire()
	return true
end

-- a packed string kept under key for who: the account's under the client
-- digit, this character's as the string itself. A value of another shape
-- (a newer version's) is never read and never replaced.
local function getPacked(key, who)
	if who == "all" then
		local db = acct()
		local t = db and type(db[key]) == "table" and db[key]
		local v = t and t[DIGIT]
		return type(v) == "string" and v or nil
	end
	local c = chr()
	local v = c and c[key]
	return type(v) == "string" and v or nil
end

local function setPacked(key, who, str)
	if who == "all" then
		local db = acct()
		if not db or (db[key] ~= nil and type(db[key]) ~= "table") then return end
		local t = db[key] or {}
		t[DIGIT] = str
		db[key] = next(t) ~= nil and t or nil
	else
		local c = chr(str ~= nil)
		if c and (c[key] == nil or type(c[key]) == "string") then c[key] = str end
		tidyChar()
	end
end

-- Hand picks: the addons the player turned on by hand while addon profiles
-- are selected (ticked in the tab) and those already on when a profile is
-- selected. A pick that is also in a selected profile stays on when that
-- profile is deselected. Ticking off, a profile load, Enable All, Disable
-- All and Undo forget them. With nothing selected nothing is recorded.
local function pickNames(who)
	return listOf(getPacked("addonPick", who))
end

local function notePicks(names, on, who, force)
	if on and not force and getPacked("addonSel", who) == nil then return end
	local have = {}
	local l = pickNames(who)
	for _, n in ipairs(l) do have[n] = true end
	local changed = false
	if on then
		for _, n in ipairs(names) do
			if not have[n] and not isPSS(n) and not hidden(n) and not find(n, NL, 1, true) and #l < count() then
				l[#l + 1] = n
				have[n] = true
				changed = true
			end
		end
	else
		local gone = {}
		for _, n in ipairs(names) do gone[n] = true end
		local out = {}
		for _, n in ipairs(l) do
			if not gone[n] then out[#out + 1] = n end
		end
		changed = #out ~= #l
		l = out
	end
	if changed then setPacked("addonPick", who, #l > 0 and packNames(l) or nil) end
end

-- the profiles selected for who: ids (numbers, or a class token), in order
local function selIds(who)
	local out = {}
	local str = getPacked("addonSel", who)
	if str then
		for tok in str:gmatch("%S+") do out[#out + 1] = tonumber(tok) or tok end
	end
	return out
end

local function setSelIds(who, ids)
	local out = {}
	for _, id in ipairs(ids) do out[#out + 1] = tostring(id) end
	setPacked("addonSel", who, #out > 0 and concat(out, " ") or nil)
end

-- forget the selection and the picks (a whole-state change: Enable All,
-- Disable All, Undo, a profile load); keep is an id to stay selected
local function forgetChoice(who, keep)
	setSelIds(who, keep and { keep } or {})
	setPacked("addonPick", who, nil)
end

-- the list view: nil = grouped (the default), "az" or "lod"
function M.PSS_AddonViewMode(v)
	local db = acct()
	if not db then return nil end
	if v == nil then
		local cur = db.addonView
		return (cur == "az" or cur == "lod") and cur or "group"
	end
	db.addonView = (v == "az" or v == "lod") and v or nil
	return M.PSS_AddonViewMode()
end

-- "Load out of date AddOns" (the client's version check is its opposite)
function M.PSS_AddonLoadOld(on)
	if not (GetVersionCheck and SetVersionCheck) then return nil end
	if on == nil then return not GetVersionCheck() end
	SetVersionCheck(not on)
	save()
	fire()
	return on and true or false
end

------------------------------------------------------------------------
-- The list
------------------------------------------------------------------------
-- scratch of the list build (arrays by addon index), reused by every build
-- while the window is open and dropped by M.PSS_AddonRelease, so a rebuild
-- makes almost no garbage; one comparator, no closure per build
local X1, X2, X3, GD, GK, GL, GC = {}, {}, {}, {}, {}, {}, {}
local function before(a, b)
	local x, y = X1[a], X1[b]
	if x ~= y then return x < y end
	x, y = X2[a], X2[b]
	if x ~= y then return x < y end
	x, y = X3[a], X3[b]
	if x ~= y then return x < y end
	return a < b
end

local LIBS = "Libraries"
local LODNAME = "Load on demand"

-- the group an addon belongs to: its TOC Group, else Libraries, else the
-- word before the first _ or - of its name (a leading ! _ or + ignored);
-- returns the display name
local function groupName(i, name)
	local g = meta(i, "Group")
	if g then return plain(g) end
	local cat = meta(i, "X-Category") or meta(i, "Category")
	if (cat and lower(cat) == "library") or (sub(name, 1, 3) == "Lib" and find(name, "^Lib%u")) then return LIBS end
	local s = gsub(name, "^[!_+]+", "")
	return s:match("^([^_%-]+)[_%-]") or s
end

-- who: "me" or "all". view: "group" (default), "az" or "lod". search: text
-- in the name or title. Returns L = { n, idx = {addon indexes in order},
-- gi = { [position] = group number }, groups = { { name, from, to } } }.
function M.PSS_AddonList(who, view, search)
	M.PSS_AddonPrune()
	local L = { n = 0, idx = {}, gi = {}, groups = {} }
	if not CAN.list() then return L end
	local needle = search and search ~= "" and lower(search) or nil
	local idx, n = L.idx, 0
	local byGroup = view ~= "az" and view ~= "lod"
	for i = 1, count() do
		local name, title = info(i)
		if type(name) == "string" and not hidden(name) then
			local key = lower(plain(type(title) == "string" and title ~= "" and title or name))
			if not needle or find(lower(name), needle, 1, true) or find(key, needle, 1, true) then
				n = n + 1
				idx[n] = i
				X3[i] = key
				if byGroup then
					local g = groupName(i, name)
					local k = lower(g)
					GD[i], GK[i] = g, k
					GC[k] = (GC[k] or 0) + 1
					GL[i] = lower(name) == k
				elseif view == "lod" then
					X1[i] = (IsLoD and IsLoD(i)) and "b" or "a"
					X2[i] = key
					X3[i] = ""
				else
					X1[i], X2[i], X3[i] = key, 0, ""
				end
			end
		end
	end
	if byGroup then
		for p = 1, n do
			local i = idx[p]
			local k = GK[i]
			local grouped = GC[k] > 1 or GD[i] == LIBS
			if GD[i] == LIBS then
				X1[i] = "\127"
			elseif grouped then
				X1[i] = k
			else
				X1[i] = X3[i]
				GK[i] = false
			end
			X2[i] = (not grouped or GL[i]) and 0 or 1
		end
	end
	sort(idx, before)
	-- the groups: runs of one key (grouped view), or the load on demand tail
	local groups, gi = L.groups, L.gi
	if byGroup then
		local cur, curKey
		for p = 1, n do
			local i = idx[p]
			local k = GK[i]
			if k then
				if curKey == k then
					cur.to = p
				else
					cur, curKey = { name = GD[i], from = p, to = p }, k
					groups[#groups + 1] = cur
				end
				gi[p] = #groups
			else
				curKey = nil
			end
		end
	elseif view == "lod" then
		for p = 1, n do
			if X1[idx[p]] == "b" then
				groups[1] = { name = LODNAME, from = p, to = n }
				for q = p, n do gi[q] = 1 end
				break
			end
		end
	end
	-- the scratch is emptied for the next build
	for p = 1, n do
		local i = idx[p]
		X1[i], X2[i], X3[i], GD[i], GK[i], GL[i] = nil, nil, nil, nil, nil, nil
	end
	for k in pairs(GC) do GC[k] = nil end
	L.n = n
	return L
end

local function status(o)
	local r = o.reason
	if o.loaded then
		if o.enabled then return "ok", "Loaded" end
		return "reload", "Turns off at reload"
	end
	if not o.enabled then
		if r == "MISSING" then return "bad", "Missing" end
		return "off", "Disabled"
	end
	if r == "DEP_DISABLED" or r == "DEP_MISSING" or r == "DEP_CORRUPT" or r == "DEP_INCOMPATIBLE" then
		o.blocked = true
		return "warn", _G["ADDON_" .. r] or "Dependency off"
	end
	if r == "INTERFACE_VERSION" or r == "INCOMPATIBLE" or r == "CORRUPT" or r == "MISSING" then
		o.blocked = true
		if r == "INTERFACE_VERSION" then o.outdated = true end
		return "bad", _G["ADDON_" .. r] or "Out of date"
	end
	if o.lod then return "lod", "Load on demand" end
	return "reload", "Turns on at reload"
end

-- one addon, from the client now; out is a table to fill (the tab reuses one)
function M.PSS_AddonRow(i, who, o)
	local name, title, notes, _, reason = info(i)
	o = o or {}
	o.i, o.name, o.reason = i, name, reason
	o.title = (type(title) == "string" and title ~= "") and title or name
	o.notes = notes
	o.state = enableState(i, who)
	o.enabled = o.state ~= NONE
	o.loaded = IsLoaded and IsLoaded(i) and true or false
	o.lod = IsLoD and IsLoD(i) and true or false
	o.blocked, o.outdated = nil, nil
	o.pss = type(name) == "string" and isPSS(name) or false
	o.locked = o.pss or (type(name) == "string" and M.PSS_AddonLocked(name)) or false
	o.status, o.text = status(o)
	o.canLoad = o.enabled and o.lod and not o.loaded and not o.blocked
	return o
end

function M.PSS_AddonName(i)
	local name = info(i)
	return type(name) == "string" and name or nil
end

function M.PSS_AddonMeta(i, field)
	return meta(i, field)
end

-- an addon's own icon: the texture file, or the atlas, from its TOC
function M.PSS_AddonIcon(i)
	local atlas = meta(i, "IconAtlas")
	if atlas then return nil, atlas end
	return meta(i, "IconTexture")
end

-- an addon's requirements and extras, for its tip: two arrays of { name, text }
function M.PSS_AddonDeps(i, who)
	local req, opt = {}, {}
	local function fill(into, get)
		if not get then return end
		for _, d in ipairs({ get(i) }) do
			local n = info(d)
			local text
			if type(n) ~= "string" or n == "" then
				text = "not installed"
			elseif IsLoaded and IsLoaded(d) then
				text = "loaded"
			elseif enableState(d, who) ~= NONE then
				text = "on"
			else
				text = "off"
			end
			into[#into + 1] = { name = d, text = text }
		end
	end
	fill(req, GetDeps)
	fill(opt, GetOptDeps)
	return req, opt
end

------------------------------------------------------------------------
-- Changes
------------------------------------------------------------------------
-- turn one addon on or off; deps also turns its required addons on (one
-- walk with a visited set, so a loop ends). Returns turnedOn (names),
-- missing (names), without saving or firing.
local function applyOne(i, name, on, c, deps, turned, missing)
	if not on then
		DisableAddOn(i, c)
		return
	end
	EnableAddOn(i, c)
	if not (deps and GetDeps) then return end
	local seen, stack = { [name] = true }, { i }
	local top = 1
	local map
	while top > 0 do
		local cur = stack[top]
		stack[top] = nil
		top = top - 1
		for _, d in ipairs({ GetDeps(cur) }) do
			if type(d) == "string" and not seen[d] then
				seen[d] = true
				map = map or nameMap()
				local di = map[d]
				if di then
					if enableState(di, c == nil and "all" or "me") == NONE then
						EnableAddOn(di, c)
						turned[#turned + 1] = d
					end
					top = top + 1
					stack[top] = di
				else
					missing[#missing + 1] = d
				end
			end
		end
	end
end

local function tickText(name, on, who, turned, missing)
	local t = format(on and T.on or T.off, name, whoText(who))
	if #turned > 0 then t = t .. format(T.alsoOn, concat(turned, ", ")) end
	if #missing > 0 then t = t .. format(T.needs, concat(missing, ", ")) end
	return t
end

function M.PSS_AddonTick(i, on, who, deps)
	M.PSS_AddonPrune()
	if not CAN.tick() then return false, T.noApi end
	local c = charArg(who)
	if c == false then return false, T.noChar end
	local name = info(i)
	if type(name) ~= "string" then return false, format(T.unknown, tostring(i)) end
	if not on and isPSS(name) then return false, T.pss end
	local turned, missing = {}, {}
	applyOne(i, name, on, c, deps, turned, missing)
	notePicks({ name }, on, who)
	save()
	fire()
	return true, tickText(name, on, who, turned, missing)
end

-- positions a to b of a built list, together; protected addons and Pour
-- Social Score are spared when turning off
function M.PSS_AddonTickMany(L, a, b, on, who, deps)
	M.PSS_AddonPrune()
	if not CAN.tick() then return false, T.noApi end
	local c = charArg(who)
	if c == false then return false, T.noChar end
	local turned, missing, done, picked = {}, {}, 0, {}
	for p = a, b do
		local i = L.idx[p]
		local name = i and info(i)
		if type(name) == "string" and (on or not M.PSS_AddonLocked(name)) then
			applyOne(i, name, on, c, deps, turned, missing)
			done = done + 1
			picked[done] = name
		end
	end
	notePicks(picked, on, who)
	save()
	fire()
	return true, done
end

function M.PSS_AddonLoad(i)
	M.PSS_AddonPrune()
	if InCombatLockdown() then return false, T.combat end
	if not CAN.load() then return false, T.noApi end
	local name = info(i)
	if type(name) ~= "string" then return false, format(T.unknown, tostring(i)) end
	if not (IsLoD and IsLoD(i)) then return false, format(T.notLod, name) end
	local ok, reason = LoadAddOn(i)
	fire()
	if ok then return true, format(T.loaded, name) end
	reason = reason and (_G["ADDON_" .. tostring(reason)] or tostring(reason)) or "unknown"
	return false, format(T.loadFail, name, reason)
end

-- Pour Social Score's folders and the protected addons back on after a
-- Disable All
local function keepOn(c)
	for i = 1, count() do
		local name = info(i)
		if type(name) == "string" and M.PSS_AddonLocked(name) then EnableAddOn(i, c) end
	end
end

function M.PSS_AddonAll(on, who)
	M.PSS_AddonPrune()
	if not CAN.all() then return false, T.noApi end
	local c = charArg(who)
	if c == false then return false, T.noChar end
	if on then
		EnableAllAddOns(c)
	else
		DisableAllAddOns(c)
		if EnableAddOn then keepOn(c) end
	end
	forgetChoice(who == "all" and "all" or "me")
	save()
	fire()
	return true, format(on and T.allOn or T.allOff, whoText(who))
end

function M.PSS_AddonUndo()
	if not ResetAddOns then return false, T.noUndo end
	ResetAddOns()
	forgetChoice("me")
	forgetChoice("all")
	fire()
	return true, T.undone
end

-- a change waits for a reload: an addon that is loaded and turned off, or
-- turned on and not loaded (a load on demand addon loads when asked)
function M.PSS_AddonPending(who)
	local adds, offs = M.PSS_AddonChanges(who)
	return #adds > 0 or #offs > 0
end

-- what a reload will do: the names turned on and not loaded yet (a load on
-- demand addon loads when asked: not counted) and the names loaded and turned
-- off; the same rule as PSS_AddonPending. Returns two lists (added, turned off)
function M.PSS_AddonChanges(who)
	local adds, offs = {}, {}
	if not CAN.list() then return adds, offs end
	for i = 1, count() do
		local name, _, _, _, reason = info(i)
		if type(name) == "string" then
			local on = enableState(i, who) ~= NONE
			local loaded = IsLoaded and IsLoaded(i)
			if loaded and not on then
				offs[#offs + 1] = name
			elseif on and not loaded and not (IsLoD and IsLoD(i)) and (reason == nil or reason == "" or reason == "DISABLED") then
				adds[#adds + 1] = name
			end
		end
	end
	return adds, offs
end

function M.PSS_AddonReload()
	return M.PSS_ReloadPrompt()
end

-- how many of a group's addons are loaded, and how many it has
function M.PSS_AddonGroupLoaded(L, gi)
	local g = L.groups[gi]
	if not g then return 0, 0 end
	local loaded = 0
	for q = g.from, g.to do
		if IsLoaded and IsLoaded(L.idx[q]) then loaded = loaded + 1 end
	end
	return loaded, g.to - g.from + 1
end

------------------------------------------------------------------------
-- Presets: the enabled list saved under a number or your class, for this
-- character or all characters
------------------------------------------------------------------------
local function classToken()
	local f = _G.UnitClassBase
	local t = f and f("player")
	if t == nil then t = select(2, UnitClass("player")) end
	if type(t) ~= "string" or M.PSS_IsSecret(t) then return nil end
	return t:upper()
end

local function cleanName(s, noCap)
	s = type(s) == "string" and s or ""
	local out = {}
	for k = 1, #s do
		local b = byte(s, k)
		if b >= 32 and b <= 126 then out[#out + 1] = sub(s, k, k) end
	end
	s = concat(out):gsub("^%s+", ""):gsub("%s+$", "")
	if noCap then return s end
	return sub(s, 1, NAME_MAX)
end

-- a preset id: 1..25 or your class token; nil when it is neither
local function presetId(id)
	local n = tonumber(id)
	if n and n >= 1 and n <= PRESETS_MAX and n == floor(n) then return n end
	if type(id) == "string" then
		local t = classToken()
		local u = id:upper()
		if t and (u == t or u == "CLASS") then return t end
	end
end

-- where an id is kept: a number per scope, a class only account-wide
local function presetTable(id, scope, create)
	if type(id) == "string" or scope == "all" then
		local db = acct()
		if not db then return nil end
		if type(db.addonSets) ~= "table" and create then db.addonSets = {} end
		return type(db.addonSets) == "table" and db.addonSets or nil, "all"
	end
	local c = chr(create)
	if not c or viewOther.addonSets then return nil end	-- a newer version's shape is not replaced
	if type(c.addonSets) ~= "table" and create then c.addonSets = {} end
	return type(c.addonSets) == "table" and c.addonSets or nil, "char"
end

local function dropEmpty(scope)
	if scope == "all" then
		local db = acct()
		if db and type(db.addonSets) == "table" and next(db.addonSets) == nil then db.addonSets = nil end
	else
		local c = chr()
		if c and type(c.addonSets) == "table" and next(c.addonSets) == nil then c.addonSets = nil end
		tidyChar()
	end
end

-- a stored string: name, digit (account-wide), names start
local function parse(str, withDigit)
	if type(str) ~= "string" then return nil end
	local e = str:find(NL, 1, true)
	local head = e and sub(str, 1, e - 1) or str
	local pos = e and e + 1 or #str + 1
	if withDigit then
		local d = sub(head, 1, 1)
		if d ~= "1" and d ~= "2" then return nil end
		return sub(head, 2), pos, d
	end
	return head, pos
end

local function presetLabel(id, name)
	if name ~= "" then return name end
	if type(id) == "string" then return id:sub(1, 1) .. id:sub(2):lower() end
	return "Profile " .. id
end

-- the name in a line of text: the name, else the number or the class
local function msgLabel(id, name)
	if name ~= "" then return name end
	if type(id) == "string" then return id:sub(1, 1) .. id:sub(2):lower() end
	return tostring(id)
end

-- every preset that can be used here: { id, name, scope, n, class, label }
-- (a class set only for your own class; one a newer version wrote is left out)
function M.PSS_AddonPresets()
	M.PSS_AddonPrune()
	local list = {}
	local t = chr()
	local own = classToken()
	local function add(tbl, scope, withDigit)
		if type(tbl) ~= "table" then return end
		for id, str in pairs(tbl) do
			local name, pos = parse(str, withDigit)
			if name and (type(id) == "number" or id == own) then
				local n = 0
				eachName(str, pos, function() n = n + 1 end)
				list[#list + 1] = { id = id, name = name, scope = scope, n = n, class = type(id) == "string",
					label = presetLabel(id, name) }
			end
		end
	end
	add(t and t.addonSets, "char", false)
	local db = acct()
	add(db and db.addonSets, "all", true)
	sort(list, function(a, b)
		if a.class ~= b.class then return b.class end
		if a.scope ~= b.scope then return a.scope == "char" end
		return a.id < b.id
	end)
	return list
end

-- the slots of the Sets menu for who ("me" or "all"): the 25 numbers of that
-- scope, then your class's (always account-wide), each { id, name, scope, n,
-- class, label, empty, elsewhere, hidden }; an empty one is a free place to
-- save into (elsewhere: the other scope holds a profile with this id; hidden:
-- a saved string this version cannot read, left alone)
function M.PSS_AddonSlots(who)
	local scope = who == "all" and "all" or "char"
	local have, other = {}, {}
	for _, p in ipairs(M.PSS_AddonPresets()) do
		if p.class or p.scope == scope then have[p.id] = p else other[p.id] = p.scope end
	end
	local out = {}
	local function slot(id)
		local p = have[id]
		if not p then
			local class = type(id) == "string"
			p = { id = id, name = "", scope = class and "all" or scope, n = 0, class = class,
				label = presetLabel(id, ""), empty = true, elsewhere = other[id] }
			-- a string the list left out (a newer version's): not a free place
			local tbl = presetTable(id, p.scope)
			p.hidden = tbl ~= nil and tbl[id] ~= nil
		end
		out[#out + 1] = p
	end
	for id = 1, PRESETS_MAX do slot(id) end
	local own = classToken()
	if own then slot(own) end
	for _, p in ipairs(out) do
		p.layer = (type(p.id) == "number" and p.id <= CORE_MAX) and "core" or "layered"
	end
	return out
end

-- the enabled addons for who, not Pour Social Score, not protected
local function enabledNames(who)
	local list = {}
	for i = 1, count() do
		local name = info(i)
		if type(name) == "string" and not hidden(name) and not M.PSS_AddonLocked(name)
			and enableState(i, who) ~= NONE then
			list[#list + 1] = name
		end
	end
	return list
end

-- save the addons now on for who under id: this character's list when who
-- is "me", the account-wide one for "all" (a class preset is always account-wide)
function M.PSS_AddonPresetSave(id, name, who)
	M.PSS_AddonPrune()
	if not CAN.list() then return false, T.noApi end
	local pid = presetId(id)
	if not pid then return false, format(T.presetBadId, tostring(id), PRESETS_MAX) end
	local tbl, scope = presetTable(pid, who == "all" and "all" or "char", true)
	if not tbl then return false, T.noApi end
	if tbl[pid] ~= nil and not parse(tbl[pid], scope == "all") then
		dropEmpty(scope)
		return false, format(T.presetOther, msgLabel(pid, ""))
	end
	local list = enabledNames(who)
	local head = (scope == "all" and DIGIT or "") .. cleanName(name)
	tbl[pid] = #list > 0 and (head .. NL .. packNames(list)) or head
	dropEmpty(scope)
	return true, format(T.presetSaved, msgLabel(pid, cleanName(name)), #list)
end

local function presetOf(id, scope)
	local pid = presetId(id)
	if not pid then return nil, format(T.presetBadId, tostring(id), PRESETS_MAX) end
	local tbl, sc = presetTable(pid, scope == "all" and "all" or "char")
	local str = tbl and tbl[pid]
	local name, pos = parse(str, sc == "all")
	if not name then
		if str ~= nil then return nil, format(T.presetOther, msgLabel(pid, "")) end
		return nil, format(T.presetNo, msgLabel(pid, ""))
	end
	return pid, str, name, pos, sc
end

-- walk a preset's names that are installed: fn(i, name); returns the number
-- turned and the number not installed
local function eachInstalled(str, pos, fn)
	local map = nameMap()
	local done, missing = 0, 0
	eachName(str, pos, function(n)
		local i = map[n]
		if i then
			fn(i, n)
			done = done + 1
		else
			missing = missing + 1
		end
	end)
	return done, missing
end

-- scope: where the preset is kept; who: whose enable states it writes
-- (a character preset always writes this character's)
function M.PSS_AddonPresetLoad(id, scope, who)
	M.PSS_AddonPrune()
	local pid, str, name, pos = presetOf(id, scope)
	if not pid then return false, str end
	if not CAN.all() or not CAN.tick() then return false, T.noApi end
	who = scope == "all" and who == "all" and "all" or "me"
	local c = charArg(who)
	if c == false then return false, T.noChar end
	DisableAllAddOns(c)
	keepOn(c)
	local done, missing = eachInstalled(str, pos, function(i) EnableAddOn(i, c) end)
	-- the profile stays selected when it belongs to the scope shown
	forgetChoice(who, (type(pid) == "string" or (scope == "all") == (who == "all")) and pid or nil)
	save()
	fire()
	return true, format(T.presetLoaded, msgLabel(pid, name), done, missing)
end

-- Enable all / Disable all on one profile, as a manual group tick: its
-- installed addons only (protected ones and Pour Social Score stay on when
-- turning off), dependencies when deps, hand picks noted; the profile, the
-- selection and the saved profiles are not changed
function M.PSS_AddonPresetTick(id, scope, on, who, deps)
	M.PSS_AddonPrune()
	local pid, str, name, pos = presetOf(id, scope)
	if not pid then return false, str end
	if not CAN.tick() then return false, T.noApi end
	who = scope == "all" and who == "all" and "all" or "me"
	local c = charArg(who)
	if c == false then return false, T.noChar end
	local turned, missing, picked = {}, {}, {}
	local done, absent = eachInstalled(str, pos, function(i, n)
		if on or not M.PSS_AddonLocked(n) then
			applyOne(i, n, on, c, deps, turned, missing)
			picked[#picked + 1] = n
		end
	end)
	if done == 0 then return false, format(T.presetEmpty, msgLabel(pid, name)) end
	notePicks(picked, on, who)
	save()
	fire()
	return true, format(on and T.presetEnabled or T.presetDisabled, msgLabel(pid, name), #picked, absent)
end

-- how many of a profile's addons are installed (the menu greys Enable all
-- and Disable all at 0)
function M.PSS_AddonPresetInstalled(id, scope)
	local pid, str, _, pos = presetOf(id, scope)
	if not pid then return 0 end
	return (eachInstalled(str, pos, function() end))
end

-- the tick next to a profile in the Profiles menu: true when it has an
-- installed addon and every installed addon of it is on (Enable all / Disable
-- all are what ticking and unticking do)
function M.PSS_AddonPresetOn(id, scope, who)
	local pid, str, _, pos = presetOf(id, scope)
	if not pid then return false end
	who = scope == "all" and who == "all" and "all" or "me"
	local n, off = 0, 0
	eachInstalled(str, pos, function(i)
		n = n + 1
		if enableState(i, who) == NONE then off = off + 1 end
	end)
	return n > 0 and off == 0
end

-- one addon (by folder name) into a preset
function M.PSS_AddonPresetInclude(id, scope, name)
	M.PSS_AddonPrune()
	local pid, str, label, pos, sc = presetOf(id, scope)
	if not pid then return false, str end
	if type(name) ~= "string" or find(name, NL, 1, true) or isPSS(name) or hidden(name) then return false end
	local list, have = {}, false
	eachName(str, pos, function(n)
		list[#list + 1] = n
		if n == name then have = true end
	end)
	if not have then list[#list + 1] = name end
	local tbl = presetTable(pid, scope)
	tbl[pid] = (sc == "all" and DIGIT or "") .. label .. NL .. packNames(list)
	dropEmpty(sc)
	return true, format(T.presetAdded2, msgLabel(pid, label), name)
end

-- a name for a profile: ASCII, not empty, at most NAME_MAX, and not another
-- profile's in the same store; returns the clean name or nil and the reason
local function checkName(tbl, pid, raw, withDigit)
	local name = cleanName(raw, true)
	if name == "" then return nil, T.nameEmpty end
	if #name > NAME_MAX then return nil, format(T.nameLong, NAME_MAX) end
	local want = lower(name)
	for id, str in pairs(tbl) do
		if id ~= pid then
			local other = parse(str, withDigit)
			if other and lower(other) == want then return nil, format(T.nameDup, name) end
		end
	end
	return name
end

-- name any place, a free one too (it is then kept, empty, under its name)
function M.PSS_AddonPresetRename(id, name, scope)
	M.PSS_AddonPrune()
	local pid = presetId(id)
	if not pid then return false, format(T.presetBadId, tostring(id), PRESETS_MAX) end
	local tbl, sc = presetTable(pid, scope == "all" and "all" or "char", true)
	if not tbl then return false, T.noApi end
	local withDigit = sc == "all"
	local str = tbl[pid]
	local pos
	if str ~= nil then
		local old
		old, pos = parse(str, withDigit)
		if not old then
			dropEmpty(sc)
			return false, format(T.presetOther, msgLabel(pid, ""))
		end
	end
	local clean, why = checkName(tbl, pid, name, withDigit)
	if not clean then
		dropEmpty(sc)
		return false, why
	end
	local rest = (str and pos <= #str) and sub(str, pos - 1) or ""
	tbl[pid] = (withDigit and DIGIT or "") .. clean .. rest
	dropEmpty(sc)
	return true, format(T.presetRenamed, msgLabel(pid, clean))
end

------------------------------------------------------------------------
-- Selected addon profiles: any of the Core (1 to 5) and Layered (6 to 25
-- and your class) profiles at once. What is wanted on is the union of the
-- selected profiles' addons and the hand picks; deselecting turns off only
-- what nothing else still wants (protected addons stay on).
------------------------------------------------------------------------
local function profileScope(id, who)
	return (type(id) == "string" or who == "all") and "all" or "char"
end

local function selIndex(ids, id)
	for k, v in ipairs(ids) do
		if v == id then return k end
	end
end

-- a profile was deleted: it is no longer selected
local function dropSel(pid, sc)
	for _, who in ipairs(type(pid) == "string" and { "me", "all" } or { sc == "all" and "all" or "me" }) do
		local ids = selIds(who)
		local k = selIndex(ids, pid)
		if k then
			tremove(ids, k)
			setSelIds(who, ids)
		end
	end
end

function M.PSS_AddonPresetDelete(id, scope)
	M.PSS_AddonPrune()
	local pid, str, name, _, sc = presetOf(id, scope)
	if not pid then return false, str end
	local tbl = presetTable(pid, scope)
	tbl[pid] = nil
	dropEmpty(sc)
	dropSel(pid, sc)
	return true, format(T.presetDeleted, msgLabel(pid, name))
end

function M.PSS_AddonProfileSelected(id, who)
	local pid = presetId(id)
	if not pid then return false end
	who = who == "all" and "all" or "me"
	return selIndex(selIds(who), pid) ~= nil and presetOf(pid, profileScope(pid, who)) ~= nil
end

-- the names the selected profiles and the hand picks want on, for who
local function wantedBy(who)
	local want = {}
	for _, id in ipairs(selIds(who)) do
		local pid, str, _, pos = presetOf(id, profileScope(id, who))
		if pid then eachName(str, pos, function(n) want[n] = true end) end
	end
	for _, n in ipairs(pickNames(who)) do want[n] = true end
	return want
end
M.PSS_AddonProfileUnion = wantedBy

function M.PSS_AddonProfileSelect(id, on, who)
	M.PSS_AddonPrune()
	local pid0 = presetId(id)
	if not pid0 then return false, format(T.presetBadId, tostring(id), PRESETS_MAX) end
	who = who == "all" and "all" or "me"
	local pid, str, name, pos = presetOf(pid0, profileScope(pid0, who))
	if not pid then return false, str end
	if not CAN.tick() then return false, T.noApi end
	local c = charArg(who)
	if c == false then return false, T.noChar end
	local ids = selIds(who)
	local k = selIndex(ids, pid)
	if on then
		if not k then
			-- what is already on and nothing wants is the player's own
			local want, mine = wantedBy(who), {}
			eachInstalled(str, pos, function(i, n)
				if enableState(i, who) ~= NONE and not want[n] and not M.PSS_AddonLocked(n) then mine[#mine + 1] = n end
			end)
			notePicks(mine, true, who, true)
			ids[#ids + 1] = pid
			setSelIds(who, ids)
		end
		local done, missing = eachInstalled(str, pos, function(i) EnableAddOn(i, c) end)
		save()
		fire()
		return true, format(T.presetSelected, msgLabel(pid, name), done, missing)
	end
	if k then
		tremove(ids, k)
		setSelIds(who, ids)
	end
	local want = wantedBy(who)
	local off, kept = 0, 0
	eachInstalled(str, pos, function(i, n)
		if want[n] or M.PSS_AddonLocked(n) then
			kept = kept + 1
		else
			DisableAddOn(i, c)
			off = off + 1
		end
	end)
	save()
	fire()
	return true, format(T.presetDeselected, msgLabel(pid, name), off, kept)
end

------------------------------------------------------------------------
-- Prune: once per load of this file, on the first call into it. A name
-- that is not installed goes from a protected list or a preset that this
-- client saved; the other client's names are kept.
------------------------------------------------------------------------
local pruned

local function keep(map, str, pos)
	local out, changed = {}, false
	eachName(str, pos, function(n)
		if map[n] then out[#out + 1] = n else changed = true end
	end)
	return out, changed
end

function M.PSS_AddonPrune()
	if pruned then return end
	pruned = true
	if not CAN.list() or count() == 0 then return end
	local map = nameMap()
	local db = acct()
	-- protected lists (this client's)
	local a, c = lockStrings()
	if a then
		local out, changed = keep(map, a, 1)
		if changed then setLockList("all", out) end
	end
	if c then
		local out, changed = keep(map, c, 1)
		if changed then setLockList("me", out) end
	end
	for _, who in ipairs({ "me", "all" }) do
		local str = getPacked("addonPick", who)
		if str then
			local out, changed = keep(map, str, 1)
			if changed then setPacked("addonPick", who, #out > 0 and packNames(out) or nil) end
		end
	end
	-- presets: this character's, then the account's saved on this client
	local function sets(tbl, withDigit, scope)
		if type(tbl) ~= "table" then return end
		local ids = {}
		for id in pairs(tbl) do ids[#ids + 1] = id end
		for _, id in ipairs(ids) do
			local str = tbl[id]
			local name, pos, d = parse(str, withDigit)
			if name and (not withDigit or d == DIGIT) then
				local out, changed = keep(map, str, pos)
				if changed then
					local head = (withDigit and DIGIT or "") .. name
					tbl[id] = #out > 0 and (head .. NL .. packNames(out)) or head
				end
			end
		end
		dropEmpty(scope)
	end
	local ch = chr()
	sets(ch and ch.addonSets, false, "char")
	sets(db and db.addonSets, true, "all")
	lockCache = nil
end

-- the window closed: drop what was kept for the tab
function M.PSS_AddonRelease()
	lockCache = nil
	X1, X2, X3, GD, GK, GL, GC = {}, {}, {}, {}, {}, {}, {}
end

------------------------------------------------------------------------
-- /pss acp (args are the lower-cased words, raw the words as typed)
------------------------------------------------------------------------
local function say(text)
	M.ShowMsg(text)
end

-- the pending-reload note on a changed line
local function report(ok, text)
	if text then
		say(ok and (text .. (M.PSS_AddonPending("me") and T.reload or "")) or ("|cffff5555" .. text .. "|r"))
	end
end

-- an addon by name: the exact folder name (any case), else the one folder
-- whose name starts with the text
local function find1(text)
	if not text then return nil end
	local want = lower(text)
	local hit, n = nil, 0
	for i = 1, count() do
		local name = info(i)
		if type(name) == "string" then
			local l = lower(name)
			if l == want then return i, name end
			if sub(l, 1, #want) == want then hit, n = i, n + 1 end
		end
	end
	if n == 1 then return hit, (info(hit)) end
end

local function listCommand(filter)
	local L = M.PSS_AddonList("me", "az", filter)
	local o, on = {}, 0
	for p = 1, L.n do
		if M.PSS_AddonRow(L.idx[p], "me", o).enabled then on = on + 1 end
	end
	say(format(T.listHead, L.n, on, T.me))
	for p = 1, L.n do
		local r = M.PSS_AddonRow(L.idx[p], "me", o)
		say(format(T.listRow, r.name, r.text .. (r.locked and " (protected)" or "")))
	end
end

local function apiCommand()
	local have, lack = {}, {}
	local function note(present, n)
		local into = present and have or lack
		into[#into + 1] = n
	end
	for _, n in ipairs(API_NAMES) do note(api(n) ~= nil, n) end
	note((stateNew or stateOld) ~= nil, "GetAddOnEnableState")
	say(format(T.apiHave, #have > 0 and concat(have, ", ") or T.apiNone))
	say(format(T.apiLack, #lack > 0 and concat(lack, ", ") or T.apiNone))
end

local function presetCommand(args, raw)
	local id = args[3]
	if not id then
		say(T.presetUsage)
		return
	end
	local k = 4
	local scope = "char"
	if args[k] == "char" or args[k] == "all" then
		scope = args[k]
		k = k + 1
	end
	local act = args[k]
	if act == "save" then
		local name = #raw >= k + 1 and concat(raw, " ", k + 1) or ""
		report(M.PSS_AddonPresetSave(id, name, scope == "all" and "all" or "me"))
	elseif act == "load" then
		report(M.PSS_AddonPresetLoad(id, scope, "me"))
	elseif act == "enable" or act == "add" then
		report(M.PSS_AddonPresetTick(id, scope, true, "me", true))
	elseif act == "disable" or act == "remove" then
		report(M.PSS_AddonPresetTick(id, scope, false, "me", true))
	elseif act == "delete" then
		report(M.PSS_AddonPresetDelete(id, scope))
	elseif act == "rename" then
		report(M.PSS_AddonPresetRename(id, #raw >= k + 1 and concat(raw, " ", k + 1) or "", scope))
	elseif act == "select" or act == "deselect" then
		report(M.PSS_AddonProfileSelect(id, act == "select", scope == "all" and "all" or "me"))
	else
		say(T.presetUsage)
	end
end

function M.PSS_AddonCommand(args, raw)
	M.PSS_AddonPrune()
	local word = args[2]
	if word == "api" then
		apiCommand()
	elseif not CAN.list() then
		say(T.noApi)
	elseif word == "list" then
		listCommand(raw[3])
	elseif word == "on" or word == "off" then
		local i, name = find1(raw[3])
		if not i then say(format(T.unknown, raw[3] or "")) return end
		report(M.PSS_AddonTick(i, word == "on", "me", true))
	elseif word == "load" then
		local i, name = find1(raw[3])
		if not i then say(format(T.unknown, raw[3] or "")) return end
		report(M.PSS_AddonLoad(i))
	elseif word == "all" and (args[3] == "on" or args[3] == "off") then
		report(M.PSS_AddonAll(args[3] == "on", "me"))
	elseif word == "undo" then
		report(M.PSS_AddonUndo())
	elseif word == "sets" or word == "profiles" then
		local l = M.PSS_AddonPresets()
		if #l == 0 then
			say(T.presetNone)
		else
			say(T.presetHead)
			for _, p in ipairs(l) do
				local on = M.PSS_AddonProfileSelected(p.id, p.scope == "all" and "all" or "me")
				say(format(T.presetRow, on and "*" or " ", tostring(p.id), p.name ~= "" and p.name or "", p.scope == "all" and T.everyone or T.me, p.n))
			end
		end
	elseif word == "set" or word == "profile" then
		presetCommand(args, raw)
	elseif word == "lock" or word == "unlock" then
		local i, name = find1(raw[3])
		if not i then say(format(T.unknown, raw[3] or "")) return end
		if isPSS(name) then say(T.lockPss) return end
		local ok, text = M.PSS_AddonLock(name, word == "lock", "me")
		say(text or format(word == "lock" and T.lockOn or T.lockOff, name))
	else
		say(T.help)
	end
end
