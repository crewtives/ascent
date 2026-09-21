-- Ascent - pace and projection estimates for the level in progress (group 7).
--
-- A pure function of a LevelRecord plus a small bag of numbers the record does not
-- carry itself -- the rested reserve and the session's own time/xp live on the
-- player and on the addon's own lifetime, not on the level -- the same shape
-- XpBarViewModel already uses for the same reason (D7: testable without a client).
--
-- Two figures worth reading before the rest:
--
--   restProjectedPercent  how far the level would be if the rested reserve were
--                          spent killing creatures. It is a projection of muertes,
--                          never of progress by any means, and it never exceeds
--                          100% -- the same rule XpBarViewModel.buildRested already
--                          applies to the bar's own rested segment, extended here
--                          to a plain percentage instead of a bar fraction.
--   averageXpPerRecentKill the per-creature average the two creature-count
--                          estimates below are built from. It is deliberately a
--                          RECENT window (the last few kills), not the level's
--                          running average: the spec's own requirement
--                          ("Estimaciones basadas en lo observado") ties windowing
--                          specifically to this figure so a temporary bonus shows
--                          up within a handful of kills instead of being diluted
--                          by the whole level's history.
--
-- The plain xp/hour figures (level and session) are NOT windowed: their own
-- requirement text asks only for "tiempo jugado dentro del nivel" / "de la
-- sesión", a flat average over real observed play -- which already satisfies
-- "no valores nominales" without needing a recent slice. The estimated time to
-- next level reuses the level's own live pace ("el ritmo reciente" of 7.4 is this
-- continuously-recomputed figure, contrasted against a static table -- not a
-- second, separately-windowed rate).
--
-- Every estimate that depends on samples nil rather than errors, divides by zero
-- or reports a fabricated number when the level has none yet (7.5) -- nil is
-- this module's only vocabulary for "not available".

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource

local ProgressEstimator = {}

-- How many of the most recent creature kills feed the recent-window average.
-- Small on purpose ("de modo que un cambio de bonificación se refleje en pocas
-- muestras", the spec's own words) -- enough to smooth out one unlucky or lucky
-- kill without taking so long to react that a bonus starting or ending goes
-- unnoticed for several minutes of play.
local RECENT_KILL_WINDOW = 8

-- The last N mob-kill gains, most recent first in traversal but returned as a
-- plain sum/count: record.gains is chronological (oldest first, RetentionPolicy
-- trims the oldest), so the recent window is the tail of the list.
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

-- 7.1: how far the level would be with the rested reserve spent, capped at 100%
-- and never less than the real percent complete. Mirrors XpBarViewModel.buildRested's
-- own treatment of restedXp as directly additive against xpRequired.
local function restProjectedPercent(percentComplete, restedXp, xpRequired)
  if restedXp == nil or restedXp <= 0 then
    return percentComplete
  end
  return math.min(1, percentComplete + restedXp / xpRequired)
end

-- 7.3: creatures until the rested reserve runs out. Zero (not nil) when there is
-- a known average but no reserve left -- the reserve being empty is itself an
-- answer, not a missing one. Nil only when there is nothing to average, per the
-- spec's own "sin muertes registradas -> no disponible".
local function restReachCreatures(restedXp, averageXpPerKill)
  if averageXpPerKill == nil or averageXpPerKill <= 0 then
    return nil
  end
  if restedXp == nil or restedXp <= 0 then
    return 0
  end
  return restedXp / averageXpPerKill
end

-- 7.3: creatures until the level fills, from the same recent average.
local function creaturesRemaining(xpRemaining, averageXpPerKill)
  if averageXpPerKill == nil or averageXpPerKill <= 0 then
    return nil
  end
  if xpRemaining <= 0 then
    return 0
  end
  return xpRemaining / averageXpPerKill
end

-- 7.2: experience per hour from an amount gained over a played-seconds figure
-- that already excludes offline time (LevelTracker:playedSeconds() for the level,
-- the session tracker's own elapsed seconds for the session) -- this function
-- never has to know which one it was handed.
local function perHour(amount, seconds)
  if seconds == nil or seconds <= 0 or amount == nil then
    return nil
  end
  return amount / (seconds / 3600)
end

-- 7.4: seconds until the level fills, from what is missing and the level's own
-- live pace. Nil with a zero or unavailable pace instead of an infinite or
-- undefined result ("ritmo nulo -> no disponible").
local function timeToLevel(xpRemaining, xpPerHourLevel)
  if xpPerHourLevel == nil or xpPerHourLevel <= 0 then
    return nil
  end
  if xpRemaining <= 0 then
    return 0
  end
  return xpRemaining / (xpPerHourLevel / 3600)
end

-- params: playedSeconds (time on this level, offline time already excluded),
-- restedXp, sessionSeconds, sessionXpGained. Every one of them is nilable, and a
-- nil simply makes the estimates that need it come back nil too.
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
