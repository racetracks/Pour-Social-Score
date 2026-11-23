------------------------------------------------------------------------
-- POUR SOCIAL SCORE - WAREHOUSE TOOLTIP LINES (warehouse-helper, one-build
-- plan STP-p15, Syndicator parity 12 to 14). Who holds an item or a currency,
-- added to Blizzard's own tooltip. All tooltip handling is ours (the author,
-- 2026-10-16): one service decides what to add and one gated post-hook calls
-- it; nothing from any other addon is read or written.
--   wh.tip      item    -> kind, left, right     (holder lines, "and n more", a total)
--   wh.tipCur   currency -> kind, left, right
-- Options: whTooltips (the switch), whTipGuilds, whTipEquipped, whTipCurrency,
-- whTipShift, whTipRealms, whTipFaction, whTipLimit (0 lists every holder),
-- whTipByName, whTipTotal. One wh.sum per tooltip; a hovered item is kept
-- until WH_CHANGED or a collection. The hook is made once at login and only
-- when the Warehouse is on; it checks IsForbidden and every id through
-- M.PSS_IsSecret first (J6, J7). Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local sort, concat = table.sort, table.concat

local cache, cacheByName, curCache = {}, {}, {}
local idMap
function M.PSS_WhTipDrop() cache, cacheByName, curCache, idMap = {}, {}, {}, nil end
M.Events.Register("WH_CHANGED", function() cache, cacheByName, curCache, idMap = {}, {}, {}, nil end)
M.Events.Register("WH_DELETED", function() cache, cacheByName, curCache, idMap = {}, {}, {}, nil end)
M.Events.Register("OPTION_CHANGED", function(key) if type(key) == "string" and key:sub(1, 5) == "whTip" then cache, cacheByName, curCache = {}, {}, {} end end)

local COLNAMES = { "Bags", "Bank", "Reagents", "Mail", "Equipped", "Void", "Auctions", "Guild bank", "Warband bank" }

local function myFaction()
	return UnitFactionGroup and (UnitFactionGroup("player")) or nil
end

-- keys sharing an item id (a variant's id), or a pet species: built when first needed
local function sameId(key)
	if not idMap then
		idMap = {}
		if M.PSS_WhHolders then
			local d = rawget(_G, "PSS_WarehouseDB")
			for _, ref in ipairs(M.PSS_WhHolders:list()) do
				local k = ref
				if ref:sub(1, 1) == "x" then k = d and d.item and d.item[tonumber(ref:sub(2))] end
				if k then
					local gid = k:match("^(p:%d+):") or tostring(M.PSS_ItemId(k) or "")
					idMap[gid] = idMap[gid] or {}
					idMap[gid][#idMap[gid] + 1] = k
				end
			end
		end
	end
	local gid = key:match("^(p:%d+):") or tostring(M.PSS_ItemId(key) or "")
	return idMap[gid] or { key }
end

local function label(r, mineRealm)
	local f = r
	if f[2] == "g" then return f[3] .. " (guild bank)" end
	if f[2] == "w" then return "Warband bank" end
	if M.PSS_Opt("whTipRealms") and f[4] and f[4] ~= "" and f[4] ~= mineRealm then return f[3] .. "-" .. f[4] end
	return f[3]
end

local function limited(list, out)
	local limit = tonumber(M.PSS_Opt("whTipLimit")) or 4
	local shown = (limit > 0 and limit < #list) and limit or #list
	for i = 1, shown do out.n = out.n + 1; out[out.n] = list[i] end
	if shown < #list then out.n = out.n + 1; out[out.n] = { "more", "and " .. (#list - shown) .. " more", "" } end
end

-- the holders of one item as { kind, left, right, n, entKind } sorted by count, and their total; nil when a read failed
local function holderList(key)
	local keys = M.PSS_Opt("whTipByName") and sameId(key) or { key }
	local set = { cols = { "item" }, n = #keys }
	for i, k in ipairs(keys) do set[i] = { k } end
	local sum, err = M.PSS_Call("wh.sum", set, { faction = M.PSS_Opt("whTipFaction") and myFaction() or nil, realms = M.PSS_WhThisRealm() })
	if err or not sum then return nil end		-- a failed read never shows another item's holders
	local by, ids, total = {}, {}, 0
	for i = 1, sum.n do
		local r = sum[i]
		local e = by[r[2]]
		if not e then e = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }; by[r[2]] = e; ids[#ids + 1] = { r[2] } end
		for c = 1, 9 do e[c] = e[c] + (r[2 + c] or 0) end
	end
	if #ids == 0 then return {}, 0 end		-- nobody holds it: an empty set must never widen wh.ent to every entity
	local entSet = { cols = { "ent" }, n = #ids }
	for i, v in ipairs(ids) do entSet[i] = v end
	local ents, eerr = M.PSS_Call("wh.ent", entSet)
	if eerr or not ents then return nil end
	local mineRealm = GetRealmName and GetRealmName() or ""
	local list = {}
	for i = 1, ents.n do
		local f = ents[i]
		local e = by[f[1]]
		if e and not (f[2] == "g" and not M.PSS_Opt("whTipGuilds")) then
			local parts, n = {}, 0
			for c, name in ipairs(COLNAMES) do
				local v = e[c]
				if v > 0 and not (c == 5 and not M.PSS_Opt("whTipEquipped")) then
					parts[#parts + 1] = name .. " " .. v
					n = n + v
				end
			end
			if n > 0 then
				total = total + n
				list[#list + 1] = { "holder", label(f, mineRealm), concat(parts, ", "), n, f[2] }
			end
		end
	end
	sort(list, function(a, b) if a[4] ~= b[4] then return a[4] > b[4] end return a[2] < b[2] end)
	return list, total
end
M.PSS_WhHolderList = holderList

local COLS = { "kind", "left", "right" }
M.PSS_Provide("wh.tip", function(input)
	local key = input and input.n > 0 and input[1][1]
	if type(key) == "number" then key = tostring(key) end
	local kept = M.PSS_Opt("whTipByName") and cacheByName or cache		-- no string is made to look a kept answer up
	local hit = type(key) == "string" and kept[key]
	if hit then return hit end
	local out = { cols = COLS, n = 0 }
	if type(key) ~= "string" then return out end
	local okc, list, total = pcall(holderList, key)
	if not okc then		-- a bug for one item is noted once and never counts toward the breaker, so other items keep their tooltips
		if M.PSS_ErrNote then M.PSS_ErrNote("fail", "wh.tip", key .. ": " .. tostring(list)) end
		return out
	end
	if not list then return out end
	limited(list, out)
	if M.PSS_Opt("whTipTotal") and total > 0 then out.n = out.n + 1; out[out.n] = { "total", "Total", tostring(total) } end
	kept[key] = out
	return out
end, { accepts = { "item" }, returns = { "kind", "left", "right" }, doc = "the tooltip lines for an item", cost = "O(holders)", writes = false, onError = "empty" })

M.PSS_Provide("wh.tipCur", function(input)
	local id = input and input.n > 0 and tonumber(input[1][1])
	local ckey = id
	if ckey and curCache[ckey] then return curCache[ckey] end
	local out = { cols = COLS, n = 0 }
	if not id then return out end
	local cur, cerr = M.PSS_Call("wh.cur", id, { faction = M.PSS_Opt("whTipFaction") and myFaction() or nil, realms = M.PSS_WhThisRealm() })
	if cerr or not cur then return out end
	local ids = { cols = { "ent" }, n = cur.n }
	for i = 1, cur.n do ids[i] = { cur[i][1] } end
	local ents, eerr = M.PSS_Call("wh.ent", ids)
	if eerr or not ents then return out end
	local q = {}
	for i = 1, cur.n do q[cur[i][1]] = cur[i][3] end
	local mineRealm = GetRealmName and GetRealmName() or ""
	local list = {}
	for i = 1, ents.n do
		local f = ents[i]
		list[#list + 1] = { "holder", label(f, mineRealm), tostring(q[f[1]] or 0), q[f[1]] or 0 }
	end
	sort(list, function(a, b) if a[4] ~= b[4] then return a[4] > b[4] end return a[2] < b[2] end)
	limited(list, out)
	curCache[ckey] = out
	return out
end, { accepts = { "currency" }, returns = { "kind", "left", "right" }, doc = "the tooltip lines for a currency", cost = "O(holders)", writes = false, onError = "empty" })

------------------------------------------------------------------------
-- The one gated post-hook
------------------------------------------------------------------------
local function add(tip, set)
	if not set or set.n == 0 then return end
	tip:AddLine(" ")
	for i = 1, set.n do
		local r = set[i]
		if tip.AddDoubleLine then tip:AddDoubleLine(r[2], r[3], 1, 1, 1, 0.8, 0.8, 0.8) else tip:AddLine(r[2] .. "  " .. r[3]) end
	end
end

local function allowed(tip, opt)
	if not (M.PSS_Opt("whTooltips") and M.PSS_On("warehouse")) then return false end
	if opt and not M.PSS_Opt(opt) then return false end
	if M.PSS_Opt("whTipShift") and not (IsShiftKeyDown and IsShiftKeyDown()) then return false end
	if tip and tip.IsForbidden and tip:IsForbidden() then return false end
	return true
end

function M.PSS_WhTipItem(tip, data)
	if not allowed(tip) or type(data) ~= "table" then return end
	local id, link = data.id, data.hyperlink
	if (type(id) ~= "nil" and M.PSS_IsSecret and M.PSS_IsSecret(id)) or (type(link) ~= "nil" and M.PSS_IsSecret and M.PSS_IsSecret(link)) then return end
	local key = type(link) == "string" and M.PSS_ItemKey(link) or (type(id) == "number" and tostring(id))
	if not key then return end
	add(tip, M.PSS_Call("wh.tip", key))
end

function M.PSS_WhTipCurrency(tip, data)
	if not allowed(tip, "whTipCurrency") or type(data) ~= "table" then return end
	local id = data.id
	if type(id) ~= "number" or (M.PSS_IsSecret and M.PSS_IsSecret(id)) then return end
	add(tip, M.PSS_Call("wh.tipCur", id))
end

function M.PSS_WhTipPet(tip, data)
	if not allowed(tip) or type(data) ~= "table" then return end
	local id = data.id or data.speciesID
	if type(id) ~= "number" or (M.PSS_IsSecret and M.PSS_IsSecret(id)) then return end
	-- a pet is kept under its cage's key: species, level, quality; the species lines join every level
	local keys = sameId("p:" .. id .. ":0:0")
	if #keys == 0 then return end
	add(tip, M.PSS_Call("wh.tip", keys[1]))
end

local hooked = false
local prev = M.PSS_WhStartMore
function M.PSS_WhStartMore(warehouse)
	if prev then prev(warehouse) end
	if not warehouse or hooked then return end
	hooked = true
	local T, E = TooltipDataProcessor, Enum and Enum.TooltipDataType
	if T and T.AddTooltipPostCall and E then
		if E.Item then T.AddTooltipPostCall(E.Item, M.PSS_WhTipItem) end
		if E.Currency then T.AddTooltipPostCall(E.Currency, M.PSS_WhTipCurrency) end
		if E.BattlePet then T.AddTooltipPostCall(E.BattlePet, M.PSS_WhTipPet) end
	else
		-- clients without the processor: the tooltip's own script, items only
		for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
			if tip and tip.HookScript then
				tip:HookScript("OnTooltipSetItem", function(t)
					local ok, name, link = pcall(t.GetItem, t)
					if ok and link then M.PSS_WhTipItem(t, { hyperlink = link }) end
				end)
			end
		end
	end
end
