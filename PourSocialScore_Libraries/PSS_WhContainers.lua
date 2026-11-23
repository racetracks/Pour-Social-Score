------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE CONTAINER REGISTRY (warehouse-helper, one-build
-- plan STP-p07, 03_Design section 4). One row per container family; every
-- reader, trigger row, packer, cap, shim field and test is driven from it, so
-- a new container is a row and never new engine code.
--   M.PSS_WH_CONTAINERS      the rows, in order
--   M.PSS_WhRow(code)        the row of a container code ("b0", "k2", "t1")
--   M.PSS_WhCodes(row)       the codes that exist now ("b0".."b5", "k1".."k3", ...)
--   M.PSS_WhEvents()         every client event the live rows listen to, per client
-- A code is the row's prefix and a tab: b0..b5 bags and the reagent bag, y0
-- keyring, k<tab> bank, r0 reagent bank, w<tab> warband, e0 equipped, m0 mail,
-- v<page> void, a0 auctions, t<tab> guild bank.
-- A row whose `has` is false on this client registers nothing. The events of a
-- row are filtered by C_EventUtils.IsEventValid where the client has it, so a
-- name a client lacks is never registered. The file returns at the top while
-- the Warehouse and the Bag manager are both off (no table is built).
-- Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not (M.PSS_On("warehouse") or M.PSS_On("bags")) then return end

local type, ipairs, pairs = type, ipairs, pairs

local function bagIndex(name)
	local e = Enum and Enum.BagIndex
	return e and e[name]
end

local function bankTabs()
	return C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character)
end

local function range(from, to)
	local t = {}
	for i = from, to do t[#t + 1] = i end
	return t
end

-- which events does this client know
local function valid(list)
	local f = C_EventUtils and C_EventUtils.IsEventValid
	if not f then return list end
	local out = {}
	for _, e in ipairs(list) do if f(e) then out[#out + 1] = e end end
	return out
end

local ROWS = {
	{ code = "b", kind = "bags", owner = "c", gate = "bags", shim = "bags", cb = "BagCacheUpdate", sum = "bags",
		has = function() return true end,
		tabs = function() return bagIndex("ReagentBag") and range(0, 5) or range(0, 4) end,
		bagId = function(tab) return tab end,
		events = { "BAG_UPDATE", "BAG_CONTAINER_UPDATE", "ITEM_CHANGED" }, settle = { "BAG_UPDATE_DELAYED" }, persist = true },
	{ code = "y", kind = "keyring", owner = "c", gate = "bags", shim = "bags", cb = "BagCacheUpdate", sum = "bags",
		has = function() return bagIndex("Keyring") ~= nil end,
		tabs = function() return { 0 } end,
		bagId = function() return bagIndex("Keyring") end,
		events = { "BAG_UPDATE" }, settle = { "BAG_UPDATE_DELAYED" }, persist = true },
	{ code = "k", kind = "bank", owner = "c", gate = "bags", shim = "bank", cb = "BagCacheUpdate", sum = "bank", ["while"] = "bank",
		has = function() return true end,
		tabs = function()
			local data = bankTabs()
			if data then return range(1, #data) end
			return range(0, (bagIndex("BankBag_1") and 7 or 0))
		end,
		bagId = function(tab)
			if bankTabs() then return bagIndex("CharacterBankTab_" .. tab) end
			if tab == 0 then return bagIndex("Bank") end
			return bagIndex("BankBag_" .. tab)
		end,
		events = { "BAG_UPDATE", "PLAYERBANKSLOTS_CHANGED", "BANK_TABS_CHANGED", "BANK_TAB_SETTINGS_UPDATED", "PLAYERBANKBAGSLOTS_CHANGED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "BANKFRAME_OPENED", "BANKFRAME_CLOSED" },
		settle = { "BAG_UPDATE_DELAYED" }, persist = true },
	{ code = "r", kind = "reagent", owner = "c", gate = "warehouse", shim = "bank", cb = "BagCacheUpdate", sum = "reagent", ["while"] = "bank",
		has = function() return bagIndex("Reagentbank") ~= nil and IsReagentBankUnlocked ~= nil end,
		tabs = function() return { 0 } end,
		bagId = function() return bagIndex("Reagentbank") end,
		events = { "PLAYERREAGENTBANKSLOTS_CHANGED" }, settle = { "BAG_UPDATE_DELAYED" }, persist = true },
	{ code = "w", kind = "warband", owner = "w", gate = "warehouse", shim = "warband", cb = "WarbandBankCacheUpdate", sum = "warband", ["while"] = "account",
		has = function()
			return bagIndex("AccountBankTab_1") ~= nil and C_Bank ~= nil and C_Bank.FetchBankLockedReason ~= nil
				and C_Bank.FetchBankLockedReason(Enum.BankType.Account) == nil
		end,
		tabs = function()
			local data = C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.FetchPurchasedBankTabData(Enum.BankType.Account)
			return data and range(1, #data) or {}
		end,
		bagId = function(tab) return bagIndex("AccountBankTab_" .. tab) end,
		events = { "BAG_UPDATE", "BANK_TABS_CHANGED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }, settle = { "BAG_UPDATE_DELAYED" }, persist = true },
	{ code = "e", kind = "equipped", owner = "c", gate = "bags", shim = "equipped", cb = "EquippedCacheUpdate", sum = "equipped",
		has = function() return GetInventoryItemID ~= nil end,
		tabs = function() return { 0 } end,
		events = { "PLAYER_EQUIPMENT_CHANGED" }, settle = { "PLAYER_LOGOUT" }, reads = { "wh.sum", "wh.find", "wh.cont" }, persist = true },
	{ code = "m", kind = "mail", owner = "c", gate = "warehouse", shim = "mail", cb = "MailCacheUpdate", sum = "mail", ["while"] = "mail", expires = true, cap = 100,
		has = function() return GetInboxNumItems ~= nil end,
		tabs = function() return { 0 } end,
		events = { "MAIL_INBOX_UPDATE", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SUCCESS", "MAIL_SEND_SUCCESS", "MAIL_FAILED" }, settle = { "MAIL_INBOX_UPDATE" }, persist = true },
	{ code = "v", kind = "void", owner = "c", gate = "warehouse", shim = "void", cb = "VoidCacheUpdate", sum = "void", ["while"] = "void",
		has = function() return CanUseVoidStorage ~= nil end,
		tabs = function() return { 1, 2 } end,
		events = { "VOID_STORAGE_UPDATE", "VOID_STORAGE_CONTENTS_UPDATE", "VOID_TRANSFER_DONE", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }, settle = { "VOID_STORAGE_CONTENTS_UPDATE", "VOID_TRANSFER_DONE" }, persist = true },
	{ code = "a", kind = "auctions", owner = "c", gate = "warehouse", shim = "auctions", cb = "AuctionsCacheUpdate", sum = "auctions", ["while"] = "auction", expires = true, cap = 400,
		has = function() return C_AuctionHouse ~= nil or GetNumAuctionItems ~= nil end,
		tabs = function() return { 0 } end,
		events = { "OWNED_AUCTIONS_UPDATED", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_CANCELED", "AUCTION_OWNED_LIST_UPDATE", "AUCTION_HOUSE_AUCTIONS_EXPIRED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" },
		settle = { "OWNED_AUCTIONS_UPDATED", "AUCTION_OWNED_LIST_UPDATE" }, persist = true },
	{ code = "t", kind = "guild", owner = "g", gate = "warehouse", shim = "guild", cb = "GuildCacheUpdate", sum = "guild", ["while"] = "guildbank",
		has = function() return M.PSS_Can("guildBank") end,
		tabs = function()
			local r = M.PSS_Call("compat.guildBank.tabs")
			return range(1, r and r[1] and r[1][1] or 0)
		end,
		events = { "GUILDBANKBAGSLOTS_CHANGED", "GUILDBANK_UPDATE_TABS", "GUILDBANK_UPDATE_MONEY", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }, settle = { "GUILDBANKBAGSLOTS_CHANGED" }, persist = true },
}
M.PSS_WH_CONTAINERS = ROWS

local byCode = {}
for _, r in ipairs(ROWS) do byCode[r.code] = r end

-- the row of a container code: "b0" -> the bags row
function M.PSS_WhRow(code)
	return type(code) == "string" and byCode[code:sub(1, 1)] or nil
end

-- the codes of a row that exist on this client now
function M.PSS_WhCodes(row)
	local out = {}
	if not row.has() then return out end
	for _, tab in ipairs(row.tabs()) do out[#out + 1] = row.code .. tab end
	return out
end

-- every event the rows that run on this client listen to (client names only)
function M.PSS_WhEvents()
	local seen, out = {}, {}
	for _, r in ipairs(ROWS) do
		if r.has() then
			local lists = { valid(r.events), type(r.settle) == "table" and valid(r.settle) or {} }
			for _, list in ipairs(lists) do
				for _, e in ipairs(list) do
					if not seen[e] then seen[e] = true; out[#out + 1] = e end
				end
			end
		end
	end
	return out
end
