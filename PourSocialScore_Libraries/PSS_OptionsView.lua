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
--   M.PSS_ExportText()                 the export string
--   M.PSS_ImportCheck(str)             data, or nil and the error text
--   M.PSS_ImportReplaceText(data)      the confirm's text (mode replace) or nil
--   M.PSS_ImportApply(data)            applies it; the report line
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
function M.PSS_OptGroups()
	local groups = {}
	local sections = M.PSS_OPTION_SECTIONS
	for section = 1, #sections do
		local g
		for _, o in ipairs(M.PSS_OPTIONS) do
			if o.section == section and not o.inline and not o.retired then
				if not g then
					g = { title = ((sections[section] or ""):gsub("[:%s]+$", "")), items = {} }
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
	return M.PSS_EncodeExport(M.PSS_BuildExport(Sections()))
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
