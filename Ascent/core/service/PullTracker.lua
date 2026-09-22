-- Ascent - the life of a pull: when one opens, what lands in it, and when it is
-- safe to call it finished.
--
-- It subscribes to the bus itself instead of registering a collector: collectors
-- write into `currentRecord()`, which is always the open level, while a pull
-- opens and closes many times within a level and keeps accepting events for a
-- few seconds after the client reports combat over. A second subscriber costs
-- one more pcall per event and leaves the level path untouched. PullRecord keys
-- abilities as LevelRecord does, so AbilityRankingViewModel ranks a pull as is.
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
-- The resume window is exactly as long as the finished plate stays visible:
-- pulling again while it is on screen continues the chain, and once it is gone
-- the next fight is a new pull. SETTLING exists because the client's "combat
-- over" is not when a pull's numbers are final; see PullPhase in
-- core/constants/Metrics.lua.
--
-- The prelude handles the other end. PLAYER_REGEN_DISABLED fires when the target
-- fights back, after the cast that pulled it, so the events that can precede
-- combat are buffered briefly, replayed into the pull when it opens, and the
-- pull is backdated to the earliest of them.
--
-- This module owns no frame. It answers which pull, what phase, and whether
-- either just changed; the view reads them on its own tick.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local EventTopic = ns.core.EventTopic
local PullPhase = ns.core.PullPhase
local PullRecord = ns.core.PullRecord

-- How long after the client reports combat over a pull keeps accepting events:
-- two KillCorrelator windows (default 1.5s) plus room for the composition root's
-- once-a-second settle pass, where a fight's last unattributed gain resolves.
local SETTLE_SECONDS = 3.5

-- How long after a pull closes it can still be resumed. The composition root
-- passes the plate's visible lifetime so the two cannot drift; this is the
-- fallback for a session with no views.
local RESUME_SECONDS = 7.2

-- How far back a pull reaches for the cast that started it: a cast plus its
-- travel time. The accepted cost is that a cast that pulled nothing, followed
-- within this window by a fight, is folded into that fight.
local PRELUDE_SECONDS = 5

-- A ceiling on the buffer, so a flurry of casts that pulled nothing cannot grow
-- it without bound; well above what the window can hold in practice.
local PRELUDE_LIMIT = 24

-- The only topics that can legitimately arrive before combat. A kill, a death or
-- attributed experience with no pull open belongs to no pull.
local PRELUDE_TOPICS = {}

local PullTracker = {}
PullTracker.__index = PullTracker

-- options.bus            the event bus (required)
-- options.clock          the session clock (required)
-- options.settleSeconds  override for the window above
-- options.resumeSeconds  how long a CLOSED pull can still be reopened. The
--                        composition root passes the plate's visible lifetime,
--                        a player setting, as a number or a function() -> number
--                        read on every question, so a change applies without a
--                        reload.
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
    -- Kept as given, function or number: resolving it here would freeze it
    -- (see resumeWindow below).
    resumeSeconds = options.resumeSeconds,
    comboWindow = options.comboWindow,
    enabled = options.enabled,

    pull = nil,
    phase = PullPhase.IDLE,
    -- When the pull stopped accepting events, the start of the resume window;
    -- nil for anything that has not closed.
    closedAt = nil,
    -- { topic, payload, at }, oldest first: events that arrived before the
    -- client reported combat (see the header).
    prelude = {},
    -- Incremented every time a pull opens, so a view tells a new pull from a
    -- continuation without holding a reference to the record.
    generation = 0,
    -- Set by any transition, cleared by consumeChange(). The view polls this
    -- on its tick instead of subscribing, so it never redraws from inside the
    -- bus mid-fight.
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

-- How long a closed pull can still be reopened, read on every call: it equals
-- the plate's visible lifetime, a setting that applies without a reload.
--
-- Anything that is not a number falls back to the default, so a settings
-- closure that returns nil degrades to the default instead of breaking the
-- comparison it feeds.
function PullTracker:resumeWindow()
  local window = self.resumeSeconds
  if type(window) == "function" then
    window = window()
  end
  if type(window) ~= "number" then
    return RESUME_SECONDS
  end
  return window
end

-- The record events may land in right now, or nil. ACTIVE and SETTLING qualify;
-- CLOSED does not, so a stray combat log line cannot change a finished pull the
-- player is reading.
function PullTracker:recording()
  if self.phase == PullPhase.ACTIVE or self.phase == PullPhase.SETTLING then
    return self.pull
  end
  return nil
end

-- Remembers one event that arrived with no pull open, dropping anything out of
-- the window or over the limit. Pruned on write, not on a timer: the contents
-- only matter when a pull opens.
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

-- Replays the buffered events into the pull and backdates the pull to the
-- earliest. The window is checked again here because the buffer may have sat
-- untouched since the last fight. `backdate` is false when the pull was already
-- running: see onCombatStarted.
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

  -- The fight began when the player pulled; the earlier start keeps the elapsed
  -- time, damage per second and experience per hour correct.
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
-- SETTLING always is: adds arriving seconds apart are the same fight, and the
-- first group's experience may not have landed yet. CLOSED is too, while the
-- plate is still on screen (see the header).
function PullTracker:canResume(now)
  if self.pull == nil then
    return false
  end
  if self.phase == PullPhase.SETTLING then
    return true
  end
  return self.phase == PullPhase.CLOSED
    and self.closedAt ~= nil
    and (now - self.closedAt) <= self:resumeWindow()
end

function PullTracker:onCombatStarted()
  if not self:isEnabled() then
    return
  end

  -- Already fighting. An engagement can open a pull a moment before
  -- PLAYER_REGEN_DISABLED fires, and that event must not replace the pull.
  if self.phase == PullPhase.ACTIVE then
    return
  end

  local now = self.clock:now()

  if self:canResume(now) then
    self.pull.endedAt = nil
    self.closedAt = nil
    self:transition(PullPhase.ACTIVE)
    -- The add's opener is replayed but the pull is not backdated: it started
    -- with the first fight, and its duration is already on screen.
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
  -- `at` comes from the payload, not the clock: the combat log router stamped
  -- it, and the chain must use the same stamp the kill was correlated against.
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

-- Who is in this fight, not who has been hurt in it: a creature that attacked
-- and missed, or that the player has not hit yet, belongs in the pull.
function PullTracker:onEnemyEngaged(payload)
  if payload.name == nil then
    return
  end
  local pull = self:recording()
  if pull == nil then
    -- A creature is fighting this character before PLAYER_REGEN_DISABLED has
    -- fired, which is the common case, so the engagement opens the pull. It is
    -- also remembered, so the ordinary replay path records it and the pull's
    -- per-creature rule keeps it from being counted twice.
    if not self:isEnabled() then
      return
    end
    self:remember(EventTopic.ENEMY_ENGAGED, payload, self.clock:now())
    self:onCombatStarted()
    pull = self:recording()
    if pull == nil then
      return
    end
  end
  -- Only when it was news: the combat log announces the same creature many times
  -- a fight, and a known one must not trigger a redraw.
  if pull:recordEngagement(payload.name, payload.guid) then
    self.changed = true
  end
end

function PullTracker:onDamageDealt(payload)
  if payload.amount == nil then
    return
  end
  local pull = self:recording()
  if pull == nil then
    -- As with the cast above; it also carries the target's name, so the pulled
    -- creature is listed when the plate first draws.
    if self:isEnabled() then
      self:remember(EventTopic.DAMAGE_DEALT, payload, self.clock:now())
    end
    return
  end
  -- The name and guid ride with the amount, so the pull learns what it is
  -- fighting from the first blow rather than from the kill.
  pull:recordDamageDealt(payload.amount, payload.name, payload.guid)
  self.changed = true
end

function PullTracker:onDamageTaken(payload)
  if payload.amount == nil then
    return
  end
  local pull = self:recording()
  if pull == nil then
    -- An ambush lands its first blow before the client reports combat, and that
    -- blow is the only thing naming the attacker, so it is buffered too.
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

-- Closes a settled pull. Called from the composition root's ticker; a single
-- comparison when nothing is settling.
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

-- True exactly once per change, then false until the next. The view asks on
-- every tick and redraws only on yes, so an idle plate costs nothing.
function PullTracker:consumeChange()
  local changed = self.changed
  self.changed = false
  return changed
end

-- Drops whatever is open without closing it, for when the player turns the
-- plate off mid-fight.
function PullTracker:reset()
  self.pull = nil
  self.phase = PullPhase.IDLE
  self.closedAt = nil
  self.prelude = {}
  self.changed = true
end

-- Filled here, once the handlers exist. Replay goes through the same handlers as
-- a live event, so a replayed prelude records exactly what a live one would.
PRELUDE_TOPICS[ns.core.EventTopic.ABILITY_USED] = PullTracker.onAbilityUsed
PRELUDE_TOPICS[ns.core.EventTopic.DAMAGE_DEALT] = PullTracker.onDamageDealt
PRELUDE_TOPICS[ns.core.EventTopic.DAMAGE_TAKEN] = PullTracker.onDamageTaken
PRELUDE_TOPICS[ns.core.EventTopic.ENEMY_ENGAGED] = PullTracker.onEnemyEngaged

ns.core.PullTracker = PullTracker
