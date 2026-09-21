-- Ascent - the level report panel's "experience pendiente" tab view-model.
--
-- Pure shaping, no math: total/readyTotal/unknownCount pass straight through
-- from QuestForecastService:report()'s own return value, and entries are
-- QuestForecastService:entries()'s own array, already sorted. This module has
-- no access to a LevelRecord at all, which is what makes "this projection
-- never gets folded into experience obtained" a structural guarantee rather
-- than a rule to remember (level-report-panel spec: "identificados como
-- proyección, no como experiencia obtenida").
--
-- `active` is false only when BOTH arguments are nil -- no forecast has ever
-- been built. A report of all zeros with an empty entries array is a
-- different, active case: "Sin misiones aceptadas".

local _, ns = ...
ns.core = ns.core or {}

local KillXpEstimator = ns.core.KillXpEstimator

local QuestPendingViewModel = {}

-- The kills a quest still asks for, priced against what this level has actually
-- paid. Only the ones still open: an objective already finished has nothing left
-- to kill and a row saying so would be a row about the past.
--
-- `record` is optional, and without it there are no estimates -- not estimates of
-- zero. A view built with no level in progress must not print a price.
local function buildObjectives(objectives, record)
  if objectives == nil then
    return nil
  end

  local built = nil
  for _, objective in ipairs(objectives) do
    if not objective:isComplete() then
      built = built or {}
      local estimate = record ~= nil and KillXpEstimator.estimate(record, objective) or nil
      built[#built + 1] = {
        creature = objective.creature,
        done = objective.done,
        needed = objective.needed,
        remaining = objective:remaining(),
        -- nil when this level cannot price it, which is a different answer from
        -- a price of zero and is shown as a different row.
        estimate = estimate and estimate.amount or nil,
        basis = estimate and estimate.basis or nil,
      }
    end
  end
  return built
end

local function buildEntries(entries, record)
  local built = {}
  for _, entry in ipairs(entries) do
    built[#built + 1] = {
      questId = entry.questId,
      questLevel = entry.questLevel,
      reward = entry.reward,
      origin = entry.origin,
      complete = entry.complete,
      adjustedReward = entry.adjustedReward,
      isKnown = entry.reward ~= nil,
      -- Deliberately NOT added into adjustedReward, nor into the totals below:
      -- the reward is experience that exists nowhere else, while these kills will
      -- be recorded as creatures when they happen. One number for both would
      -- count the same afternoon twice (design.md D2).
      objectives = buildObjectives(entry.objectives, record),
    }
  end
  return built
end

function QuestPendingViewModel.build(report, entries, record)
  if report == nil and entries == nil then
    return { active = false }
  end

  report = report or { total = 0, readyTotal = 0, unknownCount = 0 }
  entries = entries or {}

  return {
    active = true,
    total = report.total,
    readyTotal = report.readyTotal,
    unknownCount = report.unknownCount,
    entries = buildEntries(entries, record),
  }
end

ns.core.QuestPendingViewModel = QuestPendingViewModel
