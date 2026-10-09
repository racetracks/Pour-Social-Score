------------------------------------------------------------------------
-- POUR SOCIAL SCORE - MEMORY / GARBAGE COLLECTION
--
-- WoW's Lua heap is shared by every addon and collected incrementally by the
-- game. A full collectgarbage("collect") stops the whole UI for as long as
-- it takes (a visible hitch), so Pour Social Score NEVER calls it.
--
-- Instead, when there is something to clean up, it adds small incremental
-- collection steps - collectgarbage("step") - spread over many frames:
--   * only when asked for (after login, a /who scan, an import, closing the
--     window ...). There is no timer, no idle cycle and no wall-clock gate
--     (3.4.1.52; baseline 02 C15).
--   * never in combat, in a boss encounter, while the player is dead, or
--     inside a dungeon, raid, battleground or arena (asked from the game
--     with IsInInstance, no list of places); a step cycle stops the moment
--     any of these starts
--   * a request made at a bad moment waits for an event that can end it
--     (PLAYER_REGEN_ENABLED, PLAYER_ENTERING_WORLD, ZONE_CHANGED_NEW_AREA,
--     PLAYER_ALIVE, PLAYER_UNGHOST). Those events are registered only
--     while a request is waiting.
--   * at most STEP_BUDGET_MS per frame (less when the frame rate is low)
--   * not at all below MIN_FPS
--   * no heap-growth cycles and nothing more often (2.0.38). The game's own
--     collector already runs in the background every frame, and the heap
--     grows with every addon's garbage, not just ours. A cycle here walks
--     the WHOLE shared heap, and one step cannot split a big table, so each
--     cycle costs one long frame (measured 9 ms on a 150 MB heap, 19 ms on
--     300 MB) plus seconds of ~1 ms frames.
-- Options > "Background memory cleanup (out of combat)" turns it off.
------------------------------------------------------------------------
local addonName, addon = ...
local M = addon.M

local STEP_KB			= 8			-- size of one collector step (small: fine-grained budget)
local STEP_BUDGET_MS	= 1.0		-- max time per frame
local MIN_FPS			= 30
local MAX_FRAMES		= 900		-- pause a cycle after this many frames (it resumes)

local gc = { pending = false, running = false, lastCycle = 0, heapAfter = nil, waiting = false, supported = true, frames = 0,
			cycles = 0, lastReason = nil, lastMs = 0 }
M.PSS_GCState = gc

local function enabled()
	return not (M.PSS_Opt and M.PSS_Opt("gcEnabled") == false)
end

-- Why a cleanup can't run now (nil = it can). Shown by /pss mem.
local function busyReason()
	if InCombatLockdown and InCombatLockdown() then return "in combat" end
	if UnitAffectingCombat and UnitAffectingCombat("player") then return "in combat" end
	if IsEncounterInProgress and IsEncounterInProgress() then return "boss encounter" end
	if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return "dead" end
	-- dungeon, raid, battleground or arena (the game says which; "scenario"
	-- and the open world are allowed)
	if IsInInstance then
		local inside, kind = IsInInstance()
		if inside and (kind == "party" or kind == "raid" or kind == "pvp" or kind == "arena") then return "in a dungeon, raid or battleground" end
	end
	return nil
end

local function inCombatOrBusy()
	return busyReason() ~= nil
end

local function heapKB()
	local ok, kb = pcall(collectgarbage, "count")
	return ok and kb or 0
end

local runner = CreateFrame("Frame")
runner:Hide()

local function stopCycle(completed)
	runner:Hide()
	gc.running = false
	if completed then
		gc.pending = false
		gc.lastCycle = GetTime()
		gc.heapAfter = heapKB()
		gc.cycles = gc.cycles + 1
	end
end

runner:SetScript("OnUpdate", function(self, elapsed)
	if not gc.running then self:Hide() return end
	if inCombatOrBusy() or not enabled() then
		stopCycle(false)
		if enabled() then gc.pending = true; M.PSS_GCWatch(true) end		-- resumes at the next wake event
		return
	end
	-- frame budget: never more than STEP_BUDGET_MS, and a smaller share of a
	-- slow frame (5 % of the last frame time)
	local fps = GetFramerate and GetFramerate() or 60
	if fps < MIN_FPS then return end		-- wait for a calmer moment
	-- a long cycle (big heap, or a high frame rate's small budget) pauses
	-- and carries on at the next wake event; the collector keeps its place.
	-- Only a finished cycle counts as done (before 2.0.40 hitting this cap,
	-- or waiting out a low frame rate, counted as a finished cleanup).
	gc.frames = gc.frames + 1
	if gc.frames > MAX_FRAMES then stopCycle(false); gc.pending = true; M.PSS_GCWatch(true) return end
	local budget = math.min(STEP_BUDGET_MS, (elapsed or 0.016) * 1000 * 0.05)
	local clock = debugprofilestop
	local start = clock and clock() or 0
	repeat
		local ok, done = pcall(collectgarbage, "step", STEP_KB)
		if not ok then gc.supported = false; stopCycle(false) return end
		if done then
			gc.lastMs = (clock and (clock() - start)) or 0
			stopCycle(true)
			return
		end
	until not clock or (clock() - start) >= budget
end)

local function startCycle(reason)
	if gc.running or not gc.supported or not enabled() or inCombatOrBusy() then return false end
	gc.running = true
	gc.frames = 0
	gc.lastReason = reason
	gc.pending = false
	M.PSS_GCWatch(false)
	runner:Show()
	return true
end

-- The wake events, registered only while a request waits for a safe moment.
local wake = CreateFrame("Frame")
local WAKE_EVENTS = { "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_ALIVE", "PLAYER_UNGHOST" }
function M.PSS_GCWatch(on)
	if on == gc.waiting then return end
	gc.waiting = on
	for i = 1, #WAKE_EVENTS do
		if on then wake:RegisterEvent(WAKE_EVENTS[i]) else wake:UnregisterEvent(WAKE_EVENTS[i]) end
	end
end
wake:SetScript("OnEvent", function()
	if not gc.pending then M.PSS_GCWatch(false) return end
	if gc.running or not gc.supported then return end
	if not enabled() then gc.pending = false; M.PSS_GCWatch(false) return end		-- switched off while waiting
	startCycle(gc.lastReason)		-- still busy: stays registered for the next event
end)

-- Ask for a cleanup: it starts now when the moment is safe, else at the next
-- wake event.
function M.PSS_RequestGC(reason)
	gc.pending = true
	gc.lastReason = reason or gc.lastReason
	if gc.running or not gc.supported or not enabled() then return end
	if not startCycle(gc.lastReason) then M.PSS_GCWatch(true) end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_LOGIN")
	gc.lastCycle = GetTime()
	gc.heapAfter = heapKB()
	-- loading is over; tidy up once things have settled
	M.PSS_RequestGC("login")
end)

------------------------------------------------------------------------
-- /pss mem [full] - what Pour Social Score is holding in memory.
-- Numbers marked ~ are estimates (Lua cannot measure one table exactly);
-- "addon memory" is the game's own figure for the whole addon.
------------------------------------------------------------------------
local function kb(bytes) return ("%.0f KB"):format((bytes or 0) / 1024) end

function M.PSS_MemReport(full)
	local out = function(s) if M.ShowMsg then M.ShowMsg(s) else print(s) end end
	local db = PourSocialScoreDB
	if type(db) ~= "table" then out("Pour Social Score: not loaded yet.") return end
	local H = M.PSS_History

	out("|cffff99ffPour Social Score memory|r")
	if M.PSS_UpgradeText then out("  saved data upgrade: " .. M.PSS_UpgradeText()) end

	-- the game's figure for this addon (walks every addon: not in combat)
	local addonKB
	local inCombat = InCombatLockdown and InCombatLockdown()
	local getMem = GetAddOnMemoryUsage or (C_AddOns and C_AddOns.GetAddOnMemoryUsage)
	local updMem = UpdateAddOnMemoryUsage or (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage)
	if not inCombat and updMem and getMem then
		pcall(updMem)
		local ok, v = pcall(getMem, addonName)
		if ok then addonKB = v end
	end
	out(("  addon memory: %s   |   game Lua heap (all addons): %.1f MB"):format(
		addonKB and ("%.2f MB"):format(addonKB / 1024) or (inCombat and "(not measured in combat)" or "n/a"),
		heapKB() / 1024))

	-- the on-demand addons: loaded or not, and their own figure
	local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	for _, key in ipairs({ "GUI", "Libraries", "Logging", "Communities" }) do
		local name = M.PSS_PARTS and M.PSS_PARTS[key]
		if name and isLoaded and isLoaded(name) then
			local ok, v = false, nil
			if not inCombat and getMem then ok, v = pcall(getMem, name) end
			out(("  %s: loaded%s"):format(name, ok and v and (", %.2f MB"):format(v / 1024) or ""))
		elseif key == "GUI" then
			out(("  %s: not loaded"):format(name))
		end
	end
	-- the saved settings and lists (always loaded)
	if not inCombat and getMem then
		local ok, v = pcall(getMem, "PourSocialScore_Options")
		if ok and v then out(("  PourSocialScore_Options (settings and lists): %.2f MB"):format(v / 1024)) end
	end

	-- the shared block log
	if H and not H.Loaded() then
		out(("  block history: PourSocialScore_Logging not loaded (it loads when you open the history), %d new lines waiting"):format(H.Waiting()))
	elseif H then
		local bytes, n = H.EstimateBytes()
		local log = H.Log()
		local byType = { p = 0, g = 0, f = 0 }
		local byOwner = full and {} or nil
		for i = 1, #log do
			local o = log[i].o
			local t = type(o) == "string" and o:sub(1, 1)
			if t and byType[t] then byType[t] = byType[t] + 1 end
			if byOwner and o then byOwner[o] = (byOwner[o] or 0) + 1 end
		end
		local keptLines, keptPeople = H.KeepSize()
		out(("  block history: %d / %d lines (~%s)  -  players %d, guild members %d, filters %d"):format(
			n, H.Cap(), kb(bytes), byType.p, byType.g, byType.f))
		out(("  kept per person (older than the log): %d lines for %d people"):format(keptLines, keptPeople))
		if byOwner then
			local top = {}
			for o, c in pairs(byOwner) do top[#top + 1] = { o = o, c = c } end
			table.sort(top, function(a, b) return a.c > b.c end)
			for i = 1, math.min(10, #top) do
				local o = top[i].o
				local kind = ({ p = "player", g = "guild member", f = "filter" })[o:sub(1, 1)] or "?"
				out(("      %4d  %s %s"):format(top[i].c, kind, o:sub(3)))
			end
		end
	end

	-- lists
	local players = 0
	for _, e in ipairs(db.list or {}) do if (e.kind or "player") == "player" then players = players + 1 end end
	local rules, stored, managedRules = 0, 0, 0
	for _, g in pairs(db.guildData or {}) do
		if type(g) == "table" then
			rules = rules + 1
			if g.managed then managedRules = managedRules + 1 end
			for _ in pairs(g.members or {}) do stored = stored + 1 end
		end
	end
	local pd = 0
	for _ in pairs(db.playerData or {}) do pd = pd + 1 end
	out(("  Player Ignore List: %d players (%d player records)   |   Guild Ignore List: %d rules, %d saved members"):format(
		players, pd, rules, stored))
	if M.PSS_ManagedStats then
		local ms = M.PSS_ManagedStats()
		out(("  shipped guild lists: %d names in %d rules, %d indexed, %d records in use, %d changed (saved at logout)"):format(
			ms.shipped, managedRules, ms.indexed, ms.cached, ms.kept))
	end
	local active = 0
	for i = 1, #(db.filterList or {}) do if db.filterActive[i] then active = active + 1 end end
	out(("  chat filters: %d (%d on)"):format(#(db.filterList or {}), active))

	-- collector
	local gcs = M.PSS_GCState
	out(("  memory cleanup: %s, %d cycle(s) this session%s"):format(
		(M.PSS_Opt and M.PSS_Opt("gcEnabled") == false and "off") or (gcs.supported and (gcs.running and "running now" or "idle") or "not supported"),
		gcs.cycles or 0, gcs.lastReason and (", last: " .. gcs.lastReason) or ""))
	-- memory the game has not collected yet still counts as addon memory, so
	-- these say when the last cleanup finished and what a due one waits for
	local ago = (gcs.cycles or 0) > 0 and math.floor((GetTime() - (gcs.lastCycle or 0)) / 60) or nil
	local waiting = gcs.pending and not gcs.running and busyReason()
	out(("  last finished: %s%s"):format(ago and (ago .. " min ago") or "not yet this session",
		waiting and ("   |   next one waits: " .. waiting) or ""))
	if not full then out("  |cffaaaaaa/pss mem full|r also lists who has the most history lines.") end
end
