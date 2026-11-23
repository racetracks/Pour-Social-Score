------------------------------------------------------------------------
-- POUR SOCIAL SCORE - THE SOCIAL INDEXES (search-helper, STP-00245). The
-- lists as Spyglass indexes, through their accessors (never a member's saved
-- field directly; check_fields.lua):
--   players  owner name kind note w i g p c expires blizzard   (M.PSS_List, M.PSS_GetPlayerRecord;
--            w i g p c: 1 = allowed, as the window's ticks)
--   guilds   owner name rule members active shipped            (M.PSS_GuildRuleActive, M.PSS_GuildMemberCount)
--   members  owner guild name shipped whenBlocked              (M.PSS_ForEachGuildMember and the M.PSS_Member*
--            accessors; every shipped member only with Communities loaded: tier 1)
--   filters  owner id text tag on builtin                      (M.PSS_FilterRow)
-- Gate: Social Filtering. Read only. Loaded with Libraries.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local match, sort = string.match, table.sort

local History = M.PSS_History

local function allowed(rec, f)
	if type(rec) ~= "table" then return nil end
	return rec[f] == false and 1 or nil
end

M.PSS_IxDeclare({
	name = "players", kind = "state", owner = "social-manager", gate = "filtering", residency = 0,
	fields = { { "owner", "d", "p:<Name-Realm>" }, { "name", "s", "as listed" }, { "kind", "k", "player, npc or server" }, { "note", "s", "the note" },
		{ "w", "b", "whispers allowed" }, { "i", "b", "invites allowed" }, { "g", "b", "guild invites allowed" }, { "p", "b", "party chat allowed" },
		{ "c", "b", "channels allowed" }, { "expires", "t", "when the entry expires" }, { "blizzard", "b", "also on Blizzard's ignore list" } },
	dicts = { owner = "owner" }, pushdown = { "owner" },
	schemaKeys = { "players.list", "players.playerData", "players.delList" },
	doc = "the Player Ignore List",
	cost = function() return #M.PSS_List() end,
	scan = function(pd, emit)
		local r, n = {}, 0
		for _, e in ipairs(M.PSS_List()) do
			local kind = e.kind or "player"
			local key = kind == "player" and History.PlayerKey(e.name) or ("p:" .. tostring(e.name))
			if not pd.owner or pd.owner[key] then
				local rec = kind == "player" and M.PSS_GetPlayerRecord(e.name) or nil
				r.owner, r.name, r.kind, r.note = key, e.name, kind, e.note or ""
				r.w, r.i, r.g = allowed(rec, "whispersBlocked"), allowed(rec, "partyInvitesBlocked"), allowed(rec, "guildInvitesBlocked")
				r.p, r.c = allowed(rec, "partyRaidBlocked"), allowed(rec, "channelsBlocked")
				local exp = tonumber(e.exp) or 0
				local added = e.date and History.ParseTime(e.date)
				r.expires = (exp > 0 and added) and (added + exp * 86400) or nil
				r.blizzard = rec and rec.blizzardIgnore == true and 1 or nil
				n = n + 1
				if emit(r) == false then return n end
			end
		end
		return n
	end,
})

local function rules()
	local db = PourSocialScoreDB
	local keys = {}
	for k, g in pairs(db.guildData or {}) do if type(g) == "table" then keys[#keys + 1] = k end end
	sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys, db.guildData or {}
end

M.PSS_IxDeclare({
	name = "guilds", kind = "state", owner = "social-manager", gate = "filtering", residency = 0,
	fields = { { "owner", "d", "G:<guild key>" }, { "name", "s", "the guild" }, { "rule", "s", "the rule key" },
		{ "members", "n", "listed members (a rule keeps at most 1500)" }, { "active", "b", "the rule is on" }, { "shipped", "b", "from a shipped list" } },
	dicts = { owner = "owner" }, pushdown = { "owner" },
	schemaKeys = { "guilds.guildData", "guilds.guildExclusions", "guilds.guildGroupOpen" },
	doc = "the Guild Ignore List",
	scan = function(pd, emit)
		local keys, data = rules()
		local r, n = {}, 0
		for _, k in ipairs(keys) do
			local g = data[k]
			local owner = History.GuildKey(k)
			if not pd.owner or pd.owner[owner] then
				r.owner, r.name, r.rule = owner, g.name or k, k
				r.members = M.PSS_GuildMemberCount(g, k)
				r.active = M.PSS_GuildRuleActive(g) and 1 or nil
				r.shipped = g.managed ~= nil and 1 or nil
				n = n + 1
				if emit(r) == false then return n end
			end
		end
		return n
	end,
})

local function communitiesLoaded()
	local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	return f and f("PourSocialScore_Communities") and true or false
end

M.PSS_IxDeclare({
	name = "members", kind = "state", owner = "community-helper", gate = "filtering", residency = 1, needs = "Communities",
	loaded = communitiesLoaded,
	fields = { { "owner", "d", "g:<member>" }, { "guild", "d", "the rule key" }, { "name", "s", "the member" },
		{ "shipped", "b", "a shipped list's member" }, { "whenBlocked", "s", "when added (Managed list for a shipped member)" } },
	dicts = { owner = "owner" }, pushdown = { "guild" },
	schemaKeys = { "guilds.guildData" },
	doc = "the members of every guild rule",
	scan = function(pd, emit, ctx)
		local keys, data = rules()
		local r, n, stop = {}, 0, false
		local all = ctx.load and communitiesLoaded()
		for _, k in ipairs(keys) do
			if stop then break end
			local g = data[k]
			M.PSS_ForEachGuildMember(g, k, function(m, key)
				if stop then return end
				r.owner = History.MemberKey(m)
				r.guild = k
				r.name = M.PSS_MemberName(m, key)
				r.shipped = M.PSS_MemberShipped(m, g) and 1 or nil
				local wb = M.PSS_MemberWhenBlocked(m)
				r.whenBlocked = wb ~= nil and tostring(wb) or nil
				n = n + 1
				if emit(r) == false then stop = true end
			end, all)
		end
		return n
	end,
})

M.PSS_IxDeclare({
	name = "filters", kind = "state", owner = "social-manager", gate = "filtering", residency = 0,
	fields = { { "owner", "d", "f:<filter id>" }, { "id", "n", "the filter id (never reused)" }, { "text", "s", "the filter" },
		{ "tag", "s", "its description" }, { "on", "b", "switched on" }, { "builtin", "b", "a built-in filter" } },
	dicts = { owner = "owner" }, pushdown = { "owner" },
	schemaKeys = { "rules.filterList", "rules.filterDesc", "rules.filterActive", "rules.filterID", "rules.builtinRules", "rules.nextFilterId" },
	doc = "the chat filters",
	scan = function(pd, emit)
		local r, n, row = {}, 0, {}
		for i = 1, M.PSS_FilterCount() do
			if M.PSS_FilterRow(i, row) then
				local owner = M.PSS_FilterOwnerKey(i)
				if not pd.owner or pd.owner[owner] then
					r.owner, r.id = owner, tonumber(match(tostring(owner), "^f:(%d+)$"))
					r.text, r.tag, r.on, r.builtin = row.filter, row.desc, row.active and 1 or nil, row.builtin and 1 or nil
					n = n + 1
					if emit(r) == false then return n end
				end
			end
		end
		return n
	end,
})
