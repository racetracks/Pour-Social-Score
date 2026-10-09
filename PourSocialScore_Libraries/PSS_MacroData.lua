------------------------------------------------------------------------
-- POUR SOCIAL SCORE - MACRO HELPER DATA (/pss macro, 3.5.0, Camelot only)
--
-- The macros /pss macro <set> create writes. A set is "global" or a
-- class (key: the class in lower case, one of druid, hunter, mage,
-- paladin, priest, rogue, shaman, warlock, warrior; a class set runs on
-- that class only). Each macro goes to one store: store = "account"
-- (every character) or "character" (this character only). A macro's own
-- store wins, then its set's store, then the default: account for
-- "global", character for a class. /pss macro <set> create account (or
-- character) puts the whole run in one store. PSS owns these names: a
-- macro with the same name in the same store is set to this icon and
-- body. name: 1 to 16 letters, unique across every set; body: up to 255,
-- "\n" between lines; icon: a file ID (134400 is the question mark,
-- which #showtooltip turns into the used item's or spell's icon), or
-- leave it out for the question mark. ASCII only. Macros run in the
-- order written.
--
-- Built on each call and dropped by the caller, so no table stays in
-- memory between commands. Nothing is defined on other clients.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local iface = select(4, GetBuildInfo())
if type(iface) ~= "number" or iface >= 20000 then return end

function M.PSS_MacroData()
	return {
		global = {
			store = "account",
			{ name = "Trinket 1", body = "#showtooltip\n/use 13" },
			{ name = "Trinket 2", body = "#showtooltip\n/use 14" },
		},
		warrior = {
			store = "character",
			{ name = "Attack", body = "#showtooltip\n/startattack" },
		},
	}
end
