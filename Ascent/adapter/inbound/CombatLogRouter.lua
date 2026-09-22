-- Ascent - the combat log reader: COMBAT_LOG_EVENT_UNFILTERED -> EventTopic.
--
-- One frame, one handler, and a budget that is a design constraint: the combat
-- log can fire hundreds of times a second in a group, and most of those events
-- are not about this character at all.
--
--   1. read with C_CombatLog.GetCurrentEventInfo(), falling back to the deprecated
--      global only when the modern table is absent -- never looked up at all on a
--      client that has the modern one. World of Warcraft: Forever has neither: the
--      global is not in its API dump and its C_CombatLog has no GetCurrentEventInfo.
--   2. discard early everything that does not involve the player or their pet --
--      except a UNIT_DIED whose destination is a creature, which the kill
--      correlator and the unproductive-kill count need regardless.
--   3. dispatch by subevent against a table of functions, no chained ifs.
--
-- Only UNIT_DIED is listened to, not PARTY_KILL: WoW fires PARTY_KILL alongside
-- UNIT_DIED, same GUID, same instant, for every death the player or their group
-- caused, and never alone. Handling both publishes CREATURE_DIED twice per kill,
-- and the second copy expires unclaimed and is counted as an unproductive kill.
-- Every death PARTY_KILL would report, UNIT_DIED already does.
--
-- Zero table allocations for a discarded event: every field the combat log line
-- carries is captured into named locals, never a table, so step 2 can return
-- before anything is built. Known gap: the player's summons (totems, guardians)
-- are not part of the early filter, only the player and their pet.
--
-- The ABILITY_USED/DAMAGE_DEALT/DAMAGE_TAKEN/HEALING_RECEIVED payloads are
-- deliberately minimal, a straight read of what the combat log line carries.
-- CREATURE_DIED's payload is the one XpAttribution consumes.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Port = ns.core.Port
local EventTopic = ns.core.EventTopic
local CombatLogSubevent = ns.core.CombatLogSubevent
local AbilityKey = ns.core.AbilityKey
local CreatureGuid = ns.adapter.CreatureGuid
-- Nothing a combat log line carries is used before it passes this: on a client
-- with secret values a field can come back present and raise the moment it is
-- compared, added to, or used as a table key, which is all this file does with
-- them.
local readable = ns.adapter.Readable.value
local Reason = ns.adapter.Capabilities.Reason

-- ---------------------------------------------------------------------------
-- Step 1: the reader
-- ---------------------------------------------------------------------------

-- The function this client reads a line with, or nil when it offers neither. The
-- global is asked for only once the modern table has said no, so a client that
-- has C_CombatLog never has the global looked up.
local function eventReader()
  local modern = C_CombatLog
  if modern ~= nil and modern.GetCurrentEventInfo ~= nil then
    return modern.GetCurrentEventInfo
  end
  return CombatLogGetCurrentEventInfo
end

-- Nothing at all on a client with no reader, rather than a call to nil: the
-- capability below is absent there, and a line that cannot be read is a line
-- the early filter throws away like any other.
local function readCurrentEvent()
  local reader = eventReader()
  if reader ~= nil then
    return reader()
  end
end

-- ---------------------------------------------------------------------------
-- The creature's level. Not in the GUID -- resolved at the moment of death via
-- whichever unit token currently points at it, which the combat log's own 50-yard
-- range guarantees will not always exist. No token or no level is not an error:
-- it is the unknown-level group, never a guess.
-- ---------------------------------------------------------------------------

local function creatureLevel(guid)
  -- Guarded because it runs inside the combat-log handler, once per death: a
  -- client without UnitTokenFromGUID would raise on the first creature killed, and
  -- with Lua errors off (the default) every later kill in the session would go
  -- unattributed while the addon looks like it is working.
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
  -- No key, no row. The collector keys its own table on this, so a nil key is
  -- not an unnamed ability but a write that raises, inside a fight, where nobody
  -- would see it. A closed spell id reads as nil, and an ability this client will
  -- not name is one this addon does not count.
  if key == nil then
    return
  end
  self.bus:publish(EventTopic.ABILITY_USED, { key = key, name = name })
end

-- The creature the blow landed on rides along with the amount. It is what lets a
-- surface answer "what am I fighting" during the fight rather than after it: the
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

-- Symmetrical with damageDealt above, and for the same reason: a surface has to
-- be able to answer "what am I fighting" while it is being fought. Without the
-- attacker here, a creature beating on the player would join the pull only once
-- the player hit back, so a fight you did not start would read as a fight against
-- nothing.
local function damageTaken(self, amount, sourceGUID, sourceName)
  if type(amount) == "number" and amount > 0 then
    local isCreature = CreatureGuid.isCreature(sourceGUID)
    self.bus:publish(EventTopic.DAMAGE_TAKEN, {
      amount = amount,
      name = isCreature and sourceName or nil,
      guid = isCreature and sourceGUID or nil,
    })
  end
end

local function healingReceived(self, amount)
  if type(amount) == "number" and amount > 0 then
    self.bus:publish(EventTopic.HEALING_RECEIVED, { amount = amount })
  end
end

-- ---------------------------------------------------------------------------
-- Step 3: subevent handlers. Each receives (self, playerSource, playerDest,
-- destGUID, destName, sourceGUID, sourceName, ...extras), where extras are exactly
-- what that subevent's combat log line carries past the shared eleven-field
-- prefix. Both ends of the line travel: on a blow the player lands the creature is
-- the destination, and on one they take it is the source, and a pull needs to know
-- it either way.
-- ---------------------------------------------------------------------------

-- Spells are counted as "used" here and only here -- a DoT tick is SPELL_DAMAGE,
-- not a new cast, and would otherwise inflate the ranking of whatever the player
-- pressed once.
local function onSpellCastSuccess(self, playerSource, _, _, _, _, _, spellId, spellName)
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
-- A wand shot reports itself twice: once as SPELL_CAST_SUCCESS for the "Shoot"
-- spell, and again as RANGE_DAMAGE carrying the same spell id. Counting both would
-- list the same shots under two names, "Shoot" and "Ranged attack", in the ranking
-- and in every percentage computed from it.
--
-- The synthetic RANGED_AUTO key is for a shot with no cast of its own, decided by
-- what this client has been seen to announce, not by a list of spell ids: a
-- hunter's Auto Shot that never reports a cast keeps its synthetic row; a wand
-- that does, does not. It calibrates itself per class and per flavour.
--
-- The first shot of a session can still double-count if the damage precedes the
-- cast it belongs to. That costs one count and corrects itself on the second
-- shot; the alternative costs every shot, every fight.
local function castsItsOwn(self, spellId)
  return spellId ~= nil and self.castSpells[spellId] == true
end

-- A swing that misses was still swung (Events.lua's own note on this): melee
-- auto attacks are counted from both _DAMAGE and _MISSED, never doubled between
-- them because a single swing produces exactly one of the two.
local function onSwingDamage(self, playerSource, playerDest, destGUID, destName,
    sourceGUID, sourceName, amount)
  if playerSource then
    abilityUsed(self, AbilityKey.MELEE_SWING, nil)
    damageDealt(self, amount, destGUID, destName)
  elseif playerDest then
    damageTaken(self, amount, sourceGUID, sourceName)
  end
end

local function onSwingMissed(self, playerSource)
  if playerSource then
    abilityUsed(self, AbilityKey.MELEE_SWING, nil)
  end
end

local function onRangeDamage(self, playerSource, playerDest, destGUID, destName,
    sourceGUID, sourceName, spellId, _, _, amount)
  if playerSource then
    if not castsItsOwn(self, spellId) then
      abilityUsed(self, AbilityKey.RANGED_AUTO, nil)
    end
    damageDealt(self, amount, destGUID, destName)
  elseif playerDest then
    damageTaken(self, amount, sourceGUID, sourceName)
  end
end

local function onRangeMissed(self, playerSource, _, _, _, _, _, spellId)
  if playerSource and not castsItsOwn(self, spellId) then
    abilityUsed(self, AbilityKey.RANGED_AUTO, nil)
  end
end

local function onSpellDamage(self, playerSource, playerDest, destGUID, destName,
    sourceGUID, sourceName, _, _, _, amount)
  if playerSource then
    damageDealt(self, amount, destGUID, destName)
  elseif playerDest then
    damageTaken(self, amount, sourceGUID, sourceName)
  end
end

local function onSpellHeal(self, _, playerDest, _, _, _, _, _, _, _, amount)
  if playerDest then
    healingReceived(self, amount)
  end
end

-- A death that isn't claimed as your kill within this long is a new one, not a
-- second subevent for the last one. A killing blow's UNIT_DIED and PARTY_KILL land
-- at the identical GetTime() reading; the window is generous past that but short,
-- because two creatures of the same type can die close together and must never be
-- folded into one.
local DEATH_DEDUP_WINDOW = 0.5

-- The payload XpAttribution consumes: {name, npcId, level, at}.
-- npcId is nil for anything that is not a Creature GUID -- a party member's pet
-- dying, say -- and the destination check below is what keeps this from ever
-- firing for one.
local function onCreatureDied(self, _, _, destGUID, destName)
  if not CreatureGuid.isCreature(destGUID) then
    return
  end

  local at = self.clock:now()

  -- The same GUID again inside DEATH_DEDUP_WINDOW is a second subevent for the
  -- same death, not a second kill. Publishing CREATURE_DIED twice would register
  -- the death twice in the kill correlator, double-counting the kill and, once the
  -- copy expires unclaimed, the unproductive-kill count. The GUID is the only id
  -- such subevents share.
  if self.lastDeathGuid == destGUID and (at - self.lastDeathAt) < DEATH_DEDUP_WINDOW then
    return
  end
  self.lastDeathGuid = destGUID
  self.lastDeathAt = at

  -- Timestamped alongside WowEventRouter's own hint/delta logs (same clock) so the
  -- three can be lined up to show whether UNIT_DIED arrives before or after the
  -- chat line for the same death.
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

-- Nothing to publish from the line itself: a miss deals no damage and an aura is
-- not a metric this addon keeps. They are dispatched anyway because dispatch is
-- what decides which lines reach the engagement below -- and "this creature swung
-- at you and missed" is exactly as good an answer to "who is in this fight" as a
-- blow that landed.
local function onInteractionOnly() end

-- The subevents that mean "these two are fighting". Everything dispatched that is
-- not in here still does its own job; it just does not answer this question.
local ENGAGING = {
  [CombatLogSubevent.SPELL_CAST_SUCCESS]    = true,
  [CombatLogSubevent.SWING_DAMAGE]          = true,
  [CombatLogSubevent.SWING_MISSED]          = true,
  [CombatLogSubevent.RANGE_DAMAGE]          = true,
  [CombatLogSubevent.RANGE_MISSED]          = true,
  [CombatLogSubevent.SPELL_DAMAGE]          = true,
  [CombatLogSubevent.SPELL_PERIODIC_DAMAGE] = true,
  [CombatLogSubevent.SPELL_MISSED]          = true,
  [CombatLogSubevent.SPELL_AURA_APPLIED]    = true,
  -- No entry in DISPATCH, on purpose: SPELL_ABSORBED publishes nothing, but an
  -- absorbed hit still means a creature is fighting you.
  [CombatLogSubevent.SPELL_ABSORBED]        = true,
  -- Same risk SPELL_AURA_APPLIED carries and the same answer: it does not say
  -- whether the caster is hostile, so a friendly NPC casting something on the
  -- player would enrol. Accepted because waiting for the spell to land is too late
  -- for the pull, and a stray friendly shows up as one odd row rather than as a
  -- wrong number.
  [CombatLogSubevent.SPELL_CAST_START]      = true,
}

local DISPATCH = {
  [CombatLogSubevent.SPELL_CAST_SUCCESS]    = onSpellCastSuccess,
  [CombatLogSubevent.SPELL_MISSED]          = onInteractionOnly,
  [CombatLogSubevent.SPELL_AURA_APPLIED]    = onInteractionOnly,
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

-- Whether this client lets the combat log be read at all, and when it does not,
-- why: the probe of the capability every combat metric hangs from.
--
-- Absent is a client with no reader. Unreadable is one whose reader answers with
-- a line it will not let this addon read, which shows only when a line is on
-- hand, and at login there usually is not. Whether a real fight's lines arrive
-- closed is not known, and nothing here guesses it from the client's name.
function CombatLogRouter.isSupported()
  local reader = eventReader()
  if reader == nil then
    return false
  end
  local _, subevent = reader()
  -- Asked by type, not by `~= nil`: comparing is one of the operations a closed
  -- value raises on, and this one has not been admitted yet.
  if readable(subevent) == nil and type(subevent) ~= "nil" then
    return false, Reason.UNREADABLE
  end
  return true
end

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
    recordEvidence = options.recordEvidence,
    -- Told once, on the first line whose subevent comes back closed.
    onUnreadable = options.onUnreadable,
    closed = false,
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
  -- The pet's guid is a client read like any other, and this one is made per
  -- line: a closed answer here would be compared against the line's own guid.
  return guid == self.playerGuid or guid == readable(UnitGUID("pet"))
end

-- The source closing under this router: nothing about a line whose subevent
-- cannot be read can be understood, and the first one says the combat log is no
-- longer readable. Told once, and then the router stops -- the three metrics it
-- feeds stop accumulating there, and a level that got half of them is reported as
-- not measured, not as the half.
local function sourceClosed(self)
  self.closed = true
  self:stop()
  if self.onUnreadable ~= nil then
    self.onUnreadable()
  end
end

-- The method the tests drive directly. The event itself carries none of the
-- combat log's own fields as arguments -- that is what GetCurrentEventInfo() is
-- for -- so unlike WowEventRouter's dispatch there is nothing to pass in.
function CombatLogRouter:handleCombatLogEvent()
  if self.closed then
    return
  end

  local _, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName, _, _,
    a1, a2, a3, a4, a5, a6, a7, a8, a9 = readCurrentEvent()

  -- Admitted in two waves to keep to the budget: these three are what the early
  -- filter looks at, so a line about somebody else's fight is thrown away having
  -- paid for three guards and no table. The subevent goes first because it is used
  -- as a table key twice below, one of the operations a closed value raises on.
  local offered = subevent
  subevent = readable(subevent)
  -- Asked only when the admitted subevent is missing, which is the rare case: an
  -- ordinary line pays nothing for it. Asked by type, not by comparison, because
  -- `offered` is exactly the value that has not been admitted.
  if subevent == nil and type(offered) ~= "nil" then
    sourceClosed(self)
    return
  end
  sourceGUID = readable(sourceGUID)
  destGUID = readable(destGUID)

  -- Being ENGAGING is enough on its own to reach the enrolment below: a subevent
  -- that only answers "who is fighting me" needs no DISPATCH handler.
  local handler = DISPATCH[subevent]
  local engaging = ENGAGING[subevent]
  if handler == nil and not engaging then
    -- A census of what is being thrown away, taken only while the recorder is on
    -- and only for lines this character is actually in. Which subevents a client
    -- writes for, say, an absorbed hit is not documented, and some that mean a
    -- creature is fighting you may be missing from the tables above; one session
    -- with this on names them.
    if self.recordEvidence ~= nil and subevent ~= nil
      and (isPlayerSide(self, sourceGUID) or isPlayerSide(self, destGUID)) then
      self.recordEvidence("subevent." .. tostring(subevent))
    end
    return
  end

  local playerSource = isPlayerSide(self, sourceGUID)
  local playerDest = isPlayerSide(self, destGUID)

  -- The second wave: the fields only a handler or an enrolment ever touches, so
  -- they are paid for by the lines this character is actually in. Names get
  -- concatenated and compared, and the extras get compared, added up and used as
  -- keys -- `castSpells[spellId] = true` writes one, the operation that raises
  -- hardest of all.
  sourceName, destName = readable(sourceName), readable(destName)
  a1, a2, a3, a4, a5, a6, a7, a8, a9 = readable(a1), readable(a2), readable(a3),
    readable(a4), readable(a5), readable(a6), readable(a7), readable(a8), readable(a9)

  if not playerSource and not playerDest
    and not (subevent == CombatLogSubevent.UNIT_DIED and CreatureGuid.isCreature(destGUID)) then
    return
  end

  -- Who is in this fight, said by the line rather than by what the line did. Every
  -- subevent that gets this far has the player or their pet on one side, so the
  -- other side is the answer, published whether the line was a blow, a miss, a
  -- cast or a debuff: a creature that charges you, swings and misses is being
  -- fought, whether or not either of you has landed a hit.
  --
  -- Exactly one of the two sides is tested, never both: on UNIT_DIED neither is the
  -- player, and publishing the dead creature here would enrol whatever died nearby.
  --
  -- ENGAGING and not "every line that got this far", because some are not a
  -- fight: a creature that heals the player is a friendly NPC, and enrolling it
  -- would put a quest giver in the pull and count experience for killing it.
  if engaging and playerSource ~= playerDest then
    local guid, name
    if playerSource then
      guid, name = destGUID, destName
    else
      guid, name = sourceGUID, sourceName
    end
    if CreatureGuid.isCreature(guid) and name ~= nil then
      self.bus:publish(EventTopic.ENEMY_ENGAGED, { guid = guid, name = name, from = "combatlog" })
    end
  end

  -- Nil for a line that only answers who is fighting whom: it enrolled above and
  -- has nothing else to do here.
  if handler ~= nil then
    handler(self, playerSource, playerDest, destGUID, destName, sourceGUID, sourceName,
      a1, a2, a3, a4, a5, a6, a7, a8, a9)
  end
end

-- Nothing is registered on a client with no reader, such as World of Warcraft:
-- Forever: there would be no line to read, and an event the 12.0 engine may treat
-- as restricted is not one to ask for from inside the composition root, before
-- the slash commands exist.
function CombatLogRouter:start()
  if self.frame ~= nil or self.closed or not CombatLogRouter.isSupported() then
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
