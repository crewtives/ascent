describe("XpLedger", function()
  local ns, XpLedger, LevelRecord, XpGain, CreatureKey, XpSource, XpModifier
  local PlaceKey, PlaceContext

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

  -- `sharedBy` left out means nobody counted the group, as for kills saved by
  -- older versions.
  local function killOf(name, npcId, creatureLevel, amount, sharedBy)
    return gain({
      amount = amount,
      creature = CreatureKey.new(npcId, creatureLevel, name),
      sharedBy = sharedBy,
    })
  end

  local function bucketCount(record)
    local count = 0
    for _ in pairs(record.creatures) do
      count = count + 1
    end
    return count
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua")
    XpLedger = ns.core.XpLedger
    LevelRecord = ns.core.LevelRecord
    XpGain = ns.core.XpGain
    CreatureKey = ns.core.CreatureKey
    PlaceKey = ns.core.PlaceKey
    PlaceContext = ns.core.PlaceContext
    XpSource = ns.core.XpSource
    XpModifier = ns.core.XpModifier
  end)

  local function placeIn(context, areaId, name)
    return PlaceKey.new(context, areaId, name)
  end

  describe("posting a gain", function()
    it("moves the total, the source and the detail together", function()
      local record = level(10, 1000)

      XpLedger.post(record, gain({ amount = 44 }))

      assert.equal(44, record.xpTotal)
      assert.equal(44, record:xpFrom(XpSource.MOB_KILL))
      assert.equal(1, #record.gains)
      assert.is_true(record:sourcesAddUp())
    end)

    it("accumulates the modifiers alongside the amount", function()
      local record = level(10, 1000)

      XpLedger.post(record, gain({ amount = 100, restedBonus = 40, groupBonus = 8 }))

      assert.equal(100, record.xpTotal)
      assert.equal(40, record:xpFromModifier(XpModifier.RESTED_BONUS))
      assert.equal(8, record:xpFromModifier(XpModifier.GROUP_BONUS))
    end)

    it("accumulates without splitting while the level's requirement is unknown", function()
      local record = LevelRecord.new(10, 0)

      XpLedger.post(record, gain({ amount = 5000 }))

      assert.equal(5000, record.xpTotal)
      assert.is_true(record:sourcesAddUp())
    end)

    it("aggregates a quest turn-in by identifier", function()
      local record = level(10, 1000)

      XpLedger.post(record, gain({ amount = 250, source = XpSource.QUEST_TURNIN, questId = 1234 }))

      assert.equal(250, record.quests[1234].xpTotal)
      assert.equal(1, record.quests[1234].turnIns)
    end)
  end)

  describe("aggregating creatures", function()
    -- Experience depends on the creature's level and around a quarter of creature
    -- types span a level range, so averaging the range together would quietly
    -- describe a creature that does not exist.
    it("keeps the same type at different levels apart", function()
      local record = level(10, 10000)

      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 40))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 9, 90))

      local young = record.creatures["5644:6@?"]
      local older = record.creatures["5644:9@?"]

      assert.equal(2, young.kills)
      assert.equal(84, young.xpTotal)
      assert.equal(42, young.xpTotal / young.kills)
      assert.equal(1, older.kills)
      assert.equal(90, older.xpTotal / older.kills)
    end)

    it("puts a creature whose level nobody read in its own group", function()
      local record = level(10, 10000)

      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))
      XpLedger.post(record, killOf("Kobold Miner", 5644, nil, 600))

      assert.equal(44, record.creatures["5644:6@?"].xpTotal)
      assert.equal(600, record.creatures["5644:?@?"].xpTotal)
      assert.equal(44, record.creatures["5644:6@?"].xpTotal / record.creatures["5644:6@?"].kills)
    end)

    it("puts a creature nobody identified at all in the unknown group", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 44, creature = CreatureKey.unknown("Kobold Miner") }))

      assert.equal(1, record.creatures["?:?@?"].kills)
    end)

    -- The shared entry is honest; a name on it is not. Everything the combat log
    -- could not identify lands here, so keeping the first arrival's name would print
    -- one creature's name beside the kills and experience of all the others -- a
    -- creature that never paid most of what the row claims.
    it("gives the unknown group no creature's name, however many arrive", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 44, creature = CreatureKey.unknown("Kobold Miner") }))
      XpLedger.post(record, gain({ amount = 60, creature = CreatureKey.unknown("Riverpaw Runt") }))

      local bucket = record.creatures["?:?@?"]
      assert.equal(2, bucket.kills)
      assert.equal(104, bucket.xpTotal)
      assert.is_nil(bucket.key.name)
    end)

    -- A bucket that is one creature keeps its name: the rule is about the
    -- identity being unknown, not about the name being absent.
    it("keeps the name when the creature was identified", function()
      local record = level(10, 10000)

      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))

      assert.equal("Kobold Miner", record.creatures["5644:6@?"].key.name)
    end)

    it("counts a rewarded kill for every gain that names a creature", function()
      local record = level(10, 10000)

      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))
      XpLedger.post(record, killOf("Riverpaw Runt", 476, 8, 60))

      assert.equal(2, record.killsWithXp)
      assert.equal(0, record.killsWithoutXp)
    end)

    -- The server pays less for a creature killed beside four other people, so the
    -- two are two measurements and not one. Averaged together they describe a
    -- creature that pays something nobody was ever paid.
    it("keeps the same creature killed in two group sizes apart", function()
      local record = level(10, 10000)

      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44, 1))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 46, 1))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 12, 5))

      local alone = record.creatures["5644:6@1"]
      local party = record.creatures["5644:6@5"]

      assert.equal(2, alone.kills)
      assert.equal(90, alone.xpTotal)
      assert.equal(45, alone.xpTotal / alone.kills)
      assert.equal(1, party.kills)
      assert.equal(12, party.xpTotal)
      assert.equal(1, alone.sharedBy)
      assert.equal(5, party.sharedBy)
    end)

    -- Separating them is only honest if nothing is lost by it: the two halves
    -- still have to be everything that creature paid this level.
    it("still holds, between the two, everything that creature paid", function()
      local record = level(10, 10000)

      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44, 1))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 46, 1))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 12, 5))

      local alone = record.creatures["5644:6@1"]
      local party = record.creatures["5644:6@5"]

      assert.equal(102, alone.xpTotal + party.xpTotal)
      assert.equal(3, alone.kills + party.kills)
      assert.equal(102, record:xpFrom(XpSource.MOB_KILL))
      assert.equal(3, record.killsWithXp)
    end)

    -- Nobody counted is its own answer. Filing it under solo would be inventing
    -- the observation, and inventing the likeliest one is what would make it
    -- impossible to catch afterwards.
    it("keeps a group nobody counted apart from a group of one", function()
      local record = level(10, 10000)

      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44, 1))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))

      assert.equal(2, bucketCount(record))
      assert.equal(1, record.creatures["5644:6@1"].kills)
      assert.equal(1, record.creatures["5644:6@?"].kills)
      assert.is_nil(record.creatures["5644:6@?"].sharedBy)
    end)
  end)

  -- Finer populations are a finer breakdown of the same experience, so
  -- everything the level says about itself comes out identical however the kills
  -- were shared. These are the numbers the panel and every per-kill average read.
  describe("the level's own sums", function()
    local AMOUNTS = { 44, 46, 12, 90, 8, 60 }

    local function levelKilledIn(sizes)
      local record = level(10, 10000)
      for index, amount in ipairs(AMOUNTS) do
        XpLedger.post(record, killOf("Kobold Miner", 5644, 6, amount, sizes[index]))
      end
      return record
    end

    it("do not move when the same kills are split across group sizes", function()
      local before = levelKilledIn({})              -- one aggregate
      local after = levelKilledIn({ 1, 1, 5, 5, 2 }) -- four aggregates

      assert.equal(before.xpTotal, after.xpTotal)
      assert.equal(before:xpFrom(XpSource.MOB_KILL), after:xpFrom(XpSource.MOB_KILL))
      assert.equal(before.killsWithXp, after.killsWithXp)
      assert.equal(before:averageXpPerKill(), after:averageXpPerKill())

      assert.equal(260, after.xpTotal)
      assert.equal(6, after.killsWithXp)
      assert.is_true(after:sourcesAddUp())
    end)

    -- And the split really happened, so the test above is not passing because
    -- everything still landed in one bucket.
    it("are the same sums over four aggregates instead of one", function()
      assert.equal(1, bucketCount(levelKilledIn({})))
      assert.equal(4, bucketCount(levelKilledIn({ 1, 1, 5, 5, 2 })))
    end)
  end)

  describe("kills that paid nothing", function()
    it("counts them and reports their share of the killing", function()
      local record = level(10, 10000)

      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))
      XpLedger.countUnrewardedKill(record)

      assert.equal(1, record.killsWithoutXp)
      assert.equal(4, record:totalKills())
      assert.equal(0.25, record:unproductiveKillRatio())
    end)

    it("leaves the breakdown by source alone", function()
      local record = level(10, 10000)
      XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 44))

      XpLedger.countUnrewardedKill(record)

      assert.equal(44, record.xpTotal)
      assert.is_true(record:sourcesAddUp())
    end)

    -- "None of your kills were wasted" and "you killed nothing" are different
    -- answers, and only one of them is true for a level spent doing quests.
    it("has no ratio to report with no kills at all", function()
      assert.is_nil(level(10, 1000):unproductiveKillRatio())
    end)

    -- The kills that paid nothing are counted from the combat log's deaths, so
    -- without it the ratio is a fraction of a fraction, and it is not answered.
    it("does not answer for a level recorded without the combat log", function()
      local record = level(10, 1000)
      record.killsWithXp, record.killsWithoutXp = 3, 1
      record:markUnavailable(ns.core.RecordedSource.COMBAT_LOG, "absent")

      assert.is_nil(record:unproductiveKillRatio())
    end)
  end)

  describe("a gain that crosses a level", function()
    local opened

    local function nextLevel(filled)
      opened[#opened + 1] = filled
      return level(filled.level + 1, filled.xpRequired + 100)
    end

    before_each(function()
      opened = {}
    end)

    it("leaves the level it closes at exactly a hundred percent", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 900 }))

      XpLedger.post(record, gain({ amount = 250, source = XpSource.QUEST_TURNIN }), nextLevel)

      assert.equal(1, #opened)
      assert.equal(1000, opened[1].xpTotal)
      assert.equal(opened[1].xpRequired, opened[1].xpTotal)
      assert.is_true(opened[1]:sourcesAddUp())
    end)

    it("opens the next level with the remainder, under the same source", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 900 }))

      local landed = XpLedger.post(record,
        gain({ amount = 250, source = XpSource.QUEST_TURNIN }), nextLevel)

      assert.equal(11, landed.level)
      assert.equal(150, landed.xpTotal)
      assert.equal(150, landed:xpFrom(XpSource.QUEST_TURNIN))
      assert.equal(100, opened[1]:xpFrom(XpSource.QUEST_TURNIN))
    end)

    it("leaves every level it passes through complete", function()
      local record = level(10, 1000)

      local landed = XpLedger.post(record, gain({ amount = 3300 }), nextLevel)

      assert.equal(3, #opened)
      assert.equal(1000, opened[1].xpTotal) -- level 10
      assert.equal(1100, opened[2].xpTotal) -- level 11
      assert.equal(1200, opened[3].xpTotal) -- level 12
      assert.equal(13, landed.level)
      assert.equal(0, landed.xpTotal)
      for _, closed in ipairs(opened) do
        assert.equal(closed.xpRequired, closed.xpTotal)
        assert.is_true(closed:sourcesAddUp())
      end
    end)

    it("loses nothing across the boundary", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 900 }))

      local landed = XpLedger.post(record, gain({ amount = 250, restedBonus = 100 }), nextLevel)

      assert.equal(1150, opened[1].xpTotal + landed.xpTotal)
      assert.equal(100,
        opened[1]:xpFromModifier(XpModifier.RESTED_BONUS)
        + landed:xpFromModifier(XpModifier.RESTED_BONUS))
    end)

    -- "What does a Kobold Miner pay" is a fact about the creature, not about where
    -- the level boundary happened to fall. Splitting it would leave the new level
    -- holding experience with no kill to divide it by.
    it("credits the creature once, in full, to the level the gain started in", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 960 }))

      local landed = XpLedger.post(record, killOf("Kobold Miner", 5644, 6, 80), nextLevel)

      assert.equal(1, opened[1].creatures["5644:6@?"].kills)
      assert.equal(80, opened[1].creatures["5644:6@?"].xpTotal)
      assert.equal(1, opened[1].killsWithXp)
      assert.is_nil(landed.creatures["5644:6@?"])
      assert.equal(0, landed.killsWithXp)
    end)

    it("refuses to go past a level when nobody can open the next one", function()
      local record = level(10, 1000)

      assert.has_error(function() XpLedger.post(record, gain({ amount = 1001 })) end)
      assert.has_error(function() XpLedger.post(level(10, 1000), gain({ amount = 1000 })) end)
    end)

    -- A level filled to the last point is a level the player has left. Keeping it
    -- open would save a finished level as the one in progress.
    it("closes the level a gain fills exactly, and opens the next one empty", function()
      local record = level(10, 1000)

      local landed = XpLedger.post(record, gain({ amount = 1000 }), nextLevel)

      assert.equal(1, #opened)
      assert.equal(1000, opened[1].xpTotal)
      assert.equal(11, landed.level)
      assert.equal(0, landed.xpTotal)
      assert.equal(0, #landed.gains)
    end)
  end)
  -- The second dimension. Every point is counted once by source and once by
  -- place, so the two sums are the same number by construction, not two numbers
  -- that agree only while every writer remembers to do its part.
  describe("where the experience was earned", function()
    local dungeon, forest

    before_each(function()
      dungeon = placeIn(PlaceContext.DUNGEON, 389, "Ragefire Chasm")
      forest = placeIn(PlaceContext.WORLD, 1429, "Elwynn Forest")
    end)

    it("credits the place alongside the source", function()
      local record = level(10, 1000)

      XpLedger.post(record, gain({ amount = 44 }), nil, dungeon)

      assert.equal(44, record:xpAt(dungeon))
      assert.equal(44, record:xpFrom(XpSource.MOB_KILL))
    end)

    it("adds the places up to the same total as the sources", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 44 }), nil, dungeon)
      XpLedger.post(record, gain({ amount = 60 }), nil, dungeon)
      XpLedger.post(record, gain({ amount = 250, source = XpSource.QUEST_TURNIN }), nil, forest)

      assert.equal(104, record:xpAt(dungeon))
      assert.equal(250, record:xpAt(forest))
      assert.equal(record:sumOfSources(), record:sumOfPlaces())
      assert.equal(record.xpTotal, record:sumOfPlaces())
    end)

    -- The same gain counts in both dimensions at once: a quest handed in inside a
    -- dungeon is a turn-in and a dungeon, which is why the place is not a seventh
    -- source.
    it("counts one gain in both dimensions at once", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 250, source = XpSource.QUEST_TURNIN }), nil, dungeon)

      assert.equal(250, record:xpFrom(XpSource.QUEST_TURNIN))
      assert.equal(250, record:xpAt(dungeon))
    end)

    it("files a gain nobody could place in the reserved entry rather than nowhere", function()
      local record = level(10, 1000)

      XpLedger.post(record, gain({ amount = 44 }))

      assert.equal(44, record:xpAt(PlaceKey.unknown()))
      assert.equal(record:sumOfSources(), record:sumOfPlaces())
    end)

    -- The joint, not a third marginal. Two marginals do not determine it: a level
    -- with the same per-source and per-place totals can have been played two ways,
    -- and this is the only record of which one happened.
    it("records which source paid for the experience of each place", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 44 }), nil, dungeon)
      XpLedger.post(record, gain({ amount = 250, source = XpSource.QUEST_TURNIN }), nil, dungeon)
      XpLedger.post(record, gain({ amount = 60 }), nil, forest)

      assert.equal(44, record:xpAtFrom(dungeon, XpSource.MOB_KILL))
      assert.equal(250, record:xpAtFrom(dungeon, XpSource.QUEST_TURNIN))
      assert.equal(60, record:xpAtFrom(forest, XpSource.MOB_KILL))
      assert.equal(0, record:xpAtFrom(forest, XpSource.QUEST_TURNIN))
    end)

    it("keeps each place's breakdown adding up to that place's total", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 44 }), nil, dungeon)
      XpLedger.post(record, gain({ amount = 250, source = XpSource.QUEST_TURNIN }), nil, dungeon)

      local entry = record.places[dungeon:id()]
      local sum = 0
      for _, amount in pairs(entry.xpBySource) do
        sum = sum + amount
      end
      assert.equal(entry.xpTotal, sum)
    end)

    it("leaves the breakdown of a place that only cost time empty, not zeroed", function()
      local record = level(10, 10000)

      record:placeEntry(forest).seconds = 300

      assert.same({}, record.places[forest:id()].xpBySource)
      assert.is_false(record:hasPlaceSources())
    end)

    it("says it can answer the crossed question once a gain has been placed", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 44 }), nil, dungeon)

      assert.is_true(record:hasPlaceSources())
    end)

    -- The client answers a map id before it answers zone text: during a loading
    -- screen the place is already identified and still nameless. Keeping that
    -- first key would file the zone of a whole level under the reserved
    -- "somewhere we could not name", which is a different place.
    it("takes the name of a place it first met without one", function()
      local record = level(10, 10000)

      record:placeEntry(placeIn(PlaceContext.WORLD, 1429, nil)).seconds = 10
      XpLedger.post(record, gain({ amount = 44 }), nil, placeIn(PlaceContext.WORLD, 1429, "Elwynn Forest"))

      assert.equal("Elwynn Forest", record.places["world:1429"].key.name)
    end)

    it("does not let a later nameless sighting take the name back", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 44 }), nil, placeIn(PlaceContext.WORLD, 1429, "Elwynn Forest"))
      record:placeEntry(placeIn(PlaceContext.WORLD, 1429, nil)).seconds = 10

      assert.equal("Elwynn Forest", record.places["world:1429"].key.name)
    end)

    -- Answerable without naming a single place, which is why the kind travels
    -- inside the key.
    it("adds up everything earned in places of one kind", function()
      local record = level(10, 20000)

      XpLedger.post(record, gain({ amount = 4000 }), nil, placeIn(PlaceContext.DUNGEON, 389))
      XpLedger.post(record, gain({ amount = 3000 }), nil, placeIn(PlaceContext.DUNGEON, 718))
      XpLedger.post(record, gain({ amount = 3000 }), nil, placeIn(PlaceContext.WORLD, 1429))

      assert.equal(7000, record:xpByContext(PlaceContext.DUNGEON))
      assert.equal(3000, record:xpByContext(PlaceContext.WORLD))
      assert.equal(0, record:xpByContext(PlaceContext.ARENA))
    end)

    it("does not confuse two places that share a number but not a kind", function()
      local record = level(10, 10000)

      XpLedger.post(record, gain({ amount = 40 }), nil, placeIn(PlaceContext.DUNGEON, 33))
      XpLedger.post(record, gain({ amount = 70 }), nil, placeIn(PlaceContext.WORLD, 33))

      assert.equal(40, record:xpAt(placeIn(PlaceContext.DUNGEON, 33)))
      assert.equal(70, record:xpAt(placeIn(PlaceContext.WORLD, 33)))
    end)
  end)

  describe("a gain that crosses a level, seen from both dimensions", function()
    local opened

    local function nextLevel(filled)
      opened[#opened + 1] = filled
      return level(filled.level + 1, filled.xpRequired + 100)
    end

    before_each(function()
      opened = {}
    end)

    -- The place is split with the experience, unlike the creature aggregate which
    -- is credited whole to the level the gain started in: "where did this level's
    -- experience come from" is a question about the level, so the half that filled
    -- the old one belongs to the old one.
    it("splits the place exactly the way it splits the source", function()
      local dungeon = placeIn(PlaceContext.DUNGEON, 389, "Ragefire Chasm")
      local record = level(10, 1000)
      XpLedger.post(record, gain({ amount = 900 }), nil, dungeon)

      local landed = XpLedger.post(record,
        gain({ amount = 250, source = XpSource.QUEST_TURNIN }), nextLevel, dungeon)

      assert.equal(100, opened[1]:xpFrom(XpSource.QUEST_TURNIN))
      assert.equal(1000, opened[1]:xpAt(dungeon))
      assert.equal(150, landed:xpFrom(XpSource.QUEST_TURNIN))
      assert.equal(150, landed:xpAt(dungeon))
      -- The joint is split by the same arithmetic, so the crossed reading of each
      -- level agrees with that level's own two marginals rather than with the
      -- gain's original shape.
      assert.equal(100, opened[1]:xpAtFrom(dungeon, XpSource.QUEST_TURNIN))
      assert.equal(150, landed:xpAtFrom(dungeon, XpSource.QUEST_TURNIN))
    end)

    it("leaves both levels adding up in both dimensions", function()
      local record = level(10, 1000)

      local landed = XpLedger.post(record, gain({ amount = 3300 }), nextLevel,
        placeIn(PlaceContext.WORLD, 1429, "Elwynn Forest"))

      for _, closed in ipairs(opened) do
        assert.equal(closed:sumOfSources(), closed:sumOfPlaces())
      end
      assert.equal(landed:sumOfSources(), landed:sumOfPlaces())
    end)
  end)
end)
