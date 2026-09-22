-- The guarantee under test mirrors XpBarViewModel's: the per-source fractions
-- have to sum to exactly the level's own completed percentage, and the rested
-- bonus -- already folded into whichever source carried it -- must never be
-- added again on top of that sum. The two rankings (quests by xp, creatures by
-- kill count) are checked separately because they order by different things.

describe("LevelBreakdownViewModel", function()
  local ns, LevelBreakdownViewModel, XpLedger, LevelRecord, XpGain, XpSource, CreatureKey

  local function level(number, required)
    local record = LevelRecord.new(number, 0)
    record.xpRequired = required
    return record
  end

  local function gain(fields)
    fields.source = fields.source or XpSource.MOB_KILL
    fields.at = fields.at or 100
    return XpGain.new(fields)
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua",
      "core/service/Composition.lua", "core/service/LevelBreakdownViewModel.lua")
    LevelBreakdownViewModel = ns.core.LevelBreakdownViewModel
    XpLedger = ns.core.XpLedger
    LevelRecord = ns.core.LevelRecord
    XpGain = ns.core.XpGain
    XpSource = ns.core.XpSource
    CreatureKey = ns.core.CreatureKey
  end)

  describe("inactive states", function()
    it("has nothing to show with no record at all", function()
      assert.same({ active = false }, LevelBreakdownViewModel.build(nil))
    end)

    it("has nothing to show while the level's requirement is still unknown", function()
      local record = LevelRecord.new(10, 0)
      assert.is_nil(record.xpRequired)

      assert.same({ active = false }, LevelBreakdownViewModel.build(record))
    end)
  end)

  describe("sources", function()
    it("gives a completed level one entry per source, fractions summing to percentComplete", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 300, source = XpSource.MOB_KILL }))
      XpLedger.post(record, gain({ amount = 200, source = XpSource.QUEST_TURNIN }))
      -- Exactly fills the level's last 500xp; a no-next-level callback is enough
      -- since the level itself does not need to be closed for this view.
      XpLedger.post(record, gain({ amount = 500, source = XpSource.EXPLORATION }), function() return nil end)

      local viewModel = LevelBreakdownViewModel.build(record)

      assert.is_true(viewModel.active)
      assert.near(1.0, viewModel.percentComplete, 1e-9)
      assert.equal(3, #viewModel.sources)

      local sum = 0
      for _, entry in ipairs(viewModel.sources) do
        sum = sum + entry.fraction
      end
      assert.near(viewModel.percentComplete, sum, 1e-9)
    end)

    it("reflects only the progress made so far on a level still in progress", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 300, source = XpSource.MOB_KILL }))

      local viewModel = LevelBreakdownViewModel.build(record)

      assert.near(0.3, viewModel.percentComplete, 1e-9)
      assert.equal(1, #viewModel.sources)
      assert.near(0.3, viewModel.sources[1].fraction, 1e-9)
    end)

    it("never turns a source sitting at zero into an entry", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 300, source = XpSource.MOB_KILL }))

      local viewModel = LevelBreakdownViewModel.build(record)

      assert.equal(1, #viewModel.sources)
      assert.is_not.equal(XpSource.EXPLORATION, viewModel.sources[1].source)
    end)
  end)

  describe("the rested bonus", function()
    it("is reported on its own without being double-counted in the source sum", function()
      local record = level(10, 1000)
      -- The 300 already includes the 50 rested bonus -- it does not ride on top.
      XpLedger.post(record, gain({ amount = 300, source = XpSource.MOB_KILL, restedBonus = 50 }))

      local viewModel = LevelBreakdownViewModel.build(record)

      assert.near(0.3, viewModel.percentComplete, 1e-9)
      assert.equal(50, viewModel.restedBonus.amount)
      assert.near(0.05, viewModel.restedBonus.fraction, 1e-9)

      local sum = 0
      for _, entry in ipairs(viewModel.sources) do
        sum = sum + entry.fraction
      end
      -- 0.3, not 0.35: the bonus must not be added a second time on top of MOB_KILL.
      assert.near(viewModel.percentComplete, sum, 1e-9)
    end)
  end)

  describe("topQuests", function()
    it("sorts descending by xp, excluding a quest that paid nothing", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 200, source = XpSource.QUEST_TURNIN, questId = 1 }))
      XpLedger.post(record, gain({ amount = 500, source = XpSource.QUEST_TURNIN, questId = 2 }))
      XpLedger.post(record, gain({ amount = 0, source = XpSource.QUEST_TURNIN, questId = 3 }))

      local viewModel = LevelBreakdownViewModel.build(record)

      assert.equal(2, #viewModel.topQuests)
      assert.equal(2, viewModel.topQuests[1].questId)
      assert.equal(500, viewModel.topQuests[1].xpTotal)
      assert.equal(1, viewModel.topQuests[2].questId)
      assert.equal(200, viewModel.topQuests[2].xpTotal)
    end)
  end)

  describe("topCreatures", function()
    it("sorts descending by kill count, not by xp, excluding a creature with no kills", function()
      local record = level(10, 1000)

      -- Fewer kills but more xp per kill: must still rank behind the two below.
      local rareCreature = CreatureKey.new(3, 20)
      XpLedger.post(record, gain({ amount = 10, creature = rareCreature }))
      XpLedger.post(record, gain({ amount = 10, creature = rareCreature }))

      -- Same kill count as the next one, tie broken by xp.
      local weakCreature = CreatureKey.new(1, 5)
      for _ = 1, 5 do
        XpLedger.post(record, gain({ amount = 20, creature = weakCreature }))
      end

      local richCreature = CreatureKey.new(2, 5)
      for _ = 1, 5 do
        XpLedger.post(record, gain({ amount = 30, creature = richCreature }))
      end

      -- Never posted through the ledger (nothing produces a zero-kill bucket for
      -- real): inserted directly to prove the filter excludes it.
      record.creatures["9:1@?"] = { key = CreatureKey.new(9, 1), kills = 0, xpTotal = 0 }

      local viewModel = LevelBreakdownViewModel.build(record)

      assert.equal(3, #viewModel.topCreatures)
      assert.equal(2, viewModel.topCreatures[1].creatureKey.npcId) -- richCreature: 5 kills, 150 xp
      assert.equal(150, viewModel.topCreatures[1].xpTotal)
      assert.equal(1, viewModel.topCreatures[2].creatureKey.npcId) -- weakCreature: 5 kills, 100 xp
      assert.equal(3, viewModel.topCreatures[3].creatureKey.npcId) -- rareCreature: 2 kills
      assert.equal(2, viewModel.topCreatures[3].kills)
    end)

    -- 2.4: one row per population, not per creature. Adding the two back together
    -- here would print the mixed average this change exists to stop showing --
    -- separated in the file and mixed again on the screen is the worst of both --
    -- so each row says which group it was measured in, and the panel is told which
    -- of them is the group of now.
    it("keeps a creature's two populations apart and marks the one being played now", function()
      local record = level(10, 1000)
      local lynx = CreatureKey.new(15343, 6, "Springpaw Lynx")
      for _ = 1, 3 do
        XpLedger.post(record, gain({ amount = 42, creature = lynx, sharedBy = 1 }))
      end
      for _ = 1, 3 do
        XpLedger.post(record, gain({ amount = 10, creature = lynx, sharedBy = 5 }))
      end

      local viewModel = LevelBreakdownViewModel.build(record, 5)

      assert.equal(2, #viewModel.topCreatures)
      local byGroup = {}
      local paid = 0
      for _, row in ipairs(viewModel.topCreatures) do
        byGroup[row.sharedBy] = row
        paid = paid + row.xpTotal
      end
      assert.equal(126, byGroup[1].xpTotal)
      assert.is_false(byGroup[1].current)
      assert.equal(30, byGroup[5].xpTotal)
      assert.is_true(byGroup[5].current, "the group of now is the one the estimates read")
      assert.equal(156, paid, "and the two together are still what the creature paid")

      -- Same record, a character now playing alone: nothing recorded moved, only
      -- which population describes what it is doing (D81).
      for _, row in ipairs(LevelBreakdownViewModel.build(record, 1).topCreatures) do
        assert.equal(row.sharedBy == 1, row.current)
      end
    end)

    -- D84: the context nobody counted is its own population, and a row for it must
    -- not be dressed up as the one measured while playing alone.
    it("never marks kills nobody counted as the group of now", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 42, creature = CreatureKey.new(15343, 6, "Springpaw Lynx") }))

      local row = LevelBreakdownViewModel.build(record, 1).topCreatures[1]

      assert.is_nil(row.sharedBy)
      assert.is_false(row.current)
    end)
  end)

  describe("partial", function()
    it("passes a partial record's mark straight through", function()
      local record = level(10, 1000)
      record.partial = true

      assert.is_true(LevelBreakdownViewModel.build(record).partial)
    end)

    it("passes a non-partial record's mark straight through", function()
      local record = level(10, 1000)
      record.partial = false

      assert.is_false(LevelBreakdownViewModel.build(record).partial)
    end)
  end)

  describe("an empty level", function()
    it("shows zero progress and empty lists without erroring", function()
      local record = level(10, 1000)

      local viewModel = LevelBreakdownViewModel.build(record)

      assert.is_true(viewModel.active)
      assert.equal(0, viewModel.percentComplete)
      assert.equal(0, #viewModel.sources)
      assert.is_not_nil(viewModel.topQuests)
      assert.equal(0, #viewModel.topQuests)
      assert.is_not_nil(viewModel.topCreatures)
      assert.equal(0, #viewModel.topCreatures)
    end)
  end)

  -- Design D36: the panel answers two questions that look like one number. The
  -- level's percentage may legitimately sum to less than a hundred; the
  -- composition of what was observed may not.
  describe("the two percentages", function()
    -- A level with `required` experience needed and `amounts` actually earned.
    local function levelWith(amounts, required)
      local record = level(42, required)
      for source, amount in pairs(amounts) do
        XpLedger.post(record, gain({ amount = amount, source = source }))
      end
      return record
    end

    it("keeps the level fractions summing to the completed percentage, not to one", function()
      local record = levelWith({ [XpSource.MOB_KILL] = 3000, [XpSource.QUEST_TURNIN] = 1000 }, 10000)

      local model = LevelBreakdownViewModel.build(record)
      local sum = 0
      for _, source in ipairs(model.sources) do sum = sum + source.fraction end

      assert.is_true(math.abs(sum - model.percentComplete) < 1e-12)
      assert.is_true(sum < 1)
    end)

    it("makes the composition of what was observed add up to exactly a hundred", function()
      local record = levelWith({ [XpSource.MOB_KILL] = 3000, [XpSource.QUEST_TURNIN] = 1000 }, 10000)

      local model = LevelBreakdownViewModel.build(record)
      local sum = 0
      for _, source in ipairs(model.sources) do sum = sum + source.percent end

      assert.equal(100, sum)
    end)

    it("adds up to a hundred even with three sources that do not divide evenly", function()
      local record = levelWith({
        [XpSource.MOB_KILL] = 1, [XpSource.QUEST_TURNIN] = 1, [XpSource.EXPLORATION] = 1,
      }, 10000)

      local model = LevelBreakdownViewModel.build(record)
      local sum = 0
      for _, source in ipairs(model.sources) do sum = sum + source.percent end

      assert.equal(100, sum)
    end)

    it("says what the composition is a composition of", function()
      local record = levelWith({ [XpSource.MOB_KILL] = 3000, [XpSource.QUEST_TURNIN] = 1000 }, 10000)

      assert.equal(4000, LevelBreakdownViewModel.build(record).observedTotal)
    end)
  end)

  -- The group and raid figures follow the rested bonus exactly: a portion of what
  -- was already credited, reported and never added (design D41).
  -- The second dimension (D39). The rules that differ from the sources block are
  -- the interesting ones: a place that paid nothing still gets a row, and the
  -- rate divides by that place's own time and by nothing else.
  describe("places", function()
    local PlaceKey, PlaceContext

    local function place(context, areaId, name)
      return PlaceKey.new(context, areaId, name)
    end

    before_each(function()
      PlaceKey = ns.core.PlaceKey
      PlaceContext = ns.core.PlaceContext
    end)

    local function levelWithPlaces()
      local record = level(10, 1000)
      local chasm = place(PlaceContext.DUNGEON, 389, "Ragefire Chasm")
      local forest = place(PlaceContext.WORLD, 1429, "Elwynn Forest")

      XpLedger.post(record, gain({ amount = 300 }), nil, chasm)
      XpLedger.post(record, gain({ amount = 100, source = XpSource.QUEST_TURNIN }), nil, forest)
      record:placeEntry(chasm).seconds = 1800
      record:placeEntry(forest).seconds = 900
      return record, chasm, forest
    end

    it("reports one row per place, with its key, amount and time", function()
      local record = levelWithPlaces()

      local places = LevelBreakdownViewModel.build(record).places

      assert.equal(2, #places)
      assert.equal("dungeon:389", places[1].place:id())
      assert.equal("Ragefire Chasm", places[1].place.name)
      assert.equal(PlaceContext.DUNGEON, places[1].place.context)
      assert.equal(300, places[1].amount)
      assert.equal(1800, places[1].seconds)
    end)

    it("computes the rate over that place's own time, not the level's", function()
      local record = levelWithPlaces()

      local places = LevelBreakdownViewModel.build(record).places

      assert.equal(600, places[1].xpPerHour) -- 300 xp in half an hour
      assert.equal(400, places[2].xpPerHour) -- 100 xp in a quarter of an hour
    end)

    -- The row the sources block would never produce, and the one that keeps every
    -- other rate honest: twenty minutes spent for nothing.
    it("keeps a place where time was spent and nothing earned, at a rate of zero", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 300 }), nil, place(PlaceContext.DUNGEON, 389))
      record:placeEntry(place(PlaceContext.WORLD, 1433, "Westfall")).seconds = 1200

      local places = LevelBreakdownViewModel.build(record).places

      assert.equal(2, #places)
      assert.equal("world:1433", places[2].place:id())
      assert.equal(0, places[2].amount)
      assert.equal(0, places[2].xpPerHour)
    end)

    -- The reserved entry is the ledger's bucket for experience nobody could
    -- locate, not somewhere the character was. Empty, it is the moment a portal
    -- takes to resolve, and a real report showed it as a row of zeroes.
    it("drops the reserved entry when no experience landed in it", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 300 }), nil, place(PlaceContext.DUNGEON, 389))
      record:placeEntry(PlaceKey.unknown()).seconds = 1

      local places = LevelBreakdownViewModel.build(record).places

      assert.equal(1, #places)
      assert.equal("dungeon:389", places[1].place:id())
    end)

    it("keeps the reserved entry when experience did land in it", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 300 }), nil, place(PlaceContext.DUNGEON, 389))
      XpLedger.post(record, gain({ amount = 120 }), nil, PlaceKey.unknown())

      local places = LevelBreakdownViewModel.build(record).places

      assert.equal(2, #places)
      assert.equal(120, places[2].amount)
    end)

    -- Zero and unavailable are different answers. A place with experience and no
    -- measured time has no rate; answering zero would read as "this place pays
    -- nothing", which is the opposite of what happened.
    it("has no rate at all for a place whose time was never measured", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 300 }), nil, place(PlaceContext.DUNGEON, 389))

      assert.is_nil(LevelBreakdownViewModel.build(record).places[1].xpPerHour)
    end)

    it("composes to exactly a hundred, the same as the sources do", function()
      local record = level(10, 3000)
      XpLedger.post(record, gain({ amount = 100 }), nil, place(PlaceContext.WORLD, 1))
      XpLedger.post(record, gain({ amount = 100 }), nil, place(PlaceContext.WORLD, 2))
      XpLedger.post(record, gain({ amount = 100 }), nil, place(PlaceContext.WORLD, 3))

      local places = LevelBreakdownViewModel.build(record).places
      local total = 0
      for _, entry in ipairs(places) do
        total = total + entry.percent
      end

      assert.equal(100, total)
    end)

    it("keeps the level fractions summing to the completed percentage, not to one", function()
      local record = levelWithPlaces()
      local breakdown = LevelBreakdownViewModel.build(record)

      local total = 0
      for _, entry in ipairs(breakdown.places) do
        total = total + entry.fraction
      end

      assert.equal(breakdown.percentComplete, total)
      assert.is_true(total < 1)
    end)

    it("adds up to the same experience as the sources do", function()
      local record = levelWithPlaces()
      local breakdown = LevelBreakdownViewModel.build(record)

      local placed = 0
      for _, entry in ipairs(breakdown.places) do
        placed = placed + entry.amount
      end

      assert.equal(breakdown.observedTotal, placed)
      assert.equal(breakdown.observedTotal, breakdown.placedTotal)
    end)

    -- A level already under way when places started being recorded: the places
    -- column is a composition of a smaller total than the sources column, and the
    -- denominator travels with the block so the panel can say why.
    it("reports a placed total below the observed one when the level predates the places", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 400 })) -- before places: the reserved entry
      record.places = {}
      XpLedger.post(record, gain({ amount = 100 }), nil, place(PlaceContext.WORLD, 1429))

      local breakdown = LevelBreakdownViewModel.build(record)

      assert.equal(500, breakdown.observedTotal)
      assert.equal(100, breakdown.placedTotal)
      assert.equal(100, breakdown.places[1].percent)
    end)

    it("orders by experience, then by time, then by the place's own id", function()
      local record = level(10, 5000)
      XpLedger.post(record, gain({ amount = 100 }), nil, place(PlaceContext.WORLD, 2))
      XpLedger.post(record, gain({ amount = 300 }), nil, place(PlaceContext.WORLD, 1))
      record:placeEntry(place(PlaceContext.WORLD, 3)).seconds = 60
      record:placeEntry(place(PlaceContext.WORLD, 4)).seconds = 120

      local places = LevelBreakdownViewModel.build(record).places
      local ids = {}
      for index, entry in ipairs(places) do
        ids[index] = entry.place:id()
      end

      assert.same({ "world:1", "world:2", "world:4", "world:3" }, ids)
    end)

    it("gives the same order on two reads of the same record", function()
      local record = levelWithPlaces()

      local first = LevelBreakdownViewModel.build(record).places
      local second = LevelBreakdownViewModel.build(record).places

      for index = 1, #first do
        assert.equal(first[index].place:id(), second[index].place:id())
      end
    end)

    -- The row carries the time because the rate beside it divides by that time:
    -- a row that hides it cannot be checked, and for a place that earned nothing
    -- it is the only thing the row has to say.
    it("carries the time each place cost", function()
      local record = levelWithPlaces()

      local places = LevelBreakdownViewModel.build(record).places

      assert.equal(1800, places[1].seconds)
      assert.equal(900, places[2].seconds)
    end)

    it("hands out new rows rather than the record's own entries", function()
      local record = levelWithPlaces()

      local row = LevelBreakdownViewModel.build(record).places[1]
      row.amount = 0

      assert.equal(300, record:xpAt(PlaceKey.new(PlaceContext.DUNGEON, 389)))
    end)

    -- Not an empty list: a level recorded before places existed did not fail to
    -- observe where its experience came from, it never looked, and the panel has
    -- to be able to tell those apart to know whether to draw the block at all.
    it("has no block at all for a level recorded before places existed", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 300 }))
      record.places = {}

      assert.is_nil(LevelBreakdownViewModel.build(record).places)
    end)

    it("has no block for a level with entries that hold neither experience nor time", function()
      local record = level(10, 1000)
      record:placeEntry(place(PlaceContext.WORLD, 1429))

      assert.is_nil(LevelBreakdownViewModel.build(record).places)
    end)
  end)

  describe("the group and raid annotations", function()
    local function levelWithModifier(modifier, amount)
      local record = level(30, 10000)
      XpLedger.post(record, gain({ amount = 500, source = XpSource.MOB_KILL, [modifier] = amount }))
      return record
    end

    it("reports a group bonus without adding it to the level", function()
      local model = LevelBreakdownViewModel.build(levelWithModifier("groupBonus", 80))

      assert.equal(80, model.modifiers.groupBonus.amount)
      assert.equal(500 / 10000, model.percentComplete)
    end)

    it("reports a raid penalty without subtracting it from the level", function()
      local model = LevelBreakdownViewModel.build(levelWithModifier("raidPenalty", 120))

      assert.equal(120, model.modifiers.raidPenalty.amount)
      assert.equal(500 / 10000, model.percentComplete)
    end)

    it("reports zero rather than nothing when the level had no modifier", function()
      local record = level(30, 10000)
      XpLedger.post(record, gain({ amount = 500, source = XpSource.MOB_KILL }))

      local model = LevelBreakdownViewModel.build(record)

      assert.equal(0, model.modifiers.groupBonus.amount)
      assert.equal(0, model.modifiers.raidPenalty.amount)
    end)

    it("keeps the sources summing to the level percentage with a modifier present", function()
      local model = LevelBreakdownViewModel.build(levelWithModifier("groupBonus", 80))

      local sum = 0
      for _, source in ipairs(model.sources) do sum = sum + source.fraction end

      assert.is_true(math.abs(sum - model.percentComplete) < 1e-12)
    end)
  end)
end)
