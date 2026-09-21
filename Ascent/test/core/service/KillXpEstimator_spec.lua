-- Pricing the kills a quest still asks for, out of what this character has
-- actually been paid. The two rules under test are that the good number comes
-- from the creature itself, and that anything wider than that says so.

describe("KillXpEstimator", function()
  local ns, KillXpEstimator, Basis, LevelRecord, XpLedger, XpGain, CreatureKey, XpSource, QuestObjective

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua",
      "core/service/KillXpEstimator.lua")
    KillXpEstimator = ns.core.KillXpEstimator
    Basis = KillXpEstimator.Basis
    LevelRecord, XpLedger, XpGain = ns.core.LevelRecord, ns.core.XpLedger, ns.core.XpGain
    CreatureKey, XpSource = ns.core.CreatureKey, ns.core.XpSource
    QuestObjective = ns.core.QuestObjective
  end)

  local function level()
    local record = LevelRecord.new(10, 0)
    record.xpRequired = 100000
    return record
  end

  local function kill(record, name, npcId, creatureLevel, amount)
    XpLedger.post(record, XpGain.new({
      amount = amount, source = XpSource.MOB_KILL, at = 1,
      creature = CreatureKey.new(npcId, creatureLevel, name),
    }))
  end

  local function objective(creature, done, needed)
    return QuestObjective.new({ creature = creature, done = done, needed = needed })
  end

  describe("the creature's own rate", function()
    it("averages every kill of that creature, across the level bands it spans", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40)
      kill(record, "Springpaw Lynx", 15343, 6, 44)
      kill(record, "Springpaw Lynx", 15343, 7, 48) -- a different aggregate, same creature

      assert.equal(44, KillXpEstimator.creatureRate(record, "Springpaw Lynx"))
    end)

    it("answers nil for a creature this level has never killed", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40)

      assert.is_nil(KillXpEstimator.creatureRate(record, "Mana Wyrm"))
      assert.is_nil(KillXpEstimator.creatureRate(level(), "Springpaw Lynx"))
    end)
  end)

  describe("the level's rate", function()
    -- Deaths that paid nothing are recorded and are not part of this: a quest's
    -- remaining kills will pay, or estimating them would be pointless.
    it("divides the level's kill experience by the kills that paid", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40)
      kill(record, "Mana Wyrm", 15274, 6, 60)
      XpLedger.countUnrewardedKill(record)
      XpLedger.countUnrewardedKill(record)

      assert.equal(50, KillXpEstimator.levelRate(record))
    end)

    it("answers nil for a level with nothing killed yet", function()
      assert.is_nil(KillXpEstimator.levelRate(level()))
    end)
  end)

  describe("estimating an objective", function()
    it("prices what is left with the creature's own rate, and says so", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40)
      kill(record, "Springpaw Lynx", 15343, 6, 44)

      local estimate = KillXpEstimator.estimate(record, objective("Springpaw Lynx", 3, 6))

      assert.equal(126, estimate.amount) -- three left at an average of 42
      assert.equal(Basis.CREATURE, estimate.basis)
    end)

    it("falls back to the level's rate for a creature it has never seen, marked as such", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40)
      kill(record, "Springpaw Lynx", 15343, 6, 60)

      local estimate = KillXpEstimator.estimate(record, objective("Wretched Thug", 0, 8))

      assert.equal(400, estimate.amount) -- eight at the level's own 50
      assert.equal(Basis.LEVEL, estimate.basis)
    end)

    -- The distinction the whole addon is built on: not knowing is not zero.
    it("answers nil when the level has nothing to price with", function()
      assert.is_nil(KillXpEstimator.estimate(level(), objective("Springpaw Lynx", 0, 6)))
    end)

    it("prices a finished objective at zero, which is an answer and not an absence", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40)

      local estimate = KillXpEstimator.estimate(record, objective("Springpaw Lynx", 6, 6))

      assert.equal(0, estimate.amount)
    end)

    it("does not blow up on a missing objective", function()
      assert.is_nil(KillXpEstimator.estimate(level(), nil))
    end)
  end)
end)
