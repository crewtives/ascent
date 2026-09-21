-- Ascent - the store the domain talks to, and the migration chain behind it.
--
-- The Repository port deals in plain tables because that is all saved variables can
-- hold. The rest of the addon deals in records with methods and invariants. This is
-- the one place that knows both, so nothing else has to remember to convert -- and
-- the repository double, which rejects anything carrying a metatable, fails the
-- suite the moment something tries.
--
-- It also owns the stored format's version, and there are only two outcomes on load:
--
--   the data is at this version, or can be walked up to it       -> it is kept
--   anything else -- newer, unknown, or a migration that threw   -> it is archived
--
-- Loading always wins over preserving. The addon must never refuse to start because
-- of what a previous version, a half-finished logout or the player's own text editor
-- left behind; it moves that aside, says so, and starts clean.
--
-- Migrations run on STORED TABLES and are handed the repository, never live records.
-- A migration that had to build the model of the version it upgrades from would
-- force that version's code to be kept forever.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local LevelRecord = ns.core.LevelRecord
local SchemaVersion = ns.core.SchemaVersion

local RecordStore = {}
RecordStore.__index = RecordStore

-- migrations[n] upgrades data written at version n to version n + 1. A version with
-- no step archives the data rather than guessing at it, so every version below the
-- current one has to be here -- including the ones that need no conversion.
RecordStore.MIGRATIONS = {
  -- 1 -> 2: the per-place breakdown of a level. Deliberately does nothing, and is
  -- deliberately not absent. The stored shape only GAINED a field, and a record
  -- written without it restores with no places at all rather than with a reserved
  -- entry that nobody observed -- so there is nothing to convert. Leaving this out
  -- would not mean "no conversion needed": it would archive every existing
  -- character's history on first login after the update.
  [1] = function() end,

  -- 2 -> 3: `seededXp` on a level record. Nothing to convert, and deliberately
  -- present for the same reason as the step above -- a record written at 2 restores
  -- with seededXp nil, which is the honest answer and not a converted one.
  [2] = function() end,
}

function RecordStore.new(options)
  options = options or {}

  if options.repository == nil then
    error("RecordStore needs a repository", 2)
  end
  Port.verify(ns.core.Repository, options.repository, "RecordStore repository")

  return setmetatable({
    repository = options.repository,
    migrations = options.migrations or RecordStore.MIGRATIONS,
    version = options.version or SchemaVersion.CURRENT,

    loaded = false,
    archived = false,   -- stored data this version could not read was moved aside
    discarded = false,  -- a single record could not be restored and was dropped
  }, RecordStore)
end

-- ---------------------------------------------------------------------------
-- Loading and migrating
-- ---------------------------------------------------------------------------

function RecordStore:migrate(from)
  -- Not a version, or written by a build newer than this one. Walking forward is
  -- the only direction a migration chain has.
  if type(from) ~= "number" or from ~= from or from % 1 ~= 0 or from > self.version then
    return false
  end

  for version = from, self.version - 1 do
    local step = self.migrations[version]
    if type(step) ~= "function" then
      return false
    end
    -- A migration that throws leaves the data half-converted, which is precisely
    -- the state worth archiving rather than handing to the rest of the addon.
    if not pcall(step, self.repository) then
      return false
    end
  end

  self.repository:setSchemaVersion(self.version)
  return true
end

function RecordStore:load()
  local stored = self.repository:schemaVersion()

  if stored == nil then
    -- A character nobody has recorded yet. Nothing to migrate; stamp the format so
    -- the next version knows where it is starting from.
    self.repository:setSchemaVersion(self.version)
  elseif stored ~= self.version and not self:migrate(stored) then
    self.repository:archiveIncompatible()
    self.repository:setSchemaVersion(self.version)
    self.archived = true
  end

  self.loaded = true
  return self
end

local function assertLoaded(self)
  if not self.loaded then
    error("RecordStore: load() has to run before anything is read or written; "
      .. "reading first would hand the domain data from a format it does not know", 3)
  end
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

-- The level being played, or nil when there is none. A record that cannot be
-- restored at all counts as none: the caller opens a seeded one and the level goes
-- on being recorded, which is worth more than the fragment that was unreadable.
function RecordStore:current()
  assertLoaded(self)

  local stored = self.repository:currentRecord()
  if stored == nil then
    return nil
  end

  local record = LevelRecord.restore(stored)
  if record == nil then
    self.discarded = true
  end
  return record
end

-- A nil record is how the caller says there is no level in progress, which is the
-- state a character at the client's maximum level is in. Leaving the previous
-- snapshot in the slot would have the next login treat a level whose history is
-- already written as one still being played, and overwrite the real record with it.
function RecordStore:saveCurrent(record)
  assertLoaded(self)

  if record == nil then
    self.repository:saveCurrentRecord(nil)
    return nil
  end

  self.repository:saveCurrentRecord(record:toStored())
  return record
end

-- Nil is a real answer and stays distinguishable from a level recorded as all
-- zeroes: "you never played this level with the addon on" and "you played it and
-- gained nothing" are different things to show a player.
function RecordStore:completed(level)
  assertLoaded(self)

  local stored = self.repository:completedRecord(level)
  if stored == nil then
    return nil
  end

  local record = LevelRecord.restore(stored)
  if record == nil then
    self.discarded = true
  end
  return record
end

function RecordStore:saveCompleted(record)
  assertLoaded(self)
  self.repository:saveCompletedRecord(record:toStored())
  return record
end

function RecordStore:completedLevels()
  assertLoaded(self)
  return self.repository:completedLevels()
end

function RecordStore:clear()
  assertLoaded(self)
  self.repository:clear()
end

ns.core.RecordStore = RecordStore
