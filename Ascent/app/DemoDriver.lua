-- Ascent - a bar to look at, without playing.
--
-- Drives the bar on demand through every visual state (a source appearing, a
-- reclassification, a level-up) from a synthetic level that never touches the
-- player's data. It lives in app/: core/ may not hold test doubles, ui/ only
-- draws what it is given, and only the composition root can suspend the real
-- redraw while the demo is on screen, or the next 5 Hz tick would paint the
-- player's level over it.
--
-- The synthetic record writes LevelRecord's fields directly, since the model has
-- no public way to add experience outside attribution. Every step asserts
-- `sourcesAddUp`, so a drifting demo fails here instead of drawing a bar that
-- could not happen.

local _, ns = ...
ns.app = ns.app or {}

local XpSource = ns.core.XpSource
local LevelRecord = ns.core.LevelRecord
local PlaceKey = ns.core.PlaceKey
local PlaceContext = ns.core.PlaceContext

local XP_REQUIRED = 25000
local START_LEVEL = 23

-- Each step states the experience held by each source after it, plus the two
-- channels that are not earned experience (rested, pending). Absolute rather
-- than incremental, so every step reads on its own and the list can be walked
-- either way. The order is a script: a plausible stretch of levelling.
local STEPS = {
  {
    name = "fresh level",
    xp = {},
    rested = 0, pending = 0,
  },
  {
    name = "first kills",
    xp = { [XpSource.MOB_KILL] = 2100 },
    rested = 0, pending = 0,
  },
  {
    name = "rested reserve",
    xp = { [XpSource.MOB_KILL] = 3400 },
    rested = 4200, pending = 0,
  },
  {
    name = "quest turned in",
    xp = { [XpSource.MOB_KILL] = 3400, [XpSource.QUEST_TURNIN] = 4300 },
    rested = 3100, pending = 0,
  },
  {
    -- The one that matters most visually: a channel that did not exist grows
    -- out of nothing and pushes the ones after it along.
    name = "zone discovered",
    xp = { [XpSource.MOB_KILL] = 3400, [XpSource.QUEST_TURNIN] = 4300, [XpSource.EXPLORATION] = 900 },
    rested = 3100, pending = 0,
  },
  {
    name = "quests accepted",
    xp = { [XpSource.MOB_KILL] = 3400, [XpSource.QUEST_TURNIN] = 4300, [XpSource.EXPLORATION] = 900 },
    rested = 3100, pending = 5200,
  },
  {
    -- Experience the client confirmed but attribution has not settled yet.
    --
    -- Also the step the options panel previews: all four sources in clearly
    -- different proportions, a rested reserve and a pending projection at once.
    -- Not a round half of the level, because a tidy number hides the rounding
    -- and seam problems a preview is for.
    name = "unclassified gain",
    preview = true,
    xp = {
      [XpSource.MOB_KILL] = 3400, [XpSource.QUEST_TURNIN] = 4300,
      [XpSource.EXPLORATION] = 900, [XpSource.UNKNOWN] = 1800,
    },
    rested = 2400, pending = 5200,
  },
  {
    -- Settling: the same total, moved from unclassified to where it really came
    -- from. The right-hand edge of the progress must not move at all.
    name = "reclassified",
    xp = {
      [XpSource.MOB_KILL] = 5200, [XpSource.QUEST_TURNIN] = 4300,
      [XpSource.EXPLORATION] = 900, [XpSource.UNKNOWN] = 0,
    },
    rested = 2400, pending = 5200,
  },
  {
    -- A source holding far less than a pixel, to exercise the minimum-visible
    -- rule where it actually bites.
    name = "a sliver of a source",
    xp = {
      [XpSource.MOB_KILL] = 5200, [XpSource.QUEST_TURNIN] = 4300,
      [XpSource.EXPLORATION] = 900, [XpSource.UNKNOWN] = 20,
    },
    rested = 2400, pending = 5200,
  },
  {
    name = "almost there",
    xp = {
      [XpSource.MOB_KILL] = 12800, [XpSource.QUEST_TURNIN] = 9100,
      [XpSource.EXPLORATION] = 1900, [XpSource.UNKNOWN] = 20,
    },
    rested = 400, pending = 5200,
  },
  {
    name = "level up",
    levelUp = true,
    xp = { [XpSource.MOB_KILL] = 600 },
    rested = 6000, pending = 5200,
  },
}

-- The same experience, seen from where it was earned: split across two places
-- plus a zone crossed with none, because the bar's crossed reading only has
-- something to show when there is a place split behind it.
--
-- This covers the bar only. The report panel is built around the live tracker,
-- so its per-place block is exercised by the smoke harness seeding the record in
-- progress instead (test/smoke.lua).
local function placeRecord(record, total)
  if total <= 0 then
    return
  end

  local underground = math.floor(total * 0.6)
  local outside = total - underground
  local shares = {
    { key = PlaceKey.new(PlaceContext.DUNGEON, 389, "Ragefire Chasm"), amount = underground, seconds = 900 },
    { key = PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest"), amount = outside, seconds = 1200 },
    -- No experience at all: the zone crossed on the way. The other two rates
    -- are only believable next to a row like this.
    { key = PlaceKey.new(PlaceContext.WORLD, 1433, "Westfall"), amount = 0, seconds = 300 },
  }

  local remaining = { }
  for source, amount in pairs(record.xpBySource) do
    if amount > 0 then
      remaining[#remaining + 1] = { source = source, amount = amount }
    end
  end

  -- Handed out source by source so each place's breakdown adds up to its own
  -- total, which is the invariant the crossed reading rests on.
  local index = 1
  for _, share in ipairs(shares) do
    local entry = record:placeEntry(share.key)
    entry.seconds = share.seconds
    local left = share.amount
    while left > 0 and index <= #remaining do
      local take = math.min(left, remaining[index].amount)
      entry.xpTotal = entry.xpTotal + take
      entry.xpBySource[remaining[index].source] = (entry.xpBySource[remaining[index].source] or 0) + take
      remaining[index].amount = remaining[index].amount - take
      left = left - take
      if remaining[index].amount == 0 then
        index = index + 1
      end
    end
  end
end

local function buildRecord(level, step)
  local record = LevelRecord.new(level, 0)
  record.xpRequired = XP_REQUIRED
  record.playedSeconds = 2400

  local total = 0
  for source, amount in pairs(step.xp) do
    record.xpBySource[source] = amount
    total = total + amount
  end
  record.xpTotal = total

  -- A demo that broke the central invariant would show a bar the real code can
  -- never produce.
  if not record:sourcesAddUp() then
    error("DemoDriver built a level whose sources do not add up: " .. step.name)
  end

  placeRecord(record, total)

  return record
end

local DemoDriver = {}
DemoDriver.__index = DemoDriver

-- One step of the script, built whole, for a caller that wants a representative
-- level without driving anything (the options panel's live preview). Kept here
-- so the addon has one synthetic level; a second one inside ui/ would drift from
-- this script.
function DemoDriver.sample()
  for _, step in ipairs(STEPS) do
    if step.preview then
      return {
        record = buildRecord(START_LEVEL, step),
        restedXp = step.rested,
        questPending = step.pending,
      }
    end
  end
  error("DemoDriver has no step marked as the preview")
end

-- `options`: bar (the XpBarView to drive), logger, and onStop (called when the
-- demo ends, so the composition root can put the real bar back).
function DemoDriver.new(options)
  options = options or {}
  if options.bar == nil then
    error("DemoDriver needs a bar", 2)
  end

  return setmetatable({
    bar = options.bar,
    logger = options.logger,
    onStop = options.onStop,
    active = false,
    index = 0,
    level = START_LEVEL,
    record = nil,
  }, DemoDriver)
end

function DemoDriver:isActive()
  return self.active
end

function DemoDriver:show(step)
  if step.levelUp then
    self.level = self.level + 1
  end
  self.record = buildRecord(self.level, step)
  self.bar:update(self.record, {
    restedXp = step.rested,
    questPending = step.pending,
    showQuestPending = true,
    xpPerHour = 41000,
    timeToLevel = 1260,
    sessionTime = 3600,
  })
  if self.logger ~= nil then
    self.logger:info(("demo %d/%d: %s"):format(self.index, #STEPS, step.name))
  end
end

-- Advances one step, starting the demo if it was not running. Wraps around at
-- the end and starts the level over, so walking a skin through every state is
-- one key pressed repeatedly rather than a command per state.
function DemoDriver:step()
  if not self.active then
    self.active = true
    self.index = 0
    self.level = START_LEVEL
  end

  self.index = self.index + 1
  if self.index > #STEPS then
    self.index = 1
    self.level = START_LEVEL
  end

  self:show(STEPS[self.index])
  return self
end

function DemoDriver:stop()
  if not self.active then
    return self
  end
  self.active = false
  self.index = 0
  self.record = nil
  if self.onStop ~= nil then
    self.onStop()
  end
  if self.logger ~= nil then
    self.logger:info("demo off")
  end
  return self
end

function DemoDriver:stepNames()
  local names = {}
  for index, step in ipairs(STEPS) do
    names[index] = step.name
  end
  return names
end

ns.app.DemoDriver = DemoDriver
