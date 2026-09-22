-- Ascent - a single gain of experience.
--
-- `amount` is what the player actually received: the client announces the total
-- with any rested bonus already folded in, and that is the number the experience
-- bar moves by. The base portion is therefore derived by subtraction, never by
-- addition, and base + rested always equals amount exactly.
--
-- Whether the parenthetical in the client's rested kill message names the bonus
-- or the base is a parser concern; this model holds the identity either way.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local Stored = ns.core.Stored
local Packed = ns.core.Packed
local CreatureKey = ns.core.CreatureKey
local XpSource = ns.core.XpSource
local XpModifier = ns.core.XpModifier

local XpGain = {}
XpGain.__index = XpGain

-- fields: amount, source, at, restedBonus, groupBonus, raidPenalty, creature,
-- questId, sharedBy
function XpGain.new(fields)
  if type(fields) ~= "table" then
    error("XpGain.new expects a table of fields", 2)
  end

  local amount = Guard.nonNegativeInteger(fields.amount, "XpGain.amount")
  local source = Guard.member(XpSource, "XpSource", fields.source, "XpGain.source")
  local at = Guard.number(fields.at, "XpGain.at")
  local restedBonus = Guard.nonNegativeInteger(fields.restedBonus or 0, "XpGain.restedBonus")

  -- The bonus is part of the amount, so it cannot exceed it. If it does, either the
  -- parse is wrong or the client changed; both are bugs worth surfacing now.
  if restedBonus > amount then
    error(("XpGain: rested bonus %d cannot exceed the amount received %d")
      :format(restedBonus, amount), 2)
  end

  -- Guarded rather than copied raw like `creature` and `questId`, because the one
  -- wrong value this field can take is the client's own: `GetNumGroupMembers()`
  -- answers 0 out of a group, which the adapter translates to one. A zero here
  -- would file every later average under a group size nobody played at.
  if fields.sharedBy ~= nil then
    Guard.positiveInteger(fields.sharedBy, "XpGain.sharedBy")
  end

  return setmetatable({
    amount = amount,
    source = source,
    at = at,
    restedBonus = restedBonus,
    groupBonus = Guard.nonNegativeInteger(fields.groupBonus or 0, "XpGain.groupBonus"),
    raidPenalty = Guard.nonNegativeInteger(fields.raidPenalty or 0, "XpGain.raidPenalty"),
    creature = fields.creature, -- CreatureKey, when the gain came from a kill
    questId = fields.questId,   -- when the gain came from a turn-in
    -- How many the payment was split between at the instant it was collected, and
    -- nil when nothing counted it. Absent is not one: a gain written before this
    -- field existed, or posted by a path that never saw the kill happen, says
    -- nothing about the group, and reading it as "alone" would invent an
    -- observation -- one hard to catch, since most such gains probably were solo.
    sharedBy = fields.sharedBy,
  }, XpGain)
end

function XpGain:baseAmount()
  return self.amount - self.restedBonus
end

function XpGain:hasRestedBonus()
  return self.restedBonus > 0
end

function XpGain:modifierAmount(modifier)
  -- Asking for a modifier that does not exist is a typo, and answering 0 would
  -- hide it behind a plausible number.
  Guard.member(XpModifier, "XpModifier", modifier, "XpGain:modifierAmount")

  if modifier == XpModifier.RESTED_BONUS then
    return self.restedBonus
  elseif modifier == XpModifier.GROUP_BONUS then
    return self.groupBonus
  end
  return self.raidPenalty
end

-- Split a gain that crosses a level boundary. Both halves keep the source and the
-- group the gain was paid in -- that is a property of one instant, not a quantity
-- to divide, and halving it would describe two groups that were never there. Every
-- modifier is divided the same way: the head takes its rounded share and
-- the tail takes the remainder, so the two always add back up to the original
-- exactly. Rounding both halves independently would leak a point either way.
function XpGain:splitAt(amountForThisLevel)
  Guard.nonNegativeInteger(amountForThisLevel, "splitAt amount")
  if amountForThisLevel > self.amount then
    error("XpGain: cannot split off more than the gain holds", 2)
  end

  local ratio = self.amount > 0 and (amountForThisLevel / self.amount) or 0
  local function shareOf(total)
    return math.floor(total * ratio + 0.5)
  end

  local restedHere = shareOf(self.restedBonus)
  local groupHere = shareOf(self.groupBonus)
  local raidHere = shareOf(self.raidPenalty)

  local head = XpGain.new({
    amount = amountForThisLevel, source = self.source, at = self.at,
    restedBonus = restedHere, groupBonus = groupHere, raidPenalty = raidHere,
    creature = self.creature, questId = self.questId, sharedBy = self.sharedBy,
  })
  local tail = XpGain.new({
    amount = self.amount - amountForThisLevel, source = self.source, at = self.at,
    restedBonus = self.restedBonus - restedHere,
    groupBonus = self.groupBonus - groupHere,
    raidPenalty = self.raidPenalty - raidHere,
    creature = self.creature, questId = self.questId, sharedBy = self.sharedBy,
  })

  return head, tail
end


-- The on-disk form: one line of text, because there are tens of thousands of these
-- in a run and the client spends about forty-five bytes on every line it writes.
-- Ten fields in a fixed order, trailing empties dropped:
--
--   amount, source, at, rested, group, raid, npcId, creature level, quest id,
--   shared by
--
-- The group size is written even when it is one, because blank in that position is
-- already spoken for: it means nobody counted. A kill measured alone is a
-- measurement, and it is the population every average of a solo level belongs to.
--
-- The creature's name is deliberately not here. It is display-only, it is the same
-- for every gain from the same creature, and the level record already holds it once
-- in that creature's aggregate -- which is where restoring puts it back from.
--
-- `at` is kept even though it is a session-relative instant: it stays meaningful
-- across a /reload, which is the case it has to survive, and no consumer may read it
-- as a wall-clock time.
function XpGain:toStored()
  local npcId, creatureLevel = false, false
  if self.creature ~= nil then
    npcId = self.creature.npcId or false
    creatureLevel = self.creature.level or false
  end

  return Packed.join({
    self.amount,
    self.source,
    ("%.1f"):format(self.at),
    Packed.blankIf(self.restedBonus, 0),
    Packed.blankIf(self.groupBonus, 0),
    Packed.blankIf(self.raidPenalty, 0),
    npcId,
    creatureLevel,
    self.questId or false,
    self.sharedBy or false,
  })
end

function XpGain.restore(stored)
  if type(stored) ~= "string" then
    return nil
  end

  local fields = Packed.split(stored)

  -- The one field without which there is nothing to restore. Everything else has a
  -- defensible default; an amount does not.
  local amount = Stored.count(Packed.number(fields, 1), nil)
  if amount == nil then
    return nil
  end

  -- The constructor would raise on a bonus larger than the amount, and raising on
  -- stored data is exactly what this boundary exists to prevent. Clamped instead.
  local restedBonus = Stored.count(Packed.number(fields, 4), 0)
  if restedBonus > amount then
    restedBonus = amount
  end

  local source = Stored.member(XpSource, fields[2], XpSource.UNKNOWN)

  -- A kill always has a creature, known or not, and that is what tells "no creature"
  -- apart from "a creature nobody could identify" once both are written as nothing.
  local creature
  if source == XpSource.MOB_KILL then
    creature = CreatureKey.fromFields(fields, 7)
  end

  return XpGain.new({
    amount = amount,
    source = source,
    at = Stored.number(Packed.number(fields, 3), 0),
    restedBonus = restedBonus,
    groupBonus = Stored.count(Packed.number(fields, 5), 0),
    raidPenalty = Stored.count(Packed.number(fields, 6), 0),
    creature = creature,
    questId = Stored.positiveInteger(Packed.number(fields, 9)),
    -- Nil for every gain written before this field existed: unknown, never alone.
    sharedBy = Stored.positiveInteger(Packed.number(fields, 10)),
  })
end

ns.core.XpGain = XpGain
