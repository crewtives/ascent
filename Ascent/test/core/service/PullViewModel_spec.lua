describe("PullViewModel", function()
  local ns, PullRecord, PullViewModel, PullPhase, XpSource, AbilityKey

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "core/service/AbilityRankingViewModel.lua", "core/service/KillXpEstimator.lua",
      "core/service/PullViewModel.lua")
    PullRecord = ns.core.PullRecord
    PullViewModel = ns.core.PullViewModel
    PullPhase = ns.core.PullPhase
    XpSource = ns.core.XpSource
    AbilityKey = ns.core.AbilityKey
  end)

  -- A level that has already killed some of these, which is what makes an
  -- estimate a measurement rather than a guess. Built the way XpLedger builds one.
  local function levelWith(entries)
    local record = ns.core.LevelRecord.new(11, 0)
    for index, entry in ipairs(entries) do
      -- The bucket shape XpLedger writes, { key, sharedBy, kills, xpTotal },
      -- filed under the creature and its group. Built by hand so a change in
      -- how experience is posted cannot rewrite what this asserts about how it
      -- is read. No group size means nobody counted: its own population, not
      -- playing alone.
      local key = ns.core.CreatureKey.new(entry.npcId or index, entry.level or 10, entry.name)
      record.creatures[ns.core.LevelRecord.creatureId(key, entry.sharedBy)] =
        { key = key, sharedBy = entry.sharedBy, kills = entry.kills, xpTotal = entry.xpTotal }
      record.killsWithXp = record.killsWithXp + entry.kills
      record.xpBySource[XpSource.MOB_KILL] = (record.xpBySource[XpSource.MOB_KILL] or 0) + entry.xpTotal
      record.xpTotal = record.xpTotal + entry.xpTotal
    end
    return record
  end

  describe("what the pull is on course to be worth", function()
    local Basis

    before_each(function()
      Basis = ns.core.KillXpEstimator.Basis
    end)

    it("prices what was pulled from what that creature has paid", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 2, xpTotal = 172, sharedBy = 1 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull:recordDamageDealt(10, "Mana Serpent", "guid-b")

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 3, level, 1)

      assert.equal(172, view.projection.total, "two serpents at 86 each")
      assert.equal(172, view.projection.expected)
      assert.is_true(view.projection.estimated)
      assert.equal(Basis.CREATURE, view.projection.basis)
    end)

    -- The number a player reads has to mean "what this pull is worth", not "what
    -- is left in it" -- otherwise it would fall as the fight went well.
    it("holds steady as they die", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 2, xpTotal = 172 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull:recordDamageDealt(10, "Mana Serpent", "guid-b")
      local before = PullViewModel.build(pull, PullPhase.ACTIVE, 3, level).projection.total

      pull:recordKill("Mana Serpent", 4)
      pull:recordXp(86, XpSource.MOB_KILL)

      assert.equal(before, PullViewModel.build(pull, PullPhase.ACTIVE, 5, level).projection.total)
    end)

    -- In Classic the experience arrives after the last target falls, so an
    -- estimate covering only what is still standing would drop the headline to
    -- the banked zero and report a won fight as worth nothing.
    it("still answers once everything is dead and the experience has not landed", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 2, xpTotal = 172 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull:recordKill("Mana Serpent", 2)

      local view = PullViewModel.build(pull, PullPhase.SETTLING, 3, level)

      assert.equal(86, view.projection.total)
      assert.is_true(view.projection.estimated)
      assert.equal(0, view.xpTotal, "nothing has actually been paid yet")
    end)

    -- Once the real figure overtakes the expectation there is nothing left to
    -- estimate, and the surface can stop marking it -- without the number moving.
    it("stops claiming to be an estimate once more has landed than was expected", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 2, xpTotal = 172 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull:recordKill("Mana Serpent", 2)
      pull:recordXp(120, XpSource.MOB_KILL)

      local view = PullViewModel.build(pull, PullPhase.SETTLING, 3, level)

      assert.equal(120, view.projection.total, "the real figure wins once it is bigger")
      assert.is_false(view.projection.estimated)
    end)

    -- The level's own mean is a much wider number than a creature's own, and the
    -- answer has to say which one it is.
    it("falls back to the level average and marks it as the wider one", function()
      local level = levelWith({ { name = "Kobold Miner", kills = 4, xpTotal = 200 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 3, level)

      assert.equal(50, view.projection.total, "the level has paid 50 a kill")
      assert.equal(Basis.LEVEL, view.projection.basis)
    end)

    it("widens the whole figure when any one term had to fall back", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 2, xpTotal = 172 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull:recordDamageDealt(10, "Springpaw Lynx", "guid-b")

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 3, level)

      assert.equal(Basis.LEVEL, view.projection.basis,
        "a sum is only as sure as its least sure term")
    end)

    -- The plate asks for the group standing in the pull. The same creature pays a
    -- fraction of its solo rate once four other people are splitting it, so
    -- quoting the solo figure inside a dungeon would be wrong by roughly the size
    -- of the group.
    it("prices the pull for the group of now, not for the one that did the killing", function()
      local level = levelWith({
        { npcId = 17204, name = "Mana Serpent", kills = 2, xpTotal = 172, sharedBy = 1 },
        { npcId = 17204, name = "Mana Serpent", kills = 4, xpTotal = 80, sharedBy = 5 },
      })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")

      local inFive = PullViewModel.build(pull, PullPhase.ACTIVE, 3, level, 5)
      assert.equal(20, inFive.projection.total, "what one of them paid in a group of five")
      assert.equal(Basis.CREATURE, inFive.projection.basis)

      local alone = PullViewModel.build(pull, PullPhase.ACTIVE, 3, level, 1)
      assert.equal(86, alone.projection.total, "and the solo average is untouched by it")
      assert.equal(Basis.CREATURE, alone.projection.basis)
    end)

    -- A level saved before group sizes were counted still prices the pull rather
    -- than leave the plate blank, but it is marked, never passed off as a
    -- measurement of the group fighting now.
    it("serves an average from before the distinction existed, marked as mixed", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 2, xpTotal = 172 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 3, level, 5)

      assert.equal(86, view.projection.total)
      assert.equal(Basis.MIXED, view.projection.basis)
    end)

    -- Two pulls with the roles swapped: the creature measured in this group is
    -- read first in one and last in the other, whatever order `pairs` uses, so a
    -- plate that kept the last term it read would claim a measurement on one of
    -- them.
    it("keeps the least sure of its terms, whichever one it reads last", function()
      local serpent = { npcId = 1, name = "Mana Serpent", kills = 2, xpTotal = 172 }
      local lynx = { npcId = 2, name = "Springpaw Lynx", kills = 2, xpTotal = 40 }
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull:recordDamageDealt(10, "Springpaw Lynx", "guid-b")

      local function projectionWith(measured, uncounted)
        measured.sharedBy = 5
        uncounted.sharedBy = nil
        return PullViewModel.build(pull, PullPhase.ACTIVE, 3,
          levelWith({ measured, uncounted }), 5).projection
      end

      local serpentMeasured = projectionWith(serpent, lynx)
      assert.equal(106, serpentMeasured.total, "one measured in this group, one from before")
      assert.equal(Basis.MIXED, serpentMeasured.basis,
        "a sum is only as sure as its least sure term, and this one is not the level's mean")

      local lynxMeasured = projectionWith(lynx, serpent)
      assert.equal(106, lynxMeasured.total)
      assert.equal(Basis.MIXED, lynxMeasured.basis)
    end)

    it("says nothing at all when the level has nothing to estimate from", function()
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")

      assert.is_nil(PullViewModel.build(pull, PullPhase.ACTIVE, 3, levelWith({})).projection,
        "a fresh level knows nothing, and that is not the same as worth nothing")
      assert.is_nil(PullViewModel.build(pull, PullPhase.ACTIVE, 3, nil).projection)
    end)
  end)

  it("is inactive with nothing to show", function()
    assert.is_false(PullViewModel.build(nil, PullPhase.IDLE, 0).active)
    assert.is_false(PullViewModel.build(PullRecord.new(0), PullPhase.IDLE, 0).active)
  end)

  it("tells a running pull from a finished one", function()
    local pull = PullRecord.new(0)

    assert.is_false(PullViewModel.build(pull, PullPhase.ACTIVE, 5).final)
    assert.is_false(PullViewModel.build(pull, PullPhase.SETTLING, 5).final)
    assert.is_true(PullViewModel.build(pull, PullPhase.CLOSED, 5).final)
  end)

  describe("the source chips", function()
    it("are the share of THIS pull and sum to one", function()
      local pull = PullRecord.new(0)
      pull:recordXp(750, XpSource.MOB_KILL)
      pull:recordXp(250, XpSource.QUEST_TURNIN)

      local view = PullViewModel.build(pull, PullPhase.CLOSED, 10)

      assert.equal(2, #view.sources)
      assert.equal(0.75, view.sources[1].fraction)
      assert.equal(0.25, view.sources[2].fraction)
      assert.equal(1, view.sources[1].fraction + view.sources[2].fraction)
    end)

    it("leave out a source that contributed nothing", function()
      local pull = PullRecord.new(0)
      pull:recordXp(100, XpSource.MOB_KILL)

      local view = PullViewModel.build(pull, PullPhase.CLOSED, 10)

      assert.equal(1, #view.sources)
      assert.equal(XpSource.MOB_KILL, view.sources[1].source)
    end)

    -- The bar draws its channels in one order, stated once in core. A plate that
    -- ordered its chips by size would put the same pull's colours in a different
    -- sequence every fight.
    it("follow the bar's own channel order, not the size of the slice", function()
      local pull = PullRecord.new(0)
      pull:recordXp(10, XpSource.UNKNOWN)
      pull:recordXp(900, XpSource.QUEST_TURNIN)
      pull:recordXp(50, XpSource.MOB_KILL)

      local view = PullViewModel.build(pull, PullPhase.CLOSED, 10)

      assert.equal(XpSource.MOB_KILL, view.sources[1].source)
      assert.equal(XpSource.QUEST_TURNIN, view.sources[2].source)
      assert.equal(XpSource.UNKNOWN, view.sources[3].source)
    end)

    -- The bar and the rate read the forecast like the headline does: reading the
    -- banked total would put a plate saying "73 XP" above an empty bar and
    -- "0 xp/h" for the whole of every fight.
    it("shows the forecast as a slice of its own while nothing has been paid", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 1, xpTotal = 86 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 10, level)

      assert.equal(86, view.displayed)
      assert.equal(1, #view.sources)
      assert.is_true(view.sources[1].projected)
      assert.equal(XpSource.MOB_KILL, view.sources[1].source)
      assert.equal(1, view.sources[1].fraction, "the whole bar is the forecast")
    end)

    it("splits the bar between what is banked and what is still expected", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 2, xpTotal = 172 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull:recordDamageDealt(10, "Mana Serpent", "guid-b")
      pull:recordKill("Mana Serpent", 2)
      pull:recordXp(86, XpSource.MOB_KILL)

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 10, level)

      assert.equal(172, view.displayed)
      assert.equal(2, #view.sources)
      assert.is_false(view.sources[1].projected)
      assert.equal(86, view.sources[1].amount)
      assert.is_true(view.sources[2].projected)
      assert.equal(86, view.sources[2].amount)
      assert.equal(1, view.sources[1].fraction + view.sources[2].fraction)
    end)

    it("reports a rate for the number it is actually showing", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 1, xpTotal = 86 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 36, level)

      assert.equal(8600, view.xpPerHour, "86 in 36 seconds is 8600 an hour")
    end)

    it("drops the forecast slice once the pull is final", function()
      local level = levelWith({ { name = "Mana Serpent", kills = 1, xpTotal = 86 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull.endedAt = 10

      local view = PullViewModel.build(pull, PullPhase.CLOSED, 10, level)

      assert.equal(0, view.displayed, "a closed pull reports what it was paid")
      assert.equal(0, #view.sources)
    end)

    it("do not divide by zero on a pull with kills but no experience yet", function()
      local pull = PullRecord.new(0)
      pull:recordKill("Kobold Miner", 1)

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 5)

      assert.equal(0, #view.sources)
      assert.equal(1, view.kills)
    end)
  end)

  describe("the creature list", function()
    it("is ordered by how many were fought, and capped", function()
      local pull = PullRecord.new(0)
      for index = 1, 6 do
        for _ = 1, index do
          pull:recordKill("Creature " .. index, 0)
        end
      end

      local view = PullViewModel.build(pull, PullPhase.CLOSED, 10)

      assert.equal(ns.core.Defaults[ns.core.SettingKey.PLATE_ROWS], #view.creatures)
      assert.equal("Creature 6", view.creatures[1].name)
      assert.equal(6, view.creatures[1].killed)
      assert.equal("Creature 3", view.creatures[4].name)
    end)

    -- The row count is the player's, asked for on every build rather than
    -- captured: the plate is redrawn many times inside one fight, and a number
    -- read at construction would only take effect on the next one. The rows
    -- already exist up to ROW_CEILING; this decides how many have anything in
    -- them.
    it("cuts the list to the number of rows asked for", function()
      local pull = PullRecord.new(0)
      for index = 1, 6 do
        for _ = 1, index do
          pull:recordKill("Creature " .. index, 0)
        end
      end

      assert.equal(2, #PullViewModel.build(pull, PullPhase.CLOSED, 10, nil, nil, 2).creatures)
      assert.equal(6, #PullViewModel.build(pull, PullPhase.CLOSED, 10, nil, nil, 6).creatures)
    end)

    it("does not invent rows when more are asked for than were fought", function()
      local pull = PullRecord.new(0)
      pull:recordKill("Mana Serpent", 0)
      pull:recordKill("Arcane Wraith", 0)

      local view = PullViewModel.build(pull, PullPhase.CLOSED, 10, nil, nil, 6)

      assert.equal(2, #view.creatures)
    end)

    -- A file edited by hand can carry any number at all, and the plate has built
    -- exactly ROW_CEILING rows to put entries in: an eleventh entry would be a row
    -- the view-model promised and the frame has nowhere to draw.
    it("never returns more rows than the plate built", function()
      local pull = PullRecord.new(0)
      for index = 1, 12 do
        pull:recordKill("Creature " .. index, 0)
      end

      local view = PullViewModel.build(pull, PullPhase.CLOSED, 10, nil, nil, 99)

      assert.equal(PullViewModel.ROW_CEILING, #view.creatures)
      assert.equal(ns.core.SettingRange[ns.core.SettingKey.PLATE_ROWS].max,
        PullViewModel.ROW_CEILING)
    end)

    -- The engaged half keeps this list from being empty during the first fight,
    -- which is when someone is actually looking at it.
    it("lists what is being fought before anything has died", function()
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(40, "Mana Serpent", "guid-a")
      pull:recordDamageDealt(20, "Mana Serpent", "guid-b")

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 3)

      assert.equal(1, #view.creatures)
      assert.equal("Mana Serpent", view.creatures[1].name)
      assert.equal(2, view.creatures[1].engaged)
      assert.equal(0, view.creatures[1].killed)
      assert.equal(2, view.creatures[1].pending, "both are still alive")
      assert.equal(2, view.engaged)
      assert.equal(0, view.kills)
    end)

    it("counts down what is still standing as they fall", function()
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(40, "Mana Serpent", "guid-a")
      pull:recordDamageDealt(20, "Mana Serpent", "guid-b")
      pull:recordKill("Mana Serpent", 4)

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 5)

      assert.equal(2, view.creatures[1].engaged)
      assert.equal(1, view.creatures[1].killed)
      assert.equal(1, view.creatures[1].pending)
    end)

    -- `pairs` has no defined order, so without the tie-break the same unchanged
    -- pull could list its creatures differently on two consecutive redraws --
    -- which reads as a flicker, not as data.
    it("breaks ties by name so two redraws of one pull agree", function()
      local pull = PullRecord.new(0)
      pull:recordKill("Zeta", 0)
      pull:recordKill("Alpha", 0)

      local first = PullViewModel.build(pull, PullPhase.CLOSED, 10).creatures
      local second = PullViewModel.build(pull, PullPhase.CLOSED, 10).creatures

      assert.equal("Alpha", first[1].name)  -- both were fought once; the name decides
      assert.equal(first[1].name, second[1].name)
      assert.equal(first[2].name, second[2].name)
    end)
  end)

  -- The reuse PullRecord's shape exists for: no second ranking implementation.
  it("ranks abilities through the level report's own view-model", function()
    local pull = PullRecord.new(0)
    for _ = 1, 9 do pull:recordAbility(1752, "Mind Blast") end
    for _ = 1, 3 do pull:recordAbility(2098, "Smite") end
    pull:recordAbility(AbilityKey.MELEE_SWING, nil)
    pull:recordAbility(AbilityKey.RANGED_AUTO, nil)

    local view = PullViewModel.build(pull, PullPhase.CLOSED, 10)

    assert.equal(14, view.totalUses)
    assert.equal(1752, view.abilities[1].key)
    assert.equal(9, view.abilities[1].count)
    assert.equal(2098, view.abilities[2].key)
    -- Both reserved keys survive as separate entries. They are two different
    -- attacks and the plate names them apart; a ranking that folded them together
    -- would make that impossible downstream.
    assert.is_true(view.abilities[3].isAutoAttack)
    assert.is_true(view.abilities[4].isAutoAttack)
    assert.are_not.equal(view.abilities[3].key, view.abilities[4].key)
  end)

  it("caps the ability list", function()
    local pull = PullRecord.new(0)
    for spell = 1, 9 do
      for _ = 1, spell do pull:recordAbility(spell, "Spell " .. spell) end
    end

    assert.equal(ns.core.Defaults[ns.core.SettingKey.PLATE_ROWS],
      #PullViewModel.build(pull, PullPhase.CLOSED, 10).abilities)
  end)

  it("cuts the ability list to the number of rows asked for too", function()
    local pull = PullRecord.new(0)
    for spell = 1, 9 do
      for _ = 1, spell do pull:recordAbility(spell, "Spell " .. spell) end
    end

    assert.equal(2, #PullViewModel.build(pull, PullPhase.CLOSED, 10, nil, nil, 2).abilities)
    assert.equal(6, #PullViewModel.build(pull, PullPhase.CLOSED, 10, nil, nil, 6).abilities)
  end)

  it("carries the rates already divided, and nil where there is no denominator", function()
    local pull = PullRecord.new(0)
    pull:recordXp(600, XpSource.MOB_KILL)
    pull:recordDamageDealt(1200)
    pull.endedAt = 60

    local view = PullViewModel.build(pull, PullPhase.CLOSED, 60)

    assert.equal(60, view.elapsed)
    assert.equal(36000, view.xpPerHour)
    assert.equal(20, view.damagePerSecond)
    assert.is_nil(view.xpPerKill, "no kills means no average per kill, not zero")
  end)

  it("marks a pull where nothing happened as empty", function()
    local pull = PullRecord.new(0)
    pull.endedAt = 2

    local view = PullViewModel.build(pull, PullPhase.CLOSED, 2)

    assert.is_true(view.active)
    assert.is_true(view.empty)
  end)

  it("carries both the running chain and the best one", function()
    local pull = PullRecord.new(0, { comboWindow = 5 })
    pull:recordKill("Kobold Miner", 0)
    pull:recordKill("Kobold Miner", 2)
    pull:recordKill("Kobold Miner", 4)
    pull:recordKill("Kobold Miner", 60)

    local view = PullViewModel.build(pull, PullPhase.CLOSED, 60)

    assert.equal(1, view.streak)
    assert.equal(3, view.bestStreak)
    assert.equal(4, view.kills)
  end)
end)
