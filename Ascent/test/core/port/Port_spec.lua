describe("Port", function()
  local ns, Port

  before_each(function()
    ns = AscentTest.loadDomain(
      "core/port/Port.lua", "core/port/Clock.lua", "core/port/PlayerState.lua",
      "core/port/Repository.lua", "core/port/EventBus.lua", "core/port/Logger.lua",
      "core/port/Locale.lua")
    Port = ns.core.Port
  end)

  describe("a contract", function()
    it("documents what each method means, not just its name", function()
      assert.is_string(ns.core.Clock.now)
      assert.is_true(#ns.core.Clock.now > 20)
    end)

    it("errors on a method nobody declared, like every other frozen table", function()
      assert.has_error(function() return ns.core.Clock.yesterday end)
    end)

    it("knows its own name, for the error message", function()
      assert.equal("Clock", Port.nameOf(ns.core.Clock))
    end)
  end)

  describe("verifying an implementation", function()
    -- The point of the whole file: a missing method becomes one clear error at
    -- wiring time instead of a nil call inside a combat handler an hour later.
    it("accepts an implementation that has every method", function()
      local clock = { now = function() return 1 end, timestamp = function() return 2 end }

      assert.equal(clock, Port.verify(ns.core.Clock, clock))
    end)

    it("names every missing method at once, not one per reload", function()
      local ok, err = pcall(Port.verify, ns.core.PlayerState, { level = function() end })

      assert.is_false(ok)
      assert.is_truthy(err:find("PlayerState", 1, true))
      assert.is_truthy(err:find("xp", 1, true))
      assert.is_truthy(err:find("isXpDisabled", 1, true))
    end)

    it("rejects a field that is not callable", function()
      local clock = { now = 1, timestamp = function() end }

      assert.has_error(function() return Port.verify(ns.core.Clock, clock) end)
    end)

    it("rejects something that is not an implementation at all", function()
      assert.has_error(function() return Port.verify(ns.core.Clock, nil) end)
      assert.has_error(function() return Port.verify(ns.core.Clock, "clock") end)
    end)

    it("uses the label the caller gave, so the error says which adapter failed", function()
      local ok, err = pcall(Port.verify, ns.core.Clock, {}, "WowClock")

      assert.is_false(ok)
      assert.is_truthy(err:find("WowClock", 1, true))
    end)
  end)

  describe("the six ports of v1", function()
    -- The design's cut rule is explicit: a port exists only if it enables testing
    -- without the client or has two plausible implementations. Six qualify. This
    -- asserts the whole set, so a seventh has to be argued for, not just added.
    it("are exactly these six, with no seventh", function()
      assert.same({ "Clock", "EventBus", "Locale", "Logger", "PlayerState", "Repository" },
        Port.all())
    end)

    it("are each reachable on the namespace under the name the code uses", function()
      assert.equal("Clock", Port.nameOf(ns.core.Clock))
      assert.equal("PlayerState", Port.nameOf(ns.core.PlayerState))
      assert.equal("Repository", Port.nameOf(ns.core.Repository))
      assert.equal("EventBus", Port.nameOf(ns.core.EventBusPort))
      assert.equal("Logger", Port.nameOf(ns.core.Logger))
      assert.equal("Locale", Port.nameOf(ns.core.Locale))
    end)
  end)
end)
