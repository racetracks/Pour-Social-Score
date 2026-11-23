------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE DATA DICTIONARY (search-helper, STP-00285 and
-- STP-00286, DEC-00321). One row per index and field: what it holds, the
-- values it can take, its unit, where it comes from, whether it is pushed
-- down or joined. A row's kind, doc, pushdown and join come from the index
-- declaration (one source); the values, unit and source are kept here, and a
-- closed list is checked against the code that defines it when the index is
-- declared (a drift raises at load: a programming error).
--   M.PSS_DataDict["index.field"]          the row (built on first read)
--   M.PSS_DataDictExtend(owner, rows)       a later feature adds rows for an index it owns; true | nil, why
--   M.PSS_IxKinds[kind]                     field kinds: { doc, encode?, decode?, compare?, format? }
--   M.PSS_DataDictValues[name]              providers of closed lists that follow code ("fn:<name>")
--   M.PSS_DATADICT_V                        the row shape's version
--   services ix.dict { index?, field? } and ix.values { index, field, n } (cached by the data version)
-- Reserved row attributes (since, deprecated, tags, secret, example, calc)
-- are kept and shown; an attribute this version does not know is kept and
-- shown raw. Loaded with Libraries. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, tostring, tonumber, error, setmetatable, rawget = type, pairs, ipairs, tostring, tonumber, error, setmetatable, rawget
local concat, sort = table.concat, table.sort

M.PSS_DATADICT_V = 1

M.PSS_IxKinds = {
	t = { doc = "time (server seconds)" }, n = { doc = "number" }, c = { doc = "copper" }, s = { doc = "text" },
	b = { doc = "1 or empty" }, e = { doc = "entity id" }, i = { doc = "item key" }, d = { doc = "dictionary id shown as its text" },
	k = { doc = "a code from a closed list" },
}

local ENGINE_CODES = { "parse", "field", "index", "cmd", "arg", "limit", "off", "newer", "integrity", "secret", "cap" }

M.PSS_DataDictValues = {
	logCats = function() return M.PSS_History.ALL_CATS end,
	whContainerKinds = function()
		local out = {}
		for _, r in ipairs(M.PSS_WH_CONTAINERS or {}) do out[#out + 1] = r.kind end
		return out
	end,
	errCodes = function()
		local out, seen = {}, {}
		for k in pairs(M.PSS_ERR_CODES or {}) do if not seen[k] then seen[k] = true; out[#out + 1] = k end end
		for _, k in ipairs(ENGINE_CODES) do if not seen[k] then seen[k] = true; out[#out + 1] = k end end
		sort(out)
		return out
	end,
	optionKeys = function()
		local out = {}
		for _, o in ipairs(M.PSS_OPTIONS or {}) do out[#out + 1] = o.key end
		return out
	end,
}

-- values, unit and source per index.field: a closed list "a b c", a range "lo..hi", a provider "fn:name"
-- or a shape "~text"; the lists named in CHECK must equal what the code defines
local W = "whisper partyInvite guildInvite partyRaid world guildChat unknown"
local KINDS = "bags keyring bank reagent warband equipped mail void auctions guild"
local CODES = "arg cap combat early fail integrity missing newer secret parse field index cmd limit off"
local VALUES = {
	["log.cat"] = W, ["log.owner"] = "~p:<player> g:<member> G:<guild> f:<filter>", ["log.st"] = "chat.block act.dtt act.wh act.bag act.addons act.gfx act.macro act.upgrade",
	["log.message"] = "~the line's text; (message hidden by the client) when it was secret",
	["counts.type"] = W .. " total", ["counts.kind"] = "player guild filter",
	["pss.st"] = "pss.err pss.upg pss.start pss.card pss.filter", ["pss.code"] = CODES,
	["inv.kind"] = KINDS, ["inv.slot"] = "1..98", ["inv.tab"] = "0..7", ["inv.count"] = "~1 to the stack size", ["inv.cont"] = "~<letter><tab>: b y k r w e m v a t",
	["val.source"] = "tsm recrystallize auctionator vendor none",
	["ent.kind"] = "c g w", ["ent.faction"] = "Alliance Horde Neutral", ["item.quality"] = "0..8",
	["players.kind"] = "player npc server", ["guilds.members"] = "0..1500",
	["cfg.key"] = "fn:optionKeys", ["dtt.list"] = "always never", ["gfx.set"] = "1..5",
	["macros.store"] = "account character", ["upg.step"] = "1..12",
	["sq.scope"] = "any player guild filter journal bagcat", ["sq.st"] = "sq.user sq.system",
}
local UNITS = { ["gold.copper"] = "copper", ["val.vendor"] = "copper", ["val.auction"] = "copper", ["pss.ms"] = "ms" }
-- a closed list here must hold exactly what the code defines (a planted value fails the load)
local CHECK = { ["log.cat"] = "logCats", ["counts.type"] = "logCats", ["inv.kind"] = "whContainerKinds", ["pss.code"] = "errCodes" }
M.PSS_DATADICT_VALUES, M.PSS_DATADICT_CHECK = VALUES, CHECK

local function words(s)
	local out = {}
	for w in s:gmatch("%S+") do out[#out + 1] = w end
	return out
end

local function valuesOf(v)
	if type(v) ~= "string" then return v end
	if v:find("^fn:") or v:find("^~") then return v end
	local lo, hi = v:match("^(%-?%d+)%.%.(%-?%d+)$")
	if lo then return { lo = tonumber(lo), hi = tonumber(hi) } end
	return words(v)
end

local function asSet(list)
	local set = {}
	for _, v in ipairs(list or {}) do set[v] = true end
	return set
end

-- a declared index: every closed list it names equals the code's (raises naming the value)
-- (no "<index>.<field>" string is made per field: at load every new string grows the client's string table)
function M.PSS_DataDictCheck(spec)
	local name = spec.name
	local len = #name
	for key, p in pairs(CHECK) do
		local f = key:find(name, 1, true) == 1 and key:byte(len + 1) == 46 and key:sub(len + 2)
		local has = false
		if f then for _, x in ipairs(spec.fields) do if x[1] == f then has = true break end end end
		if has then
			local code = asSet(M.PSS_DataDictValues[p]())
			local dict = asSet(words(VALUES[key]))
			if p == "logCats" and key == "counts.type" then dict.total = nil end
			if p == "whContainerKinds" then
				for v in pairs(code) do if not dict[v] then error("datadict: " .. key .. ": value " .. v .. " is not in the dictionary", 3) end end
			else
				for v in pairs(code) do if not dict[v] then error("datadict: " .. key .. ": value " .. v .. " is not in the dictionary", 3) end end
				for v in pairs(dict) do if not code[v] then error("datadict: " .. key .. ": value " .. v .. " is in the dictionary but not in the code", 3) end end
			end
		end
	end
end

local ext = {}		-- rows added by M.PSS_DataDictExtend, [index.field] = row
local built

local function addIndex(rows, name)
	local x = M.PSS_Ix(name)
	local pd = asSet(x.pushdown)
	for _, f in ipairs(x.fields) do
		local key = name .. "." .. f[1]
		rows[key] = { index = name, field = f[1], kind = f[2], doc = f[3] or "", values = valuesOf(VALUES[key]), unit = UNITS[key],
			source = x.owner, pushdown = pd[f[1]] and true or nil, join = x.dicts and x.dicts[f[1]] or nil, v = M.PSS_DATADICT_V }
	end
end

local function build()
	local rows = {}
	for _, name in ipairs(M.PSS_IxNames()) do addIndex(rows, name) end
	for k, r in pairs(ext) do rows[k] = r end
	built = rows
	return rows
end

M.PSS_DataDict = setmetatable({}, { __index = function(_, k) return (built or build())[k] end })
function M.PSS_DataDictRows() return built or build() end
-- an index declared after the rows were built: its rows join them (nothing is rebuilt, nothing built before the first read)
function M.PSS_DataDictDrop(name)
	if not built then return end
	if not name or not M.PSS_Ix(name) then built = nil return end
	addIndex(built, name)
	for k, r in pairs(ext) do if r.index == name then built[k] = r end end
end

-- the rows of some indexes as a { field = row } table (fieldsummary's closed lists)
function M.PSS_DataDictFor(names)
	local rows, out = M.PSS_DataDictRows(), {}
	for _, n in ipairs(names or {}) do
		for _, r in pairs(rows) do if r.index == n and not out[r.field] then out[r.field] = r end end
	end
	return out
end

local KNOWN = { index = true, st = true, field = true, kind = true, values = true, unit = true, source = true, doc = true, pushdown = true,
	join = true, since = true, deprecated = true, tags = true, secret = true, example = true, calc = true, v = true }

function M.PSS_DataDictExtend(owner, list)
	if type(list) ~= "table" then return nil, "arg: a list of rows" end
	local add = {}		-- (the dictionary is not built here: a row is checked against the index's own fields)
	for i, r in ipairs(list) do
		local why
		local x = type(r) == "table" and M.PSS_Ix(r.index)
		if type(r) ~= "table" or type(r.field) ~= "string" or not x then why = "arg: row " .. i .. " names no declared index"
		elseif x.owner ~= owner then why = "arg: " .. tostring(owner) .. " does not own the index " .. r.index
		elseif not M.PSS_IxKinds[r.kind] then why = "arg: row " .. i .. " has no known kind"
		else
			local old = built and built[r.index .. "." .. r.field]
			if not old then
				for _, f in ipairs(x.fields) do if f[1] == r.field then old = { kind = f[2] } break end end
				old = old or ext[r.index .. "." .. r.field]
			end
			if old and old.kind ~= r.kind then why = "arg: " .. r.index .. "." .. r.field .. " exists with kind " .. old.kind end
		end
		if why then
			if M.PSS_ErrNote then M.PSS_ErrNote("arg", "ix.dict", why) end
			return nil, why
		end
		add[#add + 1] = r
	end
	for _, r in ipairs(add) do
		local key = r.index .. "." .. r.field
		local row = {}
		for k, v in pairs(r) do row[k] = v end
		row.values = valuesOf(row.values)
		row.v = row.v or M.PSS_DATADICT_V
		ext[key] = row
		if built then built[key] = row end
	end
	return true
end

local function show(v)
	if v == nil then return nil end
	if type(v) ~= "table" then return tostring(v) end
	if v.lo ~= nil then return tostring(v.lo) .. ".." .. tostring(v.hi) end
	local out = {}
	for i, s in ipairs(v) do out[i] = tostring(s) end
	if #out == 0 then for k, s in pairs(v) do out[#out + 1] = tostring(k) .. "=" .. tostring(s) end; sort(out) end
	return concat(out, " ")
end

local DICTCOLS = { "index", "st", "field", "kind", "values", "unit", "source", "doc", "pushdown", "join", "since", "deprecated", "more" }

function M.PSS_DataDictSet(index, field)
	local rows, keys = M.PSS_DataDictRows(), {}
	for k, r in pairs(rows) do
		if (not index or r.index == index) and (not field or r.field == field) then keys[#keys + 1] = k end
	end
	sort(keys)
	local out = { cols = DICTCOLS, n = 0 }
	for _, k in ipairs(keys) do
		local r = rows[k]
		local more = {}
		for a, v in pairs(r) do if not KNOWN[a] then more[#more + 1] = tostring(a) .. "=" .. show(v) end end
		sort(more)
		out.n = out.n + 1
		out[out.n] = { r.index, r.st, r.field, r.kind, show(r.values), r.unit, r.source, r.doc, r.pushdown and 1 or nil, r.join,
			r.since, r.deprecated and show(r.deprecated) or nil, #more > 0 and concat(more, ";") or nil }
	end
	return out
end

M.PSS_Provide("ix.dict", function(input)
	local index = type(input) == "table" and (input.index or (input.cols and input[1] and input[1][M.PSS_SetCol(input, "index") or 0]))
	local field = type(input) == "table" and input.field
	if index and not M.PSS_Ix(index) then error("index: no index " .. tostring(index), 0) end
	return M.PSS_DataDictSet(index, field)
end, { accepts = { "index", "field" }, returns = DICTCOLS, doc = "the data dictionary", cost = "O(fields)", writes = false })

-- the data version a cached answer depends on
local function dataVer()
	return (M.PSS_IxStats and M.PSS_IxStats.put or 0) + (M.PSS_WhStore and M.PSS_WhStore.Ver and M.PSS_WhStore.Ver() or 0)
		+ (M.PSS_EntityVer and M.PSS_EntityVer() or 0) + (M.PSS_History and M.PSS_History.Waiting() or 0)
end
M.PSS_IxDataVer = dataVer

local vcache = {}
M.PSS_IxValuesStats = { builds = 0 }

M.PSS_Provide("ix.values", function(input)
	local index, field, n = input and input.index, input and input.field, tonumber(input and input.n) or 10
	local x = M.PSS_Ix(index)
	if not x then error("index: no index " .. tostring(index), 0) end
	if not x.has[field] then error("field: " .. tostring(index) .. " has no field " .. tostring(field), 0) end
	local key = index .. "\1" .. field .. "\1" .. n
	local ver = dataVer()
	local c = vcache[key]
	if c and c.ver == ver then return c.set end
	M.PSS_IxValuesStats.builds = M.PSS_IxValuesStats.builds + 1
	local count, list = {}, {}
	x:scan({}, function(r)
		local v = r[field]
		if v ~= nil then
			if not count[v] then count[v] = 0; list[#list + 1] = v end
			count[v] = count[v] + 1
		end
		return true
	end, { load = false })
	sort(list, function(a, b) if count[a] ~= count[b] then return count[a] > count[b] end return tostring(a) < tostring(b) end)
	local set = { cols = { "value", "count" }, n = 0 }
	for i = 1, math.min(n, #list) do set.n = i; set[i] = { list[i], count[list[i]] } end
	vcache[key] = { ver = ver, set = set }
	return set
end, { accepts = { "index", "field", "n" }, returns = { "value", "count" }, doc = "the most common values of a field", cost = "O(rows)", writes = false })
