-- Ascent - composes the report panel's tabs into one view-model.
--
-- Each tab builds itself; this bundles them so ui/ReportPanelView.lua makes one
-- call per rebuild and reads one `active` flag. All tab builders share the same
-- "record == nil" inactive convention, so there is nothing to reconcile.

local _, ns = ...
ns.core = ns.core or {}

local LevelBreakdownViewModel = ns.core.LevelBreakdownViewModel
local CombatBreakdownViewModel = ns.core.CombatBreakdownViewModel
local AbilityRankingViewModel = ns.core.AbilityRankingViewModel
local QuestPendingViewModel = ns.core.QuestPendingViewModel

local ReportPanelViewModel = {}

-- params.questReport/questEntries are QuestForecastService:report()/:entries()'s
-- return values, plain data like XpBarViewModel's params. Pending experience is
-- quest-log-wide, not level-scoped, so it comes here rather than from `record`.
function ReportPanelViewModel.build(record, params)
  params = params or {}

  if record == nil then
    return { active = false }
  end

  return {
    active = true,
    -- `params.sharedBy` is the current group size even when `record` is a past
    -- level: each per-creature row carries the group it was measured in, and
    -- this picks the one matching the character's current situation.
    breakdown = LevelBreakdownViewModel.build(record, params.sharedBy),
    combat = CombatBreakdownViewModel.build(record),
    abilities = AbilityRankingViewModel.build(record),
    -- `params.currentRecord`, not `record`: the pending tab describes the current
    -- quest log even while the panel shows a past level, and what a creature pays
    -- depends on the character's current level.
    pending = QuestPendingViewModel.build(params.questReport, params.questEntries,
      params.currentRecord, params.sharedBy),
  }
end

ns.core.ReportPanelViewModel = ReportPanelViewModel
