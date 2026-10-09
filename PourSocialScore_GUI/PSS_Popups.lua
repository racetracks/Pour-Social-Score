------------------------------------------------------------------------
-- POUR SOCIAL SCORE UI - POPUPS
--
-- The window's own popups, in the look shown, built on first use. One of
-- each; showing one again replaces what it showed.
--   ns.Confirm({ title, text, accept, cancel, onAccept, onCancel })
--     number = a starting number: a number box under the text (onAccept(n));
--     numberNote(n) = the line under it, again as it is typed
--     timeout = seconds: the cancel button reads "<cancel> (<n>)" and counts
--     down; at 0 the popup hides and onTimeout() runs (not onCancel). The
--     count is an OnUpdate on the popup only while a timed one shows
--   ns.GfxPopup()  the graphics settings popup (Export, Import, History,
--     Reload UI; /pss gfx on Camelot): every button is a call into
--     Libraries (PSS_Graphics.lua); M.PSS_GfxBox() shows it and
--     M.PSS_GfxKeepPrompt() is the timed keep prompt after a reload
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
		confirm:SetScript("OnUpdate", nil)	-- the countdown runs only while shown
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

-- The timed prompt's countdown (opts.timeout): the cancel button's text
-- each whole second; at 0 the popup hides (confirmOpts cleared first, so
-- OnHide does not also run onCancel) and onTimeout runs. Set as the
-- frame's OnUpdate only while a timed popup shows.
local function Countdown(opts, left)
	local cancel = opts.cancel or CANCEL or "Cancel"
	local shown = -1
	return function(self, elapsed)
		left = left - (elapsed or 0)
		if left <= 0 then
			local o = confirmOpts
			confirmOpts = nil
			confirm:Hide()
			if o and o.onTimeout then o.onTimeout() end
			return
		end
		local n = math.ceil(left)
		if n ~= shown then
			shown = n
			confirm.cancel:SetText(cancel .. " (" .. n .. ")")
		end
	end
end

function ns.Confirm(opts)
	if not confirm then BuildConfirm() end
	if confirm:IsShown() then confirm:Hide() end
	confirmOpts = opts
	confirm.title:SetText(opts.title or "")
	confirm.text:SetText(opts.text or "")
	confirm.accept:SetText(opts.accept or OKAY or "Okay")
	if opts.timeout then
		confirm.cancel:SetText((opts.cancel or CANCEL or "Cancel") .. " (" .. math.ceil(opts.timeout) .. ")")
		confirm:SetScript("OnUpdate", Countdown(opts, opts.timeout))
	else
		confirm.cancel:SetText(opts.cancel or CANCEL or "Cancel")
	end
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

------------------------------------------------------------------------
-- Graphics settings (/pss gfx, Camelot): every button is a call into
-- PSS_Graphics.lua (Libraries); this only draws. Built on first use.
-- Export, Import, History and Reload UI along the bottom; History swaps
-- the box for the saved sets (a row click shows what changed, Restore,
-- Export and Back).
------------------------------------------------------------------------
local gfx, gfxRead, gfxRows, gfxPick

-- the line under the title (a message from Libraries or a hint)
local function GfxSay(text)
	if gfx then gfx.subtitle:SetText(text or "") end
end

-- the preview of a plan, then Apply (Import and Restore share it)
local function GfxPreview(plan, why)
	if not plan then GfxSay(why) return end
	if #plan.changes == 0 then GfxSay(M.PSS_GfxSummary(plan)) return end
	ns.Confirm({
		title = "Apply Graphics Settings?",
		text = M.PSS_GfxSummary(plan),
		accept = "Apply",
		onAccept = function()
			local ok, msg = M.PSS_GfxApply(plan)
			if not ok then GfxSay(msg) end
		end,
	})
end

-- the text box: editable for a paste, read only (all selected) for a result
local function GfxBoxText(text, readOnly)
	gfxRead = readOnly and text or nil
	gfx.edit:SetText(text or "")
	if readOnly then gfx.edit:HighlightText() end
end

-- the History view or the main view
local function GfxHistoryView(on)
	local f = gfx
	f.histOn = on
	f.listFrame:SetShown(on)
	f.export:SetShown(not on)
	f.import:SetShown(not on)
	f.history:SetShown(not on)
	f.reload:SetShown(not on)
	f.restore:SetShown(on)
	f.hexport:SetShown(on)
	f.back:SetShown(on)
	f.box:ClearAllPoints()
	f.box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 52)
	f.box:SetPoint("TOPLEFT", f, "TOPLEFT", 20, on and -176 or -58)
	gfxPick = nil
	f.restore:Disable()
	f.hexport:Disable()
	GfxBoxText("", on)
	if on then
		gfxRows = M.PSS_GfxHistory()
		f.list:SetCount(#gfxRows)
		f.list:Top()
		f.list:Select(function() return false end)
		GfxSay(#gfxRows > 0 and "Pick a saved set to see what changed" or "")
	else
		gfxRows = nil
		f.list:SetCount(0)
		GfxSay("Export, paste a set to Import, or restore an earlier one")
	end
end

local function BuildGfx()
	local f = Shell("PSS_GfxPopup", 560, 340)
	gfx = f
	f.subtitle = ns.NewText(f, 11)
	f.subtitle:SetPoint("TOP", f, "TOP", 0, -40)
	f.subtitle:SetTextColor(1, 1, 1)
	f.subtitle:SetAlpha(0.45)
	f.box = ns.NewTextArea(f, 11, nil, 6)
	f.edit = f.box.edit
	f.edit:SetScript("OnEscapePressed", function() f:Hide() end)
	-- a result stays as given, all of it selected
	f.edit:SetScript("OnTextChanged", function(self, user)
		if user and gfxRead then
			self:SetText(gfxRead)
			self:HighlightText()
		end
	end)

	-- History: the saved sets above the box
	f.listFrame = CreateFrame("Frame", nil, f)
	f.listFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -58)
	f.listFrame:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -58)
	f.listFrame:SetHeight(110)
	f.listFrame:Hide()
	f.list = ns.NewRows(f.listFrame, {
		rowH = 18, fontSize = 11, height = 80,
		cols = { { key = "when", text = "When", width = 150, sort = false },
			{ key = "changed", text = "Changed", width = 80, sort = false } },
		draw = function(row, i)
			local r = gfxRows and gfxRows[i]
			row.cells.when:SetText(r and r.whenText or "")
			row.cells.changed:SetText(r and tostring(r.changed) or "")
		end,
		click = function(row, i)
			local r = gfxRows and gfxRows[i]
			if not r then return end
			gfxPick = r.i
			f.list:Select(function(n) return n == i end)
			f.restore:Enable()
			f.hexport:Enable()
			GfxBoxText(M.PSS_GfxSetDiff(r.i), true)
		end,
	})
	f.list:SetEmptyText("No saved sets yet")

	f.export = PopupButton(f, 120, 26, false)
	f.import = PopupButton(f, 120, 26, true)
	f.history = PopupButton(f, 120, 26, false)
	f.reload = PopupButton(f, 120, 26, false)
	f.restore = PopupButton(f, 120, 26, true)
	f.hexport = PopupButton(f, 120, 26, false)
	f.back = PopupButton(f, 120, 26, false)
	f.export:SetText("Export")
	f.import:SetText("Import")
	f.history:SetText("History")
	f.reload:SetText("Reload UI")
	f.restore:SetText("Restore")
	f.hexport:SetText("Export")
	f.back:SetText("Back")
	-- one row along the bottom: four buttons, or Restore / Export / Back
	f.export:SetPoint("BOTTOM", f, "BOTTOM", -192, 14)
	f.import:SetPoint("LEFT", f.export, "RIGHT", 8, 0)
	f.history:SetPoint("LEFT", f.import, "RIGHT", 8, 0)
	f.reload:SetPoint("LEFT", f.history, "RIGHT", 8, 0)
	f.restore:SetPoint("BOTTOM", f, "BOTTOM", -128, 14)
	f.hexport:SetPoint("LEFT", f.restore, "RIGHT", 8, 0)
	f.back:SetPoint("LEFT", f.hexport, "RIGHT", 8, 0)
	f.restore:Hide()
	f.hexport:Hide()
	f.back:Hide()

	f.export:SetScript("OnClick", function()
		local text, n = M.PSS_GfxExportText()
		if not text then GfxSay(n) return end
		GfxBoxText(text, true)
		f.edit:SetFocus()
		GfxSay(n .. " settings")
	end)
	f.import:SetScript("OnClick", function()
		gfxRead = nil
		GfxPreview(M.PSS_GfxParse(f.edit:GetText() or ""))
	end)
	f.history:SetScript("OnClick", function() GfxHistoryView(true) end)
	f.reload:SetScript("OnClick", function() M.PSS_GfxReload() end)
	f.restore:SetScript("OnClick", function()
		if gfxPick then GfxPreview(M.PSS_GfxRestorePlan(gfxPick)) end
	end)
	f.hexport:SetScript("OnClick", function()
		if not gfxPick then return end
		local text, n = M.PSS_GfxExportText(gfxPick)
		if not text then GfxSay(n) return end
		GfxBoxText(text, true)
		f.edit:SetFocus()
		GfxSay(n .. " settings")
	end)
	f.back:SetScript("OnClick", function() GfxHistoryView(false) end)

	f:SetScript("OnHide", function()
		gfxRead, gfxRows, gfxPick = nil, nil, nil
		f.edit:SetText("")
		f.edit:ClearFocus()
		f.list:SetCount(0)
		if f.histOn then GfxHistoryView(false) end
		if M.PSS_RequestGC then M.PSS_RequestGC("graphics closed") end
	end)
	ns.EscapeCloses(f, "PSS_GfxPopup")	-- after its OnHide (SetScript drops hooks)
	f.title:SetText("Graphics Settings")
	GfxHistoryView(false)
	return f
end

function ns.GfxPopup()
	if not gfx then BuildGfx() end
	return gfx
end

-- the entries Libraries calls (PSS_Graphics.lua): the popup, and the keep
-- prompt after a reload with a change waiting
function M.PSS_GfxBox()
	local f = ns.GfxPopup()
	if f.histOn then GfxHistoryView(false) end
	GfxBoxText("", false)
	GfxSay("Export, paste a set to Import, or restore an earlier one")
	f:Show()
	f:Raise()
	return f
end

function M.PSS_GfxKeepPrompt()
	return ns.Confirm(M.PSS_GfxKeepSpec())
end
