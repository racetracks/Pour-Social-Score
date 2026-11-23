------------------------------------------------------------------------
-- The navigation list (kit, 3.6.0.91): ns.NewNav(parent, { width, rows,
-- onSelect }) draws M.PSS_MgrNav() rows (a heading, or an entry) like
-- Blizzard's Options window: Modern and Classic with its Options list art
-- where the client has it, Dark flat. One control, three paints; the rows
-- are a pool reused by nav:SetRows. nav:Select(key) marks and reports the
-- entry; nav.rows holds the drawn rows.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local DARK = ns.DARK
local HEAD_H, ROW_H, PAD, INDENT = 30, 20, 6, 16
local HEADER, ACTIVE, HOVER = "Options_CategoryHeader_1", "Options_List_Active", "Options_List_Hover"

function ns.NewNav(parent, o)
	local nav = ns.NewPanel(parent, true)
	nav:SetWidth(o.width or 180)
	nav.rows, nav.pool = {}, {}
	local selected

	local function PaintRow(r)
		local dark, modern = ns.IsDark(), ns.IsModern()
		local entry = r.data.key ~= nil
		local on = entry and r.data.key == selected
		local hot = entry and r.hot
		if entry then
			-- the list art where the client has it, else a plain wash
			local art = not dark and ns.HasAtlas(ACTIVE) and ns.HasAtlas(HOVER)
			r.bg:SetShown(on or hot)
			if art then
				r.bg:SetAtlas(on and ACTIVE or HOVER)
				r.bg:SetVertexColor(1, 1, 1, 1)
			else
				r.bg:SetColorTexture(DARK.hover[1], DARK.hover[2], DARK.hover[3], on and 0.18 or DARK.hover[4])
			end
			r.bar:SetShown(dark and on)
			if dark then r.bar:SetColorTexture(ns.Accent()) end
			r.text:SetAlpha((dark and not on and not hot) and DARK.menuText or 1)
		else
			local art = not dark and ns.HasAtlas(HEADER)
			r.bg:SetShown(art)
			if art then r.bg:SetAtlas(HEADER) end
			r.bar:SetShown(dark)
			if dark then r.bar:SetColorTexture(ns.Accent()) end
			if dark then r.text:SetTextColor(ns.Accent()) else r.text:SetTextColor(1, 0.82, 0) end
		end
		r.modern = modern
	end

	local function MakeRow()
		local r = CreateFrame("Button", nil, nav)
		r.bg = r:CreateTexture(nil, "BACKGROUND")
		r.bg:SetAllPoints(r)
		r.bar = r:CreateTexture(nil, "ARTWORK")
		r.text = ns.NewText(r, 12)
		r.text:SetJustifyH("LEFT")
		r:SetScript("OnEnter", function(self) self.hot = true; PaintRow(self) end)
		r:SetScript("OnLeave", function(self) self.hot = nil; PaintRow(self) end)
		r:SetScript("OnClick", function(self)
			if self.data.key then nav:Select(self.data.key, true) end
		end)
		return r
	end

	-- the heading's rule and the selected entry's bar sit on the left edge
	local function Place(r, y, entry)
		r.y, r.entry = y, entry
		y = y + nav.offset
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", nav, "TOPLEFT", 4, y)
		r:SetPoint("TOPRIGHT", nav, "TOPRIGHT", -4, y)
		r:SetHeight(entry and ROW_H or HEAD_H)
		r.text:ClearAllPoints()
		r.text:SetPoint("LEFT", r, "LEFT", entry and INDENT or 8, 0)
		r.bar:ClearAllPoints()
		if entry then
			r.bar:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
			r.bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
			r.bar:SetWidth(2)
		else
			r.bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 4, 2)
			r.bar:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -4, 2)
			r.bar:SetHeight(1)
		end
	end

	function nav:SetRows(rows)
		local y = -PAD
		self.offset = 0
		for i, d in ipairs(rows) do
			local r = self.pool[i]
			if not r then r = MakeRow(); self.pool[i] = r end
			r.data = d
			r.text:SetText(d.head or d.text)
			Place(r, y, d.key ~= nil)
			y = y - (d.key and ROW_H or HEAD_H)
			r:Show()
			PaintRow(r)
			self.rows[i] = r
		end
		for i = #rows + 1, #self.pool do self.pool[i]:Hide(); self.rows[i] = nil end
		self.contentH = PAD - y
	end

	nav:SetClipsChildren(true)
	nav.offset = 0
	nav:EnableMouseWheel(true)
	nav:SetScript("OnMouseWheel", function(self, delta)
		local maxOff = math.max(0, (self.contentH or 0) - (self:GetHeight() or 0))
		self.offset = math.min(maxOff, math.max(0, self.offset - delta * ROW_H * 3))
		for _, r in ipairs(self.rows) do Place(r, r.y, r.entry) end
	end)

	function nav:Select(key, click)
		selected = key
		for _, r in ipairs(self.rows) do PaintRow(r) end
		if click and o.onSelect then o.onSelect(key) end
	end

	-- a look or font change repaints the rows in place
	ns.OnPaint(function()
		for _, r in ipairs(nav.rows) do PaintRow(r) end
	end)
	nav:SetRows(o.rows or {})
	return nav
end
