------------------------------------------------------------------------
-- POUR SOCIAL SCORE - WAREHOUSE METADATA AND CURRENCIES (warehouse-helper,
-- one-build plan STP-p09, DEC-00241, SAV-p04, SAV-p05; Syndicator parity
-- 16, 18, 19). Beside the containers the warehouse keeps, per entity:
--   meta[ent].t  guild bank tabs   "1;" tab.name.icon.viewable , ...   (names escaped)
--   meta[ent].k  bank tabs         "1;" tab.name.icon.depositFlags , ...
--   meta[ent].q  the bag items you carry, as item keys, one per bag slot
--   meta[ent].u  the character's unit GUID (to find who a currency transfer came from)
--   cur[ent]     currencies        "1;n;sum;hash;" id.quantity , ...   (the shared ones sit on the warband)
-- A guild tab you may not view is never read, so its saved name and icon stay
-- (a tab keeps its old entry when the client cannot show it now).
-- Services: wh.curWrite (writes cur[ent] from the client, verify then swap).
-- M.PSS_WhMeta(ent, codes) is called by wh.write after a container was saved.
-- The file returns at the top while the Warehouse is off. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local sort, concat = table.sort, table.concat
local C = M.PSS_Codec

local SHARED = { [2032] = true, [3292] = true }		-- Trader's Tender, Infinite Knowledge: held by the warband, not by one character

local function db(create)
	local d = rawget(_G, "PSS_WarehouseDB")
	if type(d) ~= "table" and create then d = { v = 1 }; _G.PSS_WarehouseDB = d end
	if type(d) == "table" and type(d.v) == "number" and d.v > 1 then return nil end		-- a newer layout is kept
	return d
end

local orphansSaid

local function metaOf(ent)
	local d = db(true)
	if not d then return nil end
	d.meta = d.meta or {}
	d.meta[ent] = d.meta[ent] or {}
	return d.meta[ent]
end

-- "1;a.b.c,d.e.f" <-> { {a,b,c}, {d,e,f} } (fields escaped; a string of a newer layout is not read)
local function packList(rows)
	local out = {}
	for i = 1, #rows do out[i] = C.rec(rows[i]) end
	return "1;" .. concat(out, ",")
end
local function unpackList(str)
	if type(str) ~= "string" then return {} end
	local v, body = C.layout(str)
	if v ~= 1 then return {} end
	local rows = {}
	for e in (body .. ","):gmatch("([^,]*),") do
		if e ~= "" then rows[#rows + 1] = C.unrec(e) end
	end
	return rows
end
M.PSS_WhMetaPack, M.PSS_WhMetaUnpack = packList, unpackList

local tabSet = { cols = { "tab" }, n = 1, { 1 } }		-- the reused one-row input sets
local bagSet = { cols = { "bag" }, n = 1, { 1 } }

local function guildMeta(ent)
	local m = metaOf(ent)
	if not m then return end
	local old = {}
	for _, r in ipairs(unpackList(m.t)) do old[tonumber(r[1])] = r end
	local rows = {}
	local r = M.PSS_Call("compat.guildBank.tabs")
	local count = r and r[1] and r[1][1] or 0
	for tab = 1, count do
		tabSet[1][1] = tab
		local ans = M.PSS_Call("compat.guildBank.tab", tabSet)
		ans = ans and ans[1]
		local name, icon, viewable
		if ans then name, icon, viewable = ans[1], ans[2], ans[3] end
		if viewable == false and old[tab] then
			old[tab][4] = "0"		-- the old name and icon stay; only the flag changes
			rows[tab] = old[tab]
		else
			rows[tab] = { tab, name or "", icon or 0, viewable == false and 0 or 1 }
		end
	end
	if #rows > 0 then m.t = packList(rows) end
end

local function bankMeta(ent)
	local m = metaOf(ent)
	local data = C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character)
	if not (m and data) then return end
	local rows = {}
	for i, t in ipairs(data) do rows[i] = { i, t.name or "", t.icon or 0, t.depositFlags or 0 } end
	m.k = packList(rows)
end

local function bagMeta(ent)
	local m = metaOf(ent)
	if not (m and GetInventoryItemLink) then return end
	local keys = {}
	for i = 1, 5 do
		bagSet[1][1] = i
		local r = M.PSS_Call("compat.containers.invId", bagSet)
		local inv = r and r[1] and r[1][1]
		if not inv then return end		-- no answer: the saved bag keys stay (as before B3T5, when the API was missing)
		local link = GetInventoryItemLink("player", inv)
		keys[i] = link and M.PSS_ItemKey(link) or ""
	end
	m.q = "1;" .. C.list(keys, ",")
	local guid = UnitGUID("player")
	if type(guid) == "string" and not (M.PSS_IsSecret and M.PSS_IsSecret(guid)) then m.u = guid end
end

-- called after the containers `codes` ([code] = true) of `ent` were saved
function M.PSS_WhMeta(ent, codes)
	for code in pairs(codes) do
		local k = code:sub(1, 1)
		if k == "t" then guildMeta(ent)
		elseif k == "k" then bankMeta(ent)
		elseif k == "e" then bagMeta(ent)
		end
	end
end

------------------------------------------------------------------------
-- Currencies
------------------------------------------------------------------------
local function readCurrencies()
	local mine, shared = {}, {}
	local list = C_CurrencyInfo
	if not (list and list.GetCurrencyListSize) then return mine, shared end
	local opened = {}
	local i = 1
	while i <= list.GetCurrencyListSize() do
		local info = list.GetCurrencyListInfo(i)
		if info then
			if info.isHeader then
				if info.isHeaderExpanded == false then list.ExpandCurrencyList(i, true); opened[#opened + 1] = i end
			else
				local link = list.GetCurrencyListLink(i)
				local id = link and list.GetCurrencyIDFromLink(link)
				if id and not (M.PSS_IsSecret and M.PSS_IsSecret(id)) then
					local q = tonumber(info.quantity) or 0
					if SHARED[id] or info.isAccountWide then shared[id] = q else mine[id] = q end
				end
			end
		end
		i = i + 1
	end
	for j = #opened, 1, -1 do list.ExpandCurrencyList(opened[j], false) end
	return mine, shared
end

local curVer = 0
function M.PSS_WhCurVer() return curVer end
function M.PSS_WhCurBump() curVer = curVer + 1 end

local function packCur(map)
	local ids = {}
	for id in pairs(map) do ids[#ids + 1] = id end
	sort(ids)
	local list, sum = {}, 0
	for i, id in ipairs(ids) do list[i] = id .. "." .. map[id]; sum = sum + map[id] end
	return C.header(concat(list, ","), #list, sum)
end

local function unpackCur(str)
	local ok, _, _, body = C.check(str)
	local map = {}
	if not ok then return map end
	for e in (body .. ","):gmatch("([^,]*),") do
		local id, q = e:match("^(%d+)%.(%d+)$")
		if id then map[tonumber(id)] = tonumber(q) end
	end
	return map
end
M.PSS_WhCurPack, M.PSS_WhCurUnpack = packCur, unpackCur

-- verify then assign; true when the saved string changed
local function putCur(ent, map)
	local d = db(true)
	if not d or not ent or ent == 0 then return false end
	local str = next(map) and packCur(map) or nil
	d.cur = d.cur or {}
	if d.cur[ent] == str then return false end
	if str then
		local back = unpackCur(str)
		for id, q in pairs(map) do if back[id] ~= q then error("integrity: the currency string did not decode to its values", 0) end end
		d.cur[ent] = str
	else
		d.cur[ent] = nil
	end
	d.seen = d.seen or {}
	d.seen[ent] = GetServerTime and GetServerTime() or time()
	curVer = curVer + 1
	return true
end

M.PSS_Provide("wh.curWrite", function()
	local out = { cols = { "ent", "cont", "op" }, n = 0 }
	local me = M.PSS_Me(true)
	if not orphansSaid then
		orphansSaid = true
		local o = M.PSS_EntityOrphans()
		if #o > 0 then
			M.ShowMsg(("Warehouse: saved data for %d character(s) with no saved name is kept, hidden and not counted. Remove it in Options, Warehouse, or with /pss wh status and /pss wh remove #id."):format(#o))
		end
	end
	local mine, shared = readCurrencies()
	if me and putCur(me, mine) then out.n = out.n + 1; out[out.n] = { me, "cur", "put" } end
	local wb = M.PSS_EntityId("w", "Warband", "", true)
	if wb and next(shared) then
		-- the warband holds the shared currencies; a character that shows a different quantity wins (the client's list is the truth)
		if putCur(wb, shared) then out.n = out.n + 1; out[out.n] = { wb, "cur", "put" } end
	end
	if out.n > 0 and M.Events and M.Events.Fire then M.Events.Fire("WH_CHANGED", out) end
	return out
end, { returns = { "ent", "cont", "op" }, doc = "saves this character's currencies and the shared ones", cost = "O(currencies)", writes = true, retry = 1, onError = "empty" })

------------------------------------------------------------------------
-- The warband currency transfer log (parity 16): a transfer from another
-- character lowers that character's saved quantity
------------------------------------------------------------------------
local pendingTransfer
local function transferred()
	local p = pendingTransfer
	pendingTransfer = nil
	if not p then return end
	local d = db()
	if not (d and d.meta) then return end
	for ent, m in pairs(d.meta) do
		if m.u == p.guid and d.cur and d.cur[ent] then
			local map = unpackCur(d.cur[ent])
			if map[p.id] then
				map[p.id] = math.max(0, map[p.id] - p.amount)
				putCur(ent, map)
				if M.Events and M.Events.Fire then M.Events.Fire("WH_CHANGED", { cols = { "ent", "cont", "op" }, n = 1, { ent, "cur", "put" } }) end
			end
		end
	end
end

local started
function M.PSS_WhMetaStart(warehouse)
	if not warehouse or started then return end
	started = true
	M.PSS_Trigger({ id = "wh.cur", gate = "warehouse", on = { "CURRENCY_DISPLAY_UPDATE", "PLAYER_ENTERING_WORLD" },
		settle = { "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT" }, run = "wh.curWrite", key = function() return "c" end })
	M.PSS_Trigger({ id = "wh.transfer", gate = "warehouse", on = { "CURRENCY_TRANSFER_LOG_UPDATE", "CURRENCY_TRANSFER_FAILED" }, settle = "now", run = "wh.transfer",
		key = function(e) return e end })
	if C_CurrencyInfo and C_CurrencyInfo.RequestCurrencyFromAccountCharacter then
		hooksecurefunc(C_CurrencyInfo, "RequestCurrencyFromAccountCharacter", function(guid, id, amount)
			if M.PSS_On("warehouse") and type(guid) == "string" and not (M.PSS_IsSecret and M.PSS_IsSecret(guid)) then
				pendingTransfer = { guid = guid, id = id, amount = tonumber(amount) or 0 }
			end
		end)
	end
end

M.PSS_Provide("wh.transfer", function(set)
	for i = 1, set.n do
		if set[i][1] == "CURRENCY_TRANSFER_FAILED" then pendingTransfer = nil else transferred() end
	end
	return set
end, { accepts = { "key" }, returns = { "key" }, doc = "applies a finished warband currency transfer to the source character", cost = "O(1)", writes = true, onError = "empty" })

M.PSS_WhStartMore = M.PSS_WhMetaStart
