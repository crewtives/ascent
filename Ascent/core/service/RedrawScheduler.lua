-- Ascent - throttles how often a view is allowed to redraw.
--
-- Views mark themselves dirty when a change topic arrives and redraw at most five
-- times a second from a single accumulating OnUpdate. This is only the throttle,
-- markDirty()/tick(), with no frame or client; the OnUpdate that calls tick() every
-- frame lives in ui/.
--
--   * A burst of markDirty() calls is still just "dirty": only whether it happened
--     at least once since the last redraw matters.
--   * The first tick after construction is not held back by minInterval: there is
--     no previous redraw to measure from.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port

local RedrawScheduler = {}
RedrawScheduler.__index = RedrawScheduler

local DEFAULT_MIN_INTERVAL = 0.2 -- 5 Hz

function RedrawScheduler.new(options)
  options = options or {}
  if options.clock == nil then
    error("RedrawScheduler needs a clock", 2)
  end
  Port.verify(ns.core.Clock, options.clock, "RedrawScheduler clock")

  return setmetatable({
    clock = options.clock,
    minInterval = options.minInterval or DEFAULT_MIN_INTERVAL,
    dirty = false,
    lastRedrawAt = nil,
  }, RedrawScheduler)
end

function RedrawScheduler:markDirty()
  self.dirty = true
end

-- True the moment a redraw is due, and only then. A `true` commits the caller to
-- drawing: the flag clears and the interval restarts in the same call.
function RedrawScheduler:tick()
  if not self.dirty then
    return false
  end

  local now = self.clock:now()
  if self.lastRedrawAt ~= nil and (now - self.lastRedrawAt) < self.minInterval then
    return false
  end

  self.dirty = false
  self.lastRedrawAt = now
  return true
end

ns.core.RedrawScheduler = RedrawScheduler
