------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - BLOCK HISTORY LIST
--
-- The block history list of the Players and Guilds panes. The history
-- lives in PourSocialScore_Logging, which loads on demand: a pane reads it
-- by itself only once something else loaded it, otherwise it offers a Show
-- Block History button. Types show as one word with a tick box each to
-- filter them (the ticks are shared, Libraries M.PSS_HistHidden); the guild
-- view adds the player's name. A right-click on a line puts its sender on
-- or off the Player Ignore List (ns.SenderMenu, also used by the Events tab).
--   local hv = ns.NewHistory(body, y, { names =, empty =, open = })
--   hv:Set(id, total, read [, fresh])   hv:Clear()
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M
local History = M.PSS_History

local EMPTY = {}
local cellBuf = {}

local lists = {}

local Filter
local function FiltersChanged()
	for _, hv in ipairs(lists) do
		for t, c in pairs(hv.boxes) do c:SetChecked(not M.PSS_HistHidden(t)) end
		Filter(hv)
	end
end

-- [x] whisper [x] invite ...: untick a type to hide its lines
local function TypeBoxes(parent)
	local boxes, prev = {}, nil
	for _, t in ipairs(M.PSS_EVENT_TYPES) do
		local c = ns.NewCheck(parent)
		c:SetSize(18, 18)
		if prev then
			c:SetPoint("LEFT", prev, "RIGHT", 4, 0)
		else
			c:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
		end
		local label = ns.NewText(parent, 10)
		label:SetPoint("LEFT", c, "RIGHT", 0, 0)
		label:SetText(t)
		c:SetChecked(not M.PSS_HistHidden(t))
		c:SetScript("OnClick", function(self)
			M.PSS_SetHistHidden(t, not self:GetChecked())
			FiltersChanged()
		end)
		ns.TipOn(c, c, ("Show %s lines."):format(t))
		boxes[t] = c
		prev = label
	end
	return boxes
end

function Filter(hv)
	local n = M.PSS_HistFilter(hv.all, hv.shown)
	hv.list:SetCount(n)
	if #hv.all > 0 and n == 0 then
		hv.list:SetEmptyText(M.PSS_HistEmptyText)
	else
		hv.list:SetEmptyText(hv.emptyText)
	end
end

local function Draw(hv, row, i)
	local h = hv.shown[i]
	local cells = row.cells
	if not h then
		for _, fs in pairs(cells) do fs:SetText("") end
		return
	end
	local c = M.PSS_HistCells(h, cellBuf)
	cells.time:SetText(c.time)
	cells.kind:SetText(c.kind)
	if cells.name then cells.name:SetText(c.name) end
	cells.message:SetText(c.message)
end

local function Tip(hv, row, i)
	local h = hv.shown[i]
	if not h then return end
	ns.Tip(row, M.PSS_HistTip(h, hv.open and ns.OpenEvents and true or false))
end

-- a second left click on the same line opens the Events tab
-- A blocked line's sender, on or off the Player Ignore List (a right-click
-- on a line here or on the Events tab).
local function SenderAct(act, full)
	if act == "senderAdd" then
		M.PSS_SenderAdd(full)
	elseif act == "senderRemove" then
		local text = M.PSS_SenderRemoveText(full)
		if text then
			ns.Confirm({ title = "Remove Player?", text = text, accept = "Remove", onAccept = function() M.PSS_SenderRemove(full) end })
		end
	end
end

function ns.SenderMenu(row, name)
	ns.RowMenu(row, M.PSS_SenderMenu(name), SenderAct)
end

local function Click(hv, row, i, button)
	if button == "RightButton" then
		local h = hv.shown[i]
		if h then ns.SenderMenu(row, h.member) end
		return
	end
	if not (hv.open and ns.OpenEvents) or button ~= "LeftButton" then return end
	if M.PSS_DoubleClick(hv.clicks, i) then hv.open(hv.id) end
end

local HV = {}
HV.__index = HV

-- Show the lines of id (read(id) returns them, loading Logging); read again
-- only when id or its count changed. fresh scrolls back to the top.
function HV:Set(id, total, read, fresh)
	local ready = M.PSS_LoggingReady()
	if self.set and self.id == id and self.total == total and self.ready == ready then return end
	fresh = fresh or self.id ~= id
	self.set, self.ready = true, ready
	self.id, self.total, self.read = id, total, read
	if total > 0 and not ready then
		-- not loaded yet: offer it rather than load it for a click on a row
		self.all = EMPTY
		self.gate:SetText(("Show Block History (%d)"):format(total))
		self.gate:Show()
		self.list:SetEmptyText("")
		self.list:SetCount(0)
		wipe(self.shown)
		return
	end
	self.gate:Hide()
	self.all = total > 0 and read(id) or EMPTY
	Filter(self)
	if fresh then self.list:Top() end
end

-- Forget what is shown (the next Set reads again).
function HV:Clear()
	self.set, self.id, self.read = nil, nil, nil
end

-- body: the page; y: top of the list; opts.names adds a Name column,
-- opts.empty is the text with nothing blocked, opts.open(id) opens the
-- Events tab (a double-click on a line). Fills the space down to the
-- buttons at the bottom of the page.
function ns.NewHistory(body, y, opts)
	local hv = setmetatable({ all = EMPTY, shown = {}, emptyText = opts.empty or "", open = opts.open,
		clicks = {} }, HV)
	local f = CreateFrame("Frame", nil, body)
	f:SetPoint("TOPLEFT", body, "TOPLEFT", 6, y)
	f:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -4, 36)
	hv.frame = f

	hv.boxes = TypeBoxes(f)

	local lf = CreateFrame("Frame", nil, f)
	lf:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -20)
	lf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	local cols = {
		{ key = "time", text = "Time", width = 118 },
		{ key = "kind", text = "Type", width = 48 },
	}
	if opts.names then cols[#cols + 1] = { key = "name", text = "Name", width = 86 } end
	cols[#cols + 1] = { key = "message", text = "Message" }
	hv.list = ns.NewRows(lf, {
		rowH = 16, fontSize = 11, height = 60, cols = cols,
		draw = function(row, i) Draw(hv, row, i) end,
		enter = function(row, i) Tip(hv, row, i) end,
		click = function(row, i, button) Click(hv, row, i, button) end,
	})
	hv.list:SetEmptyText(hv.emptyText)

	hv.gate = ns.NewButton(lf, "Show Block History", 170, function()
		if not M.PSS_LoadLogging() then return end
		local id, total, read = hv.id, hv.total, hv.read
		hv.set = nil
		if read then hv:Set(id, total, read, true) end
	end)
	hv.gate:SetPoint("TOP", lf, "TOP", 0, -36)
	ns.TipOn(hv.gate, hv.gate, "Loads the block history (it stays loaded until you log out or /reload).")
	hv.gate:Hide()

	lists[#lists + 1] = hv
	return hv
end
