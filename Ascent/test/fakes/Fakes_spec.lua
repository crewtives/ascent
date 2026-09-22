-- The fakes are what let the domain be tested at all, so they get the same
-- scrutiny as the code they stand in for. Each one is checked against its port on
-- construction, which means this suite fails the moment a contract and its double
-- drift apart -- the failure mode that makes fakes worse than useless.

describe("the test doubles", function()
  local ns

  local function load()
    local files = AscentTest.tocPaths("core/port/")
    for _, extra in ipairs({
      "core/service/EventBus.lua",
      "test/fakes/FakeClock.lua",
      "test/fakes/FakePlayerState.lua",
      "test/fakes/InMemoryRepository.lua",
      "test/fakes/RecordingEventBus.lua",
    }) do
      files[#files + 1] = extra
    end
    return AscentTest.loadDomain(unpack(files))
  end

  before_each(function()
    ns = load()
  end)

  describe("FakeClock", function()
    it("satisfies the Clock port", function()
      assert.is_truthy(ns.core.Port.verify(ns.core.Clock, ns.fakes.FakeClock.new()))
    end)

    it("lets the test move time forward instead of waiting for it", function()
      local clock = ns.fakes.FakeClock.new(100, 1000)

      clock:advance(45)

      assert.equal(145, clock:now())
      assert.equal(1045, clock:timestamp())
    end)

    it("can move the wall clock alone, the way a player changing their system time does", function()
      local clock = ns.fakes.FakeClock.new(100, 1000)

      clock:setTimestamp(999999)

      assert.equal(100, clock:now())
      assert.equal(999999, clock:timestamp())
    end)
  end)

  describe("FakePlayerState", function()
    it("satisfies the PlayerState port", function()
      assert.is_truthy(ns.core.Port.verify(ns.core.PlayerState, ns.fakes.FakePlayerState.new()))
    end)

    it("starts from sensible defaults and takes overrides", function()
      local player = ns.fakes.FakePlayerState.new({ level = 24, xp = 900, xpMax = 12000 })

      assert.equal(24, player:level())
      assert.equal(900, player:xp())
      assert.equal(12000, player:xpMax())
    end)

    it("can be put in states that are tedious to reach in game", function()
      local player = ns.fakes.FakePlayerState.new()

      player:set("isXpDisabled", true):set("health", 0.08):set("restedXp", 4500)

      assert.is_true(player:isXpDisabled())
      assert.equal(0.08, player:healthFraction())
      assert.equal(4500, player:restedXp())
    end)

    -- The default every domain fixture inherits. The client's own 0 here would
    -- seed the whole suite with a group size nobody ever plays at.
    it("is alone until a test puts the character in a group", function()
      local player = ns.fakes.FakePlayerState.new()

      assert.equal(1, player:sharedBy())
      assert.equal(5, player:set("sharedBy", 5):sharedBy())
    end)

    -- The same contract the rested reserve already has: the port promises plain
    -- values and a real answer for "the client cannot say", and the double has to
    -- be able to produce both or no domain test can reach the reserved entry.
    it("answers where the character is, as three plain values", function()
      local player = ns.fakes.FakePlayerState.new()

      player:set("place", { context = ns.core.PlaceContext.DUNGEON, areaId = 389, name = "Ragefire Chasm" })
      local context, areaId, name = player:place()

      assert.equal(ns.core.PlaceContext.DUNGEON, context)
      assert.equal(389, areaId)
      assert.equal("Ragefire Chasm", name)
    end)

    it("says nothing at all when the client could not tell where the character is", function()
      local context, areaId, name = ns.fakes.FakePlayerState.new():place()

      assert.is_nil(context)
      assert.is_nil(areaId)
      assert.is_nil(name)
    end)

    it("levels up the way the client does, carrying the overflow", function()
      local player = ns.fakes.FakePlayerState.new({ level = 10, xp = 900, xpMax = 1000 })

      player:gain(350)

      assert.equal(11, player:level())
      assert.equal(250, player:xp())
    end)

    -- Each level costs more than the last. A fake where they all cost the same
    -- would let a bug in the level-crossing arithmetic pass unnoticed.
    it("makes each level cost more than the one before", function()
      local player = ns.fakes.FakePlayerState.new({ level = 10 })
      local atTen = player:xpMax()

      player:gain(atTen)

      assert.equal(11, player:level())
      assert.is_true(player:xpMax() > atTen)
    end)

    it("stops gaining at the maximum level, experience included", function()
      local player = ns.fakes.FakePlayerState.new({ level = 60, maxLevel = 60, xp = 0, xpMax = 1000 })

      player:gain(5000)

      assert.equal(60, player:level())
      assert.equal(0, player:xp())
    end)

    it("gains nothing while experience is switched off", function()
      local player = ns.fakes.FakePlayerState.new({ level = 10, xp = 100 })
      player:set("isXpDisabled", true)

      player:gain(5000)

      assert.equal(10, player:level())
      assert.equal(100, player:xp())
    end)

    it("rejects a field nobody has, instead of quietly creating one", function()
      assert.has_error(function() return ns.fakes.FakePlayerState.new({ levle = 24 }) end)
      assert.has_error(function() return ns.fakes.FakePlayerState.new():set("healthFraction", 0.5) end)
    end)

    it("identifies the character, so histories do not mix", function()
      local name, realm = ns.fakes.FakePlayerState.new():identity()

      assert.equal("Tester", name)
      assert.equal("TestRealm", realm)
    end)
  end)

  describe("InMemoryRepository", function()
    it("satisfies the Repository port", function()
      assert.is_truthy(ns.core.Port.verify(ns.core.Repository, ns.fakes.InMemoryRepository.new()))
    end)

    it("gives back what was stored", function()
      local repository = ns.fakes.InMemoryRepository.new()

      repository:setSchemaVersion(1)
      repository:saveCurrentRecord({ level = 24 })
      repository:saveCompletedRecord({ level = 23 })

      assert.equal(1, repository:schemaVersion())
      assert.equal(24, repository:currentRecord().level)
      assert.equal(23, repository:completedRecord(23).level)
    end)

    -- The distinction level-history insists on: never recorded is not the same as
    -- recorded as zero.
    it("answers nil for a level that was never recorded", function()
      local repository = ns.fakes.InMemoryRepository.new()

      assert.is_nil(repository:completedRecord(23))
      assert.is_nil(repository:schemaVersion())
      assert.same({}, repository:completedLevels())
    end)

    it("lists completed levels in order", function()
      local repository = ns.fakes.InMemoryRepository.new()

      repository:saveCompletedRecord({ level = 25 })
      repository:saveCompletedRecord({ level = 23 })
      repository:saveCompletedRecord({ level = 24 })

      assert.same({ 23, 24, 25 }, repository:completedLevels())
    end)

    it("archives data it cannot use instead of refusing to load", function()
      local repository = ns.fakes.InMemoryRepository.new({
        schemaVersion = 99, current = { level = 1 }, settings = { debug = true },
      })

      repository:archiveIncompatible()

      assert.is_nil(repository:schemaVersion())
      assert.equal(99, repository.legacy.schemaVersion)
      assert.same({ debug = true }, repository:settings())
    end)

    -- Saved variables drop metatables, functions and exotic keys on the way out,
    -- and the loss only shows up on the next login as a record missing half of
    -- itself. Better to fail here, naming the field.
    describe("refuses to store what a saved variables file could not hold", function()
      local repository

      before_each(function()
        repository = ns.fakes.InMemoryRepository.new()
      end)

      it("rejects a table with a metatable", function()
        local record = setmetatable({ level = 24 }, { __index = function() end })

        local ok, err = pcall(function() repository:saveCurrentRecord(record) end)

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("metatable", 1, true))
      end)

      it("rejects a function value, naming where it was", function()
        local ok, err = pcall(function()
          repository:saveCurrentRecord({ level = 24, nested = { onUpdate = function() end } })
        end)

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("nested.onUpdate", 1, true))
      end)

      it("rejects a cycle", function()
        local record = { level = 24 }
        record.self = record

        assert.has_error(function() repository:saveCurrentRecord(record) end)
      end)

      it("accepts plain data of any depth", function()
        assert.has_no.errors(function()
          repository:saveCurrentRecord({
            level = 24, xpBySource = { mob_kill = 400, quest_turnin = 900 },
            gains = { { amount = 44, at = 1 }, { amount = 91, at = 2 } },
          })
        end)
      end)
    end)

    it("keeps account options when a character's history is cleared", function()
      local repository = ns.fakes.InMemoryRepository.new()
      repository:saveSettings({ debug = true })
      repository:saveCompletedRecord({ level = 23 })

      repository:clear()

      assert.same({ debug = true }, repository:settings())
      assert.is_nil(repository:completedRecord(23))
    end)
  end)

  describe("RecordingEventBus", function()
    it("satisfies the EventBus port", function()
      assert.is_truthy(ns.core.Port.verify(ns.core.EventBusPort, ns.fakes.RecordingEventBus.new()))
    end)

    it("remembers what was announced, in order", function()
      local bus = ns.fakes.RecordingEventBus.new()
      local Topic = ns.core.EventTopic

      bus:publish(Topic.LEVEL_STARTED, { level = 24 })
      bus:publish(Topic.XP_ATTRIBUTED, { amount = 44 })
      bus:publish(Topic.XP_ATTRIBUTED, { amount = 91 })

      assert.same({ Topic.LEVEL_STARTED, Topic.XP_ATTRIBUTED, Topic.XP_ATTRIBUTED }, bus:topicsInOrder())
      assert.equal(2, bus:countOf(Topic.XP_ATTRIBUTED))
      assert.equal(91, bus:lastOn(Topic.XP_ATTRIBUTED).amount)
      assert.equal(24, bus:lastOn(Topic.LEVEL_STARTED).level)
    end)

    it("delivers as well as records, so it can stand in for the real bus", function()
      local bus = ns.fakes.RecordingEventBus.new()
      local received

      bus:subscribe(ns.core.EventTopic.COMBAT_ENDED, function(payload) received = payload end)
      bus:publish(ns.core.EventTopic.COMBAT_ENDED, { health = 0.61 })

      assert.equal(0.61, received.health)
    end)

    it("catches a topic typo in a test the same way the real bus would", function()
      local bus = ns.fakes.RecordingEventBus.new()

      assert.has_error(function() bus:publish("combat_finished", {}) end)
    end)

    -- The port says a handler that throws must not stop the others. A double that
    -- is more forgiving than the real bus makes every test that uses it a lie.
    it("isolates a subscriber that throws, like the real bus does", function()
      local bus = ns.fakes.RecordingEventBus.new()
      local reached = false

      bus:subscribe(ns.core.EventTopic.RECORD_UPDATED, function() error("boom") end)
      bus:subscribe(ns.core.EventTopic.RECORD_UPDATED, function() reached = true end)

      pcall(function() bus:publish(ns.core.EventTopic.RECORD_UPDATED, {}) end)

      assert.is_true(reached)
      assert.equal(1, #bus.errors)
      assert.equal(ns.core.EventTopic.RECORD_UPDATED, bus.errors[1].topic)
    end)

    it("still surfaces the failure rather than swallowing it", function()
      local bus = ns.fakes.RecordingEventBus.new()
      bus:subscribe(ns.core.EventTopic.RECORD_UPDATED, function() error("boom") end)

      assert.has_error(function() bus:publish(ns.core.EventTopic.RECORD_UPDATED, {}) end)
    end)

    it("rejects a subscriber that is not callable, like the real bus does", function()
      local bus = ns.fakes.RecordingEventBus.new()

      assert.has_error(function() bus:subscribe(ns.core.EventTopic.RECORD_UPDATED, "nope") end)
    end)

    it("can be emptied between phases of a test", function()
      local bus = ns.fakes.RecordingEventBus.new()
      bus:publish(ns.core.EventTopic.SESSION_STARTED, {})

      bus:reset()

      assert.same({}, bus:topicsInOrder())
    end)
  end)
end)
