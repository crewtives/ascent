-- Ascent - one pull: everything that happened between entering combat and the
-- moment the last consequence of it landed.
--
-- Every other record in this addon is keyed to a level, which answers where a
-- level's experience came from but not how one fight went. A pull is the smallest
-- unit of play that answers that.
--
-- `abilities` has LevelRecord's shape: keyed by spell id, or by one of
-- AbilityKey's two reserved synthetic keys for auto attacks, and holding the same
-- AbilityUsage objects. core/service/AbilityRankingViewModel.lua reads nothing
-- but `record.abilities`, so it ranks a pull with no second implementation.
--
-- A combo is consecutive kills separated by at most `comboWindow` seconds. It is
-- not the pull's kill count: three deaths in six seconds and a fourth forty
-- seconds later are a chain of three and then a chain of one. `bestStreak` keeps
-- the longest chain the pull contained; `streak` is the one still running.
--
-- Nothing here is persisted, so this model deliberately has no toStored/restore
-- pair: the level record already holds every aggregate that has to survive a
-- logout, and a second copy of the same kills per fight would only grow the saved
-- variables file.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local XpSource = ns.core.XpSource
local AbilityUsage = ns.core.AbilityUsage

-- Seconds of quiet after which the next kill starts a new chain rather than
-- extending the running one. Long enough to survive a pull where one target
-- takes a while to fall, short enough that a pause to drink ends the chain.
local COMBO_WINDOW = 10

local PullRecord = {}
PullRecord.__index = PullRecord

-- `startedAt` is a reading of the session clock (Clock.now), not a wall time: a
-- pull never outlives the session it happened in.
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
    -- name -> { engaged = n, killed = m }. Two numbers, because the plate shows
    -- mid-fight what is being fought, and a tally of the dead is empty until the
    -- first kill. `engaged` counts the distinct creatures of that name in this
    -- pull; `killed` counts how many of them fell.
    creatures = {},
    -- The GUIDs already counted as engaged, so ten swings at one kobold are one
    -- kobold. Cleared with the pull, never persisted. A name alone is not enough:
    -- two Mana Serpents are two, and the same one hit twice is still one.
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
    -- swing whose GUID was not a creature. It was still fought, so the engaged
    -- count never sits below the dead one.
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
--
-- Returns whether this changed anything. Both ways of learning that a creature is
-- in the fight repeat themselves -- the combat log writes thirty lines about one
-- creature and a sweep sees the same nameplate four times a second -- and the pull
-- is the one place that can say which of them was news.
function PullRecord:recordEngagement(name, guid)
  if name == nil then
    return false
  end

  local key = guid or name
  if self.engagedGuids[key] then
    return false
  end
  self.engagedGuids[key] = true

  local entry = self:creatureEntry(name)
  entry.engaged = entry.engaged + 1
  return true
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

-- The other half of recordDamageDealt: something hitting the player is being
-- fought, whether or not the player has hit it back. Without it, a pull the player
-- did not start would list nothing until the player's first blow. Same engagement
-- rule, so the two ends cannot count one creature twice.
function PullRecord:recordDamageTaken(amount, name, guid)
  Guard.nonNegativeInteger(amount, "PullRecord.recordDamageTaken amount")
  self.damageTaken = self.damageTaken + amount
  self:recordEngagement(name, guid)
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

-- Whether nothing at all was observed, which the plate reads as "stay hidden". A
-- pull that opened and closed with nothing in it is real -- combat entered by a
-- passing proximity aggro and left again -- and must not draw a plaque of zeros.
--
-- Being fought counts. A creature hitting an absorb shield, or charging across
-- the ground as seen by the nameplate watch, leaves every damage figure at zero,
-- and a pull with an engaged creature still has that row to show.
function PullRecord:isEmpty()
  return self.kills == 0 and self.xpTotal == 0 and self.damageDealt == 0
    and self.damageTaken == 0 and self:engagedCount() == 0
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
