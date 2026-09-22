-- Ascent - the real PlayerState, read straight off the "player" unit.
--
-- Every value the port promises is a plain number, string or boolean; this is the
-- one place that turns client calls into that shape, so nothing downstream has to
-- know a unit token exists.

local _, ns = ...
ns.adapter = ns.adapter or {}

local PlaceContext = ns.core.PlaceContext
-- Everything below is read from the client and handed straight to core/, so it
-- passes the same guard the inbound routers use. A closed read comes back nil,
-- and what nil means is decided per call below, mostly by the sanitising already
-- needed for a client that answers "" or 0 while a zone loads.
local readable = ns.adapter.Readable.value

-- The client's own instance vocabulary, translated once. Any other kind --
-- "scenario" exists on other flavours -- is deliberately absent: it answers nil
-- and the domain files that experience in the reserved entry rather than under a
-- kind chosen by resemblance.
local CONTEXT_BY_INSTANCE_TYPE = {
  none = PlaceContext.WORLD,
  party = PlaceContext.DUNGEON,
  raid = PlaceContext.RAID,
  pvp = PlaceContext.BATTLEGROUND,
  arena = PlaceContext.ARENA,
}

-- Guarded before the comparison, an operation a closed value raises on. An
-- unreadable pair answers zero, the same "nothing to show" as a unit with no
-- maximum.
local function fraction(current, max)
  current, max = readable(current), readable(max)
  if type(current) ~= "number" or type(max) ~= "number" or max <= 0 then
    return 0
  end
  return current / max
end

-- An identifier the model would refuse. The client answers 0 or nil while a zone is
-- still loading, and PlaceKey raises on anything that is not a positive integer,
-- because there it would be the addon's own bug. Sanitising is this layer's job.
local function positiveId(value)
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
    return nil
  end
  return value
end

-- "" is what the client returns for zone text mid-loading screen, and an empty name
-- is not a name.
local function displayName(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  return text
end

-- The name of the map, not of whatever the client calls the zone this instant.
-- Step into an indoor area and `GetZoneText()` answers with the building's name
-- ("Duskwither Spire") while the map id stays the zone's ("Eversong Woods"). A
-- place adopts only a name it is missing (LevelRecord:placeEntry), so whichever
-- name arrived first would label the whole level. The map's own name is one name
-- per identity; the zone text is the fallback for a client that lacks this call.
local function mapName(mapId)
  if mapId == nil or C_Map == nil or C_Map.GetMapInfo == nil then
    return nil
  end
  -- Guarded before it is indexed: reading a field off a closed table is one of
  -- the operations that raises.
  local info = readable(C_Map.GetMapInfo(mapId))
  return type(info) == "table" and info.name or nil
end

local WowPlayerState = {}
WowPlayerState.__index = WowPlayerState

function WowPlayerState.new()
  return ns.core.Port.verify(ns.core.PlayerState, setmetatable({}, WowPlayerState), "WowPlayerState")
end

-- Level, experience and the level's maximum deliberately have no fallback: a
-- client that closes them leaves Ascent nothing to measure, and an invented zero
-- would report a character frozen at the start of a level. They are still
-- guarded, so what reaches core/ is nil rather than a value that raises three
-- layers in. Whether any client closes them is not yet known.
function WowPlayerState:level()
  return readable(UnitLevel("player"))
end

function WowPlayerState:maxLevel()
  return ns.adapter.Compat.maxLevel()
end

function WowPlayerState:xp()
  return readable(UnitXP("player"))
end

function WowPlayerState:xpMax()
  return readable(UnitXPMax("player"))
end

-- `GetXPExhaustion()` returns nil when there is no rested reserve; the port
-- promises zero, never nil, for "there is none". The figure is twice the
-- server's internal reserve; that is interpreted above this adapter.
function WowPlayerState:restedXp()
  local rested = readable(GetXPExhaustion())
  return type(rested) == "number" and rested or 0
end

function WowPlayerState:isResting()
  return not not readable(IsResting())
end

-- Never compared against `true` or `1`: the client types this as a boolean, and
-- comparing it against 1 is a known mistake in other addons.
function WowPlayerState:isXpDisabled()
  return not not readable(IsXPUserDisabled())
end

-- Where the character is. Inside an instance the instance id is the identity --
-- the map id there does not exist on one supported client and names the floor on
-- the other -- and outside it the map id is, because the instance id collapses the
-- world into a few continents.
--
-- Nil is a real answer, and the reason the reserved entry exists: the client does
-- not always know where the character is, notably the instant a portal is crossed.
function WowPlayerState:place()
  local inInstance, instanceType = IsInInstance()
  -- The type is used as a table key, another operation that raises; a closed one
  -- falls through to the unmapped case.
  inInstance, instanceType = readable(inInstance), readable(instanceType)

  if inInstance then
    local name, _, _, _, _, _, _, instanceId = GetInstanceInfo()
    return CONTEXT_BY_INSTANCE_TYPE[instanceType],
      positiveId(readable(instanceId)), displayName(readable(name))
  end

  local mapId
  if C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil then
    mapId = C_Map.GetBestMapForUnit("player")
  end
  local id = positiveId(readable(mapId))
  return PlaceContext.WORLD, id, displayName(mapName(id)) or displayName(readable(GetZoneText()))
end

-- How many the payment is split between, counting the character. The client's own
-- count answers 0 out of a group; it is translated here, as `restedXp` turns the
-- client's nil into zero, so no consumer has to remember the quirk.
function WowPlayerState:sharedBy()
  local members = readable(GetNumGroupMembers())
  if type(members) ~= "number" or members < 1 then
    return 1
  end
  return members
end

function WowPlayerState:healthFraction()
  return fraction(UnitHealth("player"), UnitHealthMax("player"))
end

function WowPlayerState:powerFraction()
  return fraction(UnitPower("player"), UnitPowerMax("player"))
end

function WowPlayerState:guid()
  return readable(UnitGUID("player"))
end

function WowPlayerState:identity()
  return readable(UnitName("player")), readable(GetRealmName())
end

ns.adapter.WowPlayerState = WowPlayerState
