-- Ascent - the experience bar's view-model.
--
-- The bar is drawn from three things that all look like "a fraction of the
-- level" but mean different things:
--
--   segments   experience already earned, by source. Their widths sum to exactly
--              the level's completed percentage. Experience the client confirmed
--              but XpAttribution has not settled yet is folded into the UNKNOWN
--              segment as provisional, so the bar moves at once instead of
--              showing a stale total.
--   rested     the rested reserve, drawn past the segments. Not earned
--              experience; capped so the bar never passes 100%.
--   pending    experience quests in the log would pay if turned in. A
--              projection: it never becomes a segment or moves the completed
--              percentage, and saturates at the end of the bar.
--
-- A pure function of a LevelRecord plus the numbers the record does not carry
-- (the rested reserve, the pending quest total), so every rule is testable
-- without a client.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource

local XpBarViewModel = {}

-- The order the bar draws segments in, left to right: the order declared in
-- Xp.lua. `Frozen.each` sorts alphabetically by key and would draw EXPLORATION
-- before MOB_KILL. Written through the enum so a typo fails at load time.
local SOURCES_IN_DRAW_ORDER = {
  XpSource.MOB_KILL, XpSource.QUEST_TURNIN, XpSource.EXPLORATION, XpSource.UNKNOWN,
}

-- One entry per source that paid something, in draw order; a source at zero
-- produces no entry. `unattributedXp` (already capped by the caller) is added to
-- UNKNOWN, so a kill shows within one redraw instead of after the settling window.
local function buildSegments(record, xpRequired, unattributedXp)
  local segments = {}
  for _, source in ipairs(SOURCES_IN_DRAW_ORDER) do
    local amount = record:xpFrom(source)
    if source == XpSource.UNKNOWN then
      amount = amount + unattributedXp
    end
    if amount > 0 then
      -- `amount` rides along so the tooltip reads the figure behind the width;
      -- re-deriving it from the record would miss unattributedXp.
      segments[#segments + 1] = { source = source, amount = amount, fraction = amount / xpRequired }
    end
  end
  return segments
end

-- The reserve is capped to the room left past the completed percentage: the bar
-- has nowhere to draw rested experience beyond its end.
local function buildRested(restedXp, xpRequired, percentComplete)
  if restedXp == nil or restedXp <= 0 then
    return nil
  end

  local room = 1 - percentComplete
  if room <= 0 then
    return nil
  end

  local fraction = math.min(restedXp / xpRequired, room)
  if fraction <= 0 then
    return nil
  end
  return { fraction = fraction }
end

-- Pending experience saturates at the end of the bar instead of spilling past
-- it, measured against what is left in the level.
local function buildPending(questPending, showQuestPending, xpTotal, xpRequired)
  if questPending == nil or questPending <= 0 or showQuestPending == false then
    return nil
  end

  local remaining = xpRequired - xpTotal
  local saturated = questPending > remaining
  return {
    fraction = math.min(questPending, remaining) / xpRequired,
    saturated = saturated,
  }
end

-- What the record says about its own completeness, a fact about the recording,
-- not the experience. nil when the level was watched from its first point, so a
-- surface renders nothing and reserves no room.
--
-- Three states. A level watched throughout says nothing. A level opened part-way
-- says how much it inherited, and the rest of UNKNOWN is experience watched but
-- not attributed. A record without the inherited figure (`seededXp` nil) can only
-- say it is partial; splitting UNKNOWN for it would invent the split.
local function buildObservation(record, unattributedXp)
  if not record.partial then
    return nil
  end

  local seeded = record.seededXp
  if seeded == nil then
    return { partial = true }
  end

  -- The UNKNOWN segment on screen is the bucket plus `unattributedXp` (see
  -- buildSegments), so the split must include it to add up to that segment.
  -- Experience in the settling window was observed, so it counts as watched and
  -- unattributed.
  local unknown = record:xpFrom(XpSource.UNKNOWN) + unattributedXp
  return {
    partial = true,
    seededXp = seeded,
    -- Floored at zero. The seed can outgrow the bucket in a self-contradicting
    -- file: restore() runs reconcile(), which drops UNKNOWN to zero when the
    -- breakdown claims more than the total, while seededXp keeps its figure.
    -- Retention is not a cause: it trims `gains`, never the per-source totals.
    unexplainedXp = math.max(0, unknown - seeded),
  }
end

-- `record` may be nil, or may not yet know its requirement (the client has not
-- reported it). Both give the same inactive shape.
function XpBarViewModel.build(record, params)
  if record == nil or record.xpRequired == nil or record.xpRequired <= 0 then
    return { active = false }
  end
  params = params or {}

  local xpRequired = record.xpRequired

  -- Capped to the room left in the level, like buildPending: a delta that crosses
  -- a level boundary belongs partly to the next level, a split only settling knows.
  local unattributedXp = math.max(0, math.min(params.unattributedXp or 0, xpRequired - record.xpTotal))
  local xpTotal = record.xpTotal + unattributedXp
  local percentComplete = xpTotal / xpRequired

  return {
    active = true,
    percentComplete = percentComplete,
    xpTotal = xpTotal,
    segments = buildSegments(record, xpRequired, unattributedXp),
    rested = buildRested(params.restedXp, xpRequired, percentComplete),
    pending = buildPending(params.questPending, params.showQuestPending, xpTotal, xpRequired),
    observation = buildObservation(record, unattributedXp),
    -- Set when the client had no experience chat line to name sources, so that
    -- experience is in the Unclassified segment. The segments still show it.
    sourcesUnavailable = record:unavailableReason(ns.core.RecordedSource.XP_CHAT),
  }
end

-- The per-channel shares the bar animates, in BarChannel's vocabulary: a source
-- id per segment, plus "rested" and "pending". Here rather than in a view because
-- both the bar and the options preview use it, so the preview matches the bar.
--
-- An absent channel holds nothing; the tween draws it at its neighbour's edge
-- with zero width.
function XpBarViewModel.shares(viewModel)
  local shares = {}
  if viewModel == nil or not viewModel.active then
    return shares
  end
  for _, segment in ipairs(viewModel.segments) do
    shares[segment.source] = segment.fraction
  end
  if viewModel.rested ~= nil then
    shares.rested = viewModel.rested.fraction
  end
  if viewModel.pending ~= nil then
    shares.pending = viewModel.pending.fraction
  end
  return shares
end

-- Where one source's experience was earned, for the bar's hover popup.
--
-- Called on hover rather than computed in build(), which runs on the redraw tick
-- up to five times a second; the sort's comparator formats two strings per
-- comparison.
--
-- nil when the level cannot answer: no places, or places recorded without which
-- source paid. The popup then shows no line and reserves no room.
--
-- Two shortfalls are not padded: unsettled experience rides in UNKNOWN but is in
-- no place yet, and a level already under way when place recording began has
-- experience in no place. In both, the places sum to less than the segment.
function XpBarViewModel.placesFor(record, source)
  if record == nil or not record:hasPlaceSources() then
    return nil
  end

  local places = {}
  for _, entry in pairs(record.places) do
    local amount = entry.xpBySource[source]
    if amount ~= nil and amount > 0 then
      places[#places + 1] = { place = entry.key, amount = amount }
    end
  end

  if #places == 0 then
    return nil
  end

  -- Biggest first, ties broken on the place's id so the popup is stable.
  table.sort(places, function(a, b)
    if a.amount ~= b.amount then
      return a.amount > b.amount
    end
    return a.place:id() < b.place:id()
  end)
  return places
end

-- Where the level's experience was earned, one line per place, for the popup.
-- Called on hover, like placesFor.
--
-- Places that paid nothing are left out here but kept in the panel: the panel
-- tells the level's story with the time spent in each place, while the popup
-- answers only where the experience came from.
function XpBarViewModel.placesOf(record)
  if record == nil or record.places == nil then
    return nil
  end

  local places = {}
  for _, entry in pairs(record.places) do
    if entry.xpTotal > 0 then
      places[#places + 1] = { place = entry.key, amount = entry.xpTotal }
    end
  end

  if #places == 0 then
    return nil
  end

  table.sort(places, function(a, b)
    if a.amount ~= b.amount then
      return a.amount > b.amount
    end
    return a.place:id() < b.place:id()
  end)
  return places
end

ns.core.XpBarViewModel = XpBarViewModel
