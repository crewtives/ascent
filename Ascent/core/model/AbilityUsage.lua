-- Ascent - how often one ability was used during a level.
--
-- Keyed by spell id where there is one, and by a reserved synthetic key where
-- there is not: auto attacks arrive as swing subevents with no spell attached, and
-- letting the domain meet a nil key there would be the first of many nil checks.
--
-- Auto attacks are counted but flagged, because for most classes they would top
-- every ranking and drown the abilities the player actually chose to press.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local Guard = ns.core.Guard
local Stored = ns.core.Stored
local Packed = ns.core.Packed
local AbilityKey = ns.core.AbilityKey

local AbilityUsage = {}
AbilityUsage.__index = AbilityUsage

-- Derived from AbilityKey rather than repeated, so adding a reserved key in one
-- place is enough.
local AUTO_ATTACK_KEYS = {}
for _, key in Frozen.each(AbilityKey) do
  AUTO_ATTACK_KEYS[key] = true
end

function AbilityUsage.new(key, name)
  if type(key) == "number" then
    Guard.positiveInteger(key, "AbilityUsage.key")
  elseif type(key) == "string" then
    if not AUTO_ATTACK_KEYS[key] then
      error("AbilityUsage: a string key must be a reserved AbilityKey, got " .. key, 2)
    end
  else
    error("AbilityUsage: key must be a spell id or a reserved AbilityKey, got " .. tostring(key), 2)
  end

  return setmetatable({
    key = key,
    name = name, -- cached for display when the client cannot resolve the id later
    count = 0,
  }, AbilityUsage)
end

function AbilityUsage:record(times)
  times = times or 1
  Guard.positiveInteger(times, "AbilityUsage.record times")
  self.count = self.count + times
  return self.count
end

function AbilityUsage:isAutoAttack()
  return AUTO_ATTACK_KEYS[self.key] == true
end


-- key, count, name. The name is last because it is the only free text in the record
-- and reads better at the end of the line.
function AbilityUsage:toStored()
  return Packed.join({ self.key, self.count, self.name or false })
end

-- The key is the identity, so a key that is neither a spell id nor one of the
-- reserved synthetic ones leaves nothing to restore.
function AbilityUsage.restore(stored)
  if type(stored) ~= "string" then
    return nil
  end

  local fields = Packed.split(stored)
  local key = Packed.text(fields, 1)

  if key ~= nil and tonumber(key) ~= nil then
    key = Stored.positiveInteger(tonumber(key))
  elseif not AUTO_ATTACK_KEYS[key] then
    key = nil
  end
  if key == nil then
    return nil
  end

  local usage = AbilityUsage.new(key, Packed.text(fields, 3))
  usage.count = Stored.count(Packed.number(fields, 2), 0)
  return usage
end

ns.core.AbilityUsage = AbilityUsage
