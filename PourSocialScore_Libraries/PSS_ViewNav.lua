------------------------------------------------------------------------
-- POUR SOCIAL SCORE - WINDOW STATE (for PourSocialScore_GUI)
--
-- What the new window remembers and which look it draws. The window only
-- draws; it reads and saves through these.
--   M.PSS_UISkin()                       "modern" (default), "blizzard" (shown as
--                                        Classic) or "dark"
--   M.PSS_UIPlace(key)                   point, relPoint, x, y or nil
--   M.PSS_SetUIPlace(key, point, relPoint, x, y)
--   M.PSS_UIFontPath(), M.PSS_UIFontChoices()   (below)
--   M.PSS_UIAccent()                     r, g, b of your class colour, or nil
--   M.PSS_UI_TABS                        the window's tabs, in order
--   M.PSS_UITab() / M.PSS_SetUITab(id)   the tab shown last (its number)
--   M.PSS_NavNew(), M.PSS_DoubleClick(), M.PSS_Throttle()   (below)
--   M.PSS_ListMixin(List)                 SortBy and SetFind for a list view
--   M.PSS_PickerToggle(it), M.PSS_PickerTickAll(items)   a results picker's ticks
-- Places are saved with the other window places (PourSocialScoreDB
-- windowPoints, held in PSS_OptionsDB).
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tonumber, ipairs, pairs, pcall = type, tonumber, ipairs, pairs, pcall

-- saved values: 1 stays "dark" (it was the only other look first, named
-- Modern); 0 is Classic (Blizzard's classic art, named Blizzard until
-- dev008_4); Modern (2) is the default from dev008_4 (Dan, 2026-10-08)
local SKINS = { [0] = "blizzard", [1] = "dark", [2] = "modern" }

function M.PSS_UISkin()
	return SKINS[tonumber(M.PSS_Opt("uiSkin")) or 2] or "modern"
end

function M.PSS_UIPlace(key)
	local db = PourSocialScoreDB
	local p = type(db) == "table" and type(db.windowPoints) == "table" and db.windowPoints[key]
	if type(p) ~= "table" or type(p[1]) ~= "string" then return nil end
	return p[1], p[2] or p[1], tonumber(p[3]) or 0, tonumber(p[4]) or 0
end

function M.PSS_SetUIPlace(key, point, relPoint, x, y)
	local db = PourSocialScoreDB
	if type(db) ~= "table" or type(point) ~= "string" then return end
	if type(db.windowPoints) ~= "table" then db.windowPoints = {} end
	db.windowPoints[key] = { point, relPoint or point, tonumber(x) or 0, tonumber(y) or 0 }
end

-- The window's tabs: key (saved), the tab's text, and the Events tab's
-- number (pies and View Events open it).
M.PSS_UI_TABS = {
	{ key = "players", text = "Player Ignore List" },
	{ key = "guilds", text = "Guild Ignore List" },
	{ key = "filters", text = "Chat Filters" },
	{ key = "events", text = "Events" },
	{ key = "importExport", text = "Import/Export" },
	{ key = "options", text = "Options" },
}
M.PSS_UI_EVENTS_TAB = 4

-- The tab shown last, saved by its key beside the window's place
-- (windowPoints.PSS_WindowTab); the first tab is the default and is not saved.
-- Events is never the tab the window opens on: it reads the block history,
-- which would load PourSocialScore_Logging before any click (the tab shown
-- before it stays saved).
local TAB_KEY = "PSS_WindowTab"

function M.PSS_UITab()
	local db = PourSocialScoreDB
	local key = type(db) == "table" and type(db.windowPoints) == "table" and db.windowPoints[TAB_KEY]
	for i, t in ipairs(M.PSS_UI_TABS) do
		if t.key == key and i ~= M.PSS_UI_EVENTS_TAB then return i end
	end
	return 1
end

function M.PSS_SetUITab(id)
	local db = PourSocialScoreDB
	local t = M.PSS_UI_TABS[id]
	if type(db) ~= "table" or not t or id == M.PSS_UI_EVENTS_TAB then return end
	if id == 1 then
		if type(db.windowPoints) == "table" then db.windowPoints[TAB_KEY] = nil end
		return
	end
	if type(db.windowPoints) ~= "table" then db.windowPoints = {} end
	db.windowPoints[TAB_KEY] = t.key
end

-- The window's accent is always your class colour (Dan, 2026-10-07): your
-- own class, never secret. nil only if the client gives none.
function M.PSS_UIAccent()
	local _, class = UnitClass("player")
	if type(class) ~= "string" then return nil end
	local c = C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class)
	c = c or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
	if type(c) == "table" and c.r then return c.r, c.g, c.b end
end

------------------------------------------------------------------------
-- The window's font (option uiFont): a Blizzard font, or one another addon
-- shared through LibSharedMedia. That library is only read, and only when
-- some other addon has loaded it; PSS ships no library.
--   M.PSS_UIFontPath()      the picked font's file, or nil (the look's own)
--   M.PSS_UIFontChoices()   adds the shared fonts to the option's choices
------------------------------------------------------------------------
local LSM_PREFIX = "lsm:"

local function BlizzardFont(key)
	if key == "game" then return STANDARD_TEXT_FONT end
	if key == "names" then return UNIT_NAME_FONT end
	if key == "damage" then return DAMAGE_TEXT_FONT end
	if key == "friz" then return "Fonts\\FRIZQT__.TTF" end
	if key == "arialn" then return "Fonts\\ARIALN.TTF" end
	if key == "morpheus" then return "Fonts\\MORPHEUS.TTF" end
	if key == "skurri" then return "Fonts\\skurri.ttf" end
end

local function SharedMedia()
	local stub = _G.LibStub
	if type(stub) ~= "table" and type(stub) ~= "function" then return nil end
	local ok, lsm = pcall(stub, "LibSharedMedia-3.0", true)
	if ok and type(lsm) == "table" and type(lsm.List) == "function" and type(lsm.Fetch) == "function" then return lsm end
end

function M.PSS_UIFontPath()
	local key = M.PSS_Opt("uiFont")
	if type(key) ~= "string" or key == "" then return nil end
	if key:sub(1, #LSM_PREFIX) == LSM_PREFIX then
		local lsm = SharedMedia()
		if not lsm then return nil end
		local ok, path = pcall(lsm.Fetch, lsm, "font", key:sub(#LSM_PREFIX + 1), true)
		return ok and type(path) == "string" and path or nil
	end
	return BlizzardFont(key)
end

function M.PSS_UIFontChoices()
	local o = M.PSS_OPTION_REG and M.PSS_OPTION_REG.uiFont
	if not o then return {} end
	local lsm = SharedMedia()
	if not lsm then return o.choices end
	local have = {}
	for _, ch in ipairs(o.choices) do have[ch[1]] = true end
	local ok, names = pcall(lsm.List, lsm, "font")
	if ok and type(names) == "table" then
		for _, name in ipairs(names) do
			if type(name) == "string" and not have[LSM_PREFIX .. name] then
				have[LSM_PREFIX .. name] = true
				o.choices[#o.choices + 1] = { LSM_PREFIX .. name, name }
			end
		end
	end
	return o.choices
end

------------------------------------------------------------------------
-- Back and forward: the views the window showed, oldest first, and the
-- one shown. A view is { tab = id, view = what the tab's page says it
-- shows (nil: how the tab opens) }. The window draws the arrows and the
-- line by them; this only keeps the steps.
--   local nav = M.PSS_NavNew(max)        (max steps kept, default 50)
--   nav:Record(tab, view)  a new step after the user changed the view
--                          (drops any forward steps); false if unchanged
--   nav:Current()  nav:CanBack()  nav:CanForward()
--   nav:Back()  nav:Forward()            the step to show, or nil
--   nav:Replace(tab, view)               the step shown is now this (a
--                                        view that is gone)
--   nav:BackToOther(tab)  the newest earlier step on another tab (Escape on
--                         the Events tab returns where it came from), or nil
------------------------------------------------------------------------
local Nav = {}
Nav.__index = Nav

function M.PSS_NavNew(max)
	return setmetatable({ steps = {}, pos = 0, max = max or 50 }, Nav)
end

function Nav:Current() return self.steps[self.pos] end
function Nav:CanBack() return self.pos > 1 end
function Nav:CanForward() return self.pos < #self.steps end

function Nav:Record(tab, view)
	local top = self.steps[self.pos]
	if top and top.tab == tab and top.view == view then return false end
	for i = #self.steps, self.pos + 1, -1 do self.steps[i] = nil end
	self.steps[#self.steps + 1] = { tab = tab, view = view }
	if #self.steps > self.max then table.remove(self.steps, 1) end
	self.pos = #self.steps
	return true
end

function Nav:Back()
	if self.pos <= 1 then return nil end
	self.pos = self.pos - 1
	return self.steps[self.pos]
end

function Nav:Forward()
	if self.pos >= #self.steps then return nil end
	self.pos = self.pos + 1
	return self.steps[self.pos]
end

function Nav:Replace(tab, view)
	if self.pos > 0 then self.steps[self.pos] = { tab = tab, view = view } end
end

function Nav:BackToOther(tab)
	for pos = self.pos - 1, 1, -1 do
		if self.steps[pos].tab ~= tab then
			self.pos = pos
			return self.steps[pos]
		end
	end
	return nil
end

------------------------------------------------------------------------
-- Small helpers the window's tabs share.
--   M.PSS_DoubleClick(state, key [, now])  true for a second click on the
--       same key within 0.35 s (state: the caller's own table)
--   M.PSS_Throttle(fn [, delay])  a function that runs fn once, delay
--       seconds (0.25) after the first of a burst of calls (redraws while
--       blocks pour in)
------------------------------------------------------------------------
local DOUBLE_CLICK = 0.35

function M.PSS_DoubleClick(state, key, now)
	now = now or GetTime()
	if state.key == key and state.at and now - state.at <= DOUBLE_CLICK then
		state.key, state.at = nil, nil
		return true
	end
	state.key, state.at = key, now
	return false
end

function M.PSS_Throttle(fn, delay)
	local waiting = false
	return function()
		if waiting then return end
		waiting = true
		C_Timer.After(delay or 0.25, function()
			waiting = false
			fn()
		end)
	end
end

------------------------------------------------------------------------
-- The sort and search every list view shares (Players, Guilds, Chat
-- Filters): copied onto the view's own List table when its file loads
------------------------------------------------------------------------
local mixin = {}

-- a header clicked: that column, or the same one the other way round
function mixin:SortBy(key)
	if self.key == key then
		self.asc = not self.asc
	else
		self.key, self.asc = key, true
	end
end

-- the search text changed; true when the list must be sorted again
function mixin:SetFind(text)
	text = text or ""
	if text == self.find then return false end
	self.find = text
	return true
end

function M.PSS_ListMixin(List)
	for k, fn in pairs(mixin) do List[k] = fn end
	return List
end

------------------------------------------------------------------------
-- A search results picker's entries { name, listed, ticked } (Guild Search,
-- Player Search): a click ticks or unticks one (one already listed stays as
-- it is); Tick All ticks every one not listed. Toggle: true when it changed.
------------------------------------------------------------------------
function M.PSS_PickerToggle(it)
	if not it or it.listed then return false end
	it.ticked = not it.ticked
	return true
end

function M.PSS_PickerTickAll(items)
	for _, it in ipairs(items) do it.ticked = not it.listed end
end
