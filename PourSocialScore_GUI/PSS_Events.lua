------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - EVENTS TAB
--
-- The blocked lines of the lists: three drop-downs (Time: this session, the
-- last 24 hours, all time or a custom range; Types; Source: the lists, or
-- one entry of them), a search over player, channel and message, and
-- Time | Source | Player | Type | Channel | Message sorted by a header
-- click. Links in a message work as in chat; a double-click on a line
-- copies the message; a right-click puts its sender on or off the Player
-- Ignore List (ns.SenderMenu, PSS_History.lua). The pies, View Events and a double-click on a pane's
-- Event History open it (ns.OpenEvents) with their entry, a period and the
-- types ticked; each query is a step for back / forward. Libraries
-- (PSS_EventsView.lua) reads, filters and sorts; opening it loads
-- PourSocialScore_Logging.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M
local L = PourSocialScore_NS.L
local History = M.PSS_History

local view = M.PSS_EventsViewNew()
local cells = {}
local page, list
local ui = {}

ns.TabBuilders = ns.TabBuilders or {}

-- Filter and sort what was read, then draw the bar and the list.
local function Apply(top)
	local n = view:Apply(ui.search:GetText())
	list:SetSort(view.sortKey, view.sortAsc)
	list:SetCount(n)
	if top then list:Top() end
	ui.heading:SetText(view:Heading(n))
	ui.timeDrop:SetLabel(view:TimeLabel())
	ui.typeDrop:SetLabel(view:TypesLabel())
	ui.sourceDrop:SetLabel(view:SourceLabel())
	local custom = view.q.period == "custom"
	ui.custom:SetShown(custom)
	ui.listFrame:SetPoint("TOPLEFT", page, "TOPLEFT", 8, custom and -88 or -62)
	ui.resetButton:SetShown(view.q.scope ~= nil)
	list:SetEmptyText(view:EmptyText())
end

local function Refresh(top)
	view:Refresh()
	Apply(top)
end

-- the query changed by a drop-down: show it, as a step of its own
local function Changed()
	Refresh(true)
	ns.NavRecord()
end

local function Draw(row, i)
	local h = view.shown[i]
	local c = row.cells
	if not h then
		for _, fs in pairs(c) do fs:SetText("") end
		return
	end
	M.PSS_EventCells(view, h, cells)
	for k, fs in pairs(c) do fs:SetText(cells[k]) end
end

local clicks = {}
local function Click(row, i, button)
	if button == "RightButton" then
		local h = view.shown[i]
		if h then ns.SenderMenu(row, h.member) end
		return
	end
	if button ~= "LeftButton" then return end
	-- a double-click copies the message
	if M.PSS_DoubleClick(clicks, i) then
		local h = view.shown[i]
		if h then
			local subtitle, text = M.PSS_EventCopy(h)
			ns.CopyText({ title = "Copy Event", subtitle = subtitle, text = text })
		end
	end
end

local function ResetHistory()
	local text = view:ResetText()
	if not text then
		view:DoReset()
		Refresh(true)
		return
	end
	ns.Confirm({ title = "Reset Block History?", text = text, accept = "Reset", onAccept = function()
		view:DoReset()
		Refresh(true)
	end })
end

local function CustomBox(parent, label, x)
	local t = ns.NewText(parent, 12)
	t:SetPoint("LEFT", parent, "LEFT", x, 0)
	t:SetText(label)
	local e = ns.NewEditBox(parent, 130, 20)
	e:SetPoint("LEFT", t, "RIGHT", 8, 0)
	return e
end

ns.TabBuilders.events = function(pg)
	page = pg

	-- Events: name (n)                                  [Reset Block History]
	ui.heading = ns.NewHeading(pg, "")
	ui.heading:SetPoint("TOPLEFT", pg, "TOPLEFT", 12, -10)
	local reset = ns.NewButton(pg, L["HISTORY_RESET"] or "Reset Block History", 140, ResetHistory)
	reset:SetPoint("TOPRIGHT", pg, "TOPRIGHT", -10, -6)
	ns.TipOn(reset, reset, "Clears this entry's block history and counts.")
	ui.resetButton = reset

	-- [Time v] [Types v] [Source v]          [search player, channel or message]
	local bar = CreateFrame("Frame", nil, pg)
	bar:SetPoint("TOPLEFT", pg, "TOPLEFT", 10, -34)
	bar:SetPoint("RIGHT", pg, "RIGHT", -10, 0)
	bar:SetHeight(22)
	ui.timeDrop = ns.NewDropdown(bar, 190, function(m)
		for _, t in ipairs(M.PSS_EVENT_TIMES) do
			m:Radio(t.text, function() return (view.q.period or "all") == t.key end, function()
				view:SetPeriod(t.key)
				if t.key == "custom" then
					local from, to = view:RangeTexts()
					ui.fromBox:SetText(from)
					ui.toBox:SetText(to)
				end
				Changed()
			end)
		end
	end)
	ui.timeDrop:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
	ui.typeDrop = ns.NewDropdown(bar, 150, function(m)
		m:Button("All types", function()
			view:AllTypes()
			Changed()
		end)
		for _, cat in ipairs(History.ALL_CATS or {}) do
			m:Check(History.CAT_LABEL[cat] or cat, function() return view:TypeOn(cat) end, function()
				view:ToggleType(cat)
				Changed()
			end)
		end
	end)
	ui.typeDrop:SetPoint("LEFT", ui.timeDrop, "RIGHT", 6, 0)
	ui.sourceDrop = ns.NewDropdown(bar, 230, function(m)
		if view.q.scope then
			m:Check("Only " .. (view.name or "?"), true, function()
				view:ScopeOff()
				Changed()
			end)
		end
		for _, src in ipairs(M.PSS_EVENT_SOURCES) do
			m:Check(src.text, function() return view:SourceOn(src.key) end, function()
				view:ToggleSource(src.key)
				Changed()
			end)
		end
	end)
	ui.sourceDrop:SetPoint("LEFT", ui.typeDrop, "RIGHT", 6, 0)
	local lastFind
	ui.search = ns.NewSearchBox(bar, 240, "Search player, channel or message", function(text)
		if text ~= lastFind then
			lastFind = text
			Apply(true)
		end
	end)
	ui.search:SetPoint("RIGHT", bar, "RIGHT", 0, 0)

	-- the custom range: From [2026-10-04 13:20]  To [          ]  [Apply]
	local custom = CreateFrame("Frame", nil, pg)
	custom:SetPoint("TOPLEFT", pg, "TOPLEFT", 10, -60)
	custom:SetPoint("RIGHT", pg, "RIGHT", -10, 0)
	custom:SetHeight(22)
	custom:Hide()
	ui.custom = custom
	ui.fromBox = CustomBox(custom, "From", 0)
	ui.toBox = CustomBox(custom, "To", 190)
	ui.rangeError = ns.NewText(custom, 11)
	local apply = ns.NewButton(custom, "Apply", 70, function()
		local err = view:ApplyRange(ui.fromBox:GetText(), ui.toBox:GetText())
		ui.rangeError:SetText(err or "")
		if not err then Changed() end
	end)
	apply:SetPoint("LEFT", ui.toBox, "RIGHT", 8, 0)
	ui.rangeError:SetPoint("LEFT", apply, "RIGHT", 8, 0)
	ui.applyButton = apply
	local function enter(self) self:ClearFocus(); apply:GetScript("OnClick")(apply) end
	ui.fromBox:SetScript("OnEnterPressed", enter)
	ui.toBox:SetScript("OnEnterPressed", enter)
	ns.TipOn(ui.fromBox, ui.fromBox, "The first day and time shown, as 2026-10-05 13:20 (a day alone: from its start).")
	ns.TipOn(ui.toBox, ui.toBox, "The last day and time shown (empty: up to now; a day alone: to its end).")

	local lf = CreateFrame("Frame", nil, pg)
	lf:SetPoint("TOPLEFT", pg, "TOPLEFT", 8, -62)
	lf:SetPoint("BOTTOMRIGHT", pg, "BOTTOMRIGHT", -8, 8)
	ui.listFrame = lf
	list = ns.NewRows(lf, {
		rowH = 18, fontSize = 12, links = true,
		cols = {
			{ key = "time", text = "Time", width = 136 },
			{ key = "source", text = "Source", width = 140 },
			{ key = "member", text = "Player", width = 130 },
			{ key = "kind", text = "Type", width = 60 },
			{ key = "channel", text = "Channel", width = 120 },
			{ key = "message", text = "Message" },
		},
		sort = function(key)
			view:SortBy(key)
			Apply(true)
		end,
		draw = Draw,
		enter = function(row, i)
			local h = view.shown[i]
			if h then ns.Tip(row, M.PSS_EventTip(view, h)) end
		end,
		click = Click,
	})

	-- back / forward (PSS_Window.lua): each query a step; Events in the
	-- line by the arrows is the tab as it opens
	pg.navState = function() return view:NavKey() end
	pg.navTitle = function(key) return view:NavTitle(key) end
	pg.navApply = function(key)
		view:NavApply(key)
		Refresh(true)
	end
	pg.navReset = function()
		view:Reset()
		ui.search:SetText("")
	end
	pg.view, pg.list, pg.ui = view, list, ui
	-- hidden (another tab: its own OnHide; the window closed: pg.release,
	-- called by the window): the lines read are dropped, and read again
	-- when the tab shows
	pg.release = function()
		view:Release()
		list:SetCount(0)
	end
	pg:HookScript("OnHide", pg.release)
	return function()
		Refresh(ui.toTop)
		ui.toTop = nil
	end
end

-- Show the Events tab for spec (an entry; a whole list: that list as the
-- source; nil: every list) with opts.period and opts.cats (nil: every type).
function ns.OpenEvents(_, spec, opts)
	if not ns.ShowEventsTab then return end
	ns.ShowEventsTab(function()
		view:Open(spec, opts)
		if ui.search then ui.search:SetText("") end
		ui.toTop = true
	end)
	return view
end

-- new blocks: read the tab again while it shows, at most 4 times a second
local redraw = M.PSS_Throttle(function()
	if page and page:IsVisible() then Refresh(false) end
end)
local function OnChange()
	if page and page:IsVisible() then redraw() end
end
ns.Listen("PLAYER_BLOCKED", OnChange)
ns.Listen("GUILD_BLOCKS_CHANGED", OnChange)
ns.Listen("FILTER_HISTORY_CHANGED", OnChange)
ns.Listen("PLAYERS_CHANGED", OnChange)
ns.Listen("GUILDS_CHANGED", OnChange)
