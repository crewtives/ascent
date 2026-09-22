-- Ascent - pace and projection estimates for the level in progress.
--
-- A pure function of a LevelRecord plus the numbers the record does not carry
-- (the rested reserve, the session's time and experience), like XpBarViewModel.
--
--   restProjectedPercent   how far the level would be if the rested reserve were
--                          spent on kills; never above 100%.
--   averageXpPerRecentKill the per-creature average behind the creature-count
--                          estimates. A recent window, not the level's running
--                          average, so a bonus starting or ending shows within a
--                          few kills.
--
-- The xp/hour figures (level and session) are flat averages over played time,
-- not windowed; the time to level uses the level's xp/hour.
--
-- An estimate without samples is nil, never an error, a division by zero or a
-- made-up number: nil is this module's only "not available".

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource

local ProgressEstimator = {}

-- How many of the most recent creature kills feed the recent average: enough to
-- smooth out one odd kill, few enough that a bonus change shows within minutes.
local RECENT_KILL_WINDOW = 8

-- Average of the last N mob-kill gains. record.gains is chronological (oldest
-- first, RetentionPolicy trims the oldest), so the window is the list's tail.
local function recentKillAverage(gains)
  local total, count = 0, 0
  for index = #gains, 1, -1 do
    local gain = gains[index]
    if gain.source == XpSource.MOB_KILL then
      total = total + gain.amount
      count = count + 1
      if count >= RECENT_KILL_WINDOW then
        break
      end
    end
  end
  if count == 0 then
    return nil
  end
  return total / count
end

-- How far the level would be with the rested reserve spent, capped at 100% and
-- never below the real percent. restedXp adds directly against xpRequired, as in
-- XpBarViewModel.buildRested.
local function restProjectedPercent(percentComplete, restedXp, xpRequired)
  if restedXp == nil or restedXp <= 0 then
    return percentComplete
  end
  return math.min(1, percentComplete + restedXp / xpRequired)
end

-- Creatures until the rested reserve runs out. Zero, not nil, with an average
-- and no reserve: an empty reserve is an answer. Nil only with no kills to
-- average.
local function restReachCreatures(restedXp, averageXpPerKill)
  if averageXpPerKill == nil or averageXpPerKill <= 0 then
    return nil
  end
  if restedXp == nil or restedXp <= 0 then
    return 0
  end
  return restedXp / averageXpPerKill
end

-- Creatures until the level fills, from the same recent average.
local function creaturesRemaining(xpRemaining, averageXpPerKill)
  if averageXpPerKill == nil or averageXpPerKill <= 0 then
    return nil
  end
  if xpRemaining <= 0 then
    return 0
  end
  return xpRemaining / averageXpPerKill
end

-- Experience per hour over a played-seconds figure that already excludes
-- offline time (LevelTracker:playedSeconds() for the level, the session
-- tracker's elapsed seconds for the session).
local function perHour(amount, seconds)
  if seconds == nil or seconds <= 0 or amount == nil then
    return nil
  end
  return amount / (seconds / 3600)
end

-- Seconds until the level fills at the level's pace. Nil with a zero or unknown
-- pace rather than an infinite result.
local function timeToLevel(xpRemaining, xpPerHourLevel)
  if xpPerHourLevel == nil or xpPerHourLevel <= 0 then
    return nil
  end
  if xpRemaining <= 0 then
    return 0
  end
  return xpRemaining / (xpPerHourLevel / 3600)
end

-- params: playedSeconds (time on this level, offline time excluded), restedXp,
-- sessionSeconds, sessionXpGained. All nilable; a nil makes the estimates that
-- need it nil.
function ProgressEstimator.build(record, params)
  if record == nil or record.xpRequired == nil or record.xpRequired <= 0 then
    return { active = false }
  end
  params = params or {}

  local xpRequired = record.xpRequired
  local percentComplete = record.xpTotal / xpRequired
  local xpRemaining = xpRequired - record.xpTotal

  local averageXpPerRecentKill = recentKillAverage(record.gains)
  local xpPerHourLevel = perHour(record.xpTotal, params.playedSeconds)

  return {
    active = true,
    percentComplete = percentComplete,
    restProjectedPercent = restProjectedPercent(percentComplete, params.restedXp, xpRequired),
    averageXpPerRecentKill = averageXpPerRecentKill,
    restReachCreatures = restReachCreatures(params.restedXp, averageXpPerRecentKill),
    creaturesRemaining = creaturesRemaining(xpRemaining, averageXpPerRecentKill),
    xpPerHourLevel = xpPerHourLevel,
    xpPerHourSession = perHour(params.sessionXpGained, params.sessionSeconds),
    timeToLevel = timeToLevel(xpRemaining, xpPerHourLevel),
  }
end

ns.core.ProgressEstimator = ProgressEstimator
