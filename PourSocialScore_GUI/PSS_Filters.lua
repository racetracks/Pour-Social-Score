------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - CHAT FILTERS TAB
--
-- The filters (built-ins first, search, sortable columns) and, for the
-- selected one, a pane with three pages: Summary (counts and the period
-- pie), Event History, and View/Edit Rule (On, description, filter text,
-- Save / Copy / Remove / Reset Count, Test, link converter). Built-ins are
-- read only (On only); a guild rule's blocks are counted on the Guild
-- Ignore List, so it has View/Edit Rule only. With nothing selected the
-- pane shows every filter's totals. Libraries (PSS_FilterView.lua) works
-- out every text and does every change; the core says when filters changed
-- (FILTERS_CHANGED, FILTER_HISTORY_CHANGED) and the tab redraws if it shows.
--
-- A link shift-clicked in chat while one of the tab's boxes is being
-- edited goes there (a post-hook on Blizzard's link insert: Retail 12.x's
-- ChatFrameUtil.InsertLink, else ChatEdit_InsertLink), made the first time
-- the tab opens and doing nothing unless the pane shows.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M
local L = PourSocialScore_NS.L

local DETAIL_W = 380
local TOP_H = 32

local V = M.PSS_FilterListNew()
local sel
local cells, rowBuf, paneRow = {}, {}, {}
local page, list, pane

ns.TabBuilders = ns.TabBuilders or {}

------------------------------------------------------------------------
-- List
------------------------------------------------------------------------
local function Resort()
	local n, countText, empty = V:Resort()
	list:SetSort(V.key, V.asc)
	list:SetCount(n)
	page.count:SetText(countText)
	list:SetEmptyText(empty)
end

local function DrawRow(row, i)
	local r = M.PSS_FilterRow(V.index[i], rowBuf)
	local c = row.cells
	if not r then
		for _, fs in pairs(c) do fs:SetText("") end
		row.sel:Hide()
		return
	end
	M.PSS_FilterRowCells(r, cells)
	c.desc:SetText(cells.desc)
	c.filter:SetText(cells.filter)
	c.state:SetText(cells.state)
	c.blocked:SetText(cells.blocked)
	row.sel:SetShown(r.index == sel)
end

local function RowTip(row, i)
	local r = M.PSS_FilterRow(V.index[i], rowBuf)
	if r then ns.Tip(row, M.PSS_FilterRowTip(r)) end
end

------------------------------------------------------------------------
-- Pane
------------------------------------------------------------------------
local function SetEditable(e, on)
	e:SetEnabled(on)
	e:SetAlpha(on and 1 or 0.5)
end

local Select

local function ConfirmRemove()
	local i = sel
	local text, desc = M.PSS_FilterRemoveText(i)
	if not text then return end
	ns.Confirm({ title = "Remove Rule?", text = text, accept = "Remove", onAccept = function()
		local _, after = M.PSS_FilterRemove(i, desc, sel)
		sel = after
	end })
end

local function Save()
	if M.PSS_FilterSave(sel, pane.descBox:GetText(), pane.filterBox:GetText()) then
		pane.descBox:ClearFocus()
		pane.filterBox:ClearFocus()
	end
end

local function OpenFilterEvents(i)
	if ns.OpenEvents then ns.OpenEvents(page, M.PSS_FilterEventsSpec(i), {}) end
end

-- A row's right-click menu (Libraries M.PSS_FilterMenu): the row is
-- selected first, so each entry acts on the pane's filter as its buttons do.
local function RowAct(i, act, arg)
	if i ~= sel then Select(i) end
	if act == "toggle" then
		M.PSS_SetFilterActive(i, arg and true or false)
	elseif act == "copy" then
		local n = M.PSS_FilterCopy(i)
		if n then Select(n) end
	elseif act == "history" then
		OpenFilterEvents(i)
	elseif act == "resetCount" then
		M.PSS_ResetFilterCount(i)
	elseif act == "resetHistory" then
		M.PSS_ResetFilterHistory(i)
		page.refresh()
	elseif act == "remove" then
		ConfirmRemove()
	end
end

local function BuildPane(parent)
	pane = ns.NewPanel(parent, true)
	pane:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -TOP_H - 4)
	pane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 8)
	pane:SetWidth(DETAIL_W)
	-- nothing selected: every filter's totals (a click on the selected
	-- filter deselects it)
	pane.totals = ns.NewTotals(pane, page, "filters", "Chat Filters", "Select a filter to edit it.", M.PSS_AllFiltersSpec)

	local b = CreateFrame("Frame", nil, pane)
	b:SetAllPoints()
	b:Hide()
	pane.body = b
	pane.heading = ns.NewHeading(b, "")
	pane.heading:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -8)
	pane.heading:SetPoint("RIGHT", b, "RIGHT", -10, 0)
	pane.info = ns.NewText(b, 11)
	pane.info:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -26)
	pane.info:SetPoint("RIGHT", b, "RIGHT", -10, 0)
	pane.info:SetJustifyH("LEFT")

	-- the pages: Summary (counts), Event History, View/Edit Rule (the editor)
	local dp = ns.NewDetailPages(b, -44, "filters")
	pane.pages = dp
	local rule = dp.rule

	-- [x] On   Description [..............]
	local y = -2
	local on = ns.NewCheck(rule)
	on:SetPoint("TOPLEFT", rule, "TOPLEFT", 8, y + 2)
	local onText = ns.NewText(rule, 12)
	onText:SetPoint("LEFT", on, "RIGHT", 0, 0)
	onText:SetText("On")
	ns.TipOn(on, on, "Turns this filter on or off at once.")
	on:SetScript("OnClick", function(self)
		if sel then M.PSS_SetFilterActive(sel, self:GetChecked() and true or false) end
	end)
	pane.onBox = on
	ns.NewLabel(rule, "Description", 74, y - 3)
	local desc = ns.NewEditBox(rule, 200, 100)
	desc:SetPoint("TOPLEFT", rule, "TOPLEFT", 156, y)
	desc:SetPoint("RIGHT", rule, "RIGHT", -12, 0)
	desc:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	desc:SetScript("OnEscapePressed", function(self) self:ClearFocus(); ns.ShowFilterDetail() end)
	pane.descBox = desc
	y = y - 28

	-- Filter (?) and its text, several lines
	local fl = ns.NewLabel(rule, "Filter", 12, y)
	local help = ns.NewButton(rule, "?", 22)
	help:SetHeight(18)
	help:SetPoint("LEFT", fl, "RIGHT", 6, 0)
	ns.TipOn(help, help, L["TIP_1"])
	pane.lock = ns.NewText(rule, 11)
	pane.lock:SetPoint("LEFT", help, "RIGHT", 8, 0)
	pane.lock:SetAlpha(0.5)
	pane.lock:SetText("Built-in: read only. Copy it to edit.")
	y = y - 18
	local ff = ns.NewTextArea(rule, 11, 1000)
	ff:SetPoint("TOPLEFT", rule, "TOPLEFT", 10, y)
	ff:SetPoint("RIGHT", rule, "RIGHT", -10, 0)
	ff:SetHeight(58)
	-- a long filter scrolls inside the box instead of spilling over the
	-- buttons below; the view follows the cursor
	local fbox, fscroll = ff.edit, ff.scroll
	fbox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); ns.ShowFilterDetail() end)
	pane.filterBox, pane.filterScroll = fbox, fscroll
	y = y - 62

	-- [Save Filter] [Copy] [Remove] [Reset Count]
	local save = ns.NewButton(rule, "Save Filter", 92, Save)
	save:SetPoint("TOPLEFT", rule, "TOPLEFT", 10, y)
	ns.TipOn(save, save, "Saves the description and filter text.")
	pane.saveButton = save
	local copy = ns.NewButton(rule, "Copy", 70, function()
		local n = M.PSS_FilterCopy(sel)
		if n then Select(n) end
	end)
	copy:SetPoint("LEFT", save, "RIGHT", 6, 0)
	ns.TipOn(copy, copy, "Makes an editable custom copy (starts Off).")
	pane.copyButton = copy
	local remove = ns.NewButton(rule, "Remove", 76, ConfirmRemove)
	remove:SetPoint("LEFT", copy, "RIGHT", 6, 0)
	pane.removeButton = remove
	local resetCount = ns.NewButton(rule, "Reset Count", 100, function()
		if sel then M.PSS_ResetFilterCount(sel) end
	end)
	resetCount:SetPoint("LEFT", remove, "RIGHT", 6, 0)
	ns.TipOn(resetCount, resetCount, "The Blocked count starts again from 0 (the block history stays).")
	pane.resetCount = resetCount
	y = y - 28

	-- Test [chat line ............] [Test] BLOCKED / PASSED
	ns.NewLabel(rule, "Test", 12, y - 3)
	local test = ns.NewEditBox(rule, 170, 255)
	test:SetPoint("TOPLEFT", rule, "TOPLEFT", 56, y)
	local result = ns.NewText(rule, 12)
	local function RunTest()
		result:SetText(M.PSS_FilterTestText(fbox:GetText(), test:GetText()))
	end
	test:SetScript("OnTextChanged", function() result:SetText("") end)
	test:SetScript("OnEnterPressed", RunTest)
	test:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	ns.TipOn(test, test, L["TIP_2"])
	local testButton = ns.NewButton(rule, "Test", 50, RunTest)
	testButton:SetPoint("LEFT", test, "RIGHT", 6, 0)
	result:SetPoint("LEFT", testButton, "RIGHT", 8, 0)
	pane.testBox, pane.testButton, pane.result = test, testButton, result
	y = y - 26

	-- Link [shift-click a link] -> its [tag], selected to copy
	ns.NewLabel(rule, "Link", 12, y - 3)
	local link = ns.NewEditBox(rule, 200, 255)
	link:SetPoint("TOPLEFT", rule, "TOPLEFT", 56, y)
	link:SetPoint("RIGHT", rule, "RIGHT", -12, 0)
	link:SetScript("OnEnterPressed", function(self)
		self:SetText(M.PSS_ConvertChatLink(self:GetText()))
		self:HighlightText()
	end)
	link:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	ns.TipOn(link, link, "Click here, then shift-click a link in chat (or paste one and press Enter): it turns into the filter [tag], selected to copy. Shift-clicking a link while the filter box is being edited puts the [tag] there directly.")
	pane.linkBox = link

	pane.counts = ns.NewText(dp.summary, 11)
	pane.counts:SetPoint("TOPLEFT", dp.summary, "TOPLEFT", 10, -6)
	pane.counts:SetPoint("RIGHT", dp.summary, "RIGHT", -10, 0)
	pane.counts:SetJustifyH("LEFT")
	pane.summary = ns.NewSummary(dp.summary, page, -30)
	pane.sumSpec = { specFn = M.PSS_FilterEventsSpec }

	-- Event History: the filter's block history, the whole page
	pane.hist = ns.NewHistory(dp.history, -2, { names = true, empty = "Nothing blocked by this filter yet.",
		open = OpenFilterEvents })
	-- no buttons under it: the list goes to the bottom of the page
	pane.hist.frame:SetPoint("BOTTOMRIGHT", dp.history, "BOTTOMRIGHT", -4, 6)
end

-- A link shift-clicked while one of our boxes is being edited goes there:
-- the filter box gets its [tag], the Test box the link, the Link box the
-- converted tag. A post-hook (baseline 02 J3), made once and doing nothing
-- unless the pane shows (C1).
local hooked
local function OnInsertLink(text)
	if not (pane and pane:IsVisible()) or type(text) ~= "string" or M.PSS_IsSecret(text) then return end
	if pane.filterBox:HasFocus() then
		pane.filterBox:Insert(M.PSS_ConvertChatLink(text))
	elseif pane.testBox:HasFocus() then
		pane.testBox:Insert(text)
	elseif pane.linkBox:HasFocus() then
		pane.linkBox:SetText(M.PSS_ConvertChatLink(text))
		pane.linkBox:HighlightText()
	end
end

local function HookLinks()
	if hooked then return end
	-- Retail 12.x inserts links with ChatFrameUtil.InsertLink (the old
	-- ChatEdit_InsertLink is only a deprecated copy of it there)
	if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then
		hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
		hooked = "ChatFrameUtil.InsertLink"
	elseif type(ChatEdit_InsertLink) == "function" then
		hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
		hooked = "ChatEdit_InsertLink"
	end
end

-- Redraw the pane for the selected filter (none: the totals). fresh:
-- another filter was selected (its texts are loaded again, the test cleared).
function ns.ShowFilterDetail(fresh)
	if not pane then return end
	local r = sel and M.PSS_FilterRow(sel, paneRow)
	pane.body:SetShown(r and true or false)
	if not r then
		sel = nil
		pane.hist:Clear()
		pane.totals:Show()
		return
	end
	pane.totals:Hide()
	pane.heading:SetText(M.PSS_FilterHeading(r))
	pane.info:SetText(M.PSS_FilterInfo(r))
	pane.onBox:SetChecked(r.active)
	if fresh or not pane.descBox:HasFocus() then pane.descBox:SetText(r.desc) end
	if fresh or not pane.filterBox:HasFocus() then
		pane.filterBox:SetText(r.filter)
		if fresh then pane.filterScroll:SetVerticalScroll(0) end
	end
	if fresh then
		pane.testBox:SetText("")
		pane.result:SetText("")
	end
	SetEditable(pane.descBox, not r.builtin)
	SetEditable(pane.filterBox, not r.builtin)
	pane.lock:SetShown(r.builtin)
	pane.saveButton:SetEnabled(not r.builtin)
	pane.removeButton:SetEnabled(not r.builtin)
	pane.copyButton:SetEnabled(not r.guildRule)
	pane.resetCount:SetEnabled(not r.guildRule)
	-- a guild rule's blocks are counted on its guilds: only its settings here
	pane.pages:Limit(r.guildRule and { rule = true } or nil)
	if r.guildRule then
		pane.hist:Clear()
		return
	end
	pane.counts:SetText(M.PSS_FilterHistoryLine(r))
	-- read again only when the filter or its count changed; the block
	-- history (PourSocialScore_Logging) loads only when asked for
	pane.hist:Set(r.index, r.lines, M.PSS_FilterHistory, fresh)
	pane.summary:Set(M.PSS_FilterSummarySpec(r, pane.sumSpec))
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------
local function Refresh()
	if V.dirty then Resort() else list:Redraw() end
	ns.ShowFilterDetail()
end

function Select(i)
	if pane then
		pane.descBox:ClearFocus()
		pane.filterBox:ClearFocus()
	end
	sel = i
	list:Redraw()
	ns.ShowFilterDetail(true)
end

ns.TabBuilders.filters = function(pg)
	page = pg
	HookLinks()

	-- top: search and counts on the left, New Filter and Reset Defaults on
	-- the right
	local search = ns.NewSearchBox(pg, 200, "Search description or filter", function(text)
		if V:SetFind(text) then
			Resort()
			list:Top()
		end
	end)
	search:SetPoint("TOPLEFT", pg, "TOPLEFT", 16, -6)
	pg.search = search
	pg.count = ns.NewText(pg, 12)
	pg.count:SetPoint("LEFT", search, "RIGHT", 12, 0)
	pg.count:SetAlpha(0.8)

	local new = ns.NewButton(pg, "New Filter", 100, function()
		local i = M.PSS_FilterNew()
		if i then
			Select(i)
			if pane then
				pane.pages:Select("rule")
				pane.descBox:SetFocus()
				pane.descBox:HighlightText()
			end
		end
	end)
	new:SetPoint("TOPRIGHT", pg, "TOPRIGHT", -8, -5)
	ns.TipOn(new, new, "A new custom filter (starts Off): give it a description and filter, Save, then tick On.")
	pg.newButton = new
	local reset = ns.NewButton(pg, L["BUT_7"] or "Reset Defaults", 120, function()
		ns.Confirm({ title = "Reset Chat Filters?", text = L["BOX_2"], accept = "Reset", onAccept = function()
			sel = nil
			M.ResetSpamFilters()
		end })
	end)
	reset:SetPoint("RIGHT", new, "LEFT", -8, 0)
	pg.resetButton = reset

	BuildPane(pg)

	local lf = CreateFrame("Frame", nil, pg)
	lf:SetPoint("TOPLEFT", pg, "TOPLEFT", 8, -TOP_H - 4)
	lf:SetPoint("BOTTOMRIGHT", pane, "BOTTOMLEFT", -8, 0)
	list = ns.NewRows(lf, {
		rowH = 20,
		cols = {
			{ key = "desc", text = "Description", width = 190 },
			{ key = "state", text = "On", width = 40 },
			{ key = "blocked", text = "Blocked", width = 60, justify = "RIGHT",
				tip = "Lines this filter blocked (n/a: a guild rule, counted on the Guild Ignore List)." },
			{ key = "filter", text = "Filter", tip = "Built-in filters always stay at the top." },
		},
		sort = function(key)
			V:SortBy(key)
			Resort()
		end,
		draw = DrawRow,
		enter = RowTip,
		click = function(row, i, button)
			local n = V.index[i]
			if not n then return end
			if button == "RightButton" then
				if n ~= sel then Select(n) end
				ns.RowMenu(row, M.PSS_FilterMenu(n), function(act, arg) RowAct(n, act, arg) end)
			else
				Select(n ~= sel and n or nil)
			end
		end,
		emptyClick = function() if sel then Select(nil) end end,
	})
	-- a tab click (PSS_Window.lua): nothing selected
	pg.navReset = function() if sel then Select(nil) end end
	pg.list, pg.pane, pg.state = list, pane, V
	pg.stale = function() V.dirty = true end
	pg.select = Select
	pg.selected = function() return sel end
	pg.linkHook = function() return hooked end
	V.dirty = true
	return Refresh
end

------------------------------------------------------------------------
-- Core events: redraw now if the tab shows, else when it next shows.
------------------------------------------------------------------------
local queued
local function RunQueued()
	queued = false
	if page and page:IsVisible() then Refresh() end
end
ns.Listen("FILTERS_CHANGED", function()
	V.dirty = true
	if queued or not (page and page:IsVisible()) then return end
	-- one redraw however many changes arrive in a frame (an import adds
	-- many filters at once)
	queued = true
	C_Timer.After(0, RunQueued)
end)

-- a blocked line: the order (the Blocked column), the counts and the
-- history, at most 4 times a second
local redrawCounts = M.PSS_Throttle(function()
	if page and page:IsVisible() then Refresh() end
end)
ns.Listen("FILTER_HISTORY_CHANGED", function()
	V.dirty = true
	if page and page:IsVisible() then redrawCounts() end
end)
