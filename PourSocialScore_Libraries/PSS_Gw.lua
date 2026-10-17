------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE GATEWAY (warehouse-helper / service-bus-helper,
-- one-build plan STP-p14). Other addons call PSS through a gateway and
-- never through a service: a manifest row per external call says which
-- service answers it, its argument contract, the shape of the answer and the
-- value to give when anything fails. The gateway holds no logic of its own
-- (the author, 2026-10-16): it checks the contract, refuses a secret value,
-- runs the row's translation in a pcall and gives the documented empty value
-- when the call fails; a row marked `raise` lets a contract breach raise the
-- error the original addon raises.
--   M.PSS_GwRows(addon, rows)     declare the rows of one addon
--   M.PSS_GwBuild(addon, root)    put a function for every row (and alias) into root
--   M.PSS_GwLint(addon)           problems found: a list of text lines
--   M.PSS_GwSample(row)           arguments that satisfy a row's contract
--   M.PSS_GwHooks()               a callback registry (RegisterCallback, UnregisterCallback)
-- Row: { path, aliases, svc, contract, shape, flags, empty, raise, run }
-- Contract letters: s string, n number, b boolean, t table, f function, ? optional.
-- Loaded with Libraries; returns at the top while the Warehouse is off.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, pairs, ipairs, pcall, error, tostring, select, unpack = type, pairs, ipairs, pcall, error, tostring, select, unpack
local sort = table.sort

local manifests = {}
M.PSS_GwShapes = M.PSS_GwShapes or {}
local LETTER = { s = "string", n = "number", b = "boolean", t = "table", f = "function" }

function M.PSS_GwRows(name, rows) manifests[name] = rows end
function M.PSS_GwManifest(name) return manifests[name] end

-- "s,b?,b?" -> { {type, optional}, ... }
local function parse(contract)
	local out = {}
	if contract == "-" or contract == "" then return out end
	for tok in (contract .. ","):gmatch("([^,]*),") do
		local l, opt = tok:sub(1, 1), tok:sub(2, 2) == "?"
		out[#out + 1] = { LETTER[l], opt }
	end
	return out
end

local function copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = copy(x) end
	return c
end

local function secret(...)
	local s = M.PSS_IsSecret
	if not s then return false end
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if (type(v) == "string" or type(v) == "number") and s(v) then return true end
	end
	return false
end

local function wrap(row)
	local spec = parse(row.contract)
	local run = row.run
	return function(...)
		local n = select("#", ...)
		for i, want in ipairs(spec) do
			local v = (select(i, ...))
			if v == nil then
				if not want[2] then
					if row.raise then error(row.raise, 2) end
					return copy(row.empty)
				end
			elseif type(v) ~= want[1] then
				if row.raise then error(row.raise, 2) end
				return copy(row.empty)
			end
		end
		if secret(...) then return copy(row.empty) end
		local ok, a, b = pcall(run, ...)
		if ok then return a, b end
		if type(a) == "string" and a:sub(1, 3) == "gw:" then error(a:sub(4), 2) end		-- a breach the original addon raises too
		if M.PSS_ErrNote then M.PSS_ErrNote("fail", "gw." .. row.path, tostring(a)) end
		return copy(row.empty)
	end
end

-- a function for every row and alias; `path` is "Group.Name" below the root
function M.PSS_GwBuild(name, root)
	for _, row in ipairs(manifests[name] or {}) do
		local f = wrap(row)
		for _, path in ipairs({ row.path, unpack(row.aliases or {}) }) do
			local t = root
			local from = 1
			while true do
				local dot = path:find(".", from, true)
				if not dot then break end
				local part = path:sub(from, dot - 1)
				t[part] = t[part] or {}
				t = t[part]
				from = dot + 1
			end
			t[path:sub(from)] = f
		end
	end
end

function M.PSS_GwSample(row)
	if row.sample then return row.sample() end
	local out, spec = {}, parse(row.contract)
	for i, want in ipairs(spec) do
		local t = want[1]
		if t == "string" then out[i] = "x" elseif t == "number" then out[i] = 1 elseif t == "boolean" then out[i] = false
		elseif t == "table" then out[i] = {} else out[i] = function() end end
	end
	return unpack(out, 1, #spec)
end

-- every row has a service that exists, a valid contract, a shape, an empty value and a translation; a row that
-- writes says so, and a row that does not write names a service that does not
function M.PSS_GwLint(name)
	local bad = {}
	for _, row in ipairs(manifests[name] or {}) do
		local svc = type(row.svc) == "string" and row.svc or nil
		local info = svc and M.PSS_ServiceInfo and M.PSS_ServiceInfo(svc)
		if not (info or row.svc == "-") then bad[#bad + 1] = row.path .. ": no service " .. tostring(row.svc) end
		if info and (info.writes and true or false) ~= ((row.flags or ""):find("w", 1, true) and true or false) then bad[#bad + 1] = row.path .. ": write flag does not match " .. svc end
		if not tostring(row.contract):match("^[snbtf%?,%-]*$") then bad[#bad + 1] = row.path .. ": bad contract" end
		if row.shape == nil or (row.shape ~= "none" and not M.PSS_GwShapes[row.shape]) then bad[#bad + 1] = row.path .. ": no shape " .. tostring(row.shape) end
		if type(row.run) ~= "function" then bad[#bad + 1] = row.path .. ": no translation" end
	end
	return bad
end

-- a callback registry in our own table (no Blizzard mixin state): fn(owner, ...)
function M.PSS_GwHooks()
	local list = {}
	local reg = {}
	function reg:RegisterCallback(event, fn, owner)
		if type(event) ~= "string" or type(fn) ~= "function" then return end
		local l = list[event]
		if not l then l = {}; list[event] = l end
		l[#l + 1] = { fn, owner }
	end
	function reg:UnregisterCallback(event, owner)
		local l = list[event]
		if not l then return end
		for i = #l, 1, -1 do if l[i][2] == owner then table.remove(l, i) end end
	end
	function reg:TriggerEvent(event, ...)
		local l = list[event]
		if not l then return end
		local copyL = {}
		for i = 1, #l do copyL[i] = l[i] end
		for i = 1, #copyL do
			local ok, err = pcall(copyL[i][1], copyL[i][2], ...)		-- one failing listener never stops the others
			if not ok and M.PSS_NoteListenerError then M.PSS_NoteListenerError("callback " .. event, err) end
		end
	end
	function reg:Count(event) return list[event] and #list[event] or 0 end
	return reg
end
