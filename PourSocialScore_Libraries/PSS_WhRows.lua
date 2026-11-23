------------------------------------------------------------------------
-- POUR SOCIAL SCORE - WAREHOUSE ROWS (warehouse-helper, W-3 F5). What the
-- Search Everywhere view draws, as plain rows { key, name, icon, link,
-- total, where }:
--   M.PSS_WhSearchRows(text, onMore)  the rows of a search and whether it is complete
--   M.PSS_WhMineRows()                with nothing typed: this character's items by name
-- Names the client has not given yet are asked for (M.PSS_ItemAwait); the view draws
-- again on ITEM_DATA. Loaded with Libraries; returns at the top while the Warehouse is off.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, ipairs, pairs, next, tonumber = type, ipairs, pairs, next, tonumber
local sort, concat = table.sort, table.concat

local MAXROWS = 200
local MAXMINE = 400		-- rows of this character shown before anything is typed

-- name, icon and a link for the hover tooltip of an item key; `missing` when the client has not told us the name yet
local function describe(key)
	local id = M.PSS_ItemId and M.PSS_ItemId(key)
	if not id or not M.PSS_ItemText then return nil, key, nil, nil, false end
	local name, icon = M.PSS_ItemText(id)
	local known = type(name) == "string" and not name:find("^item:")
	return id, name, icon, "item:" .. id, known
end

-- ask the client for the names it has not given yet; the window draws again on ITEM_DATA
local function askNames(unknown)
	if next(unknown) and M.PSS_ItemAwait then M.PSS_ItemAwait(unknown) end
end

local function holders(key)
	local list = M.PSS_WhHolderList and M.PSS_WhHolderList(key)
	if not list or #list == 0 then return "" end
	local shown = list[1]
	for i = 1, #list do if list[i][5] == "g" then shown = list[i]; break end end		-- a guild bank holder is named first
	local where = shown[2]
	if #list > 1 then where = where .. " and " .. (#list - 1) .. " more" end
	return where
end

-- the rows for a search text, and whether the search is complete (an item whose data the client has not given yet is
-- still being looked at); onMore() is called once more results arrived
function M.PSS_WhSearchRows(text, onMore)
	local rows = {}
	if type(text) ~= "string" or not text:find("%S") then return rows, true end
	local found = M.PSS_CallSet("item.search", nil, { text = text, pageSize = MAXROWS })
	local done = found.done ~= false
	if not done and onMore and M.PSS_ItemSearchWatch then M.PSS_ItemSearchWatch(text, onMore) end
	if found.n == 0 then return rows, done end
	local keys = { cols = { "item" }, n = found.n }
	for i = 1, found.n do keys[i] = { found[i][1] } end
	local sum = M.PSS_CallSet("wh.sum", keys, { hidden = false, realms = M.PSS_WhRealmScope() })
	local total = {}
	for i = 1, sum.n do total[sum[i][1]] = (total[sum[i][1]] or 0) + (sum[i][12] or 0) end
	local unknown = {}
	for i = 1, found.n do
		local key, name = found[i][1], found[i][2]
		local id, label, icon, link, known = describe(key)
		if (not name or name == "") and known then name = label end
		if id and not known then unknown[id] = true end
		if (total[key] or 0) > 0 then
			rows[#rows + 1] = { key = key, name = (name and name ~= "") and name or label, icon = icon, link = link, total = total[key] or 0, where = holders(key) }
		end
	end
	askNames(unknown)
	sort(rows, function(a, b) if a.name ~= b.name then return a.name < b.name end return a.key < b.key end)
	return rows, done
end

local FAMILY = { b = "Bags", k = "Bank", r = "Reagent bank", y = "Keyring", e = "Equipped", m = "Mail", v = "Void storage", a = "Auctions", w = "Warband bank" }

-- F5: with nothing typed the window shows what this character holds, by name; { rows, truncated }
function M.PSS_WhMineRows()
	local rows = {}
	local me = M.PSS_Me and M.PSS_Me(false)
	if not me then return rows, false end
	local c = M.PSS_CallSet("wh.cont", { cols = { "ent" }, n = 1, { me } })
	local ci, ii, ni = M.PSS_SetCol(c, "cont"), M.PSS_SetCol(c, "item"), M.PSS_SetCol(c, "count")
	if not (ci and ii and ni) then return rows, false end
	local by, order = {}, {}
	for i = 1, c.n do
		local key = c[i][ii]
		local e = by[key]
		if not e then e = { total = 0, fam = {} }; by[key] = e; order[#order + 1] = key end
		e.total = e.total + (tonumber(c[i][ni]) or 1)
		e.fam[FAMILY[c[i][ci]:sub(1, 1)] or "Other"] = true
	end
	local unknown = {}
	for _, key in ipairs(order) do
		local e = by[key]
		local id, label, icon, link, known = describe(key)
		if id and not known then unknown[id] = true end
		local fams = {}
		for f in pairs(e.fam) do fams[#fams + 1] = f end
		sort(fams)
		rows[#rows + 1] = { key = key, name = label, icon = icon, link = link, total = e.total, where = concat(fams, ", ") }
	end
	askNames(unknown)
	sort(rows, function(a, b) if a.name ~= b.name then return a.name < b.name end return a.key < b.key end)
	local truncated = #rows > MAXMINE
	for i = #rows, MAXMINE + 1, -1 do rows[i] = nil end
	return rows, truncated
end

function M.PSS_WhShowLocation(key)
	if type(key) ~= "string" then return end
	if type(M.PSS_GwShow) == "function" then
		-- an addon that registered for locations (the shim) is told; it opens its own view
		local ok = pcall(M.PSS_GwShow, key)
		if ok then return end
	end
	local list = M.PSS_WhHolderList and M.PSS_WhHolderList(key)
	if not list or #list == 0 then M.ShowMsg("Nobody holds that item.") return end
	local id = M.PSS_ItemId and M.PSS_ItemId(key)
	local name = id and M.PSS_ItemText and M.PSS_ItemText(id) or key
	M.ShowMsg(tostring(name) .. ":")
	for _, h in ipairs(list) do M.ShowMsg("  " .. h[2] .. ": " .. h[3]) end
end
