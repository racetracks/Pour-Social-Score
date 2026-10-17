------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE LOGIC OF SEARCH EVERYWHERE (warehouse-helper,
-- one-build plan STP-p15). The window (PourSocialScore_GUI/PSS_SearchEverywhere.lua)
-- only draws; what it shows is made here from the services, and every
-- service answer is checked: a failed call is an empty set, never nil.
--   M.PSS_CallSet(name, input, opts)   a record set always
--   M.PSS_WhSearchRows(text)           rows { key, name, icon, total, where } for a search text
--   M.PSS_WhShowLocation(key)          says where an item is (or hands it to the addon that asked)
--   M.PSS_WhGold()                     total copper and a breakdown text
--   M.PSS_WhOpenEverywhere(text)       opens the window (a user entry: /pss wh)
-- Loaded with Libraries; returns at the top while the Warehouse is off.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, ipairs, pairs, next, tonumber, tostring, pcall = type, ipairs, pairs, next, tonumber, tostring, pcall
local sort, concat = table.sort, table.concat

local EMPTY = { cols = {}, n = 0 }

function M.PSS_CallSet(name, input, opts)
	local r, err = M.PSS_Call(name, input, opts)
	if err or type(r) ~= "table" or type(r.n) ~= "number" then return { cols = {}, n = 0 } end
	return r
end


-- W-7: "this realm" is the realm of the logged-in character, spelled the way an entity stores it (the realm part of
-- the character's own display name, the form M.PSS_EntityId files it under: a spaced realm is its normalised name).
-- A one-entry set. A name that cannot be read gives an empty set, never every realm (PSS 02 11A.7): no character is
-- shown, the guilds and the warband stay.
function M.PSS_WhThisRealm()
	local name = M.PSS_PlayerDisplayName and M.PSS_PlayerDisplayName()
	local realm = type(name) == "string" and name:match("-([^-]*)$")
	if not realm or realm == "" then
		if M.PSS_ErrNote then M.PSS_ErrNote("fail", "wh.scope", "the character's realm cannot be read: no character is shown") end
		return {}
	end
	return { [realm] = true }
end

-- the scope choices, read from the option (the Options page and the search window offer the same two)
function M.PSS_WhScopeChoices()
	for _, o in ipairs(M.PSS_OPTIONS or {}) do
		if o.key == "whRealms" then return o.choices end
	end
	return {}
end

-- The realms search rows and gold cover (option whRealms): this realm, or nil (every realm) with "all". A tooltip
-- never calls this: it is this realm only (M.PSS_WhThisRealm), whatever the option says. A stored value other than
-- "all" (an old "connected") reads as this realm.
function M.PSS_WhRealmScope()
	if M.PSS_Opt("whRealms") == "all" then return nil end
	return M.PSS_WhThisRealm()
end

-- F2, F4: the saved gold as { name, copper, realm } rows inside the realm scope. A gold value whose entity is not
-- saved any more has no name to show: it is left out and counted in `orphans` (/pss wh status reports it), never
-- printed as "?". Hidden entities are named too, so a name always resolves.
function M.PSS_WhGoldRows()
	local gold = M.PSS_CallSet("money.gold")
	local ids = { cols = { "ent" }, n = gold.n }
	for i = 1, gold.n do ids[i] = { gold[i][1] } end
	local ents = M.PSS_CallSet("wh.ent", ids)
	local at = {}
	for i = 1, ents.n do at[ents[i][1]] = ents[i] end
	local scope = M.PSS_WhRealmScope()
	local list, orphans, copper = {}, 0, 0
	local kept = { cols = { "ent", "copper" }, n = 0 }
	for i = 1, gold.n do
		local e = at[gold[i][1]]
		if not e then
			orphans = orphans + 1
		elseif not (scope and e[2] == "c" and not scope[e[4]]) then
			local name = (e[2] == "w" and "Warband bank") or (e[2] == "g" and e[3] .. " (guild bank)") or e[3]
			list[#list + 1] = { name, gold[i][2], e[4] or "" }
			copper = copper + gold[i][2]
			kept.n = kept.n + 1
			kept[kept.n] = gold[i]
		end
	end
	sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
	return list, copper, orphans, kept
end

function M.PSS_WhGold()
	local list, total = M.PSS_WhGoldRows()
	local lines = {}
	for i, r in ipairs(list) do lines[i] = r[1] .. "  " .. (M.PSS_MoneyText and M.PSS_MoneyText(r[2], false) or tostring(r[2])) end
	return total, concat(lines, "\n")
end

-- the window loads only as the player asks (/pss wh): PSS 02 11A
function M.PSS_WhOpenEverywhere(text)
	if M.PSS_Need("GUI") and M.PSS_EverywhereShow then return M.PSS_EverywhereShow(text) end
end
