-- Ascent - what the kills a quest still asks for are likely to pay.
--
-- Everything here is measured, never modelled. The addon has no table of what a
-- creature is worth and is not going to acquire one: what it has is what THIS
-- character has actually been paid, at THIS level, for the creatures it has
-- killed -- which is a better answer than any table, because it already includes
-- the level difference, the rested state and whatever else the server applied.
--
-- TWO SOURCES, AND THE SECOND SAYS SO. The creature's own observed average is the
-- good number. When the character has never killed that creature in this level,
-- the estimate falls back to the level's average experience per kill -- a much
-- wider number, because an elite and a critter of the same level pay very
-- differently -- and every estimate carries WHICH of the two it came from, so a
-- surface can print the wide one with a mark instead of passing it off as a
-- measurement (design.md D4).
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
-- about it: the two differ by enough that showing them the same way would be
-- claiming a precision the second one does not have.
KillXpEstimator.Basis = { CREATURE = "creature", LEVEL = "level" }

-- The average this level has paid for one of these, by name. Sums across every
-- aggregate with that name -- one creature type can span a level range, and each
-- band is its own aggregate -- so the average is over every one of them killed,
-- which is exactly the mix the next few kills will come from.
function KillXpEstimator.creatureRate(record, creature)
  if record == nil or type(creature) ~= "string" or record.creatures == nil then
    return nil
  end

  local kills, xpTotal = 0, 0
  for _, bucket in pairs(record.creatures) do
    if bucket.key.name == creature then
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

-- { amount, basis } for one objective, or nil when this level has nothing to
-- estimate from. Nil is a real answer and must stay distinguishable from zero:
-- "nobody knows yet" and "these are worth nothing" are different sentences.
--
-- An objective already finished estimates zero rather than nil -- there IS an
-- answer for it, and it is that nothing is left to kill.
function KillXpEstimator.estimate(record, objective)
  if objective == nil then
    return nil
  end

  local remaining = objective:remaining()
  local rate = KillXpEstimator.creatureRate(record, objective.creature)
  local basis = KillXpEstimator.Basis.CREATURE

  if rate == nil then
    rate = KillXpEstimator.levelRate(record)
    basis = KillXpEstimator.Basis.LEVEL
  end
  if rate == nil then
    return nil
  end

  return { amount = math.floor(remaining * rate + 0.5), basis = basis }
end

ns.core.KillXpEstimator = KillXpEstimator
