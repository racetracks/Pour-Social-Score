------------------------------------------------------------------------
-- POUR SOCIAL SCORE - IMPORT / EXPORT
--
-- Export the chosen sections to one text string; import a string with
-- Merge (add what's missing, keep what you have) or Replace (the section
-- becomes exactly what was imported).
--
-- Format:  PSS1:<checksum>:<base64 payload>
-- The payload is a small typed serialisation (never executed as code), so
-- an import string can only ever contain data. Its field v is the format
-- version: 2 (3.4.1.47, core uplift U3) adds "more" to a player, guild or
-- member: the record's fields this version does not know (a newer
-- version's), kept so a version that knows them gets them back. Older
-- versions ignore v and more; the tag stays PSS1, so they still read it.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local FORMAT_TAG = "PSS1"

------------------------------------------------------------------------
-- Serialiser: T/F booleans, n<number>; , s<len>:<bytes>, { k v k v ... }
------------------------------------------------------------------------
local function ser(v, out)
	local t = type(v)
	if t == "boolean" then out[#out + 1] = v and "T" or "F"
	elseif t == "number" then out[#out + 1] = "n" .. tostring(v) .. ";"
	elseif t == "string" then out[#out + 1] = "s" .. #v .. ":" .. v
	elseif t == "table" then
		out[#out + 1] = "{"
		local keys = {}
		for k in pairs(v) do if type(k) == "string" or type(k) == "number" then keys[#keys + 1] = k end end
		table.sort(keys, function(a, b)
			if type(a) == type(b) then return a < b end
			return type(a) == "number"
		end)
		for _, k in ipairs(keys) do
			local val = v[k]
			local vt = type(val)
			if vt == "boolean" or vt == "number" or vt == "string" or vt == "table" then
				ser(k, out); ser(val, out)
			end
		end
		out[#out + 1] = "}"
	end
end

local function deser(s, pos, depth)
	if depth > 40 then error("nesting too deep") end
	local c = s:sub(pos, pos)
	if c == "T" then return true, pos + 1
	elseif c == "F" then return false, pos + 1
	elseif c == "n" then
		local e = s:find(";", pos, true)
		if not e then error("bad number") end
		local n = tonumber(s:sub(pos + 1, e - 1))
		if not n then error("bad number") end
		return n, e + 1
	elseif c == "s" then
		local colon = s:find(":", pos, true)
		if not colon then error("bad string") end
		local len = tonumber(s:sub(pos + 1, colon - 1))
		if not len or len < 0 then error("bad string length") end
		local str = s:sub(colon + 1, colon + len)
		if #str ~= len then error("truncated string") end
		return str, colon + len + 1
	elseif c == "{" then
		local t = {}
		pos = pos + 1
		while true do
			if pos > #s then error("unterminated table") end
			if s:sub(pos, pos) == "}" then return t, pos + 1 end
			local k, v
			k, pos = deser(s, pos, depth + 1)
			if type(k) ~= "string" and type(k) ~= "number" then error("bad key") end
			v, pos = deser(s, pos, depth + 1)
			t[k] = v
		end
	end
	error("unexpected data at " .. pos)
end

------------------------------------------------------------------------
-- Base64 (Lua 5.1, no bit library needed) + checksum
------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64IDX = {}
for i = 1, 64 do B64IDX[B64:sub(i, i)] = i - 1 end

local function b64enc(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1) ..
			(b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

local function b64dec(text)
	text = text:gsub("[^%w%+/=]", "")
	if #text % 4 ~= 0 then error("damaged text (length)") end
	local out = {}
	for i = 1, #text, 4 do
		local q = { text:byte(i, i + 3) }
		local n, pad = 0, 0
		for j = 1, 4 do
			local ch = string.char(q[j])
			local v
			if ch == "=" then v = 0; pad = pad + 1 else v = B64IDX[ch] end
			if not v then error("damaged text (character)") end
			n = n * 64 + v
		end
		local a = math.floor(n / 65536) % 256
		local b = math.floor(n / 256) % 256
		local c = n % 256
		if pad == 0 then out[#out + 1] = string.char(a, b, c)
		elseif pad == 1 then out[#out + 1] = string.char(a, b)
		else out[#out + 1] = string.char(a) end
	end
	return table.concat(out)
end

local function checksum(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 16777213 end
	return string.format("%06x", h)
end

function M.PSS_EncodeExport(tbl)
	local out = {}
	ser(tbl, out)
	local payload = table.concat(out)
	return FORMAT_TAG .. ":" .. checksum(payload) .. ":" .. b64enc(payload)
end

function M.PSS_DecodeExport(text)
	if type(text) ~= "string" then return nil, "nothing to import" end
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	local tag, sum, body = text:match("^(%w+):(%x+):(.+)$")
	if tag ~= FORMAT_TAG then return nil, "this is not a Pour Social Score export string" end
	local okB, payload = pcall(b64dec, body)
	if not okB then return nil, tostring(payload) end
	if checksum(payload) ~= sum:lower() then return nil, "the text is incomplete or was changed (checksum mismatch) - copy the whole string" end
	local okD, data, pos = pcall(deser, payload, 1, 0)
	if not okD then return nil, "could not read the data: " .. tostring(data) end
	if type(data) ~= "table" or pos ~= #payload + 1 then return nil, "could not read the data" end
	return data
end

------------------------------------------------------------------------
-- Build / apply
------------------------------------------------------------------------
local PREF_FIELDS = { unpack(M.PSS_BLOCK_FIELDS) }
PREF_FIELDS[#PREF_FIELDS + 1] = "nickname"
local BLOCK_CATS = M.PSS_EXCL_CATS
-- W I G P C flags (true/false; missing = inherit for members)
local function copyBlock(b)
	if type(b) ~= "table" then return nil end
	local t = {}
	for _, c in ipairs(BLOCK_CATS) do if type(b[c]) == "boolean" then t[c] = b[c] end end
	return t
end
local GUILD_FIELDS = { "enabled", "declineGuild", "declineGroup", "partyRaid", "customScan", "ruleOrigin" }
local MEMBER_FIELDS = { "name", "guild", "whenBlocked", "note", "excludedGroup", "excludedGuildInvite",
						"excludedWhispers", "excludedChat", "class", "className", "level", "race", "_playerKey" }

local function copyFields(src, fields)
	local t = {}
	for _, f in ipairs(fields) do
		local v = src[f]
		if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then t[f] = v end
	end
	return t
end

-- a plain copy of saved data (no functions, no shared tables)
local function plain(v, depth)
	if type(v) ~= "table" then
		local t = type(v)
		return (t == "string" or t == "number" or t == "boolean") and v or nil
	end
	if depth > 8 then return nil end
	local t = {}
	for k, x in pairs(v) do
		if type(k) == "string" or type(k) == "number" then t[k] = plain(x, depth + 1) end
	end
	return t
end

-- The fields of record src this version does not know (schema kind), or nil
-- (export format 2). The _ fields are runtime fields, never exported.
local function moreFields(src, kind)
	if type(src) ~= "table" or not M.PSS_SchemaKnows then return nil end
	local t
	for k, v in pairs(src) do
		if type(k) == "string" and k:sub(1, 1) ~= "_" and not M.PSS_SchemaKnows(kind, k) then
			t = t or {}
			t[k] = plain(v, 0)
		end
	end
	return t
end

-- An import's "more" fields onto record dst: only those this version does
-- not know, never over a field it has.
local function keepMore(dst, more, kind)
	if type(dst) ~= "table" or type(more) ~= "table" or not M.PSS_SchemaKnows then return end
	for k, v in pairs(more) do
		if type(k) == "string" and k:sub(1, 1) ~= "_" and not M.PSS_SchemaKnows(kind, k) and dst[k] == nil then
			dst[k] = plain(v, 0)
		end
	end
end

local function copyOpts(o)
	if type(o) ~= "table" then return nil end
	local t = {}
	for k, v in pairs(o) do if type(k) == "string" and (type(v) == "boolean" or type(v) == "number" or type(v) == "string") then t[k] = v end end
	return next(t) and t or nil
end

-- An imported option value checked against its definition: a tick box takes
-- true / false, a number is whole and kept in its range, a drop-down takes
-- one of its choices (a font name too: LibSharedMedia fonts are not listed).
-- ok, value
local function importedOption(def, v)
	if type(def) ~= "table" then return false end
	if def.kind == "bool" then return type(v) == "boolean", v end
	if def.kind == "number" then
		v = tonumber(v)
		if not v then return false end
		v = math.floor(v)
		if def.min and v < def.min then v = def.min end
		if def.max and v > def.max then v = def.max end
		return true, v
	end
	if def.kind == "choice" then
		for _, c in ipairs(def.choices or {}) do
			if c[1] == v then return true, v end
		end
		return type(v) == "string" and type(def.default) == "string", v
	end
	return false
end

-- one guild rule (and its stored members) as an export entry
local function guildEntry(key, g, members)
	local e = copyFields(g, GUILD_FIELDS)
	e.block = copyBlock(M.PSS_GuildBlock and M.PSS_GuildBlock(g) or g.block)
	e.name = g.name or key
	e.opts = copyOpts(g.opts)
	e.more = moreFields(g, "guild")
	if members then
		e.members = {}
		for mk, m in pairs(g.members or {}) do
			if type(m) == "table" then
				local me = copyFields(m, MEMBER_FIELDS)
				-- every field, filled through the accessors (S3 stops saving some)
				me.name, me.guild, me.whenBlocked = M.PSS_MemberName(m, mk), M.PSS_MemberGuildName(m, g), M.PSS_MemberWhenBlocked(m)
				me.block = copyBlock(M.PSS_MemberBlock and M.PSS_MemberBlock(m) or m.block)
				me.key = mk
				me.opts = copyOpts(m.opts)
				me.more = moreFields(m, "member")
				e.members[#e.members + 1] = me
			end
		end
	end
	return e
end

-- sections: { players, guilds, members, filters, builtins, options }
function M.PSS_BuildExport(sections)
	local db = PourSocialScoreDB
	local data = { v = 2, addon = "PourSocialScore", made = date("%Y-%m-%d %H:%M"), by = M.PSS_CharKey and M.PSS_CharKey() or "" }
	if sections.players then
		data.players = {}
		for _, le in ipairs(db.list or {}) do
			local name = le.name
			local e = {
				name = name, type = le.kind or "player", note = le.note or "",
				date = le.date or "", exp = tonumber(le.exp) or 0, faction = le.faction or "",
			}
			if e.type == "player" then
				local p = M.PSS_GetPlayerRecord and M.PSS_GetPlayerRecord(name)
				if p then
					e.prefs = copyFields(p, PREF_FIELDS)
					-- W I G P C: every switch, a missing one blocks (S3 saves only the false ones)
					for _, f in ipairs(PREF_FIELDS) do if f ~= "nickname" then e.prefs[f] = p[f] ~= false end end
					e.opts = copyOpts(p.opts); e.more = moreFields(p, "player")
				end
			end
			data.players[#data.players + 1] = e
		end
	end
	if sections.guilds then
		data.guilds = {}
		for key, g in pairs(db.guildData or {}) do
			if type(g) == "table" then data.guilds[#data.guilds + 1] = guildEntry(key, g, sections.members) end
		end
	end
	if sections.filters then
		data.filters = {}
		for i = 1, #(db.filterList or {}) do
			if not M.PSS_IsBuiltinFilter(i) then
				data.filters[#data.filters + 1] = { desc = db.filterDesc[i] or "", filter = db.filterList[i] or "", active = db.filterActive[i] == true }
			end
		end
	end
	if sections.builtins then
		data.builtins = {}
		for i = 1, #(db.filterList or {}) do
			if M.PSS_IsBuiltinFilter(i) then data.builtins[db.filterID[i]] = db.filterActive[i] == true end
		end
	end
	if sections.options then
		data.options = {}
		for _, o in ipairs(M.PSS_OPTIONS or {}) do
			if db[o.key] ~= nil then data.options[o.key] = db[o.key] end
		end
	end
	return data
end

function M.PSS_DescribeImport(data)
	local parts = {}
	if data.players then parts[#parts + 1] = #data.players .. " ignore list entr" .. (#data.players == 1 and "y" or "ies") end
	if data.guilds then
		local m = 0
		for _, g in ipairs(data.guilds) do m = m + #(g.members or {}) end
		parts[#parts + 1] = #data.guilds .. " guild rule" .. (#data.guilds == 1 and "" or "s") .. (m > 0 and (" (" .. m .. " members)") or "")
	end
	if data.filters then parts[#parts + 1] = #data.filters .. " custom chat filter" .. (#data.filters == 1 and "" or "s") end
	if data.builtins then local n = 0; for _ in pairs(data.builtins) do n = n + 1 end; parts[#parts + 1] = n .. " built-in filter states" end
	if data.options then local n = 0; for _ in pairs(data.options) do n = n + 1 end; parts[#parts + 1] = n .. " options" end
	return #parts > 0 and table.concat(parts, ", ") or "nothing"
end

-- mode: "merge" | "replace"; sections: which parts of the data to apply
function M.PSS_ApplyImport(data, mode, sections)
	local db = PourSocialScoreDB
	local replace = mode == "replace"
	local report = {}

	local ownBatch
	if not M.PSS__purgeBatch then ownBatch = {}; M.PSS__purgeBatch = ownBatch end
	if sections.players and type(data.players) == "table" then
		if replace and M.PSS_RemoveListEntryAt then
			for i = #db.list, 1, -1 do M.PSS_RemoveListEntryAt(i) end
		end
		local added = 0
		for _, e in ipairs(data.players) do
			if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
				local t = (e.type == "npc" or e.type == "server") and e.type or "player"
				local exists
				if t == "player" then exists = M.PSS_IsPlayerListed(e.name)
				elseif t == "npc" then exists = M.hasNPCIgnored(e.name) > 0
				else exists = false; for _, le in ipairs(db.list) do if le.kind == "server" and le.name == e.name then exists = true end end end
				if not exists and M.PSS_ImportListEntry then
					M.PSS_ImportListEntry(e.name, e.faction, e.note, t, e.date, e.exp)
					added = added + 1
				end
				if t == "player" then
					local p = M.PSS_GetPlayerPrefs(e.name)
					if p and type(e.prefs) == "table" and (replace or not exists) then
						for _, f in ipairs(PREF_FIELDS) do
							local v = e.prefs[f]
							-- (a switch that blocks is not stored)
							if v ~= nil then p[f] = (f ~= "nickname" and v == true) and nil or v end
						end
						p.opts = copyOpts(e.opts)
						keepMore(p, e.more, "player")
					end
				end
			end
		end
		report[#report + 1] = added .. " ignore list entries added"
	end

	if sections.guilds and type(data.guilds) == "table" then
		if replace then M.PSS_ClearGuildRules() end
		local addedG, addedM = 0, 0
		for _, ge in ipairs(data.guilds) do
			if type(ge) == "table" and type(ge.name) == "string" and ge.name ~= "" then
				-- the key guild rules are stored under (N45)
				local key = M.PSS_NormalizeGuild(ge.name)
				local existed = key ~= nil and db.guildData[key] ~= nil
				local g = M.PSS_GetGuild(ge.name)
				if g then
					if not existed then
						addedG = addedG + 1
						for _, f in ipairs(GUILD_FIELDS) do if ge[f] ~= nil then g[f] = ge[f] end end
						g.opts = copyOpts(ge.opts)
						-- older export strings have no W I G P C: rebuild from their old fields
						g.block = copyBlock(ge.block)
						keepMore(g, ge.more, "guild")
					end
					if sections.members and type(ge.members) == "table" then
						for _, me in ipairs(ge.members) do
							if type(me) == "table" and type(me.name) == "string" and me.name ~= "" then
								-- one key for every name; a shipped member merges into the shipped record
								local mk = M.PSS_NormalizePlayer((type(me.key) == "string" and me.key:find("-", 1, true)) and me.key or me.name)
								local ck = mk and M.PSS_CanonPlayer(mk)
								local shipped
								if mk and not g.members[mk] and ck and M.PSS_MergeIntoShipped then
									local m = copyFields(me, MEMBER_FIELDS)
									m.opts = copyOpts(me.opts)
									m.block = copyBlock(me.block)
									shipped = M.PSS_MergeIntoShipped(key, ck, m)
								end
								if mk and not shipped and not g.members[mk] then
									local m = copyFields(me, MEMBER_FIELDS)
									m.opts = copyOpts(me.opts)
									m.block = copyBlock(me.block)	-- nil = converted from the old Allow fields
									m.guild = g.name
									m.whenBlocked = m.whenBlocked or M.PSS_NowString()
									keepMore(m, me.more, "member")
									for _, f in ipairs({ "excludedGroup", "excludedGuildInvite", "excludedWhispers", "excludedChat" }) do
										if m[f] ~= true then m[f] = nil end
									end
									if M.PSS_CompactMember then M.PSS_CompactMember(m) end		-- only non-default fields are kept
									g.members[mk] = m
									addedM = addedM + 1
									if ck and M.PSS_GuildRuleActive(g) and M.PSS__purgeBatch then M.PSS__purgeBatch[ck] = true end
								end
							end
						end
					end
					M.PSS_StoreMemberCount(g)
					if M.PSS_RefreshGuildActive then M.PSS_RefreshGuildActive(g) end
				end
			end
		end
		if M.PSS_MarkGuildIndexDirty then M.PSS_MarkGuildIndexDirty() end
		report[#report + 1] = addedG .. " guild rules and " .. addedM .. " members added"
	end

	if sections.filters and type(data.filters) == "table" then
		if replace then
			for i = #db.filterList, 1, -1 do
				if not M.PSS_IsBuiltinFilter(i) then M.RemoveChatFilter(i) end
			end
		end
		local have, added = {}, 0
		for i = 1, #db.filterList do have[(db.filterList[i] or "") .. "\1" .. (db.filterDesc[i] or "")] = true end
		for _, fe in ipairs(data.filters) do
			if type(fe) == "table" and type(fe.filter) == "string" and fe.filter ~= "" then
				local sig = fe.filter .. "\1" .. tostring(fe.desc or "")
				if not have[sig] then
					M.PSS_AddCustomFilter(tostring(fe.desc or "Imported filter"), fe.filter, fe.active == true)
					have[sig] = true
					added = added + 1
				end
			end
		end
		report[#report + 1] = added .. " custom chat filters added"
	end

	if sections.builtins and type(data.builtins) == "table" then
		local n = 0
		for i = 1, #db.filterList do
			local id = db.filterID[i]
			if M.PSS_IsBuiltinFilter(i) and type(data.builtins[id]) == "boolean" then
				M.PSS_SetFilterActive(i, data.builtins[id]); n = n + 1
			end
		end
		report[#report + 1] = n .. " built-in filter states set"
	end

	if sections.options and type(data.options) == "table" then
		local n = 0
		for key, v in pairs(data.options) do
			local def = M.PSS_OPTION_REG and M.PSS_OPTION_REG[key]
			local ok, value = importedOption(def, v)
			if ok then
				-- through the setter: defaults are not stored, the windows
				-- repaint (OPTION_CHANGED)
				M.PSS_SetOpt(key, "global", value)
				n = n + 1
			end
		end
		report[#report + 1] = n .. " options set"
	end

	if ownBatch and M.PSS__purgeBatch == ownBatch then
		M.PSS__purgeBatch = nil
		if next(ownBatch) and M.PSS_PurgeChatFrom then M.PSS_PurgeChatFrom(ownBatch) end
	end
	if M.PSS_MarkIgnoreIndexDirty then M.PSS_MarkIgnoreIndexDirty() end
	-- an imported guild rule may be on: load the shipped member lists
	if M.PSS_LoadActiveManagedData then M.PSS_LoadActiveManagedData() end
	if M.PSS_RequestGC then M.PSS_RequestGC("import") end
	M.Events.Fire("PLAYERS_CHANGED", true)
	M.Events.Fire("GUILDS_CHANGED")
	M.Events.Fire("FILTERS_CHANGED")
	return table.concat(report, ", ")
end

-- /pss export unused (core uplift U3): the saved rules and settings this
-- version cannot use (M.PSS_UnusableRules), every field, as an export string
-- a version that knows them can import. nil when there are none.
function M.PSS_UnusedExportText()
	local db = PourSocialScoreDB
	local u = M.PSS_UnusableRules()
	if #u.filters + #u.guilds + #u.options == 0 then return nil end
	local data = { v = 2, addon = "PourSocialScore", made = date("%Y-%m-%d %H:%M"), by = M.PSS_CharKey and M.PSS_CharKey() or "",
		unused = true }
	if #u.filters > 0 then
		data.filters = {}
		for _, i in ipairs(u.filters) do
			data.filters[#data.filters + 1] = { desc = db.filterDesc[i] or "", filter = db.filterList[i] or "", active = db.filterActive[i] == true }
		end
	end
	if #u.guilds > 0 then
		data.guilds = {}
		for _, key in ipairs(u.guilds) do data.guilds[#data.guilds + 1] = guildEntry(key, db.guildData[key], true) end
	end
	if #u.options > 0 then
		data.options = {}
		for _, key in ipairs(u.options) do data.options[key] = plain(PSS_OptionsDB[key], 0) end
	end
	return M.PSS_EncodeExport(data)
end
