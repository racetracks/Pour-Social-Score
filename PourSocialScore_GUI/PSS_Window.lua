------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - WINDOW
--
-- The Pour Social Score window, 960 x 494. /pss gui (and /pss ui) and the
-- Addon Compartment open it (M.PSS_OpenWindow); with the option
-- openWithFriends it opens beside the Friends or Social window and closes
-- with it (M.PSS_WindowDock / M.PSS_WindowUndock, 3.4.0.23). Dragged
-- elsewhere it remembers the place (Libraries M.PSS_UIPlace) and the tab
-- shown (M.PSS_UITab).
--
-- Six tabs (M.PSS_UI_TABS); each is built on first open by its builder,
-- ns.TabBuilders[key](page), which returns the function that redraws it.
-- A tab without a builder yet shows a note. Back / forward arrows above the
-- tabs (and mouse buttons 4 / 5) step through the views shown; the line by
-- them names the view, each part but the last a link back to it. Escape
-- goes up one level and closes the window from the top. A tab click, even
-- on the tab shown, puts the tab back to how it opens.
--
-- A page with sub-views gives navState() (its view now), navApply(view)
-- (show it again), navUp() (one level up; true if it went), navTitle(view)
-- (for the line), navReset() (as it opens) and navClose() (closes an
-- overlay; true if one was open).
--
-- Blizzard look: a Blizzard window frame (ButtonFrameTemplate) behind our
-- frame, with its own art only. Dark look: a flat fill, a dark title
-- strip, a thin frame and a plain close glyph.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local WIN_W, WIN_H = 960, 494
local PLACE = "PSS_Window"
local TAB_H, NAV_H = 24, 20
local TOP = -32
-- the arrows' line first, the tab row under it (Dan, 3.4.0.24)
local NAV_Y = TOP
local TAB_Y = TOP - NAV_H - 4
-- for what sits in the tab row (the Options search box)
ns.TAB_ROW_Y = TAB_Y
local STREAKS = "_UI-Frame-TopTileStreaks"
local SEP = "  >  "
local TABS = M.PSS_UI_TABS
local EVENTS = M.PSS_UI_EVENTS_TAB

-- the tabs' builders, keyed by M.PSS_UI_TABS key (the tab files add theirs)
ns.TabBuilders = ns.TabBuilders or {}


local win, nav, curTab
local applying = false

local function SavePlace()
	local point, _, relPoint, x, y = win:GetPoint(1)
	if point then M.PSS_SetUIPlace(PLACE, point, relPoint, ns.Round(x), ns.Round(y)) end
end

local function RestorePlace()
	win:ClearAllPoints()
	local point, relPoint, x, y = M.PSS_UIPlace(PLACE)
	if point then
		win:SetPoint(point, UIParent, relPoint, x, y)
	else
		win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

-- The Dark art: fill, title strip and frame. The frame is Blizzard's
-- AdventureMap_TopBorder atlas where the client has it, else a thin border.
local function DarkFrame()
	local f = CreateFrame("Frame", nil, win)
	f:SetAllPoints(win)
	f:SetFrameLevel(win:GetFrameLevel())
	ns.Fill(f, ns.DARK.window, -6)
	local bar = f:CreateTexture(nil, "BACKGROUND", nil, -5)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(ns.TITLE_H)
	local c = ns.DARK.titleBar
	bar:SetColorTexture(c[1], c[2], c[3], c[4])
	if ns.HasAtlas("AdventureMap_TopBorder") then
		local edge = CreateFrame("Frame", nil, f)
		edge:SetAllPoints(f)
		edge:SetFrameLevel(win:GetFrameLevel() + 6)
		local t = edge:CreateTexture(nil, "OVERLAY", nil, 7)
		t:SetAllPoints(edge)
		t:SetAtlas("AdventureMap_TopBorder")
	else
		ns.PixelBorder(f, ns.DARK.border)
	end
	return f
end

-- Dark close: Blizzard's close glyph, no plate, brighter on hover
local function DarkClose()
	local b = CreateFrame("Button", nil, win)
	b:SetSize(24, 24)
	b:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
	b:SetFrameLevel(win:GetFrameLevel() + 8)
	local t = b:CreateTexture(nil, "ARTWORK")
	t:SetSize(14, 14)
	t:SetPoint("CENTER", b, "CENTER", -2, 0)
	if ns.HasAtlas("uitools-icon-close") then
		t:SetAtlas("uitools-icon-close")
	else
		t:SetTexture("Interface\\Buttons\\UI-StopButton")
	end
	local c, h = ns.DARK.close, ns.DARK.closeHover
	t:SetVertexColor(c[1], c[2], c[3], c[4])
	b:SetScript("OnEnter", function() t:SetVertexColor(h[1], h[2], h[3], h[4]) end)
	b:SetScript("OnLeave", function() t:SetVertexColor(c[1], c[2], c[3], c[4]) end)
	b:SetScript("OnClick", function() win:Hide() end)
	return b
end

------------------------------------------------------------------------
-- Tabs and pages
------------------------------------------------------------------------
local function BuildTab(id)
	local page = win.pages[id]
	local build = ns.TabBuilders[TABS[id].key]
	if build and not page.refresh then
		-- a tab that fails to build still reports its error and is selected;
		-- it is built again on the next click
		local ok, refresh = xpcall(function() return build(page) end, geterrorhandler())
		if ok then
			page.refresh = refresh
			if page.note then page.note:Hide() end
		end
	end
	return page
end

local function SelectTab(id)
	local page = BuildTab(id)
	curTab = id
	for i, tab in ipairs(win.tabs) do
		ns.SetTabSelected(tab, i == id)
		win.pages[i]:SetShown(i == id)
	end
	if page.refresh then page.refresh() end
	M.PSS_SetUITab(id)
end

-- redraw the tab shown (the others redraw when selected)
function ns.RefreshTab()
	if not (win and win:IsShown()) then return end
	local page = win.pages[curTab]
	if page and page.refresh then page.refresh() end
end

------------------------------------------------------------------------
-- Back / forward (the steps are kept by Libraries M.PSS_NavNew)
------------------------------------------------------------------------
local function ShownState()
	local page = win.pages[curTab]
	return curTab, page.navState and page.navState() or nil
end

local ResetTab

-- a button over each part of the line but the last (the view shown),
-- underlined in the accent on hover
local function Crumb(i)
	local c = win.crumbs[i]
	if c then return c end
	c = CreateFrame("Button", nil, win)
	c:SetHeight(NAV_H)
	local hl = c:CreateTexture(nil, "HIGHLIGHT")
	ns.NoSnap(hl)
	hl:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 2)
	hl:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 2)
	c.line = hl
	c:SetScript("OnClick", function(self) self.go() end)
	c:SetScript("OnEnter", function(self) ns.Tip(self, self.tipText) end)
	c:SetScript("OnLeave", ns.HideTip)
	win.crumbs[i] = c
	return c
end

local function PlaceCrumbs(parts)
	local text = ""
	for i, part in ipairs(parts) do
		if i < #parts then
			local c = Crumb(i)
			win.measure:SetText(text)
			local left = text == "" and 0 or win.measure:GetStringWidth()
			win.measure:SetText(part.text)
			c:ClearAllPoints()
			c:SetPoint("LEFT", win.where, "LEFT", left, 0)
			c:SetWidth(math.max(8, win.measure:GetStringWidth()))
			local r, g, b = ns.Accent()
			c.line:SetColorTexture(r, g, b, 0.9)
			c.line:SetHeight(ns.OnePixel(c))
			c.go = part.go
			c.tipText = "Back to " .. part.text .. "."
			c:Show()
		end
		text = text .. (i > 1 and SEP or "") .. part.text
	end
	for i = #parts, #win.crumbs do win.crumbs[i]:Hide() end
	win.where:SetText(text)
end

local function UpdateNav()
	win.back:SetEnabled(nav:CanBack())
	win.forward:SetEnabled(nav:CanForward())
	local tab, view = ShownState()
	local page = win.pages[tab]
	local parts = { { text = TABS[tab].text, go = function() ResetTab(tab) end } }
	if view ~= nil and page.navTitle then parts[2] = { text = page.navTitle(view) } end
	PlaceCrumbs(parts)
end

-- After the user changed the view: a new step (dropping any forward steps).
function ns.NavRecord()
	if applying or not win then return end
	nav:Record(ShownState())
	UpdateNav()
end

local function Go(st)
	if not st then return end
	applying = true
	local ok, err = pcall(function()
		local page = win.pages[st.tab]
		if page.navClose then page.navClose() end
		SelectTab(st.tab)
		if page.navApply then page.navApply(st.view) end
	end)
	applying = false
	-- a view that is gone (a removed guild) leaves the page as it is
	local tab, view = ShownState()
	if tab ~= st.tab or view ~= st.view then nav:Replace(tab, view) end
	UpdateNav()
	if not ok then geterrorhandler()(err) end
end

-- A tab as it opens: every view over it closed, nothing selected.
function ResetTab(id)
	local page = win.pages[id]
	if page.navClose then page.navClose() end
	if page.navUp then
		for _ = 1, 10 do if not page.navUp() then break end end
	end
	if page.navReset then page.navReset() end
	SelectTab(id)
	ns.NavRecord()
end
ns.ResetTab = function(id) ResetTab(id or curTab) end

-- The Events tab, built if need be; prepare() then sets what it shows, as
-- a step of its own (pies and View Events).
function ns.ShowEventsTab(prepare)
	if not win then return end
	local page = BuildTab(EVENTS)
	if not page.refresh then return end
	local shown = win.pages[curTab]
	if shown.navClose then shown.navClose() end
	if prepare then prepare() end
	SelectTab(EVENTS)
	ns.NavRecord()
end

-- Back closes an overlay first (a picker), then steps back.
function ns.NavBack()
	local page = win.pages[curTab]
	if page.navClose and page.navClose() then UpdateNav() return end
	Go(nav:Back())
end

function ns.NavForward()
	Go(nav:Forward())
end

-- Escape: up one level; false at the top (the window closes). Events
-- opened from another tab (a pie, View Events) go back to that tab.
function ns.NavUp()
	local page = win.pages[curTab]
	if page.navClose and page.navClose() then UpdateNav() return true end
	if page.navUp and page.navUp() then
		ns.NavRecord()
		return true
	end
	if curTab == EVENTS then
		local st = nav:BackToOther(EVENTS)
		if st then
			Go(st)
			return true
		end
	end
	return false
end

-- Escape: a helper frame in UISpecialFrames shown with the window; Escape
-- hides it, and that steps up one level (shown again) or closes the window.
-- A popup or menu open at that Escape takes it instead (ns.EscapeTaken).
local function EscapeFrame()
	local esc = CreateFrame("Frame", "PSS_WindowEscape", UIParent)
	esc:Hide()
	UISpecialFrames[#UISpecialFrames + 1] = "PSS_WindowEscape"
	win:HookScript("OnShow", function() esc:Show() end)
	win:HookScript("OnHide", function() esc:Hide() end)
	esc:SetScript("OnHide", function(self)
		if not win:IsShown() then return end
		if ns.EscapeTaken() then
			self:Show()
		elseif ns.NavUp() then
			self:Show()
		else
			win:Hide()
		end
	end)
end

-- mouse buttons 4 / 5 over the window; listened to only while it shows
local function OnMouseButton(self, _, button)
	if button ~= "Button4" and button ~= "Button5" then return end
	if not self:IsMouseOver() then return end
	if button == "Button4" then ns.NavBack() else ns.NavForward() end
end

local function BuildTabs()
	win.tabs, win.pages = {}, {}
	local prev
	for i, t in ipairs(TABS) do
		-- (the tab shown too: back to how it opens)
		local tab = ns.NewTab(win, t.text, function() ResetTab(i) end)
		if prev then
			tab:SetPoint("LEFT", prev, "RIGHT", 2, 0)
		else
			tab:SetPoint("TOPLEFT", win, "TOPLEFT", 10, TAB_Y)
		end
		win.tabs[i], prev = tab, tab

		local page = ns.NewPanel(win)
		page:SetPoint("TOPLEFT", win, "TOPLEFT", 10, TOP - TAB_H - NAV_H - 8)
		page:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 10)
		page:Hide()
		-- until its stage is built
		local note = ns.NewText(page, 12)
		note:SetPoint("CENTER")
		note:SetText(t.text .. " comes in a later 3.4.0 build.")
		note:SetAlpha(0.7)
		page.note = note
		win.pages[i] = page
	end

	-- [<] [>]  Guild Ignore List  >  Members of <guild>
	win.back = ns.NewButton(win, "<", 26, ns.NavBack)
	win.back:SetHeight(NAV_H)
	win.back:SetPoint("TOPLEFT", win, "TOPLEFT", 10, NAV_Y)
	ns.TipOn(win.back, win.back, "Back (mouse button 4). Escape goes up one level.")
	win.forward = ns.NewButton(win, ">", 26, ns.NavForward)
	win.forward:SetHeight(NAV_H)
	win.forward:SetPoint("LEFT", win.back, "RIGHT", 4, 0)
	ns.TipOn(win.forward, win.forward, "Forward (mouse button 5).")
	win.where = ns.NewText(win, 11)
	win.where:SetPoint("LEFT", win.forward, "RIGHT", 10, 0)
	win.where:SetAlpha(0.9)
	-- widths of the parts (never shown)
	win.measure = ns.NewText(win, 11)
	win.measure:Hide()
	win.crumbs = {}
end

local function Build()
	win = CreateFrame("Frame", "PSS_Window", UIParent)
	win:Hide()
	win:SetSize(WIN_W, WIN_H)
	win:SetFrameStrata(M.PSS_FrameStrataName())
	win:SetToplevel(true)
	win:SetClampedToScreen(true)
	win:EnableMouse(true)
	win:SetMovable(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePlace()
	end)

	local blizz = ns.NewFrameArt(win)
	local dark = DarkFrame()
	-- The title and the close buttons sit on a frame above the frame art:
	-- the Blizzard frame's border (its NineSlice) has a fixed level of about
	-- 500, so anything lower is drawn under its metal edge and corners.
	local chrome = CreateFrame("Frame", nil, win)
	chrome:SetAllPoints(win)
	local top = win:GetFrameLevel() + 8
	if blizz and blizz.NineSlice and blizz.NineSlice.GetFrameLevel then
		top = math.max(top, blizz.NineSlice:GetFrameLevel() + 10)
	end
	chrome:SetFrameLevel(top)
	win.chrome = chrome
	local blizzClose = CreateFrame("Button", nil, chrome, "UIPanelCloseButton")
	blizzClose:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
	blizzClose:SetFrameLevel(top + 1)
	-- (the template's own click hides its parent: ours closes the window)
	blizzClose:SetScript("OnClick", function() win:Hide() end)
	local darkClose = DarkClose()
	darkClose:SetParent(chrome)
	darkClose:SetFrameLevel(top + 1)

	local title = ns.NewText(chrome, 13, "GameFontNormal")
	title:SetPoint("TOP", win, "TOP", 0, -6)
	title:SetText("Pour Social Score")
	win.title = title
	-- each look's parts, so the look shown can be checked
	win.art = { blizzard = blizz, dark = dark, blizzardClose = blizzClose, darkClose = darkClose }

	-- Modern: the same metal frame on black, as Blizzard's new Social window
	-- (which sets its background to black)
	-- (the frame art's own black: ns.NewFrameArt)
	local black = blizz and blizz.pssBlack
	win.art.black = black
	-- Modern: the band behind the arrows' line and the tabs under it is the
	-- frame's stone with its streaks over it, as the AddOns list draws its
	-- top (Dan, 2026-10-08); the streaks alone are a dark overlay and show
	-- nothing on black. The black starts where the pages do.
	-- Classic and Modern: the streaks reach down past the tab row to the
	-- pages (the template's own stop 43 px down).
	local band, streaks
	local BAND_H = -TOP + TAB_H + NAV_H + 8 - 21
	if blizz then
		streaks = ns.Own(blizz:CreateTexture(nil, "BORDER", nil, 1))
		streaks:SetPoint("TOPLEFT", blizz, "TOPLEFT", 6, -21)
		streaks:SetPoint("TOPRIGHT", blizz, "TOPRIGHT", -2, -21)
		streaks:SetHeight(BAND_H)
		band = ns.Own(blizz:CreateTexture(nil, "BACKGROUND", nil, -4))
		band:SetPoint("TOPLEFT", blizz, "TOPLEFT", 2, -21)
		band:SetPoint("TOPRIGHT", blizz, "TOPRIGHT", -2, -21)
		band:SetHeight(BAND_H)
		band:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
		band:SetHorizTile(true)
		band:SetVertTile(true)
	end
	win.art.band, win.art.streaks = band, streaks
	ns.OnPaint(function(isDark)
		if black then
			local modern = ns.IsModern()
			band:SetShown(modern)
			-- ours where the client has the art, else the template's own
			local own = ns.HasAtlas(STREAKS)
			streaks:SetShown(own)
			if own then
				streaks:SetAtlas(STREAKS)
				streaks:SetHorizTile(true)
			end
			if blizz.TopTileStreaks and blizz.TopTileStreaks.SetAlpha then blizz.TopTileStreaks:SetAlpha(own and 0 or 1) end
		end
		-- a client without any Blizzard frame template falls back to Dark art
		local useDark = isDark or not blizz
		dark:SetShown(useDark)
		if blizz then blizz:SetShown(not useDark) end
		darkClose:SetShown(useDark)
		blizzClose:SetShown(not useDark)
	end)

	EscapeFrame()
	BuildTabs()
	nav = M.PSS_NavNew()
	-- the shown tab is redrawn each time the window opens; core events are
	-- listened to only while it shows, so each page first marks what may
	-- have changed while it was closed
	win:HookScript("OnShow", function(self)
		ns.ListenStart()
		for _, page in ipairs(self.pages) do
			if page.stale then page.stale() end
		end
		ns.RefreshTab()
		-- an unknown event (an older client) is not an error worth showing
		pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_UP")
	end)
	-- closed: the tabs drop what they read (a page's release), and the
	-- memory is given back at the next quiet moment
	win:HookScript("OnHide", function(self)
		self:UnregisterEvent("GLOBAL_MOUSE_UP")
		ns.ListenStop()
		for _, page in ipairs(self.pages) do
			if page.release then page.release() end
		end
		if M.PSS_RequestGC then M.PSS_RequestGC("window closed") end
	end)
	win:SetScript("OnEvent", OnMouseButton)
	SelectTab(M.PSS_UITab())
	ns.NavRecord()

	-- the look and strata: always heard (a rare event, and the kit, popups
	-- and tooltips repaint with it), unlike the tabs' ns.Listen events
	M.Events.Register("OPTION_CHANGED", function(key)
		if key == "frameStrata" then
			win:SetFrameStrata(M.PSS_FrameStrataName())
		elseif key == "uiSkin" or key == "uiFont" then
			ns.Repaint()
			-- the line by the arrows is measured in the font shown
			UpdateNav()
		end
	end)
end

-- /pss gui, /pss ui, the Addon Compartment (core M.PSS_OpenUI); show true
-- opens without toggling. Opened this way the window is at its own place.
function M.PSS_OpenWindow(show)
	if not win then Build() end
	if win:IsShown() and not show then
		win:Hide()
		return
	end
	win.byFriends = nil
	RestorePlace()
	-- fonts other addons shared since the last open join the font choices
	M.PSS_UIFontChoices()
	win:Show()
	win:Raise()
end

-- The Friends or Social window opened (core PSS_BlizzardUI.lua, option
-- openWithFriends): the window sits beside it (x from its right edge) and
-- closes with it. Opened from a command it stays put.
function M.PSS_WindowDock(host, x)
	if not win then Build() end
	win:ClearAllPoints()
	win:SetPoint("TOPLEFT", host or FriendsFrame, "TOPRIGHT", x or 12, -10)
	win.byFriends = true
	M.PSS_UIFontChoices()
	win:Show()
end

function M.PSS_WindowUndock()
	if win and win.byFriends then win:Hide() end
end
