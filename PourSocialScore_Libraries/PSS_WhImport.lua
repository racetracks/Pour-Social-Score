------------------------------------------------------------------------
-- POUR SOCIAL SCORE - IMPORT FROM SYNDICATOR (warehouse-helper, one-build
-- plan STP-p13, DEC-00102). Syndicator is another addon by Plusmouse; its
-- saved data is read only through its documented API (Syndicator.API), never
-- its saved variables, and nothing is written to it. What is read becomes
-- our own packed form through wh.write (verify, then swap).
--   wh.import   opts { dry }  ->  kind, name, conts, slots, skipped
-- A character that raises an error or has no data is skipped and counted.
-- With { dry = true } the counts are made and nothing is written. Syndicator
-- must be loaded; otherwise one line is printed and nothing is done.
-- Currencies are not imported (they are read again from the client at login).
-- Loaded with Libraries; the file returns at the top while the Warehouse is off.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, pairs, ipairs, pcall, tostring, tonumber = type, pairs, ipairs, pcall, tostring, tonumber
local sort = table.sort

local COLS = { "ent", "cont", "slot", "item", "count", "flags" }

-- one list of slot tables -> rows { slot, item key, count, flags }
local function rowsOf(list, ent, code, out)
	local n = 0
	if type(list) ~= "table" then return 0 end
	for i = 1, #list do
		local s = list[i]
		if type(s) == "table" and s.itemID then
			local key = s.itemLink and M.PSS_ItemKey(s.itemLink) or tostring(s.itemID)
			if key then
				n = n + 1
				out.n = out.n + 1
				out[out.n] = { ent, code, i, key, tonumber(s.itemCount) or 1, s.isBound and "b" or "" }
			end
		end
	end
	return n
end

local function newPayload() return { cols = COLS, n = 0, conts = {} } end

-- a character's containers -> a payload
local function character(c, ent, p)
	local slots = 0
	local function add(code, list)
		p.conts[code] = ent
		slots = slots + rowsOf(list, ent, code, p)
	end
	for i, bag in pairs(type(c.bags) == "table" and c.bags or {}) do if type(i) == "number" then add("b" .. (i - 1), bag) end end
	if type(c.bankTabs) == "table" and next(c.bankTabs) then
		for i, tab in pairs(c.bankTabs) do if type(i) == "number" and type(tab) == "table" then add("k" .. i, tab.slots) end end
	elseif type(c.bank) == "table" then
		for i, bag in pairs(c.bank) do if type(i) == "number" then add("k" .. (i - 1), bag) end end
	end
	if c.mail then add("m0", c.mail) end
	if c.auctions then add("a0", c.auctions) end
	if c.equipped then add("e0", c.equipped) end
	for i, page in pairs(type(c.void) == "table" and c.void or {}) do if type(i) == "number" then add("v" .. i, page) end end
	return slots
end

local function tabs(list, prefix, ent, p)
	local slots = 0
	for i, tab in pairs(type(list) == "table" and list or {}) do
		if type(i) == "number" and type(tab) == "table" then
			p.conts[prefix .. i] = ent
			slots = slots + rowsOf(tab.slots, ent, prefix .. i, p)
		end
	end
	return slots
end

local function count(p)
	local n = 0
	for _ in pairs(p.conts) do n = n + 1 end
	return n
end

M.PSS_Provide("wh.import", function(_, opts)
	local out = { cols = { "kind", "name", "conts", "slots", "skipped" }, n = 0 }
	local api = rawget(_G, "Syndicator")
	if type(api) == "table" and api.PSS_SHIM then api = nil end		-- our own shim is not Syndicator
	api = type(api) == "table" and api.API
	if not (api and api.GetAllCharacters) then
		M.ShowMsg("Syndicator is not loaded, so there is nothing to import.")
		return out
	end
	local dry = opts and opts.dry
	local function done(kind, name, p, slots, skipped)
		out.n = out.n + 1
		out[out.n] = { kind, name, p and count(p) or 0, slots or 0, skipped or 0 }
	end
	local function write(p)
		local r, err = M.PSS_Call("wh.write", p)
		return r ~= nil and not err
	end
	local ok, names = pcall(api.GetAllCharacters)
	for _, full in ipairs(ok and type(names) == "table" and names or {}) do
		local good, c = pcall(api.GetCharacter, full)
		local d = good and type(c) == "table" and c.details
		if not (d and d.character) then
			done("c", tostring(full), nil, 0, 1)
		else
			local ent
			if not dry then
				ent = M.PSS_EntityId("c", d.character, d.realm, true)
				if ent and M.PSS_EntitySetInfo then M.PSS_EntitySetInfo(ent, { faction = d.faction, class = d.className, race = d.race, sex = d.sex }) end
			end
			local p = newPayload()
			local slots = character(c, ent or 0, p)
			if ent and write(p) then
				if M.PSS_MoneyPut and tonumber(c.money) then M.PSS_MoneyPut(ent, tonumber(c.money)) end
				done("c", full, p, slots, 0)
			elseif dry then
				done("c", full, p, slots, 0)
			else
				done("c", full, nil, 0, 1)
			end
		end
	end
	local gok, gnames = pcall(api.GetAllGuilds or function() return {} end)
	for _, full in ipairs(gok and type(gnames) == "table" and gnames or {}) do
		local good, g = pcall(api.GetGuild, full)
		local d = good and type(g) == "table" and g.details
		if not (d and d.guild) then
			done("g", tostring(full), nil, 0, 1)
		else
			local ent = not dry and M.PSS_EntityId("g", d.guild, d.realm, true) or nil
			local p = newPayload()
			local slots = tabs(g.bank, "t", ent or 0, p)
			if (ent and write(p)) or dry then
				if ent and M.PSS_MoneyPut and tonumber(g.money) then M.PSS_MoneyPut(ent, tonumber(g.money)) end
				done("g", full, p, slots, 0)
			else
				done("g", full, nil, 0, 1)
			end
		end
	end
	if api.GetWarband then
		local good, wb = pcall(api.GetWarband, 1)
		if good and type(wb) == "table" then
			local ent = not dry and M.PSS_EntityId("w", "Warband", "", true) or nil
			local p = newPayload()
			local slots = tabs(wb.bank, "w", ent or 0, p)
			if (ent and write(p)) or dry then
				if ent and M.PSS_MoneyPut and tonumber(wb.money) then M.PSS_MoneyPut(ent, tonumber(wb.money)) end
				done("w", "Warband", p, slots, 0)
			else
				done("w", "Warband", nil, 0, 1)
			end
		end
	end
	if not dry and M.PSS_RequestGC then M.PSS_RequestGC("import") end
	return out
end, { returns = { "kind", "name", "conts", "slots", "skipped" }, doc = "copies Syndicator's data into the Warehouse, read only", cost = "O(slots)", writes = true, onError = "empty" })
