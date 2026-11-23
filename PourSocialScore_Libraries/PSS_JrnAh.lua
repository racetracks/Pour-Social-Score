local addon = PourSocialScore_NS
local M = addon.M
-- The Journal's auction-house monitors (build J2C): one adapter per client chosen at load (Modern: C_AuctionHouse; Legacy:
-- the old owner list), posts from the owned list and the money drop, sales and fails from the mail (DEC-00455 a).
-- Rows jrn.ah and jrn.invoice. No auction hook is installed: the client's own events drive everything.
local type, tonumber, tostring, pairs, floor = type, tonumber, tostring, pairs, math.floor
local SEP = "\31"
local LEFT = { 1800, 7200, 43200, 172800 }

local function unm() M.PSS_JrnUnmatched = (M.PSS_JrnUnmatched or 0) + 1 end
local function readable(v) if M.PSS_IsSecret(v) then return false end return v ~= nil end
local function on() return M.PSS_On("journal") and M.PSS_Opt("jrnMonitorAH") ~= false end
local function unitOf(buyout, count)
	if type(buyout) == "number" and readable(buyout) and buyout > 0 and (count or 0) > 0 then return floor(buyout / count) end
end

local Modern = { name = "Modern", list = "OWNED_AUCTIONS_UPDATED", events = { "OWNED_AUCTIONS_UPDATED", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_CANCELED" } }
function Modern.owned()
	local out = {}
	for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
		local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
		if a and a.quantity ~= 0 and readable(a.quantity) and (a.status == nil or a.status == 0) then
			out[#out + 1] = { key = tostring(a.auctionID), item = a.itemKey and a.itemKey.itemID, link = a.itemLink, count = a.quantity, unit = unitOf(a.buyoutAmount, a.quantity), duration = a.timeLeftSeconds }
		end
	end
	return out
end
local Legacy = { name = "Legacy", list = "AUCTION_OWNED_LIST_UPDATE", events = { "AUCTION_OWNED_LIST_UPDATE" } }
function Legacy.owned()
	local out = {}
	for i = 1, GetNumAuctionItems("owner") do
		local _, _, n, _, _, _, _, _, _, buyout = GetAuctionItemInfo("owner", i)
		local link = GetAuctionItemLink("owner", i)
		if type(link) == "string" and readable(link) and n ~= 0 then
			out[#out + 1] = { key = link .. SEP .. n, item = tonumber(link:match("item:(%d+)")), link = link, count = n, unit = unitOf(buyout, n), duration = LEFT[GetAuctionItemTimeLeft("owner", i)] or 3600 }
		end
	end
	return out
end
local AH = M.PSS_Can("modernAH") and Modern or M.PSS_Can("legacyAH") and Legacy or nil
function M.PSS_JrnAhPick() return AH and AH.name end

local function told()
	if Auctionator and Auctionator.EventBus then pcall(Auctionator.EventBus.Fire, Auctionator.EventBus, M, "LogsUpdated") end
end
local function done() return { cols = { "n" }, n = 0 } end
local function put(st, rec) M.PSS_IxPut("jrn", st, rec) end

-- posts: a multiset of keys at the open, the new keys of each adapter event wait for the money to drop
local open, base, drop = false, 0, 0
local snap, pend, cur = nil, {}, {}
local function counts(list)
	local c = {}
	for i = 1, #list do c[list[i].key] = (c[list[i].key] or 0) + 1 end
	return c
end
local function settle()
	if #pend == 0 then return end
	local d = drop > 0 and drop or base - GetMoney()
	if d <= 0 then return end
	local each, extra = floor(d / #pend), d % #pend
	for i = 1, #pend do
		local p = pend[i]
		put("jrn.post", { item = p.item, count = p.count, unit = p.unit, deposit = each + (i == 1 and extra or 0), duration = p.duration and floor(p.duration / 3600 + 0.5) or nil })
	end
	snap, pend, drop, base = counts(cur), {}, 0, GetMoney()
	told()
end
local function adapterEvent(e)
	if snap == nil then
		if e == AH.list then cur = AH.owned(); snap, pend, drop, base = counts(cur), {}, 0, GetMoney() end
		return
	end
	cur = AH.owned()
	local seen, new = {}, {}
	for i = 1, #cur do
		local k = cur[i].key
		seen[k] = (seen[k] or 0) + 1
		if seen[k] > (snap[k] or 0) then new[#new + 1] = cur[i] end
	end
	if #new == 0 then snap, pend = counts(cur), {} return end
	pend = new
	settle()
end
local isAdapter = {}
if AH then for _, e in ipairs(AH.events) do isAdapter[e] = true end end
local SHOW, HIDE = "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE"
M.PSS_Provide("jrn.ah", function(set)
	if not AH or not on() then return done() end
	local auc = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer
	for i = 1, set.n do
		local e, arg = set[i][1]:match("^([^" .. SEP .. "]*)" .. SEP .. "?(.*)$")
		if e == SHOW then
			if auc and tostring(auc) == arg then open, pend, drop, base = true, {}, 0, GetMoney(); snap = nil end
		elseif e == HIDE then
			if auc and tostring(auc) == arg then open, pend, snap = false, {}, nil end
		elseif not open then
			-- nothing to match outside the auction house
		elseif e == "PLAYER_MONEY" then
			if #pend == 0 then
				local d = base - GetMoney()
				if d > 0 then drop = d end
				base = GetMoney()
			else
				settle()
			end
		elseif isAdapter[e] then
			adapterEvent(e)
		end
	end
	return done()
end)

-- invoices and fails: each mail once (sender, subject and time left), the fail kinds from the client's own subject formats
local seen = {}
local function pattern(fmt)
	if type(fmt) ~= "string" then return nil end
	return "^" .. fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0"):gsub("%%%%s", "(.+)") .. "$"
end
local expired, removed
M.PSS_Provide("jrn.invoice", function()
	if not on() then return done() end
	expired = expired or pattern(AUCTION_EXPIRED_MAIL_SUBJECT)
	removed = removed or pattern(AUCTION_REMOVED_MAIL_SUBJECT)
	local wrote = false
	for i = 1, (GetInboxNumItems and (GetInboxNumItems())) or 0 do
		local _, _, sender, subject, _, _, days = GetInboxHeaderInfo(i)
		if readable(sender) and readable(subject) then
			local key = tostring(sender) .. SEP .. tostring(subject) .. SEP .. tostring(days)
			if not seen[key] then
				seen[key] = true
				local kind, name, who, bid, buyout, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(i)
				local item = kind and C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(name)
				if kind == "seller" or kind == "buyer" then
					local price = (bid or 0) > 0 and bid or buyout or 0
					if item and readable(who) and readable(price) then
						if kind == "seller" then
							put("jrn.sold", { item = item, count = count or 1, value = price - (consignment or 0), deposit = deposit, consignment = consignment, buyer = who })
						else
							put("jrn.bought", { item = item, count = count or 1, value = price, seller = who })
						end
						wrote = true
					else
						unm()
					end
				else
					local fk = expired and subject:match(expired) and "expired" or removed and subject:match(removed) and "cancelled" or nil
					if fk then
						local _, id, _, n = GetInboxItem(i, 1)
						if readable(id) and tonumber(id) then put("jrn.fail", { item = id, count = n or 1, kind = fk }); wrote = true else unm() end
					end
				end
			end
		end
	end
	if wrote then told() end
	return done()
end)

local started
local prevStart = M.PSS_WhStartMore
function M.PSS_WhStartMore(warehouse)
	if prevStart then prevStart(warehouse) end
	if not warehouse or started or not M.PSS_On("journal") or not M.PSS_Trigger then return end
	started = true
	local valid = C_EventUtils and C_EventUtils.IsEventValid
	local function row(id, evs, key)
		local ok = {}
		for _, e in ipairs(evs) do if not valid or valid(e) then ok[#ok + 1] = e end end
		M.PSS_Trigger({ id = id, gate = "journal", on = ok, settle = "now", run = id, key = key })
	end
	if AH then
		local evs = { SHOW, HIDE, "PLAYER_MONEY" }
		for _, e in ipairs(AH.events) do evs[#evs + 1] = e end
		row("jrn.ah", evs, function(e, t) if e == SHOW or e == HIDE then return e .. SEP .. tostring(t) end return e end)
	end
	if M.PSS_Can("mailInvoice") then row("jrn.invoice", { "MAIL_INBOX_UPDATE" }) end
end
