local addonName, addon = ...
local M = addon.M
local V = addon.V

-- Client flavour record, capability levels and the capability API
-- (multi-version suite). Detection runs once, at load; project id first,
-- interface second. Features read M.PSS_Can, never a client test.

local select = select
local type = type
local error = error
local pairs = pairs
local tostring = tostring

local pid = WOW_PROJECT_ID
local iface = GetBuildInfo and select(4, GetBuildInfo())
if type(iface) ~= "number" then iface = nil end

local flavour
local function pick(const, name)
	if const ~= nil and const == pid then flavour = name end
end
pick(WOW_PROJECT_MISTS_CLASSIC, "mists")
pick(WOW_PROJECT_CLASSIC, "era")
pick(WOW_PROJECT_BURNING_CRUSADE_CLASSIC, "tbc")
pick(WOW_PROJECT_CAMELOT, "forever")
pick(WOW_PROJECT_MAINLINE, "retail")
if not flavour then
	if iface then
		if iface >= 100000 then flavour = "retail"
		elseif iface >= 50000 and iface <= 59999 then flavour = "mists"
		elseif iface >= 20000 and iface <= 29999 then flavour = "tbc"
		elseif iface >= 16000 and iface <= 16999 then flavour = "forever"
		elseif iface >= 10000 and iface <= 15999 then flavour = "era"
		else flavour = "unknown" end
	else
		flavour = "retail"
	end
end

local family
if flavour == "retail" or flavour == "forever" then family = "mainline"
elseif flavour == "unknown" and (iface or 0) >= 100000 then family = "mainline"
elseif flavour == "unknown" then family = "classic"
else family = "classic" end


-- levels per flavour: { retail, forever, tbc, era, mists } (design.md#capability-table)
local S, O = "supported", "off"
local caps = {}
do
-- one letter per flavour (retail, forever, tbc, era, mists): s supported, o off
local LEVELS = {
	reloadButton = "osooo",
	gfxCommand = "osooo",
	macroCommand = "osooo",
	surnames = "osooo",
	compartment = "sosss",
	modernMenu = "sssss",
	cContainer = "sssss",
	secretValues = "ssooo",
	guildBank = "sssos",
	friendsAnchor = "oosoo",
	modernAH = "ssoos",
	legacyAH = "oosso",
	mailInvoice = "sssss",
	ahMailSubjects = "sssss",
}
local col = (flavour == "retail" and 1) or (flavour == "forever" and 2) or (flavour == "tbc" and 3)
	or (flavour == "era" and 4) or (flavour == "mists" and 5)
if not col then col = (family == "mainline") and 1 or 4 end

-- probes: a false probe forces the level to off
local PROBES = {
	compartment = function() return AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon end,
	modernMenu = function() return Menu and Menu.ModifyMenu end,
	secretValues = function() return issecretvalue end,
	cContainer = function() return C_Container end,
	guildBank = function() return GetGuildBankItemInfo end,
	friendsAnchor = function() return FriendsFrame and FriendsFrame.NineSlice end,
	modernAH = function() return C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions end,
	legacyAH = function() return GetNumAuctionItems and GetAuctionItemInfo end,
	mailInvoice = function() return GetInboxInvoiceInfo end,
	ahMailSubjects = function() return AUCTION_EXPIRED_MAIL_SUBJECT and AUCTION_REMOVED_MAIL_SUBJECT end,
}

for cap, row in pairs(LEVELS) do
	local lvl = row:sub(col, col) == "s" and S or O
	local probe = PROBES[cap]
	if lvl ~= O and probe and not probe() then lvl = O end
	caps[cap] = lvl
end
end

M.PSS_FLV = {
	flavour = flavour, family = family, interface = iface, projectId = pid,
	digit = (flavour == "retail" and "1") or (flavour == "forever" and "2") or (flavour == "tbc" and "3")
		or (flavour == "era" and "4") or (flavour == "mists" and "5") or "0",
	caps = caps,
}
local FLV = M.PSS_FLV

V.wowIsRetail = (flavour == "retail")

function M.PSS_IsForever()
	return FLV.flavour == "forever"
end
M.PSS_IsCamelot = M.PSS_IsForever

function M.PSS_CapLevel(cap)
	return caps[cap] or O
end

function M.PSS_Can(cap)
	local lvl = caps[cap]
	if lvl == nil then
		local t = M.PSS_Test
		if t and t.strict then error("unknown capability: " .. tostring(cap), 2) end
		return false
	end
	return lvl ~= O
end
local CONST = { retail = { guildBankSlots = 98, maxBagSize = 36, lastBagIndex = 5, battlePetCage = 82800 },
	forever = { guildBankSlots = 98, maxBagSize = 36, lastBagIndex = 5, battlePetCage = 82800 },
	tbc = { guildBankSlots = 98, maxBagSize = 36, lastBagIndex = 4, battlePetCage = 0 },
	era = { guildBankSlots = 0, maxBagSize = 36, lastBagIndex = 4, battlePetCage = 0 },
	mists = { guildBankSlots = 98, maxBagSize = 36, lastBagIndex = 4, battlePetCage = 82800 } }
M.PSS_FLV.const = CONST[M.PSS_FLV.flavour] or CONST[M.PSS_FLV.family == "mainline" and "retail" or "era"]
