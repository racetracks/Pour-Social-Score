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
-- body. name: 1 to 16 letters, unique within its set (two class sets
-- may share one, a global name is unique across every set); body: up to 255,
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

if not M.PSS_Can("macroCommand") then return end
if not M.PSS_Can("macroCommand") then return end

function M.PSS_MacroData()
	return {
		global = {
			store = "account",
			{ name = "Trinket 1", body = "#showtooltip\n/use 13" },
			{ name = "Trinket 2", body = "#showtooltip\n/use 14" },
			{ name = "Mark-Skull", icon = 132095, body = "/tm 8" },
			{ name = "Mark-X", icon = 132094, body = "/tm 7" },
			{ name = "Mark-Moon", icon = 133938, body = "/tm 5" },
			{ name = "Face", icon = 132202, body = "/s {square}{square}{square}{square}{square}\n/s {square}{circle}{square}{circle}{square}\n/s {square}{square}{square}{square}{square}\n/s {square}{triangle}{triangle}{triangle}{square}\n/s {square}{square}{square}{square}{square}" },
			{ name = "RaidGroup", body = "/invite Neo\n/script ConvertToRaid()\n/run LeaveParty()" },
			{ name = "Focus", icon = 132089, body = "/focus" },
			{ name = "TarFocus", icon = 132094, body = "/tar focus" },
			{ name = "HolyWater", body = "#showtooltip Stratholme Holy Water\n/use [@player] Stratholme Holy Water" },
		},
		priest = {
			store = "character",
			{ name = "PWS", body = "#showtooltip Power Word: Shield\n/cast [target=mouseover,exists,help][help][target=player][]Power Word: Shield" },
			{ name = "RN", body = "#showtooltip Renew\n/cast [harm] Shadow Word: Pain\n/cast [help, target=mouseover,exists,help][]Renew" },
			{ name = "Dispel", body = "#showtooltip dispel magic\n/cast [help, target=mouseover,exists,help]dispel magic\n/cast [harm] dispel magic" },
			{ name = "FH", body = "#showtooltip flash heal\n/cast [target=mouseover,exists,help][]flash heal\n/cast [harm] smite" },
			{ name = "H", body = "#showtooltip Heal\n/cast [target=mouseover,exists,help][]Heal\n/cast [harm] Mind Blast" },
			{ name = "GH", body = "#showtooltip Greater Heal\n/cast [target=mouseover,exists,help][]Greater Heal\n/cast [harm] Holy Fire" },
			{ name = "PoM", body = "#showtooltip Prayer of Mending\n/cast [target=mouseover,exists,help][]Prayer of Mending\n/cast [harm] Shadow Word: Death" },
			{ name = "AD", body = "#showtooltip abolish disease\n/cast [target=mouseover,exists,help][]abolish disease" },
			{ name = "Fort", body = "#showtooltip\n/cast [nomodifier] Power Word: Fortitude\n/cast [mod:shift] Prayer of Fortitude" },
			{ name = "DS", body = "#showtooltip\n/cast [nomodifier] Divine Spirit\n/cast [mod:shift] Prayer of Spirit" },
			{ name = "SP", body = "#showtooltip\n/cast [nomodifier] shadow protection\n/cast [mod:shift] prayer of shadow protection" },
			{ name = "PI", body = "#showtooltip Power Infusion\n/cast [target=mouseover,exists,help][]Power Infusion" },
			{ name = "MS", body = "#showtooltip mind soothe\n/cast [target=mouseover,exists,harm][]mind soothe" },
		},
		shaman = {
			store = "character",
			{ name = "HW", body = "#showtooltip Healing Wave\n/cast [help, target=mouseover,exists,help,nodead][]Healing Wave" },
			{ name = "LHW", body = "#showtooltip Lesser Healing Wave\n/cast [help, target=mouseover,exists,help,nodead][]Lesser Healing Wave" },
			{ name = "CH", body = "#showtooltip Chain Heal\n/cast [help, target=mouseover,exists,help,nodead][]Chain Heal" },
			{ name = "RT", body = "#showtooltip Riptide\n/cast [help, target=mouseover,exists,help,nodead][]Riptide" },
			{ name = "SS", body = "#showtooltip Stormstrike\n/cast stormstrike\n/startattack" },
		},
		warrior = {
			store = "character",
			{ name = "Attack", body = "#showtooltip\n/startattack" },
			{ name = "BT", body = "#showtooltip\n/cast bloodthirst\n/startattack" },
			{ name = "SS", body = "#showtooltip\n/cast shield slam\n/startattack" },
			{ name = "TC", body = "#showtooltip\n/cast thunder clap\n/startattack" },
			{ name = "Sunder", body = "#showtooltip\n/cast sunder armor\n/startattack" },
			{ name = "Revenge", body = "#showtooltip\n/cast revenge\n/startattack" },
			{ name = "HS", body = "#showtooltip\n/cast heroic strike\n/startattack" },
			{ name = "Cleave", body = "#showtooltip\n/cast cleave\n/startattack" },
		},
	}
end
