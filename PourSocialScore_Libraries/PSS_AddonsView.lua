------------------------------------------------------------------------
-- POUR SOCIAL SCORE - ADDONS VIEW (for the AddOns tab, PourSocialScore_GUI)
--
-- What the window's AddOns tab shows and does, worked out here so the tab
-- only draws (the logic is PSS_AddonsQuery.lua). One view object per tab:
--   local V = M.PSS_AddonView()
--   V.who "me" | "all", V.view "group" | "az" | "lod", V.find, V.deps
--   V:Build()                  the list and its visible lines; the lines'
--                              count, the footer text, the empty text
--   V:Row(k, out)              line k: a header or an addon, its cells
--   V:Tick(k, on)  V:Toggle(k) V:CollapseAll(on)
--   V:Tip(k)  V:Menu(k)  V:Act(k, act, arg)
--   V:Slots()  V:PresetMenu(p)  V:PresetAct(p, act, name)   (addon profiles)
--   V:ProfileMenu()  (level 1: every place; PresetMenu is level 2)
--   V:Release()                the window closed: the list is dropped
-- A line is an addon (its position in the list) or a group header.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
if not M.PSS_On("addons") then return end	-- the Addon Manager is off (issue 181)

local type, tostring, ipairs, pairs = type, tostring, ipairs, pairs
local format, floor, lower = string.format, math.floor, string.lower
local concat = table.concat

local Q = M.PSS_AddonText

local COLORS = { ok = "ffffd100", off = "ff9d9d9d", lod = "ff71d5ff", warn = "ffff8000", bad = "ffff4040", reload = "ffc07fff" }
local ALERT = "|TInterface\\DialogFrame\\DialogIcon-AlertNew-16:14|t"
local QUESTION = "Interface\\ICONS\\INV_Misc_QuestionMark"

local T = {
	loaded = "%d of %d loaded",
	footer = "%d addons, %d on for %s",
	empty = "No addons match.",
	notLoaded = "Not loaded.",
	author = "Author",
	version = "Version",
	requires = "Requires",
	optional = "Optional",
	pssTip = "Pour Social Score cannot be turned off here.",
	protectedTip = "Protected: Disable All and addon profiles leave it on.",
	coreHead = "Core Addon Profiles",
	layeredHead = "Layered Addon Profiles",
	mark = "*",
}

local function colored(key, text)
	return "|c" .. (COLORS[key] or COLORS.ok) .. text .. "|r"
end

-- an addon's own icon as text, the question mark when it has none
local function iconText(i)
	local tex, atlas = M.PSS_AddonIcon(i)
	if atlas and CreateAtlasMarkup then return CreateAtlasMarkup(atlas, 16, 16) .. " " end
	return "|T" .. (tex or QUESTION) .. ":16|t "
end

local View = M.PSS_ListMixin({})
View.__index = View

function M.PSS_AddonView()
	return setmetatable({ who = "me", view = M.PSS_AddonViewMode(), deps = true, find = "", collapsed = {}, items = {}, n = 0,
		buf = {} }, View)
end

-- the list and the lines it shows: positive = an addon (its position),
-- negative = a header (minus its group number); a search shows every group open
function View:Build()
	self.view = M.PSS_AddonViewMode()
	local L = M.PSS_AddonList(self.who, self.view, self.find)
	self.L = L
	local items, n, lastg, on = self.items, 0, nil, 0
	local open = self.find ~= ""
	local buf = self.buf
	for p = 1, L.n do
		local gi = L.gi[p]
		if gi then
			if gi ~= lastg then
				lastg = gi
				n = n + 1
				items[n] = -gi
			end
			if open or not self.collapsed[L.groups[gi].name] then
				n = n + 1
				items[n] = p
			end
		else
			n = n + 1
			items[n] = p
		end
		if M.PSS_AddonRow(L.idx[p], self.who, buf).enabled then on = on + 1 end
	end
	for k = #items, n + 1, -1 do items[k] = nil end
	self.n = n
	self.footer = format(T.footer, L.n, on, self.who == "all" and Q.everyone or Q.me)
	return n, self.footer, T.empty
end

function View:Count() return self.n end

-- the cells of line k; out is reused by the tab
function View:Row(k, out)
	local item = self.items[k]
	local L = self.L
	if not item or not L then return nil end
	if item < 0 then
		local g = L.groups[-item]
		out.header, out.open = true, not self.collapsed[g.name]
		out.name, out.n = g.name, g.to - g.from + 1
		out.text = format("%s (%d)", g.name, out.n)
		out.status, out.load, out.locked, out.pss, out.outdated = "", false, false, false, false
		-- the group's tick: 0 none on, 1 some, 2 all
		local on = 0
		for p = g.from, g.to do
			if M.PSS_AddonRow(L.idx[p], self.who, self.buf).enabled then on = on + 1 end
		end
		out.tick = on == 0 and 0 or (on == out.n and 2 or 1)
		return out
	end
	local r = M.PSS_AddonRow(L.idx[item], self.who, self.buf)
	out.header = false
	out.i, out.name = r.i, r.name
	local indent = L.gi[item] and "      " or ""
	out.text = indent .. iconText(r.i) .. colored(r.status, r.title)
	out.status = colored(r.status, r.text) .. (r.outdated and (" " .. ALERT) or "")
	out.tick = r.state == 0 and 0 or (r.state == 1 and 1 or 2)
	out.load, out.locked, out.pss, out.outdated = r.canLoad, r.locked, r.pss, r.outdated
	return out
end

-- a header's lines: positions a to b of the list
function View:Members(gi)
	local g = self.L and self.L.groups[gi]
	if g then return g.from, g.to end
end

function View:Tick(k, on)
	local item = self.items[k]
	if not item or not self.L then return false end
	if item < 0 then
		local a, b = self:Members(-item)
		return M.PSS_AddonTickMany(self.L, a, b, on, self.who, self.deps)
	end
	return M.PSS_AddonTick(self.L.idx[item], on, self.who, self.deps)
end

function View:Toggle(k)
	local item = self.items[k]
	if item and item < 0 and self.L then
		local name = self.L.groups[-item].name
		self.collapsed[name] = (not self.collapsed[name]) or nil
	end
end

function View:CollapseAll(on)
	for _, g in ipairs(self.L and self.L.groups or {}) do self.collapsed[g.name] = on or nil end
end

-- the tooltip of line k
function View:Tip(k)
	local item = self.items[k]
	local L = self.L
	if not item or not L then return nil end
	local lines = {}
	if item < 0 then
		local gi = -item
		local g = L.groups[gi]
		local loaded, total = M.PSS_AddonGroupLoaded(L, gi)
		lines[1] = g.name
		lines[2] = format(T.loaded, loaded, total)
		return concat(lines, "\n")
	end
	local i = L.idx[item]
	local r = M.PSS_AddonRow(i, self.who, self.buf)
	lines[1] = r.title
	local author, version = M.PSS_AddonMeta(i, "Author"), M.PSS_AddonMeta(i, "Version")
	if author then lines[#lines + 1] = format("%s: %s", T.author, author) end
	if version then lines[#lines + 1] = format("%s: %s", T.version, version) end
	if r.notes and r.notes ~= "" then lines[#lines + 1] = r.notes end
	local req, opt = M.PSS_AddonDeps(i, self.who)
	for _, set in ipairs({ { T.requires, req }, { T.optional, opt } }) do
		if #set[2] > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = set[1] .. ":"
			for _, d in ipairs(set[2]) do
				lines[#lines + 1] = "  " .. colored(d.text == "loaded" and "ok" or (d.text == "on" and "lod" or "bad"), d.name .. " (" .. d.text .. ")")
			end
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = colored(r.status, r.text)
	if r.pss then lines[#lines + 1] = T.pssTip elseif r.locked then lines[#lines + 1] = T.protectedTip end
	if not r.loaded then
		lines[#lines + 1] = ""
		lines[#lines + 1] = T.notLoaded
	end
	return concat(lines, "\n")
end

------------------------------------------------------------------------
-- Menus: entries { kind, text, act, arg } as PSS_RowMenus.lua describes
------------------------------------------------------------------------
function View:Menu(k)
	local item = self.items[k]
	local L = self.L
	if not item or not L then return nil end
	local e = {}
	local function add(text, act, arg) e[#e + 1] = { kind = "button", text = text, act = act, arg = arg } end
	if item < 0 then
		local g = L.groups[-item]
		e[1] = { kind = "title", text = g.name }
		add("Turn the group on", "gon")
		add("Turn the group off", "goff")
		e[#e + 1] = { kind = "divider" }
		add("Collapse all", "collapse")
		add("Expand all", "expand")
		return e
	end
	local r = M.PSS_AddonRow(L.idx[item], self.who, self.buf)
	e[1] = { kind = "title", text = r.title }
	if r.enabled then
		if not r.pss then add("Turn off", "off") end
	else
		add("Turn on", "on")
	end
	if r.canLoad then add("Load now", "load") end
	if not r.pss then add(r.locked and "Stop protecting" or "Protect", r.locked and "unlock" or "lock") end
	local presets = M.PSS_AddonPresets()
	if #presets > 0 and not r.pss then
		e[#e + 1] = { kind = "divider" }
		for _, p in ipairs(presets) do
			add("Add to " .. p.label .. (p.scope == "all" and " (all characters)" or ""), "include", p.scope .. ":" .. tostring(p.id))
		end
	end
	return e
end

-- carry out a menu entry on line k; returns text to say, if any
function View:Act(k, act, arg)
	local item = self.items[k]
	local L = self.L
	if not item or not L then return nil end
	if act == "collapse" or act == "expand" then
		self:CollapseAll(act == "collapse")
		return nil, true
	end
	if item < 0 then
		local a, b = self:Members(-item)
		if act == "gon" or act == "goff" then M.PSS_AddonTickMany(L, a, b, act == "gon", self.who, self.deps) end
		return nil
	end
	local i = L.idx[item]
	local name = M.PSS_AddonName(i)
	if act == "on" or act == "off" then
		local ok, text = M.PSS_AddonTick(i, act == "on", self.who, self.deps)
		return not ok and text or nil
	elseif act == "load" then
		local ok, text = M.PSS_AddonLoad(i)
		return not ok and text or nil
	elseif act == "lock" or act == "unlock" then
		local ok, text = M.PSS_AddonLock(name, act == "lock", self.who)
		return not ok and text or nil
	elseif act == "include" then
		local scope, id = tostring(arg):match("^(%a+):(.+)$")
		local ok, text = M.PSS_AddonPresetInclude(id, scope, name)
		return text
	end
end

------------------------------------------------------------------------
-- Addon profiles: the 25 numbered places of the scope shown (this character
-- or all characters) and your class's. Places 1 to 5 are the Core Addon
-- Profiles, the rest the Layered ones; any of them can be selected together
-- (the union of their addons, plus the hand picks, is what is on), and each
-- place can be saved into, loaded, added, taken off, renamed or deleted.
------------------------------------------------------------------------
-- the places of the menu: the engine's entries plus text, the line the
-- menu shows
function View:Slots()
	local slots = M.PSS_AddonSlots(self.who)
	for _, p in ipairs(slots) do
		if not p.empty then
			p.text = p.label .. " (" .. p.n .. ")"
		elseif p.hidden then
			p.text = p.label .. " (other version)"
		elseif p.elsewhere then
			p.text = p.label .. " (empty; saved " .. (p.elsewhere == "all" and "for all characters" or "for this character") .. ")"
		else
			p.text = p.label .. " (empty)"
		end
	end
	return slots
end

-- one place read again now (a menu may have been built before a save)
function View:Place(id)
	for _, p in ipairs(self:Slots()) do
		if p.id == id then return p end
	end
end

-- the entries of one layer: a title, then a line per place; fn(p) says what
-- a place becomes
local function layerEntries(e, head, slots, layer, fn)
	e[#e + 1] = { kind = "title", text = head }
	for _, p in ipairs(slots) do
		if p.layer == layer then e[#e + 1] = fn(p) end
	end
end

-- the drop-down's menu: Core Addon Profiles, a line, Layered Addon Profiles,
-- every place a button "Name (count)" (a free one "Profile N (empty)"), a
-- selected one marked "* "; a click opens the place's actions (PresetMenu)
function View:ProfileMenu()
	local who = self.who
	local slots = self:Slots()
	local e = {}
	local function button(p)
		local on = not p.empty and M.PSS_AddonProfileSelected(p.id, who)
		return { kind = "button", text = (on and (T.mark .. " ") or "") .. p.text, act = "place", p = p }
	end
	layerEntries(e, T.coreHead, slots, "core", button)
	e[#e + 1] = { kind = "divider" }
	layerEntries(e, T.layeredHead, slots, "layered", button)
	return e
end

-- the actions on one place p (an entry of Slots), the same rows for every
-- place as AddonControlPanel's sets menu (behaviour only): a title, Select or
-- Deselect, Save, Load, Enable all, Disable all, Rename (not the class
-- place), a divider, Delete. A free place also says why (Not saved yet) and
-- may show a profile the other scope holds; its Load, Select, Enable all,
-- Disable all and Delete are listed and say there is nothing there. Enable all
-- and Disable all are titles when none of the profile's addons is installed
function View:PresetMenu(p)
	local e = { { kind = "title", text = p.label .. (p.class and "" or (p.scope == "all" and " (all characters)" or " (this character)")) } }
	local function add(text, act) e[#e + 1] = { kind = "button", text = text, act = act } end
	if p.empty then
		e[#e + 1] = { kind = "title", text = p.hidden and "Saved by another version" or "Not saved yet" }
		if p.elsewhere then add("Show the saved profile (" .. (p.elsewhere == "all" and "all characters" or "this character") .. ")", "show") end
	end
	add((not p.empty and M.PSS_AddonProfileSelected(p.id, self.who)) and "Deselect" or "Select", "select")
	add("Save", "save")
	add("Load", "load")
	local none = not p.empty and M.PSS_AddonPresetInstalled(p.id, p.scope) == 0
	for _, a in ipairs({ { "Enable all", "enable" }, { "Disable all", "disable" } }) do
		if none then
			e[#e + 1] = { kind = "title", text = a[1] }
		else
			add(a[1], a[2])
		end
	end
	if not p.class then add("Rename", "rename") end
	e[#e + 1] = { kind = "divider" }
	add("Delete", "delete")
	return e
end

-- one action on slot p; returns the line to say (a save keeps the name)
function View:PresetAct(p, act, name)
	local ok, text
	if act == "show" then
		self.who = p.elsewhere == "all" and "all" or "me"
		return "Showing the profiles of " .. (self.who == "all" and "all characters." or "this character.")
	elseif act == "select" then
		ok, text = M.PSS_AddonProfileSelect(p.id, not M.PSS_AddonProfileSelected(p.id, self.who), self.who)
	elseif act == "load" then
		ok, text = M.PSS_AddonPresetLoad(p.id, p.scope, self.who)
	elseif act == "enable" or act == "disable" then
		ok, text = M.PSS_AddonPresetTick(p.id, p.scope, act == "enable", self.who, self.deps)
	elseif act == "save" then
		ok, text = M.PSS_AddonPresetSave(p.id, p.name, self.who)
	elseif act == "rename" then
		ok, text = M.PSS_AddonPresetRename(p.id, name, p.scope)
	elseif act == "delete" then
		ok, text = M.PSS_AddonPresetDelete(p.id, p.scope)
	end
	return text
end

-- the tick next to a place in the Profiles menu
function View:PlaceOn(p)
	return not p.empty and M.PSS_AddonPresetOn(p.id, p.scope, self.who) or false
end

-- what a reload will do, counted once for the summary at the top, the Reload
-- button and both tooltips: adds, offs (lists of names)
function View:Changes()
	return M.PSS_AddonChanges(self.who)
end

function View:Pending()
	return M.PSS_AddonPending(self.who)
end

-- the window closed: the list goes, the choices stay
function View:Release()
	self.L, self.items, self.n = nil, {}, 0
	M.PSS_AddonRelease()
end
