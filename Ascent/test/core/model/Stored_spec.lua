-- The boundary between a live model and the text file the client writes at logout.
--
-- Two directions with opposite rules, and the tests are split the same way. Going
-- out, anything saved variables cannot hold is the addon's own bug and has to raise
-- here rather than be dropped in silence. Coming in, nothing may raise at all: the
-- file is editable by the player, written by two versions of the addon, and can be
-- cut off halfway by an interrupted logout. Loading always wins over preserving.

describe("the serialization boundary", function()
  local ns

  local function walk(value, path, visit)
    visit(value, path)
    if type(value) == "table" then
      for key, item in pairs(value) do
        walk(item, ("%s.%s"):format(path, tostring(key)), visit)
      end
    end
  end

  local function assertStorable(stored, label)
    walk(stored, label, function(value, path)
      assert.is_false(type(value) == "function", path .. " is a function")
      if type(value) == "table" then
        assert.is_nil(getmetatable(value), path .. " has a metatable")
      end
    end)
  end

  -- The property that matters is not that the stored form equals the original, but
  -- that it stops changing: whatever restore had to default or clamp, it defaults or
  -- clamps to the same thing next time. A format that drifted on every logout would
  -- be unmigratable.
  local function assertRoundTrips(model, live, label)
    local once = live:toStored()
    assertStorable(once, label)

    local restored = model.restore(once)
    assert.is_not_nil(restored, label .. " did not survive a round trip")

    assert.same(once, restored:toStored(), label .. " is not stable across a round trip")
    return restored
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/")
  end)

  describe("CreatureKey", function()
    it("round-trips a fully known creature", function()
      local key = ns.core.CreatureKey.new(5644, 6, "Kobold Miner")
      local restored = assertRoundTrips(ns.core.CreatureKey, key, "CreatureKey")

      assert.equal(5644, restored.npcId)
      assert.equal(6, restored.level)
      assert.equal("Kobold Miner", restored.name)
      assert.equal(key:id(), restored:id())
    end)

    -- An unknown half has to come back unknown. Defaulting it to zero would turn
    -- "nobody read this creature's level" into a creature of level zero, which is
    -- the exact invention this model exists to refuse.
    it("keeps an unknown half unknown", function()
      local restored = assertRoundTrips(
        ns.core.CreatureKey, ns.core.CreatureKey.unknown("Kobold Miner"), "unknown CreatureKey")

      assert.is_false(restored:hasKnownType())
      assert.is_false(restored:hasKnownLevel())
      assert.equal("?:?", restored:id())
    end)

    it("refuses something that was never a record", function()
      assert.is_nil(ns.core.CreatureKey.restore(nil))
      assert.is_nil(ns.core.CreatureKey.restore(7))
      assert.is_nil(ns.core.CreatureKey.restore({ npcId = 5644 }))
    end)

    -- Unknown is one of this model's real answers, so a record whose halves cannot
    -- be read is a creature nobody identified rather than a failure to read one.
    it("drops a field it cannot read rather than failing", function()
      local restored = ns.core.CreatureKey.restore("not a number,-3,Kobold Miner")

      assert.is_not_nil(restored)
      assert.is_false(restored:hasKnownType())
      assert.is_false(restored:hasKnownLevel())
      assert.equal("Kobold Miner", restored.name)
    end)
  end)

  describe("XpGain", function()
    local function gain(fields)
      fields.source = fields.source or ns.core.XpSource.MOB_KILL
      fields.at = fields.at or 100.5
      return ns.core.XpGain.new(fields)
    end

    it("round-trips a gain with every part filled in", function()
      local live = gain({
        amount = 100, restedBonus = 40, groupBonus = 8, raidPenalty = 3,
        creature = ns.core.CreatureKey.new(5644, 6, "Kobold Miner"),
      })
      local restored = assertRoundTrips(ns.core.XpGain, live, "XpGain")

      assert.equal(100, restored.amount)
      assert.equal(40, restored.restedBonus)
      assert.equal(60, restored:baseAmount())
      assert.equal(8, restored.groupBonus)
      assert.equal(3, restored.raidPenalty)
      assert.equal(100.5, restored.at)
      assert.equal("5644:6", restored.creature:id())
    end)

    -- D81: what a kill paid is only comparable to what another kill paid when both
    -- were split between the same number of people, so the size travels with the
    -- gain to disk and back. Written as its own field and read back as a number,
    -- not inferred from the group bonus, which says nothing about how many shared.
    it("round-trips the group a kill's experience was split between", function()
      local live = gain({
        amount = 100, sharedBy = 5,
        creature = ns.core.CreatureKey.new(5644, 6, "Kobold Miner"),
      })
      local restored = assertRoundTrips(ns.core.XpGain, live, "grouped gain")

      assert.equal(5, restored.sharedBy)
      assert.equal("5644:6", restored.creature:id())
    end)

    it("round-trips a kill measured alone as alone, not as unmeasured", function()
      local restored = assertRoundTrips(ns.core.XpGain, gain({ amount = 44, sharedBy = 1 }), "solo gain")

      assert.equal(1, restored.sharedBy)
    end)

    -- The half of D84 that has to hold at this boundary: every gain in every
    -- history written before this version has no such field, and what it means is
    -- that nobody counted -- not that the character was alone. Restoring it as one
    -- would invent an observation, and the averages built on it would be wrong in
    -- the direction hardest to notice, because most of it probably WAS solo.
    it("restores a gain written without a group size as unknown, never as alone", function()
      local restored = ns.core.XpGain.restore("44,mob_kill,100.5,,,,5644,6")

      assert.is_nil(restored.sharedBy)
      assert.equal(44, restored.amount)
      assert.equal("5644:6", restored.creature:id())
    end)

    -- The client's own answer out of a group, which the adapter is supposed to have
    -- translated. Arriving here it is not a population, so it restores as unknown
    -- rather than dividing an average by nobody -- and the live constructor raises
    -- on it, which is where that bug would be found.
    it("refuses a group of nobody, from disk and from a caller alike", function()
      assert.is_nil(ns.core.XpGain.restore("44,mob_kill,100.5,,,,,,,0").sharedBy)
      assert.has_error(function() return gain({ amount = 44, sharedBy = 0 }) end)
      assert.has_error(function() return gain({ amount = 44, sharedBy = 2.5 }) end)
    end)

    it("round-trips a quest gain", function()
      local restored = assertRoundTrips(ns.core.XpGain,
        gain({ amount = 250, source = ns.core.XpSource.QUEST_TURNIN, questId = 1234 }), "quest gain")

      assert.equal(1234, restored.questId)
      assert.is_nil(restored.creature)
    end)

    -- Individual gains are the highest-cardinality thing the addon saves, so the
    -- three modifiers that are almost always zero are not written at all.
    -- One line, nine fields in a fixed order, and the ones nobody filled in are not
    -- written at all. A gain is the thing there are tens of thousands of.
    it("writes a plain gain as a short line", function()
      assert.equal("44,mob_kill,100.5", gain({ amount = 44 }):toStored())
      assert.equal("250,quest_turnin,100.5,,,,,,1234",
        gain({ amount = 250, source = ns.core.XpSource.QUEST_TURNIN, questId = 1234 }):toStored())
      -- The group size is the tenth field and nothing else moved to make room for
      -- it, so a gain nobody counted still writes the same three fields it always
      -- did -- and a counted one pays for the blanks in between.
      assert.equal("44,mob_kill,100.5,,,,,,,3", gain({ amount = 44, sharedBy = 3 }):toStored())
    end)

    it("needs an amount and nothing else", function()
      assert.is_nil(ns.core.XpGain.restore(""))
      assert.is_nil(ns.core.XpGain.restore({ amount = 44 }))
      assert.is_nil(ns.core.XpGain.restore("-5,mob_kill,10"))
      assert.is_nil(ns.core.XpGain.restore("nonsense,mob_kill,10"))

      local restored = ns.core.XpGain.restore("44")
      assert.equal(44, restored.amount)
      assert.equal(ns.core.XpSource.UNKNOWN, restored.source)
      assert.equal(0, restored.at)
      assert.equal(0, restored.restedBonus)
    end)

    -- The live constructor raises on this, and raising on stored data is exactly
    -- what the boundary exists to prevent.
    it("clamps a rested bonus larger than the amount instead of raising", function()
      local restored = ns.core.XpGain.restore("44,mob_kill,10,500")

      assert.equal(44, restored.restedBonus)
      assert.equal(0, restored:baseAmount())
    end)

    -- A source some future version renamed must not reach a frozen table lookup,
    -- where reading an unknown key raises.
    it("falls back to UNKNOWN for a source this version does not know", function()
      assert.equal(ns.core.XpSource.UNKNOWN,
        ns.core.XpGain.restore("44,pet_battle,10").source)
    end)
  end)

  describe("AbilityUsage", function()
    it("round-trips a spell and an auto attack", function()
      local spell = ns.core.AbilityUsage.new(1234, "Sinister Strike")
      spell:record(17)
      local restored = assertRoundTrips(ns.core.AbilityUsage, spell, "AbilityUsage")
      assert.equal(17, restored.count)
      assert.is_false(restored:isAutoAttack())

      local swing = ns.core.AbilityUsage.new(ns.core.AbilityKey.MELEE_SWING)
      swing:record(200)
      local restoredSwing = assertRoundTrips(ns.core.AbilityUsage, swing, "melee AbilityUsage")
      assert.equal(200, restoredSwing.count)
      assert.is_true(restoredSwing:isAutoAttack())
    end)

    it("refuses a key that is neither a spell id nor a reserved one", function()
      assert.is_nil(ns.core.AbilityUsage.restore("auto_shot_v2,3"))
      assert.is_nil(ns.core.AbilityUsage.restore(",3"))
      assert.is_nil(ns.core.AbilityUsage.restore("0,3"))
      assert.is_nil(ns.core.AbilityUsage.restore({ key = 1234 }))
    end)

    it("defaults a missing count to zero", function()
      assert.equal(0, ns.core.AbilityUsage.restore("1234").count)
    end)
  end)

  describe("QuestForecast", function()
    it("round-trips a known reward and an unknown one", function()
      local known = ns.core.QuestForecast.new({
        questId = 1234, questLevel = 20, reward = 975,
        origin = ns.core.QuestXpOrigin.CLIENT, complete = true,
      })
      local restored = assertRoundTrips(ns.core.QuestForecast, known, "QuestForecast")
      assert.equal(975, restored.reward)
      assert.equal(ns.core.QuestXpOrigin.CLIENT, restored.origin)
      assert.is_true(restored:isReadyToTurnIn())

      local unknown = ns.core.QuestForecast.unknown(9876, 14)
      local restoredUnknown = assertRoundTrips(ns.core.QuestForecast, unknown, "unknown QuestForecast")
      assert.is_false(restoredUnknown:isKnown())
    end)

    -- The constructor refuses these combinations outright; stored data that claims
    -- one has to be read as the only thing it can honestly mean.
    it("reads stored data that disagrees with itself as unknown", function()
      local noOrigin = ns.core.QuestForecast.restore("1,,500")
      assert.equal(ns.core.QuestXpOrigin.UNKNOWN, noOrigin.origin)
      assert.is_false(noOrigin:isKnown())

      local noReward = ns.core.QuestForecast.restore("1,,,client")
      assert.is_false(noReward:isKnown())
    end)

    -- Zero and nil are different answers here and the round trip has to keep them so.
    it("keeps a reward of zero apart from no reward at all", function()
      local zero = ns.core.QuestForecast.restore("1,,0,client")

      assert.is_true(zero:isKnown())
      assert.equal(0, zero.reward)
    end)

    it("needs a quest id", function()
      assert.is_nil(ns.core.QuestForecast.restore(",,500,client"))
      assert.is_nil(ns.core.QuestForecast.restore({ questId = 1 }))
    end)
  end)

  describe("CombatSummary", function()
    it("round-trips its samples", function()
      local summary = ns.core.CombatSummary.new()
      summary:record(0.5, 0.25)
      summary:record(0.25, 0.75)
      local restored = assertRoundTrips(ns.core.CombatSummary, summary, "CombatSummary")

      assert.equal(2, restored.samples)
      assert.equal(0.375, restored:averageHealth())
      assert.equal(0.25, restored:worstHealth())
    end)

    it("comes back with nothing to average when it had no samples", function()
      local restored = assertRoundTrips(ns.core.CombatSummary, ns.core.CombatSummary.new(), "empty")

      assert.is_false(restored:hasSamples())
      assert.is_nil(restored:averageHealth())
    end)

    -- A worst case with no sample behind it is data disagreeing with itself, and
    -- reporting it over an empty average would be reporting a fight that never was.
    it("drops a worst case that has no samples behind it", function()
      local restored = ns.core.CombatSummary.restore({ samples = 0, worstHealth = 0.1 })

      assert.is_nil(restored:worstHealth())
    end)
  end)

  describe("LevelRecord", function()
    local function populated()
      local record = ns.core.LevelRecord.new(24, 1700000000)
      record.xpRequired = 8800
      record.playedSeconds = 1843.25
      record.sessions = 3
      record.partial = true
      record.timeAnchored = true
      record.metrics = { deaths = { count = 2, downtime = 61.5 } }

      local ledger = ns.core.XpLedger
      local chasm = ns.core.PlaceKey.new(ns.core.PlaceContext.DUNGEON, 389, "Ragefire Chasm")
      ledger.post(record, ns.core.XpGain.new({
        amount = 44, source = ns.core.XpSource.MOB_KILL, at = 10,
        restedBonus = 22, creature = ns.core.CreatureKey.new(5644, 6, "Kobold Miner"),
      }), nil, chasm)
      ledger.post(record, ns.core.XpGain.new({
        amount = 250, source = ns.core.XpSource.QUEST_TURNIN, at = 20, questId = 1234,
      }), nil, ns.core.PlaceKey.new(ns.core.PlaceContext.WORLD, 1429, "Elwynn Forest"))
      ledger.post(record, ns.core.XpGain.new({
        amount = 60, source = ns.core.XpSource.EXPLORATION, at = 30,
      }))
      record:placeEntry(chasm).seconds = 612.5
      -- A place that paid nothing at all: walked through, and that is the half of
      -- the story an experience-only breakdown cannot tell.
      record:placeEntry(ns.core.PlaceKey.new(ns.core.PlaceContext.WORLD, 1433, "Westfall")).seconds = 240.0

      record.killsWithXp = 41
      record.killsWithoutXp = 7

      local usage = ns.core.AbilityUsage.new(1234, "Sinister Strike")
      usage:record(9)
      record.abilities[usage.key] = usage

      return record
    end

    before_each(function()
      ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua")
    end)

    it("round-trips a record with something of everything in it", function()
      local restored = assertRoundTrips(ns.core.LevelRecord, populated(), "LevelRecord")

      assert.equal(24, restored.level)
      assert.equal(8800, restored.xpRequired)
      assert.equal(1843.25, restored.playedSeconds)
      assert.equal(3, restored.sessions)
      assert.is_true(restored.partial)
      assert.is_true(restored.timeAnchored)
      assert.equal(41, restored.killsWithXp)
      assert.equal(7, restored.killsWithoutXp)
      assert.equal(354, restored.xpTotal)
      assert.is_true(restored:sourcesAddUp())
      assert.equal(44, restored:xpFrom(ns.core.XpSource.MOB_KILL))
      assert.equal(250, restored:xpFrom(ns.core.XpSource.QUEST_TURNIN))
      assert.equal(22, restored:xpFromModifier(ns.core.XpModifier.RESTED_BONUS))
      assert.equal(3, #restored.gains)
      assert.equal(9, restored.abilities[1234].count)
      assert.equal(2, restored.metrics.deaths.count)
    end)

    it("round-trips the breakdown by place, time included", function()
      local restored = assertRoundTrips(ns.core.LevelRecord, populated(), "LevelRecord")

      assert.equal(44, restored.places["dungeon:389"].xpTotal)
      assert.equal(612.5, restored.places["dungeon:389"].seconds)
      assert.equal("Ragefire Chasm", restored.places["dungeon:389"].key.name)
      assert.equal(250, restored.places["world:1429"].xpTotal)
      assert.equal(60, restored.places["unknown:?"].xpTotal)
      assert.equal(restored:sumOfSources(), restored:sumOfPlaces())
    end)

    -- Both operands survive the file already, so the figure does too without a
    -- field of its own. What this pins is that it survives INTACT: derive it
    -- from anything that does not round-trip and a level would answer one thing
    -- in the session that recorded it and another after a reload.
    it("still knows what time it could not place after a trip through the file", function()
      local restored = assertRoundTrips(ns.core.LevelRecord, populated(), "LevelRecord")

      assert.equal(852.5, restored:sumOfPlaceSeconds())
      assert.equal(1843.25 - 852.5, restored:unaccountedSeconds())
      assert.is_false(restored:timeUnderflowed())
      assert.equal(restored.playedSeconds,
        restored:sumOfPlaceSeconds() + restored:unaccountedSeconds())
    end)

    -- A level from before places existed holds no entries at all, and that is
    -- the one state where the difference cannot be computed rather than being
    -- zero. Zero would have it claim it measured everything.
    it("declines to guess for a level written before places were tracked", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, xpTotal = 900, xpBySource = { mob_kill = 900 },
        playedSeconds = 1800, timeAnchored = true,
      })

      assert.is_false(restored:hasPlaces())
      assert.is_nil(restored:unaccountedSeconds())
    end)

    it("round-trips which source paid for each place's experience", function()
      local restored = assertRoundTrips(ns.core.LevelRecord, populated(), "LevelRecord")

      assert.equal(44, restored:xpAtFrom(
        ns.core.PlaceKey.new(ns.core.PlaceContext.DUNGEON, 389), ns.core.XpSource.MOB_KILL))
      assert.equal(250, restored:xpAtFrom(
        ns.core.PlaceKey.new(ns.core.PlaceContext.WORLD, 1429), ns.core.XpSource.QUEST_TURNIN))
      assert.is_true(restored:hasPlaceSources())
    end)

    -- The state the bar has to degrade for: places recorded, but by a build that
    -- did not yet keep which source paid for them. Empty is the answer, and it is
    -- not the same answer as a place that earned nothing.
    it("restores a place written before the breakdown was kept with an empty one", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, xpTotal = 900, xpBySource = { mob_kill = 900 },
        places = "900,120.0,world,1429,Elwynn Forest",
      })

      assert.equal(900, restored:xpAt(ns.core.PlaceKey.new(ns.core.PlaceContext.WORLD, 1429)))
      assert.same({}, restored.places["world:1429"].xpBySource)
      assert.is_false(restored:hasPlaceSources())
    end)

    it("drops a breakdown pair it cannot read without losing the place's total", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, places = "900,120.0,world,1429,Elwynn Forest,mob_kill,400,tourism,500",
      })

      assert.equal(900, restored.places["world:1429"].xpTotal)
      assert.same({ mob_kill = 400 }, restored.places["world:1429"].xpBySource)
    end)

    -- The pairs encoding was chosen over columns so a source added later costs no
    -- migration. It only buys that if an unreadable pair is stepped over: the
    -- pairs are written in the enumeration's sorted order, so a future source
    -- lands in the MIDDLE, and stopping at it would wipe everything behind it --
    -- and write the loss back to disk at the next logout.
    it("steps over a source it cannot read and keeps the pairs behind it", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, places = "900,120.0,world,1429,Elwynn,tourism,300,mob_kill,400,quest_turnin,200",
      })

      assert.same({ mob_kill = 400, quest_turnin = 200 }, restored.places["world:1429"].xpBySource)
      assert.is_true(restored:hasPlaceSources())
    end)

    -- PlaceKey.fromFields collapses every line it cannot fully read onto the one
    -- reserved entry, so two stored lines can arrive as the same place. Assigning
    -- instead of merging deleted the first one's experience without a word.
    it("merges two stored lines that collapse onto the same place", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, xpTotal = 1500, xpBySource = { mob_kill = 1500 },
        places = "1200,,scenario,2000,Some Place;300,60.0,unknown",
      })

      assert.equal(1500, restored:xpAt(ns.core.PlaceKey.unknown()))
      assert.equal(60, restored.places["unknown:?"].seconds)
      assert.equal(1500, restored:sumOfPlaces())
    end)

    -- Experience zero is a real entry, not an empty one: it says the player was
    -- there and got nothing for it.
    it("keeps a place that only ever cost time", function()
      local restored = assertRoundTrips(ns.core.LevelRecord, populated(), "LevelRecord")

      assert.equal(0, restored.places["world:1433"].xpTotal)
      assert.equal(240.0, restored.places["world:1433"].seconds)
      assert.same({}, restored.places["world:1433"].xpBySource)
    end)

    -- The migration plan, in one test. A level recorded before places existed did
    -- not fail to observe where its experience came from; it never tried, and an
    -- unknown entry would claim otherwise.
    it("restores a record saved without places with no places at all", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, xpTotal = 1000, xpBySource = { mob_kill = 1000 },
      })

      assert.same({}, restored.places)
      assert.is_false(restored:hasPlaces())
      assert.equal(0, restored:xpAt(ns.core.PlaceKey.unknown()))
      assert.is_true(restored:sourcesAddUp())
    end)

    it("skips a place entry with neither experience nor time in it", function()
      local restored = ns.core.LevelRecord.restore({ level = 24, places = ",,world,1429,Elwynn Forest" })

      assert.same({}, restored.places)
    end)

    -- The maps come back keyed the way the live model keys them, not as the
    -- sequences the file holds.
    it("comes back with its collections keyed again", function()
      local restored = assertRoundTrips(ns.core.LevelRecord, populated(), "LevelRecord")

      assert.equal(1, restored.creatures["5644:6@?"].kills)
      assert.equal(44, restored.creatures["5644:6@?"].xpTotal)
      assert.equal("Kobold Miner", restored.creatures["5644:6@?"].key.name)
      assert.equal(250, restored.quests[1234].xpTotal)
      assert.equal(1, restored.quests[1234].turnIns)
    end)

    -- The line, spelled out: kills, experience, the group the kill was paid to,
    -- and then the creature's own three fields. The group sits AHEAD of the key
    -- because the key is the line's tail and a tail has no fixed position -- an
    -- unidentified creature ends the line two fields in. Blank in that third
    -- field is the context nobody counted, which is exactly what tells a level
    -- recorded before this distinction from one played alone.
    it("writes the group a creature was killed in ahead of the creature", function()
      local record = ns.core.LevelRecord.new(24, 0)
      record.xpRequired = 8800
      local lynx = ns.core.CreatureKey.new(15343, 6, "Springpaw Lynx")
      local function kill(amount, sharedBy)
        ns.core.XpLedger.post(record, ns.core.XpGain.new({
          amount = amount, source = ns.core.XpSource.MOB_KILL, at = 10,
          creature = lynx, sharedBy = sharedBy,
        }))
      end

      kill(40, 5)
      kill(44, 5)
      kill(84)

      assert.equal(
        "1,84,,15343,6,Springpaw Lynx;2,84,5,15343,6,Springpaw Lynx",
        record:toStored().creatures)
    end)

    -- The first of the three nets the schema step needs: version 4 rewrites every
    -- stored creature line into this shape, so a shape that did not survive its own
    -- write and read would convert a character's history into something the next
    -- login cannot use -- and there is no going back from a conversion.
    it("carries both of a creature's contexts through a round trip", function()
      local record = ns.core.LevelRecord.new(24, 0)
      record.xpRequired = 8800
      local lynx = ns.core.CreatureKey.new(15343, 6, "Springpaw Lynx")
      local function kill(amount, sharedBy)
        ns.core.XpLedger.post(record, ns.core.XpGain.new({
          amount = amount, source = ns.core.XpSource.MOB_KILL, at = 10,
          creature = lynx, sharedBy = sharedBy,
        }))
      end

      kill(40, 5)
      kill(84)

      local restored = assertRoundTrips(ns.core.LevelRecord, record, "grouped creatures")

      assert.equal(5, restored.creatures["15343:6@5"].sharedBy)
      assert.equal(40, restored.creatures["15343:6@5"].xpTotal)
      assert.equal("Springpaw Lynx", restored.creatures["15343:6@5"].key.name)
      assert.is_nil(restored.creatures["15343:6@?"].sharedBy)
      assert.equal(84, restored.creatures["15343:6@?"].xpTotal)
    end)

    -- Two lines for one creature is the whole point, and restore ASSIGNS each
    -- bucket into the map: read under a key that left the group out, the second
    -- line would silently delete the first one's kills and experience.
    it("brings a creature's two contexts back as two aggregates", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24,
        creatures = "1,84,,15343,6,Springpaw Lynx;2,84,5,15343,6,Springpaw Lynx",
      })

      local uncounted = restored.creatures["15343:6@?"]
      local party = restored.creatures["15343:6@5"]

      assert.equal(1, uncounted.kills)
      assert.equal(84, uncounted.xpTotal)
      assert.is_nil(uncounted.sharedBy)
      assert.equal(2, party.kills)
      assert.equal(84, party.xpTotal)
      assert.equal(5, party.sharedBy)
      assert.equal("Springpaw Lynx", party.key.name)
    end)

    it("needs a level and nothing else", function()
      assert.is_nil(ns.core.LevelRecord.restore(nil))
      assert.is_nil(ns.core.LevelRecord.restore({}))
      assert.is_nil(ns.core.LevelRecord.restore({ level = 0 }))
      assert.is_nil(ns.core.LevelRecord.restore("level 24"))
    end)

    -- Adding a field in a future version must not need a migration, only a default.
    it("defaults every field a stored record is missing", function()
      local restored = ns.core.LevelRecord.restore({ level = 24 })

      assert.equal(24, restored.level)
      assert.equal(0, restored.startedAt)
      assert.is_nil(restored.completedAt)
      assert.equal(0, restored.playedSeconds)
      assert.equal(1, restored.sessions)
      assert.equal(0, restored.xpTotal)
      assert.is_nil(restored.xpRequired)
      assert.is_false(restored.partial)
      assert.is_false(restored.timeAnchored)
      assert.same({}, restored.gains)
      assert.same({}, restored.creatures)
      assert.same({}, restored.places)
      assert.same({}, restored.metrics)
      assert.is_true(restored:sourcesAddUp())
      for _, source in ns.core.Frozen.each(ns.core.XpSource) do
        assert.equal(0, restored:xpFrom(source))
      end
    end)

    -- The guarantee the addon exists to make, restated on the way in. The file is
    -- editable and a logout can be cut off halfway, so the sum and the total can
    -- arrive disagreeing; the difference goes where every unexplained gain goes.
    it("absorbs a total larger than its breakdown into unclassified", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, xpTotal = 1000, xpBySource = { mob_kill = 400 },
      })

      assert.equal(1000, restored.xpTotal)
      assert.equal(600, restored:xpFrom(ns.core.XpSource.UNKNOWN))
      assert.is_true(restored:sourcesAddUp())
    end)

    it("lets the breakdown win when it claims more than the total", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, xpTotal = 100, xpBySource = { mob_kill = 400, quest_turnin = 250 },
      })

      assert.equal(650, restored.xpTotal)
      assert.equal(0, restored:xpFrom(ns.core.XpSource.UNKNOWN))
      assert.is_true(restored:sourcesAddUp())
    end)

    it("skips a gain it cannot read instead of losing the level", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24,
        gains = "44,mob_kill,10;nonsense;,mob_kill,10;60,exploration,20",
      })

      assert.equal(2, #restored.gains)
      assert.equal(44, restored.gains[1].amount)
      assert.equal(60, restored.gains[2].amount)
    end)

    -- The order of the gains is the level's time series, so it is the one collection
    -- that is written in the order it is in rather than sorted.
    it("keeps the gains in the order they happened", function()
      local record = ns.core.LevelRecord.new(24, 0)
      for index = 1, 5 do
        ns.core.XpLedger.post(record, ns.core.XpGain.new({
          amount = index * 10, source = ns.core.XpSource.MOB_KILL, at = index,
        }))
      end

      local restored = ns.core.LevelRecord.restore(record:toStored())

      for index = 1, 5 do
        assert.equal(index * 10, restored.gains[index].amount)
      end
    end)

    -- Written from a map, so without a sort the same unchanged record would produce
    -- a different file at every logout.
    it("writes its keyed collections in a stable order", function()
      local record = ns.core.LevelRecord.new(24, 0)
      for index = 1, 12 do
        ns.core.XpLedger.post(record, ns.core.XpGain.new({
          amount = 10, source = ns.core.XpSource.MOB_KILL, at = index,
          creature = ns.core.CreatureKey.new(5000 + index, 6, "Kobold Miner"),
        }))
      end

      local once = record:toStored()
      for _ = 1, 5 do
        assert.equal(once.creatures, ns.core.LevelRecord.restore(once):toStored().creatures)
      end
    end)

    -- A collector that put a live object into the metrics table under any key OTHER
    -- than COMBAT_OUTCOME is the addon's own bug: the file would drop it in silence
    -- and hand back half a record next login. COMBAT_OUTCOME is the one legitimate
    -- exception (D23, packMetrics) -- covered separately below.
    it("refuses to store a metric that is not plain data", function()
      local record = ns.core.LevelRecord.new(24, 0)
      record.metrics = { combat = ns.core.CombatSummary.new() }

      assert.has_error(function() return record:toStored() end)
    end)

    -- The one key of metrics that is a live object on the way in (D23, D20): it
    -- gets its own toStored()/restore() at the boundary instead of tripping the
    -- guard above.
    it("round-trips a real CombatSummary under COMBAT_OUTCOME without raising", function()
      local record = ns.core.LevelRecord.new(24, 0)
      local summary = ns.core.CombatSummary.new()
      summary:record(0.8, 0.6)
      summary:record(0.2, 0.3)
      record.metrics[ns.core.MetricId.COMBAT_OUTCOME] = summary

      local restored
      assert.has_no.errors(function()
        restored = ns.core.LevelRecord.restore(record:toStored())
      end)

      local restoredSummary = restored.metrics[ns.core.MetricId.COMBAT_OUTCOME]
      assert.equal(2, restoredSummary.samples)
      assert.near(0.5, restoredSummary:averageHealth(), 1e-9)
      assert.equal(0.2, restoredSummary:worstHealth())
    end)

    it("drops a metric that came back from disk as something it cannot be", function()
      local restored = ns.core.LevelRecord.restore({
        level = 24, metrics = { deaths = { count = 2 }, broken = print },
      })

      assert.equal(2, restored.metrics.deaths.count)
      assert.is_nil(restored.metrics.broken)
    end)
  end)
end)
