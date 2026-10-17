------------------------------------------------------------------------
-- POUR SOCIAL SCORE - ENTITIES AND OWNED KEYS (service-bus-helper,
-- DDS-00010 section 11.5, SAV-00034, SAV-00035). Every saved variable is
-- account wide. Data a character owns is an account-wide record keyed by
-- that character's entity id, so nothing reads another character's slot
-- until an interface passes another id.
--   M.PSS_Me(create)                this character's id, or nil until something
--                                   is saved; create = true makes the row
--   M.PSS_EntityId(kind, name, realm, create)
--                                   the id of a character ("c"), guild ("g") or
--                                   the warband ("w"), or nil
--   M.PSS_Entity(id)                the row's fields as a record set
--   M.PSS_Owned(key)                o:Get(id), o:Set(id, value), o:Each(fn) for a
--                                   key in M.PSS_SCHEMA.owned (nil for another)
--   M.PSS_EntityRemove(id)          drops the row and every owned slot
--   M.PSS_EntityDrop()              releases the name index
-- The rows are PourSocialScoreDB.ent (a PSS_Store, routed to the Options
-- folder); an owned key is PourSocialScoreDB.<key>Of = { [id] = value }. A
-- default value and nil clear a slot, an empty key goes back to nil, an
-- unknown owned key or entity kind is kept untouched and never read. Nothing
-- runs at login and nothing is saved until a feature saves something owned.
-- Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, next = type, pairs, ipairs, next

local FIELDS = { "kind", "name", "realm", "faction", "class", "race", "sex" }
local ent = M.PSS_Store("ent", {
	key = "ent", v = 1, cap = 500,
	fields = { { "kind", "s" }, { "name", "s" }, { "realm", "s" }, { "faction", "s" }, { "class", "s" }, { "race", "s" }, { "sex", "n" }, { "flags", "s" } },
})
local KINDS = { c = true, g = true, w = true }

local me				-- this character's id, once per session

local function indexKey(kind, name, realm)
	local full = realm and realm ~= "" and (name .. "-" .. realm) or name
	return kind .. ":" .. full:lower()
end

-- [kind .. ":" .. lower name] = id, a declared index (PSS_Index.lua): built on the
-- first lookup with one row split per entity, released on a GC request
local NAMEF, tmp = { "kind", "name", "realm" }, {}
local byName = M.PSS_Index("ent.byName", {
	sourceVer = ent.Ver,
	build = function(add)
		ent.Each(function(id)
			if ent.Read(id, tmp, 1, NAMEF) and KINDS[tmp[1]] then add(indexKey(tmp[1], tmp[2] or "", tmp[3]), id) end
		end)
	end,
})

function M.PSS_EntityDrop() byName:drop(); ent.Drop() end
function M.PSS_EntityVer() return ent.Ver() end		-- rises with every change of an entity (a cache of facts is valid while it is the same)
function M.PSS_MeReset() me = nil end		-- the harness plays another character

-- every entity id of a kind ("c", "g", "w"), unsorted
function M.PSS_EntityList(kind)
	local out = {}
	ent.Each(function(id) if ent.Get(id, "kind") == kind then out[#out + 1] = id end end)
	return out
end

-- sets the descriptive fields of an entity (faction, class, race, sex), for rows a feature
-- knows from another source (an import); a nil field stays as it is
function M.PSS_EntitySetInfo(id, info)
	if ent.ReadOnly() or not KINDS[ent.Get(id, "kind")] then return false end
	local v = {}
	ent.Read(id, v, 1, { "kind", "name", "realm", "faction", "class", "race", "sex", "flags" })
	ent.Set(id, { kind = v[1], name = v[2], realm = v[3], faction = info.faction or v[4], class = info.class or v[5], race = info.race or v[6],
		sex = info.sex or v[7], flags = v[8] })
	return true
end

-- the flags of an entity (one letter each: h hidden from tooltips and search, g its gold hidden too)
function M.PSS_EntityFlags(id)
	return ent.Get(id, "flags") or ""
end

-- sets (or, with remove, clears) up to two flag letters; returns the flags now, or nil
local ALLF = { "kind", "name", "realm", "faction", "class", "race", "sex", "flags" }
function M.PSS_EntitySetFlags(id, a, b, remove)
	if ent.ReadOnly() or not KINDS[ent.Get(id, "kind")] then return nil end
	local v = {}
	ent.Read(id, v, 1, ALLF)
	local f = v[8] or ""
	if remove then
		f = f:gsub("[hg]", "")
	else
		for _, c in ipairs({ a or "", b or "" }) do
			if c ~= "" and not f:find(c, 1, true) then f = f .. c end
		end
	end
	ent.Set(id, { kind = v[1], name = v[2], realm = v[3], faction = v[4], class = v[5], race = v[6], sex = v[7], flags = f ~= "" and f or nil })
	return f ~= "" and f or nil
end

-- a character is "Name" and "Realm" (the one name builder, with Camelot surnames)
local function split(name, realm, unit)
	local display = M.PSS_NormName(name, realm, unit)
	if not display then return nil end
	return display:match("^(.*)-([^-]*)$")
end

local function api(fn, ...)
	if type(fn) ~= "function" then return nil end
	local v = fn(...)
	if M.PSS_IsSecret and M.PSS_IsSecret(v) then return nil end
	return v
end

-- W3-D5: an unnamed id is one that saved Warehouse data names (containers, gold, currencies, seen, meta) but that has
-- no entity row. Its data is kept untouched and is never shown or counted; its id is reserved here (the counter is
-- raised past it) so no new character can take it. The player removes it in Options (Warehouse) or with /pss wh remove #id.
local sort = table.sort
function M.PSS_EntityOrphans()
	local out = {}
	local d = rawget(_G, "PSS_WarehouseDB")
	if type(d) ~= "table" or (M.PSS_SavedReady and not M.PSS_SavedReady()) then return out end
	local seen = {}
	for _, key in ipairs({ "inv", "gold", "seen", "meta", "cur" }) do
		local t = d[key]
		if type(t) == "table" then
			for id in pairs(t) do
				if type(id) == "number" and not seen[id] then
					seen[id] = true
					if not KINDS[ent.Get(id, "kind")] then out[#out + 1] = id end
				end
			end
		end
	end
	sort(out)
	if #out > 0 then ent.Reserve(out[#out]) end
	return out
end

function M.PSS_EntityId(kind, name, realm, create, unit)
	if not KINDS[kind] or type(name) ~= "string" or name == "" then return nil end
	if M.PSS_IsSecret and (M.PSS_IsSecret(name) or M.PSS_IsSecret(realm)) then return nil end
	if kind == "c" then
		name, realm = split(name, realm, unit)
		if not name then return nil end
	elseif kind == "w" then
		realm = ""
	elseif type(realm) == "string" and realm ~= "" then
		local _, r = split("X", realm)		-- a guild's realm is spelled the way a character's is
		if r and r ~= "" then realm = r end
	end
	local k = indexKey(kind, name, realm)
	local id = byName:get(k)
	if id or not create then return id end
	local rec = { kind = kind, name = name, realm = realm }
	M.PSS_EntityOrphans()		-- reserves the unnamed ids before an id is handed out
	if unit then
		rec.faction = api(UnitFactionGroup, unit)
		rec.class = select(2, UnitClass(unit))
		rec.race = select(2, UnitRace(unit))
		rec.sex = api(UnitSex, unit)
	end
	local new, why = ent.Add(rec)
	if not new then
		if M.PSS_ErrNote then
			local early = type(why) == "string" and why:sub(1, 6) == "early:"		-- asked before the saved data was routed (F4): a caller bug, not a newer layout
			M.PSS_ErrNote(why == "cap" and "cap" or early and "early" or "newer", "ent", why == "cap" and "500 entities: no room for another" or early and why:sub(8) or tostring(why))
		end
		return nil, why
	end
	-- an id is handed out only when its row is saved and reads back (F4)
	if ent.Get(new, "kind") ~= kind or (kind == "c" and ent.Get(new, "name") ~= name) then
		ent.Delete(new)
		if M.PSS_ErrNote then M.PSS_ErrNote("arg", "ent", "the entity row did not save") end
		return nil, "arg: the entity row did not save"
	end
	byName:put(k, new)
	return new
end

function M.PSS_Me(create)
	if me then return me end
	if not UnitName then return nil end
	local name, realm = UnitName("player")
	if type(name) ~= "string" or (M.PSS_IsSecret and M.PSS_IsSecret(name)) then return nil end
	local id = M.PSS_EntityId("c", name, realm, create, "player")
	me = id
	return id
end

local COLS = { "id", "kind", "name", "realm", "faction", "class", "race", "sex" }

function M.PSS_Entity(id)
	if not KINDS[ent.Get(id, "kind")] then return nil end
	return ent.Rows(FIELDS, { n = 1, { id } })
end

local DICTF = { "name", "realm", "kind" }
M.PSS_QueryDict("ent", DICTF, function(id, dest, at)
	-- one split of the row; an entity of a kind this version does not know reads as absent
	if ent.Read(id, dest, at, DICTF) and not KINDS[dest[at + 2]] then
		dest[at], dest[at + 1], dest[at + 2] = nil, nil, nil
	end
end)

M.PSS_Provide("ent.get", function(input)
	local out = M.PSS_Set(COLS)
	for i = 1, input.n do
		local set = M.PSS_Entity(input[i][1])
		if set then M.PSS_SetAdd(out, set[1]) end
	end
	return out
end, { accepts = { "key" }, returns = COLS, doc = "an entity's fields by id" })

------------------------------------------------------------------------
-- Owned keys
------------------------------------------------------------------------
local ownedDefault			-- [key] = default (false when none), parsed from the schema on first need
local objects = {}

local function owned()
	if not ownedDefault then
		ownedDefault = {}
		for word in (M.PSS_SCHEMA and M.PSS_SCHEMA.owned or ""):gmatch("%S+") do
			local key, def = word:match("^([%a_][%w_]*)=?(.*)$")
			ownedDefault[key] = def ~= "" and def or false
		end
	end
	return ownedDefault
end

function M.PSS_Owned(key)
	local def = owned()[key]
	if def == nil then return nil end
	local o = objects[key]
	if o then return o end
	o = {}
	objects[key] = o
	function o:Get(id)
		local t = PourSocialScoreDB[key]
		return type(t) == "table" and t[id] or nil
	end
	function o:Set(id, value)
		if ent.ReadOnly() or not KINDS[ent.Get(id, "kind")] then return false end
		local t = PourSocialScoreDB[key]
		if value == nil or value == "" or value == def then
			if type(t) == "table" then
				t[id] = nil
				if next(t) == nil then PourSocialScoreDB[key] = nil end
			end
			return true
		end
		if type(t) ~= "table" then
			t = {}
			PourSocialScoreDB[key] = t
		end
		t[id] = value
		return true
	end
	function o:Each(fn)
		local t = PourSocialScoreDB[key]
		if type(t) == "table" then
			for id, v in pairs(t) do fn(id, v) end
		end
	end
	return o
end

function M.PSS_EntityRemove(id)
	if ent.ReadOnly() or not KINDS[ent.Get(id, "kind")] then return false end
	for key in pairs(owned()) do
		local t = PourSocialScoreDB[key]
		if type(t) == "table" then
			t[id] = nil
			if next(t) == nil then PourSocialScoreDB[key] = nil end
		end
	end
	ent.Delete(id)
	byName:drop()
	if me == id then me = nil end
	return true
end
