------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PSS DROP CHEAPEST THING: the /pss dtt words, the
-- never and always lists, the log report and the Baganator junk plugin
-- (money-helper, DDS-00009 sections 5, 10; DEC-00113). Logic and chat
-- text only. Loaded only while the feature is on.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
if not M.PSS_On("dtt") then return end

local tostring, tonumber = tostring, tonumber
local LISTS = { always = "dttAlways", never = "dttNever" }

local function ItemText(id)
	local l = select(2, (C_Item and C_Item.GetItemInfo or GetItemInfo)(id))
	return l or ("item:" .. id)
end

-- which: "always" or "never"; input: a link, "item:<id>" or an id; remove:
-- true to take it off. Returns ok, id (or the reason).
function M.PSS_DttListEdit(which, input, remove)
	local key = LISTS[which]
	local id = M.PSS_ItemIDFromText(input)
	if not key then return false, "unknown list" end
	if not id then return false, "not an item" end
	local o = M.PSS_OPTION_REG[key]
	local ok
	if remove then ok = M.PSS_OptItemRemove(o, id) else ok = M.PSS_OptItemAdd(o, id) end
	return ok, id
end

local function Log()
	local out = {}
	local H = M.PSS_History
	if M.PSS_LoadLogging then M.PSS_LoadLogging() end
	local log = H.Log()
	for i = #log, 1, -1 do
		local h = log[i]
		if h.cat == "dtt" then out[#out + 1] = h end
		if #out >= 20 then break end
	end
	return out
end

local function ShowLog()
	local lines = Log()
	if #lines == 0 then M.ShowMsg("No Drop Cheapest Thing entries yet."); return end
	for _, h in ipairs(lines) do
		local id, count, copper = tostring(h.message):match("^(%d+),(%d+),(%d+)$")
		if id then
			local ic = (C_Item and C_Item.GetItemIconByID or GetItemIconByID)
			ic = ic and ic(tonumber(id))
			M.ShowMsg(("%s %s|T%s:0|t %s x%s (%s)"):format(date("%Y-%m-%d %H:%M", h.ts or 0),
				h.event == "DTT_SELL" and "Sold" or "Destroyed", tostring(ic or 134400), ItemText(tonumber(id)), count, M.PSS_DttMoney(tonumber(copper))))
		end
	end
end

function M.PSS_DttCommand(args, rawArgs)
	local w = args[2]
	local arg3 = rawArgs and rawArgs[3] or args[3]
	if w == nil or w == "act" then
		M.PSS_DttAct("auto")
	elseif w == "list" then
		M.PSS_DttScan()
		local list = M.PSS_DttList(10)
		if #list == 0 then M.ShowMsg("Nothing to destroy."); return end
		for _, bs in ipairs(list) do
			local l, c, v, ic, src = M.PSS_DttSlot(bs)
			M.ShowMsg(("|T%s:0|t %s%s  %s%s"):format(tostring(ic or 134400), l, c > 1 and (" x" .. c) or "", M.PSS_DttMoney(v),
				src ~= "vendor" and (" (" .. src .. ")") or ""))
		end
		local n, _, total = M.PSS_DttScan()
		M.ShowMsg(("%d items, %s."):format(n, M.PSS_DttMoney(total)))
	elseif w == "sell" then
		M.PSS_DttAct("sell")
	elseif w == "never" or w == "always" then
		local ok, r = M.PSS_DttListEdit(w, arg3, false)
		if ok then M.ShowMsg(("Added %s to the %s list."):format(ItemText(r), w))
		elseif r == "not an item" or r == nil then M.ShowMsg("Give an item link, item:<id> or an id.")
		else M.ShowMsg("It is already on the " .. w .. " list.") end
	elseif w == "forget" then
		local a = M.PSS_DttListEdit("always", arg3, true)
		local b, id = M.PSS_DttListEdit("never", arg3, true)
		M.ShowMsg((a or b) and "Taken off the lists." or "It was not on a list.")
	elseif w == "options" then
		M.PSS_OpenUI("addons", { page = "dtt" })
	elseif w == "log" then
		ShowLog()
	elseif w == "icon" then
		M.PSS_SetOpt("dttIcon", "global", not M.PSS_Opt("dttIcon"))
		M.ShowMsg("The minimap button is " .. (M.PSS_Opt("dttIcon") and "on." or "off."))
	else
		M.ShowMsg("/pss dtt [list | sell | never <item> | always <item> | forget <item> | options | log | icon]")
	end
end

-- Baganator: PSS's junk rule offered as a junk plugin through Baganator's
-- documented API (DEC-00113 b); read only, nothing of Baganator's changed
function M.PSS_DttBaganator()
	local api = Baganator and Baganator.API
	if not (api and api.RegisterJunkPlugin) then return end
	pcall(api.RegisterJunkPlugin, "PSS Drop Cheapest Thing", "pss_dtt", function(bag, slot)
		return M.PSS_DttIsJunk(bag, slot, "drop")
	end)
end
