------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - MENUS
--
-- Drop-downs and right-click menus. A menu is described the same way in
-- every look, by a build function that adds its entries:
--   build(m)  m:Button(text, fn)              runs fn, closes
--             m:Radio(text, isOn, fn)          one of a set; runs fn, closes
--             m:Check(text, isOn, fn)          a tick; runs fn, stays open
--             m:Divider()   m:Title(text)
-- Blizzard: Blizzard's menus (MenuUtil, the Menu API). Dark, or a client
-- without the Menu API: our menu list (PSS_Menu), built on first use: a
-- dark list with a faint edge, the picked or ticked entries marked in the
-- accent, at most 200 tall and scrolled by the mouse wheel. A drop-down's
-- list has the port's 26 px items; a right-click menu is compact (20 px
-- items, a slim title and divider, as wide as its longest entry).
--   ns.NewDropdown(parent, w, build)   dd:SetLabel(text)
--   ns.ContextMenu(owner, build)       at the cursor
--   ns.RowMenu(owner, entries, run)    a row's right-click menu from the
--                                      entries Libraries describes
--                                      (PSS_RowMenus.lua); run(act, arg)
------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local DARK = ns.DARK
local ITEM_H, MAX_H, PAD = 26, 200, 1
local MENU_FILL = { 0.103, 0.095, 0.088, 0.98 }
local MENU_EDGE = { 1, 1, 1, 0.20 }
local floor, max, min = math.floor, math.max, math.min

------------------------------------------------------------------------
-- The entries of a menu: build(m) fills a plain list we can draw or hand
-- to Blizzard's menu.
------------------------------------------------------------------------
local Entries = {}
Entries.__index = Entries

function Entries:Button(text, fn) self[#self + 1] = { kind = "button", text = text, fn = fn } end
function Entries:Radio(text, isOn, fn) self[#self + 1] = { kind = "radio", text = text, on = isOn, fn = fn } end
function Entries:Check(text, isOn, fn) self[#self + 1] = { kind = "check", text = text, on = isOn, fn = fn } end
function Entries:Divider() self[#self + 1] = { kind = "divider" } end
function Entries:Title(text) self[#self + 1] = { kind = "title", text = text } end

local function Collect(build)
	local list = setmetatable({}, Entries)
	build(list)
	return list
end

-- isOn may be a value or a function (read when drawn)
local function IsOn(e)
	if type(e.on) == "function" then return e.on() and true or false end
	return e.on and true or false
end

-- Blizzard's menu from the same entries
local function FillBlizzard(root, list)
	for _, e in ipairs(list) do
		if e.kind == "button" then
			root:CreateButton(e.text, function() if e.fn then e.fn() end end)
		elseif e.kind == "radio" then
			root:CreateRadio(e.text, function() return IsOn(e) end, function() if e.fn then e.fn() end end)
		elseif e.kind == "check" then
			root:CreateCheckbox(e.text, function() return IsOn(e) end, function()
				if e.fn then e.fn() end
				-- a tick keeps the menu open
				return MenuResponse and MenuResponse.Refresh
			end)
		elseif e.kind == "divider" and root.CreateDivider then
			root:CreateDivider()
		elseif e.kind == "title" and root.CreateTitle then
			root:CreateTitle(e.text)
		end
	end
	if #list > 20 and root.SetScrollMode then root:SetScrollMode(400) end
end

------------------------------------------------------------------------
-- Our menu list (one, shared)
------------------------------------------------------------------------
local menu, slots, catcher
local shown, offset, owner = nil, 0, nil

-- Two sizes: a drop-down's list (the port's 26 px items) and a compact
-- right-click menu. Titles and dividers take less room than items.
local SIZES = {
	list = { item = ITEM_H, title = 22, divider = 9, font = 13, inset = 10 },
	compact = { item = 20, title = 18, divider = 7, font = 12, inset = 8 },
}
local size = SIZES.list

local function HeightOf(e)
	if e.kind == "title" then return size.title end
	if e.kind == "divider" then return size.divider end
	return size.item
end

-- do the entries from first on fit under the menu's height cap?
local function FitsFrom(first)
	local h = 0
	for i = first, #shown do
		h = h + HeightOf(shown[i])
		if h > MAX_H - PAD * 2 then return false end
	end
	return true
end

local function Close()
	if menu then menu:Hide() end
end
ns.CloseMenu = Close

local function MakeSlot(i)
	local sl = CreateFrame("Button", nil, menu)
	sl:SetPoint("RIGHT", menu, "RIGHT", -PAD, 0)
	sl.picked = sl:CreateTexture(nil, "BACKGROUND")
	sl.picked:SetAllPoints()
	sl.picked:SetColorTexture(1, 1, 1, 0.04)
	local hl = sl:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	sl.box = sl:CreateTexture(nil, "ARTWORK")
	sl.box:SetSize(12, 12)
	sl.box:SetPoint("LEFT", sl, "LEFT", 8, 0)
	sl.box:SetColorTexture(1, 1, 1, 0.12)
	sl.mark = sl:CreateTexture(nil, "OVERLAY")
	sl.mark:SetSize(8, 8)
	sl.mark:SetPoint("CENTER", sl.box, "CENTER")
	sl.text = ns.NewText(sl, 13)
	sl.text:SetJustifyH("LEFT")
	sl.text:SetWordWrap(false)
	sl.line = sl:CreateTexture(nil, "ARTWORK")
	sl.line:SetHeight(1)
	sl.line:SetPoint("LEFT", sl, "LEFT", 8, 0)
	sl.line:SetPoint("RIGHT", sl, "RIGHT", -8, 0)
	sl.line:SetColorTexture(1, 1, 1, 0.10)
	sl:SetScript("OnEnter", function(self) self.text:SetAlpha(1) end)
	sl:SetScript("OnLeave", function() ns.DrawMenu() end)
	sl:SetScript("OnClick", function(self)
		local e = self.entry
		if not e then return end
		if e.fn then e.fn() end
		if e.kind == "check" then ns.DrawMenu() else Close() end
	end)
	slots[i] = sl
	return sl
end

-- Lay the entries from offset down until the height cap; returns how many.
local function Draw()
	local marks = false
	for _, e in ipairs(shown) do
		if e.kind == "radio" or e.kind == "check" then marks = true break end
	end
	local y, n = PAD, 0
	for i = offset + 1, #shown do
		local e = shown[i]
		local h = HeightOf(e)
		if y + h > MAX_H - PAD then break end
		n = n + 1
		local sl = slots[n] or MakeSlot(n)
		sl.entry = e
		sl:SetHeight(h)
		sl:ClearAllPoints()
		sl:SetPoint("TOPLEFT", menu, "TOPLEFT", PAD, -y)
		sl:SetPoint("RIGHT", menu, "RIGHT", -PAD, 0)
		sl:Show()
		local title, divider = e.kind == "title", e.kind == "divider"
		sl.text:SetFontObject(ns.Font(title and size.font - 1 or size.font))
		sl.text:SetText(divider and "" or e.text or "")
		sl.text:ClearAllPoints()
		sl.text:SetPoint("LEFT", sl, "LEFT", marks and 24 or size.inset, 0)
		sl.text:SetPoint("RIGHT", sl, "RIGHT", -8, 0)
		sl.text:SetTextColor(1, 1, 1)
		sl.text:SetAlpha(title and 0.41 or 0.53)
		sl.line:SetShown(divider)
		local on = (e.kind == "radio" or e.kind == "check") and IsOn(e)
		sl.mark:SetShown(on)
		sl.mark:SetColorTexture(ns.Accent())
		sl.box:SetShown(e.kind == "check")
		sl.picked:SetShown(on and e.kind == "radio")
		sl:EnableMouse(not (title or divider))
		y = y + h
	end
	for i = n + 1, #slots do
		slots[i].entry = nil
		slots[i]:Hide()
	end
	menu:SetHeight(y + PAD)
	-- a list longer than the menu: a thin thumb on the right
	if n < #shown then
		local h = max(20, (menu:GetHeight() - 8) * n / #shown)
		local room = #shown - n
		menu.thumb:SetHeight(h)
		menu.thumb:ClearAllPoints()
		menu.thumb:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -2, -4 - (menu:GetHeight() - 8 - h) * min(1, offset / room))
		menu.thumb:Show()
	else
		menu.thumb:Hide()
	end
	return n
end
ns.DrawMenu = function() if menu and menu:IsShown() then Draw() end end

local function BuildMenu()
	menu = CreateFrame("Frame", "PSS_Menu", UIParent)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:SetFrameLevel(200)
	menu:SetClampedToScreen(true)
	menu:EnableMouse(true)
	menu:EnableMouseWheel(true)
	menu:Hide()
	ns.Fill(menu, MENU_FILL, -6)
	ns.PixelBorder(menu, MENU_EDGE)
	menu.thumb = menu:CreateTexture(nil, "OVERLAY")
	menu.thumb:SetWidth(4)
	menu.thumb:SetColorTexture(1, 1, 1, 0.27)
	menu:SetScript("OnMouseWheel", function(_, delta)
		-- down only while the rest does not fit yet; up to the first entry
		if delta < 0 and not FitsFrom(offset + 1) then
			offset = offset + 1
		elseif delta > 0 and offset > 0 then
			offset = offset - 1
		end
		Draw()
	end)
	-- a click anywhere else closes the menu (a full-screen catcher under it)
	catcher = CreateFrame("Button", nil, UIParent)
	catcher:SetAllPoints(UIParent)
	catcher:SetFrameStrata("FULLSCREEN_DIALOG")
	catcher:SetFrameLevel(199)
	catcher:RegisterForClicks("AnyUp")
	catcher:SetScript("OnClick", Close)
	catcher:Hide()
	menu:SetScript("OnShow", function() catcher:Show() end)
	menu:SetScript("OnHide", function()
		catcher:Hide()
		owner = nil
	end)
	ns.EscapeCloses(menu, "PSS_Menu")	-- after its OnHide (SetScript drops hooks)
	slots = {}
	menu.slots = slots
end

-- Show our list for the entries; anchor(frame) places it.
local function OpenOurs(list, width, place, by, compact)
	if not menu then BuildMenu() end
	if menu:IsShown() then Close() end
	shown, offset, owner = list, 0, by
	size = compact and SIZES.compact or SIZES.list
	menu:SetWidth(width)
	menu:ClearAllPoints()
	place(menu)
	Draw()
	menu:Show()
	menu:Raise()
end

------------------------------------------------------------------------
-- Drop-down: a Blizzard DropdownButton and our Dark button in the same
-- place; the look shows one. dd:SetLabel(text) sets what both show.
------------------------------------------------------------------------
local function Chevron(parent)
	-- a small down chevron from two lines (no art)
	local a = parent:CreateLine(nil, "OVERLAY")
	local b = parent:CreateLine(nil, "OVERLAY")
	for _, l in ipairs({ a, b }) do
		l:SetThickness(1.5)
		l:SetColorTexture(1, 1, 1, 0.7)
	end
	a:SetStartPoint("RIGHT", parent, -14, 2)
	a:SetEndPoint("RIGHT", parent, -10, -2)
	b:SetStartPoint("RIGHT", parent, -10, -2)
	b:SetEndPoint("RIGHT", parent, -6, 2)
	return { a, b }
end

function ns.NewDropdown(parent, w, build)
	local dd = CreateFrame("Frame", nil, parent)
	dd:SetSize(w, 24)
	local ok, blizz = pcall(CreateFrame, "DropdownButton", nil, dd, "WowStyle1DropdownTemplate")
	if ok and blizz and blizz.SetupMenu then
		blizz:SetAllPoints(dd)
		blizz:SetupMenu(function(_, root) FillBlizzard(root, Collect(build)) end)
	else
		blizz = nil
	end
	local dark = CreateFrame("Button", nil, dd)
	dark:SetAllPoints(dd)
	ns.Fill(dark, DARK.control, -6)
	local hover = dark:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	hover:SetColorTexture(1, 1, 1, 0.05)
	ns.PixelBorder(dark, DARK.checkBorder)
	local label = ns.NewText(dark, 12)
	label:SetPoint("LEFT", dark, "LEFT", 8, 0)
	label:SetPoint("RIGHT", dark, "RIGHT", -22, 0)
	label:SetJustifyH("LEFT")
	label:SetWordWrap(false)
	Chevron(dark)
	dark:SetScript("OnClick", function(self)
		if menu and menu:IsShown() and owner == self then Close() return end
		OpenOurs(Collect(build), w, function(m) m:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2) end, self)
	end)
	dd.blizz, dd.dark, dd.label = blizz, dark, label
	function dd:SetLabel(text)
		label:SetText(text or "")
		if blizz then
			if blizz.OverrideText then blizz:OverrideText(text or "") elseif blizz.SetDefaultText then blizz:SetDefaultText(text or "") end
		end
	end
	ns.OnPaint(function(isDark)
		local ours = isDark or not blizz
		dark:SetShown(ours)
		if blizz then blizz:SetShown(not ours) end
		if not ours and menu and owner == dark then Close() end
	end)
	return dd
end

------------------------------------------------------------------------
-- Right-click menu at the cursor
------------------------------------------------------------------------
function ns.ContextMenu(by, build)
	if not ns.IsDark() and MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(by, function(_, root) FillBlizzard(root, Collect(build)) end)
		return
	end
	local list = Collect(build)
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	local width = 100
	OpenOurs(list, width, function(m)
		m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x or 0) / scale, (y or 0) / scale)
	end, by, true)
	-- as wide as its longest entry, no wider
	local widest = 0
	for _, sl in ipairs(slots) do
		if sl:IsShown() then widest = max(widest, sl.text:GetStringWidth()) end
	end
	menu:SetWidth(max(width, widest + 28))
end

-- A row's right-click menu: entries from Libraries (PSS_RowMenus.lua), each
-- a title, a divider, a tick or a button whose act run(act, arg) carries out.
function ns.RowMenu(by, entries, run)
	if not entries then return end
	ns.ContextMenu(by, function(m)
		for _, e in ipairs(entries) do
			if e.kind == "title" then
				m:Title(e.text)
			elseif e.kind == "divider" then
				m:Divider()
			elseif e.kind == "check" then
				m:Check(e.text, e.on, function() run(e.act, e.arg) end)
			else
				m:Button(e.text, function() run(e.act, e.arg) end)
			end
		end
	end)
end
