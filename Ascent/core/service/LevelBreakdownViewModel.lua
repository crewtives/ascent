-- Ascent - the level report panel's "experience breakdown" tab view-model.
--
-- Same shape of problem as XpBarViewModel (task 10.1), read from a completed or
-- in-progress LevelRecord instead of the live one: per-source amounts that must
-- sum to the level's own completed percentage, and the rested bonus reported
-- alongside them without ever padding that sum -- a kill's amount already
-- includes whatever rested bonus rode on it (LevelRecord's own xpByModifier
-- comment: "they describe a portion of the amount already granted; they are
-- never added on top of it"), so restedBonus here is informational only.
--
-- The two rankings (topQuests, topCreatures) answer different questions on
-- purpose: quests rank by xp contributed, creatures rank by how often they were
-- killed ("las criaturas mas repetidas"), not by the xp they paid.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource
local XpModifier = ns.core.XpModifier
local Composition = ns.core.Composition

local LevelBreakdownViewModel = {}

-- Composition.percentages speaks in { key, amount }; a source entry carries more
-- than that, so this is the adapter between the two rather than a reason to make
-- the general-purpose module know about sources.
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

-- One entry per source that paid something, same "zero produces no entry" rule
-- as the bar: a zero-amount row is not information for the player to read.
--
-- TWO figures per source, and they answer different questions (design D36):
--
--   fraction  of the LEVEL. Sums to the level's completed percentage, which in a
--             level still in progress is less than one. Unchanged, and it must
--             stay that way -- forcing it to a hundred would hand out experience
--             the player has not earned.
--   percent   of what was OBSERVED. Whole numbers that sum to exactly a hundred,
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

-- Experience per hour of a place, over the time spent in THAT place -- not over
-- the level's played time, which would answer a different question for every row.
--
-- Zero and unavailable are different answers here and the distinction is the
-- spec's, not a nicety: a place where the player spent twenty minutes and earned
-- nothing has a rate of exactly zero and that is the whole point of recording it.
-- A place with experience and no measured time has no rate at all -- it is
-- reachable, because the ledger creates the entry on the gain and the sampler may
-- never have ticked there -- and answering zero would read as "this place pays
-- nothing", which is the opposite of what happened.
local function ratePerHour(amount, seconds)
  if seconds <= 0 then
    return nil
  end
  return amount / (seconds / 3600)
end

-- One row per place the level touched, INCLUDING the ones that paid nothing.
-- That is the opposite of the rule buildSources follows, and deliberately: a zone
-- crossed for twenty minutes with nothing to show for it is not an empty row, it
-- is the reason the rates of the other rows are believable. The only entries left
-- out are the ones with neither experience nor time, which exist transiently in
-- memory (the entry is created before either writer fills it) and are dropped on
-- the way to disk, so keeping them would make a level look different before and
-- after a reload.
--
-- Answers nil, never an empty list, when the level has no places at all: a level
-- recorded before this existed did not fail to observe where its experience came
-- from, it never looked, and the panel has to be able to tell those apart.
local function buildPlaces(record, xpRequired)
  if not record:hasPlaces() then
    return nil
  end

  local places = {}
  for _, entry in pairs(record.places) do
    -- A place that paid nothing is still an answer -- twenty minutes in Westfall
    -- for nothing is exactly the kind of thing this tab exists to show. The
    -- RESERVED entry is not a place, though: it is where the ledger parks
    -- experience nobody could locate, and with no experience in it what it says
    -- is "we cannot tell where you were for one second, and you earned nothing
    -- there". That is not a finding, it is the instant between crossing a portal
    -- and the client naming the other side, and a real report came back with a
    -- row of zeroes saying it.
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

  -- Sorted BEFORE the composition is computed, because the leftover point of the
  -- largest-remainder method goes to the caller's display order. Ends on the
  -- place's own id, which is unique, so the comparator is a total order -- Lua's
  -- table.sort is unstable and `pairs` over the places is hash order, which is
  -- what the spec's "same order on two consecutive reads" is really about.
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

-- The other two annotations, and they follow exactly the same rule as the rested
-- bonus: the group figure is a portion ALREADY inside the experience that was
-- credited, and the raid figure is what was taken off before crediting it.
-- Neither is added to nor subtracted from the level's total -- reporting them is
-- the whole job (design D41).
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

-- Descending by kill count ("mas repetidas"), not by xp -- a common low-level
-- creature killed often can outrank a rare high-xp one here even though it
-- would not in buildTopQuests. Ties broken by xp, then by the creature's own
-- id for determinism. Creatures with zero kills (should not occur, but nothing
-- guarantees it) are excluded the same way a zero-amount source is.
local function buildTopCreatures(creatures)
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
    return a.key:id() < b.key:id()
  end)
  local result = {}
  for _, creature in ipairs(top) do
    result[#result + 1] = { creatureKey = creature.key, kills = creature.kills, xpTotal = creature.xpTotal }
  end
  return result
end

-- Same inactive convention as XpBarViewModel.build: a record that does not
-- exist yet and one that exists but has not learned its requirement yet both
-- collapse to the same "nothing to show" shape.
function LevelBreakdownViewModel.build(record)
  if record == nil or record.xpRequired == nil or record.xpRequired <= 0 then
    return { active = false }
  end

  local xpRequired = record.xpRequired

  return {
    active = true,
    percentComplete = record.xpTotal / xpRequired,
    -- What the composition percentages are a composition OF. Carried so the
    -- panel can say so out loud: "of the 14,200 experience recorded for this
    -- level" is what makes a column summing to a hundred honest in a level that
    -- is only half done.
    observedTotal = record.xpTotal,
    sources = buildSources(record, xpRequired),
    -- The second dimension, and its own denominator. The two are normally the
    -- same number, and when they are not the difference is real: a level that was
    -- already under way when places started being recorded has experience that
    -- belongs to no place, so the places column is a composition of a SMALLER
    -- total than the sources column. Both would print "100%" side by side with
    -- nothing to say why, so the denominator travels with the block and the panel
    -- says so out loud.
    places = buildPlaces(record, xpRequired),
    placedTotal = record:sumOfPlaces(),
    restedBonus = buildRestedBonus(record, xpRequired),
    modifiers = buildModifiers(record, xpRequired),
    topQuests = buildTopQuests(record.quests),
    topCreatures = buildTopCreatures(record.creatures),
    partial = record.partial,
  }
end

ns.core.LevelBreakdownViewModel = LevelBreakdownViewModel
