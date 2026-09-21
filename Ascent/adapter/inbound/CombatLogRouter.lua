-- Ascent - the combat log reader (D6): COMBAT_LOG_EVENT_UNFILTERED -> EventTopic.
--
-- One frame, one handler, and a budget that is a design constraint, not an
-- afterthought: the combat log can fire hundreds of times a second in a group, and
-- most of those events are not about this character at all.
--
--   1. read with C_CombatLog.GetCurrentEventInfo(), falling back to the deprecated
--      global only when the modern table is absent.
--   2. discard early everything that does not involve the player or their pet --
--      except a UNIT_DIED whose destination is a creature, which the kill
--      correlator (D19) and the unproductive-kill count need regardless.
--   3. dispatch by subevent against a table of functions, no chained ifs.
--
-- ONLY UNIT_DIED IS LISTENED TO, NOT PARTY_KILL, and that is deliberate, found
-- the hard way (group 0's own first real trace): WoW fires PARTY_KILL alongside
-- UNIT_DIED, same GUID, same instant, for every death the player or their group
-- caused -- it never fires alone. Mapping both to onCreatureDied, as an earlier
-- version of this file did, published CREATURE_DIED twice per kill; the first
-- copy paired with the real hint, the second sat unclaimed until it expired and
-- was counted as an unproductive kill -- so a session with two real kills, both
-- paying experience, reported killsWithXp=2 AND killsWithoutXp=2 for the same
-- two Plainstriders. UNIT_DIED alone is a strict superset: every death PARTY_KILL
-- would have reported, UNIT_DIED already does.
--
-- Zero table allocations for a discarded event: every field the combat log line
-- carries is captured into named locals, never a table, so step 2 can return
-- before anything is built. KNOWN GAP: "the player's summons" (totems, guardians)
-- are not part of the early filter yet, only the player and their pet -- see 9.5b
-- for the sibling gap this shares a cause with (unverified specifics, not
-- unverified existence).
--
-- Combat metrics (group 6, ability/damage/heal collectors) do not exist yet, so
-- ABILITY_USED/DAMAGE_DEALT/DAMAGE_TAKEN/HEALING_RECEIVED payloads here are
-- deliberately minimal -- a straight read of what the combat log line already
-- carries -- rather than a shape designed against a consumer that is not built.
-- CREATURE_DIED is not guesswork: its payload is the one XpAttribution (group 4)
-- already consumes.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Port = ns.core.Port
local EventTopic = ns.core.EventTopic
local CombatLogSubevent = ns.core.CombatLogSubevent
local AbilityKey = ns.core.AbilityKey
local CreatureGuid = ns.adapter.CreatureGuid

-- ---------------------------------------------------------------------------
-- Step 1: the reader
-- ---------------------------------------------------------------------------

local function readCurrentEvent()
  if C_CombatLog ~= nil and C_CombatLog.GetCurrentEventInfo ~= nil then
    return C_CombatLog.GetCurrentEventInfo()
  end
  return CombatLogGetCurrentEventInfo()
end

-- ---------------------------------------------------------------------------
-- 9.8: the creature's level. Not in the GUID -- resolved at the moment of death
-- via whichever unit token currently points at it, which the combat log's own
-- 50-yard range guarantees will not always be true. No token or no level is not
-- an error: it is the unknown-level group, never a guess.
-- ---------------------------------------------------------------------------

local function creatureLevel(guid)
  -- Guarded, and this is the one call in the addon where an unguarded global would
  -- have cost the most: it runs inside the combat-log handler, once per death, and
  -- a client without the function would raise there on the first creature killed.
  -- With Lua errors off -- the default -- that is silent, and every kill for the
  -- rest of the session goes unattributed while the addon looks like it is working.
  if type(UnitTokenFromGUID) ~= "function" then
    return nil
  end

  local token = UnitTokenFromGUID(guid)
  if token == nil then
    return nil
  end

  local level = UnitLevel(token)
  if type(level) ~= "number" or level <= 0 then
    return nil
  end
  return level
end

-- ---------------------------------------------------------------------------
-- Publishing helpers
-- ---------------------------------------------------------------------------

local function abilityUsed(self, key, name)
  self.bus:publish(EventTopic.ABILITY_USED, { key = key, name = name })
end

-- The creature the blow landed on rides along with the amount. It is what lets a
-- surface answer "what am I fighting" DURING the fight rather than after it: the
-- only other name this router publishes is on CREATURE_DIED, which by definition
-- arrives once the answer has stopped being useful.
--
-- Guarded by isCreature for the same reason the death handler is -- a totem, a
-- party member's pet or a training dummy are all valid destinations -- and nil
-- for anything that is not one, which a reader treats as damage with no name
-- rather than as a nameless enemy.
local function damageDealt(self, amount, destGUID, destName)
  if type(amount) == "number" and amount > 0 then
    local isCreature = CreatureGuid.isCreature(destGUID)
    self.bus:publish(EventTopic.DAMAGE_DEALT, {
      amount = amount,
      name = isCreature and destName or nil,
      -- The guid and not only the name: two Mana Serpents in one pull are two
      -- creatures, and the same one hit eight times is one.
      guid = isCreature and destGUID or nil,
    })
  end
end

local function damageTaken(self, amount)
  if type(amount) == "number" and amount > 0 then
    self.bus:publish(EventTopic.DAMAGE_TAKEN, { amount = amount })
  end
end

local function healingReceived(self, amount)
  if type(amount) == "number" and amount > 0 then
    self.bus:publish(EventTopic.HEALING_RECEIVED, { amount = amount })
  end
end

-- ---------------------------------------------------------------------------
-- Step 3: subevent handlers. Each receives (self, playerSource, playerDest,
-- destGUID, destName, ...extras), where extras are exactly what that subevent's
-- combat log line carries past the shared eleven-field prefix.
-- ---------------------------------------------------------------------------

-- Spells are counted as "used" here and only here -- a DoT tick is SPELL_DAMAGE,
-- not a new cast, and would otherwise inflate the ranking of whatever the player
-- pressed once.
local function onSpellCastSuccess(self, playerSource, _, _, _, spellId, spellName)
  if playerSource then
    -- Remembered, so the ranged handlers below can tell a shot that announces
    -- its own cast from one that does not. See castsItsOwn.
    if spellId ~= nil then
      self.castSpells[spellId] = true
    end
    abilityUsed(self, spellId, spellName)
  end
end

-- Whether this ranged attack has already been counted as a cast.
--
-- A wand shot reports itself TWICE: once as SPELL_CAST_SUCCESS for the "Shoot"
-- spell, and again as RANGE_DAMAGE carrying the same spell id. Counting both is
-- what put "Shoot x12" and "Ranged attack x12" in the same list -- the same
-- twelve shots, under two names, in the ranking AND in every percentage computed
-- from it.
--
-- The synthetic RANGED_AUTO key is for a shot with no cast of its own, and this
-- is how that is decided: by what this client has actually been seen to
-- announce, not by a list of spell ids. A hunter's Auto Shot that never reports a
-- cast keeps its synthetic row; a wand that does, does not. It calibrates itself
-- per class and per flavour, which a hardcoded id could not.
--
-- The very first shot of a session can still double-count if the damage somehow
-- preceded the cast it belongs to. That error corrects itself on the second shot
-- and costs one count; the alternative costs every shot, every fight.
local function castsItsOwn(self, spellId)
  return spellId ~= nil and self.castSpells[spellId] == true
end

-- A swing that misses was still swung (Events.lua's own note on this): melee
-- auto attacks are counted from both _DAMAGE and _MISSED, never doubled between
-- them because a single swing produces exactly one of the two.
local function onSwingDamage(self, playerSource, playerDest, destGUID, destName, amount)
  if playerSource then
    abilityUsed(self, AbilityKey.MELEE_SWING, nil)
    damageDealt(self, amount, destGUID, destName)
  elseif playerDest then
    damageTaken(self, amount)
  end
end

local function onSwingMissed(self, playerSource)
  if playerSource then
    abilityUsed(self, AbilityKey.MELEE_SWING, nil)
  end
end

local function onRangeDamage(self, playerSource, playerDest, destGUID, destName, spellId, _, _, amount)
  if playerSource then
    if not castsItsOwn(self, spellId) then
      abilityUsed(self, AbilityKey.RANGED_AUTO, nil)
    end
    damageDealt(self, amount, destGUID, destName)
  elseif playerDest then
    damageTaken(self, amount)
  end
end

local function onRangeMissed(self, playerSource, _, _, _, spellId)
  if playerSource and not castsItsOwn(self, spellId) then
    abilityUsed(self, AbilityKey.RANGED_AUTO, nil)
  end
end

local function onSpellDamage(self, playerSource, playerDest, destGUID, destName, _, _, _, amount)
  if playerSource then
    damageDealt(self, amount, destGUID, destName)
  elseif playerDest then
    damageTaken(self, amount)
  end
end

local function onSpellHeal(self, _, playerDest, _, _, _, _, _, amount)
  if playerDest then
    healingReceived(self, amount)
  end
end

-- A death that isn't claimed as your kill within this long is a new one, not a
-- second subevent for the last one. Confirmed against a real client (a killing
-- blow's UNIT_DIED and PARTY_KILL landed at the identical GetTime() reading) --
-- generous well past that, since two different creatures of the same type could
-- still legitimately die close together and must never be folded into one.
local DEATH_DEDUP_WINDOW = 0.5

-- The payload XpAttribution already consumes (group 4): {name, npcId, level, at}.
-- npcId is nil for anything that is not a Creature GUID -- a party member's pet
-- dying, say -- and the destination check below is what keeps this from ever
-- firing for one.
local function onCreatureDied(self, _, _, destGUID, destName)
  if not CreatureGuid.isCreature(destGUID) then
    return
  end

  local at = self.clock:now()

  -- One kill commonly fires BOTH UNIT_DIED and PARTY_KILL for the same creature
  -- (both are dispatched here); publishing CREATURE_DIED for each would register
  -- the same death twice in the kill correlator, double-counting both the kill
  -- and, once the second copy expires unclaimed, the unproductive-kill count. The
  -- two subevents share no id beyond the GUID itself, so the same GUID again
  -- inside DEATH_DEDUP_WINDOW is what stands in for "this is the other half of
  -- the pair, not a second kill".
  if self.lastDeathGuid == destGUID and (at - self.lastDeathAt) < DEATH_DEDUP_WINDOW then
    return
  end
  self.lastDeathGuid = destGUID
  self.lastDeathAt = at

  -- Timestamped alongside WowEventRouter's own hint/delta logs (same clock) so the
  -- three can be lined up by eye to answer D5's Open Question 1: does UNIT_DIED
  -- arrive before or after the chat line for the same death.
  if self.logger ~= nil then
    self.logger:debug(("UNIT_DIED at %.3f: creature=%q"):format(at, tostring(destName)))
  end

  self.bus:publish(EventTopic.CREATURE_DIED, {
    name = destName,
    npcId = CreatureGuid.npcId(destGUID),
    level = creatureLevel(destGUID),
    at = at,
  })
end

local DISPATCH = {
  [CombatLogSubevent.SPELL_CAST_SUCCESS]    = onSpellCastSuccess,
  [CombatLogSubevent.SWING_DAMAGE]          = onSwingDamage,
  [CombatLogSubevent.SWING_MISSED]          = onSwingMissed,
  [CombatLogSubevent.RANGE_DAMAGE]          = onRangeDamage,
  [CombatLogSubevent.RANGE_MISSED]          = onRangeMissed,
  [CombatLogSubevent.SPELL_DAMAGE]          = onSpellDamage,
  [CombatLogSubevent.SPELL_PERIODIC_DAMAGE] = onSpellDamage,
  [CombatLogSubevent.SPELL_HEAL]            = onSpellHeal,
  [CombatLogSubevent.SPELL_PERIODIC_HEAL]   = onSpellHeal,
  [CombatLogSubevent.UNIT_DIED]             = onCreatureDied,
}

-- ---------------------------------------------------------------------------
-- The router
-- ---------------------------------------------------------------------------

local CombatLogRouter = {}
CombatLogRouter.__index = CombatLogRouter

function CombatLogRouter.new(options)
  options = options or {}
  for _, required in ipairs({ "bus", "clock", "playerState" }) do
    if options[required] == nil then
      error("CombatLogRouter needs a " .. required, 2)
    end
  end
  Port.verify(ns.core.EventBusPort, options.bus, "CombatLogRouter bus")
  Port.verify(ns.core.Clock, options.clock, "CombatLogRouter clock")
  Port.verify(ns.core.PlayerState, options.playerState, "CombatLogRouter playerState")

  return setmetatable({
    bus = options.bus,
    clock = options.clock,
    playerState = options.playerState,
    logger = options.logger,
    lastDeathGuid = nil,
    lastDeathAt = nil,
    -- Spell ids this character has been seen to cast. Bounded by the size of a
    -- spellbook, so it is left to grow for the session rather than expired.
    castSpells = {},
    playerGuid = options.playerState:guid(),
    frame = nil,
  }, CombatLogRouter)
end

local function isPlayerSide(self, guid)
  return guid == self.playerGuid or guid == UnitGUID("pet")
end

-- The method the tests drive directly. The event itself carries none of the
-- combat log's own fields as arguments -- that is what GetCurrentEventInfo() is
-- for -- so unlike WowEventRouter's dispatch there is nothing to pass in.
function CombatLogRouter:handleCombatLogEvent()
  local _, subevent, _, sourceGUID, _, _, _, destGUID, destName, _, _,
    a1, a2, a3, a4, a5, a6, a7, a8, a9 = readCurrentEvent()

  local handler = DISPATCH[subevent]
  if handler == nil then
    return
  end

  local playerSource = isPlayerSide(self, sourceGUID)
  local playerDest = isPlayerSide(self, destGUID)

  if not playerSource and not playerDest
    and not (subevent == CombatLogSubevent.UNIT_DIED and CreatureGuid.isCreature(destGUID)) then
    return
  end

  handler(self, playerSource, playerDest, destGUID, destName, a1, a2, a3, a4, a5, a6, a7, a8, a9)
end

function CombatLogRouter:start()
  if self.frame ~= nil then
    return self
  end

  local frame = CreateFrame("Frame")
  frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  frame:SetScript("OnEvent", function()
    self:handleCombatLogEvent()
  end)

  self.frame = frame
  return self
end

function CombatLogRouter:stop()
  if self.frame == nil then
    return self
  end
  self.frame:UnregisterAllEvents()
  self.frame = nil
  return self
end

ns.adapter.CombatLogRouter = CombatLogRouter
