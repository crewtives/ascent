-- Ascent - what each quest is called.
--
-- Every surface that shows a quest shows the same quest, so there is one place
-- that knows their names and every surface asks it. That is the whole point of
-- this file: the panel showed a quest named in one tab and numbered in the next
-- because the name reached one of them and not the other, and the fix for that
-- is not a second wire, it is one directory with many feeders.
--
-- WHAT FEEDS IT. Anything that ever sees a name: the quest log sweep, which
-- reads `GetQuestLogTitle` for every accepted quest, and the quest dialogue,
-- which is the only place a client names a quest it is not carrying. Feeding
-- happens at the composition root, so nothing in here knows where a name came
-- from and no service grows a dependency on this one just to pass a string
-- along.
--
-- WHY IT IS NOT KEPT WITH THE LEVEL. A name is not the level's -- it is the
-- same string for every character on the account and for every level that quest
-- ever paid, so keeping a copy per level record would write it once per
-- turn-in, and a name learned AFTER the turn-in (the usual case: the quest sat
-- in the log for an hour before being handed in) could never reach the record
-- that was already closed. Kept here, a quest seen once is named everywhere,
-- including in a level that was finished before anyone knew what it was called.
--
-- WHY IT IS ACCOUNT-WIDE. Which quests a character saw is that character's
-- (that is why the learned REWARDS are per character), but what quest 8887 is
-- called is the client's, identical on every alt. Account-wide, an alt walking
-- the same zone reads names the main already paid for.
--
-- WHAT BOUNDS IT. The number of quests the game has: a few thousand, of which a
-- levelling character sees hundreds. It never grows past what the client can
-- name, so there is no retention policy here -- a cap would be a rule that
-- never fires. The cost is measured in the saved-data budget alongside the rest.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port

local QuestNames = {}
QuestNames.__index = QuestNames

-- options: repository (port). Loads whatever was saved; a fresh install starts
-- empty, which reads as "no quest is named yet", not as an error.
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

-- Both arguments are shape-checked rather than trusted, because both come from
-- the client: an id that is not a quest and a name that is not a name are
-- dropped instead of being written to disk, where they would outlive the
-- session that produced them.
local function usable(questId, name)
  return type(questId) == "number" and questId >= 1 and questId % 1 == 0
    and type(name) == "string" and name ~= ""
end

-- Returns whether this call taught the directory something. Persisting only on a
-- change is not an optimisation detail: the sweep re-reads the whole quest log
-- on every quest-log event, so a directory that saved on every call would push a
-- few hundred writes a minute through the repository for a map that did not move.
--
-- A name already known is never overwritten by a different one. The client is
-- consistent about titles, so a second answer means something odd happened -- a
-- truncated string, another addon's replacement function -- and the first,
-- quieter answer is the one that came from a clean read.
function QuestNames:remember(questId, name)
  if not usable(questId, name) or self.names[questId] ~= nil then
    return false
  end

  self.names[questId] = name
  self.repository:saveQuestNames(self.names)
  return true
end

-- nil is a real answer, and the surfaces are expected to say so in their own
-- words: a quest turned in before this addon ever saw it has no name here and no
-- way to get one -- neither supported client can name a quest by id once it has
-- left the log.
function QuestNames:nameFor(questId)
  return self.names[questId]
end

-- How a quest is written on screen, for every surface that writes one. It lives
-- here and not in a view because there are two views -- the bar's popup and the
-- panel -- and two of these is how the same quest ends up named in one place and
-- numbered in the other, which is the bug this whole directory exists to close.
-- `locale` arrives as an argument for the reason XpBarText takes one: core/ never
-- reaches the client, and a literal kept here would be a second source of truth
-- for text that is already translated.
-- Static and nil-tolerant on purpose: a view built without a directory -- in the
-- options preview, in a test, in a client where construction failed -- still has
-- to write the quest somehow, and if each view carried that fallback itself there
-- would be two of them again.
function QuestNames.labelOf(names, locale, questId)
  local name = names ~= nil and names:nameFor(questId) or nil
  return name or locale:get(ns.core.TextKey.PANEL_QUEST, tostring(questId))
end

-- How many quests the directory can name, for the diagnostic command: the
-- honest way to tell "nothing is named" apart from "this quest is not named".
function QuestNames:count()
  local total = 0
  for _ in pairs(self.names) do
    total = total + 1
  end
  return total
end

ns.core.QuestNames = QuestNames
