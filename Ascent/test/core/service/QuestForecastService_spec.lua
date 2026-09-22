-- What is stored is always the nominal reward (never reduced twice), an unknown
-- reward is reported as unknown rather than estimated, and the total collapses
-- to zero at the cap or with experience disabled.

describe("QuestForecastService", function()
  local ns, QuestForecastService, QuestForecast, QuestXpOrigin
  local playerState, repository

  local function forecast(questId, questLevel, reward, origin, complete)
    return QuestForecast.new({
      questId = questId, questLevel = questLevel, reward = reward,
      origin = origin or (reward and QuestXpOrigin.CLIENT or QuestXpOrigin.UNKNOWN),
      complete = complete or false,
    })
  end

  -- `scanResult` is whatever list the next scan() call should hand back;
  -- swap it between assertions to simulate the quest log changing.
  local scanResult, scanCalls

  local function service(overrides)
    overrides = overrides or {}
    scanResult = overrides.scanResult or {}
    scanCalls = 0

    playerState = ns.fakes.FakePlayerState.new(overrides.player or { level = 20 })
    repository = ns.fakes.InMemoryRepository.new(overrides.seed)

    return QuestForecastService.new({
      playerState = playerState,
      repository = repository,
      scan = overrides.scan or function()
        scanCalls = scanCalls + 1
        return scanResult
      end,
      logger = overrides.logger,
    })
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "test/fakes/FakePlayerState.lua", "test/fakes/InMemoryRepository.lua",
      "core/service/QuestForecastService.lua")
    QuestForecastService = ns.core.QuestForecastService
    QuestForecast = ns.core.QuestForecast
    QuestXpOrigin = ns.core.QuestXpOrigin
  end)

  describe("construction", function()
    it("requires a playerState, a repository and a scan function", function()
      assert.has_error(function() QuestForecastService.new({}) end)
    end)
  end)

  describe("scan cadence (8.3)", function()
    it("scans on the first tick even without an explicit markDirty", function()
      local svc = service()
      assert.is_true(svc:tick())
      assert.equal(1, scanCalls)
    end)

    it("does not scan again until something marks it dirty", function()
      local svc = service()
      svc:tick()

      assert.is_false(svc:tick())
      assert.equal(1, scanCalls)
    end)

    it("scans again after markDirty, and only once per mark", function()
      local svc = service()
      svc:tick()

      svc:markDirty()
      assert.is_true(svc:tick())
      assert.equal(2, scanCalls)

      assert.is_false(svc:tick())
      assert.equal(2, scanCalls)
    end)

    it("refuses to scan again from inside its own scan", function()
      local svc
      local reentered
      svc = QuestForecastService.new({
        playerState = ns.fakes.FakePlayerState.new({ level = 20 }),
        repository = ns.fakes.InMemoryRepository.new(),
        scan = function()
          reentered = svc:tick() -- attempted reentry, while `scanning` is true
          return {}
        end,
      })

      svc:tick()
      assert.is_false(reentered)
    end)

    it("clears the scanning guard even if the scan itself throws, so a later tick can still run", function()
      local shouldThrow = true
      local svc = service({
        scan = function()
          if shouldThrow then
            error("simulated adapter failure")
          end
          return {}
        end,
      })

      assert.has_error(function() svc:tick() end)

      shouldThrow = false
      svc:markDirty()
      assert.is_true(svc:tick())
    end)
  end)

  describe("provenance chain (8.5)", function()
    it("trusts a CLIENT-origin entry from the scan as-is", function()
      local svc = service({ scanResult = { forecast(1, 10, 400, QuestXpOrigin.CLIENT) } })
      svc:tick()

      assert.equal(400, svc.current[1].reward)
      assert.equal(QuestXpOrigin.CLIENT, svc.current[1].origin)
    end)

    it("falls an UNKNOWN entry back to a previously learned reward", function()
      local svc = service({ seed = { questRewards = { [1] = 250 } }, scanResult = { forecast(1, 10, nil) } })
      svc:tick()

      assert.equal(250, svc.current[1].reward)
      assert.equal(QuestXpOrigin.LEARNED, svc.current[1].origin)
    end)

    it("leaves a quest with no learned reward and no client value as unknown", function()
      local svc = service({ scanResult = { forecast(1, 10, nil) } })
      svc:tick()

      assert.is_false(svc.current[1]:isKnown())
      assert.equal(QuestXpOrigin.UNKNOWN, svc.current[1].origin)
    end)

    it("forgets a learned reward once its quest is no longer in the log", function()
      local svc = service({ seed = { questRewards = { [1] = 250, [2] = 100 } }, scanResult = { forecast(1, 10, nil) } })
      svc:tick()

      assert.equal(250, svc.current[1].reward) -- still there
      assert.is_nil(svc.current[2]) -- gone from the sweep entirely
      assert.same({ [1] = 250 }, repository:questRewards()) -- and dropped from the persisted cache
    end)
  end)

  describe("learning a reward (8.4)", function()
    it("persists immediately", function()
      local svc = service()
      svc:learn(7, 300)

      assert.same({ [7] = 300 }, repository:questRewards())
    end)

    it("survives being re-read the way a reload would (repository round-trip)", function()
      local svc = service()
      svc:learn(7, 300)

      local reloaded = QuestForecastService.new({
        playerState = playerState, repository = repository, scan = function() return {} end,
      })
      assert.equal(300, reloaded.learned[7])
    end)

    it("shows up in the current forecast right away, without waiting for a scan", function()
      local svc = service({ scanResult = { forecast(1, 10, nil) } })
      svc:tick() -- quest 1 is on the log, unknown

      svc:learn(1, 500)

      assert.equal(500, svc.current[1].reward)
      assert.equal(QuestXpOrigin.LEARNED, svc.current[1].origin)
    end)

    it("never overrides an existing CLIENT-origin forecast", function()
      local svc = service({ scanResult = { forecast(1, 10, 400, QuestXpOrigin.CLIENT) } })
      svc:tick()

      svc:learn(1, 999) -- e.g. a stale value from before this reward became readable

      assert.equal(400, svc.current[1].reward)
      assert.equal(QuestXpOrigin.CLIENT, svc.current[1].origin)
    end)
  end)

  describe("reporting the pending total (8.1, 8.2)", function()
    it("is all zero before anything has ever been scanned", function()
      local svc = service()
      assert.same({ total = 0, readyTotal = 0, unknownCount = 0 }, svc:report())
    end)

    it("sums known rewards into the total, and only complete ones into readyTotal", function()
      local svc = service({
        scanResult = {
          forecast(1, 10, 300, QuestXpOrigin.CLIENT, true),
          forecast(2, 10, 200, QuestXpOrigin.CLIENT, false),
        },
        player = { level = 12 }, -- within five levels of the quests: no reduction
      })
      svc:tick()

      local report = svc:report()
      assert.equal(500, report.total)
      assert.equal(300, report.readyTotal)
    end)

    it("counts quests with no known reward, without letting them affect the total", function()
      local svc = service({
        scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT), forecast(2, 10, nil) },
        player = { level = 12 },
      })
      svc:tick()

      local report = svc:report()
      assert.equal(300, report.total)
      assert.equal(1, report.unknownCount)
    end)

    it("applies no reduction within five levels above the quest", function()
      local svc = service({ scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) }, player = { level = 15 } })
      svc:tick()
      assert.equal(300, svc:report().total)
    end)

    it("reduces to eighty percent exactly six levels above the quest", function()
      local svc = service({ scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) }, player = { level = 16 } })
      svc:tick()
      assert.equal(240, svc:report().total)
    end)

    it("floors at ten percent ten or more levels above the quest", function()
      local svc = service({ scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) }, player = { level = 20 } })
      svc:tick()
      assert.equal(30, svc:report().total)

      local svcFarther = service({
        scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) }, player = { level = 40 },
      })
      svcFarther:tick()
      assert.equal(30, svcFarther:report().total) -- does not keep dropping past ten
    end)

    it("reports a quest with no known level at its full value, unreduced", function()
      local svc = service({ scanResult = { forecast(1, nil, 300, QuestXpOrigin.CLIENT) }, player = { level = 40 } })
      svc:tick()
      assert.equal(300, svc:report().total)
    end)

    it("is all zero at the client's maximum level", function()
      local svc = service({
        scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) },
        player = { level = 60, maxLevel = 60 },
      })
      svc:tick()
      assert.same({ total = 0, readyTotal = 0, unknownCount = 0 }, svc:report())
    end)

    it("is all zero with experience gain disabled", function()
      local svc = service({
        scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) },
        player = { level = 20, isXpDisabled = true },
      })
      svc:tick()
      assert.same({ total = 0, readyTotal = 0, unknownCount = 0 }, svc:report())
    end)
  end)

  describe("calibrating against a real turn-in (8.6)", function()
    it("leaves the stored nominal untouched when the prediction was exact", function()
      local svc = service({ scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) }, player = { level = 16 } })
      svc:tick()
      -- Predicted (adjusted for six levels over): 240. The turn-in pays exactly that.
      svc:calibrate(1, 240)

      assert.equal(300, svc.learned[1]) -- reconstructed nominal, not the reduced 240
    end)

    it("corrects the stored nominal when the prediction was off", function()
      local svc = service({ scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) }, player = { level = 16 } })
      svc:tick()
      -- The client's number was wrong: the quest really pays 400 nominal, so the
      -- turn-in at six levels over actually delivers 320 (80% of 400).
      svc:calibrate(1, 320)

      assert.equal(400, svc.learned[1])
    end)

    it("a calibrated quest is not reduced a second time on the next report", function()
      -- The client offers no number (UNKNOWN; CLIENT would outrank a calibrated
      -- LEARNED value). Ten levels below the character the turn-in pays 30, 10%
      -- of the true nominal 300, and a later report of a similar quest must read
      -- 30 again, not 300 reduced a second time down to 3.
      local svc = service({ scanResult = { forecast(1, 10, nil) }, player = { level = 20 } })
      svc:tick()
      svc:calibrate(1, 30)
      assert.equal(300, svc.learned[1]) -- reconstructed nominal, not the reduced 30

      -- The quest is still open; a later scan still finds it, now resolved
      -- through the LEARNED fallback since the client still offers nothing.
      svc:markDirty()
      svc:tick()
      assert.equal(30, svc:report().total)
    end)

    it("still learns something sensible for a quest calibrate is called on without a prior scan", function()
      local svc = service({ player = { level = 20 } })
      svc:calibrate(9, 150) -- no forecast on record at all for quest 9

      assert.equal(150, svc.learned[9]) -- no known level assumed a zero difference: no reduction
    end)
  end)

  describe("per-quest detail for the pending-xp tab (entries, 11.5)", function()
    it("sorts several known quests descending by adjustedReward, ties broken by questId ascending", function()
      local svc = service({
        scanResult = {
          forecast(1, 10, 300, QuestXpOrigin.CLIENT),
          forecast(5, 10, 200, QuestXpOrigin.CLIENT),
          forecast(2, 10, 200, QuestXpOrigin.CLIENT), -- ties quest 5 on adjustedReward
        },
        player = { level = 12 }, -- within five levels: no reduction
      })
      svc:tick()

      local entries = svc:entries()
      assert.equal(3, #entries)
      assert.equal(1, entries[1].questId)
      assert.equal(300, entries[1].adjustedReward)
      assert.equal(2, entries[2].questId) -- tied at 200, lower questId first
      assert.equal(5, entries[3].questId)
    end)

    it("sorts a quest with no known reward last, regardless of questId", function()
      local svc = service({
        scanResult = { forecast(1, 10, nil), forecast(2, 10, 300, QuestXpOrigin.CLIENT) },
        player = { level = 12 },
      })
      svc:tick()

      local entries = svc:entries()
      assert.equal(2, entries[1].questId)
      assert.equal(300, entries[1].adjustedReward)
      assert.equal(1, entries[2].questId)
      assert.is_nil(entries[2].adjustedReward)
    end)

    it("carries questLevel, origin and complete alongside the raw reward", function()
      local svc = service({
        scanResult = { forecast(7, 15, 250, QuestXpOrigin.CLIENT, true) },
        player = { level = 15 },
      })
      svc:tick()

      local entries = svc:entries()
      assert.equal(1, #entries)
      assert.equal(7, entries[1].questId)
      assert.equal(15, entries[1].questLevel)
      assert.equal(250, entries[1].reward)
      assert.equal(QuestXpOrigin.CLIENT, entries[1].origin)
      assert.is_true(entries[1].complete)
      assert.equal(250, entries[1].adjustedReward)
    end)

    it("returns an empty array, not nil, when nothing has ever been scanned", function()
      local svc = service()
      local entries = svc:entries()

      assert.is_not_nil(entries)
      assert.equal(0, #entries)
    end)
  end)

  describe("logging (optional -- never required to construct or call this service)", function()
    it("never errors when constructed and used without a logger", function()
      local svc = service({ scanResult = { forecast(1, 10, 300, QuestXpOrigin.CLIENT) } })
      assert.has_no.errors(function()
        svc:tick()
        svc:learn(2, 100)
        svc:calibrate(1, 300)
      end)
    end)

    it("logs a reconcile summary naming each origin's count", function()
      local messages = {}
      local logger = { debug = function(_, msg) table.insert(messages, msg) end }
      local svc = service({
        logger = logger,
        seed = { questRewards = { [2] = 150 } },
        scanResult = {
          forecast(1, 10, 300, QuestXpOrigin.CLIENT),
          forecast(2, 10, nil), -- falls back to LEARNED via the seeded cache
          forecast(3, 10, nil), -- stays UNKNOWN
        },
      })
      svc:tick()

      local found = false
      for _, msg in ipairs(messages) do
        if msg:find("scan reconciled", 1, true) then found = true end
      end
      assert.is_true(found)
    end)

    it("logs when learn() is called", function()
      local messages = {}
      local logger = { debug = function(_, msg) table.insert(messages, msg) end }
      local svc = service({ logger = logger })

      svc:learn(9, 200)

      local found = false
      for _, msg in ipairs(messages) do
        if msg:find("learn:", 1, true) then found = true end
      end
      assert.is_true(found)
    end)

    -- The line compares the payout with the figure the panel was showing, and a
    -- quest whose reward came from the client and was never learned gets one too.
    it("logs what was shown against what was paid", function()
      local messages = {}
      local logger = { debug = function(_, msg) table.insert(messages, msg) end }
      local svc = service({ logger = logger, player = { level = 20 } })
      svc:learn(1, 300)

      svc:calibrate(1, 300)

      local line
      for _, msg in ipairs(messages) do
        if msg:find("calibrate:", 1, true) then line = msg end
      end
      assert.is_truthy(line)
      assert.is_truthy(line:find("shown=300", 1, true))
      assert.is_truthy(line:find("received=300", 1, true))
    end)

    it("logs a quest nothing was ever learned for, which used to produce nothing", function()
      local messages = {}
      local logger = { debug = function(_, msg) table.insert(messages, msg) end }
      local svc = service({ logger = logger, player = { level = 20 } })

      svc:calibrate(99, 250)

      local found = false
      for _, msg in ipairs(messages) do
        if msg:find("calibrate:", 1, true) then found = true end
      end
      assert.is_true(found)
    end)
  end)

  -- Each real turn-in, recorded against what was forecast for it: the payout has
  -- to be compared with the forecast, not with a number derived from the payout.
  describe("the calibration record (8.7)", function()
    it("carries what was shown, where it came from, and what was paid", function()
      local svc = service({ player = { level = 20 } })
      svc:learn(1, 300)

      local record = svc:calibrate(1, 300)

      assert.equal(1, record.questId)
      assert.equal(300, record.shown)
      assert.equal(300, record.received)
      assert.equal(300, record.nominal)
      assert.equal(20, record.characterLevel)
      assert.is_false(record.stale)
    end)

    it("records a quest the addon never learned, with no forecast to show", function()
      local svc = service({ player = { level = 20 } })

      local record = svc:calibrate(99, 250)

      assert.equal(99, record.questId)
      assert.is_nil(record.shown)
      assert.is_nil(record.origin)
      assert.equal(250, record.received)
    end)

    -- A client-reported zero is a real answer on some builds, not a missing one,
    -- and coercing it away would hide exactly that case.
    it("passes a reported zero through as zero", function()
      local svc = service({ player = { level = 20 } })

      local record = svc:calibrate(5, 0)

      assert.equal(0, record.received)
    end)

    -- The race that would otherwise read as a perfect prediction: with the
    -- forecast gone, questLevel falls back to the character's own level and
    -- nominal comes out equal to received.
    it("flags a forecast a rescan removed between the turn-in and the reward", function()
      local svc = service({
        scanResult = { forecast(7, 18, 400, QuestXpOrigin.CLIENT) },
        player = { level = 20 },
      })
      svc:tick()
      -- The quest log changed and the ticker rescanned before the reward landed;
      -- the ticker only rescans after markDirty.
      svc.scan = function() return {} end
      svc:markDirty()
      svc:tick()

      local record = svc:calibrate(7, 400)

      assert.is_true(record.stale)
      assert.equal(7, record.questId)
    end)
  end)
end)
