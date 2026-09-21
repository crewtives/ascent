-- The one guarantee the addon exists to make: whatever happened, the experience
-- attributed to all the sources of a level adds up to exactly the experience that
-- level held. Every other test here pins down a mechanism; this one drives the
-- whole chain -- classifiers, window, correlator, ledger -- with a random sequence
-- of the awkward cases and asserts only that.
--
-- Since the level also records WHERE it was earned, the same run asserts the second
-- dimension against the first: the places add up to the same number as the sources,
-- through the same level-ups, duplicate announcements and mid-run data loss. Two
-- dimensions over one set of gains are only worth having if they can never disagree.
--
-- The generator is a Park-Miller LCG rather than math.random, seeded by a constant
-- printed with every failure, so a run that breaks can be replayed exactly.

describe("the hundred percent invariant", function()
  local SEED = 20260914
  local STEPS = 200

  local CREATURES = { "Kobold Miner", "Riverpaw Runt", "Young Wolf", "Defias Thug" }

  local function newRandom(seed)
    local state = seed % 2147483647
    if state <= 0 then
      state = state + 2147483646
    end
    -- 16807 * 2147483646 stays well inside the range doubles represent exactly, so
    -- this is the same sequence on any Lua that runs the suite.
    return function(n)
      state = (16807 * state) % 2147483647
      return (state % n) + 1
    end
  end

  local function xpForLevel(level)
    return 400 + (level - 1) * 100
  end

  it("holds through kills, quests, duplicate announcements, level-ups and a reset", function()
    local ns = AscentTest.loadWith("core/model/",
      "core/port/Port.lua", "core/port/PlayerState.lua", "core/port/EventBus.lua",
      "core/registry/ClassifierRegistry.lua", "core/registry/XpClassifiers.lua",
      "core/service/KillCorrelator.lua", "core/service/XpAttribution.lua",
      "core/service/XpLedger.lua",
      "test/fakes/FakePlayerState.lua", "test/fakes/RecordingEventBus.lua")

    local EventTopic = ns.core.EventTopic
    local XpHintKind = ns.core.XpHintKind
    local XpSource = ns.core.XpSource
    local XpGain = ns.core.XpGain
    local XpLedger = ns.core.XpLedger
    local LevelRecord = ns.core.LevelRecord

    local random = newRandom(SEED)
    local bus = ns.fakes.RecordingEventBus.new()
    local player = ns.fakes.FakePlayerState.new({ level = 5, xpForLevel = xpForLevel })

    local service = ns.core.XpAttribution.new({
      bus = bus,
      registry = ns.core.XpClassifiers.registerAll(ns.core.ClassifierRegistry.new()),
      correlator = ns.core.KillCorrelator.new(),
    })

    -- The smallest thing that can stand in for the level tracker: it opens the next
    -- level when a gain fills this one, and counts a kill that paid nothing.
    local closed = {}
    local current = LevelRecord.new(player:level(), 0)
    current.xpRequired = player:xpMax()

    local function nextLevel(filled)
      closed[#closed + 1] = filled
      local opened = LevelRecord.new(filled.level + 1, 0)
      opened.xpRequired = xpForLevel(filled.level + 1)
      return opened
    end

    bus:subscribe(EventTopic.XP_ATTRIBUTED, function(payload)
      current = XpLedger.post(current, payload.gain, nextLevel, payload.place)
    end)
    bus:subscribe(EventTopic.KILL_UNREWARDED, function()
      XpLedger.countUnrewardedKill(current)
    end)

    local now = 100.0
    local function advance(seconds)
      now = now + seconds
    end

    -- Somewhere, somewhere else, and nowhere the client could name: the third is
    -- not decoration, it is the state a portal or a loading screen leaves behind.
    local PlaceKey = ns.core.PlaceKey
    local PlaceContext = ns.core.PlaceContext
    local PLACES = {
      PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"),
      PlaceKey.new(PlaceContext.WORLD, 1433, "Westfall"),
      PlaceKey.new(PlaceContext.DUNGEON, 389, "Ragefire Chasm"),
      PlaceKey.unknown(),
    }

    local function grant(amount)
      player:gain(amount)
      bus:publish(EventTopic.XP_DELTA_OBSERVED,
        { amount = amount, at = now, place = PLACES[random(#PLACES)] })
    end

    -- Half the time the announcement precedes the experience and half the time it
    -- follows, because which order the client uses is exactly what nobody knows.
    local function announce(amount, hints)
      if random(2) == 1 then
        hints()
        grant(amount)
      else
        grant(amount)
        advance(0.05)
        hints()
      end
    end

    local function creatureDied(name)
      bus:publish(EventTopic.CREATURE_DIED, {
        name = name, at = now, npcId = 5640 + random(3), level = random(9),
      })
    end

    local function step()
      local roll = random(100)

      if roll <= 45 then
        local amount = random(60) + 10
        local name = CREATURES[random(#CREATURES)]
        if random(4) > 1 then
          creatureDied(name)
        end
        announce(amount, function()
          local hint = { kind = XpHintKind.KILL_MESSAGE, creatureName = name, amount = amount, at = now }
          if random(3) == 1 then
            hint.restedRaw = math.floor(amount / 2)
          end
          bus:publish(EventTopic.XP_HINT_RECEIVED, hint)
        end)

      elseif roll <= 72 then
        local amount = random(400) + 100
        local questId = random(500)
        announce(amount, function()
          -- Quest experience is announced twice for certain, and sometimes the
          -- system echo lands as well: three claims on one gain.
          bus:publish(EventTopic.XP_HINT_RECEIVED,
            { kind = XpHintKind.QUEST_TURNED_IN, questId = questId, amount = amount, at = now })
          bus:publish(EventTopic.XP_HINT_RECEIVED,
            { kind = XpHintKind.ANONYMOUS_MESSAGE, amount = amount, at = now })
          if random(2) == 1 then
            bus:publish(EventTopic.XP_HINT_RECEIVED,
              { kind = XpHintKind.QUEST_MESSAGE, amount = amount, at = now })
          end
        end)

      elseif roll <= 82 then
        local amount = random(80) + 20
        announce(amount, function()
          bus:publish(EventTopic.XP_HINT_RECEIVED,
            { kind = XpHintKind.ZONE_DISCOVERED, zoneName = "Zone " .. random(20), amount = amount, at = now })
        end)

      elseif roll <= 92 then
        -- Experience with nothing to explain it: a reload, a missed message, a
        -- channel this version does not parse.
        grant(random(50) + 5)

      else
        -- A creature that paid nothing at all, which the client announces by saying
        -- nothing at all.
        creatureDied(CREATURES[random(#CREATURES)])
      end

      -- Mostly long enough for the window to close, sometimes not, so that the
      -- hints of one event have to be told apart from the next event's delta.
      if random(4) == 1 then
        advance(0.2)
      else
        advance(2.0)
      end
    end

    -- Data lost mid-run: the record is gone and what the character already has is
    -- seeded as unclassified, which is the only way the sources can still add up.
    local function reseed()
      service:settle(now + 5)
      advance(5)
      current = LevelRecord.new(player:level(), 0)
      current.xpRequired = player:xpMax()
      current.partial = true
      if player:xp() > 0 then
        XpLedger.post(current,
          XpGain.new({ amount = player:xp(), source = XpSource.UNKNOWN, at = now }))
      end
    end

    local resetAt = random(STEPS - 20) + 10
    for index = 1, STEPS do
      if index == resetAt then
        reseed()
      end
      step()
    end
    service:settle(now + 10)

    local context = (" (seed %d, reset at step %d)"):format(SEED, resetAt)

    assert.is_true(player:level() < player:maxLevel(),
      "the run reached the level cap, so it stopped exercising level-ups" .. context)
    assert.is_true(#closed >= 3, "the run never crossed a level" .. context)

    for _, record in ipairs(closed) do
      assert.is_true(record:sourcesAddUp(),
        ("level %d: sources total %d but the level held %d%s")
          :format(record.level, record:sumOfSources(), record.xpTotal, context))
      assert.equal(record.xpRequired, record.xpTotal,
        ("level %d did not close at a hundred percent%s"):format(record.level, context))
      assert.equal(record:sumOfSources(), record:sumOfPlaces(),
        ("level %d: places total %d but the sources total %d%s")
          :format(record.level, record:sumOfPlaces(), record:sumOfSources(), context))
    end

    assert.is_true(current:sourcesAddUp(),
      ("open level %d: sources total %d but the level held %d%s")
        :format(current.level, current:sumOfSources(), current.xpTotal, context))
    assert.equal(player:xp(), current.xpTotal,
      ("open level %d holds %d but the character has %d%s")
        :format(current.level, current.xpTotal, player:xp(), context))
    assert.equal(current:sumOfSources(), current:sumOfPlaces(),
      ("open level %d: places total %d but the sources total %d%s")
        :format(current.level, current:sumOfPlaces(), current:sumOfSources(), context))
  end)

  -- Task 1.4's own words are "hasta los modificadores del registro del nivel", and
  -- the suite had no test that went that far on ANY channel: every modifier test
  -- stopped at the gain, and the ledger's own spec posts a gain built by hand. So
  -- this drives the same chain the invariant above does, and follows one group kill
  -- all the way into xpByModifier -- announced only on the anonymous line, which is
  -- the channel that used to lose it.
  it("carries a group bonus announced without a creature name into the level record", function()
    local ns = AscentTest.loadWith("core/model/",
      "core/port/Port.lua", "core/port/PlayerState.lua", "core/port/EventBus.lua",
      "core/registry/ClassifierRegistry.lua", "core/registry/XpClassifiers.lua",
      "core/service/KillCorrelator.lua", "core/service/XpAttribution.lua",
      "core/service/XpLedger.lua",
      "test/fakes/FakePlayerState.lua", "test/fakes/RecordingEventBus.lua")

    local EventTopic = ns.core.EventTopic
    local XpHintKind = ns.core.XpHintKind
    local XpModifier = ns.core.XpModifier
    local LevelRecord = ns.core.LevelRecord

    local bus = ns.fakes.RecordingEventBus.new()
    local service = ns.core.XpAttribution.new({
      bus = bus,
      registry = ns.core.XpClassifiers.registerAll(ns.core.ClassifierRegistry.new()),
      correlator = ns.core.KillCorrelator.new(),
    })

    local record = LevelRecord.new(5, 0)
    record.xpRequired = 4000
    bus:subscribe(EventTopic.XP_ATTRIBUTED, function(payload)
      record = ns.core.XpLedger.post(record, payload.gain, function() end, payload.place)
    end)

    -- Exactly what the client sends for a group kill it did not name: one
    -- anonymous line carrying the parenthetical, and the experience.
    bus:publish(EventTopic.XP_HINT_RECEIVED,
      { kind = XpHintKind.ANONYMOUS_MESSAGE, amount = 120, at = 100.0, groupBonus = 18 })
    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = 120, at = 100.05 })
    service:settle(200.0)

    assert.equal(120, record.xpTotal)
    assert.equal(18, record:xpFromModifier(XpModifier.GROUP_BONUS),
      "the group bonus never reached the level record")
    -- D41: a modifier annotates a gain, it is never added to it.
    assert.is_true(record:sourcesAddUp())
  end)
end)
