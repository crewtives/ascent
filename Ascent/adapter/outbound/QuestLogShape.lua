-- Ascent - what a quest looks like, whichever API was asked.
--
-- Two readers implement the QuestLog port and walk the log differently: one
-- selects an entry and asks about the selection, the other asks about a quest id.
-- Everything after the read lives here -- which numbers are a quest id, a level,
-- a reward; how the client's "N of these killed" sentence is parsed; how much of
-- a sweep is worth writing down -- so both readers accept and refuse exactly the
-- same client answers.

local _, ns = ...
ns.adapter = ns.adapter or {}

local QuestObjective = ns.core.QuestObjective
local GlobalStringPattern = ns.adapter.GlobalStringPattern

local QuestLogShape = {}

-- How many quests one sweep writes to the evidence file. A full log is 20-25
-- entries, so this is the whole of a normal one; the cap is here so a client
-- reporting nonsense cannot fill the ring from a single command.
QuestLogShape.SAMPLE_CAP = 25

function QuestLogShape.validQuestId(questId)
  return type(questId) == "number" and questId >= 1 and questId % 1 == 0
end

function QuestLogShape.validLevel(level)
  if type(level) == "number" and level >= 1 and level % 1 == 0 then
    return level
  end
  return nil
end

function QuestLogShape.validReward(reward)
  if type(reward) == "number" and reward >= 0 and reward % 1 == 0 then
    return reward
  end
  return nil
end

-- The quest's own name, and the one field here that is free text rather than a
-- number. Display only, never identity: a title is localized, so the same quest
-- is named differently on two clients -- the same reason CreatureKey keeps the
-- creature's name outside its own id.
function QuestLogShape.validTitle(title)
  if type(title) == "string" and title ~= "" then
    return title
  end
  return nil
end

-- The client's own "N of these killed" sentence, compiled from the GlobalString
-- like every other client string here, so no locale is translated by hand.
-- Placeholders are 1 = creature, 2 = done, 3 = needed, and `order` keeps that
-- true in a locale that reorders them.
--
-- A client without the string compiles to nothing and the sweep reads no
-- objectives, rather than failing to read the quest log at all.
function QuestLogShape.killTemplate()
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

-- One kill objective, or nil for a line this reader cannot read. That costs the
-- one objective, never the quest: its other objectives and every later quest are
-- still read.
function QuestLogShape.killObjective(compiled, text)
  local fields = fieldsOf(compiled, text)
  local creature = fields and fields[1]
  local done, needed = fields and tonumber(fields[2]), fields and tonumber(fields[3])
  if type(creature) ~= "string" or creature == "" or done == nil or needed == nil or needed < 1 then
    return nil
  end
  return QuestObjective.new({ creature = creature, done = done, needed = needed })
end

ns.adapter.QuestLogShape = QuestLogShape
