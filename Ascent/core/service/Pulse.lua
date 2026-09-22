-- Ascent - a flash that cannot become a strobe.
--
-- The bar flashes when a segment grows, which happens on every kill, often
-- several times a second during a multi-pull. A flash that fires again
-- reinforces the one in flight instead of restarting it: one amplitude decays
-- continuously and a bump adds to it up to a ceiling. Nothing resets it to zero,
-- so there is no falling edge to flicker on, and a burst of kills is one
-- brighter, longer glow. No minimum interval, no dropped bumps.

local _, ns = ...
ns.core = ns.core or {}

local Pulse = {}
Pulse.__index = Pulse

-- The flash's maximum opacity, kept below a white flash: it sits over the bar's
-- colours and must brighten them, not replace them.
local PEAK = 0.55

-- What one bump adds. Two in a row are visibly stronger than one; more saturate
-- at the ceiling.
local BOOST = 0.3

-- Seconds for the amplitude to fall to about a third of where it was.
local DECAY = 0.35

-- Below this the flash is invisible, so it snaps to zero and the caller can go
-- idle.
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

-- Exponential rather than linear, because a linear fade ends on a visible edge.
-- Framerate-independent, like BarTween: the decay depends on elapsed time, not
-- on frame count.
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
