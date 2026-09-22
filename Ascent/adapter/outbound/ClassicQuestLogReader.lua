-- Ascent - reads the quest log the classic way: select an entry, ask for its
-- reward with no argument, and put the player's own selection back when the
-- sweep is done.
--
-- This is the whole of the classic tree: `GetQuestLogTitle`, `SelectQuestLogEntry`
-- and the no-argument reward call, none of which exist on the modern engine.
--
-- `GetQuestLogRewardXP` can be called with the questID or against the selected
-- entry. Whether the two agree is unverified, so the forecast is built from the
-- selected form -- `SelectQuestLogEntry(i)`, then the no-argument call -- and a
-- debug sweep logs both; if they agree, the selection becomes unnecessary.
-- Selecting an entry highlights it in the player's tracker, so their selection is
-- read once before the sweep and written back once after, not per entry, which
-- would only flicker the tracker.
--
-- No return shape here is verified against a live client, and `GetQuestLogTitle`
-- hands back a level of zero for some special entries. `QuestForecast.new` throws
-- on a wrongly shaped value, so anything not in the exact expected shape becomes
-- `nil` before construction and costs one quest instead of the sweep. That is a
-- shape check only; whether `GetQuestLogRewardXP` is still Blizzard's own function
-- is the separate `issecurevariable` trust check.
--
-- The value stored per quest is always the nominal, unreduced number the client
-- reports; scaling it for a character who has outlevelled the quest is not this
-- reader's job.

local _, ns = ...
ns.adapter = ns.adapter or {}

local QuestForecast = ns.core.QuestForecast
local QuestXpOrigin = ns.core.QuestXpOrigin

local Shape = ns.adapter.QuestLogShape
local validQuestId, validLevel = Shape.validQuestId, Shape.validLevel
local validReward, validTitle = Shape.validReward, Shape.validTitle

local ClassicQuestLogReader = {}
ClassicQuestLogReader.__index = ClassicQuestLogReader

-- Whether this client has the classic quest log at all: the four entry points
-- the sweep cannot do without, all absent on the modern engine.
function ClassicQuestLogReader.isSupported()
  return type(GetQuestLogTitle) == "function"
    and type(GetNumQuestLogEntries) == "function"
    and type(SelectQuestLogEntry) == "function"
    and type(GetQuestLogSelection) == "function"
end

-- Captured once, as early as possible: both the trust check and the function
-- itself. Calling the global by name would let a second addon loading afterwards
-- redirect it unnoticed; calling through the reference taken here means a later
-- replacement of the global changes nothing this reader does, secure or not.
function ClassicQuestLogReader.new()
  return ns.core.Port.verify(ns.core.QuestLog, setmetatable({
    trusted = issecurevariable("GetQuestLogRewardXP") == true,
    rewardFn = GetQuestLogRewardXP,
    killTemplate = Shape.killTemplate(),
    -- Diagnostic only: objectives the client typed as kills, against those this
    -- reader could read. They differ only when the template does not match, which
    -- separates a client that words the sentence differently from a quest that
    -- asks for items.
    objectivesSeen = 0,
    objectivesRead = 0,
  }, ClassicQuestLogReader), "ClassicQuestLogReader")
end

-- What the port promises about objectives: read against seen. A method, so the
-- diagnostic can ask either reader without knowing which one it got.
function ClassicQuestLogReader:objectiveTally()
  return self.objectivesRead, self.objectivesSeen
end

-- The kill objectives of one quest. Everything else -- items, objects,
-- reputation, a progress bar -- is skipped by type, not by whether the sentence
-- parses: an item objective reading "Feather: 3/8" parses and means something
-- else.
function ClassicQuestLogReader:objectivesFor(questIndex)
  if type(GetNumQuestLeaderBoards) ~= "function" or type(GetQuestLogLeaderBoard) ~= "function" then
    return nil
  end

  local objectives = nil
  for objectiveIndex = 1, (GetNumQuestLeaderBoards(questIndex) or 0) do
    local text, objectiveType = GetQuestLogLeaderBoard(objectiveIndex, questIndex)
    if objectiveType == "monster" then
      self.objectivesSeen = self.objectivesSeen + 1
      local objective = Shape.killObjective(self.killTemplate, text)
      if objective ~= nil then
        self.objectivesRead = self.objectivesRead + 1
        objectives = objectives or {}
        objectives[#objectives + 1] = objective
      end
    end
  end
  return objectives
end

-- `logger`, when given, logs whether `GetQuestLogRewardXP` is still Blizzard's
-- own function and, per quest, both ways of calling it -- the no-argument form
-- the forecasts are built from, and the direct `(questId)` form -- so the two can
-- be compared. It changes nothing about what is returned.
-- `recordEvidence` is optional and only the operator-triggered sweep passes one:
-- `tick` rescans on every quest-log change, and a sample per quest on that path
-- would push hundreds of rows through the bounded ring and evict kill evidence.
function ClassicQuestLogReader:scan(logger, recordEvidence)
  local originalSelection = GetQuestLogSelection()
  local forecasts = {}
  local secure = issecurevariable("GetQuestLogRewardXP")
  local sampled = recordEvidence ~= nil and {} or nil

  if logger ~= nil then
    logger:debug(("GetQuestLogRewardXP secure: %s"):format(tostring(secure)))
  end

  for index = 1, GetNumQuestLogEntries() do
    -- Position 8 is the questID (per the client's FrameXML) and position 1 is the
    -- title; the `_` positions in between only hold the questID's place.
    local title, level, _, _, isHeader, _, isComplete, questId = GetQuestLogTitle(index)

    if not isHeader and validQuestId(questId) then
      SelectQuestLogEntry(index)
      -- `reward` is the raw shape-checked value, kept for the diagnostic below
      -- regardless of trust. `trustedReward` is what this reader vouches for:
      -- nil, forcing UNKNOWN, when the global has been replaced, however
      -- plausible its number looks.
      local reward = validReward(self.rewardFn())
      local trustedReward = self.trusted and reward or nil
      local origin = trustedReward and QuestXpOrigin.CLIENT or QuestXpOrigin.UNKNOWN

      if logger ~= nil or sampled ~= nil then
        -- Whether the two call forms answer the same thing, and whether the
        -- number is nominal or already scaled: both forms are read to compare.
        local direct = validReward(self.rewardFn(questId))
        if logger ~= nil then
          logger:debug(("quest reward at %.3f: questId=%s level=%s selected=%s direct=%s agree=%s")
            :format(GetTime(), tostring(questId), tostring(level), tostring(reward), tostring(direct),
              tostring(reward == direct)))
        end
        -- Capped, and to the evidence file: the debug log holds 500 lines shared
        -- with about three per kill, so a sweep there scrolls out within the hour.
        if sampled ~= nil and #sampled < Shape.SAMPLE_CAP then
          sampled[#sampled + 1] = {
            questId = questId, level = level, selected = reward,
            direct = direct, agree = reward == direct,
          }
        end
      end

      forecasts[#forecasts + 1] = QuestForecast.new({
        questId = questId,
        questLevel = validLevel(level),
        title = validTitle(title),
        objectives = self:objectivesFor(index),
        reward = trustedReward,
        origin = origin,
        complete = isComplete == true or isComplete == 1,
      })
    end
  end

  SelectQuestLogEntry(originalSelection)

  -- One sample for the whole sweep, not one per quest.
  if sampled ~= nil then
    recordEvidence("questSweep", { secure = secure, scanned = #forecasts, quests = sampled })
  end

  return forecasts
end

ns.adapter.ClassicQuestLogReader = ClassicQuestLogReader
