-- Ascent - the level selector and the comparison against the level before
-- (tasks 6.7, 6.8; the capability has asked for both since the first spec).
--
-- Two questions, both pure functions of what the store already holds:
--
--   build    which levels can be looked at, which one is being looked at, and
--            whether there is anything there at all.
--   compare  how this level went against the one before it -- how long it took
--            and what it was made of.
--
-- THE DIRECTION IS A FIELD, NOT A COLOUR. Every difference carries `direction`
-- ("up", "down" or "same") alongside its number, so the panel can show an arrow
-- or a sign and not depend on red-versus-green. That is not a general
-- accessibility gesture -- it is forced by this addon in particular: green and
-- red already MEAN exploration and creatures here, and using them again for
-- better and worse would collide with the one thing the panel exists to teach.
--
-- And no value judgement travels with them. A level that took longer is not
-- worse -- it may have been the level someone did every quest in -- so the
-- domain reports the direction and leaves the meaning to the reader.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource
local Composition = ns.core.Composition

local LevelHistoryViewModel = {}

local SOURCES_IN_ORDER = {
  XpSource.MOB_KILL, XpSource.QUEST_TURNIN, XpSource.EXPLORATION, XpSource.UNKNOWN,
}

local function directionOf(delta)
  if delta > 0 then return "up" end
  if delta < 0 then return "down" end
  return "same"
end

-- `options`:
--   levels    the completed levels available, in any order
--   current   the level in progress, or nil
--   selected  the level the player picked, or nil for "the one in progress"
--
-- Returns the entries in DESCENDING order -- most recent first, which is the one
-- a player reaches for -- each marked with whether it is the current selection,
-- plus `empty` for the state where there is no history yet at all.
function LevelHistoryViewModel.build(options)
  options = options or {}

  local entries = {}
  for _, level in ipairs(options.levels or {}) do
    entries[#entries + 1] = { level = level, current = false }
  end
  if options.current ~= nil then
    entries[#entries + 1] = { level = options.current, current = true }
  end

  table.sort(entries, function(a, b) return a.level > b.level end)

  -- A selection pointing at a level that is not there -- data cleared, a level
  -- trimmed by retention -- falls back to the most recent rather than leaving
  -- the panel showing nothing with no way back.
  local selected = options.selected
  local found = false
  for _, entry in ipairs(entries) do
    if entry.level == selected then
      found = true
    end
  end
  if not found then
    selected = entries[1] ~= nil and entries[1].level or nil
  end

  for _, entry in ipairs(entries) do
    entry.selected = entry.level == selected
  end

  return {
    entries = entries,
    selected = selected,
    empty = #entries == 0,
  }
end

-- `record` and `previous` are LevelRecords; `previous` may be nil, which is the
-- normal case for the first level anyone records.
function LevelHistoryViewModel.compare(record, previous)
  if record == nil or previous == nil then
    return { available = false }
  end

  local function compositionOf(subject)
    local entries = {}
    for index, source in ipairs(SOURCES_IN_ORDER) do
      entries[index] = { key = source, amount = subject:xpFrom(source) }
    end
    local percentages = Composition.percentages(entries)
    local bySource = {}
    for _, entry in ipairs(percentages) do
      bySource[entry.key] = entry.percent
    end
    return bySource
  end

  local here, there = compositionOf(record), compositionOf(previous)

  local sources = {}
  for _, source in ipairs(SOURCES_IN_ORDER) do
    -- Every source, including the ones sitting at zero on both sides: a
    -- comparison that silently drops a row makes two levels look more alike
    -- than they are.
    local delta = here[source] - there[source]
    sources[#sources + 1] = {
      source = source,
      percent = here[source],
      previousPercent = there[source],
      delta = delta,
      direction = directionOf(delta),
    }
  end

  local durationDelta = (record.playedSeconds or 0) - (previous.playedSeconds or 0)

  return {
    available = true,
    level = record.level,
    previousLevel = previous.level,
    duration = {
      seconds = record.playedSeconds or 0,
      previousSeconds = previous.playedSeconds or 0,
      delta = durationDelta,
      direction = directionOf(durationDelta),
    },
    sources = sources,
  }
end

ns.core.LevelHistoryViewModel = LevelHistoryViewModel
