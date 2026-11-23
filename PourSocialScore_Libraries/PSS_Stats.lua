------------------------------------------------------------------------
-- POUR SOCIAL SCORE - STATISTICS STEPS (search-helper, STP-00239 and
-- STP-00286, DDS-00031 section 8). Bus services over record sets, like the
-- steps of PSS_Query.lua:
--   q.stats        opts.fns = { { fn, field, as, cond } }, opts.by = { f, ... }  -> by..., as...
--                  fn: count sum avg min max dc latest earliest count_if (cond = { field, value })
--   q.timechart    opts.span (seconds | "mon"), fn, field, by?, lo?, hi?      -> time, <series>... | time, <fn>
--   q.top          opts.n, field, by?, rare                                   -> [by,] field, count, percent
--   q.dedup        opts.fields                    q.calc   opts.name, a, op, b (fields or numbers)
--   q.rename       opts.map = { [old] = new }     q.tail   opts.limit (the last n rows)
--   q.fields       opts.keep | opts.drop          q.ixjoin opts.field, index (a state index's columns by key)
--   q.fieldsummary opts.maxvals, opts.kinds, opts.dict  -> field, kind, count, distinct, nulls, min, max, top
--   q.values       opts.fields, opts.n            -> field, values
-- Rules: an empty input gives an empty output with the same columns; nil
-- input is an error; avg of no rows is nil; x / 0 is nil; numbers stay
-- numbers. Groups are capped at 2,000 (the rest in "other", set.partial);
-- distinct counts at 10,000 per group or field (then set.approx).
-- Accumulators are per group (one table per group, never per row).
-- Loaded with Libraries. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tonumber, tostring, pairs, ipairs, error, next = type, tonumber, tostring, pairs, ipairs, error, next
local concat, sort = table.concat, table.sort
local lower, floor = string.lower, math.floor

local GROUPS, DISTINCT, SERIES = 2000, 10000, 10
M.PSS_STATS_CAPS = { groups = GROUPS, distinct = DISTINCT, series = SERIES }

local function need(set)
	if not M.PSS_IsSet(set) then error("arg: no input record set", 0) end
end

local function col(set, name)
	local c = M.PSS_SetCol(set, name)
	if not c then error("field: no column " .. tostring(name), 0) end
	return c
end

local function label(f)
	if f.as then return f.as end
	if f.fn == "count" and not f.field then return "count" end
	if f.fn == "count_if" then return "count_if(" .. tostring(f.cond and f.cond[1]) .. "=" .. tostring(f.cond and f.cond[2]) .. ")" end
	return f.fn .. "(" .. tostring(f.field) .. ")"
end
M.PSS_StatLabel = label

local FNS = { count = true, sum = true, avg = true, min = true, max = true, dc = true, latest = true, earliest = true, count_if = true }

-- one accumulator per function per group: { n, sum, v, t, set, dn }
local function acc(fn, a, v, t, row, cc)
	if fn == "count" then
		if cc == nil or v ~= nil then a.n = a.n + 1 end
	elseif fn == "count_if" then
		if v ~= nil and lower(tostring(v)) == cc then a.n = a.n + 1 end
	elseif fn == "sum" or fn == "avg" then
		v = tonumber(v)
		if v then a.sum = a.sum + v; a.n = a.n + 1 end
	elseif fn == "min" then
		if v ~= nil and (a.v == nil or (type(v) == type(a.v) and v < a.v)) then a.v = v end
	elseif fn == "max" then
		if v ~= nil and (a.v == nil or (type(v) == type(a.v) and v > a.v)) then a.v = v end
	elseif fn == "dc" then
		if v ~= nil and not a.set[v] then
			if a.dn < DISTINCT then a.set[v] = true; a.dn = a.dn + 1 else a.approx = true end
		end
	elseif fn == "latest" then
		if v ~= nil and t and (a.t == nil or t >= a.t) then a.t, a.v = t, v end
	elseif fn == "earliest" then
		if v ~= nil and t and (a.t == nil or t < a.t) then a.t, a.v = t, v end
	end
end

local function result(fn, a)
	if fn == "count" or fn == "count_if" then return a.n end
	if fn == "sum" then return a.n > 0 and a.sum or 0 end
	if fn == "avg" then return a.n > 0 and a.sum / a.n or nil end
	if fn == "dc" then return a.dn end
	return a.v
end

local function newAcc(fns)
	local g = {}
	for i = 1, #fns do g[i] = { n = 0, sum = 0, dn = 0, set = fns[i].fn == "dc" and {} or nil } end
	return g
end

-- the shared grouping: fills groups by key; returns order, groups, keys, partial
local function group(set, by, fns)
	local bc = {}
	for i = 1, #by do bc[i] = col(set, by[i]) end
	local fc, cc = {}, {}
	for i, f in ipairs(fns) do
		if not FNS[f.fn] then error("arg: unknown function " .. tostring(f.fn), 0) end
		if f.fn == "count_if" then
			fc[i] = col(set, f.cond[1]); cc[i] = lower(tostring(f.cond[2]))
		elseif f.field then
			fc[i] = col(set, f.field)
		elseif f.fn ~= "count" then
			error("arg: " .. f.fn .. " needs a field", 0)
		end
	end
	local tc = M.PSS_SetCol(set, "time")
	local groups, order, keys, n = {}, {}, {}, 0
	local partial, other = false, nil
	local nb = #by
	local kv = {}
	for r = 1, set.n do
		local row = set[r]
		local key
		if nb == 0 then key = ""
		elseif nb == 1 then key = row[bc[1]]; if key == nil then key = "" end
		else
			for i = 1, nb do local v = row[bc[i]]; kv[i] = v == nil and "" or tostring(v) end
			key = concat(kv, "\1", 1, nb)
		end
		local g = groups[key]
		if not g then
			if n >= GROUPS then
				partial = true
				if not other then other = newAcc(fns); other.other = true end
				g = other
			else
				g = newAcc(fns)
				n = n + 1
				order[n] = key
				groups[key] = g
				local kvals = {}
				for i = 1, nb do kvals[i] = row[bc[i]] end
				keys[key] = kvals
			end
		end
		local t = tc and row[tc]
		for i = 1, #fns do
			local f = fns[i]
			acc(f.fn, g[i], fc[i] and row[fc[i]] or nil, t, row, f.fn == "count" and (fc[i] and true or nil) or cc[i])
		end
	end
	if other then
		n = n + 1
		order[n] = "\2other"
		groups["\2other"] = other
		local kvals = {}
		for i = 1, nb do kvals[i] = "other" end
		keys["\2other"] = kvals
	end
	return order, groups, keys, partial
end

M.PSS_Provide("q.stats", function(set, opts)
	need(set)
	local fns, by = opts and opts.fns or { { fn = "count" } }, opts and opts.by or {}
	local cols = {}
	for i = 1, #by do cols[i] = by[i] end
	for i = 1, #fns do cols[#cols + 1] = label(fns[i]) end
	local out = { cols = cols, n = 0 }
	if set.n == 0 then
		if #by == 0 then		-- a bare stats over nothing is one row of zeros (a number shape)
			local row = {}
			for i = 1, #fns do local f = fns[i].fn; row[i] = (f == "count" or f == "count_if" or f == "dc" or f == "sum") and 0 or nil end
			out.n, out[1] = 1, row
		end
		return out
	end
	local order, groups, keys, partial = group(set, by, fns)
	local approx = false
	for _, key in ipairs(order) do
		local g, row = groups[key], {}
		local kv = keys[key]
		for i = 1, #by do row[i] = kv[i] end
		for i = 1, #fns do
			row[#by + i] = result(fns[i].fn, g[i])
			if g[i].approx then approx = true end
		end
		out.n = out.n + 1
		out[out.n] = row
	end
	out.partial, out.approx = partial or nil, approx or nil
	return out
end, { accepts = { "*" }, returns = { "*" }, doc = "aggregates by groups: count sum avg min max dc latest earliest count_if" })

M.PSS_Provide("q.timechart", function(set, opts)
	need(set)
	local T = M.PSS_Time
	local span = opts and opts.span or 86400
	local f = { fn = opts and opts.fn or "count", field = opts and opts.field, cond = opts and opts.cond }
	local by = opts and opts.by
	local tc = col(set, "time")
	local bcol = by and col(set, by)
	local fcol = f.field and col(set, f.field)
	local lo, hi = opts and opts.lo, opts and opts.hi
	if not lo or not hi then
		for i = 1, set.n do
			local t = set[i][tc]
			if t then
				if not opts.lo and (not lo or t < lo) then lo = t end
				if not opts.hi and (not hi or t > hi) then hi = t end
			end
		end
	end
	-- the series: every by value, ordered by total, top 10 then other
	local series, sname = {}, {}
	if bcol then
		local tot = {}
		for i = 1, set.n do local v = set[i][bcol]; v = v == nil and "" or v; tot[v] = (tot[v] or 0) + 1 end
		for v in pairs(tot) do series[#series + 1] = v end
		sort(series, function(a, b) if tot[a] ~= tot[b] then return tot[a] > tot[b] end return tostring(a) < tostring(b) end)
		for i = 1, #series do sname[series[i]] = i <= SERIES and i or (SERIES + 1) end
		if #series > SERIES then for i = SERIES + 1, #series do series[i] = nil end; series[SERIES + 1] = "other" end
	end
	local cols = { "time" }
	if bcol then for i = 1, #series do cols[#cols + 1] = tostring(series[i]) end else cols[2] = label(f) end
	local out = { cols = cols, n = 0 }
	if not lo then return out end
	local nser = bcol and #series or 1
	local buckets, at = {}, {}
	local t0 = T.bucket(lo, span)
	local guard = 0
	while t0 <= hi and guard < 5000 do
		guard = guard + 1
		local b = {}
		for s = 1, nser do b[s] = { n = 0, sum = 0, dn = 0, set = f.fn == "dc" and {} or nil } end
		buckets[#buckets + 1] = { t0, b }
		at[t0] = b
		t0 = T.nextBucket(t0, span)
	end
	local cc = f.fn == "count_if" and lower(tostring(f.cond and f.cond[2])) or (f.fn == "count" and (fcol and true or nil))
	local ccol = f.fn == "count_if" and col(set, f.cond[1])
	for i = 1, set.n do
		local row = set[i]
		local t = row[tc]
		local b = t and at[T.bucket(t, span)]
		if b then
			local s = 1
			if bcol then local v = row[bcol]; s = sname[v == nil and "" or v] end
			acc(f.fn, b[s], ccol and row[ccol] or (fcol and row[fcol]) or nil, t, row, cc)
		end
	end
	local zero = f.fn == "count" or f.fn == "sum" or f.fn == "count_if"
	for _, bk in ipairs(buckets) do
		local row = { bk[1] }
		for s = 1, nser do
			local a = bk[2][s]
			local v = result(f.fn, a)
			if not zero and a.n == 0 and a.v == nil and a.dn == 0 then v = nil end
			row[s + 1] = v
		end
		out.n = out.n + 1
		out[out.n] = row
	end
	return out
end, { accepts = { "time" }, returns = { "*" }, doc = "buckets rows by time: one row per bucket, empty buckets filled" })

M.PSS_Provide("q.top", function(set, opts)
	need(set)
	local field, by, n = opts.field, opts.by, opts.n or 10
	local fc, bc = col(set, field), by and col(set, by)
	local cols = by and { by, field, "count", "percent" } or { field, "count", "percent" }
	local out = { cols = cols, n = 0 }
	local tot, list, keyOf, total = {}, {}, {}, 0
	for i = 1, set.n do
		local v = set[i][fc]
		if v ~= nil then
			local b = bc and set[i][bc]
			local k = bc and (tostring(b) .. "\1" .. tostring(v)) or v
			if not tot[k] then tot[k] = 0; list[#list + 1] = k; keyOf[k] = { b, v } end
			tot[k] = tot[k] + 1
			total = total + 1
		end
	end
	local rare = opts.rare
	sort(list, function(a, b)
		if tot[a] ~= tot[b] then if rare then return tot[a] < tot[b] end return tot[a] > tot[b] end
		return tostring(a) < tostring(b)
	end)
	for i = 1, math.min(n, #list) do
		local k = list[i]
		local row = by and { keyOf[k][1], keyOf[k][2], tot[k], 0 } or { keyOf[k][2], tot[k], 0 }
		row[#row] = total > 0 and floor(tot[k] * 10000 / total + 0.5) / 100 or 0
		out.n = out.n + 1
		out[out.n] = row
	end
	return out
end, { accepts = { "*" }, returns = { "count", "percent" }, doc = "the most (or least) common values of a field" })

M.PSS_Provide("q.dedup", function(set, opts)
	need(set)
	local fields = opts and opts.fields or {}
	local cs = {}
	for i = 1, #fields do cs[i] = col(set, fields[i]) end
	local out = { cols = set.cols, n = 0 }
	local seen, kv = {}, {}
	for i = 1, set.n do
		local row = set[i]
		for j = 1, #cs do local v = row[cs[j]]; kv[j] = v == nil and "" or tostring(v) end
		local key = concat(kv, "\1", 1, #cs)
		if not seen[key] then seen[key] = true; out.n = out.n + 1; out[out.n] = row end
	end
	return out
end, { accepts = { "*" }, returns = { "*" }, doc = "keeps the first row of each combination of opts.fields" })

local OPS = {
	["+"] = function(a, b) return a + b end,
	["-"] = function(a, b) return a - b end,
	["*"] = function(a, b) return a * b end,
	["/"] = function(a, b) if b == 0 then return nil end return a / b end,
}

M.PSS_Provide("q.calc", function(set, opts)
	need(set)
	local f = OPS[opts.op]
	if not f or type(opts.name) ~= "string" then error("arg: calc is name = a (+|-|*|/) b", 0) end
	local function operand(x)
		if type(x) == "number" then return nil, x end
		local n = tonumber(x)
		if n then return nil, n end
		return col(set, x), nil
	end
	local ac, an = operand(opts.a)
	local bc, bn = operand(opts.b)
	local cols = {}
	for i = 1, #set.cols do cols[i] = set.cols[i] end
	local at = M.PSS_SetCol(set, opts.name)
	if not at then cols[#cols + 1] = opts.name; at = #cols end
	local out = { cols = cols, n = 0 }
	for i = 1, set.n do
		local row, new = set[i], {}
		for c = 1, #set.cols do new[c] = row[c] end
		local a, b = tonumber(ac and row[ac] or an), tonumber(bc and row[bc] or bn)
		new[at] = (a and b) and f(a, b) or nil
		out.n = out.n + 1
		out[out.n] = new
	end
	return out
end, { accepts = { "*" }, returns = { "*" }, doc = "adds a column: a op b" })

M.PSS_Provide("q.rename", function(set, opts)
	need(set)
	local map = opts and opts.map or {}
	local cols = {}
	for i = 1, #set.cols do cols[i] = map[set.cols[i]] or set.cols[i] end
	for old in pairs(map) do col(set, old) end
	local out = { cols = cols, n = set.n }
	for i = 1, set.n do out[i] = set[i] end
	return out
end, { accepts = { "*" }, returns = { "*" }, doc = "renames columns" })

M.PSS_Provide("q.tail", function(set, opts)
	need(set)
	local n = opts and opts.limit or 10
	local out = { cols = set.cols, n = 0 }
	for i = math.max(1, set.n - n + 1), set.n do out.n = out.n + 1; out[out.n] = set[i] end
	return out
end, { accepts = { "*" }, returns = { "*" }, doc = "the last opts.limit rows" })

M.PSS_Provide("q.fields", function(set, opts)
	need(set)
	local keep = opts and opts.keep
	if not keep then
		local drop = {}
		for _, f in ipairs(opts and opts.drop or {}) do col(set, f); drop[f] = true end
		keep = {}
		for _, c in ipairs(set.cols) do if not drop[c] then keep[#keep + 1] = c end end
	end
	return M.PSS_CallRaw("q.select", set, { select = keep })
end, { accepts = { "*" }, returns = { "*" }, doc = "keeps opts.keep, or drops opts.drop" })

-- a state index's columns joined by a key field: index=inv | join item index=val
M.PSS_Provide("q.ixjoin", function(set, opts)
	need(set)
	local field, name = opts.field, opts.index
	local x = M.PSS_Ix and M.PSS_Ix(name)
	if not x then error("index: no index " .. tostring(name), 0) end
	local fc = col(set, field)
	local want = {}
	for i = 1, set.n do local v = set[i][fc]; if v ~= nil then want[v] = true end end
	local add, extra = {}, {}
	for _, f in ipairs(x.fields) do
		if f[1] ~= field and not M.PSS_SetCol(set, f[1]) then extra[#extra + 1] = f[1] end
	end
	local pd = {}
	pd[field] = want
	x:scan(pd, function(row)
		local k = row[field]
		if k ~= nil and want[k] and not add[k] then
			local vals = {}
			for i = 1, #extra do vals[i] = row[extra[i]] end
			add[k] = vals
		end
	end, {})
	local cols = {}
	for i = 1, #set.cols do cols[i] = set.cols[i] end
	for i = 1, #extra do cols[#cols + 1] = extra[i] end
	local out = { cols = cols, n = 0 }
	local base = #set.cols
	for i = 1, set.n do
		local row, new = set[i], {}
		for c = 1, base do new[c] = row[c] end
		local vals = add[row[fc]]
		if vals then for j = 1, #extra do new[base + j] = vals[j] end end
		out.n = out.n + 1
		out[out.n] = new
	end
	return out
end, { accepts = { "*" }, returns = { "*" }, doc = "adds a state index's fields by a key field" })

------------------------------------------------------------------------
-- Field summary and values (STP-00286)
------------------------------------------------------------------------
local function closedList(dict, field)
	local row = dict and dict[field]
	local v = row and row.values
	if type(v) == "string" and M.PSS_DataDictValues and v:find("^fn:") then
		local p = M.PSS_DataDictValues[v:sub(4)]
		v = p and p() or nil
	end
	if type(v) ~= "table" or v.lo ~= nil or type(v[1]) ~= "string" then return nil end
	local set = {}
	for _, s in ipairs(v) do set[s] = true end
	return set
end

M.PSS_Provide("q.fieldsummary", function(set, opts)
	need(set)
	local maxvals = opts and opts.maxvals or 5
	local kinds, dict = opts and opts.kinds or {}, opts and opts.dict
	local out = { cols = { "field", "kind", "count", "distinct", "nulls", "min", "max", "top" }, n = 0 }
	for c, field in ipairs(set.cols) do
		local count, nulls, distinct, dn, approx = 0, 0, {}, 0, false
		local mn, mx
		for i = 1, set.n do
			local v = set[i][c]
			if v == nil or v == "" then nulls = nulls + 1
			else
				count = count + 1
				if distinct[v] then distinct[v] = distinct[v] + 1
				elseif dn < DISTINCT then distinct[v] = 1; dn = dn + 1
				else approx = true end
				if type(v) == type(mn) or mn == nil then
					if mn == nil or v < mn then mn = v end
					if mx == nil or v > mx then mx = v end
				end
			end
		end
		local list = {}
		for v in pairs(distinct) do list[#list + 1] = v end
		sort(list, function(a, b) if distinct[a] ~= distinct[b] then return distinct[a] > distinct[b] end return tostring(a) < tostring(b) end)
		local closed = closedList(dict, field)
		local top = {}
		for i = 1, math.min(maxvals, #list) do
			local v = list[i]
			local shown = tostring(v)
			if closed and not closed[shown] then shown = "unknown:" .. shown end
			top[i] = shown .. " (" .. distinct[v] .. ")"
		end
		if closed then		-- a value outside the closed list shows even when it is not among the most common
			for _, v in ipairs(list) do
				if not closed[tostring(v)] then
					local s = "unknown:" .. tostring(v) .. " (" .. distinct[v] .. ")"
					local there = false
					for _, t in ipairs(top) do if t == s then there = true end end
					if not there then top[#top + 1] = s end
				end
			end
		end
		out.n = out.n + 1
		out[out.n] = { field, kinds[field] or "", count, dn, nulls, mn, mx, concat(top, ", ") }
		if approx then out.approx = true end
	end
	return out
end, { accepts = { "*" }, returns = { "field", "kind", "count", "distinct", "nulls", "min", "max", "top" }, doc = "one row per field: count, distinct, nulls, min, max, most common" })

M.PSS_Provide("q.values", function(set, opts)
	need(set)
	local fields = opts and opts.fields or set.cols
	local n = opts and opts.n or 100
	local out = { cols = { "field", "values" }, n = 0 }
	for _, f in ipairs(fields) do
		local c = col(set, f)
		local seen, list = {}, {}
		for i = 1, set.n do
			local v = set[i][c]
			if v ~= nil and not seen[v] then seen[v] = true; list[#list + 1] = v end
		end
		sort(list, function(a, b) return tostring(a) < tostring(b) end)
		local shown = {}
		for i = 1, math.min(n, #list) do shown[i] = tostring(list[i]) end
		out.n = out.n + 1
		out[out.n] = { f, concat(shown, ", ") }
	end
	return out
end, { accepts = { "*" }, returns = { "field", "values" }, doc = "the distinct values of fields" })
