------------------------------------------------------------------------
-- POUR SOCIAL SCORE - ITEM VALUE (money-helper, one-build plan STP-p11,
-- Syndicator parity 23). The vendor price of an item, and an auction value
-- from a price addon through its documented API, read only:
--   TradeSkillMaster (TSM_API.GetCustomPriceValue: DBMarket, DBMinBuyout,
--   DBHistorical, DBRegionMarketAvg), RECrystallize (RECrystallize_PriceCheck),
--   Auctionator (Auctionator.API.v1). Nothing is saved or cached here.
--   money.value   item, count?  -> item, vendor, auction, source   opts { source, tsm }
-- An item is a key, an id or a link. `source` is the option whValueSource:
-- "" vendor only, "auto" the first addon that answers, or one addon's name.
-- M.Events MONEY_VALUE_SOURCE (source) fires once when whValueSource changes.
-- Loaded with Libraries; it holds no timers or frames.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not (M.PSS_On("items") or M.PSS_On("warehouse")) then return end

local type, tonumber, tostring, pcall, ipairs = type, tonumber, tostring, pcall, ipairs

local TSM = { DBMarket = true, DBMinBuyout = true, DBHistorical = true, DBRegionMarketAvg = true }

local function idOf(v)
	if type(v) == "number" then return v end
	if type(v) ~= "string" then return nil end
	return tonumber(v:match("item:(%d+)") or v:match("^(%d+)"))
end

local function vendorOf(v)
	local id = idOf(v)
	if not id then return 0 end
	local f = C_Item and C_Item.GetItemInfo or GetItemInfo
	local r = f and { f(id) }
	local sell = r and r[11]
	return type(sell) == "number" and sell or 0
end

local function num(ok, v) if ok and type(v) == "number" and v > 0 then return v end end

local ASK = {
	tsm = function(id, opts)
		if not (TSM_API and TSM_API.GetCustomPriceValue) then return end
		local src = opts and opts.tsm
		if not TSM[src] then src = "DBMarket" end
		return num(pcall(TSM_API.GetCustomPriceValue, src, "i:" .. id))
	end,
	recrystallize = function(id)
		if type(RECrystallize_PriceCheck) ~= "function" then return end
		return num(pcall(RECrystallize_PriceCheck, id))
	end,
	auctionator = function(id)
		local api = Auctionator and Auctionator.API and Auctionator.API.v1
		if not (api and api.GetAuctionPriceByItemID) then return end
		return num(pcall(api.GetAuctionPriceByItemID, "PourSocialScore", id))
	end,
}
local ORDER = { "tsm", "recrystallize", "auctionator" }

local function auctionOf(v, source, opts)
	if source == nil or source == "" then return nil, "" end
	local id = idOf(v)
	if not id then return nil, "" end
	if source == "auto" then
		for _, name in ipairs(ORDER) do
			local p = ASK[name](id, opts)
			if p then return p, name end
		end
		return nil, ""
	end
	local f = ASK[source]
	local p = f and f(id, opts)
	return p, p and source or ""
end

-- the price addons that answer on this client now (for the Options page)
function M.PSS_MoneySources()
	local out = {}
	if TSM_API and TSM_API.GetCustomPriceValue then out[#out + 1] = "tsm" end
	if type(RECrystallize_PriceCheck) == "function" then out[#out + 1] = "recrystallize" end
	if Auctionator and Auctionator.API and Auctionator.API.v1 then out[#out + 1] = "auctionator" end
	return out
end

M.PSS_Provide("money.value", function(input, opts)
	local out = { cols = { "item", "vendor", "auction", "source" }, n = 0 }
	local source = opts and opts.source
	if source == nil then source = M.PSS_Opt("whValueSource") end
	local c = M.PSS_SetCol(input, "item") or M.PSS_SetCol(input, "key") or 1
	local cc = M.PSS_SetCol(input, "count")
	for i = 1, input.n do
		local item = input[i][c]
		local n = cc and tonumber(input[i][cc]) or 1
		local a, from = auctionOf(item, source, opts)
		out.n = out.n + 1
		out[out.n] = { item, vendorOf(item) * n, a and a * n or false, from }
	end
	return out
end, { accepts = { "item" }, returns = { "item", "vendor", "auction", "source" }, doc = "vendor price and an auction value from a price addon", cost = "O(rows)",
	writes = false, onError = "empty" })

local last = M.PSS_Opt("whValueSource")
M.Events.Register("OPTION_CHANGED", function(key)
	if key ~= "whValueSource" then return end
	local now = M.PSS_Opt("whValueSource")
	if now == last then return end
	last = now
	M.Events.Fire("MONEY_VALUE_SOURCE", now)
end)
