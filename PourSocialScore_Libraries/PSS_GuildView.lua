------------------------------------------------------------------------
-- POUR SOCIAL SCORE - GUILD IGNORE LIST VIEW (for PourSocialScore_GUI)
--
-- What the window's Guild Ignore List tab shows and does, worked out here
-- so the tab only draws: the grouped list's sort, search and selection,
-- each row's text and tooltip, Scan All's status, the Add / Exclude entry
-- rows, Guild Search and its results picker, and the Events specs. Read
-- through PSS_GuildQuery.lua and changed through the guild setters.
--   local v = M.PSS_GuildListNew()     the list's state
--   v:Resort()                          n shown (v.rows filled by M.PSS_GuildRows)
--   v:SortBy(key), v:SetFind(text), v:CountText()
--   v:IsSel(item), v:Select(kind, value), v:ItemSel(item), v:Click(item, now)
--   M.PSS_GuildRowCells(item, find, nested, into)   guild / members / total / scan text, dim
--   M.PSS_GuildRowTip(item)
--   M.PSS_GuildScanTip(g)               a guild's sweep (g) or Scan All (nil)
--   Members view (in place of the list): v:OpenMembers(key), v:CloseMembers(),
--   v:MResort() (n, total), v:MSortBy(key), v:SetMFind(text), v:MembersHeading(),
--   v:MembersEmptyText(), M.PSS_MemberTip(m)
--   The pane: M.PSS_GuildInfoLine(g), M.PSS_GuildGroupView(k, rows, into),
--   M.PSS_GuildExclView(name), M.PSS_MemberHeading(m), M.PSS_MemberGuildLine(m),
--   M.PSS_MemberAddedLine(m), M.PSS_MemberAllowed(gg, m, cat) (ticked, own),
--   M.PSS_MemberOtherGuild(gg, gkey, m)
--   Edits: M.PSS_GuildToggleAllowed, M.PSS_GuildScanNow, M.PSS_GuildCustomScan,
--   M.PSS_GuildCommitFields, M.PSS_ToggleException(target, scope, key),
--   M.PSS_GuildRemoveText / M.PSS_GuildRemove, M.PSS_MemberRemoveText /
--   v:RemoveMember(), M.PSS_MemberCommitNote, M.PSS_MemberToggleAllowed,
--   M.PSS_GroupToggleRule(k), M.PSS_GroupToggleOpen(k) (k: a default list,
--   M.PSS_GUILD_MANAGED or M.PSS_GUILD_EXCL_OPEN), M.PSS_ExclRemove(name)
--   M.PSS_GuildAddFromText(text), M.PSS_GuildExcludeFromText(text)
--   M.PSS_GuildSearchFromText(text, mode)
--   M.PSS_GuildPickerItems(found, mode, into), M.PSS_GuildPickerTitle(n, query, mode)
--   M.PSS_GuildPickerSave(items, mode), M.PSS_GuildPickerClose(mode)
--   M.PSS_GuildNoneFound(query, mode)   the text for no results, and the
--                                       name to exclude anyway (or nil);
--                                       M.PSS_GuildExcludeAnyway(name)
--   M.PSS_GUILD_SEARCH_OWNER            the window's Guild Search tag
--   M.PSS_AllGuildsSpec(), M.PSS_GuildEventsSpec(key), M.PSS_GroupEventsSpec(k),
--   M.PSS_MemberEventsSpec(m, gkey)
--   M.PSS_GuildGroupLabel(k)
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local History = M.PSS_History

local type, tostring, pairs, ipairs, next, setmetatable, concat, wipe = type, tostring, pairs, ipairs, next, setmetatable, table.concat, wipe

-- the Managed Communities row is selected as "managed"
local MANAGED = "__managed"
local MANAGED_PREFIX = "Managed Communities - "
local DOUBLE_CLICK = 0.35

M.PSS_GUILD_MANAGED = MANAGED
-- Guild Search results go to the window that asked (the old window takes
-- only searches without an owner)
M.PSS_GUILD_SEARCH_OWNER = "window"

------------------------------------------------------------------------
-- The list: sort, search, selection
------------------------------------------------------------------------
local List = M.PSS_ListMixin({})
List.__index = List

-- selKind: "guild" (sel = key), "group" (key), "managed", "exclHeader",
-- "excl" (name), or nil
function M.PSS_GuildListNew()
	return setmetatable({ key = "guild", asc = true, find = "", rows = { nest = true }, n = 0, dirty = true, gen = 0,
		view = "guilds", mkey = "name", masc = true, mfind = "", members = {}, mn = 0, mtotal = 0, mdirty = true }, List)
end

function List:Resort()
	local _, n = M.PSS_GuildRows(self.key, self.asc, self.find, self.rows)
	self.n, self.dirty = n, false
	local gen = self.gen
	for i = 1, n do self.rows[i].counted = gen end
	return n
end

-- Blocked lines changed counts. Re-sorting the whole list on each one cost
-- about 180 KB of garbage and 5 ms on a large save (3.4.0.15); instead a guild
-- row counts again when it is drawn (FreshCounts: only the rows on screen),
-- and the next Resort (a click, a sort, the tab shown again) brings the
-- order and the group totals up to date.
function List:CountsChanged()
	self.gen = (self.gen or 0) + 1
	self.dirty = true
end

function List:FreshCounts(item)
	if item.g and item.key and item.counted ~= self.gen then
		item.bc = M.PSS_GetGuildBlockCounts(item.key)
		item.counted = self.gen
	end
end

function List:CountText()
	if self.view == "members" then
		if self.mfind ~= "" then return ("%d of %d members"):format(self.mn, self.mtotal) end
		return ("%d member%s"):format(self.mtotal, self.mtotal == 1 and "" or "s")
	end
	local all = M.PSS_GuildCount()
	if self.find ~= "" then return ("%d of %d"):format(self.n, all) end
	return ("%d guild rule%s"):format(all, all == 1 and "" or "s")
end

function List:IsSel(item)
	if item.managedHeader then return self.selKind == "managed" end
	if item.header then return self.selKind == "group" and self.sel == item.groupKey end
	if item.exclHeader then return self.selKind == "exclHeader" end
	if item.exclItem then return self.selKind == "excl" and self.sel == item.name end
	return self.selKind == "guild" and self.sel == item.key
end

function List:Select(kind, value)
	self.selKind, self.sel = kind, value
end

-- what selecting a row would select (kind, value), without opening it (a
-- right-click selects the row before its menu opens)
function List:ItemSel(item)
	if item.managedHeader then return "managed", MANAGED end
	if item.header then return "group", item.groupKey end
	if item.exclHeader then return "exclHeader", true end
	if item.exclItem then return "excl", item.name end
	return "guild", item.key
end

-- A click on a row. A heading opens or closes (and is selected); a guild is
-- selected, or deselected when it was; a second click on the same guild
-- within 0.35 s returns "members" (its members view). Returns what to do
-- next: "resort" (the list changed shape), "select", "members" or nil.
function List:Click(item, now)
	if not item then return nil end
	if item.managedHeader then
		M.PSS_SetGuildGroupOpen(M.PSS_GUILD_MANAGED_SHUT, item.open)
		self:Select("managed", MANAGED)
		return "resort"
	elseif item.header then
		M.PSS_SetGuildGroupOpen(item.groupKey, not item.open)
		self:Select("group", item.groupKey)
		return "resort"
	elseif item.exclHeader then
		M.PSS_SetGuildGroupOpen(M.PSS_GUILD_EXCL_OPEN, not item.open)
		self:Select("exclHeader", true)
		return "resort"
	elseif item.exclItem then
		self:Select("excl", item.name)
		return "select"
	end
	now = now or GetTime()
	if self.lastKey == item.key and now - (self.lastAt or 0) < DOUBLE_CLICK then
		self.lastKey = nil
		self:Select("guild", item.key)
		return "members"
	end
	self.lastKey, self.lastAt = item.key, now
	if self.selKind == "guild" and self.sel == item.key then self:Select(nil, nil) else self:Select("guild", item.key) end
	return "select"
end

------------------------------------------------------------------------
-- Row text
------------------------------------------------------------------------
-- how many default guild lists have their rule on
local function ManagedOn()
	local n = 0
	for k in pairs(M.PSS_ManagedGroups()) do
		if M.PSS_ManagedGroupActive(k) then n = n + 1 end
	end
	return n
end

-- into: guild, members, total, scan (texts) and dim (true: a group whose
-- rule is off; nothing in it is blocked). find: the search shown.
function M.PSS_GuildRowCells(item, find, nested, into)
	into.dim = false
	if item.managedHeader then
		into.guild = (item.open and "[-] " or "[+] ") .. "|cffffd100Managed Communities|r"
			.. ("  |cffaaaaaa(%d)|r"):format(item.groups)
		into.members, into.total = item.members, item.bc.total or 0
		into.scan = ("|cffaaaaaa%d of %d on|r"):format(ManagedOn(), item.groups)
	elseif item.header then
		-- under the Managed Communities row: indented, without its prefix
		local name = item.name
		if item.nested and name:sub(1, #MANAGED_PREFIX) == MANAGED_PREFIX then name = name:sub(#MANAGED_PREFIX + 1) end
		into.guild = (item.nested and "   " or "") .. (item.open and "[-] " or "[+] ") .. "|cffffd100" .. name .. "|r"
			.. ("  |cffaaaaaa(%d guilds)|r"):format(item.guilds)
		into.members, into.total = item.members, item.bc.total or 0
		into.scan = M.PSS_ManagedGroupActive(item.groupKey) and "|cff00ff00Rule ON|r" or "|cffff5555Rule OFF|r"
	elseif item.exclHeader then
		into.guild = (item.open and "[-] " or "[+] ") .. "|cff4dccffGuild Exclusion List|r"
			.. ("  |cffaaaaaa(%d guilds)|r"):format(item.count)
		into.members, into.total, into.scan = "", "", "|cff4dccffNever|r"
	elseif item.exclItem then
		into.guild = "      " .. item.name
		into.members, into.total, into.scan = "", "", "|cff4dccffExcluded|r"
	else
		local g = item.g
		local indent = ""
		if item.inGroup and (find or "") == "" then indent = nested and "         " or "      " end
		into.guild = indent .. tostring(g.name)
		into.members, into.total = g.memberCount or 0, item.bc.total or 0
		into.scan = M.PSS_GuildSweepLabel(item.key)
		into.dim = item.inGroup and not item.groupOn or false
	end
	return into
end

function M.PSS_GuildRowTip(item)
	if item.managedHeader then
		return "Managed Communities\n\nThe default guild lists, each with its own rule on the Chat Filters tab."
			.. "\n\nClick to expand or collapse and see them added up."
	elseif item.header then
		local grp = M.PSS_ManagedGroups()[item.groupKey] or {}
		return (item.name or "") .. "\n\nDefault guild list. Rule on the Chat Filters tab: "
			.. tostring(grp.rule) .. " (" .. tostring(grp.filter) .. ").\n\nClick to expand or collapse."
	elseif item.exclHeader then
		return "Guild Exclusion List\n\nGuilds that no guild rule ever blocks, captures or scans in.\n\nClick to expand or collapse."
	elseif item.exclItem then
		return item.name .. "\n\nExcluded: never blocked by a guild rule."
	end
	return tostring(item.g.name) .. "\n\nClick for the details, double-click for the members."
end

-- The status of a guild's sweep (g) or of Scan All (nil), for the tooltip.
function M.PSS_GuildScanTip(g)
	local t = {}
	local function add(s) t[#t + 1] = s end
	if g then
		add("Scan <" .. tostring(g.name) .. ">")
		add("|cffccccccOne /who per click: the whole guild first. An answer of 50 (the /who cap) is split into narrower searches until each is under the cap.|r")
		local sw = M.PSS_GuildSweep(M.PSS_NormalizeGuild(g.name))
		if not sw then
			add("Not swept yet. Next: " .. M.PSS_HarvestFilter(g.name, {}))
		else
			add(("Searches %d sent, %d queued. Players found %d (%d new)."):format(sw.sent, #sw.queue, sw.seen, sw.added))
			if sw.done then
				add("|cff00ff00Sweep complete: click to start it again.|r")
			elseif sw.queue[1] then
				add("Next: " .. M.PSS_HarvestFilter(g.name, sw.queue[1]))
			end
		end
	else
		add("Scan All")
		add("|cffccccccOne /who per click across every guild, A-Z: each guild is swept to the end before the next.|r")
		local nextG, done, n = M.PSS_ScanAllNext(true)
		add(("Guilds swept %d / %d."):format(done, n))
		if nextG then add("Now: " .. tostring(nextG.name)) end
	end
	if M.PSS_WhoPending() then
		add("|cffffff00Waiting for the /who answer.|r")
	elseif M.PSS_ScanCooldownActive() then
		add("|cffff8000/who is cooling down.|r")
	else
		add("|cff00ff00Ready: click for the next search.|r")
	end
	if g then add("|cff999999Shift-click: start this guild's sweep over.|r") end
	add("|cff999999Key binding for Scan All: Key Bindings > AddOns > Pour Social Score.|r")
	return concat(t, "\n")
end

------------------------------------------------------------------------
-- The entry rows: Add, Exclude, Guild Search
------------------------------------------------------------------------
local function BoxText(text)
	text = M.trim(text or "") or ""
	if text == "" then return nil end
	return text
end

-- Add Guild: the key to select, or nil (nothing typed)
function M.PSS_GuildAddFromText(text)
	text = BoxText(text)
	if not text then
		M.PSS_Say("Type a guild name in the box first.")
		return nil
	end
	if M.PSS_IsGuildListed(text) then
		M.PSS_Say(("<%s> is already on the Guild Ignore List."):format(text))
	else
		M.PSS_AddGuild(text)
		M.PSS_Say(("<%s> added to the Guild Ignore List."):format(text))
	end
	return M.PSS_NormalizeGuild(text)
end

-- Exclude: true when something was typed (the box is then cleared)
function M.PSS_GuildExcludeFromText(text)
	text = BoxText(text)
	if not text then
		M.PSS_Say("Type a guild name in the box first.")
		return false
	end
	if M.PSS_AddGuildExclusion(text) == false then
		M.PSS_Say(("<%s> is already on the Guild Exclusion List."):format(text))
	else
		M.PSS_Say(("<%s> added to the Guild Exclusion List."):format(text))
	end
	return true
end

-- Guild Search (mode "exclude": for the Guild Exclusion List). Runs a /who
-- straight from the click; true when it went out (the box is then cleared).
function M.PSS_GuildSearchFromText(text, mode)
	if M.PSS_ScanBlockedMsg() then return false end
	text = BoxText(text)
	if not text then
		M.PSS_Say("Type part of a guild name in the box first.")
		return false
	end
	if mode == "exclude" then text = text:gsub('"', "") end
	return M.PSS_GuildSearch(text, mode, M.PSS_GUILD_SEARCH_OWNER) and true or false
end

-- The results picker's entries: { name, listed (already on the list), ticked }
function M.PSS_GuildPickerItems(found, mode, into)
	into = into or {}
	for i = #into, 1, -1 do into[i] = nil end
	for _, name in ipairs(found or {}) do
		local listed
		if mode == "exclude" then listed = M.PSS_IsGuildExcluded(name) else listed = M.PSS_IsGuildListed(name) end
		into[#into + 1] = { name = name, listed = listed and true or false }
	end
	return into
end

function M.PSS_GuildPickerTitle(n, query, mode)
	local exclude = mode == "exclude"
	return (exclude and "Guild Exclusion Search: " or "Guild Search: ")
		.. ("%d guild(s) found for \"%s\". Click the guilds to "):format(n, query or "")
		.. (exclude and "exclude." or "add.")
end

-- the picker's ticks: the shared ones (PSS_ViewNav.lua)
M.PSS_GuildPickerToggle, M.PSS_GuildPickerTickAll = M.PSS_PickerToggle, M.PSS_PickerTickAll

-- Save the ticked entries; the count saved
function M.PSS_GuildPickerSave(items, mode)
	local names = {}
	for _, it in ipairs(items) do
		if it.ticked and not it.listed then names[#names + 1] = it.name end
	end
	if #names > 0 then
		if mode == "exclude" then M.PSS_SaveGuildExclusions(names) else M.PSS_SaveGuildSearch(names) end
	end
	return #names
end

-- the picker closed: a guild search's cache of who was seen is dropped
function M.PSS_GuildPickerClose(mode)
	if mode ~= "exclude" then M.PSS_ForgetGuildSearch() end
end

-- No results: the message, and for the exclusion search the name to offer
-- to add anyway (nil: nothing to offer).
function M.PSS_GuildNoneFound(query, mode)
	if mode == "exclude" then
		local name = M.trim(((query or ""):gsub('"', ""))) or ""
		if name == "" then return nil end
		return ("No guild named <%s> was found online.\n\nAdd it to the Guild Exclusion List anyway?"):format(name), name
	end
	M.PSS_Say(("Guild Search found no guilds for \"%s\"."):format(query or ""))
	return nil
end

function M.PSS_GuildExcludeAnyway(name)
	M.PSS_AddGuildExclusion(name)
	M.PSS_Say(("<%s> added to the Guild Exclusion List."):format(name))
end

------------------------------------------------------------------------
-- The members of one guild rule, in place of the guild list
-- (mguild: the rule's key; msel: the selected member record)
------------------------------------------------------------------------
function List:OpenMembers(key)
	if not key then return false end
	self.view, self.mguild, self.msel, self.mfind, self.mdirty = "members", key, nil, "", true
	return true
end

function List:SelectMember(m) self.msel = m end
function List:SetView(view) self.view = view end

-- a guild rule removed: forget it where it was selected or open
function List:GuildRemoved(key)
	if self.selKind == "guild" and self.sel == key then self:Select(nil, nil) end
	if self.mguild == key then self.mguild, self.msel = nil, nil end
end

-- the member list is dropped (thousands of rows for a shipped guild); the
-- next OpenMembers builds it again
function List:CloseMembers()
	self.view, self.msel, self.find = "guilds", nil, ""
	self.dirty = true
	wipe(self.members)
	self.mn, self.mtotal, self.mdirty = 0, 0, true
end

-- n shown, total; the rule gone: n 0 and mguild nil
function List:MResort()
	local _, n, total = M.PSS_GuildMembers(self.mguild, self.mkey, self.masc, self.mfind, self.members)
	if not n then
		self.mguild, self.msel = nil, nil
		n, total = 0, 0
	end
	self.mn, self.mtotal, self.mdirty = n, total, false
	if self.msel then
		local found = false
		for i = 1, n do if self.members[i] == self.msel then found = true break end end
		if not found and not (self.members.stored and self.members.stored[self.msel]) then self.msel = nil end
	end
	return n, total
end

function List:MSortBy(key)
	if self.mkey == key then
		self.masc = not self.masc
	else
		self.mkey, self.masc = key, true
	end
end

function List:SetMFind(text)
	text = text or ""
	if text == self.mfind then return false end
	self.mfind = text
	return true
end

function List:MembersHeading()
	local _, g = M.PSS_FindGuildRule(self.mguild)
	return "Members of |cffffd100" .. tostring(g and g.name or "?") .. "|r"
end

function List:MembersEmptyText()
	return self.mfind ~= "" and "Nothing matches the search." or "No members yet. Scan the guild to find them."
end

-- the members view's title by the arrows
function M.PSS_MembersNavTitle(key)
	local _, g = M.PSS_FindGuildRule(key)
	return ("Members of <%s>"):format(g and g.name or tostring(key))
end

function M.PSS_MemberTip(m)
	return tostring(m.name) .. ((m.guild or "") ~= "" and ("  <" .. m.guild .. ">") or "")
		.. ((m.note or "") ~= "" and ("\n\n" .. m.note) or "") .. "\n\nClick for the details."
end

-- Remove the selected member (asked first by the window); true if removed
function List:RemoveMember()
	local m, gkey = self.msel, self.mguild
	if not (m and gkey) then return false end
	M.PSS_RemoveGuildMember(gkey, m.name, gkey, self.members.stored and self.members.stored[m] or nil)
	self.msel = nil
	self.mdirty, self.dirty = true, true
	return true
end

------------------------------------------------------------------------
-- The pane's text
------------------------------------------------------------------------
function M.PSS_GuildInfoLine(g)
	local n = g.memberCount or 0
	local info = ("%d member%s"):format(n, n == 1 and "" or "s")
	if g.managed then
		local grp = M.PSS_ManagedGroups()[g.managed] or {}
		info = info .. "  |cffaaaaaa" .. tostring(grp.name or g.managed) .. " list, rule "
			.. (M.PSS_ManagedGroupActive(g.managed) and "|cff00ff00on|r" or "|cffff5555off|r")
	end
	return info
end

-- every guild of every default guild list (MANAGED), reused
local managedItems = {}
local function ManagedItems(rows)
	for i = #managedItems, 1, -1 do managedItems[i] = nil end
	for _, items in pairs(rows.groups or {}) do
		for _, it in ipairs(items) do managedItems[#managedItems + 1] = it end
	end
	return managedItems
end

-- A default guild list, or (k = MANAGED) the Managed Communities row: all
-- of them added up. into: name, info, rule, state, toggle (button text or
-- nil: no toggle), open (button text), item (its row), items (its guilds).
-- nil when it is gone.
function M.PSS_GuildGroupView(k, rows, into)
	if k == MANAGED then
		local item = rows.managedHead
		if not (item and rows.groups and next(rows.groups)) then return nil end
		into.name, into.item, into.items = "Managed Communities", item, ManagedItems(rows)
		into.info = ("%d lists, %d guilds, %d members"):format(item.groups, item.guilds, item.members)
		into.rule = "Each list has its own rule on the Chat Filters tab."
		into.state = ("%d of %d rules on."):format(ManagedOn(), item.groups)
		into.toggle = nil
		into.open = item.open and "Collapse" or "Expand"
		return into
	end
	local grp = M.PSS_ManagedGroups()[k]
	if not grp then return nil end
	local item = rows.heads and rows.heads[k]
	into.name, into.item, into.items = tostring(grp.name or k), item, rows.groups and rows.groups[k]
	into.info = item and ("%d guilds, %d members"):format(item.guilds, item.members) or ""
	into.rule = ("Rule on the Chat Filters tab: %s (%s)"):format(tostring(grp.rule), tostring(grp.filter))
	local on = M.PSS_ManagedGroupActive(k)
	into.state = on and "|cff00ff00Rule is ON|r: its guilds are blocked, minus each guild's exclusions."
		or "|cffff5555Rule is OFF|r: nothing in this list is blocked."
	into.toggle = on and "Turn Rule Off" or "Turn Rule On"
	into.open = M.PSS_GuildGroupOpen(k) and "Collapse" or "Expand"
	return into
end

-- heading, text; nil when name is not excluded (name nil: the heading row)
function M.PSS_GuildExclView(name)
	if name then
		if not M.PSS_IsGuildExcluded(name) then return nil end
		return name, "|cff4dccffExcluded|r: never blocked by a guild rule, even one whose name it contains."
	end
	local n = #M.PSS_GuildExclusions()
	return "Guild Exclusion List", ("%d guild%s.\n\nGuilds that no guild rule ever blocks, captures or scans in, even a rule whose name they contain or a default list.\n\nAdd guilds with the \"Exclude a Guild\" box above."):format(n, n == 1 and "" or "s")
end

function M.PSS_MemberHeading(m)
	local cr, cg, cb = M.PSS_ClassColor(m.class)
	return ("|cff%02x%02x%02x"):format(cr * 255, cg * 255, cb * 255) .. tostring(m.name) .. "|r"
end

function M.PSS_MemberGuildLine(m)
	local actual = m.guild or ""
	return "Guild " .. (actual ~= "" and ("<" .. actual .. ">") or "|cff808080unknown|r")
end

function M.PSS_MemberAddedLine(m)
	return "Added " .. ((m.whenBlocked or "") ~= "" and m.whenBlocked or "|cff808080unknown|r")
end

-- ticked (allowed), and own (the member's own setting; false: follows the guild)
function M.PSS_MemberAllowed(gg, m, cat)
	return not M.PSS_MemberBlocks(gg, m, cat), M.PSS_MemberBlock(m)[cat] ~= nil
end

-- true when the member's actual guild is another than this rule (Add Guild)
function M.PSS_MemberOtherGuild(gg, gkey, m)
	local base = M.PSS_NormalizeGuild(gg.name or gkey)
	local ag = M.PSS_NormalizeGuild(m.guild or "")
	return ag ~= nil and ag ~= "" and ag ~= base
end

------------------------------------------------------------------------
-- The pane's edits (through the core's setters)
------------------------------------------------------------------------
-- W I G P C for the whole guild: ticked = allowed
-- the block history owners of a guild rule and of a member (the Summary's
-- session and day counts)
function M.PSS_GuildHistoryKey(key) return History.GuildKey(key) end
function M.PSS_MemberHistoryKey(m) return History.MemberKey(m) end

-- a member's blocks in all, as M.PSS_GetMemberBlockCounts(m).total, without a
-- table per call (the members list draws it on every row)
function M.PSS_MemberBlockTotal(m)
	if type(m) ~= "table" then return 0 end
	M.PSS_EnsureMemberBlockData(m)
	local bc, total = m.blockCounts, 0
	if not bc then return 0 end
	for _, c in ipairs(History.ALL_CATS) do total = total + (bc[c] or 0) end
	return total
end

-- a guild's W I G P C tick: allowed unless the rule blocks it
function M.PSS_GuildAllowed(g, cat)
	return M.PSS_GuildBlock(g)[cat] ~= true
end

function M.PSS_GuildToggleAllowed(key, cat, allowed)
	if key then M.PSS_SetGuildBlock(key, cat, not allowed) end
end

-- Scan (the guild's sweep; shift: start it over) and Custom Scan (with the
-- Scan Fields): one /who straight from the click
function M.PSS_GuildScanNow(key, restart)
	local _, g = M.PSS_FindGuildRule(key)
	if not g or M.PSS_ScanBlockedMsg() then return end
	M.PSS_ScanGuild(g.name, "sweep", restart)
end

function M.PSS_GuildCustomScan(key, fields)
	local _, g = M.PSS_FindGuildRule(key)
	if not g or M.PSS_ScanBlockedMsg() then return end
	M.PSS_SetGuildScanFields(g, M.trim(fields or "") or "")
	M.PSS_ScanGuild(g.name, "custom")
end

function M.PSS_GuildCommitFields(key, text)
	local _, g = M.PSS_FindGuildRule(key)
	if g then M.PSS_SetGuildScanFields(g, M.trim(text or "") or "") end
end

function M.PSS_GuildRemoveText(key)
	local _, g = M.PSS_FindGuildRule(key)
	if not g then return nil end
	return ("Remove <%s> from the Guild Ignore List?\n\nIts members, their notes and block history are deleted."):format(tostring(g.name))
end

function M.PSS_GuildRemove(key)
	if key then M.PSS_RemoveGuildNow(key) end
end

function M.PSS_MemberRemoveText(m)
	return ("Remove %s from this guild rule?\n\nThey stay on the Player Ignore List if they are on it."):format(tostring(m.name))
end

-- a member's note (25 letters); true if it changed
function M.PSS_MemberCommitNote(m, text)
	if not m then return false end
	text = (M.trim(text or "") or ""):sub(1, 25)
	if text == (m.note or "") then return false end
	M.PSS_SetMemberNote(m, text)
	return true
end

-- W I G P C for one member: ticked = allowed; follow = back to the guild's
function M.PSS_MemberToggleAllowed(gkey, m, cat, allowed, follow)
	local _, gg = M.PSS_FindGuildRule(gkey)
	if not (m and gg) then return false end
	if follow then
		M.PSS_SetMemberBlock(gg, m, cat, nil)
	else
		M.PSS_SetMemberBlock(gg, m, cat, not allowed)
	end
	return true
end

-- a default guild list's rule on or off (as on the Chat Filters tab)
function M.PSS_GroupToggleRule(k)
	if k and k ~= MANAGED then M.PSS_SetManagedGroupActive(k, not M.PSS_ManagedGroupActive(k)) end
end

function M.PSS_GroupToggleOpen(k)
	if k == MANAGED then
		M.PSS_SetGuildGroupOpen(M.PSS_GUILD_MANAGED_SHUT, not M.PSS_GuildGroupOpen(M.PSS_GUILD_MANAGED_SHUT))
	elseif k then
		M.PSS_SetGuildGroupOpen(k, not M.PSS_GuildGroupOpen(k))
	end
end

function M.PSS_ExclRemove(name)
	if name and M.PSS_RemoveGuildExclusion(name) then
		M.ChatMsg(("PSS: <%s> removed from the Guild Exclusion List."):format(name))
		return true
	end
	return false
end

------------------------------------------------------------------------
-- Events specs (the Events tab reads them; nothing here loads Logging)
------------------------------------------------------------------------
local allGuilds

function M.PSS_AllGuildsSpec()
	if allGuilds then return allGuilds end
	allGuilds = {
		kind = "guild", id = false, allText = "All Guilds", source = "guilds",
		label = function() return "All Guilds" end,
		read = M.PSS_GetGuildBlockHistory,
		reset = M.PSS_ResetAllGuildEvents,
	}
	return allGuilds
end

local function GuildLabel(key)
	local _, g = M.PSS_FindGuildRule(key)
	return g and tostring(g.name or key) or nil
end

function M.PSS_GuildEventsSpec(key)
	return {
		kind = "guild", id = key, allText = "All Guilds", all = M.PSS_AllGuildsSpec,
		label = GuildLabel,
		read = M.PSS_GetGuildBlockHistory,
		reset = M.PSS_ResetGuildBlockHistory,
		owner = History.GuildKey, counts = M.PSS_GetGuildBlockCounts,
	}
end

-- a default guild list (or MANAGED: every one)
function M.PSS_GuildGroupLabel(k)
	if k == MANAGED then return "Managed Communities" end
	local grp = M.PSS_ManagedGroups()[k]
	return grp and tostring(grp.name or k) or nil
end

function M.PSS_GroupEventsSpec(k)
	return {
		kind = "group", id = k, confirm = true, allText = "All Guilds", all = M.PSS_AllGuildsSpec,
		label = M.PSS_GuildGroupLabel,
		read = M.PSS_GroupEvents,
		reset = M.PSS_ResetGroupEvents,
	}
end

function M.PSS_MemberEventsSpec(m, gkey)
	return {
		kind = "member", id = m, allText = "Whole Guild",
		all = function() return GuildLabel(gkey) and M.PSS_GuildEventsSpec(gkey) or M.PSS_AllGuildsSpec() end,
		label = function(rec)
			local _, g = M.PSS_FindGuildRule(gkey)
			if not (g and type(g.members) == "table") then return nil end
			for _, x in pairs(g.members) do
				if x == rec then return tostring(rec.name or "?") end
			end
			return nil
		end,
		read = M.PSS_GetMemberBlockHistory,
		owner = History.MemberKey, counts = M.PSS_GetMemberBlockCounts,
		reset = M.PSS_ResetMemberBlockHistory,
	}
end
