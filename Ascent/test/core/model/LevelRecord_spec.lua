describe("LevelRecord", function()
  local ns, LevelRecord, XpSource, XpModifier

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua")
    LevelRecord = ns.core.LevelRecord
    XpSource = ns.core.XpSource
    XpModifier = ns.core.XpModifier
  end)

  describe("a new record", function()
    local record

    before_each(function()
      record = LevelRecord.new(24, 1000)
    end)

    it("knows its level and when it started", function()
      assert.equal(24, record.level)
      assert.equal(1000, record.startedAt)
      assert.is_nil(record.completedAt)
      assert.is_false(record:isComplete())
    end)

    it("starts every experience accumulator at zero", function()
      assert.equal(0, record.xpTotal)
      for _, source in ipairs(ns.core.Frozen.keys(XpSource)) do
        assert.equal(0, record:xpFrom(XpSource[source]), source .. " did not start at zero")
      end
      for _, modifier in ipairs(ns.core.Frozen.keys(XpModifier)) do
        assert.equal(0, record:xpFromModifier(XpModifier[modifier]))
      end
    end)

    it("starts every count and clock at zero", function()
      assert.equal(0, record.playedSeconds)
      assert.equal(0, record.killsWithXp)
      assert.equal(0, record.killsWithoutXp)
      assert.equal(0, record:totalKills())
      assert.same({}, record.creatures)
      assert.same({}, record.abilities)
      assert.same({}, record.quests)
      assert.same({}, record.metrics)
      assert.same({}, record.gains)
    end)

    it("counts as one sitting, not zero", function()
      assert.equal(1, record.sessions)
    end)

    it("carries no marks", function()
      assert.is_false(record.partial)
      assert.is_false(record.timeAnchored)
    end)

    it("does not pretend to know how much experience the level needs", function()
      assert.is_nil(record.xpRequired)
    end)

    it("trivially satisfies the invariant that sources add up", function()
      assert.equal(0, record:sumOfSources())
      assert.is_true(record:sourcesAddUp())
    end)
  end)

  describe("the invariant", function()
    it("holds when the sources account for the total", function()
      local record = LevelRecord.new(24, 1000)

      record.xpBySource[XpSource.QUEST_TURNIN] = 700
      record.xpBySource[XpSource.MOB_KILL] = 300
      record.xpTotal = 1000

      assert.equal(1000, record:sumOfSources())
      assert.is_true(record:sourcesAddUp())
    end)

    it("fails loudly when experience went missing", function()
      local record = LevelRecord.new(24, 1000)

      record.xpTotal = 1000
      record.xpBySource[XpSource.QUEST_TURNIN] = 700 -- the other 300 vanished

      assert.is_false(record:sourcesAddUp())
    end)
  end)

  describe("reset", function()
    it("clears a used record completely", function()
      local record = LevelRecord.new(24, 1000)
      record.xpTotal = 5000
      record.xpBySource[XpSource.MOB_KILL] = 5000
      record.playedSeconds = 3600
      record.sessions = 4
      record.killsWithXp = 120
      record.partial = true
      record.timeAnchored = true
      record.completedAt = 4600
      record.gains = { "something" }

      record:reset(25, 4600)

      assert.equal(25, record.level)
      assert.equal(4600, record.startedAt)
      assert.is_nil(record.completedAt)
      assert.equal(0, record.xpTotal)
      assert.equal(0, record:xpFrom(XpSource.MOB_KILL))
      assert.equal(0, record.playedSeconds)
      assert.equal(1, record.sessions)
      assert.equal(0, record.killsWithXp)
      assert.is_false(record.partial)
      assert.is_false(record.timeAnchored)
      assert.same({}, record.gains)
    end)

    it("does not share accumulators between records", function()
      local first = LevelRecord.new(24, 1000)
      local second = LevelRecord.new(25, 2000)

      first.xpBySource[XpSource.MOB_KILL] = 999

      assert.equal(0, second:xpFrom(XpSource.MOB_KILL))
    end)
  end)

  describe("construction", function()
    it("refuses a level that is not a positive integer", function()
      assert.has_error(function() return LevelRecord.new(0, 1000) end)
      assert.has_error(function() return LevelRecord.new(-1, 1000) end)
      assert.has_error(function() return LevelRecord.new(24.5, 1000) end)
      assert.has_error(function() return LevelRecord.new("24", 1000) end)
      assert.has_error(function() return LevelRecord.new(nil, 1000) end)
    end)

    it("refuses a start time that is not a timestamp", function()
      assert.has_error(function() return LevelRecord.new(24, nil) end)
      assert.has_error(function() return LevelRecord.new(24, "now") end)
    end)
  end)

  -- 6.7: derived rather than accumulated, so there is nothing for a collector to
  -- keep in sync -- see CombatTimeCollector's header for why out-of-combat time in
  -- particular is derived here instead of tracked by a third counter.
  describe("combat efficiency (6.7)", function()
    local record

    before_each(function()
      record = LevelRecord.new(24, 0)
    end)

    it("is unavailable for a level with no combat time at all", function()
      record.xpTotal = 500
      assert.is_nil(record:xpPerCombatMinute())
    end)

    it("divides the level's total xp by minutes of combat time", function()
      record.xpTotal = 300
      record.metrics[ns.core.MetricId.TIME] = { combatSeconds = 120, recoverySeconds = 0 }

      assert.equal(150, record:xpPerCombatMinute())
    end)

    it("is unavailable with no productive kills, even with xp from other sources", function()
      assert.is_nil(record:averageXpPerKill())
    end)

    it("averages mob-kill xp specifically over kills that paid something", function()
      ns.core.XpLedger.post(record, ns.core.XpGain.new({ amount = 40, source = XpSource.MOB_KILL, at = 1 }))
      ns.core.XpLedger.post(record, ns.core.XpGain.new({ amount = 60, source = XpSource.MOB_KILL, at = 2 }))
      ns.core.XpLedger.post(record, ns.core.XpGain.new({ amount = 250, source = XpSource.QUEST_TURNIN, at = 3 }))
      record.killsWithXp = 2
      record.killsWithoutXp = 5 -- must not dilute the average

      assert.equal(50, record:averageXpPerKill())
    end)

    it("derives out-of-combat time as played time minus combat time", function()
      record.playedSeconds = 100
      record.metrics[ns.core.MetricId.TIME] = { combatSeconds = 35, recoverySeconds = 0 }

      assert.equal(65, record:outOfCombatSeconds())
    end)

    it("is zero for combat/recovery/death time on a level nothing has happened on", function()
      assert.equal(0, record:combatSeconds())
      assert.equal(0, record:recoverySeconds())
      assert.equal(0, record:deathCount())
      assert.equal(0, record:timeLostToDeath())
      assert.equal(0, record:outOfCombatSeconds())
    end)
  end)

  -- Two numbers that look like one. `sumOfPlaces` is ledger arithmetic and counts
  -- the reserved entry, because that is what keeps the place dimension equal to
  -- the source dimension. `placedXp` is what a reader means by "placed", and the
  -- diagnostic that printed the first while labelling it the second could
  -- contradict itself in the same breath.
  describe("placed experience versus the ledger's total", function()
    local PlaceKey, PlaceContext

    local function seed(record, key, amount, seconds)
      local entry = record:placeEntry(key)
      entry.xpTotal = entry.xpTotal + (amount or 0)
      entry.seconds = entry.seconds + (seconds or 0)
      if amount ~= nil and amount > 0 then
        entry.xpBySource[XpSource.MOB_KILL] = (entry.xpBySource[XpSource.MOB_KILL] or 0) + amount
      end
      return entry
    end

    before_each(function()
      PlaceKey, PlaceContext = ns.core.PlaceKey, ns.core.PlaceContext
    end)

    -- The experience dimension balances because what cannot be attributed goes
    -- somewhere explicit. Time had no such somewhere, so a level could measure
    -- less than it played and say nothing at all about the difference (D78).
    describe("the time it could not place", function()
      local function played(record, seconds)
        record.playedSeconds = seconds
        record.timeAnchored = true
        return record
      end

      it("names the difference between the time played and the time measured", function()
        local record = played(ns.core.LevelRecord.new(5, 0), 9304)
        seed(record, PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"), 900, 8000)
        seed(record, PlaceKey.new(PlaceContext.DUNGEON, 1581, "The Deadmines"), 100, 931)

        assert.equal(8931, record:sumOfPlaceSeconds())
        assert.equal(373, record:unaccountedSeconds())
      end)

      -- The invariant the figure exists to make writable. Its counterpart on the
      -- experience side has been assertable since the beginning; this one could
      -- not even be stated before.
      it("adds up: the places plus what they could not account for is the time played", function()
        local record = played(ns.core.LevelRecord.new(5, 0), 9304)
        seed(record, PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"), 900, 8000)
        seed(record, PlaceKey.new(PlaceContext.DUNGEON, 1581, "The Deadmines"), 100, 931)

        assert.equal(record.playedSeconds, record:sumOfPlaceSeconds() + record:unaccountedSeconds())
      end)

      it("answers zero when every second of the level was measured", function()
        local record = played(ns.core.LevelRecord.new(5, 0), 8000)
        seed(record, PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"), 900, 8000)

        assert.equal(0, record:unaccountedSeconds())
        assert.is_false(record:timeUnderflowed())
      end)

      -- Zero would be a claim this level cannot make: it never heard the
      -- server's figure, so it does not know whether it measured everything.
      it("answers nothing at all when the level was never anchored against the server", function()
        local record = ns.core.LevelRecord.new(5, 0)
        seed(record, PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"), 900, 8000)

        assert.is_nil(record:unaccountedSeconds())
      end)

      it("answers nothing for a level written before places were tracked", function()
        local record = played(ns.core.LevelRecord.new(5, 0), 9304)

        assert.is_false(record:hasPlaces())
        assert.is_nil(record:unaccountedSeconds())
      end)

      -- A negative difference is not less time, it is a broken anchor: the
      -- server's figure arrived after seconds had already been booked against
      -- places. Floored, and flagged, rather than shown as if it were time.
      it("floors at zero and says so when the anchor landed late", function()
        local record = played(ns.core.LevelRecord.new(5, 0), 500)
        seed(record, PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"), 900, 8000)

        assert.equal(0, record:unaccountedSeconds())
        assert.is_true(record:timeUnderflowed())
      end)
    end)

    it("leaves the reserved entry out of what was placed", function()
      local record = ns.core.LevelRecord.new(5, 0)
      seed(record, PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"), 900)
      seed(record, PlaceKey.unknown(), 100)

      assert.equal(1000, record:sumOfPlaces())
      assert.equal(900, record:placedXp())
    end)

    it("answers zero when everything landed in the reserved entry", function()
      local record = ns.core.LevelRecord.new(5, 0)
      seed(record, PlaceKey.unknown(), 400)

      assert.equal(400, record:sumOfPlaces())
      assert.equal(0, record:placedXp())
    end)

    it("answers zero for a record that has no places at all", function()
      local record = ns.core.LevelRecord.new(5, 0)

      assert.is_false(record:hasPlaces())
      assert.equal(0, record:placedXp())
    end)

    -- The shape a place that only cost time takes: an entry, no experience.
    it("is not moved by an entry that paid nothing", function()
      local record = ns.core.LevelRecord.new(5, 0)
      seed(record, PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"), 900)
      seed(record, PlaceKey.new(PlaceContext.WORLD, 1433, "Westfall"), 0, 300)

      assert.is_true(record:hasPlaces())
      assert.equal(900, record:placedXp())
      assert.equal(900, record:sumOfPlaces())
    end)
  end)

  -- The seed figure survives the file, and the three states stay three. Round trip
  -- rather than a field check, because the whole point of the field is that it has
  -- to come back from disk meaning what it meant.
  describe("the seeded portion across the file", function()
    local function roundTrip(record)
      return LevelRecord.restore(record:toStored())
    end

    it("carries the amount that was seeded", function()
      local record = LevelRecord.new(35, 1700000000)
      record.partial = true
      record.seededXp = 8632

      assert.equal(8632, roundTrip(record).seededXp)
    end)

    it("keeps a seed of zero distinct from no seed at all", function()
      local seeded = LevelRecord.new(35, 1700000000)
      seeded.partial = true
      seeded.seededXp = 0

      assert.equal(0, roundTrip(seeded).seededXp)
      assert.is_nil(roundTrip(LevelRecord.new(35, 1700000000)).seededXp)
    end)

    -- A record written before the field existed. It restores nil rather than zero
    -- because it genuinely cannot say: zero would claim every unclassified point in
    -- it was watched and left unattributed, which is the opposite of true for a
    -- level the addon joined halfway.
    it("restores nil from a record written before the field existed", function()
      local stored = LevelRecord.new(35, 1700000000):toStored()
      stored.partial = true
      stored.seededXp = nil

      local restored = LevelRecord.restore(stored)
      assert.is_true(restored.partial)
      assert.is_nil(restored.seededXp)
    end)

    it("refuses a stored value that is not a count", function()
      for _, bad in ipairs({ "8632", -1, 1.5, {} }) do
        local stored = LevelRecord.new(35, 1700000000):toStored()
        stored.seededXp = bad
        assert.is_nil(LevelRecord.restore(stored).seededXp)
      end
    end)
  end)
end)
