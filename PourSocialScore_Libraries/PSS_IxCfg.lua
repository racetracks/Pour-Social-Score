------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE CONFIGURATION AND SYSTEM INDEXES (search-helper,
-- STP-00246). Settings and PSS's own state as Spyglass indexes, read only:
--   cfg     key value default section changed     (M.PSS_OPTIONS, M.PSS_Opt)
--   addons  set place name addons owner           (the addon manager's profiles; a string from a
--                                                   newer version is listed as kept, never decoded)
--   dtt     list item                             (Drop Cheapest Thing's always and never lists)
--   gfx     set time count                        (the last graphics sets)
--   macros  set name store                        (PSS_MacroData.lua, Camelot)
--   trig    id gate on settle run live            (trig.rows)
--   upg     step done feature                     (upg.plan)
--   err     code service message count first last (err.rows)
-- No adapter writes. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local match, gmatch, sort = string.match, string.gmatch, table.sort

local function each(list, r, emit, fill)
	local n = 0
	for _, x in ipairs(list) do
		fill(x, r)
		n = n + 1
		if emit(r) == false then return n end
	end
	return n
end

local function setRows(name, fill)
	return function(pd, emit)
		local set = M.PSS_ServiceInfo(name) and M.PSS_Call(name)
		local r, n = {}, 0
		for i = 1, set and set.n or 0 do
			fill(set[i], r)
			n = n + 1
			if emit(r) == false then return n end
		end
		return n
	end
end

local function str(v)
	if v == nil then return nil end
	if type(v) == "table" then return "(table)" end
	return tostring(v)
end

M.PSS_IxDeclare({
	name = "cfg", kind = "state", owner = "options-helper", residency = 0,
	fields = { { "key", "k", "the option key" }, { "value", "s", "its value" }, { "default", "s", "its default" },
		{ "section", "n", "the Options section" }, { "changed", "b", "not the default" } },
	pushdown = {}, schemaKeys = { "options.charOptions" },
	doc = "every option, its value and its default",
	cost = function() return #M.PSS_OPTIONS end,
	scan = function(pd, emit)
		return each(M.PSS_OPTIONS, {}, emit, function(o, r)
			local v = M.PSS_Opt(o.key)
			r.key, r.value, r.default, r.section = o.key, str(v), str(o.default), o.section
			r.changed = (v ~= o.default and type(v) ~= "table") and 1 or nil
		end)
	end,
})

M.PSS_IxDeclare({
	name = "addons", kind = "state", owner = "addon-helper", gate = "addons", residency = 0,
	fields = { { "set", "s", "the profile's name" }, { "place", "s", "1 to 25 or a class" }, { "name", "s", "the label shown" },
		{ "addons", "n", "how many addons it holds" }, { "owner", "s", "this character's entity id, or all" } },
	pushdown = {}, schemaKeys = { "options.addonSets", "options.addonLock", "options.addonView", "options.addonSel", "options.addonPick",
		"owned.addonSetsOf", "owned.addonLockOf", "owned.addonSelOf", "owned.addonPickOf" },
	doc = "the addon manager's profiles",
	scan = function(pd, emit)
		if not M.PSS_AddonSlots then return 0 end
		local r, n = {}, 0
		local me = M.PSS_Me and M.PSS_Me(false)
		for _, who in ipairs({ "me", "all" }) do
			for _, s in ipairs(M.PSS_AddonSlots(who)) do
				if s.hidden or not s.empty then
					r.place, r.owner = tostring(s.id), who == "all" and "all" or tostring(me or "me")
					if s.hidden then r.set, r.name, r.addons = nil, "(kept: saved by a newer version)", nil
					else r.set, r.name, r.addons = s.name, s.label, s.n end
					n = n + 1
					if emit(r) == false then return n end
				end
			end
		end
		return n
	end,
})

local function dttIds(text)
	local list = {}
	if type(text) ~= "string" then return list end
	local body = match(text, "^1;(.*)$")
	if not body then return list end		-- another layout: kept, not read
	for id in gmatch(body, "[^,]+") do list[#list + 1] = tonumber(id) or id end
	return list
end

M.PSS_IxDeclare({
	name = "dtt", kind = "state", owner = "money-helper", gate = "dtt", residency = 0,
	fields = { { "list", "k", "always or never" }, { "item", "i", "the item" } },
	dicts = { item = "item" }, pushdown = {}, schemaKeys = { "options.dttAlways", "options.dttNever" },
	doc = "Drop Cheapest Thing's always and never lists",
	scan = function(pd, emit)
		local r, n = {}, 0
		for _, list in ipairs({ "always", "never" }) do
			for _, id in ipairs(dttIds(M.PSS_Opt(list == "always" and "dttAlways" or "dttNever"))) do
				r.list, r.item = list, id
				n = n + 1
				if emit(r) == false then return n end
			end
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "gfx", kind = "state", owner = "gfx-helper", gate = "gfx", residency = 0,
	fields = { { "set", "n", "1 newest to 5" }, { "time", "t", "when it was saved" }, { "count", "n", "settings in it" } },
	pushdown = {}, schemaKeys = { "options.gfxSets", "options.gfxPending" },
	doc = "the last graphics settings sets",
	scan = function(pd, emit)
		local sets = type(PourSocialScoreDB) == "table" and PourSocialScoreDB.gfxSets
		local r, n = {}, 0
		for i, s in ipairs(type(sets) == "table" and sets or {}) do
			if type(s) == "string" then
				local head, body = match(s, "^([^\n]*)\n?(.*)$")
				local c = 0
				for _ in gmatch(body or "", "[^\n]+") do c = c + 1 end
				r.set, r.time, r.count = i, tonumber(match(head or "", "(%d%d%d%d%d%d%d%d+)")), c
				n = n + 1
				if emit(r) == false then return n end
			end
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "macros", kind = "state", owner = "macro-helper", residency = 0,
	fields = { { "set", "k", "global or a class" }, { "name", "s", "the macro" }, { "store", "k", "account or character" } },
	pushdown = {}, doc = "the macros Macro Helper writes (Forever)",
	scan = function(pd, emit)
		if not M.PSS_MacroData then return 0 end
		local data = M.PSS_MacroData()
		local sets = {}
		for k in pairs(data) do sets[#sets + 1] = k end
		sort(sets)
		local r, n = {}, 0
		for _, set in ipairs(sets) do
			for _, mac in ipairs(data[set]) do
				r.set, r.name, r.store = set, mac.name, mac.store or data[set].store
				n = n + 1
				if emit(r) == false then return n end
			end
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "trig", kind = "state", owner = "service-bus-helper", residency = 0,
	fields = { { "id", "s", "the row" }, { "gate", "s", "its component" }, { "on", "s", "what wakes it" }, { "settle", "s", "when it runs" },
		{ "run", "s", "the service it calls" }, { "live", "b", "registered now" } },
	pushdown = {}, doc = "every trigger row",
	scan = setRows("trig.rows", function(x, r) r.id, r.gate, r.on, r.settle, r.run, r.live = x[1], x[2], x[3], x[4], x[5], x[6] and 1 or nil end),
})

M.PSS_IxDeclare({
	name = "upg", kind = "state", owner = "migration-helper", residency = 0,
	fields = { { "step", "n", "the upgrade step" }, { "done", "b", "done on this save" }, { "feature", "k", "what it upgrades" } },
	pushdown = {}, schemaKeys = { "core.upgrade" }, doc = "the upgrade steps and where this save stands",
	scan = setRows("upg.plan", function(x, r) r.step, r.feature, r.done = x[1], x[2], x[3] == "done" and 1 or nil end),
})

M.PSS_IxDeclare({
	name = "err", kind = "state", owner = "service-bus-helper", residency = 0,
	fields = { { "code", "k", "the error code" }, { "service", "s", "where" }, { "message", "s", "what" }, { "count", "n", "how often" },
		{ "first", "t", "first seen" }, { "last", "t", "last seen" } },
	pushdown = {}, doc = "the last distinct service errors this session",
	scan = setRows("err.rows", function(x, r) r.code, r.service, r.message, r.count, r.first, r.last = x[1], x[2], x[3], x[4], x[5], x[6] end),
})
