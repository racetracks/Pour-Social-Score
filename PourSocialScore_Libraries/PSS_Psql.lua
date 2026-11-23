------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PSQL, THE SPYGLASS QUERY LANGUAGE (search-helper,
-- STP-00241, DDS-00031 section 6). A hand-written tokenizer (one pass,
-- positions kept) and a recursive descent parser. A query is never compiled
-- from text into Lua: the compiler builds closures over the syntax tree.
--   M.PSS_Psql.parse(text)    -> ast | nil, { code, pos, msg }
--   M.PSS_Psql.compile(text)  -> plan | nil, { code, pos, msg }
--   M.PSS_Psql.tokens(text)   -> record set pos, len, kind (every byte, never raises)
--   plan:bind(params) -> plan   plan:text()   plan:shape()   plan:needs()
-- Error codes: parse field index cmd arg limit off newer. Limits: text 512
-- bytes, 16 commands, 32 terms, 8 indexes. Parameters ($name) are values
-- only and are put in after parsing, so a parameter is always one literal.
-- Loaded with Libraries. No frame, no event.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, tonumber, pairs, ipairs, next, error, pcall, setmetatable = type, tostring, tonumber, pairs, ipairs, next, error, pcall, setmetatable
local byte, sub, find, lower, match, gsub = string.byte, string.sub, string.find, string.lower, string.match, string.gsub
local concat, sort = table.concat, table.sort

local Q = {}
M.PSS_Psql = Q
local LIMIT = { text = 512, commands = 16, terms = 32, indexes = 8 }
Q.LIMIT = LIMIT
Q.conRows = 500

local function err(code, pos, msg) error({ code = code, pos = pos or 1, msg = msg }, 0) end

------------------------------------------------------------------------
-- Tokenizer
------------------------------------------------------------------------
local SPACE = { [32] = true, [9] = true, [10] = true, [13] = true }

-- tokens { t = ws|pipe|lp|rp|op|comma|str|word, s = text, v = value, p = pos, n = len }
local function tokenize(text)
	local toks, i, n = {}, 1, #text
	while i <= n do
		local c = byte(text, i)
		local start = i
		if SPACE[c] then
			i = (find(text, "[^ \t\n\r]", i) or n + 1)		-- one pattern scan, not a byte loop
			toks[#toks + 1] = { t = "ws", p = start, n = i - start }
		elseif c == 124 then toks[#toks + 1] = { t = "pipe", s = "|", p = i, n = 1 }; i = i + 1
		elseif c == 40 then toks[#toks + 1] = { t = "lp", s = "(", p = i, n = 1 }; i = i + 1
		elseif c == 41 then toks[#toks + 1] = { t = "rp", s = ")", p = i, n = 1 }; i = i + 1
		elseif c == 44 then toks[#toks + 1] = { t = "comma", s = ",", p = i, n = 1 }; i = i + 1
		elseif c == 61 then toks[#toks + 1] = { t = "op", s = "=", p = i, n = 1 }; i = i + 1
		elseif c == 60 or c == 62 or c == 33 then
			local two = byte(text, i + 1) == 61
			if c == 33 and not two then return nil, { code = "parse", pos = i, msg = "! is only part of !=" } end
			local s = sub(text, i, two and i + 1 or i)
			toks[#toks + 1] = { t = "op", s = s, p = i, n = #s }
			i = i + #s
		elseif c == 34 then
			local out, j = {}, i + 1
			while true do
				local k = find(text, '["\\]', j)		-- the next quote or backslash; the run before it is plain
				if not k then return nil, { code = "parse", pos = start, msg = "a quoted value is not closed" } end
				out[#out + 1] = sub(text, j, k - 1)
				if byte(text, k) == 34 then j = k break end
				if k == n then return nil, { code = "parse", pos = start, msg = "a quoted value is not closed" } end
				out[#out + 1] = sub(text, k + 1, k + 1); j = k + 2
			end
			toks[#toks + 1] = { t = "str", s = sub(text, i, j), v = concat(out), p = i, n = j - i + 1 }
			i = j + 1
		else
			i = (find(text, "[ \t\n\r|()\"=<>!,]", i) or n + 1)
			toks[#toks + 1] = { t = "word", s = sub(text, start, i - 1), p = start, n = i - start }
		end
	end
	return toks
end
Q.tokenize = tokenize

------------------------------------------------------------------------
-- Field knowledge
------------------------------------------------------------------------
local ENVELOPE = { time = "t", st = "k", ent = "e", index = "k" }
local LAZYCOLS = { "time", "index", "st", "ent", "item", "owner", "summary" }
local LAZYKIND = { time = "t", index = "k", st = "k", ent = "e", item = "i", owner = "d", summary = "s" }
Q.LAZYCOLS = LAZYCOLS

-- the event indexes a search with no index= covers (only those declared and on)
local LAZY = { "log", "pss", "jrn", "whh" }
Q.LAZY = LAZY

local function dist(a, b)
	if a == b then return 0 end
	local la, lb = #a, #b
	if math.abs(la - lb) > 2 then return 3 end
	local prev = {}
	for j = 0, lb do prev[j] = j end
	for i = 1, la do
		local cur = { [0] = i }
		for j = 1, lb do
			local cost = sub(a, i, i) == sub(b, j, j) and 0 or 1
			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		end
		prev = cur
	end
	return prev[lb]
end

local function suggest(word, list)
	local best, bd = nil, 3
	for _, c in ipairs(list) do
		local d = dist(lower(word), c)
		if d < bd then best, bd = c, d end
	end
	return best and (" (did you mean " .. best .. "?)") or ""
end
Q.suggest = suggest

------------------------------------------------------------------------
-- Parser
------------------------------------------------------------------------
local P = {}
local PMT = { __index = P }

local function peek(s, k) return s.toks[s.i + (k or 0)] end
local function take(s) local t = s.toks[s.i]; s.i = s.i + 1; return t end
local function isWord(t, w) return t and t.t == "word" and lower(t.s) == w end
local function role(t, r) if t then t.role = r end end

local VTIME = { weekday = true, hour = true }		-- computed from time on event rows, only when a query names them
Q.VTIME = VTIME
local VIRTUAL = { sender = true, server = true, filter = true }		-- text names computed per row of log and counts, only when a query names them; never searched as bare words
Q.VIRTUAL = VIRTUAL
local function known(s, f)
	if VTIME[f] and s.kinds[f] then s.vtime = true end
	if VIRTUAL[f] and s.kinds[f] and s.vnames then s.vnames[f] = true end
	if s.any then return s.kinds[f] or "s" end
	return s.kinds[f]
end

local function checkField(s, t, f)
	if known(s, f) then return end
	if s.kinds.ent and (f == "realm" or f == "faction" or f == "class") then return end
	local list = {}
	for k in pairs(s.kinds) do list[#list + 1] = k end
	sort(list)
	err("field", t.p, "unknown field " .. f .. suggest(f, list))
end

local function valueTok(s, opTok)
	local v = take(s)
	if not v or (v.t ~= "word" and v.t ~= "str") then err("parse", v and v.p or (opTok.p + opTok.n), "a value is needed after " .. opTok.s) end
	return v
end

local parseOr

local function atom(s)
	local t = peek(s)
	if not t then err("parse", s.len + 1, "a term is needed") end
	if t.t == "lp" then
		take(s); role(t, "paren")
		local e = parseOr(s, true)
		local r = take(s)
		if not r or r.t ~= "rp" then err("parse", r and r.p or s.len + 1, "a ) is needed") end
		role(r, "paren")
		return e
	end
	if t.t == "str" then
		take(s); role(t, "string")
		s.terms = s.terms + 1
		return { k = "text", value = t.v, pos = t.p }
	end
	if t.t ~= "word" then err("parse", t.p, "a term is needed, not " .. tostring(t.s)) end
	take(s)
	local w = t.s
	local nx = peek(s)
	local vt = peek(s, 1)
	local likeWord = isWord(nx, "like") and s.kinds[w] ~= nil and vt ~= nil and (vt.t == "word" or vt.t == "str")
	if likeWord then nx = { t = "op", s = "=", p = nx.p, n = nx.n, tok = nx } end
	if nx and nx.t == "op" then
		take(s)
		role(t, "field"); role(nx.tok or nx, "op")
		local field = w
		checkField(s, t, field)
		known(s, field)
		local v = valueTok(s, nx)
		s.terms = s.terms + 1
		local node = { k = "cmp", field = field, op = nx.s, pos = t.p, vpos = v.p }
		if v.t == "str" then
			role(v, "string"); node.value = v.v
			if likeWord then node.k = "like" end
		elseif byte(v.s, 1) == 36 then
			node.param = sub(v.s, 2)
			if not find(node.param, "^[%a_][%w_]*$") then err("arg", v.p, "a parameter is $ and a name") end
			role(v, "param"); s.params[node.param] = true
		else
			node.value = v.s
			if find(v.s, "*", 1, true) and (nx.s == "=" or nx.s == "!=") then node.k = "like" end
			if likeWord then node.k = "like" end
			local tm = M.PSS_Time and M.PSS_Time.parse(v.s)
			role(v, tonumber(v.s) and "number" or (tm and (byte(v.s, 1) == 45 or byte(v.s, 1) == 64 or find(v.s, "^%d%d%d%d%-")) and "time") or "value")
		end
		if likeWord and type(node.value) == "string" and not find(node.value, "*", 1, true) and s.kinds[field] ~= "t" then		-- implicit *: contains (a time field is matched by Pred.timeLike)
			node.value = "*" .. node.value .. "*"
		end
		return node
	end
	if byte(w, 1) == 35 then
		role(t, "keyword")
		s.terms = s.terms + 1
		local kw = sub(w, 2)
		if kw == "" then err("arg", t.p, "a keyword is needed after #") end
		if M.PSS_Terms then
			local ok, why = M.PSS_Terms.resolve(kw)
			if not ok then err("arg", t.p, why or ("unknown keyword #" .. kw)) end
		end
		return { k = "term", value = kw, pos = t.p }
	end
	if byte(w, 1) == 36 then err("arg", t.p, "a parameter goes after a field and an operator") end
	role(t, "word")
	s.terms = s.terms + 1
	return { k = "text", value = w, pos = t.p, bare = true }
end

local function unary(s)
	local t = peek(s)
	if isWord(t, "not") then
		take(s); role(t, "bool")
		return { k = "not", unary(s), pos = t.p }
	end
	if t and t.t == "word" and byte(t.s, 1) == 45 and #t.s > 1 then
		-- -word / -field=value: NOT; the word without its dash is read again
		role(t, "bool")
		local rest = { t = "word", s = sub(t.s, 2), p = t.p + 1, n = t.n - 1 }
		s.toks[s.i] = rest
		local node = atom(s)
		rest.role = rest.role or "word"
		t.split = rest
		return { k = "not", node, pos = t.p }
	end
	return atom(s)
end

local function metaTerm(s)
	local t, nx = peek(s), peek(s, 1)
	if not (t and t.t == "word" and nx and nx.t == "op" and nx.s == "=") then return false end
	local w = lower(t.s)
	if w == "index" then
		take(s); take(s); role(t, "index"); role(nx, "op")
		if s.indexes then err("parse", t.p, "index= is given once") end
		local list = {}
		repeat
			local v = take(s)
			if not v or v.t ~= "word" then err("parse", v and v.p or s.len + 1, "an index name is needed") end
			role(v, "indexname")
			list[#list + 1] = { name = lower(v.s), pos = v.p }
			local c = peek(s)
			if c and c.t == "comma" then take(s); role(c, "indexname") else break end
		until false
		if #list > LIMIT.indexes then err("limit", list[LIMIT.indexes + 1].pos, "at most " .. LIMIT.indexes .. " indexes") end
		s.indexes = list
		return true
	end
	if w == "earliest" or w == "latest" then
		take(s); take(s); role(t, "index"); role(nx, "op")
		local v = take(s)
		if not v or (v.t ~= "word" and v.t ~= "str") then err("parse", v and v.p or s.len + 1, "a time is needed after " .. w .. "=") end
		local text = v.v or v.s
		local tm, pos = M.PSS_Time.parse(text, s.now)
		if not tm then err("arg", v.p + (pos or 1) - 1, "not a time: " .. text) end
		role(v, "time")
		s.time = s.time or {}
		s.time[w == "earliest" and "lo" or "hi"] = tm
		s.time[w == "earliest" and "loText" or "hiText"] = text
		return true
	end
	return false
end

local function stopAt(t, inParen)
	if not t or t.t == "pipe" then return true end
	if inParen and t.t == "rp" then return true end
	return false
end

local function parseAnd(s, inParen)
	local node = { k = "and" }
	while true do
		local t = peek(s)
		if stopAt(t, inParen) or isWord(t, "or") then break end
		if t.t == "rp" then err("parse", t.p, "a ( is missing for this )") end
		if isWord(t, "and") then take(s); role(t, "bool")
		elseif not (s.top and not inParen and metaTerm(s)) then
			node[#node + 1] = unary(s)
		end
		if s.terms > LIMIT.terms then err("limit", (peek(s, -1) or t).p, "at most " .. LIMIT.terms .. " terms") end
	end
	return node
end

function parseOr(s, inParen)
	local first = parseAnd(s, inParen)
	if not isWord(peek(s), "or") then return #first == 1 and first[1] or first end
	local node = { k = "or", #first == 1 and first[1] or first }
	while isWord(peek(s), "or") do
		local t = take(s); role(t, "bool")
		local nxt = parseAnd(s, inParen)
		if #nxt == 0 then err("parse", (peek(s) or t).p or s.len + 1, "a term is needed after OR") end
		node[#node + 1] = #nxt == 1 and nxt[1] or nxt
	end
	return node
end

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
local function cmdEnd(s)
	local t = peek(s)
	return not t or t.t == "pipe"
end

-- f1, f2 ... (commas optional); each a known column
local function fieldList(s, allowMinus)
	local list, minus = {}, false
	while not cmdEnd(s) do
		local t = take(s)
		if t.t == "comma" then role(t, "arg")
		elseif t.t == "word" then
			local f = t.s
			if allowMinus and f == "-" then minus = true; role(t, "op")
			else
				local desc = false
				if allowMinus == "sort" and byte(f, 1) == 45 then desc = true; f = sub(f, 2) end
				if allowMinus == "sort" and byte(f, 1) == 43 then f = sub(f, 2) end
				role(t, "field")
				if not known(s, f) then checkField(s, { p = t.p + (desc and 1 or 0) }, f) end
				list[#list + 1] = allowMinus == "sort" and { f, desc and "desc" or "asc" } or f
			end
		else err("parse", t.p, "a field name is needed") end
	end
	return list, minus
end

local function setKinds(s, kinds) s.kinds, s.any = kinds, false end

local FN = { count = true, sum = true, avg = true, min = true, max = true, dc = true, latest = true, earliest = true, count_if = true }

-- a name given by as: letters, digits and _ only (a name with a space or symbol would never be typeable)
local function newName(t)
	local n = t.t == "str" and t.v or t.s
	if not match(n, "^[%a_][%w_]*$") then err("arg", t.p, "a field name has no spaces or symbols: " .. n) end
	return n
end

-- fn(field) [as name] | count | count_if(f=v)
local function fnSpec(s)
	local t = take(s)
	if not t or t.t ~= "word" or not FN[lower(t.s)] then err("arg", t and t.p or s.len + 1, "a function is needed: count, sum, avg, min, max, dc, latest, earliest, count_if" .. (t and t.s and suggest(t.s, { "count", "sum", "avg", "min", "max", "dc", "latest", "earliest", "count_if" }) or "")) end
	role(t, "fn")
	local f = { fn = lower(t.s) }
	local lp = peek(s)
	if lp and lp.t == "lp" then
		take(s); role(lp, "paren")
		local a = take(s)
		if not a or a.t ~= "word" then err("parse", a and a.p or s.len + 1, "a field is needed inside ( )") end
		role(a, "field")
		if not known(s, a.s) then checkField(s, a, a.s) end
		if f.fn == "count_if" then
			local op = take(s)
			if not op or op.t ~= "op" or op.s ~= "=" then err("parse", op and op.p or s.len + 1, "count_if takes field=value") end
			role(op, "op")
			local v = take(s)
			if not v or (v.t ~= "word" and v.t ~= "str") then err("parse", v and v.p or s.len + 1, "a value is needed") end
			role(v, v.t == "str" and "string" or "value")
			f.cond = { a.s, v.v or v.s }
		else
			f.field = a.s
		end
		local rp = take(s)
		if not rp or rp.t ~= "rp" then err("parse", rp and rp.p or s.len + 1, "a ) is needed") end
		role(rp, "paren")
	elseif f.fn ~= "count" then
		err("arg", t.p, f.fn .. " needs a field: " .. f.fn .. "(field)")
	end
	if f.fn == "count_if" and not f.cond then err("arg", t.p, "count_if takes field=value") end
	if isWord(peek(s), "as") then
		role(take(s), "arg")
		local nm = take(s)
		if not nm or (nm.t ~= "word" and nm.t ~= "str") then err("parse", nm and nm.p or s.len + 1, "a name is needed after as") end
		role(nm, "field")
		f.as = newName(nm)
	end
	return f
end

local function byList(s)
	if not isWord(peek(s), "by") then return {} end
	role(take(s), "arg")
	local list = {}
	while not cmdEnd(s) do
		local t = take(s)
		if t.t == "comma" then role(t, "arg")
		elseif t.t == "word" then
			role(t, "field")
			if not known(s, t.s) then checkField(s, t, t.s) end
			list[#list + 1] = t.s
		else err("parse", t.p, "a field name is needed after by") end
	end
	if #list == 0 then err("parse", s.len + 1, "a field is needed after by") end
	return list
end

local function kv(s)
	local t, op = peek(s), peek(s, 1)
	if t and t.t == "word" and op and op.t == "op" and op.s == "=" then
		take(s); take(s); role(t, "arg"); role(op, "op")
		local v = take(s)
		if not v or (v.t ~= "word" and v.t ~= "str") then err("parse", v and v.p or s.len + 1, "a value is needed after " .. t.s .. "=") end
		role(v, v.t == "str" and "string" or (tonumber(v.s) and "number" or "value"))
		return lower(t.s), v.v or v.s, v
	end
end

local function number(s, t, what)
	local n = tonumber(t.s)
	if not n or n < 1 or n ~= math.floor(n) then err("arg", t.p, what .. " is a whole number above 0") end
	role(t, "number")
	return n
end

local CMD = {}

CMD.where = function(s, c)
	if cmdEnd(s) then err("parse", s.len + 1, "where needs a term") end
	local e = parseOr(s, false)
	c.ast = e
	return "q.where"
end
CMD.fields = function(s, c)
	local list, minus = fieldList(s, true)
	if #list == 0 then err("parse", c.pos, "fields needs a field") end
	if minus then c.opts.drop = list; for _, f in ipairs(list) do s.kinds[f] = nil end
	else
		c.opts.keep = list
		local k = {}
		for _, f in ipairs(list) do k[f] = known(s, f) end
		setKinds(s, k)
	end
	return "q.fields"
end
CMD.table = function(s, c)
	local list = fieldList(s, false)
	if #list == 0 then err("parse", c.pos, "table needs a field") end
	c.opts.select = list
	local k = {}
	for _, f in ipairs(list) do k[f] = known(s, f) end
	setKinds(s, k)
	s.shape = "table"
	return "q.select"
end
CMD.rename = function(s, c)
	local map = {}
	while not cmdEnd(s) do
		local a = take(s)
		if a.t == "comma" then role(a, "arg")
		else
			if a.t ~= "word" then err("parse", a.p, "rename takes a as b") end
			role(a, "field")
			if not known(s, a.s) then checkField(s, a, a.s) end
			local as = take(s)
			if not isWord(as, "as") then err("parse", as and as.p or s.len + 1, "rename takes a as b") end
			role(as, "arg")
			local b = take(s)
			if not b or (b.t ~= "word" and b.t ~= "str") then err("parse", b and b.p or s.len + 1, "a new name is needed") end
			role(b, "field")
			local bn = newName(b)
			map[a.s] = bn
			s.kinds[bn], s.kinds[a.s] = s.kinds[a.s], nil
		end
	end
	if not next(map) then err("parse", c.pos, "rename takes a as b") end
	c.opts.map = map
	return "q.rename"
end
CMD.sort = function(s, c)
	local list = fieldList(s, "sort")
	if #list == 0 then err("parse", c.pos, "sort needs a field") end
	c.opts.order = list
	return "q.order"
end
local function headTail(s, c)
	c.opts.limit = 10
	if not cmdEnd(s) then
		local t = take(s)
		c.opts.limit = number(s, t, c.name)
		if c.opts.limit > (Q.maxRows or 5000) then err("limit", t.p, c.name .. " at most " .. (Q.maxRows or 5000)) end
	end
	if not cmdEnd(s) then err("parse", peek(s).p, c.name .. " takes one number") end
end
CMD.head = function(s, c) headTail(s, c) return "q.limit" end
CMD.tail = function(s, c) headTail(s, c) return "q.tail" end
CMD.dedup = function(s, c)
	local list = fieldList(s, false)
	if #list == 0 then err("parse", c.pos, "dedup needs a field") end
	c.opts.fields = list
	return "q.dedup"
end
CMD.stats = function(s, c)
	local fns = {}
	while not cmdEnd(s) and not isWord(peek(s), "by") do
		local t = peek(s)
		if t.t == "comma" then role(take(s), "arg") else fns[#fns + 1] = fnSpec(s) end
	end
	if #fns == 0 then err("arg", c.pos, "stats needs a function") end
	local by = byList(s)
	c.opts.fns, c.opts.by = fns, by
	local k = {}
	for _, f in ipairs(by) do k[f] = known(s, f) end
	for _, f in ipairs(fns) do k[M.PSS_StatLabel(f)] = "n" end
	setKinds(s, k)
	s.shape = #by == 0 and (#fns == 1 and "number" or "table") or (#by == 1 and "table" or "matrix")
	return "q.stats"
end
CMD.timechart = function(s, c)
	local key, val, vt = kv(s)
	if key ~= "span" then err("arg", vt and vt.p or c.pos, "timechart starts with span=1h, 1d, 1w or 1mon") end
	local span = M.PSS_Time.span(val)
	if not span then err("arg", vt.p, "span is 1h, 1d, 1w, 1mon or a number of m, h, d") end
	role(vt, "time")
	c.opts.span = span
	if not known(s, "time") then err("field", c.pos, "timechart needs a time field") end
	local f = fnSpec(s)
	c.opts.fn, c.opts.field, c.opts.cond, c.opts.as = f.fn, f.field, f.cond, f.as
	local by = byList(s)
	if #by > 1 then err("arg", c.pos, "timechart splits by one field") end
	c.opts.by = by[1]
	if not cmdEnd(s) then err("parse", peek(s).p, "unexpected " .. tostring(peek(s).s)) end
	local k = { time = "t" }
	if not by[1] then k[M.PSS_StatLabel(f)] = "n" end
	setKinds(s, k)
	s.any = by[1] ~= nil		-- the series are named by values
	s.shape = "series"
	return "q.timechart"
end
local function topRare(s, c, rare)
	local t = peek(s)
	c.opts.n = 10
	if t and t.t == "word" and tonumber(t.s) then take(s); c.opts.n = number(s, t, "top") end
	local kk, vv, vt = kv(s)
	if kk == "limit" then c.opts.n = number(s, vt, "limit") end
	local f = take(s)
	if not f or f.t ~= "word" then err("parse", f and f.p or s.len + 1, c.name .. " needs a field") end
	role(f, "field")
	if not known(s, f.s) then checkField(s, f, f.s) end
	c.opts.field, c.opts.rare = f.s, rare or nil
	local by = byList(s)
	c.opts.by = by[1]
	local k = { [f.s] = known(s, f.s), count = "n", percent = "n" }
	if by[1] then k[by[1]] = known(s, by[1]) end
	setKinds(s, k)
	s.shape = "table"
	return "q.top"
end
CMD.top = function(s, c) return topRare(s, c, false) end
CMD.rare = function(s, c) return topRare(s, c, true) end
CMD.calc = function(s, c)
	local first = peek(s)
	if not first then err("parse", c.pos, "calc is name = a (+|-|*|/) b") end
	local stop = #s.text
	local nxt = s.i
	while s.toks[nxt] and s.toks[nxt].t ~= "pipe" do nxt = nxt + 1 end
	if s.toks[nxt] then stop = s.toks[nxt].p - 1 end
	local raw = sub(s.text, first.p, stop)
	local name, a, op, b = match(raw, "^%s*([%a_][%w_]*)%s*=%s*([%w_%.]+)%s*([%+%-%*/])%s*([%w_%.]+)%s*$")
	if not name then err("arg", first.p, "calc is name = a (+|-|*|/) b") end
	for k = s.i, nxt - 1 do s.toks[k].role = "arg" end
	role(first, "field")
	s.i = nxt
	for _, x in ipairs({ a, b }) do
		if not tonumber(x) and not known(s, x) then checkField(s, first, x) end
	end
	c.opts.name, c.opts.a, c.opts.op, c.opts.b = name, tonumber(a) or a, op, tonumber(b) or b
	s.kinds[name] = "n"
	return "q.calc"
end
CMD.join = function(s, c)
	local f = take(s)
	if not f or f.t ~= "word" then err("parse", f and f.p or s.len + 1, "join needs a field") end
	role(f, "field")
	if not known(s, f.s) then checkField(s, f, f.s) end
	local key, val, vt = kv(s)
	if key == "index" then
		role(vt, "indexname")
		local x = M.PSS_Ix and M.PSS_Ix(lower(val))
		if not x then err("index", vt.p, "unknown index " .. val .. suggest(val, M.PSS_IxNames and M.PSS_IxNames() or {})) end
		if x.kind ~= "state" then err("arg", vt.p, "join reads a state index; " .. val .. " is an event index") end
		c.opts.field, c.opts.index = f.s, lower(val)
		for _, fl in ipairs(x.fields) do if not s.kinds[fl[1]] then s.kinds[fl[1]] = fl[2] end end
		return "q.ixjoin"
	elseif key then
		err("arg", vt.p, "join takes index=<name>")
	end
	local dict = M.PSS_IX_DICTS and M.PSS_IX_DICTS[f.s]
	if not dict then err("arg", f.p, "no dictionary " .. f.s .. " (join item, ent, owner, cmp, evt, channel, or join <field> index=<state index>)") end
	c.opts.join = { f.s }
	for _, df in ipairs(dict) do s.kinds[f.s .. "_" .. df] = df == "pending" and "b" or "s" end
	return "q.join"
end
local CHART = { column = true, bar = true, line = true, area = true, donut = true, heat = true, number = true, table = true }
local CHARTSHAPE = { line = { series = true }, area = { series = true }, column = { series = true, table = true },
	bar = { series = true, table = true }, donut = { table = true }, heat = { matrix = true }, number = { number = true } }
CMD.chart = function(s, c)
	local kt = take(s)
	if not kt or kt.t ~= "word" or not CHART[lower(kt.s)] then err("arg", kt and kt.p or c.pos, "chart kind: column, bar, line, area, donut, heat, number or table") end
	role(kt, "arg")
	local chart = { kind = lower(kt.s) }
	while not cmdEnd(s) do
		local key, val, vt = kv(s)
		if key then
			if key == "x" or key == "y" or key == "series" then
				if not known(s, val) then checkField(s, vt, val) end
				chart[key] = val
			elseif key == "top" then chart.top = number(s, vt, "top")
			elseif key == "title" then chart.title = val
			else err("arg", vt.p, "chart takes x, y, series, top, title and stack") end
		else
			local t = take(s)
			if isWord(t, "stack") then role(t, "arg"); chart.stack = true
			else err("arg", t.p, "chart takes x, y, series, top, title and stack") end
		end
	end
	local ok = CHARTSHAPE[chart.kind]
	if ok and not ok[s.shape or "events"] then
		err("arg", kt.p, "a " .. chart.kind .. " chart needs " .. (chart.kind == "heat" and "a stats by two fields" or chart.kind == "number" and "one number" or (ok.series and ok.table) and "a table or a time series" or ok.table and "a table" or "a time series (timechart)") .. "; this search gives " .. (s.shape or "events"))
	end
	c.chart = chart
	return nil
end
CMD.fieldsummary = function(s, c)
	c.opts.maxvals = 5
	local key, val, vt = kv(s)
	if key == "maxvals" then c.opts.maxvals = number(s, vt, "maxvals") elseif key then err("arg", vt.p, "fieldsummary takes maxvals=n") end
	if not cmdEnd(s) then err("parse", peek(s).p, "unexpected " .. tostring(peek(s).s)) end
	c.opts.kinds = s.kinds
	setKinds(s, { field = "s", kind = "k", count = "n", distinct = "n", nulls = "n", min = "s", max = "s", top = "s" })
	s.shape = "table"
	return "q.fieldsummary"
end
CMD.values = function(s, c)
	local list = fieldList(s, false)
	c.opts.fields = #list > 0 and list or nil
	setKinds(s, { field = "s", values = "s" })
	s.shape = "table"
	return "q.values"
end

local CMDNAMES = {}
for k in pairs(CMD) do CMDNAMES[#CMDNAMES + 1] = k end
sort(CMDNAMES)
Q.COMMANDS = CMDNAMES

------------------------------------------------------------------------
-- parse and compile
------------------------------------------------------------------------
-- the fields a search may use: the named indexes', or every lazy index's
local function searchKinds(s)
	local kinds = {}
	local list = s.indexes
	if not list or (#list == 1 and list[1].name == "*") then
		s.lazy = true
		for f, k in pairs(LAZYKIND) do kinds[f] = k end
		for _, name in ipairs(LAZY) do
			local x = M.PSS_Ix and M.PSS_Ix(name)
			if x then for _, f in ipairs(x.fields) do if not kinds[f[1]] then kinds[f[1]] = f[2] end end end
		end
		kinds.weekday, kinds.hour = "n", "n"
		for f in pairs(VIRTUAL) do if not kinds[f] then kinds[f] = "s" end end
		return kinds
	end
	for _, it in ipairs(list) do
		local x = M.PSS_Ix and M.PSS_Ix(it.name)
		if not x then err("index", it.pos, "unknown index " .. it.name .. suggest(it.name, M.PSS_IxNames and M.PSS_IxNames() or {})) end
		for _, f in ipairs(x.fields) do if not kinds[f[1]] then kinds[f[1]] = f[2] end end
	end
	for f, k in pairs(ENVELOPE) do if not kinds[f] and (f ~= "time" or kinds.st) then kinds[f] = k end end
	if #list > 1 then kinds.index = "k" end
	if kinds.time and kinds.st then kinds.weekday, kinds.hour = "n", "n" end
	for _, it in ipairs(list) do
		if it.name == "log" or it.name == "counts" then
			for f in pairs(VIRTUAL) do if not kinds[f] then kinds[f] = "s" end end
			break
		end
	end
	return kinds
end

-- the index= list is read before the terms (it may come after them in the text)
local function preIndexes(s)
	for k, t in ipairs(s.toks) do
		if t.t == "pipe" then break end
		local op, v = s.toks[k + 1], s.toks[k + 2]
		if isWord(t, "index") and op and op.t == "op" and op.s == "=" and v and v.t == "word" then
			local list, j = {}, k + 2
			while s.toks[j] and s.toks[j].t == "word" do
				list[#list + 1] = { name = lower(s.toks[j].s), pos = s.toks[j].p }
				if s.toks[j + 1] and s.toks[j + 1].t == "comma" then j = j + 2 else break end
			end
			return list
		end
	end
end

local function run(text, now, all)
	if type(text) ~= "string" then err("parse", 1, "a query is text") end
	if #text > LIMIT.text then err("limit", LIMIT.text + 1, "a query is at most " .. LIMIT.text .. " bytes") end
	local terr
	if not all then all, terr = tokenize(text) end
	if not all then error(terr, 0) end
	local toks = {}
	for _, t in ipairs(all) do if t.t ~= "ws" then toks[#toks + 1] = t end end
	local s = { text = text, len = #text, toks = toks, i = 1, terms = 0, params = {}, now = now, top = true, all = all, vnames = {} }
	local pre = preIndexes(s)
	s.indexes = nil
	s.kinds = searchKinds({ indexes = pre })
	s.lazy = not pre or (#pre == 1 and pre[1].name == "*")
	local where = parseAnd(s, false)
	if isWord(peek(s), "or") then
		local node = { k = "or", #where == 1 and where[1] or where }
		while isWord(peek(s), "or") do
			local o = take(s)
			role(o, "bool")
			local nx = parseAnd(s, false)
			if #nx == 0 then err("parse", (peek(s) or {}).p or s.len + 1, "a term is needed after OR") end
			node[#node + 1] = #nx == 1 and nx[1] or nx
		end
		where = { k = "and", node }
	end
	local cols = {}
	for f in pairs(s.kinds) do cols[#cols + 1] = f end
	local ast = { indexes = s.indexes, lazy = s.lazy, time = s.time, where = where, commands = {}, kinds = s.kinds, params = s.params }
	s.shape = "events"
	if not s.lazy then		-- a search over state indexes only is a table
		local state = true
		for _, it in ipairs(pre or {}) do local x = M.PSS_Ix(it.name); if x and x.kind == "event" then state = false end end
		if state then s.shape = "table" end
	end
	local ncmd = 0
	while peek(s) do
		local p = take(s)
		if p.t ~= "pipe" then err("parse", p.p, "unexpected " .. tostring(p.s)) end
		role(p, "pipe")
		local nt = take(s)
		if not nt or nt.t ~= "word" then err("parse", nt and nt.p or s.len + 1, "a command is needed after |") end
		local name = lower(nt.s)
		local f = CMD[name]
		if not f then err("cmd", nt.p, "unknown command " .. nt.s .. suggest(nt.s, CMDNAMES)) end
		role(nt, "cmd")
		ncmd = ncmd + 1
		if ncmd > LIMIT.commands then err("limit", nt.p, "at most " .. LIMIT.commands .. " commands") end
		if ast.chart then err("arg", nt.p, "chart is the last command") end
		local c = { name = name, opts = {}, pos = nt.p }
		local before = s.kinds
		local svc = f(s, c)
		if name == "where" then c.kinds = before end
		c.svc = svc
		if c.chart then ast.chart = c.chart end
		ast.commands[#ast.commands + 1] = c
		if not cmdEnd(s) then err("parse", peek(s).p, "unexpected " .. tostring(peek(s).s)) end
	end
	ast.shape = s.shape
	ast.finalKinds = s.kinds
	ast.vtime = s.vtime
	ast.vnames = s.vnames
	return ast, s
end

function Q.parse(text, now)
	local ok, ast = pcall(run, text, now)
	if not ok then
		if type(ast) == "table" then return nil, ast end
		return nil, { code = "parse", pos = 1, msg = tostring(ast) }
	end
	return ast
end

------------------------------------------------------------------------
-- Plans
------------------------------------------------------------------------
local Plan = {}
local PlanMT = { __index = Plan }

local function norm(text)
	local all = tokenize(text)
	if not all then return text end
	local out = {}
	for _, t in ipairs(all) do
		if t.t == "ws" then out[#out + 1] = " " else out[#out + 1] = sub(text, t.p, t.p + t.n - 1) end
	end
	return (gsub(gsub(concat(out), "^ ", ""), " $", ""))
end
Q.norm = norm

local function kindFn(kinds) return function(f) return kinds[f] end end

local function textFieldsOf(kinds, ast)
	local list = {}
	for f, k in pairs(kinds) do if k == "s" and not VIRTUAL[f] then list[#list + 1] = f end end
	sort(list)
	return list
end

local function copy(node, params)
	if type(node) ~= "table" then return node end
	local c = {}
	for k, v in pairs(node) do c[k] = copy(v, params) end
	if c.param then
		local v = params and params[c.param]
		if v == nil then err("arg", c.vpos or c.pos, "parameter $" .. c.param .. " has no value") end
		c.value = v		-- one literal, never parsed again
		c.param = nil
		c.bound = true
	end
	return c
end

local function hasParam(node)
	if type(node) ~= "table" then return false end
	if node.param then return true end
	for _, v in pairs(node) do if type(v) == "table" and hasParam(v) then return true end end
	return false
end

-- lazy search: the bare words become one test that also matches the names they resolve to
local function lazyNode(where, kinds, info)
	local words, keep = {}, { k = "and" }
	local top = where.k == "and" and where or { where }
	for _, n in ipairs(top) do
		if n.k == "text" then words[#words + 1] = n.value else keep[#keep + 1] = n end
	end
	if #words == 0 then return where end
	local phrase = concat(words, " ")
	local got = M.PSS_Terms and M.PSS_Terms.names(phrase) or { items = {}, owners = {}, ents = {} }
	local items, owners, ents = {}, {}, {}
	for _, id in ipairs(got.items) do items[id] = true end
	for _, k in ipairs(got.owners) do owners[k] = true end
	for _, id in ipairs(got.ents) do ents[id] = true end
	local parts = {}
	if #got.items > 0 then parts[#parts + 1] = phrase .. ": " .. #got.items .. (#got.items == 1 and " item" or " items") end
	if #got.owners > 0 then parts[#parts + 1] = phrase .. ": " .. #got.owners .. (#got.owners == 1 and " owner" or " owners") end
	if #got.ents > 0 then parts[#parts + 1] = phrase .. ": " .. #got.ents .. (#got.ents == 1 and " character" or " characters") end
	info.resolved = #parts > 0 and concat(parts, "; ") or nil
	info.ambiguous = got.ambiguous
	keep[#keep + 1] = { k = "lazy", words = phrase, items = items, owners = owners, ents = ents }
	return keep
end

local function build(ast, params, now)
	local plan = setmetatable({ ast = ast, indexes = ast.indexes, lazy = ast.lazy, chart = ast.chart, steps = {}, info = {} }, PlanMT)
	local where = copy(ast.where, params)
	if ast.lazy then where = lazyNode(where, ast.kinds, plan.info) end
	local F = { kind = kindFn(ast.kinds), textFields = textFieldsOf(ast.kinds) }
	plan.F = F
	local pred, perr = M.PSS_Pred.compile(where, F)
	if not pred then err(perr.code, perr.pos, perr.msg) end
	plan.pred = pred
	plan.where = where
	for _, c in ipairs(ast.commands) do
		if c.svc then
			local opts = {}
			for k, v in pairs(c.opts) do opts[k] = v end
			if c.name == "where" then
				local w = copy(c.ast, params)
				local p2, e2 = M.PSS_Pred.compile(w, { kind = kindFn(c.kinds), textFields = textFieldsOf(c.kinds) })
				if not p2 then err(e2.code, e2.pos, e2.msg) end
				opts.pred = p2
			end
			plan.steps[#plan.steps + 1] = { c.svc, opts, c.name }
		end
	end
	return plan
end

function Q.compile(text, now)
	local ast, e = Q.parse(text, now)
	if not ast then return nil, e end
	ast.text = norm(text)
	if hasParam(ast.where) or (function() for _, c in ipairs(ast.commands) do if hasParam(c.ast) then return true end end end)() then
		local plan = setmetatable({ ast = ast, unbound = true, indexes = ast.indexes, lazy = ast.lazy, chart = ast.chart, steps = {}, info = {} }, PlanMT)
		for _, c in ipairs(ast.commands) do if c.svc then plan.steps[#plan.steps + 1] = { c.svc, c.opts, c.name } end end
		return plan
	end
	local ok, plan = pcall(build, ast, nil, now)
	if not ok then
		if type(plan) == "table" and plan.code then return nil, plan end
		return nil, { code = "parse", pos = 1, msg = tostring(plan) }
	end
	return plan
end

function Plan:bind(params)
	if not self.unbound and not params then return self end
	if not self.unbound then return self end
	local ok, plan = pcall(build, self.ast, params or {})
	if not ok then
		if type(plan) == "table" and plan.code then return nil, plan end
		return nil, { code = "arg", pos = 1, msg = tostring(plan) }
	end
	return plan
end

function Plan:text() return self.ast.text end
function Plan:shape() return self.ast.shape end
-- the folder the plan needs before it can answer in full (tier 1), nil when none
function Plan:needs()
	local list = self.indexes
	local names = {}
	if not list or self.lazy then names = LAZY else for i, it in ipairs(list) do names[i] = it.name end end
	for _, name in ipairs(names) do
		local x = M.PSS_Ix and M.PSS_Ix(name)
		local part = x and (x:ready()) and x:needs()
		if part then return part end
	end
	return nil
end
function Plan:indexNames()
	if not self.indexes or self.lazy then return nil end
	local out = {}
	for i, it in ipairs(self.indexes) do out[i] = it.name end
	return out
end

------------------------------------------------------------------------
-- Tokens for colour coding (B): every byte, never raises
------------------------------------------------------------------------
local TCOLS = { "pos", "len", "kind" }
local DEFAULT = { ws = "space", pipe = "pipe", lp = "paren", rp = "paren", op = "op", comma = "arg", str = "string", word = "word" }

function Q.tokens(text)
	local out = { cols = TCOLS, n = 0 }
	if type(text) ~= "string" then return out end
	local all, terr = tokenize(text)
	local errAt
	if not all then
		errAt = terr.pos
		all = {}
		local part = tokenize(sub(text, 1, errAt - 1)) or {}
		for _, t in ipairs(part) do all[#all + 1] = t end
		all[#all + 1] = { t = "err", p = errAt, n = #text - errAt + 1 }
	elseif #text > LIMIT.text then
		errAt = LIMIT.text + 1
	else
		local ok, e = pcall(run, text, nil, all)		-- run() marks the role of every token it reads
		if not ok then errAt = type(e) == "table" and e.pos or 1 end
	end
	for _, t in ipairs(all) do
		local kind
		if t.t == "err" then kind = "error"
		elseif errAt and t.p >= errAt and t.t ~= "ws" then kind = "error"
		elseif t.split then
			out.n = out.n + 1; out[out.n] = { t.p, 1, "bool" }
			out.n = out.n + 1; out[out.n] = { t.p + 1, t.n - 1, (errAt and t.p + 1 >= errAt) and "error" or (t.split.role or "word") }
		else kind = t.role or DEFAULT[t.t] end
		if kind then out.n = out.n + 1; out[out.n] = { t.p, t.n, kind } end
	end
	return out
end
