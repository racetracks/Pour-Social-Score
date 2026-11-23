local addon = PourSocialScore_NS
local M = addon.M
-- The Journal's basic monitors (build J2B): mail, trade, taxi, training, quest, loot. Rows jrn.mail, jrn.trade, jrn.taxi,
-- jrn.train, jrn.quest, jrn.loot; post-hooks (DEC-00411) read what the client shows, every value through M.PSS_IsSecret.
local type, tonumber, tostring, pairs = type, tonumber, tostring, pairs
local concat = table.concat
local SEP = "\31"

local function unm() M.PSS_JrnUnmatched = (M.PSS_JrnUnmatched or 0) + 1 end
local function readable(v) if M.PSS_IsSecret(v) then return false end return v ~= nil end
local function on(opt) return M.PSS_On("journal") and (not opt or M.PSS_Opt(opt) ~= false) end
local function idOf(link) if type(link) == "string" and readable(link) then return tonumber(link:match("item:(%d+)")) end end
local function put(st, rec) M.PSS_IxPut("jrn", st, rec) end
local function party(name)
	if type(name) ~= "string" or not readable(name) then return "?" end
	return (M.PSS_NormName and M.PSS_NormName(name)) or name
end
local function done() return { cols = { "n" }, n = 0 } end
local function keys(set) local t = {}; for i = 1, set.n do t[i] = set[i][1] end return t end
local function split(k) local t = {}; for p in (k .. SEP):gmatch("([^" .. SEP .. "]*)" .. SEP) do t[#t + 1] = p end return t end

-- mail: the inbox as strings sender, subject, money, cod at each MAIL_INBOX_UPDATE; the hooks read this copy
local box = {}
M.PSS_Provide("jrn.mail", function()
	if not on("jrnMonitorMail") or not GetInboxHeaderInfo then return done() end
	for k in pairs(box) do box[k] = nil end
	for i = 1, (GetInboxNumItems and (GetInboxNumItems())) or 0 do
		local _, _, sender, subject, money, cod = GetInboxHeaderInfo(i)
		if readable(sender) and readable(money) and readable(cod) then box[i] = { sender, subject, money or 0, cod or 0 } end
	end
	return done()
end)
local function attach(i, a)
	local name, id, _, count = GetInboxItem(i, a)
	id = idOf(GetInboxItemLink and GetInboxItemLink(i, a)) or (readable(id) and tonumber(id)) or nil
	return id and (id .. ":" .. (count or 1)) or nil
end
local function mailIn(i, a)
	if not on("jrnMonitorMail") then return end
	local m = box[i]
	if not m then unm() return end
	local items
	if a == true then
		local t = {}
		for n = 1, 12 do local s = attach(i, n); if s then t[#t + 1] = s end end
		items = #t > 0 and concat(t, ";") or nil
	elseif a then
		items = attach(i, a)
	end
	put("jrn.mailin", { party = party(m[1]), copper = (not a or a == true) and m[3] > 0 and m[3] or (m[4] > 0 and -m[4] or nil), cod = m[4] > 0 and m[4] or nil, items = items, subject = m[2] })
end
local function mailMoney(i) mailIn(i) end
local function mailAll(i) mailIn(i, true) end
local function mailOut(recipient, subject)
	if not on("jrnMonitorMail") then return end
	local t = {}
	for a = 1, ATTACHMENTS_MAX_SEND or 12 do
		local _, id, _, count = GetSendMailItem(a)
		if readable(id) and tonumber(id) then t[#t + 1] = id .. ":" .. (count or 1) end
	end
	local money, cod = GetSendMailMoney and GetSendMailMoney() or 0, GetSendMailCOD and GetSendMailCOD() or 0
	if not readable(money) or not readable(cod) then unm() return end
	put("jrn.mailout", { party = party(recipient), copper = money > 0 and money or nil, cod = cod > 0 and cod or nil, items = #t > 0 and concat(t, ";") or nil, subject = readable(subject) and subject or nil })
end

-- trade: what both sides showed at the last accept is written when the client says the trade is complete
local tr
local function tradeSide(money, link, info)
	local t = {}
	for a = 1, 6 do
		local id = idOf(link(a))
		if id then t[#t + 1] = id .. ":" .. (select(3, info(a)) or 1) end
	end
	return money(), #t > 0 and concat(t, ";") or nil
end
M.PSS_Provide("jrn.trade", function(set)
	if not on("jrnMonitorTrades") then return done() end
	for _, k in ipairs(keys(set)) do
		local p = split(k)
		if p[1] == "TRADE_SHOW" then
			tr = {}
		elseif p[1] == "TRADE_ACCEPT_UPDATE" and p[2] == "1" and p[3] == "1" and GetPlayerTradeMoney then
			local o, oi = tradeSide(GetPlayerTradeMoney, GetTradePlayerItemLink, GetTradePlayerItemInfo)
			local i, ii = tradeSide(GetTargetTradeMoney, GetTradeTargetItemLink, GetTradeTargetItemInfo)
			tr = { party = party(UnitName("NPC")), out = o, ["in"] = i, outI = oi, inI = ii }
		elseif p[1] == "UI_INFO_MESSAGE" and ERR_TRADE_COMPLETE and p[3] == ERR_TRADE_COMPLETE then
			if tr and tr.party then
				put("jrn.trade", { party = tr.party, copperOut = tr.out > 0 and tr.out or nil, copperIn = tr["in"] > 0 and tr["in"] or nil, itemsOut = tr.outI, itemsIn = tr.inI })
			else
				unm()
			end
			tr = nil
		elseif p[1] == "UI_INFO_MESSAGE" and ERR_TRADE_CANCELLED and p[3] == ERR_TRADE_CANCELLED then
			tr = nil
		end
	end
	return done()
end)

-- taxi and training: the window opens, the post-hook of the purchase writes the cost
local taxiFrom, trainOpen
M.PSS_Provide("jrn.taxi", function()
	if not on() or not NumTaxiNodes then return done() end
	taxiFrom = nil
	for i = 1, NumTaxiNodes() do
		if TaxiNodeGetType(i) == "CURRENT" then taxiFrom = TaxiNodeName(i) end
	end
	return done()
end)
local function onTaxi(index)
	if not taxiFrom or not on() then return end
	local to, cost = TaxiNodeName(index), TaxiNodeCost(index)
	if not readable(to) or not readable(cost) or not readable(taxiFrom) then unm() return end
	put("jrn.taxi", { copper = cost, from = taxiFrom, to = to })
	taxiFrom = nil
end
M.PSS_Provide("jrn.train", function() trainOpen = on(); return done() end)
local function onTrain(index)
	if not trainOpen or not on() or not GetTrainerServiceCost then return end
	local cost, spell = GetTrainerServiceCost(index), GetTrainerServiceInfo and GetTrainerServiceInfo(index)
	if not readable(cost) or not readable(spell) then unm() return end
	put("jrn.train", { copper = cost, spell = spell })
end

-- quest: reward items seen before the turn-in join its line (the order is checked in game)
local qItems = {}
M.PSS_Provide("jrn.quest", function(set)
	if not on("jrnMonitorQuests") then return done() end
	for _, k in ipairs(keys(set)) do
		local p = split(k)
		local q = tonumber(p[2])
		if p[1] == "QUEST_LOOT_RECEIVED" and q then
			local id = idOf(p[3])
			if id then qItems[q] = (qItems[q] and qItems[q] .. ";" or "") .. id .. ":" .. (tonumber(p[4]) or 1) end
		elseif p[1] == "QUEST_TURNED_IN" and q then
			local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(q)
			local money, xp = tonumber(p[4]), tonumber(p[3])
			put("jrn.quest", { quest = readable(title) and title or tostring(q), copper = money and money > 0 and money or nil, xp = xp and xp > 0 and xp or nil, items = qItems[q] })
			qItems[q] = nil
		end
	end
	return done()
end)

-- loot: the slots read when the window opens are written when it closes
local lt
local function lootRead()
	local items, cur, copper = {}, {}, 0
	for i = 1, GetNumLootItems and GetNumLootItems() or 0 do
		local _, _, q = GetLootSlotInfo(i)
		local kind, link = GetLootSlotType(i), GetLootSlotLink(i)
		if kind == (Enum and Enum.LootSlotType and Enum.LootSlotType.Money or 2) then
			if readable(q) and tonumber(q) then copper = copper + q end
		elseif kind == (Enum and Enum.LootSlotType and Enum.LootSlotType.Currency or 3) then
			local c = type(link) == "string" and readable(link) and tonumber(link:match("currency:(%d+)"))
			if c then cur[#cur + 1] = c .. ":" .. (q or 1) end
		elseif idOf(link) then
			items[#items + 1] = idOf(link) .. ":" .. (q or 1)
		end
	end
	if #items + #cur == 0 and copper == 0 then lt = nil return end
	lt = { items = #items > 0 and concat(items, ";") or nil, cur = #cur > 0 and concat(cur, ";") or nil, copper = copper > 0 and copper or nil }
end
M.PSS_Provide("jrn.loot", function(set)
	if not on("jrnMonitorLoot") then return done() end
	for _, e in ipairs(keys(set)) do
		if e == "LOOT_OPENED" or e == "LOOT_READY" then
			lootRead()
		elseif e == "LOOT_CLOSED" then
			if lt then put("jrn.loot", { copper = lt.copper, items = lt.items, currencies = lt.cur }) else unm() end
			lt = nil
		end
	end
	return done()
end)

local hooked = {}
local function hook(name, fn)
	if not hooked[fn] and type(_G[name]) == "function" then hooked[fn] = true; hooksecurefunc(name, fn) end
end
local started
local prevStart = M.PSS_WhStartMore
function M.PSS_WhStartMore(warehouse)
	if prevStart then prevStart(warehouse) end
	if not warehouse or not M.PSS_On("journal") or not M.PSS_Trigger then return end
	hook("SendMail", mailOut); hook("TakeInboxMoney", mailMoney); hook("TakeInboxItem", mailIn)
	hook("AutoLootMailItem", mailAll); hook("TakeTaxiNode", onTaxi); hook("BuyTrainerService", onTrain)
	if started then return end
	started = true
	local valid = C_EventUtils and C_EventUtils.IsEventValid
	local function row(id, evs, key)
		local on = {}
		for _, e in ipairs(evs) do if not valid or valid(e) then on[#on + 1] = e end end
		M.PSS_Trigger({ id = id, gate = "journal", on = on, settle = "now", run = id, key = key })
	end
	row("jrn.mail", { "MAIL_INBOX_UPDATE" })
	row("jrn.trade", { "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "UI_INFO_MESSAGE" }, function(e, a, b)
		if e == "UI_INFO_MESSAGE" then return M.PSS_IsSecret(b) and nil or e .. SEP .. tostring(a) .. SEP .. tostring(b) end
		return e .. SEP .. tostring(a) .. SEP .. tostring(b)
	end)
	row("jrn.taxi", { "TAXIMAP_OPENED" })
	row("jrn.train", { "TRAINER_SHOW" })
	row("jrn.quest", { "QUEST_TURNED_IN", "QUEST_LOOT_RECEIVED" }, function(e, a, b, c)
		if M.PSS_IsSecret(a) or M.PSS_IsSecret(b) or M.PSS_IsSecret(c) then return nil end
		return e .. SEP .. tostring(a) .. SEP .. tostring(b) .. SEP .. tostring(c)
	end)
	row("jrn.loot", { "LOOT_OPENED", "LOOT_READY", "LOOT_CLOSED" })
end
