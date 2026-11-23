------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE SERVICE BUS (service-bus-helper, DDS-00010
-- sections 2 and 3). The one shape every service speaks is a record set:
--   set = { cols = { "item", "count" }, n = 2, { 17, 4 }, { 31, 1 } }
-- rows are values by position; n is the row count. Services are named
-- "<store>.<verb>" and called by name, so the output of one is the input
-- of the next:
--   M.PSS_Provide(name, fn, { accepts = { cols }, returns = { cols }, doc })
--   local set, err = M.PSS_Call(name, input, opts)
--   M.PSS_Services()          the bus describes itself, as a record set
-- Loaded with Libraries. Nothing registers an event, makes a frame or
-- touches the window; a failing service returns nil, err and is reported
-- once (M.PSS_NoteListenerError).
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local date = date

local type, pairs, pcall, tostring, next = type, pairs, pcall, tostring, next
local sort, concat = table.sort, table.concat

local services = {}		-- [name] = { fn, accepts, returns, doc }
local colIndex = setmetatable({}, { __mode = "k" })		-- [set] = { name = column }

------------------------------------------------------------------------
-- Record sets
------------------------------------------------------------------------
function M.PSS_Set(cols)
	return { cols = cols, n = 0 }
end

function M.PSS_IsSet(v)
	return type(v) == "table" and type(v.cols) == "table" and type(v.n) == "number"
end

function M.PSS_SetAdd(set, row)
	local n = set.n + 1
	set.n = n
	set[n] = row
	return row
end

-- the row after the last, reused when one is left from an earlier fill
-- (opts.reuse: a redraw allocates nothing); the caller sets every column
function M.PSS_SetNext(set)
	local n = set.n + 1
	local row = set[n]
	if not row then row = {}; set[n] = row end
	set.n = n
	return row
end

function M.PSS_SetClear(set)
	set.n = 0
end

-- the index of a column by name (cached per set), nil when it has none
function M.PSS_SetCol(set, name)
	local idx = colIndex[set]
	if not idx then
		idx = {}
		for i = 1, #set.cols do idx[set.cols[i]] = i end
		colIndex[set] = idx
	end
	return idx[name]
end

-- how a time cell is shown: day month year hour:minute (DEC-00401)
M.PSS_TIME_SHOW = "%d %b %Y %H:%M"

-- text of one table cell: blank for nil and secret values; with the column's kind, the friendly text of M.PSS_Fields.show;
-- else time as day month year hour:minute
function M.PSS_CellText(col, v, kind)
	if M.PSS_IsSecret(v) or v == nil then return "" end
	if kind and M.PSS_Fields then return M.PSS_Fields.show(kind, v, col) end
	if (col == "time" or col == "ts") and type(v) == "number" and v > 0 then return date(M.PSS_TIME_SHOW, v) end
	return tostring(v)
end

------------------------------------------------------------------------
-- The bus
------------------------------------------------------------------------
-- spec: accepts / returns (column lists), doc, cost, paged, and the error
-- contract (one-build plan STP-p01): onError "empty" | "last" | "default",
-- default (a set or a function), ver (function: the source's version, for
-- "last"), retry = 1 (a failed write runs once more after the next settle,
-- out of combat), critical, writes.
function M.PSS_Provide(name, fn, spec)
	if type(name) ~= "string" or not name:find("^[%w_]+%.[%w_.]+$") or type(fn) ~= "function" then
		local T = M.PSS_Test
		if T and T.strict then error("bad service declaration: " .. tostring(name), 2) end
		if M.PSS_ErrNote then M.PSS_ErrNote("arg", tostring(name), "bad service declaration") end
		return
	end
	spec = spec or {}
	services[name] = { fn = fn, accepts = spec.accepts or {}, returns = spec.returns or {}, doc = spec.doc, cost = spec.cost,
		paged = spec.paged, writes = spec.writes, onError = spec.onError, default = spec.default, ver = spec.ver,
		retry = spec.retry, critical = spec.critical }
end

-- a service declared now and built on its first call (one-build plan A10): the
-- name and the contract are known to discovery at once, `load()` returns the
-- real function and nothing of it is built until someone calls
function M.PSS_ProvideStub(name, spec, load)
	M.PSS_Provide(name, function(set, opts)
		local real = load()
		if type(real) ~= "function" then error("missing: " .. name .. " could not be built", 0) end
		local svc = services[name]
		if svc then svc.fn = real; svc.stub = nil end
		return real(set, opts)
	end, spec)
	if services[name] then services[name].stub = true end
end

function M.PSS_ServiceIsStub(name)
	local s = services[name]
	return s ~= nil and s.stub == true
end

-- what a service declares (a copy; nil when it does not exist)
function M.PSS_ServiceInfo(name)
	local s = services[name]
	if not s then return nil end
	return { accepts = s.accepts, returns = s.returns, doc = s.doc, cost = s.cost, paged = s.paged, writes = s.writes,
		onError = s.onError, retry = s.retry, critical = s.critical }
end

local KEYCOLS = { "key" }
local pool = {}			-- [depth] = a one-row key set, reused (a key call allocates nothing once warm)
local depth = 0
local retryQ = {}		-- [service] = { { input, opts }, ... } : a direct call's failed inputs, key sets merged (a trigger row keeps its own keys)

local function keySet(v)
	local s = pool[depth]
	if not s then s = { cols = KEYCOLS, n = 1, { false } }; pool[depth] = s end
	s[1][1] = v
	return s
end

-- a key, a { key = ... } table and a one-row set are the same call
local function Normalize(input)
	local t = type(input)
	if t == "string" or t == "number" then return keySet(input) end
	if t == "table" and not M.PSS_IsSet(input) and input.key ~= nil and next(input, "key") == nil and next(input) == "key" then
		return keySet(input.key)
	end
	return input
end

local function copySet(set)
	if not M.PSS_IsSet(set) then return set end
	local c = { cols = set.cols, n = set.n }
	for i = 1, set.n do
		local row, r = set[i], {}
		for j = 1, #row do r[j] = row[j] end
		c[i] = r
	end
	return c
end

local function emptyLike(svc, input)
	local cols = svc.returns
	if (cols[1] == "*" or #cols == 0) and M.PSS_IsSet(input) then cols = input.cols end
	return { cols = cols, n = 0 }
end

-- what a failing call gives back: the service's policy set, or nil
local function fallback(svc, input, err)
	local p = svc.onError
	if p == "empty" then
		return emptyLike(svc, input), err
	elseif p == "last" then
		local l = svc.last
		if l and (not svc.ver or l.ver == svc.ver()) then return l.set, err end
		return emptyLike(svc, input), err
	elseif p == "default" then
		local d = svc.default
		if type(d) == "function" then d = d() end
		if M.PSS_IsSet(d) then return d, err end
		return emptyLike(svc, input), err
	end
	return nil, err
end

local function Fail(name, svc, input, err, opts)
	err = M.PSS_ErrFail(name, err)		-- ring, breaker; the text starts with its code
	if M.PSS_NoteListenerError then M.PSS_NoteListenerError("service " .. name, err, true) end
	if svc.retry and not M.PSS_InRow and M.PSS_IsSet(input) then
		local q = retryQ[name]
		if not q then q = {}; retryQ[name] = q end
		local last = q[#q]
		if last and last.opts == opts and #input.cols == 1 and input.cols[1] == "key" and #last.input.cols == 1 and last.input.cols[1] == "key" then
			local have = {}
			for i = 1, last.input.n do have[last.input[i][1]] = true end
			for i = 1, input.n do
				local k = input[i][1]
				if not have[k] then have[k] = true; last.input.n = last.input.n + 1; last.input[last.input.n] = { k } end
			end
		elseif #q < 8 then
			q[#q + 1] = { input = copySet(input), opts = opts }
		end
	end
	return fallback(svc, input, err)
end

local function runRetries()
	for name, q in pairs(retryQ) do
		retryQ[name] = nil
		local svc = services[name]
		if svc then
			for _, r in ipairs(q) do
				local ok, out = pcall(svc.fn, r.input, r.opts)
				if ok and M.PSS_IsSet(out) then M.PSS_ErrOk(name)
				else M.PSS_ErrFail(name, ok and "fail: retry returned no record set" or out) end
			end
		end
	end
end

-- called after a settle (M.PSS_ErrSettle): pending retries run out of combat
function M.PSS_BusRetry()
	if next(retryQ) == nil then return end
	if M.PSS_When then M.PSS_When("nocombat", runRetries) else runRetries() end
end

function M.PSS_Call(name, input, opts)
	local svc = services[name]
	if not svc then
		if M.PSS_ErrNote then M.PSS_ErrNote("missing", tostring(name), "no service") end
		return nil, "missing: no service " .. tostring(name)
	end
	if M.PSS_WatchPull then M.PSS_WatchPull(name) end		-- a reader's trigger rows settle first (pull)
	local secret = M.PSS_IsSecret
	if secret then
		local t = type(input)
		if (t == "string" or t == "number") and secret(input) or t == "table" and secret(input.key) then
			M.PSS_ErrNote("secret", name, "secret value")
			return fallback(svc, nil, "secret: secret value")
		end
	end
	if M.PSS_ErrOpen(name) then
		M.PSS_ErrNote("fail", name, "breaker open")
		return fallback(svc, nil, "fail: breaker open")
	end
	depth = depth + 1
	local set = Normalize(input)
	local T = M.PSS_Test
	local ok, out
	if T and T.fault and (T.fault == "*" or T.fault == name) then
		ok, out = false, "fail: injected fault"
	elseif T and T.trace then		-- the harness wants the stack of a failing service
		ok, out = xpcall(function() return svc.fn(set, opts) end, debug.traceback)
	else
		ok, out = pcall(svc.fn, set, opts)
	end
	depth = depth - 1
	if not ok then return Fail(name, svc, set, out, opts) end
	if out ~= nil and not M.PSS_IsSet(out) then return Fail(name, svc, set, "fail: returned a value that is not a record set") end
	if out == set and set == pool[depth + 1] then out = copySet(out) end		-- never hand out the reused key set
	if svc.onError == "last" and out then svc.last = { set = out, ver = svc.ver and svc.ver() } end
	M.PSS_ErrOk(name)
	return out
end

-- the same call without the guard: an error raises (a query pipeline wraps all
-- of its steps in one pcall and reports one ring entry)
function M.PSS_CallRaw(name, input, opts)
	local svc = services[name]
	if not svc then error("missing: no service " .. tostring(name), 0) end
	if M.PSS_WatchPull then M.PSS_WatchPull(name) end
	local out = svc.fn(input, opts)
	if out ~= nil and not M.PSS_IsSet(out) then error("fail: " .. name .. " returned a value that is not a record set", 0) end
	return out
end

-- name, accepts, returns (column lists joined by commas), sorted by name
function M.PSS_Services()
	local names = {}
	for name in pairs(services) do names[#names + 1] = name end
	sort(names)
	local set = { cols = { "name", "accepts", "returns" }, n = #names }
	for i = 1, #names do
		local svc = services[names[i]]
		set[i] = { names[i], concat(svc.accepts, ","), concat(svc.returns, ",") }
	end
	return set
end

------------------------------------------------------------------------
-- Signals and trigger rows (core PSS_Watch.lua, the engine PSS_Trig.lua)
------------------------------------------------------------------------
-- our own acts (a move done, a sale, a scan finished, a window opened)
-- wake the trigger rows and the needs that list "@name"; nothing runs on a clock
function M.PSS_Signal(name, set)
	if type(name) ~= "string" then return end
	if M.PSS_WatchSignal then M.PSS_WatchSignal(name, set) end
	if M.PSS_TrigSignal then M.PSS_TrigSignal(name, set) end
end

-- every declared trigger row as a record set: id, gate, on, settle, run, live
function M.PSS_Triggers()
	local rows, live = M.PSS_WatchRows()
	local set = { cols = { "id", "gate", "on", "settle", "run", "live" }, n = #rows }
	for i = 1, #rows do
		local r = rows[i]
		local settle = r.settle
		if type(settle) == "table" then settle = concat(settle, ",") end
		set[i] = { r.id, r.gate or "", concat(r.on, ","), settle or "", r.run, live[r.id] ~= nil }
	end
	return set
end

M.PSS_Provide("trig.rows", function() return M.PSS_Triggers() end, { returns = { "id", "gate", "on", "settle", "run", "live" }, doc = "every trigger row" })

M.PSS_Provide("err.rows", function() return M.PSS_ErrRows() end, { returns = { "code", "service", "message", "count", "first", "last" },
	doc = "the last distinct service errors", cost = "O(50)", writes = false, onError = "empty" })

-- the upgrade helper's services (core PSS_Upgrade.lua holds the work): the plan,
-- the state, and the one retry that the trigger row upgretry runs
M.PSS_Provide("upg.plan", function()
	local set = { cols = { "step", "feature", "state" }, n = 0 }
	for _, r in ipairs(M.PSS_UpgradePlan()) do M.PSS_SetAdd(set, r) end
	return set
end, { returns = { "step", "feature", "state" }, doc = "the upgrade steps and whether each is done, due or always", cost = "O(steps)", writes = false, onError = "empty" })

M.PSS_Provide("upg.status", function()
	local rec = type(PourSocialScoreDB) == "table" and PourSocialScoreDB.upgrade or {}
	return { cols = { "step", "version", "fail", "undo" }, n = 1, { tonumber(rec.step) or 0, tostring(rec.version or ""), tostring(rec.fail or ""), rec.undo ~= nil } }
end, { returns = { "step", "version", "fail", "undo" }, doc = "where the upgrade stands", cost = "O(1)", writes = false, onError = "empty" })

M.PSS_Provide("upg.retry", function(set)
	M.PSS_UpgradeRetry()
	return set
end, { accepts = { "key" }, returns = { "key" }, doc = "the one retry of a paused upgrade, out of combat", writes = true, onError = "empty" })
