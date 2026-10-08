------------------------------------------------------------------------
-- POUR SOCIAL SCORE - CHAT FILTER QUERIES (3.1)
--
-- What a front end needs to show, test and convert the Chat Filters (the
-- PSS window, PourSocialScore_GUI). It is in PourSocialScore_Libraries,
-- which the window loads first, so none of it is in memory until the
-- window opens. No events, no timers, and
-- every table a query fills belongs to the caller (reused on every redraw).
--   M.PSS_FilterCount()                 total, built-in, custom, on
--   M.PSS_FilterRow(i, into)            one filter as shown
--   M.PSS_FilterRows(key, asc, find, into)  the list in display order
--   M.PSS_FilterBlockedText(i)          its Blocked cell ("n/a": guild rule)
--   M.PSS_AllFilterHistory()            every filter's lines, labelled
--   M.PSS_ResetAllFilterHistory()       Reset Block History of all filters
--   M.PSS_TestChatFilter(filter, text)  "blocked", "passed" or "error"
--   M.PSS_ConvertChatLink(link)         a chat link as a filter [tag]
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local V = addon.V

local lower, find = string.lower, string.find
local History = M.PSS_History

function M.PSS_FilterCount()
	local db = PourSocialScoreDB
	local n, builtin, on = #db.filterList, 0, 0
	for i = 1, n do
		if M.PSS_IsBuiltinFilter(i) then builtin = builtin + 1 end
		if db.filterActive[i] == true then on = on + 1 end
	end
	return n, builtin, n - builtin, on
end

function M.PSS_FilterBlockedText(i)
	if M.PSS_IsGuildRuleFilter(i) then return "n/a" end
	return tostring(tonumber(PourSocialScoreDB.filterCount[i]) or 0)
end

-- into: index, desc, filter, active, builtin, guildRule, blocked (nil for a
-- guild rule: its blocks are counted on the Guild Ignore List), lines (its
-- counted blocks, so a front end can tell there is history without loading
-- it); nil past the end.
function M.PSS_FilterRow(i, into)
	local db = PourSocialScoreDB
	if not db.filterList[i] then return nil end
	into = into or {}
	into.index = i
	into.desc = db.filterDesc[i] or ""
	into.filter = db.filterList[i] or ""
	into.active = db.filterActive[i] == true
	into.builtin = M.PSS_IsBuiltinFilter(i)
	into.guildRule = M.PSS_IsGuildRuleFilter(i)
	into.blocked = not into.guildRule and (tonumber(db.filterCount[i]) or 0) or nil
	local t = db.filterBlocked[i]
	local c = type(t) == "table" and t.counts
	into.lines = type(c) == "table" and (tonumber(c.total) or 0) or (type(t) == "table" and #t or 0)
	return into
end

-- Filter numbers in display order: built-ins first, then by key ("desc",
-- "state", "blocked", "filter"; ties by description A-Z). find keeps only
-- the filters whose description or filter text holds it. into[1..n].
function M.PSS_FilterRows(key, asc, findText, into)
	local db = PourSocialScoreDB
	into = into or {}
	into.v, into.b, into.d = into.v or {}, into.b or {}, into.d or {}
	local v, b, d = into.v, into.b, into.d
	local q = findText and lower(findText) or ""
	local n = 0
	for i = 1, #db.filterList do
		local desc = lower(db.filterDesc[i] or "")
		local text = db.filterList[i] or ""
		if q == "" or find(desc, q, 1, true) or find(lower(text), q, 1, true) then
			n = n + 1
			into[n] = i
			local val
			if key == "state" then val = db.filterActive[i] == true and 1 or 0
			elseif key == "blocked" then val = M.PSS_IsGuildRuleFilter(i) and -1 or (tonumber(db.filterCount[i]) or 0)
			elseif key == "filter" then val = lower(text)
			else val = desc end
			v[i], b[i], d[i] = val, M.PSS_IsBuiltinFilter(i) and 0 or 1, desc
		end
	end
	for i = #into, n + 1, -1 do into[i] = nil end
	table.sort(into, function(x, y)
		if b[x] ~= b[y] then return b[x] < b[y] end				-- built-ins first, always
		if v[x] ~= v[y] then if asc then return v[x] < v[y] end return v[x] > v[y] end
		if d[x] ~= d[y] then return d[x] < d[y] end
		return x < y
	end)
	return into, n
end

-- Every filter's lines, newest first, each labelled with its filter (guild
-- rules have none: their blocks are on the Guild Ignore List).
function M.PSS_AllFilterHistory()
	local db = PourSocialScoreDB
	local byKey = {}
	for n = 1, #db.filterList do
		byKey[M.PSS_FilterOwnerKey(n)] = "Filter: " .. tostring(db.filterDesc[n] or n)
	end
	return History.Collect(function(h)
		local l = byKey[h.o]
		if l then History.SetSource(h, l) return true end
		return false
	end)
end

function M.PSS_ResetAllFilterHistory()
	for n = 1, #PourSocialScoreDB.filterList do M.PSS_ResetFilterHistory(n) end
end

-- The editor's Test: chatText against filterText (not saved).
function M.PSS_TestChatFilter(filterText, chatText)
	local res = M.filterComplex(filterText, lower(chatText or ""), 1)
	if V.lastFilterError == true then return "error" end
	return res == true and "blocked" or "passed"
end

-- A chat link as the [tag] the filter language uses; "UNKNOWN" otherwise.
local LINK_TAGS = {
	{ "|Hitem:(%d+)", "item" },
	{ "|Hspell:(%d+)", "spell" },
	{ "|Htalent:(%d+)", "talent" },
	{ "|Hachievement:(%d+)", "achievement" },
	{ "|Hbattlepet:(%d+)", "pet" },
}
local LINK_PLAIN = {
	{ "|Hjournal:%d+", "[journal]" },
	{ "|Htrade:", "[trade]" },
	{ "|Hclubfinder:", "[guild]" },
	{ "|Hclubticket:", "[community]" },
}
function M.PSS_ConvertChatLink(text)
	if text == nil or text == "" then return "UNKNOWN" end
	for _, t in ipairs(LINK_TAGS) do
		local id = string.match(text, t[1])
		if id then return "[" .. t[2] .. "=" .. id .. "]" end
	end
	for _, t in ipairs(LINK_PLAIN) do
		if string.match(text, t[1]) then return t[2] end
	end
	return "UNKNOWN"
end
