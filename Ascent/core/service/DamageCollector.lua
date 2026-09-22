-- Ascent - metric collector: damage dealt, damage taken, healing received.
--
-- CombatLogRouter's early filter already restricts
-- DAMAGE_DEALT/DAMAGE_TAKEN/HEALING_RECEIVED to the player and their pet (other
-- party members' damage never reaches these topics), so the only state this
-- collector needs is `enabled`: the player's opt-out (SettingKey.COLLECT_DAMAGE),
-- read live through a function so toggling it in the options panel takes effect
-- on the same tick without rebuilding the collector or its registry.
local _, ns = ...
ns.core = ns.core or {}

local MetricId = ns.core.MetricId
local EventTopic = ns.core.EventTopic

local DamageCollector = {}
DamageCollector.__index = DamageCollector

DamageCollector.id = MetricId.DAMAGE
DamageCollector.topics = { EventTopic.DAMAGE_DEALT, EventTopic.DAMAGE_TAKEN, EventTopic.HEALING_RECEIVED }

-- options.enabled: optional function() -> boolean. Absent (or nil-returning) means
-- always enabled.
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
