-- Ascent - the life of a pull: when one opens, what lands in it, and when it is
-- safe to call it finished.
--
-- WHY THIS SUBSCRIBES TO THE BUS ITSELF instead of registering a collector.
-- Every other combat metric in this addon is a descriptor in MetricRegistry that
-- CombatAggregator dispatches into `currentRecord()`, and `currentRecord()` is
-- always the open LEVEL. A pull has a different lifetime, opens and closes many
-- times inside one of those, and -- the part that decides it -- has to keep
-- accepting events for a few seconds AFTER the client says combat is over. None
-- of that is expressible as a collector without teaching the aggregator about a
-- second kind of record and a second clock, which would put this module's whole
-- problem inside a file that currently has none. A second subscriber costs one
-- more pcall per event on topics that already have one (see EventBus's per
-- subscriber isolation) and leaves the level path untouched.
--
-- The one thing that IS reused rather than rebuilt is the ranking: PullRecord
-- keys its abilities exactly as LevelRecord does, so AbilityRankingViewModel
-- ranks a pull with no change at all.
--
-- THE STATE MACHINE, and every edge in it is load-bearing:
--
--        COMBAT_STARTED            COMBAT_ENDED           tick() past the window
--   IDLE ---------------> ACTIVE ----------------> SETTLING ------------------> CLOSED
--                           ^                         |                           |
--                           +-------------------------+                           |
--                             COMBAT_STARTED (same pull continues)                |
--                           ^                                                     |
--                           +-----------------------------------------------------+
--                             COMBAT_STARTED, while the plate is still on screen:
--                             the SAME pull reopens, counter and chain intact
--                           ^
--                           +---- COMBAT_STARTED after that: a new pull
--
-- THE RESUME WINDOW is the settling idea carried one step further, and its length
-- is not arbitrary: it is exactly how long the finished plate stays visible. A
-- player who pulls the next thing while the last fight is still fading meant to
-- keep going -- that is what chain pulling IS -- and the surface in front of them
-- is the affordance saying so. When the plate is gone the offer is gone with it,
-- which is a rule someone can learn by playing rather than by reading.
--
-- SETTLING accepting events is the whole reason this file is not four lines: see
-- PullPhase in core/constants/Metrics.lua for why the client's own "combat over"
-- is not the moment a pull's numbers are final.
--
-- THE PRELUDE, which is the same problem at the other end. A pull is opened by
-- PLAYER_REGEN_DISABLED, and that fires when the target FIGHTS BACK -- which is
-- after the shot that started it. The opener is therefore always early: the cast
-- that pulled, and the damage that made it aggro, both land while there is no
-- pull to put them in, and a tracker that simply dropped them lost the one
-- ability the player chose most deliberately in the whole fight.
--
-- So the events that can legitimately precede combat are kept in a small bounded
-- buffer and replayed into the pull the moment it opens, and the pull is
-- backdated to the earliest of them: the fight began when you pulled, not when
-- the server agreed you were in one.
--
-- This module owns no frame and draws nothing. It answers three questions --
-- which pull, what phase, and whether either just changed -- and the view reads
-- them on the tick it already runs.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local EventTopic = ns.core.EventTopic
local PullPhase = ns.core.PullPhase
local PullRecord = ns.core.PullRecord

-- How long after the client says combat ended a pull keeps accepting events.
-- Two full KillCorrelator windows (its default is 1.5s) plus room for the
-- composition root's own once-a-second settle pass to run inside it, because the
-- last unattributed gain of a fight resolves on that pass and not on an event.
local SETTLE_SECONDS = 3.5

-- How far back a pull reaches for the shot that started it. Long enough for a
-- cast plus its travel time, short enough that it cannot sweep in an action from
-- something the player did and then walked away from. The trade is explicit:
-- five seconds of idling after a cast that pulled nothing would fold that cast
-- into the next fight, which is a wrong row in a list -- against losing the
-- opener of every fight, which is what the alternative costs.
-- How long after a pull closes it can still be resumed. The composition root
-- overrides this with the plate's own visible lifetime so the two cannot drift;
-- the value here is what a session with no views falls back to.
local RESUME_SECONDS = 7.2

local PRELUDE_SECONDS = 5

-- And a ceiling on top of the window, so a flurry of casts that aggroed nothing
-- cannot grow this without bound. Well above what five seconds of opening can
-- hold, and far below anything worth worrying about.
local PRELUDE_LIMIT = 24

-- The only topics that can honestly arrive before combat does. A kill, a death or
-- attributed experience with no pull open belongs to no pull, and buffering them
-- would be inventing one.
local PRELUDE_TOPICS = {}

local PullTracker = {}
PullTracker.__index = PullTracker

-- options.bus            the event bus (required)
-- options.clock          the session clock (required)
-- options.settleSeconds  override for the window above
-- options.resumeSeconds  how long a CLOSED pull can still be reopened. The
--                        composition root passes the plate's visible lifetime.
-- options.comboWindow    forwarded to every PullRecord this opens
-- options.enabled        optional function() -> boolean, read live. False means
--                        events are dropped and no pull is ever opened, so a
--                        player who turned the plate off pays nothing for it.
function PullTracker.new(options)
  options = options or {}
  for _, required in ipairs({ "bus", "clock" }) do
    if options[required] == nil then
      error("PullTracker needs a " .. required, 2)
    end
  end
  Port.verify(ns.core.EventBusPort, options.bus, "PullTracker bus")
  Port.verify(ns.core.Clock, options.clock, "PullTracker clock")

  local self = setmetatable({
    bus = options.bus,
    clock = options.clock,
    settleSeconds = options.settleSeconds or SETTLE_SECONDS,
    resumeSeconds = options.resumeSeconds or RESUME_SECONDS,
    comboWindow = options.comboWindow,
    enabled = options.enabled,

    pull = nil,
    phase = PullPhase.IDLE,
    -- When the pull stopped accepting events. What the resume window is measured
    -- from, and nil for anything that has not closed.
    closedAt = nil,
    -- { topic, payload, at }, oldest first. See the header: this is where the
    -- shot that started the fight waits for the fight to be acknowledged.
    prelude = {},
    -- Incremented every time a pull OPENS. A view comparing this against what it
    -- drew last cannot mistake a new pull for a continuation of the old one, and
    -- does not have to hold a reference to the record to find out.
    generation = 0,
    -- Set by any transition, cleared by consumeChange(). The view drives off
    -- this instead of subscribing, so there is one tick and one redraw rather
    -- than a callback firing mid-fight from inside the bus.
    changed = false,
  }, PullTracker)

  self.subscriptions = {}
  local function on(topic, handler)
    self.subscriptions[#self.subscriptions + 1] = options.bus:subscribe(topic, function(payload)
      handler(self, payload or {})
    end)
  end

  on(EventTopic.COMBAT_STARTED, PullTracker.onCombatStarted)
  on(EventTopic.COMBAT_ENDED, PullTracker.onCombatEnded)
  on(EventTopic.XP_ATTRIBUTED, PullTracker.onXpAttributed)
  on(EventTopic.CREATURE_DIED, PullTracker.onCreatureDied)
  on(EventTopic.ABILITY_USED, PullTracker.onAbilityUsed)
  on(EventTopic.ENEMY_ENGAGED, PullTracker.onEnemyEngaged)
  on(EventTopic.DAMAGE_DEALT, PullTracker.onDamageDealt)
  on(EventTopic.DAMAGE_TAKEN, PullTracker.onDamageTaken)
  on(EventTopic.HEALING_RECEIVED, PullTracker.onHealingReceived)
  on(EventTopic.PLAYER_DIED, PullTracker.onPlayerDied)

  return self
end

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

function PullTracker:isEnabled()
  return self.enabled == nil or self.enabled() ~= false
end

-- The record events are allowed to land in right now, or nil. ACTIVE and
-- SETTLING both qualify and CLOSED deliberately does not: a closed pull is a
-- finished statement, and a stray combat log line arriving after it must not
-- change a number the player is already reading.
function PullTracker:recording()
  if self.phase == PullPhase.ACTIVE or self.phase == PullPhase.SETTLING then
    return self.pull
  end
  return nil
end

-- Remembers one event that arrived with no pull open, dropping anything now out
-- of the window. Pruned on write rather than on a timer: the only moment the
-- contents matter is the moment a pull opens, and a buffer nobody is filling is
-- a buffer nobody is paying for.
function PullTracker:remember(topic, payload, at)
  local prelude = self.prelude
  prelude[#prelude + 1] = { topic = topic, payload = payload, at = at }

  local cutoff = at - PRELUDE_SECONDS
  local first = 1
  while first <= #prelude and (prelude[first].at < cutoff or (#prelude - first + 1) > PRELUDE_LIMIT) do
    first = first + 1
  end
  if first > 1 then
    local kept = {}
    for index = first, #prelude do
      kept[#kept + 1] = prelude[index]
    end
    self.prelude = kept
  end
end

-- Replays the shot that started the fight into the pull it started, and backdates
-- the pull to it. Anything older than the window is dropped here as well as on
-- write, because the buffer may have been sitting untouched since the last fight.
-- `backdate` is false when the pull was already running: see onCombatStarted.
function PullTracker:replayPrelude(now, backdate)
  local cutoff = now - PRELUDE_SECONDS
  local earliest

  for _, entry in ipairs(self.prelude) do
    if entry.at >= cutoff then
      if earliest == nil then
        earliest = entry.at
      end
      PRELUDE_TOPICS[entry.topic](self, entry.payload)
    end
  end

  self.prelude = {}

  -- The fight began when the player pulled. Moving the start back is what keeps
  -- the elapsed time, the damage per second and the experience per hour honest
  -- about a fight whose first two seconds the client had not noticed yet.
  if backdate and earliest ~= nil and earliest < self.pull.startedAt then
    self.pull.startedAt = earliest
  end
end

function PullTracker:transition(phase)
  if self.phase ~= phase then
    self.phase = phase
    self.changed = true
  end
end

-- ---------------------------------------------------------------------------
-- Topic handlers
-- ---------------------------------------------------------------------------

-- Whether the fight starting now is the one that was already going.
--
-- SETTLING always is: adds walking in three seconds apart are the same fight,
-- and the experience for the first group has not necessarily landed yet.
--
-- CLOSED is too, for as long as the plate is still on screen. See the header.
function PullTracker:canResume(now)
  if self.pull == nil then
    return false
  end
  if self.phase == PullPhase.SETTLING then
    return true
  end
  return self.phase == PullPhase.CLOSED
    and self.closedAt ~= nil
    and (now - self.closedAt) <= self.resumeSeconds
end

function PullTracker:onCombatStarted()
  if not self:isEnabled() then
    return
  end

  local now = self.clock:now()

  if self:canResume(now) then
    self.pull.endedAt = nil
    self.closedAt = nil
    self:transition(PullPhase.ACTIVE)
    -- The opener of the add is replayed too, but the pull is NOT backdated to
    -- it: this fight started when the first one did, and moving its start
    -- forward -- or back to something inside it -- would be rewriting a
    -- duration the player has been watching.
    self:replayPrelude(now, false)
    self.changed = true
    return
  end

  self.pull = PullRecord.new(now, { comboWindow = self.comboWindow })
  self.closedAt = nil
  self.generation = self.generation + 1
  self.changed = true
  self:transition(PullPhase.ACTIVE)
  self:replayPrelude(now, true)
end

function PullTracker:onCombatEnded()
  if self.phase ~= PullPhase.ACTIVE then
    return
  end
  self.pull.endedAt = self.clock:now()
  self:transition(PullPhase.SETTLING)
end

function PullTracker:onXpAttributed(payload)
  local pull = self:recording()
  local gain = payload.gain
  if pull == nil or gain == nil then
    return
  end
  pull:recordXp(gain.amount, gain.source)
  self.changed = true
end

function PullTracker:onCreatureDied(payload)
  local pull = self:recording()
  if pull == nil then
    return
  end
  -- `at` comes off the payload rather than the clock: the combat log router
  -- already stamped it, and a kill correlated against that stamp elsewhere must
  -- not be chained against a different one here.
  pull:recordKill(payload.name, payload.at or self.clock:now())
  self.changed = true
end

function PullTracker:onAbilityUsed(payload)
  if payload.key == nil then
    return
  end
  local pull = self:recording()
  if pull == nil then
    -- No pull yet: this may be the cast that is about to start one.
    if self:isEnabled() then
      self:remember(EventTopic.ABILITY_USED, payload, self.clock:now())
    end
    return
  end
  pull:recordAbility(payload.key, payload.name)
  self.changed = true
end

-- Who is in this fight, which is a different question from who has been hurt in
-- it. A creature that charged the player, swung and missed belongs in the pull --
-- and so does one the player has not hit back yet, which is the whole of the
-- defect this answers: the plate used to count what the player had damaged, so a
-- fight the player did not start read as a fight against nobody.
function PullTracker:onEnemyEngaged(payload)
  if payload.name == nil then
    return
  end
  local pull = self:recording()
  if pull == nil then
    -- The same prelude as the opening shot, from the other end: the swing that
    -- announces an ambush lands before the client agrees there is a fight.
    if self:isEnabled() then
      self:remember(EventTopic.ENEMY_ENGAGED, payload, self.clock:now())
    end
    return
  end
  pull:recordEngagement(payload.name, payload.guid)
  self.changed = true
end

function PullTracker:onDamageDealt(payload)
  if payload.amount == nil then
    return
  end
  local pull = self:recording()
  if pull == nil then
    -- Same reasoning as the cast above, and it carries the target's name too --
    -- so the creature that was pulled is already in the list when the plate
    -- first draws, rather than appearing on the second blow.
    if self:isEnabled() then
      self:remember(EventTopic.DAMAGE_DEALT, payload, self.clock:now())
    end
    return
  end
  -- The name and the guid ride on the same payload as the amount, so the pull
  -- learns what it is fighting from the first blow rather than from the kill.
  pull:recordDamageDealt(payload.amount, payload.name, payload.guid)
  self.changed = true
end

function PullTracker:onDamageTaken(payload)
  if payload.amount == nil then
    return
  end
  local pull = self:recording()
  if pull == nil then
    -- The prelude, from the other side. An ambush lands its first blow before the
    -- client says you are in combat, and that blow is the only thing naming the
    -- creature that started it -- so it waits in the same buffer as the shot that
    -- opens a pull the player chose.
    if self:isEnabled() then
      self:remember(EventTopic.DAMAGE_TAKEN, payload, self.clock:now())
    end
    return
  end
  pull:recordDamageTaken(payload.amount, payload.name, payload.guid)
  self.changed = true
end

function PullTracker:onHealingReceived(payload)
  local pull = self:recording()
  if pull == nil or payload.amount == nil then
    return
  end
  pull:recordHealing(payload.amount)
  self.changed = true
end

function PullTracker:onPlayerDied()
  local pull = self:recording()
  if pull == nil then
    return
  end
  pull:recordDeath()
  self.changed = true
end

-- ---------------------------------------------------------------------------
-- The tick
-- ---------------------------------------------------------------------------

-- Closes a settled pull. Called from whatever clock the composition root already
-- runs; it costs a comparison when there is nothing open, which is most of the
-- time a character is logged in.
function PullTracker:tick(now)
  if self.phase ~= PullPhase.SETTLING then
    return false
  end
  now = now or self.clock:now()
  if (now - self.pull.endedAt) < self.settleSeconds then
    return false
  end
  self.closedAt = now
  self:transition(PullPhase.CLOSED)
  return true
end

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

function PullTracker:current()
  return self.pull
end

function PullTracker:currentPhase()
  return self.phase
end

function PullTracker:currentGeneration()
  return self.generation
end

-- True exactly once per change, and then false until the next one. The view asks
-- this on every tick and redraws only when the answer is yes, which is what
-- keeps a plate on screen from costing anything while the player reads it.
function PullTracker:consumeChange()
  local changed = self.changed
  self.changed = false
  return changed
end

-- Drops whatever is open without closing it. Used when the player turns the
-- plate off mid-fight: a pull nobody will ever see must not go on accumulating.
function PullTracker:reset()
  self.pull = nil
  self.phase = PullPhase.IDLE
  self.closedAt = nil
  self.prelude = {}
  self.changed = true
end

-- Declared at the top and filled here, once the handlers exist. Replay goes
-- through the SAME functions a live event does, so a prelude can never diverge
-- from what the tracker would have recorded had the client been quicker.
PRELUDE_TOPICS[ns.core.EventTopic.ABILITY_USED] = PullTracker.onAbilityUsed
PRELUDE_TOPICS[ns.core.EventTopic.DAMAGE_DEALT] = PullTracker.onDamageDealt
PRELUDE_TOPICS[ns.core.EventTopic.DAMAGE_TAKEN] = PullTracker.onDamageTaken
PRELUDE_TOPICS[ns.core.EventTopic.ENEMY_ENGAGED] = PullTracker.onEnemyEngaged

ns.core.PullTracker = PullTracker
