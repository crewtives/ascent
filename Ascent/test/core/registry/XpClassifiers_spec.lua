describe("the shipped classifiers", function()
  local ns, XpSource, XpHintKind, registry

  local function classify(hint)
    return registry:classify(hint)
  end

  before_each(function()
    ns = AscentTest.loadDomain(
      "core/model/Guard.lua",
      "core/registry/ClassifierRegistry.lua",
      "core/registry/XpClassifiers.lua")
    XpSource = ns.core.XpSource
    XpHintKind = ns.core.XpHintKind
    registry = ns.core.XpClassifiers.registerAll(ns.core.ClassifierRegistry.new())
  end)

  it("registers all five channels", function()
    assert.equal(5, registry:count())
  end)

  describe("a creature kill", function()
    local classification

    before_each(function()
      classification = classify({
        kind = XpHintKind.KILL_MESSAGE, amount = 44, at = 10,
        creatureName = "Kobold Miner", restedRaw = 22, groupBonus = 4,
      })
    end)

    it("is a mob kill", function()
      assert.equal(XpSource.MOB_KILL, classification.source)
      assert.is_true(classification.resolvesSource)
    end)

    it("keeps the creature's name, which is the only join back to the combat log", function()
      assert.equal("Kobold Miner", classification.payload.creatureName)
    end)

    -- Kills are the only channel that can carry these, because kills are the only
    -- thing that spends the rested reserve.
    it("keeps the rested and group breakdown the channel carried", function()
      assert.equal(22, classification.payload.restedRaw)
      assert.equal(4, classification.payload.groupBonus)
    end)
  end)

  describe("a quest turn-in", function()
    it("is a quest, and keeps the quest id", function()
      local classification = classify({
        kind = XpHintKind.QUEST_TURNED_IN, amount = 250, at = 10, questId = 1234,
      })

      assert.equal(XpSource.QUEST_TURNIN, classification.source)
      assert.equal(1234, classification.payload.questId)
    end)

    -- The system echo announces the same turn-in without the id, so it has to be
    -- offered the delta second; otherwise the gain would be attributed correctly and
    -- still lose the identifier the spec requires it to keep.
    it("outranks the system echo of the same turn-in", function()
      local event = classify({ kind = XpHintKind.QUEST_TURNED_IN, amount = 250, at = 10, questId = 1 })
      local echo = classify({ kind = XpHintKind.QUEST_MESSAGE, amount = 250, at = 10 })

      assert.equal(XpSource.QUEST_TURNIN, echo.source)
      assert.is_true(event.priority > echo.priority)
    end)
  end)

  it("classifies a zone discovery and keeps the zone", function()
    local classification = classify({
      kind = XpHintKind.ZONE_DISCOVERED, amount = 60, at = 10, zoneName = "Northshire Abbey",
    })

    assert.equal(XpSource.EXPLORATION, classification.source)
    assert.equal("Northshire Abbey", classification.payload.zoneName)
  end)

  describe("the anonymous line", function()
    it("classifies nothing on its own", function()
      local classification = classify({ kind = XpHintKind.ANONYMOUS_MESSAGE, amount = 250, at = 10 })

      assert.equal(XpSource.UNKNOWN, classification.source)
      assert.is_false(classification.resolvesSource)
      assert.is_true(classification.amountOnly)
      assert.equal("anonymous_line", classification.classifierId)
    end)

    it("ranks below every channel that can name a source", function()
      local anonymous = classify({ kind = XpHintKind.ANONYMOUS_MESSAGE, amount = 250, at = 10 })
      local kill = classify({ kind = XpHintKind.KILL_MESSAGE, amount = 44, at = 10, creatureName = "Rat" })

      assert.is_true(kill.priority > anonymous.priority)
    end)
  end)

  it("recognises nothing in a channel it was never told about", function()
    assert.is_nil(classify({ kind = "chat_msg_loot", amount = 0, at = 10 }).classifierId)
  end)
end)
