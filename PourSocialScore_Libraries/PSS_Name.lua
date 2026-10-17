------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE NAME HELPER (one-build plan A09). Characters and
-- guilds are keyed through these two services by the warehouse, the money
-- service and later the journal, so one name always reaches one entity.
-- Input: a key "Name-Realm" or rows of name, realm; opts.kind "c" (default)
-- | "g" | "w", opts.create to make the entity.
--   name.norm  -> display, name, realm   (M.PSS_NormName: Camelot surnames)
--   name.ent   -> ent                    (M.PSS_EntityId)
-- Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local function nameRow(row)
	local name, realm = row[1], row[2]
	if realm == nil and type(name) == "string" then
		local n, r = name:match("^(.*)-([^-]*)$")
		if n then name, realm = n, r end
	end
	return name, realm
end

M.PSS_Provide("name.norm", function(input)
	local out = M.PSS_Set({ "display", "name", "realm" })
	for i = 1, input.n do
		local name, realm = nameRow(input[i])
		local display = M.PSS_NormName(name, realm)
		if display then
			local n, r = display:match("^(.*)-([^-]*)$")
			M.PSS_SetAdd(out, { display, n or display, r or "" })
		end
	end
	return out
end, { accepts = { "key" }, returns = { "display", "name", "realm" }, doc = "the one display name of a character", cost = "O(rows)", writes = false, onError = "empty" })

M.PSS_Provide("name.ent", function(input, opts)
	local out = M.PSS_Set({ "ent" })
	for i = 1, input.n do
		local name, realm = nameRow(input[i])
		local id = M.PSS_EntityId(opts and opts.kind or "c", name, realm, opts and opts.create)
		if id then M.PSS_SetAdd(out, { id }) end
	end
	return out
end, { accepts = { "key" }, returns = { "ent" }, doc = "the entity id of a character, guild or the warband", cost = "O(rows)", writes = false, onError = "empty" })
