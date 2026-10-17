------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - SEARCH EVERYWHERE (warehouse-helper, one-build
-- plan STP-p15; Syndicator parity 5 to 8, 24). One search box over every
-- character, guild bank and the warband. The window only draws: the rows
-- come from M.PSS_WhSearchRows, the gold from M.PSS_WhGold (PSS_WhView.lua,
-- Libraries). Built the first time it is asked for; a window made like a
-- popup (ns.PopupShell: the same frame in all three looks, the title says
-- what it does, Escape closes). A click on a row says where the item is
-- (M.PSS_WhShowLocation). Nothing here listens to core events; the results
-- are made again when the window shows and on every change of the text.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local win

-- The search view: one box, the realm scope, the rows (icon, name, holders, total) and the gold. `host` is the
-- frame it fills: the popup of /pss wh (and /syn) or the Warehouse tab of the main window (F6). Both draw the same
-- rows from the same Libraries calls (M.PSS_WhSearchRows, M.PSS_WhMineRows, M.PSS_WhGold).
local function BuildView(host, tab)
	local f = host
	f.search = ns.NewSearchBox(f, tab and 360 or 400, "Name, keyword or numbers: epic & >400", function(text) f.Search(text) end)
	f.search:SetPoint("TOPLEFT", f, "TOPLEFT", tab and 12 or 20, tab and -10 or -44)
	-- F2, W-7: which realms the rows and the gold cover (option whRealms, the one the Options page reads; the choices are
	-- the option's own, a change from either place redraws an open window)
	f.scope = ns.NewDropdown(f, 118, function(m)
		for _, v in ipairs(M.PSS_WhScopeChoices()) do
			m:Radio(v[2], function() return M.PSS_Opt("whRealms") == v[1] end, function()
				M.PSS_SetOpt("whRealms", "global", v[1])
			end)
		end
	end)
	if tab then f.scope:SetPoint("LEFT", f.search, "RIGHT", 10, 0) else f.scope:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -44) end
	f.hint = ns.NewText(f, 11)
	f.hint:SetPoint("TOPLEFT", f, "TOPLEFT", tab and 16 or 24, tab and -36 or -70)
	f.hint:SetAlpha(0.55)
	f.listFrame = CreateFrame("Frame", nil, f)
	f.listFrame:SetPoint("TOPLEFT", f, "TOPLEFT", tab and 8 or 14, tab and -54 or -88)
	f.listFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, tab and 36 or 46)
	f.rows = {}
	f.list = ns.NewRows(f.listFrame, {
		rowH = 20, fontSize = 12,
		cols = {
			{ key = "icon", text = "", width = 24, sort = false },
			{ key = "name", text = "Item" },
			{ key = "where", text = "Held by", width = 190 },
			{ key = "total", text = "Total", width = 56, justify = "RIGHT" },
		},
		-- an icon on the left of every row (the item's own art, the same in all three looks)
		make = function(row)
			row.icon = row:CreateTexture(nil, "ARTWORK")
			row.icon:SetSize(16, 16)
			row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)
		end,
		-- the item's tooltip on hover: Blizzard's tooltip in every look (only an item: link, only when not forbidden)
		enter = function(row, i)
			local r = f.rows[i]
			if not r or not r.link or GameTooltip:IsForbidden() then return end
			GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
			if pcall(GameTooltip.SetHyperlink, GameTooltip, r.link) and GameTooltip:NumLines() > 0 then GameTooltip:Show() else GameTooltip:Hide() end
		end,
		draw = function(row, i)
			local r = f.rows[i]
			if not r then return end
			row.icon:SetTexture(r.icon)
			row.cells.name:SetText(r.name)
			row.cells.where:SetText(r.where)
			row.cells.total:SetText(tostring(r.total))
		end,
		click = function(_, i)
			local r = f.rows[i]
			if r then M.PSS_WhShowLocation(r.key) end
		end,
	})
	f.money = ns.NewMoneyLine(f, 250)
	f.money:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", tab and 12 or 20, tab and 8 or 18)
	f.money:SetLabel("Gold")
	function f.Search(text)
		local typed = text and text:find("%S")
		local done, truncated = true, false
		if typed then
			f.rows, done = M.PSS_WhSearchRows(text, function()
				if f:IsShown() and f.search:GetText() == text then f.Search(text) end
			end)
		else
			f.rows, truncated = M.PSS_WhMineRows()
		end
		f.list:SetCount(#f.rows)
		f.list:Redraw()
		if not typed then
			f.hint:SetText(#f.rows == 0 and "Nothing is saved for this character yet. Type to search every character, guild bank and the warband"
				or ("This character's items" .. (truncated and " (the first " .. #f.rows .. ")" or "") .. ". Type to search every character, guild bank and the warband"))
		elseif not done then f.hint:SetText("Searching... " .. #f.rows .. " found so far")
		elseif #f.rows == 0 then f.hint:SetText("Nothing found")
		else f.hint:SetText(#f.rows .. " found; click one to see where it is") end
	end
	function f.Refresh()
		local total, breakdown = M.PSS_WhGold()
		f.money:SetMoney(total, breakdown)
		f.Search(f.search:GetText())
	end
	-- item names the client gave late: draw again (the window hears core events only while it shows)
	ns.Listen("ITEM_DATA", function() if f:IsShown() then f.Refresh() end end)
	ns.Listen("OPTION_CHANGED", function(key) if key == "whRealms" and f:IsShown() then f.Refresh() end end)
	return f
end

local function Build()
	local f = ns.PopupShell("PSS_Everywhere", 560, 440)
	win = f
	f.title:SetText("Search Everywhere")
	BuildView(f, false)
	f.close = ns.PopupButton(f, 100, 24, false)
	f.close:SetText(CLOSE or "Close")
	f.close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 12)
	f.close:SetScript("OnClick", function() f:Hide() end)
	ns.PopupAbove(f, f.search, f.scope, f.listFrame, f.money, f.close)
	-- the popup can show without the main window: it hears core events (a changed scope, late item names) while it shows
	f:SetScript("OnShow", function() ns.ListenStart() f.Refresh() end)
	f:HookScript("OnHide", function()
		local main = _G.PSS_Window
		if not (main and main:IsShown()) then ns.ListenStop() end
	end)
	ns.EscapeCloses(f, "PSS_Everywhere")
end

-- the Warehouse tab of the main window (shown only while the Warehouse is on): the same view in the page
ns.TabBuilders = ns.TabBuilders or {}
ns.TabBuilders.warehouse = function(page)
	local v = BuildView(page, true)
	return v.Refresh
end

-- the entry Libraries calls (PSS_WhView.lua, /pss wh)
function M.PSS_EverywhereShow(text)
	ns.Fresh()
	if not win then Build() end
	win.search:SetText(text or "")
	win:Show()
	win:Raise()
	win.Refresh()
	if not text and win.search.SetFocus then win.search:SetFocus() end
	return win
end
