-- Ascent - one pull: everything that happened between entering combat and the
-- moment the last consequence of it landed.
--
-- Every other record in this addon is keyed to a LEVEL. That is the right unit
-- for "where did this level's experience come from" and the wrong one for the
-- question a player actually asks mid-fight, which is "how did THAT go". A pull
-- is the smallest unit of play that has an answer, and nothing here had one.
--
-- WHY `abilities` IS SHAPED LIKE LEVELRECORD'S. It is keyed exactly the way that
-- record keys its own -- spell id, or one of AbilityKey's two reserved synthetic
-- keys for auto attacks -- and holds the same AbilityUsage objects. That is not a
-- coincidence, it is the point: core/service/AbilityRankingViewModel.lua reads
-- nothing but `record.abilities`, so it ranks a pull with no change and no second
-- implementation.
--
-- WHAT A COMBO IS, precisely, because the word is vaguer than the number.
-- A combo is consecutive kills separated by less than `comboWindow` seconds.
-- It is NOT the same as the pull's kill count: a pull where three things died
-- in six seconds and a fourth died forty seconds later was a chain of three and
-- then a chain of one, and reporting it as four would flatter the player about a
-- fight they did not have. `bestStreak` keeps the longest chain the pull
-- contained; `streak` is the one still running.
--
-- NOTHING HERE IS PERSISTED. A pull is answered while the player can still
-- remember it and then it is gone -- the level record already holds every
-- aggregate that has to survive a logout, and writing a second copy of the same
-- kills to disk once per fight is how a saved variables file gets big for no
-- reason. This model therefore has no toStored/restore pair, deliberately, and
-- that absence is the only thing about it that is worth checking twice.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local XpSource = ns.core.XpSource
local AbilityUsage = ns.core.AbilityUsage

-- Seconds of quiet after which the next kill starts a new chain rather than
-- extending the running one. Long enough to survive a pull where one target
-- takes a while to fall, short enough that a pause to drink ends the chain --
-- which is what a player means when they say the combo dropped.
local COMBO_WINDOW = 10

local PullRecord = {}
PullRecord.__index = PullRecord

-- `startedAt` is a reading of the session clock, not a wall time: a pull never
-- outlives the session it happened in, so the clock whose contract says it is
-- meaningless between sessions is exactly the right one.
function PullRecord.new(startedAt, options)
  Guard.number(startedAt, "PullRecord.startedAt")
  options = options or {}

  return setmetatable({
    startedAt = startedAt,
    -- When combat last ended. Cleared when combat resumes inside the settling
    -- window, which is what makes a chained pull one pull (see PullTracker).
    endedAt = nil,
    comboWindow = options.comboWindow or COMBO_WINDOW,

    xpTotal = 0,
    xpBySource = {},

    kills = 0,
    -- name -> { engaged = n, killed = m }. TWO numbers and not one, because the
    -- question the plate answers mid-fight is "what am I fighting", and a tally
    -- of the dead cannot answer it -- it is empty for the whole of the first
    -- fight, which is exactly when a player is looking. `engaged` counts the
    -- distinct creatures of that name this pull has landed a blow on; `killed`
    -- counts how many of them fell.
    creatures = {},
    -- The GUIDs already counted as engaged, so ten swings at one kobold are one
    -- kobold. Cleared with the pull, never persisted, and the only reason a name
    -- alone is not enough: two Mana Serpents are two, and the same one hit twice
    -- is still one.
    engagedGuids = {},

    abilities = {},   -- LevelRecord's shape exactly; see the header

    streak = 0,
    bestStreak = 0,
    lastKillAt = nil,

    damageDealt = 0,
    damageTaken = 0,
    healingReceived = 0,
    deaths = 0,
  }, PullRecord)
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

-- Experience is recorded by amount and source rather than by handing over the
-- XpGain itself: a pull has no business with the rested split, the quest id or
-- the creature key -- the level record owns all three and answers for them.
function PullRecord:recordXp(amount, source)
  Guard.nonNegativeInteger(amount, "PullRecord.recordXp amount")
  Guard.member(XpSource, "XpSource", source, "PullRecord.recordXp source")

  self.xpTotal = self.xpTotal + amount
  self.xpBySource[source] = (self.xpBySource[source] or 0) + amount
  return self.xpTotal
end

-- `name` may be nil: the combat log gives a name for every creature death this
-- addon is shown, but a nil there must cost the per-creature tally and not the
-- kill count, which is the number the plate leads with.
function PullRecord:recordKill(name, at)
  Guard.number(at, "PullRecord.recordKill at")

  self.kills = self.kills + 1

  if self.lastKillAt ~= nil and (at - self.lastKillAt) <= self.comboWindow then
    self.streak = self.streak + 1
  else
    self.streak = 1
  end
  self.lastKillAt = at
  if self.streak > self.bestStreak then
    self.bestStreak = self.streak
  end

  if name ~= nil then
    local entry = self:creatureEntry(name)
    entry.killed = entry.killed + 1
    -- A creature can die without this pull ever having recorded a blow on it --
    -- a killing blow from a DoT applied before the pull opened, a pet's kill, a
    -- swing whose GUID was not a creature. It was still something we fought, so
    -- the engaged count never sits below the dead one.
    if entry.killed > entry.engaged then
      entry.engaged = entry.killed
    end
  end

  return self.streak
end

function PullRecord:creatureEntry(name)
  local entry = self.creatures[name]
  if entry == nil then
    entry = { engaged = 0, killed = 0 }
    self.creatures[name] = entry
  end
  return entry
end

-- One blow landed on a named creature. Counted once per creature, not once per
-- swing: `guid` is what tells two Mana Serpents apart from the same one hit
-- eight times. With no guid -- a client that gave none, a source this router
-- could not name -- the creature is counted once by name and never again, which
-- undercounts a pack of identical adds rather than inventing one per hit.
function PullRecord:recordEngagement(name, guid)
  if name == nil then
    return
  end

  local key = guid or name
  if self.engagedGuids[key] then
    return
  end
  self.engagedGuids[key] = true

  local entry = self:creatureEntry(name)
  entry.engaged = entry.engaged + 1
end

function PullRecord:recordAbility(key, name)
  local usage = self.abilities[key]
  if usage == nil then
    usage = AbilityUsage.new(key, name)
    self.abilities[key] = usage
  end
  usage:record()
  return usage.count
end

function PullRecord:recordDamageDealt(amount, name, guid)
  Guard.nonNegativeInteger(amount, "PullRecord.recordDamageDealt amount")
  self.damageDealt = self.damageDealt + amount
  -- Landing a blow on something is what "fighting it" means here. Recorded on
  -- the same call rather than as a second event, because the two facts arrive on
  -- one combat log line and splitting them would let one be dropped.
  self:recordEngagement(name, guid)
end

function PullRecord:recordDamageTaken(amount)
  Guard.nonNegativeInteger(amount, "PullRecord.recordDamageTaken amount")
  self.damageTaken = self.damageTaken + amount
end

function PullRecord:recordHealing(amount)
  Guard.nonNegativeInteger(amount, "PullRecord.recordHealing amount")
  self.healingReceived = self.healingReceived + amount
end

function PullRecord:recordDeath()
  self.deaths = self.deaths + 1
end

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

-- How long the pull has lasted, or lasted for: once combat has ended the answer
-- stops growing, even while the record is still absorbing experience that was
-- already in flight. A rate whose denominator kept climbing during the settling
-- window would sag visibly on a plate the player is looking at.
function PullRecord:duration(now)
  local until_ = self.endedAt or now
  if until_ == nil then
    return 0
  end
  local seconds = until_ - self.startedAt
  if seconds < 0 then
    return 0
  end
  return seconds
end

-- Rates answer nil rather than zero when there is no time to divide by. Zero is
-- a measurement; this is the absence of one, and the two print differently.
function PullRecord:xpPerHour(now)
  local seconds = self:duration(now)
  if seconds <= 0 then
    return nil
  end
  return self.xpTotal / seconds * 3600
end

function PullRecord:damagePerSecond(now)
  local seconds = self:duration(now)
  if seconds <= 0 then
    return nil
  end
  return self.damageDealt / seconds
end

function PullRecord:xpPerKill()
  if self.kills <= 0 then
    return nil
  end
  return self.xpTotal / self.kills
end

-- Whether anything at all was observed. A pull that opened and closed with
-- nothing in it is a real thing -- combat entered by a passing proximity aggro
-- and left again -- and the plate needs to be able to say so rather than draw a
-- plaque full of zeros.
function PullRecord:isEmpty()
  return self.kills == 0 and self.xpTotal == 0 and self.damageDealt == 0 and self.damageTaken == 0
end

-- How many distinct creatures this pull has traded blows with, dead or not. The
-- headline count while a fight is running, where `kills` is still zero.
function PullRecord:engagedCount()
  local total = 0
  for _, entry in pairs(self.creatures) do
    total = total + entry.engaged
  end
  return total
end

ns.core.PullRecord = PullRecord
