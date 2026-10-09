------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - POPUPS
--
-- The window's own popups, in the look shown, built on first use. One of
-- each; showing one again replaces what it showed.
--   ns.Confirm({ title, text, accept, cancel, onAccept, onCancel })
--     number = a starting number: a number box under the text (onAccept(n));
--     numberNote(n) = the line under it, again as it is typed
--   ns.CopyText({ title, subtitle, text })          read only, selected
--   ns.ImportText({ title, subtitle, accept, onAccept(text) })
-- Classic and Modern: the window's own frame and background
-- (ns.NewFrameArt: the metal frame on its stone, or on black in Modern),
-- Blizzard's buttons (Modern: the red one to accept). Dark: a flat panel
-- with a faint edge over a dimmed screen (a click on it or Escape cancels),
-- the accept button in the accent. Escape cancels in every look.
------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local M = ns.M

local DARK = ns.DARK
local POP_FILL = { 0.077, 0.068, 0.058, 1 }
local POP_EDGE = { 1, 1, 1, 0.15 }
local DIM = { 0, 0, 0, 0.25 }

-- A popup button: the kit's button; Dark gives it a dark fill and an edge,
-- in the accent for the button that accepts.
local function PopupButton(parent, w, h, accept)
	-- Modern: the accepting button is the red one
	local b = ns.NewButton(parent, "", w, nil, accept and true or false)
	b:SetHeight(h)
	ns.OnPaint(function(dark)
		local p = b.pssParts
		if dark then
			p.fill:SetColorTexture(0, 0, 0, 0.5)
			if accept then
				local r, g, bl = ns.Accent()
				p.edge:SetColor(r, g, bl, 0.9)
			else
				p.edge:SetColor(1, 1, 1, 0.5)
			end
			b:SetNormalFontObject(ns.Font(12, accept and "Accent" or "GameFontHighlight"))
		else
			p.fill:SetColorTexture(DARK.control[1], DARK.control[2], DARK.control[3], DARK.control[4])
			p.edge:SetColor(DARK.border[1], DARK.border[2], DARK.border[3], DARK.border[4])
		end
	end)
	return b
end

-- The frame both popups share the build of: Blizzard dialog art or the Dark
-- panel, a title, Escape, and in Dark a dimmed screen behind.
local function Shell(name, w, h)
	local f = CreateFrame("Frame", name, UIParent)
	f:SetSize(w, h)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetFrameLevel(100)
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:Hide()
	-- Classic and Modern: the same frame and background as the window
	-- (Dan, dev011_3: Blizzard's dialog backgrounds were see-through)
	local art = ns.NewFrameArt(f)
	local fill = ns.Fill(f, POP_FILL, -6)
	local edge = ns.PixelBorder(f, POP_EDGE)
	local dim = CreateFrame("Button", nil, f)
	dim:SetAllPoints(UIParent)
	dim:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))
	ns.Fill(dim, DIM, -8)
	dim:SetScript("OnClick", function() f:Hide() end)
	-- The title says what the popup asks (no addon name). It sits on a frame
	-- above the frame art: the Blizzard frame's border (its NineSlice) has a
	-- fixed level of about 500 and hid it (as the window's own title,
	-- PSS_Window.lua). Classic and Modern: in the title bar, as the window's;
	-- Dark: larger, lower on the flat panel.
	local chrome = CreateFrame("Frame", nil, f)
	chrome:SetAllPoints(f)
	local top = f:GetFrameLevel() + 8
	if art and art.NineSlice and art.NineSlice.GetFrameLevel then
		top = math.max(top, art.NineSlice:GetFrameLevel() + 10)
	end
	chrome:SetFrameLevel(top)
	f.title = ns.NewText(chrome, 16, "GameFontNormalLarge")
	f.pssParts = { fill = fill, edge = edge, art = art, dim = dim }
	ns.OnPaint(function(dark)
		local ours = dark or not art
		fill:SetShown(ours)
		edge:SetShown(ours)
		dim:SetShown(dark)
		if art then art:SetShown(not ours) end
		f.title:SetFontObject(ours and ns.Font(16, "GameFontNormalLarge") or ns.Font(13, "GameFontNormal"))
		f.title:ClearAllPoints()
		f.title:SetPoint("TOP", f, "TOP", 0, ours and -20 or -6)
	end)
	return f
end

------------------------------------------------------------------------
-- Confirm
------------------------------------------------------------------------
local confirm, confirmOpts

local function BuildConfirm()
	confirm = Shell("PSS_Confirm", 390, 176)
	confirm.text = ns.NewText(confirm, 12)
	confirm.text:SetPoint("TOP", confirm, "TOP", 0, -46)
	confirm.text:SetWidth(330)
	confirm.text:SetJustifyH("CENTER")
	confirm.text:SetSpacing(4)
	confirm.text:SetWordWrap(true)
	-- the number box (opts.number) and its note
	confirm.number = ns.NewNumberBox(confirm, 70)
	confirm.number:SetPoint("TOP", confirm.text, "BOTTOM", 0, -10)
	confirm.number:Hide()
	confirm.note = ns.NewText(confirm, 11)
	confirm.note:SetPoint("TOP", confirm.number, "BOTTOM", 0, -6)
	confirm.note:SetAlpha(0.7)
	confirm.note:Hide()
	confirm.number:SetScript("OnTextChanged", function(self)
		local o = confirmOpts
		if o and o.numberNote then confirm.note:SetText(o.numberNote(tonumber(self:GetText()))) end
	end)
	confirm.number:SetScript("OnEscapePressed", function() confirm:Hide() end)
	confirm.accept = PopupButton(confirm, 125, 27, true)
	confirm.cancel = PopupButton(confirm, 125, 27, false)
	confirm.accept:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -8, 13)
	confirm.cancel:SetPoint("BOTTOMLEFT", confirm, "BOTTOM", 8, 13)
	local function Accept()
		local o = confirmOpts
		confirmOpts = nil
		local n = o and o.number ~= nil and tonumber(confirm.number:GetText()) or nil
		confirm:Hide()
		if o and o.onAccept then o.onAccept(n) end
	end
	confirm.accept:SetScript("OnClick", Accept)
	confirm.number:SetScript("OnEnterPressed", Accept)
	confirm.cancel:SetScript("OnClick", function() confirm:Hide() end)
	-- hidden any other way (Cancel, Escape, a click on the dimmed screen,
	-- another popup) is a cancel
	confirm:SetScript("OnHide", function()
		local o = confirmOpts
		confirmOpts = nil
		if o and o.onCancel then o.onCancel() end
	end)
	ns.EscapeCloses(confirm, "PSS_Confirm")	-- after its OnHide (SetScript drops hooks)
	ns.OnPaint(function(dark)
		confirm.text:SetTextColor(1, 1, 1)
		confirm.text:SetAlpha(dark and 0.53 or 1)
	end)
end

function ns.Confirm(opts)
	if not confirm then BuildConfirm() end
	if confirm:IsShown() then confirm:Hide() end
	confirmOpts = opts
	confirm.title:SetText(opts.title or "")
	confirm.text:SetText(opts.text or "")
	confirm.accept:SetText(opts.accept or OKAY or "Okay")
	confirm.cancel:SetText(opts.cancel or CANCEL or "Cancel")
	local withNumber = opts.number ~= nil
	confirm.number:SetShown(withNumber)
	confirm.note:SetShown(withNumber)
	if withNumber then
		confirm.number:SetText(tostring(opts.number))
		confirm.note:SetText(opts.numberNote and opts.numberNote(tonumber(opts.number)) or "")
	end
	-- grows with a long message (and the number box)
	local over = math.max(0, confirm.text:GetStringHeight() - 44)
	confirm:SetHeight(176 + over + (withNumber and 52 or 0))
	confirm:Show()
	confirm:Raise()
	if withNumber then confirm.number:SetFocus() end
	return confirm
end

------------------------------------------------------------------------
-- Copy and import: one text popup
------------------------------------------------------------------------
local textPop, textOpts

local function BuildText()
	local f = Shell("PSS_TextPopup", 520, 310)
	textPop = f
	f.subtitle = ns.NewText(f, 11)
	f.subtitle:SetPoint("TOP", f, "TOP", 0, -40)
	f.subtitle:SetTextColor(1, 1, 1)
	f.subtitle:SetAlpha(0.45)
	local box = ns.NewTextArea(f, 11, nil, 6)
	box:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -58)
	box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 52)
	local eb = box.edit
	eb:SetScript("OnEscapePressed", function() f:Hide() end)
	-- copy: the text stays as given, all of it selected
	eb:SetScript("OnTextChanged", function(self, user)
		if user and textOpts and textOpts.readOnly then
			self:SetText(textOpts.text or "")
			self:HighlightText()
		end
	end)
	f.edit = eb
	f.accept = PopupButton(f, 120, 26, true)
	f.close = PopupButton(f, 120, 26, false)
	f.accept:SetScript("OnClick", function()
		local o = textOpts
		local text = eb:GetText() or ""
		textOpts = nil
		f:Hide()
		if o and o.onAccept then o.onAccept(text) end
	end)
	f.close:SetScript("OnClick", function() f:Hide() end)
	f:SetScript("OnHide", function()
		textOpts = nil
		eb:SetText("")
		eb:ClearFocus()
	end)
	ns.EscapeCloses(f, "PSS_TextPopup")
end

local function ShowText(opts, readOnly)
	if not textPop then BuildText() end
	if textPop:IsShown() then textPop:Hide() end
	opts.readOnly = readOnly
	textOpts = opts
	local f = textPop
	f.title:SetText(opts.title or "")
	f.subtitle:SetText(opts.subtitle or "")
	f.edit:SetText(opts.text or "")
	f.accept:ClearAllPoints()
	f.close:ClearAllPoints()
	if readOnly then
		f.accept:Hide()
		f.close:SetText(CLOSE or "Close")
		f.close:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
	else
		f.accept:Show()
		f.accept:SetText(opts.accept or "Import")
		f.close:SetText(CANCEL or "Cancel")
		f.accept:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, 14)
		f.close:SetPoint("BOTTOMLEFT", f, "BOTTOM", 4, 14)
	end
	f:Show()
	f:Raise()
	f.edit:SetFocus()
	if readOnly then f.edit:HighlightText() end
	return f
end

function ns.CopyText(opts) return ShowText(opts, true) end

-- /pss export unused (Libraries PSS_Commands.lua): the copy box on its own
function M.PSS_CopyTextBox(title, subtitle, text)
	return ns.CopyText({ title = title, subtitle = subtitle, text = text })
end
function ns.ImportText(opts) return ShowText(opts, false) end
