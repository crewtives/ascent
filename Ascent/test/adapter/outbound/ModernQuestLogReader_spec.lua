-- The two readers answer the same question through APIs that share nothing, so
-- the same quest log, read either way, has to reach the domain in the same shape.
-- Only the modern one can also promise that the player's own selection is never
-- touched: it has no call that could touch it.

describe("ModernQuestLogReader", function()
  local ns, reader, QuestXpOrigin
  -- Which entry the classic client has selected. Out here because the reward
  -- function has to answer for it: the classic call form takes no argument and
  -- means "whichever entry is selected".
  local selection

  -- One quest log, described once, and handed to both clients below. A fixture
  -- per reader would let the two drift and call the result agreement.
  local LOG = {
    {
      title = "Kobold Candles", level = 5, questId = 1234, reward = 250, isComplete = false,
      objectives = {
        { text = "Kobold Miner slain: 3/8", kind = "monster" },
        { text = "Large Candle: 1/8", kind = "item" },
      },
    },
    {
      title = "Wolves Across the Border", level = 9, questId = 5678, reward = 700, isComplete = true,
      objectives = {},
    },
  }

  local function entryFor(questId)
    for _, entry in ipairs(LOG) do
      if entry.questId == questId then return entry end
    end
    return nil
  end

  -- The modern tree, as the client's own API dump describes it: C_QuestLog
  -- complete, and every classic entry point gone.
  local function modernClient()
    _G.GetQuestLogTitle, _G.GetNumQuestLogEntries = nil, nil
    _G.SelectQuestLogEntry, _G.GetQuestLogSelection = nil, nil
    _G.GetNumQuestLeaderBoards, _G.GetQuestLogLeaderBoard = nil, nil
    _G.C_QuestLog = {
      selections = 0,
      GetNumQuestLogEntries = function() return #LOG, #LOG end,
      GetInfo = function(index)
        local entry = LOG[index]
        if entry == nil then return nil end
        return {
          title = entry.title, level = entry.level, questID = entry.questId,
          isHeader = false, isComplete = entry.isComplete,
        }
      end,
      GetQuestIDForLogIndex = function(index)
        return LOG[index] and LOG[index].questId or 0
      end,
      GetQuestObjectives = function(questId)
        local entry = entryFor(questId)
        local out = {}
        for _, objective in ipairs(entry and entry.objectives or {}) do
          out[#out + 1] = { text = objective.text, type = objective.kind, finished = false }
        end
        return out
      end,
      GetSelectedQuest = function() return 0 end,
      SetSelectedQuest = function() _G.C_QuestLog.selections = _G.C_QuestLog.selections + 1 end,
    }
  end

  -- The same log, through the classic tree, so the two can be compared.
  local function classicClient()
    _G.C_QuestLog = nil
    selection = 1
    _G.GetNumQuestLogEntries = function() return #LOG end
    _G.GetQuestLogSelection = function() return selection end
    _G.SelectQuestLogEntry = function(index) selection = index end
    _G.GetQuestLogTitle = function(index)
      local entry = LOG[index]
      return entry.title, entry.level, nil, nil, false, nil, entry.isComplete, entry.questId
    end
    _G.GetNumQuestLeaderBoards = function(index)
      return LOG[index] and #LOG[index].objectives or 0
    end
    _G.GetQuestLogLeaderBoard = function(objectiveIndex, index)
      local objective = LOG[index] and LOG[index].objectives[objectiveIndex]
      if objective == nil then return nil end
      return objective.text, objective.kind, false
    end
  end

  local function load(which)
    ns = AscentTest.loadWith("core/model/", "core/port/", "adapter/compat/Readable.lua",
      "adapter/inbound/GlobalStringPattern.lua", "adapter/outbound/QuestLogShape.lua",
      "adapter/outbound/ClassicQuestLogReader.lua", "adapter/outbound/ModernQuestLogReader.lua")
    QuestXpOrigin = ns.core.QuestXpOrigin
    return ns.adapter[which].new()
  end

  before_each(function()
    _G.QUEST_MONSTERS_KILLED = "%s slain: %d/%d"
    _G.issecurevariable = function() return true end
    -- Both call forms: with a quest id it answers for that quest, and with none
    -- it answers for whatever the classic client has selected.
    _G.GetQuestLogRewardXP = function(questId)
      local entry = questId ~= nil and entryFor(questId) or LOG[selection]
      return entry and entry.reward
    end
    modernClient()
    reader = load("ModernQuestLogReader")
  end)

  after_each(function()
    for _, name in ipairs({ "C_QuestLog", "QUEST_MONSTERS_KILLED", "issecurevariable",
      "GetQuestLogRewardXP", "GetQuestLogTitle", "GetNumQuestLogEntries", "SelectQuestLogEntry",
      "GetQuestLogSelection", "GetNumQuestLeaderBoards", "GetQuestLogLeaderBoard" }) do
      _G[name] = nil
    end
  end)

  it("is supported only where the modern quest log actually is", function()
    assert.is_true(ns.adapter.ModernQuestLogReader.isSupported())

    _G.C_QuestLog = nil
    assert.is_false(ns.adapter.ModernQuestLogReader.isSupported())
  end)

  it("reads every accepted quest, with its id, level, title and reward", function()
    local forecasts = reader:scan()

    assert.equal(2, #forecasts)
    assert.equal(1234, forecasts[1].questId)
    assert.equal(5, forecasts[1].questLevel)
    assert.equal("Kobold Candles", forecasts[1].title)
    assert.equal(250, forecasts[1].reward)
    assert.equal(QuestXpOrigin.CLIENT, forecasts[1].origin)
    assert.is_false(forecasts[1].complete)
    assert.is_true(forecasts[2].complete)
  end)

  it("reads the kill objectives and skips the ones that are not kills", function()
    local forecasts = reader:scan()

    assert.equal(1, #forecasts[1].objectives)
    assert.equal("Kobold Miner", forecasts[1].objectives[1].creature)
    assert.equal(3, forecasts[1].objectives[1].done)
    assert.equal(8, forecasts[1].objectives[1].needed)

    local read, seen = reader:objectiveTally()
    assert.equal(1, read)
    assert.equal(1, seen)
  end)

  -- The domain must not be able to tell which client it is running on from what
  -- it was handed.
  it("hands the domain what the classic reader hands it, for the same log", function()
    local modern = reader:scan()

    classicClient()
    local classic = load("ClassicQuestLogReader"):scan()

    assert.equal(#classic, #modern)
    for index = 1, #classic do
      assert.same(classic[index], modern[index])
    end
  end)

  -- There is no selection call in this reader at all, so the assertion is on the
  -- client double, which counts any selection it is asked to make.
  it("never moves the player's own selection", function()
    reader:scan()

    assert.equal(0, _G.C_QuestLog.selections)
  end)

  describe("on a client that cannot be vouched for", function()
    it("reports UNKNOWN when the reward function has been replaced", function()
      _G.issecurevariable = function() return false end
      local replaced = load("ModernQuestLogReader")

      local forecasts = replaced:scan()

      assert.is_nil(forecasts[1].reward)
      assert.equal(QuestXpOrigin.UNKNOWN, forecasts[1].origin)
    end)

    it("reports UNKNOWN on a client with no reward function at all", function()
      _G.GetQuestLogRewardXP = nil
      local without = load("ModernQuestLogReader")

      local forecasts = without:scan()

      assert.equal(2, #forecasts)
      assert.is_nil(forecasts[1].reward)
      assert.equal(QuestXpOrigin.UNKNOWN, forecasts[1].origin)
    end)

    it("reads the log even where objectives cannot be asked for", function()
      _G.C_QuestLog.GetQuestObjectives = nil

      local forecasts = reader:scan()

      assert.equal(2, #forecasts)
      assert.is_nil(forecasts[1].objectives)
    end)
  end)
end)
