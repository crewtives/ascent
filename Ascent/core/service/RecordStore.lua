-- Ascent - the store the domain talks to, and the migration chain behind it.
--
-- The Repository port deals in plain tables because that is all saved variables can
-- hold; the rest of the addon deals in records with methods and invariants. This is
-- the one place that converts between them, and the repository test double rejects
-- anything carrying a metatable.
--
-- It also owns the stored format's version, and there are only two outcomes on load:
--
--   the data is at this version, or can be walked up to it       -> it is kept
--   anything else -- newer, unknown, or a migration that threw   -> it is archived
--
-- Loading always wins over preserving: whatever a previous version, a half-finished
-- logout or a hand edit left behind is moved aside, reported, and the addon starts
-- clean rather than refusing to start.
--
-- Migrations run on stored tables and are handed the repository, never live records,
-- so no old version's model code has to be kept.

local _, ns = ...
ns.core = ns.core or {}

local Packed = ns.core.Packed
local Port = ns.core.Port
local LevelRecord = ns.core.LevelRecord
local SchemaVersion = ns.core.SchemaVersion

-- Inserts a blank field at position 3 of one packed creature line, the whole of the
-- 3 -> 4 conversion: kills and experience stay put, the creature's key moves one to
-- the right, and the gap holds the unknown group size.
--
-- Built by hand rather than with table.insert: on LuaJIT table.insert past the end
-- of a table raises, so one corrupted line with fewer than two fields would fail the
-- step and archive the character's whole history.
local function widenCreature(fields)
  local shifted = { fields[1], fields[2] or false, false }
  for index = 3, #fields do
    shifted[#shifted + 1] = fields[index]
  end
  return Packed.join(shifted)
end

local function widenCreatures(stored)
  if type(stored) ~= "table" or type(stored.creatures) ~= "string"
    or stored.creatures == "" then
    return stored
  end

  local lines = Packed.unlist(stored.creatures, function(fields) return fields end)
  stored.creatures = Packed.list(lines, widenCreature)
  return stored
end

local RecordStore = {}
RecordStore.__index = RecordStore

-- migrations[n] upgrades data written at version n to version n + 1. A version with
-- no step archives the data rather than guessing at it, so every version below the
-- current one has to be here -- including the ones that need no conversion.
RecordStore.MIGRATIONS = {
  -- 1 -> 2: the per-place breakdown of a level. Empty but required: the stored shape
  -- only gained a field, and a record without it restores with no places. A missing
  -- step would archive every existing character's history.
  [1] = function() end,

  -- 2 -> 3: `seededXp` on a level record. Empty but required, as above: a record
  -- written at 2 restores with seededXp nil, which is correct.
  [2] = function() end,

  -- 3 -> 4: the size of the group a creature's kills were paid to. The group is
  -- written ahead of the creature's key, so every stored creature line shifts by a
  -- field; unconverted, a line would be read with the npc id where the group belongs.
  --
  -- The gap is blank, not one: writing "1" would pass off unobserved group sizes as
  -- solo measurements. Blank means unknown, and the estimator can decline to price a
  -- kill from it.
  --
  -- Only the packed creature text moves. The level's sums (xpTotal, xpBySource,
  -- killsWithXp) live outside it and are untouched.
  [3] = function(repository)
    local current = widenCreatures(repository:currentRecord())
    if current ~= nil then
      repository:saveCurrentRecord(current)
    end
    for _, level in ipairs(repository:completedLevels()) do
      local stored = widenCreatures(repository:completedRecord(level))
      if stored ~= nil then
        repository:saveCompletedRecord(stored)
      end
    end
  end,

  -- 4 -> 5: the client sources a level was recorded without. Empty but required: a
  -- record written at 4 came from Classic Era or Burning Crusade Classic, which have
  -- both sources, so it correctly restores with no mark.
  [4] = function() end,
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
  -- Not a version, or written by a newer build: migrations only walk forward.
  if type(from) ~= "number" or from ~= from or from % 1 ~= 0 or from > self.version then
    return false
  end

  for version = from, self.version - 1 do
    local step = self.migrations[version]
    if type(step) ~= "function" then
      return false
    end
    -- A migration that throws leaves the data half-converted, so it is archived
    -- rather than handed to the rest of the addon.
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
    -- A character never recorded. Nothing to migrate; stamp the format so the next
    -- version knows where it starts from.
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
-- restored counts as none: the caller opens a seeded one and recording goes on.
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

-- A nil record means no level in progress, as for a character at the client's
-- maximum level. The slot is cleared, or the next login would treat an already
-- completed level as still being played and overwrite its real record.
function RecordStore:saveCurrent(record)
  assertLoaded(self)

  if record == nil then
    self.repository:saveCurrentRecord(nil)
    return nil
  end

  self.repository:saveCurrentRecord(record:toStored())
  return record
end

-- Nil is a real answer, distinct from a level recorded as all zeroes: "never
-- played with the addon on" is not "played and gained nothing".
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
