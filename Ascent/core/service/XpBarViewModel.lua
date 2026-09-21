-- Ascent - the experience bar's view-model.
--
-- The bar is drawn from three things that all look like "a fraction of the level"
-- but mean different things, and keeping that distinction is the whole point of
-- this module (D7, task 10.1):
--
--   segments   experience already earned, broken down by source. Their widths sum
--              to exactly the level's completed percentage -- that sum is the
--              guarantee the rest of the addon exists to keep, so it is verified
--              rather than assumed. What the client has confirmed but XpAttribution
--              has not yet settled into a source (D21's bounded lag) is folded into
--              the UNKNOWN segment as provisional, per D21's own prescription --
--              "paint the not-yet-attributed queue as unclassified instead of not
--              moving" -- rather than leaving the bar showing a stale total.
--   rested     the resting reserve. It sits past the segments, visually, but it
--              is not experience the player has earned: it is capped so it can
--              never push the end of the bar past 100%.
--   pending    experience a quest in the log would pay, if turned in. It is a
--              projection, never a fact, so it NEVER becomes a segment and NEVER
--              moves the completed percentage -- it lives in its own channel and
--              saturates at the end of the bar instead of overflowing it.
--
-- All of it is a pure function of a LevelRecord plus a small bag of numbers the
-- record does not carry itself (the rested reserve lives on the player, not the
-- level; the pending total belongs to the quest forecast capacity, group 8, which
-- does not exist yet). Building it in core rather than ui (D7) is what makes every
-- one of these rules testable without a client.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource

local XpBarViewModel = {}

-- The order the bar draws segments in, left to right. `Frozen.each` is sorted
-- alphabetically by the enum's Lua key (a deliberate property of Frozen, for
-- reproducible diagnostics) and would draw EXPLORATION before MOB_KILL, which is
-- not a reading order a player looking at a bar would recognise. This is the
-- source's own declared order from Xp.lua instead, spelled out through the enum
-- rather than as bare strings so a typo here still fails at load time.
local SOURCES_IN_DRAW_ORDER = {
  XpSource.MOB_KILL, XpSource.QUEST_TURNIN, XpSource.EXPLORATION, XpSource.UNKNOWN,
}

-- One entry per source that actually paid something, in that draw order. A source
-- sitting at zero produces no entry: an empty segment would be a sliver of nothing
-- for the player to puzzle over, not information. `unattributedXp` (already capped
-- by the caller) rides along with UNKNOWN's own confirmed total, which is what
-- makes a kill's XP show up in the bar within one redraw tick instead of D21's
-- full settling window.
local function buildSegments(record, xpRequired, unattributedXp)
  local segments = {}
  for _, source in ipairs(SOURCES_IN_DRAW_ORDER) do
    local amount = record:xpFrom(source)
    if source == XpSource.UNKNOWN then
      amount = amount + unattributedXp
    end
    if amount > 0 then
      -- `amount` rides along so a caller (the bar's tooltip) reads the same figure
      -- that produced the segment's width, instead of re-deriving it from the
      -- record and landing on a number that no longer matches once unattributedXp
      -- is folded in above.
      segments[#segments + 1] = { source = source, amount = amount, fraction = amount / xpRequired }
    end
  end
  return segments
end

-- The reserve is capped to whatever room is left past the completed percentage,
-- because the bar has nowhere to put a rested portion beyond its own end. There is
-- no scenario in the spec for this edge; capping rather than overflowing is the
-- safer of the two guesses.
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

-- Pending experience saturates at the end of the bar instead of spilling past it,
-- and is measured against what is actually left in the level rather than against
-- its own size -- the spec's "se satura al final de la barra sin desbordarla".
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

-- What the record can say about its OWN completeness, which is a fact about the
-- recording and not about the experience. Absent whenever the level was watched
-- from its first point, so a surface reading this renders nothing and reserves no
-- room for it.
--
-- Three states, because there are genuinely three. A level watched throughout says
-- nothing. A level opened part-way says how much it inherited, and the remainder of
-- UNKNOWN is experience that WAS watched and could not be attributed -- a different
-- failure with a different owner. And a record written before the addon kept that
-- figure can only say it is partial: `seededXp` is nil there, and splitting UNKNOWN
-- for it would be inventing the split rather than reporting it.
local function buildObservation(record, unattributedXp)
  if not record.partial then
    return nil
  end

  local seeded = record.seededXp
  if seeded == nil then
    return { partial = true }
  end

  -- `unattributedXp`, not just the bucket. The UNKNOWN segment shown to the player
  -- is the bucket PLUS whatever the client has confirmed and attribution has not
  -- settled yet (D21) -- buildSegments adds it there, so a split computed from the
  -- bucket alone does not add up to the line it sits under, and the difference is
  -- unexplained on screen in the one place whose whole job is explaining it.
  --
  -- It belongs on this side of the split and not the other: experience waiting in
  -- the settling window WAS observed. Nobody has said where it came from yet, which
  -- is precisely what "watched and unattributed" means.
  local unknown = record:xpFrom(XpSource.UNKNOWN) + unattributedXp
  return {
    partial = true,
    seededXp = seeded,
    -- Floored at zero. The seed can outgrow the bucket when a file arrives
    -- contradicting itself: restore() runs reconcile(), which drops UNKNOWN to zero
    -- when the breakdown claims more than the total, while seededXp keeps the figure
    -- it was written with. Retention is NOT a cause -- it trims `gains` and never
    -- the per-source totals -- and looking for it there would waste the search.
    unexplainedXp = math.max(0, unknown - seeded),
  }
end

-- `record` may be nil (no experience to show at all) and, separately, a real
-- record may not yet know its own requirement (the client has not reported it).
-- Both collapse to the same inactive shape rather than making the caller guess
-- which kind of "nothing to show" it got.
function XpBarViewModel.build(record, params)
  if record == nil or record.xpRequired == nil or record.xpRequired <= 0 then
    return { active = false }
  end
  params = params or {}

  local xpRequired = record.xpRequired

  -- Capped to whatever room the level actually has left, the same way buildPending
  -- already caps its own projection: a delta that turns out to cross a level
  -- boundary belongs partly to the level that opens next, and this view has no way
  -- to know that split ahead of XpAttribution settling it for real.
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
  }
end

-- The per-channel shares the bar animates, in the vocabulary BarChannel declares:
-- a source id for each segment, plus "rested" and "pending". Pure, and here
-- rather than in the view because TWO views need it -- the real bar and the
-- preview in the options panel -- and two derivations of the same thing is how
-- a preview starts lying about what the bar will look like.
--
-- A channel that is absent from the result is a channel holding nothing, which
-- the tween places on its neighbour's edge with zero width rather than removing
-- from a vector it indexes by identity.
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
-- ASKED, not built. This used to ride on every segment, which meant computing it
-- inside build() -- and build() runs on the redraw tick, up to five times a
-- second, whether or not the bar is even on screen. Four lists, a table per
-- matching place and a sort whose comparator formats two strings per comparison,
-- thrown away unread, for a popup nobody is hovering. It is a question with an
-- answer, so it is a function, and the cost is paid by the one event that wants
-- it.
--
-- It stays here rather than in the view for the reason the rest of this file
-- gives: it is arithmetic over a record, and arithmetic gets a test.
--
-- Answers nil when the level cannot support the question -- no places at all, or
-- places recorded by a build that did not keep which source paid for them. Both
-- must render as the popup rendered before any of this existed: no line, no
-- placeholder, no reserved room.
--
-- Two shortfalls are deliberate and neither is padded. The experience the client
-- has confirmed and the attribution has not settled (D21) rides in the UNKNOWN
-- segment and is in no place yet; and a level already under way when places
-- started being recorded carries experience that belongs to no place at all. In
-- both the places add up to less than the segment, which is what actually
-- happened.
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

  -- Biggest first, ties broken on the place's own id so two reads of the same
  -- record produce the same popup.
  table.sort(places, function(a, b)
    if a.amount ~= b.amount then
      return a.amount > b.amount
    end
    return a.place:id() < b.place:id()
  end)
  return places
end

-- Where the level's experience was earned, one line per place, for the popup's
-- own block. ASKED rather than built, exactly like placesFor above and for the
-- same reason: build() runs on the redraw tick and nobody is hovering.
--
-- Places that paid nothing are left out HERE and kept in the panel, and the
-- difference is what each surface is for: a zone walked through is part of the
-- story of a level (the panel tells it, with the time spent there), and the popup
-- answers one question at a glance -- where did this level's experience come from.
-- A row of zeroes is not an answer to that one.
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
