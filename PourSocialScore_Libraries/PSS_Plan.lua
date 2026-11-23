------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE PLANNER AND RUNNER (search-helper, STP-00242 and
-- STP-00287, DDS-00031 section 7). One call answers a PSQL query:
--   M.PSS_Search(textOrPlan, opts) -> set, info | nil, { code, pos, msg }
--     opts = { params, from, to, rows, load, budget }
--     info = { scanned, ms, partial, tier, needs, indexes, shape, cached, notes, pending, resolved, ambiguous, chart }
--   service ix.search { q, params, load, rows } -> the set (info as set.info)
--   M.PSS_SearchDrop()   empties the plan cache (a GC request)
-- 1 the plan (32 texts cached); 2 parameters bound into literals; 3 the
-- pushdown (a typed earliest= / latest= wins over the picker's from / to);
-- 4 the tier: an index whose folder is not loaded answers its resident part
-- only, unless opts.load (a click, a command), and says what it needs;
-- 5 each index scanned with the pushdown, rows that pass the predicate kept,
-- stopped at the scan budget (200,000: partial); 6 the steps in order, all
-- in one guard (a failing step is one ring entry); 7 the shape.
-- A search with no index= covers every event index that is on (log, pss,
-- jrn, whh) and its bare words also match the items, owners and characters
-- they name (lazy search). Loaded with Libraries. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, pcall, tostring, tonumber = type, pairs, ipairs, pcall, tostring, tonumber
local sort, remove = table.sort, table.remove

local Q = M.PSS_Psql
local BUDGET = 200000
local CACHE = 32
M.PSS_IX_BUDGET = BUDGET

-- virtual text names of a log or counts row (PSS_Fields.sourceName / splitName / filterNames)
local function virt(name, row, fmap)
	local F = M.PSS_Fields
	if not F then return nil end
	if name == "filter" then
		local o = row.owner
		if M.PSS_IsSecret and M.PSS_IsSecret(o) then return nil end
		if type(o) == "string" and o:sub(1, 2) == "f:" then return fmap[o] or o:sub(3) end
		return nil
	end
	local n = F.sourceName(row)
	if not n then return nil end
	local sender, server = F.splitName(n)
	if name == "sender" then return sender end
	return server
end

-- one virtual value of row r of a set (the Fields panel, a click); the filter map is kept on the set
function M.PSS_SetVirtual(set, r, name)
	if type(set) ~= "table" or type(r) ~= "number" or not Q.VIRTUAL[name] or not set[r] then return nil end
	local F = M.PSS_Fields
	if not F then return nil end
	local mc, oc = M.PSS_SetCol(set, "member"), M.PSS_SetCol(set, "owner")
	local row = { member = mc and set[r][mc], owner = oc and set[r][oc] }
	if name == "filter" and not set.vmap then set.vmap = F.filterNames() end
	return virt(name, row, set.vmap)
end

local cache, order = {}, {}
M.PSS_SearchStats = { hits = 0, misses = 0 }

function M.PSS_SearchDrop()
	cache, order = {}, {}
end

local function cached(text)
	local key = Q.norm(text)
	local plan = cache[key]
	if plan then
		M.PSS_SearchStats.hits = M.PSS_SearchStats.hits + 1
		for i = 1, #order do if order[i] == key then remove(order, i) break end end
		order[#order + 1] = key
		return plan, true
	end
	M.PSS_SearchStats.misses = M.PSS_SearchStats.misses + 1
	local p, e = Q.compile(text)
	if not p then return nil, false, e end
	cache[key] = p
	order[#order + 1] = key
	if #order > CACHE then cache[remove(order, 1)] = nil end
	return p, false
end

local function now() return debugprofilestop and debugprofilestop() or 0 end

local function loadPart(part)
	if part == "Logging" and M.PSS_LoadLogging then return M.PSS_LoadLogging() end
	return M.PSS_Need and M.PSS_Need(part)
end

local function copyPd(pd)
	local c = {}
	for k, v in pairs(pd or {}) do c[k] = v end
	return c
end

function M.PSS_Search(textOrPlan, opts)
	opts = opts or {}
	local t0 = now()
	local plan, hit, e
	if type(textOrPlan) == "string" then
		plan, hit, e = cached(textOrPlan)
		if not plan then return nil, e end
	elseif type(textOrPlan) == "table" and textOrPlan.ast then
		plan = textOrPlan
	else
		return nil, { code = "arg", pos = 1, msg = "a query text or a plan" }
	end
	if plan.unbound then
		local b, be = plan:bind(opts.params or {})
		if not b then return nil, be end
		plan = b
	end
	local info = { scanned = 0, partial = false, tier = 0, notes = {}, cached = hit, shape = plan:shape(), chart = plan.chart,
		resolved = plan.info.resolved, ambiguous = plan.info.ambiguous }
	local pd = copyPd(plan.pred:pushdown())
	local tm = plan.ast.time
	if tm and (tm.lo or tm.hi) then pd.lo, pd.hi = tm.lo or pd.lo, tm.hi or pd.hi
	else
		if opts.from and (not pd.lo or opts.from > pd.lo) then pd.lo = opts.from end
		if opts.to and (not pd.hi or opts.to < pd.hi) then pd.hi = opts.to end
	end
	-- the indexes
	local names, lazy = plan:indexNames(), false
	if not names then
		lazy = true
		names = {}
		for _, n in ipairs(Q.LAZY) do
			local x = M.PSS_Ix(n)
			if x and x.kind == "event" then names[#names + 1] = n end
		end
	end
	local multi = lazy or #names > 1
	-- the columns
	local cols, at = {}, {}
	if lazy then
		for i, c in ipairs(Q.LAZYCOLS) do cols[i] = c; at[c] = i end
	else
		for _, n in ipairs(names) do
			for _, f in ipairs(M.PSS_Ix(n).fields) do if not at[f[1]] then cols[#cols + 1] = f[1]; at[f[1]] = #cols end end
		end
		if multi then cols[#cols + 1] = "index"; at.index = #cols end
	end
	local vtime = plan.ast.vtime and M.PSS_Time
	if vtime then
		for _, c in ipairs({ "weekday", "hour" }) do if not at[c] then cols[#cols + 1] = c; at[c] = #cols end end
	end
	local vn = {}
	for _, v in ipairs({ "filter", "sender", "server" }) do
		if plan.ast.vnames and plan.ast.vnames[v] then
			vn[#vn + 1] = v
			if not at[v] then cols[#cols + 1] = v; at[v] = #cols end
		end
	end
	local fmap = {}
	if plan.ast.vnames and plan.ast.vnames.filter and M.PSS_Fields then fmap = M.PSS_Fields.filterNames() end
	local set = { cols = cols, n = 0 }
	local budget = opts.budget or M.PSS_IX_BUDGET
	local scanned, stopped = 0, false
	local test = plan.pred.fn
	plan.F.pending = nil
	local events = true
	local single = not multi and M.PSS_Ix(names[1])
	if pd.none then names = {} end		-- a virtual field that names no one: nothing to read
	for _, name in ipairs(names) do
		local x = M.PSS_Ix(name)
		local ok, why = x:ready()
		if not ok then
			info.notes[#info.notes + 1] = name .. ": " .. why
			if single then info.off = why end
		else
			if x.kind ~= "event" then events = false end
			local part = x:needs()
			local ctx = { load = false, budget = budget }
			if part then
				if opts.load and loadPart(part) then
					part = nil
				else
					info.needs = part
					info.tier = 1
				end
			end
			ctx.load = part == nil
			local proven = x.textExact == true and pd.text ~= nil
			local summary = lazy and x.summary
			local n, err = x:scan(pd, function(row)
				scanned = scanned + 1
				if scanned > budget then stopped = true return false end
				if vtime and row.time then row.weekday, row.hour = vtime.weekday(row.time), vtime.hour(row.time) end
				for i = 1, #vn do row[vn[i]] = virt(vn[i], row, fmap) end
				if test(row, proven) then
					local r = {}
					if lazy then
						r[1], r[2], r[3], r[4], r[5], r[6] = row.time, name, row.st, row.ent, row.item, row.owner
						if summary then local okS, s = pcall(summary, row); r[7] = okS and s or nil end
						if vtime then r[at.weekday], r[at.hour] = row.weekday, row.hour end
						for i = 1, #vn do r[at[vn[i]]] = row[vn[i]] end
					else
						for i = 1, #cols do r[i] = row[cols[i]] end
						if multi then r[at.index] = name end
					end
					set.n = set.n + 1
					set[set.n] = r
				end
				return true
			end, ctx)
			if n == nil then
				if single then return nil, { code = M.PSS_ErrSplit(err), pos = 1, msg = tostring(err) } end
				info.notes[#info.notes + 1] = name .. ": " .. tostring(err)
			end
			if stopped then break end
		end
	end
	info.scanned, info.partial = scanned, stopped
	info.pending = plan.F.pending or nil
	info.indexes = names
	-- newest first across indexes (each event index hands its rows newest first already)
	local tc = at.time
	local sorted = true
	if events and tc then
		for i = 2, set.n do
			local x, y = set[i - 1][tc] or 0, set[i][tc] or 0
			if y > x then sorted = false break end
		end
	end
	if events and tc and set.n > 1 and not sorted then
		local pos = {}
		for i = 1, set.n do pos[set[i]] = i end
		local rows = {}
		for i = 1, set.n do rows[i] = set[i] end
		sort(rows, function(a, b)
			local x, y = a[tc] or 0, b[tc] or 0
			if x ~= y then return x > y end
			return pos[a] < pos[b]
		end)
		for i = 1, set.n do set[i] = rows[i] end
	end
	-- the steps, in one guard
	local okRun, out = pcall(function()
		local s = set
		for _, step in ipairs(plan.steps) do
			local svc, so = step[1], step[2]
			if svc == "q.timechart" then
				local c = {}
				for k, v in pairs(so) do c[k] = v end
				c.lo, c.hi = c.lo or pd.lo, c.hi or pd.hi
				if c.lo and not c.hi then c.hi = (M.PSS_Time and M.PSS_Time.now()) end
				so = c
			elseif svc == "q.fieldsummary" and M.PSS_DataDictFor then
				local c = {}
				for k, v in pairs(so) do c[k] = v end
				c.dict = M.PSS_DataDictFor(names)
				so = c
			end
			s = M.PSS_CallRaw(svc, s, so)
			if s and s.partial then info.partial = true end
			if s and s.approx then info.approx = true end
		end
		return s
	end)
	if not okRun then
		local msg = M.PSS_ErrFail("ix.search", out)
		local code = M.PSS_ErrSplit(out)
		return nil, { code = code, pos = 1, msg = msg }
	end
	set = out
	local vf = {}
	for _, n in ipairs(names) do
		if n == "log" or n == "counts" then vf = { "filter", "sender", "server" } break end
	end
	for _, c in ipairs(plan.ast.commands) do
		local n = c.name
		if n == "stats" or n == "top" or n == "rare" or n == "timechart" or n == "chart" then vf = {} break end
	end
	set.vfields = vf
	local rows = opts.rows or Q.conRows
	if rows > (Q.maxRows or 5000) then rows = Q.maxRows or 5000 end
	if set.n > rows then
		for i = rows + 1, set.n do set[i] = nil end
		set.n = rows
		info.truncated = true
	end
	info.ms = now() - t0
	return set, info
end

M.PSS_Provide("ix.search", function(input)
	local q = input and input.q
	if type(q) ~= "string" then error("arg: ix.search takes { q = text }", 0) end
	local set, info = M.PSS_Search(q, { params = input.params, load = input.load, rows = input.rows, from = input.from, to = input.to })
	if not set then error((info.code or "parse") .. ": " .. tostring(info.msg) .. " (at " .. tostring(info.pos) .. ")", 0) end
	set.info = info
	return set
end, { accepts = { "q" }, returns = { "*" }, doc = "answers a Spyglass query", cost = "O(rows scanned)", writes = false })

-- a GC request releases the plans with the declared indexes
if M.PSS_IndexDropAll then
	local drop = M.PSS_IndexDropAll
	M.PSS_IndexDropAll = function(...)
		M.PSS_SearchDrop()
		return drop(...)
	end
end
