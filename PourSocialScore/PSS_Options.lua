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
	{ key = "showIgnoreReplies",	kind = "bool",		default = true,		section = 2, label = "Show sent ignore replies (the \"To player\" line of the ignore response)" },
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
	{ key = "showErrors",		kind = "bool",		default = false,		section = 4, label = "Show addon errors in chat (otherwise /pss status lists them)" },
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
-- Enabled components (3.6.0.69, issue 181): section 6, listed first; a change
-- applies after a reload (reload = true). Read through M.PSS_On, never directly.
local COMPONENTS = {
	{ key = "useAddons",		kind = "bool",		default = false, section = 6, reload = true, label = "Addon Manager",
		tip = "The AddOns tab, /pss acp and /acp, the Open Addon Manager key and the Addon Manager entry in the Addon Compartment. Off: none of it exists and nothing of it is loaded. Applies after a reload." },
	{ key = "useLogging",		kind = "bool",		default = true,		section = 6, reload = true, label = "Event Logging",
		tip = "Keeps a line for every blocked chat line or request (the Events tab, Block History). Off: no line is stored and the Events tab goes; every count stays as it is. Applies after a reload.",
		warn = "Turn off Event Logging? From now on nothing is recorded about what Pour Social Score blocks: the Events tab and every Event History page go, and you will not be able to track or review anything in the addon (the counts still run). OK turns it off after a reload; Cancel keeps it on." },
	{ key = "useGfx",			kind = "bool",		default = false, section = 6, reload = true, label = "Graphics Settings Exporter",
		tip = "/pss gfx: export, import and restore the graphics settings with a 15 second keep prompt (Camelot only). Off: /pss gfx does nothing and its code is not loaded. Applies after a reload." },
	{ key = "useFiltering",		kind = "bool",		default = true,		section = 6, reload = true, label = "Social Filtering",
		tip = "Everything that blocks: chat filtering, invite, duel and trade declines, the party warning, the Blizzard ignore sync, the Block menu items and capture. Off: nothing is blocked; your lists, rules and counts are kept and editable. Applies after a reload." },
}
for _, o in ipairs(COMPONENTS) do OPTIONS[#OPTIONS + 1] = o end

-- PSS Drop Cheapest Thing (3.6.1, money-helper): section 6 holds the switch,
-- section 7 its options under the group title "Feature Options" (shown
-- disabled while the switch is off). Read through M.PSS_On("dtt") and M.PSS_Opt.
OPTIONS[#OPTIONS + 1] = { key = "useDtt", kind = "bool", default = false, section = 6, reload = true, label = "PSS Drop Cheapest Thing",
	tip = "A minimap button and /pss dtt that destroy or sell your cheapest junk. Off: nothing loads. Applies after a reload." }
-- The Warehouse (3.7.0.106, warehouse-helper): every character's, guild's and warband's items,
-- currencies and gold, saved account wide (PSS_WarehouseDB), with tooltips and search. The Bag
-- manager switch is the shared item layer's: it reads your bags live for other features (the bag
-- windows come in a later line). Both off by default; off means no file, event or table.
OPTIONS[#OPTIONS + 1] = { key = "useWarehouse", kind = "bool", default = false, section = 6, reload = true, label = "Warehouse",
	tip = "Keeps every character's, guild's and warband's items, currencies and gold, shows them in item tooltips and in search (/pss wh). Off: nothing loads and nothing is saved. Applies after a reload." }
OPTIONS[#OPTIONS + 1] = { key = "useBags", kind = "bool", default = false, section = 6, reserved = true, reload = true, label = "Bag manager (item layer)",
	tip = "Reads your bags, bank and equipped items live for other features. The bag windows come later. Off: nothing loads. Applies after a reload." }
local DTT = {
	{ key = "dttIcon",			kind = "bool",		default = true,		section = 7, label = "Show the minimap button" },
	{ key = "dttQuality",		kind = "choice",	default = 0,		section = 7, label = "Highest quality to destroy",
		choices = { { 0, "Poor (grey)" }, { 1, "Common (white)" }, { 2, "Uncommon (green)" }, { 3, "Rare (blue)" }, { 4, "Epic (purple)" }, { 5, "Legendary (orange)" }, { 6, "Artifact" }, { 7, "Heirloom" } } },
	{ key = "dttSellQuality",	kind = "choice",	default = 0,		section = 7, label = "Highest quality to sell",
		choices = { { 0, "Poor (grey)" }, { 1, "Common (white)" }, { 2, "Uncommon (green)" }, { 3, "Rare (blue)" }, { 4, "Epic (purple)" }, { 5, "Legendary (orange)" }, { 6, "Artifact" }, { 7, "Heirloom" } } },
	{ key = "dttFood",			kind = "bool",		default = false,	section = 7, label = "Low-level food and drink" },
	{ key = "dttPotion",		kind = "bool",		default = false,	section = 7, label = "Low-level potions" },
	{ key = "dttBandage",		kind = "bool",		default = false,	section = 7, label = "Low-level bandages" },
	{ key = "dttScroll",		kind = "bool",		default = false,	section = 7, label = "Low-level scrolls" },
	{ key = "dttSoulbound",	kind = "bool",		default = false,	section = 7, label = "Include soulbound items" },
	{ key = "dttValueless",	kind = "bool",		default = false,	section = 7, label = "Include items with no value",
		tip = "Warning: this includes the hearthstone." },
	{ key = "dttAppearance",	kind = "bool",		default = false,	section = 7, label = "Include unknown appearances",
		tip = "Retail only: gear whose look you have not collected." },
	{ key = "dttFullStacks",	kind = "bool",		default = false,	section = 7, label = "Compare by full stack value" },
	{ key = "dttMerchantButton", kind = "bool",	default = false,	section = 7, label = "Show a Sell junk button on the merchant window",
		tip = "Needs PSS Drop Cheapest Thing on. Sells what the sell quality marks as junk, only when you click it." },
	{ key = "dttCautious",		kind = "bool",		default = true,		section = 7, label = "Sell at most 12 items at once",
		tip = "So the buyback tab can undo it." },
	{ key = "dttAuction",		kind = "bool",		default = false,	section = 7, label = "Use auction values",
		tip = "Shows an auction price beside a vendor price when a price addon provides one. Never saved." },
	{ key = "dttAuctionQuality", kind = "choice",	default = 1,		section = 7, label = "Lowest quality for auction values",
		choices = { { 0, "Poor (grey)" }, { 1, "Common (white)" }, { 2, "Uncommon (green)" }, { 3, "Rare (blue)" }, { 4, "Epic (purple)" }, { 5, "Legendary (orange)" }, { 6, "Artifact" }, { 7, "Heirloom" } } },
	{ key = "dttAlways",		kind = "itemlist",	default = "",		section = 7, label = "Always destroy these items" },
	{ key = "dttNever",		kind = "itemlist",	default = "",		section = 7, label = "Never destroy these items" },
}
for _, o in ipairs(DTT) do OPTIONS[#OPTIONS + 1] = o end
-- Warehouse options (section 8, shown under Feature Options; SAV-p09). A tooltip line for every holder
-- of the item, from the Warehouse.
local WHCAM = (select(4, GetBuildInfo()) or 0) < 20000
local WH = {
	{ key = "whTooltips",		kind = "bool",		default = true,		section = 8, label = "Show who holds an item in its tooltip" },
	{ key = "whTipGuilds",		kind = "bool",		default = true,		section = 8, label = "Include guild banks" },
	{ key = "whTipEquipped",	kind = "bool",		default = true,		section = 8, label = "Include equipped items" },
	{ key = "whTipCurrency",	kind = "bool",		default = true,		section = 8, label = "Show who holds a currency in its tooltip" },
	{ key = "whTipShift",		kind = "bool",		default = false,	section = 8, label = "Only while Shift is held" },
	{ key = "whTipRealms",		kind = "bool",		default = WHCAM,	section = 8, label = "Show the realm of other realms' characters" },
	{ key = "whTipFaction",		kind = "bool",		default = false,	section = 8, label = "Only characters of your faction" },
	{ key = "whTipLimit",		kind = "number",	default = 4,		section = 8, min = 0, max = 50, label = "Holders listed before \"and n more\" (0-50)" },
	{ key = "whTipByName",		kind = "bool",		default = false,	section = 8, label = "Join variants of an item by its name" },
	{ key = "whTipTotal",		kind = "bool",		default = false,	section = 8, label = "Show a total line" },
	{ key = "whRealms",			kind = "choice",	default = "this", section = 8, label = "Realms shown in search and gold",
		tip = "This realm: the characters of the realm you are on. All realms: every character you saved. Item and currency tooltips always show this realm only.",
		choices = { { "this", "This realm" }, { "all", "All realms" } } },
	{ key = "whUnnamed",		kind = "action",	default = false,	section = 8, label = "Saved data with no saved character" },
	{ key = "whValueSource",	kind = "choice",	default = "",		section = 8, label = "Where an item's value comes from",
		choices = { { "", "Vendor price" }, { "auto", "The first price addon found" }, { "tsm", "TradeSkillMaster" }, { "recrystallize", "RECrystallize" }, { "auctionator", "Auctionator" } } },
	{ key = "whGuildDays",		kind = "number",	default = 0,		section = 8, min = 0, max = 365, label = "Forget a guild bank not seen for this many days (0 keeps it)" },
}
for _, o in ipairs(WH) do OPTIONS[#OPTIONS + 1] = o end
local SECTIONS = { L["OPT_8"], "Blocking Options:", L["OPT_9"], L["OPT_15"], "Whois Scan Options:", "Enabled components:", "Drop The Cheapest Thing:", "Warehouse:" }
-- the order the Options tab lists the sections in (Enabled components first)
M.PSS_OPTION_SECTION_ORDER = { 6, 1, 2, 3, 4, 5, 7, 8 }
-- sections drawn under a group title, and sections shown disabled (one line)
-- while their Enabled component is off: { [section] = ... }; none yet
M.PSS_OPTION_SECTION_GROUP = { [7] = "Feature Options", [8] = "Feature Options" }
M.PSS_OPTION_SECTION_GATE = { [7] = { on = "dtt", text = "Turn on PSS Drop Cheapest Thing in Enabled components, then reload." },
	[8] = { on = "warehouse", text = "Turn on the Warehouse in Enabled components, then reload." } }
M.PSS_OPTION_SECTION_PAGE = { [7] = "dtt", [8] = "warehouse" }	-- section -> its Addon Manager page key

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
	if not db and def then
		-- before the core table exists (ADDON_LOADED on a first run): the options table alone
		local o = PSS_OptionsDB
		local v = o and o[key]
		if v ~= nil then return v end
	end
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

-- Enabled components (issue 181). M.PSS_On(name) is the one reader: name is
-- "addons", "gfx", "logging" or "filtering". It answers what the session
-- started with (M.PSS_SnapComponents at ADDON_LOADED), so a change made in
-- the Options tab applies after a reload and a session never has half a
-- component. M.PSS_OnNow(name) is the option as set now (the Options tab).
local COMPONENT_KEY = { addons = "useAddons", gfx = "useGfx", logging = "useLogging", filtering = "useFiltering", dtt = "useDtt", warehouse = "useWarehouse", bags = "useBags" }
local snap

local function camelot()
	local build = select(4, GetBuildInfo())
	return type(build) == "number" and build < 20000
end
M.PSS_IsCamelot = camelot

local liveOn
function liveOn(name)
	if name == "items" then return liveOn("bags") or liveOn("warehouse") end		-- the shared item layer runs for either
	local key = COMPONENT_KEY[name]
	if not key then return false end
	if name == "gfx" and not camelot() then return false end
	return M.PSS_Opt(key) == true
end

function M.PSS_SnapComponents()
	snap = {}
	for name in pairs(COMPONENT_KEY) do snap[name] = liveOn(name) end
	snap.items = snap.bags or snap.warehouse
end

function M.PSS_On(name)
	if snap then return snap[name] == true end
	return liveOn(name)
end
M.PSS_OnNow = liveOn

-- the line a command or key prints while its component is off
M.PSS_OFF_TEXT = {
	addons = "The Addon Manager is off: Options, Enabled components.",
	gfx = "The Graphics Settings Exporter is off: Options, Enabled components.",
	logging = "Event Logging is off: Options, Enabled components.",
	filtering = "Social Filtering is off: nothing is blocked (Options, Enabled components).",
	dtt = "PSS Drop Cheapest Thing is off: turn it on in Options, Enabled components, then reload.",
	warehouse = "The Warehouse is off: turn it on in Options, Enabled components, then reload.",
	bags = "The Bag manager is off: turn it on in Options, Enabled components, then reload.",
}

-- a component whose option was changed since the session started
function M.PSS_ComponentPending(name)
	return snap ~= nil and snap[name] ~= nil and snap[name] ~= liveOn(name)
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
