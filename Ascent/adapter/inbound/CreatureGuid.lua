-- Ascent - reading a creature's identity out of its GUID.
--
-- A GUID is unitType-0-serverID-instanceID-zoneUID-ID-spawnUID. The level is not
-- in the GUID at all: CombatLogRouter resolves it via UnitTokenFromGUID at the
-- point of death.

local _, ns = ...
ns.adapter = ns.adapter or {}

local CreatureGuid = {}

function CreatureGuid.typeOf(guid)
  if type(guid) ~= "string" then
    return nil
  end
  return guid:match("^([^%-]+)%-")
end

function CreatureGuid.isCreature(guid)
  return CreatureGuid.typeOf(guid) == "Creature"
end

-- The sixth dash-separated field, accepted only for a Creature GUID: a Player or
-- Pet GUID has an entirely different shape at that position, and reading it
-- anyway would produce a false, silently plausible number instead of nothing.
function CreatureGuid.npcId(guid)
  if not CreatureGuid.isCreature(guid) then
    return nil
  end

  local id = guid:match("^[^%-]+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
  if id == nil then
    return nil
  end
  return tonumber(id)
end

ns.adapter.CreatureGuid = CreatureGuid
