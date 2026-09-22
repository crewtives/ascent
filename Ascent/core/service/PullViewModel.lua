-- Ascent - what the pull plate draws, as a pure read.
--
-- No client, no frames, no formatting: a PullRecord becomes the ordered lists
-- and already-divided numbers the plate paints, so its content is testable.
--
-- `fraction` on a source is its share of this pull and sums to one. It is not
-- the level's percentage, which the bar shows, and must never be printed as one.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource
local Frozen = ns.core.Frozen
local PullPhase = ns.core.PullPhase
local AbilityRankingViewModel = ns.core.AbilityRankingViewModel
local KillXpEstimator = ns.core.KillXpEstimator
local SettingKey = ns.core.SettingKey

-- How sure each provenance is, so a sum of several terms can keep the least sure
-- of them rather than the last one read.
local BASIS_CONFIDENCE = {
  [KillXpEstimator.Basis.CREATURE] = 3,
  [KillXpEstimator.Basis.MIXED] = 2,
  [KillXpEstimator.Basis.LEVEL] = 1,
}

-- How many creature and ability rows a plate lists is a player setting, passed
-- per build. The ceiling is fixed: the plate creates its row pools once at load
-- (see PullPlateView's header), so it is read from the same range Settings
-- clamps to, and this never returns more rows than the pools hold.
local ROW_FLOOR = ns.core.SettingRange[SettingKey.PLATE_ROWS].min
local ROW_CEILING = ns.core.SettingRange[SettingKey.PLATE_ROWS].max
local ROW_DEFAULT = ns.core.Defaults[SettingKey.PLATE_ROWS]

-- The requested row count, made safe. Settings.resolve already clamps saved
-- values; this covers callers that pass nothing (the demo, a test, the plate
-- before settings load) and values that reach here by another path.
local function rowsAsked(rows)
  if type(rows) ~= "number" then
    return ROW_DEFAULT
  end
  if rows < ROW_FLOOR then
    return ROW_FLOOR
  end
  if rows > ROW_CEILING then
    return ROW_CEILING
  end
  return math.floor(rows)
end

local PullViewModel = {}

-- The four sources in the order the bar draws them, so the plate's chips and the
-- bar's segments read left to right the same way.
local SOURCE_ORDER = {
  XpSource.MOB_KILL,
  XpSource.QUEST_TURNIN,
  XpSource.EXPLORATION,
  XpSource.UNKNOWN,
}

-- The bar under the headline, which shows whatever the headline shows.
--
-- `displayed` is the figure on the plate: the forecast while the pull still
-- expects experience, the banked total once it does not. This bar and the
-- footer's rate both derive from it, so they never contradict the headline.
--
-- A source at zero produces no entry, as XpBarViewModel skips zero-width
-- segments.
--
-- The projected remainder is one slice counted as creature experience, since
-- the forecast is built only from what creatures have paid (see
-- buildProjection). It is flagged `projected` so a surface can draw it lighter.
local function buildSources(pull, displayed)
  local entries = {}
  local total = displayed > 0 and displayed or pull.xpTotal

  for _, source in ipairs(SOURCE_ORDER) do
    local amount = pull.xpBySource[source]
    if amount ~= nil and amount > 0 then
      entries[#entries + 1] = {
        source = source,
        amount = amount,
        -- The total can only be zero when every amount is; guarded anyway.
        fraction = total > 0 and (amount / total) or 0,
        projected = false,
      }
    end
  end

  local remainder = displayed - pull.xpTotal
  if remainder > 0 then
    entries[#entries + 1] = {
      source = XpSource.MOB_KILL,
      amount = remainder,
      fraction = total > 0 and (remainder / total) or 0,
      projected = true,
    }
  end

  return entries
end

-- Sorted by how many were fought, not killed, so the order is meaningful from the
-- first blow instead of every row tying at zero. Ties break by name so the list
-- does not reshuffle (following `pairs`) between redraws of an unchanged pull.
local function buildCreatures(pull, rows)
  local entries = {}
  for name, entry in pairs(pull.creatures) do
    entries[#entries + 1] = {
      name = name,
      engaged = entry.engaged,
      killed = entry.killed,
      -- Still fighting at least one of them, so the plate can mark the row live.
      pending = entry.engaged - entry.killed,
    }
  end
  table.sort(entries, function(a, b)
    if a.engaged ~= b.engaged then
      return a.engaged > b.engaged
    end
    return a.name < b.name
  end)
  for index = #entries, rows + 1, -1 do
    entries[index] = nil
  end
  return entries
end

-- What this pull is on course to be worth.
--
-- Everything engaged counts, dead or alive: in Classic the experience arrives
-- after the kill, so an estimate of only what still stands would drop to zero
-- for the whole settling window of a fight just won.
--
-- The rate is measured, never modelled: KillXpEstimator reads what this
-- character was paid for this creature at this level, so level difference,
-- rested bonus and server modifiers are already in it. There is no table of
-- creature values.
--
-- `sharedBy` is how many characters share the pay right now, and the rate is the
-- one measured with that many: the same creature pays differently solo and in a
-- party of five.
--
-- The basis travels with the number because the three differ in precision: a
-- creature average for this group size, a creature average recorded without a
-- group size, and the level's average per kill (for a creature never killed at
-- this level), the widest since an elite and a critter pay very differently.
--
-- nil, not zero, when the level has nothing to estimate from: "unknown" is not
-- "worth nothing".
local function buildProjection(pull, levelRecord, sharedBy)
  if levelRecord == nil then
    return nil
  end

  local expected = 0
  local basis = nil

  for name, entry in pairs(pull.creatures) do
    if entry.engaged > 0 then
      local rate, term = KillXpEstimator.rateFor(levelRecord, name, sharedBy)
      if rate == nil then
        return nil
      end
      -- A sum is only as sure as its least sure term, so the basis keeps the
      -- least confident one instead of whichever `pairs` visited last.
      if basis == nil or BASIS_CONFIDENCE[term] < BASIS_CONFIDENCE[basis] then
        basis = term
      end
      expected = expected + entry.engaged * rate
    end
  end

  if expected <= 0 then
    return nil
  end

  expected = math.floor(expected + 0.5)

  -- Once more has landed than expected, the real figure wins: `estimated` goes
  -- false and the surface stops marking it as a guess without the number jumping.
  return {
    total = math.max(pull.xpTotal, expected),
    expected = expected,
    estimated = expected > pull.xpTotal,
    basis = basis,
  }
end

-- AbilityRankingViewModel reads only `record.abilities` (and a level's
-- `unavailable` mark, which a pull does not carry), and PullRecord keeps that
-- field in LevelRecord's shape, so the ranking is reused as is.
local function buildAbilities(pull, rows)
  local ranking = AbilityRankingViewModel.build(pull)
  local entries = ranking.entries or {}
  for index = #entries, rows + 1, -1 do
    entries[index] = nil
  end
  return entries, ranking.totalUses or 0
end

-- `levelRecord` is the level in progress, read only to price the projection;
-- nil means no projection.
--
-- `sharedBy` is how many characters share the pay right now, asked of the client
-- on every draw; it only picks which measured rate the projection uses.
--
-- `rows` is the requested creature and ability row count, passed per build so a
-- change mid-fight shows on the next redraw. Absent means the default.
function PullViewModel.build(pull, phase, now, levelRecord, sharedBy, rows)
  if pull == nil or phase == PullPhase.IDLE then
    return { active = false, phase = PullPhase.IDLE }
  end

  rows = rowsAsked(rows)
  local abilities, totalUses = buildAbilities(pull, rows)
  local projection = buildProjection(pull, levelRecord, sharedBy)

  -- The one figure everything on the plate is derived from. See buildSources.
  local displayed = pull.xpTotal
  if projection ~= nil and projection.estimated and phase ~= PullPhase.CLOSED then
    displayed = projection.total
  end

  local seconds = pull:duration(now)

  return {
    active = true,
    phase = phase,
    -- True only once the pull is final. While false everything is provisional;
    -- the plate's effects fire when it turns true.
    final = phase == PullPhase.CLOSED,
    empty = pull:isEmpty(),

    elapsed = pull:duration(now),

    xpTotal = pull.xpTotal,
    -- What the headline reads: the forecast while one stands, the banked total
    -- once it does not. Everything below derives from this, not from xpTotal.
    displayed = displayed,
    sources = buildSources(pull, displayed),
    -- { total, expected, estimated, basis } or nil. See buildProjection.
    projection = projection,

    kills = pull.kills,
    -- Creatures this pull has fought, dead or not: the count the plate shows
    -- while kills is still zero.
    engaged = pull:engagedCount(),
    streak = pull.streak,
    bestStreak = pull.bestStreak,
    creatures = buildCreatures(pull, rows),

    abilities = abilities,
    totalUses = totalUses,

    damageDealt = pull.damageDealt,
    damageTaken = pull.damageTaken,
    healingReceived = pull.healingReceived,
    deaths = pull.deaths,

    -- From the displayed figure, so the rate matches the headline; the banked
    -- total stays zero until the experience lands, which in Classic is after the
    -- kill. nil rather than zero with no denominator; see PullRecord.
    xpPerHour = seconds > 0 and (displayed / seconds * 3600) or nil,
    damagePerSecond = pull:damagePerSecond(now),
    xpPerKill = pull:xpPerKill(),
  }
end

-- Exposed so the plate can size its fixed pools once and a test can assert the
-- ceiling.
PullViewModel.ROW_CEILING = ROW_CEILING
PullViewModel.SOURCE_COUNT = #Frozen.keys(XpSource)

ns.core.PullViewModel = PullViewModel
