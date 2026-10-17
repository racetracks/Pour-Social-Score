------------------------------------------------------------------------
-- POUR SOCIAL SCORE - TRIGGER ROWS (service-bus-helper, DDS-00010
-- section 7, STP-00095 and STP-00126). The core part of the trigger
-- helper: a row says "when these client events (or our own signals)
-- change something, mark what changed, and on the settle event call this
-- service once with the changed keys".
--   M.PSS_Trigger({ id, gate, on = { "BAG_UPDATE", "@sig" },
--       settle = { "BAG_UPDATE_DELAYED" } | "now" | "pull",
--       run = "wh.bags", key = function(event, ...) return key end,
--       reads = { "service" } })
-- Nothing registers, and no frame exists, until a row's gate is on
-- (M.PSS_On) and M.PSS_WatchStart has run. One plain event frame serves
-- every row; an event is registered by reference count. No OnUpdate and
-- no timer here (the engine clock is in PSS_Trig.lua, Libraries). A flush
-- loads Libraries and calls the service with the keys as a record set;
-- the service's output set raises "@<row id>" for the rows that follow it.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, next, pairs, pcall, select = type, next, pairs, pcall, select

local rows = {}				-- declared rows, in order
local live = {}				-- [id] = row, enabled
local dirty = {}			-- [id] = { [key] = true }, one reused table per row
local byEvent = {}			-- [client event] = { id, ... } (marks) / "!id" (settles)
local bySignal = {}			-- ["@name"] = { id, ... }
local byService = {}		-- [service] = { id, ... } (pull)
local refs = {}				-- [client event] = how many live rows need it
local src					-- the one event frame, made with the first registration
local started = false

local function index(map, k, v)
	local t = map[k]
	if not t then t = {}; map[k] = t end
	t[#t + 1] = v
end

local function need(e)
	local n = (refs[e] or 0) + 1
	refs[e] = n
	if not src then
		src = CreateFrame("Frame")
		src:SetScript("OnEvent", M.PSS_WatchEvent)
	end
	src:RegisterEvent(e)
end

-- A change is forgotten only after the service took it (one-build plan
-- STP-p05, ISS-p01): Libraries load first, the keys are cleared one by one
-- after the call returned without an error. A failed load or a failed
-- service keeps every key; the next settle (or the next pull) writes them.
-- The output set raises "@<row id>", so a second reader (the bag window, Drop
-- Cheapest Thing, a journal monitor) follows the one settled read.
local function flush(id)
	local d = dirty[id]
	if not d or not next(d) then return end
	local row = live[id]
	local set = { cols = { "key" }, n = 0 }
	for k in pairs(d) do
		local n = set.n + 1
		set.n = n
		set[n] = { k }
	end
	local out, err = true, true
	if M.PSS_Need("Libraries") then
		M.PSS_InRow = true		-- the bus does not retry this call: the row keeps its keys
		out, err = M.PSS_Call(row.run, set)
		M.PSS_InRow = nil
		M.PSS_ErrSettle()		-- a settle half-opens open breakers and runs waiting retries
	end
	if err then		-- the keys stay, at most 1000 (PB-13)
		for i = 1001, set.n do d[set[i][1]] = nil end
		return
	end
	for i = 1, set.n do d[set[i][1]] = nil end
	if out then M.PSS_Signal("@" .. id, out) end
	return out
end

local function mark(id, e, ...)
	local row = live[id]
	local k = e
	if row.key then k = row.key(e, ...) end
	if type(k) ~= "nil" and (type(k) == "table" or not (M.PSS_IsSecret and M.PSS_IsSecret(k))) then
		dirty[id][k] = true
	end
	if row.settle == "now" then flush(id) end
end

local function enable(row)
	if live[row.id] or (row.gate and not M.PSS_On(row.gate)) then return end
	live[row.id] = row
	dirty[row.id] = {}
	for i = 1, #row.on do
		local e = row.on[i]
		if e:sub(1, 1) == "@" then
			index(bySignal, e, row.id)
		else
			index(byEvent, e, row.id)
			need(e)
		end
	end
	if type(row.settle) == "table" then
		for i = 1, #row.settle do
			index(byEvent, row.settle[i], "!" .. row.id)
			need(row.settle[i])
		end
	end
	for i = 1, #(row.reads or {}) do index(byService, row.reads[i], row.id) end
end

-- take a row down for good (a one-shot row after it has run): its events are
-- released, so nothing stays registered for it
function M.PSS_TriggerOff(id)
	local row = live[id]
	if not row then return end
	live[id] = nil
	dirty[id] = nil
	local settle = "!" .. id
	for e, t in pairs(byEvent) do
		for i = #t, 1, -1 do
			if t[i] == id or t[i] == settle then
				table.remove(t, i)
				refs[e] = refs[e] - 1
				if refs[e] <= 0 then refs[e] = nil; src:UnregisterEvent(e) end
			end
		end
	end
	for _, map in pairs({ bySignal, byService }) do
		for _, t in pairs(map) do
			for i = #t, 1, -1 do if t[i] == id then table.remove(t, i) end end
		end
	end
	for i = #rows, 1, -1 do if rows[i] == row then table.remove(rows, i) end end
end

-- declare a row; it goes live now when the watch has started, else at start
function M.PSS_Trigger(row)
	if type(row) ~= "table" or type(row.id) ~= "string" or type(row.run) ~= "string" or type(row.on) ~= "table" then return end
	rows[#rows + 1] = row
	if started then enable(row) end
end

-- once per session, after the Enabled components are read (PSS_StartComponents)
function M.PSS_WatchStart()
	started = true
	for i = 1, #rows do enable(rows[i]) end
end

-- the one event handler: settle events flush, the others mark
function M.PSS_WatchEvent(_, e, ...)
	local ids = byEvent[e]
	if not ids then return end
	for i = 1, #ids do
		local id = ids[i]
		if id:byte(1) == 33 then flush(id:sub(2)) else mark(id, e, ...) end
	end
end

-- our own acts wake the rows that list "@name"
function M.PSS_WatchSignal(name, set)
	local ids = bySignal[name]
	if not ids then return end
	for i = 1, #ids do mark(ids[i], name, set) end
end

-- a reader settles its rows before it answers (M.PSS_Call asks here first)
function M.PSS_WatchPull(service)
	local ids = byService[service]
	if not ids then return end
	for i = 1, #ids do flush(ids[i]) end
end

-- the declared rows, whether each is live and the changes waiting (read by M.PSS_Triggers and the Syndicator shim)
function M.PSS_WatchRows()
	return rows, live, dirty
end
