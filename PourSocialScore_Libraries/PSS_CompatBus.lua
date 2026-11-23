local addon = PourSocialScore_NS
local M = addon.M

-- Compat bus services (multi-version suite, design.md#containers and
-- #guild-bank): compat.containers.<verb> and compat.guildBank.<verb>. The
-- path of each verb is chosen once, at load, from M.PSS_FLV.caps. A verb takes
-- its key (bag or tab) as the input and its other arguments in opts (slot,
-- out); it answers a record set. read fills opts.out (a set) and allocates
-- nothing when it is given. This file is the engine-rework re-cut point.

local type = type
local tonumber = tonumber
local select = select

local caps = M.PSS_FLV.caps
local function on(cap)
	return caps[cap] ~= nil and caps[cap] ~= "off"
end

local function key(set)
	return set and set[1] and set[1][1]
end

-- one reused answer set per verb
local function one(cols)
	return { cols = cols, n = 1, { false } }
end
local EMPTY = { cols = { "n" }, n = 0 }

local function declare(name, returns, doc, fn)
	M.PSS_ProvideStub(name, { returns = returns, doc = doc, cost = "O(1)", onError = "empty", writes = false, default = EMPTY }, function() return fn end)
end

-- a reusable out set
local function outSet(opts, cols)
	local out = opts and opts.out
	if type(out) ~= "table" then out = {} end
	out.cols = cols
	return out
end

local function wipeAbove(out, n)
	for i = n + 1, #out do out[i] = nil end
	out.n = n
end

------------------------------------------------------------------------
-- compat.containers
------------------------------------------------------------------------
local CT = on("cContainer") and C_Container or nil
local function sizeFn(...)
	local f = CT and CT.GetContainerNumSlots or GetContainerNumSlots
	if f then return f(...) end
end
local function infoFn(...)
	local f = CT and CT.GetContainerItemInfo or GetContainerItemInfo
	if f then return f(...) end
end
local function invFn(...)
	local f = CT and CT.ContainerIDToInventoryID or ContainerIDToInventoryID
	if f then return f(...) end
end
local function useFn(...)
	local f = CT and CT.UseContainerItem or UseContainerItem
	if f then return f(...) end
end
local function pickFn(...)
	local f = CT and CT.PickupContainerItem or PickupContainerItem
	if f then return f(...) end
end

local sizeRes, invRes = one({ "n" }), one({ "inv" })
local ITEMCOLS = { "slot" }

declare("compat.containers.size", { "n" }, "slots in a bag (0 for an unknown bag)", function(set)
	local bag = key(set)
	sizeRes[1][1] = (bag ~= nil and sizeFn and tonumber(sizeFn(bag))) or 0
	return sizeRes
end)

local readSlot
if CT then
	readSlot = function(out, slot, bag)
		return infoFn(bag, slot) or false
	end
else
	-- legacy: the global returns icon, count, locked, quality, -, -, link, -, noValue, itemID, bound
	readSlot = function(out, slot, bag)
		if not infoFn then return false end
		local icon, count, locked, quality, _, _, link, _, noValue, id, bound = infoFn(bag, slot)
		if icon == nil and link == nil then return false end
		local pool = out.pool
		if not pool then pool = {}; out.pool = pool end
		local t = pool[slot]
		if not t then t = {}; pool[slot] = t end
		t.iconFileID, t.stackCount, t.isLocked, t.quality = icon, count, locked, quality
		t.hyperlink, t.hasNoValue, t.itemID, t.isBound = link, noValue, id, bound
		return t
	end
end

declare("compat.containers.read", { "slot" }, "one bag's slots into opts.out: out[slot] = info or false", function(set, opts)
	local bag = key(set)
	local out = outSet(opts, ITEMCOLS)
	local n = (bag ~= nil and sizeFn and tonumber(sizeFn(bag))) or 0
	for slot = 1, n do out[slot] = readSlot(out, slot, bag) end
	wipeAbove(out, n)
	return out
end)

declare("compat.containers.invId", { "inv" }, "the inventory slot of a bag", function(set)
	local bag = key(set)
	invRes[1][1] = bag ~= nil and invFn and invFn(bag) or nil
	return invRes
end)

declare("compat.containers.use", { "n" }, "use a slot's item (opts.slot)", function(set, opts)
	local bag = key(set)
	if bag ~= nil and opts and opts.slot and useFn then useFn(bag, opts.slot) end
	return nil
end)

declare("compat.containers.pickup", { "n" }, "pick up a slot's item (opts.slot)", function(set, opts)
	local bag = key(set)
	if bag ~= nil and opts and opts.slot and pickFn then pickFn(bag, opts.slot) end
	return nil
end)

------------------------------------------------------------------------
-- compat.guildBank
------------------------------------------------------------------------
local GB = on("guildBank")
local tabsRes, tabRes, moneyRes = one({ "n" }), one({ "name", "icon", "viewable" }), one({ "copper" })
tabRes[1][2], tabRes[1][3] = false, false
local GCOLS = { "slot" }

declare("compat.guildBank.tabs", { "n" }, "number of guild bank tabs (0 when off)", function()
	tabsRes[1][1] = (GB and GetNumGuildBankTabs and tonumber(GetNumGuildBankTabs())) or 0
	return tabsRes
end)

declare("compat.guildBank.tab", { "name", "icon", "viewable" }, "name, icon and viewable flag of a tab", function(set)
	local tab, row = key(set), tabRes[1]
	if GB and tab ~= nil and GetGuildBankTabInfo then
		local name, icon, viewable = GetGuildBankTabInfo(tab)
		row[1], row[2], row[3] = name, icon, viewable
	else
		row[1], row[2], row[3] = nil, nil, nil
	end
	return tabRes
end)

declare("compat.guildBank.read", { "slot" }, "a tab's slots into opts.out: out[slot] = { link, count } or false; false when the tab is not viewable", function(set, opts)
	local tab = key(set)
	local out = outSet(opts, GCOLS)
	if not (GB and tab ~= nil and GetGuildBankItemLink) then wipeAbove(out, 0); return out end
	if select(3, GetGuildBankTabInfo(tab)) == false then return false end
	local slots = M.PSS_FLV.const.guildBankSlots
	local isSecret = M.PSS_IsSecret
	local pool = out.pool
	if not pool then pool = {}; out.pool = pool end
	for slot = 1, slots do
		local link = GetGuildBankItemLink(tab, slot)
		if link and not isSecret(link) then
			local t = pool[slot]
			if not t then t = {}; pool[slot] = t end
			t.link = link
			t.count = select(2, GetGuildBankItemInfo(tab, slot))
			out[slot] = t
		else
			out[slot] = false
		end
	end
	wipeAbove(out, slots)
	return out
end)

declare("compat.guildBank.money", { "copper" }, "guild bank gold (nil when off or no tabs)", function()
	local row = moneyRes[1]
	row[1] = (GB and GetGuildBankMoney and (tonumber(GetNumGuildBankTabs and GetNumGuildBankTabs() or 0) or 0) > 0) and GetGuildBankMoney() or nil
	return moneyRes
end)
