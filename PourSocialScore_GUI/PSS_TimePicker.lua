------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - TIME PICKER (search-helper, phase B, STP-00288)
-- Drawing only; the ranges, presets and month maths are Libraries
-- (M.PSS_ConsoleView: PRESETS, pickerRange, monthGrid, monthStep).
--   local p = ns.NewTimePicker(parent, onChange)   a drop-down
--   p:SetChoice(choice)  p:Choice()  p:Range()  p:SetTyped(on)
--   onChange(earliest, latest, label, term)
--   ns.NewCalendar(parent, onPick)   cal:SetMonth(y, m); onPick("YYYY-MM-DD")
-- The choice lives on the picker only: per view, this session, nothing saved.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local format, tonumber = string.format, tonumber
local INITIALS = { "M", "T", "W", "T", "F", "S", "S" }
local UNITS = { { "m", "minutes" }, { "h", "hours" }, { "d", "days" }, { "w", "weeks" }, { "mon", "months" } }
local SNAPS = { { nil, "none" }, { "d", "start of day" }, { "w", "start of week" }, { "mon", "start of month" } }
local MODES = { { "between", "Between" }, { "before", "Before" }, { "since", "Since" } }

function ns.NewCalendar(parent, onPick)
	local CV, T = M.PSS_ConsoleView, M.PSS_Time
	local cal = ns.NewPanel(parent)
	cal:SetSize(7 * 26 + 12, 24 + 16 + 6 * 26 + 12)
	cal:SetFrameStrata("DIALOG")
	cal:SetFrameLevel(parent:GetFrameLevel() + 20)
	local y, m
	cal.prev = ns.NewButton(cal, "<", 24, function() local a, b = CV.monthStep(y, m, -1); cal:SetMonth(a, b) end)
	cal.prev:SetPoint("TOPLEFT", cal, "TOPLEFT", 6, -6)
	cal.next = ns.NewButton(cal, ">", 24, function() local a, b = CV.monthStep(y, m, 1); cal:SetMonth(a, b) end)
	cal.next:SetPoint("TOPRIGHT", cal, "TOPRIGHT", -6, -6)
	cal.label = ns.NewText(cal, 12)
	cal.label:SetPoint("TOP", cal, "TOP", 0, -10)
	cal.initials = {}
	for i = 1, 7 do
		local fs = ns.NewText(cal, 11)
		fs:SetPoint("TOPLEFT", cal, "TOPLEFT", 6 + (i - 1) * 26, -34)
		fs:SetWidth(26)
		fs:SetText(INITIALS[i])
		cal.initials[i] = fs
	end
	cal.days = {}
	for i = 1, 42 do
		local b = ns.NewButton(cal, "", 24)
		b:SetSize(24, 24)
		local col, row = (i - 1) % 7, math.floor((i - 1) / 7)
		b:SetPoint("TOPLEFT", cal, "TOPLEFT", 7 + col * 26, -50 - row * 26)
		b:SetScript("OnClick", function(self)
			if self.day and onPick then onPick(format("%04d-%02d-%02d", y, m, self.day)) end
		end)
		b:Hide()
		cal.days[i] = b
	end
	function cal:SetMonth(yy, mm)
		y, m = yy, mm
		local offset, n = CV.monthGrid(y, m)
		cal.label:SetText(T.fmt(T.parse(format("%04d-%02d-01", y, m)), "month"))
		for i, b in ipairs(cal.days) do
			local d = i - offset
			if d >= 1 and d <= n then
				b.day = d
				b:SetText(tostring(d))
				b:Show()
			else
				b.day = nil
				b:Hide()
			end
		end
	end
	return cal
end

function ns.NewTimePicker(parent, onChange)
	local CV, T = M.PSS_ConsoleView, M.PSS_Time
	local choice, typed = { preset = "all" }, false
	local p, panel, cal
	local st = { mode = "relative", unit = "d", snap = nil, rmode = "between", pick = nil }

	local function labelNow()
		local _, _, label = CV.pickerRange(choice)
		if typed then label = "Custom (from the search)" end
		p:SetLabel(label or "")
	end

	local function fire()
		local e, l, label, term = CV.pickerRange(choice)
		if onChange then onChange(e, l, label, term) end
	end

	local function build(m)
		m:Title("Presets")
		for _, r in ipairs(CV.PRESETS) do
			m:Radio(r.text, function() return choice.preset == r.key end, function()
				choice = { preset = r.key }
				labelNow()
				fire()
			end)
		end
		m:Divider()
		m:Button("Relative...", function() p:OpenPanel("relative") end)
		m:Button("Date range...", function() p:OpenPanel("range") end)
		m:Button("Advanced...", function() p:OpenPanel("advanced") end)
	end

	p = ns.NewDropdown(parent, 190, build)

	local function dd(host, w, list, key, x, y)
		local d = ns.NewDropdown(host, w, function(m)
			for _, it in ipairs(list) do
				m:Radio(it[2], function() return st[key] == it[1] end, function() st[key] = it[1]; d:SetLabel(it[2]); if host.Relayout then host:Relayout() end end)
			end
		end)
		d:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
		return d
	end

	local function makePanel()
		panel = ns.NewPanel(UIParent)
		panel:SetSize(300, 150)
		panel:SetFrameStrata("DIALOG")
		panel:SetPoint("TOPLEFT", p, "BOTTOMLEFT", 0, -2)
		panel:Hide()
		ns.EscapeCloses(panel, "PSS_TimePickerPanel")
		cal = ns.NewCalendar(panel, function(day)
			local box = st.pick
			if box then box:SetText(day) end
			cal:Hide()
		end)
		cal:SetPoint("TOPLEFT", panel, "TOPRIGHT", 4, 0)
		cal:Hide()

		-- Relative
		local rel = CreateFrame("Frame", nil, panel)
		rel:SetAllPoints(panel)
		rel.num = ns.NewNumberBox(rel, 50)
		rel.num:SetPoint("TOPLEFT", rel, "TOPLEFT", 12, -14)
		rel.num:SetMaxLetters(4)
		rel.unit = dd(rel, 100, UNITS, "unit", 70, -12)
		rel.unit:SetLabel("days")
		local ago = ns.NewText(rel, 12)
		ago:SetPoint("LEFT", rel.unit, "RIGHT", 8, 0)
		ago:SetText("ago")
		local snapText = ns.NewText(rel, 11)
		snapText:SetPoint("TOPLEFT", rel, "TOPLEFT", 12, -48)
		snapText:SetText("Snap to")
		rel.snap = dd(rel, 150, SNAPS, "snap", 70, -44)
		rel.snap:SetLabel("none")

		-- Date range
		local rng = CreateFrame("Frame", nil, panel)
		rng:SetAllPoints(panel)
		rng.mode = ns.NewDropdown(rng, 100, function(m)
			for _, it in ipairs(MODES) do
				m:Radio(it[2], function() return st.rmode == it[1] end, function() st.rmode = it[1]; rng.mode:SetLabel(it[2]); rng:Relayout() end)
			end
		end)
		rng.mode:SetPoint("TOPLEFT", rng, "TOPLEFT", 12, -10)
		rng.mode:SetLabel("Between")
		local function endRow(y, caption)
			local row = {}
			row.cap = ns.NewText(rng, 11)
			row.cap:SetPoint("TOPLEFT", rng, "TOPLEFT", 12, y - 4)
			row.cap:SetText(caption)
			row.date = ns.NewEditBox(rng, 90, 10, "YYYY-MM-DD")
			row.date:SetPoint("TOPLEFT", rng, "TOPLEFT", 50, y)
			row.time = ns.NewEditBox(rng, 50, 5, "HH:MM")
			row.time:SetPoint("LEFT", row.date, "RIGHT", 8, 0)
			row.pick = ns.NewButton(rng, "...", 26, function()
				st.pick = row.date
				local yy, mm = tonumber(row.date:GetText():match("^(%d%d%d%d)")), tonumber(row.date:GetText():match("^%d%d%d%d%-(%d%d)"))
				if not (yy and mm and mm >= 1 and mm <= 12) then
					local d = (date or os.date)("*t", T.now())
					yy, mm = d.year, d.month
				end
				cal:SetMonth(yy, mm)
				cal:SetShown(not cal:IsShown())
			end)
			row.pick:SetPoint("LEFT", row.time, "RIGHT", 8, 0)
			return row
		end
		rng.from = endRow(-40, "From")
		rng.to = endRow(-68, "To")
		function rng:Relayout()
			local showFrom, showTo = st.rmode ~= "before", st.rmode ~= "since"
			for _, k in ipairs({ "cap", "date", "time", "pick" }) do
				rng.from[k]:SetShown(showFrom)
				rng.to[k]:SetShown(showTo)
			end
		end
		rng:Relayout()

		-- Advanced
		local adv = CreateFrame("Frame", nil, panel)
		adv:SetAllPoints(panel)
		adv.earliest = ns.NewEditBox(adv, 140, 32, "earliest")
		adv.earliest:SetPoint("TOPLEFT", adv, "TOPLEFT", 12, -14)
		adv.latest = ns.NewEditBox(adv, 140, 32, "latest")
		adv.latest:SetPoint("TOPLEFT", adv, "TOPLEFT", 12, -44)
		local hint = ns.NewText(adv, 11)
		hint:SetPoint("LEFT", adv.earliest, "RIGHT", 8, 0)
		hint:SetText("-7d@d")
		hint:SetAlpha(0.6)

		panel.modes = { relative = rel, range = rng, advanced = adv }
		panel.err = ns.NewText(panel, 11)
		panel.err:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 40)
		panel.err:SetTextColor(1, 0.3, 0.3)
		panel.err:SetText("")

		local function read()
			if panel.mode == "relative" then
				return { relative = true, n = tonumber(rel.num:GetText()), unit = st.unit, snap = st.snap }
			elseif panel.mode == "range" then
				local function val(row)
					local d, t = row.date:GetText() or "", row.time:GetText() or ""
					if d ~= "" and t ~= "" then d = d .. "T" .. t end
					return d
				end
				local c = { [st.rmode] = true, from = val(rng.from), to = val(rng.to) }
				return c
			end
			return { advanced = true, earliest = adv.earliest:GetText(), latest = adv.latest:GetText() }
		end
		panel.apply = ns.NewButton(panel, "Apply", 80, function()
			local c = read()
			local e, l, label, term = CV.pickerRange(c)
			if term == nil then
				panel.err:SetText(tostring(label or l))
				return
			end
			choice = c
			panel.err:SetText("")
			typed = false
			labelNow()
			panel:Hide()
			fire()
		end, true)
		panel.apply:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -96, 10)
		panel.cancel = ns.NewButton(panel, "Cancel", 80, function() panel:Hide() end)
		panel.cancel:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 10)
		panel:HookScript("OnHide", function() cal:Hide() end)
	end

	function p:OpenPanel(mode)
		if not panel then makePanel() end
		panel.mode = mode
		for k, f in pairs(panel.modes) do f:SetShown(k == mode) end
		panel.err:SetText("")
		cal:Hide()
		panel:Show()
	end
	function p:Panel() return panel, cal end

	function p:SetChoice(c)
		choice = c or { preset = "all" }
		labelNow()
	end
	function p:Choice() return choice end
	function p:Range() return CV.pickerRange(choice) end
	function p:SetTyped(on)
		typed = on and true or false
		labelNow()
	end

	labelNow()
	return p
end
