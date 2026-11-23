------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE INDEX WRITER (search-helper, STP-00235). The one
-- way a line reaches a Spyglass index, from always-loaded code:
--   M.PSS_IxPut(index, st, rec)   true, or nil and "arg" | "secret" | "off"
--   M.PSS_IxHot(index, clear)     the hot lines (read only); clear empties them (Logging loaded)
--   M.PSS_IxStats                 { put, secret, off, dropped }
--   M.PSS_IxWaiting[index]        true while an alert waits on the index (only then a put signals)
-- rec is a flat table { time?, ent?, <field> = value }. Every value goes
-- through M.PSS_IsSecret before any other use; a secret anywhere writes
-- nothing. A hot line is "<time>\t<st>\t<ent>\t<field>=<value>..." with
-- plain escaped strings (no dictionary); Libraries re-encodes it when it
-- seals it into a segment store. Hot buffers: log 200 (runtime: the outbox
-- saves those lines), pss 50 (saved as PourSocialScoreDB.pssHot), jrn and
-- whh 100. The writer counts nothing a caller counts: a refused line never
-- changes a block count. No frame, no event, no timer.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, tostring = type, pairs, tostring
local gsub, concat, remove = string.gsub, table.concat, table.remove

local hot, early = {}, {}
local stats = { put = 0, secret = 0, off = 0, dropped = 0 }
M.PSS_IxStats, M.PSS_IxWaiting = stats, {}

local function esc(v)
	return (gsub(gsub(gsub(gsub(tostring(v), "%%", "%%25"), "\t", "%%09"), "\n", "%%0A"), "=", "%%3D"))
end

-- the pss ring lives in the save once it is routed (the early lines join it); before that a runtime list
function M.PSS_IxHot(index, clear)
	local db = PourSocialScoreDB
	if index ~= "pss" then
		if clear then hot[index] = nil end
		local b = hot[index]
		if not b and not clear then b = {}; hot[index] = b end
		return b or early
	end
	if type(db) ~= "table" then return early end
	if clear then rawset(db, "pssHot", nil); early = {} return early end
	local b = rawget(db, "pssHot")
	if type(b) ~= "table" then b = {}; rawset(db, "pssHot", b) end
	for i = 1, #early do b[#b + 1] = early[i] end
	early = {}
	return b
end

function M.PSS_IxPut(index, st, rec)
	-- caps: log 200, pss 50, jrn and whh 100; gates: log Event Logging, jrn and whh the journal, pss none
	local cap = index == "log" and 200 or index == "pss" and 50 or (index == "jrn" or index == "whh") and 100
	if type(st) ~= "string" or type(rec) ~= "table" or not cap then return nil, "arg" end
	local isSecret = M.PSS_IsSecret
	for k, v in pairs(rec) do
		if isSecret(v) or isSecret(k) then stats.secret = stats.secret + 1 return nil, "secret" end
	end
	local gate = index == "log" and "logging" or cap == 100 and "journal"
	if gate and not M.PSS_On(gate) then stats.off = stats.off + 1 return nil, "off" end
	local ent = rec.ent or (M.PSS_Me and M.PSS_Me(false)) or 0
	local parts = { tostring(rec.time or GetServerTime()), st, tostring(ent) }
	for k, v in pairs(rec) do
		if k ~= "time" and k ~= "ent" then parts[#parts + 1] = esc(k) .. "=" .. esc(v) end
	end
	local buf = M.PSS_IxHot(index)
	if #buf >= cap then
		if M.PSS_IxFlush and cap == 100 then M.PSS_IxFlush(index); buf = M.PSS_IxHot(index)		-- jrn, whh: sealed into their store
		else remove(buf, 1); stats.dropped = stats.dropped + 1 end
	end
	buf[#buf + 1] = concat(parts, "\t")
	stats.put = stats.put + 1
	if M.PSS_IxWaiting[index] and M.PSS_Signal then M.PSS_Signal("@ix." .. index) end
	return true
end
