# Changelog

All notable changes to Ascent are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-22

Still a beta. What changed about that: the addon has now been played through a complete level and the
sources added up to exactly the experience of it, which is one level more than could be said when
0.1.0 shipped. Every fix below came out of reading the file that session left behind.

### Added

- **Knowing that a newer version exists.** An addon cannot make a network request, so the only
  possible source is other players: Ascent announces its version over the addon channel to your guild
  and your group, and listens for theirs. It does not believe a single one — the contents of those
  messages are written by somebody else's client and can be forged — so it takes three distinct
  players announcing the same later version before it says anything, and it says it once per session.
  It sends far below what the client allows, never retries a rejection, and never answers somebody
  else's announcement with one of its own.
- **`/ascent changelog`**, which shows what changed without leaving the game, headed by the version you
  are running and as selectable text. It is generated from this file when the addon is packaged, so it
  cannot tell you anything else.
- **A notice when the version changes.** On login the addon says whether it was updated. And if you
  went back to an earlier version, it says what used to happen in silence: the history written by the
  later version is **set aside, not deleted**, because a migration only ever walks forward.
- **A switch** under Interface → AddOns to turn it off, which silences both halves: it stops telling
  you, and it stops announcing.

### Changed

- **The session recorder moved inside `debug`**: what was `/ascent evidence on|off|reset` is now
  `/ascent debug evidence on|off|reset`. The addon's diagnostics are reached through one door, which is
  the same reason the three separate dumps it used to have were folded into one. The help was also
  still offering `debug quests` and `debug strings`, gone since that merge.

### Fixed

- **The rested bonus was counted twice.** The figure the client prints in parentheses was credited to
  its own kill, and then again to the first kill behind it that carried no parentheses at all: with
  nothing to read there, the addon inferred the bonus from how far the rested reserve had fallen, and
  that reading is taken from the chat line — which the client prints BEFORE applying the experience
  — so it described the previous kill. A line that does not mention rest now means zero, which is
  what it means. Levels already on disk keep the inflated figure: the correction applies from here on
  and does not rewrite your history.
- **A level could end up labelled with the name of a building.** A place is identified by its map, but
  it was shown with the name the client gave the zone at that instant, and inside a building that name
  is the building's while the map underneath stays the zone's. Because a place only adopts a name it
  was missing, the first one to arrive stayed for good: a whole level spent across Eversong Woods could
  read as “Duskwither Spire”. The name comes from the map now, one name per place.
- **The session recorder did not say which level had completed.** It noted that one had, and left the
  number blank, because it was reading the level in the wrong place.

## [0.1.0] - 2026-09-21

First public build, and an early beta rather than a finished thing: it has been played far less than
it has been tested. Targets Classic Era 1.15.x (`11509`) and Burning Crusade 2.5.x (`20506`) from a
single TOC.

If something looks wrong, `/ascent copy` hands you the diagnostics as selectable text - that is the
only way anything from your game can reach the author, since an addon cannot make a network request.

### Added

- **Experience attribution.** Every gain is reconciled against the client's authoritative experience
  delta, so the sources add up to exactly the experience of the level. Quests, creature kills and
  exploration are classified from the client's own messages; what the client reported but did not
  explain is kept in a bucket that says so, including the part of a level the addon was not installed
  for. Gains that cross a level-up are split across the two levels.
- **The rested bonus, read rather than inferred.** The bonus is taken from the figure the client puts
  in parentheses on the kill itself, not from watching the reserve drain.
- **The group bonus and the raid penalty**, shown as portions already inside the amount rather than as
  extra experience.
- **Where it happened.** Each gain is sealed with the place it was earned in — open world, dungeon,
  raid, battleground, arena — at the instant the increase is observed. What the client could not name
  is counted as unrecorded and reported as a share of the level, never imputed.
- **Level history.** A record per level and per character: duration, experience by source and by place,
  rested portion, sessions crossed, combat aggregates. Versioned on disk, migrated across schema
  changes, and bounded by an explicit retention policy.
- **Combat metrics per level.** Health and resource on leaving combat, deaths and the time lost to
  them, time in combat versus downtime, damage done and taken, healing, and efficiency per kill.
- **Ability ranking.** What was actually pressed, ranked by use, with auto-attacks kept separate so the
  percentages are answering one question at a time.
- **Pending experience.** What the quest log would pay out right now, adjusted to the character's
  level, with the provenance of each figure stated and quests the client cannot price counted rather
  than hidden. Quest names come from one account-wide directory, so every surface calls the same quest
  the same thing.
- **Projections.** Experience per hour for the level and the session, time to the next level, estimated
  kills remaining, and the level's completion with and without the rested bonus.
- **A report you can actually send.** `/ascent copy`, and a button on the options panel, open the
  diagnostics as selectable text —
  headed by the addon's build, the client's flavour and the interface language — because an addon
  cannot make a network request and chat text cannot be selected. It carries no character name and
  no realm, and it is editable before you paste it.
- **Segmented bar.** An independent bar — Blizzard's is left alone — where each segment is a source,
  with a rested marker, a separate channel for pending experience, a breakdown tooltip, configurable
  text, and a saved position that is clamped back onto the visible screen.
- **Level report panel** with five tabs: Sources, Combat, Abilities, Pending and History, the last one
  selectable level by level and comparable against the level before.
- **Six skins** — Tabard, Cartographer, Stormwind, Glass, Telemetry, Phantom — each covering bar and
  panel alike, with per-axis tuning, per-source colours, a high-contrast mode and a motion scale that
  reaches zero.
- **Options** in `/ascent options` and under Interface → AddOns, persisted per account, with a live
  preview bar and a demo mode that steps every visual state.
- **Commands**: `show`, `hide`, `panel`, `summary`, `pending`, `options`, `demo`, `reset confirm`,
  `debug` and `evidence`.
- **Evidence recording** (`/ascent evidence on`), which writes a session to the saved variables file
  for later reading instead of to chat.
- **Graceful stop** at maximum level and when experience gain is disabled.
- **Flavour compatibility** resolved at runtime: only the collectors the client supports are
  registered, and `/ascent debug` reports which capabilities are present and which are not.

[0.2.0]: https://github.com/crewtives/ascent/releases/tag/v0.2.0
[0.1.0]: https://github.com/crewtives/ascent/releases/tag/v0.1.0
