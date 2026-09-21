-- Ascent - composes the report panel's three tabs into one view-model (11.1).
--
-- Each tab already knows how to build itself from a LevelRecord (11.2, 11.3,
-- 11.4); this only bundles the three so ui/ReportPanelView.lua has one call to
-- make per rebuild instead of three, and one `active` flag instead of three
-- that would always agree with each other anyway -- all three tab builders
-- share the exact same "record == nil" inactive convention, so there is
-- nothing to reconcile here, only to read once.

local _, ns = ...
ns.core = ns.core or {}

local LevelBreakdownViewModel = ns.core.LevelBreakdownViewModel
local CombatBreakdownViewModel = ns.core.CombatBreakdownViewModel
local AbilityRankingViewModel = ns.core.AbilityRankingViewModel
local QuestPendingViewModel = ns.core.QuestPendingViewModel

local ReportPanelViewModel = {}

-- params.questReport/questEntries are QuestForecastService:report()/:entries()'s
-- own return values (11.5) -- plain data, not the service itself, the same
-- "params is a bag of things the record does not carry" shape XpBarViewModel
-- already uses for restedXp/questPending. Pending experience is quest-log-wide,
-- not level-scoped, so it rides along here rather than coming from `record`.
function ReportPanelViewModel.build(record, params)
  params = params or {}

  if record == nil then
    return { active = false }
  end

  return {
    active = true,
    breakdown = LevelBreakdownViewModel.build(record),
    combat = CombatBreakdownViewModel.build(record),
    abilities = AbilityRankingViewModel.build(record),
    -- `params.currentRecord`, not `record`: the pending tab describes the quest
    -- log of NOW even while the rest of the panel is reading a past level, and
    -- what a creature pays is a fact about the character's current level. Pricing
    -- today's objectives with a finished level's averages would be quoting a
    -- character who no longer exists.
    pending = QuestPendingViewModel.build(params.questReport, params.questEntries, params.currentRecord),
  }
end

ns.core.ReportPanelViewModel = ReportPanelViewModel
