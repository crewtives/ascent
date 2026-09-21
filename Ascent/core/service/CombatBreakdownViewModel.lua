-- Ascent - the level-report panel's "combat" tab view-model (D7, task 11.3).
--
-- Pure read of the combat-related metrics a LevelRecord already carries: nothing
-- here is derived beyond what CombatSummary and LevelRecord's own methods already
-- compute. The one decision this module owns is `hasData` -- the spec's "sin
-- datos" scenario needs a truthful yes/no the UI can switch on instead of reading
-- zeros and guessing whether they mean "nothing happened" or "nothing was
-- measured".

local _, ns = ...
ns.core = ns.core or {}

local MetricId = ns.core.MetricId

local CombatBreakdownViewModel = {}

-- { average, worst }, both nil when the summary has no samples -- "no hubo
-- combate" and "el promedio fue cero" are different claims, and CombatSummary
-- already keeps them apart; this just reads its two pairs of accessors through.
local function buildVitals(summary, averageMethod, worstMethod)
  if summary == nil then
    return { average = nil, worst = nil }
  end
  return { average = summary[averageMethod](summary), worst = summary[worstMethod](summary) }
end

-- Dealt/taken/healing default to zero, not nil, when nothing was ever recorded:
-- a total accumulates from zero, unlike an average that has nothing to average.
local function buildDamage(record)
  local damage = record.metrics[MetricId.DAMAGE]
  if damage == nil then
    return { dealt = 0, taken = 0, healingReceived = 0 }
  end
  return { dealt = damage.dealt, taken = damage.taken, healingReceived = damage.healingReceived }
end

-- `record` may be nil (no level selected yet), same convention as
-- XpBarViewModel.build.
function CombatBreakdownViewModel.build(record)
  if record == nil then
    return { active = false }
  end

  local hasData = record:combatSeconds() > 0 or record:deathCount() > 0
  local summary = record.metrics[MetricId.COMBAT_OUTCOME]

  return {
    active = true,
    hasData = hasData,
    health = buildVitals(summary, "averageHealth", "worstHealth"),
    power = buildVitals(summary, "averagePower", "worstPower"),
    deathCount = record:deathCount(),
    damage = buildDamage(record),
    time = {
      combatSeconds = record:combatSeconds(),
      recoverySeconds = record:recoverySeconds(),
      outOfCombatSeconds = record:outOfCombatSeconds(),
      timeLostToDeath = record:timeLostToDeath(),
    },
    efficiency = {
      xpPerCombatMinute = record:xpPerCombatMinute(),
      averageXpPerKill = record:averageXpPerKill(),
    },
  }
end

ns.core.CombatBreakdownViewModel = CombatBreakdownViewModel
