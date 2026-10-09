------------------------------------------------------------------------
-- POUR SOCIAL SCORE - GRAPHICS SETTINGS (/pss gfx, 3.5.0, Camelot only)
--
-- Export, import and keep the last 5 sets of the client's graphics
-- settings (CVars in the console's Graphics category). All the logic;
-- the popups are drawn by PourSocialScore_GUI (PSS_Popups.lua). Nothing
-- is defined on other clients.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local iface = select(4, GetBuildInfo())
if type(iface) ~= "number" or iface >= 20000 then return end

local C_CVar, ReloadUI, InCombatLockdown = C_CVar, ReloadUI, InCombatLockdown
local GetBuildInfo, time, date = GetBuildInfo, time, date
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local sort, concat, tinsert = table.sort, table.concat, table.insert
local format, find, sub, gmatch, gsub = string.format, string.find, string.sub, string.gmatch, string.gsub

local TAG = "PSSGFX1 Camelot"
local KEEP = 5			-- sets kept in gfxSets
local KEEP_SECONDS = 15		-- the keep prompt's countdown
local VALUE_MAX = 255
local SHOW_MAX = 20		-- change lines shown in a preview, then "+N more"
local NAMES_MAX = 8		-- names in the line Revert prints
local GRAPHICS = Enum and Enum.ConsoleCategory and Enum.ConsoleCategory.Graphics or 1
local CVAR = Enum and Enum.ConsoleCommandType and Enum.ConsoleCommandType.Cvar or 0

-- the popup and chat texts (English, inline as the other Libraries files)
local T = {
	noApi = "Graphics settings are not available: this client has no console command list.",
	combat = "Graphics settings cannot be changed in combat.",
	noHeader = "That is not a graphics export: the first line must start with " .. TAG .. ".",
	badText = "Paste a graphics export first.",
	nothing = "No settings differ from now.",
	refused = "The client refused every change.",
	noSet = "That set is not saved.",
	kept = "Graphics settings kept.",
	reverted = "Graphics settings put back (%s). Display settings need /reload or a game restart to finish.",
	revertedNone = "Graphics settings put back. Display settings need /reload or a game restart to finish.",
	count = "%d graphics settings: %s",
	willChange1 = "1 setting will change:",
	willChange = "%d settings will change:",
	more = "+%d more",
	skipped = "%d skipped (not graphics settings on this client)",
	close = "Close Blizzard's settings first. The game reloads; you then have %d s to keep them.",
	saved = "Saved %s",
	same = "No differences from now.",
	keepText = "Keep these graphics settings? With no answer in %d s the old ones are put back.",
	restart = "Display settings (gx...) may need a game restart to take effect.",
	keepTitle = "Keep Graphics Settings?",
	keep = "Keep",
	revert = "Revert",
}

------------------------------------------------------------------------
-- LOCAL HELPERS
------------------------------------------------------------------------
local function allCommands()
	if ConsoleGetAllCommands then return ConsoleGetAllCommands() end
	if C_Console and C_Console.GetAllCommands then return C_Console.GetAllCommands() end
end

-- value, default, ..., locked, secure, readOnly
local function info(name)
	return C_CVar.GetCVarInfo(name)
end

-- the value reads back as written (a client that clamps or ignores it fails)
local function setValue(name, value)
	C_CVar.SetCVar(name, value)
	return (info(name)) == value
end

local function trim(s)
	return (gsub(gsub(s, "^%s+", ""), "%s+$", ""))
end

-- name -> current value for every listed name
local function currentMap(list)
	local out = {}
	for _, name in ipairs(list) do
		local v = info(name)
		if v ~= nil then out[name] = tostring(v) end
	end
	return out
end

-- the history string: the time, then sorted name=value for the values that
-- differ from the client's default
local function packSet(t, set, list)
	local out = { tostring(t) }
	for _, name in ipairs(list) do
		local v = set[name]
		if v ~= nil then
			local _, d = info(name)
			if d == nil or tostring(d) ~= v then out[#out + 1] = name .. "=" .. v end
		end
	end
	return concat(out, "\n")
end

-- time, stored non-defaults (names this client does not know included)
local function readSet(str)
	local t, set = nil, {}
	for l in gmatch(str .. "\n", "([^\n]*)\n") do
		if t == nil then
			t = tonumber(l) or 0
		else
			local name, v = l:match("^([^=]+)=(.*)$")
			if name then set[name] = v end
		end
	end
	return t or 0, set
end

-- every allowed name: the stored value, or the client default
local function expand(set, list)
	local out = {}
	for _, name in ipairs(list) do
		local v = set[name]
		if v == nil then
			local _, d = info(name)
			if d ~= nil then v = tostring(d) end
		end
		if v ~= nil then out[name] = v end
	end
	return out
end

-- {name, old, new} where the two maps differ, in list order
local function diff(from, to, list)
	local out = {}
	for _, name in ipairs(list) do
		local a, b = from[name], to[name]
		if a ~= nil and b ~= nil and a ~= b then out[#out + 1] = { name, a, b } end
	end
	return out
end

local function body(str)
	return str:match("\n(.*)$") or ""
end

-- the newest set; a copy of it (same values, any time) is not saved again
local function saveSet(str)
	local sets = PourSocialScoreDB.gfxSets
	if type(sets) ~= "table" then
		sets = {}
		PourSocialScoreDB.gfxSets = sets
	end
	if sets[1] and body(sets[1]) == body(str) then return end
	tinsert(sets, 1, str)
	for i = #sets, KEEP + 1, -1 do sets[i] = nil end
end

local function cleanLine(name, value, allowed)
	return allowed[name] == true and #value <= VALUE_MAX and not find(value, "[^\32-\126]")
end

local function changeLines(changes)
	local out = {}
	for i = 1, #changes do
		if i > SHOW_MAX then
			out[#out + 1] = format(T.more, #changes - SHOW_MAX)
			break
		end
		local c = changes[i]
		out[#out + 1] = c[1] .. ": " .. c[2] .. " -> " .. c[3]
	end
	return out
end

local function setOf(list)
	local out = {}
	for _, name in ipairs(list) do out[name] = true end
	return out
end

local function isDisplay(name)
	return sub(name, 1, 2) == "gx"
end

------------------------------------------------------------------------
-- LIST AND EXPORT
------------------------------------------------------------------------
-- the allowed names, sorted: the console's Graphics category CVars that
-- are not secure, read-only, locked or an addon restriction CVar (J9).
-- Built per call, never kept. nil, reason without the console API.
function M.PSS_GfxList()
	local cmds = allCommands()
	if type(cmds) ~= "table" or not (C_CVar and C_CVar.GetCVarInfo and C_CVar.SetCVar) then return nil, T.noApi end
	local out, seen = {}, {}
	for _, c in ipairs(cmds) do
		local name = c.command
		if c.category == GRAPHICS and c.commandType == CVAR and type(name) == "string" and not seen[name]
				and find(name, "^[%w_]+$") and not find(name:lower(), "^addon") then
			local v, _, _, _, locked, secure, readOnly = info(name)
			if v ~= nil and not locked and not secure and not readOnly then
				seen[name] = true
				out[#out + 1] = name
			end
		end
	end
	sort(out)
	return out
end

-- the export string now (i nil) or of history set i, with the number of settings
function M.PSS_GfxExportText(i)
	local list, why = M.PSS_GfxList()
	if not list then return nil, why end
	local values
	if i then
		local s = type(PourSocialScoreDB.gfxSets) == "table" and PourSocialScoreDB.gfxSets[i]
		if not s then return nil, T.noSet end
		local _, set = readSet(s)
		values = expand(set, list)
	else
		values = currentMap(list)
	end
	local out = { TAG .. " " .. tostring((GetBuildInfo())) }
	local n = 0
	for _, name in ipairs(list) do
		if values[name] ~= nil then
			out[#out + 1] = name .. "=" .. values[name]
			n = n + 1
		end
	end
	return concat(out, "\n"), n
end

------------------------------------------------------------------------
-- IMPORT: PARSE, PREVIEW, APPLY
------------------------------------------------------------------------
-- plan = { set, changes = { {name, old, new} }, same, skipped }; never writes
function M.PSS_GfxParse(text)
	local list, why = M.PSS_GfxList()
	if not list then return nil, why end
	if type(text) ~= "string" then return nil, T.badText end
	local allowed = setOf(list)
	local set, skipped, header = {}, 0, false
	for l in gmatch(text .. "\n", "([^\n]*)\n") do
		l = trim(l)
		if l ~= "" then
			if not header then
				if sub(l, 1, #TAG) ~= TAG or (#l > #TAG and sub(l, #TAG + 1, #TAG + 1) ~= " ") then return nil, T.noHeader end
				header = true
			else
				local eq = find(l, "=", 1, true)
				local name, v
				if eq then name, v = trim(sub(l, 1, eq - 1)), trim(sub(l, eq + 1)) end
				if name and cleanLine(name, v, allowed) then set[name] = v else skipped = skipped + 1 end
			end
		end
	end
	if not header then return nil, T.noHeader end
	local now = currentMap(list)
	local changes, same = diff(now, set, list), 0
	for name, v in pairs(set) do
		if now[name] == v then same = same + 1 end
	end
	return { set = set, changes = changes, same = same, skipped = skipped }
end

-- the preview text
function M.PSS_GfxSummary(plan)
	local out = {}
	local n = #plan.changes
	if n == 0 then
		out[1] = T.nothing
	else
		out[1] = n == 1 and T.willChange1 or format(T.willChange, n)
		for _, l in ipairs(changeLines(plan.changes)) do out[#out + 1] = l end
	end
	if plan.skipped and plan.skipped > 0 then out[#out + 1] = format(T.skipped, plan.skipped) end
	if n > 0 then
		out[#out + 1] = ""
		out[#out + 1] = format(T.close, KEEP_SECONDS)
	end
	return concat(out, "\n")
end

-- true, applied, refused (saves the set in use, flags the change, reloads);
-- false, reason[, refused] when nothing was applied
function M.PSS_GfxApply(plan)
	if InCombatLockdown() then return false, T.combat end
	if type(plan) ~= "table" or type(plan.changes) ~= "table" or #plan.changes == 0 then return false, T.nothing end
	local list = M.PSS_GfxList()
	if not list then return false, T.noApi end
	local allowed = setOf(list)
	local before = packSet(time(), currentMap(list), list)
	local applied, refused = 0, 0
	for _, c in ipairs(plan.changes) do
		if allowed[c[1]] and setValue(c[1], c[3]) then applied = applied + 1 else refused = refused + 1 end
	end
	if applied == 0 then return false, T.refused, refused end
	saveSet(before)
	PourSocialScoreDB.gfxPending = true
	ReloadUI()
	return true, applied, refused
end

------------------------------------------------------------------------
-- HISTORY
------------------------------------------------------------------------
-- rows { i, when, whenText, changed }: the settings that differ from now
function M.PSS_GfxHistory()
	local out = {}
	local sets = PourSocialScoreDB.gfxSets
	local list = M.PSS_GfxList()
	if type(sets) ~= "table" or not list then return out end
	local now = currentMap(list)
	for i, s in ipairs(sets) do
		local t, set = readSet(s)
		out[#out + 1] = { i = i, when = t, whenText = date("%Y-%m-%d %H:%M", t), changed = #diff(expand(set, list), now, list) }
	end
	return out
end

-- "Saved <time>", then every name: then -> now
function M.PSS_GfxSetDiff(i)
	local list, why = M.PSS_GfxList()
	if not list then return nil, why end
	local s = type(PourSocialScoreDB.gfxSets) == "table" and PourSocialScoreDB.gfxSets[i]
	if not s then return nil, T.noSet end
	local t, set = readSet(s)
	local out = { format(T.saved, date("%Y-%m-%d %H:%M", t)) }
	local changes = diff(expand(set, list), currentMap(list), list)
	if #changes == 0 then
		out[#out + 1] = T.same
	else
		for _, c in ipairs(changes) do out[#out + 1] = c[1] .. ": " .. c[2] .. " -> " .. c[3] end
	end
	return concat(out, "\n")
end

-- the same plan shape as M.PSS_GfxParse, from history set i; names this
-- client no longer knows are skipped (and stay in the saved string)
function M.PSS_GfxRestorePlan(i)
	local list, why = M.PSS_GfxList()
	if not list then return nil, why end
	local s = type(PourSocialScoreDB.gfxSets) == "table" and PourSocialScoreDB.gfxSets[i]
	if not s then return nil, T.noSet end
	local _, set = readSet(s)
	local allowed, skipped = setOf(list), 0
	for name in pairs(set) do
		if not allowed[name] then skipped = skipped + 1 end
	end
	local want = expand(set, list)
	local changes = diff(currentMap(list), want, list)
	return { set = want, changes = changes, same = #list - #changes, skipped = skipped }
end

------------------------------------------------------------------------
-- KEEP OR REVERT (after the reload)
------------------------------------------------------------------------
function M.PSS_GfxKeep()
	if PourSocialScoreDB.gfxPending then M.ShowMsg(T.kept) end
	PourSocialScoreDB.gfxPending = nil
end

-- puts set 1 back (no new history entry); never refused, also in combat
function M.PSS_GfxRevert()
	if not PourSocialScoreDB.gfxPending then return end
	PourSocialScoreDB.gfxPending = nil
	local list = M.PSS_GfxList()
	local s = type(PourSocialScoreDB.gfxSets) == "table" and PourSocialScoreDB.gfxSets[1]
	if not list or not s then return end
	local _, set = readSet(s)
	local names = {}
	for _, c in ipairs(diff(currentMap(list), expand(set, list), list)) do
		if setValue(c[1], c[3]) then names[#names + 1] = c[1] end
	end
	if #names == 0 then
		M.ShowMsg(T.revertedNone)
		return
	end
	local shown = {}
	for i = 1, #names do
		if i > NAMES_MAX then shown[#shown + 1] = format(T.more, #names - NAMES_MAX) break end
		shown[#shown + 1] = names[i]
	end
	M.ShowMsg(format(T.reverted, concat(shown, ", ")))
end

-- the keep prompt for the window's ns.Confirm
function M.PSS_GfxKeepSpec()
	local out = { format(T.keepText, KEEP_SECONDS) }
	local list = M.PSS_GfxList()
	local s = type(PourSocialScoreDB.gfxSets) == "table" and PourSocialScoreDB.gfxSets[1]
	if list and s then
		local _, set = readSet(s)
		local changes = diff(expand(set, list), currentMap(list), list)
		local display = false
		for _, c in ipairs(changes) do
			if isDisplay(c[1]) then display = true end
		end
		for _, l in ipairs(changeLines(changes)) do out[#out + 1] = l end
		if display then out[#out + 1] = T.restart end
	end
	return { title = T.keepTitle, text = concat(out, "\n"), accept = T.keep, cancel = T.revert, timeout = KEEP_SECONDS,
		onAccept = M.PSS_GfxKeep, onCancel = M.PSS_GfxRevert, onTimeout = M.PSS_GfxRevert }
end

function M.PSS_GfxReload()
	ReloadUI()
end

------------------------------------------------------------------------
-- THE COMMAND'S ENTRY
------------------------------------------------------------------------
-- /pss gfx: the popup (PourSocialScore_GUI); without it, the count
function M.PSS_GfxOpen()
	local list, why = M.PSS_GfxList()
	if not list then M.ShowMsg(why) return end
	if M.PSS_Need("GUI") and M.PSS_GfxBox then M.PSS_GfxBox() return end
	local first = {}
	for i = 1, 5 do first[i] = list[i] end
	M.ShowMsg(format(T.count, #list, concat(first, ", ")))
end

-- after a reload with a change waiting: ask whether to keep it. Core's
-- ApplicationStartup calls this once this addon has finished loading (the
-- window's folder needs this one, so it cannot be loaded from inside this file)
function M.PSS_GfxAsk()
	if PourSocialScoreDB.gfxPending and M.PSS_Need("GUI") and M.PSS_GfxKeepPrompt then
		M.PSS_GfxKeepPrompt()
	end
end
