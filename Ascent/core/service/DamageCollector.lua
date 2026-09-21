-- Ascent - metric collector: damage dealt, damage taken, healing received (6.6).
--
-- CombatLogRouter's early filter (D6) already restricts
-- DAMAGE_DEALT/DAMAGE_TAKEN/HEALING_RECEIVED to the player and their pet -- other
-- party members' damage in the same fight never reaches this topic at all -- so
-- the only state this collector needs of its own is `enabled`: the player's own
-- opt-out (SettingKey.COLLECT_DAMAGE), read live through a function rather than a
-- value captured once at construction, so toggling the option in the options
-- panel takes effect the same tick without rebuilding the collector or the
-- registry it is registered in.
local _, ns = ...
ns.core = ns.core or {}

local MetricId = ns.core.MetricId
local EventTopic = ns.core.EventTopic

local DamageCollector = {}
DamageCollector.__index = DamageCollector

DamageCollector.id = MetricId.DAMAGE
DamageCollector.topics = { EventTopic.DAMAGE_DEALT, EventTopic.DAMAGE_TAKEN, EventTopic.HEALING_RECEIVED }

-- options.enabled: optional function() -> boolean. Absent (or nil-returning) means
-- always enabled, which is what every existing caller (and every test) gets.
function DamageCollector.new(options)
  options = options or {}
  return setmetatable({ enabled = options.enabled }, DamageCollector)
end

local function metricsOf(record)
  local metrics = record.metrics[MetricId.DAMAGE]
  if metrics == nil then
    metrics = { dealt = 0, taken = 0, healingReceived = 0 }
    record.metrics[MetricId.DAMAGE] = metrics
  end
  return metrics
end

-- payload: { amount }, straight from CombatLogRouter.
function DamageCollector:collect(record, payload, topic)
  if self.enabled ~= nil and self.enabled() == false then
    return
  end

  local metrics = metricsOf(record)
  if topic == EventTopic.DAMAGE_DEALT then
    metrics.dealt = metrics.dealt + payload.amount
  elseif topic == EventTopic.DAMAGE_TAKEN then
    metrics.taken = metrics.taken + payload.amount
  elseif topic == EventTopic.HEALING_RECEIVED then
    metrics.healingReceived = metrics.healingReceived + payload.amount
  end
end

ns.core.DamageCollector = DamageCollector
