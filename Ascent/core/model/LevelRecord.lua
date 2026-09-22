-- Ascent - the record of a single level.
--
-- This is the aggregate everything else writes into and the panel reads from. It
-- is deliberately plain data with a strict constructor: services mutate it, but
-- nobody gets to invent a field or leave an accumulator nil.
--
-- These marks carry meaning beyond their value:
--
--   partial       the addon did not observe this whole level. It was installed
--                 mid-level, or data was reset, or levels went by while it was
--                 not watching. The sources still add up to the client's total
--                 because the gap is seeded into UNKNOWN, but the level was not
--                 fully accounted for and the panel says so.
--   seededXp      how much of that UNKNOWN is the seed itself. `partial` says the
--                 accounting is incomplete; this says by how much, and it is the
--                 only thing that separates experience nobody watched from
--                 experience that was watched and could not be attributed. Both
--                 live in UNKNOWN; without it a surface showing "unclassified"
--                 would present the unwatched part as a failure to attribute.
--
--                 Nil is a real answer and not zero: a record written before this
--                 field existed cannot say how much of its UNKNOWN was seeded, and
--                 zero would claim every one of those points was observed and
--                 unattributed. Zero means "seeded nothing", nil means "never
--                 recorded which".
--   timeAnchored  the time on this level was confirmed against the server's own
--                 played-time figure rather than only measured locally.
--   unavailable   the client sources this level was recorded without, whole or in
--                 part, each with the reason it was off. What a source fed is not
--                 "zero" on such a level, it is "not measured", and the surfaces
--                 say so -- also when the level is opened later on a client that
--                 does have the source. Empty means both were there.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local Guard = ns.core.Guard
local Stored = ns.core.Stored
local Packed = ns.core.Packed
local XpGain = ns.core.XpGain
local AbilityUsage = ns.core.AbilityUsage
local CombatSummary = ns.core.CombatSummary
local XpSource = ns.core.XpSource
local XpModifier = ns.core.XpModifier
local MetricId = ns.core.MetricId
local RecordedSource = ns.core.RecordedSource
local SourceState = ns.core.SourceState

local LevelRecord = {}
LevelRecord.__index = LevelRecord

local function zeroedFrom(enum)
  local zeroed = {}
  for _, value in Frozen.each(enum) do
    zeroed[value] = 0
  end
  return zeroed
end

-- Start (or restart) a record in place. Everything resets together so a reused
-- record can never keep half of a previous level's numbers.
function LevelRecord:reset(level, startedAt)
  Guard.positiveInteger(level, "LevelRecord.level")
  Guard.number(startedAt, "LevelRecord.startedAt")

  self.level = level
  self.startedAt = startedAt
  self.completedAt = nil

  -- how long the player was actually here, and over how many sittings
  self.playedSeconds = 0
  self.sessions = 1

  -- The monotonic clock at the last save. It is the only way to tell a /reload from
  -- a fresh client: that clock keeps running across a reload and starts again from
  -- near zero when the client does, so a value lower than the stored one means the
  -- client restarted and this is a new sitting. Meaningless as an instant; only the
  -- comparison is meaningful.
  self.lastSeenAt = nil

  -- experience, kept per source so the sum can be checked against the client
  self.xpTotal = 0
  self.xpRequired = nil -- learned from the client; unknown until then
  self.xpBySource = zeroedFrom(XpSource)
  self.xpByModifier = zeroedFrom(XpModifier)

  -- creatures, keyed by type, observed level and the group the kill was paid to
  -- (see LevelRecord.creatureId)
  self.creatures = {}
  self.killsWithXp = 0
  self.killsWithoutXp = 0

  -- quests turned in during this level, by quest id
  self.quests = {}

  -- where the level was spent, by place key: experience earned there and time
  -- spent there, including places that paid nothing at all. A second dimension
  -- over the same experience the sources already account for, never a partition
  -- of it -- which is why it has its own map and not a field on a gain.
  self.places = {}

  -- abilities used, by spell id or by a reserved synthetic key
  self.abilities = {}

  -- whatever the registered metric collectors accumulate, keyed by MetricId
  self.metrics = {}

  -- bounded detail: the most recent individual gains, trimmed by the retention
  -- policy. The aggregates above are never trimmed.
  self.gains = {}

  self.partial = false
  self.seededXp = nil
  self.timeAnchored = false
  self.unavailable = {}

  return self
end

function LevelRecord.new(level, startedAt)
  return setmetatable({}, LevelRecord):reset(level, startedAt)
end

function LevelRecord:isComplete()
  return self.completedAt ~= nil
end

-- A source this level is being recorded without. The first reason stands:
-- a source absent from the start does not become "unreadable" later, and one that
-- closed mid-level is not unclosed by anything that happens after.
function LevelRecord:markUnavailable(source, reason)
  Guard.member(RecordedSource, "RecordedSource", source, "LevelRecord.markUnavailable source")
  Guard.member(SourceState, "SourceState", reason, "LevelRecord.markUnavailable reason")
  if self.unavailable[source] == nil then
    self.unavailable[source] = reason
  end
  return self
end

-- Why this level was recorded without `source`, or nil when it was not.
function LevelRecord:unavailableReason(source)
  return self.unavailable[source]
end

function LevelRecord:xpFrom(source)
  return self.xpBySource[source] or 0
end

function LevelRecord:xpFromModifier(modifier)
  return self.xpByModifier[modifier] or 0
end

-- The addon's central invariant: what the sources add up to must equal what was
-- actually earned. Exposed so tests and diagnostics can assert it
-- rather than trusting that every writer did its part.
function LevelRecord:sumOfSources()
  local total = 0
  for _, amount in pairs(self.xpBySource) do
    total = total + amount
  end
  return total
end

function LevelRecord:sourcesAddUp()
  return self:sumOfSources() == self.xpTotal
end

-- The entry for a place, created empty on first sight. Both writers go through
-- here -- the ledger crediting experience and the collector crediting time -- so a
-- place the player only walked through and a place they only killed in are the
-- same kind of entry, with the half nobody filled left at zero.
--
-- `xpBySource` is the joint of the two dimensions, and it exists because the two
-- marginals do not imply it. A level of a thousand with sources {kills 500,
-- turn-ins 500} and places {dungeon 500, world 500} is the same record whether
-- every kill happened underground or each source split evenly -- and "what part
-- of your creature experience came from that dungeon" is exactly the question
-- that tells those two levels apart. It is left empty rather than zeroed, so a
-- place written before this was recorded stays distinguishable from a place that
-- genuinely earned nothing.
function LevelRecord:placeEntry(key)
  local id = key:id()
  local entry = self.places[id]
  if entry == nil then
    entry = { key = key, xpTotal = 0, seconds = 0, xpBySource = {} }
    self.places[id] = entry
  elseif entry.key.name == nil and key.name ~= nil then
    -- The name often arrives late. The client answers a map id before it answers
    -- zone text -- during a loading screen `GetZoneText()` is the empty string
    -- while `C_Map` already knows where the character is -- so the first sighting
    -- of a place routinely identifies it without naming it. The entry adopts the
    -- name when it arrives; the identity never changes, only the missing half.
    entry.key = key
  end
  return entry
end

function LevelRecord:xpAt(key)
  local entry = self.places[key:id()]
  return entry and entry.xpTotal or 0
end

function LevelRecord:xpAtFrom(key, source)
  local entry = self.places[key:id()]
  return entry and entry.xpBySource[source] or 0
end

-- Everything earned in places of one kind: "how much of this level came from
-- dungeons", answerable without naming a single one of them because the kind
-- travels inside the key.
function LevelRecord:xpByContext(context)
  local total = 0
  for _, entry in pairs(self.places) do
    if entry.key.context == context then
      total = total + entry.xpTotal
    end
  end
  return total
end

-- Whether this level can answer the crossed question at all. Structural, not
-- arithmetic: a place the player only walked through has an empty breakdown and
-- that is a correct answer, while a record written before the joint was kept has
-- experience with an empty breakdown, which is not. Asking "does any entry name a
-- source" separates them; asking "does anything add up" does not.
function LevelRecord:hasPlaceSources()
  for _, entry in pairs(self.places) do
    if next(entry.xpBySource) ~= nil then
      return true
    end
  end
  return false
end

-- The other half of the invariant, and the one that says the second dimension was
-- built correctly: every point of experience is counted once by source and once by
-- place, so the two sums are the same number.
--
-- Records restored from a version that did not track places are the exception and
-- deliberately so: they hold no entries at all rather than a made-up unknown one,
-- so this answers zero for them and the caller checks `hasPlaces` first.
function LevelRecord:sumOfPlaces()
  local total = 0
  for _, entry in pairs(self.places) do
    total = total + entry.xpTotal
  end
  return total
end

function LevelRecord:hasPlaces()
  return next(self.places) ~= nil
end

-- The time dimension's half of the same idea.
--
-- Every point of experience that cannot be attributed lands in an explicit
-- bucket rather than disappearing, which is why the experience sums balance to
-- the unit. Time has no such bucket: the seconds measured against places fall
-- short of the seconds played, because none of this runs during loading screens,
-- and unaccountedSeconds below reports that gap.
--
-- Derived, never accumulated. Both operands already live in the record, so this
-- cannot drift away from them the way a third counter kept alongside would.
function LevelRecord:sumOfPlaceSeconds()
  local total = 0
  for _, entry in pairs(self.places) do
    total = total + entry.seconds
  end
  return total
end

-- Nil, not zero, when it cannot be known. Zero is a claim -- "all of it was
-- measured" -- and a level that never received the server's figure, or that was
-- written before places were tracked at all, cannot make it.
--
-- Floored at zero. A negative difference is not a smaller amount of time, it is
-- a broken anchor; `timeUnderflowed` is how that gets noticed instead of being
-- presented as if it were time.
function LevelRecord:unaccountedSeconds()
  if not self.timeAnchored or not self:hasPlaces() then
    return nil
  end
  return math.max(0, self.playedSeconds - self:sumOfPlaceSeconds())
end

-- The server's figure landing after time had already been accumulated against
-- places. Not shown to the player; it exists for diagnostics, so a level never
-- silently claims it measured everything.
function LevelRecord:timeUnderflowed()
  if not self.timeAnchored or not self:hasPlaces() then
    return false
  end
  return self.playedSeconds < self:sumOfPlaceSeconds()
end

-- The experience the client could actually put somewhere, which is not the same
-- number as sumOfPlaces: the reserved entry is a place in the ledger's arithmetic
-- (that is what keeps the two dimensions equal) and the absence of one to a
-- reader. Conflating them would print "1000 of 1000 experience placed" directly
-- above "with no place the client could name: 1000 (100%)".
function LevelRecord:placedXp()
  return self:sumOfPlaces() - self:xpAt(ns.core.PlaceKey.unknown())
end

function LevelRecord:totalKills()
  return self.killsWithXp + self.killsWithoutXp
end

-- How much of the killing was wasted effort. Nil rather than zero with no kills at
-- all: "none of your kills were wasted" and "you killed nothing" are different
-- answers, and only one of them is true for a level spent doing quests.
--
-- And nil on a level recorded without the combat log: the kills that paid
-- nothing are counted from its deaths, so the ratio would be built on some of them.
function LevelRecord:unproductiveKillRatio()
  if self.unavailable[RecordedSource.COMBAT_LOG] ~= nil then
    return nil
  end
  local total = self:totalKills()
  if total == 0 then
    return nil
  end
  return self.killsWithoutXp / total
end

-- ---------------------------------------------------------------------------
-- Combat efficiency -- derived, not accumulated. Out-of-combat time is derived
-- here too, the same way: playedSeconds minus combatSeconds, rather than a third
-- counter CombatTimeCollector would have to keep in sync with the other two.
-- ---------------------------------------------------------------------------

function LevelRecord:combatSeconds()
  local metrics = self.metrics[MetricId.TIME]
  return metrics and metrics.combatSeconds or 0
end

function LevelRecord:recoverySeconds()
  local metrics = self.metrics[MetricId.TIME]
  return metrics and metrics.recoverySeconds or 0
end

function LevelRecord:outOfCombatSeconds()
  return math.max(0, self.playedSeconds - self:combatSeconds())
end

function LevelRecord:deathCount()
  local metrics = self.metrics[MetricId.DEATHS]
  return metrics and metrics.count or 0
end

function LevelRecord:timeLostToDeath()
  local metrics = self.metrics[MetricId.DEATHS]
  return metrics and metrics.timeLostToDeath or 0
end

-- Nil with no combat time at all, so it is reported as unavailable instead of
-- producing an error: a level spent entirely on quests has nothing to divide by.
function LevelRecord:xpPerCombatMinute()
  local seconds = self:combatSeconds()
  if seconds <= 0 then
    return nil
  end
  return self.xpTotal / (seconds / 60)
end

-- Experience from kills specifically, divided by kills that paid something -- not
-- the level's total xp (which mixes in quests and exploration) and not total
-- kills (which would count the unproductive ones as diluting the average, when
-- they contributed nothing to it either way).
function LevelRecord:averageXpPerKill()
  if self.killsWithXp <= 0 then
    return nil
  end
  return self:xpFrom(XpSource.MOB_KILL) / self.killsWithXp
end

-- How one creature's aggregate is indexed: the creature, and how many the kill's
-- experience was split between. The group size is part of the key rather than a
-- number kept inside a single bucket, because a bucket holding kills paid at two
-- group sizes averages them, and once added together they cannot be told apart.
--
-- A context nobody counted gets `?`, and that is deliberately not the key a group
-- of one gets: playing alone is a measurement, and the absence of one is not.
local UNCOUNTED = "?"

function LevelRecord.creatureId(key, sharedBy)
  return ("%s@%s"):format(key:id(), sharedBy and tostring(sharedBy) or UNCOUNTED)
end

-- ---------------------------------------------------------------------------
-- The serialization boundary
--
-- Saved variables hold plain data and drop metatables without a word, so a record
-- crosses this line in both directions rather than being handed over as it is. Two
-- shapes differ from the live model on purpose:
--
--   * The per-source and per-modifier totals leave out their zeroes, and restore
--     zeroes the whole enumeration first. Adding a source in a future version then
--     costs no migration -- it simply reads as zero on every record written before
--     it existed.
--   * Creatures, quests, abilities and gains are written as packed text rather than
--     as the maps they are in memory. The client spends about forty-five bytes on
--     every line it writes, and a gain written a field to a line costs about 210 of
--     them against 22 packed -- across a run from one to seventy that is the
--     difference between four megabytes and under one, and what makes keeping
--     every level's full detail affordable.
-- ---------------------------------------------------------------------------

local function nonZero(totals)
  local kept
  for key, amount in pairs(totals) do
    if amount ~= 0 then
      kept = kept or {}
      kept[key] = amount
    end
  end
  return kept
end

-- The group size goes before the key, not after it. The key is three fields of
-- which the last two are routinely absent, and trailing empties are dropped, so
-- "after the key" is not a position at all: an unidentified creature writes two
-- fields and a named one writes five. Position is identity in this format, so a
-- new field can only live ahead of that variable-length tail -- which is why
-- schema step 3 -> 4 converts rather than defaults (see SchemaVersion).
local function packCreature(bucket)
  local fields = { bucket.kills, bucket.xpTotal, bucket.sharedBy or false }
  for _, value in ipairs(bucket.key:fields()) do
    fields[#fields + 1] = value
  end
  return Packed.join(fields)
end

local function unpackCreature(fields)
  -- An unknown creature is a legitimate aggregate, so the creature's own fields
  -- cannot say whether this record means anything. The kill count can: every
  -- aggregate has at least one.
  if Packed.number(fields, 1) == nil then
    return nil
  end

  local key = ns.core.CreatureKey.fromFields(fields, 4)
  return {
    key = key,
    -- Blank is unknown and never one: it is what the migration writes for every
    -- bucket recorded before the group was counted, and reading it as solo would
    -- invent an observation nobody made.
    sharedBy = Stored.positiveInteger(Packed.number(fields, 3)),
    kills = Stored.count(Packed.number(fields, 1), 0),
    xpTotal = Stored.count(Packed.number(fields, 2), 0),
  }
end

-- A place entry: what it paid, how long the player was there, the key, and then
-- the breakdown of that experience by source as (source, amount) pairs.
--
-- Both leading numbers are written blank when they are zero, which is the common
-- case for one of the two -- a zone walked through pays nothing, a dungeon cleared
-- in one sitting is the only place time was spent -- and a blank field costs one
-- byte.
--
-- The tail is pairs rather than one column per source for the same reason the
-- record's own per-source totals are a map and not a list (see the serialization
-- header): a source added in a future version then costs no migration, it simply
-- is not mentioned by any line written before it existed. Columns would make the
-- position the meaning, so inserting a source anywhere but the end would silently
-- re-read every place ever written. The pairs are walked in the
-- enumeration's own sorted order so the same record writes the same line twice.
local function packPlace(entry)
  local fields = {
    Packed.blankIf(entry.xpTotal, 0),
    entry.seconds > 0 and ("%.1f"):format(entry.seconds) or false,
  }
  for _, value in ipairs(entry.key:fields()) do
    fields[#fields + 1] = value
  end
  for _, source in Frozen.each(XpSource) do
    local amount = entry.xpBySource[source]
    if amount ~= nil and amount > 0 then
      fields[#fields + 1] = source
      fields[#fields + 1] = amount
    end
  end
  return Packed.join(fields)
end

local function unpackPlaceSources(fields)
  local bySource = {}
  -- Read in pairs from field 6 on. An odd tail, or a source this version cannot
  -- read, is skipped rather than folded somewhere plausible: the breakdown is a
  -- refinement of `xpTotal`, which is stored separately and stays authoritative,
  -- so an unreadable piece of it costs the crossed reading and nothing else.
  local index = 6
  while true do
    local amount = Stored.count(Packed.number(fields, index + 1), nil)
    if amount == nil then
      -- No readable amount means the pair boundary itself is unknown, and
      -- resynchronising from there would be guessing. This is also how the tail
      -- ends, which is why it is the only condition that stops the walk.
      return bySource
    end

    local source = Stored.member(XpSource, Packed.text(fields, index), nil)
    if source ~= nil then
      bySource[source] = (bySource[source] or 0) + amount
    end
    -- A source this version cannot read is skipped, not abandoned along with
    -- everything behind it. The pairs encoding exists so a future source costs no
    -- migration, and `packPlace` writes them in the enumeration's sorted order --
    -- so a new source can land in the middle of the tail, and stopping at it would
    -- wipe every pair an older build could still read, then write the loss back
    -- to disk at the next logout.
    index = index + 2
  end
end

local function unpackPlace(fields)
  -- The key alone cannot say whether this is a record: an unknown place is a
  -- legitimate entry, so its fields read the same as a line that was never written.
  -- What the entry is for can: an entry with neither experience nor time in it
  -- says nothing that the level did not already say by not mentioning the place.
  if Packed.number(fields, 1) == nil and Packed.number(fields, 2) == nil then
    return nil
  end

  return {
    key = ns.core.PlaceKey.fromFields(fields, 3),
    xpTotal = Stored.count(Packed.number(fields, 1), 0),
    seconds = math.max(0, Stored.number(Packed.number(fields, 2), 0)),
    -- Empty for a line written before the joint was kept, which is exactly how a
    -- reader tells that apart from a place that earned nothing.
    xpBySource = unpackPlaceSources(fields),
  }
end

local function packQuest(bucket)
  return Packed.join({ bucket.questId, bucket.turnIns, bucket.xpTotal })
end

local function unpackQuest(fields)
  local questId = Stored.positiveInteger(Packed.number(fields, 1))
  if questId == nil then
    return nil
  end
  return {
    questId = questId,
    turnIns = Stored.count(Packed.number(fields, 2), 0),
    xpTotal = Stored.count(Packed.number(fields, 3), 0),
  }
end

-- The only key of `metrics` that ever holds a live object: every other collector
-- writes a plain table straight into its own slot, so `Stored.plainCopy` reaches
-- those untouched. This swaps the live CombatSummary for its toStored() so
-- plainCopy never meets its metatable and raises.
local function packMetrics(metrics)
  local sanitized = {}
  for key, value in pairs(metrics) do
    if key == MetricId.COMBAT_OUTCOME then
      sanitized[key] = value:toStored()
    else
      sanitized[key] = value
    end
  end
  return Stored.plainCopy(sanitized, "metrics")
end

local function unpackMetrics(stored)
  local fields = Stored.plainRead(Stored.table(stored) or {}) or {}
  if fields[MetricId.COMBAT_OUTCOME] ~= nil then
    fields[MetricId.COMBAT_OUTCOME] = CombatSummary.restore(fields[MetricId.COMBAT_OUTCOME]) or CombatSummary.new()
  end
  return fields
end

function LevelRecord:toStored()
  return {
    level = self.level,
    startedAt = self.startedAt,
    completedAt = self.completedAt,

    playedSeconds = self.playedSeconds,
    sessions = self.sessions,
    lastSeenAt = self.lastSeenAt,

    xpTotal = self.xpTotal,
    xpRequired = self.xpRequired,
    xpBySource = nonZero(self.xpBySource),
    xpByModifier = nonZero(self.xpByModifier),

    killsWithXp = self.killsWithXp,
    killsWithoutXp = self.killsWithoutXp,

    creatures = Packed.set(self.creatures, packCreature),
    quests = Packed.set(self.quests, packQuest),
    places = Packed.set(self.places, packPlace),
    abilities = Packed.set(self.abilities, function(usage) return usage:toStored() end),
    gains = Packed.list(self.gains, function(gain) return gain:toStored() end),

    -- A metric collector's state has to end up plain data. packMetrics only
    -- substitutes the one key (COMBAT_OUTCOME) that legitimately holds a live
    -- object; everything else still raises through Stored.plainCopy if a
    -- collector hands this a metatable by mistake, because the file would
    -- otherwise swallow that bug silently and hand back half a record next login.
    metrics = packMetrics(self.metrics),

    partial = self.partial,
    seededXp = self.seededXp,
    timeAnchored = self.timeAnchored,
    -- Absent rather than an empty table when nothing was missing, which is every
    -- level a classic client records: the file is one line per level shorter.
    unavailable = next(self.unavailable) ~= nil and Stored.plainCopy(self.unavailable, "unavailable") or nil,
  }
end

-- The sources must add up to the level's total, and a file the player can edit --
-- or a logout cut off halfway -- can arrive disagreeing with itself. The
-- disagreement is absorbed the same way a live gain nobody could explain is: into
-- UNKNOWN. When the breakdown claims more than the total, the breakdown is the
-- more detailed record of the two and the total yields.
local function reconcile(record)
  local difference = record.xpTotal - record:sumOfSources()
  if difference == 0 then
    return
  end

  local unknown = record.xpBySource[XpSource.UNKNOWN] + difference
  if unknown < 0 then
    record.xpBySource[XpSource.UNKNOWN] = 0
    record.xpTotal = record:sumOfSources()
  else
    record.xpBySource[XpSource.UNKNOWN] = unknown
  end
end

function LevelRecord.restore(stored)
  local fields = Stored.table(stored)
  if fields == nil then
    return nil
  end

  -- Without a level there is no record: it is the key the whole history is filed
  -- under, and no default for it would be anything but an invention.
  local level = Stored.positiveInteger(fields.level)
  if level == nil then
    return nil
  end

  local record = LevelRecord.new(level, Stored.number(fields.startedAt, 0))

  record.completedAt = Stored.number(fields.completedAt, nil)
  -- Seconds, not a count: this is a sum of clock differences and is routinely
  -- fractional, so the integer reader would have silently zeroed every level.
  record.playedSeconds = math.max(0, Stored.number(fields.playedSeconds, 0))
  record.sessions = math.max(1, Stored.count(fields.sessions, 1))
  record.lastSeenAt = Stored.number(fields.lastSeenAt, nil)

  record.xpTotal = Stored.count(fields.xpTotal, 0)
  record.xpRequired = Stored.positiveInteger(fields.xpRequired)

  local bySource = Stored.table(fields.xpBySource) or {}
  for _, source in Frozen.each(XpSource) do
    record.xpBySource[source] = Stored.count(bySource[source], 0)
  end
  local byModifier = Stored.table(fields.xpByModifier) or {}
  for _, modifier in Frozen.each(XpModifier) do
    record.xpByModifier[modifier] = Stored.count(byModifier[modifier], 0)
  end
  reconcile(record)

  record.killsWithXp = Stored.count(fields.killsWithXp, 0)
  record.killsWithoutXp = Stored.count(fields.killsWithoutXp, 0)

  for _, bucket in ipairs(Packed.unlist(fields.creatures, unpackCreature)) do
    record.creatures[LevelRecord.creatureId(bucket.key, bucket.sharedBy)] = bucket
  end
  for _, bucket in ipairs(Packed.unlist(fields.quests, unpackQuest)) do
    record.quests[bucket.questId] = bucket
  end
  -- A record written before places existed has no `places` field, and comes back
  -- with none: no reserved entry is invented for it. Attributing its experience to
  -- an unknown place would claim the addon tried to record where it was earned and
  -- could not, when it never tried.
  --
  -- Merged rather than assigned, because two stored lines can legitimately arrive
  -- as the same place: `PlaceKey.fromFields` collapses every line it cannot fully
  -- read onto the one reserved entry, so a file holding two unreadable places has
  -- two lines and one key. Assigning would silently delete the first one's
  -- experience and time.
  for _, entry in ipairs(Packed.unlist(fields.places, unpackPlace)) do
    local target = record:placeEntry(entry.key)
    target.xpTotal = target.xpTotal + entry.xpTotal
    target.seconds = target.seconds + entry.seconds
    for source, amount in pairs(entry.xpBySource) do
      target.xpBySource[source] = (target.xpBySource[source] or 0) + amount
    end
  end
  for _, usage in ipairs(Packed.unlist(fields.abilities, function(_, text)
    return AbilityUsage.restore(text)
  end)) do
    record.abilities[usage.key] = usage
  end

  record.gains = Packed.unlist(fields.gains, function(_, text)
    return XpGain.restore(text)
  end)

  -- A gain writes down which creature paid it but not what that creature is called:
  -- the name is display-only and the same for every gain from the same creature, so
  -- it is stored once in that creature's aggregate. This is where it goes back.
  --
  -- By the aggregate's own key, group size included: the gain and the bucket were
  -- written by the same posting and therefore share a context, and looking the
  -- creature up without it would find whichever population the hash happened to
  -- reach first -- or none at all, in silence, leaving every restored gain nameless.
  for _, gain in ipairs(record.gains) do
    if gain.creature ~= nil then
      local bucket = record.creatures[LevelRecord.creatureId(gain.creature, gain.sharedBy)]
      if bucket ~= nil then
        gain.creature.name = bucket.key.name
      end
    end
  end
  record.metrics = unpackMetrics(fields.metrics)

  record.partial = Stored.flag(fields.partial, false)
  -- No default on purpose: absent stays absent (see the field's note above).
  record.seededXp = Stored.count(fields.seededXp, nil)
  record.timeAnchored = Stored.flag(fields.timeAnchored, false)
  -- Only the sources this build knows, with a reason it can print. A file from a
  -- newer build that tracks a third source keeps its level; it just loses a mark
  -- this one could not show anyway.
  local unavailable = Stored.table(fields.unavailable) or {}
  local known = {}
  for _, reason in Frozen.each(SourceState) do
    known[reason] = true
  end
  for _, source in Frozen.each(RecordedSource) do
    local reason = unavailable[source]
    if known[reason] then
      record.unavailable[source] = reason
    end
  end

  return record
end

ns.core.LevelRecord = LevelRecord
