-- The two things worth stating up front, echoed from ProgressEstimator's own
-- header: the rested projection never claims more than 100% of the level, and
-- every sample-dependent estimate answers "not available" (nil) rather than
-- erroring or inventing a number when the level has nothing to sample yet (7.5).

describe("ProgressEstimator", function()
  local ns, ProgressEstimator, XpLedger, LevelRecord, XpGain, XpSource

  local function level(number, required)
    local record = LevelRecord.new(number, 0)
    record.xpRequired = required
    return record
  end

  local function killGain(amount, at)
    return XpGain.new({ amount = amount, source = XpSource.MOB_KILL, at = at or 0 })
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua", "core/service/ProgressEstimator.lua")
    ProgressEstimator = ns.core.ProgressEstimator
    XpLedger = ns.core.XpLedger
    LevelRecord = ns.core.LevelRecord
    XpGain = ns.core.XpGain
    XpSource = ns.core.XpSource
  end)

  describe("inactive record", function()
    it("reports inactive with no record", function()
      assert.is_false(ProgressEstimator.build(nil).active)
    end)

    it("reports inactive when the level does not know its own requirement yet", function()
      local record = level(10, nil)
      assert.is_false(ProgressEstimator.build(record).active)
    end)
  end)

  describe("percent completed and rested projection (7.1)", function()
    it("reports the percent completed from the level's own totals", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(400))

      local estimate = ProgressEstimator.build(record)

      assert.near(0.4, estimate.percentComplete, 1e-9)
    end)

    it("projects the rested reserve as additional percent, identified apart from progress", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(400))

      local estimate = ProgressEstimator.build(record, { restedXp = 300 })

      assert.near(0.7, estimate.restProjectedPercent, 1e-9)
    end)

    it("never lets the rested projection exceed the whole level", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(400))

      local estimate = ProgressEstimator.build(record, { restedXp = 5000 })

      assert.equal(1, estimate.restProjectedPercent)
    end)

    it("matches the plain percent completed when there is no rest reserve", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(400))

      local withoutRest = ProgressEstimator.build(record)
      local withZeroRest = ProgressEstimator.build(record, { restedXp = 0 })

      assert.equal(withoutRest.percentComplete, withoutRest.restProjectedPercent)
      assert.equal(withoutRest.percentComplete, withZeroRest.restProjectedPercent)
    end)
  end)

  describe("creature estimates over a recent window (7.3)", function()
    it("reports both as not available with no creature kills registered", function()
      local record = level(10, 1000)

      local estimate = ProgressEstimator.build(record, { restedXp = 200 })

      assert.is_nil(estimate.averageXpPerRecentKill)
      assert.is_nil(estimate.restReachCreatures)
      assert.is_nil(estimate.creaturesRemaining)
    end)

    it("averages the recent kills and derives both creature counts from it", function()
      local record = level(10, 1000)
      for _ = 1, 4 do
        XpLedger.post(record, killGain(50))
      end
      -- 200 xp from kills, 800 xp remaining, 500 xp rested reserve.

      local estimate = ProgressEstimator.build(record, { restedXp = 500 })

      assert.near(50, estimate.averageXpPerRecentKill, 1e-9)
      assert.near(16, estimate.creaturesRemaining, 1e-9) -- 800 / 50
      assert.near(10, estimate.restReachCreatures, 1e-9) -- 500 / 50
    end)

    it("only averages over the recent window, not the whole level's history", function()
      local record = level(10, 100000)
      -- Ten early kills worth 10 each, far outside the window, then eight recent
      -- ones worth 100 each -- the window is 8, so only the recent batch counts.
      for _ = 1, 10 do
        XpLedger.post(record, killGain(10))
      end
      for _ = 1, 8 do
        XpLedger.post(record, killGain(100))
      end

      local estimate = ProgressEstimator.build(record)

      assert.near(100, estimate.averageXpPerRecentKill, 1e-9)
    end)

    it("ignores gains from other sources when averaging kills", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(60))
      XpLedger.post(record, XpGain.new({ amount = 500, source = XpSource.QUEST_TURNIN, at = 0 }))

      local estimate = ProgressEstimator.build(record)

      assert.near(60, estimate.averageXpPerRecentKill, 1e-9)
    end)

    it("reports zero creatures left on the rested reserve when it is already empty", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(50))

      local estimate = ProgressEstimator.build(record, { restedXp = 0 })

      assert.equal(0, estimate.restReachCreatures)
    end)
  end)

  describe("experience per hour (7.2)", function()
    it("computes the level's pace from its own played time", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(400))

      local estimate = ProgressEstimator.build(record, { playedSeconds = 1800 }) -- half an hour

      assert.near(800, estimate.xpPerHourLevel, 1e-9)
    end)

    it("reports the level's pace as not available without played time", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(400))

      local estimate = ProgressEstimator.build(record, { playedSeconds = 0 })

      assert.is_nil(estimate.xpPerHourLevel)
    end)

    it("computes the session's pace from the session's own gained xp and elapsed time", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(400))

      local estimate = ProgressEstimator.build(record, { sessionXpGained = 1200, sessionSeconds = 3600 })

      assert.near(1200, estimate.xpPerHourSession, 1e-9)
    end)

    it("reports the session's pace as not available without a session elapsed time", function()
      local record = level(10, 1000)

      local estimate = ProgressEstimator.build(record, { sessionXpGained = 1200 })

      assert.is_nil(estimate.xpPerHourSession)
    end)
  end)

  describe("estimated time to next level (7.4)", function()
    it("derives the estimate from what is missing and the level's own live pace", function()
      local record = level(10, 1000)
      XpLedger.post(record, killGain(400))

      -- 400 xp over half an hour is 800 xp/h; 600 xp remaining at that pace is 45 minutes.
      local estimate = ProgressEstimator.build(record, { playedSeconds = 1800 })

      assert.near(2700, estimate.timeToLevel, 1e-6)
    end)

    it("reports not available with a null pace instead of an infinite or erroring result", function()
      local record = level(10, 1000)

      local estimate = ProgressEstimator.build(record, { playedSeconds = 0 })

      assert.is_nil(estimate.timeToLevel)
    end)
  end)

  describe("robustness on a freshly started level (7.5)", function()
    it("keeps the percent completed available while every sample-dependent estimate is not", function()
      local record = level(10, 1000)

      local estimate = ProgressEstimator.build(record)

      assert.equal(0, estimate.percentComplete)
      assert.equal(0, estimate.restProjectedPercent)
      assert.is_nil(estimate.averageXpPerRecentKill)
      assert.is_nil(estimate.restReachCreatures)
      assert.is_nil(estimate.creaturesRemaining)
      assert.is_nil(estimate.xpPerHourLevel)
      assert.is_nil(estimate.xpPerHourSession)
      assert.is_nil(estimate.timeToLevel)
    end)

    it("never errors or produces a non-numeric value with every input nil", function()
      local record = level(10, 1000)

      local ok, estimate = pcall(ProgressEstimator.build, record, {
        playedSeconds = nil, restedXp = nil, sessionSeconds = nil, sessionXpGained = nil,
      })

      assert.is_true(ok)
      for _, key in ipairs({
        "percentComplete", "restProjectedPercent", "averageXpPerRecentKill", "restReachCreatures",
        "creaturesRemaining", "xpPerHourLevel", "xpPerHourSession", "timeToLevel",
      }) do
        local value = estimate[key]
        assert.is_true(value == nil or (type(value) == "number" and value == value), key)
      end
    end)
  end)

  -- Not a ProgressEstimator test alone: the "no degrada el ritmo" guarantee (7.2)
  -- lives in the combination -- LevelTracker already excludes offline time from
  -- playedSeconds (5.3), and this only holds if the pace built on top of it stays
  -- honest about that. Wiring the two together end to end is what actually proves
  -- a long disconnect cannot inflate or shrink the level's own xp/hour.
  describe("pace unaffected by offline time (7.2, with LevelTracker)", function()
    it("keeps the level's pace intact across a long disconnect", function()
      local domain = AscentTest.loadWith("core/model/", "core/port/",
        "core/service/XpLedger.lua", "core/service/RecordStore.lua",
        "core/service/RetentionPolicy.lua", "core/service/LevelTracker.lua",
        "core/service/ProgressEstimator.lua",
        "test/fakes/FakeClock.lua", "test/fakes/FakePlayerState.lua",
        "test/fakes/InMemoryRepository.lua", "test/fakes/RecordingEventBus.lua")

      local clock = domain.fakes.FakeClock.new(0)
      local player = domain.fakes.FakePlayerState.new({ level = 5 })
      local repository = domain.fakes.InMemoryRepository.new()
      local store = domain.core.RecordStore.new({ repository = repository }):load()
      local bus = domain.fakes.RecordingEventBus.new()
      local tracker = domain.core.LevelTracker.new({
        bus = bus, clock = clock, playerState = player, store = store,
      })

      tracker:start()

      player:gain(400)
      bus:publish(domain.core.EventTopic.XP_ATTRIBUTED, {
        gain = domain.core.XpGain.new({ amount = 400, source = domain.core.XpSource.MOB_KILL, at = clock:now() }),
      })
      clock:advance(1800) -- half an hour of real, online play

      tracker:stop() -- logout: playedSeconds stops accruing here
      clock:advance(100000) -- over a day offline
      tracker:start() -- login again, same level and character

      local estimate = domain.core.ProgressEstimator.build(tracker:current(), {
        playedSeconds = tracker:playedSeconds(),
      })

      assert.near(1800, tracker:playedSeconds(), 1e-9)
      assert.near(800, estimate.xpPerHourLevel, 1e-9) -- 400 xp / 0.5 h, gap or no gap
    end)
  end)
end)
