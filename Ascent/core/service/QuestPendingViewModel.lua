-- Ascent - the level report panel's pending-experience tab view-model.
--
-- Pure shaping: total, readyTotal and unknownCount pass through from
-- QuestForecastService:report(), and entries is its already-sorted entries()
-- array. The level record is used only to price open kill objectives; the
-- pending rewards are a projection and never become experience obtained.
--
-- `active` is false only when both report and entries are nil (no forecast has
-- been built). All zeros with no entries is active: no quests accepted.

local _, ns = ...
ns.core = ns.core or {}

local KillXpEstimator = ns.core.KillXpEstimator

local QuestPendingViewModel = {}

-- The kills a quest still asks for, priced against what this level has paid.
-- Finished objectives are skipped.
--
-- `record` is optional; without it there are no estimates, not estimates of zero.
--
-- `sharedBy` is how many characters share the pay right now; it picks which
-- measured rate prices these kills, as the record picks the level.
local function buildObjectives(objectives, record, sharedBy)
  if objectives == nil then
    return nil
  end

  local built = nil
  for _, objective in ipairs(objectives) do
    if not objective:isComplete() then
      built = built or {}
      local estimate = record ~= nil and KillXpEstimator.estimate(record, objective, sharedBy) or nil
      built[#built + 1] = {
        creature = objective.creature,
        done = objective.done,
        needed = objective.needed,
        remaining = objective:remaining(),
        -- nil when this level cannot price it, shown differently from zero.
        estimate = estimate and estimate.amount or nil,
        basis = estimate and estimate.basis or nil,
      }
    end
  end
  return built
end

local function buildEntries(entries, record, sharedBy)
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
      -- Not added into adjustedReward or the totals: these kills will be
      -- recorded as creature experience when they happen, and adding them here
      -- would count them twice.
      objectives = buildObjectives(entry.objectives, record, sharedBy),
    }
  end
  return built
end

function QuestPendingViewModel.build(report, entries, record, sharedBy)
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
    entries = buildEntries(entries, record, sharedBy),
  }
end

ns.core.QuestPendingViewModel = QuestPendingViewModel
