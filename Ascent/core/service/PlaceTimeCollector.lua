-- Ascent - metric collector: how long the level spent in each place.
--
-- The experience half of a place entry comes from the ledger, one gain at a time.
-- This is the other half, and it is the one that makes the entry worth having: a
-- rate needs a denominator, and without time a place can only say what it paid,
-- never what it paid per hour.
--
-- It is also the only writer that records a place the player earned NOTHING in.
-- Walking across a zone to reach the next one costs the level real minutes, and a
-- breakdown that showed only the places that paid would quietly flatter every one
-- of them -- the zone that ate twenty minutes for no experience would simply not
-- appear, and the dungeon's rate would look like the whole story.
--
-- The client has no event for "the character changed place" that this could react
-- to, so time is SAMPLED, exactly as CombatTimeCollector samples recovery (D23):
-- `observe()` runs on the composition root's own ticker with whatever the player
-- state says right now, while `collect()` handles the two bus topics that pause
-- and resume a session like every other collector.
--
-- Two things keep the per-frame cost where the budget wants it. The place key is
-- rebuilt only when the place actually changes -- the common case is a tick that
-- finds the character exactly where the last one left them -- and a call with no
-- level open, or with the session paused, returns before touching the clock.
--
-- The interval is closed on EVERY tick and not only on a change, for the same
-- reason the combat collector does it: a level-up in the middle of a long stay
-- fires nothing at all here, so without a periodic close the whole stay would land
-- on whichever level happened to be open when the character finally moved.

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

    -- The place the open interval belongs to, and the two raw halves it was built
    -- from -- kept so a tick can tell "same place" from "new place" by comparing
    -- two values instead of building a key to throw away.
    key = nil,
    context = nil,
    areaId = nil,

    -- The clock reading the open interval started at. nil means there is nothing
    -- to close yet.
    mark = nil,
  }, PlaceTimeCollector)
end

-- Credits the open interval to whichever place it belongs to, on whichever record
-- is current AT THIS INSTANT -- which is what puts a stretch that crosses a
-- level-up on the level it actually happened in -- and starts a fresh mark.
function PlaceTimeCollector:closeInterval(record, now)
  if self.mark ~= nil and self.sessionActive and record ~= nil and self.key ~= nil then
    local elapsed = now - self.mark
    if elapsed > 0 then
      self:entryIn(record).seconds = self:entryIn(record).seconds + elapsed
    end
  end
  self.mark = now
end

-- The entry for the current place in the current record, remembered between
-- ticks. Without this, a character standing still still pays for a string.format
-- and a tostring on every one of the five ticks a second, for the whole session:
-- `placeEntry` keys the map by `key:id()`, and PlaceKey builds that string fresh
-- each time. The cache is invalid exactly when the place changes or the level
-- does, and both are cheap to compare.
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

  -- A session that starts again starts its own interval: the hours in between were
  -- spent logged out, and crediting them to the place the character logged out in
  -- is the one answer that is certainly wrong.
  self.sessionActive = true
  self.mark = now
end

-- The sampled half. `context, areaId, name` are the three values the player state
-- port answers with, passed straight through so this never has to know that a unit
-- token or an instance exists.
function PlaceTimeCollector:observe(record, context, areaId, name)
  if record == nil or not self.sessionActive then
    -- The open interval is ABANDONED, not carried across the gap. `record` is nil
    -- for as long as experience gain is switched off, and the session topics do
    -- not fire in that state either -- so leaving the mark standing meant the
    -- first tick after recording resumed credited the whole gap, hours of it, to
    -- whichever place the character happened to be in when it stopped. Dropping
    -- the mark costs nothing and reads the clock zero times.
    self.mark = nil
    return
  end

  self:closeInterval(record, self.clock:now())

  -- `self.key == nil` is the first tick, and it is not the same state as "the
  -- client answered nil": the unknown place is a place, and comparing only the two
  -- halves would leave a character who logs in somewhere the client cannot name
  -- accruing no time at all, which is the exact case the reserved entry is for.
  --
  -- The third condition is the name arriving LATE, and it is not the same as the
  -- place changing. A zone first sampled during a loading screen answers with no
  -- name, and the client supplies one a tick or two later; without this the key
  -- was rebuilt only on a change of context or area, so that stay stayed nameless
  -- for its whole duration and the panel reported hours spent "somewhere the
  -- client could not name" for a zone it names perfectly well now. Rebuilding is
  -- safe precisely because the name is NOT part of a place's identity (PlaceKey):
  -- the same context and area is the same entry, so this adopts a label without
  -- ever moving the time to a different row.
  -- `self.areaId ~= nil` guards the reserved bucket: a place the client could not
  -- identify at all has no room for a name, and PlaceKey hands back the same
  -- nameless bucket whatever it is told, so without this the key would be
  -- rebuilt on every tick a nameless somewhere reported zone text.
  local named = self.key ~= nil and self.areaId ~= nil and self.key.name == nil and name ~= nil
  if self.key == nil or named or context ~= self.context or areaId ~= self.areaId then
    self.context, self.areaId = context, areaId
    self.key = PlaceKey.new(context, areaId, name)
  end
end

ns.core.PlaceTimeCollector = PlaceTimeCollector
