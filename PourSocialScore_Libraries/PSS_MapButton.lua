------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE GENERIC MINIMAP BUTTON (money-helper, DEC-00107,
-- DEC-00120). One factory for every minimap button PSS makes:
--   local b = M.PSS_MapButton({ key, icon, title, tip = function(tt),
--     clicks = { [Modifier..Button] = fn } })   b:SetIcon(tex) b:Show() b:Hide()
-- A button is one frame and four textures, built on the call and never at
-- load; its place is whole degrees under mapButtons ("<key>=<deg>;...",
-- default 225 not saved, unknown keys kept). Drag uses StartMoving and
-- the angle on stop; no OnUpdate. Only Blizzard's minimap art is used.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local atan2, cos, sin, floor = math.atan2, math.cos, math.sin, math.floor
local rad, deg = math.rad, math.deg

local DEFAULT_ANGLE = 225
local buttons = {}

-- "a=90;b=10" -> { a = "90" }, kept as the saved text so an unknown or odd
-- entry is written back untouched
local function Read()
	local t = {}
	local raw = M.PSS_Opt("mapButtons")
	if type(raw) == "string" then
		for k, v in raw:gmatch("([^=;]+)=([^;]*)") do t[k] = v end
	end
	return t
end

local function Angle(key)
	return tonumber(Read()[key]) or DEFAULT_ANGLE
end

local function Save(key, angle)
	local t = Read()
	angle = floor(angle % 360 + 0.5) % 360
	t[key] = (angle ~= DEFAULT_ANGLE) and tostring(angle) or nil
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = {}
	for i, k in ipairs(keys) do out[i] = k .. "=" .. t[k] end
	M.PSS_SetOpt("mapButtons", "global", #out > 0 and table.concat(out, ";") or nil)
end

local function Place(b)
	local a = rad(Angle(b.key))
	local r = Minimap:GetWidth() / 2 + 5
	local x, y = cos(a) * r, sin(a) * r
	if GetMinimapShape and GetMinimapShape() == "SQUARE" then
		local h = Minimap:GetWidth() / 2 + 5
		x = math.max(-h, math.min(h, x * 1.4142))
		y = math.max(-h, math.min(h, y * 1.4142))
	end
	b:ClearAllPoints()
	b:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function Modifier(btn)
	return (IsShiftKeyDown() and "Shift" or "") .. (IsControlKeyDown() and "Ctrl" or "") .. (IsAltKeyDown() and "Alt" or "") .. btn
end

function M.PSS_MapButton(spec)
	local key = spec.key
	if buttons[key] then return buttons[key] end
	local b = CreateFrame("Button", "PSS_MapButton_" .. key, Minimap)
	b.key, b.spec = key, spec
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("AnyUp")
	b:RegisterForDrag("LeftButton")
	b:SetMovable(true)
	local back = b:CreateTexture(nil, "BACKGROUND")
	back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	back:SetSize(20, 20)
	back:SetPoint("CENTER", b, "CENTER", 0, 1)
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	icon:SetPoint("CENTER", b, "CENTER", 0, 1)
	icon:SetTexture(spec.icon)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	b.icon = icon
	function b:SetIcon(tex) icon:SetTexture(tex or spec.icon) end
	b:SetScript("OnClick", function(self, btn)
		local fn = spec.clicks and spec.clicks[Modifier(btn)]
		if fn then fn(self, btn) end
	end)
	b:SetScript("OnDragStart", function(self) self:StartMoving() end)
	b:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local bx, by = self:GetCenter()
		local mx, my = Minimap:GetCenter()
		if bx and mx then Save(key, deg(atan2(by - my, bx - mx))) end
		Place(self)
	end)
	b:SetScript("OnEnter", function(self)
		if GameTooltip:IsForbidden() then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(spec.title)
		if spec.tip then spec.tip(GameTooltip) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() if not GameTooltip:IsForbidden() then GameTooltip:Hide() end end)
	Place(b)
	buttons[key] = b
	return b
end
