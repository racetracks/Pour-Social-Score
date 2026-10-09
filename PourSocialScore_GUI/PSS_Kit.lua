------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - KIT
--
-- The controls every tab is built from, each in all three looks
-- (PSS_Skin.lua). Modern: Blizzard's 12.x art. Classic: the Blizzard
-- template as it is. Dark: the template's art faded out and flat fills and
-- one-pixel borders drawn over it. Sizes are the same in every look.
--   ns.NewHeading(parent, text)          13, the accent colour
--   ns.NewButton(parent, text, w, onClick, primary)   primary: the red one in Modern
--   ns.NewCheck(parent)                  24 x 24
--   ns.NewEditBox(parent, w, maxLetters, hint) and ns.NewNumberBox(parent, w)
--       hint: grey text while empty (it hooks OnTextChanged: do not SetScript it)
--   ns.NewTextArea(parent, size, maxLetters, pad)   a panel with a scrolling
--       multi-line box; ta.edit, ta.scroll (pad 4: bar room 22)
--   ns.OnCommit(box, commit, refresh)    Enter or focus loss, once
--   ns.NewSearchBox(parent, w, hint, onChange)
--   ns.NewPanel(parent, inset)           a tab page or a pane
--   ns.NewScrollFrame(parent)            scroll frame with a skinned bar
--   ns.NewTab(parent, text, onClick) and ns.SetTabSelected(tab, on)
-- Each widget keeps its Dark parts in widget.pssParts (shown in Dark).
------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local DARK = ns.DARK
local ipairs, pcall = ipairs, pcall

function ns.NewHeading(parent, text)
	local fs = ns.NewText(parent, 13)
	ns.OnPaint(function() fs:SetTextColor(ns.Accent()) end)
	fs:SetText(text or "")
	return fs
end

-- Modern: Blizzard's red three-slice button (the new Social window's
-- "Add New Friend"), its ends scaled to the height, with its pressed,
-- disabled and highlight art.
local RED = "128-RedButton"

local function RedButton(b)
	local l = ns.Own(b:CreateTexture(nil, "BACKGROUND", nil, 1))
	local c = ns.Own(b:CreateTexture(nil, "BACKGROUND", nil, 1))
	local r = ns.Own(b:CreateTexture(nil, "BACKGROUND", nil, 1))
	local hl = ns.Own(b:CreateTexture(nil, "HIGHLIGHT"))
	l:SetPoint("TOPLEFT")
	l:SetPoint("BOTTOMLEFT")
	r:SetPoint("TOPRIGHT")
	r:SetPoint("BOTTOMRIGHT")
	c:SetPoint("TOPLEFT", l, "TOPRIGHT")
	c:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
	hl:SetAllPoints(b)
	local on, pressed = false, false
	local function State()
		if not on then return end
		local post = (not b:IsEnabled()) and "-Disabled" or (pressed and "-Pressed" or "")
		l:SetAtlas(RED .. "-Left" .. post)
		c:SetAtlas("_" .. RED .. "-Center" .. post)
		r:SetAtlas(RED .. "-Right" .. post)
		local h = b:GetHeight()
		l:SetWidth(ns.AtlasWidth(RED .. "-Left", h))
		r:SetWidth(ns.AtlasWidth(RED .. "-Right", h))
	end
	b:HookScript("OnMouseDown", function() pressed = true; State() end)
	b:HookScript("OnMouseUp", function() pressed = false; State() end)
	b:HookScript("OnEnable", State)
	b:HookScript("OnDisable", State)
	b:HookScript("OnSizeChanged", State)
	local parts = { l, c, r }
	local red = { left = l, center = c, right = r, highlight = hl }
	function red.Paint(modern)
		on = modern
		for _, t in ipairs(parts) do t:SetShown(modern) end
		if modern then
			hl:SetAtlas(RED .. "-Highlight")
			hl:SetBlendMode("ADD")
			State()
		end
		hl:SetAlpha(modern and 1 or 0)
	end
	return red
end

-- Modern: the Social window's straight dark button with a gold frame
-- (common-button-tertiary, its action buttons), stretched over the button;
-- the pressed art while held; on hover the same art again, added on top, as
-- Blizzard draws it. (Its side-tab plate has a cut corner: uneven on a row.)
local PLATE, PLATE_DOWN = "common-button-tertiary-normal", "common-button-tertiary-pressed"

local function TertiaryButton(b)
	local t = ns.Own(b:CreateTexture(nil, "BACKGROUND", nil, 1))
	t:SetAllPoints(b)
	local hl = ns.Own(b:CreateTexture(nil, "HIGHLIGHT"))
	hl:SetAllPoints(b)
	local on = false
	b:HookScript("OnMouseDown", function() if on then t:SetAtlas(PLATE_DOWN) end end)
	b:HookScript("OnMouseUp", function() if on then t:SetAtlas(PLATE) end end)
	local dim = { texture = t, highlight = hl }
	function dim.Paint(modern)
		on = modern
		t:SetShown(modern)
		if modern then
			t:SetAtlas(PLATE)
			hl:SetAtlas(PLATE)
			hl:SetBlendMode("ADD")
		end
		hl:SetAlpha(modern and 0.5 or 0)
	end
	return dim
end

-- Labels: Blizzard's gold / white / grey button fonts; Dark white, grey
-- when disabled (the shared font objects follow the look).
function ns.NewButton(parent, text, w, onClick, primary)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b.pssPrimary = primary
	b:SetSize(w, 22)
	b:SetNormalFontObject(ns.Font(12, "GameFontNormal"))
	b:SetHighlightFontObject(ns.Font(12, "GameFontHighlight"))
	b:SetDisabledFontObject(ns.Font(12, "GameFontDisable"))
	b:SetText(text or "")
	if onClick then b:SetScript("OnClick", onClick) end
	local fill = ns.Own(ns.Fill(b, DARK.control, -6))
	local hover = ns.Own(b:CreateTexture(nil, "HIGHLIGHT"))
	hover:SetAllPoints(b)
	hover:SetColorTexture(DARK.hover[1], DARK.hover[2], DARK.hover[3], DARK.hover[4])
	local edge = ns.PixelBorder(b, DARK.border)
	local red = RedButton(b)
	local dim = TertiaryButton(b)
	b.pssParts = { fill = fill, edge = edge, red = red, tertiary = dim }
	b.pssPaint = function()
		local dark, modern = ns.IsDark(), ns.IsModern()
		ns.ShowArt(b, dark or modern)
		fill:SetShown(dark)
		-- a HIGHLIGHT texture shows on hover by itself: fade it in Blizzard
		hover:SetAlpha(dark and 1 or 0)
		edge:SetShown(dark)
		-- Modern: the Social window's straight gold-framed button; a button
		-- that accepts (b.pssPrimary) is its red one
		red.Paint(modern and b.pssPrimary == true)
		dim.Paint(modern and not b.pssPrimary)
		-- Dark labels are white when enabled (the normal font is gold in Blizzard)
		b:SetNormalFontObject(ns.Font(12, dark and "GameFontHighlight" or "GameFontNormal"))
	end
	ns.OnPaint(b.pssPaint)
	return b
end

-- Dark: a near-black box inset 4 with a grey edge; Blizzard's tick kept
-- and tinted with the accent.
function ns.NewCheck(parent)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	c:SetSize(24, 24)
	local box = ns.Own(c:CreateTexture(nil, "BACKGROUND", nil, -6))
	box:SetPoint("TOPLEFT", 4, -4)
	box:SetPoint("BOTTOMRIGHT", -4, 4)
	box:SetColorTexture(DARK.box[1], DARK.box[2], DARK.box[3], DARK.box[4])
	local edgeHolder = CreateFrame("Frame", nil, c)
	edgeHolder:SetPoint("TOPLEFT", 4, -4)
	edgeHolder:SetPoint("BOTTOMRIGHT", -4, 4)
	local edge = ns.PixelBorder(edgeHolder, DARK.checkBorder)
	local keep = {}
	local tick, tickOff = c:GetCheckedTexture(), c.GetDisabledCheckedTexture and c:GetDisabledCheckedTexture()
	if tick then keep[tick] = true end
	if tickOff then keep[tickOff] = true end
	-- Modern: Blizzard's minimal box and tick (our own textures; the tick
	-- follows the ticked state)
	local mbox = ns.Own(c:CreateTexture(nil, "ARTWORK"))
	mbox:SetAllPoints(c)
	local mtick = ns.Own(c:CreateTexture(nil, "OVERLAY"))
	mtick:SetAllPoints(c)
	local modernOn = false
	local function Tick()
		mtick:SetShown(modernOn and c:GetChecked() and true or false)
		if modernOn then mtick:SetAtlas(c:IsEnabled() and "checkmark-minimal" or "checkmark-minimal-disabled") end
	end
	hooksecurefunc(c, "SetChecked", Tick)
	c:HookScript("OnClick", Tick)
	c:HookScript("OnEnable", Tick)
	c:HookScript("OnDisable", Tick)
	c.pssParts = { box = box, edge = edge, tick = tick, modernBox = mbox, modernTick = mtick }
	ns.OnPaint(function(dark)
		local modern = ns.IsModern()
		modernOn = modern
		-- Modern hides the template's tick too (ours draws it)
		ns.ShowArt(c, dark or modern, not modern and keep or nil)
		box:SetShown(dark)
		edge:SetShown(dark)
		mbox:SetShown(modern)
		if modern then mbox:SetAtlas("checkbox-minimal") end
		Tick()
		if tick then
			if dark then tick:SetVertexColor(ns.Accent()) else tick:SetVertexColor(1, 1, 1) end
		end
	end)
	return c
end

-- Dark: a near-black fill with a grey edge over the template's box.
local function SkinBox(e, size)
	local fill = ns.Own(e:CreateTexture(nil, "BACKGROUND", nil, -6))
	fill:SetPoint("TOPLEFT", -5, 0)
	fill:SetPoint("BOTTOMRIGHT", 0, 0)
	fill:SetColorTexture(DARK.box[1], DARK.box[2], DARK.box[3], DARK.box[4])
	local holder = CreateFrame("Frame", nil, e)
	holder:SetAllPoints(fill)
	local edge = ns.PixelBorder(holder, DARK.border)
	-- Modern: the new search bar's box art, stretched (it is nine-sliced)
	local bar = ns.Own(e:CreateTexture(nil, "BACKGROUND", nil, -5))
	bar:SetAllPoints(fill)
	e.pssParts = { fill = fill, edge = edge, modernBox = bar }
	ns.OnPaint(function(dark)
		local modern = ns.IsModern()
		ns.ShowArt(e, dark or modern)
		fill:SetShown(dark)
		edge:SetShown(dark)
		bar:SetShown(modern)
		if modern then bar:SetAtlas("common-searchbar-a") end
		e:SetFontObject(ns.Font(size or 12, "ChatFontNormal"))
	end)
end

-- A grey hint inside an empty box (alpha 0.4, faded with SetAlpha)
local function BoxHint(e, text, size, x, white)
	local fs = ns.NewText(e, size)
	fs:SetPoint("LEFT", e, "LEFT", x, 0)
	if white then fs:SetTextColor(1, 1, 1) end
	fs:SetAlpha(0.4)
	fs:SetText(text or "")
	return fs
end

function ns.NewEditBox(parent, w, maxLetters, hint)
	local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	e:SetSize(w, 20)
	e:SetAutoFocus(false)
	if maxLetters then e:SetMaxLetters(maxLetters) end
	SkinBox(e)
	if hint then
		local fs = BoxHint(e, hint, 12, 2)
		e:HookScript("OnTextChanged", function(self) fs:SetShown((self:GetText() or "") == "") end)
		e.hint = fs
	end
	return e
end

function ns.NewNumberBox(parent, w)
	local e = ns.NewEditBox(parent, w)
	e:SetNumeric(true)
	e:SetJustifyH("CENTER")
	return e
end

-- commit on Enter and focus loss, once (ClearFocus fires focus loss again)
function ns.OnCommit(e, commit, refresh)
	local busy
	local function run(self)
		if busy then return end
		busy = true
		commit(self:GetText())
		self:ClearFocus()
		refresh()
		busy = false
	end
	e:SetScript("OnEnterPressed", run)
	e:SetScript("OnEditFocusLost", run)
	e:SetScript("OnEscapePressed", function(self) self:ClearFocus(); refresh() end)
end

-- A search box: a magnifier, a grey hint while empty and a clear button
-- while not. onChange(text) runs as you type; Escape clears it.
function ns.NewSearchBox(parent, w, hint, onChange)
	local eb = ns.NewEditBox(parent, w, 128)
	eb:SetTextInsets(16, 18, 0, 0)
	local icon = ns.Own(eb:CreateTexture(nil, "OVERLAY"))
	icon:SetSize(12, 12)
	icon:SetPoint("LEFT", eb, "LEFT", 2, 0)
	ns.OnPaint(function()
		-- Modern: the new search bar's own magnifier
		if ns.IsModern() then
			icon:SetAtlas("common-searchbar-icon-a")
			icon:SetAlpha(1)
		else
			icon:SetAtlas("common-search-magnifyingglass")
			icon:SetAlpha(0.6)
		end
	end)
	local text = BoxHint(eb, hint, 11, 18, true)
	local clear = CreateFrame("Button", nil, eb)
	clear:SetSize(14, 14)
	clear:SetPoint("RIGHT", eb, "RIGHT", -2, 0)
	local x = clear:CreateTexture(nil, "ARTWORK")
	x:SetAllPoints()
	x:SetAtlas("common-search-clearbutton")
	x:SetAlpha(0.6)
	clear:SetScript("OnEnter", function() x:SetAlpha(1) end)
	clear:SetScript("OnLeave", function() x:SetAlpha(0.6) end)
	clear:SetScript("OnClick", function() eb:SetText(""); eb:ClearFocus() end)
	clear:Hide()
	eb:SetScript("OnTextChanged", function(self)
		local t = self:GetText() or ""
		text:SetShown(t == "")
		clear:SetShown(t ~= "")
		if onChange then onChange(t) end
	end)
	eb:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
	eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	eb.hint, eb.clear = text, clear
	return eb
end

-- A multi-line text box that scrolls: an inset panel, a scroll frame and a
-- multi-line edit box that follows the width and keeps the cursor in view.
-- pad: the scroll frame's inset (4 or 6); the bar takes 18 more on the right.
-- Place ta (a panel) yourself; set the edit box's own scripts after.
function ns.NewTextArea(parent, size, maxLetters, pad)
	pad = pad or 4
	local ta = ns.NewPanel(parent, true)
	local sf = ns.NewScrollFrame(ta)
	sf:SetPoint("TOPLEFT", ta, "TOPLEFT", pad, -pad)
	sf:SetPoint("BOTTOMRIGHT", ta, "BOTTOMRIGHT", -(pad + 18), pad)
	local eb = CreateFrame("EditBox", nil, sf)
	eb:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, 0)
	eb:SetWidth(300)
	eb:SetMultiLine(true)
	eb:SetAutoFocus(false)
	if maxLetters then eb:SetMaxLetters(maxLetters) end
	eb:SetFontObject(ns.Font(size or 11, "ChatFontNormal"))
	sf:SetScrollChild(eb)
	sf:SetScript("OnSizeChanged", function(_, w) if w and w > 0 then eb:SetWidth(w) end end)
	eb:SetScript("OnCursorChanged", function(_, _, cy, _, h)
		local top, view = sf:GetVerticalScroll(), sf:GetHeight()
		cy, h = -(cy or 0), h or 0
		if cy < top then
			sf:SetVerticalScroll(cy)
		elseif view > 0 and cy + h > top + view then
			sf:SetVerticalScroll(cy + h - view)
		end
	end)
	ta:EnableMouse(true)
	ta:SetScript("OnMouseDown", function() if eb:IsEnabled() then eb:SetFocus() end end)
	ta.edit, ta.scroll = eb, sf
	return ta
end

-- A tab page or a pane. Blizzard: the inset frame art. Modern: no frame (a
-- page on the window's black under a thin divider; an inset box as the
-- Social list's dark card). Dark: a flat fill (darker when inset) with a
-- grey edge.
function ns.NewPanel(parent, inset)
	local p = CreateFrame("Frame", nil, parent)
	local ok, art = pcall(CreateFrame, "Frame", nil, p, "InsetFrameTemplate")
	if ok and art then
		art:SetAllPoints(p)
		art:SetFrameLevel(p:GetFrameLevel())
		art:EnableMouse(false)
	else
		art = nil
	end
	local fill = ns.Fill(p, inset and DARK.inset or DARK.panel, -6)
	local edge = ns.PixelBorder(p, DARK.border)
	-- Modern: a page sits on the window's black with the Social window's thin
	-- divider along its top; a pane or box is the Social list's dark card
	local card = ns.Own(p:CreateTexture(nil, "BACKGROUND", nil, -5))
	card:SetAllPoints(p)
	local divider = ns.Own(p:CreateTexture(nil, "ARTWORK"))
	divider:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 1)
	divider:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 1)
	divider:SetHeight(3)
	p.pssParts = { fill = fill, edge = edge, art = art, card = card, divider = divider }
	ns.OnPaint(function(dark)
		local modern = ns.IsModern()
		local useDark = dark or (not art and not modern)
		fill:SetShown(useDark)
		edge:SetShown(useDark)
		if art then art:SetShown(not useDark and not modern) end
		card:SetShown(modern and inset == true)
		divider:SetShown(modern and not inset)
		if modern then
			card:SetAtlas("friends-card-default")
			divider:SetAtlas("perks-divider-short")
		end
	end)
	return p
end

-- A scroll frame (ScrollFrameTemplate where the client has it, else the
-- older UIPanelScrollFrameTemplate). Dark: the bar's arrows and track
-- faded, the thumb a 4 px light strip.
local BAR_BUTTONS = { "Back", "Forward", "ScrollUpButton", "ScrollDownButton" }

function ns.NewScrollFrame(parent)
	local ok, sf = pcall(CreateFrame, "ScrollFrame", nil, parent, "ScrollFrameTemplate")
	if not (ok and sf) then sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate") end
	local bar = sf.ScrollBar
	if type(bar) ~= "table" then return sf end
	-- new bars: Back, Forward, Track with a Thumb frame; old: up / down
	-- buttons, track textures on the bar and a thumb texture
	local thumbFrame = bar.Track and bar.Track.Thumb
	local thumbTex = not thumbFrame and bar.GetThumbTexture and bar:GetThumbTexture()
	local strip = ns.Own(bar:CreateTexture(nil, "OVERLAY", nil, 7))
	strip:SetColorTexture(DARK.thumb[1], DARK.thumb[2], DARK.thumb[3], DARK.thumb[4])
	strip:SetWidth(4)
	local anchor = thumbFrame or thumbTex
	if anchor then
		strip:SetPoint("TOP", anchor, "TOP")
		strip:SetPoint("BOTTOM", anchor, "BOTTOM")
	end
	local keep = thumbTex and { [thumbTex] = true } or nil
	ns.OnPaint(function(dark)
		for _, k in ipairs(BAR_BUTTONS) do
			if bar[k] then bar[k]:SetAlpha(dark and 0 or 1) end
		end
		ns.ShowArt(bar, dark, keep)
		if bar.Track then ns.ShowArt(bar.Track, dark) end
		if thumbFrame then ns.ShowArt(thumbFrame, dark) end
		if thumbTex then thumbTex:SetAlpha(dark and 0 or 1) end
		strip:SetShown(dark and anchor ~= nil)
	end)
	return sf
end

------------------------------------------------------------------------
-- Tabs: the port's tab row. Blizzard: a Blizzard top tab where the client
-- has one, else the Dark plate in Blizzard's font. Dark: a dark plate,
-- the label at half strength unless selected; the selected tab gets a faint
-- wash and a one-pixel underline in the accent. Labels fade with SetAlpha,
-- never text colour alpha (that leaves the shadow as a second label).
------------------------------------------------------------------------
local TAB_TEMPLATES = { "PanelTopTabButtonTemplate", "TabButtonTemplate" }
-- the template's art for an unselected and a selected tab
local TAB_IDLE = { "Left", "Middle", "Right" }
local TAB_ACTIVE = { "LeftActive", "MiddleActive", "RightActive" }
local TAB_DIM = 0.7

function ns.NewTab(parent, text, onClick)
	local tab
	for _, t in ipairs(TAB_TEMPLATES) do
		local ok, f = pcall(CreateFrame, "Button", nil, parent, t)
		if ok and f then
			tab = f
			tab.pssTemplate = t
			break
		end
	end
	tab = tab or CreateFrame("Button", nil, parent)
	tab:SetNormalFontObject(ns.Font(11, "GameFontNormalSmall"))
	tab:SetHighlightFontObject(ns.Font(11, "GameFontHighlightSmall"))
	tab:SetDisabledFontObject(ns.Font(11, "GameFontHighlightSmall"))
	tab:SetText(text)
	if tab.pssTemplate then
		-- the template resizes itself on show and on display changes to its
		-- own padding (that cut "Player Ignore List" short): our row sizes it
		tab:SetScript("OnShow", nil)
		tab:SetScript("OnEvent", nil)
		tab:UnregisterAllEvents()
	end
	local label = tab:GetFontString()
	label:SetWidth(0)
	tab:SetSize(label:GetStringWidth() + 32, 24)
	tab:SetScript("OnClick", onClick)
	local plate = ns.Own(ns.Fill(tab, DARK.tab, -6))
	local wash = ns.Own(tab:CreateTexture(nil, "ARTWORK", nil, 7))
	wash:SetAllPoints()
	wash:SetColorTexture(DARK.tabWash[1], DARK.tabWash[2], DARK.tabWash[3], DARK.tabWash[4])
	wash:SetBlendMode("ADD")
	local line = ns.Own(tab:CreateTexture(nil, "OVERLAY", nil, 7))
	ns.NoSnap(line)
	line:SetPoint("BOTTOMLEFT")
	line:SetPoint("BOTTOMRIGHT")
	tab.pssWash, tab.pssLine, tab.pssPlate = wash, line, plate
	-- Modern: the buttons' straight gold-framed plate; brighter on hover, and
	-- kept brighter (the same art added on top) on the selected tab
	local side = ns.Own(tab:CreateTexture(nil, "BACKGROUND", nil, 1))
	side:SetAllPoints(tab)
	local sideLit = ns.Own(tab:CreateTexture(nil, "BACKGROUND", nil, 2))
	sideLit:SetAllPoints(tab)
	sideLit:SetBlendMode("ADD")
	local sideHover = ns.Own(tab:CreateTexture(nil, "HIGHLIGHT"))
	sideHover:SetAllPoints(tab)
	sideHover:SetBlendMode("ADD")
	tab.pssSide = { plate = side, lit = sideLit, hover = sideHover }
	ns.OnPaint(function(dark)
		local modern = ns.IsModern()
		local plain = dark or not tab.pssTemplate
		ns.ShowArt(tab, plain or modern)
		plate:SetShown(plain and not modern)
		side:SetShown(modern)
		sideHover:SetAlpha(modern and 0.3 or 0)
		if modern then
			side:SetAtlas(PLATE)
			sideLit:SetAtlas(PLATE)
			sideHover:SetAtlas(PLATE)
		end
		if plain then tab:SetNormalFontObject(ns.Font(11, "GameFontHighlightSmall")) end
		ns.SetTabSelected(tab, tab.pssSelected)
	end)
	return tab
end

function ns.SetTabSelected(tab, selected)
	selected = selected and true or false
	tab.pssSelected = selected
	local modern = ns.IsModern()
	local plain = (ns.IsDark() or not tab.pssTemplate) and not modern
	tab.pssWash:SetShown(plain and selected)
	tab.pssLine:SetShown(plain and selected)
	tab.pssSide.lit:SetShown(modern and selected)
	tab.pssSide.lit:SetAlpha(0.6)
	tab.pssLine:SetColorTexture(ns.Accent())
	-- one physical pixel, as the port's underline
	tab.pssLine:SetHeight(ns.OnePixel(tab))
	local fs = tab:GetFontString()
	-- Blizzard's PanelTemplates_SelectTab / DeselectTab move a top tab's
	-- label 4 / 8 px below centre (for their 32 px tabs, art 24 at the
	-- bottom), which put ours near the bottom edge: the label and the active
	-- art are set here instead. Our tabs are 24 high, all art.
	fs:ClearAllPoints()
	if modern then
		fs:SetPoint("CENTER", tab, "CENTER", 0, 0)
		fs:SetAlpha(1)
		tab:SetNormalFontObject(ns.Font(11, selected and "GameFontHighlightSmall" or "GameFontNormalSmall"))
	elseif plain then
		fs:SetPoint("CENTER", tab, "CENTER", 0, 0)
		-- unselected: dimmed but easy to read on the dark plate (Dan, 2026-10-07)
		fs:SetAlpha(selected and 1 or TAB_DIM)
	else
		fs:SetPoint("CENTER", tab, "CENTER", 0, selected and 0 or -1)
		fs:SetAlpha(1)
		for _, k in ipairs(TAB_IDLE) do
			if tab[k] then tab[k]:SetShown(not selected) end
		end
		for _, k in ipairs(TAB_ACTIVE) do
			if tab[k] then tab[k]:SetShown(selected) end
		end
		tab:SetNormalFontObject(ns.Font(11, selected and "GameFontHighlightSmall" or "GameFontNormalSmall"))
	end
end
