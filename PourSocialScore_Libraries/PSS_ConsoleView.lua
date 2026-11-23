------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE SPYGLASS CONSOLE'S MODELS (search-helper, phase B)
-- Logic for the console's views; the GUI folder only draws what these return.
--   M.PSS_QV_EVENTS                 index name -> the core event that says it changed
--   M.PSS_ChartSpec(shape, want, set)   the chart a result shape gets
--   M.PSS_QueryViewModel(o)         vm:SetQuery, Run, Status, Text, Events, Drop
-- Loads on demand with the Libraries folder; nothing registers or runs at load.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, tonumber, ipairs, pcall, setmetatable = type, tostring, tonumber, ipairs, pcall, setmetatable
local format = string.format

local CV = M.PSS_ConsoleView or {}
M.PSS_ConsoleView = CV

M.PSS_QV_EVENTS = { log = "HISTORY_CHANGED", inv = "WH_CHANGED", jrn = "JRN_CHANGED" }

local ALLOWED = {
	events = {}, table = { bar = true, donut = true, table = true },
	series = { column = true, line = true, area = true, table = true },
	matrix = { heat = true, table = true }, number = { number = true },
}

local function numericCols(set)
	local row, n = set[1], 0
	if not row then return 0 end
	for i = 2, #set.cols do if type(row[i]) == "number" then n = n + 1 end end
	return n
end

function M.PSS_ChartSpec(shape, want, set)
	local allowed = shape and ALLOWED[shape]
	if want and allowed and allowed[want.kind] then return want end
	local cols = set and set.cols or {}
	if shape == "series" then
		return { kind = #cols > 2 and "line" or "column", x = cols[1] }
	elseif shape == "table" then
		return { kind = (set and numericCols(set) == 1) and "bar" or "table" }
	elseif shape == "matrix" then
		return { kind = (cols[1] == "weekday" and cols[2] == "hour") and "heat" or "table" }
	elseif shape == "number" then
		return { kind = "number" }
	end
	return { kind = "table" }
end

local VM = {}
VM.__index = VM

function M.PSS_QueryViewModel(o)
	return setmetatable({ o = o or {}, state = "idle", loaded = false }, VM)
end

function VM:SetQuery(text, params)
	self.query, self.params = text, params
	self.err, self.set, self.info, self.chart = nil, nil, nil, nil
	self.state, self.loaded = "idle", false
	self.plan = nil
	if type(text) == "string" then
		local ok, plan, e = pcall(M.PSS_Psql.compile, text)
		if ok and plan then self.plan = plan
		else
			self.err = (ok and type(e) == "table" and e) or { code = "parse", pos = 1, msg = ok and "invalid query" or tostring(plan) }
		end
	end
end

function VM:Run(load, range)
	if range and CV.typedTime(self.query) then range = nil end
	self.loaded = self.loaded or load == true
	self.state = "running"
	local ok, set, info = pcall(M.PSS_Search, self.query, {
		params = self.params, load = self.loaded or nil,
		from = range and range.earliest, to = range and range.latest,
		rows = self.o.rows or 500, reuse = self.set,
	})
	if not ok or not set then
		local e = (not ok) and { code = "lua", pos = 1, msg = tostring(set) }
			or (type(info) == "table" and info) or { code = "lua", pos = 1, msg = "no result" }
		self.err = { code = e.code, pos = e.pos, msg = e.msg }
		self.state = "error"
		self.set, self.info, self.chart = nil, nil, nil
		return
	end
	self.err = nil
	self.set, self.info = set, info
	if info.needs and not self.loaded then self.state = "needsload"
	elseif info.partial then self.state = "partial"
	else self.state = "shown" end
	local okC, spec = pcall(M.PSS_ChartSpec, info.shape, self.plan and self.plan.chart, set)
	self.chart = okC and spec or { kind = "table" }
	self.chart.pending = info.pending or nil
end

function VM:Status()
	if self.state == "needsload" then return "History not loaded" end
	if self.state == "error" then
		local e = self.err or {}
		return format("Error: %s (at %s)", tostring(e.msg), tostring(e.pos))
	end
	if not self.set then return "" end
	local n = self.set.n or 0
	local s = n == 1 and "1 line" or format("%d lines", n)
	if self.state == "partial" then s = s .. ", partial" end
	local q = self.query or ""
	local H = M.PSS_History
	if H and q:find("index=log", 1, true) and not q:find("| head", 1, true) and #H.Log() >= H.Cap() then
		s = s .. ", history holds the newest " .. H.Cap() .. " lines"
	end
	return s, format("%.2f ms", (self.info and self.info.ms) or 0)
end

-- one value as a query literal: a number as is, anything else quoted
local function quote(v)
	if type(v) == "number" then return tostring(v) end
	return '"' .. tostring(v):gsub("[\\\"]", "\\%0") .. '"'
end

-- the plan's text with each $name put in as one quoted literal (plan:text() keeps the $name)
function VM:Text()
	if not self.plan then return nil end
	local text = self.plan:text()
	local params = self.params
	if not params or not text then return text end
	return (text:gsub("%$([%a_][%w_]*)", function(name)
		local v = params[name]
		if v == nil then return nil end
		return quote(v)
	end))
end

function VM:Events()
	local out, seen = {}, {}
	local names = self.plan and self.plan:indexNames()
	for _, n in ipairs(names or {}) do
		local ev = M.PSS_QV_EVENTS[n]
		if ev and not seen[ev] then seen[ev] = true; out[#out + 1] = ev end
	end
	return out
end

function VM:Drop()
	self.set, self.info = nil, nil
	self.state = "idle"
end

------------------------------------------------------------------------
-- Time picker (STP-00288): presets, the range a choice means, month grid
--   CV.PRESETS  CV.pickerRange(choice, now) -> earliest, latest, label, term | nil, pos, msg
--   CV.typedTime(text)  CV.monthGrid(y, m) -> offset, days   CV.monthStep(y, m, k) -> y2, m2
------------------------------------------------------------------------
local T = M.PSS_Time
local date = date or os.date

CV.PRESETS = {
	{ key = "last15m", text = "Last 15 minutes", e = "-15m" },
	{ key = "last60m", text = "Last 60 minutes", e = "-60m" },
	{ key = "last4h", text = "Last 4 hours", e = "-4h" },
	{ key = "last24h", text = "Last 24 hours", e = "-24h" },
	{ key = "last7d", text = "Last 7 days", e = "-7d" },
	{ key = "last30d", text = "Last 30 days", e = "-30d" },
	{ key = "today", text = "Today", e = "@d" },
	{ key = "yesterday", text = "Yesterday", e = "-1d@d", l = "@d" },
	{ key = "thisweek", text = "This week", e = "@w" },
	{ key = "lastweek", text = "Last week", e = "-1w@w", l = "@w" },
	{ key = "thismonth", text = "This month", e = "@mon" },
	{ key = "lastmonth", text = "Last month", e = "-1mon@mon", l = "@mon" },
	{ key = "all", text = "All time" },
}

local UNIT_WORD = { m = "minutes", h = "hours", d = "days", w = "weeks", mon = "months" }
local SNAP_WORD = { d = "day", w = "week", mon = "month" }

local function stamp(t) return date("%Y-%m-%dT%H:%M", t) end

-- one end of a date range: "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM"
local function endTime(text, isTo, now)
	if type(text) ~= "string" or text == "" then return nil, 1, "a date is needed" end
	if isTo and not text:find("T", 1, true) then
		local t, pos, msg = T.parse(text .. "T23:59", now)
		if not t then return nil, pos, msg end
		return t + 60
	end
	return T.parse(text, now)
end

function CV.pickerRange(choice, now)
	now = now or T.now()
	choice = choice or {}
	if choice.preset then
		for _, r in ipairs(CV.PRESETS) do
			if r.key == choice.preset then
				if not r.e then return nil, nil, r.text, "" end
				local e = T.parse(r.e, now)
				local l = r.l and T.parse(r.l, now) or now
				return e, l, r.text, "earliest=" .. r.e .. (r.l and (" latest=" .. r.l) or "")
			end
		end
		return nil, 1, "no such preset"
	elseif choice.relative then
		local n = tonumber(choice.n)
		if not n or n ~= math.floor(n) or n < 1 or n > 9999 then return nil, 1, "a whole number 1 to 9999" end
		local unit, snap = choice.unit, choice.snap
		if not UNIT_WORD[unit] then return nil, 1, "unit m, h, d, w or mon" end
		if snap and not SNAP_WORD[snap] then return nil, 1, "snap d, w or mon" end
		local txt = format("-%d%s%s", n, unit, snap and ("@" .. snap) or "")
		local e, pos, msg = T.parse(txt, now)
		if not e then return nil, pos, msg end
		local label = format("Last %d %s", n, UNIT_WORD[unit]) .. (snap and (", from start of " .. SNAP_WORD[snap]) or "")
		return e, now, label, "earliest=" .. txt
	elseif choice.between or choice.before or choice.since then
		local e, l, pos, msg
		if not choice.before then
			e, pos, msg = endTime(choice.from, false, now)
			if not e then return nil, pos, msg end
		end
		if not choice.since then
			l, pos, msg = endTime(choice.to, true, now)
			if not l then return nil, pos, msg end
		end
		if e and l and e > l then return nil, 1, "the start is after the end" end
		local label = choice.between and (choice.from .. " to " .. choice.to)
			or choice.before and ("Before " .. choice.to) or ("Since " .. choice.from)
		local term = (e and ("earliest=" .. stamp(e)) or "") .. ((e and l) and " " or "") .. (l and ("latest=" .. stamp(l)) or "")
		return e, l or now, label, term
	elseif choice.advanced then
		local etxt = choice.earliest
		local e, pos, msg = T.parse(etxt, now)
		if not e then return nil, pos, "earliest: " .. msg end
		local ltxt = (choice.latest ~= nil and choice.latest ~= "") and choice.latest or "now"
		local l
		l, pos, msg = T.parse(ltxt, now)
		if not l then return nil, pos, "latest: " .. msg end
		return e, l, etxt .. " to " .. ltxt, "earliest=" .. etxt .. " latest=" .. ltxt
	end
	return nil, 1, "no choice"
end

local TIMEFIELD = { earliest = true, latest = true, time = true }
function CV.typedTime(text)
	if type(text) ~= "string" then return false end
	local ok, toks = pcall(M.PSS_Psql.tokens, text)
	if not ok or not toks then return false end
	for i = 1, toks.n or 0 do
		local r = toks[i]
		if (r[3] == "field" or r[3] == "index") and TIMEFIELD[text:sub(r[1], r[1] + r[2] - 1):lower()] then return true end
	end
	return false
end

function CV.monthGrid(y, m)
	local t = T.parse(format("%04d-%02d-01", y, m))
	local y2, m2 = CV.monthStep(y, m, 1)
	local t2 = T.parse(format("%04d-%02d-01", y2, m2))
	return T.weekday(t) - 1, math.floor((t2 - t) / 86400 + 0.5)
end

function CV.monthStep(y, m, k)
	local i = y * 12 + (m - 1) + k
	return math.floor(i / 12), i % 12 + 1
end

------------------------------------------------------------------------
-- Console tab model (STP-00255): highlight, sidebar, row actions, left list, help
--   M.PSS_ConsoleModel() -> cm   cm:Tokens, Fields, ChartKinds, RowActions, LeftRows, SetText
--   CV.colorize(text, toks, hexFn)  CV.term(field, value)  CV.addTerm(text, term)
--   M.PSS_DictPageModel(index, field)  CV.HELP  M.PSS_BUTTON_QUERIES  M.PSS_DeepDiveText(keyOrText, ctx)
------------------------------------------------------------------------
local sub, gsub = string.sub, string.gsub

local function esc(s) return (gsub(s, "|", "||")) end

-- PSQL has no || operator, so every || in the bar text is one typed pipe (the client edit box stores a typed | as ||).
function CV.unpipe(s) return (gsub(s or "", "||", "|")) end
function CV.pipe(s) return (gsub(s or "", "|", "||")) end

function CV.colorize(text, toks, hexFn)
	local out, at = {}, 1
	for i = 1, toks and toks.n or 0 do
		local t = toks[i]
		local p, len, kind = t[1], t[2], t[3]
		if p > at then out[#out + 1] = esc(sub(text, at, p - 1)) end
		if p >= at and len > 0 then
			local s = esc(sub(text, p, p + len - 1))
			local hex = kind ~= "space" and hexFn and hexFn(kind)
			out[#out + 1] = hex and ("|cff" .. hex .. s .. "|r") or s
			at = p + len
		end
	end
	if at <= #text then out[#out + 1] = esc(sub(text, at)) end
	return table.concat(out)
end

function CV.term(field, value)
	if type(value) == "number" then return field .. "=" .. tostring(value) end
	return field .. '="' .. gsub(tostring(value), '[\\"]', "\\%0") .. '"'
end

-- the first | outside quotes
local function pipeAt(text)
	local q, i = false, 1
	while i <= #text do
		local c = sub(text, i, i)
		if q then
			if c == "\\" then i = i + 1 elseif c == '"' then q = false end
		elseif c == '"' then q = true
		elseif c == "|" then return i end
		i = i + 1
	end
end

function CV.addTerm(text, term)
	text = text or ""
	local i = pipeAt(text)
	local r
	if i then
		local head = gsub(sub(text, 1, i - 1), "%s+$", "")
		r = (head ~= "" and (head .. " ") or "") .. term .. " " .. sub(text, i)
	else
		local head = gsub(text, "%s+$", "")
		r = (head ~= "" and (head .. " ") or "") .. term
	end
	return r
end

local KIND_ORDER = { "column", "line", "area", "bar", "donut", "heat", "number", "table" }

local CM = {}
CM.__index = CM

-- a service call that keeps its error (the dialog shows it): set or nil, err
function CV.call(name, input) return M.PSS_Call(name, input) end

-- The Save dialog's gate (STP-00256): canSave false with why at the 200 saved searches; chartWhy at the 100 saved charts
-- save a search, then its chart when asked: put = sq.put input, ch = { kind, chart = {x,y,series,opts} } | nil
-- -> id, err, chartErr (the search stays saved when only the chart fails)
function CV.saveSearch(put, ch)
	local set, err = CV.call("sq.put", put)
	if not set then return nil, err end
	local id = set[1][1]
	if ch then
		local c = ch.chart or {}
		local cs, cerr = CV.call("sq.chart.put", { queryId = id, kind = ch.kind, x = c.x or "", y = c.y or "", series = c.series or "", opts = c.opts or {} })
		if not cs then return id, nil, cerr or "chart not saved" end
	end
	return id
end

function CV.saveState(hasChart)
	local caps = M.PSS_SQ_CAPS or {}
	local out = { canSave = true }
	local q = M.PSS_Call("sq.list", { scope = "any" })
	if q and q.n >= (caps.records or 200) then
		out.canSave, out.why = false, "You have " .. (caps.records or 200) .. " saved searches. Delete one to save another."
	end
	if hasChart then
		local c = M.PSS_Call("sq.chart.list", {})
		if c and c.n >= (caps.charts or 100) then out.chartWhy = "You have " .. (caps.charts or 100) .. " saved charts." end
	end
	return out
end

function M.PSS_ConsoleModel() return setmetatable({ text = "" }, CM) end
function CM:SetText(t) self.text = t or "" end

function CM:Tokens(text)
	local toks = M.PSS_Psql.tokens(text)
	local ok, r, e = pcall(M.PSS_Psql.parse, text)
	local err
	if ok and r == nil then ok, e = false, e or "invalid query"		-- parse returns nil, err
	elseif not ok then e = r end
	if not ok then
		err = type(e) == "table" and { pos = e.pos or 1, msg = tostring(e.msg) } or { pos = 1, msg = tostring(e) }
	end
	return toks, err
end

-- the Fields panel (F135a): the set's columns in order, then its virtual fields; each with its distinct count and
-- row count; the open field also gets its top 5 values. Computed only while the panel is open.
local FIELDS_CAP = 30
local floor = math.floor
local function sortedCopy(list)
	local out = {}
	for i = 1, #list do out[i] = list[i] end
	table.sort(out)
	return out
end

function CM:Fields(set, open)
	local res = { fields = {}, more = 0 }
	if type(set) ~= "table" or type(set.cols) ~= "table" or (set.n or 0) == 0 then return res end
	local kinds = M.PSS_SetKinds(set) or {}
	local names, isCol = {}, {}
	for _, c in ipairs(set.cols) do names[#names + 1] = c; isCol[c] = true end
	local vf = type(set.vfields) == "table" and set.vfields or {}
	for _, v in ipairs(sortedCopy(vf)) do
		if not isCol[v] then names[#names + 1] = v; isCol[v] = true end
	end
	local nf = 0
	for _, name in ipairs(names) do
		local ci = M.PSS_SetCol(set, name)
		local seen, dc, n = {}, 0, 0
		for r = 1, set.n do
			local v
			if ci then v = set[r][ci] else v = M.PSS_SetVirtual(set, r, name) end
			if v ~= nil then
				n = n + 1
				if M.PSS_IsSecret(v) then dc = dc + 1
				elseif seen[v] then seen[v] = seen[v] + 1
				else seen[v] = 1; dc = dc + 1 end
			end
		end
		if n > 0 then
			if nf >= FIELDS_CAP then
				res.more = res.more + 1
			else
				nf = nf + 1
				local f = { name = name, label = M.PSS_FieldLabel(name), dc = dc, n = n, one = dc <= 1 }
				if name == open then
					local top = {}
					for v, c in pairs(seen) do
						top[#top + 1] = { raw = v, text = M.PSS_CellText(name, v, kinds[name]) or "", count = c, pct = floor(c * 1000 / set.n + 0.5) / 10 }
					end
					table.sort(top, function(a, b)
						if a.count ~= b.count then return a.count > b.count end
						return a.text < b.text
					end)
					for i = #top, 6, -1 do top[i] = nil end
					f.top = top
				end
				res.fields[nf] = f
			end
		end
	end
	return res
end

function CM:ChartKinds(shape)
	local allowed, out = ALLOWED[shape] or {}, {}
	for _, k in ipairs(KIND_ORDER) do if allowed[k] then out[#out + 1] = k end end
	return out
end

function CM:RowActions(set, i)
	local out = { { key = "copy", text = "Copy line" } }
	local row = set and set[i]
	if not row then return out end
	local oc, ic = M.PSS_SetCol(set, "owner"), M.PSS_SetCol(set, "item")
	if oc and row[oc] ~= nil then
		out[#out + 1] = { key = "owner", text = "Show this owner", query = CV.addTerm(self.text, CV.term("owner", row[oc])) }
	end
	if ic and row[ic] ~= nil then
		out[#out + 1] = { key = "item", text = "Where is this item", query = "index=inv " .. CV.term("item", row[ic]) }
	end
	return out
end

-- the tab-joined text of result row i; a secret cell is "" (PSS 02 section 10)
function CM:CopyLine(set, i)
	local row, cells = set and set[i], {}
	if not row then return "" end
	for k = 1, #set.cols do
		local v = row[k]
		if M.PSS_IsSecret(v) then cells[k] = "" else cells[k] = v == nil and "" or tostring(v) end
	end
	return table.concat(cells, "\t")
end

-- the detail box rows of result row i: raw field name and raw value, the display text dimmed after it when it
-- differs; set columns in order, then the virtual fields; a secret cell is "" (PSS 02 section 10)
function CM:RowDetail(set, i)
	local row, out = type(set) == "table" and type(set.cols) == "table" and set[i], {}
	if not row then return out end
	local kinds = M.PSS_SetKinds(set) or {}
	local names, isCol = {}, {}
	for k = 1, #set.cols do names[k] = set.cols[k]; isCol[set.cols[k]] = true end
	local vf = type(set.vfields) == "table" and set.vfields or {}
	for _, v in ipairs(sortedCopy(vf)) do
		if not isCol[v] then names[#names + 1] = v; isCol[v] = true end
	end
	for k, col in ipairs(names) do
		local v
		if k <= #set.cols then v = row[k] else v = M.PSS_SetVirtual(set, i, col) end
		local e = { field = col, value = "" }
		if not M.PSS_IsSecret(v) and v ~= nil then
			local raw = tostring(v)
			local text = M.PSS_CellText(col, v, kinds[col]) or ""
			e.raw, e.value = raw, raw
			if text ~= raw then e.dim = text; e.value = raw .. "  |cff999999" .. text .. "|r" end
		end
		out[k] = e
	end
	return out
end

function CM:LeftRows()
	local rows = { { head = "System" } }
	rows[#rows + 1] = { key = "preset:events", text = "Events", query = "index=log | head 500" }
	local sys = M.PSS_Call("sq.system", { scope = "any" })
	for i = 1, sys and sys.n or 0 do
		local r = sys[i]
		rows[#rows + 1] = { key = "sys:" .. r[1], text = r[2], query = r[4], view = r[5] }
	end
	rows[#rows + 1] = { head = "Mine" }
	local mine = M.PSS_Call("sq.list", { scope = "any" })
	for i = 1, mine and mine.n or 0 do
		local r = mine[i]
		rows[#rows + 1] = { key = "sq:" .. r[1], text = r[2] .. (r[7] and " (cannot run)" or ""), query = r[5], broken = r[7] and true or nil }
	end
	rows[#rows + 1] = { head = "Sources" }
	local ixs = M.PSS_Call("ix.list")
	for i = 1, ixs and ixs.n or 0 do
		rows[#rows + 1] = { key = "ix:" .. ixs[i][1], text = M.PSS_INDEX_LABELS[ixs[i][1]] or ixs[i][1], insert = "index=" .. ixs[i][1] }
	end
	rows[#rows + 1] = { head = "Data dictionary" }
	rows[#rows + 1] = { key = "dict", text = "Data dictionary" }
	return rows
end

function M.PSS_DictPageModel(index, field)
	local set, err
	if not index then set, err = M.PSS_Call("ix.list")
	elseif not field then set, err = M.PSS_Call("ix.dict", { index = index })
	else set, err = M.PSS_Call("ix.values", { index = index, field = field, n = 10 }) end
	if not set then return nil, err or "no result" end
	return set
end

CV.HELP = {
	{ "index=log | where time>-24h", "where: keep rows that match a comparison" },
	{ "index=log | fields time, cat", "fields: keep only these columns" },
	{ "index=log | rename cat as category", "rename: give a column another name" },
	{ "index=log | sort -time", "sort: order rows, - for descending" },
	{ "index=log | head 20", "head: the first rows (tail: the last)" },
	{ "index=log | dedup cat", "dedup: one row for each value" },
	{ "index=log | stats count by cat", "stats: count, sum, avg, min, max, dc ... by a column" },
	{ "index=log | timechart span=1d count", "timechart: a count over time" },
	{ "index=log | top 5 cat", "top: the most common values (rare: the least)" },
	{ "index=gold | calc k = copper / 1000", "calc: one sum of two columns or numbers" },
	{ "index=log | table time, cat", "table: show these columns as a table" },
	{ "index=log | stats count by cat | chart bar", "chart: draw the answer (last command)" },
	{ "gold", "A bare word searches the text of every index" },
	{ "index=log cat=whisper", "field=value keeps rows where it matches" },
	{ "index=log time like 21", "time text contains 21 (day, hour or minute)" },
	{ "earliest=-7d@d", "earliest and latest set the time range" },
}

-- The button query registry (STP-00257): a key -> query text (or a function of ctx) and
-- bind(ctx) -> params, range. Buttons call ns.DeepDive("<literal key>", ctx).
local EV_OWNER = "index=log owner=$owner | sort -time | head 200"
local function ownerRow(fn)
	return { query = EV_OWNER, bind = function(ctx) return { owner = fn(ctx.id) } end }
end
M.PSS_BUTTON_QUERIES = {
	["player.events"] = ownerRow(function(id) return M.PSS_PlayerHistoryKey(id) end),
	["member.events"] = ownerRow(function(id) return M.PSS_History.MemberKey(id) end),
	["filter.events"] = ownerRow(function(id) return M.PSS_FilterOwnerKey(id) end),
	["guild.events"] = { query = "index=log guild=$guild | sort -time | head 200", bind = function(ctx) return { guild = ctx.id } end },
	["group.events"] = { query = "index=log rule=$rule | sort -time | head 200", bind = function(ctx) return { rule = ctx.id } end },
	["player.all"] = { query = 'index=log owner="p:*" | sort -time | head 200' },
	["member.all"] = { query = 'index=log owner="g:*" | sort -time | head 200' },
	["filter.all"] = { query = 'index=log owner="f:*" | sort -time | head 200' },
	["guild.all"] = { query = 'index=log guild="*" | sort -time | head 200' },
	["group.all"] = { query = 'index=log guild="*" | sort -time | head 200' },
	["pane.events"] = { pane = "events" },
	["pane.slice"] = { pane = "slice" },
	["wh.holders"] = { sys = "wh.holders", bind = function(ctx) return { item = ctx.item } end },
}

local function rowText(row, ctx)
	if row.sys then
		for _, r in ipairs(M.PSS_SQ_SYSTEM or {}) do if r.id == row.sys then return r.q end end
		return nil
	end
	return type(row.query) == "function" and row.query(ctx) or row.query
end

local function sortedNames(set)
	local out = {}
	for k, on in pairs(set or {}) do
		if on and type(k) == "string" and k:match("^[%w_]+$") then out[#out + 1] = k end
	end
	table.sort(out)
	return out
end

local function beforePipe(text, add)
	local a, b = text:find(" | ", 1, true)
	if not a then return text .. add end
	return text:sub(1, a - 1) .. add .. text:sub(a)
end

local function orList(names)
	for i, c in ipairs(names) do names[i] = "cat=" .. c end
	return table.concat(names, " OR ")
end

local PERIOD_RANGE = {
	session = function() return { advanced = { earliest = "@session" } } end,
	day = function() return { preset = "last24h" } end,
}

function M.PSS_DeepDiveText(keyOrText, ctx)
	local row = type(keyOrText) == "string" and M.PSS_BUTTON_QUERIES[keyOrText]
	if row then
		ctx = ctx or {}
		local base, range = row, nil
		local evKind = keyOrText:match("^(%a+)%.events$")
		if row.pane then
			base = M.PSS_BUTTON_QUERIES[tostring(ctx.kind) .. ".events"]
			if not base then return nil, "unknown query" end
			evKind = ctx.kind
		end
		if (row.pane or evKind) and not ctx.id then
			base = M.PSS_BUTTON_QUERIES[tostring(evKind) .. ".all"]
			if not base then return nil, "unknown query" end
		end
		local text = rowText(base, ctx)
		if not text then return nil, "unknown query" end
		local params
		if base.bind then params, range = base.bind(ctx) end
		params = params or {}
		if row.pane == "slice" then
			text = beforePipe(text, " cat=$cat")
			params.cat = ctx.cat
		elseif row.pane == "events" then
			local f = ctx.period and PERIOD_RANGE[ctx.period]
			range = f and f() or nil
		end
		local names = type(ctx) == "table" and ctx.cats and sortedNames(ctx.cats) or {}
		if #names > 0 then text = beforePipe(text, " (" .. orList(names) .. ")") end
		for name in text:gmatch("%$([%w_]+)") do
			if params[name] == nil then return nil, "nothing selected" end
		end
		return text, params, range
	end
	if type(keyOrText) == "string" then return keyOrText, ctx, nil end
	return nil, "unknown query"
end

-- the values a $name takes when the context has none (nil = nothing to fill in)
M.PSS_QUERY_SOURCES = {
	owner = function(ctx) return ctx.owner end,
	item = function()
		local ok, set = pcall(M.PSS_Search, "index=inv | sort -count | head 1", {})
		if not ok or not set or not set[1] then return nil end
		local i = M.PSS_SetCol(set, "item")
		return i and set[1][i] or nil
	end,
}

-- every $name in text put in as a literal; nil, name for the first one nothing fills
function M.PSS_ResolveQuery(text, ctx)
	ctx = ctx or {}
	local missing
	local out = text:gsub("%$([%a_][%w_]*)", function(name)
		if missing then return nil end
		local v = ctx[name]
		if v == nil and M.PSS_QUERY_SOURCES[name] then v = M.PSS_QUERY_SOURCES[name](ctx) end
		if v == nil then missing = name; return nil end
		return quote(v)
	end)
	if missing then return nil, missing end
	return out
end

M.PSS_UNBOUND_TEXT = { owner = "Select a player in Player Ignore List first", item = "No item recorded yet", other = "This search needs a value Spyglass cannot fill" }

M.PSS_CON_BLANK = "Type a search, or pick one on the left, then Run."

-- the report profiles (ux-review 4.3): the columns a report draws, in order, when the set has the index's own columns
M.PSS_REPORT_COLS = {
	log = { "time", "member", "cat", "channel", "owner", "message" },
	["log.pane"] = { "time", "cat", "channel", "message" },
}

local MEASURE_ROWS = 100
local kindCache = {}

-- the kind of each column of the log index (cached), nil when the set is not that index's own columns
local function ownKinds(set)
	local ix = M.PSS_Ix and M.PSS_Ix("log")
	if not (ix and set and type(set.cols) == "table" and #set.cols == #ix.fields) then return nil end
	for i = 1, #set.cols do
		if set.cols[i] ~= ix.fields[i][1] then return nil end
	end
	local k = kindCache[ix]
	if not k then
		k = {}
		for i = 1, #ix.fields do k[ix.fields[i][1]] = ix.fields[i][2] end
		kindCache[ix] = k
	end
	return k
end

-- the kind of each column of a set: its own, else the log index's when it has the log columns
function M.PSS_SetKinds(set)
	if type(set) ~= "table" then return nil end
	return set.kinds or ownKinds(set)
end

-- indexes into set.cols of the columns a profile draws, hidden ones left out (R9 empty in the first 100 rows,
-- R13 owner and every column equal to the bound owner's name); nil when there is no profile for this set
function M.PSS_ReportCols(set, profile, bound)
	if type(set) ~= "table" or type(set.cols) ~= "table" or (set.n or 0) == 0 then return nil end
	local want = type(profile) == "string" and M.PSS_REPORT_COLS[profile]
	if not want then return nil end
	local kinds = ownKinds(set)
	if not kinds then return nil end
	local out = {}
	local rows = math.min(set.n, MEASURE_ROWS)
	for _, name in ipairs(want) do
		local ci = M.PSS_SetCol(set, name)
		if ci then
			local blank, same = true, bound ~= nil
			for r = 1, rows do
				local t = M.PSS_CellText(name, set[r][ci], kinds[name])
				if t ~= "" then blank = false end
				if t ~= bound then same = false end
			end
			if not blank and not (bound and (name == "owner" or same)) then out[#out + 1] = ci end
		end
	end
	if #out == 0 then return nil end
	return out
end

-- the kind letter of a log index field (nil when unknown)
local function logKind(field)
	local ix = M.PSS_Ix and M.PSS_Ix("log")
	for i = 1, ix and #ix.fields or 0 do
		if ix.fields[i][1] == field then return ix.fields[i][2] end
	end
end

-- text split at the | outside quotes
local function splitPipes(text)
	local out, at, q, i = {}, 1, false, 1
	while i <= #text do
		local c = sub(text, i, i)
		if q then
			if c == "\\" then i = i + 1 elseif c == '"' then q = false end
		elseif c == '"' then q = true
		elseif c == "|" then out[#out + 1] = sub(text, at, i - 1); at = i + 1 end
		i = i + 1
	end
	out[#out + 1] = sub(text, at)
	return out
end

-- words split at spaces outside quotes
local function words(seg)
	local out, cur, q, i = {}, {}, false, 1
	while i <= #seg do
		local c = sub(seg, i, i)
		if q then
			cur[#cur + 1] = c
			if c == "\\" then i = i + 1; cur[#cur + 1] = sub(seg, i, i) elseif c == '"' then q = false end
		elseif c == '"' then q = true; cur[#cur + 1] = c
		elseif c:find("%s") then
			if #cur > 0 then out[#out + 1] = table.concat(cur); cur = {} end
		else cur[#cur + 1] = c end
		i = i + 1
	end
	if #cur > 0 then out[#out + 1] = table.concat(cur) end
	return out
end

local function unquote(v)
	if sub(v, 1, 1) == '"' and sub(v, -1) == '"' and #v >= 2 then return (gsub(sub(v, 2, -2), "\\(.)", "%1")) end
	return v
end

local function shownValue(field, v)
	return M.PSS_Fields.show(logKind(field), v, field)
end

local function splitOr(s)
	local out, at = {}, 1
	while true do
		local a, b = s:find("%s+OR%s+", at)
		if not a then break end
		out[#out + 1] = sub(s, at, a - 1)
		at = b + 1
	end
	out[#out + 1] = sub(s, at)
	return out
end

-- the owner name of a top-level owner="<v>" term, nil with none or a wildcard (a bound report's subject)
function CV.boundName(text)
	if type(text) ~= "string" then return nil end
	local segs = splitPipes(text)
	local first = gsub(segs[1] or "", "NOT%s*%([^%)]*%)", "")
	for _, w in ipairs(words(first)) do
		local v = w:match("^owner=(.+)$")
		if v then
			v = unquote(v)
			if v:find("*", 1, true) then return nil end
			local name = shownValue("owner", v)
			name = gsub(name, "^%a[%a ]*: ", "")
			return name ~= "" and name or nil
		end
	end
end

local SPAN = { ["1h"] = "hour", ["1d"] = "day", ["1w"] = "week", ["1mon"] = "month" }

-- the plain-words summary of a search (ux-review 6.3): parts joined by " . ", "+ more" for what it leaves out;
-- a search that does not parse is "Custom search"
function M.PSS_QuerySummary(text, bound, rangeLabel)
	if type(text) ~= "string" or text == "" then return "Custom search" end
	local ok, plan = pcall(M.PSS_Psql.compile, text)
	if not ok or not plan then return "Custom search" end
	local segs = splitPipes(text)
	local parts, more = {}, false
	local first = gsub(segs[1] or "", "^%s+", "")
	first = gsub(first, "NOT%s*%(([^%)]*)%)", function(inner)
		local field, vals = nil, {}
		for _, t in ipairs(splitOr(inner)) do
			local f, v = t:match("^%s*([%a_][%w_]*)=(.-)%s*$")
			if not f or (field and f ~= field) then more = true; return "" end
			field = f
			vals[#vals + 1] = shownValue(f, unquote(v))
		end
		if #vals > 0 then parts[#parts + 1] = "without " .. table.concat(vals, ", ") end
		return ""
	end)
	for _, w in ipairs(words(first)) do
		local f, v = w:match("^([%a_][%w_]*)=(.+)$")
		if f == "index" then
			-- the source: said by the title
		elseif f and f ~= "earliest" and f ~= "latest" then
			v = unquote(v)
			if bound and f == "owner" and not v:find("*", 1, true) then
				-- the title names it
			elseif v:find("*", 1, true) then more = true
			else parts[#parts + 1] = f .. "=" .. v end
		else more = true end
	end
	local newest = false
	for i = 2, #segs do
		local w = words(segs[i])
		local cmd = w[1]
		if cmd == "sort" then
			newest = w[2] == "-time"
		elseif cmd == "head" and tonumber(w[2]) and #w == 2 then
			parts[#parts + 1] = (newest and "newest " or "first ") .. w[2]
		elseif cmd == "stats" and w[2] == "count" and w[3] == "by" and w[4] and #w == 4 then
			parts[#parts + 1] = "count by " .. w[4]
		elseif cmd == "timechart" and #w == 3 and w[3] == "count" and SPAN[(w[2] or ""):match("^span=(.+)$") or ""] then
			parts[#parts + 1] = "count per " .. SPAN[w[2]:match("^span=(.+)$")]
		else more = true end
	end
	if type(rangeLabel) == "string" and rangeLabel ~= "" then parts[#parts + 1] = rangeLabel end
	local out = table.concat(parts, " \194\183 ")
	if more then out = out == "" and "+ more" or (out .. " + more") end
	return out
end

-- the header line of a report or a typed search: "<title> . <summary>"
function CV.header(report, text, rangeLabel)
	if type(text) ~= "string" or text == "" then return "" end
	local title = report and report.title or "Custom search"
	local sum = M.PSS_QuerySummary(text, report and report.bound, rangeLabel)
	if sum == "" or sum == title then return title end
	return title .. " \194\183 " .. sum
end

-- the columns that keep their full width: time, and the first drawn of member, sender, ent, holder
function M.PSS_KeepCols(cols)
	local keep, who = {}, false
	for i = 1, #cols do
		local c = cols[i]
		if c == "time" or c == "ts" then keep[i] = true
		elseif not who and (c == "member" or c == "sender" or c == "ent" or c == "holder") then keep[i] = true; who = true end
	end
	return keep
end

local COL_MIN, COL_MAX, FILL_MIN, PADX = 36, 200, 120, 10
local FILL_SHARE = 0.4

-- column widths for a table of cols in avail pixels from the measured need of each: every column fits its
-- content (COL_MIN to COL_MAX), the message / summary / label (else the widest text) column fills (nil);
-- a keep[i] column never shrinks
function M.PSS_TableWidths(cols, avail, need, keep)
	local w = {}
	local n = #cols
	if n == 0 then return w end
	if type(avail) ~= "number" or avail < 0 then avail = 0 end
	local fillMin = math.max(FILL_MIN, math.floor(avail * FILL_SHARE))
	need = need or {}
	keep = keep or {}
	local function nd(i) return tonumber(need[i]) or 0 end
	local fill
	for _, name in ipairs({ "message", "summary", "label" }) do
		for i = 1, n do
			if cols[i] == name then fill = i; break end
		end
		if fill then break end
	end
	if not fill then
		local best = -1
		for i = 1, n do
			if cols[i] ~= "time" and cols[i] ~= "ts" and nd(i) >= best then fill, best = i, nd(i) end
		end
		fill = fill or n
	end
	local function shrinks(i)
		return i ~= fill and not keep[i]
	end
	local sum = 0
	for i = 1, n do
		if i ~= fill then
			if need[i] == nil then w[i] = COL_MIN
			else w[i] = math.min(COL_MAX, math.max(COL_MIN, math.ceil(need[i]) + PADX)) end
			sum = sum + w[i]
		end
	end
	local rest = avail - sum
	if rest >= fillMin then return w end
	local over = fillMin - rest
	local S = 0
	for i = 1, n do
		if shrinks(i) then S = S + w[i] - COL_MIN end
	end
	if S == 0 then return w end
	local owed = over
	for i = 1, n do
		if shrinks(i) then
			local give = math.min(w[i] - COL_MIN, math.floor(over * (w[i] - COL_MIN) / S))
			w[i] = w[i] - give
			owed = owed - give
		end
	end
	while owed > 0 do
		local pick
		for i = 1, n do
			if shrinks(i) and w[i] > COL_MIN and (not pick or w[i] > w[pick]) then pick = i end
		end
		if not pick then break end
		w[pick] = w[pick] - 1
		owed = owed - 1
	end
	return w
end

M.PSS_PANE_OFF = "Event Logging is off. Turn it on in Optional Features."

-- types -> the log categories they stand for (party, raid and BG lines are told apart by channel)
local TYPE_CATS = { whisper = { "whisper" }, invite = { "partyInvite", "guildInvite" }, world = { "world" }, guild = { "guildChat" } }

-- the pane's text and params: the kind's .events row, hidden types (a set of type names) excluded
function M.PSS_PaneQuery(kind, id, hidden)
	local row = M.PSS_BUTTON_QUERIES[tostring(kind) .. ".events"]
	if not row then return nil, "unknown query" end
	local ctx = { kind = kind, id = id }
	local text = rowText(row, ctx)
	local params = row.bind and row.bind(ctx) or {}
	local cats = {}
	for t, on in pairs(hidden or {}) do
		if on then for _, c in ipairs(TYPE_CATS[t] or {}) do cats[#cats + 1] = c end end
	end
	if #cats > 0 then
		table.sort(cats)
		text = beforePipe(text, " NOT (" .. orList(cats) .. ")")
	end
	return text, params
end

-- the Queries drop-down of a pane: { { id, name, text, system } ... }
function M.PSS_PaneQueries(kind)
	local scope = kind == "member" and "guild" or kind
	local out = {}
	local sys = M.PSS_Call("sq.system", { scope = scope })
	for i = 1, sys and sys.n or 0 do
		out[#out + 1] = { id = sys[i][1], name = sys[i][2], text = sys[i][4], system = true }
	end
	local mine = M.PSS_Call("sq.list", { scope = scope })
	for i = 1, mine and mine.n or 0 do
		out[#out + 1] = { id = mine[i][1], name = mine[i][2], text = mine[i][5] }
	end
	return out
end
