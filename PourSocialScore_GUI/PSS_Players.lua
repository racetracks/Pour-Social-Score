------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - PLAYER IGNORE LIST TAB
--
-- The list (search, sortable columns, Add Player; a right-click on a row
-- for its menu, Libraries M.PSS_PlayerMenu) and a detail pane for the
-- selected entry with three pages (PSS_Detail.lua): Summary (counts and the
-- period pie), Event History and View/Edit Rule (note, expiry, W I G P C,
-- exceptions, Remove, Add Guild). With nothing selected the pane shows the
-- whole list's totals. Libraries (PSS_PlayerView.lua) works out every text
-- and does every edit; the core says when the list changed
-- (PLAYERS_CHANGED, PLAYER_BLOCKED) and the tab redraws if it shows.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M
local L = PourSocialScore_NS.L

local DETAIL_W = 380
local TOP_H = 32
local LINE_H = 16

-- the list's sort and search (Libraries); sel: the selected entry as
-- stored; row: the one table every drawn row is read into
local V = M.PSS_PlayerListNew()
local sel
local rowBuf = {}
local page, list, pane, lf, picker, searchButton
local pickCells = {}

ns.TabBuilders = ns.TabBuilders or {}

------------------------------------------------------------------------
-- List
------------------------------------------------------------------------
local function Resort()
	local n, _, countText, empty = V:Resort()
	list:SetSort(V.key, V.asc)
	list:SetCount(n)
	page.count:SetText(countText)
	list:SetEmptyText(empty)
end

local function DrawRow(row, i)
	local r = M.PSS_PlayerRow(V.index[i], rowBuf)
	local cells = row.cells
	if not r then
		for _, fs in pairs(cells) do fs:SetText("") end
		row.sel:Hide()
		return
	end
	cells.name:SetText(r.name)
	cells.name:SetTextColor(M.PSS_ClassColor(r.record and r.record.class))
	cells.server:SetText(r.server)
	cells.type:SetText(M.PSS_PlayerTypeText(r))
	cells.listed:SetText(M.PSS_PlayerListedText(r))
	cells.expire:SetText(M.PSS_PlayerExpireText(r))
	cells["metric:total"]:SetText(r.record and M.PSS_PlayerTotal(r.record) or "")
	row.sel:SetShown(r.entry == sel)
end

local function RowTip(row, i)
	local r = M.PSS_PlayerRow(V.index[i], rowBuf)
	if r then ns.Tip(row, M.PSS_PlayerTip(r)) end
end

------------------------------------------------------------------------
-- Detail pane
------------------------------------------------------------------------
-- The note and expiry boxes save to the entry that was shown when typing
-- started, even when the click that ends it selects another entry.
local function EditStart()
	pane.editEntry = sel
end

local function ConfirmRemove()
	local entry = sel
	if not entry then return end
	ns.Confirm({
		title = "Remove Player?",
		text = M.PSS_PlayerRemoveText(entry),
		accept = "Remove",
		onAccept = function()
			local pos = M.PSS_PlayerPosition(entry)
			if pos > 0 then M.PSS_RemovePlayerAt(pos) end
		end,
	})
end

local function OpenPlayerEvents(entry)
	if ns.OpenEvents then ns.OpenEvents(page, M.PSS_PlayerEventsSpec(entry), {}) end
end

local function BuildPane(parent)
	pane = ns.NewPanel(parent, true)
	pane:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -TOP_H - 4)
	pane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 8)
	pane:SetWidth(DETAIL_W)
	pane.row = {}
	-- shown for players only (NPCs and servers have no counts)
	pane.player = {}

	-- nothing selected: the whole list's totals (a click on the selected
	-- entry deselects it)
	pane.totals = ns.NewTotals(pane, page, "players", "Player Ignore List", "Select an entry to see its details.",
		M.PSS_AllPlayersSpec)

	local body = CreateFrame("Frame", nil, pane)
	body:SetAllPoints()
	pane.body = body

	pane.heading = ns.NewHeading(body, "")
	pane.heading:SetPoint("TOPLEFT", body, "TOPLEFT", 10, -8)
	pane.heading:SetPoint("RIGHT", body, "RIGHT", -10, 0)
	local dp = ns.NewDetailPages(body, -28, "players")
	pane.pages = dp

	-- Summary: the counts and the period pie
	pane.counts = ns.NewLine(dp.summary, -6)
	pane.player[#pane.player + 1] = pane.counts
	pane.summary = ns.NewSummary(dp.summary, page, -30)
	pane.sumSpec = { specFn = M.PSS_PlayerEventsSpec, who = "this player" }

	-- View/Edit Rule
	local rule = dp.rule
	local y = -2
	pane.typeLine = ns.NewLine(rule, y); y = y - LINE_H
	pane.addedLine = ns.NewLine(rule, y); y = y - LINE_H
	pane.guildLine = ns.NewLine(rule, y); y = y - LINE_H
	pane.inviteLine = ns.NewLine(rule, y); y = y - LINE_H - 6
	pane.player[#pane.player + 1] = pane.guildLine
	pane.player[#pane.player + 1] = pane.inviteLine

	-- expiry: days after the date added, 0 = never
	local expRow = ns.NewStrip(rule, y, 22, DETAIL_W - 20)
	ns.NewLabel(expRow, "Expires after")
	local exp = ns.NewNumberBox(expRow, 44)
	exp:SetPoint("LEFT", expRow, "LEFT", 90, 0)
	exp:SetMaxLetters(4)
	pane.expireNote = ns.NewText(expRow, 12)
	pane.expireNote:SetPoint("LEFT", exp, "RIGHT", 8, 0)
	ns.TipOn(exp, exp, "Days after the date added before this entry is removed by itself. 0 = never.")
	ns.OnCommit(exp, function(text)
		M.PSS_PlayerCommitExpiry(pane.editEntry or sel, text)
	end, function() ns.ShowPlayerDetail() end)
	exp:SetScript("OnEditFocusGained", EditStart)
	pane.expireBox = exp
	y = y - 26

	local noteRow = ns.NewStrip(rule, y, 22, DETAIL_W - 20)
	ns.NewLabel(noteRow, "Note")
	local note = ns.NewEditBox(noteRow, 200, 128)
	note:SetPoint("LEFT", noteRow, "LEFT", 94, 0)
	note:SetPoint("RIGHT", noteRow, "RIGHT", -4, 0)
	ns.OnCommit(note, function(text)
		M.PSS_PlayerCommitNote(pane.editEntry or sel, text)
	end, function() ns.ShowPlayerDetail() end)
	note:SetScript("OnEditFocusGained", EditStart)
	pane.noteBox = note
	y = y - 28

	-- W I G P C (ticked = allowed)
	local exRow
	pane.excl, exRow = ns.NewAllowedBoxes(rule, y, DETAIL_W - 20, "Ticked = allowed from this player, unticked = blocked.",
		function(_, box, _, e) M.PSS_PlayerToggleAllowed(sel, e.field, box:GetChecked()) end)
	pane.player[#pane.player + 1] = exRow
	y = y - 28

	-- Also on Blizzard's ignore list (off by default)
	local bzRow = ns.NewStrip(rule, y, 24, DETAIL_W - 20)
	ns.NewLabel(bzRow, "Blizzard")
	local bz = ns.NewCheck(bzRow)
	bz:SetPoint("LEFT", bzRow, "LEFT", 90, 0)
	local bzText = ns.NewText(bzRow, 12)
	bzText:SetPoint("LEFT", bz, "RIGHT", 0, 0)
	bzText:SetText(M.PSS_BLIZZARD_TEXT)
	ns.TipOn(bz, bz, M.PSS_BLIZZARD_TIP)
	bz:SetScript("OnClick", function(self) M.PSS_PlayerToggleBlizzard(sel, self:GetChecked()) end)
	pane.blizzard = bz
	pane.player[#pane.player + 1] = bzRow
	y = y - 28

	-- exceptions to the Options for this player (ticked = it happens)
	pane.exceptions = ns.NewExceptions(rule, 10, y, DETAIL_W - 20, function() ns.ShowPlayerDetail() end)
	pane.player[#pane.player + 1] = pane.exceptions.frame

	-- the rule's actions: Remove, Add Guild
	local remove = ns.NewButton(rule, "Remove", 100, ConfirmRemove)
	remove:SetPoint("BOTTOMLEFT", rule, "BOTTOMLEFT", 10, 4)
	pane.removeButton = remove
	local addGuild = ns.NewButton(rule, "Add Guild", 100, function(self)
		M.PSS_PlayerAddGuild(self.guild)
		ns.ShowPlayerDetail()
	end)
	addGuild:SetPoint("LEFT", remove, "RIGHT", 6, 0)
	ns.TipOn(addGuild, addGuild, "Adds this player's current guild to the Guild Ignore List.")
	pane.addGuild = addGuild

	-- Event History: the block history, the whole page, Reset under it
	pane.hist = ns.NewHistory(dp.history, -2, {
		empty = "Nothing blocked from this player yet.",
		open = OpenPlayerEvents,
	})
	pane.player[#pane.player + 1] = pane.hist.frame
	local reset = ns.NewButton(dp.history, L["HISTORY_RESET"] or "Reset Block History", 130, function()
		if sel then M.PSS_ResetPlayerBlockHistory(sel) end
	end)
	reset:SetPoint("BOTTOMLEFT", dp.history, "BOTTOMLEFT", 10, 4)
	pane.resetButton = reset
	pane.player[#pane.player + 1] = reset
end

-- Redraw the pane for the selected entry (none: the list's totals).
function ns.ShowPlayerDetail(newEntry)
	if not pane then return end
	local pos = M.PSS_PlayerPosition(sel)
	local r = pos > 0 and M.PSS_PlayerRow(pos, pane.row)
	pane.body:SetShown(r and true or false)
	if not r then
		sel, pane.record = nil, nil
		pane.hist:Clear()
		pane.totals:Show()
		return
	end
	pane.totals:Hide()
	local p = r.record or nil
	pane.record = p
	local isPlayer = p ~= nil
	for _, f in ipairs(pane.player) do f:SetShown(isPlayer) end
	-- NPCs and servers have no counts or history: View/Edit Rule only
	pane.pages:Limit(not isPlayer and { rule = true } or nil)

	pane.heading:SetText(M.PSS_PlayerHeading(r))
	pane.typeLine:SetText(M.PSS_PlayerTypeLine(r))
	pane.addedLine:SetText(M.PSS_PlayerAddedLine(r))
	if not pane.expireBox:HasFocus() then pane.expireBox:SetText(M.PSS_PlayerExpireBoxText(r)) end
	pane.expireNote:SetText(M.PSS_PlayerExpireNote(r))
	if not pane.noteBox:HasFocus() then pane.noteBox:SetText(r.note or "") end

	pane.addGuild:Hide()
	if not p then
		pane.hist:Clear()
		return
	end
	pane.guildLine:SetText(M.PSS_PlayerGuildLine(p))
	pane.inviteLine:SetText(M.PSS_PlayerInviteLine(p))
	local guild, listed, guildText = M.PSS_PlayerGuildState(p)
	if guild then
		pane.addGuild.guild = guild
		pane.addGuild:SetText(guildText)
		pane.addGuild:SetEnabled(not listed)
		pane.addGuild:Show()
	end

	for _, e in ipairs(M.EXCL) do pane.excl[e.cat]:SetChecked(M.PSS_PlayerAllowed(p, e.field)) end
	pane.blizzard:SetChecked(M.PSS_PlayerOnBlizzard(p))
	pane.exceptions:Set(p, "person", "this player")

	local c = M.PSS_GetPlayerBlockCounts(p)
	pane.counts:SetText(M.PSS_CountsText(c))

	-- read again only when the entry or its count changed; the block
	-- history (PourSocialScore_Logging) loads only when asked for
	pane.hist:Set(r.entry, c.total or 0, M.PSS_GetPlayerBlockHistory, newEntry)
	pane.summary:Set(M.PSS_PlayerSummarySpec(r, c, pane.sumSpec))
end

-- A block only changes the counts: the counts line, the history and the
-- Summary (the rest of the pane is as it was). Anything else: the whole pane.
function ns.ShowPlayerCounts()
	local p = pane and pane.record
	if not (p and sel and pane.body:IsShown()) then return ns.ShowPlayerDetail() end
	local c = M.PSS_GetPlayerBlockCounts(p)
	pane.counts:SetText(M.PSS_CountsText(c))
	pane.hist:Set(sel, c.total or 0, M.PSS_GetPlayerBlockHistory)
	local s = pane.sumSpec
	s.allTime = c.total or 0
	pane.summary:Set(s)
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------
local function Refresh()
	if V.dirty then Resort() else list:Redraw() end
	ns.ShowPlayerDetail()
end

local function SelectEntry(entry)
	if pane then
		-- saves what was typed first
		pane.noteBox:ClearFocus()
		pane.expireBox:ClearFocus()
		pane.editEntry = nil
	end
	sel = entry
	list:Redraw()
	ns.ShowPlayerDetail(true)
end

-- A row's right-click menu (Libraries M.PSS_PlayerMenu): the row is
-- selected first, so each entry acts on the pane's entry as its buttons do.
local function RowAct(entry, act, arg)
	if entry ~= sel then SelectEntry(entry) end
	if act == "history" then
		OpenPlayerEvents(entry)
	elseif act == "addGuild" then
		M.PSS_PlayerAddGuild(arg)
		ns.ShowPlayerDetail()
	elseif act == "noExpiry" then
		M.PSS_PlayerCommitExpiry(entry, "0")
	elseif act == "resetHistory" then
		M.PSS_ResetPlayerBlockHistory(entry)
	elseif act == "exception" then
		M.PSS_ToggleException(pane.record, "person", arg)
		ns.ShowPlayerDetail()
	elseif act == "remove" then
		ConfirmRemove()
	end
end

local function RowMenu(row, entry)
	if entry ~= sel then SelectEntry(entry) end
	ns.RowMenu(row, M.PSS_PlayerMenu(entry), function(act, arg) RowAct(entry, act, arg) end)
end

------------------------------------------------------------------------
-- Player Search results (in place of the list), as Guild Search's
------------------------------------------------------------------------
local function ClosePicker()
	if not (picker and picker:IsShown()) then return false end
	picker:Hide()
	lf:Show()
	return true
end

local function BuildPicker(parent)
	picker = ns.NewPicker(parent, lf, {
		cols = {
			{ key = "name", text = "Name" },
			{ key = "level", text = "Level", width = 44, justify = "RIGHT" },
			{ key = "class", text = "Class", width = 86 },
			{ key = "guild", text = "Guild", width = 120 },
		},
		fill = function(c, it)
			M.PSS_PlayerPickerCells(it, pickCells)
			c.name:SetText(pickCells.name)
			c.level:SetText(pickCells.level)
			c.class:SetText(pickCells.class)
			c.guild:SetText(pickCells.guild)
		end,
		toggle = M.PSS_PickerToggle,
		tickAll = M.PSS_PickerTickAll,
		save = function(items) M.PSS_PlayerPickerSave(items) end,
		close = ClosePicker,
	})
end

-- the /who answer (Libraries M.PSS_PlayerSearchFromText calls it)
local function ShowSearchResults(found, query)
	if not picker then return end
	if not found or #found == 0 then
		local text, name = M.PSS_PlayerNoneFound(query)
		if text then
			ns.Confirm({ title = "Add Player?", text = text, accept = "Add Anyway", onAccept = function() M.PSS_PlayerAddAnyway(name) end })
		end
		return
	end
	M.PSS_PlayerPickerItems(found, picker.items)
	lf:Hide()
	picker:ShowItems(M.PSS_PlayerPickerTitle(#found, query))
end

local function ConfirmPrune()
	ns.Confirm({ title = "Prune Players?", text = M.PSS_PruneText(), accept = "Prune", number = M.PSS_PRUNE_DAYS,
		numberNote = M.PSS_PruneNote, onAccept = function(days) M.PSS_PruneApply(days) end })
end

ns.TabBuilders.players = function(pg)
	page = pg

	-- top: search on the left, Add Player on the right
	local search = ns.NewSearchBox(pg, 200, "Search name, server or note", function(text)
		if V:SetFind(text) then
			Resort()
			list:Top()
		end
	end)
	search:SetPoint("TOPLEFT", pg, "TOPLEFT", 16, -6)
	pg.search = search

	pg.count = ns.NewText(pg, 12)
	pg.count:SetPoint("LEFT", search, "RIGHT", 12, 0)
	pg.count:SetAlpha(0.7)

	local add = ns.NewEditBox(pg, 150, 64, "Name-Realm")
	local function AddPlayer()
		local text = add:GetText()
		add:SetText("")
		add:ClearFocus()
		local entry = M.PSS_PlayerAddFromText(text)
		if entry then SelectEntry(entry) end
	end
	local addButton = ns.NewButton(pg, "Add Player", 100, AddPlayer)
	addButton:SetPoint("TOPRIGHT", pg, "TOPRIGHT", -8, -5)
	-- Player Search: a /who straight from the click (it needs a hardware event)
	searchButton = ns.NewButton(pg, "Player Search", 100, function()
		if M.PSS_PlayerSearchFromText(add:GetText(), ShowSearchResults) then add:SetText("") end
		add:ClearFocus()
	end)
	searchButton:SetPoint("RIGHT", addButton, "LEFT", -6, 0)
	searchButton:SetEnabled(not M.PSS_ScanCooldownActive())
	add:SetPoint("RIGHT", searchButton, "LEFT", -8, 0)
	add:SetScript("OnEnterPressed", AddPlayer)
	add:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	ns.TipOn(addButton, addButton, "Adds the player typed in the box (Name or Name-Realm). With the box empty, adds your target if it is a player of your faction. Everything from them is blocked until you tick what to allow.")
	ns.TipOn(searchButton, searchButton, "Runs a /who for the name in the box and lists the players found, so you can tick which to add. If nobody is found you can add the name anyway.\n\n/who cannot search by realm: only the name is searched for.")
	-- Prune: entries listed for a number of days or more, after a confirm
	local prune = ns.NewButton(pg, "Prune", 70, ConfirmPrune)
	prune:SetPoint("RIGHT", add, "LEFT", -16, 0)
	ns.TipOn(prune, prune, "Removes every entry added this many days ago or more (you choose the days and see how many first).")
	pg.add, pg.addButton, pg.searchButton, pg.pruneButton = add, addButton, searchButton, prune

	BuildPane(pg)

	lf = CreateFrame("Frame", nil, pg)
	lf:SetPoint("TOPLEFT", pg, "TOPLEFT", 8, -TOP_H - 4)
	lf:SetPoint("BOTTOMRIGHT", pane, "BOTTOMLEFT", -8, 0)
	list = ns.NewRows(lf, {
		rowH = 20,
		cols = {
			{ key = "name", text = "Name" },
			{ key = "server", text = "Server", width = 112 },
			{ key = "type", text = "Type", width = 72 },
			{ key = "listed", text = "Listed", width = 54, justify = "RIGHT",
				tip = "Days since the entry was added." },
			{ key = "expire", text = "Expires", width = 62, justify = "RIGHT",
				tip = "Days left before the entry is removed by itself." },
			{ key = "metric:total", text = "Blocked", width = 62, justify = "RIGHT",
				tip = "Messages and invites blocked from this player." },
		},
		sort = function(key)
			V:SortBy(key)
			Resort()
		end,
		draw = DrawRow,
		enter = RowTip,
		click = function(row, i, button)
			local pos = V.index[i]
			local entry = pos and M.PSS_PlayerEntry(pos)
			if not entry then return end
			if button == "RightButton" then
				RowMenu(row, entry)
			else
				SelectEntry(entry ~= sel and entry or nil)
			end
		end,
		emptyClick = function() if sel then SelectEntry(nil) end end,
	})
	BuildPicker(pg)
	-- the results picker closes on Back and Escape, as Guild Search's
	pg.navClose = ClosePicker
	pg.navUp = ClosePicker
	-- a tab click (PSS_Window.lua): nothing selected, the picker closed
	pg.navReset = function()
		ClosePicker()
		if sel then SelectEntry(nil) end
	end
	pg.list, pg.pane, pg.picker = list, pane, picker
	pg.stale = function()
		V.dirty = true
		searchButton:SetEnabled(not M.PSS_ScanCooldownActive())
	end
	pg.select = SelectEntry
	V.dirty = true
	return Refresh
end

-- The core says the list changed: redraw now if the tab shows, else when it
-- next shows. Blocked lines only change counts: at most 4 redraws a second.
ns.Listen("PLAYERS_CHANGED", function()
	V.dirty = true
	if page and page:IsVisible() then Refresh() end
end)

local redrawCounts = M.PSS_Throttle(function()
	if page and page:IsVisible() then
		list:Redraw()
		ns.ShowPlayerCounts()
	end
end)
ns.Listen("PLAYER_BLOCKED", function()
	if page and page:IsVisible() then redrawCounts() end
end)

-- the /who cooldown: Player Search waits with the guild scans
ns.Listen("WHOIS_COOLDOWN", function(active)
	if searchButton then searchButton:SetEnabled(not active) end
end)
