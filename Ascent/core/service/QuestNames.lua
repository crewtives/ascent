-- Ascent - what each quest is called.
--
-- One directory of quest names that every surface asks, so a quest is never
-- named in one view and numbered in another. It is fed at the composition root
-- by whatever sees a name: the quest log sweep (`GetQuestLogTitle` for every
-- accepted quest) and the quest dialogue, the only place the client names a
-- quest the character is not carrying.
--
-- Not stored per level: a name is the same for every level a quest paid, and one
-- learned after the turn-in must still reach a level already closed. Account-wide
-- because the name is the client's, identical on every character (learned
-- rewards, by contrast, are per character). Bounded by the number of quests in
-- the game, so there is no retention policy.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port

local QuestNames = {}
QuestNames.__index = QuestNames

-- options: repository (port). Loads whatever was saved; a fresh install starts
-- empty, meaning "no quest is named yet", not an error.
function QuestNames.new(options)
  options = options or {}
  if options.repository == nil then
    error("QuestNames needs a repository", 2)
  end
  Port.verify(ns.core.Repository, options.repository, "QuestNames repository")

  return setmetatable({
    repository = options.repository,
    names = options.repository:questNames(),
  }, QuestNames)
end

-- Both arguments come from the client and are shape-checked, so a bad id or name
-- is dropped instead of persisted.
local function usable(questId, name)
  return type(questId) == "number" and questId >= 1 and questId % 1 == 0
    and type(name) == "string" and name ~= ""
end

-- Returns whether this call added a name. It persists only on a change: the
-- sweep re-reads the whole quest log on every quest-log event, which would
-- otherwise mean hundreds of writes a minute.
--
-- A known name is never overwritten. The client is consistent about titles, so a
-- different second answer (a truncated string, another addon's replacement
-- function) is the suspect one.
function QuestNames:remember(questId, name)
  if not usable(questId, name) or self.names[questId] ~= nil then
    return false
  end

  self.names[questId] = name
  self.repository:saveQuestNames(self.names)
  return true
end

-- nil is a real answer for surfaces to word: neither Classic Era nor Burning
-- Crusade Classic can name a quest by id once it has left the log, so a quest
-- turned in before the addon saw it has no name.
function QuestNames:nameFor(questId)
  return self.names[questId]
end

-- How a quest is written on screen, shared by the bar's popup and the panel so
-- both label it the same way. `locale` is an argument, as in XpBarText, because
-- core/ never reaches the client.
-- Static and nil-tolerant, so a view built without a directory (the options
-- preview, a test, a failed construction) still gets the same fallback label.
function QuestNames.labelOf(names, locale, questId)
  local name = names ~= nil and names:nameFor(questId) or nil
  return name or locale:get(ns.core.TextKey.PANEL_QUEST, tostring(questId))
end

-- How many quests the directory can name, for the diagnostic command: it tells
-- "nothing is named" apart from "this quest is not named".
function QuestNames:count()
  local total = 0
  for _ in pairs(self.names) do
    total = total + 1
  end
  return total
end

ns.core.QuestNames = QuestNames
