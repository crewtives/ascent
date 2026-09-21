-- ReportPanelViewModel is pure composition: the three tabs already have their
-- own full test suites, so this only has to prove the bundling is correct, not
-- re-prove each tab's own rules.

describe("ReportPanelViewModel", function()
  local ns, ReportPanelViewModel, XpLedger, LevelRecord, XpGain, XpSource

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua", "core/service/Composition.lua",
      "core/service/LevelBreakdownViewModel.lua", "core/service/CombatBreakdownViewModel.lua",
      "core/service/AbilityRankingViewModel.lua", "core/service/QuestPendingViewModel.lua",
      "core/service/ReportPanelViewModel.lua")
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

  it("still returns a pending tab (inactive, not an error) when no quest data is given", function()
    local record = LevelRecord.new(10, 0)
    record.xpRequired = 1000

    local viewModel = ReportPanelViewModel.build(record)

    assert.is_false(viewModel.pending.active)
  end)
end)
