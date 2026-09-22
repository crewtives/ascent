-- Ascent - the level report panel.
--
-- Turns each tab's view-model into rows for a RowList.
--
-- The sources tab shows two figures that look alike: the share of the level,
-- which sums to under a hundred while the level is in progress, and the
-- composition of what was recorded, which sums to exactly a hundred. Each has
-- its own column, and the composition is labelled as such.
--
-- Colour never carries meaning alone: red and green already mean creatures and
-- exploration, so a "better" in green would collide with them. Differences
-- carry a sign, and the direction comes from the domain as a field.
--
-- The view never touches SavedVariables: it gets a resolved `settings` table
-- and a `saveSetting(key, value)` callback for its position and size.

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
local SpellIcon = ns.ui.SpellIcon
-- The sentence for what a level was recorded without, shared with the bar and the
-- chat summary so the three say it the same way.
local UnavailableText = ns.core.UnavailableText
local RecordedSource = ns.core.RecordedSource

-- Only the floor lives here: the default position and size are the shape
-- PANEL_POSITION's default declares (core/constants/Settings.lua), so a stored
-- one always arrives complete.
local MIN_WIDTH, MIN_HEIGHT = 300, 240

-- How much of the panel has to stay on screen to be grabbed; the same number
-- as the bar's (ui/XpBarView.lua).
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

-- The palette key each source paints with, so a row's colour matches its
-- segment on the bar.
local SOURCE_PALETTE = {
  [XpSource.MOB_KILL] = "MOB_KILL",
  [XpSource.QUEST_TURNIN] = "QUEST_TURNIN",
  [XpSource.EXPLORATION] = "EXPLORATION",
  [XpSource.UNKNOWN] = "UNKNOWN",
}

-- One noun per kind of place, so a row can say "Elwynn Forest (Dungeon)". Read
-- defensively like every map here: an unknown kind degrades to the raw value
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
  -- The only list whose rows carry an icon; RowList reserves the room once for
  -- every row, so it must be told.
  { id = "abilities", labelKey = TextKey.TAB_ABILITIES, icons = true },
  { id = "pending", labelKey = TextKey.TAB_PENDING },
  { id = "history", labelKey = TextKey.PANEL_TAB_HISTORY },
}

-- One column layout per tab. A column with no width takes what is left, so a
-- stretching name followed by aligned figures needs no arithmetic here.
local COLUMNS = {
  -- Name, experience, share, rate. Only place rows have a rate, and it gets
  -- its own column rather than sharing a cell with another figure.
  -- The third column holds a percentage on source and place rows and a count
  -- ("1 turn-in", "17 kills") under the top quests and creatures, which needs
  -- 58 pixels; they come off the elastic name column.
  breakdown = { {}, { width = 70, justify = "RIGHT" }, { width = 58, justify = "RIGHT" },
                { width = 48, justify = "RIGHT" } },
  combat = { {}, { width = 140, justify = "RIGHT" } },
  abilities = { {}, { width = 56, justify = "RIGHT" }, { width = 44, justify = "RIGHT" } },
  pending = { {}, { width = 64, justify = "RIGHT" }, { width = 74, justify = "RIGHT" } },
  history = { {}, { width = 90, justify = "RIGHT" }, { width = 64, justify = "RIGHT" } },
}

-- ---------------------------------------------------------------------------
-- Formatting. Mechanical: the sorting and arithmetic these read live in core/
-- and have their own suites.
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
-- a field LevelHistoryViewModel computed, never re-derived from the sign here.
local function deltaText(locale, direction, magnitude)
  if direction == "same" then
    return locale:get(TextKey.PANEL_DELTA_SAME)
  elseif direction == "up" then
    return locale:get(TextKey.PANEL_DELTA_UP, magnitude)
  end
  return locale:get(TextKey.PANEL_DELTA_DOWN, magnitude)
end

-- Zero and "not measured" read differently: time spent earning nothing rates
-- zero, while a place whose time was never sampled has no rate.
local function ratePerHourText(locale, value)
  if value == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  return locale:get(TextKey.PANEL_PER_HOUR, math.floor(value + 0.5))
end

-- How a quest is written: asked of the directory the bar's popup also asks, so
-- both name a quest the same way. Without a directory every quest keeps its
-- number.
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
  -- Above the rows, because it changes how they read: what the kill line would
  -- have named is in Unclassified.
  if breakdown.sourcesUnavailable ~= nil then
    rows[#rows + 1] = row({ locale:get(UnavailableText[RecordedSource.XP_CHAT][breakdown.sourcesUnavailable]) })
  end
  if #breakdown.sources == 0 then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_NOTHING_YET) })
  end
  for _, source in ipairs(breakdown.sources) do
    -- Indexed only once the key is known: appearance.colors is a strict proxy,
    -- so colors[nil] raises, and an unknown source would break the whole tab.
    local paletteKey = SOURCE_PALETTE[source.source]
    local color = paletteKey ~= nil and view.appearance.colors[paletteKey] or nil
    rows[#rows + 1] = row({
      locale:get(SOURCE_LABEL[source.source] or source.source),
      tostring(source.amount),
      wholePercentText(locale, source.percent),
    }, {
      color = color,
      -- The bar is the share of the level, as on the experience bar, not the
      -- composition percentage in the column beside it.
      bar = { fraction = source.fraction, color = color },
    })
  end

  if breakdown.restedBonus.amount > 0 then
    rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_RESTED_BONUS, tostring(breakdown.restedBonus.amount))
  end
  -- The group and raid annotations read like the rested one: a portion of what
  -- was already credited, never an addition. Each is shown only when non-zero,
  -- independently, since a level can have both.
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

  -- Places, beside the sources, never instead of them. Unlike the sources block,
  -- a level recorded before places were tracked gets no header and no
  -- placeholder: "nothing recorded yet" would claim the addon looked.
  if breakdown.places ~= nil then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_BY_PLACE) })
    -- Before the rows: it qualifies the rate column before it is read.
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_PLACE_RATE_NOTE) })
    if breakdown.placedTotal < breakdown.observedTotal then
      rows[#rows + 1] = row({
        locale:get(TextKey.PANEL_PLACE_PARTIAL, breakdown.placedTotal, breakdown.observedTotal),
      })
    end
    for _, place in ipairs(breakdown.places) do
      local name = place.place.name or locale:get(TextKey.PANEL_UNKNOWN_PLACE)
      -- The kind and the time in the name cell: the rate divides by the time,
      -- and for a place that earned nothing the time is all the row has.
      name = name .. locale:get(TextKey.PANEL_PLACE_CONTEXT,
        locale:get(PLACE_LABEL[place.place.context] or place.place.context),
        durationText(locale, place.seconds))
      rows[#rows + 1] = row({
        name,
        tostring(place.amount),
        wholePercentText(locale, place.percent),
        ratePerHourText(locale, place.xpPerHour),
      }, {
        -- Uncoloured: red and green mean creatures and exploration here, and a
        -- place is not a source. The grey default reads as a proportion only.
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
      -- A row measured with a different number of people sharing the pay says
      -- so, and one recorded before group size was counted says that rather than
      -- passing for solo. The current group's row carries no mark, so marks stay
      -- meaningful when every row would read the same.
      if not creature.current then
        name = name .. (creature.sharedBy ~= nil
          and locale:get(TextKey.PANEL_CREATURE_SHARED, creature.sharedBy)
          or locale:get(TextKey.PANEL_CREATURE_MIXED))
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

  local rows = {
    labelRow(locale, TextKey.PANEL_LBL_HEALTH, avgWorst(combat.health)),
    labelRow(locale, TextKey.PANEL_LBL_RESOURCE, avgWorst(combat.power)),
    labelRow(locale, TextKey.PANEL_LBL_DEATHS, tostring(combat.deathCount)),
    labelRow(locale, TextKey.PANEL_LBL_TIME_LOST, durationText(locale, combat.time.timeLostToDeath)),
    labelRow(locale, TextKey.PANEL_LBL_TIME_COMBAT, durationText(locale, combat.time.combatSeconds)),
    labelRow(locale, TextKey.PANEL_LBL_TIME_RECOVER, durationText(locale, combat.time.recoverySeconds)),
    labelRow(locale, TextKey.PANEL_LBL_TIME_OUT, durationText(locale, combat.time.outOfCombatSeconds)),
  }
  -- One line in place of three figures on a level recorded without the combat
  -- log: not zeros, which would read as measured, and not the part counted
  -- before it stopped, which would read as the whole level.
  if combat.damage.unavailable ~= nil then
    rows[#rows + 1] = row({ locale:get(UnavailableText[RecordedSource.COMBAT_LOG][combat.damage.unavailable]) })
  else
    rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_DAMAGE_DEALT, tostring(combat.damage.dealt))
    rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_DAMAGE_TAKEN, tostring(combat.damage.taken))
    rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_HEALING, tostring(combat.damage.healingReceived))
  end
  rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_XP_PER_MINUTE,
    numberText(locale, combat.efficiency.xpPerCombatMinute))
  rows[#rows + 1] = labelRow(locale, TextKey.PANEL_LBL_XP_PER_KILL,
    numberText(locale, combat.efficiency.averageXpPerKill))
  return rows
end

-- A label for each of the two reserved synthetic keys, so a melee swing and a
-- ranged shot read differently. The keys are shared with the pull plate through
-- core/constants/Text.lua, so both surfaces name them the same way.
local AUTO_ATTACK_LABEL = {
  [ns.core.AbilityKey.MELEE_SWING] = TextKey.PANEL_AUTO_ATTACK,
  [ns.core.AbilityKey.RANGED_AUTO] = TextKey.PANEL_RANGED_ATTACK,
}

local function renderAbilities(view, abilities)
  local locale = view.locale
  if not abilities.active then
    return nil, locale:get(TextKey.PANEL_NO_LEVEL)
  end
  -- Before "no abilities yet": not recorded and none used are different answers,
  -- and on a level the combat log never reached only the first is true.
  if abilities.unavailable ~= nil then
    return nil, locale:get(UnavailableText[RecordedSource.COMBAT_LOG][abilities.unavailable])
  end
  if #abilities.entries == 0 then
    return nil, locale:get(TextKey.PANEL_NO_ABILITIES)
  end

  local rows = { labelRow(locale, TextKey.PANEL_LBL_TOTAL_USES, tostring(abilities.totalUses)) }
  for _, entry in ipairs(abilities.entries) do
    local name = entry.name
      or (entry.isAutoAttack and locale:get(AUTO_ATTACK_LABEL[entry.key] or TextKey.PANEL_AUTO_ATTACK))
      or locale:get(TextKey.PANEL_SPELL, tostring(entry.key))
    -- An icon the client cannot resolve is left out, not replaced with a
    -- question mark, which would read as something broken. Looked up through
    -- SpellIcon, like the plate: World of Warcraft: Forever has no bare
    -- GetSpellTexture global.
    local icon
    if not entry.isAutoAttack then
      icon = SpellIcon.texture(entry.key)
    end
    rows[#rows + 1] = row({ name, tostring(entry.count), percentText(locale, entry.fraction) }, {
      icon = icon,
      bar = { fraction = entry.fraction },
    })
  end
  return rows
end

-- Never folded into the breakdown's total: a projection from the quest log,
-- not experience obtained, as the bar keeps its pending channel apart.
local function renderPending(view, pending)
  local locale = view.locale
  -- The one tab that cannot follow the level selector, and it says so: pending
  -- experience is read from the quest log as it is now, not stored per level,
  -- so there is no past version to show.
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
  -- The mark goes beside each figure; the sentence explaining it is printed
  -- once at the end if any row used it.
  local rough, mixed = false, false
  for _, entry in ipairs(pending.entries) do
    -- "Not recorded" and "zero" must not look alike: a quest whose reward has
    -- never been seen is unknown, not worthless.
    local amount = entry.isKnown and tostring(entry.adjustedReward) or locale:get(TextKey.NOT_AVAILABLE)
    local label = questLabel(view, entry.questId)
    if entry.complete then
      label = label .. locale:get(TextKey.PANEL_READY_MARK)
    end
    rows[#rows + 1] = row({ label, amount, locale:get(ORIGIN_LABEL[entry.origin] or entry.origin) })

    -- What this quest still asks the player to kill, and what those kills are
    -- worth. Under the quest, never added to it: the reward is paid on turn-in,
    -- the kills are paid on killing and will be recorded as creatures.
    for _, objective in ipairs(entry.objectives or {}) do
      local estimate
      if objective.estimate == nil then
        estimate = locale:get(TextKey.PANEL_OBJ_NO_RATE)
      elseif objective.basis == KillXpEstimator.Basis.LEVEL then
        rough = true
        estimate = locale:get(TextKey.PANEL_OBJ_ROUGH, objective.estimate)
      elseif objective.basis == KillXpEstimator.Basis.MIXED then
        -- Its own mark, not the rough one: the figure comes from this creature,
        -- but from kills recorded without their group size, so it is neither a
        -- measurement for the current group nor the level's blanket average.
        mixed = true
        estimate = locale:get(TextKey.PANEL_OBJ_MIXED, objective.estimate)
      else
        estimate = locale:get(TextKey.PANEL_OBJ_ESTIMATE, objective.estimate)
      end
      rows[#rows + 1] = row({
        locale:get(TextKey.PANEL_OBJECTIVE, objective.creature, objective.done, objective.needed),
        estimate,
      })
    end
  end

  -- The narrower mark first: from a real average of the wrong population down
  -- to no average of this creature at all.
  if mixed then
    rows[#rows + 1] = row({ locale:get(TextKey.PANEL_OBJ_MIXED_FOOTNOTE) })
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

  -- The previous recorded level: the entry below this one in a list sorted
  -- descending, not `selected - 1`. They differ when the history has a hole
  -- (the addon installed mid-levelling, a level played with it disabled, a level
  -- dropped by retention), where `selected - 1` would find nothing.
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

-- Pulled back inside the visible screen, with the bar's rule and margin
-- (ui/XpBarView.lua): the position is re-applied on every login, so a panel
-- saved on a detached monitor would stay unreachable, and no chat command
-- resets the panel's position.
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
  -- Clamped on the way in as well as out: a size below the minimum may
  -- already be on disk.
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

-- The panel wears the bar's skin, so the source colours match between a row
-- and its segment on the bar.
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
  -- An alpha floor the bar does not need: a skin meant for a thin strip can be
  -- nearly transparent, which leaves a page of numbers unreadable over the world.
  local alpha = math.max(background.a or 0, 0.82)
  self.background:SetColorTexture(background.r, background.g, background.b, alpha)

  self:applyBorder(self.appearance.border)
  self:applyChromeFont(self.appearance.text)

  for _, list in pairs(self.lists) do
    list:applyAppearance(self.appearance)
  end

  return self
end

-- The bar's border rules (BarRenderer's applyBorder) applied to the panel:
-- kind, thickness and colour, so NONE and a thick frame match the bar. The edges
-- keep two-corner anchoring rather than an explicit length, because this frame
-- is resizable and the length must follow.
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
    -- 1 and 2 are the horizontal edges, 3 and 4 the vertical ones (createFrame).
    if index <= 2 then
      edge:SetHeight(border.thickness)
    else
      edge:SetWidth(border.thickness)
    end
    -- Top and left lit, bottom and right dimmed, with the bar's indices.
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

-- The panel's own title, tab buttons and empty-state message wear the skin too.
-- Every path comes from GetFont, never a literal: a Latin font draws no glyphs
-- on a Korean client.
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

-- Which level the panel is reading.
--
-- `selectedLevel` nil means follow the level in progress, not "nothing
-- selected". Storing the current level's number when its row is clicked would
-- silently pin the panel to it, and after the next level-up it would show a
-- finished level with nothing saying so.
function ReportPanelView:select(level)
  -- nil and the level in progress both mean follow the live level. The
  -- composition root passes nil after erasing the character's history.
  if level == nil or level == self.currentLevel() then
    self.selectedLevel = nil
  else
    self.selectedLevel = level
  end
  self.selectedRecord, self.selectedRecordLevel = nil, nil
  -- Marked dirty, not just redrawn: the gate returns nil for an unchanged
  -- panel, and every other tab would keep its previous level.
  self:markDirty()
  self:refresh()
end

-- Whether the panel is showing a level other than the one in progress.
function ReportPanelView:isPinned()
  return self.selectedLevel ~= nil and self.selectedLevel ~= self.currentLevel()
end

-- The record every tab is built from: the selected level when there is one, and
-- the level in progress otherwise.
--
-- Memoised per selection: `recordFor` rebuilds a whole LevelRecord from saved
-- data on every call (RecordStore's `completed`), and this runs on every
-- rebuild, i.e. every experience gain while the panel is open. A completed
-- level never changes; the level in progress is the live object and is never
-- memoised.
--
-- A selection that stops resolving (dropped by retention, history erased)
-- clears itself: LevelHistoryViewModel already falls the list back to the most
-- recent entry, and the rest of the panel must not stay half pinned.
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
    -- A locked highlight, not a disabled button: greyed out means "cannot use"
    -- in the client's vocabulary, the opposite of the current tab.
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
  -- has something to show even with no level in progress.
  --
  -- The two empty states are told apart by whether anything was ever recorded,
  -- not by `lastViewModel == nil`, which is only true between construction and
  -- the first refresh, while the frame is still hidden.
  if (self.lastViewModel == nil or not self.lastViewModel.active) and self.activeTab ~= "history" then
    list:clear()
    -- Only one of the three ways to have no level is a new install. A character
    -- at the cap, such as a fresh install on a level-60 Classic Era character,
    -- will never gain experience, so it must not be told recording starts at
    -- the next point.
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
  -- SetMinResize does not exist on the supported clients; SetResizeBounds does.
  -- The older name stays as a fallback. Without a minimum the panel could be
  -- dragged down to nothing and that size persisted.
  if frame.SetResizeBounds then
    frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
  elseif frame.SetMinResize then
    frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
  end

  self.frame = frame

  self.background = frame:CreateTexture(nil, "BACKGROUND")
  self.background:SetAllPoints(frame)

  -- Four thin textures, the bar's border: a backdrop would need the frame built
  -- from a template and scales its edge art.
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

  -- A way into the settings from the panel. It opens by the same path as
  -- `/ascent options panel`, degrading the same way on a client with neither
  -- options API, rather than a second way in that could drift.
  --
  -- Optional, so the view can be built without the seam.
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

  -- One list per tab rather than one reconfigured on every switch: the columns
  -- differ per tab, and a changed row layout would rebuild every row anyway.
  self.lists = {}
  for _, tab in ipairs(TABS) do
    local list = RowList.new({
      parent = frame,
      -- Named uniquely: RowList.new requires a name (see its header).
      name = "AscentPanelList" .. tab.id,
      columns = COLUMNS[tab.id],
      icons = tab.icons,
      onSelect = tab.id == "history" and function(level) self:select(level) end or nil,
    })
    -- Anchored to the frame, not the last tab button, whose position moves when
    -- a tab is added, renamed or translated into a longer word.
    list:setPoints("TOPLEFT", frame, "TOPLEFT", 12, -66)
    list:hide()
    self.lists[tab.id] = list
  end

  -- The empty state is a message, not an empty list: a blank panel reads as a
  -- bug, and every empty state here is normal.
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
-- currentRecord() (returns the LevelRecord to build the panel from),
-- questForecastService (core's own service, read directly), `questNames` (what
-- a quest is called; without it quest rows show their number), `locale` (every
-- player-visible string goes through it), and the three history seams:
-- completedLevels(), recordFor(level) and currentLevel(). The history seams are
-- optional; without them that tab shows its empty state.
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
    -- How many are sharing the pay right now, asked on every rebuild like the
    -- record. Optional: without it every row reads as not the current group.
    sharedBy = options.sharedBy or function() return nil end,
    questForecastService = options.questForecastService,
    questNames = options.questNames,
    locale = options.locale,
    completedLevels = options.completedLevels or function() return {} end,
    recordFor = options.recordFor or function() return nil end,
    currentLevel = options.currentLevel or function() return nil end,
    -- Whether the character can still gain a level at all. "No level in
    -- progress" looks the same at the cap, with experience switched off and on
    -- a new install, and the three want different sentences.
    atCap = options.atCap or function() return false end,
    -- Optional: where the options never registered there is no button.
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
-- frame, like the bar's applySettings.
function ReportPanelView:applySettings(settings)
  self.settings = settings or self.settings
  self:applyAppearance()
  self:applySavedPosition()
  self:layoutLists()
  -- Not while closed: Bootstrap calls this from `saveSetting`, which the
  -- options panel calls on every slider release. `open` draws what a closed
  -- panel missed.
  if self:isOpen() then
    self:renderActiveTab()
  end
  return self
end

-- The title carries the level: the selector reaches every tab, and the number
-- is what tells the level in progress from a finished one.
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
  -- `refresh` draws when the gate had something new. Otherwise the tab is drawn
  -- here, since it may predate a settings change made while closed. Asking
  -- refresh whether it drew avoids rendering every row twice.
  if not self:refresh() then
    self:renderActiveTab()
  end
end

function ReportPanelView:close()
  self.frame:Hide()
  -- The selection is a reading position, not a setting: the panel always opens
  -- on the level in progress.
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

-- Marks the panel's view-model stale. Bootstrap calls this on the topics that
-- mark the bar's RedrawScheduler dirty (RECORD_UPDATED and others); the view
-- does not act on it until it is shown.
function ReportPanelView:markDirty()
  self.gate:markDirty()
end

-- Called from Bootstrap's ticker, like the bar's redraw(). The gate decides
-- whether there is anything to do: closed, or open but unchanged, returns
-- without touching the record. Returns whether it rebuilt and redrew, for
-- `open`.
function ReportPanelView:refresh()
  local record
  local viewModel = self.gate:refresh(self:isOpen(), function()
    record = self:viewedRecord()
    return ReportPanelViewModel.build(record, {
      questReport = self.questForecastService:report(),
      questEntries = self.questForecastService:entries(),
      -- The level in progress, whatever level is shown: the pending tab and the
      -- kill rates its estimates use are about now.
      currentRecord = self.currentRecord(),
      -- And the current group size: what a creature pays depends on how many
      -- share it, so estimates must not use another group's average.
      sharedBy = self.sharedBy(),
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
