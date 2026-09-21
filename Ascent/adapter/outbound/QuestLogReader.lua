-- Ascent - reads the quest log the classic way: select an entry, ask for its
-- reward with no argument, and put the player's own selection back when the
-- sweep is done.
--
-- D15 names two ways to call `GetQuestLogRewardXP`: with the questID as an
-- argument, or against whichever entry is currently selected. Spike 0.5 will
-- settle whether the two agree, and if they do the selection dance below can
-- go away entirely. Until then this reader implements only the recipe D15
-- already commits to -- `SelectQuestLogEntry(i)` followed by the no-argument
-- call -- because that is the one the design is willing to stand behind today.
-- Selecting an entry is a real, visible effect (it is what highlights a quest
-- in the tracker), so the player's own selection is read once before the sweep
-- and written back once after, not per entry: restoring it inside the loop
-- would flicker the tracker in front of the player for no reason and would
-- still be wrong the moment the sweep moved on to the next index anyway.
--
-- Everything this file reads is a shape nobody has verified against a real
-- client yet -- `GetQuestLogRewardXP` is itself the function the spike exists
-- to check, and `GetQuestLogTitle` is known to hand back a level of zero for
-- some special entries. `QuestForecast.new` throws on a value with the wrong
-- shape, by design, so a bad number here would otherwise take down the whole
-- sweep instead of just the one quest it came from. This reader turns anything
-- that is not the exact shape the model expects into `nil` before construction,
-- the same way `WowPlayerState` never hands its port something that could break
-- it downstream. That is only a shape check, not the provenance check of 8.5:
-- this reader never asks whether `GetQuestLogRewardXP` is still Blizzard's own
-- function, only whether what it returned looks like a reward.
--
-- The value stored per quest is always the nominal, unreduced number the client
-- reports (D15): scaling it down for a character who has outlevelled the quest
-- is a job for a layer above this one, which does not exist yet.

local _, ns = ...
ns.adapter = ns.adapter or {}

local QuestForecast = ns.core.QuestForecast
local QuestObjective = ns.core.QuestObjective
local QuestXpOrigin = ns.core.QuestXpOrigin
local GlobalStringPattern = ns.adapter.GlobalStringPattern

local function validQuestId(questId)
  return type(questId) == "number" and questId >= 1 and questId % 1 == 0
end

local function validLevel(level)
  if type(level) == "number" and level >= 1 and level % 1 == 0 then
    return level
  end
  return nil
end

local function validReward(reward)
  if type(reward) == "number" and reward >= 0 and reward % 1 == 0 then
    return reward
  end
  return nil
end

-- The quest's own name, and the one field here that is free text rather than a
-- number. Display only, never identity: a title is localized, so the same quest
-- is named differently on two clients -- the same reason CreatureKey keeps the
-- creature's name outside its own id.
local function validTitle(title)
  if type(title) == "string" and title ~= "" then
    return title
  end
  return nil
end

-- The client's own "N of these killed" sentence, compiled the way every other
-- client string in this addon is (D5): from the GlobalString, so no locale is
-- translated by hand. Placeholders are 1 = creature, 2 = done, 3 = needed, and
-- `order` is what keeps that true in a locale that reorders them.
--
-- A client without the string compiles to nothing and the sweep reads no
-- objectives -- the same capacity-absent tolerance the rest of the addon has,
-- rather than a quest log that fails to be read at all.
local function compileKillTemplate()
  if type(QUEST_MONSTERS_KILLED) ~= "string" then
    return nil
  end
  local pattern, order = GlobalStringPattern.compile(QUEST_MONSTERS_KILLED)
  return { pattern = pattern, order = order }
end

local function fieldsOf(compiled, text)
  if compiled == nil or type(text) ~= "string" then
    return nil
  end
  local captures = { text:match(compiled.pattern) }
  if #captures == 0 then
    return nil
  end
  local fields = {}
  for index, placeholder in ipairs(compiled.order) do
    fields[placeholder] = captures[index]
  end
  return fields
end

-- How many quests one sweep writes to the evidence file. A full log is 20-25
-- entries, so this is the whole of a normal one; the cap is here so a client
-- reporting nonsense cannot fill the ring from a single command.
local SAMPLE_CAP = 25

local QuestLogReader = {}
QuestLogReader.__index = QuestLogReader

-- Captured once, as early as possible (D15, 8.5): both the trust check AND
-- the function itself. Capturing only the boolean would leave every later
-- call reading the GLOBAL by name, which a second addon loading afterwards
-- could still redirect without this reader ever noticing; calling through
-- the reference taken here instead means a later replacement of the global
-- changes nothing this reader does, secure or not.
function QuestLogReader.new()
  return setmetatable({
    trusted = issecurevariable("GetQuestLogRewardXP") == true,
    rewardFn = GetQuestLogRewardXP,
    killTemplate = compileKillTemplate(),
    -- Diagnostic only, and the one number that tells a "this client words it
    -- differently" problem apart from a "this quest asks for feathers" one:
    -- objectives the client typed as kills, against those this reader could
    -- actually read. They can only differ if the template does not match.
    objectivesSeen = 0,
    objectivesRead = 0,
  }, QuestLogReader)
end

-- The kill objectives of one quest. Everything else the client can ask for --
-- items, objects, reputation, a progress bar -- is skipped by TYPE and not by
-- whether the sentence happens to parse, because an item objective that reads
-- "Feather: 3/8" would parse perfectly and mean something else entirely.
function QuestLogReader:objectivesFor(questIndex)
  if type(GetNumQuestLeaderBoards) ~= "function" or type(GetQuestLogLeaderBoard) ~= "function" then
    return nil
  end

  local objectives = nil
  for objectiveIndex = 1, (GetNumQuestLeaderBoards(questIndex) or 0) do
    local text, objectiveType = GetQuestLogLeaderBoard(objectiveIndex, questIndex)
    if objectiveType == "monster" then
      self.objectivesSeen = self.objectivesSeen + 1
      local fields = fieldsOf(self.killTemplate, text)
      local creature = fields and fields[1]
      local done, needed = fields and tonumber(fields[2]), fields and tonumber(fields[3])
      -- A line this reader cannot read is one objective lost, never the quest:
      -- the others are still read, and so is every quest after it.
      if type(creature) == "string" and creature ~= "" and done ~= nil and needed ~= nil and needed >= 1 then
        self.objectivesRead = self.objectivesRead + 1
        objectives = objectives or {}
        objectives[#objectives + 1] = QuestObjective.new({
          creature = creature, done = done, needed = needed,
        })
      end
    end
  end
  return objectives
end

-- `logger`, when given, turns this into spike 0.5's dump: whether the client's
-- own `GetQuestLogRewardXP` is still Blizzard's (D15's provenance check, distinct
-- from the shape check the reader already does everywhere else), and, per quest,
-- both ways D15 names of calling it -- the no-argument form the returned
-- forecasts are actually built from, and the direct `(questId)` form -- so the
-- two can be compared without guessing which one to trust. Passing a logger
-- changes nothing about what is returned; it only makes the sweep observable.
-- `recordEvidence` is optional and only the operator-triggered sweep passes one.
-- That is deliberate: `tick` rescans on every quest-log change, so a sample per
-- quest on the ticker path would push hundreds of rows through a bounded ring and
-- evict the kill evidence the other spikes need.
function QuestLogReader:scan(logger, recordEvidence)
  local originalSelection = GetQuestLogSelection()
  local forecasts = {}
  local secure = issecurevariable("GetQuestLogRewardXP")
  local sampled = recordEvidence ~= nil and {} or nil

  if logger ~= nil then
    logger:debug(("GetQuestLogRewardXP secure: %s"):format(tostring(secure)))
  end

  for index = 1, GetNumQuestLogEntries() do
    -- Position 8 is the questID (D15, citing the FrameXML this addon reads
    -- against), and position 1 is the title. The unread positions between are
    -- kept in the unpacking only to hold the questID's place; the codebase's own
    -- convention for "returned but not needed here" is a repeated `_`, not a
    -- renumbering of the call.
    local title, level, _, _, isHeader, _, isComplete, questId = GetQuestLogTitle(index)

    if not isHeader and validQuestId(questId) then
      SelectQuestLogEntry(index)
      -- `reward` is the raw shape-checked value, kept for the diagnostic dump
      -- below regardless of trust -- spike 0.5 wants to see what the function
      -- actually returns. `trustedReward` is what this reader is willing to
      -- vouch for (8.5's provenance chain starts here): nil, forcing UNKNOWN,
      -- when the global has been replaced, however plausible its number looks.
      local reward = validReward(self.rewardFn())
      local trustedReward = self.trusted and reward or nil
      local origin = trustedReward and QuestXpOrigin.CLIENT or QuestXpOrigin.UNKNOWN

      if logger ~= nil or sampled ~= nil then
        -- Spike 0.5's question: whether the two call forms answer the same thing,
        -- and whether the number is nominal or already scaled. Both forms are read
        -- here so the comparison exists at all.
        local direct = validReward(self.rewardFn(questId))
        if logger ~= nil then
          logger:debug(("quest reward at %.3f: questId=%s level=%s selected=%s direct=%s agree=%s")
            :format(GetTime(), tostring(questId), tostring(level), tostring(reward), tostring(direct),
              tostring(reward == direct)))
        end
        -- Capped, and to the FILE: the chat ring this used to be the only record
        -- in holds 500 lines shared with roughly three per kill, so a sweep taken
        -- an hour into a session was gone before anyone could read it.
        if sampled ~= nil and #sampled < SAMPLE_CAP then
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

ns.adapter.QuestLogReader = QuestLogReader
