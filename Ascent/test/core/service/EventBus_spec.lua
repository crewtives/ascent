describe("EventBus", function()
  local ns, EventBus, EventTopic, bus

  before_each(function()
    ns = AscentTest.loadDomain("core/service/EventBus.lua")
    EventBus = ns.core.EventBus
    EventTopic = ns.core.EventTopic
    bus = EventBus.new()
  end)

  describe("delivery", function()
    it("reaches every subscriber of a topic", function()
      local seen = {}
      bus:subscribe(EventTopic.XP_ATTRIBUTED, function(payload) seen[#seen + 1] = "first:" .. payload.amount end)
      bus:subscribe(EventTopic.XP_ATTRIBUTED, function(payload) seen[#seen + 1] = "second:" .. payload.amount end)

      local delivered = bus:publish(EventTopic.XP_ATTRIBUTED, { amount = 44 })

      assert.equal(2, delivered)
      assert.same({ "first:44", "second:44" }, seen)
    end)

    it("passes the topic alongside the payload, so one handler can serve several", function()
      local topics = {}
      local handler = function(_, topic) topics[#topics + 1] = topic end

      bus:subscribe(EventTopic.COMBAT_STARTED, handler)
      bus:subscribe(EventTopic.COMBAT_ENDED, handler)
      bus:publish(EventTopic.COMBAT_STARTED)
      bus:publish(EventTopic.COMBAT_ENDED)

      assert.same({ EventTopic.COMBAT_STARTED, EventTopic.COMBAT_ENDED }, topics)
    end)

    it("does not mind a topic nobody is listening to", function()
      assert.equal(0, bus:publish(EventTopic.SESSION_ENDED, {}))
    end)

    it("leaves other topics alone", function()
      local called = false
      bus:subscribe(EventTopic.LEVEL_STARTED, function() called = true end)

      bus:publish(EventTopic.LEVEL_COMPLETED, {})

      assert.is_false(called)
    end)
  end)

  describe("unsubscribing", function()
    it("stops delivery", function()
      local calls = 0
      local subscription = bus:subscribe(EventTopic.RECORD_UPDATED, function() calls = calls + 1 end)

      bus:publish(EventTopic.RECORD_UPDATED, {})
      bus:unsubscribe(subscription)
      bus:publish(EventTopic.RECORD_UPDATED, {})

      assert.equal(1, calls)
      assert.equal(0, bus:subscriberCount(EventTopic.RECORD_UPDATED))
    end)

    -- Teardown order is not always knowable, so a second unsubscribe must be a
    -- no-op rather than something every caller has to guard against.
    it("is safe to do twice", function()
      local subscription = bus:subscribe(EventTopic.RECORD_UPDATED, function() end)

      assert.is_true(bus:unsubscribe(subscription))
      assert.is_false(bus:unsubscribe(subscription))
      assert.is_false(bus:unsubscribe(nil))
    end)

    -- A view that hides itself while handling an update does exactly this.
    it("is safe from inside a handler that is being delivered to", function()
      local calls = 0
      local second
      bus:subscribe(EventTopic.RECORD_UPDATED, function()
        calls = calls + 1
        bus:unsubscribe(second)
      end)
      second = bus:subscribe(EventTopic.RECORD_UPDATED, function() calls = calls + 1 end)

      bus:publish(EventTopic.RECORD_UPDATED, {})
      bus:publish(EventTopic.RECORD_UPDATED, {})

      assert.equal(2, calls) -- both on the first round, only the survivor on the second
      assert.equal(1, bus:subscriberCount(EventTopic.RECORD_UPDATED))
    end)

    it("does not deliver to a subscriber created during the round that created it", function()
      local lateCalls = 0
      bus:subscribe(EventTopic.RECORD_UPDATED, function()
        bus:subscribe(EventTopic.RECORD_UPDATED, function() lateCalls = lateCalls + 1 end)
      end)

      bus:publish(EventTopic.RECORD_UPDATED, {})

      assert.equal(0, lateCalls)
    end)
  end)

  describe("topics are constants, not strings", function()
    it("refuses to publish to something that is not a topic", function()
      assert.has_error(function() bus:publish("xp_attributed_typo", {}) end)
      assert.has_error(function() bus:publish(nil, {}) end)
    end)

    it("refuses to subscribe to something that is not a topic", function()
      assert.has_error(function() bus:subscribe("made_up", function() end) end)
    end)

    it("refuses a subscriber that is not callable", function()
      assert.has_error(function() bus:subscribe(EventTopic.RECORD_UPDATED, "nope") end)
    end)
  end)

  describe("a handler that throws", function()
    it("does not stop the others from being called", function()
      local reached = false
      bus:subscribe(EventTopic.RECORD_UPDATED, function() error("collector exploded") end)
      bus:subscribe(EventTopic.RECORD_UPDATED, function() reached = true end)

      pcall(function() bus:publish(EventTopic.RECORD_UPDATED, {}) end)

      assert.is_true(reached)
    end)

    it("goes to the error handler when there is one, and publishing still succeeds", function()
      local failures = {}
      local isolated = EventBus.new(function(topic, err) failures[#failures + 1] = { topic, err } end)
      local reached = false

      isolated:subscribe(EventTopic.RECORD_UPDATED, function() error("boom") end)
      isolated:subscribe(EventTopic.RECORD_UPDATED, function() reached = true end)
      isolated:publish(EventTopic.RECORD_UPDATED, {})

      assert.is_true(reached)
      assert.equal(1, #failures)
      assert.equal(EventTopic.RECORD_UPDATED, failures[1][1])
      assert.is_truthy(tostring(failures[1][2]):find("boom", 1, true))
    end)

    -- Never swallowed: without a handler wired, the error comes back to the caller
    -- once everyone has been served.
    it("surfaces afterwards when no error handler was given", function()
      bus:subscribe(EventTopic.RECORD_UPDATED, function() error("boom") end)

      assert.has_error(function() bus:publish(EventTopic.RECORD_UPDATED, {}) end)
    end)

    it("rejects an error handler that is not callable", function()
      assert.has_error(function() return EventBus.new("not a function") end)
    end)

    -- The error handler is somebody else's code too. If it could escape, the
    -- in-flight counter would stay above zero and compaction would be dead for the
    -- rest of the session.
    it("does not let a broken error handler stop delivery either", function()
      local reached = false
      local isolated = EventBus.new(function() error("the logger is broken too") end)

      isolated:subscribe(EventTopic.RECORD_UPDATED, function() error("boom") end)
      isolated:subscribe(EventTopic.RECORD_UPDATED, function() reached = true end)
      isolated:publish(EventTopic.RECORD_UPDATED, {})

      assert.is_true(reached)
    end)

    it("still compacts after a handler blew up, so the bus is not poisoned", function()
      local isolated = EventBus.new(function() error("the logger is broken too") end)
      isolated:subscribe(EventTopic.RECORD_UPDATED, function() error("boom") end)
      isolated:publish(EventTopic.RECORD_UPDATED, {})

      local subscription = isolated:subscribe(EventTopic.COMBAT_ENDED, function() end)
      isolated:unsubscribe(subscription)

      assert.equal(0, #isolated.subscribers[EventTopic.COMBAT_ENDED])
    end)

    -- `error()` raises nil. Using nil as the "no failure" sentinel would swallow
    -- precisely that, against what the header promises.
    it("surfaces a handler that raised nothing at all", function()
      bus:subscribe(EventTopic.RECORD_UPDATED, function() error() end)

      assert.has_error(function() bus:publish(EventTopic.RECORD_UPDATED, {}) end)
    end)
  end)

  describe("housekeeping", function()
    -- The shape this addon actually has: an adapter publishes, and a service
    -- publishes a second topic from inside that handler. With a single global
    -- in-flight counter, that second topic would never compact and its dead
    -- subscriptions would pile up for the whole session.
    it("compacts a topic that is only ever published from inside another handler", function()
      bus:subscribe(EventTopic.XP_DELTA_OBSERVED, function(payload)
        bus:publish(EventTopic.XP_ATTRIBUTED, payload)
      end)

      for _ = 1, 50 do
        local subscription = bus:subscribe(EventTopic.XP_ATTRIBUTED, function() end)
        bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 1 })
        bus:unsubscribe(subscription)
      end

      assert.equal(0, bus:subscriberCount(EventTopic.XP_ATTRIBUTED))
      assert.is_true(#bus.subscribers[EventTopic.XP_ATTRIBUTED] <= 1,
        "dead subscriptions piled up: " .. #bus.subscribers[EventTopic.XP_ATTRIBUTED])
    end)

    it("ignores a subscription that belongs to a different bus", function()
      local other = EventBus.new()
      local subscription = other:subscribe(EventTopic.RECORD_UPDATED, function() end)

      assert.is_false(bus:unsubscribe(subscription))
      assert.equal(1, other:subscriberCount(EventTopic.RECORD_UPDATED))
    end)

    it("ignores a table that was never a subscription", function()
      assert.is_false(bus:unsubscribe({}))
      assert.is_false(bus:unsubscribe({ topic = EventTopic.RECORD_UPDATED, handler = function() end }))
    end)

    it("stops a cycle of topics with a named error instead of a stack overflow", function()
      bus:subscribe(EventTopic.XP_DELTA_OBSERVED, function()
        bus:publish(EventTopic.XP_DELTA_OBSERVED, {})
      end)

      local ok, err = pcall(function() bus:publish(EventTopic.XP_DELTA_OBSERVED, {}) end)

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("cycle", 1, true))
    end)
  end)
end)
