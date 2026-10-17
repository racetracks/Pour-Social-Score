------------------------------------------------------------------------
-- POUR SOCIAL SCORE - OPTIONS AND IMPORT/EXPORT VIEW (for PourSocialScore_GUI)
--
-- What the window's Options and Import/Export tabs show and do, worked out
-- here so the tabs only draw. Options come from M.PSS_OPTIONS (the one
-- definitions table every window renders from) and are written only through
-- M.PSS_SetOpt; Import/Export goes through PSS_ImportExport.lua.
--   M.PSS_OptLabel(o), M.PSS_OptTip(o), M.PSS_OptChoiceText(o, v)
--   M.PSS_OptGroups()                  { { title, items = { { o, find } } } }
--                                      by section, inline numbers left out
--   M.PSS_OptMatches(group, item, q)   the search keeps it
--   M.PSS_OptNumberText(o), M.PSS_OptSetNumber(o, text)    false: not a number
--   M.PSS_OptFieldOn(o), M.PSS_OptFieldText(o)
--   M.PSS_OptSetFieldOn(o, on, typed)  a tick box with its number (the scan
--                                      level cap); false: refused (said why)
--   M.PSS_OptSetField(o, text)         false: refused
--   M.PSS_IO, M.PSS_IO_PARTS, M.PSS_IO_MODES   what to include, the mode
--   M.PSS_IOSet(key, on), M.PSS_IOSetMode(key) set them
--   M.PSS_IOPartOff(key)               a part that cannot be ticked now
--   M.PSS_IOOn(key), M.PSS_IOMode()    a tick, the mode
--   M.PSS_ExportText()                 the export string, and the box's subtitle
--   M.PSS_ImportStart(str)             error text, or nil, the confirm's text
--                                      (mode replace, else nil) and apply()
--   M.PSS_ImportCheck(str), M.PSS_ImportReplaceText(data), M.PSS_ImportApply(data)
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local ipairs, tonumber, tostring, floor = ipairs, tonumber, tostring, math.floor
local lower = string.lower

------------------------------------------------------------------------
-- Options
------------------------------------------------------------------------
function M.PSS_OptLabel(o)
	return ((o.label or o.key):gsub("[:%s]+$", ""))
end

function M.PSS_OptTip(o)
	local t = M.PSS_OptLabel(o)
	if o.tip then t = t .. "\n\n" .. o.tip end
	if o.target then t = t .. "\n\nCan also be set per guild or per player." end
	return t
end

function M.PSS_OptChoiceText(o, v)
	for _, ch in ipairs(o.choices or {}) do if ch[1] == v then return ch[2] end end
	return tostring(v)
end

local function Clamp(o, v)
	local n = tonumber(v)
	if not n then return nil end
	n = floor(n)
	if o.min and n < o.min then n = o.min end
	if o.max and n > o.max then n = o.max end
	return n
end

-- every option under its section, in M.PSS_OPTIONS order (an inline
-- number is drawn by its tick box), with the text the search looks in
-- an item list entry (Drop The Cheapest Thing): an item link, "item:<id>" or
-- a plain id, to the item id (nil for anything else)
function M.PSS_ItemIDFromText(text)
	if type(text) ~= "string" then return nil end
	local id = text:match("item:(%d+)") or text:match("^%s*(%d+)%s*$")
	id = tonumber(id)
	if id and id > 0 then return floor(id) end
end

-- the name and icon a row of an item list shows: the item's own when the
-- client knows it, else "item:<id>" and the question mark
function M.PSS_ItemText(id)
	local get = C_Item and C_Item.GetItemInfo or GetItemInfo
	local name = get and get(id)
	local geti = C_Item and C_Item.GetItemIconByID or GetItemIconByID
	local icon = geti and geti(id)
	return name or ("item:" .. id), icon or 134400
end

-- a section's group title ("Feature Options", the group the Options builder
-- and the navigation draw once above its sections), and the line shown in
-- place of its rows while its Enabled component is off (nil: always live)
function M.PSS_OptSectionGroup(section)
	return M.PSS_OPTION_SECTION_GROUP and M.PSS_OPTION_SECTION_GROUP[section]
end
function M.PSS_OptSectionOff(section)
	local g = M.PSS_OPTION_SECTION_GATE and M.PSS_OPTION_SECTION_GATE[section]
	if g and not M.PSS_On(g.on) then return g.text end
end

function M.PSS_OptGroups()
	local groups = {}
	local sections = M.PSS_OPTION_SECTIONS
	for _, section in ipairs(M.PSS_OPTION_SECTION_ORDER) do
		local g
		for _, o in ipairs(M.PSS_OPTIONS) do
			if o.section == section and not o.inline and not o.retired and not o.reserved then
				if not g then
					g = { title = ((sections[section] or ""):gsub("[:%s]+$", "")), items = {}, section = section,
						group = M.PSS_OptSectionGroup(section), off = M.PSS_OptSectionOff(section) }
					groups[#groups + 1] = g
				end
				g.items[#g.items + 1] = { o = o, find = lower(M.PSS_OptLabel(o) .. "\n" .. (o.tip or "")) }
			end
		end
	end
	return groups
end

-- the search keeps an option whose name, tip or section holds the text
function M.PSS_OptMatches(group, item, q)
	q = lower(q or "")
	return q == "" or lower(group.title):find(q, 1, true) ~= nil or item.find:find(q, 1, true) ~= nil
end

-- an Enabled components row: its label with a note, whether it can be ticked
-- (Graphics is Camelot only), and whether the change waits for a reload
local COMPONENT_NAME = { useAddons = "addons", useLogging = "logging", useGfx = "gfx", useFiltering = "filtering", useDtt = "dtt", useWarehouse = "warehouse", useBags = "bags" }
function M.PSS_OptGate(o)
	local name = COMPONENT_NAME[o.key]
	if not name then return true, "" end
	local enabled, note = true, ""
	if name == "gfx" and not M.PSS_IsCamelot() then
		enabled, note = false, " (Camelot only)"
	end
	if M.PSS_ComponentPending(name) then note = note .. " (after reload)" end
	return enabled, note
end

-- how this client reloads: "press" on Camelot (it blocks ReloadUI from addon
-- code even inside a click: only the player's own click on a secure "/reload"
-- macro reloads, which ns.Confirm { reload = true } sets up), else "direct"
function M.PSS_ReloadMode()
	return M.PSS_IsCamelot and M.PSS_IsCamelot() and "press" or "direct"
end

-- the one reload call (allowed in combat: the player chose it, the author,
-- 2026-10-10); C_UI.Reload where the client has it, else ReloadUI. On "press" clients the call is blocked
-- from addon code (the click's macro does the reload), so a reload prompt's
-- accept skips it (M.PSS_ReloadPrompt)
function M.PSS_ReloadUI()
	local reload = C_UI and C_UI.Reload or ReloadUI
	reload()
	return true
end

-- what a reload prompt's accept runs: nothing to call on "press" (its click
-- is the reload), else the reload
function M.PSS_ReloadPrompt()
	if M.PSS_ReloadMode() == "press" then return true, "press" end
	return M.PSS_ReloadUI()
end

-- the reload now
function M.PSS_ReloadNow()
	return M.PSS_ReloadPrompt()
end

-- Saved item lists (SAV-00018): "1;<id>,<id>,..." (layout 1, ids ascending,
-- no repeats, at most 500). A string of another layout is kept untouched,
-- not applied and not edited (PSS 02 section 3).
local DTT_CAP = 500
function M.PSS_DttPack(set)
	local ids = {}
	for id in pairs(set) do ids[#ids + 1] = id end
	table.sort(ids)
	return #ids > 0 and ("1;" .. table.concat(ids, ",")) or ""
end
-- set (id -> true), ok; ok is false for a layout this version cannot read
function M.PSS_DttParse(text)
	local set = {}
	if text == nil or text == "" then return set, true end
	if type(text) ~= "string" then return set, false end
	local layout, body = text:match("^(%d+);(.*)$")
	if layout ~= "1" then return set, false end
	for n in body:gmatch("%d+") do set[tonumber(n)] = true end
	return set, true
end

-- an itemlist option: its ids, ascending
function M.PSS_OptItems(o)
	local set = M.PSS_DttParse(M.PSS_Opt(o.key))
	local ids = {}
	for id in pairs(set) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end
local told
local function Edit(o, id, remove)
	local set, ok = M.PSS_DttParse(M.PSS_Opt(o.key))
	if not ok then
		if not told then told = true; M.ShowMsg("That list was saved by a newer version and is left as it is.") end
		return false
	end
	if remove then
		if not set[id] then return false end
		set[id] = nil
	else
		if set[id] then return false end
		local n = 0
		for _ in pairs(set) do n = n + 1 end
		if n >= DTT_CAP then return false end
		set[id] = true
	end
	M.PSS_SetOpt(o.key, "global", M.PSS_DttPack(set))
	return true
end
function M.PSS_OptItemAdd(o, id) return Edit(o, id, false) end
function M.PSS_OptItemRemove(o, id) return Edit(o, id, true) end

function M.PSS_OptNumberText(o)
	local n = M.PSS_Opt(o.key)
	return n ~= nil and tostring(n) or ""
end

function M.PSS_OptSetNumber(o, text)
	local n = Clamp(o, text)
	if not n then return false end
	M.PSS_SetOpt(o.key, "global", n)
	return true
end

-- A tick box with its number (o.field, the scan level cap): the number
-- must be set while the box is ticked.
function M.PSS_OptFieldOn(o)
	return M.PSS_Opt(o.key) == true and Clamp(M.PSS_OPTION_REG[o.field], M.PSS_Opt(o.field)) ~= nil
end

function M.PSS_OptFieldText(o)
	local f = M.PSS_OPTION_REG[o.field]
	local n = Clamp(f, M.PSS_Opt(f.key))
	return n and tostring(n) or ""
end

-- typed: the number in its box (ticking takes it, else the saved one)
function M.PSS_OptSetFieldOn(o, on, typed)
	local f = M.PSS_OPTION_REG[o.field]
	local n = Clamp(f, typed)
	if on and n then M.PSS_SetOpt(f.key, "global", n) end
	if on and not Clamp(f, M.PSS_Opt(f.key)) then
		M.ShowMsg(("|cffff5555%s: enter the %s first (%d-%d).|r"):format(o.label, f.label:lower(), f.min, f.max))
		return false
	end
	M.PSS_SetOpt(o.key, "global", on and true or false)
	return true
end

function M.PSS_OptSetField(o, text)
	local f = M.PSS_OPTION_REG[o.field]
	local n = Clamp(f, text)
	if n then
		M.PSS_SetOpt(f.key, "global", n)
		return true
	elseif M.PSS_Opt(o.key) then
		M.ShowMsg(("|cffff5555%s is required while %s is ticked.|r"):format(f.label, o.label))
		return false
	end
	M.PSS_SetOpt(f.key, "global", nil)
	return true
end

------------------------------------------------------------------------
-- Import/Export: what to include lives for the session only
------------------------------------------------------------------------
M.PSS_IO = { players = true, guilds = true, members = false, filters = true, builtins = true, options = false, mode = "merge" }

-- the tab's ticks and mode (kept for the session)
function M.PSS_IOSet(key, on) M.PSS_IO[key] = on == true end
function M.PSS_IOSetMode(key) M.PSS_IO.mode = key end
function M.PSS_IOOn(key) return M.PSS_IO[key] == true end
function M.PSS_IOMode() return M.PSS_IO.mode end
M.PSS_IO_PARTS = {
	{ key = "players", text = "Player Ignore List" },
	{ key = "guilds", text = "Guild Ignore List" },
	{ key = "members", text = "Captured guild members", under = "guilds" },
	{ key = "filters", text = "Custom chat filters" },
	{ key = "builtins", text = "Built-in filter on/off" },
	{ key = "options", text = "Options (all characters)" },
}
M.PSS_IO_MODES = {
	{ key = "merge", text = "Merge (add what is missing)" },
	{ key = "replace", text = "Replace (only the import)" },
}

local function Sections()
	local io = M.PSS_IO
	return { players = io.players, guilds = io.guilds, members = io.guilds and io.members,
		filters = io.filters, builtins = io.builtins, options = io.options }
end

-- captured members go with the guilds only
function M.PSS_IOPartOff(key)
	return key == "members" and not M.PSS_IO.guilds
end

function M.PSS_IOModeText()
	for _, m in ipairs(M.PSS_IO_MODES) do if m.key == M.PSS_IO.mode then return m.text end end
	return ""
end

function M.PSS_ExportText()
	local text = M.PSS_EncodeExport(M.PSS_BuildExport(Sections()))
	return text, ("Copy the string below (%d characters)"):format(#text)
end

function M.PSS_ImportCheck(str)
	local data, err = M.PSS_DecodeExport(str)
	if not data then return nil, "|cffff5555Import failed: " .. tostring(err) .. "|r" end
	return data
end

function M.PSS_ImportReplaceText(data)
	if M.PSS_IO.mode ~= "replace" then return nil end
	return "Replace the ticked sections with the imported data?\n\n" .. M.PSS_DescribeImport(data)
		.. "\n\nWhat you have now in those sections will be removed."
end

function M.PSS_ImportApply(data)
	local mode = M.PSS_IO.mode == "replace" and "replace" or "merge"
	local report = M.PSS_ApplyImport(data, mode, Sections())
	return (mode == "replace" and "Replaced: " or "Merged: ") .. tostring(report)
end

-- the whole import decision: error text; or nil, the confirm's text (nil
-- when the import needs none) and the function that applies it (returns
-- the report line)
function M.PSS_ImportStart(str)
	local data, err = M.PSS_ImportCheck(str)
	if not data then return err end
	return nil, M.PSS_ImportReplaceText(data), function() return M.PSS_ImportApply(data) end
end
