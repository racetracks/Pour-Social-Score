------------------------------------------------------------------------
-- POUR SOCIAL SCORE - /pss q AND EXPORT (search-helper, STP-00250). The
-- engine's one visible part in phase A:
--   /pss q <query>                 runs it (Logging loads: the command is the player's click) and prints
--                                  by shape: events up to 20 lines, a table up to 6 columns, a number
--   /pss q status                  each index: rows, bytes, on
--   /pss q export <query> [as pssio]   the answer as CSV (RFC 4180) or a PSSIO string, in the window's
--                                  copy box (the GUI loads for this command only)
--   /pss q alert <id> on|off       a saved query's alert
--   M.PSS_IxCsv(set) -> text       M.PSS_IxPssio(set) -> text    M.PSS_IxFromPssio(text) -> set | nil, err
-- Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, tonumber, ipairs, pairs = type, tostring, tonumber, ipairs, pairs
local find, gsub, format, rep, sub, match = string.find, string.gsub, string.format, string.rep, string.sub, string.match
local concat = table.concat

local C = M.PSS_Codec
local EVENTS, COLS = 20, 6
M.PSS_Q_LIMITS = { events = EVENTS, cols = COLS }

local function cell(v)
	if v == nil then return "" end
	if v == true then return "1" end
	if v == false then return "" end
	return tostring(v)
end

-- RFC 4180: a field with a comma, a quote or a line break is quoted, quotes doubled
local function csvField(v)
	local s = cell(v)
	if find(s, '[,"\r\n]') then s = '"' .. gsub(s, '"', '""') .. '"' end
	return s
end

function M.PSS_IxCsv(set)
	local lines = {}
	local head = {}
	for i, c in ipairs(set.cols) do head[i] = csvField(c) end
	lines[1] = concat(head, ",")
	for r = 1, set.n do
		local row, out = set[r], {}
		for i = 1, #set.cols do out[i] = csvField(row[i]) end
		lines[#lines + 1] = concat(out, ",")
	end
	return concat(lines, "\r\n")
end

-- PSSIO kind "sq": the columns, then each row, every field escaped
function M.PSS_IxPssio(set)
	local lines = { C.list(set.cols, "\t") }
	for r = 1, set.n do
		local row, out = set[r], {}
		for i = 1, #set.cols do
			local v = row[i]
			out[i] = type(v) == "number" and ("#" .. tostring(v)) or (v == nil and "" or ("s" .. cell(v)))
		end
		lines[#lines + 1] = C.list(out, "\t")
	end
	return M.PSS_IoPack("sq", 1, concat(lines, "\n"))
end
M.PSS_IoKinds.sq = true

function M.PSS_IxFromPssio(text)
	local kind, v, body = M.PSS_IoUnpack(text)
	if not kind then return nil, v end
	if kind ~= "sq" then return nil, "arg: not a Spyglass answer (" .. tostring(kind) .. ")" end
	if v > 1 then return nil, "newer: layout " .. v end
	local set = { n = 0 }
	for line in (body .. "\n"):gmatch("([^\n]*)\n") do
		local f = C.unlist(line, "\t")
		if not set.cols then set.cols = f
		elseif line ~= "" or #set.cols == 1 then
			local row = {}
			for i = 1, #set.cols do
				local x = f[i] or ""
				local tag = sub(x, 1, 1)
				if tag == "#" then row[i] = tonumber(sub(x, 2)) elseif tag == "s" then row[i] = sub(x, 2) else row[i] = nil end
			end
			set.n = set.n + 1
			set[set.n] = row
		end
	end
	set.cols = set.cols or {}
	return set
end

local function fmtTime(v) return M.PSS_Time and M.PSS_Time.fmt(v, "short") or tostring(v) end

local function pad(s, w)
	s = tostring(s)
	if #s >= w then return sub(s, 1, w) end
	return s .. rep(" ", w - #s)
end

-- the lines /pss q prints for an answer (a list, so the harness reads them)
function M.PSS_QLines(set, info)
	local out = {}
	local shape = info and info.shape or "events"
	local at = {}
	for i, c in ipairs(set.cols) do at[c] = i end
	if shape == "number" and set.n == 1 and #set.cols <= 2 then
		out[1] = tostring(set.cols[#set.cols]) .. " = " .. cell(set[1][#set.cols])
	elseif shape == "events" and at.time then
		for r = 1, math.min(set.n, EVENTS) do
			local row = set[r]
			local text = row[at.summary or at.message or at.label or 0] or row[at.raw or 0]
			out[#out + 1] = concat({ fmtTime(row[at.time]), cell(row[at.index or 0] or row[at.st or 0]), cell(row[at.owner or 0]), cell(text) }, "  ")
		end
		if set.n > EVENTS then out[#out + 1] = "... " .. (set.n - EVENTS) .. " more" end
	else
		local nc = math.min(#set.cols, COLS)
		local w = {}
		for i = 1, nc do w[i] = math.min(24, #tostring(set.cols[i])) end
		for r = 1, math.min(set.n, EVENTS) do
			for i = 1, nc do
				local v = set[r][i]
				local s = set.cols[i] == "time" and type(v) == "number" and fmtTime(v) or cell(v)
				if #s > w[i] then w[i] = math.min(24, #s) end
			end
		end
		local head = {}
		for i = 1, nc do head[i] = pad(set.cols[i], w[i]) end
		out[1] = concat(head, " | ") .. (#set.cols > COLS and (" | (+" .. (#set.cols - COLS) .. " columns)") or "")
		for r = 1, math.min(set.n, EVENTS) do
			local parts = {}
			for i = 1, nc do
				local v = set[r][i]
				parts[i] = pad(set.cols[i] == "time" and type(v) == "number" and fmtTime(v) or cell(v), w[i])
			end
			out[#out + 1] = concat(parts, " | ")
		end
		if set.n > EVENTS then out[#out + 1] = "... " .. (set.n - EVENTS) .. " more rows" end
	end
	if info then
		local foot = format("%d rows, %d scanned, %.1f ms", set.n, info.scanned or 0, info.ms or 0)
		if info.partial then foot = foot .. ", partial" end
		if info.needs then foot = foot .. ", needs " .. info.needs end
		if info.resolved then foot = foot .. "; " .. info.resolved end
		if info.ambiguous then foot = foot .. "; " .. info.ambiguous .. " items start with this: type more" end
		for _, n in ipairs(info.notes or {}) do foot = foot .. "; " .. n end
		out[#out + 1] = foot
	end
	return out
end

local function say(s) M.ShowMsg(s) end

local function status()
	local list = M.PSS_IxList()
	say("Spyglass indexes:")
	for i = 1, list.n do
		local r = list[i]
		local x = M.PSS_Ix(r[1])
		local bytes = (r[1] == "pss" and M.PSS_PssStore) and M.PSS_PssStore:size() or 0
		say(format("  %-8s %-5s rows %d%s %s", r[1], r[2], r[5], bytes > 0 and (", " .. bytes .. " bytes") or "", r[6] and "on" or ("|cff999999" .. (select(2, x:ready()) or "off") .. "|r")))
	end
	local s = M.PSS_IxStats
	say(format("  lines written %d, refused: secret %d, off %d; dropped %d", s.put, s.secret, s.off, s.dropped))
end

local function errLine(e)
	return "|cffff5555Spyglass: " .. tostring(e.code) .. ": " .. tostring(e.msg) .. " (at " .. tostring(e.pos) .. ")|r"
end

-- The chat edit box sends a typed | as || (its escape). PSQL has no || operator and a typed quoted value
-- arrives escaped too, so every || in the text is one typed pipe.
local function unpipe(s) return (gsub(s, "||", "|")) end

-- /pss q export: the GUI loads for this command only (a listed entry point, check_layers.lua)
function M.PSS_QExport(query)
	local pssio = false
	query = unpipe(query or "")
	local q = match(query, "^(.-)%s+as%s+pssio%s*$")
	if q then query, pssio = q, true end
	local set, info = M.PSS_Search(query, { load = true })
	if not set then say(errLine(info)) return nil end
	local text = pssio and M.PSS_IxPssio(set) or M.PSS_IxCsv(set)
	if M.PSS_Need("GUI") and M.PSS_CopyTextBox then
		M.PSS_CopyTextBox("Spyglass Export", format("%d rows as %s: copy the text below", set.n, pssio and "PSSIO" or "CSV"), text)
	end
	return text
end

function M.PSS_QCommand(rest)
	rest = gsub(rest or "", "^%s+", "")
	local word = match(rest, "^(%S+)")
	local lw = word and word:lower()
	if not word then
		say("Spyglass: /pss q <query> | status | export <query> [as pssio] | alert <id> on|off")
		return
	end
	if lw == "status" and rest:lower() == "status" then status() return end
	if lw == "export" then return M.PSS_QExport(match(rest, "^%S+%s*(.*)$")) end
	if lw == "alert" then
		local id, on = match(rest, "^%S+%s+(%d+)%s+(%a+)")
		if not id then say("Spyglass: /pss q alert <id> on|off") return end
		local ok, e = M.PSS_SqAlert(tonumber(id), on:lower() == "on")
		say(ok and ("Spyglass: alert " .. id .. " " .. on:lower()) or ("|cffff5555Spyglass: " .. tostring(e) .. "|r"))
		return
	end
	if lw == "bar" and rest:lower() == "bar" then
		local fn = M.PSS_ConsoleBarRaw or addon.ConsoleBarRaw
		local raw = fn and fn()
		say(raw and ("bar raw: " .. M.PSS_ConsoleView.pipe(raw)) or "bar raw: (Spyglass not opened)")
		return
	end
	local set, info = M.PSS_Search(unpipe(rest), { load = true })
	if not set then say(errLine(info)) return end
	for _, line in ipairs(M.PSS_QLines(set, info)) do say(line) end
	return set, info
end
