------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - DETAIL PANE PARTS
--
-- The parts the Players, Guilds and Chat Filters panes share, drawn in the
-- look shown; the numbers come from Libraries (PSS_DetailQuery.lua).
--   ns.NewDetailPages(body, top, kind)   three pages picked along the bottom:
--       Summary, Event History, View/Edit Rule; dp:Select(key), dp:Limit(only)
--   ns.NewSummary(page, tabPage, top, size)   the period pie with a tick box
--       per period and View Events; sm:Set(spec)
--   ns.NewTypePie(parent, top, size, tabPage) all time by type; tp:Set(counts, title, specFn, id)
--   ns.NewTotals(pane, tabPage, kind, title, hint, allSpec)   a whole list's
--       totals (nothing selected); tt:Show(guildRows), tt:Hide()
--   ns.NewExceptions(parent, x, y, width, onChange)   a tick box per Option a
--       player, guild or member can be an exception to (ticked = it
--       happens; "(exception)" where it differs from the default);
--       ex:Set(target, scope, who [, parentOpts])
-- A slice or View Events opens the Events tab (ns.OpenEvents, from the
-- Events tab's stage); until it is there they only show their counts.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M
local History = M.PSS_History

local BAR_H = 24

------------------------------------------------------------------------
-- The three pages and the buttons along the bottom
------------------------------------------------------------------------
local PAGES = {
	{ key = "summary", text = "Summary" },
	{ key = "history", text = "Event History" },
	{ key = "rule", text = "View/Edit Rule" },
}
ns.DETAIL_PAGES = PAGES

-- the page last picked, per tab ("players", "guilds", "filters")
local picked = {}

local DP = {}
DP.__index = DP

function DP:Select(key)
	if not self[key] then key = "rule" end
	if self.only and not self.only[key] then key = "rule" end
	self.shown = key
	picked[self.kind] = key
	for i, p in ipairs(PAGES) do
		local on = p.key == key
		self[p.key]:SetShown(on)
		ns.SetTabSelected(self.buttons[i], on)
	end
end

-- only: { rule = true } to offer just that page (nil: all three)
function DP:Limit(only)
	self.only = only
	for i, p in ipairs(PAGES) do
		local on = not only or only[p.key] == true
		self.buttons[i]:SetEnabled(on)
		self.buttons[i]:SetAlpha(on and 1 or 0.4)
	end
	if only and not only[self.shown] then self:Select("rule") end
end

-- body: the pane body; top: where the pages start (below the heading);
-- kind: remembers the page picked on this tab
function ns.NewDetailPages(body, top, kind)
	local dp = setmetatable({ kind = kind, buttons = {} }, DP)
	for _, p in ipairs(PAGES) do
		local f = CreateFrame("Frame", nil, body)
		f:SetPoint("TOPLEFT", body, "TOPLEFT", 0, top)
		f:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, BAR_H + 10)
		f:Hide()
		dp[p.key] = f
	end
	local bar = CreateFrame("Frame", nil, body)
	bar:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 8, 6)
	bar:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -8, 6)
	bar:SetHeight(BAR_H)
	dp.bar = bar
	local n = #PAGES
	for i, p in ipairs(PAGES) do
		dp.buttons[i] = ns.NewTab(bar, p.text, function() dp:Select(p.key) end)
	end
	-- equal widths across the bar
	local function Lay()
		local w = bar:GetWidth()
		if not w or w <= 0 then return end
		local bw = (w - (n - 1) * 4) / n
		for i, b in ipairs(dp.buttons) do
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", bar, "TOPLEFT", (i - 1) * (bw + 4), 0)
			b:SetSize(bw, BAR_H)
		end
	end
	bar:SetScript("OnSizeChanged", Lay)
	Lay()
	dp:Select(picked[kind] or "summary")
	return dp
end

------------------------------------------------------------------------
-- Summary: a pie of this session / last 24 hours / all time, a tick box
-- per period (all time starts off; off takes its slice out), the "Stored:"
-- line and View Events. The ticks are shared by every pane (Libraries).
------------------------------------------------------------------------
local summaries, typePies = {}, {}

local function CanOpen() return ns.OpenEvents ~= nil end

local function OpenEvents(tabPage, spec, period, cats)
	if ns.OpenEvents then ns.OpenEvents(tabPage, spec, { period = period, cats = cats }) end
end

-- every pie again (a period or type tick changed)
local function RedrawAll()
	for _, sm in ipairs(summaries) do sm:Refresh() end
	for _, tp in ipairs(typePies) do if tp.counts then tp:Set(tp.counts, tp.title, tp.specFn, tp.id) end end
end

-- a tick box with its colour, label and count; a click on the colour or
-- the label ticks it too. onClick(box) after either.
local function NewKey(parent, countX, onClick)
	local c = ns.NewCheck(parent)
	c:SetSize(18, 18)
	local sq = parent:CreateTexture(nil, "ARTWORK")
	sq:SetSize(10, 10)
	sq:SetPoint("LEFT", c, "RIGHT", 2, 0)
	local t = ns.NewText(parent, 12)
	t:SetPoint("LEFT", sq, "RIGHT", 6, 0)
	t:SetJustifyH("LEFT")
	local n = ns.NewText(parent, 12)
	n:SetPoint("LEFT", c, "RIGHT", countX, 0)
	n:SetJustifyH("LEFT")
	local hit = CreateFrame("Button", nil, parent)
	hit:SetPoint("TOPLEFT", c, "TOPRIGHT", 0, 0)
	hit:SetPoint("BOTTOMLEFT", c, "BOTTOMRIGHT", 0, 0)
	hit:SetWidth(countX + 50)
	hit:SetScript("OnClick", function()
		c:SetChecked(not c:GetChecked())
		onClick(c)
	end)
	c:SetScript("OnClick", function() onClick(c) end)
	c.square, c.label, c.count, c.hit = sq, t, n, hit
	return c
end

local SM = {}
SM.__index = SM

local BuildSummary

function SM:Refresh()
	if not self.page:IsVisible() or not self.spec then return end
	if not self.pie then BuildSummary(self) end
	local v = M.PSS_SummaryValues(self.spec, self.values)
	for _, per in ipairs(M.PSS_PERIODS) do self.boxes[per.key].count:SetText(tostring(v[per.key])) end
	M.PSS_PeriodSlices(v, self.slices, self.map, self.pool)
	self.pie:Set(self.slices)
	local s = self.spec
	self.where:SetText(s.noWhere and "" or M.PSS_StoredText(s.owner, s.allTime or 0, s.who))
	self.empty:SetShown(v.all == 0 and v.session == 0 and v.day == 0)
	self.viewButton:SetShown(CanOpen())
end

-- spec: what M.PSS_SummaryValues reads (owner, allTime, counts, recent,
-- prefix, recentByCat) plus title, specFn(id) / id (the Events spec, made
-- only when opened), noWhere (no "Stored:" line) and who ("this player")
function SM:Set(spec)
	self.spec = spec
	self:Refresh()
end

-- key: a period (a slice), or nil (View Events: the widest ticked)
function SM:Open(key)
	local s = self.spec
	if not s then return end
	local events = s.specFn and s.specFn(s.id) or nil
	local period
	if key == nil then period = M.PSS_WidestPeriodOn() elseif key ~= "all" then period = key end
	OpenEvents(self.tabPage, events, period, s.counts and M.PSS_TypesOn() or nil)
end

-- the pie, the tick boxes and View Events: made the first time the page shows
function BuildSummary(sm)
	local page, top = sm.page, sm.top
	local SIZE = sm.size or 116
	sm.pie = ns.NewPie(page, SIZE, function(i) if CanOpen() then sm:Open(sm.map[i]) end end)
	sm.pie.frame:SetPoint("TOPLEFT", page, "TOPLEFT", 18, top)
	sm.pie.tip = function(i)
		return M.PSS_PeriodTip(sm.spec.title, sm.slices[i], CanOpen(), sm.spec.counts ~= nil)
	end
	sm.empty = ns.NewText(page, 11)
	sm.empty:SetPoint("CENTER", sm.pie.frame, "CENTER", 0, 0)
	sm.empty:SetAlpha(0.5)
	sm.empty:SetText("Nothing yet")

	-- a tick box per period: its colour, name and count
	local x, y = SIZE + 40, top - (sm.size and 2 or 8)
	for _, per in ipairs(M.PSS_PERIODS) do
		local c = NewKey(page, sm.size and 104 or 128, function(self)
			M.PSS_SetPeriodOn(per.key, self:GetChecked())
			for _, other in ipairs(summaries) do
				if other.boxes[per.key] then other.boxes[per.key]:SetChecked(M.PSS_PeriodOn(per.key)) end
			end
			RedrawAll()
		end)
		c:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
		c:SetChecked(M.PSS_PeriodOn(per.key))
		c.square:SetColorTexture(per.r, per.g, per.b, 0.9)
		c.label:SetText(per.text)
		c.count:SetTextColor(per.r, per.g, per.b)
		local tip = "Shows " .. string.lower(per.text) .. " in the pie."
		ns.TipOn(c, c, tip)
		ns.TipOn(c.hit, c.hit, tip)
		sm.boxes[per.key] = c
		y = y - 26
	end

	-- where the blocks are: log / kept / waiting / expired
	sm.where = ns.NewText(page, 11)
	sm.where:SetPoint("TOPLEFT", page, "TOPLEFT", 12, top - SIZE - 12)
	sm.where:SetPoint("RIGHT", page, "RIGHT", -10, 0)
	sm.where:SetJustifyH("LEFT")
	sm.where:SetWordWrap(true)
	sm.where:SetAlpha(0.7)

	-- View Events at the top right of the page
	local view = ns.NewButton(page, "View Events", 96, function() sm:Open(nil) end)
	view:SetPoint("TOPRIGHT", page, "TOPRIGHT", -8, -6)
	ns.TipOn(view, view, "These events in the Events tab: the widest period and the types ticked (loads the block history).")
	sm.viewButton = view

	summaries[#summaries + 1] = sm
end

-- page: the Summary page; tabPage: the tab; top: where the pie starts;
-- size: the pie (116 when nil)
function ns.NewSummary(page, tabPage, top, size)
	local sm = setmetatable({ page = page, tabPage = tabPage, top = top, size = size, slices = {}, map = {},
		pool = {}, values = {}, boxes = {} }, SM)
	page:HookScript("OnShow", function() sm:Refresh() end)
	return sm
end

------------------------------------------------------------------------
-- A pie of all-time blocks by type, with a tick box per type blocked (a
-- whole list, a default guild list), one line each: the colour, the type
-- and its count. Unticked, a type leaves this pie and the counts of every
-- period pie (Libraries keeps the ticks); its count stays in the legend.
------------------------------------------------------------------------
local TYPE_SLOTS = 7
local KEY_H = 18

local TP = {}
TP.__index = TP

function TP:Build()
	local f, size, top = self.frame, self.size, self.top
	self.pie = ns.NewPie(f, size, function(i)
		local sl = self.slices[i]
		if not (sl and sl.cat and CanOpen()) then return end
		local spec = self.specFn and self.specFn(self.id) or nil
		OpenEvents(self.tabPage, spec, M.PSS_WidestPeriodOn(), { [sl.cat] = true })
	end)
	self.pie.frame:SetPoint("TOPLEFT", f, "TOPLEFT", 18, top)
	self.pie.tip = function(i)
		local sl = self.slices[i]
		return ("%s\n%s: %d blocked (all time)"):format(self.title or "", sl.text, sl.value or 0)
			.. (CanOpen() and "\n\n|cffaaaaaaClick: these events in the Events tab.|r" or "")
	end
	self.keys = {}
	for i = 1, TYPE_SLOTS do
		local k = {}
		local c = NewKey(f, 104, function(btn)
			if not k.cat then return end
			M.PSS_SetTypeOff(k.cat, not btn:GetChecked())
			RedrawAll()
		end)
		c:SetPoint("TOPLEFT", f, "TOPLEFT", size + 40, top - 2 - (i - 1) * KEY_H)
		c.count:SetTextColor(1, 1, 1)
		local tip = "Shows this type in the pies (every period pie counts the ticked types only)."
		ns.TipOn(c, c, tip)
		ns.TipOn(c.hit, c.hit, tip)
		k.check, k.sq, k.text, k.count = c, c.square, c.label, c.count
		self.keys[i] = k
	end
	typePies[#typePies + 1] = self
	self.empty = ns.NewText(f, 11)
	self.empty:SetPoint("CENTER", self.pie.frame, "CENTER", 0, 0)
	self.empty:SetAlpha(0.5)
	self.empty:SetText("Nothing yet")
end

function TP:Set(counts, title, specFn, id)
	if not self.pie then self:Build() end
	self.title, self.counts, self.specFn, self.id = title, counts, specFn, id
	local n = M.PSS_TypeSlices(counts, self.slices, TYPE_SLOTS)
	for i = 1, TYPE_SLOTS do
		local k, sl = self.keys[i], self.slices[i]
		local on = i <= n
		k.cat = on and sl.cat or nil
		if on then
			k.check:SetChecked(not sl.off)
			k.sq:SetColorTexture(sl.r, sl.g, sl.b, sl.off and 0.3 or 0.9)
			k.text:SetText(sl.text)
			k.count:SetText(tostring(sl.value))
		end
		k.check:SetShown(on)
		k.sq:SetShown(on)
		k.text:SetShown(on)
		k.count:SetShown(on)
		k.check.hit:SetShown(on)
	end
	self.count = n
	self.pie:Set(self.slices)
	self.empty:SetShown(n == 0)
end

function ns.NewTypePie(parent, top, size, tabPage)
	return setmetatable({ frame = parent, top = top, size = size or 84, slices = {}, tabPage = tabPage }, TP)
end

------------------------------------------------------------------------
-- A whole list's totals, shown in a tab's pane when nothing on it is
-- selected: its blocks this session / last 24 hours / all time and by
-- type (Libraries M.PSS_TotalsView). Nothing loads PourSocialScore_Logging.
------------------------------------------------------------------------
local TT = {}
TT.__index = TT

function TT:Show(guildRows)
	self.frame:Show()
	local v = M.PSS_TotalsView(self.kind, self.view, guildRows)
	self.info:SetText(v.info)
	local s = self.spec
	s.allTime, s.counts, s.recent, s.prefix = v.total, v.counts, v.recent, v.prefix
	self.summary:Set(s)
	self.typePie:Set(v.counts, self.title, self.specFn, nil)
end

function TT:Hide() self.frame:Hide() end

function ns.NewTotals(pane, tabPage, kind, title, hint, allSpec)
	local tt = setmetatable({ kind = kind, title = title, view = {} }, TT)
	if allSpec then
		-- a copy each time: a slice sets the period it opens on
		tt.specFn = function()
			local spec = {}
			for k, v in pairs(allSpec()) do spec[k] = v end
			return spec
		end
	end
	tt.spec = { title = title, noWhere = true, specFn = tt.specFn }
	local f = CreateFrame("Frame", nil, pane)
	f:SetAllPoints()
	f:Hide()
	tt.frame = f
	tt.heading = ns.NewHeading(f, title)
	tt.heading:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
	tt.info = ns.NewText(f, 12)
	tt.info:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28)
	tt.info:SetPoint("RIGHT", f, "RIGHT", -10, 0)
	tt.info:SetJustifyH("LEFT")
	tt.info:SetText(hint)
	tt.summary = ns.NewSummary(f, tabPage, -52, 84)
	tt.typePie = ns.NewTypePie(f, -52 - 84 - 10, 84, tabPage)
	return tt
end

------------------------------------------------------------------------
-- Exceptions (3.4.0.22, Dan): a tick box per Option a player, guild or
-- member can be an exception to, two to a row. Ticked = it happens for
-- this entry; a box that differs from the default (the Options tab, or a
-- member's guild) is marked "(exception)", and setting it back removes the
-- exception (Libraries M.PSS_ExceptionState / M.PSS_SetException).
------------------------------------------------------------------------
local EX = {}
EX.__index = EX

function EX:Set(target, scope, who, parentOpts)
	self.target, self.scope, self.who, self.parentOpts = target, scope, who, parentOpts
	self.heading:SetText(M.PSS_ExceptionHeading(who))
	for _, b in ipairs(self.boxes) do
		local on, isEx, base = M.PSS_ExceptionState(target, b.opt.key, parentOpts)
		b:SetChecked(on)
		b.label:SetText(M.PSS_ExceptionText(b.opt, isEx))
		b.tip = M.PSS_ExceptionTip(b.opt, who, base)
	end
end

-- ex.frame: placed at (x, y) on parent, width wide; ex.height its height
function ns.NewExceptions(parent, x, y, width, onChange)
	local ex = setmetatable({ boxes = {} }, EX)
	local opts = M.PSS_OverrideOptions()
	local f = CreateFrame("Frame", nil, parent)
	ex.frame = f
	ex.height = 18 + math.ceil(#opts / 2) * 24
	f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	f:SetSize(width, ex.height)
	ex.heading = ns.NewText(f, 12)
	ex.heading:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	ex.heading:SetWidth(width)
	ex.heading:SetJustifyH("LEFT")
	ex.heading:SetWordWrap(false)
	local colW = (width - 6) / 2
	for n, o in ipairs(opts) do
		local c = ns.NewCheck(f)
		local col, r = (n - 1) % 2, math.floor((n - 1) / 2)
		c:SetPoint("TOPLEFT", f, "TOPLEFT", col * (colW + 6), -16 - r * 24)
		c.opt = o
		c.label = ns.NewText(f, 12)
		c.label:SetPoint("LEFT", c, "RIGHT", 0, 0)
		c.label:SetWidth(colW - 24)
		c.label:SetJustifyH("LEFT")
		c.label:SetWordWrap(false)
		c:SetScript("OnClick", function(self)
			if not ex.target then return end
			M.PSS_SetException(ex.target, ex.scope, o.key, self:GetChecked(), ex.parentOpts)
			if onChange then onChange() end
		end)
		c:SetScript("OnEnter", function(self) if self.tip then ns.Tip(self, self.tip) end end)
		c:SetScript("OnLeave", ns.HideTip)
		ex.boxes[#ex.boxes + 1] = c
	end
	return ex
end
