## What changes, and why

<!-- One or two sentences. The "why" is the part a reviewer cannot reconstruct from the diff. -->

## How it was verified

<!-- Which of the three gates you ran, and anything you checked inside the game. -->

- [ ] `./dev.sh test`
- [ ] `./dev.sh lint`
- [ ] `./dev.sh smoke`
- [ ] Checked in the game client (say which flavour: Classic Era / Burning Crusade Classic)

## Checklist

- [ ] New or changed behaviour is covered by a test, **or** the pull request says why it cannot be and
      what was checked in game instead
- [ ] Any new `.lua` file is listed in `Ascent/Ascent.toc`, in its layer's section
- [ ] `core/` still references no outer layer, and still calls no WoW API
- [ ] No external libraries were added
- [ ] Code, comments and player-facing strings are in English
- [ ] If `CHANGELOG.md` changed, `Ascent/core/constants/Changelog.lua` was regenerated with
      `luajit tools/changelog.lua`
