-- The segments add up to exactly the level's own percentage, and what is only a
-- projection (the rested reserve, the pending quest experience) stays visibly
-- apart from that sum rather than padding it.

describe("XpBarViewModel", function()
  local ns, XpBarViewModel, XpLedger, LevelRecord, XpGain, XpSource

  local function level(number, required)
    local record = LevelRecord.new(number, 0)
    record.xpRequired = required
    return record
  end

  local function gain(amount, source)
    return XpGain.new({ amount = amount, source = source or XpSource.MOB_KILL, at = 100 })
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua", "core/service/XpBarViewModel.lua")
    XpBarViewModel = ns.core.XpBarViewModel
    XpLedger = ns.core.XpLedger
    LevelRecord = ns.core.LevelRecord
    XpGain = ns.core.XpGain
    XpSource = ns.core.XpSource
  end)

  describe("segments", function()
    it("gives a level with several sources one segment per source, summing to the level's percent", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(300, XpSource.MOB_KILL))
      XpLedger.post(record, gain(200, XpSource.QUEST_TURNIN))
      XpLedger.post(record, gain(100, XpSource.EXPLORATION))

      local viewModel = XpBarViewModel.build(record)

      assert.is_true(viewModel.active)
      assert.equal(3, #viewModel.segments)
      -- XpSource's own order: MOB_KILL, QUEST_TURNIN, EXPLORATION, UNKNOWN.
      assert.equal(XpSource.MOB_KILL, viewModel.segments[1].source)
      assert.equal(XpSource.QUEST_TURNIN, viewModel.segments[2].source)
      assert.equal(XpSource.EXPLORATION, viewModel.segments[3].source)

      local sum = 0
      for _, segment in ipairs(viewModel.segments) do
        sum = sum + segment.fraction
      end
      assert.near(viewModel.percentComplete, sum, 1e-9)
      assert.near(0.6, viewModel.percentComplete, 1e-9)
    end)

    it("gives a level with a single source one segment covering the whole percent", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(400, XpSource.MOB_KILL))

      local viewModel = XpBarViewModel.build(record)

      assert.equal(1, #viewModel.segments)
      assert.near(viewModel.percentComplete, viewModel.segments[1].fraction, 1e-9)
    end)

    it("shows an empty bar for a level that just started, without erroring", function()
      local record = level(10, 1000)

      local viewModel = XpBarViewModel.build(record)

      assert.is_true(viewModel.active)
      assert.equal(0, #viewModel.segments)
      assert.equal(0, viewModel.percentComplete)
    end)

    it("never turns a source sitting at zero into a segment", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(300, XpSource.MOB_KILL))
      XpLedger.post(record, gain(200, XpSource.QUEST_TURNIN))
      -- EXPLORATION is left untouched: it must not appear below.

      local viewModel = XpBarViewModel.build(record)

      assert.equal(2, #viewModel.segments)
      for _, segment in ipairs(viewModel.segments) do
        assert.is_not.equal(XpSource.EXPLORATION, segment.source)
      end
    end)
  end)

  -- What the client has confirmed but XpAttribution has not yet settled into a
  -- source. The bar folds it into UNKNOWN as provisional so the total and the
  -- percent move immediately instead of lagging behind the settling window.
  describe("unattributedXp, the experience still waiting for its source", function()
    it("is folded into the UNKNOWN segment and into the completed percent", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(300, XpSource.MOB_KILL))

      local viewModel = XpBarViewModel.build(record, { unattributedXp = 50 })

      assert.near(0.35, viewModel.percentComplete, 1e-9) -- (300 + 50) / 1000
      assert.equal(350, viewModel.xpTotal)

      local unknown
      for _, segment in ipairs(viewModel.segments) do
        if segment.source == XpSource.UNKNOWN then
          unknown = segment
        end
      end
      assert.is_not_nil(unknown)
      assert.equal(50, unknown.amount)
      assert.near(0.05, unknown.fraction, 1e-9)
    end)

    it("still sums the segments to exactly the completed percent with something pending", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(300, XpSource.MOB_KILL))
      XpLedger.post(record, gain(200, XpSource.QUEST_TURNIN))

      local viewModel = XpBarViewModel.build(record, { unattributedXp = 40 })

      local sum = 0
      for _, segment in ipairs(viewModel.segments) do
        sum = sum + segment.fraction
      end
      assert.near(viewModel.percentComplete, sum, 1e-9)
    end)

    it("caps at the room actually left in the level instead of pushing past 100%", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(950, XpSource.MOB_KILL))

      -- More than the 50 xp actually left in the level -- a delta that will turn
      -- out to cross into the next level once it settles for real.
      local viewModel = XpBarViewModel.build(record, { unattributedXp = 200 })

      assert.near(1.0, viewModel.percentComplete, 1e-9)
      assert.equal(1000, viewModel.xpTotal)
    end)

    it("defaults to zero when the caller does not pass it", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(300, XpSource.MOB_KILL))

      local viewModel = XpBarViewModel.build(record)

      assert.near(0.3, viewModel.percentComplete, 1e-9)
      assert.equal(300, viewModel.xpTotal)
    end)
  end)

  describe("inactive states", function()
    it("has nothing to show with no record at all", function()
      assert.same({ active = false }, XpBarViewModel.build(nil))
    end)

    it("has nothing to show while the level's requirement is still unknown", function()
      local record = LevelRecord.new(10, 0)
      assert.is_nil(record.xpRequired)

      assert.same({ active = false }, XpBarViewModel.build(record))
    end)
  end)

  describe("the rested reserve", function()
    it("reports the reserve as its own fraction", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(400))

      local viewModel = XpBarViewModel.build(record, { restedXp = 200 })

      assert.near(0.2, viewModel.rested.fraction, 1e-9)
    end)

    it("caps the reserve so progress plus rest never pushes past the end of the bar", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(900)) -- 90% done, only 10% of room left

      local viewModel = XpBarViewModel.build(record, { restedXp = 500 }) -- would be 50%

      assert.near(0.1, viewModel.rested.fraction, 1e-9)
      assert.is_true(viewModel.percentComplete + viewModel.rested.fraction <= 1 + 1e-9)
    end)

    it("shows no reserve without a positive one", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(400))

      assert.is_nil(XpBarViewModel.build(record, {}).rested)
      assert.is_nil(XpBarViewModel.build(record, { restedXp = 0 }).rested)
    end)
  end)

  describe("pending quest experience", function()
    it("reports pending in its own channel, and never as a segment", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(400, XpSource.MOB_KILL))

      local viewModel = XpBarViewModel.build(record, { questPending = 300 })

      assert.near(0.3, viewModel.pending.fraction, 1e-9)
      assert.is_false(viewModel.pending.saturated)

      assert.equal(1, #viewModel.segments)
      assert.near(0.4, viewModel.segments[1].fraction, 1e-9)
    end)

    it("saturates at the end of the bar when pending overshoots what's left", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(900, XpSource.MOB_KILL))

      local viewModel = XpBarViewModel.build(record, { questPending = 300 })

      assert.is_true(viewModel.pending.saturated)
      assert.near(0.1, viewModel.pending.fraction, 1e-9)
    end)

    it("shows no pending channel without a known amount", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(400))

      assert.is_nil(XpBarViewModel.build(record, {}).pending)
    end)

    it("shows no pending channel when the player disabled it", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(400))

      local viewModel = XpBarViewModel.build(record, { questPending = 300, showQuestPending = false })

      assert.is_nil(viewModel.pending)
    end)
  end)
  -- The crossed reading: the popup can answer "which part of this source came
  -- from where", and asking it changes nothing at all about the bar.
  describe("where each source was earned", function()
    local PlaceKey, PlaceContext

    before_each(function()
      PlaceKey = ns.core.PlaceKey
      PlaceContext = ns.core.PlaceContext
    end)

    local function place(context, areaId, name)
      return PlaceKey.new(context, areaId, name)
    end

    local function levelEarnedInTwoPlaces()
      local record = level(10, 1000)
      local chasm = place(PlaceContext.DUNGEON, 389, "Ragefire Chasm")
      local forest = place(PlaceContext.WORLD, 1429, "Elwynn Forest")

      XpLedger.post(record, gain(300), nil, chasm)
      XpLedger.post(record, gain(100), nil, forest)
      XpLedger.post(record, gain(200, XpSource.QUEST_TURNIN), nil, forest)
      return record
    end

    local function segmentFor(viewModel, source)
      for _, segment in ipairs(viewModel.segments) do
        if segment.source == source then
          return segment
        end
      end
      return nil
    end

    it("splits a source across the places its experience came from", function()
      local kills = XpBarViewModel.placesFor(levelEarnedInTwoPlaces(), XpSource.MOB_KILL)

      assert.equal(2, #kills)
      assert.equal("dungeon:389", kills[1].place:id())
      assert.equal(300, kills[1].amount)
      assert.equal("world:1429", kills[2].place:id())
      assert.equal(100, kills[2].amount)
    end)

    -- The popup's own block lists the places of the level, not of a source, so
    -- one zone does not print once per source.
    it("lists the level's places once each, whatever mix of sources paid for them", function()
      local places = XpBarViewModel.placesOf(levelEarnedInTwoPlaces())

      assert.equal(2, #places)
      -- Both paid 300, so the tie breaks on the place's own id, exactly as
      -- placesFor breaks it: two reads of one record give the same popup.
      assert.equal("dungeon:389", places[1].place:id())
      assert.equal(300, places[1].amount)
      assert.equal("world:1429", places[2].place:id())
      assert.equal(300, places[2].amount) -- 100 from kills and 200 from a quest, in one line
    end)

    it("leaves out a place that paid nothing, and answers nil when none paid", function()
      local record = levelEarnedInTwoPlaces()
      record:placeEntry(place(PlaceContext.WORLD, 1433, "Westfall")).seconds = 300

      for _, entry in ipairs(XpBarViewModel.placesOf(record)) do
        assert.is_true(entry.place:id() ~= "world:1433")
      end

      local walked = level(10, 1000)
      walked:placeEntry(place(PlaceContext.WORLD, 1433, "Westfall")).seconds = 300
      assert.is_nil(XpBarViewModel.placesOf(walked))
      assert.is_nil(XpBarViewModel.placesOf(level(10, 1000)))
    end)

    it("gives each source only its own places", function()
      local quests = XpBarViewModel.placesFor(levelEarnedInTwoPlaces(), XpSource.QUEST_TURNIN)

      assert.equal(1, #quests)
      assert.equal("world:1429", quests[1].place:id())
      assert.equal(200, quests[1].amount)
    end)

    it("adds each source's places up to that source's own recorded total", function()
      local record = levelEarnedInTwoPlaces()

      local sum = 0
      for _, entry in ipairs(XpBarViewModel.placesFor(record, XpSource.MOB_KILL)) do
        sum = sum + entry.amount
      end

      assert.equal(record:xpFrom(XpSource.MOB_KILL), sum)
    end)

    it("orders the places of a source biggest first, then by the place's own id", function()
      local record = level(10, 5000)
      XpLedger.post(record, gain(100), nil, place(PlaceContext.WORLD, 2))
      XpLedger.post(record, gain(100), nil, place(PlaceContext.WORLD, 1))
      XpLedger.post(record, gain(500), nil, place(PlaceContext.WORLD, 3))

      local ids = {}
      for index, entry in ipairs(XpBarViewModel.placesFor(record, XpSource.MOB_KILL)) do
        ids[index] = entry.place:id()
      end

      assert.same({ "world:3", "world:1", "world:2" }, ids)
    end)

    -- The places must not give the bar a segment, change its geometry or break
    -- the match between occupied width and the level's percentage. The reading is
    -- asked for, not carried: building it on the redraw tick would allocate four
    -- lists and run four sorts up to five times a second for a popup nobody hovers.
    it("is not on the segment at all, so no redraw pays for it", function()
      local viewModel = XpBarViewModel.build(levelEarnedInTwoPlaces())

      for _, segment in ipairs(viewModel.segments) do
        assert.is_nil(segment.places)
      end
    end)

    it("changes nothing about the bar itself", function()
      local placed = levelEarnedInTwoPlaces()
      local bare = levelEarnedInTwoPlaces()
      bare.places = {}

      local withPlaces = XpBarViewModel.build(placed)
      local without = XpBarViewModel.build(bare)

      assert.equal(#without.segments, #withPlaces.segments)
      assert.equal(without.percentComplete, withPlaces.percentComplete)
      assert.equal(without.xpTotal, withPlaces.xpTotal)
      local sum = 0
      for index, segment in ipairs(withPlaces.segments) do
        assert.equal(without.segments[index].source, segment.source)
        assert.equal(without.segments[index].amount, segment.amount)
        assert.equal(without.segments[index].fraction, segment.fraction)
        sum = sum + segment.fraction
      end
      assert.near(withPlaces.percentComplete, sum, 1e-9)
    end)

    it("keeps the places out of the channels the bar animates", function()
      local shares = XpBarViewModel.shares(XpBarViewModel.build(levelEarnedInTwoPlaces()))

      local channels = 0
      for _ in pairs(shares) do
        channels = channels + 1
      end
      assert.equal(2, channels) -- mob_kill and quest_turnin, and nothing else
    end)

    it("says nothing at all for a level with no places", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(300))
      record.places = {}

      assert.is_nil(XpBarViewModel.placesFor(record, XpSource.MOB_KILL))
    end)

    -- Places recorded by a build that did not yet keep which source paid for them.
    -- A third state the popup must render exactly like the second one.
    it("says nothing for a level whose places predate the breakdown", function()
      local record = levelEarnedInTwoPlaces()
      for _, entry in pairs(record.places) do
        entry.xpBySource = {}
      end

      for _, source in ipairs({ XpSource.MOB_KILL, XpSource.QUEST_TURNIN }) do
        assert.is_nil(XpBarViewModel.placesFor(record, source))
      end
    end)

    -- The one honest gap: experience the client has confirmed and the attribution
    -- has not settled rides in the UNKNOWN segment but is in no place entry yet.
    it("leaves the unsettled experience out of the crossed reading rather than inventing a place", function()
      local record = level(10, 1000)
      XpLedger.post(record, gain(100, XpSource.UNKNOWN), nil, place(PlaceContext.WORLD, 1429))

      local viewModel = XpBarViewModel.build(record, { unattributedXp = 50 })
      local unknown = segmentFor(viewModel, XpSource.UNKNOWN)
      local places = XpBarViewModel.placesFor(record, XpSource.UNKNOWN)

      assert.equal(150, unknown.amount)
      assert.equal(1, #places)
      assert.equal(100, places[1].amount)
    end)
  end)

  -- The bar's half of "say what you did not see". The numbers are from a real
  -- level: joined at 8632, it went on to earn 13111 more, of which 184 never got a
  -- source.
  describe("what the record can say about its own completeness", function()
    local function partialLevel()
      local record = level(35, 54017)
      XpLedger.post(record, gain(8632, XpSource.UNKNOWN))
      XpLedger.post(record, gain(184, XpSource.UNKNOWN))
      XpLedger.post(record, gain(12918, XpSource.MOB_KILL))
      record.partial = true
      record.seededXp = 8632
      return record
    end

    it("says nothing about a level it watched from the first point", function()
      local record = level(35, 54017)
      XpLedger.post(record, gain(500))

      assert.is_nil(XpBarViewModel.build(record).observation)
    end)

    it("splits the seed from what it watched and could not explain", function()
      local observation = XpBarViewModel.build(partialLevel()).observation

      assert.is_true(observation.partial)
      assert.equal(8632, observation.seededXp)
      assert.equal(184, observation.unexplainedXp)
    end)

    -- A record saved before the addon kept the figure can say the accounting is
    -- incomplete and nothing more; claiming a split here would invent it.
    it("declines to split when the record never recorded the seed", function()
      local record = partialLevel()
      record.seededXp = nil

      local observation = XpBarViewModel.build(record).observation

      assert.is_true(observation.partial)
      assert.is_nil(observation.seededXp)
      assert.is_nil(observation.unexplainedXp)
    end)

    -- The split adds up to the line it sits under: the bucket plus what the
    -- settling window has not settled. The other tests here pass no params, so
    -- only this one tells the two apart.
    it("adds up to the unclassified segment, settling window included", function()
      local built = XpBarViewModel.build(partialLevel(), { unattributedXp = 250 })

      local unknown
      for _, segment in ipairs(built.segments) do
        if segment.source == XpSource.UNKNOWN then unknown = segment end
      end

      assert.equal(9066, unknown.amount)
      assert.equal(434, built.observation.unexplainedXp)
      assert.equal(unknown.amount, built.observation.seededXp + built.observation.unexplainedXp)
    end)

    it("never reports a negative remainder", function()
      local record = partialLevel()
      record.seededXp = 99999

      assert.equal(0, XpBarViewModel.build(record).observation.unexplainedXp)
    end)

    it("leaves every segment exactly as it was", function()
      local record = partialLevel()
      local withMark = XpBarViewModel.build(record)
      record.partial = false
      local without = XpBarViewModel.build(record)

      assert.equal(#without.segments, #withMark.segments)
      for index, segment in ipairs(without.segments) do
        assert.equal(segment.source, withMark.segments[index].source)
        assert.equal(segment.amount, withMark.segments[index].amount)
        assert.equal(segment.fraction, withMark.segments[index].fraction)
      end
      assert.equal(without.xpTotal, withMark.xpTotal)
    end)
  end)

  -- The third thing a record can say about its own completeness: that the kill
  -- line was not there to name creatures.
  describe("a level recorded without the kill line", function()
    it("carries why, and leaves the segments the bar paints alone", function()
      local record = ns.core.LevelRecord.new(10, 0)
      record.xpRequired = 1000
      ns.core.XpLedger.post(record, ns.core.XpGain.new({ amount = 400, source = ns.core.XpSource.UNKNOWN, at = 1 }))
      local before = ns.core.XpBarViewModel.build(record)
      record:markUnavailable(ns.core.RecordedSource.XP_CHAT, "unreadable")

      local viewModel = ns.core.XpBarViewModel.build(record)

      assert.equal("unreadable", viewModel.sourcesUnavailable)
      assert.same(before.segments, viewModel.segments)
      assert.is_nil(before.sourcesUnavailable)
    end)
  end)
end)
