------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PSS DROP CHEAPEST THING: acting, starting, the
-- button (money-helper, DDS-00009 sections 2, 3, 8, 10). Destroys (or, at
-- a merchant, sells) the cheapest candidate, one item per call, only from
-- a click, a key or /pss dtt, out of combat. Loaded only while the feature
-- is on.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
if not M.PSS_On("dtt") then return end

local C_Container = C_Container
local InCombatLockdown = InCombatLockdown
local tostring, tonumber, type, pcall = tostring, tonumber, type, pcall

local DEFAULT_ICON = 133634		-- Interface\Icons\INV_Misc_Bag_22 (the bag picture)

local actSet = { cols = { "bag" }, n = 1, { 0 } }		-- the one-row key set, the reused out and the use opts
local actOut = {}
local actOpts, actUse = { out = actOut }, { slot = 0 }

local function Money(copper)
	if GetMoneyString then return GetMoneyString(copper or 0, true) end
	return tostring(copper or 0) .. "c"
end
M.PSS_DttMoney = Money

local function CursorBusy()
	if CursorHasItem then return CursorHasItem() end
	return GetCursorInfo ~= nil and GetCursorInfo() ~= nil
end

local function Say(verb, l, count, copper, ic)
	local tex = ic and ("|T" .. tostring(ic) .. ":0|t ") or ""
	M.ShowMsg(("%s %s%s%s (%s)"):format(verb, tex, l, count > 1 and (" x" .. count) or "", Money(copper)))
end

-- Act on one item. mode: "auto" (sell at a merchant, else destroy), "drop",
-- "sell". bagslot and link (default the cheapest): the pair a scan or list
-- gave; the slot is re-read first and a different item or count is refused
-- (DEC-00116). Returns ok, reason, link, value. quiet: no chat line.
function M.PSS_DttAct(mode, bagslot, l, quiet)
	local merchant = M.PSS_DttAtMerchant()
	if mode == nil or mode == "auto" then mode = merchant and "sell" or "drop" end
	local function Fail(reason)
		if not quiet then M.ShowMsg(reason) end
		return false, reason
	end
	if InCombatLockdown() then return Fail("Not in combat.") end
	if CursorBusy() then return Fail("Put down the item on your cursor first.") end
	if mode == "sell" and not merchant then return Fail("Open a merchant window to sell.") end
	local want, wantCount
	if not bagslot then
		M.PSS_DttScan(mode)
		bagslot = M.PSS_DttList(1)[1]
		if not bagslot then
			return Fail(mode == "sell" and "Nothing to sell." or "Nothing to destroy.")
		end
		local ll, cc = M.PSS_DttSlot(bagslot)
		l, want, wantCount = ll, tonumber(tostring(ll):match("item:(%d+)")), cc
	else
		want = tonumber(tostring(l):match("item:(%d+)"))
	end
	local bag, slot = math.floor(bagslot / 100), bagslot % 100
	actSet[1][1] = bag
	M.PSS_Call("compat.containers.read", actSet, actOpts)
	local info = actOut[slot] or nil
	if not info or info.itemID ~= want or (wantCount and info.stackCount ~= wantCount) then
		return Fail("The slot changed; try again.")
	end
	if not M.PSS_DttIsJunk(bag, slot, mode) then return Fail("That item is not junk by your settings.") end
	local count = info.stackCount or 1
	local _, _, _, _, _, _, _, _, _, ic, sell = (C_Item and C_Item.GetItemInfo or GetItemInfo)(info.hyperlink)
	local value = (sell or 0) * count
	if mode == "sell" then
		actUse.slot = slot
		M.PSS_Call("compat.containers.use", actSet, actUse)
	else
		actUse.slot = slot
		M.PSS_Call("compat.containers.pickup", actSet, actUse)
		if CursorBusy() and DeleteCursorItem then
			DeleteCursorItem()
		end
		if CursorBusy() then
			if ClearCursor then ClearCursor() end
			return Fail("The client did not let the item go.")
		end
	end
	M.PSS_History.Act(mode == "sell" and "DTT_SELL" or "DTT_DROP", want .. "," .. count .. "," .. value)
	M.Events.Fire("DTT_ACTED", mode, info.hyperlink, count, value)
	if not quiet then Say(mode == "sell" and "Sold" or "Destroyed", info.hyperlink, count, value, info.iconFileID or ic) end
	return true, nil, info.hyperlink, value
end

------------------------------------------------------------------------
-- Starting: the button and the events, only while they are wanted
------------------------------------------------------------------------
local frame, button, dirty, unknownWait, routeWait
local EV = {}

local function Rescan()
	if M.PSS_SavedReady and not M.PSS_SavedReady() then		-- ADDON_LOADED: the saved data is routed at login, and a scan reads the entity row
		routeWait = true
		frame:RegisterEvent("PLAYER_ENTERING_WORLD")
		return
	end
	if InCombatLockdown() then
		dirty = true
		frame:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end
	dirty = false
	frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
	M.PSS_DttScan()
	if M.PSS_DttMerchantRefresh then M.PSS_DttMerchantRefresh() end
	if M.PSS_DttMissing() then
		unknownWait = true
		frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	elseif unknownWait then
		unknownWait = false
		frame:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
	end
end
EV.BAG_UPDATE_DELAYED = Rescan
EV.PLAYER_ENTERING_WORLD = function()
	frame:UnregisterEvent("PLAYER_ENTERING_WORLD")
	if routeWait then routeWait = false; Rescan() end
end
EV.PLAYER_REGEN_ENABLED = function() if dirty then Rescan() end end
EV.GET_ITEM_INFO_RECEIVED = function() if unknownWait then Rescan() end end

local function Tip(tt)
	M.PSS_DttScan()
	local list = M.PSS_DttList(5)
	if #list == 0 then
		tt:AddLine("Nothing to destroy.", 0.7, 0.7, 0.7)
	else
		for _, bs in ipairs(list) do
			local l, c, v, ic = M.PSS_DttSlot(bs)
			tt:AddDoubleLine(("|T%s:14|t %s%s"):format(tostring(ic or DEFAULT_ICON), l, c > 1 and (" x" .. c) or ""), Money(v), 1, 1, 1, 1, 1, 1)
		end
		local n, _, total = M.PSS_DttScan()
		tt:AddLine(("%d items, %s"):format(n, Money(total)), 0.7, 0.7, 0.7)
	end
	tt:AddLine("Shift-click: destroy or sell the cheapest. Right-click: options. Ctrl-right-click: the never list.", 0.5, 0.8, 1, true)
end

local function Button()
	if button then return button end
	button = M.PSS_MapButton({
		key = "dtt", icon = DEFAULT_ICON, title = "PSS Drop Cheapest Thing", tip = Tip,
		clicks = {
			ShiftLeftButton = function() M.PSS_DttAct("auto") end,
			RightButton = function() M.PSS_SlashPSS("dtt options") end,
			CtrlRightButton = function() M.PSS_SlashPSS("dtt options") end,
		},
	})
	return button
end

local function SyncButton()
	if not frame then return end
	if M.PSS_Opt("dttIcon") then
		Button():Show()
		frame:RegisterEvent("BAG_UPDATE_DELAYED")
		Rescan()
	else
		if button then button:Hide() end
		frame:UnregisterEvent("BAG_UPDATE_DELAYED")
		frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
		frame:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
		dirty, unknownWait, routeWait = false, false, false
		frame:UnregisterEvent("PLAYER_ENTERING_WORLD")
		M.PSS_DttClearCaches()
	end
end

-- the button's picture follows the cheapest item
M.Events.Register("DTT_CHANGED", function(n, total, ic)
	if button then button:SetIcon(ic or DEFAULT_ICON) end
end)

-- called once by core's login line, only while the feature is on
function M.PSS_DttStart()
	if frame then return end
	frame = CreateFrame("Frame", "PSS_DttFrame")
	frame:SetScript("OnEvent", function(_, event, ...)
		local f = EV[event]
		if f then f(...) elseif M.PSS_DttMerchantEvent then M.PSS_DttMerchantEvent(event, ...) end
	end)
	M.PSS_DttFrame = frame
	SyncButton()
	if M.PSS_DttMerchantSync then M.PSS_DttMerchantSync() end
	if M.PSS_DttBaganator then M.PSS_DttBaganator() end
	M.Events.Register("OPTION_CHANGED", function(key)
		if type(key) ~= "string" or key:sub(1, 3) ~= "dtt" then return end
		if key == "dttIcon" then SyncButton()
		elseif key == "dttMerchantButton" then
			if M.PSS_DttMerchantSync then M.PSS_DttMerchantSync() end
		elseif button and button:IsShown() then Rescan() end
	end)
end
