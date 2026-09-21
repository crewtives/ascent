-- Ascent - posting attributed experience into the level history.
--
-- One entry point, because two rules have to hold at once and they pull in opposite
-- directions when a gain lands on a level boundary:
--
--   * The per-source totals of a level must add up to exactly what that level
--     required. A gain that fills the level is split, the closing level takes
--     precisely what it was missing, the remainder opens the next one, and both
--     halves keep the source.
--
--   * The creature and quest aggregates answer "what does a Kobold Miner pay",
--     which is a fact about the creature and not about where the boundary happened
--     to fall. They are credited once, in full, to the level the gain started in.
--
-- Splitting the aggregates the way the totals are split would make every average
-- that straddles a level-up quietly wrong, and would leave the new level holding a
-- creature bucket with experience in it and no kill to divide by.
--
-- The same asymmetry decides the place, and in the opposite direction from the
-- creature: it IS split with the experience. "Where did this level's experience
-- come from" is a question about the level, so the half that filled the old level
-- belongs to the old level -- unlike "what does a Kobold Miner pay", which is a
-- fact about the creature and does not care where the boundary fell.
--
-- One gain is one kill. The ledger counts a creature every time it is handed a gain
-- that names one, which is only correct because the attribution service consumes an
-- announcement exactly once and therefore emits exactly one gain for it. Anything
-- that ever emits a creature's experience in two pieces would be counted as two
-- kills here, halving that creature's average with nothing to show for it.
--
-- The ledger owns no clock and announces nothing. Closing a level and telling the
-- rest of the addon about it belongs to whoever passes `nextLevel`.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local XpModifier = ns.core.XpModifier
local PlaceKey = ns.core.PlaceKey
local CreatureKey = ns.core.CreatureKey

local XpLedger = {}

local MODIFIERS = {}
for _, modifier in Frozen.each(XpModifier) do
  MODIFIERS[#MODIFIERS + 1] = modifier
end

-- What the level still has room for, or nil while the requirement is unknown. The
-- client is what tells the addon how much a level costs; until it has, nothing can
-- be split and everything simply accumulates.
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

  -- Every point counted once by source and once by place, including the halves a
  -- level boundary split: that is what makes the two sums the same number rather
  -- than two numbers that usually agree. A gain nobody could place lands in the
  -- reserved entry for the same reason one nobody could explain lands in UNKNOWN --
  -- leaving it out of the second dimension would break the invariant in silence.
  local entry = record:placeEntry(place or PlaceKey.unknown())
  entry.xpTotal = entry.xpTotal + gain.amount
  -- And the joint of the two, which is the one thing neither marginal can give
  -- back afterwards. Credited here rather than derived later for the reason D44
  -- gives about aggregates: a field can be added to a gain at any time, but an
  -- aggregate that was not accumulated cannot be reconstructed.
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
  local id = gain.creature:id()
  local bucket = record.creatures[id]
  if bucket == nil then
    -- A bucket whose key has no npcId is not a creature. It is every death the
    -- combat log could not identify, sharing one entry on purpose -- the model says
    -- an unknown bucket is honest, and the name is deliberately outside the identity
    -- so it cannot split that entry back apart.
    --
    -- Which is exactly why the name has to be dropped here. Keeping the first
    -- arrival's would dress the shared entry up as one specific creature, and the
    -- panel prints that name beside the kills and experience of everything else in
    -- it. Honest bucket, dishonest label. Dropping it in the view instead would
    -- leave the aggregate itself holding a claim it cannot support.
    local key = gain.creature
    if not key:hasKnownType() then
      key = CreatureKey.unknown(nil)
    end
    bucket = { key = key, kills = 0, xpTotal = 0 }
    record.creatures[id] = bucket
  end

  bucket.kills = bucket.kills + 1
  bucket.xpTotal = bucket.xpTotal + gain.amount
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

-- Post a gain. `nextLevel(filledRecord)` is called each time the gain fills the
-- level and returns the record for the level that opens; it is where closing the old
-- level belongs. Returns the record the remainder landed in.
--
-- `place` is where the experience was earned, read at the instant of the delta and
-- not of the announcement (D43). It follows the experience across a level boundary
-- exactly as the source does -- the closing level keeps the head, the opening one
-- the tail -- which is the only way the two dimensions can keep agreeing on a gain
-- that straddles a level-up.
--
-- `nextLevel` may answer nil, meaning there is no level after this one -- the only
-- caller that says so is a character reaching the client's maximum. Posting stops
-- there and whatever is left is dropped, which is correct rather than lossy: a
-- character at the cap is granted no experience beyond it, so there is nothing real
-- for the discarded remainder to correspond to.
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

    -- The gain reaches the end of this level. Exactly filling it counts as reaching
    -- it: leaving a level open at a hundred percent would mean a logout right here
    -- saved a finished level as the one in progress, and the next gain would find a
    -- record with no room in it.
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

-- A creature died and paid nothing. Counted separately from the kills that did pay,
-- because the ratio between them is what tells a player they are grinding mobs
-- their level has left behind.
function XpLedger.countUnrewardedKill(record)
  record.killsWithoutXp = record.killsWithoutXp + 1
  return record.killsWithoutXp
end

ns.core.XpLedger = XpLedger
