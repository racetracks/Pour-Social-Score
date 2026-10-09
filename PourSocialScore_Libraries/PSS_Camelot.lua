------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE CAMELOT NAME REPAIR (core uplift S3, step 10)
--
-- On Camelot (WoW Forever) a character is "First Last". Before 3.4.1.33 the
-- names built from a unit (target, mouseover, group, the unit menus) joined
-- the surname to the first name with "-" as if it were a realm, so people
-- were stored as "first-last" and never matched what chat and /who give
-- ("first last-classicbetapvp"). Upgrade step 10 repairs the saved ones, on
-- a Camelot save only (the core checks the client and the realm before it
-- loads this file):
--   * a guild member found by a unit ("first-last", with a faction, with no
--     key from /who): merged into the shipped member of that rule, else into
--     its stored twin, else stored again as "first last-<own realm>"
--   * a Player Ignore List entry, its record and the recently removed names
--     (delList): the same name; an entry whose repaired name is already
--     listed is dropped, the listed one wins
--   * the block lines and recent counts owned by the old name move to the new
-- A name that lost its surname cannot be repaired; the entries that may be
-- one are named once in chat.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M
local History = M.PSS_History

-- "first-last" -> display, key, canon of "first last-<own realm>"; nil when
-- the part after the dash is a realm of this client (or the name is not
-- that shape)
local function surnameFix(key)
	if type(key) ~= "string" then return nil end
	local base, tail = key:match("^([^%-%s]+)%-([^%-%s]+)$")
	if not base then return nil end
	local realm = M.PSS_CanonRealm(tail)
	if not realm or realm:find("^classicbetapvp") then return nil end
	return M.PSS_NormName(base .. " " .. tail .. "-" .. M.PSS_OwnRealm())
end

-- block lines and recent counts of the old owner go to the new one
local function moveOwner(prefix, oldKey, newKey)
	local from, to = M.PSS_CanonPlayer(oldKey), M.PSS_CanonPlayer(newKey)
	if from and to and from ~= to then History.RenameOwner(prefix .. from, prefix .. to) end
end

-- the guild members; returns how many records were repaired
local function repairMembers()
	local n = 0
	local guilds = (PourSocialScoreDB and PourSocialScoreDB.guildData) or {}
	for gkey, g in pairs(guilds) do
		if type(g) == "table" and type(g.members) == "table" then
			local todo = {}
			for k, m in pairs(g.members) do
				if type(m) == "table" and m.faction ~= nil and not M.PSS_MemberHasPlayerKey(m) and surnameFix(k) then
					todo[#todo + 1] = k
				end
			end
			table.sort(todo)
			for _, k in ipairs(todo) do
				local m = g.members[k]
				local display, key, canon = surnameFix(k)
				if m and key and canon then
					if History.CountTotal(m.blockCounts) > 0 and not History.Loaded() then M.PSS_LoadLogging() end
					local twin = g.members[key]
					if g.managed and M.PSS_MergeIntoShipped(gkey, canon, m) then
						g.members[k] = nil
						n = n + 1
					elseif twin and twin ~= m then
						M.PSS_MergeMember(twin, m)
						g.members[k] = nil
						n = n + 1
					elseif not twin then
						m.name = display
						g.members[key] = m
						g.members[k] = nil
						n = n + 1
					else
						key = nil
					end
					if key then moveOwner("g:", k, key) end
				end
			end
		end
	end
	if n > 0 and M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
	return n
end

-- the Player Ignore List and the recently removed names; how many entries
local function repairPlayers()
	local db = PourSocialScoreDB
	if type(db) ~= "table" then return 0 end
	local n = 0
	local list = type(db.list) == "table" and db.list or {}
	local have = {}
	for _, e in ipairs(list) do
		if type(e) == "table" and type(e.name) == "string" then have[(e.kind or "player") .. ":" .. e.name:lower()] = true end
	end
	local i = 1
	while i <= #list do
		local e = list[i]
		local fix = type(e) == "table" and (e.kind or "player") == "player" and type(e.name) == "string"
			and select(1, surnameFix(M.PSS_NormalizePlayer(e.name)))
		if fix then
			local oldKey, newKey = M.PSS_NormalizePlayer(e.name), M.PSS_NormalizePlayer(fix)
			local pd = db.playerData
			if have["player:" .. fix:lower()] then
				-- already listed under the repaired name: that entry stays
				table.remove(list, i)
				if pd and oldKey then pd[oldKey] = nil end
			else
				have["player:" .. e.name:lower()] = nil
				have["player:" .. fix:lower()] = true
				e.name = fix
				if pd and oldKey and pd[oldKey] and newKey and not pd[newKey] then
					pd[newKey] = pd[oldKey]
					pd[newKey].name = fix
				end
				if pd and oldKey and oldKey ~= newKey then pd[oldKey] = nil end
				i = i + 1
			end
			moveOwner("p:", oldKey, newKey)
			n = n + 1
		else
			i = i + 1
		end
	end
	local del = type(db.delList) == "table" and db.delList or {}
	local out, seen = {}, {}
	for _, name in ipairs(del) do
		local fix = type(name) == "string" and select(1, surnameFix(M.PSS_NormalizePlayer(name)))
		if fix then n = n + 1 end
		local use = fix or name
		if type(use) == "string" and not seen[use:lower()] then
			seen[use:lower()] = true
			out[#out + 1] = use
		end
	end
	for j = 1, #del do del[j] = out[j] end
	if n > 0 and M.PSS_MarkIgnoreIndexDirty then M.PSS_MarkIgnoreIndexDirty() end
	return n
end

-- listed names that may have lost their surname: "First-Classicbetapvp"
-- with a faction (found by a unit), in the spelling the broken path gave
local function maybeFirstNameOnly()
	local out = {}
	for _, e in ipairs((PourSocialScoreDB and PourSocialScoreDB.list) or {}) do
		if type(e) == "table" and (e.kind or "player") == "player" and e.faction ~= nil and type(e.name) == "string"
			and e.name:find("^[^%-%s]+%-Classicbetapvp$") then
			out[#out + 1] = e.name
		end
	end
	return out
end

-- Upgrade step 10 (Camelot saves). Returns members, players, the names that
-- may be first name only.
function M.PSS_RepairCamelotNames()
	local members = repairMembers()
	local players = repairPlayers()
	return members, players, maybeFirstNameOnly()
end
