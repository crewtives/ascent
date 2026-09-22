-- Ascent - what the kills a quest still asks for are likely to pay.
--
-- Everything here is measured, never modelled. The addon has no table of what a
-- creature is worth and is not going to acquire one: what it has is what THIS
-- character has actually been paid, at THIS level, for the creatures it has
-- killed -- which is a better answer than any table, because it already includes
-- the level difference, the rested state and whatever else the server applied.
--
-- THREE SOURCES, AND THE LAST TWO SAY SO. The creature's own observed average,
-- taken with the same number of people sharing the pay, is the good number. Short
-- of that comes what was recorded before this addon counted the context at all --
-- one number over kills taken alone and kills taken in a group, a real measurement
-- of a population nobody can name (D83) -- and short of that the level's average
-- experience per kill, a much wider number because an elite and a critter of the
-- same level pay very differently. Every estimate carries WHICH of the three it
-- came from, so a surface can mark the two wide ones instead of passing them off
-- as a measurement of right now (design.md D4, D83).
--
-- ONE POPULATION AT A TIME. A rate is asked for one group size and answers with
-- the kills taken at that size and no others: two people and five split what the
-- server pays very differently, and an average over both describes neither of
-- them. Borrowing across group sizes is the same loan as borrowing across levels,
-- which this module already refuses, and the kills nobody counted are their own
-- population rather than a stand-in for playing alone (D82, D84).
--
-- WHY ONLY THIS LEVEL. What a creature pays depends on the gap between its level
-- and the character's, so last level's average describes a character who no
-- longer exists. A level with nothing recorded gets no estimate at all rather
-- than a borrowed one.
--
-- WHY NAMES. The quest log gives its objectives a creature NAME and no id, so
-- that is what there is to match on. The comparison is exact and case-sensitive,
-- and what does not match falls to the level average instead of guessing: an
-- objective that reads "Amani troll slain" names a family, not an NPC, and no
-- amount of fuzzy matching would turn it into one.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource

local KillXpEstimator = {}

-- Where an estimate came from, and it is part of the answer rather than a detail
-- about it: the three differ by enough that showing them the same way would be
-- claiming a precision the last two do not have. MIXED is an average that groups
-- populations -- the creature's own kills, taken with nobody counting how many
-- people shared them -- and it is served rather than discarded so that a history
-- written before this distinction existed still prices something, marked (D83).
KillXpEstimator.Basis = { CREATURE = "creature", MIXED = "mixed", LEVEL = "level" }

-- The average this level has paid for one of these, by name, with `sharedBy`
-- characters splitting the pay. Sums across every aggregate with that name AND
-- that group size -- one creature type can span a level range, and each band is
-- its own aggregate -- so the average is over every one of them killed in that
-- context, which is exactly the mix the next few kills will come from.
--
-- A `sharedBy` of nil asks for the kills nobody counted, which is a population of
-- its own and not a synonym for playing alone (D84). Any other size answers nil
-- when it has nothing of its own rather than handing back what a different size
-- measured: that borrowed number is what this whole distinction exists to stop,
-- and the refusal is the same one D4 already makes across levels (D82).
function KillXpEstimator.creatureRate(record, creature, sharedBy)
  if record == nil or type(creature) ~= "string" or record.creatures == nil then
    return nil
  end

  local kills, xpTotal = 0, 0
  for _, bucket in pairs(record.creatures) do
    if bucket.key.name == creature and bucket.sharedBy == sharedBy then
      kills = kills + bucket.kills
      xpTotal = xpTotal + bucket.xpTotal
    end
  end

  if kills == 0 then
    return nil
  end
  return xpTotal / kills
end

-- The level's own average per kill. `killsWithXp` and not the total kill count:
-- the deaths that paid nothing are real and recorded, and they are precisely the
-- ones that must not drag this average down -- a quest's remaining kills will
-- pay, or they would not be worth estimating.
--
-- This one has no group dimension and is not gaining one here: its denominator is
-- a single counter the level keeps, so splitting it would need a count that was
-- never accumulated and cannot be reconstructed. It is already the number every
-- surface marks as the wide one, which is why it can stay as it is.
function KillXpEstimator.levelRate(record)
  if record == nil then
    return nil
  end
  local kills = record.killsWithXp or 0
  if kills == 0 then
    return nil
  end
  return record:xpFrom(XpSource.MOB_KILL) / kills
end

-- What one of these is likely to pay, and where that number came from: `rate,
-- basis`, or nil when this level has nothing to price it with.
--
-- The chain is here and only here because every surface that prices a creature
-- has to fall back the same way. Two copies of it would drift, and the drift
-- would show up as the pull plate and the pending tab disagreeing about the same
-- creature on the same screen.
--
-- `sharedBy` is how many characters are sharing the pay RIGHT NOW, and all it does
-- is choose which population to read. Nothing already recorded is reclassified by
-- it: what was measured is a property of the past, and a character that joins a
-- group does not thereby turn its solo kills into group ones (D81).
function KillXpEstimator.rateFor(record, creature, sharedBy)
  if sharedBy ~= nil then
    local measured = KillXpEstimator.creatureRate(record, creature, sharedBy)
    if measured ~= nil then
      return measured, KillXpEstimator.Basis.CREATURE
    end
  end

  -- The kills taken before anyone counted the context. Served instead of
  -- discarded, because discarding leaves a character with no estimates at all
  -- over a distinction it never had the chance to record -- but served MARKED,
  -- never as a measurement of the group the character is in now (D83, D84).
  local mixed = KillXpEstimator.creatureRate(record, creature, nil)
  if mixed ~= nil then
    return mixed, KillXpEstimator.Basis.MIXED
  end

  local level = KillXpEstimator.levelRate(record)
  if level ~= nil then
    return level, KillXpEstimator.Basis.LEVEL
  end
  return nil
end

-- { amount, basis } for one objective, or nil when this level has nothing to
-- estimate from. Nil is a real answer and must stay distinguishable from zero:
-- "nobody knows yet" and "these are worth nothing" are different sentences.
--
-- An objective already finished estimates zero rather than nil -- there IS an
-- answer for it, and it is that nothing is left to kill.
function KillXpEstimator.estimate(record, objective, sharedBy)
  if objective == nil then
    return nil
  end

  local rate, basis = KillXpEstimator.rateFor(record, objective.creature, sharedBy)
  if rate == nil then
    return nil
  end

  return { amount = math.floor(objective:remaining() * rate + 0.5), basis = basis }
end

ns.core.KillXpEstimator = KillXpEstimator
