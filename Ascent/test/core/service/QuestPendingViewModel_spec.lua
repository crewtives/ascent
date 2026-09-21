-- The guarantee under test is the level-report-panel spec's "experiencia
-- pendiente" scenarios: total/readyTotal/unknownCount pass straight through
-- from the report as a projection this module never touches, an unknown
-- quest shows up in entries without affecting the total, an empty forecast
-- (no quests accepted) is active but empty, and only the total absence of
-- both a report and entries reads as inactive.

describe("QuestPendingViewModel", function()
  local ns, QuestPendingViewModel, QuestXpOrigin

  local function levelThatKilled(name, kills, each)
    local record = ns.core.LevelRecord.new(10, 0)
    record.xpRequired = 100000
    for _ = 1, kills do
      ns.core.XpLedger.post(record, ns.core.XpGain.new({
        amount = each, source = ns.core.XpSource.MOB_KILL, at = 1,
        creature = ns.core.CreatureKey.new(15343, 6, name),
      }))
    end
    return record
  end

  local function objective(creature, done, needed)
    return ns.core.QuestObjective.new({ creature = creature, done = done, needed = needed })
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua",
      "core/service/KillXpEstimator.lua", "core/service/QuestPendingViewModel.lua")
    QuestPendingViewModel = ns.core.QuestPendingViewModel
    QuestXpOrigin = ns.core.QuestXpOrigin
  end)

  describe("inactive state", function()
    it("is inactive only when both report and entries are nil", function()
      assert.same({ active = false }, QuestPendingViewModel.build(nil, nil))
    end)
  end)

  describe("no quests accepted", function()
    it("is active, at zero, with an empty entries list -- not inactive", function()
      local report = { total = 0, readyTotal = 0, unknownCount = 0 }

      local viewModel = QuestPendingViewModel.build(report, {})

      assert.is_true(viewModel.active)
      assert.equal(0, viewModel.total)
      assert.equal(0, viewModel.readyTotal)
      assert.equal(0, viewModel.unknownCount)
      assert.is_not_nil(viewModel.entries)
      assert.equal(0, #viewModel.entries)
    end)
  end)

  describe("what a quest still asks the player to kill", function()
    local function entryWith(objectives)
      return { questId = 1, questLevel = 10, reward = 300, origin = QuestXpOrigin.CLIENT,
        complete = false, adjustedReward = 300, objectives = objectives }
    end

    it("prices what is left with the creature's own average, and says where it came from", function()
      local record = levelThatKilled("Springpaw Lynx", 2, 42)
      local model = QuestPendingViewModel.build(nil, { entryWith({ objective("Springpaw Lynx", 3, 6) }) }, record)

      local shown = model.entries[1].objectives[1]
      assert.equal("Springpaw Lynx", shown.creature)
      assert.equal(3, shown.remaining)
      assert.equal(126, shown.estimate)
      assert.equal("creature", shown.basis)
    end)

    it("marks an estimate that had to fall back to the level's average", function()
      local record = levelThatKilled("Springpaw Lynx", 2, 50)
      local model = QuestPendingViewModel.build(nil, { entryWith({ objective("Wretched Thug", 0, 4) }) }, record)

      assert.equal(200, model.entries[1].objectives[1].estimate)
      assert.equal("level", model.entries[1].objectives[1].basis)
    end)

    -- Not knowing is not zero, here as everywhere else in this addon.
    it("leaves the estimate absent when the level has nothing to price with", function()
      local empty = ns.core.LevelRecord.new(10, 0)
      local model = QuestPendingViewModel.build(nil, { entryWith({ objective("Springpaw Lynx", 0, 6) }) }, empty)

      assert.is_nil(model.entries[1].objectives[1].estimate)
      assert.is_nil(model.entries[1].objectives[1].basis)
    end)

    it("leaves out the objectives already finished, and the quests that have none", function()
      local record = levelThatKilled("Springpaw Lynx", 2, 42)
      local model = QuestPendingViewModel.build(nil, {
        entryWith({ objective("Springpaw Lynx", 6, 6), objective("Springpaw Lynx", 1, 4) }),
        entryWith(nil),
      }, record)

      assert.equal(1, #model.entries[1].objectives)
      assert.equal(3, model.entries[1].objectives[1].remaining)
      assert.is_nil(model.entries[2].objectives)
    end)

    -- The guarantee of design D2: those kills will be recorded as creatures when
    -- they happen, so adding them here would count the same afternoon twice.
    it("never lets an estimate reach the pending totals", function()
      local record = levelThatKilled("Springpaw Lynx", 2, 42)
      local report = { total = 300, readyTotal = 0, unknownCount = 0 }
      local model = QuestPendingViewModel.build(report, { entryWith({ objective("Springpaw Lynx", 0, 10) }) }, record)

      assert.equal(300, model.total)
      assert.equal(0, model.readyTotal)
      assert.equal(300, model.entries[1].adjustedReward)
    end)

    it("prices nothing at all when there is no level in progress to price with", function()
      local model = QuestPendingViewModel.build(nil, { entryWith({ objective("Springpaw Lynx", 0, 6) }) }, nil)

      assert.equal(1, #model.entries[1].objectives)
      assert.is_nil(model.entries[1].objectives[1].estimate)
    end)
  end)

  describe("known quests", function()
    it("passes total, readyTotal and unknownCount straight through from the report", function()
      local report = { total = 500, readyTotal = 300, unknownCount = 0 }
      local entries = {
        { questId = 1, questLevel = 10, reward = 300, origin = QuestXpOrigin.CLIENT,
          complete = true, adjustedReward = 300 },
        { questId = 2, questLevel = 10, reward = 200, origin = QuestXpOrigin.CLIENT,
          complete = false, adjustedReward = 200 },
      }

      local viewModel = QuestPendingViewModel.build(report, entries)

      assert.equal(500, viewModel.total)
      assert.equal(300, viewModel.readyTotal)
      assert.equal(0, viewModel.unknownCount)
      assert.equal(2, #viewModel.entries)
    end)

    it("shapes each entry with its provenance, keeping the input order", function()
      local report = { total = 300, readyTotal = 0, unknownCount = 0 }
      local entries = {
        { questId = 1, questLevel = 12, reward = 300, origin = QuestXpOrigin.LEARNED,
          complete = false, adjustedReward = 300 },
      }

      local viewModel = QuestPendingViewModel.build(report, entries)

      local entry = viewModel.entries[1]
      assert.equal(1, entry.questId)
      assert.equal(12, entry.questLevel)
      assert.equal(300, entry.reward)
      assert.equal(QuestXpOrigin.LEARNED, entry.origin)
      assert.is_false(entry.complete)
      assert.equal(300, entry.adjustedReward)
      assert.is_true(entry.isKnown)
    end)
  end)

  describe("a quest with no known reward", function()
    it("appears in entries as not known, and does not affect the total", function()
      local report = { total = 300, readyTotal = 0, unknownCount = 1 }
      local entries = {
        { questId = 1, questLevel = 10, reward = 300, origin = QuestXpOrigin.CLIENT,
          complete = false, adjustedReward = 300 },
        { questId = 2, questLevel = 10, reward = nil, origin = QuestXpOrigin.UNKNOWN,
          complete = false, adjustedReward = nil },
      }

      local viewModel = QuestPendingViewModel.build(report, entries)

      assert.equal(300, viewModel.total) -- unaffected by the unknown quest
      assert.equal(1, viewModel.unknownCount)
      assert.equal(2, #viewModel.entries)

      local unknownEntry = viewModel.entries[2]
      assert.equal(2, unknownEntry.questId)
      assert.is_false(unknownEntry.isKnown)
      assert.is_nil(unknownEntry.adjustedReward)
    end)
  end)
end)
