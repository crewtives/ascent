-- Ascent - what the kills a quest still asks for are likely to pay.
--
-- Measured, never modelled: the addon has no table of what a creature is worth.
-- It has what this character was actually paid, at this level, for the creatures
-- it killed, which already includes the level difference, the rested state and
-- whatever else the server applied.
--
-- Three sources, and the last two say so. The creature's own observed average,
-- taken with the same number of people sharing the pay, is the good number. Short
-- of that comes its average over kills recorded without a group size, one number
-- over solo and group kills alike; short of that, the level's average per kill,
-- much wider because an elite and a critter of the same level pay very
-- differently. Every estimate carries which source it came from, so a surface can
-- mark the two wide ones instead of passing them off as a measurement of now.
--
-- One population at a time: a rate is asked for one group size and answers with
-- the kills taken at that size only, because two people and five split the pay
-- very differently and an average over both describes neither. Kills with no
-- recorded group size are their own population, not a stand-in for playing alone.
--
-- Only this level: what a creature pays depends on the gap between its level and
-- the character's, so last level's average describes a character who no longer
-- exists. A level with nothing recorded gets no estimate rather than a borrowed
-- one.
--
-- Matched by name, because the quest log gives objectives a creature name and no
-- id. The comparison is exact and case-sensitive, and what does not match falls
-- to the level average instead of guessing: an objective that reads "Amani troll
-- slain" names a family, not an NPC.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource

local KillXpEstimator = {}

-- Where an estimate came from, part of the answer: the three differ by enough
-- that showing them the same way would claim a precision the last two lack. MIXED
-- is the creature's own kills with no recorded group size, served rather than
-- discarded so that a history recorded without group sizes still prices
-- something, marked.
KillXpEstimator.Basis = { CREATURE = "creature", MIXED = "mixed", LEVEL = "level" }

-- The average this level has paid for one of these, by name, with `sharedBy`
-- characters splitting the pay. Sums across every aggregate with that name and
-- that group size (one creature type can span a level range, and each band is
-- its own aggregate), so the average is over every one of them killed in that
-- context: the mix the next few kills will come from.
--
-- A `sharedBy` of nil asks for the kills with no recorded group size, a
-- population of its own and not a synonym for playing alone. Any other size
-- answers nil when it has nothing of its own rather than handing back what a
-- different size measured, as the module refuses to borrow across levels.
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
-- the deaths that paid nothing are real and recorded, and must not drag this
-- average down, since a quest's remaining kills will pay.
--
-- No group dimension: its denominator is a single counter the level keeps, and a
-- per-size count was never accumulated and cannot be reconstructed. Every surface
-- already marks this number as the wide one.
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
-- The fallback chain lives only here because every surface that prices a
-- creature has to fall back the same way; otherwise the pull plate and the
-- pending tab could disagree about the same creature on the same screen.
--
-- `sharedBy` is how many characters share the pay right now, and it only chooses
-- which population to read. Nothing recorded is reclassified by it: a character
-- that joins a group does not turn its solo kills into group ones.
function KillXpEstimator.rateFor(record, creature, sharedBy)
  if sharedBy ~= nil then
    local measured = KillXpEstimator.creatureRate(record, creature, sharedBy)
    if measured ~= nil then
      return measured, KillXpEstimator.Basis.CREATURE
    end
  end

  -- The kills recorded without a group size. Served rather than discarded, which
  -- would leave such a history with no estimates at all, but marked, never as a
  -- measurement of the group the character is in now.
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
-- An objective already finished estimates zero rather than nil: there is an
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
