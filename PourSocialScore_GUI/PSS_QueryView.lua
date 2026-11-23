------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE QUERY VIEW (search-helper, phase B)
--   local v = ns.NewQueryView(parent, o)
--   o = { w, h, query, params, scope, shape = "auto"|"events"|"table"|"chart",
--         deepDive, compact, from, rows, fill, detail }
--   v:SetQuery(text, params)  v:Run(load)  v:Refresh()  v:Result()  v:SetRange(range)
-- Drawing only: the model is M.PSS_QueryViewModel (Libraries). Heard events
-- only while the window shows (ns.Listen), redraws coalesced by M.PSS_Throttle.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local ERR = { 1, 0.36, 0.36 }

function ns.NewQueryView(parent, o)
	o = o or {}
	local W, H = o.w or 400, o.h or 240
	local v = CreateFrame("Frame", nil, parent)
	v:SetSize(W, H)
	local vm = M.PSS_QueryViewModel(o)
	v.vm = vm
	local top = 0
	if o.compact then
		v.line = ns.NewText(v, 11)
		v.line:SetPoint("TOPLEFT", v, "TOPLEFT", 0, 0)
		v.line:SetWidth(W - 70)
		v.line:SetWordWrap(true)
		v.line:SetNonSpaceWrap(true)
		v.line:SetHeight(26)
		v.line:SetJustifyV("TOP")
		v.lineHit = CreateFrame("Frame", nil, v)
		v.lineHit:SetPoint("TOPLEFT", v.line, "TOPLEFT", 0, 0)
		v.lineHit:SetPoint("BOTTOMRIGHT", v.line, "BOTTOMRIGHT", 0, 0)
		v.lineHit:EnableMouse(true)
		v.lineHit:SetScript("OnEnter", function(self) local t = vm:Text(); if t and t ~= "" then ns.Tip(self, t) end end)
		v.lineHit:SetScript("OnLeave", function() ns.HideTip() end)
		v.run = ns.NewButton(v, "Run", 60, function() v:Run(true) end)
		v.run:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, 0)
		top = 30
	end
	if o.deepDive then
		v.deep = ns.NewButton(v, "Open in Spyglass", 120, function()
			if ns.DeepDive then ns.DeepDive(vm:Text(), vm.params, o.from) end
		end)
		v.deep:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, -top)
		v.deep:SetScript("OnEnter", function(self) ns.Tip(self, "Open this search in Spyglass") end)
		v.deep:SetScript("OnLeave", function() ns.HideTip() end)
		top = top + 26
	end
	v.chart = ns.NewChart(v, W, H - 40 - top)
	v.chart:SetPoint("TOPLEFT", v, "TOPLEFT", 0, -top)
	v.status = ns.NewText(v, 11)
	v.status:SetPoint("BOTTOMLEFT", v, "BOTTOMLEFT", 0, 4)
	v.status:SetAlpha(0.7)
	v.statusHit = CreateFrame("Frame", nil, v)
	v.statusHit:SetPoint("TOPLEFT", v.status, "TOPLEFT", 0, 0)
	v.statusHit:SetPoint("BOTTOMRIGHT", v.status, "BOTTOMRIGHT", 0, 0)
	v.statusHit:EnableMouse(true)
	v.statusHit:SetScript("OnEnter", function(self) local _, ms = vm:Status(); if ms then ns.Tip(self, ms) end end)
	v.statusHit:SetScript("OnLeave", function() ns.HideTip() end)
	v.load = ns.NewButton(v, "Load history", 110, function() v:Run(true) end)
	v.load:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 0, 0)
	v.load:Hide()

	local function Paint()
		if vm.state == "error" then v.status:SetTextColor(ERR[1], ERR[2], ERR[3])
		else v.status:SetTextColor(1, 1, 1) end
	end

	-- the pane line: the plain summary of the search (its tooltip is the raw text)
	local function Line()
		local t = vm:Text() or ""
		if t == "" then return "" end
		local sum = M.PSS_QuerySummary(t, M.PSS_ConsoleView.boundName(t))
		return sum ~= "" and sum or "Events"
	end

	local HookDetail
	-- detail: a left click on a result row opens the row detail box (every row is hooked once; a taller list makes more later)
	function HookDetail()
		local list = v.chart.tableList
		if not o.detail or not list then return end
		if not list.pssDetailLayout then
			list.pssDetailLayout = true
			local layout = list.Layout
			list.Layout = function(self, ...) local r = layout(self, ...); HookDetail(); return r end
		end
		for _, row in pairs(list.rows or {}) do
			if not row.pssDetail then
				row.pssDetail = true
				row:HookScript("OnClick", function(self, button)
					if button ~= "LeftButton" or not self.index or not vm.set then return end
					local cm = M.PSS_ConsoleModel()
					ns.RowDetail({ title = "Event Details", rows = cm:RowDetail(vm.set, self.index), copy = cm:CopyLine(vm.set, self.index) })
				end)
			end
		end
	end

	local function Draw()
		if vm.state == "error" or not vm.set then
			v.chart:Clear()
		else
			local spec = vm.chart
			if o.shape == "events" or o.shape == "table" then spec = { kind = "table" } end
			local rb = vm.report and vm.report.bound
			if rb then
				local c = {}
				for k, x in pairs(spec or {}) do c[k] = x end
				c.bound = rb
				spec = c
			end
			v.chart:Draw(vm.set, spec or { kind = "table" })
			HookDetail()
		end
		v.status:SetText(vm:Status())
		Paint()
		if vm.state == "needsload" then v.load:Show() else v.load:Hide() end
		if v.line then v.line:SetText(Line()) end
	end

	function v:SetQuery(text, params)
		vm:SetQuery(text, params)
		if v.line then v.line:SetText(Line()) end
	end
	function v:Run(load)
		vm:Run(load, v.range)
		Draw()
	end
	function v:Refresh() v:Run(vm.loaded) end
	function v:Result() return vm.set, vm.info end
	function v:SetRange(range) v.range = range end
	function v:Resize(w, h)
		if not w or not h or w <= 0 or h <= 0 then return end
		v:SetSize(w, h)
		if v.line then v.line:SetWidth(w - 70) end
		v.chart:Resize(w, h - 40 - top)
		if vm.set then Draw() end
	end
	if o.fill then
		v:ClearAllPoints()
		v:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
		v:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
		v:HookScript("OnSizeChanged", function(_, w, h) v:Resize(w, h) end)
		local pw, ph = parent:GetWidth(), parent:GetHeight()
		if pw and ph and pw > 0 and ph > 0 then v:Resize(pw, ph) end
	end

	v:HookScript("OnShow", function()
		if vm.state == "idle" and vm.query then v:Run(false) end
	end)
	v:HookScript("OnHide", function() vm:Drop() end)

	local fn = M.PSS_Throttle(function() if v:IsVisible() then v:Refresh() end end)
	for _, ev in pairs(M.PSS_QV_EVENTS) do ns.Listen(ev, fn) end
	ns.OnPaint(Paint)

	if o.query then v:SetQuery(o.query, o.params) end
	return v
end
