describe("CombatAggregator", function()
  local ns, bus, registry, record, MetricId, EventTopic

  local function load()
    return AscentTest.loadWith("core/model/", "core/port/",
      "core/registry/MetricRegistry.lua", "core/service/CombatAggregator.lua",
      "test/fakes/RecordingEventBus.lua")
  end

  before_each(function()
    ns = load()
    MetricId = ns.core.MetricId
    EventTopic = ns.core.EventTopic
    bus = ns.fakes.RecordingEventBus.new()
    registry = ns.core.MetricRegistry.new()
    record = ns.core.LevelRecord.new(5, 0)
  end)

  local function fakeLogger()
    local messages = {}
    return { warn = function(_, message) messages[#messages + 1] = message end }, messages
  end

  it("dispatches a bus event to the collector that declared its topic", function()
    local received
    registry:register({
      id = MetricId.DAMAGE,
      topics = { EventTopic.DAMAGE_DEALT },
      collect = function(rec, payload) received = { rec, payload } end,
    })
    local _ = ns.core.CombatAggregator.new({
      bus = bus, registry = registry, currentRecord = function() return record end,
    })

    bus:publish(EventTopic.DAMAGE_DEALT, { amount = 42 })

    assert.equal(record, received[1])
    assert.equal(42, received[2].amount)
  end)

  it("never subscribes to a topic nothing registered", function()
    registry:register({ id = MetricId.DAMAGE, topics = { EventTopic.DAMAGE_DEALT }, collect = function() end })
    local _ = ns.core.CombatAggregator.new({
      bus = bus, registry = registry, currentRecord = function() return record end,
    })

    -- Publishing an unrelated combat topic must not throw looking for a handler
    -- that was never registered.
    assert.has_no.errors(function()
      bus:publish(EventTopic.COMBAT_STARTED, {})
    end)
  end)

  it("drops an event when there is no level in progress to attribute it to", function()
    local called = false
    registry:register({
      id = MetricId.DAMAGE,
      topics = { EventTopic.DAMAGE_DEALT },
      collect = function() called = true end,
    })
    local _ = ns.core.CombatAggregator.new({
      bus = bus, registry = registry, currentRecord = function() return nil end,
    })

    bus:publish(EventTopic.DAMAGE_DEALT, { amount = 5 })

    assert.is_false(called)
  end)

  it("reads currentRecord fresh on every event instead of caching it (6.8)", function()
    local seen = {}
    registry:register({
      id = MetricId.DAMAGE,
      topics = { EventTopic.DAMAGE_DEALT },
      collect = function(rec) seen[#seen + 1] = rec end,
    })
    local current = record
    local _ = ns.core.CombatAggregator.new({
      bus = bus, registry = registry, currentRecord = function() return current end,
    })

    bus:publish(EventTopic.DAMAGE_DEALT, { amount = 1 })
    local nextLevel = ns.core.LevelRecord.new(6, 0)
    current = nextLevel
    bus:publish(EventTopic.DAMAGE_DEALT, { amount = 1 })

    assert.equal(record, seen[1])
    assert.equal(nextLevel, seen[2])
  end)

  -- A single subscriber fans out to several collectors: one that throws must
  -- not stop the others from seeing the same event, not just later ones.
  describe("per-collector isolation (12.5)", function()
    it("keeps a second collector working when the first one throws on the same event", function()
      local secondRan = false
      registry:register({
        id = MetricId.DEATHS,
        topics = { EventTopic.DAMAGE_DEALT },
        collect = function() error("boom") end,
      })
      registry:register({
        id = MetricId.DAMAGE,
        topics = { EventTopic.DAMAGE_DEALT },
        collect = function() secondRan = true end,
      })
      local logger = fakeLogger()
      local _ = ns.core.CombatAggregator.new({
        bus = bus, registry = registry, currentRecord = function() return record end, logger = logger,
      })

      assert.has_no.errors(function()
        bus:publish(EventTopic.DAMAGE_DEALT, { amount = 1 })
      end)
      assert.is_true(secondRan)
    end)

    it("warns about a failing collector once, not on every recurrence", function()
      registry:register({
        id = MetricId.DEATHS,
        topics = { EventTopic.DAMAGE_DEALT },
        collect = function() error("boom") end,
      })
      local logger, messages = fakeLogger()
      local _ = ns.core.CombatAggregator.new({
        bus = bus, registry = registry, currentRecord = function() return record end, logger = logger,
      })

      bus:publish(EventTopic.DAMAGE_DEALT, { amount = 1 })
      bus:publish(EventTopic.DAMAGE_DEALT, { amount = 1 })
      bus:publish(EventTopic.DAMAGE_DEALT, { amount = 1 })

      assert.equal(1, #messages)
    end)

    it("keeps working with no logger at all", function()
      registry:register({
        id = MetricId.DEATHS,
        topics = { EventTopic.DAMAGE_DEALT },
        collect = function() error("boom") end,
      })
      local _ = ns.core.CombatAggregator.new({
        bus = bus, registry = registry, currentRecord = function() return record end,
      })

      assert.has_no.errors(function()
        bus:publish(EventTopic.DAMAGE_DEALT, { amount = 1 })
      end)
    end)
  end)
end)
