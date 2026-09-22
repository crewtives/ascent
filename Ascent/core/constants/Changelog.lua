-- Ascent - what changed, version by version.
--
-- GENERATED from CHANGELOG.md by tools/changelog.lua. Do not edit by hand:
-- `./dev.sh lint` regenerates it and fails if this file disagrees with the
-- changelog it came from.
--
-- The last 5 released versions travel with the addon; older ones stay in the
-- repository, where nobody's client pays for them.

local _, ns = ...
ns.core = ns.core or {}

ns.core.CHANGELOG = {
  {
    version = "0.3.0",
    date = "2026-09-22",
    lines = {
      "Still a beta: that the sources add up to a level's exact experience is verified only on the levels played so far.",
      "",
      "Added",
      "- The combat summary has its own options page: size, width, opacity, how long it stays, rows, which zones to show and its look.",
      "- /ascent options plate opens that page, for a summary dragged off screen or made invisible.",
      "- What a creature pays now depends on how many of you shared the kill, so a dungeon run no longer inflates your solo estimates.",
      "- Each level shows the time it could not place, such as loading screens, next to the time spent in each place.",
      "",
      "Changed",
      "- The creature breakdown shows one row per creature and group size, instead of one per creature.",
      "- The combat summary has its own lock instead of the bar's; if you locked the bar to lock both, lock the summary once.",
      "- Your saved history is converted automatically, with the kills recorded so far filed under an unknown group size.",
      "- An earlier version misreads the converted history: if you go back to one, clear the creature breakdown.",
      "",
      "Fixed",
      "- The combat summary no longer stays empty while a creature hits an absorb shield.",
      "- A creature running toward you is counted before it arrives, not only once combat starts.",
      "- A caster is counted from the moment it starts casting at you, not when the spell lands.",
      "- Every creature in the fight is counted, not only the ones you hit.",
      "- The played-time replies the addon asks for no longer show up in your chat.",
    },
  },
  {
    version = "0.2.0",
    date = "2026-09-22",
    lines = {
      "Still a beta: one complete level has now been played with every source adding up to its exact experience.",
      "",
      "Added",
      "- The addon tells you once per session when a newer version exists, after three players in your guild or group have announced it.",
      "- It announces its own version to your guild and group, well under the client's limits, and never replies to an announcement.",
      "- /ascent changelog shows what changed as selectable text, starting with the version you run.",
      "- On login the addon says whether it was updated; after going back a version, the newer history is set aside, not deleted.",
      "- A switch under Interface → AddOns turns off both the update notice and the announcements.",
      "",
      "Changed",
      "- The session recorder moved to /ascent debug evidence on|off|reset.",
      "",
      "Fixed",
      "- The rested bonus is no longer counted twice; levels already recorded keep the old figure.",
      "- A level is named after its zone, not after a building you entered, such as Duskwither Spire in Eversong Woods.",
      "- The session recorder now says which level was completed.",
      "- The help no longer lists the removed debug quests and debug strings commands.",
    },
  },
  {
    version = "0.1.0",
    date = "2026-09-21",
    lines = {
      "First public build and an early beta: it has been tested far more than it has been played.",
      "",
      "Added",
      "- Runs on Classic Era (1.15.x) and Burning Crusade Classic (2.5.x) from one download.",
      "- Every point of experience is attributed to quests, kills, exploration or an unexplained share, so the sources add up to the level exactly.",
      "- Experience that crosses a level-up is split between the two levels.",
      "- The rested bonus is read from the figure the client shows on each kill, not inferred from the rested pool.",
      "- The group bonus and the raid penalty are shown as parts of what you earned, not as extra experience.",
      "- Each gain records where it was earned: open world, dungeon, raid, battleground or arena.",
      "- Level history keeps a record per level and character: duration, experience by source and place, rested share and combat totals.",
      "- Your saved history is upgraded automatically across versions, and old levels are trimmed so the file stays small.",
      "- Combat metrics per level: health and resource after a fight, deaths, downtime, damage, healing and efficiency per kill.",
      "- Abilities ranked by use, with auto-attacks counted apart.",
      "- Pending experience: what your quest log would pay right now at your level, with the quests it cannot price counted.",
      "- Projections: experience per hour, time to level, kills remaining, and level completion with and without rested bonus.",
      "- /ascent copy and a button in the options open the diagnostics as selectable text for a report, without character name or realm.",
      "- A segmented experience bar of its own, leaving Blizzard's untouched, with a rested marker, pending experience, tooltip and custom text.",
      "- The bar's saved position is pulled back onto the screen if it ends up outside it.",
      "- A level report panel with Sources, Combat, Abilities, Pending and History tabs; History compares a level with the one before.",
      "- Six skins — Tabard, Cartographer, Stormwind, Glass, Telemetry and Phantom — with per-source colours, high contrast and adjustable motion.",
      "- Options in /ascent options and under Interface → AddOns, saved per account, with a live preview and a demo of every state.",
      "- Commands: show, hide, panel, summary, pending, options, demo, reset confirm, debug and evidence.",
      "- /ascent evidence on records a session to the saved variables file instead of the chat.",
      "- The addon stops cleanly at the maximum level and when experience gain is turned off.",
      "- Only what the client supports is watched, and /ascent debug lists what is available and what is not.",
    },
  },
}
