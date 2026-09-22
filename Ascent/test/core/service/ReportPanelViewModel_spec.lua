-- Pure composition: each tab has its own suite, so this proves only that the
-- bundling is correct.

describe("ReportPanelViewModel", function()
  local ns, ReportPanelViewModel, XpLedger, LevelRecord, XpGain, XpSource

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua", "core/service/Composition.lua",
      "core/service/LevelBreakdownViewModel.lua", "core/service/CombatBreakdownViewModel.lua",
      "core/service/AbilityRankingViewModel.lua", "core/service/KillXpEstimator.lua",
      "core/service/QuestPendingViewModel.lua", "core/service/ReportPanelViewModel.lua")
    ReportPanelViewModel = ns.core.ReportPanelViewModel
    XpLedger = ns.core.XpLedger
    LevelRecord = ns.core.LevelRecord
    XpGain = ns.core.XpGain
    XpSource = ns.core.XpSource
  end)

  it("is inactive with no record selected", function()
    local viewModel = ReportPanelViewModel.build(nil)
    assert.is_false(viewModel.active)
  end)

  it("bundles all three tabs from the same record", function()
    local record = LevelRecord.new(10, 0)
    record.xpRequired = 1000
    XpLedger.post(record, XpGain.new({ amount = 400, source = XpSource.MOB_KILL, at = 0 }))

    local viewModel = ReportPanelViewModel.build(record)

    assert.is_true(viewModel.active)
    assert.is_true(viewModel.breakdown.active)
    assert.near(0.4, viewModel.breakdown.percentComplete, 1e-9)
    assert.is_true(viewModel.combat.active)
    assert.is_true(viewModel.abilities.active)
  end)

  it("bundles the pending-quest-xp tab from params, independent of the record", function()
    local record = LevelRecord.new(10, 0)
    record.xpRequired = 1000

    local viewModel = ReportPanelViewModel.build(record, {
      questReport = { total = 300, readyTotal = 100, unknownCount = 1 },
      questEntries = {},
    })

    assert.is_true(viewModel.pending.active)
    assert.equal(300, viewModel.pending.total)
  end)

  -- The group of now has to reach both tabs that price a creature, and the
  -- bundling is the only place that can hand it to them; otherwise the
  -- per-creature rows and the pending estimates would describe different
  -- groups.
  it("hands both tabs the group of now", function()
    local record = LevelRecord.new(10, 0)
    record.xpRequired = 1000
    local lynx = ns.core.CreatureKey.new(15343, 6, "Springpaw Lynx")
    XpLedger.post(record, XpGain.new({ amount = 100, source = XpSource.MOB_KILL, at = 0,
      creature = lynx, sharedBy = 1 }))
    XpLedger.post(record, XpGain.new({ amount = 20, source = XpSource.MOB_KILL, at = 0,
      creature = lynx, sharedBy = 5 }))

    local viewModel = ReportPanelViewModel.build(record, {
      questEntries = { { questId = 1, questLevel = 10, reward = 300, adjustedReward = 300,
        origin = ns.core.QuestXpOrigin.CLIENT, complete = false,
        objectives = { ns.core.QuestObjective.new({ creature = "Springpaw Lynx", done = 0, needed = 2 }) } } },
      currentRecord = record,
      sharedBy = 5,
    })

    local objective = viewModel.pending.entries[1].objectives[1]
    assert.equal(40, objective.estimate, "two of them at what a group of five was paid for one")
    assert.equal("creature", objective.basis)

    for _, row in ipairs(viewModel.breakdown.topCreatures) do
      assert.equal(row.sharedBy == 5, row.current)
    end
  end)

  it("still returns a pending tab (inactive, not an error) when no quest data is given", function()
    local record = LevelRecord.new(10, 0)
    record.xpRequired = 1000

    local viewModel = ReportPanelViewModel.build(record)

    assert.is_false(viewModel.pending.active)
  end)
end)
