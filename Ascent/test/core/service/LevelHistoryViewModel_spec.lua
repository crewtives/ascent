describe("LevelHistoryViewModel", function()
  local ns, LevelHistoryViewModel, LevelRecord, XpLedger, XpGain, XpSource

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua",
      "core/service/Composition.lua", "core/service/LevelHistoryViewModel.lua")
    LevelHistoryViewModel = ns.core.LevelHistoryViewModel
    LevelRecord = ns.core.LevelRecord
    XpLedger = ns.core.XpLedger
    XpGain = ns.core.XpGain
    XpSource = ns.core.XpSource
  end)

  local function levelWith(number, amounts, playedSeconds)
    local record = LevelRecord.new(number, 0)
    record.xpRequired = 10000
    record.playedSeconds = playedSeconds or 0
    for source, amount in pairs(amounts) do
      XpLedger.post(record, XpGain.new({ amount = amount, source = source, at = 100 }))
    end
    return record
  end

  describe("the selector", function()
    it("says so when there is no history at all", function()
      local model = LevelHistoryViewModel.build({})

      assert.is_true(model.empty)
      assert.is_nil(model.selected)
      assert.same({}, model.entries)
    end)

    it("lists the most recent level first", function()
      local model = LevelHistoryViewModel.build({ levels = { 12, 15, 13 } })

      assert.equal(15, model.entries[1].level)
      assert.equal(13, model.entries[2].level)
      assert.equal(12, model.entries[3].level)
    end)

    it("includes the level in progress, marked as such", function()
      local model = LevelHistoryViewModel.build({ levels = { 20, 21 }, current = 22 })

      assert.equal(22, model.entries[1].level)
      assert.is_true(model.entries[1].current)
      assert.is_false(model.entries[2].current)
    end)

    it("selects the most recent when the player has not picked one", function()
      local model = LevelHistoryViewModel.build({ levels = { 20, 21 }, current = 22 })

      assert.equal(22, model.selected)
      assert.is_true(model.entries[1].selected)
    end)

    it("honours the level the player picked", function()
      local model = LevelHistoryViewModel.build({ levels = { 20, 21 }, current = 22, selected = 20 })

      assert.equal(20, model.selected)
      assert.is_true(model.entries[3].selected)
      assert.is_false(model.entries[1].selected)
    end)

    -- Retention trims old levels and the player can clear their data, so a
    -- selection outliving the level it points at is ordinary, not exotic.
    it("falls back to the most recent when the selected level is gone", function()
      local model = LevelHistoryViewModel.build({ levels = { 20, 21 }, selected = 7 })

      assert.equal(21, model.selected)
    end)

    it("marks exactly one entry as selected", function()
      local model = LevelHistoryViewModel.build({ levels = { 1, 2, 3 }, current = 4, selected = 2 })

      local count = 0
      for _, entry in ipairs(model.entries) do
        if entry.selected then count = count + 1 end
      end

      assert.equal(1, count)
    end)
  end)

  describe("the comparison", function()
    it("has nothing to compare against for the very first level", function()
      local record = levelWith(10, { [XpSource.MOB_KILL] = 100 })

      assert.is_false(LevelHistoryViewModel.compare(record, nil).available)
      assert.is_false(LevelHistoryViewModel.compare(nil, record).available)
    end)

    it("reports how much longer or shorter the level took", function()
      local here = levelWith(11, { [XpSource.MOB_KILL] = 100 }, 1800)
      local there = levelWith(10, { [XpSource.MOB_KILL] = 100 }, 2400)

      local comparison = LevelHistoryViewModel.compare(here, there)

      assert.equal(-600, comparison.duration.delta)
      assert.equal("down", comparison.duration.direction)
      assert.equal(1800, comparison.duration.seconds)
      assert.equal(2400, comparison.duration.previousSeconds)
    end)

    -- The panel must be able to show the sense of a difference without relying
    -- on red and green, because in this addon those two colours already mean
    -- creatures and exploration.
    it("carries the direction of every difference as a field, not as a colour", function()
      local here = levelWith(11, { [XpSource.MOB_KILL] = 900, [XpSource.QUEST_TURNIN] = 100 })
      local there = levelWith(10, { [XpSource.MOB_KILL] = 100, [XpSource.QUEST_TURNIN] = 900 })

      local comparison = LevelHistoryViewModel.compare(here, there)

      local bySource = {}
      for _, entry in ipairs(comparison.sources) do bySource[entry.source] = entry end

      assert.equal("up", bySource[XpSource.MOB_KILL].direction)
      assert.equal("down", bySource[XpSource.QUEST_TURNIN].direction)
    end)

    it("says 'same' rather than inventing a difference", function()
      local here = levelWith(11, { [XpSource.MOB_KILL] = 500 }, 1200)
      local there = levelWith(10, { [XpSource.MOB_KILL] = 500 }, 1200)

      local comparison = LevelHistoryViewModel.compare(here, there)

      assert.equal("same", comparison.duration.direction)
      for _, entry in ipairs(comparison.sources) do
        assert.equal("same", entry.direction)
      end
    end)

    it("keeps a row for every source, including the ones at zero on both sides", function()
      local here = levelWith(11, { [XpSource.MOB_KILL] = 100 })
      local there = levelWith(10, { [XpSource.MOB_KILL] = 100 })

      assert.equal(4, #LevelHistoryViewModel.compare(here, there).sources)
    end)

    it("compares compositions, so two levels of different length are comparable", function()
      -- Half the experience, same shape: the composition is identical and the
      -- comparison should say so, which a raw-amount comparison never would.
      local here = levelWith(11, { [XpSource.MOB_KILL] = 500, [XpSource.QUEST_TURNIN] = 500 })
      local there = levelWith(10, { [XpSource.MOB_KILL] = 1000, [XpSource.QUEST_TURNIN] = 1000 })

      for _, entry in ipairs(LevelHistoryViewModel.compare(here, there).sources) do
        assert.equal(0, entry.delta)
      end
    end)

    it("names both levels being compared", function()
      local comparison = LevelHistoryViewModel.compare(
        levelWith(11, { [XpSource.MOB_KILL] = 1 }),
        levelWith(10, { [XpSource.MOB_KILL] = 1 })
      )

      assert.equal(11, comparison.level)
      assert.equal(10, comparison.previousLevel)
    end)
  end)
end)
