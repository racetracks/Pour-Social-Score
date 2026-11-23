------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PSS DROP CHEAPEST THING: the scan (money-helper,
-- DDS-00009 section 3). One pass over the bags keeps the cheapest
-- candidate (no sort; the sorted list is built only on request). Loaded only
-- while the feature is on. Logic only: no frames, no events here except the
-- one DTT_CHANGED on M.Events.
--
-- The idea (items below the quality threshold, valued by vendor price, the
-- cheapest first) is Kemayo's DropTheCheapestThing (BSD); this code is new.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
if not M.PSS_On("dtt") then return end

local C_Container, C_Item = C_Container, C_Item
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring
local sort, wipe = table.sort, wipe or function(t) for k in pairs(t) do t[k] = nil end end

local LAST_BAG = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)
local CACHE_MAX = 256
local LOW_LEVELS = 10		-- "low level": required level this far below yours
local QUEST_CLASS, CONSUMABLE = 12, 0
-- consumable subclass -> the option that includes it
local LOW_OPT = { [5] = "dttFood", [1] = "dttPotion", [7] = "dttBandage", [4] = "dttScroll" }

-- the scan's three reused arrays and the slot list (wiped per scan)
local slotOf, link, count, price, icon = {}, {}, {}, {}, {}
local weight = {}			-- the comparison value (price x count, or x full stack)
local n, best, total = 0, nil, 0
local never, always, listsRaw = {}, {}, {}
local questCache, appearCache, ncache = {}, {}, 0
local missing = false		-- an item had no info yet
local lastKey

M.PSS_DttMissing = function() return missing end

local bagSet = { cols = { "bag" }, n = 1, { 0 } }		-- the one-row key set and the reused out of the bag read
local bagOut = {}
local bagOpts = { out = bagOut }
local readBag
local function ReadBag(bag)
	bagSet[1][1] = bag
	M.PSS_Call("compat.containers.read", bagSet, bagOpts)
	readBag = bag
end
local function Info(bag, slot)
	if readBag ~= bag then ReadBag(bag) end
	return bagOut[slot] or nil
end
local function ItemInfo(l)
	local f = C_Item and C_Item.GetItemInfo or GetItemInfo
	return f(l)
end

-- the never and always sets, re-read only when the saved strings change
local function Lists()
	local a, b = M.PSS_Opt("dttAlways"), M.PSS_Opt("dttNever")
	if listsRaw[1] ~= a or listsRaw[2] ~= b then
		listsRaw[1], listsRaw[2] = a, b
		always = M.PSS_DttParse(a)
		never = M.PSS_DttParse(b)
	end
end

local function Cache(t, key, value)
	if ncache >= CACHE_MAX then wipe(questCache); wipe(appearCache); ncache = 0 end
	t[key] = value
	ncache = ncache + 1
	return value
end
function M.PSS_DttClearCaches() wipe(questCache); wipe(appearCache); ncache = 0 end

-- Is this stack a candidate, and what is one worth? mode "drop" or "sell".
-- Returns price (vendor, per item) or nil. The cheap checks come first;
-- GetItemInfo is called only for an item that passed them.
local function Evaluate(info, mode)
	local id = info.itemID
	if not id or never[id] then return nil end
	local limit = tonumber(M.PSS_Opt(mode == "sell" and "dttSellQuality" or "dttQuality")) or 0
	local inAlways = mode == "drop" and always[id]
	local q = info.quality or 0
	-- a ticked low-level kind lets higher qualities through to the info check
	local lowOn = mode == "drop" and (M.PSS_Opt("dttFood") or M.PSS_Opt("dttPotion") or M.PSS_Opt("dttBandage") or M.PSS_Opt("dttScroll"))
	if not inAlways and q > limit and not lowOn then return nil end
	if not info.hyperlink then return nil end
	local name, _, _, _, minLevel, _, _, stack, equipLoc, _, sell, classID, subID, bindType = ItemInfo(info.hyperlink)
	if not name then missing = true; return nil end
	if classID == QUEST_CLASS or bindType == 4 then return nil end
	if not inAlways and q > limit then
		-- only a low-level consumable of a ticked kind is above the limit
		local opt = classID == CONSUMABLE and LOW_OPT[subID]
		local lvl = UnitLevel and UnitLevel("player") or 0
		if not (opt and M.PSS_Opt(opt) and (minLevel or 0) + LOW_LEVELS <= lvl) then return nil end
	end
	sell = sell or 0
	if mode == "sell" then
		if sell <= 0 or info.hasNoValue then return nil end
	elseif not inAlways then
		if (info.hasNoValue or sell <= 0) and not M.PSS_Opt("dttValueless") then return nil end
		if info.isBound and not M.PSS_Opt("dttSoulbound") then return nil end
		if equipLoc and equipLoc ~= "" and not M.PSS_Opt("dttAppearance") and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogByItemInfo then
			local has = appearCache[id]
			if has == nil then has = Cache(appearCache, id, C_TransmogCollection.PlayerHasTransmogByItemInfo(info.hyperlink) and true or false) end
			if not has then return nil end
		end
	end
	return sell, stack or 1
end

local function Less(a, b)
	if weight[a] ~= weight[b] then return weight[a] < weight[b] end
	if price[a] ~= price[b] then return price[a] < price[b] end
	return count[a] < count[b]
end

-- merchant window open (read only)
function M.PSS_DttAtMerchant()
	return MerchantFrame ~= nil and MerchantFrame.IsShown ~= nil and MerchantFrame:IsShown() == true
end

-- One pass. mode: "drop" or "sell" (default: sell at a merchant, else drop).
-- Returns n, the cheapest bagslot (bag * 100 + slot) or nil, and the total
-- vendor value of all candidates. Fires DTT_CHANGED(n, total, icon) only
-- when the result changed.
-- the occupied bag slots from the shared reader, [bag] = { slot, ... }, or nil to scan every slot
-- (Bag manager or Warehouse on; any failure of the service falls back to the full scan)
local function LiveSlots()
	if not (M.PSS_On and M.PSS_On("items") and M.PSS_Call) then return nil end
	local set, err = M.PSS_Call("item.live", { cols = { "key" }, n = 1, { "b*" } })
	if err or not set or not set.conts then return nil end
	local out = {}
	for i = 1, set.n do
		local r = set[i]
		local bag = tonumber(tostring(r[2]):match("^b(%d+)$"))
		if bag then
			local t = out[bag]
			if not t then t = {}; out[bag] = t end
			t[#t + 1] = r[3]
		end
	end
	return out
end

function M.PSS_DttScan(mode)
	mode = mode or (M.PSS_DttAtMerchant() and "sell" or "drop")
	Lists()
	wipe(slotOf); wipe(link); wipe(count); wipe(price); wipe(icon); wipe(weight)
	n, best, total, missing = 0, nil, 0, false
	local full = M.PSS_Opt("dttFullStacks")
	local live = LiveSlots()
	for bag = 0, LAST_BAG do
		local only = live and (live[bag] or {})
		ReadBag(bag)
		bagSet[1][1] = bag
		local r = M.PSS_Call("compat.containers.size", bagSet)
		for k = 1, only and #only or (r and r[1] and r[1][1] or 0) do
			local slot = only and only[k] or k
			local info = Info(bag, slot)
			if info then
				local p, stack = Evaluate(info, mode)
				if p then
					n = n + 1
					local c = info.stackCount or 1
					slotOf[n], link[n], count[n], price[n], icon[n] = bag * 100 + slot, info.hyperlink, c, p, info.iconFileID
					weight[n] = p * (full and stack or c)
					total = total + p * c
					if not best or Less(n, best) then best = n end
				end
			end
		end
	end
	local key = n .. ":" .. total .. ":" .. tostring(best and slotOf[best]) .. ":" .. tostring(best and link[best])
	if key ~= lastKey then
		lastKey = key
		M.Events.Fire("DTT_CHANGED", n, total, best and icon[best] or nil)
	end
	return n, best and slotOf[best] or nil, total
end

-- bagslots, cheapest first (sorted on request only)
function M.PSS_DttList(max)
	local idx = {}
	for i = 1, n do idx[i] = i end
	sort(idx, Less)
	local out = {}
	for i = 1, math.min(max or 10, n) do out[i] = slotOf[idx[i]] end
	return out
end

-- link, count, value (price x count), icon, source of a scanned bagslot
function M.PSS_DttSlot(bagslot)
	for i = 1, n do
		if slotOf[i] == bagslot then
			local v, src = M.PSS_DttValue(link[i])
			return link[i], count[i], (v or price[i]) * count[i], icon[i], src
		end
	end
end

-- the vendor price of an item and its source; with auction values on, an
-- auction price from a price addon beside it (shown only, never saved or
-- compared: DEC-00111). Documented APIs of those addons only.
function M.PSS_DttValue(l, vendorOnly)
	local _, _, q, _, _, _, _, _, _, _, sell = ItemInfo(l)
	local vendor = sell or 0
	if vendorOnly or not M.PSS_Opt("dttAuction") or (q or 0) < (tonumber(M.PSS_Opt("dttAuctionQuality")) or 1) then
		return vendor, "vendor"
	end
	if M.PSS_Call and M.PSS_On("items") and (M.PSS_Opt("whValueSource") or "") ~= "" then
		-- the shared value service; its failure leaves the addon calls below
		local set, err = M.PSS_Call("money.value", { cols = { "item" }, n = 1, { l } })
		if not err and set and set.n == 1 and type(set[1][3]) == "number" then return set[1][3], set[1][4] end
	end
	local ok, a
	if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemLink then
		ok, a = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, "PourSocialScore", l)
		if ok and type(a) == "number" and a > 0 then return a, "Auctionator" end
	end
	if TSM_API and TSM_API.GetCustomPriceValue then
		local id = tonumber(tostring(l):match("item:(%d+)"))
		ok, a = pcall(TSM_API.GetCustomPriceValue, "DBMarket", "i:" .. tostring(id))
		if ok and type(a) == "number" and a > 0 then return a, "TSM" end
	end
	return vendor, "vendor"
end

-- one slot, for another addon's junk marking (the Baganator plugin)
function M.PSS_DttIsJunk(bag, slot, mode)
	Lists()
	readBag = nil		-- always a fresh read of the bag
	local info = Info(bag, slot)
	return info ~= nil and Evaluate(info, mode or "drop") ~= nil
end
