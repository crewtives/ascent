-- Prices the kills a quest still asks for from what this character has been
-- paid. The good number comes from the creature itself, killed with the same
-- number of people sharing the pay; nothing is borrowed from a different group
-- size; and anything wider than that says so.

describe("KillXpEstimator", function()
  local ns, KillXpEstimator, Basis, LevelRecord, XpLedger, XpGain, CreatureKey, XpSource, QuestObjective

  -- The populations these tests keep apart. Playing alone is a measurement and
  -- has a number; nil is nobody having counted, which is not the same thing and
  -- not the same key.
  local ALONE, DUO, FIVE = 1, 2, 5

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

  local function kill(record, name, npcId, creatureLevel, amount, sharedBy)
    XpLedger.post(record, XpGain.new({
      amount = amount, source = XpSource.MOB_KILL, at = 1,
      creature = CreatureKey.new(npcId, creatureLevel, name),
      sharedBy = sharedBy,
    }))
  end

  local function objective(creature, done, needed)
    return QuestObjective.new({ creature = creature, done = done, needed = needed })
  end

  describe("the creature's own rate", function()
    it("averages every kill of that creature, across the level bands it spans", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)
      kill(record, "Springpaw Lynx", 15343, 6, 44, ALONE)
      kill(record, "Springpaw Lynx", 15343, 7, 48, ALONE) -- a different aggregate, same creature

      assert.equal(44, KillXpEstimator.creatureRate(record, "Springpaw Lynx", ALONE))
    end)

    it("answers nil for a creature this level has never killed", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)

      assert.is_nil(KillXpEstimator.creatureRate(record, "Mana Wyrm", ALONE))
      assert.is_nil(KillXpEstimator.creatureRate(level(), "Springpaw Lynx", ALONE))
    end)
  end)

  -- The group size is the population, and a rate is only ever the average of one
  -- of them: what that size paid, nothing when that size has paid nothing, and
  -- still nothing when a different size has plenty.
  describe("one group size at a time", function()
    it("answers with the kills taken at the size it was asked about", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, FIVE)
      kill(record, "Springpaw Lynx", 15343, 6, 44, FIVE)

      assert.equal(42, KillXpEstimator.creatureRate(record, "Springpaw Lynx", FIVE))
    end)

    it("answers nil for a size that has never killed it, in a level that has", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)
      kill(record, "Mana Wyrm", 15274, 6, 60, FIVE)

      assert.is_nil(KillXpEstimator.creatureRate(record, "Springpaw Lynx", FIVE))
    end)

    it("does not borrow the average a different group size measured", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)
      kill(record, "Springpaw Lynx", 15343, 6, 44, ALONE)

      assert.is_nil(KillXpEstimator.creatureRate(record, "Springpaw Lynx", FIVE))
      -- And the loan is refused in the other direction too: what alone measured
      -- is still exactly what alone measured.
      assert.equal(42, KillXpEstimator.creatureRate(record, "Springpaw Lynx", ALONE))
    end)

    -- The kills nobody counted are a third population, not a spare copy of any
    -- other one: they answer only when they are what was asked for.
    it("keeps what nobody counted out of every size that was counted", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 30)
      kill(record, "Springpaw Lynx", 15343, 6, 50, ALONE)

      assert.equal(50, KillXpEstimator.creatureRate(record, "Springpaw Lynx", ALONE))
      assert.equal(30, KillXpEstimator.creatureRate(record, "Springpaw Lynx", nil))
    end)

    it("prices two sizes each from its own kills, neither holding the other's", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, DUO)
      kill(record, "Springpaw Lynx", 15343, 6, 44, DUO)
      kill(record, "Springpaw Lynx", 15343, 6, 20, FIVE)
      kill(record, "Springpaw Lynx", 15343, 6, 24, FIVE)

      assert.equal(42, KillXpEstimator.creatureRate(record, "Springpaw Lynx", DUO))
      assert.equal(22, KillXpEstimator.creatureRate(record, "Springpaw Lynx", FIVE))
      -- 32 is the average over all four kills: what a pooled read would give both
      -- sizes, and true of neither.
      assert.not_equal(32, KillXpEstimator.creatureRate(record, "Springpaw Lynx", DUO))
      assert.not_equal(32, KillXpEstimator.creatureRate(record, "Springpaw Lynx", FIVE))
    end)
  end)

  describe("the level's rate", function()
    -- Deaths that paid nothing are recorded and are not part of this: a quest's
    -- remaining kills will pay, or estimating them would be pointless.
    it("divides the level's kill experience by the kills that paid", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)
      kill(record, "Mana Wyrm", 15274, 6, 60, ALONE)
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
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)
      kill(record, "Springpaw Lynx", 15343, 6, 44, ALONE)

      local estimate = KillXpEstimator.estimate(record, objective("Springpaw Lynx", 3, 6), ALONE)

      assert.equal(126, estimate.amount) -- three left at an average of 42
      assert.equal(Basis.CREATURE, estimate.basis)
    end)

    it("falls back to the level's rate for a creature it has never seen, marked as such", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)
      kill(record, "Springpaw Lynx", 15343, 6, 60, ALONE)

      local estimate = KillXpEstimator.estimate(record, objective("Wretched Thug", 0, 8), ALONE)

      assert.equal(400, estimate.amount) -- eight at the level's own 50
      assert.equal(Basis.LEVEL, estimate.basis)
    end)

    -- The character killed these alone and has just joined a group of five. What
    -- it measured alone describes a kill it is not about to make.
    it("refuses a different group size's measurement rather than pass it off as this one's", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)
      kill(record, "Springpaw Lynx", 15343, 6, 44, ALONE)
      kill(record, "Mana Wyrm", 15274, 6, 60, FIVE)

      local estimate = KillXpEstimator.estimate(record, objective("Springpaw Lynx", 4, 8), FIVE)

      assert.equal(192, estimate.amount) -- four at the level's 48, not at the 42 measured alone
      assert.not_equal(168, estimate.amount)
      assert.equal(Basis.LEVEL, estimate.basis)
    end)

    -- A history written before the context was counted still prices things, and
    -- the price says what it is rather than claiming to be of this moment.
    it("declares a rate from before the context was counted as one that groups contexts", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40)
      kill(record, "Springpaw Lynx", 15343, 6, 44)

      local estimate = KillXpEstimator.estimate(record, objective("Springpaw Lynx", 3, 6), FIVE)

      assert.equal(126, estimate.amount)
      assert.equal(Basis.MIXED, estimate.basis)
      assert.not_equal(Basis.CREATURE, estimate.basis)
    end)

    it("prefers what the current context measured over what nobody counted", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 30)
      kill(record, "Springpaw Lynx", 15343, 6, 50, ALONE)
      kill(record, "Springpaw Lynx", 15343, 6, 54, ALONE)

      local estimate = KillXpEstimator.estimate(record, objective("Springpaw Lynx", 2, 6), ALONE)

      assert.equal(208, estimate.amount) -- four left at the 52 measured alone, not the 44.67 over all three
      assert.equal(Basis.CREATURE, estimate.basis)
    end)

    -- The distinction the whole addon is built on: not knowing is not zero.
    it("answers nil when the level has nothing to price with", function()
      assert.is_nil(KillXpEstimator.estimate(level(), objective("Springpaw Lynx", 0, 6), ALONE))
    end)

    it("prices a finished objective at zero, which is an answer and not an absence", function()
      local record = level()
      kill(record, "Springpaw Lynx", 15343, 6, 40, ALONE)

      local estimate = KillXpEstimator.estimate(record, objective("Springpaw Lynx", 6, 6), ALONE)

      assert.equal(0, estimate.amount)
    end)

    it("does not blow up on a missing objective", function()
      assert.is_nil(KillXpEstimator.estimate(level(), nil, ALONE))
    end)
  end)
end)
