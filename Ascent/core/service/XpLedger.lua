-- Ascent - posting attributed experience into the level history.
--
-- One entry point, because two rules must hold at once and pull in opposite
-- directions when a gain lands on a level boundary:
--
--   * A level's per-source totals add up to exactly what it required. A gain that
--     fills the level is split: the closing level takes what it was missing, the
--     remainder opens the next one, and both halves keep the source.
--
--   * The creature and quest aggregates answer "what does a Kobold Miner pay", a
--     fact about the creature, not about where the boundary fell. They are
--     credited once, in full, to the level the gain started in; splitting them
--     would skew every average across a level-up and leave the new level with
--     experience in a creature bucket and no kill to divide by.
--
-- The place, by contrast, is split with the experience: "where did this level's
-- experience come from" is a question about the level.
--
-- One gain is one kill. That holds because XpAttribution consumes an announcement
-- exactly once and emits one gain for it; a creature's experience emitted in two
-- pieces would count as two kills and halve its average.
--
-- The ledger owns no clock and announces nothing. Closing a level and announcing it
-- belongs to whoever passes `nextLevel`.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local XpModifier = ns.core.XpModifier
local PlaceKey = ns.core.PlaceKey
local CreatureKey = ns.core.CreatureKey
local LevelRecord = ns.core.LevelRecord

local XpLedger = {}

local MODIFIERS = {}
for _, modifier in Frozen.each(XpModifier) do
  MODIFIERS[#MODIFIERS + 1] = modifier
end

-- What the level still has room for, or nil while the client has not reported the
-- requirement; until then nothing is split and everything accumulates.
function XpLedger.headroom(record)
  if record.xpRequired == nil then
    return nil
  end

  local left = record.xpRequired - record.xpTotal
  if left < 0 then
    return 0
  end
  return left
end

local function applyXp(record, gain, place)
  if gain.amount == 0 then
    return
  end

  record.xpTotal = record.xpTotal + gain.amount
  record.xpBySource[gain.source] = (record.xpBySource[gain.source] or 0) + gain.amount

  -- Every point is counted once by source and once by place, split halves included,
  -- so the two sums are equal by construction. An unplaced gain lands in the
  -- reserved entry, as an unexplained one lands in UNKNOWN.
  local entry = record:placeEntry(place or PlaceKey.unknown())
  entry.xpTotal = entry.xpTotal + gain.amount
  -- And the joint of the two, which neither marginal can give back. Accumulated
  -- here because an aggregate not accumulated cannot be reconstructed later.
  entry.xpBySource[gain.source] = (entry.xpBySource[gain.source] or 0) + gain.amount

  for index = 1, #MODIFIERS do
    local modifier = MODIFIERS[index]
    local amount = gain:modifierAmount(modifier)
    if amount ~= 0 then
      record.xpByModifier[modifier] = (record.xpByModifier[modifier] or 0) + amount
    end
  end

  record.gains[#record.gains + 1] = gain
end

local function aggregateCreature(record, gain)
  -- A creature killed in a party of five and killed alone pays different amounts,
  -- and one average over both describes neither. The group size indexes the
  -- aggregate so the two are never summed; a single total could not be split later.
  local id = LevelRecord.creatureId(gain.creature, gain.sharedBy)
  local bucket = record.creatures[id]
  if bucket == nil then
    -- A key with no npcId is not a creature: it is every death the combat log
    -- could not identify, sharing one entry, and the name is outside the identity.
    -- So the name is dropped here; keeping the first arrival's would label the
    -- shared entry as one specific creature in the panel.
    local key = gain.creature
    if not key:hasKnownType() then
      key = CreatureKey.unknown(nil)
    end
    -- Carried on the bucket as well as in its id: the stored form is what the
    -- key is rebuilt from, and nothing else records the group size.
    bucket = { key = key, sharedBy = gain.sharedBy, kills = 0, xpTotal = 0 }
    record.creatures[id] = bucket
  end

  bucket.kills = bucket.kills + 1
  bucket.xpTotal = bucket.xpTotal + gain.amount
  -- The level's counter, one per gain whatever the bucket, so splitting buckets by
  -- group size leaves the level's average per kill unchanged.
  record.killsWithXp = record.killsWithXp + 1
end

local function aggregateQuest(record, gain)
  local bucket = record.quests[gain.questId]
  if bucket == nil then
    bucket = { questId = gain.questId, turnIns = 0, xpTotal = 0 }
    record.quests[gain.questId] = bucket
  end

  bucket.turnIns = bucket.turnIns + 1
  bucket.xpTotal = bucket.xpTotal + gain.amount
end

-- Posts a gain. `nextLevel(filledRecord)` is called each time the gain fills the
-- level and returns the record for the level that opens; closing the old level
-- belongs there. Returns the record the remainder landed in.
--
-- `place` is where the experience was earned, read at the delta, not the
-- announcement. It follows the experience across a boundary like the source (head
-- to the closing level, tail to the opening one), so the two dimensions agree.
--
-- `nextLevel` may answer nil, meaning no level follows: a character reaching the
-- client's maximum. Posting stops and the rest is dropped, which is correct: a
-- character at the cap is granted no experience beyond it.
function XpLedger.post(record, gain, nextLevel, place)
  if gain.creature ~= nil then
    aggregateCreature(record, gain)
  end
  if gain.questId ~= nil then
    aggregateQuest(record, gain)
  end

  local remaining = gain
  while remaining.amount > 0 do
    local headroom = XpLedger.headroom(record)
    if headroom == nil or remaining.amount < headroom then
      applyXp(record, remaining, place)
      return record
    end

    -- The gain reaches the end of this level; exactly filling it counts. A level
    -- left open at 100% would be saved as in progress by a logout here, and the
    -- next gain would find no room in it.
    if nextLevel == nil then
      error(("XpLedger: the gain completes level %s and no way to open the next one was given")
        :format(tostring(record.level)), 2)
    end
    if record.xpRequired <= 0 then
      error(("XpLedger: level %s requires no experience, so nothing can be posted into it")
        :format(tostring(record.level)), 2)
    end

    local head, tail = remaining:splitAt(headroom)
    applyXp(record, head, place)

    local opened = nextLevel(record)
    if opened == nil then
      return record
    end

    record = opened
    remaining = tail
  end

  return record
end

-- A creature died and paid nothing. Counted apart from paying kills: the ratio tells
-- a player they are killing creatures too low to pay.
function XpLedger.countUnrewardedKill(record)
  record.killsWithoutXp = record.killsWithoutXp + 1
  return record.killsWithoutXp
end

ns.core.XpLedger = XpLedger
