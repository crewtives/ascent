-- Ascent - one "kill N of these" line of an accepted quest.
--
-- Only kills. A quest that asks for eight feathers is also asking the player to
-- kill something, but how many deaths a feather costs is a drop rate, and this
-- addon does not know drop rates and will not guess one. An objective this model
-- holds is one the client itself typed as a monster kill.
--
-- The creature is a name and nothing else, because a name is all the quest log
-- gives: its objectives carry no creature id. Matching it against what the
-- character has killed is therefore a name comparison, and it fails softly --
-- "Amani troll slain" names a family of creatures and no single one.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard

local QuestObjective = {}
QuestObjective.__index = QuestObjective

-- fields: creature (name), done, needed
function QuestObjective.new(fields)
  if type(fields) ~= "table" then
    error("QuestObjective.new expects a table of fields", 2)
  end
  if type(fields.creature) ~= "string" or fields.creature == "" then
    error("QuestObjective.creature must be a non-empty name", 2)
  end

  local needed = Guard.positiveInteger(fields.needed, "QuestObjective.needed")
  local done = Guard.nonNegativeInteger(fields.done, "QuestObjective.done")

  return setmetatable({
    creature = fields.creature,
    -- A client can report more done than needed; letting that through would make
    -- `remaining` negative and subtract experience from an estimate downstream.
    done = math.min(done, needed),
    needed = needed,
  }, QuestObjective)
end

function QuestObjective:remaining()
  return self.needed - self.done
end

function QuestObjective:isComplete()
  return self:remaining() == 0
end

ns.core.QuestObjective = QuestObjective
