------------------------------------------------------------------------
-- POUR SOCIAL SCORE - CHAT FILTERS VIEW (for PourSocialScore_GUI)
--
-- What the window's Chat Filters tab shows and does, worked out here so the
-- tab only draws: the list's sort and search, each row's text, the editor
-- pane's lines, its edits (save, copy, remove, new, reset defaults, test)
-- and the Events specs. Read through PSS_FilterQuery.lua and changed
-- through the filter setters; a guild rule's blocks are counted on the
-- Guild Ignore List, so it has no count or history here.
--   local v = M.PSS_FilterListNew()    the list's state
--   v:Resort()                          n shown, the count line, the empty text
--   v:SortBy(key), v:SetFind(text)
--   M.PSS_FilterRowCells(r, into)       desc / filter / state / blocked text
--   M.PSS_FilterRowTip(r), M.PSS_FilterHeading(r), M.PSS_FilterInfo(r)
--   M.PSS_FilterHistoryLine(r)          "History n lines: ..."
--   M.PSS_FilterSave(i, desc, text)     true when saved
--   M.PSS_FilterCopy(i)                 the copy's number, or nil
--   M.PSS_FilterRemoveText(i), M.PSS_FilterRemove(i, desc, sel) -> removed, sel after
--   M.PSS_FilterNew()                   a new custom filter's number
--   M.PSS_FilterTestText(filter, line)  BLOCKED / PASSED / FILTER ERROR
--   M.PSS_AllFiltersSpec(), M.PSS_FilterEventsSpec(i)
--   M.PSS_FilterSummarySpec(r, into)    fills the pane's Summary spec from row r
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local L = addon.L

local setmetatable = setmetatable

------------------------------------------------------------------------
-- The list: sort and search (index: filter numbers in the order shown)
------------------------------------------------------------------------
local List = M.PSS_ListMixin({})
List.__index = List

function M.PSS_FilterListNew()
	return setmetatable({ key = "desc", asc = true, find = "", index = {}, count = 0, dirty = true }, List)
end

function List:Resort()
	local _, n = M.PSS_FilterRows(self.key, self.asc, self.find, self.index)
	self.count, self.dirty = n, false
	local total, builtin, custom, on = M.PSS_FilterCount()
	local countText = (self.find ~= "" and ("%d of %d   "):format(n, total) or "")
		.. ("|cffaaaaaaBuilt-in|r %d   |cffaaaaaaCustom|r %d   |cffaaaaaaOn|r |cff33ff99%d|r"):format(builtin, custom, on)
	return n, countText, total == 0 and "No chat filters." or "Nothing matches the search."
end

------------------------------------------------------------------------
-- Text (r: a row from M.PSS_FilterRow)
------------------------------------------------------------------------
function M.PSS_FilterRowCells(r, into)
	if r.builtin then
		into.desc = "|cff8a8a8a" .. r.desc .. " |cff5f5f5f" .. (r.guildRule and "(guild rule)" or "(built-in)") .. "|r"
		into.filter = "|cff7a7a7a" .. r.filter .. "|r"
	else
		into.desc, into.filter = r.desc, r.filter
	end
	into.state = r.active and ("|cff33ff99" .. L["ON"] .. "|r") or ("|cffe60000" .. L["OFF"] .. "|r")
	into.blocked = M.PSS_FilterBlockedText(r.index)
	return into
end

function M.PSS_FilterRowTip(r)
	return r.desc .. "\n\n" .. r.filter .. "\n\n|cffaaaaaaClick to edit. Built-ins are read only.|r"
end

function M.PSS_FilterHeading(r)
	return r.desc .. (r.guildRule and "  |cff808080(guild rule)|r" or (r.builtin and "  |cff808080(built-in)|r" or ""))
end

function M.PSS_FilterInfo(r)
	if r.guildRule then
		return "|cffaaaaaaTurns its guilds on the Guild Ignore List on or off; their blocks are counted there.|r"
	end
	return ("Blocked |cffffff00%d|r messages"):format(r.blocked or 0)
end

function M.PSS_FilterHistoryLine(r)
	local c = M.PSS_FilterCounts(r.index)
	return ("History %d lines:  Whispers %d  Party %d  Chat %d"):format(r.lines,
		c and c.whisper or 0, c and c.partyRaid or 0, (c and c.world or 0) + (c and c.guildChat or 0))
end

------------------------------------------------------------------------
-- Edits (through the core's filter setters)
------------------------------------------------------------------------
local prow = {}

-- a custom filter's description and text; true when saved
function M.PSS_FilterSave(i, desc, text)
	local r = i and M.PSS_FilterRow(i, prow)
	if not r or r.builtin then return false end
	desc = M.trim(desc or "") or ""
	text = text or ""
	if desc == "" or text == "" then
		M.PSS_Say("A chat filter needs a description and a filter.")
		return false
	end
	M.PSS_SaveChatFilter(i, desc, text)
	M.PSS_Say(("Chat filter \"%s\" saved."):format(desc))
	return true
end

-- an editable custom copy (starts Off): its number, or nil (a guild rule)
function M.PSS_FilterCopy(i)
	if not i or M.PSS_IsGuildRuleFilter(i) then return nil end
	local src = M.PSS_FilterRow(i, prow) and prow.desc
	local n = M.PSS_CopyChatFilter(i)
	if not n then return nil end
	M.PSS_Say(("Copied \"%s\" to a new custom filter (starts Off). Edit it, tick On and save."):format(tostring(src)))
	return n
end

-- the confirm's text, or nil (nothing to remove: a built-in)
function M.PSS_FilterRemoveText(i)
	local r = i and M.PSS_FilterRow(i, prow)
	if not r or r.builtin then return nil end
	return ("Remove the chat filter \"%s\"?\n\nIts count and block history are deleted."):format(r.desc), r.desc
end

-- remove filter i if it is still the one asked about (desc); true if removed
-- sel: the row selected now (another may have been clicked while the
-- confirm was open); returned as it is after the rows below i move up
function M.PSS_FilterRemove(i, desc, sel)
	if M.PSS_FilterRow(i, prow) and prow.desc == desc then
		M.RemoveChatFilter(i)
		if sel == i then return true, nil end
		if sel and sel > i then return true, sel - 1 end
		return true, sel
	end
	return false, sel
end

function M.PSS_FilterNew()
	return M.PSS_AddCustomFilter("New Chat Filter", "[word=newchatfilter]", false)
end

function M.PSS_FilterTestText(filter, line)
	local res = M.PSS_TestChatFilter(filter or "", line or "")
	if res == "error" then return "|cffffff00FILTER ERROR|r" end
	return res == "blocked" and "|cffff5c5cBLOCKED|r" or "|cff00ff96PASSED|r"
end

------------------------------------------------------------------------
-- Events specs (the Events tab reads them; nothing here loads Logging)
------------------------------------------------------------------------
local allFilters

function M.PSS_AllFiltersSpec()
	if allFilters then return allFilters end
	allFilters = {
		kind = "filter", id = false, allText = "All Filters", source = "filters",
		label = function() return "All Filters" end,
		read = M.PSS_AllFilterHistory,
		reset = M.PSS_ResetAllFilterHistory,
	}
	return allFilters
end

-- the Summary spec (history owner, all-time count, title, id) of a row
function M.PSS_FilterSummarySpec(r, into)
	into.owner, into.allTime, into.title, into.id = M.PSS_FilterOwnerKey(r.index), r.blocked or 0, r.desc, r.index
	return into
end

local lrow = {}

function M.PSS_FilterEventsSpec(i)
	return {
		kind = "filter", id = i, allText = "All Filters", all = M.PSS_AllFiltersSpec,
		label = function(n)
			local r = M.PSS_FilterRow(n, lrow)
			return r and not r.guildRule and r.desc or nil
		end,
		read = M.PSS_FilterHistory,
		reset = M.PSS_ResetFilterHistory,
		owner = M.PSS_FilterOwnerKey, counts = M.PSS_FilterCounts,
	}
end
