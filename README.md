# Ascent

Per-level leveling analytics for World of Warcraft **Classic Era** (1.15.x) and **Burning Crusade
Classic** (2.5.x).

Ascent records where every point of experience in a level came from, where you were standing when you
earned it, and how you played while earning it — and then keeps it, level by level, so you can look
back at a level you already finished.

## Why

Every experience bar for Classic answers the present: how much is left, experience per hour, how much
rested you have. None of them keeps the past. The moment you ding, how you got there is gone — which
quests carried the level, how much of it you ground out, what the dungeon run was actually worth, how
much you lost to deaths and downtime.

Ascent's promise is arithmetic: **the sources add up to exactly the experience of the level.** Anything
the client does not explain lands in a bucket that says so, rather than quietly disappearing into a
total. Where a number is a guess, the addon says it is a guess; where the client never told it
anything, it says that too.

No external libraries, no Ace3, no LibStub. One folder of Lua.

## Screenshots

Taken from a real Burning Crusade session. The full set, and the notes on what each one shows, live in
[`press/`](press/curseforge.md).

| | |
|---|---|
| [The level report, by source and by place](press/screenshots/02-panel-sources.png) | [Combat](press/screenshots/03-panel-combat.png) |
| [What you actually pressed](press/screenshots/04-panel-abilities.png) | [The pull plate, mid-fight](press/screenshots/05-pull-plate.png) |

Two are still missing: the History tab with more than one level closed, and the skin gallery with all
six in frame.

## The bar

A bar of its own, not a hook into Blizzard's — you can hide that one from the game's interface options
if you want. Each segment is a **source** rather than one undifferentiated block:

- quests, creature kills, exploration, and everything else the client reported but did not classify
- a rested marker over the stretch the bonus is still paying for
- a separate channel for **pending** experience: what you would be handed right now for the quests
  already in your log
- a tooltip that breaks the level down by source, cross-reads it by place, and states plainly which
  part of the level it was not watching (a level in progress when the addon was installed is partial,
  and says so)

Drag it, lock it, scale it, resize it, or park it wherever; the position survives a reload and is
clamped back onto the visible screen if your resolution changes.

## The panel

`/ascent panel` opens the level report — five tabs:

| Tab | What it answers |
|---|---|
| **Sources** | the level broken down by source and by place, with the rested portion, the group bonus, and the raid penalty |
| **Combat** | health and resource on leaving combat, deaths, time lost to them, time in combat versus downtime, damage and healing |
| **Abilities** | what you actually pressed, ranked, with auto-attacks kept separate from everything else |
| **Pending** | the experience sitting in your quest log, what is ready to hand in, and how many quests the client could not price |
| **History** | every level you have closed, selectable, comparable against the one before it |

## Appearance

Six skins — Tabard, Cartographer, Stormwind, Glass, Telemetry, Phantom — each a complete look for both
the bar and the panel: background, border, fill, separator, typography, accent. Pick one from the
gallery in the options panel and tune it per axis from there, or set the colour of each source by hand.
There is a high-contrast mode, and a motion scale that goes all the way down to zero if you would
rather nothing moved.

## Commands

| Command | |
|---|---|
| `/ascent` | list the commands |
| `/ascent show` · `hide` | show or hide the bar |
| `/ascent panel` | open or close the level report |
| `/ascent summary` | the current level's breakdown, in chat |
| `/ascent pending` | forecasted experience from the quests in progress |
| `/ascent options` | current settings; `lock`, `unlock`, `scale <n>`, `skin <name>`, `contrast on\|off`, `motion <n>`, `panel`, `reset` |
| `/ascent demo` | step the bar through every visual state; `off` to stop |
| `/ascent reset confirm` | erase this character's recorded history |
| `/ascent debug` | everything the addon knows about itself: client, capabilities, attribution counters, places |
| `/ascent evidence on` | record a session to the saved variables file for later reading; `off`, `reset` |
| `/ascent copy` | the diagnostics as selectable text, ready to paste into a bug report; `summary`, `pending` for a narrower one |

The options panel also lives under **Interface → AddOns → Ascent**, and its Behaviour page has a
**Copy a report** button — the same window `/ascent copy` opens.

## Data

- `AscentCharDB` — per character: the level records, the quest rewards this character has learned.
- `AscentDB` — per account: settings, and the quest-name directory (what quest 8887 is *called* is the
  same answer on every alt).

History is bounded by an explicit retention policy, the stored format is versioned and migrated, and
`/ascent reset confirm` erases it. The addon makes no network requests — a WoW addon cannot, which is
why there is no telemetry and why `/ascent copy` exists: the only thing that can ever reach the author
is what a player chooses to paste, and chat text cannot be selected.

At maximum level, or with experience gain disabled, Ascent stops tracking instead of recording zeroes.

## Status

**Not released.** The desktop side is green — the domain suite, the linter, the architecture rule and
the load smoke test all pass on every commit — and the addon has now been played rather than only
tested. Those sessions are where the interesting bugs came from: experience mis-attributed to the
rested bonus, the addon switching off the client's own experience frame while claiming to sit inside
it, two ranks of one spell listed as two abilities, a row of zeroes for a place that was never a place.

What the sessions have **not** done yet is the whole of it. `ui/` has no unit coverage — the only thing
that exercises it is a load harness against a stand-in client — the smoke checklist has not been run
end to end on either flavour, and the central promise, that the sources add up to exactly the level,
has been confirmed level by level rather than across a full 1–60. The plan that tracks what remains
lives in `openspec/`, and the in-client verification each task still owes is written into it.

Treat it as an early beta: worth levelling with if you want to help find the rest, not yet something to
rely on.

## Architecture

Hexagonal, and enforced rather than intended:

```
Ascent/
  core/      73 files   pure domain — no WoW API, at all
  adapter/   13 files   translation between the client and the domain
  ui/         9 files   frames; they consume view-models and decide nothing
  locale/     2 files   strings (enUS)
  app/        3 files   composition root — the only layer that sees the other three
  test/      89 files   headless suite, 1370+ assertions
```

`core/` is where the addon actually lives, and it never touches the client. Two halves of the same rule
keep it that way: `.luacheckrc` declares no WoW globals for `core/`, so reaching for one fails the
linter, and `./dev.sh lint` greps `core/` for references to the outer layers and fails on those too.
The same run checks that every `.lua` file is listed in the TOC and that every path the TOC lists
exists — drift there fails silently in-game, which is the worst way for anything to fail.

The view-models are pure: what a tab shows is decided in `core/`, tested headlessly, and handed to a
frame that only draws it.

## Development

Requires a Lua 5.1 runtime. On macOS:

```sh
brew install luajit luacheck luarocks
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" install --local busted
```

`busted` lands in `~/.luarocks/bin`, where `dev.sh` looks for it before falling back to `PATH`.

```sh
./dev.sh test      # the domain suite, on LuaJIT (Lua 5.1 semantics, same as the client)
./dev.sh lint      # luacheck + the TOC consistency check + the layer dependency rule
./dev.sh smoke     # load every file in TOC order against a stand-in client and drive the addon
./dev.sh link      # symlink the addon into your WoW AddOns folders
./dev.sh package   # build dist/Ascent-<version>.zip
```

### Releasing

Tagging is the whole interface:

```sh
git tag v0.1.0 && git push --tags
```

That runs the same three gates on CI, builds the zip and uploads it to CurseForge as a **beta**. To
publish something as a full release instead, run the Release workflow by hand from the Actions tab and
pick the type. The version, the supported clients and the release notes are read from
`Ascent/Ascent.toc` and `CHANGELOG.md`, so nothing about a release is written down twice — and a tag
that disagrees with the TOC fails the run instead of shipping a mislabelled zip.

The upload itself is `tools/curseforge-upload.sh`, which runs locally too:

```sh
./dev.sh package
./tools/curseforge-upload.sh --dry-run    # prints exactly what would be sent
```

It needs `CF_API_TOKEN` (a repository secret on CI, from your CurseForge account's API tokens page)
and `CF_PROJECT_ID`, which is the number in the project's authors URL and lives in the workflow.

`./dev.sh smoke` exists because none of the unit suite touches `ui/`. It loads the addon the way the
client would and drives it the way a player would in their first minute — every visual state, every
tab, every skin, the options panel — against a stub that accepts any call. It does not replace a real
login: anything flavour- or template-specific still needs one. Everything else it catches in under a
second.

All three have to be green before a task is marked done.

## License

[MIT](LICENSE).
