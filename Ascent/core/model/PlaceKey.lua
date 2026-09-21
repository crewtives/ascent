-- Ascent - how a place is identified for aggregation.
--
-- The name of a zone is translated, so it cannot be the identity: a player who
-- changes the client's language would come back to a history split in two, the same
-- ground recorded under two names with nothing saying they are one place.
--
-- And no single client identifier covers both cases (D42). The map id does not
-- exist for the dungeons of one supported client and names the FLOOR rather than
-- the instance in the other; the instance id collapses the whole open world into a
-- handful of continents. So the rule is: inside an instance the instance id
-- identifies the place, outside it the map id does -- and the KIND of place travels
-- inside the key, which is what lets a place describe itself without anything
-- having to look it up afterwards.
--
-- The name is kept so the place can be shown and is never part of the identity,
-- exactly the rule CreatureKey already follows for creature names.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local Stored = ns.core.Stored
local Packed = ns.core.Packed
local PlaceContext = ns.core.PlaceContext

-- What an absent identifier is written as inside the key string. Same character
-- CreatureKey uses for the same idea, and never a number: "the client did not say"
-- and "area zero" have to stay different answers.
local UNKNOWN_ID = "?"

local PlaceKey = {}
PlaceKey.__index = PlaceKey

-- A place the client could not put a number on is THE unknown place, whatever kind
-- it claimed to be. Keeping the kind would split the one reserved entry into five
-- of them, and five buckets that all mean "somewhere" are not five places.
function PlaceKey.new(context, areaId, name)
  if context ~= nil then
    Guard.member(PlaceContext, "PlaceContext", context, "PlaceKey.context")
  end
  if areaId ~= nil then
    Guard.positiveInteger(areaId, "PlaceKey.areaId")
  end

  if context == nil or areaId == nil then
    -- No name either: the reserved entry is one bucket, and two nameless
    -- somewheres arriving with different zone text would fight over it.
    return setmetatable({ context = PlaceContext.UNKNOWN }, PlaceKey)
  end

  return setmetatable({ context = context, areaId = areaId, name = name }, PlaceKey)
end

function PlaceKey.unknown()
  return PlaceKey.new(nil, nil)
end

function PlaceKey:isKnown()
  return self.areaId ~= nil
end

-- The stable string used to index the per-place aggregates and to compare places.
function PlaceKey:id()
  return ("%s:%s"):format(self.context, self.areaId and tostring(self.areaId) or UNKNOWN_ID)
end

function PlaceKey:equals(other)
  return other ~= nil and getmetatable(other) == PlaceKey and self:id() == other:id()
end

-- Deliberately no __tostring, for the reason spelled out in CreatureKey: the PUC
-- Lua 5.1 the client runs raises on `("%s"):format(table)` even with one defined,
-- while LuaJIT honours it -- a trap that passes the suite and fails in the game.

-- The three fields a place is written as, in order. `false` rather than nil so the
-- sequence stays dense, which is what keeps a field's position its identity.
function PlaceKey:fields()
  return { self.context, self.areaId or false, self.name or false }
end

-- A kind this version cannot read -- one a later build added and this one has never
-- heard of -- restores as the reserved entry rather than as UNKNOWN with a number
-- still attached. The pair is the identity: half of it unreadable makes the place
-- unidentifiable, and letting the number through would put two different meanings
-- ("the client did not say" and "this build cannot read the kind") into one context.
function PlaceKey.fromFields(fields, offset)
  return PlaceKey.new(
    Stored.member(PlaceContext, Packed.text(fields, offset), nil),
    Stored.positiveInteger(Packed.number(fields, offset + 1)),
    Packed.text(fields, offset + 2))
end

ns.core.PlaceKey = PlaceKey
