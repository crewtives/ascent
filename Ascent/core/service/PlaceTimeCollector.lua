-- Ascent - metric collector: how long the level spent in each place.
--
-- The ledger supplies a place's experience; this supplies its time, the
-- denominator of a per-hour rate. It is the only writer that records a place
-- that paid nothing, so a zone crossed for no experience still shows its cost.
--
-- The client has no "the character changed place" event, so time is sampled
-- like CombatTimeCollector's recovery: `observe()` runs on the composition
-- root's ticker, `collect()` handles the session pause/resume topics. The
-- interval is closed on every tick, not only on a change, so a stay that
-- crosses a level-up is split between the two levels.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local MetricId = ns.core.MetricId
local EventTopic = ns.core.EventTopic
local PlaceKey = ns.core.PlaceKey

local PlaceTimeCollector = {}
PlaceTimeCollector.__index = PlaceTimeCollector

PlaceTimeCollector.id = MetricId.PLACE_TIME
PlaceTimeCollector.topics = { EventTopic.SESSION_STARTED, EventTopic.SESSION_ENDED }

function PlaceTimeCollector.new(options)
  options = options or {}
  if options.clock == nil then
    error("PlaceTimeCollector needs a clock", 2)
  end
  Port.verify(ns.core.Clock, options.clock, "PlaceTimeCollector clock")

  return setmetatable({
    clock = options.clock,
    sessionActive = true,

    -- The open interval's place and the two raw halves it was built from, so a
    -- tick compares two values instead of building a key to throw away.
    key = nil,
    context = nil,
    areaId = nil,

    -- Clock reading the open interval started at; nil means nothing to close.
    mark = nil,
  }, PlaceTimeCollector)
end

-- Credits the open interval to its place on the record current at this instant,
-- which puts a stretch that crosses a level-up on the right level, and starts a
-- fresh mark.
function PlaceTimeCollector:closeInterval(record, now)
  if self.mark ~= nil and self.sessionActive and record ~= nil and self.key ~= nil then
    local elapsed = now - self.mark
    if elapsed > 0 then
      self:entryIn(record).seconds = self:entryIn(record).seconds + elapsed
    end
  end
  self.mark = now
end

-- The current place's entry in the current record, cached between ticks:
-- `placeEntry` keys by `key:id()`, which PlaceKey formats fresh each call, five
-- times a second. The cache is invalid exactly when the place or the record
-- changes.
function PlaceTimeCollector:entryIn(record)
  if self.entry == nil or self.entryRecord ~= record or self.entryKey ~= self.key then
    self.entry = record:placeEntry(self.key)
    self.entryRecord = record
    self.entryKey = self.key
  end
  return self.entry
end

function PlaceTimeCollector:collect(record, _, topic)
  local now = self.clock:now()

  if topic == EventTopic.SESSION_ENDED then
    self:closeInterval(record, now)
    self.sessionActive = false
    return
  end

  -- A resumed session starts its own interval: the time logged out belongs to
  -- no place.
  self.sessionActive = true
  self.mark = now
end

-- The sampled half. `context, areaId, name` are the player state port's answer,
-- passed through so this never knows about unit tokens or instances.
function PlaceTimeCollector:observe(record, context, areaId, name)
  if record == nil or not self.sessionActive then
    -- The open interval is abandoned, not carried across the gap: `record` is nil
    -- while experience gain is off, and no session topic fires then, so a kept
    -- mark would credit the whole gap to the place the character stopped in.
    self.mark = nil
    return
  end

  self:closeInterval(record, self.clock:now())

  -- `self.key == nil` is the first tick, distinct from "the client answered nil":
  -- the unknown place is a place and must accrue time in the reserved entry.
  --
  -- `named` covers a name that arrives late: a zone sampled during a loading
  -- screen has no name until a tick or two later. The name is not part of a
  -- place's identity (PlaceKey), so rebuilding adopts the label without moving
  -- time to another row. `self.areaId ~= nil` excludes the reserved bucket, which
  -- takes no name and would otherwise be rebuilt on every tick.
  local named = self.key ~= nil and self.areaId ~= nil and self.key.name == nil and name ~= nil
  if self.key == nil or named or context ~= self.context or areaId ~= self.areaId then
    self.context, self.areaId = context, areaId
    self.key = PlaceKey.new(context, areaId, name)
  end
end

ns.core.PlaceTimeCollector = PlaceTimeCollector
