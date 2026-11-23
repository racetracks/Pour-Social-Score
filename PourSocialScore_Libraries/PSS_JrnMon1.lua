local addon = PourSocialScore_NS
local M = addon.M
-- The Journal's vendor and repair monitors (build J2A): sells matched by slot and money, buys, buybacks, refunds, repairs.
-- Rows jrn.vend and jrn.repair settle on the client's own events; post-hooks (DEC-00411) only note what the player asked for.
local type, tonumber, tostring, pairs, floor = type, tonumber, tostring, pairs, math.floor
local SEP = "\31"

local function unm() M.PSS_JrnUnmatched = (M.PSS_JrnUnmatched or 0) + 1 end
local function readable(v) if M.PSS_IsSecret(v) then return false end return v ~= nil end
local function live() return M.PSS_On("journal") and M.PSS_Opt("jrnMonitorVendor") ~= false end
local function itemOf(link) if type(link) == "string" and readable(link) then return tonumber(link:match("item:(%d+)")) end end

local open, base = false, 0
local snap, now, pend = {}, {}, {}

local function bagRead(into)
	for k in pairs(into) do into[k] = nil end
	local cc = M.PSS_Can("cContainer")
	for bag = 0, (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0) do
		local n = (cc and C_Container.GetContainerNumSlots or GetContainerNumSlots)(bag) or 0
		for slot = 1, n do
			local link, count
			if cc then
				local i = C_Container.GetContainerItemInfo(bag, slot)
				if i then link, count = i.hyperlink, i.stackCount end
			else
				local _, c, _, _, _, _, l = GetContainerItemInfo(bag, slot)
				link, count = l, c
			end
			if type(link) == "string" and readable(link) then into[bag .. ":" .. slot] = link .. SEP .. (count or 1) end
		end
	end
end

local function sellPrice(link)
	local info = C_Item and C_Item.GetItemInfo or GetItemInfo
	return info and select(11, info(link))
end

local function put(rec, st) M.PSS_IxPut("jrn", st or "jrn.vend", rec) end

-- one settle: every pending act is matched at most once, against the money that moved since the last claim
local function settle()
	if not open then return end
	bagRead(now)
	local gained = GetMoney() - base
	local rest = {}
	for i = 1, #pend do
		local p, done = pend[i], false
		if p.k == "sell" then
			local total = p.price * p.count
			if now[p.key] ~= p.sig and gained >= total then
				put({ item = p.item, count = p.count, unit = p.price, kind = "sell" })
				gained = gained - total; done = true
			end
		elseif p.k == "buy" or p.k == "buyback" then
			local total = p.unit * p.count
			if -gained >= total then
				put({ item = p.item, count = p.count, unit = p.unit, kind = p.k })
				gained = gained + total; done = true
			end
		elseif p.k == "repair" then
			if p.guild or -gained >= p.cost then
				put({ copper = p.cost, guild = p.guild and 1 or nil }, "jrn.repair")
				if not p.guild then gained = gained + p.cost end
				done = true
			end
		else
			put({ item = p.item, kind = "refund", currencies = p.cur, items = p.items })
			done = true
		end
		if not done then rest[#rest + 1] = p end
	end
	pend = rest
	base = GetMoney() - gained
	for k in pairs(snap) do snap[k] = nil end
	for k, v in pairs(now) do snap[k] = v end
end

M.PSS_Provide("jrn.vend", function(set)
	if not live() then return { cols = { "n" }, n = 0 } end
	for i = 1, set.n do
		local e = set[i][1]
		if e == "MERCHANT_SHOW" then
			open, pend, base = true, {}, GetMoney()
			bagRead(snap)
		elseif e == "MERCHANT_CLOSED" then
			settle()
			for _ = 1, #pend do unm() end
			if #pend == 0 and GetMoney() ~= base then unm() end
			open, pend = false, {}
		else
			settle()
		end
	end
	return { cols = { "n" }, n = 0 }
end)
M.PSS_Provide("jrn.repair", function()
	if live() then settle() end
	return { cols = { "n" }, n = 0 }
end)

local function noted() return open and live() end
local function onUse(bag, slot)
	if not noted() then return end
	local key = bag .. ":" .. slot
	local sig = snap[key]
	if not sig then return end
	for i = 1, #pend do if pend[i].key == key then return end end
	local link = sig:match("^(.-)" .. SEP)
	local price = sellPrice(link)
	if type(price) ~= "number" then unm() return end
	pend[#pend + 1] = { k = "sell", key = key, sig = sig, item = itemOf(link), count = tonumber(sig:match(SEP .. "(%d+)$")) or 1, price = price }
end
local function onBuy(index, qty)
	if not noted() then return end
	local _, _, price, q
	if GetMerchantItemInfo then _, _, price, q = GetMerchantItemInfo(index) end
	local item = itemOf(GetMerchantItemLink and GetMerchantItemLink(index))
	if not item or type(price) ~= "number" then unm() return end
	pend[#pend + 1] = { k = "buy", item = item, count = qty or 1, unit = floor(price / ((q or 1) > 0 and q or 1)) }
end
local function onBuyback(index)
	if not noted() then return end
	local _, _, price, q = GetBuybackItemInfo(index)
	local item = itemOf(GetBuybackItemLink(index))
	if not item or type(price) ~= "number" or not q or q < 1 then unm() return end
	pend[#pend + 1] = { k = "buyback", item = item, count = q, unit = floor(price / q) }
end
local function onRefund(bag, slot)
	if not noted() then return end
	local api = M.PSS_Can("cContainer") and C_Container or nil
	local get = api and api.GetContainerItemPurchaseInfo or GetContainerItemPurchaseInfo
	if not get then unm() return end
	local _, nItems, _, nCur = get(bag, slot, false)
	local it, cu = {}, {}
	for i = 1, nItems or 0 do
		local _, c, l = (api and api.GetContainerItemPurchaseItem or GetContainerItemPurchaseItem)(bag, slot, i, false)
		local id = itemOf(l)
		if id then it[#it + 1] = id .. ":" .. (c or 1) end
	end
	for i = 1, nCur or 0 do
		local _, c, l = (api and api.GetContainerItemPurchaseCurrency or GetContainerItemPurchaseCurrency)(bag, slot, i, false)
		local id = type(l) == "string" and readable(l) and tonumber(l:match("currency:(%d+)"))
		if id then cu[#cu + 1] = id .. ":" .. (c or 1) end
	end
	local sig = snap[bag .. ":" .. slot]
	pend[#pend + 1] = { k = "refund", item = sig and itemOf(sig:match("^(.-)" .. SEP)) or nil, items = #it > 0 and table.concat(it, ";") or nil, cur = #cu > 0 and table.concat(cu, ";") or nil }
end
local function onRepair(useGuild)
	if not noted() then return end
	local cost = GetRepairAllCost and GetRepairAllCost()
	if type(cost) ~= "number" or cost <= 0 or M.PSS_IsSecret(cost) then unm() return end
	pend[#pend + 1] = { k = "repair", cost = cost, guild = useGuild == true or nil }
end

local hooked = {}
local function hook(tbl, name, fn)
	if hooked[fn] then return end
	if tbl then
		if type(tbl[name]) == "function" then hooked[fn] = true; hooksecurefunc(tbl, name, fn) end
	elseif type(_G[name]) == "function" then
		hooked[fn] = true; hooksecurefunc(name, fn)
	end
end

local started
local prevStart = M.PSS_WhStartMore
function M.PSS_WhStartMore(warehouse)
	if prevStart then prevStart(warehouse) end
	if not warehouse or not M.PSS_On("journal") or not M.PSS_Trigger then return end
	local cc = M.PSS_Can("cContainer") and C_Container or nil
	hook(cc, "UseContainerItem", onUse)
	hook(cc, "ContainerRefundItemPurchase", onRefund)
	hook(nil, "BuyMerchantItem", onBuy)
	hook(nil, "BuybackItem", onBuyback)
	hook(nil, "RepairAllItems", onRepair)
	if started then return end
	started = true
	M.PSS_Trigger({ id = "jrn.vend", gate = "journal", on = { "MERCHANT_SHOW", "MERCHANT_CLOSED", "BAG_UPDATE_DELAYED", "PLAYER_MONEY" }, settle = "now", run = "jrn.vend" })
	M.PSS_Trigger({ id = "jrn.repair", gate = "journal", on = { "PLAYER_MONEY" }, settle = "now", run = "jrn.repair" })
end
