-------------------------------------------
-- Pour Social Score - MAINLINE COMPAT --
-------------------------------------------

local addonName, addon = ...
local M = addon.M

-- The client flavour flags (V.wowIs*) are set once, in PSS_Globals.lua.

-- Some older WoW UI helpers were global functions.  Keep the addon self
-- contained where Mainline has removed/renamed one of them.
if not _G.strlen then _G.strlen = string.len end
if not _G.strbyte then _G.strbyte = string.byte end

-- Modern clients can expose these APIs only after the relevant UI has loaded.
-- The core addon always checks the objects before using optional integrations.
M.PSS_Mainline = true
