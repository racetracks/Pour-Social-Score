------------------------------------------------------------------------
-- POUR SOCIAL SCORE - EVENTS VIEW (for PourSocialScore_GUI)
--
-- What the window's Events tab shows, worked out here so the tab only
-- draws: the blocked lines of the lists (or one entry of them), filtered by
-- time (this session, the last 24 hours, all time or a custom range), types,
-- source and a search over player, channel and message, and sorted by a
-- column. The pies, View Events and the panes' histories open it with an
-- entry, a period and the types ticked. Reading the lines loads
-- PourSocialScore_Logging (the specs' read functions do).
--
--   spec (an entry, from PSS_PlayerView / PSS_GuildView / PSS_FilterView) =
--     { kind, id, label(id) -> name (nil: gone), read(id) -> lines,
--       reset(id) (asked first when confirm), owner(id), counts(id),
--       all() -> its whole list's spec }
--   A whole list's spec has id false and source = its key.
--
--   M.PSS_EVENT_SOURCES, M.PSS_EVENT_TIMES
--   local v = M.PSS_EventsViewNew()
--   v:Open(spec, opts)          a fresh query (opts.period, opts.cats)
--   v:Refresh()                 read the lines again (an entry gone: its list)
--   v:Apply(find)               filter and sort into v.shown; n
--   v:SortBy(key)
--   v:SetPeriod(key)            "session" | "day" | "all" | "custom"
--   v:ApplyRange(fromText, toText)   nil, or the error text
--   v:AllTypes(), v:ToggleType(cat), v:TypeOn(cat)
--   v:SourceOn(key), v:ToggleSource(key), v:ScopeOff()
--   v:IsCustom(), v:Scoped(), v:PeriodIs(key), v:ScopeText()   the query, asked
--   v:Heading(n), v:TimeLabel(), v:TypesLabel(), v:SourceLabel()
--   v:NavKey(), v:NavTitle(key), v:NavApply(key), v:Reset()
--   v:ResetText()               the confirm's text, or nil (no confirm)
--   v:DoReset()
--   M.PSS_EventCells(v, h, into), M.PSS_EventTip(v, h), M.PSS_EventCopy(h)
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local History = M.PSS_History

local ipairs, pairs, tostring, tonumber, setmetatable, date = ipairs, pairs, tostring, tonumber, setmetatable, date
local lower, concat, sort, wipe = string.lower, table.concat, table.sort, wipe

local TIME_FMT = "%Y/%m/%d %H:%M:%S"
local INPUT_FMT = "%Y-%m-%d %H:%M"
local DAY = 86400
local MAX_SAVED = 100

-- the lists whose events show
M.PSS_EVENT_SOURCES = {
	{ key = "players", text = "Player Ignore List", all = function() return M.PSS_AllPlayersSpec() end },
	{ key = "guilds", text = "Guild Ignore List", all = function() return M.PSS_AllGuildsSpec() end },
	{ key = "filters", text = "Chat Filters", all = function() return M.PSS_AllFiltersSpec() end },
}
local SOURCES = M.PSS_EVENT_SOURCES

M.PSS_EVENT_TIMES = {
	{ key = "session", text = "This session" },
	{ key = "day", text = "Last 24 hours" },
	{ key = "all", text = "All time" },
	{ key = "custom", text = "Custom range" },
}

local PERIOD_TEXT = {}
for _, t in ipairs(M.PSS_EVENT_TIMES) do PERIOD_TEXT[t.key] = t.text end

------------------------------------------------------------------------
-- Queries: q = { scope = an entry's spec (nil: the sources), sources =
-- { [key] = true }, period = "session" | "day" | "custom" | nil (all time),
-- from, to (custom), cats = { [cat] = true } (nil: every type) }
------------------------------------------------------------------------
local function NewQuery()
	local q = { sources = {} }
	for _, src in ipairs(SOURCES) do q.sources[src.key] = true end
	return q
end

local function CopyQuery(q)
	local c = { scope = q.scope, period = q.period, from = q.from, to = q.to, sources = {} }
	for k, v in pairs(q.sources) do c.sources[k] = v end
	if q.cats then
		c.cats = {}
		for k, v in pairs(q.cats) do c.cats[k] = v end
	end
	return c
end

-- a string for the query (back / forward tell views apart by it); nil for
-- the tab as it opens
local function QueryKey(q)
	local parts = {}
	if q.scope then parts[#parts + 1] = tostring(q.scope.kind) .. "=" .. tostring(q.scope.id) end
	for _, src in ipairs(SOURCES) do if not q.sources[src.key] then parts[#parts + 1] = "-" .. src.key end end
	if q.period then parts[#parts + 1] = q.period .. (q.period == "custom" and (tostring(q.from) .. "-" .. tostring(q.to)) or "") end
	if q.cats then
		for _, cat in ipairs(History.ALL_CATS or {}) do if q.cats[cat] then parts[#parts + 1] = "+" .. cat end end
	end
	if #parts == 0 then return nil end
	return concat(parts, " ")
end

local function Title(q, name)
	if q.scope then return name or "?" end
	local on, all = {}, true
	for _, src in ipairs(SOURCES) do
		if q.sources[src.key] then on[#on + 1] = src.text else all = false end
	end
	if all then return "All sources" end
	if #on == 0 then return "No source" end
	return concat(on, ", ")
end

local function TimeLabel(q)
	if q.period == "custom" then
		return ("%s to %s"):format(q.from and date(INPUT_FMT, q.from) or "...", q.to and date(INPUT_FMT, q.to) or "now")
	end
	return PERIOD_TEXT[q.period or "all"] or ""
end

local function TypesLabel(q)
	if not q.cats then return "All types" end
	local on = {}
	for _, cat in ipairs(History.ALL_CATS or {}) do
		if q.cats[cat] then on[#on + 1] = History.CAT_LABEL[cat] or cat end
	end
	if #on == 0 then return "No type" end
	if #on <= 2 then return concat(on, ", ") end
	return ("%d types"):format(#on)
end

local function TimeText(h)
	local ts = tonumber(h.ts)
	return ts and ts > 0 and date(TIME_FMT, ts) or History.UNKNOWN
end

------------------------------------------------------------------------
-- The view
------------------------------------------------------------------------
local View = {}
View.__index = View

function M.PSS_EventsViewNew()
	return setmetatable({ q = NewQuery(), all = {}, shown = {}, vals = {}, order = {}, srcOf = {}, saved = {},
		nsaved = 0, sortKey = "time", sortAsc = false }, View)
end

function View:SourceText(h)
	local src = History.sourceLabel and History.sourceLabel[h]
	return src or self.srcOf[h] or self.name or ""
end

local SORT = {
	time = function(_, h) return tonumber(h.ts) or 0 end,
	source = function(v, h) return lower(v:SourceText(h)) end,
	member = function(_, h) return lower(h.member or "") end,
	kind = function(_, h) return M.PSS_EventType(h) end,
	channel = function(_, h) return lower(h.channel or "") end,
	message = function(_, h) return lower(h.message or "") end,
}

-- A fresh query: spec (an entry; a whole list: that list as the source;
-- nil: every list), opts.period, opts.cats (nil: every type)
function View:Open(spec, opts)
	opts = opts or {}
	local q = NewQuery()
	if spec and spec.id == false and spec.source then
		for k in pairs(q.sources) do q.sources[k] = k == spec.source end
	elseif spec then
		q.scope = spec
	end
	q.period = opts.period ~= "all" and opts.period or nil
	if opts.cats then
		q.cats = {}
		for k, v in pairs(opts.cats) do q.cats[k] = v end
	end
	self.q = q
	self.sortKey, self.sortAsc = "time", false
end

-- Read the lines again (an entry gone: its whole list instead).
function View:Refresh()
	local q = self.q
	local all, srcOf = {}, self.srcOf
	wipe(srcOf)
	local scope = q.scope
	local name = scope and scope.label(scope.id)
	if scope and not name then
		if scope.all then
			local list = scope.all()
			if list and list.source then
				for k in pairs(q.sources) do q.sources[k] = k == list.source end
			end
		end
		q.scope, scope = nil, nil
	end
	self.name = name
	if scope then
		local lines = scope.read(scope.id) or {}
		for i = 1, #lines do all[i] = lines[i] end
		if scope.owner and scope.counts then
			local counts = scope.counts(scope.id)
			if counts then
				-- blocks counted but no longer in the block history
				M.PSS_AddExpiredEvents(all, counts, History.RecentSlots and History.RecentSlots(scope.owner(scope.id)),
					scope.kind ~= "filter" and History.KEEP_TOTAL ~= nil and not History.LOG_ALL)
			end
		end
	else
		local order = self.order
		wipe(order)
		for _, src in ipairs(SOURCES) do
			if q.sources[src.key] then
				local spec = src.all()
				local lines = spec and spec.read(false) or {}
				for i = 1, #lines do
					local h = lines[i]
					all[#all + 1] = h
					srcOf[h] = src.text
					order[h] = #all
				end
			end
		end
		-- newest first across the lists
		sort(all, function(a, b)
			local x, y = tonumber(a.ts) or 0, tonumber(b.ts) or 0
			if x ~= y then return x > y end
			return order[a] < order[b]
		end)
	end
	self.all = all
end

-- Drop the lines read (the whole block log and the unpacked kept lines)
-- while the tab is not shown; Refresh reads them again.
function View:Release()
	self.all = {}
	wipe(self.shown)
	wipe(self.vals)
	wipe(self.order)
	wipe(self.srcOf)
end

-- Filter by the query and the search text, sort into self.shown; n
function View:Apply(find)
	local q = self.q
	find = lower(M.trim(find or "") or "")
	local since, upto = M.PSS_EventRange(q)
	local out, n = self.shown, 0
	for i = 1, #self.all do
		local h = self.all[i]
		if M.PSS_EventMatches(q, h, find, since, upto) then
			n = n + 1
			out[n] = h
		end
	end
	for i = #out, n + 1, -1 do out[i] = nil end
	if self.sortKey ~= "time" or self.sortAsc then
		local fn, asc, vals = SORT[self.sortKey] or SORT.time, self.sortAsc, self.vals
		wipe(vals)
		for i = 1, n do vals[out[i]] = fn(self, out[i]) end
		-- read order (newest first) breaks ties
		local order = self.order
		wipe(order)
		for i = 1, n do order[out[i]] = i end
		sort(out, function(a, b)
			local A, B = vals[a], vals[b]
			if A ~= B then if asc then return A < B end return A > B end
			return order[a] < order[b]
		end)
	end
	return n
end

function View:SortBy(key)
	if self.sortKey == key then
		self.sortAsc = not self.sortAsc
	else
		-- time starts newest first
		self.sortKey, self.sortAsc = key, key ~= "time"
	end
end

-- the Time drop-down
function View:SetPeriod(key)
	local q = self.q
	if key == "custom" then
		q.period = "custom"
		q.from = q.from or (History.Now() - DAY)
	else
		q.period = key ~= "all" and key or nil
	end
end

function View:RangeTexts()
	local q = self.q
	return q.from and date(INPUT_FMT, q.from) or "", q.to and date(INPUT_FMT, q.to) or ""
end

-- the custom range's boxes: nil when applied, else the error text
function View:ApplyRange(fromText, toText)
	local from = M.PSS_ParseEventTime(fromText)
	toText = M.trim(toText or "") or ""
	local to = toText ~= "" and M.PSS_ParseEventTime(toText) or nil
	if not from or (toText ~= "" and not to) then return "|cffff6060Dates as 2026-10-05 13:20|r" end
	-- a "to" without a time takes the whole day
	if to and not toText:find(":", 1, true) then to = to + DAY - 1 end
	self.q.from, self.q.to = from, to
	return nil
end

-- the Types drop-down
function View:AllTypes() self.q.cats = nil end

function View:TypeOn(cat)
	return not self.q.cats or self.q.cats[cat] == true
end

function View:ToggleType(cat)
	local q = self.q
	if not q.cats then
		q.cats = {}
		for _, c in ipairs(History.ALL_CATS) do q.cats[c] = true end
	end
	q.cats[cat] = not q.cats[cat] or nil
	local every = true
	for _, c in ipairs(History.ALL_CATS) do if not q.cats[c] then every = false end end
	if every then q.cats = nil end
end

-- the Source drop-down
function View:SourceOn(key)
	return self.q.scope == nil and self.q.sources[key] == true
end

function View:ToggleSource(key)
	local q = self.q
	if q.scope then
		-- from one entry to this whole list
		q.scope = nil
		for k in pairs(q.sources) do q.sources[k] = k == key end
	else
		q.sources[key] = not q.sources[key] or nil
	end
end

function View:ScopeOff()
	self.q.scope = nil
	for _, src in ipairs(SOURCES) do self.q.sources[src.key] = true end
end

-- the query's state, for the tab to ask (it never reads self.q)
function View:IsCustom() return self.q.period == "custom" end
function View:Scoped() return self.q.scope ~= nil end
function View:PeriodIs(key) return (self.q.period or "all") == key end
function View:ScopeText() return "Only " .. (self.name or "?") end

-- labels
function View:Heading(n)
	return ("Events: %s  |cffaaaaaa(%s)|r"):format(Title(self.q, self.name),
		n == #self.all and tostring(n) or (n .. " of " .. #self.all))
end

function View:TimeLabel() return TimeLabel(self.q) end
function View:TypesLabel() return TypesLabel(self.q) end

function View:SourceLabel()
	return self.q.scope and self:ScopeText() or Title(self.q)
end

function View:EmptyText()
	return #self.all == 0 and "Nothing blocked here yet." or "No line matches the time, the types and the search."
end

-- back / forward: each query a step (the tab as it opens: nil)
function View:NavKey()
	local key = QueryKey(self.q)
	if key and not self.saved[key] then
		if self.nsaved >= MAX_SAVED then wipe(self.saved); self.nsaved = 0 end
		self.saved[key] = CopyQuery(self.q)
		self.nsaved = self.nsaved + 1
	end
	return key
end

function View:NavTitle(key)
	local q = self.saved[key]
	if not q then return "?" end
	local t = Title(q, q.scope and q.scope.label(q.scope.id))
	if q.period then t = t .. ", " .. TimeLabel(q) end
	if q.cats then t = t .. ", " .. TypesLabel(q) end
	return t
end

function View:NavApply(key)
	local q = key and self.saved[key]
	self.q = q and CopyQuery(q) or NewQuery()
end

function View:Reset()
	self.q = NewQuery()
end

-- Reset Block History of the entry shown: the confirm's text when the
-- entry asks first (a whole default list), else nil
function View:ResetText()
	local spec = self.q.scope
	if not (spec and spec.confirm) then return nil end
	return ("Clear the block history and counts of %s?"):format(lower(self.name or "everything"))
end

function View:DoReset()
	local spec = self.q.scope
	if spec then spec.reset(spec.id) end
end

------------------------------------------------------------------------
-- A line's cells, tooltip and copy text
------------------------------------------------------------------------
function M.PSS_EventCells(v, h, into)
	into.time = TimeText(h)
	into.source = v:SourceText(h)
	into.member = M.removeServer and M.removeServer(h.member or "", true) or (h.member or "")
	into.kind = "|c" .. (History.CAT_COLOR[h.cat or "unknown"] or "ffffffff") .. M.PSS_EventType(h) .. "|r"
	into.channel = h.channel or ""
	local msg = h.message or ""
	into.message = msg ~= "" and msg or "|cff888888(no message text)|r"
	return into
end

function M.PSS_EventTip(v, h)
	return TimeText(h) .. "  " .. (h.channel or "") .. "\n" .. (h.member or "")
		.. "\n|cffaaaaaa" .. v:SourceText(h) .. "|r\n\n" .. (h.message or "")
		.. "\n\n|cffaaaaaaClick a link to open it, shift-click to paste it. Double-click: copy the message.|r"
end

-- title line and text for the copy popup
function M.PSS_EventCopy(h)
	return (h.member or "") .. "  " .. TimeText(h), h.message or ""
end
