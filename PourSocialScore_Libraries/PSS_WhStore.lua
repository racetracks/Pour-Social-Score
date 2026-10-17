------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE WAREHOUSE STORE (warehouse-helper, one-build plan
-- STP-p09: W1, W2, W3). Every character's, guild's and the warband's
-- containers, saved account wide in PSS_WarehouseDB, one packed string per
-- container, written whole and checked (03_Design sections 5 to 7):
--   container = "1;n;sum;hash;body"   body = entry *( "," entry )
--   entry     = slot "." ref [ "." count ] [ "." flags ]     (count left out when 1)
--   ref       = item id (a plain item) | "x" dictionary id   (PSS_ItemDict.lua)
--   flags     = b bound, l has loot, t<time> expires at
-- Services (all return record sets; a failing one gives its policy set):
--   wh.write    ent, cont, slot, item, count, flags (+ .conts)   -> ent, cont, op   [writes]
--   wh.cont     ent, cont? -> ent, cont, slot, item, count, flags (the saved containers)
--   wh.delete   ent -> ent, done      wh.hide  ent -> ent, hidden   (opts.gold)
--   wh.status   -> ent, codes, slots, items, bad, seen
--   wh.sweep    opts.force -> freed, remapped, dropped
-- Functions: M.PSS_WhPack(rows, cont), M.PSS_WhUnpack(str, out, ent, cont),
-- M.PSS_WhStart(), M.PSS_WhStore (the map store of the containers).
-- A write builds the new strings, decodes them back, compares, and only then
-- assigns every string of the entity in one step; an unequal re-read writes
-- nothing and fires nothing; a failure keeps the changed keys for the next
-- settle (PSS_Watch.lua). WH_CHANGED carries the change set (ent, cont, op).
-- Syndicator loaded means the warehouse is off this session, said once.
-- The file returns at the top while the Warehouse and the Bag manager are off.
-- Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not (M.PSS_On("warehouse") or M.PSS_On("bags")) then return end

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local sort, concat = table.sort, table.concat
local floor = math.floor
local find, sub, match = string.find, string.sub, string.match

local C = M.PSS_Codec
local COLS = { "ent", "cont", "slot", "item", "count", "flags" }
local CAP = { m = 100, a = 400 }		-- entries kept per container: mail, auctions (oldest dropped first)

local ms = M.PSS_MapStore("wh.inv", { db = "PSS_WarehouseDB", key = "inv", bad = "bad", v = 1, cap = 500, badCap = 32 })
M.PSS_WhStore = ms

local function now() return GetServerTime and GetServerTime() or time() end

------------------------------------------------------------------------
-- Pack and unpack
------------------------------------------------------------------------
-- rows: { slot, key, count, flags } by slot; returns the container string, n, sum, or nil, why
function M.PSS_WhPack(rows)
	local list, sum = {}, 0
	local order = {}
	for i = 1, #rows do order[i] = rows[i] end
	sort(order, function(a, b) return a[1] < b[1] end)
	for i = 1, #order do
		local r = order[i]
		local ref, why = M.PSS_ItemRef(r[2], true)
		if not ref then return nil, why or ("fail: no ref for " .. tostring(r[2])) end
		local count, flags = r[3] or 1, r[4] or ""
		local e = r[1] .. "." .. ref
		if flags ~= "" then e = e .. "." .. (count ~= 1 and count or "") .. "." .. flags
		elseif count ~= 1 then e = e .. "." .. count end
		list[i] = e
		sum = sum + count
	end
	return C.header(concat(list, ","), #list, sum), #list, sum
end

-- appends the rows of a verified container string to `out` (a record set of COLS)
function M.PSS_WhUnpack(str, out, ent, cont)
	local ok, n, sum, body = C.check(str)
	if not ok then return nil, n end
	local k = 0
	local from = 1
	while from <= #body do
		local to = find(body, ",", from, true) or (#body + 1)
		local e = sub(body, from, to - 1)
		local slot, ref, count, flags = match(e, "^(%d+)%.([^.]+)%.?([^.]*)%.?(.*)$")
		local key = M.PSS_ItemUnref(ref)
		-- a row saved as item 0 by 3.7.0.107 (an empty slot) is kept in the save and never listed (F9)
		if not (key and tonumber(key:match("^%d+")) == 0) then
			out.n = out.n + 1
			out[out.n] = { ent, cont, tonumber(slot), key, count ~= "" and tonumber(count) or 1, flags or "" }
			k = k + 1
		end
		from = to + 1
	end
	return k
end

local function newSet() return { cols = COLS, n = 0 } end

-- the same slot content, whatever the order
local function sameRows(a, b)
	if a.n ~= b.n then return false end
	local by = {}
	for i = 1, a.n do by[a[i][3]] = a[i] end
	for i = 1, b.n do
		local x, y = by[b[i][3]], b[i]
		if not x or x[4] ~= y[4] or x[5] ~= y[5] or x[6] ~= y[6] then return false end
	end
	return true
end

------------------------------------------------------------------------
-- Entities: hidden flag, kind
------------------------------------------------------------------------
------------------------------------------------------------------------
-- wh.write
------------------------------------------------------------------------
-- the soonest-expiring entries of a capped container go first
local function capRows(code, rows)
	local cap = CAP[code:sub(1, 1)]
	if not cap or #rows <= cap then return rows, 0 end
	sort(rows, function(a, b)
		local ta, tb = tonumber(match(a[4] or "", "t(%d+)")) or 0, tonumber(match(b[4] or "", "t(%d+)")) or 0
		return ta > tb
	end)
	local kept = {}
	for i = 1, cap do kept[i] = rows[i] end
	return kept, #rows - cap
end

local function dropExpired(rows, t)
	local out, n = {}, 0
	for i = 1, #rows do
		local exp = tonumber(match(rows[i][4] or "", "t(%d+)"))
		if exp and exp <= t then n = n + 1 else out[#out + 1] = rows[i] end
	end
	return out, n
end

local changeCols = { "ent", "cont", "op" }

local function db() return rawget(_G, "PSS_WarehouseDB") end

local function seen(ent)
	local d = db()
	if d then
		d.seen = d.seen or {}
		d.seen[ent] = now()
	end
end

-- payload sets in, from a follower row ({ key } rows holding the leader's set) or a set direct
local function payloads(input)
	local list = {}
	if input.cols[1] == "key" then
		for i = 1, input.n do
			local p = input[i][1]
			if type(p) == "table" and p.cols then list[#list + 1] = p end
		end
	else
		list[1] = input
	end
	return list
end

M.PSS_Provide("wh.write", function(input)
	local out = { cols = changeCols, n = 0 }
	local t = now()
	local touched = {}
	local built = 0
	for _, p in ipairs(payloads(input)) do
		-- the rows of each container read, by entity and code
		local rowsBy = {}
		for i = 1, p.n do
			local r = p[i]
			local key = r[2]
			rowsBy[key] = rowsBy[key] or {}
			local list = rowsBy[key]
			list[#list + 1] = { r[3], r[4], r[5], r[6] }
		end
		local changes = {}		-- [ent] = { [code] = string | false }
		local ops = {}			-- [ent] = { [code] = "put" | "drop" }
		for code, ent in pairs(p.conts or {}) do
			if ent and ent ~= 0 and not (M.PSS_Entity and M.PSS_Entity(ent)) then
				-- F4: containers are saved only for an entity whose row is saved
				if M.PSS_ErrNote then M.PSS_ErrNote("arg", "wh.write", "unknown entity " .. tostring(ent) .. ": " .. code .. " not saved") end
			elseif ent and ent ~= 0 then
				local rows = rowsBy[code] or {}
				local capped, dropped = capRows(code, rows)
				if dropped > 0 and M.PSS_ErrNote then M.PSS_ErrNote("cap", "wh.write", code .. ": " .. dropped .. " oldest entries left out") end
				local kept = dropExpired(capped, t)
				local old = ms.Get(ent, code)
				if #kept == 0 then
					if old then changes[ent] = changes[ent] or {}; changes[ent][code] = false; ops[ent] = ops[ent] or {}; ops[ent][code] = "drop" end
				else
					local str, n, sum = M.PSS_WhPack(kept)
					if not str then error(n, 0) end
					built = built + 1
					local T = M.PSS_Test
					if T and T.buildFail and built >= T.buildFail then error("fail: injected fault after " .. built .. " strings were built", 0) end
					-- the decoded string must be the rows it came from
					local back = newSet()
					M.PSS_WhUnpack(str, back, ent, code)
					local want = newSet()
					for _, r in ipairs(kept) do want.n = want.n + 1; want[want.n] = { ent, code, r[1], r[2], r[3] or 1, r[4] or "" } end
					if not sameRows(back, want) then error("integrity: " .. code .. " did not decode to the rows it came from", 0) end
					if str ~= old then
						changes[ent] = changes[ent] or {}
						changes[ent][code] = str
						ops[ent] = ops[ent] or {}
						ops[ent][code] = "put"
					end
				end
			end
		end
		for ent, ch in pairs(changes) do
			local ok, why = ms.Put(ent, ch)
			if not ok then error(why, 0) end
			seen(ent)
			touched[ent] = true
			for code, op in pairs(ops[ent]) do
				out.n = out.n + 1
				out[out.n] = { ent, code, op }
			end
		end
	end
	-- guild tabs, bank tabs and the bags you carry are read again whenever their containers were read
	if M.PSS_WhMeta then
		for _, p in ipairs(payloads(input)) do
			local byEnt = {}
			for code, ent in pairs(p.conts or {}) do
				if ent and ent ~= 0 then byEnt[ent] = byEnt[ent] or {}; byEnt[ent][code] = true end
			end
			for ent, codes in pairs(byEnt) do
				local ok, why = pcall(M.PSS_WhMeta, ent, codes)		-- the notes beside a container never fail the write
				if not ok then M.PSS_ErrNote("fail", "wh.write", "meta: " .. tostring(why)) end
			end
		end
	end
	if out.n > 0 then
		if M.PSS_IndexDirty then
			local ids = {}
			for i = 1, out.n do ids[#ids + 1] = out[i][1] .. "." .. out[i][2] end		-- the containers that changed
			M.PSS_IndexDirty("wh.holders", ids)		-- before the event: a listener may ask at once
		end
		if M.Events and M.Events.Fire then M.Events.Fire("WH_CHANGED", out) end
	end
	return out
end, { accepts = COLS, returns = changeCols, doc = "writes the read containers: verify, then swap", cost = "O(slots)", writes = true, retry = 1,
	critical = true, onError = "empty" })

------------------------------------------------------------------------
-- wh.cont
------------------------------------------------------------------------
M.PSS_Provide("wh.cont", function(input, opts)
	local out = newSet()
	local ci = M.PSS_SetCol(input, "cont")
	for i = 1, input.n do
		local ent = input[i][1]
		if type(ent) == "number" then
			local wantCode = ci and input[i][ci] or (opts and opts.cont)
			for _, code in ipairs(ms.Codes(ent)) do
				if not wantCode or wantCode == code then
					local str = ms.Get(ent, code)
					if str then M.PSS_WhUnpack(str, out, ent, code) end
				end
			end
		end
	end
	return out
end, { accepts = { "ent" }, returns = COLS, doc = "the saved containers of an entity", cost = "O(slots)", writes = false, onError = "empty",
	ver = function() return ms.Ver() end })

------------------------------------------------------------------------
-- wh.delete, wh.hide, wh.status
------------------------------------------------------------------------
M.PSS_Provide("wh.delete", function(input)
	local out = { cols = { "ent", "done" }, n = 0 }
	local me = M.PSS_Me and M.PSS_Me(false)
	for i = 1, input.n do
		local ent = input[i][1]
		if ent == me then
			error("arg: the character you are playing cannot be removed", 0)
		end
		local d = db()
		local kind = M.PSS_Entity(ent)
		kind = kind and kind[1] and kind[1][2]
		local codes = ms.Codes(ent)
		local ch = {}
		for _, code in ipairs(codes) do ch[code] = false end
		if next(ch) then ms.Put(ent, ch) end
		if d then
			for _, key in ipairs({ "meta", "cur", "gold", "seen" }) do if d[key] then d[key][ent] = nil end end
			if d.bad then d.bad[ent] = nil end
			if M.PSS_WhCurBump then M.PSS_WhCurBump() end
		end
		ms.Drop(ent)
		M.PSS_EntityRemove(ent)
		out.n = out.n + 1
		out[out.n] = { ent, true }
		if M.Events and M.Events.Fire then M.Events.Fire("WH_DELETED", { cols = { "ent", "kind" }, n = 1, { ent, kind or "c" } }) end
	end
	return out
end, { accepts = { "ent" }, returns = { "ent", "done" }, doc = "forgets an entity and everything saved for it", cost = "O(containers)", writes = true, onError = "empty" })

M.PSS_Provide("wh.hide", function(input, opts)
	local out = { cols = { "ent", "hidden" }, n = 0 }
	for i = 1, input.n do
		local ent = input[i][1]
		local flag = M.PSS_EntitySetFlags and M.PSS_EntitySetFlags(ent, "h", opts and opts.gold and "g" or nil, opts and opts.show)
		out.n = out.n + 1
		out[out.n] = { ent, flag and true or false }
	end
	return out
end, { accepts = { "ent" }, returns = { "ent", "hidden" }, doc = "hides an entity from tooltips, search and the Syndicator view; its data is kept", cost = "O(1)", writes = true, onError = "empty" })

M.PSS_Provide("wh.status", function()
	local out = { cols = { "ent", "codes", "slots", "items", "bad", "seen" }, n = 0 }
	local d = db()
	for _, ent in ipairs(ms.Ents()) do
		local codes, slots, items = {}, 0, 0
		for _, code in ipairs(ms.Codes(ent)) do
			codes[#codes + 1] = code
			local str = d.inv[ent][code]
			local _, n, sum = str:match("^(%d+);(%d+);(%d+);")
			slots = slots + (tonumber(n) or 0)
			items = items + (tonumber(sum) or 0)
		end
		local bad = 0
		for _ in pairs(ms.Bad(ent)) do bad = bad + 1 end
		out.n = out.n + 1
		out[out.n] = { ent, concat(codes, ","), slots, items, bad, d.seen and d.seen[ent] or 0 }
	end
	return out
end, { returns = { "ent", "codes", "slots", "items", "bad", "seen" }, doc = "what is saved per entity", cost = "O(entities)", writes = false, onError = "empty" })

------------------------------------------------------------------------
-- The holders of refs: the sweep frees unused dictionary ids and rewrites them on compaction
------------------------------------------------------------------------
local function eachString(fn)
	local d = db()
	if not d then return end
	for _, key in ipairs({ "inv", "bad" }) do
		local t = d[key]
		if type(t) == "table" then
			for ent, codes in pairs(t) do
				for code, str in pairs(codes) do
					if type(str) == "string" then fn(key, ent, code, str) end
				end
			end
		end
	end
end

local function refsOf(str, add)
	for ref in str:gmatch("%.(x%d+)") do add(ref) end
end

M.PSS_ItemRefs("inv", { used = function(add) eachString(function(_, _, _, str) refsOf(str, add) end) end,
	remap = function(map)
		local d = db()
		local plan = {}
		local ok = true
		eachString(function(key, ent, code, str)
			local bad = false
			local new = str:gsub("(%.)x(%d+)", function(dot, n)
				local m = map[tonumber(n)]
				if not m then bad = true return dot .. "x" .. n end
				return dot .. "x" .. m
			end)
			if bad then ok = false return end
			if new ~= str then
				local head = new:match("^(%d+;%d+;%d+;)")
				local newBody = new:match("^%d+;%d+;%d+;%d+;(.*)$")
				plan[#plan + 1] = { key, ent, code, head .. C.hash(newBody) .. ";" .. newBody }
			end
		end)
		if not ok then return false end
		return function()
			for _, p in ipairs(plan) do d[p[1]][p[2]][p[3]] = p[4] end
			ms.Drop()
			ms.Bump()		-- the holders index was built on the old ids
			if M.PSS_IndexDrop then M.PSS_IndexDrop("wh.holders") end
		end
	end })

M.PSS_SWEEP_BUDGET = 3000000		-- bytes of saved containers a logout sweep may read (PB-04); over it, the sweep waits for /pss wh sweep

M.PSS_Provide("wh.sweep", function(_, opts)
	local out = { cols = { "freed", "remapped", "dropped" }, n = 1 }
	if not (opts and opts.force) then
		local bytes = 0
		eachString(function(_, _, _, str) bytes = bytes + #str end)
		if bytes > M.PSS_SWEEP_BUDGET then
			M.PSS_ErrNote("cap", "wh.sweep", "skipped at logout: " .. bytes .. " bytes of containers is over the budget")
			out[1] = { 0, 0, 0 }
			return out
		end
	end
	local freed, remapped, dropped = M.PSS_ItemSweep(opts and opts.force)
	out[1] = { freed or 0, remapped or 0, dropped or 0 }
	return out
end, { returns = { "freed", "remapped", "dropped" }, doc = "frees unused item ids, compacts past 25% free", cost = "O(strings)", writes = true, retry = 1, onError = "empty" })

------------------------------------------------------------------------
-- Start: the trigger rows come from the registry
------------------------------------------------------------------------
local function validEvents(list)
	local f = C_EventUtils and C_EventUtils.IsEventValid
	if not f then return list end
	local out = {}
	for _, e in ipairs(list) do if f(e) then out[#out + 1] = e end end
	return out
end

local started
local said

function M.PSS_WhStart()
	if started then return end
	started = true
	local synd = (C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded)("Syndicator")
	local warehouse = M.PSS_On("warehouse") and not synd
	if synd and M.PSS_On("warehouse") and not said then
		said = true
		M.ShowMsg("Syndicator is loaded, so the Warehouse is off this session. /pss wh import copies its data.")
	end
	M.PSS_WhOn = warehouse
	for _, row in ipairs(M.PSS_WH_CONTAINERS) do
		if row.has() and (row.gate == "bags" or warehouse) then
			M.PSS_Trigger({ id = "item." .. row.kind, gate = row.gate == "bags" and "items" or "warehouse", on = validEvents(row.events),
				settle = type(row.settle) == "table" and validEvents(row.settle) or row.settle, reads = row.reads, run = "item.live", key = M.PSS_ItemKeyFn(row) })
			if warehouse then
				M.PSS_Trigger({ id = "wh." .. row.kind, gate = "warehouse", on = { "@item." .. row.kind }, settle = "now", run = "wh.write",
					key = function(_, set) return set end })
			end
		end
	end
	-- the first read of everything that can be read without a window, once the world is up
	M.PSS_Trigger({ id = "item.first", gate = "items", on = { "PLAYER_ENTERING_WORLD" }, settle = "now", run = "item.live", key = function() return "*" end })
	if warehouse then
		M.PSS_Trigger({ id = "wh.first", gate = "warehouse", on = { "@item.first" }, settle = "now", run = "wh.write", key = function(_, set) return set end })
		M.PSS_Trigger({ id = "wh.sweep", gate = "warehouse", on = { "PLAYER_LOGOUT" }, settle = "now", run = "wh.sweep" })
		M.PSS_WhExpire()
	end
	if M.PSS_WhStartMore then M.PSS_WhStartMore(warehouse) end
end

-- mail and auction entries past their time are dropped at login, for every character
function M.PSS_WhExpire()
	local t = now()
	for _, ent in ipairs(ms.Ents()) do
		local ch
		for _, code in ipairs(ms.Codes(ent)) do
			local k = code:sub(1, 1)
			if k == "m" or k == "a" then
				local str = ms.Get(ent, code)
				if str then
					local rows = newSet()
					M.PSS_WhUnpack(str, rows, ent, code)
					local list = {}
					for i = 1, rows.n do list[i] = { rows[i][3], rows[i][4], rows[i][5], rows[i][6] } end
					local kept, n = dropExpired(list, t)
					if n > 0 then
						ch = ch or {}
						ch[code] = #kept == 0 and false or M.PSS_WhPack(kept)
					end
				end
			end
		end
		if ch then ms.Put(ent, ch) end
	end
end

-- the start, run once at PLAYER_LOGIN by the core row whboot
M.PSS_Provide("wh.boot", function(set)
	if M.PSS_TriggerOff then M.PSS_TriggerOff("whboot") end
	M.PSS_WhStart()
	return set
end, { accepts = { "key" }, returns = { "key" }, doc = "starts the warehouse once every addon has loaded", cost = "O(registry)", writes = false, onError = "empty" })
