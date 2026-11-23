------------------------------------------------------------------------
-- POUR SOCIAL SCORE - PSS DROP CHEAPEST THING: the merchant sell button
-- (money-helper, DEC-00112, DDS-00009 section 4.1). Opt-in twice: the
-- feature on and dttMerchantButton ticked. Built at the first MERCHANT_SHOW
-- after that, our own frame on MerchantFrame (not protected), tabs watched
-- with HookScript, never EventRegistry. Sells only on a click.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
if not M.PSS_On("dtt") then return end

local CAUTIOUS = 12
local button, hooked, active

local function Refresh()
	if not (button and active) then return end
	local tab = MerchantFrame and MerchantFrame.selectedTab or 1
	button:SetShown(tab == 1)
	local n = M.PSS_DttScan("sell")
	button:SetEnabled(n > 0)
end
M.PSS_DttMerchantRefresh = function() if active and button and button:IsShown() then Refresh() end end

local function Click()
	local limit = M.PSS_Opt("dttCautious") and CAUTIOUS or 9999
	M.PSS_DttScan("sell")
	local sold, copper = 0, 0
	for _, bs in ipairs(M.PSS_DttList(limit)) do
		local l = M.PSS_DttSlot(bs)
		local ok, _, _, v = M.PSS_DttAct("sell", bs, l, true)
		if not ok then break end
		sold, copper = sold + 1, copper + (v or 0)
	end
	if sold > 0 then
		M.ShowMsg(("Sold %d item%s (%s)."):format(sold, sold == 1 and "" or "s", M.PSS_DttMoney(copper)))
	else
		M.ShowMsg("Nothing to sell.")
	end
	button:SetEnabled(false)		-- until the next bag update
end

local function Build()
	if button or not MerchantFrame then return end
	button = CreateFrame("Button", "PSS_DttSellButton", MerchantFrame, M.PSS_CompatTemplate("button"))
	button:SetSize(80, 22)
	button:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 70, -28)
	button:SetText("Sell junk")
	button:SetScript("OnClick", Click)
	button:SetScript("OnEnter", function(self)
		if GameTooltip:IsForbidden() then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local n, _, total = M.PSS_DttScan("sell")
		GameTooltip:AddLine("PSS Drop Cheapest Thing")
		GameTooltip:AddLine(n > 0 and ("Sells %d items for %s%s"):format(n, M.PSS_DttMoney(total),
			(M.PSS_Opt("dttCautious") and n > CAUTIOUS) and (", " .. CAUTIOUS .. " at a time") or "") or "Nothing to sell.", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() if not GameTooltip:IsForbidden() then GameTooltip:Hide() end end)
	if not hooked then
		hooked = true
		for i = 1, 2 do
			local tab = _G["MerchantFrameTab" .. i]
			if tab and tab.HookScript then tab:HookScript("OnClick", function() if active then Refresh() end end) end
		end
	end
end

-- the events this module needs, only while it is wanted (ticked)
function M.PSS_DttMerchantSync()
	local f = M.PSS_DttFrame
	if not f then return end
	active = M.PSS_Opt("dttMerchantButton") == true
	if active then
		f:RegisterEvent("MERCHANT_SHOW")
	else
		f:UnregisterEvent("MERCHANT_SHOW")
		if not M.PSS_Opt("dttIcon") then f:UnregisterEvent("BAG_UPDATE_DELAYED") end
		if button then button:Hide() end
	end
end

function M.PSS_DttMerchantEvent(event)
	if event == "MERCHANT_SHOW" and active then
		Build()
		local f = M.PSS_DttFrame
		if f then f:RegisterEvent("BAG_UPDATE_DELAYED") end
		Refresh()
	end
end
