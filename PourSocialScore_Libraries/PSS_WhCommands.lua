------------------------------------------------------------------------
-- POUR SOCIAL SCORE - WAREHOUSE COMMANDS (warehouse-helper, one-build plan
-- STP-p16). Each command is a call into a service and prints what it gave:
--   /pss wh                      Search Everywhere (the window)
--   /pss wh search [text]        the window, filled in (with "chat" after the text: the matches in chat, 15 to a page)
--   /pss wh status               what is saved for each character, guild and the warband
--   /pss wh import [dry]         copy Syndicator's data (it must be loaded)
--   /pss wh sweep                free unused item ids now
--   /pss wh hide <Name-Realm>    hide or show a character or guild
--   /pss wh remove <Name-Realm>  (or delete) forget a character or guild and what is saved for it
--   /pss money                   gold per character, per realm and the total
-- /syn and /syndicator open Search Everywhere when no other addon owns them.
-- Loaded with Libraries; returns at the top while the Warehouse is off.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

if not M.PSS_On("warehouse") then return end

local type, ipairs, tonumber, tostring = type, ipairs, tonumber, tostring
local concat = table.concat

local PAGE = 15

local function say(s) M.ShowMsg(s) end

local function entOf(full)
	if type(full) ~= "string" then return nil end
	local id = full:match("^#(%d+)$")		-- an unnamed saved id (W3-D5), listed by /pss wh status
	if id then
		id = tonumber(id)
		for _, o in ipairs(M.PSS_EntityOrphans()) do if o == id then return id end end
		return nil
	end
	local name, realm = full:match("^(.*)-([^-]*)$")
	if not name then return nil end
	return M.PSS_EntityId("c", name, realm, false) or M.PSS_EntityId("g", name, realm, false)
end

-- the chat listing of a search ("/pss wh search <text> chat"); a search still waiting for item names prints when it is done
local function list(text, page)
	local rows, done = M.PSS_WhSearchRows(text, function() end)
	if not done then
		say("Searching for '" .. text .. "' (the client is still giving item names)...")
		local printed
		M.PSS_ItemSearchWatch(text, function()
			if printed or not (M.PSS_ItemSearchDone and M.PSS_ItemSearchDone(text)) then return end
			printed = true
			list(text, page)
		end)
		return
	end
	if #rows == 0 then say("Nothing found for '" .. text .. "'.") return end
	page = page or 1
	local pages = math.ceil(#rows / PAGE)
	if page > pages then page = pages end
	say(("%d found for '%s' (page %d of %d):"):format(#rows, text, page, pages))
	for i = (page - 1) * PAGE + 1, math.min(#rows, page * PAGE) do
		local r = rows[i]
		say(("  %s x%d: %s"):format(r.name, r.total, r.where))
	end
end

-- /pss wh search [text] [chat [page]]: the window, filled in (W3-D2); "chat" keeps the listing in chat
local function search(args)
	local words, chat, page = {}, false, nil
	for i = 3, #args do
		local w = args[i]
		if w == "chat" and not chat then chat = true
		elseif chat and tonumber(w) and not page then page = tonumber(w)
		else words[#words + 1] = w end
	end
	local text = concat(words, " ")
	if text == "" or not chat then M.PSS_WhOpenEverywhere(text ~= "" and text or nil) return end
	list(text, page)
end

function M.PSS_WhCommand(args)
	local sub = args[2]
	if not sub then M.PSS_WhOpenEverywhere() return end
	if sub == "search" then return search(args) end
	if sub == "status" then
		local s = M.PSS_CallSet("wh.status")
		local orphans = M.PSS_MoneyOrphans and M.PSS_MoneyOrphans(false) or 0
		if orphans > 0 then say(("  %d saved gold value(s) belong to no saved character (they are left as they are; they are not counted)."):format(orphans)) end
		if s.n == 0 then say("Nothing is saved yet.") return end
		local ids = { cols = { "ent" }, n = s.n }
		for i = 1, s.n do ids[i] = { s[i][1] } end
		local ents = M.PSS_CallSet("wh.ent", ids)
		local name = {}
		for i = 1, ents.n do name[ents[i][1]] = ents[i][2] == "w" and "Warband" or ents[i][3] end
		for i = 1, s.n do
			local r = s[i]
			say(("  %s: %s slots in %s containers%s"):format(name[r[1]] or ("unnamed #" .. r[1] .. ", kept"), r[3], (r[2] ~= "" and select(2, r[2]:gsub(",", ",")) + 1 or 0), r[5] > 0 and (", " .. r[5] .. " unreadable") or ""))
		end
	elseif sub == "import" then
		local r = M.PSS_CallSet("wh.import", nil, { dry = args[3] == "dry" })
		local slots, skipped = 0, 0
		for i = 1, r.n do slots = slots + r[i][4]; skipped = skipped + r[i][5] end
		if r.n > 0 then
			say(("%s %d sources, %d slots%s."):format(args[3] == "dry" and "Would copy" or "Copied", r.n, slots, skipped > 0 and (", " .. skipped .. " skipped") or ""))
			if args[3] ~= "dry" then say("You can now turn Syndicator off.") end
		end
	elseif sub == "sweep" then
		local r = M.PSS_CallSet("wh.sweep", nil, { force = true })
		say(r.n > 0 and ("Freed %d item ids, remapped %d."):format(r[1][1], r[1][2]) or "Nothing to free.")

	elseif sub == "hide" or sub == "delete" or sub == "remove" then
		local full = args[3]
		local ent = entOf(full)
		if not ent then say("Give a name like Name-Realm that the Warehouse knows, or #id for an unnamed one listed by /pss wh status.") return end
		if sub == "hide" then
			local flags = M.PSS_EntityFlags(ent) or ""
			local r = M.PSS_CallSet("wh.hide", { cols = { "ent" }, n = 1, { ent } }, { show = flags:find("h", 1, true) ~= nil })
			say(r.n > 0 and r[1][2] and (full .. " is hidden.") or (full .. " is shown."))
		else
			local r, err = M.PSS_Call("wh.delete", { cols = { "ent" }, n = 1, { ent } })
			say(err and ("Could not remove " .. full .. ": " .. tostring(err):gsub("^%a+: ", "")) or (full .. " was removed from the Warehouse."))
		end
	else
		say("/pss wh [search [text] [chat [page]] | status | import [dry] | sweep | hide <Name-Realm> | remove <Name-Realm>]")
	end
end

-- W3-D5: Options (Warehouse) lists and removes saved data that belongs to no saved character
function M.PSS_WhUnnamed() return #M.PSS_EntityOrphans() end
function M.PSS_WhUnnamedRemove()
	local n = 0
	for _, id in ipairs(M.PSS_EntityOrphans()) do
		local _, err = M.PSS_Call("wh.delete", { cols = { "ent" }, n = 1, { id } })
		if not err then n = n + 1 end
	end
	return n
end

function M.PSS_MoneyCommand()
	local list, total, orphans, kept = M.PSS_WhGoldRows()
	if #list == 0 then say("No gold is saved yet.") return end
	local by = M.PSS_CallSet("money.total", kept, { by = "realm" })
	for _, r in ipairs(list) do say("  " .. r[1] .. ": " .. M.PSS_MoneyText(r[2], false)) end
	for i = 1, by.n do say("  " .. by[i][1] .. " (realm): " .. M.PSS_MoneyText(by[i][2], false)) end
	say("  Total: " .. M.PSS_MoneyText(total, false))
	if orphans > 0 then say("  " .. orphans .. " saved gold value(s) belong to a character that is no longer saved and are not counted.") end
end

-- /syn and /syndicator, only when free (parity 10, 11)
local prev = M.PSS_WhStartMore
function M.PSS_WhStartMore(warehouse)
	if prev then prev(warehouse) end
	if not warehouse then return end
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if SlashCmdList["SYNDICATOR"] == nil and SlashCmdList["PSSSYN"] == nil and not (isLoaded and isLoaded("Syndicator")) then
		SLASH_PSSSYN1 = "/syn"
		SLASH_PSSSYN2 = "/syndicator"
		SlashCmdList["PSSSYN"] = function(msg)
			if msg and msg:find("%S") then M.PSS_SlashPSS("wh search " .. msg) else M.PSS_SlashPSS("wh") end
		end
	end
end
