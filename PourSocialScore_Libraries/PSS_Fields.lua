------------------------------------------------------------------------
-- POUR SOCIAL SCORE - FIELDS (search-helper, Spyglass display text). Pure
-- functions that turn a raw field value into the text a user reads; no
-- frames, nothing saved. Sort, Copy line, CSV and a click's term keep the
-- raw value.
--   local F = M.PSS_Fields
--   F.show(kind, v, col) -> text          the one cell formatter (M.PSS_CellText calls it)
--   F.money(copper) -> "12,345g 6s 7c"    coin colours, zero units left out, "0c" for 0
--   F.moneyParse(text) -> copper | nil    "12g50s", "1,000g", "75" (plain digits are copper)
--   F.splitName(name) -> sender, server   server is myRealm() when the name has no "-"
--   F.myRealm() -> text                   normalised realm of this character
--   F.filterNames() -> { [ownerKey] = text }   one entry per chat filter: its name (filterDesc), else its pattern
--   F.sourceName(row) -> name | nil       the sender of a log or counts row (member, else its owner's name)
--   M.PSS_FieldLabel(field) -> label      M.PSS_FIELD_LABELS, M.PSS_INDEX_LABELS, M.PSS_EVENT_LABELS
-- Loaded with Libraries, after PSS_Time.lua.
------------------------------------------------------------------------
local addon = PourSocialScore_NS
local M = addon.M

local type, tostring, tonumber, pairs = type, tostring, tonumber, pairs
local find, sub, match, gsub, lower, upper, format = string.find, string.sub, string.match, string.gsub, string.lower, string.upper, string.format
local floor, abs = math.floor, math.abs
local date = date or os.date

local F = {}
M.PSS_Fields = F

M.PSS_FIELD_LABELS = {
	time = "Time", ts = "Time", st = "Action", ent = "Character", cat = "Type", event = "Chat event", owner = "Blocked by",
	member = "From", channel = "Channel", rule = "Guild rule", message = "Message", label = "Label", guild = "Guild",
	sender = "Sender", server = "Server", filter = "Filter",
}
M.PSS_INDEX_LABELS = { log = "Chat log", pss = "Addon messages", gold = "Gold", inv = "Items", err = "Errors", gfx = "Graphics" }
M.PSS_EVENT_LABELS = {
	CHAT_MSG_CHANNEL = "Channel chat", CHAT_MSG_WHISPER = "Whisper", CHAT_MSG_BN_WHISPER = "Battle.net whisper", CHAT_MSG_SAY = "Say",
	CHAT_MSG_YELL = "Yell", CHAT_MSG_GUILD = "Guild chat", CHAT_MSG_PARTY = "Party", CHAT_MSG_RAID = "Raid", CHAT_MSG_EMOTE = "Emote",
	PARTY_INVITE_REQUEST = "Party invite", GUILD_INVITE_REQUEST = "Guild invite",
}
local CAT = { whisper = "Whisper", partyInvite = "Party invite", guildInvite = "Guild invite", world = "World chat", guildChat = "Guild chat" }

-- the label of a field; a name with none shows as itself
function M.PSS_FieldLabel(field)
	if field == nil then return "" end
	if type(field) ~= "string" then return tostring(field) end
	return M.PSS_FIELD_LABELS[field] or field
end

local function cap(s) return (gsub(s, "^%l", upper)) end

------------------------------------------------------------------------
-- Names and realms
------------------------------------------------------------------------
function F.myRealm()
	local r = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or ""
	if type(r) ~= "string" then return "" end
	return (gsub(r, "[%s%-]", ""))
end

local function realmKey(r) return lower((gsub(r or "", "[%s%-]", ""))) end

-- name part and realm part of "Name-Realm"; a name with no "-" is on this realm
function F.splitName(name)
	if type(name) ~= "string" or (M.PSS_IsSecret and M.PSS_IsSecret(name)) or name == "" then return nil end
	local d = find(name, "-", 1, true)
	if not d then return name, F.myRealm() end
	return sub(name, 1, d - 1), sub(name, d + 1)
end

-- "Name", or "Name-Realm" when the realm is not this one
local function personText(name)
	local n, r = F.splitName(name)
	if not n then return "" end
	if r == "" or realmKey(r) == realmKey(F.myRealm()) then return n end
	return n .. "-" .. r
end

-- the chat filters by owner key (built per call; a caller keeps it for a run)
function F.filterNames()
	local out = {}
	local db = PourSocialScoreDB
	local list = db and db.filterList
	if type(list) ~= "table" or not M.PSS_FilterOwnerKey then return out end
	local desc = db.filterDesc
	for i = 1, #list do
		local key = M.PSS_FilterOwnerKey(i)
		if key then
			local d = type(desc) == "table" and desc[i]
			if type(d) == "string" and d ~= "" then out[key] = d
			elseif type(list[i]) == "string" then out[key] = list[i] end
		end
	end
	return out
end

-- the source name of a row: member when non-empty, else the record name of a p: owner, the text of a g: owner
function F.sourceName(row)
	local m = row.member
	if M.PSS_IsSecret and M.PSS_IsSecret(m) then m = nil end
	if type(m) == "string" and m ~= "" then return m end
	local o = row.owner
	if (M.PSS_IsSecret and M.PSS_IsSecret(o)) or type(o) ~= "string" then return nil end
	local k, rest = match(o, "^(%a):(.+)$")
	if k == "p" then
		local rec = M.PSS_GetPlayerRecord and M.PSS_GetPlayerRecord(rest)
		return rec and type(rec.name) == "string" and rec.name ~= "" and rec.name or rest
	elseif k == "g" then return rest end
	return nil
end

------------------------------------------------------------------------
-- Money
------------------------------------------------------------------------
local function thousands(n)
	local s = tostring(n)
	local k
	repeat s, k = gsub(s, "^(%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

function F.money(copper)
	if type(copper) ~= "number" then return "" end
	local neg = copper < 0
	local c = floor(abs(copper))
	local g, s, k = floor(c / 10000), floor(c / 100) % 100, c % 100
	local out = {}
	if g > 0 then out[#out + 1] = "|cffffd700" .. thousands(g) .. "g|r" end
	if s > 0 then out[#out + 1] = "|cffc7c7cf" .. s .. "s|r" end
	if k > 0 or #out == 0 then out[#out + 1] = "|cffeda55f" .. k .. "c|r" end
	return (neg and "-" or "") .. table.concat(out, " ")
end

function F.moneyParse(text)
	if type(text) ~= "string" then return nil end
	local t = lower((gsub(text, "%s+", "")))
	if t == "" then return nil end
	if find(t, "^%d+$") then return tonumber(t) end
	local total, any = 0, false
	local g, rest = match(t, "^(%d[%d,]*)g(.*)$")
	if g then total = total + tonumber((gsub(g, ",", ""))) * 10000; any = true; t = rest end
	local s, rest2 = match(t, "^(%d+)s(.*)$")
	if s then total = total + tonumber(s) * 100; any = true; t = rest2 end
	local c, rest3 = match(t, "^(%d+)c(.*)$")
	if c then total = total + tonumber(c); any = true; t = rest3 end
	if not any or t ~= "" then return nil end
	return total
end

------------------------------------------------------------------------
-- Display rules
------------------------------------------------------------------------
local function entityText(id)
	if type(id) ~= "number" then return tostring(id) end
	if id == 0 then return "" end
	local set = M.PSS_Entity and M.PSS_Entity(id)
	local row = set and set[1]
	if not row then return "#" .. id end
	local kind, name, realm = row[M.PSS_SetCol(set, "kind")], row[M.PSS_SetCol(set, "name")], row[M.PSS_SetCol(set, "realm")]
	if type(name) ~= "string" or name == "" then name = nil end
	if kind == "w" then return "Warband" end
	if not name then return "#" .. id end
	if kind == "g" then return "<" .. name .. ">" end
	if type(realm) == "string" and realm ~= "" and realmKey(realm) ~= realmKey(F.myRealm()) then return name .. "-" .. realm end
	return name
end

local function itemText(v)
	local f = M.PSS_IxItemText
	if f then return (f(v)) end
	return "Item " .. tostring(v)
end

local function ownerText(v, prefixed)
	if type(v) ~= "string" then return tostring(v) end
	local k, rest = match(v, "^(%a):(.*)$")
	if not k then return v end
	if k == "p" then
		local rec = M.PSS_GetPlayerRecord and M.PSS_GetPlayerRecord(rest)
		local name = rec and rec.name and personText(rec.name) or cap(personText(rest))
		return (prefixed and "Player: " or "") .. name
	elseif k == "g" then
		return (prefixed and "Guild member: " or "") .. cap(personText(rest))
	elseif k == "G" then
		local _, g = M.PSS_FindGuildRule and M.PSS_FindGuildRule(rest)
		return (prefixed and "Guild: " or "") .. (type(g) == "table" and g.name or rest)
	elseif k == "f" then
		return "Filter: " .. (F.filterNames()[v] or rest)
	end
	return v
end

local function actText(v)
	if v == "chat.block" then return "Chat block" end
	local c = match(v, "^act%.(.+)$")
	if c then
		local l = M.PSS_IX_CMP_LABELS and M.PSS_IX_CMP_LABELS[c]
		if l then return l end
	end
	return cap((gsub(v, "%.", " ")))
end

local EVENT = M.PSS_EVENT_LABELS
local function eventText(v)
	local lab = EVENT[v]
	if lab then return lab end
	return cap(lower((gsub((gsub(v, "^CHAT_MSG_", "")), "_", " "))))
end

-- by column, for a column whose value is a word the reader should not see raw
local BYCOL = {
	cat = function(v) return CAT[v] or cap(lower((gsub(v, "(%l)(%u)", "%1 %2")))) end,
	event = eventText,
	st = actText,
	channel = function(v) return v == "Channel" and "" or v end,
	member = personText,
}

-- by kind
local BYKIND = {
	t = function(v) if type(v) ~= "number" then return tostring(v) end return v > 0 and date(M.PSS_TIME_SHOW, v) or "" end,
	c = function(v) return type(v) == "number" and F.money(v) or tostring(v) end,
	e = entityText,
	i = itemText,
	d = function(v, col) return ownerText(v, col == "owner") end,
}

-- text of one cell: kind is the column's kind letter (PSS_IxCatalog.lua), nil shows the raw value
function F.show(kind, v, col)
	if (M.PSS_IsSecret and M.PSS_IsSecret(v)) or v == nil then return "" end
	local bc = BYCOL[col]
	if kind and bc and type(v) == "string" then return bc(v) end
	local fn = BYKIND[kind]
	if fn then return fn(v, col) end
	return tostring(v)
end
