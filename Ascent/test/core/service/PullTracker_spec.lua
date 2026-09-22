describe("PullTracker", function()
  local ns, bus, clock, EventTopic, PullPhase, XpSource, tracker

  local function load()
    return AscentTest.loadWith("core/model/", "core/port/",
      "core/service/PullTracker.lua",
      "test/fakes/RecordingEventBus.lua", "test/fakes/FakeClock.lua")
  end

  local function build(options)
    options = options or {}
    options.bus = bus
    options.clock = clock
    return ns.core.PullTracker.new(options)
  end

  local function gain(amount, source)
    return { gain = { amount = amount, source = source or XpSource.MOB_KILL } }
  end

  before_each(function()
    ns = load()
    EventTopic = ns.core.EventTopic
    PullPhase = ns.core.PullPhase
    XpSource = ns.core.XpSource
    bus = ns.fakes.RecordingEventBus.new()
    clock = ns.fakes.FakeClock.new(0)
    tracker = build()
  end)

  it("starts with nothing open", function()
    assert.equal(PullPhase.IDLE, tracker:currentPhase())
    assert.is_nil(tracker:current())
  end)

  it("opens a pull when combat starts", function()
    bus:publish(EventTopic.COMBAT_STARTED, {})

    assert.equal(PullPhase.ACTIVE, tracker:currentPhase())
    assert.is_not_nil(tracker:current())
    assert.equal(1, tracker:currentGeneration())
  end)

  -- The whole of the reported defect, end to end: a fight the player never struck
  -- back in used to list nothing, so the plate showed a pull against no one and
  -- expected no experience from it.
  it("lists what is beating on you in a fight you never struck back in", function()
    bus:publish(EventTopic.COMBAT_STARTED, {})
    bus:publish(EventTopic.DAMAGE_TAKEN,
      { amount = 13, name = "Withered Green Keeper", guid = "Creature-0-1-1-1-15636-A" })
    bus:publish(EventTopic.DAMAGE_TAKEN,
      { amount = 16, name = "Withered Green Keeper", guid = "Creature-0-1-1-1-15636-B" })

    local pull = tracker:current()
    assert.equal(2, pull:engagedCount())
    assert.equal(2, pull.creatures["Withered Green Keeper"].engaged)
    assert.equal(29, pull.damageTaken)
  end)

  -- The prelude from the other side: an ambush lands its first blow before the
  -- client says you are in combat, and that blow is the only thing naming what
  -- started it.
  it("keeps the first blow of an ambush, which lands before combat opens", function()
    clock:advance(10)
    bus:publish(EventTopic.DAMAGE_TAKEN,
      { amount = 13, name = "Withered Green Keeper", guid = "Creature-0-1-1-1-15636-A" })
    clock:advance(1)
    bus:publish(EventTopic.COMBAT_STARTED, {})

    local pull = tracker:current()
    assert.equal(1, pull:engagedCount())
    assert.equal(13, pull.damageTaken)
    assert.equal(10, pull.startedAt, "the fight began when the first blow landed")
  end)

  -- What the player actually asked for after the first fix: it should not take a
  -- blow landing. A creature that swung and missed is in the fight.
  it("counts a creature that is fighting you before it has hurt you", function()
    bus:publish(EventTopic.COMBAT_STARTED, {})
    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Withered Green Keeper", guid = "Creature-0-1-1-1-15636-A" })
    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Withered Green Keeper", guid = "Creature-0-1-1-1-15636-B" })
    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Withered Green Keeper", guid = "Creature-0-1-1-1-15636-A" })

    local pull = tracker:current()
    assert.equal(2, pull:engagedCount(), "one per creature, however many lines it takes")
    assert.equal(0, pull.damageTaken, "and nothing has hurt anyone yet")
  end)

  -- The defect the whole nameplate path existed to answer, and could not: a
  -- creature fighting this character before the client says PLAYER_REGEN_DISABLED
  -- left the plate empty, because only that event opened a pull. Eight of the
  -- nine fights recorded on 2026-09-22 were opened by a combat log line.
  it("opens a pull for a creature fighting the player before the client agrees", function()
    clock:advance(10)

    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Starving Ghostclaw", guid = "Creature-0-1-1-1-16347-A" })

    local pull = tracker:current()
    assert.is_not_nil(pull)
    assert.equal(1, pull:engagedCount())
    assert.equal(10, pull.startedAt)
  end)

  -- The event that used to be the only opener arrives a moment later, and must
  -- not throw away the pull that is already running. It could not happen before:
  -- while a pull was ACTIVE the player was in combat by definition.
  it("does not restart the pull when combat is declared just after", function()
    clock:advance(10)
    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Starving Ghostclaw", guid = "Creature-0-1-1-1-16347-A" })
    clock:advance(2)
    bus:publish(EventTopic.COMBAT_STARTED, {})

    local pull = tracker:current()
    assert.equal(10, pull.startedAt)
    assert.equal(1, pull:engagedCount())
  end)

  it("counts the creature once, not once for opening and once for the replay", function()
    clock:advance(10)
    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Starving Ghostclaw", guid = "Creature-0-1-1-1-16347-A" })
    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Starving Ghostclaw", guid = "Creature-0-1-1-1-16347-A" })

    assert.equal(1, tracker:current():engagedCount())
  end)

  it("keeps an engagement that precedes combat, and backdates the pull to it", function()
    clock:advance(10)
    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Withered Green Keeper", guid = "Creature-0-1-1-1-15636-A" })
    clock:advance(1)
    bus:publish(EventTopic.COMBAT_STARTED, {})

    local pull = tracker:current()
    assert.equal(1, pull:engagedCount())
    assert.equal(10, pull.startedAt)
  end)

  it("records what lands while combat runs", function()
    bus:publish(EventTopic.COMBAT_STARTED, {})
    bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Miner", at = 1 })
    bus:publish(EventTopic.XP_ATTRIBUTED, gain(44))
    bus:publish(EventTopic.ABILITY_USED, { key = 1752, name = "Mind Blast" })
    bus:publish(EventTopic.DAMAGE_DEALT, { amount = 200 })
    bus:publish(EventTopic.DAMAGE_TAKEN, { amount = 30 })
    bus:publish(EventTopic.HEALING_RECEIVED, { amount = 12 })
    bus:publish(EventTopic.PLAYER_DIED, {})

    local pull = tracker:current()
    assert.equal(1, pull.kills)
    assert.equal(44, pull.xpTotal)
    assert.equal(1, pull.abilities[1752].count)
    assert.equal(200, pull.damageDealt)
    assert.equal(30, pull.damageTaken)
    assert.equal(12, pull.healingReceived)
    assert.equal(1, pull.deaths)
  end)

  it("drops everything while nothing is open", function()
    bus:publish(EventTopic.XP_ATTRIBUTED, gain(44))
    bus:publish(EventTopic.DAMAGE_DEALT, { amount = 200 })

    assert.is_nil(tracker:current())
  end)

  -- The other end of the settling window. The client opens combat when the target
  -- FIGHTS BACK, so the shot that started it is always early.
  describe("the prelude", function()
    it("takes the opener into the pull it opened", function()
      bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })
      clock:advance(0.4)
      bus:publish(EventTopic.DAMAGE_DEALT, { amount = 30, name = "Ether Fiend", guid = "guid-a" })
      clock:advance(0.3)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      local pull = tracker:current()
      assert.equal(1, pull.abilities[589].count, "the opening cast was dropped")
      assert.equal(30, pull.damageDealt)
      assert.equal(1, pull:engagedCount(), "the creature that was pulled should already be listed")
    end)

    it("backdates the pull to the shot that started it", function()
      bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })
      clock:advance(2)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.equal(2, tracker:current():duration(clock:now()),
        "the fight began when the player pulled, not when the server agreed")
    end)

    it("forgets anything older than its window", function()
      bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })
      clock:advance(30)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      local pull = tracker:current()
      assert.is_nil(pull.abilities[589], "a cast half a minute ago did not start this fight")
      assert.equal(0, pull:duration(clock:now()))
    end)

    it("never lets the buffer grow without bound", function()
      for _ = 1, 500 do
        bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })
        clock:advance(0.001)
        assert.is_true(#tracker.prelude <= 24, "the prelude grew to " .. #tracker.prelude)
      end
    end)

    it("does not replay the same opener into a second pull", function()
      -- Far enough past the close that the pull is genuinely over, not resumed:
      -- inside the resume window this is the SAME fight carrying on, and the
      -- opener it already holds is its own.
      tracker = build({ resumeSeconds = 1 })
      bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })
      bus:publish(EventTopic.COMBAT_STARTED, {})
      clock:advance(10)
      bus:publish(EventTopic.COMBAT_ENDED, {})
      clock:advance(10)
      tracker:tick(clock:now())
      clock:advance(5)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.equal(2, tracker:currentGeneration())
      assert.is_nil(tracker:current().abilities[589])
    end)

    it("buffers nothing at all when the player has the plate off", function()
      tracker = build({ enabled = function() return false end })

      bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })

      assert.equal(0, #tracker.prelude)
    end)
  end)

  -- The whole reason this module is not four lines. See PullPhase.
  describe("the settling window", function()
    before_each(function()
      tracker = build({ settleSeconds = 3 })
      bus:publish(EventTopic.COMBAT_STARTED, {})
      bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Miner", at = 1 })
      clock:advance(10)
      bus:publish(EventTopic.COMBAT_ENDED, {})
    end)

    it("does not close the pull when the client says combat is over", function()
      assert.equal(PullPhase.SETTLING, tracker:currentPhase())
    end)

    it("still takes the experience that was already in flight", function()
      bus:publish(EventTopic.XP_ATTRIBUTED, gain(44))

      assert.equal(44, tracker:current().xpTotal,
        "the last kill's experience arrives after combat ends and must not be lost")
    end)

    it("closes once the window has passed", function()
      clock:advance(3)

      assert.is_true(tracker:tick(clock:now()))
      assert.equal(PullPhase.CLOSED, tracker:currentPhase())
    end)

    it("does not close early", function()
      clock:advance(2.9)

      assert.is_false(tracker:tick(clock:now()))
      assert.equal(PullPhase.SETTLING, tracker:currentPhase())
    end)

    it("refuses anything that arrives after it closed", function()
      clock:advance(3)
      tracker:tick(clock:now())

      bus:publish(EventTopic.XP_ATTRIBUTED, gain(999))

      assert.equal(0, tracker:current().xpTotal,
        "a closed pull is a finished statement and must not move under the player")
    end)
  end)

  describe("a chain of pulls", function()
    it("continues the same pull when adds arrive inside the window", function()
      tracker = build({ settleSeconds = 3 })
      bus:publish(EventTopic.COMBAT_STARTED, {})
      bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Miner", at = 0 })
      clock:advance(8)
      bus:publish(EventTopic.COMBAT_ENDED, {})
      clock:advance(2)
      bus:publish(EventTopic.COMBAT_STARTED, {})
      bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Laborer", at = 11 })

      assert.equal(PullPhase.ACTIVE, tracker:currentPhase())
      assert.equal(1, tracker:currentGeneration(), "adds two seconds later are the same fight")
      assert.equal(2, tracker:current().kills)
    end)

    it("restarts the clock so the continued pull is not reported as ended", function()
      tracker = build({ settleSeconds = 3 })
      bus:publish(EventTopic.COMBAT_STARTED, {})
      clock:advance(8)
      bus:publish(EventTopic.COMBAT_ENDED, {})
      clock:advance(2)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.is_nil(tracker:current().endedAt)
      assert.equal(12, tracker:current():duration(12))
    end)

    it("opens a new pull when combat starts after the window closed", function()
      tracker = build({ settleSeconds = 3, resumeSeconds = 0 })
      bus:publish(EventTopic.COMBAT_STARTED, {})
      clock:advance(8)
      bus:publish(EventTopic.COMBAT_ENDED, {})
      clock:advance(4)
      tracker:tick(clock:now())
      clock:advance(1)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.equal(2, tracker:currentGeneration())
      assert.equal(0, tracker:current().kills)
    end)
  end)

  -- The settling window carried one step further: a pull stays resumable for as
  -- long as the plate that shows it is still on screen. Pulling the next thing
  -- while the last one fades IS chain pulling, and the counter should follow.
  describe("resuming a closed pull", function()
    local function closedPull(options)
      options = options or {}
      tracker = build({ settleSeconds = 1, resumeSeconds = options.resumeSeconds or 7 })
      bus:publish(EventTopic.COMBAT_STARTED, {})
      bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Miner", at = clock:now() })
      bus:publish(EventTopic.XP_ATTRIBUTED, gain(44))
      clock:advance(5)
      bus:publish(EventTopic.COMBAT_ENDED, {})
      clock:advance(2)
      tracker:tick(clock:now())
      assert.equal(PullPhase.CLOSED, tracker:currentPhase())
      return tracker:current()
    end

    it("carries the same pull on rather than starting over", function()
      closedPull()
      clock:advance(3)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.equal(PullPhase.ACTIVE, tracker:currentPhase())
      assert.equal(1, tracker:currentGeneration(), "a resumed pull is not a new one")
      assert.equal(44, tracker:current().xpTotal, "the counter kept what it had")
    end)

    it("keeps the chain running across the resume", function()
      closedPull()
      clock:advance(3)
      bus:publish(EventTopic.COMBAT_STARTED, {})
      bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Laborer", at = clock:now() })

      assert.equal(2, tracker:current().streak, "the combo should have carried")
      assert.equal(2, tracker:current().kills)
    end)

    it("starts the clock again instead of reporting the pull as ended", function()
      closedPull()
      clock:advance(3)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.is_nil(tracker:current().endedAt)
    end)

    it("does not move the start of a pull it resumed", function()
      local pull = closedPull()
      local startedAt = pull.startedAt
      bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })
      clock:advance(2)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.equal(startedAt, tracker:current().startedAt,
        "a resumed fight began when the first one did")
      assert.equal(1, tracker:current().abilities[589].count,
        "the add's opener still counts")
    end)

    it("starts a new pull once the plate would be gone", function()
      closedPull({ resumeSeconds = 7 })
      clock:advance(8)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.equal(2, tracker:currentGeneration())
      assert.equal(0, tracker:current().xpTotal)
    end)

    -- How long the plate stays is the player's (D89) and this window is the same
    -- number, so it arrives as a function and is asked for at the moment the
    -- question comes up. A tracker built with the old value would go on offering
    -- the old window until the interface was reloaded -- and this is the tracker
    -- that decides what counts as the same fight, so that would be a reload
    -- between changing a slider and the records agreeing with what is on screen.
    it("asks for the window every time rather than keeping the one it was built with", function()
      local window = 7
      tracker = build({ settleSeconds = 1, resumeSeconds = function() return window end })
      bus:publish(EventTopic.COMBAT_STARTED, {})
      bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Miner", at = clock:now() })
      bus:publish(EventTopic.XP_ATTRIBUTED, gain(44))
      clock:advance(5)
      bus:publish(EventTopic.COMBAT_ENDED, {})
      clock:advance(2)
      tracker:tick(clock:now())
      assert.equal(PullPhase.CLOSED, tracker:currentPhase())

      window = 1
      clock:advance(3)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.equal(2, tracker:currentGeneration(),
        "the tracker resumed on a window the player had already shortened")
      assert.equal(0, tracker:current().xpTotal)
    end)

    -- The other direction, and the one that says WHEN it is read: the pull was
    -- closed while the window was short, and what decides whether it can carry on
    -- is the window in force at the moment somebody pulls again.
    it("measures a pull that closed earlier against the window in force now", function()
      local window = 3
      tracker = build({ settleSeconds = 1, resumeSeconds = function() return window end })
      bus:publish(EventTopic.COMBAT_STARTED, {})
      bus:publish(EventTopic.XP_ATTRIBUTED, gain(44))
      clock:advance(5)
      bus:publish(EventTopic.COMBAT_ENDED, {})
      clock:advance(2)
      tracker:tick(clock:now())
      assert.equal(PullPhase.CLOSED, tracker:currentPhase())

      window = 20
      clock:advance(9)
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.equal(1, tracker:currentGeneration(), "nine seconds is inside the window now")
      assert.equal(44, tracker:current().xpTotal, "the counter kept what it had")
    end)

    -- A session with no views at all still has to answer the question, and the
    -- fallback is the value this file has always carried.
    it("falls back to its own window when the seam answers with nothing", function()
      tracker = build({ settleSeconds = 1, resumeSeconds = function() return nil end })

      assert.equal(7.2, tracker:resumeWindow())
    end)
  end)

  describe("the change flag", function()
    it("reports a change once and then stops", function()
      bus:publish(EventTopic.COMBAT_STARTED, {})

      assert.is_true(tracker:consumeChange())
      assert.is_false(tracker:consumeChange())
    end)

    it("reports a change for every event that moved a number", function()
      bus:publish(EventTopic.COMBAT_STARTED, {})
      tracker:consumeChange()

      bus:publish(EventTopic.DAMAGE_DEALT, { amount = 10 })
      assert.is_true(tracker:consumeChange())
    end)

    -- The property that keeps a plate on screen free: an event that changed
    -- nothing must not cost a redraw.
    it("stays quiet for an event that landed nowhere", function()
      bus:publish(EventTopic.DAMAGE_DEALT, { amount = 10 })

      assert.is_false(tracker:consumeChange())
    end)
  end)

  describe("when the player has it turned off", function()
    it("opens nothing at all", function()
      tracker = build({ enabled = function() return false end })

      bus:publish(EventTopic.COMBAT_STARTED, {})
      bus:publish(EventTopic.XP_ATTRIBUTED, gain(44))

      assert.equal(PullPhase.IDLE, tracker:currentPhase())
      assert.is_nil(tracker:current())
    end)

    it("reads the answer live, not once at construction", function()
      local on = false
      tracker = build({ enabled = function() return on end })

      bus:publish(EventTopic.COMBAT_STARTED, {})
      assert.is_nil(tracker:current())

      on = true
      bus:publish(EventTopic.COMBAT_STARTED, {})
      assert.is_not_nil(tracker:current())
    end)
  end)

  it("drops what is open when reset", function()
    bus:publish(EventTopic.COMBAT_STARTED, {})
    tracker:reset()

    assert.equal(PullPhase.IDLE, tracker:currentPhase())
    assert.is_nil(tracker:current())
  end)

  it("tolerates a combat log kill with no timestamp on the payload", function()
    bus:publish(EventTopic.COMBAT_STARTED, {})

    assert.has_no.errors(function()
      bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Miner" })
    end)
    assert.equal(1, tracker:current().kills)
  end)
  -- The plate rebuilds when the tracker says something changed, and every one of
  -- the ~30 lines the combat log writes about one creature used to say so. The
  -- pull is the one place that knows which of them was news; both ways of
  -- learning a creature is in the fight are repetitive by nature.
  it("asks for a redraw once per creature, not once per line about it", function()
    bus:publish(EventTopic.COMBAT_STARTED, {})
    assert.is_true(tracker:consumeChange())

    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Starving Ghostclaw", guid = "Creature-0-1-1-1-16347-A" })
    assert.is_true(tracker:consumeChange(), "the first one is news")

    -- Consumed between each, or the flag being reset would hide the difference
    -- and this would pass with or without the gate -- which it did, first try.
    for line = 2, 10 do
      bus:publish(EventTopic.ENEMY_ENGAGED,
        { name = "Starving Ghostclaw", guid = "Creature-0-1-1-1-16347-A" })
      assert.is_false(tracker:consumeChange(), "line " .. line .. " changed nothing")
    end

    assert.equal(1, tracker:current():engagedCount())
  end)

  it("still asks for one when a different creature joins", function()
    bus:publish(EventTopic.COMBAT_STARTED, {})
    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Starving Ghostclaw", guid = "Creature-0-1-1-1-16347-A" })
    tracker:consumeChange()

    bus:publish(EventTopic.ENEMY_ENGAGED,
      { name = "Starving Ghostclaw", guid = "Creature-0-1-1-1-16347-B" })

    assert.is_true(tracker:consumeChange())
    assert.equal(2, tracker:current():engagedCount())
  end)

end)
