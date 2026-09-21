-- The denominator of every per-place rate. What makes this collector worth its own
-- file is the case nothing else records: a place that paid no experience at all
-- still cost the level its minutes, and a breakdown that left it out would flatter
-- every place that did pay.

describe("PlaceTimeCollector", function()
  local ns, collector, record, clock, EventTopic

  -- The three values the player-state port answers with, in its order. Written out
  -- rather than read off PlaceContext because they are the wire, and a test that
  -- spells them is one that fails if the persisted vocabulary is renamed.
  local FOREST = { "world", 1429, "Elwynn Forest" }
  local CHASM = { "dungeon", 389, "Ragefire Chasm" }

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "core/service/PlaceTimeCollector.lua", "test/fakes/FakeClock.lua")
    EventTopic = ns.core.EventTopic
    clock = ns.fakes.FakeClock.new(0)
    collector = ns.core.PlaceTimeCollector.new({ clock = clock })
    record = ns.core.LevelRecord.new(5, 0)
  end)

  local function observe(place)
    collector:observe(record, place[1], place[2], place[3])
  end

  local function secondsAt(id)
    local entry = record.places[id]
    return entry and entry.seconds or 0
  end

  it("accumulates the time spent in a place across ticks", function()
    observe(FOREST)
    clock:advance(10)
    observe(FOREST)
    clock:advance(5)
    observe(FOREST)

    assert.equal(15, secondsAt("world:1429"))
  end)

  it("credits each stretch to the place it was spent in", function()
    observe(FOREST)
    clock:advance(30)
    observe(CHASM)
    clock:advance(120)
    observe(CHASM)

    assert.equal(30, secondsAt("world:1429"))
    assert.equal(120, secondsAt("dungeon:389"))
  end)

  -- The whole reason this collector exists. The ledger only ever creates an entry
  -- for a place that paid something.
  it("records a place that never paid a single point of experience", function()
    observe(FOREST)
    clock:advance(600)
    observe(CHASM)

    local entry = record.places["world:1429"]
    assert.equal(600, entry.seconds)
    assert.equal(0, entry.xpTotal)
    assert.equal("Elwynn Forest", entry.key.name)
  end)

  it("files time the client could not place in the reserved entry", function()
    observe({ nil, nil, nil })
    clock:advance(12)
    observe({ nil, nil, nil })

    assert.equal(12, secondsAt("unknown:?"))
  end)

  -- 6.8, for time as well as for experience: a level-up in the middle of a long
  -- stay fires nothing here, so the stretch has to be credited as it passes rather
  -- than when the character finally moves.
  it("credits a stretch that crosses a level-up to the level it happened in", function()
    observe(CHASM)
    clock:advance(60)
    observe(CHASM)

    local nextRecord = ns.core.LevelRecord.new(6, 0)
    clock:advance(40)
    collector:observe(nextRecord, CHASM[1], CHASM[2], CHASM[3])

    assert.equal(60, secondsAt("dungeon:389"))
    assert.equal(40, nextRecord.places["dungeon:389"].seconds)
  end)

  describe("a session that pauses", function()
    it("does not count the hours the player was logged out", function()
      observe(FOREST)
      clock:advance(30)
      collector:collect(record, {}, EventTopic.SESSION_ENDED)

      clock:advance(36000) -- logged out overnight
      collector:collect(record, {}, EventTopic.SESSION_STARTED)
      clock:advance(10)
      observe(FOREST)

      assert.equal(40, secondsAt("world:1429"))
    end)

    -- The gap is ABANDONED, not carried. `record` is nil for as long as
    -- experience gain is switched off, and the session topics do not fire in that
    -- state either -- so a standing mark meant the first tick after recording
    -- resumed credited hours to whichever place the character left off in.
    it("does not credit a stretch where nothing was being recorded", function()
      observe(FOREST)
      clock:advance(30)
      observe(FOREST)

      collector:observe(nil, FOREST[1], FOREST[2], FOREST[3]) -- experience gain switched off
      clock:advance(7200)                                     -- two hours elsewhere
      observe(CHASM)
      clock:advance(60)
      observe(CHASM)

      assert.equal(30, secondsAt("world:1429"))
      assert.equal(60, secondsAt("dungeon:389"))
    end)

    it("ignores a tick while the session is paused", function()
      observe(FOREST)
      collector:collect(record, {}, EventTopic.SESSION_ENDED)

      clock:advance(100)
      observe(FOREST)

      assert.equal(0, secondsAt("world:1429"))
    end)
  end)

  -- Sampled five times a second for the whole of a levelling run, so what it does
  -- on a tick where nothing changed is the only cost that matters.
  describe("what a tick costs", function()
    it("builds no new key while the character has not moved", function()
      observe(FOREST)
      local key = collector.key

      -- 0.25 rather than the ticker's own 0.2: exact in binary, so the assertion
      -- below is about the key and not about floating point.
      for _ = 1, 40 do
        clock:advance(0.25)
        observe(FOREST)
      end

      assert.equal(key, collector.key)
      assert.equal(10, secondsAt("world:1429"))
    end)

    it("touches neither the clock nor the record with no level open", function()
      local reads = 0
      local counting = setmetatable({}, { __index = function(_, name)
        if name == "now" then
          return function() reads = reads + 1 return 0 end
        end
        return function() return 0 end
      end })
      local idle = ns.core.PlaceTimeCollector.new({ clock = ns.fakes.FakeClock.new(0) })
      idle.clock = counting

      idle:observe(nil, FOREST[1], FOREST[2], FOREST[3])

      assert.equal(0, reads)
    end)

    -- Caching the key alone still paid for a string.format and a tostring on every
    -- tick, because placeEntry keys its map by key:id(). Five times a second for a
    -- whole session, for a character standing still.
    it("does not look the entry up again while the character has not moved", function()
      observe(FOREST)
      local lookups = 0
      local realPlaceEntry = record.placeEntry
      record.placeEntry = function(self, key)
        lookups = lookups + 1
        return realPlaceEntry(self, key)
      end

      for _ = 1, 20 do
        clock:advance(0.25)
        observe(FOREST)
      end
      record.placeEntry = realPlaceEntry

      -- One, on the first tick that credits this place, and none for the other
      -- nineteen. Not zero: the entry is looked up when the place becomes the
      -- current one, which is exactly when the cache is allowed to miss.
      assert.equal(1, lookups)
      assert.equal(5, secondsAt("world:1429"))
    end)

    it("adds no entry to a level where the place has not changed", function()
      observe(FOREST)
      clock:advance(1)
      observe(FOREST)

      local count = 0
      for _ in pairs(record.places) do
        count = count + 1
      end
      assert.equal(1, count)
    end)
  end)

  -- A zone first sampled during a loading screen answers with no name and gets one
  -- a tick or two later. The key used to be rebuilt only on a change of context or
  -- area, so that whole stay stayed nameless and the panel reported hours spent
  -- "somewhere the client could not name" for a zone it names perfectly well.
  describe("a name that arrives after the place does", function()
    local NAMELESS_FOREST = { "world", 1429, nil }

    it("adopts it without moving the time to a different entry", function()
      observe(NAMELESS_FOREST)
      clock:advance(60)
      observe(FOREST)
      clock:advance(30)
      observe(FOREST)

      assert.equal(90, secondsAt("world:1429"))
      assert.equal("Elwynn Forest", record.places["world:1429"].key.name)
    end)

    it("keeps the name it already had when a later tick comes back nameless", function()
      observe(FOREST)
      clock:advance(10)
      observe(NAMELESS_FOREST)

      assert.equal("Elwynn Forest", record.places["world:1429"].key.name)
    end)

    -- The reserved bucket has no room for a name, and PlaceKey hands back the same
    -- nameless one whatever it is told, so a nameless somewhere reporting zone text
    -- must not rebuild the key on every tick.
    it("does not rebuild the key for a place the client could not identify", function()
      collector:observe(record, nil, nil, nil)
      local first = collector.key
      clock:advance(5)
      collector:observe(record, nil, nil, "Some Zone")

      assert.equal(first, collector.key)
    end)
  end)
end)
