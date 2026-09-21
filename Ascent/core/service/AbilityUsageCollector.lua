-- Ascent - metric collector: which abilities were used, and how often (6.2).
--
-- Auto attacks arrive under AbilityKey's reserved synthetic keys (D9), so this
-- never has to special-case them: `record.abilities` is keyed the same way for a
-- spell id and for melee_swing/ranged_auto, and the ranking (a pure read of that
-- table) already tells them apart via AbilityUsage:isAutoAttack().

local _, ns = ...
ns.core = ns.core or {}

local AbilityUsage = ns.core.AbilityUsage
local MetricId = ns.core.MetricId
local EventTopic = ns.core.EventTopic

local AbilityUsageCollector = {}
AbilityUsageCollector.__index = AbilityUsageCollector

AbilityUsageCollector.id = MetricId.ABILITY_USAGE
AbilityUsageCollector.topics = { EventTopic.ABILITY_USED }

function AbilityUsageCollector.new()
  return setmetatable({}, AbilityUsageCollector)
end

-- payload: { key, name }, straight from CombatLogRouter's ABILITY_USED.
function AbilityUsageCollector:collect(record, payload)
  local usage = record.abilities[payload.key]
  if usage == nil then
    usage = AbilityUsage.new(payload.key, payload.name)
    record.abilities[payload.key] = usage
  end
  usage:record()
end

ns.core.AbilityUsageCollector = AbilityUsageCollector
