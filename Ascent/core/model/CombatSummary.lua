-- Ascent - how the player came out of the fights of one level.
--
-- Samples are taken when combat ends: health and primary resource as fractions of
-- their maximum. With no samples the answers are nil, not zero -- "you averaged 0%
-- health" and "there is nothing to average" are different statements, and only one
-- of them is true for a level spent in a city.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local Stored = ns.core.Stored

local CombatSummary = {}
CombatSummary.__index = CombatSummary

function CombatSummary.new()
  return setmetatable({
    samples = 0,
    healthTotal = 0,
    powerTotal = 0,
    worstHealthSeen = nil,
    worstPowerSeen = nil,
  }, CombatSummary)
end

function CombatSummary:record(healthFraction, powerFraction)
  Guard.fraction(healthFraction, "CombatSummary health")
  Guard.fraction(powerFraction, "CombatSummary power")

  self.samples = self.samples + 1
  self.healthTotal = self.healthTotal + healthFraction
  self.powerTotal = self.powerTotal + powerFraction

  if self.worstHealthSeen == nil or healthFraction < self.worstHealthSeen then
    self.worstHealthSeen = healthFraction
  end
  if self.worstPowerSeen == nil or powerFraction < self.worstPowerSeen then
    self.worstPowerSeen = powerFraction
  end

  return self.samples
end

function CombatSummary:hasSamples()
  return self.samples > 0
end

function CombatSummary:averageHealth()
  if self.samples == 0 then return nil end
  return self.healthTotal / self.samples
end

function CombatSummary:averagePower()
  if self.samples == 0 then return nil end
  return self.powerTotal / self.samples
end

function CombatSummary:worstHealth()
  return self.worstHealthSeen
end

function CombatSummary:worstPower()
  return self.worstPowerSeen
end


function CombatSummary:toStored()
  return {
    samples = self.samples,
    healthTotal = self.healthTotal,
    powerTotal = self.powerTotal,
    worstHealth = self.worstHealthSeen,
    worstPower = self.worstPowerSeen,
  }
end

function CombatSummary.restore(stored)
  local fields = Stored.table(stored)
  if fields == nil then
    return nil
  end

  local summary = CombatSummary.new()
  summary.samples = Stored.count(fields.samples, 0)

  -- With no samples there is nothing to have been worst at, so a stored worst case
  -- is dropped rather than reported over an empty average.
  if summary.samples > 0 then
    summary.healthTotal = Stored.number(fields.healthTotal, 0)
    summary.powerTotal = Stored.number(fields.powerTotal, 0)
    summary.worstHealthSeen = Stored.fraction(fields.worstHealth, nil)
    summary.worstPowerSeen = Stored.fraction(fields.worstPower, nil)
  end

  return summary
end

ns.core.CombatSummary = CombatSummary
