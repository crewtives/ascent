-- Ascent - the real Repository, backed by two client-managed globals.
--
-- `AscentDB` is account-wide (declared `SavedVariables`); `AscentCharDB` is
-- per-character (declared `SavedVariablesPerCharacter`, so the client itself keeps
-- one file per character and realm -- nothing here has to key by name or realm to
-- get that separation; the file the client loads already is this character's).
--
-- D8 fixes what lives where:
--   AscentDB      -- options, and the quest name directory. Account-wide, because
--                    what a quest is CALLED is the client's answer, the same on
--                    every alt -- unlike which quests this character has seen.
--   AscentCharDB  -- schemaVersion, the level in progress, closed levels, learned
--                    quest rewards. All of it this character's, none of it shared.
--
-- Both globals are created by the client from disk before ADDON_LOADED fires, or
-- left nil on a character that has never saved anything -- this is the file that
-- fills them in either case.

local _, ns = ...
ns.adapter = ns.adapter or {}

local SavedVariablesRepository = {}
SavedVariablesRepository.__index = SavedVariablesRepository

function SavedVariablesRepository.new()
  AscentDB = AscentDB or {}
  AscentCharDB = AscentCharDB or {}

  return ns.core.Port.verify(ns.core.Repository, setmetatable({}, SavedVariablesRepository),
    "SavedVariablesRepository")
end

function SavedVariablesRepository:schemaVersion()
  return AscentCharDB.schemaVersion
end

function SavedVariablesRepository:setSchemaVersion(version)
  AscentCharDB.schemaVersion = version
end

function SavedVariablesRepository:currentRecord()
  return AscentCharDB.current
end

function SavedVariablesRepository:saveCurrentRecord(record)
  AscentCharDB.current = record
end

function SavedVariablesRepository:completedRecord(level)
  return (AscentCharDB.completed or {})[level]
end

function SavedVariablesRepository:saveCompletedRecord(record)
  AscentCharDB.completed = AscentCharDB.completed or {}
  AscentCharDB.completed[record.level] = record
end

function SavedVariablesRepository:completedLevels()
  local levels = {}
  for level in pairs(AscentCharDB.completed or {}) do
    levels[#levels + 1] = level
  end
  table.sort(levels)
  return levels
end

function SavedVariablesRepository:settings()
  return AscentDB.settings
end

function SavedVariablesRepository:saveSettings(settings)
  AscentDB.settings = settings
end

function SavedVariablesRepository:questRewards()
  return AscentCharDB.questRewards or {}
end

function SavedVariablesRepository:saveQuestRewards(rewards)
  AscentCharDB.questRewards = rewards
end

function SavedVariablesRepository:questNames()
  AscentDB.questNames = AscentDB.questNames or {}
  return AscentDB.questNames
end

function SavedVariablesRepository:saveQuestNames(names)
  AscentDB.questNames = names
end

-- Keeps what is account-wide untouched -- the options and the quest names live in
-- AscentDB, which this never archives -- and puts everything else in one pocket
-- instead of scattering fields the next version would have to know to look for.
-- The names survive on purpose: they describe the client, not the character's
-- history, so throwing them away would lose something this version can still read.
function SavedVariablesRepository:archiveIncompatible()
  local legacy = AscentCharDB
  AscentCharDB = { legacy = legacy }
end

function SavedVariablesRepository:clear()
  AscentCharDB = {}
end

ns.adapter.SavedVariablesRepository = SavedVariablesRepository
