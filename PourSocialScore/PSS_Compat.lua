local addonName, addon = ...
local M = addon.M

-- Direct compat adapters (multi-version suite, design.md#menu,
-- #compartment, #reload, #templates). Each implementation is chosen once at
-- load from M.PSS_FLV.caps; callers never test the client.

local pcall = pcall
local type = type
local ipairs = ipairs

local caps = M.PSS_FLV.caps
local function on(cap)
	return caps[cap] ~= nil and caps[cap] ~= "off"
end

-- unit and Group Finder menus: true after the call, false with no call
if on("modernMenu") then
	function M.PSS_CompatMenu(tag, fn)
		local mm = Menu and Menu.ModifyMenu
		if not mm then return false end
		pcall(mm, tag, fn)
		return true
	end
else
	function M.PSS_CompatMenu()
		return false
	end
end

-- addon compartment entry: true after the call, false with no call
if on("compartment") then
	function M.PSS_CompatCompartment(entry)
		local frame = AddonCompartmentFrame
		if not (frame and frame.RegisterAddon) then return false end
		frame:RegisterAddon(entry)
		return true
	end
else
	function M.PSS_CompatCompartment()
		return false
	end
end

-- how this client reloads: "press" on Camelot (it blocks ReloadUI from addon
-- code even inside a click: only the player's own click on a secure "/reload"
-- macro reloads, which ns.Confirm { reload = true } sets up), else "direct"
local reloadMode = on("reloadButton") and "press" or "direct"
function M.PSS_ReloadMode()
	return reloadMode
end

-- template kinds and their candidates in order
local CANDIDATES = {
	frame = { "ButtonFrameTemplate", "PortraitFrameTemplate", "BasicFrameTemplateWithInset" },
	scroll = { "ScrollFrameTemplate", "UIPanelScrollFrameTemplate" },
	tab = { "PanelTopTabButtonTemplate", "TabButtonTemplate" },
	button = { "UIPanelButtonTemplate" },
	check = { "UICheckButtonTemplate" },
	input = { "InputBoxTemplate" },
	inset = { "InsetFrameTemplate" },
}

-- one entry per kind: the chosen name, or false when none exists
local chosen = {}

-- the first candidate the client knows; the first candidate when C_XMLUtil is
-- missing; nil when none exists (the caller builds the Dark parts)
function M.PSS_CompatTemplate(kind)
	local hit = chosen[kind]
	if hit ~= nil then return hit or nil end
	local list = CANDIDATES[kind]
	if not list then return nil end
	local xml = C_XMLUtil
	local info = xml and xml.GetTemplateInfo
	local name
	if type(info) ~= "function" then
		name = list[1]
	else
		for _, cand in ipairs(list) do
			if info(cand) ~= nil then name = cand break end
		end
	end
	chosen[kind] = name or false
	return name
end

-- TBC Anniversary: the PSS window anchors flush beside FriendsFrame (cap
-- friendsAnchor). One reused table; the strata is read per call. nil unless
-- the cap is on and host is FriendsFrame.
local friendsAnchor = { x = 2, y = 0 }
function M.PSS_CompatFriendsAnchor(host)
	if not (on("friendsAnchor") and host ~= nil and host == FriendsFrame) then return nil end
	friendsAnchor.strata = FriendsFrame:GetFrameStrata()
	return friendsAnchor
end
