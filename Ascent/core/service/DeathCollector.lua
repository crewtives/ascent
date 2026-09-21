-- Ascent - metric collector: deaths and the time lost to each one (6.4).
--
-- PLAYER_DIED marks the moment; PLAYER_REVIVED closes it and credits the elapsed
-- time to timeLostToDeath, on whichever record is current when the revive lands
-- (6.8) -- not the one open when the character died, which in the extreme case of
-- a level closing while dead would be the wrong one to blame the corpse run on.
-- CombatTimeCollector reads `dead` state of its own from these same two topics so
-- that the same stretch never also counts toward recovery time (D23): the two
-- collectors do not share state, they each derive their own from the same events.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local MetricId = ns.core.MetricId
local EventTopic = ns.core.EventTopic

local DeathCollector = {}
DeathCollector.__index = DeathCollector

DeathCollector.id = MetricId.DEATHS
DeathCollector.topics = { EventTopic.PLAYER_DIED, EventTopic.PLAYER_REVIVED }

function DeathCollector.new(options)
  options = options or {}
  if options.clock == nil then
    error("DeathCollector needs a clock", 2)
  end
  Port.verify(ns.core.Clock, options.clock, "DeathCollector clock")

  return setmetatable({ clock = options.clock, diedAt = nil }, DeathCollector)
end

local function metricsOf(record)
  local metrics = record.metrics[MetricId.DEATHS]
  if metrics == nil then
    metrics = { count = 0, timeLostToDeath = 0 }
    record.metrics[MetricId.DEATHS] = metrics
  end
  return metrics
end

function DeathCollector:collect(record, _, topic)
  if topic == EventTopic.PLAYER_DIED then
    local metrics = metricsOf(record)
    metrics.count = metrics.count + 1
    self.diedAt = self.clock:now()
    return
  end

  -- PLAYER_REVIVED. A revive with no matching death (this collector was just
  -- constructed mid-session, say) has nothing to close.
  if self.diedAt == nil then
    return
  end
  local elapsed = self.clock:now() - self.diedAt
  self.diedAt = nil
  if elapsed > 0 then
    local metrics = metricsOf(record)
    metrics.timeLostToDeath = metrics.timeLostToDeath + elapsed
  end
end

ns.core.DeathCollector = DeathCollector
