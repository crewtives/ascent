-- The tracker is where a level record spends its life, so most of these cases are
-- about the addon not having been there: installed halfway through a level, not
-- running while three of them went by, logged out for a day, or watching a character
-- that cannot gain experience at all.
--
-- The rule they all test is the same one. The addon says what it observed and says
-- what it deduced, and never dresses the second up as the first.

describe("LevelTracker", function()
  local ns, clock, player, repository, bus, store, tracker
  local EventTopic, XpSource

  local function xpForLevel(level)
    return 400 + (level - 1) * 100
  end

  local function load()
    return AscentTest.loadWith("core/model/", "core/port/",
      "core/service/XpLedger.lua", "core/service/RecordStore.lua",
      "core/service/RetentionPolicy.lua", "core/service/LevelTracker.lua",
      "test/fakes/FakeClock.lua", "test/fakes/FakePlayerState.lua",
      "test/fakes/InMemoryRepository.lua", "test/fakes/RecordingEventBus.lua")
  end

  -- A fresh login over whatever the repository already holds. `now` is the monotonic
  -- clock at that moment: near zero after the client restarts, and carrying on from
  -- where it was after a /reload.
  local function login(now)
    clock = ns.fakes.FakeClock.new(now or 1000, clock and clock.epoch or 1700000000)
    bus = ns.fakes.RecordingEventBus.new()
    store = ns.core.RecordStore.new({ repository = repository }):load()
    tracker = ns.core.LevelTracker.new({
      bus = bus, clock = clock, playerState = player, store = store,
      xpForLevel = xpForLevel,
    })
    return tracker
  end

  -- Same as `login`, but wired with a fake logger double so a test can assert on
  -- which reconciliation branch fired without caring about the exact wording.
  local function loginWithLogger(now, logger)
    clock = ns.fakes.FakeClock.new(now or 1000, clock and clock.epoch or 1700000000)
    bus = ns.fakes.RecordingEventBus.new()
    store = ns.core.RecordStore.new({ repository = repository }):load()
    tracker = ns.core.LevelTracker.new({
      bus = bus, clock = clock, playerState = player, store = store,
      xpForLevel = xpForLevel, logger = logger,
    })
    return tracker
  end

  local function attribute(amount, source, fields)
    fields = fields or {}
    fields.amount = amount
    fields.source = source or XpSource.MOB_KILL
    fields.at = fields.at or clock:now()
    bus:publish(EventTopic.XP_ATTRIBUTED, { gain = ns.core.XpGain.new(fields) })
  end

  local function seedStored(stored)
    repository:setSchemaVersion(ns.core.SchemaVersion.CURRENT)
    repository:saveCurrentRecord(stored)
  end

  before_each(function()
    ns = load()
    EventTopic = ns.core.EventTopic
    XpSource = ns.core.XpSource
    clock = nil
    player = ns.fakes.FakePlayerState.new({ level = 5, xpForLevel = xpForLevel })
    repository = ns.fakes.InMemoryRepository.new()
    login(1000)
  end)

  describe("the level lifecycle", function()
    it("opens the level the character is on", function()
      tracker:start()

      local opened = tracker:current()
      assert.equal(5, opened.level)
      assert.equal(800, opened.xpRequired)
      assert.equal(1, bus:countOf(EventTopic.LEVEL_STARTED))
      assert.equal(opened, bus:lastOn(EventTopic.LEVEL_STARTED).record)
    end)

    it("closes the level that fills and opens the next", function()
      tracker:start()

      player:gain(800) -- the client levels first; the attribution follows
      attribute(800)

      local completed = bus:payloadsFor(EventTopic.LEVEL_COMPLETED)
      assert.equal(1, #completed)
      assert.equal(5, completed[1].record.level)
      assert.equal(800, completed[1].record.xpTotal)
      assert.equal(800, completed[1].record.xpRequired)
      assert.is_not_nil(completed[1].record.completedAt)

      assert.equal(6, tracker:current().level)
      assert.equal(900, tracker:current().xpRequired)
      assert.equal(0, tracker:current().xpTotal)
      assert.equal(2, bus:countOf(EventTopic.LEVEL_STARTED))
    end)

    it("splits a gain across the boundary, keeping its source on both sides", function()
      player:set("xp", 700)
      tracker:start()

      player:gain(250)
      attribute(250, XpSource.QUEST_TURNIN, { questId = 1234 })

      local closed = bus:lastOn(EventTopic.LEVEL_COMPLETED).record
      assert.equal(800, closed.xpTotal)
      assert.equal(100, closed:xpFrom(XpSource.QUEST_TURNIN))
      assert.equal(700, closed:xpFrom(XpSource.UNKNOWN))
      assert.is_true(closed:sourcesAddUp())

      assert.equal(150, tracker:current().xpTotal)
      assert.equal(150, tracker:current():xpFrom(XpSource.QUEST_TURNIN))
    end)

    it("keeps the closed level in the history", function()
      tracker:start()
      player:gain(800)
      attribute(800)

      assert.same({ 5 }, store:completedLevels())
      assert.equal(800, store:completed(5).xpTotal)
    end)

    it("announces every change to the record", function()
      tracker:start()
      attribute(44)
      bus:publish(EventTopic.KILL_UNREWARDED, { creature = ns.core.CreatureKey.unknown("Rat") })

      assert.equal(2, bus:countOf(EventTopic.RECORD_UPDATED))
      assert.equal(1, tracker:current().killsWithoutXp)
    end)
  end)

  describe("time on the level", function()
    it("does not count the hours the player was logged out", function()
      tracker:start()
      clock:advance(600)
      tracker:stop()

      clock:advance(86400) -- a day away, on a clock nobody is measuring with

      login(0) -- the client restarted, so its monotonic clock did too
      tracker:start()
      clock:advance(300)
      tracker:stop()

      assert.equal(900, store:current().playedSeconds)
    end)

    it("reports the time of the session in progress without waiting for logout", function()
      tracker:start()
      clock:advance(120)

      assert.equal(120, tracker:playedSeconds())
    end)

    -- A sitting, not a reload. The monotonic clock keeps running across /reload and
    -- starts again from near zero when the client does, which is the only signal
    -- available to tell the two apart.
    it("counts a new sitting when the client restarted, and not on a reload", function()
      tracker:start()
      assert.equal(1, tracker:current().sessions)
      clock:advance(600)
      tracker:stop()

      login(0)
      tracker:start()
      assert.equal(2, tracker:current().sessions)
      clock:advance(300)
      tracker:stop()

      login(clock:now() + 5)
      tracker:start()
      assert.equal(2, tracker:current().sessions)
    end)

    it("carries the level's experience across a reload instead of restarting it", function()
      tracker:start()
      attribute(350)
      tracker:stop()

      login(2000)
      tracker:start()

      assert.equal(350, tracker:current().xpTotal)
      assert.equal(350, tracker:current():xpFrom(XpSource.MOB_KILL))
    end)
  end)

  describe("the server's own figure for time on this level", function()
    it("corrects the record and keeps measuring from there", function()
      tracker:start()
      clock:advance(600)
      assert.is_false(tracker:current().timeAnchored)

      bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = 7200 })

      assert.equal(7200, tracker:current().playedSeconds)
      assert.is_true(tracker:current().timeAnchored)

      clock:advance(60)
      assert.equal(7260, tracker:playedSeconds())
    end)

    -- The level that was already half played when the addon was installed is the
    -- case this exists for: local measurement can only ever see the second half.
    it("gives a true answer for a level that began before the addon did", function()
      player:set("xp", 640)
      tracker:start()
      clock:advance(60)

      bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = 5400 })

      assert.equal(5400, tracker:current().playedSeconds)
    end)

    it("keeps measuring, marked as estimated, when no reference arrives", function()
      tracker:start()
      clock:advance(600)

      assert.equal(600, tracker:playedSeconds())
      assert.is_false(tracker:current().timeAnchored)
    end)

    it("ignores a reference that is not a time", function()
      tracker:start()
      bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = -1 })
      bus:publish(EventTopic.TIME_PLAYED_SYNCED, {})

      assert.is_false(tracker:current().timeAnchored)
    end)
  end)

  describe("meeting the character again", function()
    -- Covers the reload gap and the late start: the addon compares what it saved
    -- against what the character actually is, and the difference has to land
    -- somewhere for the level to keep adding up.
    it("imputes experience gained while it was not watching", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("xp", 500)
      login(1000)

      tracker:start()

      assert.equal(500, tracker:current().xpTotal)
      assert.equal(200, tracker:current():xpFrom(XpSource.UNKNOWN))
      assert.equal(300, tracker:current():xpFrom(XpSource.MOB_KILL))
      assert.is_true(tracker:current():sourcesAddUp())
      -- And says it did not watch it. This assertion used to read is_false, which
      -- was the whole defect: a gap the addon slept through arrived in UNKNOWN
      -- indistinguishable from experience it saw and could not classify, so the
      -- breakdown blamed itself for a failure it never had.
      assert.is_true(tracker:current().partial)
      assert.equal(200, tracker:current().seededXp)
    end)

    -- Same rule as the seed, at the other site that posts experience the addon did
    -- not watch arrive: the gap belongs to whatever group the character was in
    -- while the addon was off, which is nothing anyone can now say (D81).
    it("imputes the gap without claiming to know who shared it", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("xp", 500):set("sharedBy", 5)
      login(1000)

      tracker:start()

      local gains = tracker:current().gains
      assert.equal(1, #gains)
      assert.equal(200, gains[1].amount)
      assert.is_nil(gains[1].sharedBy)
    end)

    -- A record already carrying a seed adds to it rather than replacing it: both
    -- gaps are experience nobody watched, and they are the same kind of missing.
    it("adds a later gap to the seed it already carried", function()
      seedStored({
        level = 5, xpTotal = 300, xpRequired = 800, partial = true, seededXp = 120,
        xpBySource = { mob_kill = 180, unknown = 120 },
      })
      player:set("xp", 500)
      login(1000)

      tracker:start()

      assert.equal(320, tracker:current().seededXp)
      assert.equal(320, tracker:current():xpFrom(XpSource.UNKNOWN))
      assert.is_true(tracker:current():sourcesAddUp())
    end)

    -- A record written before the figure existed. The gap is real and the mark is
    -- deserved, but how its EXISTING unclassified experience divides is unknowable
    -- now, and putting a number on it would invent the split for everything that
    -- came before this login.
    it("declines to invent a split for a record that never kept the figure", function()
      seedStored({
        level = 5, xpTotal = 300, xpRequired = 800, partial = true,
        xpBySource = { mob_kill = 180, unknown = 120 },
      })
      player:set("xp", 500)
      login(1000)

      tracker:start()

      assert.is_true(tracker:current().partial)
      assert.is_nil(tracker:current().seededXp)
    end)

    -- The level it did not see finish is closed, and deliberately NOT topped up to a
    -- hundred percent. The addon did not watch that experience arrive.
    it("closes a level it did not see finish, without declaring it complete", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("level", 6)
      player:set("xpMax", 900)
      player:set("xp", 120)
      login(1000)

      tracker:start()

      local closed = store:completed(5)
      assert.is_true(closed.partial)
      assert.equal(300, closed.xpTotal)
      assert.is_true(closed.xpTotal < closed.xpRequired)

      assert.equal(6, tracker:current().level)
      assert.equal(120, tracker:current():xpFrom(XpSource.UNKNOWN))
      assert.is_true(tracker:current().partial)
    end)

    it("leaves a record for every level that went by unwatched", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("level", 8)
      player:set("xpMax", 1100)
      player:set("xp", 50)
      login(1000)

      tracker:start()

      assert.same({ 5, 6, 7 }, store:completedLevels())
      for _, level in ipairs({ 5, 6, 7 }) do
        assert.is_true(store:completed(level).partial,
          ("level %d was not marked partial"):format(level))
      end
      assert.equal(8, tracker:current().level)
      assert.equal(50, tracker:current().xpTotal)
    end)

    -- Without this seed the promise that the sources add up to the level total would
    -- be false from the addon's first minute of use.
    it("seeds a level it is meeting for the first time", function()
      player:set("xp", 640)

      tracker:start()

      assert.equal(640, tracker:current().xpTotal)
      assert.equal(640, tracker:current():xpFrom(XpSource.UNKNOWN))
      assert.is_true(tracker:current().partial)
      assert.is_true(tracker:current():sourcesAddUp())
    end)

    -- And says HOW MUCH it seeded, which is the half `partial` cannot express. Both
    -- the seed and a gain nobody could explain land in UNKNOWN, so without this
    -- figure a surface reading that bucket cannot tell experience the addon never
    -- watched from experience it watched and failed to attribute.
    it("records how much it seeded, not only that it did", function()
      player:set("xp", 640)

      tracker:start()

      assert.equal(640, tracker:current().seededXp)
    end)

    -- D81: the seed is experience earned at instants nobody watched, so it goes in
    -- with the group unknown even while the character stands in one right now.
    -- Stamping the present group on it is the reclassification the decision exists
    -- to prevent, and it would be invisible: a party of five at login would price
    -- the whole level as if every kill in it had been shared.
    it("seeds without claiming to know who shared it", function()
      player:set("xp", 640):set("sharedBy", 5)

      tracker:start()

      local gains = tracker:current().gains
      assert.equal(1, #gains)
      assert.equal(640, gains[1].amount)
      assert.is_nil(gains[1].sharedBy)
    end)

    it("records a seed of zero when it meets a level at its very first point", function()
      player:set("xp", 0)

      tracker:start()

      assert.is_true(tracker:current().partial)
      assert.equal(0, tracker:current().seededXp)
    end)

    it("starts clean when the stored record cannot be read", function()
      seedStored({ level = "five" })
      player:set("xp", 200)
      login(1000)

      tracker:start()

      assert.equal(5, tracker:current().level)
      assert.equal(200, tracker:current():xpFrom(XpSource.UNKNOWN))
      assert.is_true(store.discarded)
    end)
  end)

  describe("at the client's maximum level", function()
    before_each(function()
      player = ns.fakes.FakePlayerState.new({ level = 59, maxLevel = 60, xpForLevel = xpForLevel })
      repository = ns.fakes.InMemoryRepository.new()
      login(1000)
    end)

    it("closes the last level and opens nothing when the cap is reached in play", function()
      tracker:start()
      local required = tracker:current().xpRequired

      player:gain(required)
      attribute(required)

      assert.is_nil(tracker:current())
      assert.equal(required, store:completed(59).xpTotal)
      assert.equal(1, bus:countOf(EventTopic.LEVEL_COMPLETED))
      assert.equal(1, bus:countOf(EventTopic.LEVEL_STARTED))
    end)

    it("opens no record for a character that is already at the cap", function()
      seedStored({ level = 59, xpTotal = 400, xpRequired = 6200, xpBySource = { mob_kill = 400 } })
      player:set("level", 60)
      login(1000)

      tracker:start()

      assert.is_nil(tracker:current())
      assert.same({ 59 }, store:completedLevels())
    end)

    it("ignores experience afterwards without raising", function()
      player:set("level", 60)
      login(1000)
      tracker:start()

      attribute(500)
      bus:publish(EventTopic.KILL_UNREWARDED, { creature = ns.core.CreatureKey.unknown("Rat") })

      assert.is_nil(tracker:current())
      assert.equal(0, #bus.errors)
    end)

    it("keeps the history readable", function()
      seedStored({ level = 59, xpTotal = 400, xpRequired = 6200, xpBySource = { mob_kill = 400 } })
      player:set("level", 60)
      login(1000)
      tracker:start()

      assert.equal(400, store:completed(59):xpFrom(XpSource.MOB_KILL))
    end)
  end)

  -- Frozen, not finished. The two terminal states differ, and this is the half that
  -- is reversible: switching experience gain back on continues the same level.
  describe("with experience gain switched off", function()
    before_each(function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("isXpDisabled", true)
      player:set("xp", 500)
      login(1000)
    end)

    it("leaves the level in progress open, and does not reconcile it", function()
      tracker:start()

      assert.equal(5, tracker:current().level)
      assert.equal(300, tracker:current().xpTotal)
      assert.equal(0, tracker:current():xpFrom(XpSource.UNKNOWN))
      assert.is_false(tracker:current().partial)
    end)

    it("records nothing while it is off, and resumes when it is back on", function()
      tracker:start()
      attribute(500)
      assert.equal(300, tracker:current().xpTotal)

      player:set("isXpDisabled", false)
      attribute(400)

      assert.equal(700, tracker:current().xpTotal)
      assert.equal(5, tracker:current().level)
    end)

    it("does not raise", function()
      tracker:start()
      attribute(500)
      bus:publish(EventTopic.KILL_UNREWARDED, { creature = ns.core.CreatureKey.unknown("Rat") })

      assert.equal(0, #bus.errors)
    end)
  end)

  -- Every case below is a defect a review reproduced against the real modules, kept
  -- here so the next change has to break it deliberately.
  describe("regressions", function()
    -- At the cap the tracker lets go of the record and logout writes nothing, so the
    -- previous snapshot stayed in the current slot. Every later login found a record
    -- for a level whose history was already written, closed it again, and overwrote
    -- the real one with the stale half of it.
    it("does not overwrite the last level of a run on every login after the cap", function()
      player = ns.fakes.FakePlayerState.new({ level = 5, maxLevel = 6, xpForLevel = xpForLevel })
      repository = ns.fakes.InMemoryRepository.new()
      login(1000)
      tracker:start()

      player:gain(100)
      attribute(100)
      tracker:stop()

      login(50) -- a new client run
      tracker:start()
      player:gain(700) -- fills level 5, which is the last one
      attribute(700)
      tracker:stop()

      assert.is_nil(tracker:current())
      assert.equal(800, store:completed(5).xpTotal)
      assert.equal(2, #store:completed(5).gains)

      login(60)
      tracker:start()

      assert.equal(800, store:completed(5).xpTotal, "the finished level was overwritten")
      assert.equal(2, #store:completed(5).gains)
      assert.is_nil(store:current())
    end)

    -- There is no event for the instant gain comes back on, so the tracker finds out
    -- because something arrives to be recorded. It used to find out with its clock
    -- still stopped, and the whole session's time went uncounted.
    it("counts the play that follows experience being switched back on", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("isXpDisabled", true)
      login(1000)
      tracker:start()

      clock:advance(600) -- frozen, and this stretch stays uncounted
      player:set("isXpDisabled", false)
      clock:advance(3600)
      attribute(100)
      clock:advance(60)
      tracker:stop()

      assert.equal(60, store:current().playedSeconds)
    end)

    -- Freezing ran before reconciling, so a character several levels beyond its
    -- stored record held that old record open. Switching gain back on then wrote
    -- experience into a level it had already left.
    it("does not freeze a record for a level the character has already left", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("isXpDisabled", true)
      player:set("level", 8)
      player:set("xpMax", 1100)
      player:set("xp", 50)
      login(1000)

      tracker:start()

      assert.same({ 5, 6, 7 }, store:completedLevels())
      assert.is_nil(tracker:current(), "a level the character has left was left open")
    end)

    -- Attribution settles two windows after the experience arrives, so for those few
    -- seconds the client is on the next level while the record still open here is the
    -- previous one. The server's figure is for the client's level, not this record's.
    it("ignores a played-time reference for a level the record is not on", function()
      tracker:start()
      clock:advance(2760)

      player:gain(800) -- the client levels; the gain has not been attributed yet
      bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = 3 })

      assert.equal(2760, tracker:playedSeconds())
      assert.is_false(tracker:current().timeAnchored)
    end)

    -- The client is the authority for the level it is on and the compatibility table
    -- for every other one. With the same function behind both, nothing could tell
    -- which branch had answered.
    it("takes each level's requirement from the source that knows it", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("level", 8)
      player:set("xpMax", 1150) -- the client disagrees with the table, on purpose
      player:set("xp", 50)
      login(1000)

      tracker:start()

      assert.equal(900, store:completed(6).xpRequired)
      assert.equal(1000, store:completed(7).xpRequired)
      assert.equal(1150, tracker:current().xpRequired)
    end)

    -- Reconciling again in the same sitting -- which is how the adapter will pick the
    -- tracker back up when gain is switched on -- must not throw the session away or
    -- count it twice.
    it("can be started again without discarding the session", function()
      tracker:start()
      attribute(350)
      clock:advance(120)

      tracker:start()

      assert.equal(5, tracker:current().level)
      assert.equal(350, tracker:current().xpTotal)
      assert.equal(1, tracker:current().sessions)
      assert.equal(120, tracker:playedSeconds())
    end)

    -- XpLedger.post's own guard used to trust xpRequired blindly: a level opened
    -- right as the client's UnitXPMax read comes back 0 (a beat after a level
    -- transition, before it repopulates) got a REAL but non-positive requirement
    -- instead of "unknown", and the next gain crossing it threw inside onAttributed
    -- -- silently, since the event bus swallows it, and only once out loud (the
    -- warning is deduped) -- with nothing left to call publishUpdate() and mark
    -- the bar dirty. This is the "always shows an old number" bug from real play.
    it("never opens a level with a non-positive requirement", function()
      player:set("xpMax", 0) -- what the client reads for a beat right after a transition
      login(1000)

      tracker:start()

      assert.is_nil(tracker:current().xpRequired)

      -- Would have thrown inside XpLedger.post (xpRequired <= 0) before this fix.
      attribute(50)
      assert.equal(50, tracker:current().xpTotal)
    end)

    -- Without this, a record stuck at "unknown" -- the case above, or any level
    -- opened before the client's data was ready -- stayed stuck until the next
    -- reload/start(), because openLevel/resume only resolve xpRequired once, at
    -- open time.
    it("resolves an unknown requirement on the next gain instead of staying stuck until reload", function()
      player:set("xpMax", 0)
      login(1000)
      tracker:start()
      assert.is_nil(tracker:current().xpRequired)

      player:set("xpMax", 1000) -- the client has since repopulated it
      attribute(50)

      assert.equal(1000, tracker:current().xpRequired)
      assert.equal(50, tracker:current().xpTotal)
    end)
  end)

  -- A fake logger double, not the Logger port itself: LevelTracker only ever calls
  -- :debug on it, guarded by "self.logger ~= nil", so nothing here needs info/warn/
  -- isDebug to stand in for the real thing.
  describe("debug logging", function()
    local messages

    local function fakeLogger()
      messages = {}
      return {
        debug = function(_, msg) table.insert(messages, msg) end,
      }
    end

    local function loggedSomething(fragment)
      for _, msg in ipairs(messages) do
        if msg:find(fragment, 1, true) then
          return true
        end
      end
      return false
    end

    it("names the branch when resuming a stored record for the level in progress", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      loginWithLogger(1000, fakeLogger())

      tracker:start()

      assert.is_true(loggedSomething("resuming stored record"))
    end)

    it("names the branch for a fresh open with no stored record", function()
      loginWithLogger(1000, fakeLogger())

      tracker:start()

      assert.is_true(loggedSomething("fresh open, no stored record"))
    end)

    it("names the branch when frozen at the level cap", function()
      player = ns.fakes.FakePlayerState.new({ level = 60, maxLevel = 60, xpForLevel = xpForLevel })
      loginWithLogger(1000, fakeLogger())

      tracker:start()

      assert.is_true(loggedSomething("frozen, at level cap"))
    end)

    it("names the branch when frozen with experience gain disabled", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("isXpDisabled", true)
      loginWithLogger(1000, fakeLogger())

      tracker:start()

      assert.is_true(loggedSomething("frozen, experience gain disabled"))
    end)

    it("names the branch when closing levels skipped while not running, before reopening", function()
      seedStored({ level = 5, xpTotal = 300, xpRequired = 800, xpBySource = { mob_kill = 300 } })
      player:set("level", 8)
      player:set("xpMax", 1100)
      player:set("xp", 50)
      loginWithLogger(1000, fakeLogger())

      tracker:start()

      assert.is_true(loggedSomething("closing stored level 5"))
    end)

    it("logs a level opening, and separately that it was seeded as unknown", function()
      player:set("xp", 640)
      loginWithLogger(1000, fakeLogger())

      tracker:start()

      assert.is_true(loggedSomething("level opened: level=5"))
      assert.is_true(loggedSomething("level opened seeded: level=5 unknown=640"))
    end)

    it("logs a level closing", function()
      -- Seeded from live player state (openLevel's own honest-by-default partial
      -- mark, since a fresh login cannot tell "installed at 0 xp" from "installed
      -- mid-level"), so the level that closes here is still marked partial=true.
      loginWithLogger(1000, fakeLogger())
      tracker:start()

      player:gain(800)
      attribute(800)

      assert.is_true(loggedSomething("level closed: level=5 partial=true"))
    end)

    it("logs the played-time reference being applied, and being ignored for a level the record has left", function()
      loginWithLogger(1000, fakeLogger())
      tracker:start()

      bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = 7200 })
      assert.is_true(loggedSomething("time anchor applied"))

      messages = {}
      player:gain(800) -- the client levels; attribution has not settled yet
      bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = 3 })
      assert.is_true(loggedSomething("time anchor ignored"))
    end)

    -- The default every existing test in this file already uses: logging is entirely
    -- optional, and nothing above requires a logger to behave correctly.
    it("does not error and behaves the same when no logger is given", function()
      tracker:start()
      attribute(350)
      bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = 500 })

      assert.equal(5, tracker:current().level)
      assert.equal(0, #bus.errors)
    end)
  end)

  describe("construction", function()
    it("insists on everything it cannot work without", function()
      for _, missing in ipairs({ "bus", "clock", "playerState", "store" }) do
        local options = { bus = bus, clock = clock, playerState = player, store = store }
        options[missing] = nil
        assert.has_error(function() return ns.core.LevelTracker.new(options) end, nil,
          "constructed without a " .. missing)
      end
    end)
  end)
end)
