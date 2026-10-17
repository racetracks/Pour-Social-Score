------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE SHARED ITEM LAYER (warehouse-helper, one-build
-- plan STP-p08, L1). One reader per container family of the registry
-- (PSS_WhContainers.lua) reads what the client shows right now; the
-- Warehouse, the bag windows and Drop Cheapest Thing all stand on it, so a
-- burst of changes is read once.
--   service item.live   input: container codes ("b0", "k*" for every bank tab, "*" for all) or none
--                       -> ent, cont, slot, item, count, flags      (item is the item key)
--                       the set also carries .conts = { [code] = true }: the containers that
--                       were read (an emptied container is in it with no rows)
--   service item.slots  input: a bag id -> bag, slots
--   M.PSS_ItemKeyFn(row)   the key function of the trigger row of a registry row
--   M.PSS_ItemOpen(kind)   whether bank | account | mail | guildbank | void | auction is open
--   M.PSS_ItemAwait(ids)   asks the client for item data and raises @item.data when it arrives
-- flags: b bound, l has loot, t<time> expires at (mail and auctions).
-- A container that needs an open window (bank, mail, void, auctions, guild
-- bank, warband) is read only while that window is open, so closing it never
-- empties the saved copy. An item whose data the client has not loaded is
-- saved at once with its id and count; its name is awaited (class await-data)
-- for display only. A secret value is skipped.
-- The file returns at the top while the Warehouse and the Bag manager are off.
-- Loaded with Libraries. No frame, no OnUpdate.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not (M.PSS_On("warehouse") or M.PSS_On("bags")) then return end

local type, pairs, ipairs, next, tostring, tonumber = type, pairs, ipairs, next, tostring, tonumber
local floor = math.floor

local COLS = { "ent", "cont", "slot", "item", "count", "flags" }
local OPEN = {}				-- [kind] = true while that window is open
local KIND_OF_TYPE			-- [interaction type] = kind, built on first need
local pending = {}			-- [itemID] = true: data asked for, not yet here

local function now() return GetServerTime and GetServerTime() or time() end
local function secret(v) return M.PSS_IsSecret and M.PSS_IsSecret(v) end

local function kinds()
	if not KIND_OF_TYPE then
		KIND_OF_TYPE = {}
		local t = Enum and Enum.PlayerInteractionType or {}
		for kind, name in pairs({ bank = "Banker", account = "AccountBanker", mail = "MailInfo", guildbank = "GuildBanker", void = "VoidStorageBanker", auction = "Auctioneer" }) do
			if t[name] then KIND_OF_TYPE[t[name]] = kind end
		end
	end
	return KIND_OF_TYPE
end

-- open: the events say so; where the client can be asked, it answers
function M.PSS_ItemOpen(kind)
	if OPEN[kind] then return true end
	local pim = C_PlayerInteractionManager
	local name = ({ bank = "Banker", account = "AccountBanker", mail = "MailInfo", guildbank = "GuildBanker", void = "VoidStorageBanker", auction = "Auctioneer" })[kind]
	local t = name and Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType[name]
	if pim and pim.IsInteractingWithNpcOfType and t and t ~= 0 then return pim.IsInteractingWithNpcOfType(t) == true end
	return false
end

local function active(row)
	if not row.has() then return false end
	if row.gate == "warehouse" then return M.PSS_On("warehouse") end
	return M.PSS_On("bags") or M.PSS_On("warehouse")
end

local function needsOpen(row)
	local w = row["while"]
	return w ~= nil and not M.PSS_ItemOpen(w)
end

------------------------------------------------------------------------
-- Waiting for item data (display only)
------------------------------------------------------------------------
local awaiting = false
-- how many items the client has been asked about and not yet answered
local npending = 0
function M.PSS_ItemPending() return npending end

function M.PSS_ItemAwait(ids)
	if not (C_Item and C_Item.RequestLoadItemDataByID) then return end
	for id in pairs(ids) do
		if not pending[id] then pending[id] = true; npending = npending + 1; C_Item.RequestLoadItemDataByID(id) end
	end
	if awaiting or not M.PSS_Want then return end
	awaiting = true
	M.PSS_Want({ id = "item.data", class = "await-data", on = { "ITEM_DATA_LOAD_RESULT" }, fn = function(_, id)
		if pending[id] then pending[id] = nil; npending = npending - 1 end
		if M.PSS_Signal then M.PSS_Signal("@item.data", { cols = { "key" }, n = 1, { id } }) end
		if npending == 0 then
			awaiting = false
			M.PSS_Unwant("item.data")
			if M.Events and M.Events.Fire then M.Events.Fire("ITEM_DATA") end		-- a window showing names asks again
		end
	end })
end

------------------------------------------------------------------------
-- Readers
------------------------------------------------------------------------
local function entOf(row)
	if not M.PSS_On("warehouse") then return 0 end
	if row.owner == "c" then return M.PSS_Me and M.PSS_Me(true) or 0 end
	if row.owner == "w" then return M.PSS_EntityId and M.PSS_EntityId("w", "Warband", "", true) or 0 end
	if row.owner == "g" then
		if not IsInGuild() then return 0 end
		local name, _, _, realm = GetGuildInfo("player")
		if type(name) ~= "string" or secret(name) then return 0 end
		return M.PSS_EntityId and M.PSS_EntityId("g", name, realm or GetRealmName(), true) or 0
	end
	return 0
end

local unseen				-- itemIDs read this pass whose data the client does not have

local function add(out, ent, code, slot, link, id, count, flags)
	local key = (link and M.PSS_ItemKey(link)) or (id and tostring(id))
	-- an empty slot the client reports as item 0 (Camelot) is not an item (F9)
	if not key or tonumber(key:match("^%d+")) == 0 then return end
	if id and C_Item.IsItemDataCachedByID and not C_Item.IsItemDataCachedByID(id) then
		unseen = unseen or {}
		unseen[id] = true
	end
	out.n = out.n + 1
	out[out.n] = { ent, code, slot, key, count or 1, flags or "" }
end

local function bagFlags(info)
	local f = ""
	if info.isBound then f = f .. "b" end
	if info.hasLoot then f = f .. "l" end
	return f
end

-- the client takes an ItemLocation object, never a plain table (F1: "Usage: C_Item.IsBound(itemLocation)" on Camelot)
local function locBag(bag, slot)
	if ItemLocation and ItemLocation.CreateFromBagAndSlot then return ItemLocation:CreateFromBagAndSlot(bag, slot) end
end

local function locEquip(slot)
	if ItemLocation and ItemLocation.CreateFromEquipmentSlot then return ItemLocation:CreateFromEquipmentSlot(slot) end
end

local function readBagLike(row, code, out, ent)
	local bag = row.bagId(tonumber(code:sub(2)))
	if bag == nil then return end
	local n = C_Container.GetContainerNumSlots(bag) or 0
	for slot = 1, n do
		local info = C_Container.GetContainerItemInfo(bag, slot)
		if info and not secret(info.hyperlink) then
			add(out, ent, code, slot, info.hyperlink, info.itemID, info.stackCount, bagFlags(info))
		elseif not info and C_Item.DoesItemExist then
			local loc = locBag(bag, slot)
			if loc and C_Item.DoesItemExist(loc) then
				local id = C_Item.GetItemID(loc)
				if id then add(out, ent, code, slot, nil, id, 1, "") end
			end
		end
	end
end

local function readEquipped(row, code, out, ent)
	local top = C_Container.ContainerIDToInventoryID(1) - 1
	for slot = 0, top do
		local id = GetInventoryItemID("player", slot)
		if id then
			local loc = C_Item.IsBound and locEquip(slot)
			local ok, bound = false, false
			if loc then ok, bound = pcall(C_Item.IsBound, loc) end
			if not ok then bound = false end
			add(out, ent, code, slot, GetInventoryItemLink("player", slot), id, GetInventoryItemCount("player", slot), bound and "b" or "")
		end
	end
end

local function readMail(row, code, out, ent)
	local t = now()
	local count = GetInboxNumItems()
	local per = ATTACHMENTS_MAX_RECEIVE or 16
	for i = 1, count do
		local _, _, _, _, _, _, daysLeft = GetInboxHeaderInfo(i)
		local expiry = floor(t + (tonumber(daysLeft) or 30) * 86400)
		for a = 1, per do
			local _, id, _, n = GetInboxItem(i, a)
			if id then add(out, ent, code, (i - 1) * per + a, GetInboxItemLink(i, a), id, n, "t" .. expiry) end
		end
	end
end

local function readVoid(row, code, out, ent)
	local page = tonumber(code:sub(2))
	for slot = 1, 80 do
		local id = GetVoidItemInfo(page, slot)
		if id then add(out, ent, code, slot, GetVoidItemHyperlinkString((page - 1) * 80 + slot), id, 1, "") end
	end
end

local LEFT = { 1800, 7200, 43200, 172800 }
local function readAuctions(row, code, out, ent)
	local t = now()
	if C_AuctionHouse then
		for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
			local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
			if a then add(out, ent, code, i, a.itemLink, a.itemKey and a.itemKey.itemID, a.quantity, "t" .. floor(t + (a.timeLeftSeconds or 3600))) end
		end
	else
		for i = 1, GetNumAuctionItems("owner") do
			local _, _, n = GetAuctionItemInfo("owner", i)
			local link = GetAuctionItemLink("owner", i)
			if link then add(out, ent, code, i, link, nil, n, "t" .. floor(t + (LEFT[GetAuctionItemTimeLeft("owner", i)] or 3600))) end
		end
	end
end

local function readGuild(row, code, out, ent)
	local tab = tonumber(code:sub(2))
	if select(3, GetGuildBankTabInfo(tab)) == false then return false end		-- a tab we may not view is never read: its saved copy stays
	for slot = 1, 98 do
		local link = GetGuildBankItemLink(tab, slot)
		if link and not secret(link) then
			local _, n = GetGuildBankItemInfo(tab, slot)
			add(out, ent, code, slot, link, nil, n, "")
		end
	end
end

local READER = { bags = readBagLike, keyring = readBagLike, bank = readBagLike, reagent = readBagLike, warband = readBagLike,
	equipped = readEquipped, mail = readMail, void = readVoid, auctions = readAuctions, guild = readGuild }

-- the codes of `row` that a key asks for: "k*" every code of the row, "k2" one, "*" every row
local function wanted(keys)
	if not keys then return nil end
	local w = {}
	for i = 1, keys.n do
		local k = keys[i][1]
		if type(k) == "string" then w[k] = true end
	end
	return w
end

M.PSS_Provide("item.live", function(input)
	local out = { cols = COLS, n = 0, conts = {} }
	local w = wanted(input)
	unseen = nil
	for _, row in ipairs(M.PSS_WH_CONTAINERS) do
		if active(row) and not needsOpen(row) then
			local all = w == nil or w["*"] or w[row.code .. "*"]
			local ent
			for _, code in ipairs(M.PSS_WhCodes(row)) do
				if all or w[code] then
					ent = ent or entOf(row)
					if READER[row.kind](row, code, out, ent) ~= false then out.conts[code] = ent end
				end
			end
		end
	end
	if unseen then M.PSS_ItemAwait(unseen) end
	return out
end, { accepts = { "key" }, returns = COLS, doc = "the containers as the client shows them now", cost = "O(slots read)", writes = false,
	onError = "empty" })

M.PSS_Provide("item.slots", function(input)
	local out = { cols = { "bag", "slots" }, n = 0 }
	for i = 1, input.n do
		local bag = tonumber(input[i][1])
		out.n = out.n + 1
		out[out.n] = { bag, bag and C_Container.GetContainerNumSlots(bag) or 0 }
	end
	return out
end, { accepts = { "key" }, returns = { "bag", "slots" }, doc = "the number of slots of a bag id", cost = "O(1)", writes = false, onError = "default",
	default = { cols = { "bag", "slots" }, n = 0 } })

------------------------------------------------------------------------
-- The key function of a registry row's trigger row
------------------------------------------------------------------------
-- bag id -> container code, for the rows that BAG_UPDATE names a bag of
local function bagCode(row, bag)
	if row.code == "b" then
		if type(bag) == "number" and bag >= 0 and bag <= 5 then
			for _, c in ipairs(M.PSS_WhCodes(row)) do if row.bagId(tonumber(c:sub(2))) == bag then return c end end
		end
		return nil
	end
	for _, c in ipairs(M.PSS_WhCodes(row)) do
		if row.bagId(tonumber(c:sub(2))) == bag then return c end
	end
end

function M.PSS_ItemKeyFn(row)
	local kind, w = row.kind, row["while"]
	return function(event, a1)
		if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
			local k = kinds()[a1]
			if k then OPEN[k] = event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or nil end
			if k and k == w and OPEN[k] then return row.code .. "*" end
			return nil
		elseif event == "BANKFRAME_OPENED" then
			OPEN.bank = true
			return w == "bank" and row.code .. "*" or nil
		elseif event == "BANKFRAME_CLOSED" or event == "MAIL_CLOSED" then
			OPEN[event == "MAIL_CLOSED" and "mail" or "bank"] = nil
			return nil
		elseif event == "MAIL_SHOW" then
			OPEN.mail = true
			return w == "mail" and row.code .. "*" or nil
		elseif event == "BAG_UPDATE" then
			if w and not M.PSS_ItemOpen(w) then return nil end
			return bagCode(row, a1)
		elseif event == "PLAYERBANKSLOTS_CHANGED" then
			if kind ~= "bank" then return nil end
			if w and not M.PSS_ItemOpen(w) then return nil end
			if C_Bank and C_Bank.FetchPurchasedBankTabData then return type(a1) == "number" and "k" .. a1 or "k*" end
			return "k0"
		elseif event == "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED" then
			if kind ~= "warband" or not M.PSS_ItemOpen("account") then return nil end
			return type(a1) == "number" and "w" .. a1 or "w*"
		end
		-- the rest are whole-family changes: every code of the row
		if w and not M.PSS_ItemOpen(w) and event ~= "PLAYER_LOGOUT" then return nil end
		return row.code .. "*"
	end
end
