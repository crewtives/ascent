-- Ascent - the level-report panel's "combat" tab view-model.
--
-- Pure read of the combat-related metrics a LevelRecord already carries: nothing
-- here is derived beyond what CombatSummary and LevelRecord's own methods
-- compute. The one decision this module owns is `hasData`, a truthful yes/no the
-- UI can switch on instead of reading zeros and guessing whether they mean
-- "nothing happened" or "nothing was measured".

local _, ns = ...
ns.core = ns.core or {}

local MetricId = ns.core.MetricId
local RecordedSource = ns.core.RecordedSource

local CombatBreakdownViewModel = {}

-- { average, worst }, both nil when the summary has no samples: "there was no
-- combat" and "the average was zero" are different claims, and CombatSummary
-- already keeps them apart.
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

  -- Damage and healing come from the combat log. On a level recorded without it,
  -- from the start or from a point part-way, whatever was counted is a fraction
  -- of the level, and a fraction is reported as not measured, with why. The rest
  -- of this tab does not depend on the combat log.
  local withoutCombatLog = record:unavailableReason(RecordedSource.COMBAT_LOG)
  local damage = withoutCombatLog ~= nil and { unavailable = withoutCombatLog } or buildDamage(record)

  return {
    active = true,
    hasData = hasData,
    health = buildVitals(summary, "averageHealth", "worstHealth"),
    power = buildVitals(summary, "averagePower", "worstPower"),
    deathCount = record:deathCount(),
    damage = damage,
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
