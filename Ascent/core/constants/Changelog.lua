-- Ascent - what changed, version by version.
--
-- GENERATED from CHANGELOG.md by tools/changelog.lua. Do not edit by hand:
-- `./dev.sh lint` regenerates it and fails if this file disagrees with the
-- changelog it came from.
--
-- The last 5 released versions travel with the addon; older ones stay in the
-- repository, where nobody's client pays for them (design D70).

local _, ns = ...
ns.core = ns.core or {}

ns.core.CHANGELOG = {
  {
    version = "0.3.0",
    date = "2026-09-22",
    lines = {
      "Published as a release rather than a beta. What changed about that: the addon has now been played across sessions on Burning Crusade Classic, and the three separate reports about the live combat summary turned out to be one defect with one cause -- a sweep that was switched off. What has not changed: ui/ still has no tests, and the promise that the sources add up to exactly the experience of a level is verified on the levels that have actually been played, not on all of them.",
      "",
      "Added",
      "- The combat summary has a page of its own. It answered to two settings, one of which had no checkbox anywhere and existed only as a chat command, while all six options pages were about the bar. It now has shown, locked, scale, width, opacity, how long it stays, how many rows, which of its seven zones to draw, and three axes of its own look over the bar's -- plus a demo button, a reset, and /ascent options plate for the one case a panel cannot help with: a plate dragged off screen or made invisible, because you cannot click what you cannot see. It still follows the bar's skin and palette on purpose. The summary's source bar uses the experience bar's segment colours so that what you learn on one you read on the other without translating, and two palettes would not be two tastes but two vocabularies, the second to be learned mid-fight.",
      "- What a creature pays now depends on how many of you split it. Every average this addon shows is measured -- that is the whole claim -- and the bucket holding those measurements kept kills and experience and nothing else, so the same creature killed alone and killed in a five-man landed in one number. Level alone, then run a dungeon, and every estimate was inflated about five-fold; go back to solo and the dungeon's kills dragged it down. The live summary, the kill-quest forecast and the panel's breakdown all read from it, so all three were wrong at once and in the same direction. The group size is sampled at the instant of the gain and travels with it, so stepping into a dungeon does not reclassify the level you earned outside one.",
      "- The time a level could not place. Experience balances to the unit because whatever cannot be attributed lands in an explicit bucket. The seconds measured against places had no such bucket and could quietly fall short of the seconds actually played: one level measured 8931.6s of 9304.2s, and the missing 4% -- loading screens, where none of this runs -- could only be found by subtracting the two by hand. It is left unknown rather than zero when the level never received the server's own figure, because zero is a claim that level is not entitled to make.",
      "",
      "Changed",
      "- The breakdown draws one row per population, not one per creature. A creature killed solo and the same creature killed in a group are two measurements, and merging them is the thing this version exists to stop doing.",
      "- The combat summary has its own lock. It borrowed the bar's, and the bar's lock is disabled while the client's bar slot suspends its position -- so a setting about the client's own experience bar decided whether the summary could be dragged at all. If you locked the bar in order to lock both, the summary will be loose once.",
      "- Your recorded history is converted, not discarded. AscentCharDB goes to schema 4 and rewrites every creature bucket, filing what it already held under an unknown group size: that history is still worth something as long as nothing passes it off as measured. Going back to an earlier version is not clean, though -- an older build reads the new line and takes the group size for a creature id, silently -- so if you roll back, clear the breakdown rather than trust it.",
      "",
      "Fixed",
      "- The live summary stayed empty through entire fights. It hides while a pull has nothing to say, and \"nothing\" was defined by kills and damage alone, so a creature beating on an absorb shield left all four figures at zero and the summary stayed down for the whole fight with the creature enrolled and the pull open. A pull with a creature in it has something to show.",
      "- A creature crossing the ground toward you was not counted until it arrived. The nameplate sweep that exists to see one coming ran only while a fight was already open, and only the client's combat flag opened one -- so the single mechanism that could see a creature early was gated behind the very thing it existed to precede. It runs always now: four times a second in a fight, once a second outside one.",
      "- A caster is counted from the moment it starts casting at you, which is the earliest thing the combat log will ever say about one, instead of when the spell lands.",
      "- Every creature in the fight is counted, not only the ones you hit.",
      "- The played-time answers the addon asks for no longer reach your chat. One request comes back two to four times in the same instant, and the silence was being released on the first answer -- inside the very dispatch that then printed the rest. It is held on a timer now, because the number of repetitions is not knowable: two to four were seen on Burning Crusade Classic and the figure has never been measured on Classic Era, so calibrating to a count would fail silently on a client that sends one more.",
    },
  },
  {
    version = "0.2.0",
    date = "2026-09-22",
    lines = {
      "Still a beta. What changed about that: the addon has now been played through a complete level and the sources added up to exactly the experience of it, which is one level more than could be said when 0.1.0 shipped. Every fix below came out of reading the file that session left behind.",
      "",
      "Added",
      "- Knowing that a newer version exists. An addon cannot make a network request, so the only possible source is other players: Ascent announces its version over the addon channel to your guild and your group, and listens for theirs. It does not believe a single one — the contents of those messages are written by somebody else's client and can be forged — so it takes three distinct players announcing the same later version before it says anything, and it says it once per session. It sends far below what the client allows, never retries a rejection, and never answers somebody else's announcement with one of its own.",
      "- /ascent changelog, which shows what changed without leaving the game, headed by the version you are running and as selectable text. It is generated from this file when the addon is packaged, so it cannot tell you anything else.",
      "- A notice when the version changes. On login the addon says whether it was updated. And if you went back to an earlier version, it says what used to happen in silence: the history written by the later version is set aside, not deleted, because a migration only ever walks forward.",
      "- A switch under Interface → AddOns to turn it off, which silences both halves: it stops telling you, and it stops announcing.",
      "",
      "Changed",
      "- The session recorder moved inside debug: what was /ascent evidence on|off|reset is now /ascent debug evidence on|off|reset. The addon's diagnostics are reached through one door, which is the same reason the three separate dumps it used to have were folded into one. The help was also still offering debug quests and debug strings, gone since that merge.",
      "",
      "Fixed",
      "- The rested bonus was counted twice. The figure the client prints in parentheses was credited to its own kill, and then again to the first kill behind it that carried no parentheses at all: with nothing to read there, the addon inferred the bonus from how far the rested reserve had fallen, and that reading is taken from the chat line — which the client prints BEFORE applying the experience — so it described the previous kill. A line that does not mention rest now means zero, which is what it means. Levels already on disk keep the inflated figure: the correction applies from here on and does not rewrite your history.",
      "- A level could end up labelled with the name of a building. A place is identified by its map, but it was shown with the name the client gave the zone at that instant, and inside a building that name is the building's while the map underneath stays the zone's. Because a place only adopts a name it was missing, the first one to arrive stayed for good: a whole level spent across Eversong Woods could read as “Duskwither Spire”. The name comes from the map now, one name per place.",
      "- The session recorder did not say which level had completed. It noted that one had, and left the number blank, because it was reading the level in the wrong place.",
    },
  },
  {
    version = "0.1.0",
    date = "2026-09-21",
    lines = {
      "First public build, and an early beta rather than a finished thing: it has been played far less than it has been tested. Targets Classic Era 1.15.x (11509) and Burning Crusade 2.5.x (20506) from a single TOC.",
      "If something looks wrong, /ascent copy hands you the diagnostics as selectable text - that is the only way anything from your game can reach the author, since an addon cannot make a network request.",
      "",
      "Added",
      "- Experience attribution. Every gain is reconciled against the client's authoritative experience delta, so the sources add up to exactly the experience of the level. Quests, creature kills and exploration are classified from the client's own messages; what the client reported but did not explain is kept in a bucket that says so, including the part of a level the addon was not installed for. Gains that cross a level-up are split across the two levels.",
      "- The rested bonus, read rather than inferred. The bonus is taken from the figure the client puts in parentheses on the kill itself, not from watching the reserve drain.",
      "- The group bonus and the raid penalty, shown as portions already inside the amount rather than as extra experience.",
      "- Where it happened. Each gain is sealed with the place it was earned in — open world, dungeon, raid, battleground, arena — at the instant the increase is observed. What the client could not name is counted as unrecorded and reported as a share of the level, never imputed.",
      "- Level history. A record per level and per character: duration, experience by source and by place, rested portion, sessions crossed, combat aggregates. Versioned on disk, migrated across schema changes, and bounded by an explicit retention policy.",
      "- Combat metrics per level. Health and resource on leaving combat, deaths and the time lost to them, time in combat versus downtime, damage done and taken, healing, and efficiency per kill.",
      "- Ability ranking. What was actually pressed, ranked by use, with auto-attacks kept separate so the percentages are answering one question at a time.",
      "- Pending experience. What the quest log would pay out right now, adjusted to the character's level, with the provenance of each figure stated and quests the client cannot price counted rather than hidden. Quest names come from one account-wide directory, so every surface calls the same quest the same thing.",
      "- Projections. Experience per hour for the level and the session, time to the next level, estimated kills remaining, and the level's completion with and without the rested bonus.",
      "- A report you can actually send. /ascent copy, and a button on the options panel, open the diagnostics as selectable text — headed by the addon's build, the client's flavour and the interface language — because an addon cannot make a network request and chat text cannot be selected. It carries no character name and no realm, and it is editable before you paste it.",
      "- Segmented bar. An independent bar — Blizzard's is left alone — where each segment is a source, with a rested marker, a separate channel for pending experience, a breakdown tooltip, configurable text, and a saved position that is clamped back onto the visible screen.",
      "- Level report panel with five tabs: Sources, Combat, Abilities, Pending and History, the last one selectable level by level and comparable against the level before.",
      "- Six skins — Tabard, Cartographer, Stormwind, Glass, Telemetry, Phantom — each covering bar and panel alike, with per-axis tuning, per-source colours, a high-contrast mode and a motion scale that reaches zero.",
      "- Options in /ascent options and under Interface → AddOns, persisted per account, with a live preview bar and a demo mode that steps every visual state.",
      "- Commands: show, hide, panel, summary, pending, options, demo, reset confirm, debug and evidence.",
      "- Evidence recording (/ascent evidence on), which writes a session to the saved variables file for later reading instead of to chat.",
      "- Graceful stop at maximum level and when experience gain is disabled.",
      "- Flavour compatibility resolved at runtime: only the collectors the client supports are registered, and /ascent debug reports which capabilities are present and which are not.",
    },
  },
}
