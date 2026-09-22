-- Ascent - reads the quest log the modern way: ask about a quest id, and never
-- touch what the player has selected.
--
-- The classic reader has to select an entry to ask about it, which moves the
-- highlight in the player's tracker. `C_QuestLog.GetQuestObjectives(questID)`
-- takes the id directly, so a sweep leaves the quest log exactly as it was.
--
-- Every function named here is in the client's API dump: `C_QuestLog` is present
-- and complete on Forever, and the four classic entry points are absent. The dump
-- does not say what they return at runtime, so every read goes through the same
-- shape checks as the classic reader, and a field without the shape the domain
-- expects becomes nil rather than a plausible number.
--
-- `GetQuestLogRewardXP` is not in the dump. Where the client has it, it is called
-- with the quest id, the form that needs no selection; where it does not, a
-- quest's reward is UNKNOWN and the forecast says so rather than guessing.

local _, ns = ...
ns.adapter = ns.adapter or {}

local QuestForecast = ns.core.QuestForecast
local QuestXpOrigin = ns.core.QuestXpOrigin

local Shape = ns.adapter.QuestLogShape
local validQuestId, validLevel = Shape.validQuestId, Shape.validLevel
local validReward, validTitle = Shape.validReward, Shape.validTitle
local readable = ns.adapter.Readable.value

local ModernQuestLogReader = {}
ModernQuestLogReader.__index = ModernQuestLogReader

-- Whether this client has the modern quest log at all. The two calls the sweep
-- cannot do without: everything else it uses degrades to a missing field.
function ModernQuestLogReader.isSupported()
  return C_QuestLog ~= nil
    and type(C_QuestLog.GetNumQuestLogEntries) == "function"
    and type(C_QuestLog.GetInfo) == "function"
end

-- Captured once, as early as possible, as the classic reader does: both the trust
-- check and the function itself, so a second addon replacing the global
-- afterwards changes nothing this reader does.
function ModernQuestLogReader.new()
  local rewardFn = GetQuestLogRewardXP
  return ns.core.Port.verify(ns.core.QuestLog, setmetatable({
    trusted = rewardFn ~= nil and issecurevariable("GetQuestLogRewardXP") == true,
    rewardFn = rewardFn,
    killTemplate = Shape.killTemplate(),
    objectivesSeen = 0,
    objectivesRead = 0,
  }, ModernQuestLogReader), "ModernQuestLogReader")
end

function ModernQuestLogReader:objectiveTally()
  return self.objectivesRead, self.objectivesSeen
end

-- The kill objectives of one quest, by id. Others are skipped by type, not by
-- whether the sentence parses: an item objective reading "Feather: 3/8" parses
-- and means something else.
function ModernQuestLogReader:objectivesFor(questId)
  if type(C_QuestLog.GetQuestObjectives) ~= "function" then
    return nil
  end

  local entries = readable(C_QuestLog.GetQuestObjectives(questId))
  if type(entries) ~= "table" then
    return nil
  end

  local objectives = nil
  for _, entry in ipairs(entries) do
    local objective = readable(entry)
    if type(objective) == "table" and objective.type == "monster" then
      self.objectivesSeen = self.objectivesSeen + 1
      local parsed = Shape.killObjective(self.killTemplate, objective.text)
      if parsed ~= nil then
        self.objectivesRead = self.objectivesRead + 1
        objectives = objectives or {}
        objectives[#objectives + 1] = parsed
      end
    end
  end
  return objectives
end

-- The id of the entry at this index. `GetInfo` carries it, and
-- `GetQuestIDForLogIndex` answers the same question for a client whose info
-- table does not -- asked in that order so the ordinary case costs one call.
local function questIdAt(info, index)
  if validQuestId(info.questID) then
    return info.questID
  end
  if type(C_QuestLog.GetQuestIDForLogIndex) ~= "function" then
    return nil
  end
  local questId = readable(C_QuestLog.GetQuestIDForLogIndex(index))
  return validQuestId(questId) and questId or nil
end

function ModernQuestLogReader:scan(logger, recordEvidence)
  local forecasts = {}
  local sampled = recordEvidence ~= nil and {} or nil
  local secure = self.trusted

  if logger ~= nil then
    logger:debug(("modern quest log; GetQuestLogRewardXP secure: %s"):format(tostring(secure)))
  end

  -- The first return is how many entries the log has, headers included, as the
  -- classic call answers, so the loop is the same.
  local shown = readable(C_QuestLog.GetNumQuestLogEntries())
  for index = 1, (type(shown) == "number" and shown or 0) do
    local info = readable(C_QuestLog.GetInfo(index))

    if type(info) == "table" and not info.isHeader then
      local questId = questIdAt(info, index)

      if questId ~= nil then
        -- One call form: the id is in hand, so there is no selected-entry form to
        -- compare it against.
        local reward = self.rewardFn ~= nil and validReward(self.rewardFn(questId)) or nil
        local trustedReward = self.trusted and reward or nil
        local origin = trustedReward and QuestXpOrigin.CLIENT or QuestXpOrigin.UNKNOWN

        if logger ~= nil then
          logger:debug(("quest reward: questId=%s level=%s reward=%s")
            :format(tostring(questId), tostring(info.level), tostring(reward)))
        end
        if sampled ~= nil and #sampled < Shape.SAMPLE_CAP then
          sampled[#sampled + 1] = { questId = questId, level = info.level, direct = reward }
        end

        forecasts[#forecasts + 1] = QuestForecast.new({
          questId = questId,
          questLevel = validLevel(info.level),
          title = validTitle(info.title),
          objectives = self:objectivesFor(questId),
          reward = trustedReward,
          origin = origin,
          complete = info.isComplete == true or info.isComplete == 1,
        })
      end
    end
  end

  if sampled ~= nil then
    recordEvidence("questSweep", { secure = secure, scanned = #forecasts, quests = sampled })
  end

  return forecasts
end

ns.adapter.ModernQuestLogReader = ModernQuestLogReader
