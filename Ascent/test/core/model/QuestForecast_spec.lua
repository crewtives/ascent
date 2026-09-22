describe("QuestForecast", function()
  local ns, QuestForecast, QuestXpOrigin

  before_each(function()
    ns = AscentTest.loadDomain("core/model/Guard.lua", "core/model/QuestForecast.lua")
    QuestForecast = ns.core.QuestForecast
    QuestXpOrigin = ns.core.QuestXpOrigin
  end)

  -- Conflating the two would make a forecast under-report instead of showing
  -- the gap.
  describe("an unknown reward is not a zero reward", function()
    it("reports a quest with no reward data as unknown", function()
      local quest = QuestForecast.unknown(1234, 20)

      assert.is_false(quest:isKnown())
      assert.is_nil(quest.reward)
      assert.equal(QuestXpOrigin.UNKNOWN, quest.origin)
    end)

    it("reports a quest that genuinely pays nothing as known", function()
      local quest = QuestForecast.new({ questId = 1234, reward = 0, origin = QuestXpOrigin.CLIENT })

      assert.is_true(quest:isKnown())
      assert.equal(0, quest.reward)
    end)
  end)

  describe("provenance", function()
    it("records where the number came from", function()
      local fromClient = QuestForecast.new({ questId = 1, reward = 500, origin = QuestXpOrigin.CLIENT })
      local learned = QuestForecast.new({ questId = 2, reward = 500, origin = QuestXpOrigin.LEARNED })

      assert.equal(QuestXpOrigin.CLIENT, fromClient.origin)
      assert.equal(QuestXpOrigin.LEARNED, learned.origin)
    end)

    it("refuses a reward with no stated source", function()
      assert.has_error(function()
        return QuestForecast.new({ questId = 1, reward = 500, origin = QuestXpOrigin.UNKNOWN })
      end)
    end)

    it("refuses a missing reward that claims a source", function()
      assert.has_error(function()
        return QuestForecast.new({ questId = 1, origin = QuestXpOrigin.CLIENT })
      end)
    end)

    it("refuses an origin that is not a real origin", function()
      assert.has_error(function()
        return QuestForecast.new({ questId = 1, reward = 500, origin = "guessed" })
      end)
    end)
  end)

  describe("state", function()
    it("knows whether the quest is ready to hand in", function()
      local ready = QuestForecast.new({ questId = 1, reward = 500, origin = QuestXpOrigin.CLIENT, complete = true })
      local inProgress = QuestForecast.new({ questId = 2, reward = 500, origin = QuestXpOrigin.CLIENT })

      assert.is_true(ready:isReadyToTurnIn())
      assert.is_false(inProgress:isReadyToTurnIn())
    end)

    it("keeps the quest level, which the reduction will need", function()
      assert.equal(20, QuestForecast.unknown(1234, 20).questLevel)
    end)
  end)

  it("refuses impossible values", function()
    assert.has_error(function()
      return QuestForecast.new({ questId = 1, reward = -1, origin = QuestXpOrigin.CLIENT })
    end)
    assert.has_error(function()
      return QuestForecast.new({ questId = 0, reward = 1, origin = QuestXpOrigin.CLIENT })
    end)
  end)
end)
