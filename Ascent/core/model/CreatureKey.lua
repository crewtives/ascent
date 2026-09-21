-- Ascent - how a creature is identified for aggregation.
--
-- Two facts arrive from different places and neither is guaranteed: the chat
-- message names the creature, the combat log carries its id, and its level is only
-- readable if some unit token still pointed at it when it died.
--
-- The experience a creature gives depends on its level, and around a quarter of
-- creature types spawn across a level range, so `(id, level)` is the unit of
-- aggregation. When either half is missing the key says so instead of guessing:
-- an unknown bucket is honest, an imputed level quietly poisons the averages.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local Stored = ns.core.Stored
local Packed = ns.core.Packed

local UNKNOWN = "?"

local CreatureKey = {}
CreatureKey.__index = CreatureKey

function CreatureKey.new(npcId, level, name)
  if npcId ~= nil then
    Guard.positiveInteger(npcId, "CreatureKey.npcId")
  end
  if level ~= nil then
    Guard.positiveInteger(level, "CreatureKey.level")
  end

  return setmetatable({
    npcId = npcId,
    level = level,
    name = name, -- for display only; never part of identity, because it is localized
  }, CreatureKey)
end

function CreatureKey.unknown(name)
  return CreatureKey.new(nil, nil, name)
end

function CreatureKey:hasKnownType()
  return self.npcId ~= nil
end

function CreatureKey:hasKnownLevel()
  return self.level ~= nil
end

function CreatureKey:isFullyKnown()
  return self:hasKnownType() and self:hasKnownLevel()
end

-- The stable string used to index aggregates and to persist them.
function CreatureKey:id()
  return ("%s:%s"):format(
    self.npcId and tostring(self.npcId) or UNKNOWN,
    self.level and tostring(self.level) or UNKNOWN
  )
end

function CreatureKey:equals(other)
  return other ~= nil and getmetatable(other) == CreatureKey and self:id() == other:id()
end

-- Deliberately no __tostring. In the PUC Lua 5.1 the client runs, `("%s"):format(key)`
-- raises "string expected, got table" even with one defined, while LuaJIT honours it
-- -- so the trap would pass the suite and fail in the game. `key:id()` is the one
-- way to get a creature's string form, and it is also what the aggregates persist.


-- The three fields a creature is written as, in order, named once here because the
-- per-creature aggregate of a level record embeds the same three as its tail.
-- `false` rather than nil: a leading nil makes the length of the table it is in
-- undefined, and the first of these three is absent whenever the creature is.
function CreatureKey:fields()
  return { self.npcId or false, self.level or false, self.name or false }
end

function CreatureKey.fromFields(fields, offset)
  return CreatureKey.new(
    Stored.positiveInteger(Packed.number(fields, offset)),
    Stored.positiveInteger(Packed.number(fields, offset + 1)),
    Packed.text(fields, offset + 2))
end

-- The on-disk form. An absent half stays absent rather than becoming zero: saying
-- the level is unknown is the entire reason this model exists, and a creature of
-- level nil is not a creature of level 0.
function CreatureKey:toStored()
  return Packed.join(self:fields())
end

-- Anything that is a string restores to a key, because a key with both halves
-- unknown is one of this model's real answers rather than a failure to read one.
-- Only something that was never a record at all comes back as nil.
function CreatureKey.restore(stored)
  if type(stored) ~= "string" then
    return nil
  end

  return CreatureKey.fromFields(Packed.split(stored), 1)
end

ns.core.CreatureKey = CreatureKey
