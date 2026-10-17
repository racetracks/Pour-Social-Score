------------------------------------------------------------------------
-- POUR SOCIAL SCORE - KEY/VALUE STORES (service-bus-helper, DDS-00010
-- section 11.3, DEC-00193). A saved table as a data-driven store:
--   local S = M.PSS_Store(name, schema)
--   schema = { key = "ent", v = 1, cap = 500, fields = { { name, kind, default }, ... } }
-- kinds are rows: n number, s string, b boolean, d dictionary id (a string
-- that repeats is saved once). The saved table is PourSocialScoreDB[schema.key]
-- (routed to the Options folder): { v, n = last id, dn = last dictionary id,
-- rec = { [id] = "packed;fields" }, dict = { [id] = string } }.
--   S.Get(id, field)  S.Set(id, rec)  S.Add(rec) -> id  S.Delete(id)
--   S.Each(fn)  S.Count()  S.Rows(fields, ids) -> record set  S.Drop()
-- Store v2 (one-build plan STP-p03): schema.db names the saved global table
-- (default PourSocialScoreDB; PSS_WarehouseDB is its own SavedVariables);
-- S.Read(id, out, at, names) splits a row once; S.Col(name) is a lazy
-- { [id] = value } map; S.Ver() rises with every write that happened;
-- S.Rows(names, ids, opts) with opts.reuse fills a pool of its own. The
-- saved text of a v1 store is unchanged (the ent store: byte for byte).
-- M.PSS_MapStore(name, spec) is the checked map of packed strings the
-- warehouse keeps (below).
-- A default is never stored; trailing empty fields are dropped; ids are
-- never reused; a table of a newer layout (v above the schema's) and every
-- key the store does not know are kept untouched (PSS 02 section 3). Nothing
-- is written until the first Set or Add, nothing registers an event, and the
-- reverse dictionary index is built on the first dictionary write and
-- dropped by S.Drop(). Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, tonumber, pairs = type, tostring, tonumber, pairs
local concat = table.concat
local find, sub = string.find, string.sub

local SEP = ";"
local KINDS = {
	n = { pack = function(v) return v ~= nil and tostring(v) or "" end, unpack = function(s) return s ~= "" and tonumber(s) or nil end },
	s = { pack = function(v) return v ~= nil and (tostring(v):gsub("[;\n]", ",")) or "" end, unpack = function(s) return s ~= "" and s or nil end },
	b = { pack = function(v) return v and "1" or "" end, unpack = function(s) return s == "1" or nil end },
	d = { dict = true },
}

local stores = {}

function M.PSS_Store(name, schema)
	local S = stores[name]
	if S then return S end
	S = {}
	stores[name] = S
	local fields, idx = schema.fields, {}
	for i = 1, #fields do idx[fields[i][1]] = i end
	local rev, count		-- reverse dictionary index and record count, built on first need
	local dbName = schema.db or "PourSocialScoreDB"
	local ver, cols, parts, pool = 0, {}, {}, nil
	local blocked		-- read while the saved data was not routed yet: what was built from that is stale (F4)

	local function root(create)
		-- a key of PourSocialScoreDB is routed to an Options table at login: before that it is not readable here and
		-- must not be created (F4: a fresh table made early replaced the saved one when the login moved it)
		if dbName == "PourSocialScoreDB" and M.PSS_SavedReady and not M.PSS_SavedReady() then blocked = true return nil end
		local db = _G[dbName]
		if type(db) ~= "table" then
			if not (create and dbName ~= "PourSocialScoreDB") then return nil end
			db = {}
			_G[dbName] = db
		end
		local t = db[schema.key]
		if type(t) ~= "table" and create then
			t = { v = schema.v }
			db[schema.key] = t
		end
		return type(t) == "table" and t or nil
	end

	-- a table written by a newer layout is read as far as it goes, never changed
	function S.ReadOnly()
		local t = root()
		return t ~= nil and type(t.v) == "number" and t.v > schema.v
	end

	local function dictId(t, str)
		if str == nil then return "" end
		t.dict = t.dict or {}
		if not rev then
			rev = {}
			for id, s in pairs(t.dict) do rev[s] = id end
		end
		local id = rev[str]
		if not id then
			id = (t.dn or 0) + 1
			t.dn = id
			t.dict[id] = str
			rev[str] = id
		end
		return tostring(id)
	end

	local function pack(t, rec)
		local parts, last = {}, 0
		for i = 1, #fields do
			local f = fields[i]
			local v = rec[f[1]]
			if v == f[3] then v = nil end
			local k = KINDS[f[2]]
			local p = k.dict and dictId(t, v) or k.pack(v)
			parts[i] = p
			if p ~= "" then last = i end
		end
		return concat(parts, SEP, 1, last)
	end

	-- the pos-th field of a packed record
	local function cut(str, pos)
		local from = 1
		for _ = 2, pos do
			local at = str:find(SEP, from, true)
			if not at then return "" end
			from = at + 1
		end
		local to = str:find(SEP, from, true)
		return to and str:sub(from, to - 1) or str:sub(from)
	end

	local function value(t, str, pos)
		local f = fields[pos]
		local raw = cut(str, pos)
		local k = KINDS[f[2]]
		local v
		if k.dict then
			v = raw ~= "" and t.dict and t.dict[tonumber(raw)] or nil
		else
			v = k.unpack(raw)
		end
		if v == nil then v = f[3] end
		return v
	end

	-- O(1) by id: one table read, then only the asked field is cut out
	function S.Get(id, field)
		local t = root()
		local str = t and t.rec and t.rec[id]
		local pos = idx[field]
		if not str or not pos then return nil end
		return value(t, str, pos)
	end

	function S.Count()
		if not count then
			local t = root()
			count = 0
			if t and t.rec then for _ in pairs(t.rec) do count = count + 1 end end
		end
		return count
	end

	-- replaces (or adds, with an id above the last) the record; false, why when it did not
	function S.Set(id, rec)
		local t = root()
		if t and t.v and t.v > schema.v then return false, "newer layout kept" end
		local had = t and t.rec and t.rec[id]
		if not had and schema.cap and S.Count() >= schema.cap then return false, "cap" end
		t = root(true)
		if not t then return false, "early: the saved data is not there yet" end
		t.rec = t.rec or {}
		t.rec[id] = pack(t, rec)
		ver = ver + 1
		if not had then
			count = S.Count() + 1
			if id > (t.n or 0) then t.n = id end
		end
		return true
	end

	-- keeps ids up to n from being handed out (W3-D5); the counter only rises
	function S.Reserve(n)
		local t = root()
		if t and t.v and t.v > schema.v then return false end
		if n > ((t and t.n) or 0) then
			t = root(true)
			if not t then return false end
			t.n = n
			ver = ver + 1
		end
		return true
	end

	-- a new record under the next id (ids are never reused)
	function S.Add(rec)
		local t = root()
		if t and t.v and t.v > schema.v then return nil, "newer layout kept" end
		local id = ((t and t.n) or 0) + 1
		local ok, why = S.Set(id, rec)
		if not ok then return nil, why end
		return id
	end

	function S.Delete(id)
		local t = root()
		if t and t.rec and t.rec[id] and not (t.v and t.v > schema.v) then
			t.rec[id] = nil
			ver = ver + 1
			if count then count = count - 1 end
			return true
		end
	end

	function S.Each(fn)
		local t = root()
		if t and t.rec then
			for id in pairs(t.rec) do fn(id) end
		end
	end

	-- the version of the data: it rises with every write that was made, so a
	-- cache or an index built at one version knows it is stale
	function S.Ver()
		if blocked and M.PSS_SavedReady and M.PSS_SavedReady() then blocked = false; count = nil; ver = ver + 1 end
		return ver
	end

	-- one row split once: out[at], out[at + 1], ... get the values of names
	-- (every field in order when names is nil); false when the id is unknown
	function S.Read(id, out, at, names)
		local t = root()
		local str = t and t.rec and t.rec[id]
		if not str then return false end
		local n, from = 0, 1
		while true do
			local to = find(str, SEP, from, true)
			n = n + 1
			if to then
				parts[n] = sub(str, from, to - 1)
				from = to + 1
			else
				parts[n] = sub(str, from)
				break
			end
		end
		local count_ = names and #names or #fields
		for i = 1, count_ do
			local pos = names and idx[names[i]] or i
			local f = fields[pos]
			local raw = pos <= n and parts[pos] or ""
			local k = KINDS[f[2]]
			local v
			if k.dict then
				v = raw ~= "" and t.dict and t.dict[tonumber(raw)] or nil
			else
				v = k.unpack(raw)
			end
			if v == nil then v = f[3] end
			out[at + i - 1] = v
		end
		return true
	end

	-- { [id] = value } of one field, built on the first ask and rebuilt when the version moved
	function S.Col(name)
		local c = cols[name]
		if c and c.ver == ver then return c.map end
		local t = root()
		local map = {}
		local pos = idx[name]
		if t and t.rec and pos then
			for id, str in pairs(t.rec) do map[id] = value(t, str, pos) end
		end
		cols[name] = { ver = ver, map = map }
		return map
	end

	-- a record set { "id", fields... } of the asked ids (a record set with the
	-- id in its first column) or of every record; it joins on "id". With
	-- opts.reuse the rows come from a pool of this store (use the answer
	-- before the next call)
	function S.Rows(names, ids, opts)
		local out
		if opts and opts.reuse then
			out = pool
			if not out or out.cols[#out.cols] ~= names[#names] or #out.cols ~= #names + 1 then
				out = { cols = { "id" }, n = 0 }
				for i = 1, #names do out.cols[i + 1] = names[i] end
				pool = out
			end
			out.n = 0
		else
			out = { cols = { "id" }, n = 0 }
			for i = 1, #names do out.cols[i + 1] = names[i] end
		end
		local reuse = opts and opts.reuse
		local t = root()
		if not (t and t.rec) then return out end
		local function add(id)
			local n = out.n + 1
			local r = reuse and out[n] or {}
			r[1] = id
			S.Read(id, r, 2, names)
			out.n = n
			out[n] = r
		end
		if ids then
			for i = 1, ids.n do
				local id = ids[i][1]
				if t.rec[id] then add(id) end
			end
		else
			for id in pairs(t.rec) do add(id) end
		end
		return out
	end

	-- the runtime indexes are released (window closed, GC requested)
	function S.Drop() rev = nil; count = nil; cols = {}; pool = nil end
	return S
end

------------------------------------------------------------------------
-- The map store (one-build plan STP-p03, DEC-00266): a saved map
--   _G[spec.db][spec.key][entity][code] = "1;n;sum;hash;body"   (see PSS_Codec)
-- written only whole and checked: ms.Put verifies every string, then swaps
-- every string in one step; ms.Get checks a string's header the first time
-- it is read in a session and quarantines a bad one to _G[spec.db][spec.bad]
-- (never deletes it); a table or a string of a newer layout, an unknown code
-- and a quarantined string are kept untouched.
--   local ms = M.PSS_MapStore(name, { db = "PSS_WarehouseDB", key = "inv", bad = "bad", v = 1, cap = 500, badCap = 32 })
--   ms.Get(ent, code)      the verified string, or nil, "bad" | "newer"
--   ms.Put(ent, changes)   { [code] = string | false }: true, or false, "integrity: ..." | "newer: ..." | "cap: ..."
--   ms.Codes(ent)          sorted codes of that entity    ms.Bad(ent)   { [code] = string }
--   ms.Ents()              entity ids (unsorted)          ms.Ver(ent)   rises with each Put (ent nil: any)
--   ms.Checks()            how many headers were verified ms.Drop(ent)  forget what was verified
--   ms.Bump()              the strings changed outside Put: ms.Ver() rises
------------------------------------------------------------------------
local mapStores = {}

function M.PSS_MapStore(name, spec)
	local ms = mapStores[name]
	if ms then return ms end
	ms = {}
	mapStores[name] = ms
	local layout = spec.v or 1
	local ver, ents, verified, checks = 0, {}, {}, 0

	local function db(create)
		local d = _G[spec.db]
		if type(d) ~= "table" then
			if not create then return nil end
			d = { v = layout }
			_G[spec.db] = d
		end
		return d
	end
	local function newer(d) return d ~= nil and type(d.v) == "number" and d.v > layout end

	function ms.Get(ent, code)
		local d = db()
		local m = d and d[spec.key]
		local e = m and m[ent]
		local str = e and e[code]
		if not str then return nil end
		local vf = verified[ent]
		if vf and vf[code] == str then return str end
		checks = checks + 1
		local C = M.PSS_Codec
		local ok, why = C.check(str)
		if not ok then
			if why:find("^newer") then return nil, "newer" end
			-- quarantine: moved, never deleted; the container is read again from the client
			local b = d[spec.bad]
			if not b then b = {}; d[spec.bad] = b end
			if not newer(d) then
				b[ent] = b[ent] or {}
				b[ent][code] = str
				e[code] = nil
				if next(e) == nil then m[ent] = nil end
				local total, oldE, oldC = 0, nil, nil
				for be, codes in pairs(b) do
					for bc in pairs(codes) do
						total = total + 1
						if not oldE or be < oldE or (be == oldE and bc < oldC) then oldE, oldC = be, bc end
					end
				end
				if spec.badCap and total > spec.badCap then
					b[oldE][oldC] = nil
					if next(b[oldE]) == nil then b[oldE] = nil end
					M.PSS_ErrNote("cap", name, "quarantine full: the oldest string dropped")
				end
			end
			M.PSS_ErrNote("integrity", name, "string " .. tostring(ent) .. "/" .. tostring(code) .. " failed its check: " .. why)
			ver = ver + 1
			return nil, "bad"
		end
		verified[ent] = verified[ent] or {}
		verified[ent][code] = str
		return str
	end

	function ms.Put(ent, changes)
		local d = db()
		if newer(d) then return false, "newer: layout " .. tostring(d.v) .. " kept" end
		local C = M.PSS_Codec
		for code, str in pairs(changes) do
			if str ~= false then
				local ok, why = C.check(str)
				if not ok then return false, why end
			end
		end
		d = db(true)
		local m = d[spec.key]
		if not m then m = {}; d[spec.key] = m end
		local e = m[ent]
		if not e then
			if spec.cap then
				local n = 0
				for _ in pairs(m) do n = n + 1 end
				if n >= spec.cap then return false, "cap: " .. spec.cap .. " entities" end
			end
			e = {}
		end
		m[ent] = e
		for code, str in pairs(changes) do
			if str == false then
				e[code] = nil
				if verified[ent] then verified[ent][code] = nil end
			else
				e[code] = str
				verified[ent] = verified[ent] or {}
				verified[ent][code] = str
			end
		end
		if next(e) == nil then m[ent] = nil end
		ver = ver + 1
		ents[ent] = (ents[ent] or 0) + 1
		return true
	end

	function ms.Codes(ent)
		local d = db()
		local e = d and d[spec.key] and d[spec.key][ent]
		local out = {}
		if e then for code in pairs(e) do out[#out + 1] = code end end
		table.sort(out)
		return out
	end

	function ms.Bad(ent)
		local d = db()
		local b = d and d[spec.bad]
		return b and b[ent] or {}
	end

	function ms.Ents()
		local d = db()
		local m = d and d[spec.key]
		local out = {}
		if m then for ent in pairs(m) do out[#out + 1] = ent end end
		return out
	end

	function ms.Ver(ent)
		if ent then return ents[ent] or 0 end
		return ver
	end
	function ms.Checks() return checks end
	function ms.Drop(ent)
		if ent then verified[ent] = nil else verified = {} end
	end
	-- strings were rewritten outside Put (a compaction remapped ids): every index built on them is stale
	function ms.Bump() ver = ver + 1 end
	return ms
end
