------------------------------------------------------------------------
-- The Addon Manager tab (interface-helper, 3.6.0.91): a collapsible
-- navigation on the left (ns.NewNav, M.PSS_MgrNav) and the page chosen on
-- the right: Addons, Optional Features, Import/Export, All Options, and a
-- note with an "Open <tab>" button for each Social Services list. Drawing
-- only; the page list and the state (page, folded) are Libraries
-- (PSS_ManagerNav.lua). Each page is built on first select. Folding is one
-- re-anchor in the click's own call: no timer, no OnUpdate.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local NAV_W, HEAD_H, SIDE = 180, 26, 6

ns.PageBuilders = ns.PageBuilders or {}
ns.TabBuilders = ns.TabBuilders or {}

local SOCIAL = {
	players = "Your Player Ignore List, with notes, expiry and the W I G P C flags, has its own tab.",
	guilds = "Your Guild Ignore List, with scans and the Guild Exclusion List, has its own tab.",
	filters = "Chat filters, custom rules and the chat link converter have their own tab.",
}
for key, line in pairs(SOCIAL) do
	ns.PageBuilders[key] = function(pg)
		local t = ns.NewText(pg, 12)
		t:SetPoint("TOPLEFT", pg, "TOPLEFT", 16, -16)
		t:SetPoint("RIGHT", pg, "RIGHT", -16, 0)
		t:SetJustifyH("LEFT")
		t:SetAlpha(0.8)
		t:SetText(line)
		local label = "Open " .. M.PSS_MgrRow(key).text
		pg.open = ns.NewButton(pg, label, 200, function() M.PSS_OpenUI(true, key) end)
		pg.open:SetPoint("TOPLEFT", pg, "TOPLEFT", 16, -52)
	end
end

local host

local function SetCollapsed(c)
	host.nav:SetShown(not c)
	host.body:ClearAllPoints()
	if c then
		host.body:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
	else
		host.body:SetPoint("TOPLEFT", host, "TOPLEFT", NAV_W + 2 * SIDE, 0)
	end
	host.body:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
	host.toggle:SetText(c and ">>" or "<<")
	M.PSS_SetMgrCollapsed(c)
end

local function ShowPage(key)
	local row = M.PSS_MgrRow(key)
	if not row then return end
	M.PSS_SetMgrPage(key)
	local pg = host.pages[key]
	if not pg then
		pg = CreateFrame("Frame", nil, host.body)
		pg:SetPoint("TOPLEFT", host.body, "TOPLEFT", 0, -HEAD_H)
		pg:SetPoint("BOTTOMRIGHT", host.body, "BOTTOMRIGHT", 0, 0)
		pg:Hide()
		host.pages[key] = pg
		local build = ns.PageBuilders[key] or (row.section and ns.SectionBuilder(row))
		if build then
			-- a page that fails to build reports its error and is shown empty
			local ok, refresh = xpcall(function() return build(pg) end, geterrorhandler())
			if ok then pg.refresh = refresh end
		end
	end
	for k, p in pairs(host.pages) do p:SetShown(k == key) end
	host.nav:Select(key)
	host.title:SetText(row.text)
	if pg.refresh then pg.refresh() end
end

ns.TabBuilders.addons = function(page)
	host = page
	host.pages = {}
	host.nav = ns.NewNav(host, { width = NAV_W, rows = M.PSS_MgrNav(), onSelect = ShowPage })
	host.nav:SetPoint("TOPLEFT", host, "TOPLEFT", SIDE, -SIDE)
	host.nav:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", SIDE, SIDE)
	host.body = CreateFrame("Frame", nil, host)
	host.toggle = ns.NewButton(host.body, "<<", 30, function() SetCollapsed(not M.PSS_MgrCollapsed()) end)
	host.toggle:SetHeight(HEAD_H - 6)
	host.toggle:SetPoint("TOPLEFT", host.body, "TOPLEFT", 8, -4)
	ns.TipOn(host.toggle, host.toggle, "Show or hide the list of pages.")
	host.title = ns.NewHeading(host.body, "")
	host.title:SetPoint("LEFT", host.toggle, "RIGHT", 10, 0)
	SetCollapsed(M.PSS_MgrCollapsed())
	ShowPage(M.PSS_MgrPage())

	-- the window's hooks: what shows is refreshed; each page drops what it
	-- read when the window closes
	host.stale = function()
		for _, p in pairs(host.pages) do if p.stale then p.stale() end end
	end
	host.release = function()
		for _, p in pairs(host.pages) do if p.release then p.release() end end
	end
	return function()
		local p = host.pages[M.PSS_MgrPage()]
		if p and p.refresh then p.refresh() end
	end
end

-- opened by an entry point (/acp, /pss acp, the binding, the compartment):
-- the page and the fold as that entry asks
function ns.ManagerShow(page, collapse)
	if page then M.PSS_SetMgrPage(page) end
	if collapse ~= nil then M.PSS_SetMgrCollapsed(collapse) end
	if host then
		SetCollapsed(M.PSS_MgrCollapsed())
		ShowPage(M.PSS_MgrPage())
	end
end
