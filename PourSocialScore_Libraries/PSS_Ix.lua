------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE INDEX REGISTRY (search-helper, STP-00232,
-- DDS-00031 section 3). Every Spyglass index is declared once, as data:
--   M.PSS_IxDeclare(spec)       validates and registers; a bad spec raises
--                               "ix: <name>: <field>" (a programming error)
--   M.PSS_Ix(name)              the Index object (nil when unknown)
--   M.PSS_IxList()              record set name, kind, owner, residency, rows, on, doc
--   M.PSS_IxFields(name)        record set field, kind, doc
--   M.PSS_IxNames()             the declared names, in declaration order
-- Index methods (shared, one metatable):
--   ix:ready() -> true | false, "off" | "newer"     ix:needs() -> part key or nil
--   ix:cost(pd) -> rows                              ix:scan(pd, emit, ctx) -> n, partial | nil, err
-- A scan that raises is turned into nil, err and noted once (M.PSS_ErrFail).
-- Services ix.list and ix.fields. No frame, no event, no saved data.
-- Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, pcall, error, tostring, tonumber, setmetatable = type, pairs, ipairs, pcall, error, tostring, tonumber, setmetatable

local ix, order = {}, {}
local FKINDS = { t = true, n = true, s = true, b = true, e = true, i = true, d = true, c = true, k = true }
M.PSS_IX_FKINDS = FKINDS
local ENVELOPE = { time = true, st = true, ent = true, index = true }

local X = {}
local IXMT = { __index = X }

local function bad(name, field) error("ix: " .. tostring(name) .. ": " .. field, 3) end

function M.PSS_IxDeclare(spec)
	if type(spec) ~= "table" then bad("?", "spec") end
	local name = spec.name
	if type(name) ~= "string" or not name:find("^[a-z][a-z0-9]*$") or #name > 8 then bad(name, "name") end
	if ix[name] then bad(name, "duplicate") end
	if spec.kind ~= "event" and spec.kind ~= "state" then bad(name, "kind") end
	if type(spec.owner) ~= "string" or spec.owner == "" then bad(name, "owner") end
	if spec.gate ~= nil and type(spec.gate) ~= "string" then bad(name, "gate") end
	local r = spec.residency
	if r ~= 0 and r ~= 1 and r ~= 2 then bad(name, "residency") end
	if r == 1 and type(spec.needs) ~= "string" then bad(name, "needs") end
	if type(spec.fields) ~= "table" or #spec.fields == 0 then bad(name, "fields") end
	local has = {}
	for i, f in ipairs(spec.fields) do
		if type(f) ~= "table" or type(f[1]) ~= "string" or not f[1]:find("^[%a_][%w_]*$") then bad(name, "fields[" .. i .. "]") end
		if not FKINDS[f[2]] then bad(name, "fields." .. f[1] .. ".kind") end
		if has[f[1]] then bad(name, "fields." .. f[1] .. ".duplicate") end
		has[f[1]] = f[2]
	end
	if spec.kind == "event" and not (has.time and has.st) then bad(name, "fields.time") end
	if spec.dicts ~= nil then
		if type(spec.dicts) ~= "table" then bad(name, "dicts") end
		for f, d in pairs(spec.dicts) do
			if not has[f] or type(d) ~= "string" then bad(name, "dicts." .. tostring(f)) end
		end
	end
	if type(spec.pushdown) ~= "table" then bad(name, "pushdown") end
	for _, f in ipairs(spec.pushdown) do
		if not has[f] then bad(name, "pushdown." .. tostring(f)) end
	end
	if type(spec.scan) ~= "function" then bad(name, "scan") end
	if spec.cost ~= nil and type(spec.cost) ~= "function" then bad(name, "cost") end
	if spec.summary ~= nil and type(spec.summary) ~= "function" then bad(name, "summary") end
	if spec.schemaKeys ~= nil and type(spec.schemaKeys) ~= "table" then bad(name, "schemaKeys") end
	if type(spec.doc) ~= "string" or spec.doc == "" then bad(name, "doc") end
	-- the spec's functions move off the method names (ix:scan, ix:cost, ix:needs are the guarded methods)
	spec._scan, spec._cost, spec.part = spec.scan, spec.cost, spec.needs
	spec.scan, spec.cost, spec.needs = nil, nil, nil
	spec.has, spec.scans = has, 0
	local text = {}
	for _, f in ipairs(spec.fields) do if f[2] == "s" then text[#text + 1] = f[1] end end
	spec.textFields = text
	ix[name] = setmetatable(spec, IXMT)
	order[#order + 1] = name
	if M.PSS_DataDictCheck then M.PSS_DataDictCheck(spec) end
	if M.PSS_DataDictDrop then M.PSS_DataDictDrop(name) end
	return ix[name]
end

function X:ready()
	if self.gate and not M.PSS_On(self.gate) then return false, "off" end
	if self.newer and self.newer() then return false, "newer" end
	return true
end

-- the folder a tier 1 scan needs, while it is not loaded
function X:needs()
	if self.residency ~= 1 then return nil end
	if self.loaded and self.loaded() then return nil end
	return self.part
end

function X:cost(pd)
	local f = self._cost
	if not f then return 0 end
	local ok, n = pcall(f, pd or {})
	return ok and tonumber(n) or 0
end

function X:scan(pd, emit, ctx)
	local ok, why = self:ready()
	if not ok then return 0, false, why end
	self.scans = self.scans + 1
	local okc, n, partial = pcall(self._scan, pd or {}, emit, ctx or {})
	if not okc then return nil, M.PSS_ErrFail("ix." .. self.name, n) end
	return n or 0, partial == true
end

function X:fieldKind(f)
	if ENVELOPE[f] and not self.has[f] then
		if f == "index" or f == "st" then return "k" end
		if f == "time" then return "t" end
		return "e"
	end
	return self.has[f]
end

function M.PSS_Ix(name) return ix[name] end
function M.PSS_IxNames() return order end

local LISTCOLS = { "name", "kind", "owner", "residency", "rows", "on", "doc" }
function M.PSS_IxList()
	local set = { cols = LISTCOLS, n = 0 }
	for _, name in ipairs(order) do
		local x = ix[name]
		set.n = set.n + 1
		set[set.n] = { name, x.kind, x.owner, x.residency, x:cost({}), (x:ready()), x.doc }
	end
	return set
end

local FIELDCOLS = { "field", "kind", "doc" }
function M.PSS_IxFields(name)
	local x = ix[name]
	if not x then return nil, "index: no index " .. tostring(name) end
	local set = { cols = FIELDCOLS, n = 0 }
	for _, f in ipairs(x.fields) do
		set.n = set.n + 1
		set[set.n] = { f[1], f[2], f[3] or "" }
	end
	return set
end

M.PSS_Provide("ix.list", function() return M.PSS_IxList() end, { returns = LISTCOLS, doc = "every Spyglass index", cost = "O(indexes)", writes = false, onError = "empty" })
M.PSS_Provide("ix.fields", function(input)
	local name = input and (input.name or (input.cols and input[1] and input[1][1]))
	local set, err = M.PSS_IxFields(name)
	if not set then error(err, 0) end
	return set
end, { accepts = { "name" }, returns = FIELDCOLS, doc = "the fields of an index", cost = "O(fields)", writes = false })
