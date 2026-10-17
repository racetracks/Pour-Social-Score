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
-- accent, scrolled by the mouse wheel past its height cap. A drop-down's
-- list has the port's 26 px items and is at most 200 tall; a right-click
-- menu is compact (20 px items, a slim title and divider, as wide as its
-- longest entry) and at most 400 tall, where Blizzard's menu scrolls.
--   ns.NewDropdown(parent, w, build, cap)   dd:SetLabel(text)
--                                      (cap: our list's height before it scrolls, default 200)
--                                      (always opens downward; our list is
--                                      as wide as its longest entry)
--   ns.ContextMenu(owner, build)       at the cursor
--   build(m): m:Title m:Button m:Radio m:Check m:Divider m:Sub(text, build)
--   ns.RowMenu(owner, entries, run)    a row's right-click menu from the
--                                      entries Libraries describes
--                                      (PSS_RowMenus.lua); run(act, arg)
------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local DARK = ns.DARK
local ITEM_H, PAD = 26, 1
local MENU_FILL = { 0.103, 0.095, 0.088, 0.98 }
local MENU_EDGE = { 1, 1, 1, 0.20 }
local floor, max, min = math.floor, math.max, math.min

------------------------------------------------------------------------
-- The entries of a menu: build(m) fills a plain list we can draw or hand
-- to Blizzard's menu.
------------------------------------------------------------------------
local Entries = {}
Entries.__index = Entries
local Collect

function Entries:Button(text, fn) self[#self + 1] = { kind = "button", text = text, fn = fn } end
function Entries:Radio(text, isOn, fn) self[#self + 1] = { kind = "radio", text = text, on = isOn, fn = fn } end
function Entries:Check(text, isOn, fn) self[#self + 1] = { kind = "check", text = text, on = isOn, fn = fn } end
function Entries:Divider() self[#self + 1] = { kind = "divider" } end
function Entries:Title(text) self[#self + 1] = { kind = "title", text = text } end
-- a submenu: build(sm) fills its entries (Blizzard's menu opens it beside the
-- entry on hover; our list opens a side panel beside the row, one level deep)
-- tick = { on, fn }: a tick box next to the entry (its own click toggles it,
-- fn(); anywhere else opens the submenu)
function Entries:Sub(text, build, tick) self[#self + 1] = { kind = "sub", text = text, children = Collect(build), tick = tick } end

function Collect(build)
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
local FillBlizzard
function FillBlizzard(root, list)
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
		elseif e.kind == "sub" then
			if e.tick then
				local t = e.tick
				FillBlizzard(root:CreateCheckbox(e.text, function() return IsOn(t) end, function()
					if t.fn then t.fn() end
					return MenuResponse and MenuResponse.Refresh
				end), e.children)
			else
				FillBlizzard(root:CreateButton(e.text), e.children)
			end
		elseif e.kind == "divider" and root.CreateDivider then
			root:CreateDivider()
		elseif e.kind == "title" and root.CreateTitle then
			root:CreateTitle(e.text)
		end
	end
	if #list > 20 and root.SetScrollMode then root:SetScrollMode(400) end
end

------------------------------------------------------------------------
-- Our menu list: one panel (PSS_Menu) and, built on the first hover of a
-- side menu entry, a second one beside the hovered row (PSS_MenuSide).
-- Both draw the same way; the side panel is one level deep (a side menu
-- entry inside it opens nothing).
------------------------------------------------------------------------
local menu, catcher
local P1, P2 = {}, nil
local owner = nil

-- Two sizes: a drop-down's list (the port's 26 px items) and a compact
-- right-click menu. Titles and dividers take less room than items; cap is
-- the height past which the menu scrolls.
local SIZES = {
	list = { item = ITEM_H, title = 22, divider = 9, font = 13, inset = 10, cap = 200 },
	compact = { item = 20, title = 18, divider = 7, font = 12, inset = 8, cap = 400 },
}
P1.size = SIZES.list

local function HeightOf(p, e)
	if e.kind == "title" then return p.size.title end
	if e.kind == "divider" then return p.size.divider end
	return p.size.item
end

-- do the entries from first on fit under the menu's height cap?
local function FitsFrom(p, first)
	local h = 0
	for i = first, #p.shown do
		h = h + HeightOf(p, p.shown[i])
		if h > p.size.cap - PAD * 2 then return false end
	end
	return true
end

local function Close()
	if menu then menu:Hide() end
end

local Draw, OpenSide

-- a row's text alpha: the label's colour, one step fainter; a title fainter again
local function RowAlpha(e)
	return e and e.kind == "title" and DARK.menuTitle or DARK.menuText
end

local function MakeSlot(p, i)
	local f = p.f
	local sl = CreateFrame("Button", nil, f)
	sl:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
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
	ns.NoSnap(sl.line)
	sl.line:SetPoint("LEFT", sl, "LEFT", 8, 0)
	sl.line:SetPoint("RIGHT", sl, "RIGHT", -8, 0)
	sl.line:SetColorTexture(1, 1, 1, 0.10)
	sl:SetScript("OnEnter", function(self)
		self.text:SetAlpha(1)
		local e = self.entry
		if p ~= P1 or not e then return end
		-- a side menu entry opens its side panel; any other row closes it
		if e.kind == "sub" then OpenSide(self) elseif P2 and P2.f:IsShown() then P2.f:Hide() end
	end)
	sl:SetScript("OnLeave", function(self)
		local e = self.entry
		self.text:SetAlpha(RowAlpha(e))
	end)
	sl:SetScript("OnClick", function(self)
		local e = self.entry
		if not e then return end
		if e.kind == "sub" and e.tick and p == P1 then
			-- the tick box is the left edge of the row; a click there toggles
			local x = GetCursorPosition() / self:GetEffectiveScale()
			if x - (self:GetLeft() or 0) < 24 then
				if e.tick.fn then e.tick.fn() end
				ns.DrawMenu()
				return
			end
		end
		if e.kind == "sub" then
			if p == P1 then OpenSide(self) end
			return
		end
		if e.fn then e.fn() end
		if e.kind == "check" or e.keep then ns.DrawMenu() else Close() end
	end)
	p.slots[i] = sl
	return sl
end

-- Lay the entries from offset down until the height cap; returns how many.
function Draw(p)
	local shown, slots, size, f = p.shown, p.slots, p.size, p.f
	local marks = false
	for _, e in ipairs(shown) do
		if e.kind == "radio" or e.kind == "check" or (e.kind == "sub" and e.tick) then marks = true break end
	end
	local sideOn = p == P1 and P2 and P2.f:IsShown() and P2.entry
	local y, n = PAD, 0
	for i = p.offset + 1, #shown do
		local e = shown[i]
		local h = HeightOf(p, e)
		if y + h > size.cap - PAD then break end
		n = n + 1
		local sl = slots[n] or MakeSlot(p, n)
		sl.entry = e
		sl:SetHeight(h)
		sl:ClearAllPoints()
		sl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
		sl:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
		sl:Show()
		local title, divider = e.kind == "title", e.kind == "divider"
		sl.text:SetFontObject(ns.Font(title and size.font - 1 or size.font))
		sl.text:SetText(divider and "" or (e.kind == "sub" and (e.text or "") .. " >" or e.text) or "")
		sl.text:ClearAllPoints()
		sl.text:SetPoint("LEFT", sl, "LEFT", marks and 24 or size.inset, 0)
		sl.text:SetPoint("RIGHT", sl, "RIGHT", -8, 0)
		sl.text:SetTextColor(DARK.text[1], DARK.text[2], DARK.text[3])
		sl.text:SetAlpha(RowAlpha(e))
		sl.line:SetShown(divider)
		if divider then sl.line:SetHeight(ns.OnePixel(sl)) end
		local on = ((e.kind == "radio" or e.kind == "check") and IsOn(e) or (e.kind == "sub" and e.tick and IsOn(e.tick))) and true or false
		sl.mark:SetShown(on)
		sl.mark:SetColorTexture(ns.Accent())
		sl.box:SetShown(e.kind == "check" or (e.kind == "sub" and e.tick ~= nil))
		sl.picked:SetShown((on and e.kind == "radio") or sideOn == e)
		sl:EnableMouse(not (title or divider))
		y = y + h
	end
	for i = n + 1, #slots do
		slots[i].entry = nil
		slots[i].text:SetText("")
		slots[i]:Hide()
	end
	f:SetHeight(y + PAD)
	-- a list longer than the menu: a thin thumb on the right
	if n < #shown then
		local h = max(20, (f:GetHeight() - 8) * n / #shown)
		local room = #shown - n
		f.thumb:SetHeight(h)
		f.thumb:ClearAllPoints()
		f.thumb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -4 - (f:GetHeight() - 8 - h) * min(1, p.offset / room))
		f.thumb:Show()
	else
		f.thumb:Hide()
	end
	return n
end
ns.DrawMenu = function()
	if menu and menu:IsShown() then
		Draw(P1)
		if P2 and P2.f:IsShown() then Draw(P2) end
	end
end

local function BuildPanel(p, name, level)
	local f = CreateFrame("Frame", name, UIParent)
	p.f, p.slots, p.offset = f, {}, 0
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetFrameLevel(level)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:EnableMouseWheel(true)
	f:Hide()
	ns.Fill(f, MENU_FILL, -6)
	ns.PixelBorder(f, MENU_EDGE)
	f.thumb = f:CreateTexture(nil, "OVERLAY")
	f.thumb:SetWidth(4)
	f.thumb:SetColorTexture(1, 1, 1, 0.27)
	f:SetScript("OnMouseWheel", function(_, delta)
		-- down only while the rest does not fit yet; up to the first entry
		if delta < 0 and not FitsFrom(p, p.offset + 1) then
			p.offset = p.offset + 1
		elseif delta > 0 and p.offset > 0 then
			p.offset = p.offset - 1
		end
		Draw(p)
	end)
	-- measures every entry for the panel's width, shown or not
	f.measure = ns.NewText(f, 13)
	f.measure:SetPoint("TOPLEFT")
	f.measure:Hide()	-- hidden, never faded: GetStringWidth still works (#201)
	f.slots = p.slots
	return f
end

local function BuildMenu()
	menu = BuildPanel(P1, "PSS_Menu", 200)
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
		if P2 then P2.f:Hide() end
		owner = nil
	end)
	ns.EscapeCloses(menu, "PSS_Menu")	-- after its OnHide (SetScript drops hooks)
end

-- Show our list for the entries; anchor(frame) places it.
local function OpenOurs(list, width, place, by, compact, cap)
	if not menu then BuildMenu() end
	if menu:IsShown() then Close() end
	P1.shown, P1.offset, owner = list, 0, by
	local size = compact and SIZES.compact or SIZES.list
	if cap then size = setmetatable({ cap = cap }, { __index = size }) end
	P1.size = size
	menu:SetWidth(width)
	menu:ClearAllPoints()
	place(menu)
	Draw(P1)
	menu:Show()
	menu:Raise()
end

-- a panel as wide as its longest entry (every entry, also those below the
-- height cap) and no narrower than minW
local function FitPanel(p, list, minW)
	local widest, fs = 0, p.f.measure
	for _, e in ipairs(list) do
		if e.kind ~= "divider" then
			fs:SetFontObject(ns.Font(e.kind == "title" and p.size.font - 1 or p.size.font))
			fs:SetText(e.text or "")
			widest = max(widest, fs:GetStringWidth())
		end
	end
	fs:SetText("")
	p.f:SetWidth(max(minW, widest + 28))
end
local function FitWidth(list, minW) FitPanel(P1, list, minW) end

-- The side panel beside a side menu entry's row: its children, to the right
-- of the row (to the left when the right side does not fit on the screen).
-- It stays until another row of the menu is entered or the menu closes.
function OpenSide(slot)
	local e = slot.entry
	if not e or e.kind ~= "sub" then return end
	if not P2 then
		P2 = { size = P1.size }
		BuildPanel(P2, "PSS_MenuSide", 201)
	end
	if P2.f:IsShown() and P2.entry == e then return end
	P2.entry, P2.shown, P2.offset, P2.size = e, e.children, 0, P1.size
	FitPanel(P2, e.children, 100)
	Draw(P2)
	local f = P2.f
	f:ClearAllPoints()
	local right, w = slot:GetRight() or 0, f:GetWidth()
	if right + 2 + w > (UIParent:GetRight() or 0) and (slot:GetLeft() or 0) - 2 - w >= (UIParent:GetLeft() or 0) then
		f:SetPoint("TOPRIGHT", slot, "TOPLEFT", -2, 0)
	else
		f:SetPoint("TOPLEFT", slot, "TOPRIGHT", 2, 0)
	end
	f:Show()
	f:Raise()
	Draw(P1)
	slot.text:SetAlpha(1)
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

function ns.NewDropdown(parent, w, build, cap)
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
		local list = Collect(build)
		OpenOurs(list, w, function(m)
			m:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
		end, self, false, cap)
		FitWidth(list, w)
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
	ns.Fresh()
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
	FitWidth(list, width)
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
