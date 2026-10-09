------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - GUILD IGNORE LIST TAB
--
-- The guild list (Managed Communities and its default lists, the Guild
-- Exclusion List, the other guilds), a guild's members in its place (a
-- double-click or the Members button), Scan All, the Add and Exclude entry
-- rows with Guild Search, the Guild Search results picker in place of the
-- list, and a pane for what is selected: a guild (Summary, Event History,
-- View/Edit Rule with W I G P C, Scan / Custom Scan, exceptions, Members,
-- Remove Guild), a default list or Managed Communities (counts, pies, its
-- rule), the Guild Exclusion List or an excluded guild, or a member (note,
-- W I G P C that follow the guild until set, exceptions, Remove Member, Add
-- Guild); with nothing selected, the list's totals. A right-click on a
-- row or a member opens its menu (Libraries PSS_RowMenus.lua). Libraries
-- (PSS_GuildView.lua) works out every text and does every change; the core
-- says when guilds changed (GUILDS_CHANGED, GUILD_SCAN_DONE, GUILD_REMOVED,
-- GUILD_BLOCKS_CHANGED) and the tab redraws if it shows. Scan buttons are
-- disabled while /who cools down (WHOIS_COOLDOWN).
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M
local L = PourSocialScore_NS.L

local DETAIL_W = 380
local TOP_H = 58
local LINE_H = 16
local PIE_SMALL = 84
local MANAGED = M.PSS_GUILD_MANAGED

local V = M.PSS_GuildListNew()
local cells = {}
local groupView = {}
local page, list, mlist, lf, mview, pane, picker
local scanButtons = {}
local cellBuf, paneView, memberView = {}, {}, {}

ns.TabBuilders = ns.TabBuilders or {}

-- Scan buttons follow the /who cooldown.
local function ScanButton(b)
	scanButtons[#scanButtons + 1] = b
	b:SetEnabled(not M.PSS_ScanCooldownActive())
	return b
end

local ShowDetail, OpenMembers, RowMenu, MemberMenu

------------------------------------------------------------------------
-- Guild list
------------------------------------------------------------------------
local function Resort()
	local n = V:Resort()
	list:SetSort(V.key, V.asc)
	list:SetCount(n)
	list:SetEmptyText(V:EmptyText())
	page.count:SetText(V:CountText())
end

local function DrawRow(row, i)
	local item = V.rows[i]
	local c = row.cells
	row:SetAlpha(1)
	if not item then
		for _, fs in pairs(c) do fs:SetText("") end
		row.sel:Hide()
		return
	end
	V:FreshCounts(item)
	M.PSS_GuildRowCells(item, V.find, V.rows.managedHead and true or false, cells)
	c.guild:SetText(cells.guild)
	c.members:SetText(cells.members)
	c["metric:total"]:SetText(cells.total)
	c.scan:SetText(cells.scan)
	-- a group whose rule is off: dimmed (nothing in it is blocked)
	if cells.dim then row:SetAlpha(0.55) end
	row.sel:SetShown(V:IsSel(item))
end

local function RowTip(row, i)
	local item = V.rows[i]
	if item then ns.Tip(row, M.PSS_GuildRowTip(item)) end
end

local function ClearEdits()
	-- saves what was typed first
	if pane then
		pane.fieldsBox:ClearFocus()
		pane.noteBox:ClearFocus()
	end
end

local function Select(kind, value)
	ClearEdits()
	V:Select(kind, value)
	list:Redraw()
	ShowDetail(true)
end

local function ClickRow(row, i, button)
	ClearEdits()
	local item = V.rows[i]
	if button == "RightButton" then
		if item then RowMenu(row, item) end
		return
	end
	local what = V:Click(item)
	if what == "resort" then
		Resort()
	else
		list:Redraw()
	end
	ShowDetail(true)
	if what == "members" then OpenMembers(item.key) end
end

------------------------------------------------------------------------
-- Members view (in place of the guild list)
------------------------------------------------------------------------
local function MResort()
	local n = V:MResort()
	mlist:SetSort(V.mkey, V.masc)
	mlist:SetCount(n)
	mlist:SetEmptyText(V:MembersEmptyText())
	mview.heading:SetText(V:MembersHeading())
	page.count:SetText(V:CountText())
end

local function DrawMember(row, i)
	local m = V.members[i]
	local c = row.cells
	if not m then
		for _, fs in pairs(c) do fs:SetText("") end
		row.sel:Hide()
		return
	end
	local mc = M.PSS_MemberCells(m, cellBuf)
	c.name:SetText(mc.name)
	c.name:SetTextColor(M.PSS_ClassColor(mc.class))
	c.guild:SetText(mc.guild)
	c.note:SetText(mc.note)
	c["metric:total"]:SetText(mc.total)
	row.sel:SetShown(m == V.msel)
end

local function SelectMember(m)
	ClearEdits()
	V:SelectMember(m)
	mlist:Redraw()
	ShowDetail(true)
end

local function ShowView(view)
	V:SetView(view)
	page.search:SetText("")
	page.search.hint:SetText(V:SearchHint())
	lf:SetShown(view == "guilds")
	mview:SetShown(view == "members")
end

function OpenMembers(key)
	if not V:OpenMembers(key) then return end
	ShowView("members")
	MResort()
	mlist:Top()
	ShowDetail(true)
	ns.NavRecord()
end

local function CloseMembers()
	ClearEdits()
	V:CloseMembers()
	ShowView("guilds")
	Resort()
	ShowDetail(true)
	ns.NavRecord()
end

------------------------------------------------------------------------
-- Detail pane
------------------------------------------------------------------------
-- A line under another: a wrapped line pushes the ones below it down.
-- A FontString held by two side anchors stays one line tall when it wraps,
-- so these get a set width and FitLines gives each its wrapped height.
local function WrapLine(parent)
	local fs = ns.NewText(parent, 12)
	fs:SetWidth(DETAIL_W - 20)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(true)
	return fs
end

local function LineBelow(prev, gap)
	local fs = WrapLine(prev:GetParent())
	fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -gap)
	return fs
end

local function FitLines(lines)
	for _, fs in ipairs(lines) do fs:SetHeight(fs:GetStringHeight()) end
end

local function Body(parent)
	local b = CreateFrame("Frame", nil, parent)
	b:SetAllPoints()
	b:Hide()
	b.heading = ns.NewHeading(b, "")
	b.heading:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -8)
	b.heading:SetPoint("RIGHT", b, "RIGHT", -10, 0)
	return b
end

-- W I G P C tick boxes (ticked = allowed). onClick(cat, box, button).
local function ExclBoxes(parent, y, tip, onClick)
	return ns.NewAllowedBoxes(parent, y, DETAIL_W - 20, tip, onClick, true)
end

local function OpenGuildEvents(key)
	if ns.OpenEvents then ns.OpenEvents(page, M.PSS_GuildEventsSpec(key), {}) end
end

local function ConfirmRemoveGuild()
	local key = V:RemoveTarget()
	local text = M.PSS_GuildRemoveText(key)
	if not text then return end
	ns.Confirm({ title = "Remove Guild?", text = text, accept = "Remove", onAccept = function()
		if V.view == "members" then CloseMembers() end
		M.PSS_GuildRemove(key)
	end })
end

local function ConfirmRemoveMember()
	local m = V.msel
	if not m then return end
	ns.Confirm({ title = "Remove Member?", text = M.PSS_MemberRemoveText(m), accept = "Remove", onAccept = function()
		if V:RemoveMember() and page:IsVisible() then
			MResort()
			ShowDetail(true)
		end
	end })
end

-- A row's right-click menu (Libraries M.PSS_GuildRowMenu, M.PSS_MemberMenu):
-- the row is selected first (a heading is not opened or closed by it), so
-- each entry acts on the pane's guild or member as its buttons do.
local function RowAct(item, act, arg)
	if act == "allRules" then
		M.PSS_GuildSetAllRules(arg)
		page.refresh()
	elseif act == "rule" then
		M.PSS_GroupToggleRule(arg)
		page.refresh()
	elseif act == "open" then
		M.PSS_GroupToggleOpen(arg)
		Resort()
		ShowDetail()
	elseif act == "exclRemove" then
		if M.PSS_ExclRemove(arg) then
			Select(nil, nil)
			Resort()
		end
	elseif act == "members" then
		OpenMembers(arg)
	elseif act == "history" then
		OpenGuildEvents(arg)
	elseif act == "resetHistory" then
		M.PSS_ResetGuildBlockHistory(arg)
	elseif act == "exception" then
		M.PSS_GuildToggleException(item.key, arg)
		ShowDetail()
	elseif act == "remove" then
		ConfirmRemoveGuild()
	end
end

function RowMenu(row, item)
	local kind, value = V:ItemSel(item)
	if not V:IsSel(item) then Select(kind, value) end
	ns.RowMenu(row, M.PSS_GuildRowMenu(item), function(act, arg) RowAct(item, act, arg) end)
end

local function MemberAct(m, act, arg)
	if m ~= V.msel then SelectMember(m) end
	if act == "history" then
		if ns.OpenEvents then ns.OpenEvents(page, M.PSS_MemberEventsSpec(m, V.mguild), {}) end
	elseif act == "resetHistory" then
		M.PSS_ResetMemberBlockHistory(m)
	elseif act == "exception" then
		M.PSS_MemberToggleException(V.mguild, m, arg)
		ShowDetail()
	elseif act == "remove" then
		ConfirmRemoveMember()
	end
end

function MemberMenu(row, m)
	if m ~= V.msel then SelectMember(m) end
	ns.RowMenu(row, M.PSS_MemberMenu(m, V.mguild), function(act, arg) MemberAct(m, act, arg) end)
end

local function BuildGuildBody(parent)
	local b = Body(parent)
	b.info = ns.NewLine(b, -28)
	local dp = ns.NewDetailPages(b, -46, "guilds")
	b.pages = dp
	b.counts = ns.NewLine(dp.summary, -6)
	b.summary = ns.NewSummary(dp.summary, page, -30)
	b.sumSpec = { specFn = M.PSS_GuildEventsSpec, noWhere = true }

	-- View/Edit Rule
	local rule = dp.rule
	local y = -2
	b.excl = ExclBoxes(rule, y, "Ticked = allowed from every member of the guild, unticked = blocked. A member's own setting wins.",
		function(cat, box) M.PSS_GuildToggleAllowed(pane.guildKey, cat, box:GetChecked()) end)
	y = y - 28

	-- Scan (the sweep), Scan Fields, Custom Scan: /who first, the window after
	local sr = ns.NewStrip(rule, y, 24, DETAIL_W - 20)
	local scan = ns.NewButton(sr, "Scan", 100, function() M.PSS_GuildScanNow(pane.guildKey, IsShiftKeyDown()) end)
	scan:SetPoint("LEFT", sr, "LEFT", 0, 0)
	scan:SetScript("OnEnter", function(self)
		ns.Tip(self, M.PSS_GuildScanTip(pane.guildKey))
	end)
	scan:SetScript("OnLeave", ns.HideTip)
	b.scan = ScanButton(scan)
	local fields = ns.NewEditBox(sr, 120, 128)
	fields:SetPoint("LEFT", scan, "RIGHT", 10, 0)
	-- saves to the guild shown when typing started
	ns.OnCommit(fields, function(text) M.PSS_GuildCommitFields(pane.fieldsKey or pane.guildKey, text) end,
		function() ShowDetail() end)
	fields:SetScript("OnEditFocusGained", function() pane.fieldsKey = pane.guildKey end)
	ns.TipOn(fields, fields, "Custom Scan Fields\n\nExtra /who filters sent with the guild name by Custom Scan.\nExamples: 80   70-80   80 c-\"Mage\"   r-\"Orc\"")
	pane.fieldsBox = fields
	local custom = ns.NewButton(sr, "Custom Scan", 96, function()
		M.PSS_GuildCustomScan(pane.guildKey, fields:GetText())
		fields:ClearFocus()
	end)
	custom:SetPoint("LEFT", fields, "RIGHT", 8, 0)
	ns.TipOn(custom, custom, "Custom Scan: /who for the guild plus its Scan Fields.")
	b.custom = ScanButton(custom)
	y = y - 28

	-- exceptions to the Options for this guild (ticked = it happens)
	b.exceptions = ns.NewExceptions(rule, 10, y, DETAIL_W - 20, function() ShowDetail() end)

	local members = ns.NewButton(rule, "Members", 90, function() OpenMembers(pane.guildKey) end)
	members:SetPoint("BOTTOMLEFT", rule, "BOTTOMLEFT", 10, 4)
	ns.TipOn(members, members, "The guild's members, in place of the guild list.")
	b.membersButton = members
	local remove = ns.NewButton(rule, "Remove Guild", 100, ConfirmRemoveGuild)
	remove:SetPoint("LEFT", members, "RIGHT", 6, 0)
	b.removeButton = remove

	-- Event History: the guild's block history, the whole page
	b.hist = ns.NewHistory(dp.history, -2, { names = true, empty = "Nothing blocked from this guild yet.", open = OpenGuildEvents })
	local reset = ns.NewButton(dp.history, L["HISTORY_RESET"] or "Reset Block History", 130, function()
		if pane.guildKey then M.PSS_ResetGuildBlockHistory(pane.guildKey) end
	end)
	reset:SetPoint("BOTTOMLEFT", dp.history, "BOTTOMLEFT", 10, 4)
	b.resetButton = reset
	return b
end

local function BuildGroupBody(parent)
	local b = Body(parent)
	b.info = WrapLine(b)
	b.info:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -28)
	b.rule = LineBelow(b.info, 2)
	b.state = LineBelow(b.rule, 2)
	b.counts = LineBelow(b.state, 6)
	b.lines = { b.info, b.rule, b.state, b.counts }
	-- a new font wraps differently
	ns.OnPaint(function() FitLines(b.lines) end)
	-- the pies hang under the last line, wherever it ends
	b.charts = CreateFrame("Frame", nil, b)
	b.charts:SetPoint("TOPLEFT", b.counts, "BOTTOMLEFT", -10, -6)
	b.charts:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
	b.summary = ns.NewSummary(b.charts, page, 0, PIE_SMALL)
	b.typePie = ns.NewTypePie(b.charts, -PIE_SMALL - 10, PIE_SMALL, page)
	b.recent = {}
	-- the list's guilds' session and 24 hour counts by type, added up
	local one = {}
	b.sumSpec = { specFn = M.PSS_GroupEventsSpec, noWhere = true,
		recentByCat = function(into) M.PSS_GroupRecentByCat(b.groupItems, into, one) end }
	local toggle = ns.NewButton(b, "", 130, function()
		M.PSS_GroupToggleRule(pane.groupKey)
		page.refresh()
	end)
	toggle:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 10, 8)
	ns.TipOn(toggle, toggle, "Turns this default guild list's rule on or off (the same switch as on the Chat Filters tab).")
	b.toggle = toggle
	local open = ns.NewButton(b, "", 100, function()
		M.PSS_GroupToggleOpen(pane.groupKey)
		Resort()
		ShowDetail()
	end)
	open:SetPoint("LEFT", toggle, "RIGHT", 6, 0)
	b.open = open
	return b
end

local function BuildInfoBody(parent)
	local b = Body(parent)
	b.text = ns.NewLine(b, -30)
	b.text:SetWordWrap(true)
	b.text:SetJustifyV("TOP")
	b.text:SetHeight(160)
	local remove = ns.NewButton(b, "Remove from Exclusion List", 190, function()
		if M.PSS_ExclRemove(pane.exclName) then V:Select(nil, nil) end
	end)
	remove:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 10, 8)
	b.removeButton = remove
	return b
end

local function BuildMemberBody(parent)
	local b = Body(parent)
	local dp = ns.NewDetailPages(b, -28, "guilds")
	b.pages = dp
	b.counts = ns.NewLine(dp.summary, -6)
	b.summary = ns.NewSummary(dp.summary, page, -30)
	b.sumSpec = { specFn = function(m) return M.PSS_MemberEventsSpec(m, V.mguild) end, who = "this member" }

	-- View/Edit Rule
	local rule = dp.rule
	local y = -2
	b.guildLine = ns.NewLine(rule, y); y = y - LINE_H
	b.addedLine = ns.NewLine(rule, y); y = y - LINE_H - 4

	local nr = ns.NewStrip(rule, y, 22, DETAIL_W - 20)
	ns.NewLabel(nr, "Note")
	local note = ns.NewEditBox(nr, 200, 25)
	note:SetPoint("LEFT", nr, "LEFT", 94, 0)
	note:SetPoint("RIGHT", nr, "RIGHT", -4, 0)
	-- saves to the member shown when typing started
	ns.OnCommit(note, function(text)
		if M.PSS_MemberCommitNote(pane.noteMember or V.msel, text) then V:MarkDirty(false, true) end
	end, function() if page:IsVisible() then MResort(); ShowDetail() end end)
	note:SetScript("OnEditFocusGained", function() pane.noteMember = V.msel end)
	pane.noteBox = note
	y = y - 28

	-- ticked = allowed; dimmed = following the guild; right-click = follow
	-- the guild again
	b.excl = ExclBoxes(rule, y, "Ticked = allowed from this player, unticked = blocked. Dimmed boxes follow the guild's setting; right-click to follow it again.",
		function(cat, box, button)
			if M.PSS_MemberToggleAllowed(V.mguild, V.msel, cat, box:GetChecked(), button == "RightButton") then
				V:MarkDirty(true, false)
				ShowDetail()
			end
		end)
	y = y - 28

	-- exceptions for this member; its guild's settings are its default
	b.exceptions = ns.NewExceptions(rule, 10, y, DETAIL_W - 20, function() ShowDetail() end)

	local remove = ns.NewButton(rule, "Remove Member", 110, ConfirmRemoveMember)
	remove:SetPoint("BOTTOMLEFT", rule, "BOTTOMLEFT", 10, 4)
	b.removeButton = remove
	local addGuild = ns.NewButton(rule, "Add Guild", 90, function()
		local m = V.msel
		if m and M.PSS_AddMembersGuild(V.mguild, M.PSS_MemberGuildName(m)) then
			V:MarkDirty(true, true)
			MResort()
			ShowDetail()
		end
	end)
	addGuild:SetPoint("LEFT", remove, "RIGHT", 6, 0)
	ns.TipOn(addGuild, addGuild, "The player's actual guild is not this rule: adds a rule for it and moves its members there.")
	b.addGuild = addGuild

	-- Event History: the member's block history, the whole page
	b.hist = ns.NewHistory(dp.history, -2, { empty = "Nothing blocked from this player yet.", open = function(m)
		if ns.OpenEvents then ns.OpenEvents(page, M.PSS_MemberEventsSpec(m, V.mguild), {}) end
	end })
	local reset = ns.NewButton(dp.history, L["HISTORY_RESET"] or "Reset Block History", 130, function()
		if V.msel then M.PSS_ResetMemberBlockHistory(V.msel) end
	end)
	reset:SetPoint("BOTTOMLEFT", dp.history, "BOTTOMLEFT", 10, 4)
	b.resetButton = reset
	return b
end

local function BuildPane(parent)
	pane = ns.NewPanel(parent, true)
	pane:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -TOP_H - 4)
	pane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 8)
	pane:SetWidth(DETAIL_W)
	-- nothing selected: every guild's totals (a click on the selected guild
	-- deselects it)
	pane.totals = ns.NewTotals(pane, page, "guilds", "Guild Ignore List", "Select a guild to see its details.",
		M.PSS_AllGuildsSpec)
	pane.bodies = {}
	pane.guild = BuildGuildBody(pane)
	pane.group = BuildGroupBody(pane)
	pane.info = BuildInfoBody(pane)
	pane.member = BuildMemberBody(pane)
	for _, k in ipairs({ "guild", "group", "info", "member" }) do pane.bodies[#pane.bodies + 1] = pane[k] end
end

local function ShowGuild(key, fresh)
	local gv = M.PSS_GuildPaneView(key, paneView)
	if not gv then return false end
	local g = gv.record
	local b = pane.guild
	pane.guildKey = key
	b:Show()
	b.heading:SetText(gv.name)
	b.info:SetText(gv.info)
	for cat, c in pairs(b.excl) do c:SetChecked(M.PSS_GuildAllowed(g, cat)) end
	b.scan:SetText(gv.sweep)
	if not pane.fieldsBox:HasFocus() then pane.fieldsBox:SetText(gv.fields) end
	b.exceptions:Set(g, "guild", "this guild")
	local c = V:GuildCounts(key)
	b.counts:SetText(M.PSS_CountsText(c))
	b.removeButton:SetEnabled(gv.removable)
	b.membersButton:SetShown(V.view ~= "members")
	b.hist:Set(key, c.total or 0, M.PSS_GetGuildBlockHistory, fresh)
	b.summary:Set(M.PSS_GuildSummarySpec(key, gv.name, c, b.sumSpec))
	return true
end

-- A default guild list, or (k = MANAGED) the Managed Communities row
local function ShowGroup(k)
	local gv = M.PSS_GuildGroupView(k, V.rows, groupView)
	if not gv then return false end
	local b = pane.group
	pane.groupKey = k
	b:Show()
	b.heading:SetText(gv.name)
	b.info:SetText(gv.info)
	b.rule:SetText(gv.rule)
	b.state:SetText(gv.state)
	b.toggle:SetShown(gv.toggle ~= nil)
	if gv.toggle then b.toggle:SetText(gv.toggle) end
	b.open:SetText(gv.open)
	local item, items = gv.item, gv.items
	b.counts:SetText(item and M.PSS_CountsText(item.bc) or "")
	FitLines(b.lines)
	b.charts:SetShown(item and items and true or false)
	if item and items then
		-- periods like a guild's Summary and all-time blocks by type
		b.groupItems = items
		b.summary:Set(M.PSS_GroupSummarySpec(k, gv.name, item, items, b.recent, b.sumSpec))
		b.typePie:Set(item.bc, gv.name, M.PSS_GroupEventsSpec, k)
	end
	return true
end

local function ShowExcl(name)
	local heading, text = M.PSS_GuildExclView(name)
	if not heading then return false end
	local b = pane.info
	b.heading:SetText(heading)
	b.text:SetText(text)
	pane.exclName = name
	b.removeButton:SetShown(name ~= nil)
	b:Show()
	return true
end

local function ShowMember(fresh)
	local m = V.msel
	local mv = M.PSS_MemberPaneView(V.mguild, m, memberView)
	if not mv then return false end
	local gg = mv.rule
	local b = pane.member
	b:Show()
	b.heading:SetText(mv.heading)
	b.guildLine:SetText(mv.guildLine)
	b.addedLine:SetText(mv.addedLine)
	if not pane.noteBox:HasFocus() then pane.noteBox:SetText(mv.note) end
	for cat, c in pairs(b.excl) do
		local on, own = M.PSS_MemberAllowed(gg, m, cat)
		c:SetChecked(on)
		c:SetAlpha(own and 1 or 0.45)
	end
	b.exceptions:Set(m, "person", "this member", mv.opts)
	b.addGuild:SetShown(mv.otherGuild)
	local c = M.PSS_GetMemberBlockCounts(m)
	b.counts:SetText(M.PSS_CountsText(c))
	b.hist:Set(m, c.total or 0, M.PSS_GetMemberBlockHistory, fresh)
	b.summary:Set(M.PSS_MemberSummarySpec(m, mv.name, c, b.sumSpec))
	return true
end

-- A block only changes the counts: the counts line, the history and the
-- Summary of the guild or member shown (the rest of the pane is as it was).
-- Anything else shown: the whole pane.
local function ShowCounts()
	local b = pane and (V.view == "members" and V.msel and pane.member or V.view ~= "members" and V.selKind == "guild" and pane.guild)
	if not (b and b:IsShown()) then return ShowDetail() end
	local s = b.sumSpec
	local c
	if b == pane.member then
		local m = V.msel
		c = M.PSS_GetMemberBlockCounts(m)
		b.hist:Set(m, c.total or 0, M.PSS_GetMemberBlockHistory)
	else
		local key = V.sel
		c = V:GuildCounts(key)
		b.hist:Set(key, c.total or 0, M.PSS_GetGuildBlockHistory)
	end
	b.counts:SetText(M.PSS_CountsText(c))
	s.allTime = c.total or 0
	b.summary:Set(s)
end

-- Redraw the pane for what is selected (nothing: the list's totals).
function ShowDetail(fresh)
	if not pane then return end
	for _, body in ipairs(pane.bodies) do body:Hide() end
	local shown = false
	if V.view == "members" then
		shown = (V.msel and ShowMember(fresh)) or ShowGuild(V.mguild, fresh)
	elseif V.selKind == "guild" then
		shown = ShowGuild(V.sel, fresh)
	elseif V.selKind == "group" then
		shown = ShowGroup(V.sel)
	elseif V.selKind == "managed" then
		shown = ShowGroup(MANAGED)
	elseif V.selKind == "exclHeader" then
		shown = ShowExcl(nil)
	elseif V.selKind == "excl" then
		shown = ShowExcl(V.sel)
	end
	if not shown then V:Select(nil, nil) end
	if shown then pane.totals:Hide() else pane.totals:Show(V.rows.pool and V.rows or nil) end
end

------------------------------------------------------------------------
-- Guild Search results (in place of the list)
------------------------------------------------------------------------
local function ClosePicker()
	if not picker:IsShown() then return end
	picker:Hide()
	M.PSS_GuildPickerClose(picker.mode)
	lf:SetShown(V.view == "guilds")
	mview:SetShown(V.view == "members")
end

local function BuildPicker(parent)
	picker = ns.NewPicker(parent, lf, {
		cols = { { key = "guild", text = "Guild" } },
		stateW = 70,
		fill = function(c, it) c.guild:SetText(it.name) end,
		toggle = M.PSS_PickerToggle,
		tickAll = M.PSS_PickerTickAll,
		save = function(items) M.PSS_GuildPickerSave(items, picker.mode) end,
		close = ClosePicker,
	})
end

local function ShowSearchResults(found, query, mode)
	if not found or #found == 0 then
		local text, name = M.PSS_GuildNoneFound(query, mode)
		if text then
			ns.Confirm({ title = "Exclude Guild?", text = text, accept = "Add Anyway", onAccept = function() M.PSS_GuildExcludeAnyway(name) end })
		end
		return
	end
	picker.mode = mode
	M.PSS_GuildPickerItems(found, mode, picker.items)
	lf:Hide()
	mview:Hide()
	picker:ShowItems(M.PSS_GuildPickerTitle(#found, query, mode))
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------
local function Refresh()
	if V.view == "members" then
		if V.mdirty then MResort() else mlist:Redraw() end
		if not V.mguild then CloseMembers() return end
	end
	if V.dirty then Resort() elseif V.view == "guilds" then list:Redraw() end
	page.count:SetText(V:CountText())
	ShowDetail()
end

-- [box] [Guild Search] [Add]: the top right entry rows
local function EntryRow(pg, y, hintText, addText, onSearch, onAdd, searchTip, addTip)
	local addButton = ns.NewButton(pg, addText, 90)
	addButton:SetPoint("TOPRIGHT", pg, "TOPRIGHT", -8, y)
	local search = ns.NewButton(pg, "Guild Search", 100)
	search:SetPoint("RIGHT", addButton, "LEFT", -6, 0)
	local box = ns.NewEditBox(pg, 150, 64, hintText)
	box:SetPoint("RIGHT", search, "LEFT", -8, 0)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	-- /who must go out straight from the click (hardware event)
	local function doSearch()
		if onSearch(box:GetText()) then box:SetText("") end
	end
	local function doAdd()
		if onAdd(box:GetText()) then box:SetText("") end
		box:ClearFocus()
	end
	search:SetScript("OnClick", doSearch)
	addButton:SetScript("OnClick", doAdd)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); doSearch() end)
	ns.TipOn(search, search, searchTip)
	ns.TipOn(addButton, addButton, addTip)
	ScanButton(search)
	return box, search, addButton
end

ns.TabBuilders.guilds = function(pg)
	page = pg

	-- top left: search (guild names, or the members shown) and the count
	local search = ns.NewSearchBox(pg, 200, "Search guild name", function(text)
		if V.view == "members" then
			if V:SetMFind(text) then
				MResort()
				mlist:Top()
			end
		elseif V:SetFind(text) then
			Resort()
			list:Top()
		end
	end)
	search:SetPoint("TOPLEFT", pg, "TOPLEFT", 16, -6)
	pg.search = search
	pg.count = ns.NewText(pg, 12)
	pg.count:SetPoint("LEFT", search, "RIGHT", 12, 0)
	pg.count:SetAlpha(0.7)

	-- top right: Scan All, [Add a Guild] [Guild Search] [Add Guild], under
	-- it [Exclude a Guild] [Guild Search] [Exclude]
	pg.add, pg.searchButton, pg.addButton = EntryRow(pg, -5, "Add a Guild", "Add Guild",
		function(text) return M.PSS_GuildSearchFromText(text) end,
		function(text)
			local key = M.PSS_GuildAddFromText(text)
			if not key then return false end
			if V:SetFind("") then pg.search:SetText("") end
			Resort()
			Select("guild", key)
			return true
		end,
		"Guild Search\n\nRuns a /who and lists every guild found (not the players). Type part of a guild name, or a full /who filter containing quotes, e.g. g-\"Name\" 10-80.",
		"Add Guild\n\nAdds the guild typed in the box to the Guild Ignore List.")
	pg.excl, pg.exclSearchButton, pg.exclButton = EntryRow(pg, -31, "Exclude a Guild", "Exclude",
		function(text) return M.PSS_GuildSearchFromText(text, "exclude") end,
		function(text) return M.PSS_GuildExcludeFromText(text) end,
		"Guild Search\n\nRuns a /who for the guild name in the box and lets you pick which guilds found go on the Guild Exclusion List. If none is found you can add the name anyway.",
		"Exclude\n\nAdds the guild typed in the box to the Guild Exclusion List: no guild rule ever blocks it, even one whose name it contains.")

	-- /who first, the window after
	local scanAll = ns.NewButton(pg, "Scan All", 80, function() M.PSS_ScanAll() end)
	scanAll:SetPoint("RIGHT", pg.add, "LEFT", -10, 0)
	scanAll:SetScript("OnEnter", function(self) ns.Tip(self, M.PSS_GuildScanTip(nil)) end)
	scanAll:SetScript("OnLeave", ns.HideTip)
	pg.scanAll = ScanButton(scanAll)

	BuildPane(pg)

	lf = CreateFrame("Frame", nil, pg)
	lf:SetPoint("TOPLEFT", pg, "TOPLEFT", 8, -TOP_H - 4)
	lf:SetPoint("BOTTOMRIGHT", pane, "BOTTOMLEFT", -8, 0)
	list = ns.NewRows(lf, {
		rowH = 20,
		cols = {
			{ key = "guild", text = "Guild" },
			{ key = "members", text = "Members", width = 70, justify = "RIGHT" },
			{ key = "metric:total", text = "Blocked", width = 62, justify = "RIGHT",
				tip = "Messages and invites blocked from the guild's members." },
			{ key = "scan", text = "Scan", width = 90, justify = "RIGHT",
				tip = "Scan n/m = /who searches sent / planned so far this session. Sorts by searches sent." },
		},
		sort = function(key)
			V:SortBy(key)
			Resort()
		end,
		draw = DrawRow,
		enter = RowTip,
		click = ClickRow,
		emptyClick = function() if V.selKind then Select(nil, nil) end end,
	})

	-- the members of one guild, in place of the guild list
	mview = CreateFrame("Frame", nil, pg)
	mview:SetPoint("TOPLEFT", lf, "TOPLEFT", 0, 0)
	mview:SetPoint("BOTTOMRIGHT", lf, "BOTTOMRIGHT", 0, 0)
	mview:Hide()
	local back = ns.NewButton(mview, "All Guilds", 90, CloseMembers)
	back:SetPoint("TOPLEFT", mview, "TOPLEFT", 0, 0)
	ns.TipOn(back, back, "Back to the guild list.")
	mview.back = back
	mview.heading = ns.NewText(mview, 12)
	mview.heading:SetPoint("LEFT", back, "RIGHT", 10, 0)
	local mf = CreateFrame("Frame", nil, mview)
	mf:SetPoint("TOPLEFT", mview, "TOPLEFT", 0, -26)
	mf:SetPoint("BOTTOMRIGHT", mview, "BOTTOMRIGHT", 0, 0)
	mlist = ns.NewRows(mf, {
		rowH = 20, height = 280,
		cols = {
			{ key = "name", text = "Name" },
			{ key = "guild", text = "Guild", width = 130 },
			{ key = "note", text = "Note", width = 110 },
			{ key = "metric:total", text = "Blocked", width = 62, justify = "RIGHT",
				tip = "Messages and invites blocked from this player." },
		},
		sort = function(key)
			V:MSortBy(key)
			MResort()
		end,
		draw = DrawMember,
		enter = function(row, i)
			local m = V.members[i]
			if m then ns.Tip(row, M.PSS_MemberTip(m)) end
		end,
		click = function(row, i, button)
			local m = V.members[i]
			if not m then return end
			if button == "RightButton" then
				MemberMenu(row, m)
			else
				-- the selected member again: back to the guild's own
				SelectMember(m ~= V.msel and m or nil)
			end
		end,
		emptyClick = function() if V.msel then SelectMember(nil) end end,
	})

	BuildPicker(pg)

	-- back / forward and Escape (PSS_Window.lua): the members of a guild
	-- are a view of their own, the Guild Search results an overlay
	pg.navState = function() return V.view == "members" and V.mguild or nil end
	pg.navTitle = M.PSS_MembersNavTitle
	pg.navApply = function(key)
		if key then
			-- (the rule's first return is the key even when it is gone)
			if (V.mguild ~= key or V.view ~= "members") and M.PSS_GuildExists(key) then OpenMembers(key) end
		elseif V.view == "members" then
			CloseMembers()
		end
	end
	pg.navClose = function()
		if not picker:IsShown() then return false end
		ClosePicker()
		return true
	end
	pg.navUp = function()
		if pg.navClose() then return true end
		if V.view == "members" then
			CloseMembers()
			return true
		end
		return false
	end
	-- a tab click: the guild list, nothing selected, the picker closed
	pg.navReset = function()
		pg.navClose()
		if V.view == "members" then CloseMembers() end
		if V.selKind then Select(nil, nil) end
	end

	pg.list, pg.members, pg.membersView, pg.pane, pg.picker, pg.state = list, mlist, mview, pane, picker, V
	pg.selectMember = SelectMember
	pg.stale = function()
		V.dirty, V.mdirty = true, true
		for _, b in ipairs(scanButtons) do b:SetEnabled(not M.PSS_ScanCooldownActive()) end
	end
	pg.select = Select
	V.dirty = true
	return Refresh
end

------------------------------------------------------------------------
-- Core events: redraw now if the tab shows, else when it next shows.
------------------------------------------------------------------------
local queued = false
local function RunQueued()
	queued = false
	if page and page:IsVisible() then Refresh() end
end
local function Changed()
	V.dirty, V.mdirty = true, true
	if queued or not (page and page:IsVisible()) then return end
	-- one redraw however many changes arrive in a frame (saving Guild
	-- Search results adds many guilds at once)
	queued = true
	C_Timer.After(0, RunQueued)
end
ns.Listen("GUILDS_CHANGED", Changed)
ns.Listen("GUILD_SCAN_DONE", Changed)
-- a default guild list's rule is a chat filter: its on or off (the rows'
-- dim) changes on the Chat Filters tab too
ns.Listen("FILTERS_CHANGED", Changed)

ns.Listen("GUILD_REMOVED", function(key)
	V:GuildRemoved(key)
	Changed()
end)

-- Blocked lines only change counts: at most 4 redraws a second, the rows on
-- screen counted again (V:CountsChanged); the order and a heading's totals
-- follow at the next Resort
local redrawCounts = M.PSS_Throttle(function()
	if page and page:IsVisible() then
		if V.view == "members" then
			mlist:Redraw()
		else
			V:CountsChanged()
			-- the selected guild's row was counted by the redraw: the pane reuses it
			V.share = true
			list:Redraw()
		end
		ShowCounts()
		V.share = nil
	else
		V.dirty, V.mdirty = true, true
	end
end)
ns.Listen("GUILD_BLOCKS_CHANGED", function()
	if page and page:IsVisible() then redrawCounts() else V.dirty, V.mdirty = true, true end
end)

ns.Listen("WHOIS_COOLDOWN", function(active)
	for _, b in ipairs(scanButtons) do b:SetEnabled(not active) end
	if not active then Changed() end
end)

ns.Listen("GUILD_SEARCH_RESULTS", function(found, query, mode, owner)
	if owner ~= M.PSS_GUILD_SEARCH_OWNER or not picker then return end
	ShowSearchResults(found, query, mode)
end)
