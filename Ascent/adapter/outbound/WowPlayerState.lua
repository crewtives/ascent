-- Ascent - the real PlayerState, read straight off the "player" unit.
--
-- Every value the port promises is a plain number, string or boolean; this is the
-- one place that turns client calls into that shape, so nothing downstream has to
-- know a unit token exists.

local _, ns = ...
ns.adapter = ns.adapter or {}

local PlaceContext = ns.core.PlaceContext

-- The client's own instance vocabulary, translated once. Anything it grows later --
-- "scenario" is the one that already exists on other flavours -- is deliberately
-- absent: an unmapped kind answers nil and the domain files that experience in the
-- reserved entry, which is honest, rather than under a kind chosen by resemblance.
local CONTEXT_BY_INSTANCE_TYPE = {
  none = PlaceContext.WORLD,
  party = PlaceContext.DUNGEON,
  raid = PlaceContext.RAID,
  pvp = PlaceContext.BATTLEGROUND,
  arena = PlaceContext.ARENA,
}

local function fraction(current, max)
  if max <= 0 then
    return 0
  end
  return current / max
end

-- An identifier the model would refuse. The client answers 0 or nil while a zone is
-- still loading, and PlaceKey raises on anything that is not a positive integer --
-- correctly, because there it would be the addon's own bug. Sanitising is this
-- layer's job, the same way `restedXp` turns the client's nil into zero.
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

local WowPlayerState = {}
WowPlayerState.__index = WowPlayerState

function WowPlayerState.new()
  return ns.core.Port.verify(ns.core.PlayerState, setmetatable({}, WowPlayerState), "WowPlayerState")
end

function WowPlayerState:level()
  return UnitLevel("player")
end

function WowPlayerState:maxLevel()
  return ns.adapter.Compat.maxLevel()
end

function WowPlayerState:xp()
  return UnitXP("player")
end

function WowPlayerState:xpMax()
  return UnitXPMax("player")
end

-- `GetXPExhaustion()` returns nil when there is no rested reserve; the port
-- promises zero, never nil, for "there is none" (D18 covers the client doubling
-- the server's internal figure -- that reading happens above this adapter).
function WowPlayerState:restedXp()
  return GetXPExhaustion() or 0
end

function WowPlayerState:isResting()
  return not not IsResting()
end

-- Never compared against `true` or `1`: the client types this as a boolean, but at
-- least one addon in production gets it wrong by comparing against 1 (D17).
function WowPlayerState:isXpDisabled()
  return not not IsXPUserDisabled()
end

-- Where the character is, by the one rule that works for both cases (D42): inside
-- an instance the instance id is the identity -- the map id there does not exist on
-- one supported client and names the floor on the other -- and outside it the map
-- id is, because the instance id collapses the whole world into a few continents.
--
-- Answering nil is a real answer and the reason the reserved entry exists: the
-- client does not always know where the character is, and the instant a portal is
-- crossed is exactly when it does not.
function WowPlayerState:place()
  local inInstance, instanceType = IsInInstance()

  if inInstance then
    local name, _, _, _, _, _, _, instanceId = GetInstanceInfo()
    return CONTEXT_BY_INSTANCE_TYPE[instanceType], positiveId(instanceId), displayName(name)
  end

  local mapId
  if C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil then
    mapId = C_Map.GetBestMapForUnit("player")
  end
  return PlaceContext.WORLD, positiveId(mapId), displayName(GetZoneText())
end

function WowPlayerState:healthFraction()
  return fraction(UnitHealth("player"), UnitHealthMax("player"))
end

function WowPlayerState:powerFraction()
  return fraction(UnitPower("player"), UnitPowerMax("player"))
end

function WowPlayerState:guid()
  return UnitGUID("player")
end

function WowPlayerState:identity()
  return UnitName("player"), GetRealmName()
end

ns.adapter.WowPlayerState = WowPlayerState
