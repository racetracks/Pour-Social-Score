------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - ADDONS TAB
--
-- Every addon in one grouped, searchable list: a tick (on for this
-- character or for all), the title in its state's colour, its status, a
-- Load button for a load on demand addon and a protect mark.
-- Hovering an addon shows its details, a group header how many of its
-- addons are loaded. Addon Profiles (bottom left), Undo, Enable All, Disable All and
-- Reload are under the list. Drawing only: Libraries (PSS_AddonsView.lua over
-- PSS_AddonsQuery.lua) works out every text and does every change; the
-- tab redraws when core fires ADDONS_CHANGED. Built on first open; closing
-- the window drops the list (page.release).
--
-- Art is Blizzard's, through the kit and by name, never a file of ours:
-- the group arrow is the atlas "bag-arrow" (a +/- text where the client
-- has none), the protect mark is cell 4 of the glue screen's addon icons
-- (a * where the client has no such file), checks and buttons are the
-- kit's in every look.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M
if not M.PSS_On("addons") then return end	-- the Addon Manager is off: no AddOns tab (issue 181)

local V = M.PSS_AddonView()
local page, list, search, charDD, viewDD, setsDD
local tally, footer, undo, enableAll, disableAll, reload, deps, oldCheck
local rowBuf = {}

local STAR = "Interface\\Glues\\CharacterSelect\\Glues-AddOn-Icons"
local STAR_COORDS = { 0.75, 1, 0, 1 }
local ARROW = "bag-arrow"
local TOP_H = 28

ns.PageBuilders = ns.PageBuilders or {}

local Refresh

local function Say(text)
	if text and text ~= "" then M.ShowMsg(text) end
end

------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------
local function LockClick(row)
	local k = row.index
	if not k then return end
	local o = V:Row(k, rowBuf)
	if not o or o.header or o.pss then return end
	Say(V:Act(k, o.locked and "unlock" or "lock"))
end

local function MakeRow(row)
	local tick = ns.NewCheck(row)
	tick:SetPoint("LEFT", row, "LEFT", 2, 0)
	tick:SetScript("OnClick", function(self)
		local k = row.index
		if k then
			local ok, text = V:Tick(k, self:GetChecked() and true or false)
			if not ok then Say(text) end
		end
		-- the state shown is what the client says (a refused tick is undone)
		list:Redraw()
	end)
	row.tick = tick

	local load = ns.NewButton(row, "Load", 56, function()
		local k = row.index
		if k then Say(V:Act(k, "load")) end
	end)
	load:SetHeight(18)
	load:SetPoint("LEFT", row.cells.load, "LEFT", 0, 0)
	row.load = load

	-- the protect mark: Blizzard's star, a * where the client has no such file
	local lock = CreateFrame("Button", nil, row)
	lock:SetSize(18, 18)
	lock:SetPoint("LEFT", row.cells.lock, "LEFT", 4, 0)
	local star = lock:CreateTexture(nil, "ARTWORK")
	star:SetAllPoints()
	lock.hasStar = ns.FileTexture(star, STAR, STAR_COORDS)
	star:SetShown(lock.hasStar)
	local glyph = ns.NewText(lock, 16)
	glyph:SetPoint("CENTER", lock, "CENTER", 0, -3)
	glyph:SetText("*")
	glyph:SetShown(not lock.hasStar)
	ns.OnPaint(function()
		glyph:SetTextColor(ns.Accent())
	end)
	lock:SetScript("OnClick", function() LockClick(row) end)
	lock:SetScript("OnEnter", function(self)
		local k = row.index
		local o = k and V:Row(k, rowBuf)
		if o and not o.header then
			ns.Tip(self, o.pss and "Pour Social Score is always protected." or
				(o.locked and "Protected: Disable All and addon profiles leave it on. Click to stop protecting it."
				or "Click to protect it: Disable All and addon profiles leave it on."))
		end
	end)
	lock:SetScript("OnLeave", ns.HideTip)
	row.lock, row.star, row.glyph = lock, star, glyph

	-- a group's arrow: Blizzard's atlas, rotated open or closed
	local arrow = row:CreateTexture(nil, "ARTWORK")
	arrow:SetSize(12, 12)
	arrow:SetPoint("LEFT", row.cells.title, "LEFT", 0, 0)
	arrow:Hide()
	row.arrow = arrow
end

local function Clear(row)
	for _, fs in pairs(row.cells) do fs:SetText("") end
	row.tick:Hide()
	row.load:Hide()
	row.lock:Hide()
	row.arrow:Hide()
end

local function DrawRow(row, k)
	local o = V:Row(k, rowBuf)
	local c = row.cells
	if not o then
		Clear(row)
		return
	end
	row.tick:Show()
	row.tick:SetChecked(o.tick ~= 0)
	row.tick:SetAlpha(o.tick == 1 and 0.6 or 1)
	row.tick:SetEnabled(not o.pss)
	if o.header then
		local arrow = ns.HasAtlas(ARROW)
		row.arrow:SetShown(arrow)
		if arrow then
			row.arrow:SetAtlas(ARROW)
			row.arrow:SetRotation(o.open and -math.pi / 2 or 0)
			c.title:SetText("      |cffffffff" .. o.text .. "|r")
		else
			c.title:SetText((o.open and "[-] " or "[+] ") .. "|cffffffff" .. o.text .. "|r")
		end
		c.status:SetText("")
		row.load:Hide()
		row.lock:Hide()
		return
	end
	row.arrow:Hide()
	c.title:SetText(o.text)
	c.status:SetText(o.status)
	row.load:SetShown(o.load)
	row.lock:Show()
	row.lock:SetAlpha((o.locked or o.pss) and 1 or 0.18)
	row.star:SetShown(row.lock.hasStar)
	row.glyph:SetShown(not row.lock.hasStar)
end

local function RowTip(row, k)
	ns.Tip(row, V:Tip(k))
end

local function RowClick(row, k, button)
	if button == "RightButton" then
		local entries = V:Menu(k)
		if entries then
			ns.RowMenu(row, entries, function(act, arg)
				local text, redraw = V:Act(k, act, arg)
				Say(text)
				if redraw then Refresh() end
			end)
		end
	elseif V:Row(k, rowBuf) and rowBuf.header then
		V:Toggle(k)
		Refresh()
	end
end

------------------------------------------------------------------------
-- The tab
------------------------------------------------------------------------
-- the texts of what a reload will do (the counts come from Libraries: V:Changes):
-- the summary at the top, the Reload button's "(+x/-y)", and the hover of both
local function Counts(adds, offs) return "+" .. #adds .. "/-" .. #offs end

local TIP_MAX = 30

local function ChangeTip()
	local adds, offs = V:Changes()
	if #adds == 0 and #offs == 0 then return nil end
	local lines, n = {}, 0
	for _, set in ipairs({ { "+ ", adds }, { "- ", offs } }) do
		for _, name in ipairs(set[2]) do
			n = n + 1
			if n <= TIP_MAX then lines[#lines + 1] = set[1] .. name end
		end
	end
	if n > TIP_MAX then lines[#lines + 1] = "... and " .. (n - TIP_MAX) .. " more" end
	return { title = "Addon changes (" .. Counts(adds, offs) .. ")", bold = "Reload Required", text = table.concat(lines, "\n") }
end

local function AccentHex()
	local r, g, b = ns.Accent()
	if not r then return "ffffffff" end
	return ("ff%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function Refresh()
	if not page then return end
	local n, text, empty = V:Build()
	list:SetCount(n)
	list:SetEmptyText(n == 0 and empty or nil)
	footer:SetText(text)
	local adds, offs = V:Changes()
	local none = #adds == 0 and #offs == 0
	tally:SetText(none and "No changes waiting for a reload" or ("Enabling " .. #adds .. ", disabling " .. #offs))
	charDD:SetLabel(V.who == "all" and "All characters" or "This character")
	viewDD:SetLabel(V.view == "az" and "A to Z" or (V.view == "lod" and "Load on demand apart" or "Grouped"))
	deps:SetChecked(V.deps)
	if oldCheck:IsShown() then oldCheck:SetChecked(M.PSS_AddonLoadOld() and true or false) end
	-- Reload is marked while a change waits for it
	local waits = V:Pending()
	reload.pssPrimary = waits
	if reload.pssPaint then reload.pssPaint() end
	reload:SetText(waits and ("|c" .. AccentHex() .. "Reload" .. (none and "" or (" (" .. Counts(adds, offs) .. ")")) .. "|r") or "Reload")
	undo:SetEnabled(M.PSS_AddonCan("undo"))
	enableAll:SetEnabled(M.PSS_AddonCan("all"))
	disableAll:SetEnabled(M.PSS_AddonCan("all"))
end

-- Rename's popup: an addon profile's name (the kit's Confirm with a name field)
local function AskName(p, run)
	ns.Confirm({ title = "Rename Addon Profile?", text = "Enter the new name for [" .. p.label .. "]:", accept = "Rename",
		name = { text = p.name or "", max = 32 }, onAccept = function(_, typed) run(typed or "") end })
end

-- one action on a place of the Addon Profiles menu; Save and Delete ask first
local function SetAction(p, act)
	p = V:Place(p.id) or p
	if act == "save" then
		ns.Confirm({ title = "Save Addon Profile?", text = "Save the current addon list to [" .. p.label .. "]?", accept = "Yes",
			onAccept = function()
				Say(V:PresetAct(p, "save"))
				Refresh()
			end })
	elseif act == "rename" then
		AskName(p, function(name)
			Say(V:PresetAct(p, "rename", name))
			Refresh()
		end)
	elseif act == "delete" then
		ns.Confirm({ title = "Delete Addon Profile?", text = "Delete the addon profile " .. p.label .. "? The addons stay as they are.", accept = "Delete",
			onAccept = function() Say(V:PresetAct(p, "delete")); Refresh() end })
	else
		Say(V:PresetAct(p, act))
		Refresh()
	end
end

-- the Addon Profiles menu: every place (Core, a line, Layered); a place is a
-- side menu with its actions (Blizzard's submenu; under a Back line in Dark)
local function BuildSets(m)
	for _, e in ipairs(V:ProfileMenu()) do
		if e.kind == "title" then
			m:Title(e.text)
		elseif e.kind == "divider" then
			m:Divider()
		else
			local place = V:Place(e.p.id) or e.p
			m:Sub(e.text, function(sm)
				for _, a in ipairs(V:PresetMenu(V:Place(e.p.id) or e.p)) do
					if a.kind == "title" then
						sm:Title(a.text)
					elseif a.kind == "divider" then
						sm:Divider()
					else
						sm:Button(a.text, function() SetAction(e.p, a.act) end)
					end
				end
			end, {
				-- the tick next to the place: ticked turns all of its addons on, unticked off
				on = function() return V:PlaceOn(V:Place(e.p.id) or e.p) end,
				fn = function() SetAction(e.p, V:PlaceOn(V:Place(e.p.id) or e.p) and "disable" or "enable") end,
			})
		end
	end
end

local function BuildToolbar()
	search = ns.NewSearchBox(page, 160, "Search addons", function(text)
		if V:SetFind(text) then Refresh() end
	end)
	search:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -8)

	charDD = ns.NewDropdown(page, 130, function(m)
		m:Radio("This character", function() return V.who == "me" end, function() V.who = "me"; Refresh() end)
		m:Radio("All characters", function() return V.who == "all" end, function() V.who = "all"; Refresh() end)
	end)
	charDD:SetPoint("LEFT", search, "RIGHT", 10, 0)

	viewDD = ns.NewDropdown(page, 150, function(m)
		for _, v in ipairs({ { "group", "Grouped" }, { "az", "A to Z" }, { "lod", "Load on demand apart" } }) do
			m:Radio(v[2], function() return V.view == v[1] end, function()
				M.PSS_AddonViewMode(v[1])
				Refresh()
			end)
		end
	end)
	viewDD:SetPoint("LEFT", charDD, "RIGHT", 6, 0)

	deps = ns.NewCheck(page)
	deps:SetPoint("LEFT", viewDD, "RIGHT", 8, 0)
	local depsText = ns.NewText(page, 12)
	depsText:SetPoint("LEFT", deps, "RIGHT", 0, 0)
	depsText:SetText("Dependencies")
	ns.TipOn(deps, deps, "Turning an addon on also turns on the addons it requires (never its optional ones).")
	deps:SetScript("OnClick", function(self) V.deps = self:GetChecked() and true or false end)

	oldCheck = ns.NewCheck(page)
	oldCheck:SetPoint("LEFT", depsText, "RIGHT", 10, 0)
	local oldText = ns.NewText(page, 12)
	oldText:SetPoint("LEFT", oldCheck, "RIGHT", 0, 0)
	oldText:SetText("Out of date")
	ns.TipOn(oldCheck, oldCheck, "Load out of date AddOns: also loads addons made for another game version.")
	oldCheck:SetScript("OnClick", function(self) M.PSS_AddonLoadOld(self:GetChecked() and true or false) end)
	local can = M.PSS_AddonCan("loadold")
	oldCheck:SetShown(can)
	oldText:SetShown(can)
end

local function BuildFooter()
	-- the Addon Profiles drop-down, bottom left (its menu opens downward)
	setsDD = ns.NewDropdown(page, 190, BuildSets, 420)
	setsDD:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 10, 8)
	setsDD:SetLabel("Profiles")
	footer = ns.NewText(page, 12)
	footer:SetPoint("LEFT", setsDD, "RIGHT", 12, 0)
	footer:SetJustifyH("RIGHT")
	footer:SetWordWrap(false)
	footer:SetAlpha(0.8)

	reload = ns.NewButton(page, "Reload", 130, function()
		ns.Confirm({ title = "Reload UI?", text = "Reloads the game's interface so the changes take effect.", accept = "Reload", reload = true,
			onAccept = function()
				local ok, text = M.PSS_AddonReload()
				if ok then Say("Reloading...") else Say(text) end
			end })
	end)
	reload:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -10, 8)
	-- hover: the same list as the summary at the top (nothing waiting: no tip)
	ns.TipOn(reload, reload, ChangeTip)
	disableAll = ns.NewButton(page, "Disable All", 96, function()
		ns.Confirm({ title = "Disable All AddOns?", text = "Turns every addon off for "
			.. (V.who == "all" and "all characters" or "this character")
			.. " except Pour Social Score and protected addons. Undo brings them back until you reload.",
			accept = "Disable All", onAccept = function()
				Say(select(2, M.PSS_AddonAll(false, V.who)))
			end })
	end)
	disableAll:SetPoint("RIGHT", reload, "LEFT", -6, 0)
	enableAll = ns.NewButton(page, "Enable All", 96, function()
		Say(select(2, M.PSS_AddonAll(true, V.who)))
	end)
	enableAll:SetPoint("RIGHT", disableAll, "LEFT", -6, 0)
	undo = ns.NewButton(page, "Undo", 70, function()
		Say(select(2, M.PSS_AddonUndo()))
	end)
	undo:SetPoint("RIGHT", enableAll, "LEFT", -6, 0)
	ns.TipOn(undo, undo, "Puts the addons back as they were when you logged in.")
	-- the count is anchored to the leftmost button and builds leftward
	footer:SetPoint("RIGHT", undo, "LEFT", -12, 0)
end

ns.PageBuilders.addons = function(pg)
	page = pg
	BuildToolbar()
	-- the summary of what a reload will do, top right; its hover lists the addons
	local tf = CreateFrame("Frame", nil, page)
	tf:SetPoint("TOPRIGHT", page, "TOPRIGHT", -12, -TOP_H - 8)
	tf:SetSize(230, 20)
	tf:EnableMouse(true)
	tally = ns.NewText(tf, 11)
	tally:SetPoint("RIGHT", tf, "RIGHT", 0, 0)
	tally:SetJustifyH("RIGHT")
	ns.TipOn(tf, tf, ChangeTip)
	page.tally = tally
	BuildFooter()

	local lf = CreateFrame("Frame", nil, page)
	lf:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -TOP_H - 32)
	lf:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -8, 38)
	list = ns.NewRows(lf, {
		rowH = 20,
		cols = {
			{ key = "tick", text = "", width = 30, sort = false },
			{ key = "title", text = "AddOn", sort = false },
			{ key = "status", text = "Status", width = 170, sort = false },
			{ key = "load", text = "", width = 64, sort = false },
			{ key = "lock", text = "", width = 30, sort = false },
		},
		make = MakeRow,
		draw = DrawRow,
		enter = RowTip,
		click = RowClick,
	})
	page.list, page.state, page.search = list, V, search
	page.setsDD, page.footer, page.setsBuild, page.undoButton, page.reloadButton = setsDD, footer, BuildSets, undo, reload
	page.release = function()
		V:Release()
		if list then list:SetCount(0) end
	end
	return Refresh
end

------------------------------------------------------------------------
-- Core says a change was made: redraw now if the tab shows (one redraw for
-- a burst), else when it next shows.
------------------------------------------------------------------------
local queued
local function RunQueued()
	queued = false
	if page and page:IsVisible() then Refresh() end
end
ns.Listen("ADDONS_CHANGED", function()
	if queued or not (page and page:IsVisible()) then return end
	queued = true
	C_Timer.After(0, RunQueued)
end)
