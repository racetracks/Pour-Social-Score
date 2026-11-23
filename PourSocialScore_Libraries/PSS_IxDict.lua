------------------------------------------------------------------------
-- POUR SOCIAL SCORE - JOIN DICTIONARIES (search-helper, STP-00236). The
-- dictionaries a query joins by id (q.join adds "<dict>_<field>" columns),
-- each a lookup into a store that already exists (no copy of names):
--   item     name quality ilvl class link pending   (the client's item cache; an item it has not
--            loaded reads "item:<id>" with pending 1, and is asked for once per session)
--   owner    kind name note listed                  (the lists: p: player, G: guild, g: member, f: filter)
--   cmp      label                                  (a component's name: dtt, wh, addons, ...)
--   evt      label                                  (a client event's channel label)
--   channel  name
-- (ent: name realm kind, from PSS_Entity.lua.) M.PSS_IX_DICTS lists their
-- fields (the parser checks joined columns with it). M.PSS_IxItemPending
-- counts rows that came back pending since the last read (a view re-runs
-- once on GET_ITEM_INFO_RECEIVED: M.PSS_IxOnItemData). Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tonumber, tostring, ipairs, match, sub = type, tonumber, tostring, ipairs, string.match, string.sub

local History = M.PSS_History

M.PSS_IX_DICTS = {
	item = { "name", "quality", "ilvl", "class", "link", "pending" },
	owner = { "kind", "name", "note", "listed" },
	cmp = { "label" },
	evt = { "label" },
	channel = { "name" },
	ent = { "name", "realm", "kind" },
}

local requested = {}
M.PSS_IxDictStats = { requests = 0, pending = 0 }

local function itemId(v)
	if type(v) == "number" then return v end
	return tonumber(match(tostring(v or ""), "^x?(%d+)"))
end

M.PSS_QueryDict("item", M.PSS_IX_DICTS.item, function(ref, dest, at)
	local id = itemId(ref)
	if not id or id <= 0 then return end
	local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local name, link, quality, ilvl, _, _, _, _, _, _, _, class = nil
	if f then name, link, quality, ilvl, _, _, _, _, _, _, _, class = f(id) end
	if type(name) ~= "string" or (M.PSS_IsSecret and M.PSS_IsSecret(name)) then
		dest[at], dest[at + 5] = "item:" .. id, 1
		M.PSS_IxDictStats.pending = M.PSS_IxDictStats.pending + 1
		if not requested[id] then
			requested[id] = true
			M.PSS_IxDictStats.requests = M.PSS_IxDictStats.requests + 1
			local load = C_Item and C_Item.RequestLoadItemDataByID
			if load then load(id) end
		end
		return
	end
	dest[at], dest[at + 1], dest[at + 2], dest[at + 3], dest[at + 4], dest[at + 5] = name, quality, ilvl, class, link, nil
end)

local KIND = { p = "player", G = "guild", g = "member", f = "filter" }
M.PSS_QueryDict("owner", M.PSS_IX_DICTS.owner, function(key, dest, at)
	if type(key) ~= "string" then return end
	local k, rest = match(key, "^(%a):(.*)$")
	local kind = k and KIND[k]
	if not kind then return end
	dest[at], dest[at + 1] = kind, rest
	if kind == "player" then
		local rec = M.PSS_GetPlayerRecord and M.PSS_GetPlayerRecord(rest)
		local listed = M.PSS_IsPlayerListed and M.PSS_IsPlayerListed(rest)
		if rec and rec.name then dest[at + 1] = rec.name end
		dest[at + 3] = listed and 1 or nil
		if listed then
			for i, e in ipairs(M.PSS_List()) do
				if History.PlayerKey(e.name) == key then dest[at + 2] = e.note; break end
			end
		end
	elseif kind == "guild" then
		local g = M.PSS_FindGuildRule and M.PSS_FindGuildRule(rest)
		dest[at + 3] = g and 1 or nil
		if type(g) == "table" and g.name then dest[at + 1] = g.name end
	elseif kind == "filter" then
		local id = tonumber(match(rest, "^(%d+)"))
		dest[at + 3] = 1
		dest[at + 1] = rest
		if id then dest[at + 1] = "filter " .. id end
	end
end)

local CMP = { dtt = "Drop Cheapest Thing", wh = "Warehouse", bag = "Bags", addons = "Addon Manager", gfx = "Graphics Settings",
	macro = "Macro Helper", upgrade = "Upgrades", pss = "Pour Social Score" }
M.PSS_IX_CMP_LABELS = CMP
M.PSS_QueryDict("cmp", M.PSS_IX_DICTS.cmp, function(id, dest, at)
	if type(id) ~= "string" then return end
	dest[at] = CMP[id] or CMP[sub(id, 5)] or id
end)

M.PSS_QueryDict("evt", M.PSS_IX_DICTS.evt, function(id, dest, at)
	if type(id) ~= "string" or (M.PSS_IsSecret and M.PSS_IsSecret(id)) then return end
	dest[at] = M.PSS_ChannelLabel and M.PSS_ChannelLabel(id) or id
end)

M.PSS_QueryDict("channel", M.PSS_IX_DICTS.channel, function(id, dest, at)
	if type(id) ~= "string" or (M.PSS_IsSecret and M.PSS_IsSecret(id)) then return end
	dest[at] = id
end)

-- the rows of the last join that were pending (and resets the count)
function M.PSS_IxItemPending()
	local n = M.PSS_IxDictStats.pending
	M.PSS_IxDictStats.pending = 0
	return n
end

-- a view re-runs once when the client sends item data (only while it asks; never a timer)
function M.PSS_IxOnItemData(fn)
	if not M.PSS_Want then return end
	M.PSS_Unwant("ix.itempending")
	M.PSS_Want({ id = "ix.itempending", class = "await-data", on = { "GET_ITEM_INFO_RECEIVED" }, once = true, fn = fn })
end
