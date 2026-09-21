-- Ascent - one "kill N of these" line of an accepted quest.
--
-- Only kills. A quest that asks for eight feathers is also asking the player to
-- kill something, but how many deaths a feather costs is a drop rate, and this
-- addon does not know drop rates and will not guess one (design.md D3). An
-- objective this model holds is one the client itself typed as a monster kill.
--
-- The creature is a NAME and nothing else, because a name is all the quest log
-- gives: its objectives carry no creature id. That is why matching it against
-- what the character has actually killed is a name comparison, and why it fails
-- softly -- "Amani troll slain" names a family of creatures and no single one.

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
    -- A client that reports more done than needed is not worth arguing with, and
    -- letting it through would make `remaining` negative -- which would then
    -- subtract experience from an estimate further downstream.
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
