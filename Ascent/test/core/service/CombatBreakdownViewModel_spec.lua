-- The panel's combat tab has one job the spec calls out by name: never show a
-- zero that could mean "measured and it was zero" when it actually means "never
-- measured at all". `hasData` is the switch the tests below hold to that
-- standard, alongside a straight pass-through check for every field it reports.

describe("CombatBreakdownViewModel", function()
  local ns, CombatBreakdownViewModel, LevelRecord, MetricId, CombatSummary

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua", "core/service/CombatBreakdownViewModel.lua")
    CombatBreakdownViewModel = ns.core.CombatBreakdownViewModel
    LevelRecord = ns.core.LevelRecord
    MetricId = ns.core.MetricId
    CombatSummary = ns.core.CombatSummary
  end)

  describe("inactive state", function()
    it("has nothing to show with no record at all", function()
      assert.same({ active = false }, CombatBreakdownViewModel.build(nil))
    end)
  end)

  describe("hasData", function()
    it("is false on a level with zero combat seconds and zero deaths, with sane defaults everywhere", function()
      local record = LevelRecord.new(10, 0)

      local viewModel = CombatBreakdownViewModel.build(record)

      assert.is_true(viewModel.active)
      assert.is_false(viewModel.hasData)

      -- averages/worsts: nothing to average, so nil rather than a fabricated 0.
      assert.is_nil(viewModel.health.average)
      assert.is_nil(viewModel.health.worst)
      assert.is_nil(viewModel.power.average)
      assert.is_nil(viewModel.power.worst)

      -- totals accumulate from zero, so they default to 0, not nil.
      assert.equal(0, viewModel.damage.dealt)
      assert.equal(0, viewModel.damage.taken)
      assert.equal(0, viewModel.damage.healingReceived)
      assert.equal(0, viewModel.deathCount)
      assert.equal(0, viewModel.time.combatSeconds)
      assert.equal(0, viewModel.time.recoverySeconds)
      assert.equal(0, viewModel.time.outOfCombatSeconds)
      assert.equal(0, viewModel.time.timeLostToDeath)

      -- nothing to divide by, so unavailable rather than 0.
      assert.is_nil(viewModel.efficiency.xpPerCombatMinute)
      assert.is_nil(viewModel.efficiency.averageXpPerKill)
    end)

    it("is true once the level has combat seconds", function()
      local record = LevelRecord.new(10, 0)
      record.metrics[MetricId.TIME] = { combatSeconds = 30, recoverySeconds = 0 }

      assert.is_true(CombatBreakdownViewModel.build(record).hasData)
    end)

    it("is true on a level with a death but no recorded combat seconds", function()
      local record = LevelRecord.new(10, 0)
      record.metrics[MetricId.DEATHS] = { count = 1, timeLostToDeath = 12 }

      assert.is_true(CombatBreakdownViewModel.build(record).hasData)
    end)
  end)

  describe("health and power", function()
    it("reads average and worst from a CombatSummary with several samples", function()
      local record = LevelRecord.new(10, 0)
      local summary = CombatSummary.new()
      summary:record(0.8, 0.9)
      summary:record(0.4, 0.5)
      summary:record(0.6, 0.7)
      record.metrics[MetricId.COMBAT_OUTCOME] = summary

      local viewModel = CombatBreakdownViewModel.build(record)

      assert.near((0.8 + 0.4 + 0.6) / 3, viewModel.health.average, 1e-9)
      assert.near(0.4, viewModel.health.worst, 1e-9)
      assert.near((0.9 + 0.5 + 0.7) / 3, viewModel.power.average, 1e-9)
      assert.near(0.5, viewModel.power.worst, 1e-9)
    end)

    it("reports nil, not zero, for a fresh CombatSummary with no samples", function()
      local record = LevelRecord.new(10, 0)
      record.metrics[MetricId.COMBAT_OUTCOME] = CombatSummary.new()

      local viewModel = CombatBreakdownViewModel.build(record)

      assert.is_nil(viewModel.health.average)
      assert.is_nil(viewModel.health.worst)
      assert.is_nil(viewModel.power.average)
      assert.is_nil(viewModel.power.worst)
    end)
  end)

  describe("damage", function()
    it("reads dealt/taken/healingReceived when present", function()
      local record = LevelRecord.new(10, 0)
      record.metrics[MetricId.DAMAGE] = { dealt = 500, taken = 200, healingReceived = 80 }

      local viewModel = CombatBreakdownViewModel.build(record)

      assert.equal(500, viewModel.damage.dealt)
      assert.equal(200, viewModel.damage.taken)
      assert.equal(80, viewModel.damage.healingReceived)
    end)

    it("defaults to zero when no damage was ever recorded", function()
      local record = LevelRecord.new(10, 0)

      local viewModel = CombatBreakdownViewModel.build(record)

      assert.equal(0, viewModel.damage.dealt)
      assert.equal(0, viewModel.damage.taken)
      assert.equal(0, viewModel.damage.healingReceived)
    end)
  end)

  describe("deaths and time", function()
    it("reads death count, time lost to death, combat/recovery/out-of-combat seconds", function()
      local record = LevelRecord.new(10, 0)
      record.playedSeconds = 100
      record.metrics[MetricId.DEATHS] = { count = 2, timeLostToDeath = 25 }
      record.metrics[MetricId.TIME] = { combatSeconds = 40, recoverySeconds = 10 }

      local viewModel = CombatBreakdownViewModel.build(record)

      assert.equal(2, viewModel.deathCount)
      assert.equal(25, viewModel.time.timeLostToDeath)
      assert.equal(40, viewModel.time.combatSeconds)
      assert.equal(10, viewModel.time.recoverySeconds)
      assert.equal(60, viewModel.time.outOfCombatSeconds) -- 100 played - 40 combat
    end)
  end)

  describe("efficiency", function()
    it("passes xpPerCombatMinute and averageXpPerKill through from the record", function()
      local record = LevelRecord.new(10, 0)
      record.metrics[MetricId.TIME] = { combatSeconds = 120, recoverySeconds = 0 }
      ns.core.XpLedger.post(record, ns.core.XpGain.new({ amount = 300, source = ns.core.XpSource.MOB_KILL, at = 1 }))
      record.killsWithXp = 3

      local viewModel = CombatBreakdownViewModel.build(record)

      assert.equal(150, viewModel.efficiency.xpPerCombatMinute) -- 300xp / 2min
      assert.equal(100, viewModel.efficiency.averageXpPerKill) -- 300 mob-kill xp / 3 kills
    end)

    it("reports xpPerCombatMinute as unavailable with zero combat time", function()
      local record = LevelRecord.new(10, 0)
      record.xpTotal = 300

      assert.is_nil(CombatBreakdownViewModel.build(record).efficiency.xpPerCombatMinute)
    end)
  end)
end)
