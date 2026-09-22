# Contributing to Ascent

Thanks for looking. This is a small addon with a specific promise — that a level's
experience sources add up to exactly the experience of that level — and the rules below exist to keep
that promise checkable.

## The most valuable thing you can send

Not code: **a report from inside the game.**

Ascent has been tested far more than it has been played. It cannot phone home — a WoW addon cannot make
a network request, so there is no telemetry and there never will be — which means the only way anything
from your session reaches the author is if you send it.

Type `/ascent copy` and paste what it gives you into an issue. It carries the addon build, the client
flavour and the interface language, and it carries **no character name and no realm**. It is editable
before you paste it, so you decide what goes.

## Before you open a pull request

Once per clone, install the commit-message hook, so that a message is checked when you write it rather than
when someone reviews it:

```sh
./dev.sh hooks
```

Three gates, the same ones CI runs. All three green, or the pull request cannot merge:

```sh
./dev.sh test    # the domain suite (busted on LuaJIT)
./dev.sh lint    # luacheck, plus the structural checks below
./dev.sh smoke   # loads and drives the addon against a stand-in client
```

`./dev.sh lint` is where most surprises come from, because it enforces the things that fail **silently
inside the client** rather than loudly on your machine:

- **Every `.lua` file is listed in `Ascent/Ascent.toc`, and every TOC entry exists.** A file that is not
  listed simply never loads, and nothing says so.
- **`core/` never references `adapter/`, `ui/` or `app/`.** If a change seems to need it, the answer is
  a port, not an exception.
- **`Ascent/core/constants/Changelog.lua` matches `CHANGELOG.md`.** It is generated — run
  `luajit tools/changelog.lua` rather than editing it.

## How the code is laid out

Load order is explicit and layered, and a layer may only reference what loads above it:

| Layer | What it may do |
|---|---|
| `core/` | Pure domain. **Never touches the WoW API.** This is what makes the addon testable outside the game. |
| `adapter/` | Translates between the client and the domain. The only layer that speaks the client's language. |
| `ui/` | Draws. Consumes view-models that `core/` already built. |
| `locale/` | Localization tables, keyed by constants rather than bare strings. |
| `app/` | The composition root. The only file that sees all of the above. |

Two house rules that are not negotiable, because they are what the addon is:

- **No external libraries.** No Ace3, no LibStub, no LibSharedMedia. It ships self-contained.
- **New behaviour comes with a test.** If it genuinely cannot be tested outside the client — anything
  in `ui/` — say so in the pull request and describe what you checked in game, on which flavour.

## Style

- **Code, comments and player-facing text are in English.**
- Commit messages, the changelog and comments follow the writing conventions below.
- Keep the diff to what the change needs. Unrelated reformatting makes a review about the wrong thing.

## Writing conventions

One rule covers everything public: **it describes the addon, never the process that built it.** No
decision or task numbers from planning notes, no names of internal documents, no account of how a change was
worked out, and no attribution to the tools used to write it. `./dev.sh lint` rejects the recognisable forms
of this (the rules are in `tools/public-text.patterns`), and review catches the rest.

### Commit messages

[Conventional Commits 1.0](https://www.conventionalcommits.org/en/v1.0.0/), checked by the hook:

```
fix(plate): keep the summary up while a creature hits a shield

The summary hid while a pull had no kills and no damage yet, which is
what fighting an absorb shield looks like.
```

- **Type**: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`, `chore`, `revert` or `style`.
- **Scope**: optional, and one of the areas in `.githooks/scopes`. A new area adds its scope there in the
  commit that first uses it.
- **Header**: at most 72 characters. The summary is imperative, starts in lowercase, has no final period, and
  says literally what changes: *"add an options page for the combat summary"*, not *"the combat summary
  answers to the player now"*.
- **Body**: optional, after a blank line, wrapped at 72. What changes and why, in plain terms.
- **Breaking**: `!` after the scope and a `BREAKING CHANGE:` footer when an earlier version can no longer read
  the saved history, or a command or setting goes away.
- **Credit** a co-author with `Co-Authored-By: Name <email>`. No assistant attribution, no session links.
- A pull request title follows the same format, because it becomes the commit.

### Changelog

`CHANGELOG.md` follows [Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The addon shows it in the game, so it is written
for players:

- **One entry, one sentence**: what changes for the player, at most 160 characters once formatting is
  removed. A change too big for that is several entries.
- A version may open with **one status line** of at most 200 characters (for example, why it is a beta).
- **Only what a player can notice.** Refactoring, tests and tooling stay out.
- **Client tags** go first when an entry does not apply to every client: `[Era]`, `[TBC]`, `[Forever]`,
  several in a row if needed. No tag means every client.
- **Saved data** is described by its effect: *"Your saved history is upgraded automatically; earlier
  versions cannot read it."*, not by a schema number.
- **Contributions** are credited at the end of their entry: *"— thanks @name"*.

`luajit tools/changelog.lua` regenerates the in-game copy and refuses an entry over its limit or a tag it does
not know. `./dev.sh lint` fails if you forget to run it.

### Release notes

A release's notes are its section of `CHANGELOG.md`, word for word, on GitHub and on CurseForge alike, and its
title is `Ascent <version>`. `tools/release-notes.sh` extracts them; nothing is written for a release that is
not already in the changelog.

### Issues

The title states the symptom in a sentence — *"Sources tab total disagrees with the bar's tooltip"*, not *"bug"*.
Pick the client in the form, and paste what `/ascent copy` gives you.

### Code comments

- Every addon file outside `test/` opens with `-- Ascent - <what this file is>`, followed, where it helps, by
  up to six lines on its role and the constraint that shapes it.
- A comment says **why**, or the constraint the code cannot state: an invariant, a unit, an ordering, the
  failure it guards against. When a client lacks an API or behaves oddly, name the API and the client.
- Keep it to about four lines. It is written in the present tense and says nothing about how the code came to
  be — git already has that. No dialogue, no headings in capitals, and no pointers to documents that are not
  in this repository.
- In a test, the `describe` and `it` texts are the documentation. A comment is for set-up that cannot be
  understood without one.
- A commit that only rewrites comments can prove it: `./dev.sh same-code` compares the compiled code of every
  changed `.lua` file with `HEAD` and names any file whose code is not the same.

### Text in the game

Clients are named **Classic Era**, **Burning Crusade Classic** and **World of Warcraft: Forever**. Text a
player reads does not expose the addon's internals, such as schema versions or the names of layers and
buckets; the diagnostics that `/ascent copy` produces for a report are the exception.

## What happens to your pull request

Every pull request is reviewed and has to pass CI before it can merge.

One thing worth knowing so it does not surprise you: **this repository is published in batches from a
separate development repository.** An accepted contribution is integrated there and returns here with
the next publication, so your commit may not appear verbatim in the history. Your authorship is
credited in `CHANGELOG.md`, and the discussion stays on the pull request.

If a change is large, open an issue first and let's agree on the shape before you write it.
