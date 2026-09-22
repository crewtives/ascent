-- The flight recorder is read after the fact, by someone who was not there, to
-- settle questions the code itself cannot answer. So what it records has to stay
-- truthful and bounded: samples in order, the authoritative delta kept apart from
-- the parsed claim, the saved-variables store seeing later samples without a
-- flush, and no cost at all when it is switched off.

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

  -- A sentence no template recognised answers "what does this client actually
  -- print", and the debug log cannot be read back afterwards, so the file keeps it.
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

  -- start() returns before subscribing when the recorder was never switched on:
  -- the normal login path, where a player who never typed the command pays for
  -- nothing. Stopping a running recorder is the case below.
  it("subscribes to nothing when it was never switched on", function()
    local log = newLog({ enabled = false }):start()

    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 120 })

    assert.is_false(log:isEnabled())
    assert.equal(0, #log.samples)
  end)

  describe("switching it off while it is running", function()
    -- The live subscriptions must read `enabled` on every event: read once at
    -- subscribe time, `/ascent evidence off` would change a flag and nothing else.
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

    -- The ring is bounded and drops the oldest, so a recorder that keeps running
    -- after being switched off evicts the evidence the player stopped it to keep.
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

  -- The ring is scarce and the counters are not: a fact that happens constantly
  -- and says the same thing every time is counted without spending a sample.
  describe("counting without keeping", function()
    it("tallies a counter-only kind without spending a sample on it", function()
      local log = newLog():start()

      log:record("timePlayedReceived", { levelSeconds = 900 })

      assert.equal(1, log.counters.timePlayedReceived)
      assert.equal(0, #log.samples)
    end)

    -- By declaration and not by volume: a counter-only kind is counter-only the
    -- first time too. Otherwise the same fact would occupy a sample in a short
    -- session and not in a long one, and two files would stop being comparable.
    it("keeps a counter-only kind out of the ring even when it happens once", function()
      local log = newLog():start()

      log:record("sessionStarted", { carriedSamples = 0 })

      assert.equal(1, log.counters.sessionStarted)
      assert.equal(0, #log.samples)
    end)

    it("still counts and keeps a kind that was not declared", function()
      local log = newLog():start()

      log:record("questSweep", { scanned = 3 })

      assert.equal(1, log.counters.questSweep)
      assert.equal(1, #log.samples)
    end)

    -- Declaring a kind of the experience path counter-only would fail nothing:
    -- it would quietly drop the evidence, and nobody would find out until they
    -- read the file.
    it("declares nothing on the experience path as counter-only", function()
      for _, kind in ipairs({ "delta", "hint", "attributed", "gain", "levelCompleted",
        "restChanged", "engaged", "unmatchedLine", "recordingChanged" }) do
        assert.is_nil(EvidenceLog.COUNTER_ONLY[kind],
          ("%q is on the experience path and must never be counter-only"):format(kind))
      end
    end)

    -- The shape of a real session: every delta followed by four time-played
    -- answers and a reload marker. If those took samples, the experience the ring
    -- exists to capture would be pushed off its oldest end.
    it("does not let predictable noise evict the evidence", function()
      local log = newLog({ limit = 5 }):start()

      for amount = 1, 5 do
        bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = amount })
        for _ = 1, 4 do
          log:record("timePlayedReceived", { levelSeconds = 900 })
        end
        log:record("sessionStarted", { carriedSamples = 0 })
      end

      assert.equal(5, #log.samples)
      local amounts = {}
      for _, sample in ipairs(log.samples) do
        amounts[#amounts + 1] = sample.amount
      end
      assert.same({ 1, 2, 3, 4, 5 }, amounts)
      assert.equal(20, log.counters.timePlayedReceived)
      assert.equal(5, log.counters.sessionStarted)
    end)
  end)

  it("keeps the authoritative delta and the parsed claim as separate samples", function()
    -- Whether the two agree is the open question, so the recorder never folds
    -- them into one number.
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

  -- No flushing anywhere: the store holds the live tables, so anything recorded
  -- after attaching is already in the file when the client writes it at logout.
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

  -- A reload must not empty the file before anyone has read it: a new recorder
  -- attaching to a store that already has samples continues the ring instead of
  -- replacing it.
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
      -- The session marker is counted and not kept: one marker sample per
      -- reload is enough to crowd a long session's evidence out of the ring.
      assert.same({ 11, 22 }, amounts)
      assert.equal(1, store.evidence.counters.sessionStarted)
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
    -- store's table is the recorder's own, and adopting it would append the ring
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

    -- Version 2 kept session markers as samples, with counters that cannot say
    -- which of the two they came from: its noise cannot be told apart from its
    -- evidence, so it is dropped.
    it("drops evidence written before counting and keeping were separated", function()
      local store = { evidence = { version = 2,
        samples = { { kind = "sessionStarted" }, { kind = "delta", amount = 999 } },
        counters = { delta = 7, sessionStarted = 32 } } }

      session(store)

      assert.equal(0, #store.evidence.samples)
      assert.is_nil(store.evidence.counters.delta)
      assert.is_nil(store.evidence.counters.sessionStarted)
    end)

    -- Carrying forward sums the counter-only tallies while the ring keeps only
    -- what was kept.
    it("carries counter-only tallies forward without carrying samples for them", function()
      local store = {}
      local first = session(store)
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 11 })
      first:record("timePlayedReceived", { levelSeconds = 900 })
      first:record("timePlayedReceived", { levelSeconds = 960 })

      bus = EventBus.new()
      local second = session(store)
      bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 22 })
      second:record("timePlayedReceived", { levelSeconds = 1020 })

      local amounts = {}
      for _, sample in ipairs(store.evidence.samples) do
        amounts[#amounts + 1] = sample.amount
      end
      assert.same({ 11, 22 }, amounts)
      assert.equal(3, store.evidence.counters.timePlayedReceived)
      assert.equal(1, store.evidence.counters.sessionStarted)
    end)

    it("still honours the limit once the carried samples are added back", function()
      local store = {}
      local first = newLog({ limit = 3 }):start()
      first:attachTo(store, {})
      for amount = 1, 3 do bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = amount }) end

      bus = EventBus.new()
      local second = newLog({ limit = 3 }):start()
      second:attachTo(store, {})

      -- Three carried and nothing else: the session marker does not spend a
      -- sample, so the limit buys three samples of evidence, not two plus a marker.
      assert.equal(3, #store.evidence.samples)
      assert.equal(1, store.evidence.samples[1].amount)
      assert.equal(3, store.evidence.samples[3].amount)
      assert.equal(1, store.evidence.counters.sessionStarted)
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

  -- Published with a real XpGain, wrapped the way XpAttribution wraps it: a
  -- hand-written flat payload would agree with a reader looking in the wrong
  -- place. A fake payload can only confirm the shape its author already believed.
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

  -- LEVEL_COMPLETED carries the level inside `record`, wrapped like the verdict
  -- above, and a real LevelRecord is published for the same reason.
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
