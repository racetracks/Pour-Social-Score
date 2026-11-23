------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE SAVE SEARCH DIALOG (search-helper, phase B, STP-00256)
-- Drawing only: sq.put / sq.chart.put / sq.del and the caps come from Libraries
-- (M.PSS_ConsoleView.saveState). ns.SaveQueryDialog(spec) with spec
-- { query, range (a time-picker choice), chart = { kind, shape, x, y, series } };
-- called as (text, choice) by the console's Save button, it reads the chart from the page.
-- ns.AttachQueryList(pg) hooks the console's left list: right click on a "Mine" row opens Rename and Delete.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local ERR = { 1, 0.36, 0.36, 1 }
local SCOPES = { "any", "player", "guild", "filter" }
local dlg, conPage

local function Msg(r, err)
	if r then return nil end
	return tostring(err or "failed")
end

local function Build()
	local CV = M.PSS_ConsoleView
	local f = ns.PopupShell("PSS_QueryDialog", 400, 310)
	f.title:SetText("Save Search?")
	local function Label(text, y)
		local t = ns.NewText(f, 12)
		t:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y)
		t:SetText(text)
		return t
	end
	Label("Name", -48)
	f.name = ns.NewEditBox(f, 240, 48)
	f.name:SetPoint("TOPLEFT", f, "TOPLEFT", 130, -44)
	f.name:SetScript("OnEscapePressed", function() f:Hide() end)
	Label("Scope", -80)
	f.scope = "any"
	f.scopeDrop = ns.NewDropdown(f, 150, function(m)
		for _, s in ipairs(SCOPES) do
			m:Radio(s, function() return f.scope == s end, function() f.scope = s; f.scopeDrop:SetLabel(s) end)
		end
	end)
	f.scopeDrop:SetPoint("TOPLEFT", f, "TOPLEFT", 126, -76)
	f.scopeDrop:SetLabel("any")
	Label("Default time", -112)
	f.time = ns.NewText(f, 12)
	f.time:SetPoint("TOPLEFT", f, "TOPLEFT", 130, -112)
	f.alert = ns.NewCheck(f)
	f.alert:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -138)
	local at = ns.NewText(f, 12)
	at:SetPoint("LEFT", f.alert, "RIGHT", 4, 0)
	at:SetText("Alert me in chat")
	f.chartCheck = ns.NewCheck(f)
	f.chartCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -166)
	f.chartText = ns.NewText(f, 12)
	f.chartText:SetPoint("LEFT", f.chartCheck, "RIGHT", 4, 0)
	f.chartText:SetText("Save chart too")
	f.kind = nil
	f.kindDrop = ns.NewDropdown(f, 110, function(m)
		for _, k in ipairs(f.kinds or {}) do
			m:Radio(k, function() return f.kind == k end, function() f.kind = k; f.kindDrop:SetLabel(k) end)
		end
	end)
	f.kindDrop:SetPoint("LEFT", f.chartText, "RIGHT", 10, 0)
	f.err = ns.NewText(f, 11)
	f.err:SetPoint("BOTTOM", f, "BOTTOM", 0, 52)
	f.err:SetWidth(360)
	f.err:SetTextColor(ERR[1], ERR[2], ERR[3])
	f.save = ns.PopupButton(f, 125, 27, true)
	f.cancel = ns.PopupButton(f, 125, 27, false)
	f.save:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -8, 13)
	f.cancel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 8, 13)
	f.save:SetText("Save")
	f.cancel:SetText(CANCEL or "Cancel")
	ns.PopupAbove(f, f.name, f.scopeDrop, f.alert, f.chartCheck, f.kindDrop, f.save, f.cancel)
	f.cancel:SetScript("OnClick", function() f:Hide() end)
	f.save:SetScript("OnEnter", function(self) if f.saveWhy then ns.Tip(self, f.saveWhy) end end)
	f.save:SetScript("OnLeave", function() ns.HideTip() end)
	f.save:SetScript("OnClick", function()
		local spec = f.spec or {}
		local flags = f.alert:GetChecked() and "a" or ""
		local id, err, chartErr = CV.saveSearch({ name = f.name:GetText() or "", scope = f.scope, query = spec.query or "", time = f.term or "", flags = flags },
			(spec.chart and f.chartCheck:GetChecked() and f.kind) and { kind = f.kind, chart = spec.chart } or nil)
		if not id then f.err:SetText(Msg(nil, err)); return end
		if chartErr then f.err:SetText(Msg(nil, chartErr)); f.savedId = id; M.ShowMsg("Spyglass: search saved, chart not saved: " .. tostring(chartErr)); return end
		f.err:SetText("")
		f.savedId = id
		f:Hide()
		if conPage and conPage.refreshLeft then conPage.refreshLeft(id) end
	end)
	ns.EscapeCloses(f, "PSS_QueryDialog")
	return f
end

function ns.SaveQueryDialog(spec, choice)
	if type(spec) ~= "table" then
		local chart
		local vm = conPage and conPage.qv and conPage.qv.vm
		if vm and vm.chart and vm.chart.kind ~= "table" then
			chart = { kind = vm.chart.kind, shape = vm.info and vm.info.shape, x = vm.chart.x, y = vm.chart.y, series = vm.chart.series, opts = vm.chart.opts }
		end
		spec = { query = spec, range = choice, chart = chart }
	end
	local CV = M.PSS_ConsoleView
	ns.Fresh()
	if not dlg then dlg = Build() end
	dlg.spec = spec
	dlg.name:SetText("")
	dlg.scope = "any"
	dlg.scopeDrop:SetLabel("any")
	dlg.alert:SetChecked(false)
	dlg.err:SetText("")
	dlg.savedId = nil
	local _, _, label, term = CV.pickerRange(spec.range or { preset = "all" })
	dlg.term = (type(term) == "string") and term or ""
	dlg.time:SetText(label or "All time")
	local hasChart = spec.chart ~= nil
	dlg.chartCheck:SetShown(hasChart)
	dlg.chartText:SetShown(hasChart)
	dlg.kindDrop:SetShown(hasChart)
	dlg.chartCheck:SetChecked(false)
	dlg.kinds = hasChart and M.PSS_ConsoleModel():ChartKinds(spec.chart.shape) or {}
	dlg.kind = hasChart and (spec.chart.kind or dlg.kinds[1]) or nil
	dlg.kindDrop:SetLabel(dlg.kind or "")
	local st = CV.saveState(hasChart)
	dlg.saveWhy = st.why
	dlg.chartWhy = st.chartWhy
	dlg.save:SetEnabled(st.canSave)
	if hasChart and st.chartWhy then
		dlg.chartCheck:SetEnabled(false)
		dlg.chartText:SetText("Save chart too (" .. st.chartWhy .. ")")
	else
		dlg.chartCheck:SetEnabled(true)
		dlg.chartText:SetText("Save chart too")
	end
	dlg:Show()
	dlg:Raise()
	dlg.name:SetFocus()
	return dlg
end

------------------------------------------------------------------------
-- The console's left list: refresh after a change, right click menu, broken rows
------------------------------------------------------------------------
local function Attach(pg)
	conPage = pg
	local nav, byKey = pg.nav, {}
	local origSelect = nav.Select

	local function Rows()
		wipe(byKey)
		local rows = pg.cm:LeftRows()
		for _, d in ipairs(rows) do if d.key then byKey[d.key] = d end end
		return rows
	end
	local function Hook()
		for _, r in ipairs(nav.pool) do
			if not r.pssSaveHooked then
				r.pssSaveHooked = true
				r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
				r:SetScript("OnClick", function(self, button)
					local key = self.data and self.data.key
					if not key then return end
					if button == "RightButton" then
						if key:find("^sq:") then pg.rowMenu(self, tonumber(key:sub(4))) end
					else
						nav:Select(key, true)
					end
				end)
			end
		end
	end
	function pg.refreshLeft(selectId)
		nav:SetRows(Rows())
		Hook()
		if selectId then origSelect(nav, "sq:" .. selectId, false) end
	end
	function nav:Select(key, click)
		local d = byKey[key]
		if key:find("^sq:") and d then
			origSelect(self, key, false)
			if click then
				pg.bar:SetText(d.query or "")
				if not d.broken then pg.run(true) end
			end
			return
		end
		return origSelect(self, key, click)
	end

	function pg.rowMenu(row, id)
		local rec = M.PSS_ConsoleView.call("sq.get", { id = id })
		if not rec or rec.n == 0 then return end
		local r = rec[1]
		ns.ContextMenu(row, function(m)
			m:Button("Rename", function()
				ns.Confirm({ title = "Rename Search?", text = "New name", accept = "Rename", name = { text = r[2], max = 48 },
					onAccept = function(_, typed)
						local ok, err = M.PSS_ConsoleView.call("sq.put", { id = id, name = typed or "", scope = r[3], query = r[5], time = r[6], flags = r[4] })
						if not ok then M.ShowMsg("Spyglass: " .. tostring(err)) end
						pg.refreshLeft()
					end })
			end)
			m:Button("Delete", function()
				ns.Confirm({ title = "Delete Search?", text = "Delete \"" .. tostring(r[2]) .. "\"?", accept = "Delete",
					onAccept = function()
						M.PSS_ConsoleView.call("sq.del", { id = id })
						pg.refreshLeft()
					end })
			end)
		end)
	end
	pg.refreshLeft()
end

-- called by the console page as it is built (PSS_Console.lua)
ns.AttachQueryList = Attach
