-- Ascent - the bar's geometry, moving (tasks 4.2, 4.3, 4.4, 4.8).
--
-- The bar does not animate a number. It animates a SET of pieces that push each
-- other along, and the shape chosen for that set is what makes the hard cases
-- fall out for free (design D25): a vector of CUMULATIVE BOUNDARIES -- where
-- each channel's right edge sits, as a fraction of the bar -- with one fixed
-- slot per channel, indexed by the channel's IDENTITY rather than by its
-- position in an array.
--
-- Why identity and not position: `segments` is built from whichever sources
-- actually paid something, so it changes length the moment a source appears or
-- stops appearing. Animating by position would then interpolate mobs' old edge
-- towards quests' new one -- a real bug, and one that would only ever show up on
-- the frame a player discovers a zone for the first time.
--
-- What the shape buys, without a special case for any of it:
--
--   * A source that appears grows from zero and pushes the ones after it along,
--     which is exactly what the eye expects to see.
--   * A RECLASSIFICATION -- experience moving out of "unclassified" into the
--     source it really came from once attribution settles (D21) -- moves only
--     INTERIOR boundaries. The last one has the same from and to, so the right
--     edge of the progress does not move by so much as a subpixel. Without that,
--     the addon's most honest moment would look like a glitch.
--   * Every channel shares ONE clock, so if the start and the end are both
--     monotonic, every frame in between is too: no piece can cross another.
--
-- Duration times the motion scale is the only knob. At a scale of zero the
-- duration is zero and the very first advance lands on the target -- "animations
-- off" is this same code with a shorter clock, not a second path that rots
-- because nobody exercises it (D33).

local _, ns = ...
ns.core = ns.core or {}

local Easing = ns.core.Easing

local BarTween = {}
BarTween.__index = BarTween

local DEFAULT_DURATION = 0.35

-- `options`:
--   channels  the ids, in draw order. Fixed for the tween's life.
--   duration  seconds a move takes at full motion scale
--   easing    an EasingName
function BarTween.new(options)
  options = options or {}
  if type(options.channels) ~= "table" or #options.channels == 0 then
    error("BarTween needs the channels it animates", 2)
  end

  local slots = {}
  local edges, from, target = {}, {}, {}
  for index, id in ipairs(options.channels) do
    slots[id] = index
    edges[index], from[index], target[index] = 0, 0, 0
  end

  return setmetatable({
    channels = options.channels,
    slots = slots,
    duration = options.duration or DEFAULT_DURATION,
    easing = options.easing or Easing.DEFAULT,
    -- Mutated in place, forever, and handed out by reference on purpose: see
    -- the note on boundaries() below. Named apart from the method that returns
    -- it because a field and a method of the same name cannot coexist on one
    -- table in Lua -- the field wins and the method becomes uncallable.
    edges = edges,
    from = from,
    target = target,
    elapsed = 0,
    span = 0,
    moving = false,
  }, BarTween)
end

-- `shares` maps a channel id to the fraction of the bar THAT channel holds --
-- not its boundary. The accumulation happens here so that a channel the caller
-- left out simply holds nothing, which places its boundary exactly on its
-- neighbour's and gives it zero width, rather than removing it from the vector.
--
-- `motionScale` of 0 collapses the move to an instant one. Anything else scales
-- the duration.
function BarTween:setTarget(shares, motionScale)
  shares = shares or {}
  local running = 0
  local changed = false

  for index, id in ipairs(self.channels) do
    local share = shares[id] or 0
    if share < 0 then share = 0 end
    running = running + share
    local edge = running > 1 and 1 or running
    if edge ~= self.target[index] then
      changed = true
    end
    self.target[index] = edge
    self.from[index] = self.edges[index]
  end

  if not changed and not self.moving then
    return self
  end

  local scale = motionScale
  if type(scale) ~= "number" or scale < 0 then
    scale = 1
  end
  self.span = self.duration * (scale > 1 and 1 or scale)
  self.elapsed = 0
  self.moving = true

  -- A zero-length move still goes through advance(), so there is exactly one
  -- place where values are written and exactly one definition of "arrived".
  if self.span <= 0 then
    self:advance(0)
  end

  return self
end

-- Advances by `dt` seconds and returns whether anything is still moving.
--
-- Returning false is what lets the caller stop paying for motion entirely: the
-- composition root's per-frame call does nothing measurable once this says the
-- bar has arrived, which is the "idle costs nothing" the design asks for.
--
-- Framerate independence is structural rather than tuned: the position is a
-- function of elapsed/span, so thirty frames of 1/30s and a hundred and
-- forty-four of 1/144s land on exactly the same place.
function BarTween:advance(dt)
  if not self.moving then
    return false
  end

  self.elapsed = self.elapsed + (dt or 0)

  local t = 1
  if self.span > 0 and self.elapsed < self.span then
    t = self.elapsed / self.span
  end

  local eased = Easing.at(self.easing, t)
  for index = 1, #self.channels do
    local origin = self.from[index]
    self.edges[index] = origin + (self.target[index] - origin) * eased
  end

  if t >= 1 then
    -- Snapped to the target rather than left at whatever the curve computed:
    -- the resting state has to be the exact number, not one float away from it,
    -- or a bar at 100% can sit a hair short of its own end forever.
    for index = 1, #self.channels do
      self.edges[index] = self.target[index]
    end
    self.moving = false
  end

  return self.moving
end

-- The live boundary vector, in draw order. ALWAYS THE SAME TABLE: this is read
-- every frame, and returning a fresh one would allocate sixty times a second for
-- the lifetime of the session. That cost does not show up in a CPU profile --
-- it shows up later, as collection pauses nobody can trace back here -- so it is
-- a property with a test of its own rather than a comment.
function BarTween:boundaries()
  return self.edges
end

function BarTween:isMoving()
  return self.moving
end

ns.core.BarTween = BarTween
