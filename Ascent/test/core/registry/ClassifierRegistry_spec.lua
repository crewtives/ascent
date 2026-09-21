describe("ClassifierRegistry", function()
  local ns, ClassifierRegistry, XpSource, registry

  local function classifier(fields)
    fields.priority = fields.priority or 100
    fields.matches = fields.matches or function() return true end
    return fields
  end

  before_each(function()
    ns = AscentTest.loadDomain("core/model/Guard.lua", "core/registry/ClassifierRegistry.lua")
    ClassifierRegistry = ns.core.ClassifierRegistry
    XpSource = ns.core.XpSource
    registry = ClassifierRegistry.new()
  end)

  describe("resolving", function()
    it("asks the highest priority classifier that matches", function()
      registry:register(classifier({
        id = "low", priority = 10,
        classify = function() return XpSource.EXPLORATION end,
      }))
      registry:register(classifier({
        id = "high", priority = 900,
        classify = function() return XpSource.QUEST_TURNIN end,
      }))

      local classification = registry:classify({})

      assert.equal(XpSource.QUEST_TURNIN, classification.source)
      assert.equal("high", classification.classifierId)
    end)

    it("skips a higher priority classifier that does not match", function()
      registry:register(classifier({
        id = "picky", priority = 900,
        matches = function(hint) return hint.kind == "never" end,
        classify = function() return XpSource.QUEST_TURNIN end,
      }))
      registry:register(classifier({
        id = "willing", priority = 10,
        classify = function() return XpSource.MOB_KILL end,
      }))

      assert.equal(XpSource.MOB_KILL, registry:classify({}).source)
    end)

    it("hands the classifier's payload back alongside the source", function()
      registry:register(classifier({
        id = "quest",
        classify = function() return XpSource.QUEST_TURNIN end,
        payload = function(hint) return { questId = hint.questId } end,
      }))

      assert.same({ questId = 1234 }, registry:classify({ questId = 1234 }).payload)
    end)

    -- table.sort is not stable, so equal priorities would otherwise be free to swap
    -- between runs and make a failure impossible to reproduce.
    it("orders equal priorities by id, so the order is reproducible", function()
      registry:register(classifier({ id = "zulu", classify = function() return XpSource.MOB_KILL end }))
      registry:register(classifier({ id = "alpha", classify = function() return XpSource.EXPLORATION end }))

      assert.same({ "alpha", "zulu" }, registry:ids())
      assert.equal(XpSource.EXPLORATION, registry:classify({}).source)
    end)
  end)

  describe("a channel that only carries an amount", function()
    before_each(function()
      registry:register(classifier({ id = "anonymous", priority = 100, amountOnly = true }))
    end)

    it("never resolves a source on its own", function()
      local classification = registry:classify({})

      assert.equal(XpSource.UNKNOWN, classification.source)
      assert.is_false(classification.resolvesSource)
      assert.is_true(classification.amountOnly)
    end)

    -- Named anyway: "a channel I understand that says nothing about the source" and
    -- "a channel I do not understand" are different diagnoses.
    it("is still named, so it can be told apart from a channel nobody recognises", function()
      assert.equal("anonymous", registry:classify({}).classifierId)
    end)

    it("does not stand in the way of a lower priority classifier that can resolve one", function()
      registry:register(classifier({
        id = "kill", priority = 10,
        classify = function() return XpSource.MOB_KILL end,
      }))

      local classification = registry:classify({})

      assert.equal(XpSource.MOB_KILL, classification.source)
      assert.is_true(classification.resolvesSource)
    end)

    -- The rule lives in the shape of the descriptor rather than in a branch at
    -- classification time, so it cannot be forgotten by whoever adds the next one.
    it("cannot be registered with a classify function at all", function()
      assert.has_error(function()
        registry:register(classifier({
          id = "contradiction", amountOnly = true,
          classify = function() return XpSource.MOB_KILL end,
        }))
      end)
    end)
  end)

  describe("with no candidate", function()
    it("answers UNKNOWN and names no classifier", function()
      local classification = registry:classify({ kind = "something new" })

      assert.equal(XpSource.UNKNOWN, classification.source)
      assert.is_false(classification.resolvesSource)
      assert.is_false(classification.amountOnly)
      assert.is_nil(classification.classifierId)
    end)

    it("answers the same when nothing matched", function()
      registry:register(classifier({
        id = "picky",
        matches = function() return false end,
        classify = function() return XpSource.MOB_KILL end,
      }))

      assert.is_nil(registry:classify({}).classifierId)
    end)
  end)

  describe("registering", function()
    it("refuses a duplicate id", function()
      registry:register(classifier({ id = "kill", classify = function() return XpSource.MOB_KILL end }))

      assert.has_error(function()
        registry:register(classifier({ id = "kill", classify = function() return XpSource.MOB_KILL end }))
      end)
    end)

    it("refuses a descriptor missing its parts", function()
      assert.has_error(function() registry:register({}) end)
      assert.has_error(function() registry:register(classifier({ id = "", classify = function() end })) end)
      assert.has_error(function() registry:register({ id = "x", matches = function() end,
        classify = function() end }) end) -- no priority
      assert.has_error(function() registry:register(classifier({ id = "x" })) end) -- no classify
      assert.has_error(function() registry:register(classifier({
        id = "x", classify = function() end, payload = "not a function" })) end)
    end)

    -- A classifier answering something that is not a source would otherwise put an
    -- unknown key into the per-source totals, where it would never add up.
    it("refuses a source that is not one of the constants", function()
      registry:register(classifier({ id = "liar", classify = function() return "mob_kil" end }))

      assert.has_error(function() registry:classify({}) end)
    end)

    it("counts what it holds", function()
      assert.equal(0, registry:count())
      registry:register(classifier({ id = "kill", classify = function() return XpSource.MOB_KILL end }))
      assert.equal(1, registry:count())
    end)
  end)
end)
