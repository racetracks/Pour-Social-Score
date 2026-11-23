------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - CHART KIT (search-helper, phase B, STP-00253)
--
-- One chart for every result of a query, the same in all three looks.
--   local chart = ns.NewChart(parent, w, h)
--   chart:Draw(set, spec)   spec = { kind, x, y, series, stack, top, title, pending }
--   chart:Kind()            the kind last drawn, or nil
--   chart:Clear()           hide everything it made
-- Kinds: column, bar, line, area, donut, heat, number, table. A set is a
-- record set (M.PSS_Set); x = spec.x or the first column, the values =
-- spec.y or every later column whose first row is a number. Caps: 60 bars,
-- 6 series, 8 slices (one "other" holds the rest); heat keeps the first 7 x
-- and 24 y values. Every object is pooled and reused; the look repaints in
-- place (one ns.OnPaint per chart, made at build).
-- Never does: OnUpdate (the pie keeps its own), a frame per Draw, a read of
-- saved data, any query or counting logic.
-- Loaded with PourSocialScore_GUI.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local type, tonumber, tostring, floor, ceil, max, min = type, tonumber, tostring, math.floor, math.ceil, math.max, math.min
local format, concat = string.format, table.concat

local MEASURE_ROWS = 100
local PAD, AXIS_W, LABEL_W, AXIS_H, TITLE_H, PEND_H = 8, 40, 80, 16, 16, 14
local CAP_BARS, CAP_SERIES, CAP_SLICES, CAP_HEAT_X, CAP_HEAT_Y, KEEP_LISTS = 60, 6, 8, 7, 24, 4

local function Fmt(v)
	if v == floor(v) then return tostring(v) end
	return format("%.2f", v)
end

local function Num(v) return tonumber(v) or 0 end

-- the colour of an object: its index (accent, a series, "other") and alpha
local function Paint(o)
	local r, g, b
	if o.cc == "accent" then r, g, b = ns.Accent() else r, g, b = ns.ChartColor(o.cc) end
	(o.tex or o):SetColorTexture(r, g, b, o.ca or 1)
end

local function OnEnter(self) ns.Tip(self, { title = self.tipTitle, text = self.tipText }) end
local function OnLeave() ns.HideTip() end

local MAKE = {}
function MAKE.bars(f)
	local b = CreateFrame("Button", nil, f)
	b.tex = b:CreateTexture(nil, "ARTWORK")
	b.tex:SetAllPoints(b)
	b:SetScript("OnEnter", OnEnter)
	b:SetScript("OnLeave", OnLeave)
	return b
end
MAKE.cells = MAKE.bars
function MAKE.hits(f)
	local b = CreateFrame("Button", nil, f)
	b:SetScript("OnEnter", OnEnter)
	b:SetScript("OnLeave", OnLeave)
	return b
end
function MAKE.segs(f) return f:CreateLine(nil, "ARTWORK") end
function MAKE.fills(f) return f:CreateTexture(nil, "BACKGROUND") end

local function Acq(f, name)
	local c = f.c[name] + 1
	f.c[name] = c
	local p = f.p[name]
	local o = p[c]
	if not o then o = MAKE[name](f); p[c] = o end
	o:Show()
	return o
end

local function At(f, o, x, y, w, h)
	o:ClearAllPoints()
	o:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, y)
	o:SetSize(w, h)
end

local function Clear(f)
	for name, p in pairs(f.p) do
		for i = 1, #p do p[i]:Hide() end
		f.c[name] = 0
	end
	for i = 1, 4 do f.grid[i]:Hide() end
	for i = 1, 2 do f.ylab[i]:Hide() end
	for i = 1, 3 do f.xlab[i]:Hide() end
	f.noText:Hide(); f.pendText:Hide(); f.titleText:Hide(); f.num:Hide(); f.numName:Hide()
	if f.pie then f.pie.frame:Hide() end
	for _, t in pairs(f.lists) do t.frame:Hide() end
end

-- the plot rectangle: x0, y0 (from the bottom), width, height
local function Plot(f, kind, spec)
	local top = PAD + (spec.title and TITLE_H or 0) + (spec.pending == true and PEND_H or 0)
	local y0 = PAD + AXIS_H
	local x0 = PAD + (kind == "bar" and LABEL_W or AXIS_W)
	return x0, y0, f.w - x0 - PAD, f.h - top - y0
end

-- grid, the two y labels and the three x labels
local function Frame(f, x0, y0, pw, ph, mx, xs, ytop, ybot)
	local px = ns.OnePixel(f)
	for i = 1, 4 do
		local g = f.grid[i]
		At(f, g, x0, y0 + (i - 1) / 3 * ph, pw, px)
		g:Show()
	end
	f.ylab[1]:ClearAllPoints()
	f.ylab[1]:SetPoint("TOPLEFT", f, "BOTTOMLEFT", PAD, y0 + ph)
	f.ylab[1]:SetText(ytop or Fmt(mx))
	f.ylab[2]:ClearAllPoints()
	f.ylab[2]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, y0)
	f.ylab[2]:SetText(ybot or "0")
	local n = #xs
	if n > 0 then
		local xl = f.xlab
		xl[1]:ClearAllPoints(); xl[1]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x0, PAD); xl[1]:SetText(tostring(xs[1]))
		xl[2]:ClearAllPoints(); xl[2]:SetPoint("BOTTOM", f, "BOTTOMLEFT", x0 + pw / 2, PAD); xl[2]:SetText(tostring(xs[ceil(n / 2)]))
		xl[3]:ClearAllPoints(); xl[3]:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", x0 + pw, PAD); xl[3]:SetText(tostring(xs[n]))
		for i = 1, 3 do xl[i]:Show() end
	end
	f.ylab[1]:Show(); f.ylab[2]:Show()
end

-- x column and value columns of a set
local function Cols(set, spec)
	local xc = spec.x and M.PSS_SetCol(set, spec.x) or 1
	local ys = {}
	local y = spec.y
	if type(y) == "string" then y = { y } end
	if y then
		for _, name in ipairs(y) do
			local c = M.PSS_SetCol(set, name)
			if c then ys[#ys + 1] = c end
		end
	else
		local r1 = set[1]
		for c = 1, #set.cols do
			if c ~= xc and r1 and tonumber(r1[c]) then ys[#ys + 1] = c end
		end
	end
	return xc, ys
end

local DRAW = {}

local function DrawBars(f, set, spec, horizontal)
	local xc, ys = Cols(set, spec)
	local stack = spec.stack and #ys > 1
	local nser = stack and #ys or 1
	local n = set.n
	local cap = CAP_BARS
	if type(spec.top) == "number" and spec.top > 0 and spec.top < cap then cap = floor(spec.top) end
	local cnt = min(n, cap)
	local xs, vals = {}, {}
	for i = 1, cnt do
		local r = set[i]
		xs[i] = r[xc]
		local v = {}
		for s = 1, nser do v[s] = Num(r[ys[s]]) end
		vals[i] = v
	end
	local hasOther = n > cnt
	if hasOther then
		local v = {}
		for s = 1, nser do v[s] = 0 end
		for i = cnt + 1, n do
			for s = 1, nser do v[s] = v[s] + Num(set[i][ys[s]]) end
		end
		cnt = cnt + 1
		xs[cnt], vals[cnt] = "other", v
	end
	local kind = horizontal and "bar" or "column"
	local x0, y0, pw, ph = Plot(f, kind, spec)
	local mx = 0
	for i = 1, cnt do
		local t = 0
		for s = 1, nser do
			if stack then t = t + vals[i][s] else t = max(t, vals[i][s]) end
		end
		mx = max(mx, t)
	end
	if mx <= 0 then mx = 1 end
	local px = ns.OnePixel(f)
	local names = set.cols
	local step = (horizontal and ph or pw) / cnt
	for i = 1, cnt do
		local acc = 0
		for s = 1, nser do
			local v = vals[i][s]
			local len = max(v / mx * (horizontal and pw or ph), px)
			local o = Acq(f, "bars")
			if horizontal then
				At(f, o, x0 + acc, y0 + ph - i * step, len, max(step - px, px))
			else
				At(f, o, x0 + (i - 1) * step, y0 + acc, max(step - px, px), len)
			end
			if stack then acc = acc + len end
			o.cc = (hasOther and i == cnt and not stack) and "other" or (stack and s or 1)
			o.ca = 1
			Paint(o)
			o.tipTitle = tostring(xs[i])
			o.tipText = tostring(names[ys[s]] or "") .. ": " .. tostring(v)
		end
	end
	Frame(f, x0, y0, pw, ph, mx, xs)
end
DRAW.column = function(f, set, spec) DrawBars(f, set, spec, false) end
DRAW.bar = function(f, set, spec) DrawBars(f, set, spec, true) end

local function DrawLines(f, set, spec, area)
	local xc, ys = Cols(set, spec)
	local n = min(set.n, CAP_BARS)
	local nser = #ys
	local names = {}
	local shown = min(nser, CAP_SERIES)
	for s = 1, shown do names[s] = tostring(set.cols[ys[s]]) end
	local series = nser > CAP_SERIES and CAP_SERIES + 1 or nser
	if nser > CAP_SERIES then names[series] = "other" end
	local xs, vals = {}, {}
	for s = 1, series do vals[s] = {} end
	local mx = 0
	for i = 1, n do
		local r = set[i]
		xs[i] = r[xc]
		for s = 1, shown do
			local v = Num(r[ys[s]])
			vals[s][i] = v
			mx = max(mx, v)
		end
		if series > shown then
			local t = 0
			for c = shown + 1, nser do t = t + Num(r[ys[c]]) end
			vals[series][i] = t
			mx = max(mx, t)
		end
	end
	if mx <= 0 then mx = 1 end
	local x0, y0, pw, ph = Plot(f, area and "area" or "line", spec)
	local px = ns.OnePixel(f)
	local function PX(i) return n > 1 and x0 + (i - 1) / (n - 1) * pw or x0 + pw / 2 end
	local bw = pw / n
	for s = 1, series do
		local cc = (series > shown and s == series) and "other" or s
		local v = vals[s]
		for i = 1, n - 1 do
			local l = Acq(f, "segs")
			l:SetThickness(2 * px)
			l:SetStartPoint("BOTTOMLEFT", f, PX(i), y0 + v[i] / mx * ph)
			l:SetEndPoint("BOTTOMLEFT", f, PX(i + 1), y0 + v[i + 1] / mx * ph)
			l.cc, l.ca = cc, 1
			Paint(l)
		end
		if area then
			for i = 1, n do
				local o = Acq(f, "fills")
				At(f, o, PX(i) - bw / 2, y0, bw, max(v[i] / mx * ph, px))
				o.cc, o.ca = cc, 0.25
				Paint(o)
			end
		end
	end
	for i = 1, n do
		local h = Acq(f, "hits")
		At(f, h, x0 + (i - 1) * bw, y0, bw, ph)
		local t = {}
		for s = 1, series do t[s] = names[s] .. ": " .. tostring(vals[s][i]) end
		h.tipTitle = tostring(xs[i])
		h.tipText = concat(t, "\n")
	end
	Frame(f, x0, y0, pw, ph, mx, xs)
end
DRAW.line = function(f, set, spec) DrawLines(f, set, spec, false) end
DRAW.area = function(f, set, spec) DrawLines(f, set, spec, true) end

DRAW.donut = function(f, set, spec)
	local xc, ys = Cols(set, spec)
	local vc = ys[1] or 2
	if not f.pie then
		f.pie = ns.NewPie(f, min(f.w, f.h) - 2 * PAD)
		f.pie.frame:SetPoint("CENTER", f, "CENTER", 0, 0)
		f.pieLabels, f.pieVals = {}, {}
		f.pie.tip = function(i) return tostring(f.pieLabels[i]) .. ": " .. tostring(f.pieVals[i]) end
	end
	local n = set.n
	local cnt = min(n, CAP_SLICES)
	local slices, labels, vals = {}, f.pieLabels, f.pieVals
	for i = 1, cnt do
		local r = set[i]
		local r_, g, b = ns.ChartColor(i)
		labels[i], vals[i] = r[xc], Num(r[vc])
		slices[i] = { value = vals[i], r = r_, g = g, b = b, text = tostring(labels[i]) }
	end
	if n > cnt then
		local t = 0
		for i = cnt + 1, n do t = t + Num(set[i][vc]) end
		cnt = cnt + 1
		labels[cnt], vals[cnt] = "other", t
		local r_, g, b = ns.ChartColor("other")
		slices[cnt] = { value = t, r = r_, g = g, b = b, text = "other" }
	end
	for i = cnt + 1, #labels do labels[i], vals[i] = nil, nil end
	f.pie.frame:Show()
	f.pie:Set(slices)
end

DRAW.heat = function(f, set, spec)
	local xs, ys, xi, yi, cell = {}, {}, {}, {}, {}
	local mx = 0
	for i = 1, set.n do
		local r = set[i]
		local x, y = r[1], r[2]
		if not xi[x] and #xs < CAP_HEAT_X then xs[#xs + 1] = x; xi[x] = #xs end
		if not yi[y] and #ys < CAP_HEAT_Y then ys[#ys + 1] = y; yi[y] = #ys end
		if xi[x] and yi[y] then
			local k = xi[x] * 100 + yi[y]
			cell[k] = (cell[k] or 0) + Num(r[3])
			mx = max(mx, cell[k])
		end
	end
	if mx <= 0 then mx = 1 end
	local nx, ny = #xs, #ys
	local x0, y0, pw, ph = Plot(f, "heat", spec)
	local cw, ch = pw / nx, ph / ny
	local px = ns.OnePixel(f)
	local steps = ns.CHART.heatSteps
	for a = 1, nx do
		for b = 1, ny do
			local v = cell[a * 100 + b] or 0
			local o = Acq(f, "cells")
			At(f, o, x0 + (a - 1) * cw, y0 + ph - b * ch, max(cw - px, px), max(ch - px, px))
			o.cc = "accent"
			o.ca = v > 0 and steps[ceil(v / mx * 5)] or 0.05
			Paint(o)
			o.tipTitle = tostring(xs[a])
			o.tipText = tostring(ys[b]) .. ": " .. tostring(v)
		end
	end
	Frame(f, x0, y0, pw, ph, mx, xs, tostring(ys[1]), tostring(ys[ny]))
end

DRAW.number = function(f, set, spec)
	local r = set[1]
	local name, val
	for c = 1, #set.cols do
		if r and tonumber(r[c]) then name, val = set.cols[c], r[c]; break end
	end
	f.num:ClearAllPoints(); f.num:SetPoint("CENTER", f, "CENTER", 0, 10)
	f.num:SetText(tostring(val)); f.num:Show()
	f.numName:ClearAllPoints(); f.numName:SetPoint("CENTER", f, "CENTER", 0, -14)
	f.numName:SetText(tostring(name)); f.numName:Show()
end

DRAW.table = function(f, set, spec)
	local idx = M.PSS_ReportCols(set, spec.profile or f.profile or "log", spec.bound)
	local cols, src = {}, set.cols
	for i = 1, idx and #idx or #src do cols[i] = src[idx and idx[i] or i] end
	local kinds = M.PSS_SetKinds(set)
	local sig = concat(cols, "\t") .. "\n" .. (idx and concat(idx, ",") or "")
	local t = f.lists[sig]
	if not t then
		if #f.listOrder >= KEEP_LISTS then
			local old = table.remove(f.listOrder, 1)
			f.lists[old].frame:Hide()
			f.lists[old] = nil
		end
		t = { set = set, idx = idx }
		local c = CreateFrame("Frame", nil, f)
		c:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
		c:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
		t.frame = c
		f.lists[sig] = t
		f.listOrder[#f.listOrder + 1] = sig
		local lc = {}
		local ms = f.measure
		if not ms then
			ms = ns.NewText(f, 12)
			ms:Hide()
			f.measure = ms
		end
		local need = {}
		for i = 1, #cols do
			local ci = idx and idx[i] or i
			ms:SetText(cols[i])
			local mx = ms:GetStringWidth() or 0
			for r = 1, math.min(#set, MEASURE_ROWS) do
				ms:SetText(M.PSS_CellText(cols[i], set[r][ci], kinds and kinds[cols[i]]))
				local sw = ms:GetStringWidth() or 0
				if sw > mx then mx = sw end
			end
			need[i] = mx
		end
		local avail = f.w - 2 * PAD - 22
		local widths = M.PSS_TableWidths(cols, avail, need, idx and M.PSS_KeepCols(cols) or nil)
		local used, open = 0, nil
		for i = 1, #cols do
			if widths[i] then used = used + widths[i] else open = i end
		end
		if open and avail - used <= 0 then widths[open] = 0 end
		for i = 1, #cols do
			local lab = M.PSS_FieldLabel(cols[i])
			lc[i] = { key = "c" .. i, text = cols[i], width = widths[i],
				tip = { title = cols[i], text = (lab ~= cols[i] and (lab .. "\n") or "") .. "Click to sort." } }
		end
		t.list = ns.NewRows(c, { rowH = 18, cols = lc,
		enter = function(row, i)
			local r, ks = t.set[i], M.PSS_SetKinds(t.set)
			local lines, head = nil, nil
			for k = 1, #cols do
				local raw = r[t.idx and t.idx[k] or k]
				local txt = M.PSS_CellText(cols[k], raw, ks and ks[cols[k]])
				local fs = row.cells["c" .. k]
				local cut = fs and fs.IsTruncated and fs:IsTruncated()
				if raw ~= nil and (txt ~= tostring(raw) or cut) then
					head = head or tostring(raw)
					lines = (lines and (lines .. "\n") or "") .. cols[k] .. ": " .. tostring(raw) .. (txt ~= tostring(raw) and ("  " .. txt) or "")
				end
			end
			if lines then ns.Tip(row, { title = head, text = lines }) end
		end,
		draw = function(row, i)
			local r = t.set[i]
			local ks = M.PSS_SetKinds(t.set)
			for k = 1, #cols do
				local ci = t.idx and t.idx[k] or k
				row.cells["c" .. k]:SetText(M.PSS_CellText(cols[k], r[ci], ks and ks[cols[k]]))
			end
		end })
	end
	t.set = set
	t.frame:ClearAllPoints()
	t.frame:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + (spec.title and TITLE_H or 0) + (spec.pending == true and PEND_H or 0)))
	t.frame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
	t.frame:Show()
	t.list:SetCount(set.n)
	t.list:Redraw()
	f.tableList = t.list
end

local function Purge(f)
	for sig, t in pairs(f.lists) do
		if t.list == nil then
			t.frame:Hide()
			f.lists[sig] = nil
			for i = #f.listOrder, 1, -1 do
				if f.listOrder[i] == sig then table.remove(f.listOrder, i) end
			end
		end
	end
end

local function Draw(f, set, spec)
	spec = spec or {}
	Clear(f)
	f.kind = spec.kind
	if not set or set.n == 0 or not DRAW[spec.kind] then
		f.noText:Show()
		return
	end
	if spec.title then
		f.titleText:SetText(spec.title); f.titleText:Show()
	end
	if spec.pending == true then f.pendText:Show() end
	local ok, err = pcall(DRAW[spec.kind], f, set, spec)
	if not ok then
		Purge(f)
		Clear(f)
		f.noText:Show()
		local h = geterrorhandler and geterrorhandler()
		if h then h(err) end
	end
end

local function Kind(f) return f.kind end

local function Label(f, size, alpha)
	local fs = ns.NewText(f, size)
	fs:SetTextColor(1, 1, 1, 1)
	fs:SetAlpha(alpha)
	fs:Hide()
	return fs
end

function ns.NewChart(parent, w, h)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(w, h)
	f.w, f.h = w, h
	f.p = { bars = {}, cells = {}, hits = {}, segs = {}, fills = {} }
	f.c = { bars = 0, cells = 0, hits = 0, segs = 0, fills = 0 }
	f.lists, f.listOrder = {}, {}
	f.Draw, f.Clear, f.Kind = Draw, Clear, Kind
	function f:Resize(nw, nh)
		if nw == f.w and nh == f.h then return end
		f:SetSize(nw, nh)
		f.w, f.h = nw, nh
		for _, l in pairs(f.lists) do l.frame:Hide() end
		wipe(f.lists)
		wipe(f.listOrder)
		f.tableList = nil
	end
	f.grid, f.ylab, f.xlab = {}, {}, {}
	for i = 1, 4 do
		f.grid[i] = f:CreateTexture(nil, "BACKGROUND")
		f.grid[i]:Hide()
	end
	for i = 1, 2 do f.ylab[i] = Label(f, 10, 0.7) end
	for i = 1, 3 do f.xlab[i] = Label(f, 10, 0.7) end
	f.titleText = Label(f, 12, 1)
	f.titleText:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
	f.pendText = Label(f, 11, 0.7)
	f.pendText:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + TITLE_H))
	f.pendText:SetText("Loading items")
	f.noText = Label(f, 12, 0.7)
	f.noText:SetPoint("CENTER", f, "CENTER", 0, 0)
	f.noText:SetText("No results")
	f.num = Label(f, 28, 1)
	f.numName = Label(f, 12, 0.7)
	ns.OnPaint(function(dark)
		f.dark = dark
		local c = dark and ns.CHART.gridDark or ns.CHART.grid
		for i = 1, 4 do f.grid[i]:SetColorTexture(c[1], c[2], c[3], c[4]) end
		for name, p in pairs(f.p) do
			for i = 1, #p do Paint(p[i]) end
		end
	end)
	return f
end
