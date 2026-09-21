describe("PullRecord", function()
  local ns, PullRecord, XpSource, AbilityKey

  before_each(function()
    ns = AscentTest.loadWith("core/model/")
    PullRecord = ns.core.PullRecord
    XpSource = ns.core.XpSource
    AbilityKey = ns.core.AbilityKey
  end)

  it("starts empty and says so", function()
    local pull = PullRecord.new(0)

    assert.equal(0, pull.xpTotal)
    assert.equal(0, pull.kills)
    assert.is_true(pull:isEmpty())
  end)

  it("splits experience by source and keeps the total", function()
    local pull = PullRecord.new(0)

    pull:recordXp(120, XpSource.MOB_KILL)
    pull:recordXp(40, XpSource.MOB_KILL)
    pull:recordXp(900, XpSource.QUEST_TURNIN)

    assert.equal(1060, pull.xpTotal)
    assert.equal(160, pull.xpBySource[XpSource.MOB_KILL])
    assert.equal(900, pull.xpBySource[XpSource.QUEST_TURNIN])
  end)

  it("refuses experience from a source nobody declared", function()
    local pull = PullRecord.new(0)

    assert.has_error(function() pull:recordXp(10, "banana") end)
  end)

  -- The distinction the model exists to keep: a chain is not a kill count.
  describe("the chain", function()
    it("extends while kills keep landing inside the window", function()
      local pull = PullRecord.new(0, { comboWindow = 10 })

      pull:recordKill("Kobold Miner", 0)
      pull:recordKill("Kobold Miner", 4)
      pull:recordKill("Kobold Laborer", 9)

      assert.equal(3, pull.streak)
      assert.equal(3, pull.bestStreak)
      assert.equal(3, pull.kills)
    end)

    it("breaks when the player goes quiet for longer than the window", function()
      local pull = PullRecord.new(0, { comboWindow = 10 })

      pull:recordKill("Kobold Miner", 0)
      pull:recordKill("Kobold Miner", 5)
      -- Forty seconds of drinking.
      pull:recordKill("Kobold Miner", 45)

      assert.equal(1, pull.streak, "the chain should have restarted")
      assert.equal(2, pull.bestStreak, "the best chain of the pull should survive the break")
      assert.equal(3, pull.kills, "a broken chain is not a lost kill")
    end)

    it("remembers the longest chain even after a shorter one follows it", function()
      local pull = PullRecord.new(0, { comboWindow = 5 })

      for at = 0, 12, 3 do
        pull:recordKill("Kobold Miner", at)
      end
      pull:recordKill("Kobold Miner", 60)

      assert.equal(1, pull.streak)
      assert.equal(5, pull.bestStreak)
    end)
  end)

  it("tallies creatures by name and survives one with none", function()
    local pull = PullRecord.new(0)

    pull:recordKill("Kobold Miner", 0)
    pull:recordKill("Kobold Miner", 1)
    pull:recordKill(nil, 2)

    assert.equal(2, pull.creatures["Kobold Miner"].killed)
    assert.equal(3, pull.kills, "a nameless kill still counts as a kill")
  end)

  -- The half of the creature tally that exists for the fight IN PROGRESS. A plate
  -- that could only list the dead had nothing to show for the whole of the first
  -- kill, which is exactly when someone is looking at it.
  describe("what the pull is fighting", function()
    it("counts a creature the moment it is hit, before anything dies", function()
      local pull = PullRecord.new(0)

      pull:recordDamageDealt(40, "Mana Serpent", "Creature-0-1-1-1-17204-A")

      assert.equal(1, pull.creatures["Mana Serpent"].engaged)
      assert.equal(0, pull.creatures["Mana Serpent"].killed)
      assert.equal(1, pull:engagedCount())
      assert.equal(0, pull.kills)
    end)

    it("counts one creature once however many times it is hit", function()
      local pull = PullRecord.new(0)

      for _ = 1, 8 do
        pull:recordDamageDealt(12, "Mana Serpent", "Creature-0-1-1-1-17204-A")
      end

      assert.equal(1, pull.creatures["Mana Serpent"].engaged)
      assert.equal(96, pull.damageDealt, "every blow still counts towards the damage")
    end)

    it("tells two creatures of the same name apart by their guid", function()
      local pull = PullRecord.new(0)

      pull:recordDamageDealt(12, "Mana Serpent", "Creature-0-1-1-1-17204-A")
      pull:recordDamageDealt(12, "Mana Serpent", "Creature-0-1-1-1-17204-B")

      assert.equal(2, pull.creatures["Mana Serpent"].engaged)
      assert.equal(2, pull:engagedCount())
    end)

    -- Undercounting a pack is survivable; inventing one creature per swing is
    -- not, and that is what a nil guid would do without this.
    it("counts a creature with no guid once rather than once per hit", function()
      local pull = PullRecord.new(0)

      pull:recordDamageDealt(12, "Mana Serpent", nil)
      pull:recordDamageDealt(12, "Mana Serpent", nil)

      assert.equal(1, pull.creatures["Mana Serpent"].engaged)
    end)

    -- The defect this closes: a fight you did not start listed nothing and
    -- expected nothing until the first blow the PLAYER landed, so a creature that
    -- beat on you for half a minute was not in the pull at all.
    it("counts something that is hitting you, even if you never hit it back", function()
      local pull = PullRecord.new(0)

      pull:recordDamageTaken(13, "Withered Green Keeper", "Creature-0-1-1-1-15636-A")
      pull:recordDamageTaken(13, "Withered Green Keeper", "Creature-0-1-1-1-15636-A")

      assert.equal(1, pull.creatures["Withered Green Keeper"].engaged)
      assert.equal(1, pull:engagedCount())
      assert.equal(26, pull.damageTaken, "every blow still counts towards the damage")
    end)

    -- One creature, whichever end of it the pull learned about first.
    it("counts a creature once whether it hit you, you hit it, or both", function()
      local pull = PullRecord.new(0)

      pull:recordDamageTaken(13, "Withered Green Keeper", "Creature-0-1-1-1-15636-A")
      pull:recordDamageDealt(20, "Withered Green Keeper", "Creature-0-1-1-1-15636-A")

      assert.equal(1, pull:engagedCount())
    end)

    it("ignores damage taken from something it cannot name", function()
      local pull = PullRecord.new(0)

      pull:recordDamageTaken(50, nil, nil)

      assert.equal(0, pull:engagedCount())
      assert.equal(50, pull.damageTaken)
    end)

    it("ignores damage dealt to something it cannot name", function()
      local pull = PullRecord.new(0)

      pull:recordDamageDealt(50, nil, nil)

      assert.equal(0, pull:engagedCount())
      assert.equal(50, pull.damageDealt)
    end)

    it("never reports fewer engaged than dead", function()
      local pull = PullRecord.new(0)

      -- A kill with no blow of ours ever recorded against it: a pet's killing
      -- blow, or a DoT applied before the pull opened.
      pull:recordKill("Mana Serpent", 1)

      assert.equal(1, pull.creatures["Mana Serpent"].engaged)
      assert.equal(1, pull.creatures["Mana Serpent"].killed)
    end)

    it("keeps counting the same creature as engaged after it dies", function()
      local pull = PullRecord.new(0)

      pull:recordDamageDealt(40, "Mana Serpent", "Creature-0-1-1-1-17204-A")
      pull:recordKill("Mana Serpent", 1)

      assert.equal(1, pull.creatures["Mana Serpent"].engaged)
      assert.equal(1, pull.creatures["Mana Serpent"].killed)
    end)
  end)

  -- The field that exists in exactly LevelRecord's shape so the ranking
  -- view-model can read a pull with no second implementation.
  it("keys abilities the way a level record does", function()
    local pull = PullRecord.new(0)

    pull:recordAbility(1752, "Mind Blast")
    pull:recordAbility(1752, "Mind Blast")
    pull:recordAbility(AbilityKey.MELEE_SWING, nil)

    assert.equal(2, pull.abilities[1752].count)
    assert.equal("Mind Blast", pull.abilities[1752].name)
    assert.is_true(pull.abilities[AbilityKey.MELEE_SWING]:isAutoAttack())
  end)

  describe("time and rates", function()
    it("keeps running while combat is open", function()
      local pull = PullRecord.new(100)

      assert.equal(20, pull:duration(120))
      assert.equal(45, pull:duration(145))
    end)

    -- The reason PullRecord owns `endedAt` rather than letting the view subtract:
    -- a rate whose denominator kept growing while the plaque sat on screen would
    -- visibly sag while the player read it.
    it("stops the moment combat ends, even while the plate is still shown", function()
      local pull = PullRecord.new(100)
      pull:recordXp(600, XpSource.MOB_KILL)
      pull.endedAt = 130

      local rate = pull:xpPerHour(130)
      assert.equal(30, pull:duration(130))
      assert.equal(30, pull:duration(400), "the clock should not have kept running")
      assert.equal(rate, pull:xpPerHour(400))
    end)

    it("answers nil rather than zero when there is nothing to divide by", function()
      local pull = PullRecord.new(100)

      assert.is_nil(pull:xpPerHour(100))
      assert.is_nil(pull:damagePerSecond(100))
      assert.is_nil(pull:xpPerKill())
    end)

    it("divides experience by kills once there are kills", function()
      local pull = PullRecord.new(0)
      pull:recordXp(300, XpSource.MOB_KILL)
      pull:recordKill("Kobold Miner", 0)
      pull:recordKill("Kobold Miner", 1)

      assert.equal(150, pull:xpPerKill())
    end)

    it("never reports negative time from a clock that moved backwards", function()
      local pull = PullRecord.new(100)

      assert.equal(0, pull:duration(80))
    end)
  end)

  it("counts damage, healing and deaths", function()
    local pull = PullRecord.new(0)

    pull:recordDamageDealt(420)
    pull:recordDamageDealt(80)
    pull:recordDamageTaken(130)
    pull:recordHealing(60)
    pull:recordDeath()

    assert.equal(500, pull.damageDealt)
    assert.equal(130, pull.damageTaken)
    assert.equal(60, pull.healingReceived)
    assert.equal(1, pull.deaths)
    assert.is_false(pull:isEmpty())
  end)

  -- Stated as a test because it is a decision, not an omission: a pull is
  -- answered while the player remembers it and then it is gone. See the header.
  it("is not persistable, on purpose", function()
    local pull = PullRecord.new(0)

    assert.is_nil(pull.toStored)
    assert.is_nil(PullRecord.restore)
  end)
end)
