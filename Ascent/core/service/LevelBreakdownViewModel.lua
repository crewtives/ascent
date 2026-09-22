-- Ascent - the level report panel's "experience breakdown" tab view-model.
--
-- The same problem as XpBarViewModel, read from a completed or in-progress
-- LevelRecord instead of the live one: per-source amounts that must sum to the
-- level's own completed percentage, and the rested bonus reported alongside them
-- without ever padding that sum. A kill's amount already includes whatever rested
-- bonus rode on it (see LevelRecord's xpByModifier), so restedBonus here is
-- informational only.
--
-- The two rankings answer different questions: quests rank by experience
-- contributed, creatures by how often they were killed.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource
local XpModifier = ns.core.XpModifier
local Composition = ns.core.Composition

local LevelBreakdownViewModel = {}

-- Composition.percentages speaks in { key, amount }; a source entry carries more
-- than that, and this adapter keeps that general-purpose module unaware of
-- sources.
local function sources_as_entries(sources)
  local entries = {}
  for index, entry in ipairs(sources) do
    entries[index] = { key = entry.source, amount = entry.amount }
  end
  return entries
end

-- Mirrors XpBarViewModel's SOURCES_IN_DRAW_ORDER: the source's own declared
-- order (Xp.lua), not Frozen.each's alphabetical order, so the breakdown reads
-- the same way the bar itself does.
local SOURCES_IN_ORDER = {
  XpSource.MOB_KILL, XpSource.QUEST_TURNIN, XpSource.EXPLORATION, XpSource.UNKNOWN,
}

-- One entry per source that paid something, the same "zero produces no entry"
-- rule as the bar. Two figures per source, answering different questions:
--
--   fraction  of the level. Sums to the level's completed percentage, which in a
--             level still in progress is less than one; forcing it to a hundred
--             would hand out experience the player has not earned.
--   percent   of what was observed. Whole numbers that sum to exactly a hundred,
--             because "what was this level made of" is a composition.
local function buildSources(record, xpRequired)
  local sources = {}
  for _, source in ipairs(SOURCES_IN_ORDER) do
    local amount = record:xpFrom(source)
    if amount > 0 then
      sources[#sources + 1] = { source = source, amount = amount, fraction = amount / xpRequired }
    end
  end

  local shares = Composition.percentages(sources_as_entries(sources))
  for index, share in ipairs(shares) do
    sources[index].percent = share.percent
  end

  return sources
end

local function places_as_entries(places)
  local entries = {}
  for index, entry in ipairs(places) do
    entries[index] = { key = entry.place:id(), amount = entry.amount }
  end
  return entries
end

-- Experience per hour of a place, over the time spent in that place, not over the
-- level's played time.
--
-- Zero and unavailable are different answers: a place where the player spent
-- twenty minutes and earned nothing has a rate of exactly zero. A place with
-- experience and no measured time has no rate at all (the ledger creates the
-- entry on the gain, and the sampler may never have ticked there), and answering
-- zero would read as "this place pays nothing".
local function ratePerHour(amount, seconds)
  if seconds <= 0 then
    return nil
  end
  return amount / (seconds / 3600)
end

-- One row per place the level touched, including the ones that paid nothing,
-- unlike buildSources: a zone crossed for twenty minutes for nothing is what
-- makes the rates of the other rows believable. The only entries left out are
-- the ones with neither experience nor time, which exist transiently in memory
-- (the entry is created before either writer fills it) and are dropped on the
-- way to disk, so keeping them would make a level look different before and
-- after a reload.
--
-- Answers nil, never an empty list, when the level has no places at all: a level
-- recorded without place tracking never looked, and the panel has to tell that
-- apart from a level that looked and found nothing.
local function buildPlaces(record, xpRequired)
  if not record:hasPlaces() then
    return nil
  end

  local places = {}
  for _, entry in pairs(record.places) do
    -- A place that paid nothing is still an answer. The reserved entry is not a
    -- place: it is where the ledger parks experience nobody could locate, and
    -- with no experience in it, its time is only the instant between crossing a
    -- portal and the client naming the other side: a row of zeroes.
    local worthShowing = entry.xpTotal > 0 or (entry.seconds > 0 and entry.key:isKnown())
    if worthShowing then
      places[#places + 1] = {
        place = entry.key,
        amount = entry.xpTotal,
        seconds = entry.seconds,
        fraction = entry.xpTotal / xpRequired,
        xpPerHour = ratePerHour(entry.xpTotal, entry.seconds),
      }
    end
  end

  if #places == 0 then
    return nil
  end

  -- Sorted before the composition is computed, because the leftover points of the
  -- largest-remainder method follow the caller's display order. Ends on the
  -- place's own id, which is unique, so the comparator is a total order: Lua's
  -- table.sort is unstable and `pairs` over the places is hash order, and two
  -- consecutive reads must give the same order.
  table.sort(places, function(a, b)
    if a.amount ~= b.amount then
      return a.amount > b.amount
    end
    if a.seconds ~= b.seconds then
      return a.seconds > b.seconds
    end
    return a.place:id() < b.place:id()
  end)

  local shares = Composition.percentages(places_as_entries(places))
  for index, share in ipairs(shares) do
    places[index].percent = share.percent
  end

  return places
end

-- Informational only: this amount is already inside whichever source carried it,
-- so it is never folded into the sum the source fractions are checked against.
local function buildRestedBonus(record, xpRequired)
  local amount = record:xpFromModifier(XpModifier.RESTED_BONUS)
  return { amount = amount, fraction = amount / xpRequired }
end

-- The other two annotations follow the rested bonus's rule: the group figure is a
-- portion already inside the experience that was credited, and the raid figure is
-- what was taken off before crediting it. Neither is added to nor subtracted from
-- the level's total.
--
-- Reported even at zero, unlike a source, because "you gained nothing extra from
-- grouping this level" is an answer and an absent row is not.
local function buildModifiers(record, xpRequired)
  local group = record:xpFromModifier(XpModifier.GROUP_BONUS)
  local raid = record:xpFromModifier(XpModifier.RAID_PENALTY)
  return {
    groupBonus = { amount = group, fraction = group / xpRequired },
    raidPenalty = { amount = raid, fraction = raid / xpRequired },
  }
end

-- Descending by xp, ties broken by questId for a deterministic order. Quests
-- with no xp (declined, or a reward never observed) are excluded: they made no
-- contribution to rank.
local function buildTopQuests(quests)
  local top = {}
  for _, quest in pairs(quests) do
    if quest.xpTotal > 0 then
      top[#top + 1] = quest
    end
  end
  table.sort(top, function(a, b)
    if a.xpTotal ~= b.xpTotal then
      return a.xpTotal > b.xpTotal
    end
    return a.questId < b.questId
  end)
  return top
end

-- Descending by kill count, not by xp: a common low-level creature killed often
-- can outrank a rare high-xp one. Ties broken by xp, then by the creature's own
-- id for determinism. Creatures with zero kills (should not occur, but nothing
-- guarantees it) are excluded the same way a zero-amount source is.
--
-- One row per population, not per creature. The same creature killed alone and
-- killed beside four other people paid two different amounts, and adding the two
-- back together here would print a mixed average that describes neither. Each
-- row says which group size it was measured in, and a `sharedBy` of nil means no
-- group size was recorded, which is not the same claim as playing alone.
--
-- `current` marks the row whose population prices what the character is doing
-- now, so a surface can mark the others rather than let a number measured in
-- another context pass for a measurement of this one.
local function buildTopCreatures(creatures, sharedBy)
  local top = {}
  for _, creature in pairs(creatures) do
    if creature.kills > 0 then
      top[#top + 1] = creature
    end
  end
  table.sort(top, function(a, b)
    if a.kills ~= b.kills then
      return a.kills > b.kills
    end
    if a.xpTotal ~= b.xpTotal then
      return a.xpTotal > b.xpTotal
    end
    if a.key:id() ~= b.key:id() then
      return a.key:id() < b.key:id()
    end
    -- Two populations of one creature share an id, so the group size is the last
    -- tie-break: without it two rows with the same kills and the same experience
    -- would swap places between redraws of a level that never changed.
    return (a.sharedBy or 0) < (b.sharedBy or 0)
  end)
  local result = {}
  for _, creature in ipairs(top) do
    result[#result + 1] = {
      creatureKey = creature.key,
      kills = creature.kills,
      xpTotal = creature.xpTotal,
      sharedBy = creature.sharedBy,
      current = creature.sharedBy ~= nil and creature.sharedBy == sharedBy,
    }
  end
  return result
end

-- Same inactive convention as XpBarViewModel.build: a record that does not
-- exist yet and one that exists but has not learned its requirement yet both
-- collapse to the same "nothing to show" shape.
--
-- `sharedBy` is how many characters are sharing the pay right now. The record can
-- be any level, finished or in progress, but the group is always the current one:
-- it is the question asked of what the level measured, not part of it.
function LevelBreakdownViewModel.build(record, sharedBy)
  if record == nil or record.xpRequired == nil or record.xpRequired <= 0 then
    return { active = false }
  end

  local xpRequired = record.xpRequired

  return {
    active = true,
    percentComplete = record.xpTotal / xpRequired,
    -- What the composition percentages are a composition of, carried so the
    -- panel can say "of the 14,200 experience recorded for this level" and a
    -- column summing to a hundred reads right in a level that is half done.
    observedTotal = record.xpTotal,
    sources = buildSources(record, xpRequired),
    -- The second dimension, with its own denominator. Normally the same number as
    -- observedTotal; a level already under way when place recording began has
    -- experience that belongs to no place, so the places column is a composition
    -- of a smaller total than the sources column. The denominator travels with
    -- the block so the panel can say why both columns read 100%.
    places = buildPlaces(record, xpRequired),
    placedTotal = record:sumOfPlaces(),
    restedBonus = buildRestedBonus(record, xpRequired),
    modifiers = buildModifiers(record, xpRequired),
    topQuests = buildTopQuests(record.quests),
    topCreatures = buildTopCreatures(record.creatures, sharedBy),
    partial = record.partial,
    -- Why creatures cannot be told apart from Unclassified on this level, or nil.
    -- The sources above stand as they are: quests and discoveries arrive by ways
    -- of their own, and what the kill line would have named is already in
    -- Unclassified, which keeps the sources summing to the level's total.
    sourcesUnavailable = record:unavailableReason(ns.core.RecordedSource.XP_CHAT),
  }
end

ns.core.LevelBreakdownViewModel = LevelBreakdownViewModel
