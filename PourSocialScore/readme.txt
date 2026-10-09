POUR SOCIAL SCORE AND CHAT SPAM FILTER
Version 3.4.0.24 - by Boaties

Pour Social Score is a quality-of-life addon with an unlimited, account-wide
ignore list, a guild ignore list, and a chat/spam filter engine. It removes
gold sellers, boosting spam, guild and community recruitment, non-latin text
and anything else you write a filter for. Built with the WoW API only (no
libraries).

Type /pss (or open your Friends window) to open the interface, and /pss help
for the chat command list.


== INSTALLING AND UPDATING

Pour Social Score is six folders. Extract the zip into World of Warcraft/
_retail_/Interface/AddOns/ (or your Camelot client's AddOns folder) so the
folders sit side by side:

  PourSocialScore              always loaded: chat filtering, warnings,
                               declines, guild member capture
  PourSocialScore_Options      always loaded, data only: your settings, the
                               Player and Guild Ignore Lists, chat rules
                               and every block count
  PourSocialScore_GUI          the window, loaded when you open it
  PourSocialScore_Libraries    commands, scans and import/export, loaded
                               when you use them
  PourSocialScore_Logging      the block history, loaded when you view it,
                               run /pss check, or 200 new lines are waiting
  PourSocialScore_Communities  the shipped guild lists, loaded when their
                               rule is on or you work with their members

The AddOns list shows them under one Pour Social Score heading. Keep all
six enabled; PourSocialScore and PourSocialScore_Options are required.

From 3.4.0.25 PourSocialScore_GUI holds the new Pour Social Score window
(see THE POUR SOCIAL SCORE WINDOW below). The PourSocialScore_UI and
PourSocialScore_EllesmereUI folders of earlier builds are no longer used:
delete them if they are still in your AddOns folder (Pour Social Score says
so once at login).

When updating, replace every folder (delete the old ones first so no stale
file is left behind).

Upgrading from 2.0: back up your WTF folder first, because a 3.0 save can't
be read by 2.0. At the first login your saved data moves to the new files
in WTF/Account/<account>/SavedVariables/, and is checked before and after
(if any count differs the move is undone and tried again next login):
  PourSocialScore_Options.lua  settings (only those you changed), lists,
                               chat rules, block counts, window sizes
  PourSocialScore_Logging.lua  the block history and kept lines
  PourSocialScore.lua          the upgrade record, and new block lines
                               waiting to join the history

After any update, the first login lists what was upgraded in your saved
data, one line per feature that changed, plus the "SavedVariables
performance cleanup" line; later logins say nothing.


== FEATURES

Player Ignore List
* Unlimited size, shared across all your characters, factions and servers
* Ignore players, NPCs and whole servers
* Notes and expiry times (entries remove themselves after N days)
* Per-player exclusions W I G P C (see EXCLUSIONS below)
* Character names with a space ("First Last-Realm") are supported
* For everyone listed, by default: no ignore response, no decline messages,
  duels and trades declined (set on the Options tab). Any player, guild or
  guild member can be an exception (ticks on its View/Edit Rule page, or
  its right-click menu, in the window: /pss gui)
* Player details: select an entry and its details show beside the list
  (see THE POUR SOCIAL SCORE WINDOW below)
* Warnings when you invite, or are grouped with, someone on your list
* Group warning covers every list: the Player Ignore List and guild rules
  that are on (once per player per group, checked after combat)
* Whisper warning: whispering someone whose whispers a list blocks prints a
  chat warning and a raid warning style notice, once per player per session.
  No warning when their whispers are allowed (W ticked). Options: "Warn when
  grouped with, or whispering, a player on any list"
* Automatic decline of duels, trades and party invites from ignored players
* Block a player or their guild from the "PSS" heading in right-click menus on targets, raid frames, chat names and the LFG list

Guild Ignore List
* Ignore whole guilds. Members are captured by guild Scan (a /who sweep of
  the guild, one search per click: the whole guild first, then every answer
  capped at 50 is split by level bracket, class and single level until each
  search is under the cap), Scan All (the same sweep across every guild row,
  A-Z; also on a key binding), Custom Scan (your own /who filter;
  Scan Fields start as 1-60), guild invites, and any /who you run yourself
  whose results include members of a saved guild. Each scan reports in chat
  how many players it found and captured.
* Per-guild exclusions W I G P C, and the same W I G P C on every member so
  you can opt each player in or out individually; members also get a note
* Default guild lists (read only): groups of guilds shipped with the addon
  (the PourSocialScore_Communities folder, loaded only when a group's rule is
  on or you work with its members), e.g. "Managed Communities - Asmongold". Each
  group has a guild rule of the same name on the Chat Filters tab
  (InfluencerGuild=Olympus) that switches the whole group on or off - off by
  default, like every built-in filter - and a collapsible entry on the Guild
  Ignore List with its guilds and their members. Shipped guilds can't be
  removed; their W I G P C exclusions, Scan Fields and scans work like any
  guild. Only your changes are saved: members your scans find that aren't
  in the shipped list (kept in the group), shipped members you edit or that
  have block history, and shipped members that left the guild (a mark the
  shipped list no longer needs is removed when the lists load). The lists
  take about 0.5 MB when loaded, nothing when off.
* Guild Search: /who for part of a guild name and add any guilds it finds;
  everyone the search saw in a guild you add becomes a member of its rule
* Block counters per guild and per type, with full block history

Chat Filters
* Built-in filters for the most common spam (read only; turn them on or off,
  or copy one to make your own version)
* Write your own filters with tags and and/or/not logic (see HOW TO CREATE
  CHAT FILTERS below), test them against sample text, and view what each
  filter has blocked

Also
* Every list can be sorted by any column, and searched
* Links in blocked messages (items, recipes, professions, spells,
  achievements...) work like in chat: hover for the tooltip, click to open,
  shift-click to paste into chat
* Import/Export of your lists, filters and options as a text string
* Light on the game: chat filters are compiled once, every list lookup is
  O(1), nothing is scanned in combat, and memory is tidied up in small
  steps (never a full collection) after login, a /who scan, an import or
  closing the window, and otherwise every 10 minutes. Never in combat,
  within 5 minutes of leaving combat, or inside a dungeon, raid,
  battleground or arena. /pssguild status shows the cleanup state.
* Block history is ONE shared log of the last 2,000 chat filter lines
  (Options > "Block history lines kept in total" 100-20000), and a short
  history per listed player and guild member (default lists too): their
  newest 10 whispers and party / raid / instance / battleground lines, 5
  party invites and 5 guild invites, at most 2,000 of those lines in all
  (the oldest go first). Their world chat (channels, say, yell, emotes) and
  guild chat are counted but not stored. Memory has a hard ceiling however
  many people you block, and none until the history is loaded
  (PourSocialScore_Logging). Blocks are counted at once; new lines wait and
  are stored when it loads (a person's waiting lines already follow the
  limits above). The blocked counts are totals kept per person/filter and
  are never cut. A player's lines follow them when they are moved to
  another guild rule.
  /pss mem shows what the addon is using (/pss mem full: who has the most
  history lines).
* Options apply to every character on the account; some can also be set
  per guild or per player. Only options you changed are saved.


== EXCLUSIONS: W I G P C

The same five tickboxes appear on the Player Ignore List, on each guild of
the Guild Ignore List, and on each member in a guild's members view (on
each entry's View/Edit Rule page).
Ticked = ALLOWED from that player / guild / member; unticked = blocked.
Adding a player or a guild to a list opts them IN to blocking: everything
from them is blocked. The boxes are per-player / per-guild EXCLUSIONS from
that, so they start unticked; tick one to let that one thing through.
(Built-in chat filters are different: each one starts off, tick the ones
you want.)

PSS does all the blocking itself and leaves Blizzard's ignore list alone.
Someone you ignore with Blizzard's own Ignore (or /ignore) is listed in PSS
with the note "Synced from Blizzard ignore list on <date>" and taken off
Blizzard's list; your existing Blizzard list is copied into PSS the first
time you log in with this version and stays where it is. Tick "Also on
Blizzard's ignore list" on a player's View/Edit Rule page (off by default)
to keep that one player on Blizzard's list as well - but Blizzard's list
blocks everything and ignores the exclusions. Removing a player from either
list removes them from both. The "You are being ignored" auto-reply is also
off by default.

  W  Whispers (including Battle.net whispers)
  I  Party invites (auto-declined)
  G  Guild invites (auto-declined)
  P  Party/Raid chat, including raid warnings, instance and battleground chat
  C  Chat channels (Trade, General, LFG, community channels) and public
     chat (say, yell, emotes)

Guild members follow their guild's tickboxes until you change one: a dimmed
box is following the guild; click it to set it for that player (ticked or
not), right-click it to go back to the guild's setting. A member can be
blocked even when their guild has every box ticked (allowed).

Upgrading from 2.0.3 or earlier keeps existing behaviour: C starts unticked
(public chat was always blocked), the old guild Filter / Guild Inv / Group
Inv boxes and the members' Allow boxes are converted automatically.


== THE POUR SOCIAL SCORE WINDOW

/pss (also /pss gui, ui or eui), the Addon Compartment and, with "Open Pour Social
Score UI with Blizzard Friends/Ignore UI" on, your Friends or Social window
open the window. Opened with Friends it sits beside it and closes with it;
opened with /pss gui it is where you last dragged it, on the tab you last
used. It is loaded only when first opened, and lets go of what it read when
closed.

Looks
* Three looks, chosen on its Options tab ("Look of the Pour Social Score
  window"): Modern (the default, the art of Blizzard's Social window),
  Classic (Blizzard's classic window art) and Dark (flat and dark). The
  layout and every feature are the same in all three; the accent is your
  class colour. "Font of the Pour Social Score window" picks its font.

Getting around
* Six tabs: Player Ignore List, Guild Ignore List, Chat Filters, Events,
  Options and Import/Export. Each tab is built the first time you open it.
* The back and forward arrows above the tabs (and mouse buttons 4 and 5)
  step through the views you opened; the line beside them says where you
  are and links back up. Clicking a tab takes it back to its start.
* Escape closes a popup or menu first, then goes up one level, and closes
  the window from the top.
* Right-click a row for its menu (the row is selected first). Removing
  anything asks first.

The lists (Player Ignore List, Guild Ignore List, Chat Filters)
* Click a column header to sort by it, click it again to reverse; type in
  the search box to narrow the list.
* With nothing selected, the pane on the right shows the whole list's
  totals: blocks this session, in the last 24 hours and in all time (a
  pie), and all time by type (a second pie; untick a type to leave it out
  of the pies). Click a slice to see those lines on the Events tab.
* Select an entry and the pane shows it, on three pages picked along the
  bottom: Summary (its own pies and counts, View Events), Event History
  (its blocked lines; the history loads only when you ask for it with Show
  Block History) and View/Edit Rule (note, expiry, W I G P C, and the
  exceptions below).
* For everyone listed, by default: no ignore response, no decline messages,
  duels and trades declined (the Options tab sets the default). Each
  player, guild or guild member can be an exception: the ticks under "For
  this player" (or guild, or member) on View/Edit Rule, or in the row's
  menu. Ticked = it happens; "(exception)" marks one that differs from the
  default. A member follows its guild unless it has its own.

Player Ignore List
* Add Player adds the name in the box, or your target when the box is
  empty (another player of your faction). Player Search runs a /who for the
  name and lists who it found: tick the ones to add (players already listed
  are greyed), then Save. Nobody found: you are asked whether to add the
  name anyway. Back or Escape closes the results.
* Prune: choose a number of days and see how many entries were added that
  long ago or more; Prune removes them with their notes, settings and
  history.

Guild Ignore List
* Grouped: Managed Communities (the shipped lists, each with its rule on or
  off), your guilds and the Guild Exclusion List. Click a heading to open
  or close it.
* Scan All sweeps every guild (hover it for the sweep's status); a guild's
  own page has Scan and Custom Scan. Guild Search finds guilds by part of
  their name: tick and Save. Exclude adds a guild to the Guild Exclusion
  List.
* Double-click a guild (or Members) for its members view: each member has
  its own note, W I G P C and exceptions. Back or Escape returns to the
  guilds.

Chat Filters
* Built-in filters stay at the top; they are read only (turn them on or off,
  or Copy one to make your own). Click a filter to edit it: On,
  description, the filter itself, then Save. Test runs the filter on sample
  text; shift-click a link in chat to put it into the box being edited (the
  link converter turns it into a filter tag). Reset Count keeps the
  history. A guild rule (a shipped list) shows n/a: its blocks are counted
  on the Guild Ignore List.

Events
* Every blocked line in one list, newest first: time, sender, type, where
  and the message. Pick the time (or a custom range), the types and the
  source, search, and sort by any column. Hover a link for its tooltip;
  double-click a line to copy it; right-click a line to add its sender to,
  or remove them from, the Player Ignore List. Reset Block History clears
  the block history and counts of what the tab is showing (it asks first).
* Every pie slice, View Events and a double-click in an Event History opens
  this tab on those lines; Back returns to where you were.

Options and Import/Export
* Options: every option by section, with a search box. Changes save at once.
* Import/Export: pick the parts (Player Ignore List, Guild Ignore List and
  its captured members, custom chat filters, built-in filters on or off,
  options) and the mode, then Export to get a text string, or paste one and
  Import (Replace asks first).

Core's own popups (the note prompt, the party warning, the reload prompt)
are Blizzard's popups.


== NOTES AND KNOWN LIMITATIONS

* Guild rules only block characters PSS has captured (by a scan or a guild
  invite). Blizzard does not include a sender's guild in chat messages, so
  an uncaptured member of an ignored guild is not recognised until a scan
  finds them. /pssguild check Name-Realm shows whether a character is stored.

* /who is hardware-event protected, so guild scans only run from a real
  button click or key press (Key Bindings > AddOns > Pour Social Score >
  Scan All), and all scan buttons share a short cooldown. Hover a Scan
  button for the sweep status: searches sent and queued, players found and
  captured, the next search, and when the next click is allowed.

* /who returns at most 50 players. Scan splits a capped answer on its own;
  a search that is still capped at one level and one class is reported in
  the tooltip ("still capped"). Custom and the Scan Fields remain for any
  filter of your own (e.g. 85-90, or 90 c-"Mage").
  Only players who are online and visible to /who can be captured.

* Options > Whois Scan Options > Enable scan level cap (with the cap in the
  field next to it, required to tick it): no scan searches above that level.
  Scan and Scan All search 1-cap first and stop their level brackets at the
  cap; Custom and Guild Search have their levels cut to the cap (or get
  1-cap added when they have none).

* Character names that contain a space ("First Last-Realm") are supported
  everywhere: Add Player, Player Search, /pss add, remove and expire, and
  chat blocking. Spaces inside the realm are ignored ("Area 52" = "Area52").

* WoW sometimes reports every ignore list entry as "Unknown" during login,
  which stops PSS synchronising your character's ignore list. If that
  happens PSS prints a message and syncs again when you open the interface.
  You can also run /pss sync.

* When you ignore someone from chat, WoW does not always report their server.
  PSS checks your group, raid and recent chat to find it, and otherwise
  assumes they are on your server.

* Blizzard's own ignore list holds 50 entries per character. PSS fills it
  with the best 50 for each character, so account-wide blocking (their alts
  too) covers the people most likely to matter, and blocks everyone else
  itself.


== HOW TO CREATE CHAT FILTERS

PSS ships with built-in filters that are updated as new spam turns up, and
lets you create your own. Every built-in filter starts off - tick the
ones you want on the Chat Filters tab. They include "Filter Asmon"
([contains=asmon]) and "Filter Olympus" ([word=olympus]). Create, copy and remove filters with the buttons
on the Chat Filters tab; click one to edit it.

A filter is made of tags in square brackets that describe what to look for
in a chat message. When the filter as a whole is TRUE, the message is
hidden. Tags can be combined with logic (see USING LOGICAL EVALUATION).

[word]

The word tag looks for a whole word within the chat message. The word to search
for must be provided within the tag with an equals sign such as: "[word=anal]".

Word and partial word matches are case insensitive, so ANAL anal and AnAL will
all match the tag shown above. Punctuation at either end of a word is
ignored, so [word=olympus] also matches "<Olympus>", "(olympus" and
"Olympus!", but not "OlympusTycoons".

[contains]

The contains tag is similar to the word filter, but performs a partial match of
a word instead of a whole word match. If for example, you see people spamming
analanalanal [Thunderfury], then you might want to add a tag with something like
[contains=analan] so that it will catch people who do that sort of spam.

[link]

The link tag matches if the chat contains any linked content at all, which can
mean a spell, item, achievement, etc.

[spell]

The spell tag allows one to filter out specific spell links or all spell links
from chat. If the spell tag exists with no equals, then it will filter when
the message contains ANY spell link at all. For example "[spell]". If the
equals sign is provided and followed by a Spell ID, then only that specific
spell ID will be filtered. Such as "[spell=17]" would filter any message with
the Power Word Shield spell linked in it.

[item]

The item tag allows one to filter out all item links or specific item links.
This tag works in the same way that the spell tag does. For example "[item]"
will filter if any item at all is linked, whereas "[item=19019]" would filter
any chat message that contained a link for Thunderfury.

[talent]

The talent tag works just the same as the spell and item tags.

[achievement]

The achievement tag works just the same as the spell and item tags. See the item and spell examples above.

[pet]

The pet tag works just the same as the spell and item tags. See the item and spell examples above.

[icon]

The icon tag allows filtering based on raid icons in the chat text. The
"[icon]" tag by itself will result in a filtered message if the chat message
has any icon at all in the text. A number can also be provided to filter
based on if a message has a specific number or greater of raid icons. For
example "[icon=3]" would filter if the message has 3 or more raid icons in
it.

[community]

This tag allows filters to be created to filter out community Join requests.
No other data is used for this tag; If you wish to filter anything that
contains a Join request, simply include this tag

[trade]

This tag allows filters to be created to filter out tradeskill links.
No other data is used for this tag; If you wish to filter anything that
contains a tradeskill link, simply include this tag.

[journal]

This tag allows filters to be created to filter out dungeon journal links.
No other data is used for this tag; If you wish to filter anything that
contains a journal link, simply include this tag.

[mount]

This tag allows filters to be created to filter out mount links.
No other data is used for this tag; If you wish to filter anything that
contains a mount link, simply include this tag.

[guild]

This tag allows filters to be created to filter out guild links.
No other data is used for this tag; If you wish to filter anything that
contains a guild link, simply include this tag.

[outfit]

This tag allows filters to be created to filter out outfit links.
No other data is used for this tag; If you wish to filter anything that
contains an outfit link, simply include this tag.

[nonlatin]

This tag filters messages that contain Chinese/Japanese/Korean characters
for those who play on English servers that have a strong native Asian speaking
community

[cyrillic]

This tag filters messages that contain Cyrillic letters (Russian, Ukrainian,
Belarusian, Bulgarian, Serbian, Kazakh ...). It also catches English spam
that swaps in Cyrillic lookalike letters to get past word filters
("selling" written with a Cyrillic "i", U+0456). [cyrillic=3] only matches
when there are at least 3 Cyrillic letters, which lets a single stray
lookalike through.
The built-in rule "Filter Cyrillic (Russian etc.)" uses [cyrillic] and is
off by default.

[words]

This tag allows filters to test that a line of text contains only a specific number
of words.  For example: [words=2] would be true only if the text contained only two
words.

[channel]

This tag allows filters to test that a line of text sourced from a specific channel
number.  For example, channel 1 would be zone, 2 would be city/trade, and so on.  If
you wanted a filter to apply only to trade chat you could do "[channel=2]" somewhere
in your filter.

[chname=name]

This tag allows filters to test that a line of text sourced from a specific channel
name.  When the text sourced from a channel that does not have a chat channel name
PSS will set the name to a value that corresponds to the type of chat it is, as
follows:  say, yell, whisper, officer, guild, party, raid, raid_leader,
instance_chat, instance_chat_leader, battleground, battleground_leader.

As with other filter tags, spaces must be escaped with the backslash character. For
example to create a filter that only applies to Trade chat you would use a tag with
the spaces escaped: [chname=Trade\ -\ City].  If you want to apply a filter only to guild
chat you would use [chname=guild].

The "Never filter party, guild, yourself, private messages" options still apply here,
so if those are enabled even a filter with a channel name will not apply to those
channels as they are configured to never be filtered.

== SPECIAL CHARACTERS IN FILTERS

Spaces can be used in a [Contains] tag by escaping the character with a backslash
before the space (\).  Other characters can be escaped the same
way: parenthesis (), brackets [], and backslash.  For example:

  [contains=filter\ this]

Here are some other examples:

   \( would mean (
   \) would mean )
   \[ would mean [
   \] would mean ]
   \\ would mean \

== USING LOGICAL EVALUATION

Chat filters can include some logical evaluations by enclosing tags within
parenthesis and using boolean "and or not" keywords. This is really what can
tie everything together and allow for some pretty nice filters to be created.

For example, here is the built-in "Anal" spam filter:

([word=anal] or [contains=analan]) and ([link] or [words=2])

The message is filtered when it contains the whole word "anal" OR the partial
match "analan", AND it either contains a link (item, spell, achievement and
so on) OR is exactly two words long.

Order: "not" is applied first, then "and", then "or" - the usual order. So

[word=a] or [word=b] and [word=c]

means [word=a] or ([word=b] and [word=c]). Writing two tags side by side with
no keyword means "and". Use brackets whenever you mix "and" with "or" to make
the meaning obvious. (Before 2.0.9 "or" was applied before "and", so a custom
filter that mixes them without brackets may now behave differently.)


== CHAT COMMANDS

/pss                      Open or close the Pour Social Score window (also
                          /pss gui, /pss ui and /pss eui). Its look and font
                          are on its Options tab
/pss help                 Show the command list
/pss export unused        Copy the saved rules this version cannot use
                          (kept, not applied) as an export string
/pss list [days|server]   List entries; optionally only those listed for
                          [days] or more, or from one server
/pss add name [days] [note]
                          Add a player (also /pss ignore), e.g.
                          /pss add mytoon-Area52 30 spams trade
                          A name with a space needs its realm or quotes:
                          /pss add John Smith-Area52 note
                          /pss add "John Smith" note
                          On Camelot two words are the name:
                          /pss add John Smith 30 note
                          (a one-word name with a note: /pss add "Bob" note)
/pss remove name|number   Remove an entry by name or by its /pss list
                          number (also /pss delete)
/pss expire name days     Remove [name] automatically after [days]
                          (names with a space work the same way as add)
/pss defexpire days       Default expiry for newly ignored players (0 = never)
/pss prune days           Remove everyone listed for [days] or more days
                          (straight away)
/pss npc name             Add or remove an NPC ignore
/pss server name          Add or remove a whole-server ignore
/pss sync                 Synchronise the ignore list now
/pss mem [full]           Memory: addon total, block history lines / cap and
                          size, list sizes, shipped guild index, cleanup
                          state; "full" adds the top 10 history owners
/pss check                Count and check all saved data: list entries by
                          type, notes, guilds and members, chat filters,
                          history lines, the sum of every block count,
                          options, the upgrade record, and any problems
/pss showmsg on|off       Print what happens during synchronisation
/pss sameserver on|off    Only sync same-server characters to Blizzard's
                          ignore list
/pss asknote on|off       Ask for a note when ignoring someone
/pss clear                Clear the whole list on every character (asks you
                          to confirm with /pss clear confirm). You may need
                          to clear on each character, or PSS will re-add
                          entries from that character's Blizzard list.

Guild diagnostics:

/pssguild                 Status: filter registered, lines checked and
                          hidden this session, and each guild rule
/pssguild test Name-Realm Dry run: would this character be blocked, and why
                          (or target them and type /pssguild test)
/pssguild check Name-Realm Is this character stored under a guild rule?
/pssguild chat            Check the chat pipeline and other chat addons
/pssguild debug [all]     Report chat lines from listed people (all = every
                          line checked, for 2 minutes)


== VERSION HISTORY

See history.txt.
