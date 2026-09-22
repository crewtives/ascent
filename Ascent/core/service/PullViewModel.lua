-- Ascent - what the pull plate draws, as a pure read.
--
-- Same contract as every other view-model here: no client, no frames, no
-- formatting. It turns a PullRecord into the handful of ordered lists and
-- already-divided numbers the plate paints, so that what the plate shows can be
-- asserted in a test rather than looked at.
--
-- TWO PERCENTAGES THAT ARE NOT THE SAME NUMBER, which is the one trap this
-- surface shares with the report panel: `fraction` on a source is its share OF
-- THIS PULL, and it sums to one. It is not the level's percentage and must never
-- be printed as one -- the bar already owns that number and they will differ by
-- orders of magnitude.


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

-- How many creatures and abilities a plate lists before it stops. A plaque that
-- grows with the pull is a plaque that covers the screen on a good one -- how
-- many is too many is the player's call now, so it arrives per build rather than
-- being a constant of this file.
--
-- The CEILING is not: the plate builds its rows once and shows or hides them, so
-- the most it can ever be asked to draw is paid for at load whether anybody asks
-- for it or not (see PullPlateView's header on fixed pools). Read off the same
-- range Settings clamps the setting to, so the two cannot drift into a view-model
-- that returns more rows than there are rows to put them in.
local ROW_FLOOR = ns.core.SettingRange[SettingKey.PLATE_ROWS].min
local ROW_CEILING = ns.core.SettingRange[SettingKey.PLATE_ROWS].max
local ROW_DEFAULT = ns.core.Defaults[SettingKey.PLATE_ROWS]

-- What was asked for, made safe. Settings.resolve already clamps what comes off
-- disk, so this is for the callers that pass nothing -- the demo, a test, the
-- plate before it has settings -- and for a hand-edited file that got past
-- resolve on some other path.
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

-- The four sources in the order the bar draws them, so a chip row on the plate
-- and a segment row on the bar read left to right the same way. Built once from
-- the frozen enum rather than written out again.
local SOURCE_ORDER = {
  XpSource.MOB_KILL,
  XpSource.QUEST_TURNIN,
  XpSource.EXPLORATION,
  XpSource.UNKNOWN,
}

-- The bar under the headline, and it shows whatever the headline shows.
--
-- `displayed` is the figure on the plate: the forecast while the pull is still
-- expecting experience, the banked total once it is not. Everything derived from
-- the headline -- this bar, the rate in the footer -- is derived from THAT, so
-- the plate tells one story rather than a headline saying 73 above a bar and a
-- rate that both still read zero. That mismatch is what this replaces.
--
-- A source at zero produces no entry at all -- the same call XpBarViewModel makes
-- for a zero-width segment -- so the bar never draws a slice for experience
-- nobody earned.
--
-- The projected remainder is one slice, coloured as creature experience, and
-- that is not a guess about the colour: the forecast is built entirely from what
-- creatures have paid (see buildProjection), so creature experience is precisely
-- what it is. It is flagged `projected` so a surface can draw it as the lighter
-- claim it is.
local function buildSources(pull, displayed)
  local entries = {}
  local total = displayed > 0 and displayed or pull.xpTotal

  for _, source in ipairs(SOURCE_ORDER) do
    local amount = pull.xpBySource[source]
    if amount ~= nil and amount > 0 then
      entries[#entries + 1] = {
        source = source,
        amount = amount,
        -- Guarded rather than assumed: the total is the sum of these plus the
        -- remainder below, so it can only be zero when every one of them is --
        -- but a division that can only happen on a contradiction is still a
        -- division worth not writing.
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

-- Sorted by how many were FOUGHT rather than how many died, because the list has
-- to be in a sensible order from the first blow -- ordering by the dead would
-- leave every row tied at zero until something fell, and `pairs` would then
-- decide the order. Ties are broken by name for the same reason: a list that
-- reshuffles itself between two redraws of the same unchanged pull is a flicker.
local function buildCreatures(pull, rows)
  local entries = {}
  for name, entry in pairs(pull.creatures) do
    entries[#entries + 1] = {
      name = name,
      engaged = entry.engaged,
      killed = entry.killed,
      -- Still fighting at least one of them. What lets the plate mark a row as
      -- live rather than as a body count.
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
-- EVERYTHING ENGAGED COUNTS, dead or alive, and that is the correction of a real
-- defect: the estimate used to cover only what was still standing, so it vanished
-- the instant the last target fell -- which in Classic is exactly when the
-- experience has NOT arrived yet. The headline dropped from "69" to "0" and sat
-- there for the whole settling window, showing a zero for a fight that had just
-- been won.
--
-- MEASURED, NEVER MODELLED. The rate comes from KillXpEstimator, which reads what
-- THIS character has actually been paid for THIS creature at THIS level -- so the
-- level difference, the rested bonus and anything else the server applied are
-- already in it. There is no table of creature values in this addon and there is
-- not going to be one.
--
-- PRICED FOR THE GROUP THAT IS FIGHTING. `sharedBy` is how many characters are
-- sharing the pay right now, and the rate asked for is the one measured with that
-- many: the same creature pulled alone and pulled by a party of five pays two
-- different amounts, and a plate that quoted the solo figure inside a dungeon
-- would be off by roughly the size of the group (D81, D82).
--
-- The basis travels with the number because the three differ by a lot: a creature
-- average measured in this very context is a real answer, one measured before
-- anyone counted the context is an average over populations nobody can name, and
-- the level's own average per kill -- the fallback for a creature never killed at
-- this level -- is wider still, since an elite and a critter of the same level pay
-- very differently. A surface that drew them the same way would be claiming a
-- precision the last two do not have (design D4, D83).
--
-- nil, not zero, when the level has nothing to estimate from. "Nobody knows yet"
-- and "this is worth nothing" are different sentences and only one of them is
-- true on a freshly started level.
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
      -- One creature falling back is enough to widen the whole figure: the
      -- estimate is a sum, and it is only as sure as its least sure term. Which
      -- is why the order is explicit rather than a last-one-wins assignment --
      -- with three values, whichever term `pairs` happened to visit last would
      -- otherwise decide what the whole plate claims.
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

  -- Once MORE has landed than was expected, the expectation has been overtaken
  -- and the real figure is the better answer -- so `estimated` goes false and the
  -- surface can stop marking it as a guess without the number jumping.
  return {
    total = math.max(pull.xpTotal, expected),
    expected = expected,
    estimated = expected > pull.xpTotal,
    basis = basis,
  }
end

-- The ranking is not rebuilt here: AbilityRankingViewModel reads nothing but
-- `record.abilities`, and PullRecord carries that field in LevelRecord's own
-- shape precisely so this function can be four lines.
local function buildAbilities(pull, rows)
  local ranking = AbilityRankingViewModel.build(pull)
  local entries = ranking.entries or {}
  for index = #entries, rows + 1, -1 do
    entries[index] = nil
  end
  return entries, ranking.totalUses or 0
end

-- `levelRecord` is the level in progress, used ONLY to estimate what the
-- creatures still standing are likely to pay. It is read, never written, and a
-- nil one simply costs the projection.
--
-- `sharedBy` is how many characters are sharing the pay right now -- the plate
-- asks the client for it on every draw, the same way it asks for the record --
-- and it only chooses which population the projection is priced from.
--
-- `rows` is how many creature and ability rows the player asked to see, passed
-- per build rather than captured anywhere, so that changing it mid-fight shows
-- the new number on the next redraw. Absent means the default.
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
    -- True only once the pull is FINAL. The plate leads with this: everything it
    -- shows while false is provisional, and the moment it turns true is the one
    -- the effects fire on.
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
    -- How many creatures this pull has traded blows with, dead or not. The count
    -- the plate leads with while a fight is running, where kills is still zero.
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

    -- Off the DISPLAYED figure, so the rate is the rate of the number above it.
    -- It used to read zero for the whole of every fight -- the banked total is
    -- zero until the experience lands, which in Classic is after the kill -- and
    -- a plate that showed "73 XP" over "0 xp/h" was contradicting itself.
    -- nil rather than zero where there is no denominator; see PullRecord.
    xpPerHour = seconds > 0 and (displayed / seconds * 3600) or nil,
    damagePerSecond = pull:damagePerSecond(now),
    xpPerKill = pull:xpPerKill(),
  }
end

-- Exposed so the plate can size its fixed pools once instead of discovering the
-- ceiling by growing into it, and so a test can assert the ceiling rather than
-- reading it off a magic number in the drawing code.
PullViewModel.ROW_CEILING = ROW_CEILING
PullViewModel.SOURCE_COUNT = #Frozen.keys(XpSource)

ns.core.PullViewModel = PullViewModel
