------------------------------------------------------------------------
-- POUR SOCIAL SCORE - OPTIONS
--
-- Every option has one account-wide value (the Options tab, saved in
-- PSS_OptionsDB through PourSocialScoreDB, PSS_SavedData.lua). Only a value
-- that differs from the default is saved (3.0): no saved value is the
-- default, so read options with M.PSS_Opt, never PourSocialScoreDB.<key>. Options that make sense per target (e.g.
-- "Send ignore response to ignored players") can additionally be overridden
-- per GUILD rule and per PERSON (guild member or ignored player) from their
-- right-click menus / the player detail window.
--
-- Resolution (most specific wins):  person > guild > Options tab > default
-- (2.0.12 removed the per-character layer: it had no visible effect for most
-- people and an override set there could not be seen anywhere else.)
--
--   M.PSS_Opt(key [, ctx])     ctx = { person = <opts table>, guild = <opts table> }
--   M.PSS_SetOpt(key, scope, value [, target])  scope: "global" | "guild" | "person"
--                                               value nil clears an override
------------------------------------------------------------------------
local addonName, addon = ...
local L = addon.L
local M = addon.M

local OPTIONS = {
	-- Ignore list
	{ key = "asknote",			kind = "bool",		default = true, section = 1, label = L["OPT_1"] },
	{ key = "sameserver",		kind = "bool",		default = true,		section = 1, label = L["OPT_4"] },
	{ key = "samefaction",		kind = "bool",		default = true,		section = 1, label = L["OPT_27"] },
	{ key = "trackChanges",		kind = "bool",		default = true,		section = 1, label = L["OPT_6"] },
	{ key = "chatmsg",			kind = "bool",		default = true,		section = 1, label = L["OPT_26"] },
	{ key = "listWarnings",		kind = "bool",		default = true,		section = 1, label = L["OPT_29"] },
	{ key = "showWarning",		kind = "bool",		default = true, section = 1, label = L["OPT_18"] },
	{ key = "defexpire",		kind = "number", default = 0,		section = 1, label = L["OPT_5"] },
	-- Blocking (people)
	{ key = "ignoreResponse", kind = "bool",	default = false,	section = 2, label = L["OPT_24"], target = true },
	{ key = "showDeclines",		kind = "bool",		default = false,		section = 2, label = L["OPT_28"], target = true },
	{ key = "declineDuel",		kind = "bool",		default = true,		section = 2, label = "Decline duels from blocked players", target = true },
	{ key = "declineTrade",		kind = "bool",		default = true,		section = 2, label = "Decline trades from blocked players", target = true },
	{ key = "historyTotal",		kind = "number", default = 2000,	section = 2, min = 100, max = 20000,
		label = "Block history lines kept in total, shared by every player, guild and filter (100-20000; a larger buffer increases memory usage)" },
	{ key = "purgeHistory",		kind = "bool",		default = true,		section = 2, label = "Remove a player's earlier chat lines when they become blocked" },
	-- Chat filters
	{ key = "spamFilter",		kind = "bool",		default = true,		section = 3, label = L["OPT_7"] },
	{ key = "invertSpam",		kind = "bool",		default = false, section = 3, label = L["OPT_10"] },
	{ key = "floodFilter",		kind = "choice", default = 0,		section = 3, label = L["OPT_20"],
		choices = { { 0, L["OPT_21"] }, { 1, L["OPT_22"] }, { 2, L["OPT_23"] } } },
	{ key = "skipGuild",		kind = "bool",		default = true,		section = 3, label = L["OPT_12"] },
	{ key = "skipParty",		kind = "bool",		default = false, section = 3, label = L["OPT_13"] },
	{ key = "skipPrivate",		kind = "bool",		default = true,		section = 3, label = L["OPT_14"] },
	{ key = "skipYourself",		kind = "bool",		default = false, section = 3, label = L["OPT_19"] },
	-- User interface
	{ key = "openWithFriends", kind = "bool",	default = true,		section = 4, label = L["OPT_2"] },
	{ key = "useUnitHacks",		kind = "bool",		default = true,		section = 4, label = L["OPT_16"] },
	{ key = "useLFGHacks",		kind = "bool",		default = true,		section = 4, label = L["OPT_17"] },
	{ key = "gcEnabled",		kind = "bool",		default = true,		section = 4, label = "Background memory cleanup (out of combat, never causes a hitch)" },
	{ key = "frameStrata",		kind = "choice", default = 3,		section = 4, label = L["OPT_25"],
		choices = { { 0, "LOW" }, { 1, "MEDIUM" }, { 2, "HIGH" }, { 3, "DIALOG" } } },
	-- The window (PourSocialScore_GUI, /pss gui): its look
	{ key = "uiSkin",			kind = "choice", default = 2,		section = 4, label = "Look of the Pour Social Score window",
		choices = { { 2, "Modern (Default)" }, { 0, "Classic" }, { 1, "Dark" } },
		tip = "Modern: the art of Blizzard's new Social window (Retail; other clients show the Classic look). Classic: Blizzard's classic window art and fonts. Dark: flat and dark. All have the same layout." },
	{ key = "uiFont",			kind = "choice", default = "",		section = 4, label = "Font of the Pour Social Score window",
		choices = {
			{ "", "Default for the look" }, { "game", "Game text" }, { "names", "Unit names" }, { "damage", "Damage numbers" },
			{ "friz", "Friz Quadrata" }, { "arialn", "Arial Narrow" }, { "morpheus", "Morpheus" }, { "skurri", "Skurri" },
		},
		tip = "Blizzard's fonts, and fonts other addons have shared through LibSharedMedia (listed once the new window has been opened). Default: Blizzard's own for the Modern and Classic looks, Arial Narrow for Dark." },
	-- Whois scans (Scan, Scan All, Custom, Guild Search): see PSS_WhoisHarvest.lua.
	-- The cap is drawn in the tickbox's row (field) and must be set to tick it.
	{ key = "whoLevelCapOn",	kind = "bool",		default = false, section = 5, label = "Enable scan level cap", field = "whoLevelCap",
		tip = "When ticked, no /who scan searches above this level: Scan and Scan All stop their level brackets at the cap, Custom and Guild Search are limited to it." },
	{ key = "whoLevelCap",		kind = "number", default = nil,		section = 5, min = 1, max = 999, inline = true, label = "Scan level cap" },
}
local SECTIONS = { L["OPT_8"], "Blocking Options:", L["OPT_9"], L["OPT_15"], "Whois Scan Options:" }

local REG = {}
for _, o in ipairs(OPTIONS) do REG[o.key] = o end
M.PSS_OPTIONS = OPTIONS
M.PSS_OPTION_REG = REG
M.PSS_OPTION_SECTIONS = SECTIONS

------------------------------------------------------------------------
-- Resolution
------------------------------------------------------------------------
local charKeyCache
local function charKey()
	if not charKeyCache and UnitName then
		local n, r = UnitName("player")
		charKeyCache = select(2, M.PSS_NormName(n, r, "player"))
	end
	return charKeyCache
end
M.PSS_CharKey = charKey

function M.PSS_Opt(key, ctx)
	local def = REG[key]
	if ctx and def and def.target then
		local person, guild = ctx.person, ctx.guild
		if type(person) == "table" and person[key] ~= nil then return person[key] end
		if type(guild) == "table" and guild[key] ~= nil then return guild[key] end
	end
	local db = PourSocialScoreDB
	if db then
		local v
		if def then
			-- an option is saved in PSS_OptionsDB: read it there, without the
			-- router's __index (P4, N26); a value PourSocialScoreDB still holds
			-- (before the split moved it) wins, as through the router
			v = rawget(db, key)
			if v == nil then
				local o = PSS_OptionsDB
				if o then v = o[key] end
			end
		else
			v = db[key]
		end
		if v ~= nil then return v end
	end
	if def then return def.default end
	return nil
end

local STRATA = { [0] = "LOW", [1] = "MEDIUM", [2] = "HIGH", [3] = "DIALOG" }
function M.PSS_FrameStrataName()
	return STRATA[tonumber(M.PSS_Opt("frameStrata")) or 3] or "DIALOG"
end

-- target: the record whose .opts holds the override (guild rule, member,
-- or player record) for scope "guild"/"person".
function M.PSS_SetOpt(key, scope, value, target)
	local db = PourSocialScoreDB
	if not db then return end
	local def = REG[key]
	if scope == "global" then
		-- the default is not saved
		if def and value == def.default then value = nil end
		db[key] = value
	elseif (scope == "guild" or scope == "person") and type(target) == "table" then
		if M.PSS_KeepManaged then M.PSS_KeepManaged(target) end		-- shipped member: save it
		target.opts = target.opts or {}
		target.opts[key] = value
		if next(target.opts) == nil then target.opts = nil end
	end
	-- the windows apply what they show at once (e.g. frameStrata)
	M.Events.Fire("OPTION_CHANGED", key)
	-- a smaller history buffer frees the memory now, not only as lines arrive
	if key == "historyTotal" and M.PSS_TrimAllHistory then M.PSS_TrimAllHistory() end
end

-- Saved values equal to their default are dropped (3.0: only changes are
-- saved; M.PSS_Opt returns the default for a missing value). Every login.
-- (The 2.0.12 switch-off of ignoreResponse and blizzardSync is upgrade
-- step 5 now, PSS_Upgrade.lua. blizzardSync is a per-player tick from
-- 3.4.1.35: step 8.) Returns the number of values dropped.
function M.PSS_ApplyOptionDefaults()
	local db = PourSocialScoreDB
	if not db then return 0 end
	local n = 0
	for _, o in ipairs(OPTIONS) do
		if db[o.key] ~= nil and db[o.key] == o.default then
			db[o.key] = nil
			n = n + 1
		end
	end
	return n
end
