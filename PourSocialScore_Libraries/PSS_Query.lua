------------------------------------------------------------------------
-- POUR SOCIAL SCORE - QUERIES AND JOINS (service-bus-helper, DDS-00010
-- section 4). A query is a chain of bus services over record sets:
--   M.PSS_Query({ from = "ent.get" | set, key = ..., where = { col = value | { values } },
--                 join = { "ent" }, by = "col", sum = "col",
--                 order = { "col", "desc" }, limit = 10, reuse = true })
-- Each step is itself a service (q.where, q.join, q.by, q.order, q.limit; the
-- step's parameter is in opts), so its output is an input like any other.
--   where   rows whose column equals the value or is in the list (all columns)
--   join    adds a dictionary's columns by id: the set needs a column of the
--           dictionary's name; the added columns are "<dict>_<field>"
--           (M.PSS_QueryDict registers a dictionary: ent from PSS_Entity.lua)
--   by      groups by a column: columns { by, "total", "n" } (sum of the
--           "sum" column and the row count), in order of first sight
--   order   { column, "asc" | "desc" }, ties keep their order
--   limit   the first n rows; after: skip the rows already seen (paging); an order with a limit
--           keeps only that page in one pass
--   select  { "col", ... } keeps only those columns, in that order
-- Without opts.reuse where, order and limit hand out the input's row tables
-- and join and by make one new row each; with opts.reuse every step fills a
-- pool of its own, so a redraw allocates nothing once the pool is warm (the
-- caller uses the answer before the next call). A bad column or dictionary
-- is an error the bus reports once and the caller sees as nil, err.
-- Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, error, tostring, pcall, next = type, pairs, ipairs, error, tostring, pcall, next
local sort, floor = table.sort, math.floor

local dicts = {}		-- [name] = { fields = { names }, get = function(id) -> values }
local pushdown = {}		-- [service] = { col, fn }: a service that answers where[col] == value from an index
M.PSS_QueryStats = { scanned = 0 }		-- rows q.where walked (the harness proves a pushdown reads none)
local pools = {}		-- [step name] = a record set kept for opts.reuse

-- a dictionary the join step can read: get(id, dest, at) writes one value per
-- field into dest[at], dest[at + 1], ... (nothing when the id is unknown)
function M.PSS_QueryDict(name, fields, get)
	dicts[name] = { fields = fields, get = get }
end

-- a service answers where[col] == value straight from a declared index:
-- fn(value, key, opts) returns the rows of the set it would have returned
function M.PSS_QueryIndexed(service, column, fn)
	pushdown[service] = { col = column, fn = fn }
end

local function col(set, name)
	local c = M.PSS_SetCol(set, name)
	if not c then error("no column " .. tostring(name), 0) end
	return c
end

local function same(a, b)
	if a == b then return true end
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

-- the set a step fills: a new one, or the step's pool (rows kept) when reuse
local function out(step, cols, opts)
	if opts and opts.reuse then
		local p = pools[step]
		if not p or not same(p.cols, cols) then
			p = { cols = cols, n = 0 }
			pools[step] = p
		end
		p.n = 0
		return p, true
	end
	return { cols = cols, n = 0 }, false
end

-- a copy of the row into the pool, or the row itself into a new set
local function put(set, pooled, from)
	if pooled then
		local row = M.PSS_SetNext(set)
		for i = 1, #set.cols do row[i] = from[i] end
		return row
	end
	return M.PSS_SetAdd(set, from)
end

local function has(want, v)
	if type(want) == "table" then
		for i = 1, #want do if want[i] == v then return true end end
		return false
	end
	return want == v
end

M.PSS_Provide("q.where", function(set, opts)
	local where = opts and opts.where
	if type(where) ~= "table" then error("no where", 0) end
	local cs, ws = {}, {}
	for name, want in pairs(where) do
		cs[#cs + 1] = col(set, name)
		ws[#ws + 1] = want
	end
	local o, pooled = out("q.where", set.cols, opts)
	M.PSS_QueryStats.scanned = M.PSS_QueryStats.scanned + set.n
	for i = 1, set.n do
		local row, keep = set[i], true
		for j = 1, #cs do
			if not has(ws[j], row[cs[j]]) then keep = false break end
		end
		if keep then
			put(o, pooled, row)
		end
	end
	return o
end, { accepts = { "*" }, returns = { "*" }, doc = "rows whose columns match opts.where" })

M.PSS_Provide("q.join", function(set, opts)
	local list = opts and opts.join
	if type(list) ~= "table" then error("no join", 0) end
	local cols = {}
	for i = 1, #set.cols do cols[i] = set.cols[i] end
	local ids, ds = {}, {}
	for k, name in ipairs(list) do
		local d = dicts[name]
		if not d then error("no dictionary " .. tostring(name), 0) end
		ds[k] = d
		ids[k] = col(set, name)
		for _, f in ipairs(d.fields) do cols[#cols + 1] = name .. "_" .. f end
	end
	local o, pooled = out("q.join", cols, opts)
	local base = #set.cols
	for i = 1, set.n do
		local row = set[i]
		local n = base
		local new = pooled and M.PSS_SetNext(o) or {}
		for c = 1, base do new[c] = row[c] end
		for k = 1, #ds do
			local d = ds[k]
			for f = n + 1, n + #d.fields do new[f] = nil end
			d.get(row[ids[k]], new, n + 1)
			n = n + #d.fields
		end
		if not pooled then M.PSS_SetAdd(o, new) end
	end
	return o
end, { accepts = { "*" }, returns = { "*" }, doc = "adds a dictionary's columns by id (opts.join)" })

M.PSS_Provide("q.by", function(set, opts)
	local by, sum = opts and opts.by, opts and opts.sum
	if type(by) ~= "string" then error("no by", 0) end
	local bc, sc = col(set, by), sum and col(set, sum)
	local o, pooled = out("q.by", { by, "total", "n" }, opts)
	local at = {}
	for i = 1, set.n do
		local row = set[i]
		local key = row[bc]
		local g = at[key]
		if not g then
			if pooled then
				g = M.PSS_SetNext(o)
				g[1], g[2], g[3] = key, 0, 0
			else
				g = M.PSS_SetAdd(o, { key, 0, 0 })
			end
			at[key] = g
		end
		if sc then g[2] = g[2] + (row[sc] or 0) end
		g[3] = g[3] + 1
	end
	return o
end, { accepts = { "*" }, returns = { "total", "n" }, doc = "groups by opts.by, totals opts.sum" })

-- order, and with opts.limit (and opts.after, rows already seen) only the rows asked for: a limit smaller than
-- the set keeps a sorted list of that many rows instead of sorting all of them (same rows, same ties)
M.PSS_Provide("q.order", function(set, opts)
	local spec = opts and opts.order
	if type(spec) ~= "table" then error("no order", 0) end
	local c, desc = col(set, spec[1]), spec[2] == "desc"
	local skip = opts.after or 0
	local want = opts.limit and (opts.limit + skip)
	local pos = {}
	local function before(a, b)
		local x, y = a[c], b[c]
		if x == y then return pos[a] < pos[b] end
		if desc then return x > y end
		return x < y
	end
	local rows = {}
	for i = 1, set.n do pos[set[i]] = i end
	if want and want < set.n then
		local top, n = {}, 0
		for i = 1, set.n do
			local r = set[i]
			if n < want or before(r, top[n]) then
				local lo, hi = 1, n
				while lo <= hi do
					local mid = floor((lo + hi) / 2)
					if before(top[mid], r) then lo = mid + 1 else hi = mid - 1 end
				end
				for j = (n < want and n or n - 1), lo, -1 do top[j + 1] = top[j] end
				top[lo] = r
				if n < want then n = n + 1 end
			end
		end
		rows = top
	else
		for i = 1, set.n do rows[i] = set[i] end
		sort(rows, before)
	end
	local o, pooled = out("q.order", set.cols, opts)
	for i = skip + 1, opts.limit and math.min(#rows, skip + opts.limit) or #rows do
		put(o, pooled, rows[i])
	end
	return o
end, { accepts = { "*" }, returns = { "*" }, doc = "sorts by opts.order; with opts.limit and opts.after only that page" })

M.PSS_Provide("q.limit", function(set, opts)
	local n, skip = opts and opts.limit, opts.after or 0
	if type(n) ~= "number" then error("no limit", 0) end
	local o, pooled = out("q.limit", set.cols, opts)
	for i = skip + 1, math.min(set.n, skip + n) do
		put(o, pooled, set[i])
	end
	return o
end, { accepts = { "*" }, returns = { "*" }, doc = "rows opts.after + 1 to opts.after + opts.limit" })

M.PSS_Provide("q.select", function(set, opts)
	local want = opts and opts.select
	if type(want) ~= "table" then error("no select", 0) end
	local at = {}
	for i, name in ipairs(want) do at[i] = col(set, name) end
	local o, pooled = out("q.select", want, opts)
	for i = 1, set.n do
		local row = pooled and M.PSS_SetNext(o) or {}
		for k = 1, #at do row[k] = set[i][at[k]] end
		if not pooled then M.PSS_SetAdd(o, row) end
	end
	return o
end, { accepts = { "*" }, returns = { "*" }, doc = "keeps only the columns named in opts.select" })

local STEPS = { "where", "join", "by", "order", "limit", "select" }

-- every step runs unguarded inside this one pcall (PSS_Bus M.PSS_CallRaw), so a
-- failing step is one ring entry and one answer, not one guard per step
local function steps(q, set)
	local opts = { where = q.where, join = q.join, by = q.by, sum = q.sum, order = q.order, limit = q.limit, after = q.after, select = q.select, reuse = q.reuse }
	for _, step in ipairs(STEPS) do
		-- an order with a limit does both in one pass; a limit alone takes its page
		if q[step] ~= nil and not (step == "limit" and q.order ~= nil) then set = M.PSS_CallRaw("q." .. step, set, opts) end
	end
	return set
end

function M.PSS_Query(q)
	local set, err = q.from, nil
	local where = q.where
	if type(set) == "string" then
		local pd = pushdown[set]
		local got
		if pd and type(where) == "table" and where[pd.col] ~= nil and type(where[pd.col]) ~= "table" then
			local ok, res = pcall(pd.fn, where[pd.col], q.key, q.opts)
			if ok and M.PSS_IsSet(res) then
				got = res
				where = {}
				for k, v in pairs(q.where) do if k ~= pd.col then where[k] = v end end
				if next(where) == nil then where = nil end
			end
		end
		if got then
			set = got
		else
			set, err = M.PSS_Call(q.from, q.key, q.opts)
			if not set then return nil, err end
		end
	elseif not M.PSS_IsSet(set) then
		return nil, "arg: from is not a service or a record set"
	end
	local qq = q
	if where ~= q.where then
		qq = {}
		for k, v in pairs(q) do qq[k] = v end
		qq.where = where
	end
	local ok, out = pcall(steps, qq, set)
	if not ok then
		out = M.PSS_ErrFail("q.query", out)
		if M.PSS_NoteListenerError then M.PSS_NoteListenerError("service q.query", out, true) end
		return nil, out
	end
	return out, err
end
