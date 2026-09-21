-- Ascent - a flash that cannot become a strobe (task 4.6).
--
-- The bar flashes when a segment grows, and a segment grows every time the
-- player kills something. Over a levelling session that is thousands of times,
-- often several within the same second during a multi-pull -- which is exactly
-- the shape of input that turns a nice touch into a headache.
--
-- The rule the design asks for (D33) is "a flash that fires again REINFORCES the
-- one in flight rather than restarting it", and the model here is what makes
-- that true by construction rather than by a rate limiter: there is a single
-- amplitude that decays continuously, and a bump ADDS to it up to a ceiling.
-- Because nothing ever resets the amplitude to zero, there is no falling edge to
-- flicker on: a burst of five kills is one brighter, slightly longer glow, not
-- five flashes. No minimum interval, no dropped bumps, no special case.
--
-- Pure arithmetic, so the guarantee is a test rather than a screenshot.

local _, ns = ...
ns.core = ns.core or {}

local Pulse = {}
Pulse.__index = Pulse

-- The most opaque the flash is ever allowed to be. Deliberately below what the
-- eye reads as a "flash of white": this sits on top of the bar's own colours and
-- has to brighten them, not replace them.
local PEAK = 0.55

-- What one bump adds. Two in a row are visibly stronger than one; four are not
-- four times stronger, because the ceiling is close.
local BOOST = 0.3

-- Seconds for the amplitude to fall to about a third of where it was.
local DECAY = 0.35

-- Below this the flash is indistinguishable from nothing, so it is snapped to
-- zero -- which is also what lets the caller stop drawing it and go idle.
local FLOOR = 0.01

function Pulse.new(options)
  options = options or {}
  return setmetatable({
    peak = options.peak or PEAK,
    boost = options.boost or BOOST,
    decay = options.decay or DECAY,
    amplitude = 0,
  }, Pulse)
end

function Pulse:bump()
  self.amplitude = math.min(self.peak, self.amplitude + self.boost)
  return self
end

-- Exponential rather than linear so that the tail is long and soft: a linear
-- fade ends on a visible edge, which is the very thing this module exists to
-- avoid. Framerate-independent for the same reason BarTween is -- the decay is
-- a function of the time actually elapsed, not of how many frames went by.
function Pulse:advance(dt)
  if self.amplitude <= 0 then
    return false
  end
  self.amplitude = self.amplitude * math.exp(-(dt or 0) / self.decay)
  if self.amplitude < FLOOR then
    self.amplitude = 0
  end
  return self.amplitude > 0
end

function Pulse:alpha()
  return self.amplitude
end

function Pulse:isActive()
  return self.amplitude > 0
end

ns.core.Pulse = Pulse
