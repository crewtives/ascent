-- Ascent - reconciling what was earned with what announced it.
--
-- The one rule this whole addon rests on: the amount is authoritative and the
-- source is a claim. The amount comes from the difference between two readings of
-- the player's experience, which is the only figure the client guarantees. The
-- source arrives separately, on channels that are late, duplicated, ambiguous or
-- absent, and no channel is ever allowed to add experience to the record.
--
--   delta   44 at t=10.0            <- authoritative, from UnitXP
--   hint    "Kobold Miner dies,     <- a claim: mob kill, 44, around t=10.0
--            you gain 44 experience"
--
-- Each hint is consumed bounded by min(announced, remaining), so the same gain
-- announced on two channels adds up once and no channel can inflate the level.
-- Whatever no hint claims is attributed to UNKNOWN rather than dropped, which is
-- what makes the sources add up to exactly the level total.
--
-- Four properties, each of which cost a defect to learn:
--
--   * The window is BIDIRECTIONAL. Whether a hint arrives before or after its delta
--     is not verified for 1.15.x or 2.5.x -- there is no public trace, note or
--     comment that documents it. A queue would be right for one order and silently
--     wrong for the other. Spike 0.1 measures it; until then this is immune to both.
--
--   * NOTHING IS DECIDED WITH INCOMPLETE INFORMATION. A delta is buffered on arrival
--     and attributed TWO windows later, not one. One window is when the last hint
--     that could be about it arrives; two is when that hint's own window has closed,
--     so the delta it was really announcing has arrived too. Deciding earlier is not
--     a free optimisation, and it fails in both directions: settle at the first hint
--     that fills the delta and the channel carrying the quest id, milliseconds
--     behind the one that does not, arrives to find nothing left; settle one window
--     in and a hint is judged against deltas that have not been seen yet. The cost
--     is a bounded lag on the breakdown, and it collapses to nothing once spike 0.1
--     says which order the client uses.
--
--   * MATCHING IS BY AMOUNT, not merely by time. A hint whose announced figure is
--     exactly what a delta still needs is taken first, and a hint is never fed to a
--     delta it does not fit while a delta it fits exactly is still waiting -- which
--     is a sound test only because of the paragraph above. Without it, an
--     unexplained delta sitting in the window swallows the front of the next kill's
--     announcement and the kill gets counted twice, once per fragment.
--
--     Among hints that fit equally well, the NEARER one wins and channel priority
--     only breaks a tie between hints at the same instant. Priority ranks the
--     channels of one announcement -- the turn-in event above its echo -- and says
--     nothing about two different gains, so letting it outrank time swaps a kill's
--     experience with a quest's whenever the two happen to pay the same.
--
--   * A HINT IS ONE ANNOUNCEMENT and is consumed at most once. Leaving the losing
--     copy of a twice-announced turn-in alive is how a mob kill ends up booked to
--     QUEST_TURNIN: the copy outranks the kill and is still holding its full amount.
--     Copies are retired against each other at intake instead.
--
-- The counters are the other half of honesty: unmatched deltas and unclaimed hints
-- are how the window gets tuned against real play instead of against intuition.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local Port = ns.core.Port
local XpGain = ns.core.XpGain
local XpSource = ns.core.XpSource
local CreatureKey = ns.core.CreatureKey
local EventTopic = ns.core.EventTopic
local RestedReading = ns.core.RestedReading

-- settle() waits out 2x this before committing a delta (below), so the window is
-- also the addon's visible lag on every kill. Tuned from a real client rather than
-- from intuition, per the comment above: a solo kill's hint arrived ~0.3s before
-- its delta (design.md's Open Question 1, still open for the reverse order and for
-- non-kill sources), so 0.75s leaves a healthy 2.5x margin on one sample while
-- halving the worst case from 3s to 1.5s. Still bidirectional, not a queue: one
-- clean sample confirms an order, it does not retire the case of it arriving late.
local DEFAULT_WINDOW = 0.75

local XpAttribution = {}
XpAttribution.__index = XpAttribution

-- The client's rested figure is twice the server's internal reserve, so a kill
-- drops it by twice the base experience -- and the bonus granted equals that base.
-- Halving the drop is therefore a reading of the bonus that owes nothing to the
-- wording of the chat message: a cross-check for spike 0.4 while the parenthetical
-- is ambiguous, and the fallback if it turns out to name the base. Bounded by the
-- announced total, because the last kill before the reserve empties pays a partial
-- bonus.
function XpAttribution.restedFromReserve(before, after, amount)
  if type(before) ~= "number" or type(after) ~= "number" then
    return nil
  end

  local drop = before - after
  if drop <= 0 then
    return 0
  end

  local bonus = math.floor(drop / 2)
  if amount ~= nil and bonus > amount then
    return amount
  end
  return bonus
end

function XpAttribution.new(options)
  options = options or {}

  if options.bus == nil then
    error("XpAttribution needs an event bus", 2)
  end
  if options.registry == nil then
    error("XpAttribution needs a classifier registry", 2)
  end
  Port.verify(ns.core.EventBusPort, options.bus, "XpAttribution bus")

  local window = options.window or DEFAULT_WINDOW

  local service = setmetatable({
    bus = options.bus,
    registry = options.registry,
    correlator = options.correlator,
    logger = options.logger,
    window = window,
    restedReading = options.restedReading or RestedReading.BONUS,

    deltas = {},
    hints = {},
    sequence = 0,

    counters = {
      unmatchedDeltas = 0,        -- experience that settled with no hint claiming it
      unclaimedHints = 0,         -- source hints that expired without finding a delta
      unclassifiedHints = 0,      -- hints on a channel no classifier recognises
      duplicateAnnouncements = 0, -- a gain announced on two source channels
      anonymousClaimed = 0,       -- amount-only lines a source hint accounted for
      anonymousUnclaimed = 0,     -- amount-only lines nothing claimed
      restedDisagreements = 0,    -- parsed bonus and reserve-derived bonus disagreed
    },
  }, XpAttribution)

  service.subscriptions = {
    options.bus:subscribe(EventTopic.XP_DELTA_OBSERVED, function(payload)
      service:observeDelta(payload)
    end),
    options.bus:subscribe(EventTopic.XP_HINT_RECEIVED, function(payload)
      service:observeHint(payload)
    end),
    options.bus:subscribe(EventTopic.CREATURE_DIED, function(payload)
      service:observeDeath(payload)
    end),
  }

  return service
end

-- ---------------------------------------------------------------------------
-- Intake
-- ---------------------------------------------------------------------------

-- payload: { amount, at, place }. The amount is the authoritative difference, with
-- any level crossing already folded into it by the adapter.
--
-- The place rides with the DELTA and not with the hint, which is D43 and is the
-- whole of it: the delta is the authoritative event, the hint can arrive up to a
-- window and a half either side of it, and a kill by the entrance of a dungeon
-- would otherwise be recorded in whichever of the two places the announcement
-- happened to catch. Carried through untouched, including nil -- a caller that
-- knows no place is not the same as one that read the reserved entry, and only the
-- ledger gets to decide what "nobody said" means.
function XpAttribution:observeDelta(payload)
  local amount = Guard.nonNegativeInteger(payload.amount, "XP delta amount")
  local at = Guard.number(payload.at, "XP delta at")

  if self.logger ~= nil then
    self.logger:debug(("delta arrived at %.3f: amount=%d"):format(at, amount))
  end

  if amount > 0 then
    self.deltas[#self.deltas + 1] = {
      at = at, amount = amount, remaining = amount, claims = {}, place = payload.place,
    }
  end

  self:settle(at)
end

-- payload: whatever the channel carried, plus `kind` and `at`. The classifiers
-- decide what any of it means.
function XpAttribution:observeHint(payload)
  local announced = Guard.nonNegativeInteger(payload.amount, "XP hint amount")
  local at = Guard.number(payload.at, "XP hint at")

  local classification = self.registry:classify(payload)
  if classification.classifierId == nil then
    self.counters.unclassifiedHints = self.counters.unclassifiedHints + 1
    if self.logger ~= nil then
      self.logger:debug(("hint unclassified at %.3f: kind=%s"):format(at, tostring(payload.kind)))
    end
    self:settle(at)
    return
  end

  self.sequence = self.sequence + 1
  local hint = {
    at = at,
    sequence = self.sequence,
    announced = announced,
    spent = false,
    claimed = false,
    source = classification.source,
    resolvesSource = classification.resolvesSource,
    amountOnly = classification.amountOnly,
    classifierId = classification.classifierId,
    priority = classification.priority,
    payload = classification.payload,
  }

  if self.logger ~= nil then
    self.logger:debug(("hint classified at %.3f: source=%s announced=%d resolvesSource=%s amountOnly=%s")
      :format(at, tostring(hint.source), announced, tostring(hint.resolvesSource), tostring(hint.amountOnly)))
  end

  self:linkDuplicate(hint)
  self.hints[#self.hints + 1] = hint

  self:settle(at)
end

-- payload: { name, npcId, level, at }, straight from the combat log.
function XpAttribution:observeDeath(payload)
  if self.correlator == nil then
    return
  end

  local death = self.correlator:recordDeath(payload)
  self:settle(death.at)
end

-- ---------------------------------------------------------------------------
-- One gain, one announcement
-- ---------------------------------------------------------------------------

-- The anonymous line carries the parenthetical and never names a source, so it can
-- never build a gain of its own. When it duplicates a kill announcement -- same
-- amount, same instant, one event -- the annotation belongs on that kill, and
-- dropping it was how a group kill announced without a creature name recorded a
-- bonus of zero.
--
-- Guarded three ways, and each guard answers a question the spec asks:
--
--   only a KILL, because the group bonus is a share of creature experience and a
--   quest turn-in has none -- adopting onto one would invent a bonus the client
--   never announced;
--
--   only an unspent anonymous copy, so one line annotates one gain;
--
--   and only when the named hint carries NEITHER modifier already. The
--   xp-attribution spec forbids a group bonus and a raid penalty on one gain, so
--   the named channel's own reading wins outright rather than being merged with
--   this one. Merging is what would produce that forbidden pair.
local function adoptModifiers(named, anonymous)
  if named.source ~= XpSource.MOB_KILL or anonymous.spent then
    return
  end

  local carried = anonymous.payload
  if carried == nil then
    return
  end
  local group, raid = carried.groupBonus or 0, carried.raidPenalty or 0
  if group <= 0 and raid <= 0 then
    return
  end

  local payload = named.payload
  if payload == nil then
    payload = {}
    named.payload = payload
  end
  if (payload.groupBonus or 0) > 0 or (payload.raidPenalty or 0) > 0 then
    return
  end

  payload.groupBonus = group > 0 and group or nil
  payload.raidPenalty = raid > 0 and raid or nil
end

-- The client announces the same gain more than once. Quest experience arrives on
-- both QUEST_TURNED_IN and the system echo -- verified -- and on the anonymous
-- experience line as well. Retiring the copies against each other at intake is what
-- makes the design's claim literally true: the second copy sums zero.
--
-- Two copies are the same announcement when they say the same amount inside the
-- same window and come from DIFFERENT channels. That last condition is load-bearing:
-- two kills worth the same experience a second apart both come from the kill
-- channel, and collapsing them would lose one.
function XpAttribution:linkDuplicate(incoming)
  for index = 1, #self.hints do
    local other = self.hints[index]

    if other.announced == incoming.announced
      and math.abs(other.at - incoming.at) <= self.window then

      if other.amountOnly ~= incoming.amountOnly then
        -- One of the two is the anonymous line. It never names a source, so the
        -- other one accounts for it and it is retired as a matter of record: the
        -- count of claimed versus unclaimed lines is how the addon can answer
        -- whether discoveries emit this line, which no public source says.
        if incoming.amountOnly then
          incoming.claimed = true
          adoptModifiers(other, incoming)
        else
          other.claimed = true
          adoptModifiers(incoming, other)
        end

      elseif not other.amountOnly and other.source == incoming.source
        and other.classifierId ~= incoming.classifierId
        and not other.duplicate and not incoming.duplicate then
        -- `duplicate` is a separate mark from `spent`, and the difference matters.
        -- A retired copy is spent without having paid for anything, so reading
        -- `spent` alone as "this one already paid" retires the next real turn-in of
        -- the same reward against the previous one's echo -- two quests worth 250
        -- inside a second and a half become one.
        local redundant, reason
        if other.spent then
          redundant, reason = incoming, "echo"  -- the other copy already paid; this is the echo
        elseif other.priority >= incoming.priority then
          redundant, reason = incoming, "priority tie"
        else
          redundant, reason = other, "priority tie"
        end
        redundant.claimed = true
        redundant.spent = true
        redundant.duplicate = true
        self.counters.duplicateAnnouncements = self.counters.duplicateAnnouncements + 1
        if self.logger ~= nil then
          self.logger:debug(("duplicate retired at %.3f: source=%s amount=%d reason=%s")
            :format(redundant.at, tostring(redundant.source), redundant.announced, reason))
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

-- Whether a hint accounts for exactly what this delta still needs. This is the
-- design's "matching by amount", and it is what keeps a hint with a delta of its own
-- from being eaten by an older one that happens to still be open.
local function fits(hint, delta)
  return hint.announced == delta.remaining
end

-- Is some delta still waiting that this hint accounts for exactly? If so the hint
-- belongs to that one, and handing a fragment of it to the delta being settled would
-- split one kill into two gains -- two entries in the creature's aggregate for a
-- creature that died once.
function XpAttribution:fitsAPendingDelta(hint)
  for index = 1, #self.deltas do
    local delta = self.deltas[index]
    if delta.remaining == hint.announced
      and math.abs(delta.at - hint.at) <= self.window then
      return true
    end
  end
  return false
end

-- The best hint still available for this delta, or nil. Scanned rather than sorted:
-- the ranking depends on how much of the delta is left, which changes as hints are
-- taken, and a linear scan over a handful of hints is both cheaper and free of
-- table.sort's requirement that the comparator be a strict weak ordering.
function XpAttribution:bestHintFor(delta)
  local best, bestExact, bestDistance

  for index = 1, #self.hints do
    local hint = self.hints[index]
    local distance = math.abs(hint.at - delta.at)

    if hint.resolvesSource and not hint.spent and distance <= self.window then
      local exact = fits(hint, delta)
      if exact or not self:fitsAPendingDelta(hint) then
        local better
        if best == nil then
          better = true
        elseif exact ~= bestExact then
          better = exact
        elseif distance ~= bestDistance then
          better = distance < bestDistance
        elseif hint.priority ~= best.priority then
          better = hint.priority > best.priority
        else
          better = hint.sequence < best.sequence
        end

        if better then
          best, bestExact, bestDistance = hint, exact, distance
        end
      end
    end
  end

  return best
end

function XpAttribution:assign(delta)
  while delta.remaining > 0 do
    local hint = self:bestHintFor(delta)
    if hint == nil then
      return
    end

    local take = math.min(hint.announced, delta.remaining)
    -- Spent either way. A hint is one announcement: whatever of it the delta could
    -- not absorb was never real experience, and leaving the remainder alive is how
    -- it goes on to claim somebody else's.
    hint.spent = true

    if take > 0 then
      delta.remaining = delta.remaining - take
      delta.claims[#delta.claims + 1] = { hint = hint, amount = take }
    end
  end
end

-- ---------------------------------------------------------------------------
-- Settling
-- ---------------------------------------------------------------------------

-- Attribute everything that can no longer be decided differently. Called after every
-- intake and, from the composition root, on a timer, so a lone delta with nothing
-- following it still settles. Deltas leave in arrival order, which is also
-- completion order: the consumer splits gains across level boundaries, and one
-- landing on the wrong side of a level-up would corrupt both levels.
function XpAttribution:settle(now)
  Guard.number(now, "XpAttribution settle now")

  while #self.deltas > 0 and now - self.deltas[1].at > self.window * 2 do
    local delta = table.remove(self.deltas, 1)
    self:assign(delta)
    self:emit(delta)
  end

  self:pruneHints(now)
  self:pruneDeaths(now)
end

function XpAttribution:emit(delta)
  for index = 1, #delta.claims do
    local claim = delta.claims[index]
    if claim.amount > 0 then
      local gain = self:gainFor(claim.hint, claim.amount)
      if self.logger ~= nil then
        self.logger:debug(("delta at %.3f settled: source=%s amount=%d")
          :format(delta.at, tostring(gain.source), claim.amount))
      end
      self.bus:publish(EventTopic.XP_ATTRIBUTED, { gain = gain, place = delta.place })
    end
  end

  if delta.remaining > 0 then
    -- Never dropped. Experience nobody explained is still experience the player
    -- earned, and leaving it out is exactly how a level stops adding up.
    self.counters.unmatchedDeltas = self.counters.unmatchedDeltas + 1
    if self.logger ~= nil then
      self.logger:debug(("delta at %.3f closed unclaimed: source=%s amount=%d")
        :format(delta.at, tostring(XpSource.UNKNOWN), delta.remaining))
    end
    -- Unexplained is not the same as unannounced. A group kill the client reported
    -- without naming the creature leaves exactly one announcement -- the anonymous
    -- line -- and its parenthetical is then the ONLY record that the player was in
    -- a group for this experience. The source stays unknown, which is honest; the
    -- annotation survives, which is the point of D41: a modifier is a note about a
    -- gain, never an addend, so it costs nothing to carry on a gain whose source
    -- nobody could name.
    local group, raid = self:modifiersForRemainder(delta)
    local gain = XpGain.new({
      amount = delta.remaining, source = XpSource.UNKNOWN, at = delta.at,
      groupBonus = group, raidPenalty = raid,
    })
    delta.remaining = 0
    self.bus:publish(EventTopic.XP_ATTRIBUTED, { gain = gain, place = delta.place })
  end
end

-- The annotation carried by an anonymous line that nothing else explained. Matched
-- on the exact remaining amount and nothing looser: a remainder that is not the
-- figure the line announced belongs to a different event, and spreading one
-- parenthetical across two of them would invent a number the client never printed.
--
-- Marks the hint `spent` rather than `claimed`. The two are not synonyms here --
-- `claimed` means a named channel accounted for this line, and that count is how
-- the addon will eventually answer whether discoveries emit this family at all. A
-- line that only annotated an unknown remainder did not answer that question.
function XpAttribution:modifiersForRemainder(delta)
  for index = 1, #self.hints do
    local hint = self.hints[index]
    if hint.amountOnly and not hint.spent and hint.payload ~= nil
      and hint.announced == delta.remaining
      and math.abs(hint.at - delta.at) <= self.window then
      local group, raid = hint.payload.groupBonus or 0, hint.payload.raidPenalty or 0
      if group > 0 or raid > 0 then
        hint.spent = true
        return group, raid
      end
    end
  end
  return 0, 0
end

-- A hint has to outlive its own window by two more: a delta arriving a full window
-- after it is attributed two windows after that.
function XpAttribution:pruneHints(now)
  local hints = self.hints
  local write = 1

  for read = 1, #hints do
    local hint = hints[read]
    if now - hint.at <= self.window * 3 then
      hints[write] = hint
      write = write + 1
    else
      self:retireHint(hint)
    end
  end

  for index = #hints, write, -1 do
    hints[index] = nil
  end
end

function XpAttribution:retireHint(hint)
  -- A kill the addon heard announced but never saw paid still accounts for the
  -- creature's death. Leaving the death unclaimed would report a kill that paid 44
  -- experience as one that paid nothing.
  if hint.source == XpSource.MOB_KILL and hint.payload ~= nil then
    self:creatureFor(hint, hint.payload.creatureName)
  end

  if hint.amountOnly then
    if hint.claimed then
      self.counters.anonymousClaimed = self.counters.anonymousClaimed + 1
    else
      self.counters.anonymousUnclaimed = self.counters.anonymousUnclaimed + 1
      if self.logger ~= nil then
        self.logger:debug(("hint expired unclaimed at %.3f: amountOnly amount=%d"):format(hint.at, hint.announced))
      end
    end
  elseif not hint.spent then
    self.counters.unclaimedHints = self.counters.unclaimedHints + 1
    if self.logger ~= nil then
      self.logger:debug(("hint expired unclaimed at %.3f: source=%s amount=%d")
        :format(hint.at, tostring(hint.source), hint.announced))
    end
  end
end

-- A death nothing ever claimed is a creature that paid no experience, which the
-- client announces by saying nothing at all. Published rather than counted here
-- because the count belongs to the level record, and this service does not own one.
function XpAttribution:pruneDeaths(now)
  if self.correlator == nil then
    return
  end

  local expired = self.correlator:prune(now)
  for index = 1, #expired do
    local death = expired[index]
    self.bus:publish(EventTopic.KILL_UNREWARDED, {
      creature = CreatureKey.new(death.npcId, death.level, death.name),
      at = death.at,
    })
  end
end

-- ---------------------------------------------------------------------------
-- Building the gain
-- ---------------------------------------------------------------------------

-- A hint is consumed once, so a gain is built once. When the delta could not absorb
-- the whole announcement -- the bounded case -- the gain is split and the head kept,
-- which divides every modifier by the rule the model already tests rather than by a
-- second, subtly different one here.
function XpAttribution:gainFor(hint, amount)
  local full = self:fullGainFor(hint)
  if amount >= full.amount then
    return full
  end

  local head = full:splitAt(amount)
  return head
end

function XpAttribution:fullGainFor(hint)
  local payload = hint.payload
  if payload == nil then
    payload = {}
  end

  local creature
  if hint.source == XpSource.MOB_KILL then
    creature = self:creatureFor(hint, payload.creatureName)
  end

  return XpGain.new({
    amount = hint.announced,
    source = hint.source,
    at = hint.at,
    restedBonus = self:restedBonusFor(hint, payload),
    groupBonus = payload.groupBonus or 0,
    raidPenalty = payload.raidPenalty or 0,
    creature = creature,
    questId = payload.questId,
  })
end

-- Claiming a death is destructive, so a hint that both pays a delta and is later
-- retired must not consume two of them for one kill. But a resolve that found
-- nothing CLAIMED nothing, and remembering that answer is how one kill ends up
-- counted twice: as a paying kill with an unknown creature, and then again as an
-- unproductive one when its death is evicted unclaimed. So only a resolve that
-- found a death is final; the other is asked again, and asked non-destructively
-- first so the same hint is not counted uncorrelated more than once.
function XpAttribution:creatureFor(hint, name)
  if hint.creature ~= nil and hint.creature:hasKnownType() then
    return hint.creature
  end

  if self.correlator == nil or name == nil then
    if hint.creature == nil then
      hint.creature = CreatureKey.unknown(name)
    end
    return hint.creature
  end

  if hint.creature == nil or self.correlator:candidateFor(name, hint.at) ~= nil then
    hint.creature = self.correlator:resolve(name, hint.at)
  end
  return hint.creature
end

function XpAttribution:restedBonusFor(hint, payload)
  -- Only kills draw on the reserve. A quest or a discovery never carries a rested
  -- portion, whatever a channel appeared to say about it.
  if hint.source ~= XpSource.MOB_KILL then
    return 0
  end

  local amount = hint.announced

  local parsed
  if payload.restedRaw ~= nil then
    if self.restedReading == RestedReading.BASE then
      parsed = amount - payload.restedRaw
    else
      parsed = payload.restedRaw
    end
  end

  -- A sentence that was read and announced no rested state settles this by itself,
  -- and the reserve is not asked. It used to be, and that was a defect the file from
  -- the 2026-09-21 session caught: the reserve is sampled off the chat line, which
  -- the client prints BEFORE applying the gain, so the drop it shows belongs to the
  -- PREVIOUS kill. Every rested kill was charged twice over -- once from its own
  -- parenthetical and again to the first plain kill behind it -- and level 12 closed
  -- with 32 points of rested bonus where the truth was 16.
  --
  -- `false` is not `nil` here. No sentence at all still falls back, because then the
  -- reserve is the only reading there is; and `true` with no figure -- a fatigue
  -- line, a locale that prints a percentage -- is the case the fallback exists for.
  if parsed == nil and payload.restedAnnounced == false then
    return 0
  end

  local measured = XpAttribution.restedFromReserve(payload.restedBefore, payload.restedAfter, amount)

  -- Worth counting rather than resolving, and what it counts has changed. Spike 0.4
  -- is closed: the 2026-09-17 session settled that the parenthetical names the BONUS
  -- and that the reserve falls by exactly twice it. What the counter measures now is
  -- the OTHER reading being wrong -- the reserve is sampled off the chat line, which
  -- the client prints before applying the gain, so `measured` describes the previous
  -- kill. Expect this to climb on every kill whose predecessor paid differently; it
  -- stops meaning anything until the reserve is re-anchored on PLAYER_XP_UPDATE, and
  -- only then is a disagreement worth reading as a defect again.
  if parsed ~= nil and measured ~= nil and parsed ~= measured then
    self.counters.restedDisagreements = self.counters.restedDisagreements + 1
    if self.logger ~= nil then
      self.logger:debug(("rested bonus disagreement at %.3f: parsed=%d measured=%d")
        :format(hint.at, parsed, measured))
    end
  end

  local bonus = parsed
  if bonus == nil then
    bonus = measured
  end
  if bonus == nil or bonus < 0 then
    return 0
  end
  if bonus > amount then
    return amount
  end
  return bonus
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- The experience the client has already confirmed (XP_DELTA_OBSERVED) but this
-- service has not yet settled into a source -- D21's bounded lag, made readable
-- instead of just endured. record.xpTotal only grows when a delta settles, so
-- none of this is double-counted there; it exists for a caller (the bar) that
-- wants to show it as provisional "unclassified" instead of not moving at all
-- for up to two windows.
function XpAttribution:pendingAmount()
  local total = 0
  for index = 1, #self.deltas do
    total = total + self.deltas[index].amount
  end
  return total
end

function XpAttribution:diagnostics()
  local snapshot = {
    pendingDeltas = #self.deltas,
    pendingHints = #self.hints,
  }
  for key, value in pairs(self.counters) do
    snapshot[key] = value
  end
  if self.correlator ~= nil then
    snapshot.uncorrelatedKills = self.correlator:diagnostics().unmatchedHints
  end
  return snapshot
end

ns.core.XpAttribution = XpAttribution
