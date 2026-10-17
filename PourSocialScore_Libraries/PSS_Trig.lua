------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE TRIGGER ENGINE (service-bus-helper, DDS-00010
-- section 10, STP-00135; decisions DEC-00179 to DEC-00190). The one
-- framework for every wake-up PSS needs. A need is declared as data with
-- a class; the engine meets it on the first rung of the class's ladder
-- that the need fits (event, settle, signal, pull, interaction, pulse,
-- clock, decision). No OnUpdate anywhere; the clock is one one-shot timer
-- for the earliest deadline (the only timer call in this engine, the
-- Overrides row of DEC-00227). The engine creates one plain event frame
-- of its own and never creates, shows or hooks a window widget: the GUI
-- binds its own (rung "interaction").
--   M.PSS_Want(need)          declare a need, returns { id, class, rung }
--   M.PSS_Unwant(id)          cancel it
--   M.PSS_Use(id, seconds)    cooldown, checked when used (no timer)
--   M.PSS_When(cond, fn)      run fn once the condition holds
--   M.PSS_Needs() / M.PSS_Cards()   record sets (also services trig.needs
--                             and trig.cards)
-- Built on the first call; nothing registers while no need waits.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, next, assert, tostring = type, pairs, next, assert, tostring
local sort, remove = table.sort, table.remove
local max = math.max

-- The ladder (DEC-00180): rung weights, lower is preferred.
local RUNGS = { event = 1, settle = 2, signal = 3, pull = 4, interaction = 5, pulse = 6, clock = 7, decision = 8 }

-- Classes (DEC-00179): the rungs each may use, in ladder order. A class is
-- data: a new class is a row, never engine code.
local CLASSES = {
	coalesce = { "settle", "signal", "pull" },
	["await-data"] = { "event" },
	["await-unlock"] = { "event", "settle" },
	["step-sequence"] = { "event", "settle", "signal" },
	slice = { "pull", "pulse", "clock" },
	["hover-follow"] = { "interaction" },
	["drag-follow"] = { "interaction" },
	modifier = { "interaction" },
	countdown = { "interaction", "clock" },
	animate = { "interaction" },
	debounce = { "pull", "interaction", "pulse" },
	delay = { "event", "clock" },
	cooldown = { "pull", "clock" },
	timeout = { "event", "clock" },
	["per-frame"] = { "event", "signal", "pulse" },
}

-- what a need must carry for a rung to fit it
local FITS = {
	event = function(n) return n.on ~= nil and n.settle == nil and n.bind == nil end,
	settle = function(n) return n.on ~= nil and n.settle ~= nil end,
	signal = function(n) return n.signal ~= nil end,
	pull = function(n) return n.read ~= nil or n.page ~= nil or n.readyAt ~= nil end,
	interaction = function(n) return n.bind ~= nil end,
	pulse = function(n) return n.step ~= nil end,
	clock = function(n) return n.at ~= nil or n.duration ~= nil or n.by ~= nil end,
}

-- classes that always ask the author (a decision card) unless an event or a signal answers
local ASK = { ["per-frame"] = true }

-- pulse sources (DEC-00190): cheap, frequent client events, registered only while steps wait
local PULSE_SOURCES = { "CURSOR_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING", "MODIFIER_STATE_CHANGED", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED" }

-- Waits: a condition and the client events that can end it. test(event) is
-- the state (nocombat, quiet) or the event itself (the others).
local COND = {
	nocombat = { test = function(_, c) return not c.InCombatLockdown() end, wake = { "PLAYER_REGEN_ENABLED" } },
	itemdata = { test = function(e) return e == "ITEM_DATA_LOAD_RESULT" end, wake = { "ITEM_DATA_LOAD_RESULT" } },
	unlocked = { test = function(e) return e == "ITEM_UNLOCKED" or e == "BAG_UPDATE_DELAYED" end, wake = { "ITEM_UNLOCKED", "BAG_UPDATE_DELAYED" } },
	bankclosed = { test = function(e) return e == "BANKFRAME_CLOSED" end, wake = { "BANKFRAME_CLOSED" } },
	quiet = { test = function(_, c) return not c.InCombatLockdown() and not (c.IsInInstance and c.IsInInstance()) end,
		wake = { "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_ALIVE", "PLAYER_UNGHOST" } },
}

local function New(client)
	local E = { needs = {}, cards = { cols = { "id", "source", "class", "question", "options", "recommended" }, n = 0 },
		queue = {}, PULSE_MS = 1.0, AGE = 5, VISIBLE = 50, GUARANTEE = 1.0, ticks = 0,
		AFK_BOOST = 40, GUARANTEE_AFK = 0.25 }
	local GetTime = client.GetTime
	local src = client.CreateFrame("Frame")
	local byEvent, refs, dirty, waits, bySignal = {}, {}, {}, {}, {}
	local clockGen, clockAt = 0, nil
	local pulseOn = false

	local function need(e, d)
		local n = (refs[e] or 0) + d
		if n <= 0 then refs[e] = nil; src:UnregisterEvent(e) else refs[e] = n; src:RegisterEvent(e) end
	end
	local function listen(e, id)
		local t = byEvent[e]
		if not t then t = {}; byEvent[e] = t end
		t[#t + 1] = id
		need(e, 1)
	end
	local function unlisten(e, id)
		local t = byEvent[e]
		if not t then return end
		for i = #t, 1, -1 do if t[i] == id then remove(t, i); need(e, -1) end end
	end

	-- the first rung of the need's class that the need fits (DEC-00180)
	function E.Resolve(n)
		local ladder = CLASSES[n.class]
		if ladder then
			for i = 1, #ladder do
				if FITS[ladder[i]](n) then return ladder[i] end
			end
		end
		return "decision"
	end

	-- Weights (DEC-00181): weight + age * AGE, +VISIBLE when its widget shows.
	-- AFK (DEC-00189): an afk need is boosted and its guarantee shortens while
	-- the player is away; PLAYER_FLAGS_CHANGED is heard only while such a need waits.
	local function isAfk() return client.UnitIsAFK and client.UnitIsAFK("player") and true or false end
	local function effective(n)
		local w = (n.weight or 10) + (n.age or 0) * E.AGE
		if n.visible and n.visible() then w = w + E.VISIBLE end
		if n.afk and isAfk() then w = w + E.AFK_BOOST end
		return w
	end

	local function card(n, why)
		local c = E.cards
		c.n = c.n + 1
		c[c.n] = { n.id, n.source or "pss", n.class or "unknown", why,
			"a: map to a client event, b: map to a signal of ours, c: keep on pulses (degraded), d: refuse",
			n.step and "c until mapped" or "a" }
	end

	-- The clock (DEC-00183, DEC-00227): one pending one-shot for the earliest due
	-- time; a stale one is ignored by its generation.
	local function arm()
		local best
		for _, n in pairs(E.needs) do
			local t = n.dueAt
			-- a need paused by combat waits for an event (PLAYER_REGEN_ENABLED pulses it),
			-- never the clock; a guarantee never lands in the past (no zero-delay spin)
			if n.queued and n.step and not (n.combat == false and client.InCombatLockdown()) then
				local every = (n.afk and isAfk()) and (n.byAfk or E.GUARANTEE_AFK) or (n.by or E.GUARANTEE)
				local g = max((n.lastProgress or GetTime()) + every, GetTime() + every / 4)
				if not t or g < t then t = g end
			end
			if t and (not best or t < best) then best = t end
		end
		if best and best ~= clockAt then
			clockGen = clockGen + 1
			local gen = clockGen
			clockAt = best
			client.C_Timer.After(max(0, best - GetTime()), function()
				if gen ~= clockGen then return end
				clockAt = nil
				E.ticks = E.ticks + 1
				local now = GetTime()
				for _, n in pairs(E.needs) do
					if n.dueAt and n.dueAt <= now then
						n.dueAt = nil
						if n.fn then n.fn("clock") end
					end
				end
				E.Pulse("clock")
				E.Arm()
			end)
		elseif not best then
			clockGen = clockGen + 1		-- nothing due: any pending one-shot is ignored
			clockAt = nil
		end
	end
	E.Arm = arm

	local function pulseSources(on)
		if on == pulseOn then return end
		pulseOn = on
		for i = 1, #PULSE_SOURCES do need(PULSE_SOURCES[i], on and 1 or -1) end
	end

	-- Pulse (DEC-00182): advance queued steps by weight within the budget; any event
	-- the engine hears is a pulse, and so is the clock's guarantee.
	function E.Pulse(why)
		local q = E.queue
		if #q == 0 then return 0 end
		sort(q, function(a, b) return effective(E.needs[a]) > effective(E.needs[b]) end)
		local start = client.debugprofilestop()
		E.pulses = (E.pulses or 0) + 1
		local ran, spent, progress = 0, false, true
		while #q > 0 and not spent and progress do
			progress = false
			local i = 1
			while i <= #q do
				local n = E.needs[q[i]]
				if n.combat == false and client.InCombatLockdown() then
					i = i + 1
				else
					ran = ran + 1
					progress = true
					n.age = 0
					n.ranIn = E.pulses
					n.lastProgress = GetTime()
					if n.step(n, why) then
						remove(q, i)
						n.queued = false
						if n.afk then need("PLAYER_FLAGS_CHANGED", -1) end
						if n.done then n.done(n) end
					else
						i = i + 1
					end
					if client.debugprofilestop() - start >= E.PULSE_MS then spent = true; break end
				end
			end
		end
		for j = 1, #q do local m = E.needs[q[j]]; if m and m.ranIn ~= E.pulses then m.age = (m.age or 0) + 1 end end
		if #q == 0 then pulseSources(false) end
		arm()
		return ran
	end

	function E.Queue(id)
		local n = E.needs[id]
		if n.queued then return end
		n.queued = true
		n.lastProgress = GetTime()
		E.queue[#E.queue + 1] = id
		if n.afk then need("PLAYER_FLAGS_CHANGED", 1) end
		pulseSources(true)
		arm()
	end

	local waiting = {}
	function E.Wake(e)
		local i = 1
		while i <= #waiting do
			local w = waiting[i]
			local c = COND[w.cond]
			if c.test(e, client) then
				remove(waiting, i)
				for j = 1, #c.wake do
					local ev = c.wake[j]
					waits[ev] = waits[ev] - 1
					if waits[ev] == 0 then waits[ev] = nil end
					need(ev, -1)
				end
				w.fn()
			else
				i = i + 1
			end
		end
	end

	src:SetScript("OnEvent", function(_, e, ...)
		local ids = byEvent[e]
		if ids then
			for i = 1, #ids do
				local n = E.needs[ids[i]]
				if n then
					if n.settleOn == e then
						if next(dirty[n.id]) and n.fn then
							local keys = {}
							for k in pairs(dirty[n.id]) do keys[#keys + 1] = k; dirty[n.id][k] = nil end
							n.fn(keys, e)
						end
					elseif n.rung == "settle" then
						local k = e
						if n.key then k = n.key(e, ...) end
						if k ~= nil then dirty[n.id][k] = true end
					elseif n.fn then
						n.fn(e, ...)
					end
				end
			end
		end
		if waits[e] then E.Wake(e) end
		E.Pulse(e)
		if e == "PLAYER_FLAGS_CHANGED" then arm() end		-- AFK on or off re-times the guarantee
	end)

	-- run fn once the condition holds; the wake events are registered only while it waits
	function E.When(cond, fn)
		local c = COND[cond]
		if not c then return end
		if c.test(nil, client) then return fn() end
		waiting[#waiting + 1] = { cond = cond, fn = fn }
		for i = 1, #c.wake do
			local e = c.wake[i]
			waits[e] = (waits[e] or 0) + 1
			need(e, 1)
		end
	end

	-- our own acts (and the gateway's translations) wake the needs that list them
	function E.Signal(name, payload)
		local ids = bySignal[name]
		if not ids then return end
		for i = 1, #ids do
			local n = E.needs[ids[i]]
			if n and n.fn then n.fn(payload, name) end
		end
	end

	-- declare a need; returns its resolution { id, class, rung }
	function E.Need(n)
		assert(type(n) == "table" and n.id and not E.needs[n.id], "need id")
		E.needs[n.id] = n
		n.rung = E.Resolve(n)
		local r = n.rung
		if n.once and n.fn then		-- the first answer wins; the need then retires itself
			local fn = n.fn
			n.fn = function(...) E.Cancel(n.id); return fn(...) end
		end
		if n.orAfter then n.dueAt = GetTime() + n.orAfter end		-- an event, or the clock at the latest
		if r == "event" then
			for i = 1, #n.on do listen(n.on[i], n.id) end
		elseif r == "settle" then
			dirty[n.id] = {}
			for i = 1, #n.on do listen(n.on[i], n.id) end
			n.settleOn = n.settle
			listen(n.settle, n.id)
		elseif r == "signal" then
			local t = bySignal[n.signal]
			if not t then t = {}; bySignal[n.signal] = t end
			t[#t + 1] = n.id
		elseif r == "interaction" then
			E.Interact(n)
		elseif r == "pulse" then
			E.Queue(n.id)
		elseif r == "clock" then
			n.dueAt = n.at or (GetTime() + (n.duration or n.by))
			arm()
		elseif r == "decision" then
			card(n, "no rung of class " .. tostring(n.class) .. " fits this need")
			if n.step then E.Queue(n.id) end		-- compatibility meanwhile: pulses
		end
		if r ~= "decision" and ASK[n.class] and r ~= "event" and r ~= "signal" then
			card(n, "a " .. n.class .. " need from " .. (n.source or "pss") .. " runs on pulses; map it to an event or a signal")
		end
		if n.dueAt then arm() end
		return { id = n.id, class = n.class, rung = r }
	end

	function E.Cancel(id)
		local n = E.needs[id]
		if not n then return end
		if n.on and (n.rung ~= "interaction" or n.live) then for i = 1, #n.on do unlisten(n.on[i], id) end end
		if n.settleOn then unlisten(n.settleOn, id) end
		if n.rung == "signal" or (n.rung == "interaction" and n.live) then
			local t = n.signal and bySignal[n.signal]
			if t then for i = #t, 1, -1 do if t[i] == id then remove(t, i) end end end
		end
		if n.queued then
			if n.afk then need("PLAYER_FLAGS_CHANGED", -1) end
			for i = #E.queue, 1, -1 do if E.queue[i] == id then remove(E.queue, i) end end
			if #E.queue == 0 then pulseSources(false) end
		end
		if n.cleanup then n.cleanup() end
		E.needs[id] = nil
		dirty[id] = nil
		arm()
	end

	-- Interaction rung (DEC-00198): the GUI declares the need while its window shows and
	-- binds its own widgets: bind(fire, ctl) wires their scripts to fire(...), which runs
	-- the need's fn; ctl.on / ctl.off register the need's events only while the GUI shows.
	function E.Interact(n)
		local ctl = {
			on = function()
				if n.live then return end
				n.live = true
				for i = 1, #(n.on or {}) do listen(n.on[i], n.id) end
				if n.signal then
					local t = bySignal[n.signal]
					if not t then t = {}; bySignal[n.signal] = t end
					t[#t + 1] = n.id
				end
			end,
			off = function()
				if not n.live then return end
				n.live = false
				for i = 1, #(n.on or {}) do unlisten(n.on[i], n.id) end
				local t = n.signal and bySignal[n.signal]
				if t then for i = #t, 1, -1 do if t[i] == n.id then remove(t, i) end end end
			end,
		}
		n.ctl = ctl
		n.fire = function(...) if n.fn then return n.fn(...) end end
		if n.duration then n.dueAt = GetTime() + n.duration; arm() end		-- countdown: the clock acts
		n.bind(n.fire, ctl)
	end

	-- cooldowns are checked when used: no timer unless a shown state must change
	function E.Ready(id)
		local n = E.needs[id]
		return not n or not n.readyAt or GetTime() >= n.readyAt
	end
	function E.Use(id, seconds)
		local n = E.needs[id]
		if not n then return true end
		if not E.Ready(id) then return false end
		n.readyAt = GetTime() + seconds
		return true
	end

	-- every need and its rung as a record set (outputs are inputs)
	function E.Report()
		local out = { cols = { "id", "class", "rung", "weight" }, n = 0 }
		for id, n in pairs(E.needs) do out.n = out.n + 1; out[out.n] = { id, n.class, n.rung, n.weight or 10 } end
		sort(out, function(a, b) return a[1] < b[1] end)
		return out
	end

	return E
end

M.PSS_TrigNew = New
M.PSS_TRIG = { RUNGS = RUNGS, CLASSES = CLASSES, ASK = ASK, PULSE_SOURCES = PULSE_SOURCES, COND = COND }

------------------------------------------------------------------------
-- The session's engine, built on the first need
------------------------------------------------------------------------
local engine
local function Engine()
	if not engine then
		engine = New({ CreateFrame = CreateFrame, GetTime = GetTime, C_Timer = C_Timer, debugprofilestop = debugprofilestop,
			InCombatLockdown = InCombatLockdown, UnitIsAFK = UnitIsAFK, IsInInstance = IsInInstance })
	end
	return engine
end

function M.PSS_Want(n) return Engine().Need(n) end
function M.PSS_Unwant(id) if engine then engine.Cancel(id) end end
function M.PSS_Use(id, seconds) return Engine().Use(id, seconds) end
function M.PSS_When(cond, fn) return Engine().When(cond, fn) end
function M.PSS_TrigSignal(name, set) if engine then engine.Signal(name, set) end end
function M.PSS_Needs() return Engine().Report() end
function M.PSS_Cards() return Engine().cards end
function M.PSS_Engine() return engine end

M.PSS_Provide("trig.needs", function() return M.PSS_Needs() end, { returns = { "id", "class", "rung", "weight" }, doc = "every need and its rung" })
M.PSS_Provide("trig.cards", function() return M.PSS_Cards() end, { returns = { "id", "source", "class", "question", "options", "recommended" }, doc = "decision cards waiting on the author" })
