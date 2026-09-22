-- Ascent - reconciling what was earned with what announced it.
--
-- The amount is authoritative and the source is a claim. The amount is the
-- difference between two readings of the player's experience, the only figure
-- the client guarantees. The source arrives separately, on channels that are
-- late, duplicated, ambiguous or absent, and no channel may add experience.
--
--   delta   44 at t=10.0            <- authoritative, from UnitXP
--   hint    "Kobold Miner dies,     <- a claim: mob kill, 44, around t=10.0
--            you gain 44 experience"
--
-- Each hint is consumed bounded by min(announced, remaining), so a gain
-- announced on two channels adds up once and no channel can inflate the level.
-- Whatever no hint claims is attributed to UNKNOWN rather than dropped, so the
-- sources add up to exactly the level total.
--
--   * The window is bidirectional. Whether a hint arrives before or after its
--     delta is undocumented for Classic Era (1.15.x) and Burning Crusade Classic
--     (2.5.x), and a queue would be silently wrong for one of the two orders.
--
--   * A delta is buffered and attributed two windows after it arrives, not one.
--     One window is when the last hint about it can arrive; two is when that
--     hint's own window has closed, so any delta it really announced has arrived
--     too. Settling at the first hint that fills a delta leaves nothing for the
--     channel carrying the quest id a few milliseconds behind; settling after one
--     window judges a hint against deltas not yet seen. The cost is a bounded lag.
--
--   * Matching is by amount, not only by time. A hint announcing exactly what a
--     delta still needs is taken first, and a hint is never fed to a delta it
--     does not fit while one it fits exactly is waiting (sound only because of
--     the two-window rule). Otherwise an unexplained delta swallows the front of
--     the next kill's announcement and the kill is counted twice.
--
--     Among equally fitting hints the nearer one wins; channel priority only
--     breaks a tie at the same instant. Priority ranks the channels of one
--     announcement (the turn-in event above its echo), not two different gains,
--     and letting it outrank time would swap a kill's experience with a quest's
--     that pays the same.
--
--   * A hint is one announcement and is consumed at most once. A surviving copy
--     of a twice-announced turn-in would outrank a kill and book it to
--     QUEST_TURNIN, so copies are retired against each other at intake.
--
-- The counters (unmatched deltas, unclaimed hints) are what the window is tuned
-- against in real play.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local Port = ns.core.Port
local XpGain = ns.core.XpGain
local XpSource = ns.core.XpSource
local CreatureKey = ns.core.CreatureKey
local EventTopic = ns.core.EventTopic
local RestedReading = ns.core.RestedReading

-- settle() waits out 2x this before committing a delta, so it is also the visible
-- lag on every kill (1.5s at worst). Measured on a real client, a solo kill's hint
-- arrived ~0.3s before its delta; 0.75s leaves a 2.5x margin. The order is not
-- established for other sources, so the window stays bidirectional.
local DEFAULT_WINDOW = 0.75

local XpAttribution = {}
XpAttribution.__index = XpAttribution

-- The client's rested figure (GetXPExhaustion) is twice the server's internal
-- reserve, so a kill drops it by twice the base experience, and the bonus equals
-- that base. Halving the drop reads the bonus independently of the chat wording.
-- Bounded by the announced total, because the last kill before the reserve
-- empties pays a partial bonus.
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

-- payload: { amount, at, place, sharedBy }. The amount is the authoritative
-- difference, with any level crossing already folded into it by the adapter.
--
-- The place rides with the delta, not the hint: the delta is the authoritative
-- event, and the hint can be a window and a half away, so a kill by a dungeon
-- entrance could otherwise land in the wrong place. Carried untouched, nil
-- included: only the ledger decides what an unknown place means.
--
-- The group size rides with the delta too, nil included. A delta settles two
-- windows later, so the size read here is the one the server split this payment
-- between; one read at settling time could include a group joined since.
function XpAttribution:observeDelta(payload)
  local amount = Guard.nonNegativeInteger(payload.amount, "XP delta amount")
  local at = Guard.number(payload.at, "XP delta at")

  if self.logger ~= nil then
    self.logger:debug(("delta arrived at %.3f: amount=%d"):format(at, amount))
  end

  if amount > 0 then
    self.deltas[#self.deltas + 1] = {
      at = at, amount = amount, remaining = amount, claims = {}, place = payload.place,
      sharedBy = payload.sharedBy,
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

-- The anonymous line carries the parenthetical but never names a source, so it
-- never builds a gain of its own. When it duplicates a kill announcement (same
-- amount, same instant) its modifiers belong on that kill; otherwise a group kill
-- announced without a creature name records a bonus of zero. Guarded three ways:
--
--   only a kill: the group bonus is a share of creature experience, and a quest
--   turn-in has none;
--
--   only an unspent anonymous copy, so one line annotates one gain;
--
--   only when the named hint carries neither modifier. A gain never carries both
--   a group bonus and a raid penalty, so the named channel's reading wins
--   outright instead of being merged into that pair.
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

-- The client announces the same gain more than once: quest experience arrives on
-- QUEST_TURNED_IN, on the system echo, and on the anonymous experience line.
-- Copies are retired against each other at intake, so the second sums zero.
--
-- Two copies are the same announcement when they state the same amount inside the
-- window and come from different channels. Two same-value kills a second apart
-- both come from the kill channel and must not be collapsed.
function XpAttribution:linkDuplicate(incoming)
  for index = 1, #self.hints do
    local other = self.hints[index]

    if other.announced == incoming.announced
      and math.abs(other.at - incoming.at) <= self.window then

      if other.amountOnly ~= incoming.amountOnly then
        -- One of the two is the anonymous line. It never names a source, so the
        -- other accounts for it. The claimed versus unclaimed counts show whether
        -- discoveries emit this line, which no public source documents.
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
        -- `duplicate` is separate from `spent`: a retired copy is spent without
        -- having paid, and treating `spent` alone as "already paid" would retire
        -- the next real turn-in of the same reward against the previous echo.
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

-- Whether a hint accounts for exactly what this delta still needs: matching by
-- amount, which keeps a hint with a delta of its own from being eaten by an older
-- one still open.
local function fits(hint, delta)
  return hint.announced == delta.remaining
end

-- Whether a waiting delta fits this hint exactly. If so the hint belongs to it;
-- giving a fragment to the delta being settled would split one kill into two gains.
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

-- The best hint still available for this delta, or nil. Scanned, not sorted: the
-- ranking depends on the delta's remainder, which changes as hints are taken, and a
-- linear scan over a handful of hints avoids table.sort's strict weak ordering.
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
    -- Spent either way: a hint is one announcement, and whatever the delta could
    -- not absorb was never real experience and must not claim another delta's.
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

-- Attributes everything that can no longer be decided differently. Called after
-- every intake and, from the composition root, on a timer, so a lone delta still
-- settles. Deltas leave in arrival order: the consumer splits gains across level
-- boundaries, and one out of order would corrupt both levels.
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
      local gain = self:gainFor(claim.hint, claim.amount, delta.sharedBy)
      if self.logger ~= nil then
        self.logger:debug(("delta at %.3f settled: source=%s amount=%d")
          :format(delta.at, tostring(gain.source), claim.amount))
      end
      self.bus:publish(EventTopic.XP_ATTRIBUTED, { gain = gain, place = delta.place })
    end
  end

  if delta.remaining > 0 then
    -- Never dropped: unexplained experience is still earned, and the sources
    -- must add up to the level total.
    self.counters.unmatchedDeltas = self.counters.unmatchedDeltas + 1
    if self.logger ~= nil then
      self.logger:debug(("delta at %.3f closed unclaimed: source=%s amount=%d")
        :format(delta.at, tostring(XpSource.UNKNOWN), delta.remaining))
    end
    -- Unexplained is not unannounced. A group kill reported without a creature
    -- name leaves only the anonymous line, whose parenthetical is the only record
    -- of the group. The source stays unknown but the modifiers are kept: a
    -- modifier annotates a gain and is never added to it.
    local group, raid = self:modifiersForRemainder(delta)
    local gain = XpGain.new({
      amount = delta.remaining, source = XpSource.UNKNOWN, at = delta.at,
      groupBonus = group, raidPenalty = raid, sharedBy = delta.sharedBy,
    })
    delta.remaining = 0
    self.bus:publish(EventTopic.XP_ATTRIBUTED, { gain = gain, place = delta.place })
  end
end

-- The modifiers of an anonymous line that nothing else explained. Matched on the
-- exact remaining amount only: a different remainder belongs to another event.
--
-- Marks the hint `spent`, not `claimed`: `claimed` means a named channel accounted
-- for the line, the count that shows whether discoveries emit it.
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

-- A hint outlives its own window by two more: a delta arriving a full window after
-- it is attributed two windows after that.
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
  -- A kill announced but never seen paid still claims the creature's death, or
  -- the death would be reported as a kill that paid nothing.
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

-- A death nothing claimed is a creature that paid no experience (the client says
-- nothing). Published rather than counted: the count belongs to the level record.
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
-- the whole announcement, the gain is split and the head kept, so modifiers divide
-- by XpGain's own split rule.
--
-- `sharedBy` comes from the delta, not the hint, as with the place above.
function XpAttribution:gainFor(hint, amount, sharedBy)
  local full = self:fullGainFor(hint, sharedBy)
  if amount >= full.amount then
    return full
  end

  local head = full:splitAt(amount)
  return head
end

function XpAttribution:fullGainFor(hint, sharedBy)
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
    sharedBy = sharedBy,
  })
end

-- Claiming a death is destructive, so a hint that pays a delta and is later retired
-- must not consume two deaths. A resolve that found nothing claimed nothing, and
-- caching that would count one kill twice (paid with an unknown creature, then
-- unrewarded when its death expires). So only a found death is final; otherwise it
-- is asked again, non-destructively first, so the hint is counted uncorrelated once.
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
  -- Only kills draw on the reserve; a quest or a discovery never carries a rested
  -- portion, whatever a channel appears to say.
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

  -- A sentence that was read and announced no rested state settles it, without
  -- asking the reserve. The reserve is sampled on the chat line, which the client
  -- prints before applying the gain, so its drop belongs to the previous kill and
  -- would charge a rested kill's bonus again to the plain kill after it.
  --
  -- `false` is not `nil`: with no sentence the reserve is the only reading, and
  -- `true` with no figure (a fatigue line, a locale printing a percentage) is what
  -- the fallback is for.
  if parsed == nil and payload.restedAnnounced == false then
    return 0
  end

  local measured = XpAttribution.restedFromReserve(payload.restedBefore, payload.restedAfter, amount)

  -- Counted, not resolved. The parenthetical names the bonus, and the reserve
  -- falls by exactly twice it, but `measured` describes the previous kill (see
  -- above), so this climbs whenever the previous kill paid differently. It is a
  -- defect signal only once the reserve is sampled on PLAYER_XP_UPDATE.
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

-- Experience the client has confirmed (XP_DELTA_OBSERVED) but this service has not
-- yet settled into a source: the attribution lag. record.xpTotal grows only when a
-- delta settles, so nothing is double-counted; the bar shows this as provisional
-- instead of standing still for up to two windows.
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
