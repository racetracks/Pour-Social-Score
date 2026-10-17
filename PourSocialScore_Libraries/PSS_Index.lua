------------------------------------------------------------------------
-- POUR SOCIAL SCORE - DECLARED INDEXES (service-bus-helper, one-build plan
-- STP-p04, optimisation O07). A lookup that runs on a hover, a redraw or a
-- shim call reads a table through one of these, never scans:
--   local idx = M.PSS_Index(name, {
--       sourceVer = function() return store.Ver() end,   -- what the index was built from
--       build = function(add) ... add(key, value) ... end,   -- the whole build
--       -- or, for a build that can be cut in slices:
--       units = function() return array end,  each = function(unit, add) ... end,
--       partial = function(add, drop, ids, data) ... end,     -- rebuild only the dirty ids (data: the index's table, read only)
--       cap = 20000, sliceMs = 4 })
--   idx:get(key) idx:has(key) idx:list() idx:range(lo, hi) idx:count()
--   idx:put(key, value)            keep the index in step with a write you just made
--   idx:step()                     one slice of a build in progress (true when done)
--   M.PSS_IndexDirty(name, ids)    ids whose entries changed (the next lookup rebuilds only them)
--   M.PSS_IndexDrop(name)          release the data   M.PSS_IndexDropAll() on a GC request
-- The methods are shared (a declared index costs one small table, not a set
-- of closures). Built on the first lookup, rebuilt when sourceVer moved (in
-- part when a dirty set and partial exist), released on a GC request and when
-- its component goes off. A build past cap stops adding, tells the error ring
-- (code cap) and serves what fits. A sliced build waits on the trigger engine
-- (class slice); a lookup that arrives first finishes it at once.
-- Loaded with Libraries. No frame, no OnUpdate, no timer of its own.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, setmetatable = type, pairs, setmetatable
local sort = table.sort

local indexes = {}
local X = {}
local MT = { __index = X }

local function ver(self)
	local f = self.spec.sourceVer
	return f and f() or 0
end

-- the builder callbacks are made once per build, not once per lookup
local function add(self, key, value)
	if key == nil then return end
	local data = self.data
	if data[key] == nil then
		local cap = self.spec.cap
		if cap and self.count >= cap then
			if not self.capped then
				self.capped = true
				if M.PSS_ErrNote then M.PSS_ErrNote("cap", "index " .. self.name, "past " .. cap .. " entries: the rest left out") end
			end
			return
		end
		self.count = self.count + 1
	end
	data[key] = value
end

local function finish(self)
	self.job = nil
	self.builtVer = ver(self)
	self.sorted, self.dirtyIds = nil, nil
	self.nBuilds = self.nBuilds + 1
end

-- run units of the build in progress for at most `ms` (nil: to the end)
local function run(self, ms)
	local job, spec = self.job, self.spec
	local units = job.units
	local clock = debugprofilestop
	local t0 = ms and clock and clock() or 0
	local adder = function(k, v) add(self, k, v) end
	while job.i <= #units do
		spec.each(units[job.i], adder)
		job.i = job.i + 1
		if ms and clock and clock() - t0 >= ms then return false end
	end
	finish(self)
	return true
end

local function start(self)
	self.data, self.count, self.capped = {}, 0, false
	local spec = self.spec
	if spec.units and spec.each then
		self.job = { units = spec.units(), i = 1 }
		run(self, nil)
	else
		spec.build(function(k, v) add(self, k, v) end)
		finish(self)
	end
end

local function fresh(self)
	if self.job then run(self, nil) end
	if not self.data then
		start(self)
	elseif self.builtVer ~= ver(self) then
		local spec = self.spec
		if self.dirtyIds and spec.partial then
			spec.partial(function(k, v) add(self, k, v) end, function(k)
				if self.data[k] ~= nil then self.data[k] = nil; self.count = self.count - 1 end
			end, self.dirtyIds, self.data)
			self.builtVer, self.sorted, self.dirtyIds = ver(self), nil, nil
			self.nPartials = self.nPartials + 1
		else
			start(self)
		end
	end
	return self.data
end

function M.PSS_Index(name, spec)
	local I = indexes[name]
	if I then return I end
	I = setmetatable({ name = name, spec = spec, count = 0, nBuilds = 0, nPartials = 0 }, MT)
	indexes[name] = I
	return I
end

function X:get(key) return fresh(self)[key] end
function X:has(key) return fresh(self)[key] ~= nil end
function X:size() fresh(self); return self.count end

local function keys(self)
	local data = fresh(self)
	if not self.sorted then
		local k = {}
		for key in pairs(data) do k[#k + 1] = key end
		sort(k)
		self.sorted = k
	end
	return self.sorted
end

-- the keys in no order (a sorted list costs a sort the caller may not need)
function X:keys()
	local out = {}
	for key in pairs(fresh(self)) do out[#out + 1] = key end
	return out
end

function X:list()
	local k = keys(self)
	local out = {}
	for i = 1, #k do out[i] = k[i] end
	return out
end

-- the keys from lo to hi, in order
function X:range(lo, hi)
	local k, out = keys(self), {}
	for i = 1, #k do
		local key = k[i]
		if (lo == nil or key >= lo) and (hi == nil or key <= hi) then out[#out + 1] = key end
	end
	return out
end

-- a write you just made (after a lookup): keep the index in step instead of rebuilding it
function X:put(key, value)
	if self.data and not self.job and self.builtVer ~= nil then
		if value == nil then
			if self.data[key] ~= nil then self.data[key] = nil; self.count = self.count - 1 end
		else
			add(self, key, value)
		end
		self.builtVer, self.sorted = ver(self), nil
	end
end

function X:markDirty(ids)
	local d = self.dirtyIds or {}
	self.dirtyIds = d
	for _, id in pairs(ids) do d[id] = true end
end

-- one slice of a build in progress; true when there is nothing left to do
function X:step()
	if not self.job then return true end
	return run(self, self.spec.sliceMs or 4)
end

-- begin a build in slices and let the trigger engine run it (class slice)
function X:warm()
	if self.data and not self.job and self.builtVer == ver(self) then return false end
	if not self.job then
		self.data, self.count, self.capped = {}, 0, false
		local spec = self.spec
		if spec.units and spec.each then
			self.job = { units = spec.units(), i = 1 }
		else
			start(self)
			return true
		end
	end
	if M.PSS_Want then
		M.PSS_Unwant("index." .. self.name)		-- one need per index
		M.PSS_Want({ id = "index." .. self.name, class = "slice", once = true, step = function() return self:step() end })
	end
	return true
end

function X:built() return self.data ~= nil and not self.job and self.builtVer == ver(self) end
function X:builds() return self.nBuilds end
function X:partials() return self.nPartials end
function X:drop() self.data, self.sorted, self.dirtyIds, self.job, self.builtVer = nil, nil, nil, nil, nil end
function X:resident() return self.data ~= nil end

function M.PSS_IndexDirty(name, ids)
	local I = indexes[name]
	if I then I:markDirty(ids) end
end

function M.PSS_IndexDrop(name)
	local I = indexes[name]
	if I then I:drop() end
end

function M.PSS_IndexDropAll()
	for _, I in pairs(indexes) do I:drop() end
end
