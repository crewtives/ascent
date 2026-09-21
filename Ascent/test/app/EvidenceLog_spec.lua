-- The flight recorder has to be trustworthy in a specific way: it is read AFTER
-- the fact, by someone who was not there, to settle questions the code itself
-- cannot answer. So what is asserted here is not that it records something --
-- it is that what it records stays truthful and bounded: samples in order, the
-- authoritative delta kept apart from the parsed claim, the saved-variables
-- store seeing later samples without anyone remembering to flush, and the whole
-- thing costing nothing at all when it is switched off.

describe("EvidenceLog", function()
  local ns, EvidenceLog, EventBus, EventTopic, bus, clock

  local function fakePlayerState(level, xp)
    return {
      level = function() return level or 20 end,
      xp = function() return xp or 500 end,
      xpMax = function() return 1000 end,
      restedXp = function() return 120 end,
      isResting = function() return false end,
      isXpDisabled = function() return false end,
      healthFraction = function() return 1 end,
      powerFraction = function() return 1 end,
      classId = function() return "WARRIOR" end,
      raceId = function() return "Human" end,
      guid = function() return "Player-1" end,
      name = function() return "Tester" end,
      realm = function() return "Realm" end,
      faction = function() return "Alliance" end,
    }
  end

  before_each(function()
    -- The client surface EvidenceLog reads to say where the player is standing.
    _G.IsInInstance = function() return false, "none" end
    _G.GetInstanceInfo = function() return "none", "none", 0, "", 0, 0, 0, 0 end
    _G.GetZoneText = function() return "Westfall" end
    _G.GetSubZoneText = function() return "Sentinel Hill" end
    _G.IsInGroup = function() return true end
    _G.IsInRaid = function() return false end
    _G.GetNumGroupMembers = function() return 3 end
    _G.C_Map = { GetBestMapForUnit = function() return 52 end }

    ns = AscentTest.loadWith("core/model/", "core/service/EventBus.lua", "app/EvidenceLog.lua")
    EvidenceLog = ns.app.EvidenceLog
    EventBus = ns.core.EventBus
    EventTopic = ns.core.EventTopic
    clock = { now = function() return 100 end }
    bus = EventBus.new()
  end)

  after_each(function()
    for _, name in ipairs({ "IsInInstance", "GetInstanceInfo", "GetZoneText", "GetSubZoneText",
      "IsInGroup", "IsInRaid", "GetNumGroupMembers", "C_Map" }) do
      _G[name] = nil
    end
  end)

  local function newLog(options)
    options = options or {}
    options.bus = bus
    options.clock = clock
    options.playerState = options.playerState or fakePlayerState()
    if options.enabled == nil then options.enabled = true end
    return EvidenceLog.new(options)
  end

  it("needs its three collaborators", function()
    assert.has_error(function() EvidenceLog.new({}) end)
    assert.has_error(function() EvidenceLog.new({ bus = bus, clock = clock }) end)
  end)

  -- Retitled, because what it actually proves is narrower than what it claimed.
  -- start() returns before subscribing when the recorder was never switched on, so
  -- this is the normal login path: a player who never typed the command pays for
  -- nothing. It says nothing about a RUNNING recorder being stopped, which is the
  -- case below and the one that was broken.
  -- The sentence the family did not recognise. It used to go only to the debug log,
  -- which is the one place it could not be read back from afterwards -- so the line
  -- carrying the answer to "what does this client actually print" was the single
  -- line the recorder did not keep.
  it("keeps a line that matched no template, verbatim", function()
    local log = newLog({ enabled = true }):start()

    bus:publish(EventTopic.XP_LINE_UNMATCHED, {
      raw = "Something the family has never seen. You gain 40 experience somehow.",
      at = 12.5, restedBefore = 300, restedAfter = 260,
    })

    local sample = log.samples[#log.samples]
    assert.equal("unmatchedLine", sample.kind)
    assert.equal("Something the family has never seen. You gain 40 experience somehow.", sample.raw)
    assert.equal(1, log.counters.unmatchedLine)
  end)

  it("subscribes to nothing when it was never switched on", function()
    local log = newLog({ enabled = false }):start()

    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 120 })

    assert.is_false(log:isEnabled())
    assert.equal(0, #log.samples)
  end)

  describe("switching it off while it is running", function()
    -- The bug this covers: `enabled` was read once, at subscribe time, and the
    -- five live subscriptions never looked at it again. `/ascent evidence off`
    -- changed a flag and nothing else.
    it("stops recording", function()
      local log = newLog():start()
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 120 })
      local captured = #log.samples

      log:enable(false)
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 130 })
      bus:publish(EventTopic.XP_HINT_RECEIVED, { kind = "kill_message", amount = 130 })
      bus:publish(EventTopic.REST_CHANGED, { restedXp = 90 })

      assert.is_false(log:isEnabled())
      -- One more than captured: the marker that says it stopped.
      assert.equal(captured + 1, #log.samples)
      assert.equal("recordingChanged", log.samples[#log.samples].kind)
      assert.is_false(log.samples[#log.samples].on)
    end)

    -- The harm, stated as a test. The ring is bounded and drops the oldest, so a
    -- recorder that keeps running after being switched off does not merely waste
    -- work: it evicts the evidence the player stopped it to preserve.
    it("does not rotate the ring over what it already captured", function()
      local log = newLog({ limit = 3 }):start()
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 11 })
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 22 })
      log:enable(false)

      for _ = 1, 10 do
        bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 999 })
      end

      local amounts = {}
      for _, sample in ipairs(log.samples) do
        amounts[#amounts + 1] = sample.amount
      end
      assert.same({ 11, 22 }, { amounts[1], amounts[2] })
      for _, sample in ipairs(log.samples) do
        assert.not_equal(999, sample.amount)
      end
    end)

    it("records again when it is switched back on, once per event", function()
      local log = newLog():start()
      log:enable(false)
      log:enable(true)
      local before = #log.samples

      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 140 })

      assert.equal(before + 1, #log.samples)
      assert.equal("delta", log.samples[#log.samples].kind)
    end)

    -- Switching it on twice must not subscribe twice: the double would not fail,
    -- it would quietly double every counter in the file.
    it("installs one subscription however many times it is switched on", function()
      local log = newLog({ enabled = false })
      log:enable(true)
      log:enable(true)
      local before = #log.samples

      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 150 })

      assert.equal(before + 1, #log.samples)
    end)

    it("ignores a switch that changes nothing", function()
      local log = newLog():start()
      local before = #log.samples

      log:enable(true)

      assert.equal(before, #log.samples)
    end)
  end)

  describe("record(), the door for facts the bus does not carry", function()
    it("writes a sample of its own kind, counted by kind and placed", function()
      local log = newLog():start()

      log:record("questSweep", { scanned = 3, secure = true })

      local sample = log.samples[#log.samples]
      assert.equal("questSweep", sample.kind)
      assert.equal(3, sample.scanned)
      assert.is_true(sample.secure)
      assert.is_truthy(sample.place)
      assert.equal(1, log.counters.questSweep)
    end)

    it("writes nothing while the recorder is off", function()
      local log = newLog({ enabled = false })

      log:record("questSweep", { scanned = 3 })

      assert.equal(0, #log.samples)
      assert.is_nil(log.counters.questSweep)
    end)
  end)

  it("keeps the authoritative delta and the parsed claim as separate samples", function()
    -- The whole point: whether the two agree is the open question, so they are
    -- never folded into one number by the recorder itself.
    local log = newLog():start()

    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 138 })
    bus:publish(EventTopic.XP_HINT_RECEIVED, {
      kind = "kill_message", amount = 120, creatureName = "Boar", groupBonus = 18,
    })

    assert.equal(2, #log.samples)
    assert.equal("delta", log.samples[1].kind)
    assert.equal(138, log.samples[1].amount)
    assert.equal("hint", log.samples[2].kind)
    assert.equal(120, log.samples[2].amount)
    assert.equal(18, log.samples[2].groupBonus)
  end)

  it("stamps every sample with the time and the level it happened at", function()
    local log = newLog({ playerState = fakePlayerState(37, 4200) }):start()

    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 10 })

    assert.equal(100, log.samples[1].t)
    assert.equal(37, log.samples[1].level)
    assert.equal(4200, log.samples[1].xp)
  end)

  it("records where the player was standing", function()
    local log = newLog():start()

    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 10 })
    local place = log.samples[1].place

    assert.equal("Westfall", place.zone)
    assert.equal("Sentinel Hill", place.subZone)
    assert.equal(52, place.uiMapId)
    assert.is_false(place.inInstance)
    assert.is_true(place.inGroup)
    assert.equal(3, place.groupSize)
  end)

  -- Verbatim, because the parse is the thing under question. A file that holds
  -- only what the parser concluded cannot be used to check the parser.
  it("keeps the client's own sentence and the template it was read as", function()
    local log = newLog():start()

    bus:publish(EventTopic.XP_HINT_RECEIVED, {
      kind = "kill_message", amount = 120, creatureName = "Boar",
      template = "FIRSTPERSON", raw = "Boar dies, you gain 120 experience.",
    })

    assert.equal("FIRSTPERSON", log.samples[1].template)
    assert.equal("Boar dies, you gain 120 experience.", log.samples[1].raw)
    assert.equal(1, log.counters["template.FIRSTPERSON"])
  end)

  it("counts how often each kind of thing happened", function()
    local log = newLog():start()

    bus:publish(EventTopic.XP_HINT_RECEIVED, { kind = "kill_message", amount = 10, groupBonus = 2 })
    bus:publish(EventTopic.XP_HINT_RECEIVED, { kind = "kill_message", amount = 10 })
    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 10 })

    assert.equal(2, log.counters.hint)
    assert.equal(1, log.counters["hint.groupBonus"])
    assert.is_nil(log.counters["hint.raidPenalty"])
    assert.equal(1, log.counters.delta)
  end)

  it("drops the oldest sample rather than growing without bound", function()
    local log = newLog({ limit = 3 }):start()

    for amount = 1, 5 do
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = amount })
    end

    assert.equal(3, #log.samples)
    -- Oldest dropped, order preserved: the last hour is what matters.
    assert.equal(3, log.samples[1].amount)
    assert.equal(5, log.samples[3].amount)
  end)

  -- The property that makes it work with no flushing anywhere: the store holds
  -- the live tables, so anything recorded after attaching is already in the file
  -- when the client writes it at logout.
  it("lets the store see samples recorded after it was attached", function()
    local store = {}
    local log = newLog():start()
    log:attachTo(store, { locale = "enUS" })

    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 77 })

    assert.equal(1, #store.evidence.samples)
    assert.equal(77, store.evidence.samples[1].amount)
    assert.equal(1, store.evidence.counters.delta)
    assert.equal("enUS", store.evidence.environment.locale)
  end)

  -- What a flight recorder is FOR. The first real session was lost because a
  -- reload emptied the file before anyone had read it, so this is the property
  -- that has to hold: a new recorder attaching to a store that already has
  -- samples continues the ring instead of replacing it.
  describe("surviving a reload", function()
    -- A session: a fresh recorder over the same saved-variables store.
    local function session(store)
      local log = newLog():start()
      log:attachTo(store, { locale = "enUS" })
      return log
    end

    it("carries the previous session's samples forward", function()
      local store = {}
      session(store)
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 11 })

      bus = EventBus.new()
      local second = session(store)
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 22 })

      local amounts = {}
      for _, sample in ipairs(store.evidence.samples) do
        amounts[#amounts + 1] = sample.amount or sample.kind
      end
      assert.same({ 11, "sessionStarted", 22 }, amounts)
      assert.equal(second.samples, store.evidence.samples)
    end)

    it("sums the counters across sessions rather than restarting them", function()
      local store = {}
      session(store)
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 11 })

      bus = EventBus.new()
      session(store)
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 22 })

      assert.equal(2, store.evidence.counters.delta)
    end)

    -- Both the startup path and the chat command attach; after the first one the
    -- store's table IS the recorder's own, and adopting it would append the ring
    -- to itself.
    it("does not duplicate anything when the same recorder attaches twice", function()
      local store = {}
      local log = session(store)
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 11 })

      log:attachTo(store, { locale = "enUS" })

      assert.equal(1, #store.evidence.samples)
      assert.equal(1, store.evidence.counters.delta)
    end)

    -- Samples written by a different build of the recorder mean different things
    -- under the same field names; carrying them would make the counters lie.
    it("drops evidence left by a different version of the recorder", function()
      local store = { evidence = { version = 0, samples = { { kind = "delta", amount = 999 } },
        counters = { delta = 7 } } }

      session(store)

      assert.equal(0, #store.evidence.samples)
      assert.is_nil(store.evidence.counters.delta)
    end)

    it("still honours the limit once the carried samples are added back", function()
      local store = {}
      local first = newLog({ limit = 3 }):start()
      first:attachTo(store, {})
      for amount = 1, 3 do bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = amount }) end

      bus = EventBus.new()
      local second = newLog({ limit = 3 }):start()
      second:attachTo(store, {})

      -- Three carried plus the session marker, trimmed back to three from the
      -- oldest end.
      assert.equal(3, #store.evidence.samples)
      assert.equal(2, store.evidence.samples[1].amount)
      assert.equal("sessionStarted", store.evidence.samples[3].kind)
    end)

    it("reports the environment of the session running now, not the carried one", function()
      local store = {}
      newLog():start():attachTo(store, { locale = "frFR" })

      bus = EventBus.new()
      newLog():start():attachTo(store, { locale = "enUS" })

      assert.equal("enUS", store.evidence.environment.locale)
    end)
  end)

  it("keeps recording into the store after a reset", function()
    local store = {}
    local log = newLog():start()
    log:attachTo(store, {})

    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 1 })
    log:reset()
    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 2 })

    -- Emptied in place, never replaced: swapping the tables would silently
    -- disconnect the store and stop recording without any sign.
    assert.equal(1, #store.evidence.samples)
    assert.equal(2, store.evidence.samples[1].amount)
  end)

  -- Published with a REAL XpGain, wrapped the way XpAttribution wraps it. The
  -- first version of this test hand-wrote a flat payload, which agreed with a
  -- reader that was looking in the wrong place: both were wrong together, the
  -- test passed, and an entire recorded session came back with the verdict leg
  -- blank. A fake payload can only confirm the shape its author already believed.
  it("records what the reconciler finally decided, alongside the other two", function()
    local log = newLog():start()

    bus:publish(EventTopic.XP_ATTRIBUTED, {
      gain = ns.core.XpGain.new({
        amount = 120, source = ns.core.XpSource.MOB_KILL, at = 100, groupBonus = 18,
      }),
    })

    assert.equal("attributed", log.samples[1].kind)
    assert.equal(120, log.samples[1].amount)
    assert.equal(ns.core.XpSource.MOB_KILL, log.samples[1].source)
    assert.equal(18, log.samples[1].groupBonus)
    assert.equal(1, log.counters["attributed." .. ns.core.XpSource.MOB_KILL])
  end)

  -- Wrapped like the verdict above, and read flat for a while: the file came back
  -- with five level completions, not one of which could say which level had
  -- completed. A real LevelRecord, for the same reason as the case above -- a
  -- hand-written payload can only agree with the shape its author believed.
  it("records which level completed, not merely that one did", function()
    local log = newLog():start()

    bus:publish(EventTopic.LEVEL_COMPLETED, { record = ns.core.LevelRecord.new(12, 1700000000) })

    assert.equal("levelCompleted", log.samples[1].kind)
    assert.equal(12, log.samples[1].completedLevel)
    assert.equal(1, log.counters.levelCompleted)
  end)

  it("summarises itself in one line, so recording can be confirmed without the file", function()
    local log = newLog():start()

    assert.is_string(log:summary())
    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 10 })
    assert.is_not_nil(log:summary():find("delta=1", 1, true))
  end)
end)
