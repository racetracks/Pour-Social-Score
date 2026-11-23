------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE SYNDICATOR SHIM (warehouse-helper, one-build plan
-- STP-p14, DEC-00130, DEC-00131; Syndicator parity 12 to 15, 24). Other
-- addons (Baganator, TSM-style tools) ask Syndicator for stored inventory.
-- Syndicator is by Plusmouse; this file is written from the behaviour its
-- documented API shows (read, not copied). It is a thin adapter: each call is
-- translated to a PSS service (wh.find, wh.cur, wh.cont, wh.ent, ...) and the
-- PSS result is shaped the way the caller expects. No logic lives here.
-- The `Syndicator` global is defined once, at PLAYER_LOGIN, only when the
-- Warehouse is on, Syndicator is neither loaded nor enabled and no other addon
-- defines the name (the author's answer 2026-10-16; 02_RULES Overrides).
-- A character, guild or the warband is handed out as a read-only view whose
-- fields (bags, bank, mail, ...) are built when first read and kept until
-- WH_CHANGED for that entity or a collection; writing to a view does nothing.
-- Loaded with Libraries; returns at the top while the Warehouse is off.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, pairs, ipairs, tonumber, tostring, error, setmetatable = type, pairs, ipairs, tonumber, tostring, error, setmetatable
local sort = table.sort
local floor = math.floor

-- a failed service call is nil here, never another call's last result; the wrapper turns the breach into the documented empty value
local Call = function(...) local r, err = M.PSS_Call(...); if err then return nil end return r end
local stats = { builds = 0 }
function M.PSS_GwStats() return stats end

------------------------------------------------------------------------
-- Shapes (data): the answers other addons expect
------------------------------------------------------------------------
local FIELD = { b = "bags", y = "bags", k = "bank", r = "bank", m = "mail", e = "equipped", v = "void", a = "auctions", t = "bank", w = "bank" }

local function setOf(...)
	local s = { cols = { "ent" }, n = 0 }
	for _, id in ipairs({ ... }) do s.n = s.n + 1; s[s.n] = { id } end
	return s
end

local function entRows(ids)
	local set = { cols = { "ent" }, n = 0 }
	for id in pairs(ids) do set.n = set.n + 1; set[set.n] = { id } end
	sort(set, function(a, b) return a[1] < b[1] end)
	return Call("wh.ent", set, { hidden = true })
end

local function person(r)
	return { character = r[3], realmNormalized = r[4], className = r[6], race = r[7], sex = r[8] }
end

M.PSS_GwShapes["syn.inv"] = function(found)
	local by, ids = {}, {}
	for i = 1, found.n do
		local ent, code, n = found[i][2], found[i][3], found[i][4]
		local f = FIELD[code:sub(1, 1)]
		by[ent] = by[ent] or {}
		by[ent][f] = (by[ent][f] or 0) + n
		ids[ent] = true
	end
	local out = { characters = {}, guilds = {}, warband = { bank = 0 } }
	local ents = entRows(ids)
	for i = 1, ents.n do
		local r = ents[i]
		local c = by[r[1]]
		if r[2] == "c" then
			local p = person(r)
			p.bags, p.bank, p.mail, p.equipped, p.void, p.auctions = c.bags or 0, c.bank or 0, c.mail or 0, c.equipped or 0, c.void or 0, c.auctions or 0
			out.characters[#out.characters + 1] = p
		elseif r[2] == "g" then
			out.guilds[#out.guilds + 1] = { guild = r[3], realmNormalized = r[4], bank = c.bank or 0 }
		else
			out.warband.bank = c.bank or 0
		end
	end
	return out
end

M.PSS_GwShapes["syn.cur"] = function(rows)
	local ids = {}
	for i = 1, rows.n do ids[rows[i][1]] = true end
	local out = { characters = {}, warband = {} }
	local ents = entRows(ids)
	local q = {}
	for i = 1, rows.n do q[rows[i][1]] = rows[i][3] end
	for i = 1, ents.n do
		local r = ents[i]
		if r[2] == "c" then
			local p = person(r)
			p.quantity = q[r[1]]
			out.characters[#out.characters + 1] = p
		elseif r[2] == "w" then
			out.warband[#out.warband + 1] = { quantity = q[r[1]] }
		end
	end
	return out
end

M.PSS_GwShapes["syn.names"] = function(set)
	local out = {}
	for i = 1, set.n do out[#out + 1] = set[i][3] .. "-" .. set[i][4] end
	return out
end
M.PSS_GwShapes["syn.name"] = function(set) return set.n > 0 and (set[1][3] .. "-" .. set[1][4]) or nil end
M.PSS_GwShapes["syn.view"] = function(v) return v end
M.PSS_GwShapes["bool"] = function(v) return v end
M.PSS_GwShapes["num"] = function(v) return v end
M.PSS_GwShapes["list"] = function(v) return v end
M.PSS_GwShapes["frame"] = function(v) return v end
M.PSS_GwShapes["none"] = function(v) return v end

------------------------------------------------------------------------
-- The read-only view of one entity
------------------------------------------------------------------------
-- an item key back to a link another addon can read (the original link is not saved)
local function linkOf(key)
	local id = M.PSS_ItemId and M.PSS_ItemId(key)
	if not id then return nil end
	if key:sub(1, 2) == "p:" then
		local species, level, quality = key:match("^p:(%d+):(%d+):(%d+)")
		return ("|cff0070dd|Hbattlepet:%s:%s:%s:0:0:0:0000000000000000|h[Pet Cage]|h|r"):format(species, level, quality)
	elseif key:sub(1, 2) == "k:" then
		local map, lvl = key:match("^k:(%d+):(%d+)")
		return ("|cffa335ee|Hkeystone:%d:%s:%s:0:0:0:0|h[Keystone]|h|r"):format(id, map, lvl)
	end
	local f = {}
	for part in (key .. ":"):gmatch("([^:]*):") do f[#f + 1] = part end
	local link = {}
	for i = 1, #f do link[i] = f[i] end
	-- id : enchant : gem1..gem4 : suffix : ... : bonuses (the key keeps the fields in link order, zeros for none)
	local out = "item:" .. table.concat(link, ":")
	return "|cffffffff|H" .. out .. "|h[Item]|h|r"
end

local function slotOf(key, count, flags)
	local id = M.PSS_ItemId(key)
	local quality, icon
	local f = C_Item and C_Item.GetItemInfo or GetItemInfo
	if f and id then
		local r = { f(id) }
		quality, icon = r[3], r[10]
	end
	return { itemID = id, itemCount = count, itemLink = linkOf(key), quality = quality or 1, iconTexture = icon or 134400, isBound = flags and flags:find("b", 1, true) ~= nil or false }
end

-- the slots of one container as an array by slot (an empty slot is an empty table)
local function slotsOf(rows, size)
	local out, top = {}, size or 0
	for slot in pairs(rows) do if slot > top then top = slot end end
	for i = 1, top do out[i] = rows[i] or {} end
	return out
end

local cache = {}
function M.PSS_GwDrop() cache = {} end
M.Events.Register("WH_CHANGED", function(set)
	for i = 1, set and set.n or 0 do cache[set[i][1]] = nil end
end)
M.Events.Register("WH_DELETED", function(set)
	for i = 1, set and set.n or 0 do cache[set[i][1]] = nil end
end)

local function containers(ent)
	local rows = Call("wh.cont", setOf(ent))
	local by = {}
	for i = 1, rows.n do
		local r = rows[i]		-- ent, cont, slot, item, count, flags
		local code = r[2]
		by[code] = by[code] or {}
		by[code][r[3]] = slotOf(r[4], r[5], r[6])
	end
	return by
end

local FIELDS = {
	bags = function(by)
		local out = {}
		for code, rows in pairs(by) do
			local k, n = code:sub(1, 1), tonumber(code:sub(2))
			if k == "b" then out[n + 1] = slotsOf(rows) end
		end
		return out
	end,
	bankTabs = function(by)
		local out = {}
		for code, rows in pairs(by) do
			local n = tonumber(code:match("^k(%d+)$"))
			if n then out[n] = { slots = slotsOf(rows) } end
		end
		return out
	end,
	bank = function(by)
		local out = {}
		for code, rows in pairs(by) do
			local n = tonumber(code:match("^[ktw](%d+)$"))
			if n then out[n] = slotsOf(rows) end
		end
		return out
	end,
	mail = function(by) return by.m0 and slotsOf(by.m0) or {} end,
	auctions = function(by) return by.a0 and slotsOf(by.a0) or {} end,
	equipped = function(by) return by.e0 and slotsOf(by.e0) or {} end,
	void = function(by)
		local out = {}
		for code, rows in pairs(by) do
			local n = tonumber(code:match("^v(%d+)$"))
			if n then out[n] = slotsOf(rows) end
		end
		return out
	end,
}

local function newView(ent, kind, details)
	local built, by = {}, nil
	local view = {}
	local function field(name)
		if built[name] ~= nil then return built[name] end
		local v
		if name == "details" then v = details
		elseif name == "money" then
			local g = Call("money.gold", setOf(ent), { hidden = true })
			v = g.n > 0 and g[1][2] or 0
		elseif name == "currencies" then
			v = {}
			local rows = Call("wh.cur", setOf(ent), { hidden = true })
			for i = 1, rows.n do v[rows[i][2]] = { quantity = rows[i][3] } end
		elseif name == "containerInfo" then v = {}
		elseif FIELDS[name] and (kind == "c" or name == "bank") then
			by = by or containers(ent)
			v = FIELDS[name](by)
		elseif name == "bank" then v = {} end
		if v == nil then return nil end
		stats.builds = stats.builds + 1
		built[name] = v
		return v
	end
	return setmetatable(view, { __index = function(_, k) return field(k) end, __newindex = function() end, __metatable = false })
end

local function viewOf(ent, kind, details)
	local v = cache[ent]
	if not v then v = newView(ent, kind, details); cache[ent] = v end
	return v
end

------------------------------------------------------------------------
-- Entities by name
------------------------------------------------------------------------
local function entOf(full, kind)
	if type(full) ~= "string" then return nil end
	local name, realm = full:match("^(.*)-([^-]*)$")
	if not name then return nil end
	local id = M.PSS_EntityId(kind, name, realm, false)
	return id, name, realm
end

local function connected(sameRealm)
	if not sameRealm then return nil end
	return M.PSS_ConnectedRealms and M.PSS_ConnectedRealms() or nil
end

local function factionOpt(sameFaction)
	if not sameFaction then return nil end
	return UnitFactionGroup and (UnitFactionGroup("player")) or nil
end

local function names(kind)
	return Call("wh.ent", nil, { kind = kind, hidden = true })
end

local function ownGuild()
	if not (IsInGuild and IsInGuild()) then return nil end
	local name, _, _, realm = GetGuildInfo("player")
	return name and (name .. "-" .. (realm or GetRealmName())) or nil
end

local ready = false
M.Events.Register("WH_READY", function() ready = true end)

local function pending(id)
	local _, _, dirty = M.PSS_WatchRows()
	local d = dirty and dirty[id]
	return d ~= nil and next(d) ~= nil
end

------------------------------------------------------------------------
-- The manifest
------------------------------------------------------------------------
local function badLink() error("gw:Invalid item link", 0) end

local function keyOfLink(link)
	local key = type(link) == "string" and M.PSS_ItemKey(link)
	if not key then badLink() end
	return key
end

local function inv(key, sameRealm, sameFaction)
	local found = Call("wh.find", { cols = { "item" }, n = 1, { key } }, { realms = connected(sameRealm), faction = factionOpt(sameFaction) })
	return M.PSS_GwShapes["syn.inv"](found)
end

local EMPTY_INV = { characters = {}, guilds = {}, warband = { bank = 0 } }

local ROWS = {
	{ path = "API.GetInventoryInfo", aliases = { "API.GetInventoryInfoByItemLink" }, svc = "wh.find", sample = function() return "|cffffffff|Hitem:2589::::::::|h[x]|h|r" end, contract = "s,b?,b?", shape = "syn.inv", empty = EMPTY_INV, raise = "Invalid item link",
		run = function(link, a, b) return inv(keyOfLink(link), a, b) end },
	{ path = "API.GetInventoryInfoByItemID", svc = "wh.find", contract = "n,b?,b?", shape = "syn.inv", empty = EMPTY_INV, raise = "Invalid item id",
		run = function(id, a, b) return inv(tostring(floor(id)), a, b) end },
	{ path = "API.GetCurrencyInfo", svc = "wh.cur", contract = "n,b?,b?", shape = "syn.cur", empty = { characters = {}, warband = {} },
		run = function(id, a, b)
			local rows = Call("wh.cur", id, { realms = connected(a), faction = factionOpt(b) })
			return M.PSS_GwShapes["syn.cur"](rows)
		end },
	{ path = "API.RegisterShowItemLocation", svc = "-", contract = "f", shape = "none",
		run = function(fn) M.PSS_GwShow = fn end },
	{ path = "API.GetAllCharacters", svc = "wh.ent", contract = "-", shape = "syn.names", empty = {},
		run = function() return M.PSS_GwShapes["syn.names"](names("c")) end },
	{ path = "API.GetAllGuilds", svc = "wh.ent", contract = "-", shape = "syn.names", empty = {},
		run = function() return M.PSS_GwShapes["syn.names"](names("g")) end },
	{ path = "API.GetByCharacterFullName", aliases = { "API.GetCharacter" }, svc = "wh.cont", contract = "s", shape = "syn.view",
		run = function(full)
			local id, name, realm = entOf(full, "c")
			if not id then return nil end
			return viewOf(id, "c", { character = name, realmNormalized = realm, realm = realm })
		end },
	{ path = "API.GetByGuildFullName", aliases = { "API.GetGuild" }, svc = "wh.cont", contract = "s", shape = "syn.view",
		run = function(full)
			local id, name, realm = entOf(full, "g")
			if not id then return nil end
			return viewOf(id, "g", { guild = name, realmNormalized = realm, realm = realm })
		end },
	{ path = "API.GetWarband", svc = "wh.cont", contract = "n", shape = "syn.view",
		run = function(index)
			local id = M.PSS_EntityId("w", "Warband", "", false)
			if not id then return nil end
			return viewOf(id, "w", {})
		end },
	{ path = "API.GetCurrentCharacter", svc = "wh.ent", contract = "-", shape = "syn.name",
		run = function()
			local me = M.PSS_Me(false)
			return me and M.PSS_GwShapes["syn.name"](Call("wh.ent", setOf(me), { hidden = true })) or nil
		end },
	{ path = "API.GetCurrentGuild", svc = "wh.ent", contract = "-", shape = "syn.name", run = ownGuild },
	{ path = "API.DeleteCharacter", svc = "wh.delete", contract = "s", shape = "none", flags = "w",
		run = function(full)
			local id = entOf(full, "c")
			if id == M.PSS_Me(false) then error("gw:cannot delete the current character", 0) end
			if id then Call("wh.delete", setOf(id)) end
		end },
	{ path = "API.DeleteGuild", svc = "wh.delete", contract = "s", shape = "none", flags = "w",
		run = function(full)
			local id = entOf(full, "g")
			if id then Call("wh.delete", setOf(id)) end
		end },
	{ path = "API.ToggleCharacterHidden", svc = "wh.hide", contract = "s", shape = "none", flags = "w",
		run = function(full)
			local id = entOf(full, "c")
			if id then Call("wh.hide", setOf(id), { show = (M.PSS_EntityFlags(id) or ""):find("h", 1, true) ~= nil }) end
		end },
	{ path = "API.ToggleGuildHidden", svc = "wh.hide", contract = "s", shape = "none", flags = "w",
		run = function(full)
			local id = entOf(full, "g")
			if id then Call("wh.hide", setOf(id), { show = (M.PSS_EntityFlags(id) or ""):find("h", 1, true) ~= nil }) end
		end },
	{ path = "API.IsReady", svc = "-", contract = "-", shape = "bool", empty = false, run = function() return ready end },
	{ path = "API.IsBagEventPending", svc = "-", contract = "-", shape = "bool", empty = false, run = function() return pending("item.bags") end },
	{ path = "API.IsGuildEventPending", svc = "-", contract = "-", shape = "bool", empty = false, run = function() return pending("item.guild") end },
	{ path = "API.GetSearchKeywords", svc = "item.keywords", contract = "-", shape = "list", empty = {},
		run = function()
			local set, out = Call("item.keywords"), {}
			for i = 1, set.n do out[i] = set[i][3] end
			return out
		end },
	{ path = "API.GetContainerNumSlots", svc = "item.slots", contract = "n", shape = "num", empty = 0,
		run = function(bag)
			local set = Call("item.slots", bag)
			return set.n > 0 and set[1][2] or 0
		end },
	{ path = "Search.GetSearchBuilder", svc = "-", contract = "t?", shape = "frame", run = function() return nil end },
	{ path = "Search.GetSearchBuilderScrollable", svc = "-", contract = "t?", shape = "frame", run = function() return nil end },
	{ path = "Search.GetSearchEverywhereInterface", svc = "-", contract = "-", shape = "frame", run = function() return nil end },
	{ path = "Search.CheckItem", svc = "item.search", contract = "t,s", sample = function() return { itemID = 2589 }, "linen" end, shape = "bool", empty = false,
		run = function(details, text)
			local key = details.itemLink and M.PSS_ItemKey(details.itemLink) or (details.itemID and tostring(details.itemID))
			if not key then return false end
			local set = Call("item.search", { cols = { "item" }, n = 1, { key } }, { text = text })
			return set.n == 1
		end },
}
M.PSS_GwRows("syndicator", ROWS)

------------------------------------------------------------------------
-- Callbacks, from our events
------------------------------------------------------------------------
local hooks = M.PSS_GwHooks()
local function nameOf(ent)
	local set = M.PSS_Entity(ent)
	local r = set and set.n > 0 and set[1]
	return r and ((r[4] and r[4] ~= "") and (r[3] .. "-" .. r[4]) or r[3]) or nil
end

-- container families to the callback each one raises (the registry rows carry it)
local function callbackOf(code)
	local row = M.PSS_WhRow(code)
	return row and row.cb
end

local announced = {}
local function onChanged(set)
	local seen = {}
	for i = 1, set.n do
		local ent, code = set[i][1], set[i][2]
		local ev
		if code == "cur" then
			local s = M.PSS_Entity(ent)
			ev = (s and s[1] and s[1][2] == "w") and "WarbandCurrencyCacheUpdate" or "CurrencyCacheUpdate"
		else
			ev = callbackOf(code)
		end
		if ev then
			local key = ev .. ent
			if not seen[key] then
				seen[key] = true
				hooks:TriggerEvent(ev, nameOf(ent), set[i][3])
			end
		end
		if code:sub(1, 1) == "t" and not announced[ent] then
			announced[ent] = true
			hooks:TriggerEvent("GuildNameSet", nameOf(ent))
		end
	end
end

local started = false
local function listen()
	M.Events.Register("WH_CHANGED", onChanged)
	M.Events.Register("WH_READY", function() hooks:TriggerEvent("Ready") end)
	M.Events.Register("WH_DELETED", function(set)
		for i = 1, set.n do hooks:TriggerEvent(set[i][2] == "g" and "GuildDeleted" or "CharacterDeleted", set[i][1]) end
	end)
	M.Events.Register("MONEY_VALUE_SOURCE", function(source) hooks:TriggerEvent("AuctionValueSourceChanged", source) end)
end

------------------------------------------------------------------------
-- The one global, at login
------------------------------------------------------------------------
local function otherHas()
	local f = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if f and f("Syndicator") then return true end
	local state = C_AddOns and C_AddOns.GetAddOnEnableState
	if state then
		local ok, v = pcall(state, "Syndicator", UnitName and (UnitName("player")) or nil)
		if ok and type(v) == "number" and v > 0 then return true end
	end
	return false
end

function M.PSS_GwSyndicatorStart()
	if started then return end
	if otherHas() then return end
	if rawget(_G, "Syndicator") ~= nil then
		M.ShowMsg("Another addon already provides Syndicator, so the Warehouse does not.")
		return
	end
	started = true
	local root = { API = {}, Search = {}, Constants = {}, Utilities = {}, CallbackRegistry = hooks, Locales = setmetatable({}, { __index = function(_, k) return k end }),
		OptionsCategory = "PourSocialScore", PSS_SHIM = true }
	M.PSS_GwBuild("syndicator", root)
	local c = root.Constants
	local K = M.PSS_FLV.const
	c.IsForever = M.PSS_IsForever()
	c.IsRetail = M.PSS_FLV.flavour == "retail"
	c.BattlePetCageID, c.MaxGuildBankTabItemSlots, c.MaxBagSize = K.battlePetCage, K.guildBankSlots, K.maxBagSize
	c.AllBagIndexes, c.AllBankIndexes, c.AllWarbandIndexes = {}, {}, {}
	for i = 0, K.lastBagIndex do c.AllBagIndexes[#c.AllBagIndexes + 1] = i end
	c.KeywordGroupOrder = { "quality", "binding", "slot", "armor", "class", "consumable", "other", "expansion" }
	local U = root.Utilities
	function U.IsEquipment(link) local _, _, _, loc = (C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant)(link); return loc ~= nil and loc ~= "" end
	function U.GetConnectedRealms() local set = M.PSS_ConnectedRealms and M.PSS_ConnectedRealms() or {}; local out = {}; for r in pairs(set) do out[#out + 1] = r end; sort(out); return out end
	function U.GetCharacterIcon() return "Interface\\FriendsFrame\\Battlenet-Portrait" end
	function U.GetGuildIcon() return "Interface\\FriendsFrame\\Battlenet-Portrait" end
	function U.GetWarbandIcon() return "Interface\\FriendsFrame\\Battlenet-Portrait" end
	_G.Syndicator = root
	listen()
end

local prev = M.PSS_WhStartMore
function M.PSS_WhStartMore(warehouse)
	if prev then prev(warehouse) end
	if warehouse then M.PSS_GwSyndicatorStart() end
end
