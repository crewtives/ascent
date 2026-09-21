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
- Comments explain **why**, not what. The code already says what it does; what it cannot say is the
  reason it is shaped that way, or which failure it is guarding against.
- Commit subjects and pull request titles are a short imperative sentence saying what changes and why
  it matters — *"Say nothing on a bar too thin to be read"*, not *"fix bar"* and not `fix:`. This
  project does not use Conventional Commits.
- Keep the diff to what the change needs. Unrelated reformatting makes a review about the wrong thing.

## What happens to your pull request

Every pull request is reviewed and has to pass CI before it can merge.

One thing worth knowing so it does not surprise you: **this repository is published in batches from a
separate development repository.** An accepted contribution is integrated there and returns here with
the next publication, so your commit may not appear verbatim in the history. Your authorship is
credited in `CHANGELOG.md`, and the discussion stays on the pull request.

If a change is large, open an issue first and let's agree on the shape before you write it.
