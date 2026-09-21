-- Ascent - metric collector: health and primary resource on leaving combat (6.3).
--
-- Reads the player's state at the exact instant COMBAT_ENDED fires -- health and
-- power are not part of that event's payload, so this is the one collector that
-- needs the PlayerState port injected rather than reading everything from the
-- payload. A death that ends combat needs no special case: by the time
-- COMBAT_ENDED reaches here the character's own health is already zero, so the
-- sample records itself as such.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local CombatSummary = ns.core.CombatSummary
local MetricId = ns.core.MetricId
local EventTopic = ns.core.EventTopic

local CombatOutcomeCollector = {}
CombatOutcomeCollector.__index = CombatOutcomeCollector

CombatOutcomeCollector.id = MetricId.COMBAT_OUTCOME
CombatOutcomeCollector.topics = { EventTopic.COMBAT_ENDED }

function CombatOutcomeCollector.new(options)
  options = options or {}
  if options.playerState == nil then
    error("CombatOutcomeCollector needs a playerState", 2)
  end
  Port.verify(ns.core.PlayerState, options.playerState, "CombatOutcomeCollector playerState")

  return setmetatable({ playerState = options.playerState }, CombatOutcomeCollector)
end

function CombatOutcomeCollector:collect(record)
  local summary = record.metrics[MetricId.COMBAT_OUTCOME]
  if summary == nil then
    summary = CombatSummary.new()
    record.metrics[MetricId.COMBAT_OUTCOME] = summary
  end
  summary:record(self.playerState:healthFraction(), self.playerState:powerFraction())
end

ns.core.CombatOutcomeCollector = CombatOutcomeCollector
