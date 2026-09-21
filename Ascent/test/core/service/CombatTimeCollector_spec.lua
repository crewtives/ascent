describe("CombatTimeCollector", function()
  local ns, collector, record, clock, EventTopic
  local THRESHOLD = 0.95

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "core/service/CombatTimeCollector.lua", "test/fakes/FakeClock.lua")
    EventTopic = ns.core.EventTopic
    clock = ns.fakes.FakeClock.new(0)
    collector = ns.core.CombatTimeCollector.new({ clock = clock, recoveryThreshold = THRESHOLD })
    record = ns.core.LevelRecord.new(5, 0)
  end)

  local function fire(topic)
    collector:collect(record, {}, topic)
  end

  describe("combat time", function()
    it("accumulates the duration of several fights during the level", function()
      fire(EventTopic.COMBAT_STARTED)
      clock:advance(10)
      fire(EventTopic.COMBAT_ENDED)

      clock:advance(20) -- out of combat, in between
      fire(EventTopic.COMBAT_STARTED)
      clock:advance(5)
      fire(EventTopic.COMBAT_ENDED)

      assert.equal(15, record:combatSeconds())
    end)
  end)

  describe("recovery", function()
    it("counts time up to the threshold as recovery time after a fight", function()
      fire(EventTopic.COMBAT_ENDED)
      clock:advance(5)
      collector:observe(record, 0.5, 0.5) -- still below THRESHOLD

      clock:advance(3)
      collector:observe(record, 1.0, 1.0) -- crosses THRESHOLD now

      assert.equal(8, record:recoverySeconds())
    end)

    it("stops accumulating once the threshold is met", function()
      fire(EventTopic.COMBAT_ENDED)
      clock:advance(5)
      collector:observe(record, 1.0, 1.0) -- recovered

      clock:advance(100) -- long stretch doing nothing in particular
      collector:observe(record, 1.0, 1.0)

      assert.equal(5, record:recoverySeconds())
    end)

    it("needs BOTH health and power over the threshold, not just one", function()
      fire(EventTopic.COMBAT_ENDED)
      clock:advance(5)
      collector:observe(record, 1.0, 0.5) -- health recovered, power is not

      clock:advance(3)
      collector:observe(record, 1.0, 1.0)

      assert.equal(8, record:recoverySeconds())
    end)

    it("does not accumulate recovery time while back in combat", function()
      fire(EventTopic.COMBAT_ENDED)
      clock:advance(2)
      fire(EventTopic.COMBAT_STARTED) -- back in the fight before recovering

      clock:advance(50)
      collector:observe(record, 0.2, 0.2) -- ignored: in combat now

      assert.equal(2, record:recoverySeconds())
    end)
  end)

  describe("disconnected time", function()
    it("does not add the gap between SESSION_ENDED and SESSION_STARTED to any accumulator", function()
      fire(EventTopic.COMBAT_STARTED)
      clock:advance(5)
      fire(EventTopic.COMBAT_ENDED)

      fire(EventTopic.SESSION_ENDED)
      clock:advance(9000) -- offline for hours
      fire(EventTopic.SESSION_STARTED)

      clock:advance(3)
      fire(EventTopic.COMBAT_STARTED)
      clock:advance(2)
      fire(EventTopic.COMBAT_ENDED)

      assert.equal(7, record:combatSeconds())
    end)
  end)

  describe("death and revival", function()
    it("does not count the time spent dead as recovery -- that belongs to DeathCollector", function()
      fire(EventTopic.PLAYER_DIED)
      clock:advance(15)
      fire(EventTopic.PLAYER_REVIVED)

      assert.equal(0, record:recoverySeconds())
    end)

    it("starts a fresh recovery window after reviving below the threshold", function()
      fire(EventTopic.PLAYER_DIED)
      clock:advance(15)
      fire(EventTopic.PLAYER_REVIVED)

      clock:advance(6)
      collector:observe(record, 1.0, 1.0)

      assert.equal(6, record:recoverySeconds())
    end)
  end)

  describe("consistency", function()
    it("keeps combat + out-of-combat equal to played time", function()
      record.playedSeconds = 100

      fire(EventTopic.COMBAT_STARTED)
      clock:advance(30)
      fire(EventTopic.COMBAT_ENDED)

      assert.equal(30, record:combatSeconds())
      assert.equal(70, record:outOfCombatSeconds())
      assert.equal(record.playedSeconds, record:combatSeconds() + record:outOfCombatSeconds())
    end)

    it("is zero for a level nothing has happened on yet", function()
      assert.equal(0, record:combatSeconds())
      assert.equal(0, record:recoverySeconds())
    end)
  end)

  describe("level crossing (6.8)", function()
    -- A level-up mid-fight fires no COMBAT_STARTED/ENDED of its own -- nothing
    -- marks the crossing explicitly. What actually splits the fight is the same
    -- 5Hz observe() ticker Bootstrap already calls for recovery sampling: each
    -- tick closes the interval against whichever record is current AT THAT TICK,
    -- so the slice before the crossing lands on the old level and the slice
    -- after lands on the new one, bounded by one tick's worth of imprecision.
    it("splits a fight that crosses a level-up between the two levels at the nearest tick", function()
      local closingLevel = record
      local nextLevel = ns.core.LevelRecord.new(6, 0)

      collector:collect(closingLevel, {}, EventTopic.COMBAT_STARTED)
      clock:advance(4)
      collector:observe(closingLevel, 1.0, 1.0) -- a tick before the crossing: still the old level

      clock:advance(1) -- the level-up lands here, between two ticks
      collector:observe(nextLevel, 1.0, 1.0) -- the next tick already sees the new level current

      clock:advance(2)
      collector:collect(nextLevel, {}, EventTopic.COMBAT_ENDED)

      assert.equal(4, closingLevel:combatSeconds())
      assert.equal(3, nextLevel:combatSeconds())
    end)

    it("does not lose or double-count a second's worth of time across the split", function()
      local closingLevel = record
      local nextLevel = ns.core.LevelRecord.new(6, 0)

      collector:collect(closingLevel, {}, EventTopic.COMBAT_STARTED)
      clock:advance(4)
      collector:observe(closingLevel, 1.0, 1.0)
      clock:advance(1)
      collector:observe(nextLevel, 1.0, 1.0)
      clock:advance(2)
      collector:collect(nextLevel, {}, EventTopic.COMBAT_ENDED)

      assert.equal(7, closingLevel:combatSeconds() + nextLevel:combatSeconds())
    end)
  end)
end)
