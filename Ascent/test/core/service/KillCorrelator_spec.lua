-- Matches an experience hint, which only names the creature, to the death that
-- gives its type and level: the client does not link the two. Most cases here
-- are the ones where the match is not clean, the common case in the open world.

describe("KillCorrelator", function()
  local ns, KillCorrelator, correlator

  local function death(name, at, npcId, level)
    return correlator:recordDeath({ name = name, at = at, npcId = npcId, level = level })
  end

  before_each(function()
    ns = AscentTest.loadDomain(
      "core/model/Guard.lua", "core/model/CreatureKey.lua", "core/service/KillCorrelator.lua")
    KillCorrelator = ns.core.KillCorrelator
    correlator = KillCorrelator.new({ window = 1.5 })
  end)

  describe("matching a hint to a death", function()
    it("resolves the type and the level of the creature that died", function()
      death("Kobold Miner", 10.0, 5644, 6)

      local key = correlator:resolve("Kobold Miner", 10.1)

      assert.equal(5644, key.npcId)
      assert.equal(6, key.level)
      assert.is_true(key:isFullyKnown())
    end)

    it("matches a death that arrived after the hint", function()
      death("Kobold Miner", 10.4, 5644, 6)

      assert.equal(5644, correlator:resolve("Kobold Miner", 10.0).npcId)
    end)

    it("matches a death that arrived before the hint", function()
      death("Kobold Miner", 10.0, 5644, 6)

      assert.equal(5644, correlator:resolve("Kobold Miner", 10.4).npcId)
    end)

    it("ignores a death outside the window", function()
      death("Kobold Miner", 10.0, 5644, 6)

      local key = correlator:resolve("Kobold Miner", 12.0)

      assert.is_false(key:hasKnownType())
    end)

    it("ignores a death of a different creature", function()
      death("Kobold Miner", 10.0, 5644, 6)

      assert.is_false(correlator:resolve("Riverpaw Runt", 10.1):hasKnownType())
    end)

    it("does not mind the client spelling the name with different spacing or case", function()
      death("Kobold Miner", 10.0, 5644, 6)

      assert.equal(5644, correlator:resolve(" kobold miner ", 10.1).npcId)
    end)
  end)

  -- Ambiguous by construction when several creatures of a name die together. The
  -- error is accepted and confined to attribution by type; one death must never
  -- pay for two hints.
  describe("the same name twice", function()
    it("claims the oldest unmatched death first, and never claims one twice", function()
      death("Kobold Miner", 10.0, 5644, 6)
      death("Kobold Miner", 10.2, 5644, 7)

      local first = correlator:resolve("Kobold Miner", 10.1)
      local second = correlator:resolve("Kobold Miner", 10.3)

      assert.equal(6, first.level)
      assert.equal(7, second.level)
    end)

    it("runs out of deaths rather than reusing one", function()
      death("Kobold Miner", 10.0, 5644, 6)

      correlator:resolve("Kobold Miner", 10.1)
      local second = correlator:resolve("Kobold Miner", 10.2)

      assert.is_false(second:hasKnownType())
    end)
  end)

  -- The join enriches; it never decides whether experience is recorded.
  describe("a hint with no death to match", function()
    it("still resolves, to a key that admits both halves are unknown", function()
      local key = correlator:resolve("Kobold Miner", 10.0)

      assert.is_false(key:hasKnownType())
      assert.is_false(key:hasKnownLevel())
      assert.equal("Kobold Miner", key.name)
      assert.equal("?:?", key:id())
    end)

    it("counts itself as uncorrelated", function()
      correlator:resolve("Kobold Miner", 10.0)

      assert.equal(1, correlator:diagnostics().unmatchedHints)
    end)
  end)

  describe("a death with no hint", function()
    it("comes back from prune once its retention has run out", function()
      death("Young Wolf", 10.0, 299, 3)

      assert.same({}, correlator:prune(15.0))

      local expired = correlator:prune(17.0)
      assert.equal(1, #expired)
      assert.equal("Young Wolf", expired[1].name)
      assert.equal(0, correlator:pending())
    end)

    -- Retention is three windows: the hint claiming a death can arrive a window
    -- late, the experience paying for that hint a window after it, and the
    -- attribution settles a window after that. Evicting at the matching window
    -- would report a kill worth 44 experience as one that paid nothing.
    it("outlives the window it can be matched in, by a wide margin", function()
      assert.equal(correlator.window * 4, correlator.retention)

      death("Kobold Miner", 10.0, 5644, 6)
      correlator:prune(10.0 + correlator.window * 4)

      assert.equal(1, correlator:pending())
      assert.equal(5644, correlator:resolve("Kobold Miner", 11.4).npcId)
    end)

    it("does not come back once a hint has claimed it", function()
      death("Young Wolf", 10.0, 299, 3)
      correlator:resolve("Young Wolf", 10.1)

      assert.same({}, correlator:prune(17.0))
    end)

    it("comes back only once", function()
      death("Young Wolf", 10.0, 299, 3)

      assert.equal(1, #correlator:prune(17.0))
      assert.equal(0, #correlator:prune(18.0))
    end)
  end)

  describe("a death whose level nobody could read", function()
    it("keeps the type and says the level is unknown", function()
      death("Kobold Miner", 10.0, 5644, nil)

      local key = correlator:resolve("Kobold Miner", 10.1)

      assert.is_true(key:hasKnownType())
      assert.is_false(key:hasKnownLevel())
      assert.equal("5644:?", key:id())
    end)
  end)

  describe("the buffer", function()
    it("keeps at most its capacity and counts what it had to drop", function()
      correlator = KillCorrelator.new({ window = 1.5, capacity = 3 })
      for index = 1, 5 do
        death("Kobold Miner", 10.0 + index * 0.01, 5644, 6)
      end

      assert.equal(3, correlator:pending())
      assert.equal(2, correlator:diagnostics().droppedDeaths)
    end)

    -- Dropped is not the same as unpaid: the hint for that death may simply not have
    -- arrived yet, and reporting it as an unproductive kill would be a guess.
    it("does not report a dropped death as one that paid nothing", function()
      correlator = KillCorrelator.new({ window = 1.5, capacity = 1 })
      death("Kobold Miner", 10.0, 5644, 6)
      death("Kobold Miner", 10.1, 5644, 6)

      assert.equal(0, correlator:diagnostics().expiredDeaths)
    end)
  end)

  describe("validation", function()
    it("insists on the name, because it is the only join available", function()
      assert.has_error(function() correlator:recordDeath({ at = 10, npcId = 5644 }) end)
      assert.has_error(function() correlator:recordDeath({ name = "", at = 10 }) end)
    end)

    it("insists on the instant", function()
      assert.has_error(function() correlator:recordDeath({ name = "Kobold Miner" }) end)
    end)

    it("refuses nonsense identifiers rather than storing them", function()
      assert.has_error(function()
        correlator:recordDeath({ name = "Kobold Miner", at = 10, npcId = -1 })
      end)
      assert.has_error(function()
        correlator:recordDeath({ name = "Kobold Miner", at = 10, level = 0 })
      end)
    end)
  end)

  -- Live tracing on top of the diagnostics() counters: which death matched which
  -- hint, and why an ambiguous match went the way it did. Optional, like every
  -- logger in this addon.
  describe("debug logging (optional)", function()
    local function fakeLogger()
      local messages = {}
      return { debug = function(_, message) messages[#messages + 1] = message end }, messages
    end

    it("never requires a logger, and never errors without one", function()
      assert.has_no.errors(function()
        correlator = KillCorrelator.new({ window = 1.5 })
        death("Kobold Miner", 10.0, 5644, 6)
        correlator:resolve("Kobold Miner", 10.1)
        correlator:resolve("Riverpaw Runt", 10.1)
        correlator:prune(20.0)
      end)
    end)

    it("logs a death as it is recorded", function()
      local logger, messages = fakeLogger()
      correlator = KillCorrelator.new({ window = 1.5, logger = logger })

      death("Kobold Miner", 10.0, 5644, 6)

      assert.equal(1, #messages)
      assert.is_not_nil(messages[1]:find("Kobold Miner", 1, true))
    end)

    it("logs a dropped death and whether it had been matched", function()
      local logger, messages = fakeLogger()
      correlator = KillCorrelator.new({ window = 1.5, capacity = 1, logger = logger })

      death("Kobold Miner", 10.0, 5644, 6)
      correlator:resolve("Kobold Miner", 10.0)
      death("Riverpaw Runt", 10.1, 123, 2)

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("matched=true", 1, true))
    end)

    it("logs a hint resolving to the death it matched", function()
      local logger, messages = fakeLogger()
      correlator = KillCorrelator.new({ window = 1.5, logger = logger })
      death("Kobold Miner", 10.0, 5644, 6)
      for i = #messages, 1, -1 do messages[i] = nil end

      correlator:resolve("Kobold Miner", 10.1)

      assert.equal(1, #messages)
      assert.is_not_nil(messages[1]:find("Kobold Miner", 1, true))
    end)

    it("logs a hint that resolved to no death", function()
      local logger, messages = fakeLogger()
      correlator = KillCorrelator.new({ window = 1.5, logger = logger })

      correlator:resolve("Kobold Miner", 10.0)

      assert.equal(1, #messages)
      assert.is_not_nil(messages[1]:find("unmatched", 1, true))
    end)

    it("logs each death that expires unclaimed, not only the final count", function()
      local logger, messages = fakeLogger()
      correlator = KillCorrelator.new({ window = 1.5, logger = logger })
      death("Young Wolf", 10.0, 299, 3)
      for i = #messages, 1, -1 do messages[i] = nil end

      correlator:prune(17.0)

      assert.equal(1, #messages)
      assert.is_not_nil(messages[1]:find("Young Wolf", 1, true))
    end)

    it("stays silent when a prune finds nothing to expire", function()
      local logger, messages = fakeLogger()
      correlator = KillCorrelator.new({ window = 1.5, logger = logger })
      death("Young Wolf", 10.0, 299, 3)
      for i = #messages, 1, -1 do messages[i] = nil end

      correlator:prune(11.0)

      assert.same({}, messages)
    end)
  end)
end)
