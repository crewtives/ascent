-- Ascent - the bar's geometry, moving.
--
-- The tween animates a vector of cumulative boundaries (where each channel's
-- right edge sits, as a fraction of the bar) with one fixed slot per channel,
-- indexed by the channel's identity rather than its position in an array:
-- `segments` holds only the sources that paid something, so it changes length
-- when one appears, and animating by position would slide one source's old edge
-- towards another's new one.
--
-- With that shape, and no special case:
--
--   * A source that appears grows from zero and pushes the ones after it along.
--   * A reclassification (experience moving out of "unclassified" into the
--     source it really came from once attribution settles) moves only interior
--     boundaries; the last one has the same from and to, so the right edge of
--     the progress does not move by so much as a subpixel.
--   * Every channel shares one clock, so if the start and the end are both
--     monotonic, every frame in between is too: no piece can cross another.
--
-- Duration times the motion scale is the only knob. At a scale of zero the first
-- advance lands on the target: "animations off" runs this same code path.

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
    -- Mutated in place and handed out by reference; see boundaries(). Named
    -- apart from that method because a field of the same name on the instance
    -- would shadow it and make it uncallable.
    edges = edges,
    from = from,
    target = target,
    elapsed = 0,
    span = 0,
    moving = false,
  }, BarTween)
end

-- `shares` maps a channel id to the fraction of the bar that channel holds,
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

-- Advances by `dt` seconds and returns whether anything is still moving. False
-- lets the composition root's per-frame call stop doing work once the bar has
-- arrived, so an idle bar costs nothing.
--
-- The position is a function of elapsed/span, so the motion is framerate
-- independent: thirty frames of 1/30s and 144 of 1/144s land on the same place.
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
    -- Snapped to the exact target rather than what the curve computed, or a bar
    -- at 100% can sit a hair short of its own end forever.
    for index = 1, #self.channels do
      self.edges[index] = self.target[index]
    end
    self.moving = false
  end

  return self.moving
end

-- The live boundary vector, in draw order. Always the same table: it is read
-- every frame, and a fresh one would allocate sixty times a second for the whole
-- session, a cost that shows up as collection pauses rather than in a CPU
-- profile. A test pins this property.
function BarTween:boundaries()
  return self.edges
end

function BarTween:isMoving()
  return self.moving
end

ns.core.BarTween = BarTween
