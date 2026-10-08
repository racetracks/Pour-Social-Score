-- 3.0 loader: the one way the core loads its on-demand addons.
--   M.PSS_Need(key)          load a part (enable it first, as ElvUI does),
--                            say once if it is missing or a different version
--   M.PSS_Stub(fname, key)   a stand-in for M[fname] that loads the part on
--                            first call; the part's own M[fname] replaces it
-- Never call these from the chat filter, an invite handler or combat code:
-- parts load on a user action or a state change, never per line.
local addonName, addon = ...
local M, L = addon.M, addon.L

-- The one cross-addon global: on-demand addons reach M, V and L through it.
PourSocialScore_NS = addon

-- key -> addon folder. Nothing has moved out yet (Phase 3 fills these).
M.PSS_PARTS = {
	GUI = "PourSocialScore_GUI",
	Libraries = "PourSocialScore_Libraries",
	Logging = "PourSocialScore_Logging",
	Communities = "PourSocialScore_Communities",
}

-- C_AddOns on current clients, the old globals where it is missing
local function api(name)
	return (C_AddOns and C_AddOns[name]) or _G[name]
end

local function version(name)
	local get = api("GetAddOnMetadata")
	return get and get(name, "Version") or "?"
end

-- parts that need another part first (the windows call the back end)
local NEEDS = { GUI = "Libraries" }

local warned = {}

function M.PSS_Need(key)
	local name = M.PSS_PARTS[key]
	if not name then return false end
	if api("IsAddOnLoaded")(name) then return true end
	if NEEDS[key] and not M.PSS_Need(NEEDS[key]) then return false end
	local enable = api("EnableAddOn")
	if enable then enable(name, UnitName("player")) end
	local ok, reason = api("LoadAddOn")(name)
	if not ok then
		if not warned[name] then
			warned[name] = true
			reason = tostring(reason or "?")
			M.ShowMsg(string.format(L["PART_1"], name, _G["ADDON_" .. reason] or reason))
		end
		return false
	end
	local mine, theirs = version(addonName), version(name)
	if theirs ~= mine and not warned[name] then
		warned[name] = true
		M.ShowMsg(string.format(L["PART_2"], name, theirs, mine))
	end
	return true
end

function M.PSS_Stub(fname, key)
	local stub
	stub = function(...)
		if M.PSS_Need(key) and M[fname] ~= stub then return M[fname](...) end
	end
	M[fname] = stub
end
