------------------------------------------------------------------------
-- POUR SOCIAL SCORE - GOLD (money-helper, one-build plan STP-p11, SAV-p06,
-- Syndicator parity 17). Gold is stored once: gold[ent] = copper in
-- PSS_WarehouseDB (0 is not stored); the warband's gold sits on the warband
-- entity and a guild's on its guild entity (read at the guild bank).
--   money.write   (no input)           -> ent, copper   [writes]  saves this character, the warband and the open guild bank
--   money.gold    ent?                 -> ent, copper             opts { hidden }
--   money.total   ent, copper          -> by, copper              opts { by = "realm" | "faction" | "all" }
--   money.text    copper               -> copper, text            opts { icons }
-- M.Events MONEY_CHANGED fires a set (ent, copper) when a value changed.
-- The file returns at the top while the Warehouse is off. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, pairs, ipairs, floor, tostring = type, pairs, ipairs, math.floor, tostring
local sort = table.sort
local MAX = 2 ^ 53

local function db(create)
	local d = rawget(_G, "PSS_WarehouseDB")
	if type(d) ~= "table" and create then d = { v = 1 }; _G.PSS_WarehouseDB = d end
	if type(d) == "table" and type(d.v) == "number" and d.v > 1 then return nil end
	return d
end

local function valid(v)
	return type(v) == "number" and v == floor(v) and v >= 0 and v < MAX and v == v
end

local ver = 0
local function put(ent, copper)
	if not ent or ent == 0 then return false end
	if not (M.PSS_Entity and M.PSS_Entity(ent)) then		-- F4: gold only for an entity whose row is saved
		if M.PSS_ErrNote then M.PSS_ErrNote("arg", "money.write", "unknown entity " .. tostring(ent)) end
		return false
	end
	if not valid(copper) then
		if M.PSS_ErrNote then M.PSS_ErrNote("arg", "money.write", "gold must be a whole number of copper below 2^53") end
		return false
	end
	local d = db(true)
	if not d then return false end
	d.gold = d.gold or {}
	local old = d.gold[ent] or 0
	if old == copper then return false end
	d.gold[ent] = copper > 0 and copper or nil
	d.seen = d.seen or {}
	d.seen[ent] = GetServerTime and GetServerTime() or time()
	ver = ver + 1
	return true
end
function M.PSS_MoneyVer() return ver end
M.PSS_MoneyPut = put		-- the import writes gold through the same checks

local function changed(out)
	if out.n > 0 and M.Events and M.Events.Fire then M.Events.Fire("MONEY_CHANGED", out) end
end

M.PSS_Provide("money.write", function()
	local out = { cols = { "ent", "copper" }, n = 0 }
	local function one(ent, v)
		if ent and put(ent, v) then out.n = out.n + 1; out[out.n] = { ent, v } end
	end
	if GetMoney then one(M.PSS_Me(true), GetMoney()) end
	if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType then
		local ok, v = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
		if ok and v then one(M.PSS_EntityId("w", "Warband", "", true), v) end
	end
	if GetGuildBankMoney and GetGuildInfo then
		local name, _, _, realm = GetGuildInfo("player")
		local bank = tonumber(GetNumGuildBankTabs and GetNumGuildBankTabs() or 0) > 0
		if name and bank then one(M.PSS_EntityId("g", name, realm or GetRealmName(), true), GetGuildBankMoney()) end
	end
	changed(out)
	return out
end, { returns = { "ent", "copper" }, doc = "saves this character's, the warband's and the open guild bank's gold", cost = "O(1)", writes = true, retry = 1, onError = "empty" })

local function hiddenOf(ent)
	return (M.PSS_EntityFlags(ent) or ""):find("h", 1, true) ~= nil
end

M.PSS_Provide("money.gold", function(input, opts)
	local out = { cols = { "ent", "copper" }, n = 0 }
	local d = db()
	local gold = d and d.gold
	if not gold then return out end
	local ids = {}
	if input and input.cols and input.cols[1] == "ent" then		-- no input lists everyone; an empty set lists no one
		for i = 1, input.n do ids[#ids + 1] = input[i][1] end
	else
		for ent in pairs(gold) do ids[#ids + 1] = ent end
	end
	sort(ids)
	for _, ent in ipairs(ids) do
		local v = gold[ent]
		if v ~= nil and not valid(v) then
			gold[ent] = nil		-- a value the save should not hold
			if M.PSS_ErrNote then M.PSS_ErrNote("arg", "money.gold", "dropped a saved gold value that was not a whole number") end
		elseif v and (opts and opts.hidden or not hiddenOf(ent)) then
			out.n = out.n + 1
			out[out.n] = { ent, v }
		end
	end
	return out
end, { accepts = { "ent" }, returns = { "ent", "copper" }, doc = "the saved gold per entity", cost = "O(entities)", writes = false, onError = "last",
	ver = function() return ver end })

-- F4: the number of saved gold values whose entity is not saved (never removed here; the player removes them, W3-D5)
function M.PSS_MoneyOrphans()
	local d = db()
	local gold = d and d.gold
	if not gold then return 0 end
	local n = 0
	for ent in pairs(gold) do
		local set = M.PSS_Entity(ent)
		if not (set and set.n > 0) then n = n + 1 end
	end
	return n
end

M.PSS_Provide("money.total", function(input, opts)
	local by = opts and opts.by or "all"
	local out = { cols = { "by", "copper" }, n = 0 }
	local sums, order = {}, {}
	for i = 1, input.n do
		local ent, copper = input[i][1], input[i][2]
		local set = M.PSS_Entity(ent)
		local r = set and set.n > 0 and set[1]
		local label = "all"
		if by == "realm" then label = r and r[4] or "" elseif by == "faction" then label = r and r[5] or "" end
		if label == "" then label = "?" end
		if not sums[label] then sums[label] = 0; order[#order + 1] = label end
		sums[label] = sums[label] + (copper or 0)
	end
	sort(order)
	for _, label in ipairs(order) do out.n = out.n + 1; out[out.n] = { label, sums[label] } end
	return out
end, { accepts = { "ent", "copper" }, returns = { "by", "copper" }, doc = "adds gold up by realm, faction or all", cost = "O(entities)", writes = false, onError = "empty" })

local function text(copper, icons)
	copper = floor(tonumber(copper) or 0)
	if icons and GetCoinTextureString then return GetCoinTextureString(copper) end
	return GetMoneyString and GetMoneyString(copper) or tostring(copper) .. "c"
end
M.PSS_MoneyText = text

M.PSS_Provide("money.text", function(input, opts)
	local out = { cols = { "copper", "text" }, n = 0 }
	local c = M.PSS_SetCol(input, "copper") or 1
	for i = 1, input.n do
		out.n = out.n + 1
		out[out.n] = { input[i][c], text(input[i][c], opts and opts.icons) }
	end
	return out
end, { accepts = { "copper" }, returns = { "copper", "text" }, doc = "formats copper as the client does", cost = "O(rows)", writes = false, onError = "default",
	default = { cols = { "copper", "text" }, n = 0 } })

local prev = M.PSS_WhStartMore
function M.PSS_WhStartMore(warehouse)
	if prev then prev(warehouse) end
	if not warehouse then return end
	local isValid = C_EventUtils and C_EventUtils.IsEventValid
	local on = {}
	for _, e in ipairs({ "PLAYER_MONEY", "ACCOUNT_MONEY", "GUILDBANK_UPDATE_MONEY", "PLAYER_ENTERING_WORLD" }) do
		if not isValid or isValid(e) then on[#on + 1] = e end
	end
	M.PSS_Trigger({ id = "wh.money", gate = "warehouse", on = on, settle = "now", run = "money.write", key = function() return "m" end })
end
