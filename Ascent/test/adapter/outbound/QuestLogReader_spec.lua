describe("QuestLogReader", function()
  local reader, QuestXpOrigin
  local entries, selection, calls, selectionReads

  -- Mirrors the real client: GetQuestLogTitle(index) reads from a fixed table of
  -- entries, and GetQuestLogRewardXP() (no argument) answers for whichever index
  -- was most recently selected -- exactly the coupling the adapter relies on.
  local function stubQuestLog(fixtureEntries, initialSelection)
    entries = fixtureEntries
    selection = initialSelection
    calls = {}
    selectionReads = 0

    _G.GetQuestLogSelection = function()
      selectionReads = selectionReads + 1
      return selection
    end
    _G.GetNumQuestLogEntries = function()
      return #entries
    end
    _G.GetQuestLogTitle = function(index)
      local entry = entries[index]
      return entry.title, entry.level, entry.questTag, entry.suggestedGroup,
        entry.isHeader, entry.isCollapsed, entry.isComplete, entry.questId
    end
    _G.SelectQuestLogEntry = function(index)
      calls[#calls + 1] = index
      selection = index
    end
    -- Both invocation forms D15 names: no argument answers for whichever entry
    -- is currently selected (the recipe the reader actually uses); with a
    -- questId it answers for that quest directly, regardless of selection.
    _G.GetQuestLogRewardXP = function(questId)
      if questId ~= nil then
        for _, entry in ipairs(entries) do
          if entry.questId == questId then
            return entry.reward
          end
        end
        return nil
      end
      local entry = entries[selection]
      return entry and entry.reward
    end
    -- The trustworthy default: most tests are about the shape-checking this
    -- reader always does, not about the provenance check (8.5), which is its
    -- own describe block below and overrides this before constructing.
    _G.issecurevariable = function() return true end
    -- The client's own sentence for a kill objective, and the objectives of each
    -- fixture entry. Absent by default: most of this spec is about rewards.
    _G.QUEST_MONSTERS_KILLED = "%s slain: %d/%d"
    _G.GetNumQuestLeaderBoards = function(index)
      local entry = entries[index]
      return entry and entry.objectives and #entry.objectives or 0
    end
    _G.GetQuestLogLeaderBoard = function(objectiveIndex, index)
      local objective = entries[index] and entries[index].objectives
        and entries[index].objectives[objectiveIndex]
      if objective == nil then return nil end
      return objective.text, objective.kind, objective.finished
    end
  end

  local function load()
    local ns = AscentTest.loadWith("core/model/", "adapter/inbound/GlobalStringPattern.lua",
      "adapter/outbound/QuestLogReader.lua")
    QuestXpOrigin = ns.core.QuestXpOrigin
    reader = ns.adapter.QuestLogReader.new()
  end

  local function fakeLogger()
    local messages = {}
    return { debug = function(_, message) messages[#messages + 1] = message end }, messages
  end

  after_each(function()
    _G.GetQuestLogSelection = nil
    _G.GetNumQuestLogEntries = nil
    _G.GetQuestLogTitle = nil
    _G.SelectQuestLogEntry = nil
    _G.GetQuestLogRewardXP = nil
    _G.issecurevariable = nil
    _G.GetTime = nil
    _G.QUEST_MONSTERS_KILLED = nil
    _G.GetNumQuestLeaderBoards = nil
    _G.GetQuestLogLeaderBoard = nil
  end)

  it("reads two ordinary quests into forecasts sourced from the client", function()
    stubQuestLog({
      { questId = 101, level = 10, isHeader = false, isComplete = false, reward = 250 },
      { questId = 102, level = 12, isHeader = false, isComplete = true, reward = 300 },
    }, 0)
    load()

    local result = reader:scan()

    assert.equal(2, #result)
    assert.equal(101, result[1].questId)
    assert.equal(250, result[1].reward)
    assert.equal(QuestXpOrigin.CLIENT, result[1].origin)
    assert.equal(102, result[2].questId)
    assert.equal(300, result[2].reward)
    assert.is_true(result[2]:isReadyToTurnIn())
  end)

  it("carries the quest's own title through, and treats an empty one as no title", function()
    stubQuestLog({
      { questId = 101, level = 10, isHeader = false, title = "Wanted: Hogger", reward = 250 },
      { questId = 102, level = 12, isHeader = false, title = "", reward = 300 },
      { questId = 103, level = 12, isHeader = false, title = 42, reward = 300 },
    }, 0)
    load()

    local result = reader:scan()

    assert.equal("Wanted: Hogger", result[1].title)
    assert.is_nil(result[2].title)
    assert.is_nil(result[3].title)
  end)

  describe("the kill objectives of a quest", function()
    it("reads the creature, what is done and what is needed", function()
      stubQuestLog({
        { questId = 101, level = 10, isHeader = false, reward = 250, objectives = {
          { text = "Grimscale Murloc slain: 3/6", kind = "monster" },
          { text = "Springpaw Lynx slain: 0/8", kind = "monster" },
        } },
      }, 0)
      load()

      local objectives = reader:scan()[1].objectives

      assert.equal(2, #objectives)
      assert.equal("Grimscale Murloc", objectives[1].creature)
      assert.equal(3, objectives[1].done)
      assert.equal(6, objectives[1].needed)
      assert.equal(8, objectives[2]:remaining())
    end)

    -- Skipped by TYPE, not by whether the sentence parses: "Feather: 3/8" would
    -- parse perfectly and mean something with a drop rate in front of it.
    it("ignores everything the client did not type as a kill", function()
      stubQuestLog({
        { questId = 101, level = 10, isHeader = false, reward = 250, objectives = {
          { text = "Tainted Arcane Sliver: 3/8", kind = "item" },
          { text = "Sunsail Anchorage explored: 0/1", kind = "event" },
        } },
      }, 0)
      load()

      assert.is_nil(reader:scan()[1].objectives)
    end)

    it("drops one unreadable objective without losing the others or the quest", function()
      stubQuestLog({
        { questId = 101, level = 10, isHeader = false, reward = 250, objectives = {
          { text = "something the template does not describe", kind = "monster" },
          { text = "Grimscale Murloc slain: 3/6", kind = "monster" },
        } },
        { questId = 102, level = 10, isHeader = false, reward = 250 },
      }, 0)
      load()

      local result = reader:scan()

      assert.equal(2, #result)
      assert.equal(1, #result[1].objectives)
      assert.equal("Grimscale Murloc", result[1].objectives[1].creature)
      -- And the count that tells "worded differently" apart from "asks for feathers"
      assert.equal(2, reader.objectivesSeen)
      assert.equal(1, reader.objectivesRead)
    end)

    it("reads no objectives at all on a client without the functions, rather than failing", function()
      stubQuestLog({
        { questId = 101, level = 10, isHeader = false, reward = 250, objectives = {
          { text = "Grimscale Murloc slain: 3/6", kind = "monster" },
        } },
      }, 0)
      _G.GetNumQuestLeaderBoards = nil
      load()

      assert.is_nil(reader:scan()[1].objectives)
    end)

    it("reads none when the client has no sentence for a kill objective", function()
      stubQuestLog({
        { questId = 101, level = 10, isHeader = false, reward = 250, objectives = {
          { text = "Grimscale Murloc slain: 3/6", kind = "monster" },
        } },
      }, 0)
      _G.QUEST_MONSTERS_KILLED = nil
      load()

      assert.is_nil(reader:scan()[1].objectives)
    end)
  end)

  it("skips header entries without building a forecast for them", function()
    stubQuestLog({
      { isHeader = true },
      { questId = 101, level = 10, isHeader = false, reward = 250 },
    }, 0)
    load()

    local result = reader:scan()

    assert.equal(1, #result)
    assert.equal(101, result[1].questId)
  end)

  it("skips an entry with no usable questID without crashing the rest of the walk", function()
    stubQuestLog({
      { questId = nil, level = 5, isHeader = false, reward = 100 },
      { questId = 0, level = 5, isHeader = false, reward = 100 },
      { questId = 101, level = 10, isHeader = false, reward = 250 },
    }, 0)
    load()

    local result = reader:scan()

    assert.equal(1, #result)
    assert.equal(101, result[1].questId)
  end)

  it("reports a nil reward as unknown provenance instead of crashing", function()
    stubQuestLog({
      { questId = 101, level = 10, isHeader = false, reward = nil },
    }, 0)
    load()

    local result = reader:scan()

    assert.equal(1, #result)
    assert.is_nil(result[1].reward)
    assert.equal(QuestXpOrigin.UNKNOWN, result[1].origin)
  end)

  it("treats a non-numeric or negative reward the same as a missing one", function()
    stubQuestLog({
      { questId = 101, level = 10, isHeader = false, reward = "a lot" },
      { questId = 102, level = 10, isHeader = false, reward = -5 },
    }, 0)
    load()

    local result = reader:scan()

    assert.equal(2, #result)
    for _, forecast in ipairs(result) do
      assert.is_nil(forecast.reward)
      assert.equal(QuestXpOrigin.UNKNOWN, forecast.origin)
    end
  end)

  it("reports unknown provenance for every quest when the reward function is no longer Blizzard's own (8.5)", function()
    stubQuestLog({
      { questId = 101, level = 10, isHeader = false, reward = 250 },
    }, 0)
    _G.issecurevariable = function() return false end -- captured at construction, below
    load()

    local result = reader:scan()

    assert.equal(1, #result)
    assert.is_nil(result[1].reward) -- the number a replaced function returned is not trusted
    assert.equal(QuestXpOrigin.UNKNOWN, result[1].origin)
  end)

  it("saves the selection once, selects only the valid entries in order, and restores it once at the end", function()
    stubQuestLog({
      { isHeader = true },
      { questId = 101, level = 10, isHeader = false, reward = 250 },
      { questId = 0, level = 10, isHeader = false, reward = 100 },
      { questId = 102, level = 12, isHeader = false, reward = 300 },
    }, 7)
    load()

    reader:scan()

    assert.equal(1, selectionReads)
    assert.same({ 2, 4, 7 }, calls)
  end)

  it("normalises an invalid level to nil instead of crashing", function()
    stubQuestLog({
      { questId = 101, level = 0, isHeader = false, reward = 250 },
      { questId = 102, level = -3, isHeader = false, reward = 250 },
      { questId = 103, level = "ten", isHeader = false, reward = 250 },
    }, 0)
    load()

    local result = reader:scan()

    assert.equal(3, #result)
    for _, forecast in ipairs(result) do
      assert.is_nil(forecast.questLevel)
    end
  end)

  it("normalises isComplete from either a real boolean or the numeric 1", function()
    stubQuestLog({
      { questId = 101, level = 10, isHeader = false, isComplete = true, reward = 250 },
      { questId = 102, level = 10, isHeader = false, isComplete = 1, reward = 250 },
    }, 0)
    load()

    local result = reader:scan()

    assert.is_true(result[1]:isReadyToTurnIn())
    assert.is_true(result[2]:isReadyToTurnIn())
  end)

  it("returns an empty array for an empty quest log without crashing", function()
    stubQuestLog({}, 3)
    load()

    local result = reader:scan()

    assert.equal(0, #result)
    assert.same({ 3 }, calls)
  end)

  -- Spike 0.5: with a logger, the sweep also dumps the provenance check and both
  -- invocation forms per quest, without changing what is returned.
  describe("spike 0.5 diagnostics (optional logger)", function()
    it("changes nothing about the returned forecasts", function()
      stubQuestLog({ { questId = 101, level = 10, isHeader = false, reward = 250 } }, 0)
      load()
      _G.issecurevariable = function() return true end
      _G.GetTime = function() return 1000 end
      local logger = fakeLogger()

      local result = reader:scan(logger)

      assert.equal(1, #result)
      assert.equal(250, result[1].reward)
    end)

    it("logs whether the client's reward function is still secure", function()
      stubQuestLog({}, 0)
      load()
      _G.issecurevariable = function(name) return name == "GetQuestLogRewardXP" and false end
      _G.GetTime = function() return 1000 end
      local logger, messages = fakeLogger()

      reader:scan(logger)

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("GetQuestLogRewardXP secure: false", 1, true))
    end)

    it("logs both invocation forms per quest and whether they agree", function()
      stubQuestLog({ { questId = 101, level = 10, isHeader = false, reward = 250 } }, 0)
      load()
      _G.issecurevariable = function() return true end
      _G.GetTime = function() return 1000 end
      local logger, messages = fakeLogger()

      reader:scan(logger)

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("questId=101", 1, true))
      assert.is_not_nil(joined:find("selected=250", 1, true))
      assert.is_not_nil(joined:find("direct=250", 1, true))
      assert.is_not_nil(joined:find("agree=true", 1, true))
    end)

    it("flags a disagreement between the two forms instead of hiding it", function()
      -- The direct form is stubbed to answer for a DIFFERENT quest than the one
      -- selected, the same shape a real disagreement between the two forms would
      -- take: this one is deliberately not looked up by questId.
      stubQuestLog({ { questId = 101, level = 10, isHeader = false, reward = 250 } }, 0)
      -- Reassigned before load(): the reader now captures this reference at
      -- construction (8.5) rather than reading the global by name on every
      -- call, so an override has to be in place before that capture happens.
      _G.GetQuestLogRewardXP = function(questId)
        if questId ~= nil then
          return 0 -- disagrees with the selected-entry reading of 250
        end
        return entries[selection] and entries[selection].reward
      end
      load()
      _G.issecurevariable = function() return true end
      _G.GetTime = function() return 1000 end
      local logger, messages = fakeLogger()

      reader:scan(logger)

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("agree=false", 1, true))
    end)
  end)

  -- The sweep the spike actually reads. It used to exist only as debug lines in a
  -- 500-line chat ring shared with roughly three lines per kill, so a sweep taken
  -- an hour into a session was gone before anyone could look at it.
  describe("the sweep written to the evidence file", function()
    local function recorder()
      local samples = {}
      return function(kind, fields)
        fields = fields or {}
        fields.kind = kind
        samples[#samples + 1] = fields
      end, samples
    end

    it("writes one sample for the whole sweep, not one per quest", function()
      stubQuestLog({
        { questId = 101, level = 10, isHeader = false, reward = 250 },
        { questId = 102, level = 12, isHeader = false, reward = 300 },
        { questId = 103, level = 14, isHeader = false, reward = 350 },
      }, 0)
      load()
      _G.issecurevariable = function() return true end
      _G.GetTime = function() return 1000 end
      local record, samples = recorder()

      reader:scan(nil, record)

      assert.equal(1, #samples)
      assert.equal("questSweep", samples[1].kind)
      assert.equal(3, samples[1].scanned)
      assert.equal(3, #samples[1].quests)
      assert.is_true(samples[1].secure)
      assert.equal(101, samples[1].quests[1].questId)
    end)

    it("carries both call forms per quest, which is the spike's whole question", function()
      stubQuestLog({ { questId = 101, level = 10, isHeader = false, reward = 250 } }, 0)
      load()
      _G.issecurevariable = function() return true end
      _G.GetTime = function() return 1000 end
      local record, samples = recorder()

      reader:scan(nil, record)

      local quest = samples[1].quests[1]
      assert.equal(250, quest.selected)
      assert.is_not_nil(quest.agree)
    end)

    it("writes nothing when nobody asked for a sample", function()
      stubQuestLog({ { questId = 101, level = 10, isHeader = false, reward = 250 } }, 0)
      load()
      _G.issecurevariable = function() return true end
      _G.GetTime = function() return 1000 end

      assert.has_no.errors(function() reader:scan() end)
    end)
  end)
end)
