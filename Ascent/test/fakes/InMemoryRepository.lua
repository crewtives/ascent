-- Saved variables without the file.
--
-- The Repository port says plain tables only, and this double enforces it rather
-- than merely repeating it: anything with a metatable, a function value, an exotic
-- key or a cycle is rejected with the path to the offending field. A saved
-- variables file silently loses all of those, and the loss only shows up on the
-- next login, as a record that is missing half of itself.
--
-- Consequence worth knowing: domain objects carry metatables, so they cannot be
-- handed to the repository as they are. Something has to convert them at the
-- boundary, and this double is what will force that decision instead of letting it
-- be discovered in the client.

local _, ns = ...
ns.fakes = ns.fakes or {}

local STORABLE = { boolean = true, number = true, string = true }

local function assertStorable(value, path, seen)
  local kind = type(value)
  if STORABLE[kind] or kind == "nil" then
    return
  end
  if kind ~= "table" then
    error(("InMemoryRepository: %s is a %s; saved variables hold only tables, numbers, strings and booleans")
      :format(path, kind), 0)
  end
  if getmetatable(value) ~= nil then
    error(("InMemoryRepository: %s has a metatable, which saved variables drop on the way out; "
      .. "convert it to a plain table before storing"):format(path), 0)
  end

  seen = seen or {}
  if seen[value] then
    error(("InMemoryRepository: %s is part of a cycle, which saved variables cannot hold"):format(path), 0)
  end
  seen[value] = true

  for key, item in pairs(value) do
    local keyKind = type(key)
    if keyKind ~= "string" and keyKind ~= "number" then
      error(("InMemoryRepository: %s has a %s key; saved variables hold only string and number keys")
        :format(path, keyKind), 0)
    end
    assertStorable(item, ("%s.%s"):format(path, tostring(key)), seen)
  end

  seen[value] = nil
end

local InMemoryRepository = {}
InMemoryRepository.__index = InMemoryRepository

function InMemoryRepository.new(seed)
  local repository = setmetatable({
    data = seed or {},
    accountNames = (seed or {}).questNames or {},
    legacy = nil,
    writes = 0,
  }, InMemoryRepository)

  return ns.core.Port.verify(ns.core.Repository, repository, "InMemoryRepository")
end

local function touch(self)
  self.writes = self.writes + 1
end

function InMemoryRepository:schemaVersion() return self.data.schemaVersion end

function InMemoryRepository:setSchemaVersion(version)
  self.data.schemaVersion = version
  touch(self)
end

function InMemoryRepository:currentRecord() return self.data.current end

function InMemoryRepository:saveCurrentRecord(record)
  assertStorable(record, "currentRecord")
  self.data.current = record
  touch(self)
end

function InMemoryRepository:completedRecord(level)
  return (self.data.completed or {})[level]
end

function InMemoryRepository:saveCompletedRecord(record)
  assertStorable(record, "completedRecord")
  self.data.completed = self.data.completed or {}
  self.data.completed[record.level] = record
  touch(self)
end

function InMemoryRepository:completedLevels()
  local levels = {}
  for level in pairs(self.data.completed or {}) do
    levels[#levels + 1] = level
  end
  table.sort(levels)
  return levels
end

function InMemoryRepository:settings() return self.data.settings end

function InMemoryRepository:saveSettings(settings)
  assertStorable(settings, "settings")
  self.data.settings = settings
  touch(self)
end

function InMemoryRepository:questRewards() return self.data.questRewards or {} end

function InMemoryRepository:saveQuestRewards(rewards)
  assertStorable(rewards, "questRewards")
  self.data.questRewards = rewards
  touch(self)
end

-- Account-wide, so it lives outside `data` -- which archiveIncompatible and clear
-- both replace. Keeping it in there would have a character's reset wipe the names
-- every other character on the account is reading.
function InMemoryRepository:questNames() return self.accountNames end

function InMemoryRepository:saveQuestNames(names)
  assertStorable(names, "questNames")
  self.accountNames = names
  touch(self)
end

-- Options are account-wide and were never the problem, so archiving a character's
-- incompatible history keeps them, exactly as clear() does.
function InMemoryRepository:archiveIncompatible()
  self.legacy = self.data
  self.data = { settings = self.data.settings }
  touch(self)
end

function InMemoryRepository:clear()
  self.data = { settings = self.data.settings }
  touch(self)
end

ns.fakes.InMemoryRepository = InMemoryRepository
