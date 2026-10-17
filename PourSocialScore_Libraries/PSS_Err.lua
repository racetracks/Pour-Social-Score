------------------------------------------------------------------------
-- POUR SOCIAL SCORE - SERVICE ERRORS (service-bus-helper, one-build plan
-- STP-p01, DEC-00274). One place that remembers what went wrong and keeps
-- it away from the player:
--   M.PSS_ErrNote(code, service, message)   a ring of the last 50 distinct errors
--   M.PSS_ErrFail(service, err)             a service call failed: ring, breaker
--   M.PSS_ErrOpen(service)                  true while the breaker is open
--   M.PSS_ErrSettle()                       half-opens every open breaker (called after a settle)
--   M.PSS_ErrRows()                         the ring as a record set (service err.rows)
-- Codes (the text of an error always starts with one: "<code>: <text>"):
--   arg cap secret newer fail integrity combat missing early
-- A secret never counts toward the breaker; 5 other failures open a service
-- for the session (half-open at the next settle, closed by one success).
-- Nothing is printed here: the red chat line belongs to M.PSS_NoteListenerError
-- and only shows with the showErrors option (or in the harness).
-- Loaded with Libraries. No frame, no event, no timer.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, pairs = type, tostring, pairs
local remove, concat = table.remove, table.concat

local CODES = { arg = true, cap = true, secret = true, newer = true, fail = true, integrity = true, combat = true, missing = true, early = true }
local LIMIT = 50		-- distinct errors kept
local BREAK = 5			-- failures that open a service

local ring, byKey = {}, {}		-- oldest first
local state = {}					-- [service] = { fails, open, half }
M.PSS_ERR_CODES = CODES

local function now()
	return GetServerTime and GetServerTime() or 0
end

-- "<code>: <text>" -> code, text; text without a known code prefix is a "fail"
local function split(err)
	err = tostring(err)
	local code, text = err:match("^(%a+): (.*)$")
	if code and CODES[code] then return code, text end
	return "fail", err
end
M.PSS_ErrSplit = split

function M.PSS_ErrNote(code, service, message)
	if not CODES[code] then code = "fail" end
	service, message = tostring(service), tostring(message)
	local key = code .. "\1" .. service .. "\1" .. message
	local e = byKey[key]
	local t = now()
	if e then
		e.count = e.count + 1
		e.last = t
		return e
	end
	if #ring >= LIMIT then
		local old = remove(ring, 1)
		byKey[old.key] = nil
	end
	e = { key = key, code = code, service = service, message = message, count = 1, first = t, last = t }
	ring[#ring + 1] = e
	byKey[key] = e
	return e
end

function M.PSS_ErrFail(service, err)
	local code, text = split(err)
	M.PSS_ErrNote(code, service, text)
	local s = state[service]
	if not s then s = { fails = 0 }; state[service] = s end
	if code ~= "secret" then
		s.fails = s.fails + 1
		if s.fails >= BREAK then s.open, s.half = true, false end
	end
	return code .. ": " .. text
end

-- a success closes a half-open breaker (and forgets its failures)
function M.PSS_ErrOk(service)
	local s = state[service]
	if s and s.half then s.open, s.half, s.fails = false, false, 0 end
end

-- true while the service must not be called; a half-open breaker lets one call through
function M.PSS_ErrOpen(service)
	local s = state[service]
	return s ~= nil and s.open == true and not s.half
end

-- the next settle after a breaker opened: let one call through
function M.PSS_ErrSettle()
	for _, s in pairs(state) do
		if s.open and not s.half then s.half = true end
	end
	if M.PSS_BusRetry then M.PSS_BusRetry() end		-- failed writes that asked for a retry
end

function M.PSS_ErrCount(service)
	local s = state[service]
	return s and s.fails or 0
end

function M.PSS_ErrRows()
	local set = { cols = { "code", "service", "message", "count", "first", "last" }, n = #ring }
	for i = 1, #ring do
		local e = ring[i]
		set[i] = { e.code, e.service, e.message, e.count, e.first, e.last }
	end
	return set
end

-- the plain lines /pss status prints
function M.PSS_ErrLines()
	local out = {}
	for i = 1, #ring do
		local e = ring[i]
		out[#out + 1] = e.code .. " " .. e.service .. " x" .. e.count .. ": " .. e.message
	end
	for name, s in pairs(state) do
		if s.open then out[#out + 1] = "breaker open: " .. name .. (s.half and " (half-open)" or "") end
	end
	return out
end

function M.PSS_ErrReset()
	ring, byKey, state = {}, {}, {}
end

-- /pss status: what went wrong this session, in plain lines
function M.PSS_StatusCommand()
	local lines = M.PSS_ErrLines()
	if #lines == 0 then
		M.ShowMsg("Status: no errors this session.")
	else
		M.ShowMsg("Status: " .. #lines .. " line(s) this session.")
		for i = 1, #lines do M.ShowMsg(lines[i]) end
	end
	if M.PSS_UpgradeStatusLine then M.ShowMsg(M.PSS_UpgradeStatusLine()) end
end
