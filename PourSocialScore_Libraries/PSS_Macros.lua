------------------------------------------------------------------------
-- POUR SOCIAL SCORE - MACRO HELPER (/pss macro, 3.5.0, Camelot only)
--
-- Writes the macros of PSS_MacroData.lua, each as an account macro or
-- this character's (its store, its set's store, the default: account for
-- "global", character for a class; or one store for the whole run from
-- the command). PSS owns those names: a macro with the same name in the
-- same store gets PSS's icon and body. Never deletes a macro, never in
-- combat, never the Macro UI; no saved data, no events, no frames.
-- Every table is built for one command and released when it returns:
-- nothing is kept on M, in an upvalue or in a frame. Nothing is defined
-- on other clients.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local iface = select(4, GetBuildInfo())
if type(iface) ~= "number" or iface >= 20000 then return end

local CreateMacro, EditMacro, GetNumMacros, GetMacroInfo = CreateMacro, EditMacro, GetNumMacros, GetMacroInfo
local InCombatLockdown, UnitClass, pcall = InCombatLockdown, UnitClass, pcall
local ipairs, pairs, type = ipairs, pairs, type
local sort, concat = table.sort, table.concat
local format, lower, upper, sub, byte = string.format, string.lower, string.upper, string.sub, string.byte

local GLOBAL = "global"		-- the set that is not a class set
local QUESTION = 134400		-- Interface\Icons\INV_Misc_QuestionMark
local NAME_MAX = 16
local BODY_MAX = 255
local NAMES_MAX = 8		-- names in one chat line, then "+N more"
local CLASSES = { druid = true, hunter = true, mage = true, paladin = true, priest = true,
	rogue = true, shaman = true, warlock = true, warrior = true }
local STORES = { account = "account", character = "character", char = "character" }

-- the chat texts (English, inline as the other Libraries files)
local T = {
	sets = "Macro sets: %s. Free slots: account %d of %d, character %d of %d.",
	usage = "Type /pss macro <set> to see what it will do, then /pss macro <set> create (add account or character to put the whole set in one place).",
	head = "%s macros:",
	allAs = " all as %s macros",
	row = "  %s (%s): %s",
	created = "%s macros: created %d (%s).",
	updated = "%s macros: updated %d (%s).",
	current = "%s macros: already current %d (%s).",
	full = "No room for %d (%s): delete a macro and run it again.",
	failed = "The client refused %d (%s).",
	bad = "Skipped %d (%s): not a valid macro in the addon's data.",
	badStore = "\"%s\" is not a macro store: use account or character.",
	wrongClass = "%s macros are for a %s: log in a %s to create them.",
	noSet = "No macro set \"%s\". Sets: %s.",
	noClassSet = "There are no %s macros yet.",
	combat = "Macros cannot be changed in combat.",
	noApi = "Macros are not available on this client.",
}

local function hasApi()
	return type(CreateMacro) == "function" and type(EditMacro) == "function"
		and type(GetNumMacros) == "function" and type(GetMacroInfo) == "function"
end

-- read at call time (the client's FrameXML globals; 120 and 18 on classic)
local function limits()
	return MAX_ACCOUNT_MACROS or 120, MAX_CHARACTER_MACROS or 18
end

-- the first macro called name in one store: index, body. Scans in place,
-- builds no table (GetMacroIndexByName searches both stores)
local function findIn(name, perChar)
	local numAccount, numChar = GetNumMacros()
	local first, last
	if perChar then
		first = limits() + 1
		last = first + (numChar or 0) - 1
	else
		first, last = 1, numAccount or 0
	end
	for i = first, last do
		local n, _, body = GetMacroInfo(i)
		if type(n) == "string" and n == name then return i, body end
	end
end

local function room(perChar)
	local maxAccount, maxChar = limits()
	local numAccount, numChar = GetNumMacros()
	local free = perChar and (maxChar - (numChar or 0)) or (maxAccount - (numAccount or 0))
	return free > 0 and free or 0
end

local function playerClass()
	local _, token = UnitClass("player")
	if type(token) ~= "string" or M.PSS_IsSecret(token) then return end
	return lower(token)
end

local function title(key)
	return upper(sub(key, 1, 1)) .. sub(key, 2)
end

local function printable(s, max, newline)
	if type(s) ~= "string" or #s < 1 or #s > max then return false end
	for i = 1, #s do
		local b = byte(s, i)
		if (b < 32 or b > 126) and not (newline and b == 10) then return false end
	end
	return true
end

local function valid(m)
	return type(m) == "table" and printable(m.name, NAME_MAX) and printable(m.body, BODY_MAX, true)
		and (m.icon == nil or type(m.icon) == "number" or type(m.icon) == "string")
		and (m.store == nil or m.store == "account" or m.store == "character")
end

local function names(list)
	local n = #list
	if n <= NAMES_MAX then return concat(list, ", ") end
	return concat(list, ", ", 1, NAMES_MAX) .. format(" +%d more", n - NAMES_MAX)
end

-- global first, then the classes by name (one comparator, made once)
local function setOrder(a, b)
	if a == GLOBAL then return b ~= GLOBAL end
	if b == GLOBAL then return false end
	return a < b
end

local function storeOf(m, set, key, force)
	return force or m.store or set.store or (key == GLOBAL and "account" or "character")
end

-- the set keys in order (an array of strings, built per call)
function M.PSS_MacroSets(data)
	data = data or M.PSS_MacroData()
	local keys = {}
	for key, set in pairs(data) do
		if type(set) == "table" then keys[#keys + 1] = key end
	end
	sort(keys, setOrder)
	return keys, data
end

local function setList(data)
	local keys = M.PSS_MacroSets(data)
	for i = 1, #keys do keys[i] = format("%s (%d)", keys[i], #data[keys[i]]) end
	return concat(keys, ", ")
end

-- what create would do; never writes. The plan's array part holds one
-- entry per macro: {m, store, perChar, state}, state new, update,
-- current or bad
function M.PSS_MacroPlan(key, force, data)
	if not hasApi() then return nil, T.noApi end
	data = data or M.PSS_MacroData()
	local set = data[key]
	if type(set) ~= "table" then
		if CLASSES[key] then return nil, format(T.noClassSet, title(key)) end
		return nil, format(T.noSet, key, setList(data))
	end
	local name = title(key)
	if key ~= GLOBAL and playerClass() ~= key then
		return nil, format(T.wrongClass, name, name, name)
	end
	local plan = { title = name, force = force }
	for i, m in ipairs(set) do
		local store = storeOf(m, set, key, force)
		local perChar = store == "character"
		local state = "bad"
		if valid(m) then
			local index, body = findIn(m.name, perChar)
			state = (not index and "new") or (body == m.body and "current") or "update"
		end
		plan[i] = { m = m, store = store, perChar = perChar, state = state }
	end
	return plan
end

-- writes the plan; indexes are found again for each macro, as every
-- write re-sorts the store
function M.PSS_MacroCreate(key, force, data)
	if InCombatLockdown() then return false, T.combat end
	local plan, why = M.PSS_MacroPlan(key, force, data)
	if not plan then return false, why end
	local res = { title = plan.title, created = {}, updated = {}, current = {}, full = {}, failed = {}, bad = {} }
	for i = 1, #plan do
		local e = plan[i]
		local m, state, into = e.m, e.state
		if state == "current" then
			into = res.current
		elseif state == "bad" then
			into = res.bad
		elseif state == "new" and room(e.perChar) == 0 then
			into = res.full
		else
			local ok
			if state == "update" then
				local index = findIn(m.name, e.perChar)
				ok = index and pcall(EditMacro, index, m.name, m.icon or QUESTION, m.body)
			else
				ok = pcall(CreateMacro, m.name, m.icon or QUESTION, m.body, e.perChar)
			end
			local _, body = findIn(m.name, e.perChar)
			if ok and body == m.body then
				into = state == "update" and res.updated or res.created
			else
				into = res.failed
			end
		end
		into[#into + 1] = format("%s (%s)", type(m) == "table" and type(m.name) == "string" and m.name or "?", e.store)
	end
	return true, res
end

local function report(res)
	local t = res.title
	if #res.created > 0 then M.ShowMsg(format(T.created, t, #res.created, names(res.created))) end
	if #res.updated > 0 then M.ShowMsg(format(T.updated, t, #res.updated, names(res.updated))) end
	if #res.current > 0 then M.ShowMsg(format(T.current, t, #res.current, names(res.current))) end
	if #res.full > 0 then M.ShowMsg(format(T.full, #res.full, names(res.full))) end
	if #res.failed > 0 then M.ShowMsg(format(T.failed, #res.failed, names(res.failed))) end
	if #res.bad > 0 then M.ShowMsg(format(T.bad, #res.bad, names(res.bad))) end
end

-- /pss macro [set] [create] [account|character]
function M.PSS_MacroCommand(args)
	local data = M.PSS_MacroData()
	local key, verb, word = args[2], args[3], args[4]
	if not key then
		local maxAccount, maxChar = limits()
		if hasApi() then
			M.ShowMsg(format(T.sets, setList(data), room(false), maxAccount, room(true), maxChar))
			M.ShowMsg(T.usage)
		else
			M.ShowMsg(T.noApi)
		end
	elseif verb == "create" then
		local force = word and STORES[word]
		if word and not force then
			M.ShowMsg(format(T.badStore, word))
		else
			local ok, res = M.PSS_MacroCreate(key, force, data)
			if ok then report(res) else M.ShowMsg(res) end
		end
	elseif verb == nil or STORES[verb] then
		local plan, why = M.PSS_MacroPlan(key, verb and STORES[verb], data)
		if plan then
			M.ShowMsg(format(T.head, plan.title) .. (plan.force and format(T.allAs, plan.force) or ""))
			for i = 1, #plan do
				local e = plan[i]
				M.ShowMsg(format(T.row, type(e.m) == "table" and type(e.m.name) == "string" and e.m.name or "?", e.store, e.state))
			end
			M.ShowMsg(T.usage)
		else
			M.ShowMsg(why)
		end
	else
		M.ShowMsg(format(T.badStore, verb))
	end
	-- the data, plan and result were built for this command only; the
	-- explicit drop documents that nothing outlives it (the memory phase
	-- proves it)
	data = nil
end
