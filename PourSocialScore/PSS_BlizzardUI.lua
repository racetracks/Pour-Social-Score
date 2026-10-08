-----------------------
-- BLIZZARD UI HOOKS --
-----------------------

local addonName, addon	= ...
local L = addon.L -- localization entries
local V = addon.V -- shared variables
local M = addon.M -- shared methods

V.nameUI = ""		-- the player the note and expiry popups are for

-------------
-- WINDOW --
-------------

-- The Pour Social Score window (PourSocialScore_GUI, loaded on demand; the
-- new window from 3.4.0): /pss gui, /pss ui and the Addon Compartment open
-- it. show true: open, never toggle shut.
function M.PSS_OpenUI(show)
	if M.PSS_Need("GUI") and M.PSS_OpenWindow then M.PSS_OpenWindow(show) end
end

-- The window opens beside the Friends window when the option
-- openWithFriends is on, and closes with it.
-- Retail 12.1 opens the Social window (SocialUIFrame) for the Friends key
-- and button; FriendsFrame only shows for the Who tab. Both are hooked, and
-- the window follows whichever opened. SocialUIFrame has its tabs on its
-- right edge, so the window sits clear of them (x offset).
local hosts = { FriendsFrame }
local HOST_X = { [FriendsFrame] = 12 }
if SocialUIFrame then
	hosts[#hosts + 1] = SocialUIFrame
	HOST_X[SocialUIFrame] = 55
end

local function hostShow(host)
	if not M.PSS_Opt("openWithFriends") then return end
	if M.PSS_Need("GUI") and M.PSS_WindowDock then M.PSS_WindowDock(host, HOST_X[host]) end
end
-- switching Social to the Who tab hides one host and shows the other: the
-- window stays while either is still shown
local function hostHide()
	for i = 1, #hosts do
		if hosts[i]:IsShown() then return end
	end
	if M.PSS_WindowUndock then M.PSS_WindowUndock() end
end
for i = 1, #hosts do
	hosts[i]:HookScript("OnShow", hostShow)
	hosts[i]:HookScript("OnHide", hostHide)
end

-----------------------------------------
-- POPUPS AND ALERTS (fire during play) --
-----------------------------------------

-- The reload prompt: Blizzard's StaticPopup in every look (Dan,
-- 2026-10-08). Camelot (interface 16001) blocks ReloadUI() from addon code.
local camelot = GetBuildInfo and (select(4, GetBuildInfo()) or 0) < 20000

StaticPopupDialogs["PSS_RELOAD"] = {
	preferredIndex	= STATICPOPUPS_NUMDIALOGS,
	text			= "%s",
	button1			= RELOADUI or "Reload UI",
	button2			= LATER or "Later",
	whileDead		= 1,
	hideOnEscape	= 1,
	OnAccept		= function() ReloadUI() end,
}

function M.PSS_AskReload(text)
	if camelot then
		M.ShowMsg(text .. " Type /reload.")
	else
		StaticPopup_Show("PSS_RELOAD", text)
	end
end

StaticPopupDialogs["PSS_REASON"] = {

	preferredIndex = STATICPOPUPS_NUMDIALOGS,
	text			= "Edit ignore note for |cffffff00%s:",
	maxLetters		= 128,
	hasEditBox		= 1,
	whileDead		= 1,
	button1			= L["BOX_3"],
	button2			= L["BOX_5"],

	OnShow = function(self)
		local idx = M.hasAnyIgnored(V.nameUI)
		self.EditBox:SetText(idx > 0 and (PourSocialScoreDB.notes[idx] or "") or "")
		self.EditBox:SetFocus()
	end,
	OnAccept = function(self)
		local idx = M.hasAnyIgnored(V.nameUI)
		if idx > 0 then M.PSS_SetNote(idx, self.EditBox:GetText()) end
		M.PSS_PlayersChanged()
	end,
	EditBoxOnEnterPressed = function(self)
		local idx = M.hasAnyIgnored(V.nameUI)
		if idx > 0 then M.PSS_SetNote(idx, self:GetParent().EditBox:GetText()) end
		self:GetParent():Hide()
		M.PSS_PlayersChanged()
	end,
	EditBoxOnEscapePressed = function(self)
		self:GetParent():Hide()
	end
}

StaticPopupDialogs["PSS_PARTYWARN"] = {

	preferredIndex	= STATICPOPUPS_NUMDIALOGS,
	text			= L["BOX_8"],
	button1			= L["BOX_6"],
	timeout			= 15,
	whileDead		= true,
	hideOnEscape	= true,
}

-- The note and the party warning are these two StaticPopups in every look
-- (Dan, 2026-10-08): core never loads the window for a popup.

-- a player was just listed and Options asks for a note
M.Events.Register("ASK_NOTE", function(name)
	V.nameUI = name
	StaticPopup_Show("PSS_REASON", V.nameUI)
end)

-- you whispered a player whose whispers are blocked: raid warning style notice
M.Events.Register("WHISPER_WARNING", function(name, label)
	if RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, format(L["WARN_WHISPER"], name, label), ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] or { r = 1, g = 0.28, b = 0 })
	end
	if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end)

-- listed players are in your group (names: the players warned about)
M.Events.Register("GROUP_WARNING", function(names)
	StaticPopup_Show("PSS_PARTYWARN", #names, "\n" .. table.concat(names, "\n"))
end)

--------------------
-- LFG TOOL HACKS --
--------------------

-- Re-colour the Group Finder rows that are on screen after the list changes.
-- 2.0.8 called Blizzard's LFGListSearchPanel_UpdateResults from addon code,
-- which can taint the Group Finder (blocked "Sign Up" etc.). This only sets
-- text colours on the visible rows; Blizzard's own update recolours the rest.
function M.PSS_LFG_Refresh()
	local panel = LFGListFrame and LFGListFrame.SearchPanel
	if not (panel and panel:IsShown() and panel.ScrollBox and panel.ScrollBox.ForEachFrame) then return end
	pcall(panel.ScrollBox.ForEachFrame, panel.ScrollBox, function(row)
		if row and row.resultID and row.Name then pcall(M.PSS_LFG_Update, row) end
	end)
end

function M.PSS_LFG_Update (self)
	if not C_LFGList.HasSearchResultInfo(self.resultID) then return end

	local info = C_LFGList.GetSearchResultInfo(self.resultID);
	local leader = info and info.leaderName

	-- runs for every visible Group Finder row on every refresh: O(1) lookup,
	-- no display-name building
	if type(leader) == "string" and not M.PSS_IsSecret(leader) and leader ~= "" and M.PSS_IsPlayerListed(leader) then
		self.Name:SetTextColor(RED_FONT_COLOR.r, RED_FONT_COLOR.g, RED_FONT_COLOR.b);
	end
end

function M.PSS_LFG_Tooltip (self)
	if not C_LFGList.HasSearchResultInfo(self.resultID) then return end

	local info = C_LFGList.GetSearchResultInfo(self.resultID);

	if info ~= nil and type(info.leaderName) == "string" and not M.PSS_IsSecret(info.leaderName) then
		local idx = M.PSS_ListedPosition(M.PSS_CanonPlayer(info.leaderName)) or 0

		if (idx > 0) and not GameTooltip:IsForbidden() then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("|c00ff0000" .. L["RCM_8"])

			local notes = (PourSocialScoreDB.notes[idx] or "")

			if (notes ~= "") then
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("|cffffffff" .. L["RCM_9"])
				GameTooltip:AddLine("|cff69CCF0"..notes)
			end

			GameTooltip:Show()
		end
	end
end

function M.PSS_LFG_ApplicantMenu(owner, root, contextData)
	if not owner or not owner.resultID then return end

	local info = C_LFGList.GetSearchResultInfo(owner.resultID);

	if not info or type(info.leaderName) ~= "string" or M.PSS_IsSecret(info.leaderName) or info.leaderName == "" then return end

	local target = M.Proper(M.addServer(info.leaderName))
	local text		= ""

	if M.PSS_IsPlayerListed(info.leaderName) then
		text = L["RCM_4"]
	else
		text = L["RCM_6"]
	end

	local leaderText = format(L["RCM_7"], target)

	root:CreateDivider()
	root:CreateTitle(leaderText)
	root:CreateButton(text,
		function(owner, root, contextData)
			M.PSS_AddOrDelIgnore(M.addServer(info.leaderName))
			M.PSS_PlayersChanged(true)
		end)
end

----------------------
-- UNIT MENU- HACKS --
----------------------

function M.PSS_UnitMenuPlayer (owner, root, contextData)
	if type(contextData) ~= "table" then return end
	if contextData.bnetIDAccount and not contextData.unit then return end	-- a Battle.net friend, not a character
	local target, server
	if contextData.unit and UnitExists(contextData.unit) then
		target, server = UnitName(contextData.unit)
	else
		-- menus opened from a name in chat carry the name, not a unit
		target, server = contextData.name, contextData.server
	end
	-- secret check first: a secret value can't even be compared with ""
	if type(target) ~= "string" or M.PSS_IsSecret(target) or target == "" then return end
	if server ~= nil and (type(server) ~= "string" or M.PSS_IsSecret(server)) then server = nil end
	if contextData.unit and UnitIsUnit and UnitExists(contextData.unit) and UnitIsUnit(contextData.unit, "player") then return end

	if server == nil or server == "" then
		target = M.addServer(target)
	else
		target = target .. "-" .. server
	end

	target = M.Proper(target, true)

	local text = ""

	if (M.hasGlobalIgnored(M.addServer(target)) > 0) then
		text = L["RCM_4"]
	else
		text = L["RCM_6"]
	end

	root:CreateDivider()
	root:CreateButton(text,
		function(owner, root, contextData)
			M.PSS_AddOrDelIgnore(M.addServer(target))
			M.PSS_PlayersChanged(true)
		end)
end

-----------------------
-- ADDON COMPARTMENT --
-----------------------

if V.wowIsRetail == true and AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon then
	AddonCompartmentFrame:RegisterAddon({
		text = "Pour Social Score",
		icon = "Interface\\Icons\\ui_chat.blp",
		notCheckable = true,
		func = function(button, menuInputData, menu)
			M.PSS_OpenUI()
		end,
	})
end

--------------
-- UI HOOKS --
--------------

-- The Group Finder functions may not exist yet (load-on-demand addon) or at all
-- on some client builds (e.g. WoW Forever).  Hook only what is present, once,
-- and retry when the Group Finder addon loads.
local lfgHooked = false

local function hookLFG()
	if lfgHooked then return true end
	if not (PourSocialScoreDB and M.PSS_Opt("useLFGHacks") == true) then return true end
	if not (C_LFGList and Menu and Menu.ModifyMenu) then return true end

	if type(_G.LFGListSearchEntry_Update) ~= "function"
		or type(_G.LFGListSearchEntry_OnEnter) ~= "function" then
		return false -- not available (yet)
	end

	hooksecurefunc("LFGListSearchEntry_Update", M.PSS_LFG_Update)
	hooksecurefunc("LFGListSearchEntry_OnEnter", M.PSS_LFG_Tooltip)
	Menu.ModifyMenu("MENU_LFG_FRAME_SEARCH_ENTRY", M.PSS_LFG_ApplicantMenu)

	lfgHooked = true
	return true
end

function M.PSS_HookFunctions()
	-- /script Menu.PrintOpenMenuTags()

	if not hookLFG() then
		local waiter = CreateFrame("Frame")
		waiter:RegisterEvent("ADDON_LOADED")
		waiter:SetScript("OnEvent", function(self)
			if hookLFG() then
				self:UnregisterAllEvents()
			end
		end)
	end

	if M.PSS_Opt("useUnitHacks") == true and Menu and Menu.ModifyMenu then
		-- FRIEND is the menu for a name clicked in chat; the COMMUNITIES and
		-- GUILD ones are the guild / community rosters. (Battle.net friend
		-- menus are left alone: they carry a Battle.net name, not a character.)
		for _, tag in ipairs({ "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER",
								"MENU_UNIT_FRIEND", "MENU_UNIT_FRIEND_OFFLINE", "MENU_UNIT_CHAT_ROSTER", "MENU_UNIT_GUILD",
								"MENU_UNIT_COMMUNITIES_GUILD_MEMBER", "MENU_UNIT_COMMUNITIES_MEMBER", "MENU_UNIT_COMMUNITIES_WOW_MEMBER" }) do
			pcall(Menu.ModifyMenu, tag, M.PSS_UnitMenuPlayer)
		end
	end
end
