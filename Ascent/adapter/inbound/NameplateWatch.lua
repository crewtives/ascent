-- Ascent - what you pulled, including what has not reached you yet.
--
-- The combat log answers "who is fighting me" only once a line has been written
-- about it: a blow, a miss, a cast, a debuff. That is most of a pull and it is not
-- all of it. Aggro three creatures with one shot and two of them spend the next
-- several seconds running at you, writing nothing -- and a plate built from the
-- combat log alone shows a pull of one while three are on their way.
--
-- This is the only other place a Classic client will say it. A nameplate is a unit
-- token, and a unit token can be asked what it is doing. The rule is deliberately
-- narrow:
--
--   HOSTILE, ALIVE, FIGHTING, AND AIMING AT YOU. Both halves of that are needed
--   and neither is enough alone. "In combat" by itself takes in a creature
--   fighting somebody else across the clearing, and counting it would put
--   experience you will never be paid into the plate. "Aiming at you" by itself
--   takes in one that merely has you selected while it stands there -- and the
--   player clicking a creature must never add it to the pull, which is the exact
--   failure that made this rule two conditions instead of one.
--
-- It publishes the same ENEMY_ENGAGED the combat log router does, so nothing
-- downstream knows there are two ways to learn this, and the pull record's own
-- per-creature rule is what keeps one creature from being counted twice.
--
-- IT DEGRADES TO NOTHING. Nameplates can be switched off in the client's own
-- options, and then there are no tokens and this sees nobody -- which is exactly
-- the state the addon was in before this file existed, not a failure. It is
-- registered as a capability so `/ascent debug` says which of the two answers the
-- player is actually getting.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Port = ns.core.Port
local EventTopic = ns.core.EventTopic
local CreatureGuid = ns.adapter.CreatureGuid

local NameplateWatch = {}
NameplateWatch.__index = NameplateWatch

function NameplateWatch.isSupported()
  return C_NamePlate ~= nil and type(C_NamePlate.GetNamePlates) == "function"
end

function NameplateWatch.new(options)
  options = options or {}
  if options.bus == nil then
    error("NameplateWatch needs an event bus", 2)
  end
  Port.verify(ns.core.EventBusPort, options.bus, "NameplateWatch bus")

  return setmetatable({
    bus = options.bus,
    -- Optional, and what it writes is a TALLY rather than a line per nameplate: a
    -- sweep runs four times a second, and the question it has to answer after the
    -- fact is which of the conditions is throwing everyone out.
    recordEvidence = options.recordEvidence,
  }, NameplateWatch)
end

-- Whether this creature is in THIS fight, and WHICH condition said no. Every call
-- is guarded: a client without one of them answers nil, which reads as "no" rather
-- than raising inside a sweep that runs while the player is fighting.
--
-- The reason for a verdict rather than a boolean: these are four different client
-- questions and only one of them has to answer wrong for a pull to stay empty. A
-- sweep that could only say "nobody" left a reader with four suspects and no way to
-- tell them apart, which is exactly the state this was reported from.
local function verdictFor(token)
  if UnitExists == nil or not UnitExists(token) then
    return "gone"
  end
  if UnitCanAttack == nil or not UnitCanAttack("player", token) then
    return "friendly"
  end
  if UnitIsDead ~= nil and UnitIsDead(token) then
    return "dead"
  end
  -- The half that clicking cannot fake. A creature standing in a field is not in
  -- combat, so selecting it, targeting it or hovering it enrols nothing.
  if UnitAffectingCombat == nil or not UnitAffectingCombat(token) then
    return "idle"
  end
  if UnitIsUnit == nil then
    return "noTargetApi"
  end

  local target = token .. "target"
  if UnitIsUnit(target, "player") == true or UnitIsUnit(target, "pet") == true then
    return "mine"
  end
  return "elsewhere"
end

-- Called from the ticker the addon already runs, and only while a pull is open:
-- out of combat there is nothing to enrol and this costs nothing at all.
function NameplateWatch:sweep()
  if not NameplateWatch.isSupported() then
    return 0
  end

  local plates = C_NamePlate.GetNamePlates()
  if type(plates) ~= "table" then
    return 0
  end

  local found = 0
  local tally
  if self.recordEvidence ~= nil then
    tally = { kind = "nameplateSweep", plates = #plates }
  end

  for _, plate in ipairs(plates) do
    local token = type(plate) == "table" and plate.namePlateUnitToken or nil
    local verdict = token ~= nil and verdictFor(token) or "noToken"
    if verdict == "mine" then
      local guid = UnitGUID ~= nil and UnitGUID(token) or nil
      local name = UnitName ~= nil and UnitName(token) or nil
      -- The same two guards the combat log router applies: a guid that is not a
      -- creature's is a player or a pet, and a creature with no name is one this
      -- addon cannot show a row for.
      if name ~= nil and CreatureGuid.isCreature(guid) then
        found = found + 1
        self.bus:publish(EventTopic.ENEMY_ENGAGED, { guid = guid, name = name, from = "nameplate" })
      else
        verdict = "notACreature"
      end
    end
    if tally ~= nil then
      tally[verdict] = (tally[verdict] or 0) + 1
    end
  end

  if tally ~= nil then
    tally.enrolled = found
    self.recordEvidence("nameplateSweep", tally)
  end
  return found
end

ns.adapter.NameplateWatch = NameplateWatch
