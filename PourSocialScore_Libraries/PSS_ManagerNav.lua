-- The Addon Manager tab's navigation (interface-helper, 3.6.0.91): which
-- pages it lists, which page is shown and whether the list is folded. Logic
-- only; PourSocialScore_GUI/PSS_Manager.lua and ns.NewNav draw it. Session
-- state only: nothing is saved.
local addon = PourSocialScore_NS
local M = addon.M

-- one table, order = draw order. head: a heading. on: listed only while that
-- Enabled component is on. tab: the entry opens that top tab instead.
local NAV = {
	{ head = "Global Settings" },
	{ key = "addons", text = "Addons", on = "addons" },
	{ key = "features", text = "Optional Features" },
	{ key = "importExport", text = "Import/Export" },
	{ head = "Social Services" },
	{ key = "players", text = "Player Ignore List", tab = "players" },
	{ key = "guilds", text = "Guild Ignore List", tab = "guilds" },
	{ key = "filters", text = "Chat Filter Rules", tab = "filters" },
	{ head = "Options" },
	{ key = "options", text = "All Options" },
}

-- built once per session; a heading with no entry under it is dropped
local rows
function M.PSS_MgrNav()
	if rows then return rows end
	rows = {}
	local head
	for _, r in ipairs(NAV) do
		if r.head == "Options" then
			-- a group of Options sections (M.PSS_OPTION_SECTION_GROUP, key
			-- M.PSS_OPTION_SECTION_PAGE) is a heading with an entry each
			local sec = M.PSS_OPTION_SECTION_PAGE or {}
			local gh
			for _, section in ipairs(M.PSS_OPTION_SECTION_ORDER) do
				local group, pg = M.PSS_OptSectionGroup(section), sec[section]
				if group and pg then
					if gh ~= group then rows[#rows + 1] = { head = group }; gh = group end
					rows[#rows + 1] = { key = pg, text = (M.PSS_OPTION_SECTIONS[section]:gsub("[:%s]+$", "")), section = section }
				end
			end
		end
		if r.head then
			head = r
		elseif not r.on or M.PSS_On(r.on) then
			if head then rows[#rows + 1] = head; head = nil end
			rows[#rows + 1] = r
		end
	end
	return rows
end

local pages
function M.PSS_MgrHas(key)
	if not pages then
		pages = {}
		for _, r in ipairs(M.PSS_MgrNav()) do
			if r.key then pages[r.key] = r end
		end
	end
	return pages[key] ~= nil
end

-- the tab keys older builds saved or accepted, and the page each became
M.PSS_TAB_ALIAS = {
	importExport = { tab = "addons", page = "importExport" },
	options = { tab = "addons", page = "options" },
	events = { tab = "console" },
}

-- a key from any build: the tab key to open and the Addon Manager page (nil
-- for a plain tab; the page then stays as it was)
function M.PSS_ResolveTab(key)
	local a = M.PSS_TAB_ALIAS[key]
	if a then return a.tab, a.page end
	return key
end

function M.PSS_MgrRow(key)
	for _, r in ipairs(M.PSS_MgrNav()) do
		if r.key == key then return r end
	end
end

local page, collapsed
-- first page: Addons, else Optional Features (the Addons entry is off)
function M.PSS_MgrPage()
	if page and M.PSS_MgrHas(page) then return page end
	return M.PSS_MgrHas("addons") and "addons" or "features"
end
function M.PSS_SetMgrPage(key)
	if M.PSS_MgrHas(key) then page = key end
end
function M.PSS_MgrCollapsed() return collapsed == true end
function M.PSS_SetMgrCollapsed(b) collapsed = b == true end
