------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - ROW LIST
--
-- One scrolling row list for every list tab. Only the rows that fit are
-- made, and scrolling redraws them with the next entries, so a list of
-- thousands costs the same as a list of twenty. The tab owns the data: the
-- list asks it to draw entry i into a row. (Carried over from our own
-- earlier window's list, drawn in the look shown.)
--
--   local list = ns.NewRows(parent, {
--       rowH  = 20,
--       cols  = { { key = "name", text = "Name" }, { key = "n", text = "N", width = 50, justify = "RIGHT" } },
--       sort  = function(key) end,              -- header click (optional)
--       draw  = function(row, i) end,           -- row.cells[key]:SetText(...)
--       click = function(row, i, button) end,   -- optional
--       enter = function(row, i) end,           -- optional (tooltip)
--       emptyClick = function() end,            -- optional: a click under
--                                               -- the rows (deselects)
--   })
--   list:SetCount(n)  list:Redraw()  list:Top()  list:SetSort(key, asc)
--   list:Select(test)  list:SetEmptyText(text)
-- A column without a width takes the space left over (one per list).
-- Looks: the header labels are Blizzard's gold or Dark's white, the sorted
-- column in the accent; a hovered row gets Blizzard's highlight or a faint
-- accent wash; a selected row an accent wash in both looks.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...

-- link kinds whose tooltip GameTooltip:SetHyperlink shows (others, such as
-- trade: profession links, open a window instead)
local TIP_LINKS = {
	item = true, spell = true, enchant = true, quest = true, achievement = true,
	currency = true, talent = true, pvptal = true, glyph = true, instancelock = true,
	keystone = true, mawpower = true, conduit = true, azessence = true, unit = true,
	mount = true, transmogappearance = true, transmogillusion = true,
}

local HEADER_H = 20
local SCROLLBAR_W = 22

local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- cell positions from the column widths (the fill column stretches); the
-- cells are font strings (rows) or buttons (the header, whose labels are
-- justified where they are made: a button has no SetJustifyH)
local function PlaceCells(frame, cols, cells, inset)
	local x = inset
	local fill
	for _, c in ipairs(cols) do
		if not c.width then fill = c break end
		x = x + c.width
	end
	local rx = -inset
	if fill then
		for i = #cols, 1, -1 do
			local c = cols[i]
			if c == fill then break end
			rx = rx - c.width
		end
	end
	x = inset
	for _, c in ipairs(cols) do
		local fs = cells[c.key]
		fs:ClearAllPoints()
		if c == fill then
			fs:SetPoint("LEFT", frame, "LEFT", x, 0)
			fs:SetPoint("RIGHT", frame, "RIGHT", rx - 4, 0)
			x = nil
		elseif x then
			fs:SetPoint("LEFT", frame, "LEFT", x, 0)
			fs:SetWidth(c.width - 6)
			x = x + c.width
		else
			fs:SetPoint("LEFT", frame, "RIGHT", rx, 0)
			fs:SetWidth(c.width - 6)
			rx = rx + c.width
		end
		if fs:GetObjectType() == "FontString" then fs:SetJustifyH(c.justify or "LEFT") end
	end
end

local List = {}
List.__index = List

function ns.NewRows(parent, spec)
	local list = setmetatable({ spec = spec, rowH = spec.rowH or 20, count = 0, first = 0, rows = {},
		sortKey = nil, sortAsc = true }, List)

	local header = CreateFrame("Frame", nil, parent)
	header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	header:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -SCROLLBAR_W, 0)
	header:SetHeight(HEADER_H)
	list.header = header
	list.heads = {}
	local headCells = {}
	for _, c in ipairs(spec.cols) do
		local b = CreateFrame("Button", nil, header)
		b:SetHeight(HEADER_H)
		local fs = ns.NewText(b, 11)
		fs:SetAllPoints()
		fs:SetJustifyH(c.justify or "LEFT")
		b.label = fs
		b.key, b.text = c.key, c.text
		if spec.sort and c.sort ~= false then
			b:SetScript("OnClick", function() spec.sort(c.key) end)
		end
		if c.tip then ns.TipOn(b, b, c.tip) end
		headCells[c.key] = b
		list.heads[#list.heads + 1] = b
	end
	PlaceCells(header, spec.cols, headCells, 4)
	list:SetSort(nil)
	local bar = ns.Fill(header, { 0.02, 0.02, 0.02, 0.5 }, -6)
	ns.OnPaint(function(dark)
		bar:SetShown(dark)
		list:SetSort(list.sortKey, list.sortAsc)
	end)

	local scroll = ns.NewScrollFrame(parent)
	scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
	scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -SCROLLBAR_W, 0)
	-- the scroll child only gives the scroll bar its range; the rows stay put
	-- and show the entries from the scroll position down
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	list.scroll, list.content = scroll, content

	scroll:HookScript("OnVerticalScroll", function(_, offset)
		local first = math.floor((offset or 0) / list.rowH + 0.5)
		first = math.max(0, math.min(first, list.count - (list.shown or 1)))
		if first ~= list.first then
			list.first = first
			list:Redraw()
		end
	end)
	scroll:HookScript("OnSizeChanged", function() list:Layout() end)
	if spec.emptyClick then
		-- the rows are buttons over the scroll frame: what reaches it is a
		-- click on no row
		scroll:EnableMouse(true)
		scroll:SetScript("OnMouseUp", function(_, button)
			if button == "LeftButton" then spec.emptyClick() end
		end)
	end
	list.empty = ns.NewText(parent, 12)
	list.empty:SetPoint("TOP", scroll, "TOP", 0, -20)
	list.empty:SetTextColor(1, 1, 1)
	list.empty:SetAlpha(0.5)
	list.empty:Hide()
	list:Layout()
	return list
end

-- the rows that fit (made once each; a taller list makes more)
function List:Layout()
	local h = self.scroll:GetHeight() or 0
	if h <= 0 then h = self.spec.height or 300 end
	local n = math.max(1, math.floor(h / self.rowH))
	for i = #self.rows + 1, n do self:MakeRow(i) end
	self.shown = n
	for i = n + 1, #self.rows do self.rows[i]:Hide() end
	self:SetCount(self.count)
end

function List:MakeRow(i)
	local spec = self.spec
	local row = CreateFrame("Button", nil, self.scroll)
	row:SetHeight(self.rowH)
	row:SetPoint("TOPLEFT", self.scroll, "TOPLEFT", 0, -(i - 1) * self.rowH)
	row:SetPoint("RIGHT", self.scroll, "RIGHT", 0, 0)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	local sel = row:CreateTexture(nil, "BACKGROUND")
	sel:SetAllPoints()
	sel:Hide()
	row.sel, row.hl = sel, hl
	ns.OnPaint(function(dark)
		local r, g, b = ns.Accent()
		if dark then
			hl:SetColorTexture(r, g, b, 0.12)
			hl:SetBlendMode("BLEND")
		else
			hl:SetTexture(HIGHLIGHT)
			hl:SetBlendMode("ADD")
		end
		sel:SetColorTexture(r, g, b, 0.25)
	end)

	row.cells = {}
	for _, c in ipairs(spec.cols) do
		-- one line per cell, cut short with "..." (a long filter or
		-- description must not wrap over the rows below)
		local fs = ns.NewText(row, spec.fontSize or 12)
		fs:SetWordWrap(false)
		fs:SetNonSpaceWrap(false)
		if fs.SetMaxLines then fs:SetMaxLines(1) end
		fs:SetHeight(self.rowH)
		row.cells[c.key] = fs
	end
	PlaceCells(row, spec.cols, row.cells, 4)

	-- spec.links: links in the text work as in chat (hover for the
	-- tooltip, click to open, shift-click to paste into chat)
	if spec.links and row.SetHyperlinksEnabled then
		row:SetHyperlinksEnabled(true)
		row:SetScript("OnHyperlinkClick", function(btn, link, text, button)
			btn.linkClickAt = GetTime()
			-- SetItemRef can open Blizzard panels: never from our code in combat
			if InCombatLockdown() then return end
			if SetItemRef then pcall(SetItemRef, link, text, button, DEFAULT_CHAT_FRAME) end
		end)
		row:SetScript("OnHyperlinkEnter", function(btn, link)
			if GameTooltip:IsForbidden() then return end
			GameTooltip:SetOwner(btn, "ANCHOR_CURSOR")
			-- only the kinds with a tooltip: SetHyperlink on a profession
			-- (trade:) link opens the profession window
			local kind = type(link) == "string" and link:match("^([^:]+)")
			local ok = TIP_LINKS[kind] and pcall(GameTooltip.SetHyperlink, GameTooltip, link)
			if ok and GameTooltip:NumLines() > 0 then GameTooltip:Show() else GameTooltip:Hide() end
		end)
		row:SetScript("OnHyperlinkLeave", function() if not GameTooltip:IsForbidden() then GameTooltip:Hide() end end)
	end
	if spec.click then
		row:SetScript("OnClick", function(btn, button)
			-- a click on a link in the row is the link's, not the row's
			if btn.linkClickAt and GetTime() - btn.linkClickAt < 0.05 then return end
			if btn.index then spec.click(btn, btn.index, button) end
		end)
	end
	if spec.enter then
		row:SetScript("OnEnter", function(btn) if btn.index then spec.enter(btn, btn.index) end end)
		row:SetScript("OnLeave", ns.HideTip)
	end
	row:Hide()
	self.rows[i] = row
	return row
end

-- n entries; the scroll position stays where it is when it still fits
function List:SetCount(n)
	self.count = n or 0
	self.content:SetSize(math.max(1, (self.scroll:GetWidth() or 1)), math.max(1, self.count * self.rowH))
	local maxFirst = math.max(0, self.count - (self.shown or 1))
	if self.first > maxFirst then
		self.first = maxFirst
		self.scroll:SetVerticalScroll(maxFirst * self.rowH)
	end
	self:Redraw()
end

function List:Top()
	self.first = 0
	self.scroll:SetVerticalScroll(0)
	self:Redraw()
end

-- Redraw the rows on screen (nothing else is drawn).
function List:Redraw()
	local draw = self.spec.draw
	for i = 1, self.shown or 0 do
		local row = self.rows[i]
		local index = self.first + i
		if index <= self.count then
			row.index = index
			draw(row, index)
			row:Show()
		else
			row.index = nil
			row:Hide()
		end
	end
	self.empty:SetShown(self.count == 0 and self.emptyText ~= nil)
end

function List:SetEmptyText(text)
	self.emptyText = text
	self.empty:SetText(text or "")
end

-- The sorted column reads in the accent colour with ^ (ascending) or v;
-- the others Blizzard's gold or Dark's soft white.
function List:SetSort(key, asc)
	self.sortKey, self.sortAsc = key, asc
	local r, g, b = ns.Accent()
	local dark = ns.IsDark()
	for _, h in ipairs(self.heads) do
		if key ~= nil and h.key == key then
			h.label:SetText(h.text .. (asc and " ^" or " v"))
			h.label:SetTextColor(r, g, b)
			h.label:SetAlpha(1)
		else
			h.label:SetText(h.text)
			if dark then h.label:SetTextColor(1, 1, 1) else h.label:SetTextColor(1, 0.82, 0) end
			h.label:SetAlpha(dark and 0.85 or 1)
		end
	end
end

-- Mark the rows whose entry passes test(i) as selected.
function List:Select(test)
	for i = 1, self.shown or 0 do
		local row = self.rows[i]
		row.sel:SetShown(row.index ~= nil and test(row.index) or false)
	end
end
