------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - OPTIONS AND IMPORT/EXPORT TABS
--
-- Options: every option under its section heading in a scrolling page,
-- with a search box at the right end of the tab row (shown with this tab)
-- that keeps the options whose name, tip or section holds the text. Each
-- row is a tick box, a number box, a tick box with its number (the scan
-- level cap) or a drop-down. Import/Export: what to include, the import
-- mode, Export (a copy box) and Import (a paste box; Replace asks first).
-- Libraries (PSS_OptionsView.lua) works out every text and does every
-- change through M.PSS_SetOpt and PSS_ImportExport.lua; the tabs redraw on
-- OPTION_CHANGED while they show.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local ROW_H = 26
-- the controls sit this far left of the row's right edge
local CONTROL_X = 210

local optionsPage, ioPage

ns.TabBuilders = ns.TabBuilders or {}

local function Scroll(page)
	local scroll = ns.NewScrollFrame(page)
	scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -26, 8)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(math.max(scroll:GetWidth(), 400), 1)
	scroll:SetScrollChild(content)
	scroll:SetScript("OnSizeChanged", function(_, w) if w and w > 0 then content:SetWidth(w) end end)
	return content, scroll
end

------------------------------------------------------------------------
-- Options
------------------------------------------------------------------------
local function OptionRow(content, o, rows)
	local row = CreateFrame("Frame", nil, content)
	row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
	row:SetHeight(ROW_H)
	local label = ns.NewText(row, 12)
	label:SetPoint("LEFT", row, "LEFT", 14, 0)
	label:SetPoint("RIGHT", row, "RIGHT", -CONTROL_X - 10, 0)
	label:SetJustifyH("LEFT")
	label:SetWordWrap(false)
	label:SetText(M.PSS_OptLabel(o) .. (o.target and " *" or ""))
	row:EnableMouse(true)
	ns.TipOn(row, label, M.PSS_OptTip(o))
	row.option = o

	local refresh
	if o.kind == "bool" and o.field then
		local c = ns.NewCheck(row)
		c:SetPoint("LEFT", row, "RIGHT", -CONTROL_X, 0)
		local e = ns.NewNumberBox(row, 50)
		e:SetPoint("LEFT", c, "RIGHT", 10, 0)
		refresh = function()
			c:SetChecked(M.PSS_OptFieldOn(o))
			if not e:HasFocus() then e:SetText(M.PSS_OptFieldText(o)) end
		end
		c:SetScript("OnClick", function(self)
			M.PSS_OptSetFieldOn(o, self:GetChecked() == true, e:GetText())
			refresh()
		end)
		ns.OnCommit(e, function(text) M.PSS_OptSetField(o, text) end, refresh)
		row.check, row.box = c, e
	elseif o.kind == "bool" then
		local c = ns.NewCheck(row)
		c:SetPoint("LEFT", row, "RIGHT", -CONTROL_X, 0)
		c:SetScript("OnClick", function(self) M.PSS_SetOpt(o.key, "global", self:GetChecked() == true) end)
		refresh = function() c:SetChecked(M.PSS_Opt(o.key) == true) end
		row.check = c
	elseif o.kind == "number" then
		local e = ns.NewNumberBox(row, 60)
		e:SetPoint("LEFT", row, "RIGHT", -CONTROL_X + 4, 0)
		refresh = function() if not e:HasFocus() then e:SetText(M.PSS_OptNumberText(o)) end end
		ns.OnCommit(e, function(text) M.PSS_OptSetNumber(o, text) end, refresh)
		row.box = e
	else
		-- choices read when the menu opens (the font list grows with the
		-- fonts other addons share)
		local d = ns.NewDropdown(row, 170, function(m)
			for _, ch in ipairs(o.choices or {}) do
				m:Radio(ch[2], function() return M.PSS_Opt(o.key) == ch[1] end, function()
					M.PSS_SetOpt(o.key, "global", ch[1])
				end)
			end
		end)
		d:SetPoint("LEFT", row, "RIGHT", -CONTROL_X, 0)
		refresh = function() d:SetLabel(M.PSS_OptChoiceText(o, M.PSS_Opt(o.key))) end
		row.drop = d
	end
	rows[#rows + 1] = refresh
	return row
end

ns.TabBuilders.options = function(page)
	optionsPage = page
	local content, scroll = Scroll(page)
	local rows = {}
	local groups = M.PSS_OptGroups()
	for _, g in ipairs(groups) do
		g.heading = ns.NewHeading(content, g.title)
		for _, it in ipairs(g.items) do it.row = OptionRow(content, it.o, rows) end
	end
	local note = ns.NewText(content, 11)
	note:SetAlpha(0.6)
	note:SetText("* can also be set per guild or per player.")
	local none = ns.NewText(content, 12)
	none:SetAlpha(0.6)
	none:SetText("No options match.")

	local function Layout(q)
		local y, shown = -4, 0
		for _, g in ipairs(groups) do
			local n = 0
			for _, it in ipairs(g.items) do
				local on = M.PSS_OptMatches(g, it, q)
				it.row:SetShown(on)
				if on then
					if n == 0 then
						g.heading:ClearAllPoints()
						g.heading:SetPoint("TOPLEFT", content, "TOPLEFT", 6, y - 4)
						y = y - 28
					end
					it.row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
					y = y - ROW_H
					n = n + 1
				end
			end
			g.heading:SetShown(n > 0)
			if n > 0 then y = y - 8 end
			shown = shown + n
		end
		none:SetShown(shown == 0)
		none:ClearAllPoints()
		none:SetPoint("TOPLEFT", content, "TOPLEFT", 6, y - 4)
		if shown == 0 then y = y - 24 end
		note:ClearAllPoints()
		note:SetPoint("TOPLEFT", content, "TOPLEFT", 6, y - 4)
		content:SetHeight(-y + 30)
		scroll:SetVerticalScroll(0)
		page.shownCount = shown
	end
	Layout("")

	-- the search box sits at the right end of the tab row, over the window,
	-- and shows and hides with this page
	local search = ns.NewSearchBox(page, 200, "Search options", Layout)
	search:SetPoint("TOPRIGHT", page:GetParent(), "TOPRIGHT", -12, ns.TAB_ROW_Y - 2)
	page.search, page.groups, page.none = search, groups, none
	return function() for i = 1, #rows do rows[i]() end end
end

------------------------------------------------------------------------
-- Import/Export
------------------------------------------------------------------------
local function Export()
	local text, subtitle = M.PSS_ExportText()
	ns.CopyText({ title = "Export", subtitle = subtitle, text = text })
end

local function Import()
	ns.ImportText({ title = "Import", subtitle = "Paste a Pour Social Score export string below",
		accept = "Import", onAccept = function(str)
			local err, ask, apply = M.PSS_ImportStart(str)
			if err then
				M.ShowMsg(err)
			elseif not ask then
				M.ShowMsg(apply())
			else
				ns.Confirm({ title = "Replace on Import?", text = ask, accept = "Replace", onAccept = function() M.ShowMsg(apply()) end })
			end
		end })
end

ns.TabBuilders.importExport = function(page)
	ioPage = page
	local checks = {}
	local help = ns.NewText(page, 12)
	help:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -16)
	help:SetPoint("RIGHT", page, "RIGHT", -16, 0)
	help:SetJustifyH("LEFT")
	help:SetAlpha(0.8)
	help:SetText("Tick what to include, then Export and copy the string. To import, choose a mode and paste a string into the Import box.")
	local refresh
	local y = -46
	for _, p in ipairs(M.PSS_IO_PARTS) do
		local c = ns.NewCheck(page)
		c:SetPoint("TOPLEFT", page, "TOPLEFT", p.under and 36 or 14, y)
		local label = ns.NewText(page, 12)
		label:SetPoint("LEFT", c, "RIGHT", 4, 0)
		label:SetText(p.text)
		c:SetScript("OnClick", function(self)
			M.PSS_IOSet(p.key, self:GetChecked())
			refresh()
		end)
		checks[p.key] = { c, label }
		y = y - 28
	end
	local modeLabel = ns.NewText(page, 12)
	modeLabel:SetPoint("TOPLEFT", page, "TOPLEFT", 16, y - 10)
	modeLabel:SetText("Import mode")
	local mode = ns.NewDropdown(page, 220, function(m)
		for _, md in ipairs(M.PSS_IO_MODES) do
			m:Radio(md.text, function() return M.PSS_IOMode() == md.key end, function()
				M.PSS_IOSetMode(md.key)
				refresh()
			end)
		end
	end)
	mode:SetPoint("LEFT", modeLabel, "LEFT", 110, 0)
	local export = ns.NewButton(page, "Export", 110, Export)
	export:SetPoint("TOPLEFT", page, "TOPLEFT", 16, y - 48)
	local import = ns.NewButton(page, "Import", 110, Import)
	import:SetPoint("LEFT", export, "RIGHT", 10, 0)
	page.checks, page.mode, page.exportButton, page.importButton = checks, mode, export, import
	refresh = function()
		for key, t in pairs(checks) do
			t[1]:SetChecked(M.PSS_IOOn(key))
			local off = M.PSS_IOPartOff(key)
			t[1]:SetEnabled(not off)
			t[2]:SetAlpha(off and 0.4 or 1)
		end
		mode:SetLabel(M.PSS_IOModeText())
	end
	return refresh
end

-- an option changed (here, by a command, or by another window): the tab
-- shown again
ns.Listen("OPTION_CHANGED", function()
	if (optionsPage and optionsPage:IsVisible()) or (ioPage and ioPage:IsVisible()) then ns.RefreshTab() end
end)
