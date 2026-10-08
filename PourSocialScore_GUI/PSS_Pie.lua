------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - PIE
--
-- A small pie chart (a ring) for any window page; the same in every look.
-- (Carried over from our own earlier window's pie.)
--   local pie = ns.NewPie(parent, size, onClick)
--   pie:Set({ { value =, r =, g =, b =, text =, draw =, within = }, ... })
-- Each slice gets its share of the ring (draw, else value, over the sum).
-- draw lets a slice that contains another (the last 24 hours contain this
-- session) take only the part the other does not: the overlap is drawn
-- once, in the smaller slice. within = { [index] = true }: the slices it
-- contains, lit with it on hover. The ring is SEGS short thick lines; each
-- takes the colour of the slice its middle falls in. Hover dims the other
-- slices and shows the slice's count (the cursor is followed only while it
-- is over the pie); a click calls onClick(index of the slice). Nothing to
-- draw (every value 0): a faint ring.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local SEGS = 60
local TWO_PI = 2 * math.pi
local atan2 = math.atan2 or atan2

local Pie = {}
Pie.__index = Pie

function Pie:Set(slices)
	self.slices = slices
	local total = 0
	for i = 1, #slices do total = total + (slices[i].draw or slices[i].value or 0) end
	self.total = total
	local seg, acc, at = self.segSlice, 0, 1
	for s = 1, SEGS do seg[s] = 0 end
	if total > 0 then
		-- where each slice ends, 0..1 from the top, clockwise
		for i = 1, #slices do
			local v = slices[i].draw or slices[i].value or 0
			if v > 0 then
				acc = acc + v / total
				while at <= SEGS and (at - 0.5) / SEGS <= acc + 1e-9 do
					seg[at] = i
					at = at + 1
				end
			end
		end
	end
	self.hot = nil
	self:Paint()
end

-- colour every segment; the hovered slice (and the slices it contains)
-- full, the others dimmed
function Pie:Paint()
	local hot, slices = self.hot, self.slices
	local within = hot and slices[hot] and slices[hot].within
	for s = 1, SEGS do
		local i = self.segSlice[s]
		local line = self.segs[s]
		if i == 0 then
			line:SetColorTexture(1, 1, 1, 0.08)
			line:SetDrawLayer("ARTWORK", 0)
		else
			local sl = slices[i]
			local lit = hot == nil or hot == i or (within and within[i])
			line:SetColorTexture(sl.r, sl.g, sl.b, lit and 0.9 or 0.3)
			-- segments overlap a little (no seams): a lit one goes over a
			-- dimmed neighbour, never under it
			line:SetDrawLayer("ARTWORK", lit and 2 or 1)
		end
	end
	if hot then
		local sl = slices[hot]
		self.center:SetText(tostring(sl.value or 0))
		self.center:SetTextColor(sl.r, sl.g, sl.b)
	else
		self.center:SetText("")
	end
end

-- the slice under the cursor (nil: not on the ring)
function Pie:SliceAt()
	if not self.total or self.total == 0 then return nil end
	local x, y = GetCursorPosition()
	local sc = self.frame:GetEffectiveScale()
	local cx, cy = self.frame:GetCenter()
	if not (x and cx and sc and sc > 0) then return nil end
	local dx, dy = x / sc - cx, y / sc - cy
	local d = math.sqrt(dx * dx + dy * dy)
	if d < self.inner - 3 or d > self.outer + 3 then return nil end
	local a = atan2(dx, dy)
	if a < 0 then a = a + TWO_PI end
	local i = self.segSlice[math.min(math.floor(a / TWO_PI * SEGS) + 1, SEGS)]
	return i ~= 0 and i or nil
end

local function Hover(pie)
	local i = pie:SliceAt()
	if i == pie.hot then return end
	pie.hot = i
	pie:Paint()
	if i and pie.tip then ns.Tip(pie.frame, pie.tip(i)) else ns.HideTip() end
end

-- parent, size (px), onClick(slice index); pie.tip = function(i) -> text
function ns.NewPie(parent, size, onClick)
	local pie = setmetatable({ segs = {}, segSlice = {}, slices = {}, total = 0 }, Pie)
	local f = CreateFrame("Button", nil, parent)
	f:SetSize(size, size)
	pie.frame = f
	local ring = math.floor(size * 0.24)
	local r = (size - ring) / 2
	pie.inner, pie.outer = r - ring / 2, r + ring / 2
	local over = 0.6 / SEGS * TWO_PI	-- a little overlap: no seams
	for s = 1, SEGS do
		local a0 = (s - 1) / SEGS * TWO_PI - over
		local a1 = s / SEGS * TWO_PI + over
		local line = f:CreateLine(nil, "ARTWORK")
		line:SetThickness(ring)
		line:SetStartPoint("CENTER", f, r * math.sin(a0), r * math.cos(a0))
		line:SetEndPoint("CENTER", f, r * math.sin(a1), r * math.cos(a1))
		pie.segs[s] = line
		pie.segSlice[s] = 0
	end
	pie.center = ns.NewText(f, 14)
	pie.center:SetPoint("CENTER", f, "CENTER", 0, 0)
	local onUpdate = function() Hover(pie) end		-- one closure per pie, not per hover
	f:SetScript("OnEnter", function() f:SetScript("OnUpdate", onUpdate) end)
	f:SetScript("OnLeave", function()
		f:SetScript("OnUpdate", nil)
		pie.hot = nil
		pie:Paint()
		ns.HideTip()
	end)
	f:SetScript("OnClick", function()
		local i = pie:SliceAt()
		if i and onClick then onClick(i) end
	end)
	pie:Paint()
	return pie
end
