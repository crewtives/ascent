-- Ascent - the level report panel (tasks 11.1-11.5, 11.7; 6.1-6.9).
--
-- The panel used to build each tab as one string and hand it to a single
-- FontString. It now builds ROWS -- see ui/RowList.lua for why that is not a
-- cosmetic change -- and this file's job is to turn each tab's view-model into
-- a list of them.
--
-- WHAT A ROW SAYS AND WHAT IT DOES NOT. Two figures in the sources tab look like
-- one number and are not (design D36): the share of the LEVEL, which in a level
-- still in progress legitimately sums to less than a hundred, and the
-- composition of what was RECORDED, which sums to exactly a hundred. Both are
-- shown, in their own columns, with the composition labelled as what it is a
-- composition of. Printing one while calling it the other was the bug this tab
-- shipped with.
--
-- COLOUR IS NOT ALLOWED TO CARRY MEANING ALONE HERE, and for a reason specific
-- to this addon rather than a general principle: red and green already MEAN
-- creatures and exploration on every other surface, so a comparison that showed
-- "better" in green would collide with the one thing the panel exists to teach.
-- Differences carry a sign; the direction travels from the domain as a field.
--
-- Like the bar, this view never touches SavedVariables: it is handed a resolved
-- `settings` table and a `saveSetting(key, value)` callback for the one thing it
-- persists on its own, its position and size.

local _, ns = ...
ns.ui = ns.ui or {}

local SettingKey = ns.core.SettingKey
local XpSource = ns.core.XpSource
local PlaceContext = ns.core.PlaceContext
local QuestXpOrigin = ns.core.QuestXpOrigin
local TextKey = ns.core.TextKey
local ReportPanelViewModel = ns.core.ReportPanelViewModel
local LevelHistoryViewModel = ns.core.LevelHistoryViewModel
local SkinResolver = ns.core.SkinResolver
local SkinCatalog = ns.core.SkinCatalog
local Palette = ns.core.Palette
local RebuildGate = ns.core.RebuildGate
local QuestNames = ns.core.QuestNames
local KillXpEstimator = ns.core.KillXpEstimator
local BorderKind = ns.core.BorderKind
local TextStyle = ns.core.TextStyle
local RowList = ns.ui.RowList

-- Only the floor lives here now. The panel's default position and size are the
-- shape PANEL_POSITION's own default declares (core/constants/Settings.lua), so
-- a stored one always arrives complete and there is nothing left to fall back to.
local MIN_WIDTH, MIN_HEIGHT = 300, 240

-- How much of the panel has to stay on screen for a player to be able to grab
-- it. Same reasoning and same number as the bar's (ui/XpBarView.lua).
local OFFSCREEN_MARGIN = 40

-- The same style-to-font-flags mapping the bar and the rows use.
local FONT_FLAGS = {
  [TextStyle.PLAIN] = "",
  [TextStyle.OUTLINE] = "OUTLINE",
  [TextStyle.HEAVY] = "THICKOUTLINE",
}

local SOURCE_LABEL = {
  [XpSource.MOB_KILL] = TextKey.SOURCE_CREATURES,
  [XpSource.QUEST_TURNIN] = TextKey.SOURCE_QUESTS,
  [XpSource.EXPLORATION] = TextKey.SOURCE_EXPLORATION,
  [XpSource.UNKNOWN] = TextKey.SOURCE_UNCLASSIFIED,
}

-- The palette key each source paints with, so a row's own colour matches the
-- segment it stands for on the bar. Same order, same colours, one source of
-- truth for both.
local SOURCE_PALETTE = {
  [XpSource.MOB_KILL] = "MOB_KILL",
  [XpSource.QUEST_TURNIN] = "QUEST_TURNIN",
  [XpSource.EXPLORATION] = "EXPLORATION",
  [XpSource.UNKNOWN] = "UNKNOWN",
}

-- One noun per kind of place, so a row can say "Elwynn Forest (Dungeon)" without
-- the view knowing anything about what a dungeon is. Read defensively, like every
-- other map here: a kind this build does not know degrades to the raw value
-- rather than erroring inside a draw.
local PLACE_LABEL = {
  [PlaceContext.WORLD] = TextKey.PLACE_WORLD,
  [PlaceContext.DUNGEON] = TextKey.PLACE_DUNGEON,
  [PlaceContext.RAID] = TextKey.PLACE_RAID,
  [PlaceContext.BATTLEGROUND] = TextKey.PLACE_BATTLEGROUND,
  [PlaceContext.ARENA] = TextKey.PLACE_ARENA,
  [PlaceContext.UNKNOWN] = TextKey.PLACE_UNKNOWN,
}

local ORIGIN_LABEL = {
  [QuestXpOrigin.CLIENT] = TextKey.ORIGIN_CLIENT,
  [QuestXpOrigin.LEARNED] = TextKey.ORIGIN_LEARNED,
  [QuestXpOrigin.UNKNOWN] = TextKey.ORIGIN_UNKNOWN,
}

local TABS = {
  { id = "breakdown", labelKey = TextKey.TAB_SOURCES },
  { id = "combat", labelKey = TextKey.TAB_COMBAT },
  -- The only list whose rows carry an icon, and the list has to know: the room
  -- for it is reserved once for every row, not per row (ui/RowList.lua).
  { id = "abilities", labelKey = TextKey.TAB_ABILITIES, icons = true },
  { id = "pending", labelKey = TextKey.TAB_PENDING },
  { id = "history", labelKey = TextKey.PANEL_TAB_HISTORY },
}

-- One column layout per tab. A column with no width takes what is left, so the
-- shape every tab shares -- a name that stretches, then figures that line up --
-- needs no arithmetic here.
local COLUMNS = {
  -- Four columns since the places block: name, experience, share, rate. The rate
  -- only ever has a value on a place row, and it earns its column there because
  -- the block exists to answer "what is this place worth an hour" -- folding it
  -- into another cell would put two figures under one heading.
  -- The third column is 58 and not 44 because it carries two different kinds of
  -- answer: a percentage on a source or place row, and a COUNT on the rows under
  -- "top quests" and "top creatures". "17 kills" fitted 44 by a hair and
  -- "1 turn-in" did not, so a real report came back reading "1 turn-...". The
  -- fourteen pixels come off the name column, which is the one that can lose
  -- them: it is elastic, and a clipped quest name is still a quest name.
  breakdown = { {}, { width = 70, justify = "RIGHT" }, { width = 58, justify = "RIGHT" },
                { width = 48, justify = "RIGHT" } },
  combat = { {}, { width = 140, justify = "RIGHT" } },
  abilities = { {}, { width = 56, justify = "RIGHT" }, { width = 44, justify = "RIGHT" } },
  pending = { {}, { width = 64, justify = "RIGHT" }, { width = 74, justify = "RIGHT" } },
  history = { {}, { width = 90, justify = "RIGHT" }, { width = 64, justify = "RIGHT" } },
}

-- ---------------------------------------------------------------------------
-- Formatting. Mechanical, and the same reasoning as before: the sorting and the
-- arithmetic these read live in core/ and have their own suites.
-- ---------------------------------------------------------------------------

local function percentText(locale, fraction)
  if fraction == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  return locale:get(TextKey.PERCENT, math.floor(fraction * 100 + 0.5))
end

local function wholePercentText(locale, percent)
  if percent == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  return locale:get(TextKey.PERCENT, percent)
end

local function durationText(locale, seconds)
  if seconds == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  if seconds >= 3600 then
    return locale:get(TextKey.DURATION_HM, math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  elseif seconds >= 60 then
    return locale:get(TextKey.DURATION_MS, math.floor(seconds / 60), math.floor(seconds % 60))
  end
  return locale:get(TextKey.DURATION_S, math.floor(seconds))
end

local function numberText(locale, value)
  if value == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  return tostring(math.floor(value + 0.5))
end

-- A difference, written so its sense survives without colour. The direction is
-- a field the domain computed (LevelHistoryViewModel), not something re-derived
-- from the sign here -- there is one definition of "up" and it lives in core.
local function deltaText(locale, direction, magnitude)
  if direction == "same" then
    return locale:get(TextKey.PANEL_DELTA_SAME)
  elseif direction == "up" then
    return locale:get(TextKey.PANEL_DELTA_UP, magnitude)
  end
  return locale:get(TextKey.PANEL_DELTA_DOWN, magnitude)
end

-- Zero and "not measured" are different answers and must read differently: a
-- place where the player spent time and earned nothing rates exactly zero, while
-- a place whose time was never sampled has no rate at all.
local function ratePerHourText(locale, value)
  if value == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  return locale:get(TextKey.PANEL_PER_HOUR, math.floor(value + 0.5))
end

-- How a quest is written: asked of the directory, never decided here. The bar's
-- popup asks the same thing of the same object, which is what keeps the two from
-- disagreeing about what one quest is called. Without a directory -- a view built
-- in isolation -- every quest keeps its number.
local function questLabel(view, questId)
  return QuestNames.labelOf(view.questNames, view.locale, questId)
end

local function row(cells, extra)
  local result = extra or {}
  result.cells = cells
  return result
end

local function labelRow(locale, key, value)
  return row({ locale:get(key), value })
end

-- ---------------------------------------------------------------------------
-- Tabs. Each returns a list of rows, or nil plus a message for an empty state.
-- ---------------------------------------------------------------------------

local function renderBreakdown(view, breakdown)
  local locale = view.locale
  if not breakdown.active then
    return nil, locale:get(TextKey.PANEL_NO_LEVEL)
  end

  local rows = {
    labelRow(locale, TextKey.PANEL_LBL_PROGRESS, percentText(locale, breakdown.percentComplete)),
    labelRow(locale, TextKey.PANEL_LBL_OBSERVED, tostring(breakdown.observedTotal)),
  }
  if breakdown.partial then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_PARTIAL) })
  end

  rows[#rows + 1] = row({ locale:get(TextKey.PANEL_BY_SOURCE) })
  if #breakdown.sources == 0 then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_NOTHING_YET) })
  end
  for _, source in ipairs(breakdown.sources) do
    -- Indexed only once the key is known to exist: appearance.colors is a strict
    -- proxy, so colors[nil] RAISES instead of returning nil, and a source this
    -- version does not know about would take the whole tab down with it.
    local paletteKey = SOURCE_PALETTE[source.source]
    local color = paletteKey ~= nil and view.appearance.colors[paletteKey] or nil
    rows[#rows + 1] = row({
      locale:get(SOURCE_LABEL[source.source] or source.source),
      tostring(source.amount),
      wholePercentText(locale, source.percent),
    }, {
      color = color,
      -- The bar is the share of the LEVEL, matching what the player sees on the
      -- experience bar itself -- not the composition percentage in the column
      -- beside it, which is a different question with a different denominator.
      bar = { fraction = source.fraction, color = color },
    })
  end

  if breakdown.restedBonus.amount > 0 then
    rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_RESTED_BONUS, tostring(breakdown.restedBonus.amount))
  end
  -- The group and raid annotations, alongside the rested one and read the same
  -- way: a portion of what was already credited, never an addition to it. Shown
  -- only when there is something to say, but the two are independent -- a level
  -- can have both if the player moved between a group and a raid.
  if breakdown.modifiers ~= nil then
    if breakdown.modifiers.groupBonus.amount > 0 then
      rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_GROUP_BONUS,
        tostring(breakdown.modifiers.groupBonus.amount))
    end
    if breakdown.modifiers.raidPenalty.amount > 0 then
      rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_RAID_PENALTY,
        tostring(breakdown.modifiers.raidPenalty.amount))
    end
  end

  -- The second dimension, beside the sources and never instead of them. Guarded
  -- the way the two rankings below are and NOT the way the sources block is: a
  -- level recorded before places existed gets no header and no placeholder,
  -- because "nothing recorded yet" would claim the addon looked and found
  -- nothing, when the truth is that it never looked.
  if breakdown.places ~= nil then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_BY_PLACE) })
    -- Before the rows rather than after them: it qualifies the column the reader
    -- is about to read, and an unqualified rate invites exactly the comparison it
    -- cannot support.
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_PLACE_RATE_NOTE) })
    if breakdown.placedTotal < breakdown.observedTotal then
      rows[#rows + 1] = row({
        locale:get(TextKey.PANEL_PLACE_PARTIAL, breakdown.placedTotal, breakdown.observedTotal),
      })
    end
    for _, place in ipairs(breakdown.places) do
      local name = place.place.name or locale:get(TextKey.PANEL_UNKNOWN_PLACE)
      -- The kind AND the time, both in the name cell. The time is what the rate
      -- beside it divides by, so a row that hides it cannot be checked -- and for
      -- a place that earned nothing it is the only thing the row has to say.
      name = name .. locale:get(TextKey.PANEL_PLACE_CONTEXT,
        locale:get(PLACE_LABEL[place.place.context] or place.place.context),
        durationText(locale, place.seconds))
      rows[#rows + 1] = row({
        name,
        tostring(place.amount),
        wholePercentText(locale, place.percent),
        ratePerHourText(locale, place.xpPerHour),
      }, {
        -- Uncoloured on purpose. Red and green already mean creatures and
        -- exploration in this tab, and a place is not a source; the grey default
        -- keeps the bar readable as a proportion without claiming a meaning.
        bar = { fraction = place.fraction },
      })
    end
  end

  if #breakdown.topQuests > 0 then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_TOP_QUESTS) })
    for _, quest in ipairs(breakdown.topQuests) do
      rows[#rows + 1] = row({
        questLabel(view, quest.questId),
        tostring(quest.xpTotal),
        locale:get(TextKey.PANEL_TURN_INS, quest.turnIns),
      })
    end
  end

  if #breakdown.topCreatures > 0 then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_TOP_CREATURES) })
    for _, creature in ipairs(breakdown.topCreatures) do
      local name = creature.creatureKey.name or locale:get(TextKey.PANEL_UNKNOWN_CREATURE)
      local creatureLevel = creature.creatureKey.level
      if creatureLevel then
        name = name .. locale:get(TextKey.PANEL_CREATURE_LEVEL, creatureLevel)
      end
      rows[#rows + 1] = row({ name, tostring(creature.xpTotal), locale:get(TextKey.PANEL_KILLS, creature.kills) })
    end
  end

  return rows
end

local function renderCombat(view, combat)
  local locale = view.locale
  if not combat.active then
    return nil, locale:get(TextKey.PANEL_NO_LEVEL)
  end
  if not combat.hasData then
    return nil, locale:get(TextKey.PANEL_NO_COMBAT)
  end

  local avgWorst = function(pair)
    return locale:get(TextKey.PANEL_AVG_WORST, percentText(locale, pair.average), percentText(locale, pair.worst))
  end

  return {
    labelRow(locale, TextKey.PANEL_LBL_HEALTH, avgWorst(combat.health)),
    labelRow(locale, TextKey.PANEL_LBL_RESOURCE, avgWorst(combat.power)),
    labelRow(locale, TextKey.PANEL_LBL_DEATHS, tostring(combat.deathCount)),
    labelRow(locale, TextKey.PANEL_LBL_TIME_LOST, durationText(locale, combat.time.timeLostToDeath)),
    labelRow(locale, TextKey.PANEL_LBL_TIME_COMBAT, durationText(locale, combat.time.combatSeconds)),
    labelRow(locale, TextKey.PANEL_LBL_TIME_RECOVER, durationText(locale, combat.time.recoverySeconds)),
    labelRow(locale, TextKey.PANEL_LBL_TIME_OUT, durationText(locale, combat.time.outOfCombatSeconds)),
    labelRow(locale, TextKey.PANEL_LBL_DAMAGE_DEALT, tostring(combat.damage.dealt)),
    labelRow(locale, TextKey.PANEL_LBL_DAMAGE_TAKEN, tostring(combat.damage.taken)),
    labelRow(locale, TextKey.PANEL_LBL_HEALING, tostring(combat.damage.healingReceived)),
    labelRow(locale, TextKey.PANEL_LBL_XP_PER_MINUTE, numberText(locale, combat.efficiency.xpPerCombatMinute)),
    labelRow(locale, TextKey.PANEL_LBL_XP_PER_KILL, numberText(locale, combat.efficiency.averageXpPerKill)),
  }
end

-- Which of the two reserved synthetic keys a row is, named. The keys are shared
-- with the pull plate through core/constants/Text.lua rather than duplicated,
-- for the same reason the four source names are: two surfaces must not learn to
-- call the same thing by two names. Until this existed both auto attacks were
-- labelled "Auto attack", so a melee swing and a ranged shot were
-- indistinguishable on the surface whose job is to say what you pressed.
local AUTO_ATTACK_LABEL = {
  [ns.core.AbilityKey.MELEE_SWING] = TextKey.PANEL_AUTO_ATTACK,
  [ns.core.AbilityKey.RANGED_AUTO] = TextKey.PANEL_RANGED_ATTACK,
}

local function renderAbilities(view, abilities)
  local locale = view.locale
  if not abilities.active then
    return nil, locale:get(TextKey.PANEL_NO_LEVEL)
  end
  if #abilities.entries == 0 then
    return nil, locale:get(TextKey.PANEL_NO_ABILITIES)
  end

  local rows = { labelRow(locale, TextKey.PANEL_LBL_TOTAL_USES, tostring(abilities.totalUses)) }
  for _, entry in ipairs(abilities.entries) do
    local name = entry.name
      or (entry.isAutoAttack and locale:get(AUTO_ATTACK_LABEL[entry.key] or TextKey.PANEL_AUTO_ATTACK))
      or locale:get(TextKey.PANEL_SPELL, tostring(entry.key))
    -- An icon the client cannot resolve is left out rather than replaced with a
    -- question mark: a row with no icon reads as "no icon", a row with a
    -- placeholder reads as "something is broken".
    local icon
    if not entry.isAutoAttack and GetSpellTexture ~= nil then
      icon = GetSpellTexture(entry.key)
    end
    rows[#rows + 1] = row({ name, tostring(entry.count), percentText(locale, entry.fraction) }, {
      icon = icon,
      bar = { fraction = entry.fraction },
    })
  end
  return rows
end

-- Never folded into the breakdown's total: this is a projection from the quest
-- log, not experience obtained -- the same separation the bar keeps between its
-- earned segments and its own pending channel.
local function renderPending(view, pending)
  local locale = view.locale
  -- The one view the level selector CANNOT follow, and it says so rather than
  -- showing today's quest log under a level from last week. Pending experience
  -- is read from the quest log as it stands now; it is not a property of a
  -- level, so there is no past version of it to show.
  if view:isPinned() then
    return nil, locale:get(TextKey.PANEL_PENDING_IS_NOW)
  end
  if not pending.active then
    return nil, locale:get(TextKey.PANEL_NO_LEVEL)
  end
  if #pending.entries == 0 then
    return nil, locale:get(TextKey.PANEL_NO_PENDING)
  end

  local rows = {
    labelRow(locale, TextKey.PANEL_LBL_PENDING_TOTAL, tostring(pending.total)),
    labelRow(locale, TextKey.PANEL_LBL_READY_TOTAL, tostring(pending.readyTotal)),
  }
  if pending.unknownCount > 0 then
    rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_UNKNOWN_QUESTS, tostring(pending.unknownCount))
  end

  rows[#rows + 1] = row({ locale:get(TextKey.PANEL_BY_QUEST) })
  -- Printed once at the end if any row used it, rather than per row: the mark is
  -- what the reader needs beside the figure, and the sentence explaining it is
  -- what they need once.
  local rough = false
  for _, entry in ipairs(pending.entries) do
    -- "Not recorded" and "zero" are different answers and must not share a
    -- cell: a quest whose reward nobody has seen is unknown, not worthless.
    local amount = entry.isKnown and tostring(entry.adjustedReward) or locale:get(TextKey.NOT_AVAILABLE)
    local label = questLabel(view, entry.questId)
    if entry.complete then
      label = label .. locale:get(TextKey.PANEL_READY_MARK)
    end
    rows[#rows + 1] = row({ label, amount, locale:get(ORIGIN_LABEL[entry.origin] or entry.origin) })

    -- What this quest still asks the player to kill, and what those kills are
    -- worth. Under the quest and never added to it: the reward is paid on
    -- turn-in and these are paid by killing, and they will be recorded as
    -- creatures when they are (pending-detail design D2).
    for _, objective in ipairs(entry.objectives or {}) do
      local estimate
      if objective.estimate == nil then
        estimate = locale:get(TextKey.PANEL_OBJ_NO_RATE)
      elseif objective.basis == KillXpEstimator.Basis.LEVEL then
        rough = true
        estimate = locale:get(TextKey.PANEL_OBJ_ROUGH, objective.estimate)
      else
        estimate = locale:get(TextKey.PANEL_OBJ_ESTIMATE, objective.estimate)
      end
      rows[#rows + 1] = row({
        locale:get(TextKey.PANEL_OBJECTIVE, objective.creature, objective.done, objective.needed),
        estimate,
      })
    end
  end

  if rough then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_OBJ_FOOTNOTE) })
  end

  return rows
end

-- The history selector and the comparison against the level before it.
local function renderHistory(view)
  local locale = view.locale
  local model = LevelHistoryViewModel.build({
    levels = view.completedLevels(),
    current = view.currentLevel(),
    selected = view.selectedLevel,
  })

  if model.empty then
    return nil, locale:get(TextKey.PANEL_HISTORY_EMPTY)
  end

  local rows = {}
  for _, entry in ipairs(model.entries) do
    local label = locale:get(TextKey.PANEL_LEVEL_ROW, entry.level)
    if entry.current then
      label = label .. " (" .. locale:get(TextKey.PANEL_CURRENT_MARK) .. ")"
    end
    local record = view.recordFor(entry.level)
    local duration = record ~= nil and durationText(locale, record.playedSeconds)
      or locale:get(TextKey.PANEL_NOT_RECORDED)
    rows[#rows + 1] = row({ label, duration, "" }, { selected = entry.selected, level = entry.level })
  end

  -- The previous RECORDED level, which is the entry below this one in a list
  -- already sorted descending -- not `selected - 1`. They differ exactly when
  -- the history has a hole in it (the addon installed mid-levelling, a level
  -- played with it disabled, a level dropped by retention), and in that case
  -- asking for `selected - 1` finds nothing and the panel claims there is no
  -- earlier level to compare against when there plainly is one.
  local previousLevel
  for index, entry in ipairs(model.entries) do
    if entry.level == model.selected then
      previousLevel = model.entries[index + 1] ~= nil and model.entries[index + 1].level or nil
      break
    end
  end

  local selected = view.recordFor(model.selected)
  local previous = previousLevel ~= nil and view.recordFor(previousLevel) or nil
  local comparison = LevelHistoryViewModel.compare(selected, previous)

  if not comparison.available then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_NO_PREVIOUS) })
    return rows
  end

  rows[#rows + 1] = row({ locale:get(TextKey.PANEL_COMPARE_HEADER, comparison.previousLevel) })
  rows[#rows + 1] = row({
    locale:get(TextKey.PANEL_LBL_DURATION),
    durationText(locale, comparison.duration.seconds),
    deltaText(locale, comparison.duration.direction, durationText(locale, math.abs(comparison.duration.delta))),
  })
  for _, entry in ipairs(comparison.sources) do
    local paletteKey = SOURCE_PALETTE[entry.source]
    local color = paletteKey ~= nil and view.appearance.colors[paletteKey] or nil
    rows[#rows + 1] = row({
      locale:get(SOURCE_LABEL[entry.source] or entry.source),
      wholePercentText(locale, entry.percent),
      deltaText(locale, entry.direction, math.abs(entry.delta)),
    }, { color = color })
  end

  return rows
end

local RENDERERS = {
  breakdown = function(view) return renderBreakdown(view, view.lastViewModel.breakdown) end,
  combat = function(view) return renderCombat(view, view.lastViewModel.combat) end,
  abilities = function(view) return renderAbilities(view, view.lastViewModel.abilities) end,
  pending = function(view) return renderPending(view, view.lastViewModel.pending) end,
  history = renderHistory,
}

-- ---------------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------------

local ReportPanelView = {}
ReportPanelView.__index = ReportPanelView

-- Pulled back inside the visible screen, the same rule and the same margin the
-- bar applies to its own saved position (ui/XpBarView.lua). The panel needed it
-- just as much and did not have it: the position is re-applied on every login,
-- so a panel saved on a monitor that is no longer attached stayed unreachable,
-- and unlike the bar there is no chat command that puts it back.
function ReportPanelView:clampedPosition(position)
  local width, height = UIParent:GetWidth(), UIParent:GetHeight()
  if type(width) ~= "number" or type(height) ~= "number" or width <= 0 then
    return position.x, position.y
  end

  local limitX = width / 2 + OFFSCREEN_MARGIN
  local limitY = height / 2 + OFFSCREEN_MARGIN
  local x, y = position.x, position.y
  if x > limitX then x = limitX elseif x < -limitX then x = -limitX end
  if y > limitY then y = limitY elseif y < -limitY then y = -limitY end
  return x, y
end

function ReportPanelView:applySavedPosition()
  local position = self.settings[SettingKey.PANEL_POSITION]
  local x, y = self:clampedPosition(position)
  self.frame:ClearAllPoints()
  self.frame:SetPoint(position.point, UIParent, position.point, x, y)
  -- Clamped on the way in, not only on the way out: a size saved by a build
  -- whose minimum never applied is already on disk, and re-applying it verbatim
  -- would carry the bug forward forever.
  self.frame:SetSize(
    math.max(position.width, MIN_WIDTH),
    math.max(position.height, MIN_HEIGHT)
  )
end

function ReportPanelView:savePosition()
  local point, _, _, x, y = self.frame:GetPoint()
  self.saveSetting(SettingKey.PANEL_POSITION, {
    point = point, x = x, y = y,
    width = self.frame:GetWidth(), height = self.frame:GetHeight(),
  })
end

-- The panel wears the same skin as the bar (task 6.9). Not for tidiness: the
-- source colours have to be the same ones, or a player reading a row and then
-- glancing at the bar is matching two different palettes for the same thing.
function ReportPanelView:resolveAppearance()
  return SkinResolver.resolve({
    skin = SkinResolver.skinFor(SkinCatalog, self.settings[SettingKey.BAR_SKIN], ns.core.DEFAULT_SKIN_ID),
    overrides = self.settings[SettingKey.BAR_APPEARANCE],
    colors = self.settings[SettingKey.BAR_COLORS],
    palette = Palette,
    highContrast = self.settings[SettingKey.HIGH_CONTRAST],
  })
end

function ReportPanelView:applyAppearance()
  self.appearance = self:resolveAppearance()

  local background = self.appearance.background
  -- The panel is a reading surface, so it gets a floor the bar does not need: a
  -- skin meant for a 24-pixel strip over the world can be nearly transparent,
  -- and a page of numbers over the world at that alpha is unreadable.
  local alpha = math.max(background.a or 0, 0.82)
  self.background:SetColorTexture(background.r, background.g, background.b, alpha)

  self:applyBorder(self.appearance.border)
  self:applyChromeFont(self.appearance.text)

  for _, list in pairs(self.lists) do
    list:applyAppearance(self.appearance)
  end

  return self
end

-- The bar's own border rules, applied to the panel (ui/BarRenderer.lua's
-- applyBorder). The panel used to take only the colour, so a skin declaring a
-- three-pixel frame drew three pixels on the bar and one on the panel, and a
-- player who set the border to NONE lost it on the bar and kept it here. The
-- edges keep their two-corner anchoring rather than an explicit length, because
-- unlike the bar this frame is resizable and the length has to follow.
function ReportPanelView:applyBorder(border)
  if border.kind == BorderKind.NONE or border.thickness <= 0 then
    for _, edge in ipairs(self.edges) do
      edge:Hide()
    end
    return
  end

  local color = border.color
  local light = border.kind == BorderKind.BEVEL
  for index, edge in ipairs(self.edges) do
    -- 1 and 2 are the horizontal edges, 3 and 4 the vertical ones; see the
    -- geometry they were built from in createFrame.
    if index <= 2 then
      edge:SetHeight(border.thickness)
    else
      edge:SetWidth(border.thickness)
    end
    -- Top and left lit, bottom and right dimmed: the same depth cue, and the
    -- same two indices, as the bar.
    local factor = 1
    if light then
      factor = (index == 1 or index == 3) and 1.25 or 0.6
    end
    edge:SetColorTexture(
      math.min(color.r * factor, 1), math.min(color.g * factor, 1),
      math.min(color.b * factor, 1), color.a or 1
    )
    edge:Show()
  end
end

-- The panel's own furniture -- its title, its tab buttons and the empty-state
-- message -- wearing the skin too. Without this the one thing a player sees on
-- an empty panel is the only element that does not match the skin they picked.
-- Every path comes from GetFont rather than a literal, for the same reason the
-- bar does it: a Latin font named here is invisible text on a Korean client.
local function styleFontString(fontString, size, flags, color)
  if fontString == nil then
    return
  end
  local path = fontString:GetFont()
  if path ~= nil then
    fontString:SetFont(path, size, flags)
  end
  if color ~= nil then
    fontString:SetTextColor(color.r, color.g, color.b, color.a or 1)
  end
end

function ReportPanelView:applyChromeFont(text)
  local flags = FONT_FLAGS[text.style] or "OUTLINE"
  styleFontString(self.title, text.size + 2, flags, text.color)
  styleFontString(self.empty, math.max(9, text.size - 1), flags, text.color)
  for _, tab in ipairs(TABS) do
    local button = self.tabButtons[tab.id]
    if button ~= nil and button.GetFontString ~= nil then
      styleFontString(button:GetFontString(), math.max(9, text.size - 1), flags, nil)
    end
  end
end

-- WHICH LEVEL THE PANEL IS READING (task 6.7).
--
-- `selectedLevel` nil does not mean "nothing selected": it means FOLLOW the
-- level in progress. That distinction is the whole of it. Storing the current
-- level's number the moment the player clicks its row would pin the panel to it
-- silently, and the next time the character levelled they would be reading a
-- finished level with nothing on screen saying so and no way back to the new
-- one except noticing.
function ReportPanelView:select(level)
  -- nil and "the level in progress" are the same request: go back to following
  -- the live level. nil is what the composition root passes after erasing the
  -- character's history, when the level the panel was reading no longer exists.
  if level == nil or level == self.currentLevel() then
    self.selectedLevel = nil
  else
    self.selectedLevel = level
  end
  self.selectedRecord, self.selectedRecordLevel = nil, nil
  -- Marked dirty, not just redrawn. The gate hands back nil for a panel that
  -- has not changed, so without this the rebuild below never happens and every
  -- tab but this one keeps the level it already had.
  self:markDirty()
  self:refresh()
end

-- Whether the panel is showing a level OTHER than the one in progress.
function ReportPanelView:isPinned()
  return self.selectedLevel ~= nil and self.selectedLevel ~= self.currentLevel()
end

-- The record every tab is built from: the selected level when there is one, and
-- the level in progress otherwise.
--
-- MEMOISED, and not as a micro-optimisation. `recordFor` reaches the store,
-- which rebuilds a whole LevelRecord out of saved data on every call
-- (core/service/RecordStore.lua's `completed`), and this runs on every rebuild
-- -- which is every experience gain while the panel is open. A panel left on a
-- past level would deserialize that level several times a second. A completed
-- level does not change, so resolving it once per selection is not a staleness
-- risk; the level in progress is never memoised, because it is the live object.
--
-- A selection that stops resolving -- the level dropped by retention, the
-- history erased -- clears itself rather than leaving the panel half pinned:
-- LevelHistoryViewModel already falls the LIST back to the most recent entry,
-- and without this the rest of the panel would follow the live level while
-- `isPinned` still said otherwise.
function ReportPanelView:viewedRecord()
  if self.selectedLevel ~= nil then
    if self.selectedRecordLevel ~= self.selectedLevel then
      self.selectedRecord = self.recordFor(self.selectedLevel)
      self.selectedRecordLevel = self.selectedLevel
    end
    if self.selectedRecord ~= nil then
      return self.selectedRecord
    end
    self.selectedLevel, self.selectedRecordLevel = nil, nil
  end
  return self.currentRecord()
end

function ReportPanelView:selectTab(tabId)
  self.activeTab = tabId
  for _, tab in ipairs(TABS) do
    -- A locked highlight, not a disabled button. Greying a button out is the
    -- client's own vocabulary for "you cannot use this", which is the opposite
    -- of what the current tab means.
    local button = self.tabButtons[tab.id]
    if tab.id == tabId then
      button:LockHighlight()
    else
      button:UnlockHighlight()
    end
    if tab.id == tabId then
      self.lists[tab.id]:show()
    else
      self.lists[tab.id]:hide()
    end
  end
  self:renderActiveTab()
end

function ReportPanelView:renderActiveTab()
  local list = self.lists[self.activeTab]

  -- The history tab reads the store rather than the level's view-model, so it
  -- has something to show even when there is no level in progress at all.
  --
  -- WHICH EMPTY STATE. There are two, and the panel used to pick between them on
  -- `lastViewModel == nil` -- a condition that is only ever true in the moment
  -- between construction and the first refresh, with the frame still hidden. So
  -- the first-run message was unreachable, and a player installing the addon was
  -- told they were at the maximum level or had experience turned off. What
  -- actually separates the two states is whether anything has ever been
  -- recorded, and the view already holds the seam that answers it.
  if (self.lastViewModel == nil or not self.lastViewModel.active) and self.activeTab ~= "history" then
    list:clear()
    -- Three ways to have no level to show, and only one of them is a new
    -- install. A character at the cap has nothing in progress and never will,
    -- so promising that recording starts at their next point of experience is a
    -- promise that cannot be kept -- which is what keying this on "nothing
    -- completed" alone did to a level-60 Classic Era install.
    local firstRun = not self.atCap() and #self.completedLevels() == 0
    self.empty:SetText(self.locale:get(firstRun and TextKey.PANEL_FIRST_RUN or TextKey.PANEL_NO_LEVEL_MAX))
    self.empty:Show()
    return
  end

  local rows, message = RENDERERS[self.activeTab](self)
  if rows == nil then
    list:clear()
    self.empty:SetText(message or "")
    self.empty:Show()
    return
  end

  self.empty:Hide()
  list:setRows(rows)
end

function ReportPanelView:createFrame()
  local frame = CreateFrame("Frame", "AscentReportPanel", UIParent)
  frame:SetFrameStrata("HIGH")
  if frame.SetClipsChildren then
    frame:SetClipsChildren(true)
  end
  frame:SetMovable(true)
  frame:SetResizable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  -- SetMinResize does not exist on these clients -- the guard below never fired,
  -- which is why the panel could be dragged down to nothing and have that size
  -- persisted and re-applied on the next login. SetResizeBounds is the one the
  -- client actually has; the older name stays as a fallback rather than an
  -- assumption.
  if frame.SetResizeBounds then
    frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
  elseif frame.SetMinResize then
    frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
  end

  self.frame = frame

  self.background = frame:CreateTexture(nil, "BACKGROUND")
  self.background:SetAllPoints(frame)

  -- Four thin textures, the same border the bar draws, for the same reason: a
  -- backdrop would need the frame built from a template and scales its edge art.
  self.edges = {}
  local edgeGeometry = {
    { "TOPLEFT", "TOPRIGHT", 0, 1 },
    { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 1 },
    { "TOPLEFT", "BOTTOMLEFT", 1, 0 },
    { "TOPRIGHT", "BOTTOMRIGHT", 1, 0 },
  }
  for index, spec in ipairs(edgeGeometry) do
    local edge = frame:CreateTexture(nil, "OVERLAY")
    edge:SetPoint(spec[1], frame, spec[1], 0, 0)
    edge:SetPoint(spec[2], frame, spec[2], 0, 0)
    if spec[3] > 0 then edge:SetWidth(spec[3]) else edge:SetHeight(spec[4]) end
    self.edges[index] = edge
  end

  local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -10)
  title:SetText(self.locale:get(TextKey.PANEL_TITLE))

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 0, 0)
  close:SetScript("OnClick", function() self:close() end)

  -- A way into the settings from the surface the player is actually looking at.
  -- The panel is where someone notices they want the bar to say something else,
  -- and until now the only way there was remembering a slash command or walking
  -- the client's own options tree -- two steps away from the thought that caused
  -- it. It opens by the same path `/ascent options panel` takes, degrading the
  -- same way on a client that has neither options API, rather than learning a
  -- second way in that could drift from the first.
  --
  -- Optional, so the view stays instantiable without the seam -- which is what
  -- keeps it testable at all.
  if self.onOpenOptions ~= nil then
    local options = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    options:SetSize(64, 20)
    options:SetPoint("RIGHT", close, "LEFT", -2, 0)
    options:SetText(self.locale:get(TextKey.PANEL_OPTIONS))
    options:SetScript("OnClick", function() self.onOpenOptions() end)
    options:SetScript("OnEnter", function()
      if GameTooltip == nil then
        return
      end
      GameTooltip:SetOwner(options, "ANCHOR_LEFT")
      GameTooltip:AddLine(self.locale:get(TextKey.PANEL_OPTIONS))
      GameTooltip:AddLine(self.locale:get(TextKey.PANEL_OPTIONS_TIP), 1, 1, 1, true)
      GameTooltip:Show()
    end)
    options:SetScript("OnLeave", function()
      if GameTooltip ~= nil then
        GameTooltip:Hide()
      end
    end)
    self.optionsButton = options
  end

  local previousButton
  local tabButtons = {}
  for _, tab in ipairs(TABS) do
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(78, 22)
    if previousButton == nil then
      button:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    else
      button:SetPoint("LEFT", previousButton, "RIGHT", 2, 0)
    end
    button:SetText(self.locale:get(tab.labelKey))
    button:SetScript("OnClick", function() self:selectTab(tab.id) end)
    tabButtons[tab.id] = button
    previousButton = button
  end

  -- One list per tab rather than one list reconfigured on every switch: the
  -- columns differ per tab, and a pool whose row layout changes underneath it
  -- has to rebuild every row anyway.
  self.lists = {}
  for _, tab in ipairs(TABS) do
    local list = RowList.new({
      parent = frame,
      -- Named, and named uniquely: see RowList.new's own header for why a nil
      -- name here is a load-time failure and not a cosmetic omission.
      name = "AscentPanelList" .. tab.id,
      columns = COLUMNS[tab.id],
      icons = tab.icons,
      onSelect = tab.id == "history" and function(level) self:select(level) end or nil,
    })
    -- Anchored to the frame, not to the last tab button: the row of tabs is
    -- laid out left to right and its end moves when a tab is added, renamed or
    -- translated into a longer word.
    list:setPoints("TOPLEFT", frame, "TOPLEFT", 12, -66)
    list:hide()
    self.lists[tab.id] = list
  end

  -- The empty state is a message, not an empty list: a blank panel reads as a
  -- bug, and every one of these states is a normal thing to be in.
  self.empty = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  self.empty:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -72)
  self.empty:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
  self.empty:SetJustifyH("LEFT")
  self.empty:Hide()

  local resizeHandle = CreateFrame("Button", nil, frame)
  resizeHandle:SetPoint("BOTTOMRIGHT", -4, 4)
  resizeHandle:SetSize(16, 16)
  resizeHandle:EnableMouse(true)
  resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  resizeHandle:SetScript("OnMouseDown", function()
    frame:StartSizing("BOTTOMRIGHT")
  end)
  resizeHandle:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    self:savePosition()
    self:layoutLists()
    self:renderActiveTab()
  end)

  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    self:savePosition()
  end)

  self.title = title
  self.tabButtons = tabButtons

  self:applySavedPosition()
  self:layoutLists()
  frame:Hide()
end

-- The lists are sized rather than anchored on all four sides so that the scroll
-- child knows its own width: a row's columns are laid out from it.
function ReportPanelView:layoutLists()
  local width = math.max(MIN_WIDTH, self.frame:GetWidth() or MIN_WIDTH) - 44
  local height = math.max(60, (self.frame:GetHeight() or MIN_HEIGHT) - 92)
  for _, list in pairs(self.lists) do
    list:setSize(width, height)
  end
end

-- `options`: settings (already resolved), saveSetting(key, value),
-- currentRecord() -- a function returning the LevelRecord to build the panel
-- from -- questForecastService (read directly: it is core/'s own service, not an
-- adapter type), `questNames` (the same, and the single answer to what a quest is
-- called; without it every quest row falls back to its number), `locale` (every
-- player-visible string goes through it), and the three history seams:
-- completedLevels(), recordFor(level) and currentLevel().
-- The history ones are optional; without them that tab shows its empty state
-- rather than failing, which is what lets this view be built in isolation.
function ReportPanelView.new(options)
  options = options or {}
  for _, required in ipairs({ "settings", "saveSetting", "currentRecord", "questForecastService", "locale" }) do
    if options[required] == nil then
      error("ReportPanelView needs a " .. required, 2)
    end
  end

  local self = setmetatable({
    settings = options.settings,
    saveSetting = options.saveSetting,
    currentRecord = options.currentRecord,
    questForecastService = options.questForecastService,
    questNames = options.questNames,
    locale = options.locale,
    completedLevels = options.completedLevels or function() return {} end,
    recordFor = options.recordFor or function() return nil end,
    currentLevel = options.currentLevel or function() return nil end,
    -- Whether the character can still gain a level at all. The panel cannot
    -- work this out -- "no level in progress" looks the same at the cap, with
    -- experience switched off and on a brand-new install -- and the three want
    -- different sentences.
    atCap = options.atCap or function() return false end,
    -- Optional, and its absence is the whole degraded path: a client where the
    -- options never registered has nowhere to send the player, and no button.
    onOpenOptions = options.onOpenOptions,
    -- nil means "follow the level in progress", not "nothing selected".
    selectedLevel = nil,
    viewedLevel = nil,
    gate = RebuildGate.new(),
    activeTab = TABS[1].id,
    lastViewModel = nil,
  }, ReportPanelView)

  self.appearance = self:resolveAppearance()
  self:createFrame()
  self:applyAppearance()
  self:selectTab(self.activeTab)

  return self
end

-- Re-reads settings and reapplies what comes out of them, without rebuilding a
-- frame. Same contract as the bar's own applySettings.
function ReportPanelView:applySettings(settings)
  self.settings = settings or self.settings
  self:applyAppearance()
  self:applySavedPosition()
  self:layoutLists()
  -- Not while it is closed. Bootstrap calls this from `saveSetting`, and the
  -- options panel writes a setting on every slider release, so an unguarded
  -- render here runs a whole tab's worth of rows into a hidden list for a panel
  -- nobody is looking at. `open` draws what a closed panel missed.
  if self:isOpen() then
    self:renderActiveTab()
  end
  return self
end

-- The title carries the level, because once the selector reaches every tab the
-- number is the only thing separating "the level I am in" from "a level I
-- finished a week ago" -- and the tabs themselves look identical either way.
function ReportPanelView:updateTitle()
  if self.viewedLevel ~= nil then
    self.title:SetText(self.locale:get(TextKey.PANEL_TITLE_LEVEL, self.viewedLevel))
  else
    self.title:SetText(self.locale:get(TextKey.PANEL_TITLE))
  end
end

function ReportPanelView:isOpen()
  return self.frame:IsShown()
end

function ReportPanelView:open()
  self.frame:Show()
  -- `refresh` draws when the gate had something new. When it did not, the tab
  -- still has to be drawn -- what is on it may predate a settings change made
  -- while the panel was closed, which is not redrawn then on purpose. Asking
  -- refresh whether it drew is what keeps this from rendering every row twice
  -- on every open that did have something new.
  if not self:refresh() then
    self:renderActiveTab()
  end
end

function ReportPanelView:close()
  self.frame:Hide()
  -- The selection is a reading position, not a setting. The spec's "Apertura
  -- por comando" says the panel opens on the level in progress, so a level
  -- pinned in one sitting must not still be pinned the next time it is opened.
  self.selectedLevel, self.selectedRecord, self.selectedRecordLevel = nil, nil, nil
  self:markDirty()
end

function ReportPanelView:toggle()
  if self:isOpen() then
    self:close()
  else
    self:open()
  end
end

-- Marks the panel's own view-model stale. Bootstrap calls this on the same
-- topics that mark the bar's RedrawScheduler dirty (RECORD_UPDATED and
-- friends) -- this view just does not act on it until it is actually shown.
function ReportPanelView:markDirty()
  self.gate:markDirty()
end

-- Called from Bootstrap's own ticker, same as the bar's redraw(). The gate
-- decides whether there is anything to do at all: closed, or open-but-
-- unchanged, both return without touching the record or rebuilding a single
-- table.
-- Returns whether it actually rebuilt and redrew, so `open` can tell a panel
-- that just repainted itself from one that did not and still needs to be.
function ReportPanelView:refresh()
  local record
  local viewModel = self.gate:refresh(self:isOpen(), function()
    record = self:viewedRecord()
    return ReportPanelViewModel.build(record, {
      questReport = self.questForecastService:report(),
      questEntries = self.questForecastService:entries(),
      -- The level in progress, whatever level the panel is showing: the pending
      -- tab is about now, and so are the kill rates its estimates are priced with.
      currentRecord = self.currentRecord(),
    })
  end)
  if viewModel == nil then
    return false
  end
  self.lastViewModel = viewModel
  self.viewedLevel = record ~= nil and record.level or nil
  self:updateTitle()
  self:renderActiveTab()
  return true
end

ns.ui.ReportPanelView = ReportPanelView
