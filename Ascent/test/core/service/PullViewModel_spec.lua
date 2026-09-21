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
      -- The bucket shape XpLedger writes: { key, kills, xpTotal }, filed under
      -- the key's own id. Built by hand rather than by driving the ledger, so a
      -- change in how experience is POSTED cannot quietly rewrite what this test
      -- is asserting about how it is READ.
      local key = ns.core.CreatureKey.new(entry.npcId or index, entry.level or 10, entry.name)
      record.creatures[key:id()] = { key = key, kills = entry.kills, xpTotal = entry.xpTotal }
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
      local level = levelWith({ { name = "Mana Serpent", kills = 2, xpTotal = 172 } })
      local pull = PullRecord.new(0)
      pull:recordDamageDealt(10, "Mana Serpent", "guid-a")
      pull:recordDamageDealt(10, "Mana Serpent", "guid-b")

      local view = PullViewModel.build(pull, PullPhase.ACTIVE, 3, level)

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

    -- The defect this replaces: the estimate used to cover only what was still
    -- standing, so it vanished the instant the last target fell -- which in
    -- Classic is exactly when the experience has not arrived yet. The headline
    -- dropped to the banked zero and reported a won fight as worth nothing.
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

    -- D4: the level's own mean is a much wider number than a creature's own, and
    -- the answer has to say which one it is.
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

    -- The defect these hold: the bar and the rate read the BANKED total while the
    -- headline read the forecast, so a plate saying "73 XP" sat above an empty
    -- bar and "0 xp/h" for the whole of every fight.
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

      assert.equal(PullViewModel.TOP_CREATURES, #view.creatures)
      assert.equal("Creature 6", view.creatures[1].name)
      assert.equal(6, view.creatures[1].killed)
      assert.equal("Creature 3", view.creatures[4].name)
    end)

    -- The whole point of the engaged half: this list is not empty during the
    -- first fight, which is when someone is actually looking at it.
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
    -- Both reserved keys survive as SEPARATE entries. They are two different
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

    assert.equal(PullViewModel.TOP_ABILITIES,
      #PullViewModel.build(pull, PullPhase.CLOSED, 10).abilities)
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
