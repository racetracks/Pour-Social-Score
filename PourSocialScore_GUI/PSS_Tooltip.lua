------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - TOOLTIPS
--
-- Plain text tooltips for the window's controls.
-- Blizzard: GameTooltip (checked with IsForbidden first).
-- Dark: our own frame, built on first use: a dark fill with a faint
-- edge, 10 px text centred, at most 250 wide, 4 above its owner, fading in
-- and out over a quarter second.
--   ns.Tip(owner, text)   ns.HideTip()   ns.TipOn(frame, owner, text)
-- text may be a function returning the text (read when shown), or a table
-- { title, bold, text }: the title, a bold line under it, then the text (the
-- bold line is Blizzard's tooltip header font in GameTooltip, the same in ours).
------------------------------------------------------------------------
local ADDON_NAME, ns = ...

local DARK = ns.DARK
local MAX_W, PAD, FADE = 250, 8, 0.25

local tip, tipText, tipHead, tipBold, fadeIn, fadeOut
local blizzOwner

local function Build()
	tip = CreateFrame("Frame", "PSS_Tooltip", UIParent)
	tip:SetFrameStrata("TOOLTIP")
	tip:SetFrameLevel(200)
	tip:SetClampedToScreen(true)
	tip:Hide()
	ns.Fill(tip, DARK.tip, -6)
	ns.PixelBorder(tip, DARK.tipBorder)
	tipHead = ns.NewText(tip, 11)
	tipHead:SetJustifyH("CENTER")
	tipHead:SetTextColor(1, 1, 1)
	tipBold = ns.NewText(tip, 10, "GameTooltipHeaderText")
	tipBold:SetJustifyH("CENTER")
	tipBold:SetTextColor(DARK.tipText[1], DARK.tipText[2], DARK.tipText[3])
	tipText = ns.NewText(tip, 10)
	tipText:SetPoint("CENTER")
	tipText:SetJustifyH("CENTER")
	tipText:SetSpacing(3)
	tipText:SetTextColor(DARK.tipText[1], DARK.tipText[2], DARK.tipText[3])
	tipText:SetAlpha(DARK.tipText[4])
	fadeIn = tip:CreateAnimationGroup()
	local a = fadeIn:CreateAnimation("Alpha")
	a:SetFromAlpha(0)
	a:SetToAlpha(1)
	a:SetDuration(FADE)
	a:SetSmoothing("OUT")
	fadeIn:SetScript("OnFinished", function() tip:SetAlpha(1) end)
	fadeOut = tip:CreateAnimationGroup()
	local b = fadeOut:CreateAnimation("Alpha")
	b:SetFromAlpha(1)
	b:SetToAlpha(0)
	b:SetDuration(FADE)
	b:SetSmoothing("IN")
	fadeOut:SetScript("OnFinished", function() tip:Hide() end)
end

local function TextOf(text)
	if type(text) == "function" then text = text() end
	return text
end

function ns.Tip(owner, text)
	ns.Fresh()
	text = TextOf(text)
	local rich = type(text) == "table" and text or nil
	if not owner or not text or text == "" then return end
	if not ns.IsDark() then
		if GameTooltip:IsForbidden() then return end
		GameTooltip:SetOwner(owner, "ANCHOR_TOP")
		if rich then
			GameTooltip:SetText(rich.title or "", 1, 1, 1, 1, true)
			if rich.bold then
				GameTooltip:AddLine(rich.bold, 1, 0.82, 0, true)
				-- the bold line: the tooltip's own header font on that one line (read only otherwise)
				local line = _G["GameTooltipTextLeft" .. GameTooltip:NumLines()]
				if line and line.SetFontObject and GameTooltipHeaderText then pcall(line.SetFontObject, line, GameTooltipHeaderText) end
			end
			if rich.text and rich.text ~= "" then GameTooltip:AddLine(rich.text, 0.9, 0.9, 0.9, true) end
		else
			GameTooltip:SetText(text, 1, 1, 1, 1, true)
		end
		GameTooltip:Show()
		blizzOwner = owner
		return
	end
	if not tip then Build() end
	fadeOut:Stop()
	tipText:SetWidth(0)
	tipHead:SetWidth(0)
	tipBold:SetWidth(0)
	tipText:SetText(rich and rich.text or text)
	local w = math.min(tipText:GetStringWidth(), MAX_W - PAD * 2)
	local h = tipText:GetStringHeight()
	tipHead:SetShown(rich ~= nil)
	tipBold:SetShown(rich ~= nil and rich.bold ~= nil)
	tipText:ClearAllPoints()
	if rich then
		tipHead:SetText(rich.title or "")
		tipBold:SetText(rich.bold or "")
		w = math.min(math.max(w, tipHead:GetStringWidth(), tipBold:GetStringWidth()), MAX_W - PAD * 2)
		tipHead:SetWidth(w)
		tipBold:SetWidth(w)
		local top = tipHead:GetStringHeight() + (rich.bold and (tipBold:GetStringHeight() + 4) or 0) + 6
		tipHead:ClearAllPoints()
		tipHead:SetPoint("TOP", tip, "TOP", 0, -PAD)
		tipBold:ClearAllPoints()
		tipBold:SetPoint("TOP", tipHead, "BOTTOM", 0, -2)
		tipText:SetPoint("TOP", tip, "TOP", 0, -PAD - top)
		h = h + top
	else
		tipText:SetPoint("CENTER")
	end
	tipText:SetWidth(w)
	tip:SetSize(w + PAD * 2, h + PAD * 2)
	tip:ClearAllPoints()
	tip:SetPoint("BOTTOM", owner, "TOP", 0, 4)
	if not tip:IsShown() then
		tip:SetAlpha(0)
		tip:Show()
		fadeIn:Play()
	end
end

function ns.HideTip()
	if blizzOwner then
		blizzOwner = nil
		if not GameTooltip:IsForbidden() then GameTooltip:Hide() end
	end
	if tip and tip:IsShown() and not fadeOut:IsPlaying() then
		fadeIn:Stop()
		fadeOut:Play()
	end
end

function ns.TipOn(frame, owner, text)
	frame:SetScript("OnEnter", function() ns.Tip(owner or frame, text) end)
	frame:SetScript("OnLeave", ns.HideTip)
end
