-- Ascent - metric collector: time in combat, and time spent recovering.
--
-- Two accumulators only: combatSeconds and recoverySeconds. Out-of-combat time is
-- not accumulated here: LevelRecord derives it as playedSeconds minus
-- combatSeconds, so "combat + out-of-combat = played" holds by construction
-- rather than by two independent counters staying in sync.
--
-- recoverySeconds and DeathCollector's timeLostToDeath both live inside
-- out-of-combat time but never overlap: this collector keeps its own `dead` flag
-- from the same PLAYER_DIED/PLAYER_REVIVED topics DeathCollector reacts to, and
-- accrues no recovery time while it is set. The two collectors share no state, so
-- unregistering one never leaves the other half-fed.
--
-- The client has no event for "health crossed the recovery threshold", so
-- recovery is sampled: `observe()` is called from the composition root's 5Hz
-- ticker, not from the bus, with the player's current health/power fractions.
-- Everything else reacts to bus topics through `collect()`.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local MetricId = ns.core.MetricId
local EventTopic = ns.core.EventTopic

local CombatTimeCollector = {}
CombatTimeCollector.__index = CombatTimeCollector

CombatTimeCollector.id = MetricId.TIME
CombatTimeCollector.topics = {
  EventTopic.COMBAT_STARTED, EventTopic.COMBAT_ENDED,
  EventTopic.PLAYER_DIED, EventTopic.PLAYER_REVIVED,
  EventTopic.SESSION_STARTED, EventTopic.SESSION_ENDED,
}

function CombatTimeCollector.new(options)
  options = options or {}
  for _, required in ipairs({ "clock", "recoveryThreshold" }) do
    if options[required] == nil then
      error("CombatTimeCollector needs a " .. required, 2)
    end
  end
  Port.verify(ns.core.Clock, options.clock, "CombatTimeCollector clock")

  return setmetatable({
    clock = options.clock,
    recoveryThreshold = options.recoveryThreshold,

    inCombat = false,
    dead = false,
    sessionActive = true,
    recovering = false,
    -- The clock reading an open interval (combat, or recovery-eligible time out of
    -- combat) started at. nil means "nothing to close" -- either nothing has
    -- happened yet, or the session is paused.
    mark = nil,
  }, CombatTimeCollector)
end

local function metricsOf(record)
  local metrics = record.metrics[MetricId.TIME]
  if metrics == nil then
    metrics = { combatSeconds = 0, recoverySeconds = 0 }
    record.metrics[MetricId.TIME] = metrics
  end
  return metrics
end

-- Credits whatever interval was open up to `now` to `record` -- combat time if
-- `inCombat`, recovery time if `recovering` and not `dead`, nothing otherwise (a
-- death, or plain out-of-combat time with nothing to recover from) -- then starts a
-- fresh mark. `record` is whichever level is current at this instant, so a
-- stretch that crosses a level-up lands on the level it happened in rather than
-- the one open when the stretch began.
function CombatTimeCollector:closeInterval(record, now)
  if self.mark ~= nil and self.sessionActive and record ~= nil then
    local elapsed = now - self.mark
    if elapsed > 0 then
      local metrics = metricsOf(record)
      if self.inCombat then
        metrics.combatSeconds = metrics.combatSeconds + elapsed
      elseif self.recovering and not self.dead then
        metrics.recoverySeconds = metrics.recoverySeconds + elapsed
      end
    end
  end
  self.mark = now
end

function CombatTimeCollector:collect(record, _, topic)
  local now = self.clock:now()

  if topic == EventTopic.SESSION_ENDED then
    self:closeInterval(record, now)
    self.sessionActive = false
    return
  end
  if topic == EventTopic.SESSION_STARTED then
    self.sessionActive = true
    self.mark = now
    return
  end

  self:closeInterval(record, now)

  if topic == EventTopic.COMBAT_STARTED then
    self.inCombat = true
    self.recovering = false
  elseif topic == EventTopic.COMBAT_ENDED then
    self.inCombat = false
    self.recovering = true -- observe() clears this once the threshold is met
  elseif topic == EventTopic.PLAYER_DIED then
    self.dead = true
    self.inCombat = false
  elseif topic == EventTopic.PLAYER_REVIVED then
    self.dead = false
    self.recovering = true
  end
end

-- The sampled half of recovery tracking, called on Bootstrap's 5Hz ticker
-- whether or not anything changed. Two jobs:
--
--   * It always closes the open interval, as collect() does on a bus event. A
--     level-up in the middle of a continuous fight fires no COMBAT_STARTED/ENDED,
--     so without a periodic close the whole fight would land on whichever level
--     is current when it ends; ticking every 0.2s bounds the misattributed slice
--     to at most one tick.
--   * Only while `recovering` (and not in combat, not dead) does it also check
--     whether health/power have crossed the threshold, clearing the flag.
--
-- A no-op call (no level open, or the session is paused) returns before touching
-- the clock or the record.
function CombatTimeCollector:observe(record, healthFraction, powerFraction)
  if record == nil or not self.sessionActive then
    return
  end

  local now = self.clock:now()
  self:closeInterval(record, now)

  if self.recovering and not self.inCombat and not self.dead
    and healthFraction >= self.recoveryThreshold and powerFraction >= self.recoveryThreshold then
    self.recovering = false
  end
end

ns.core.CombatTimeCollector = CombatTimeCollector
