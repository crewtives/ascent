-- Ascent - throttles how often a view is allowed to redraw.
--
-- D7: views mark themselves dirty when a change topic arrives and redraw at most
-- five times a second from a single accumulating OnUpdate. This module is only the
-- throttle itself -- markDirty()/tick() -- with no notion of a frame or a client.
-- The `CreateFrame(...):SetScript("OnUpdate", ...)` that calls tick() every frame
-- is ui/'s job, not core's: it is the one piece of D7 that has to touch the client,
-- and everything that doesn't stays here where it can be tested without one.
--
-- Two things a naive throttle gets wrong, which is why they are called out:
--
--   * A burst of markDirty() calls is still just "dirty". There is no dirtier-than-
--     dirty, so the ledger of how many times it was called never matters -- only
--     whether it happened at least once since the last redraw.
--   * The first tick after construction is not held back by minInterval. There
--     was no previous redraw to measure the interval from, so waiting one anyway
--     would just be a made-up delay before the player ever sees a bar.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port

local RedrawScheduler = {}
RedrawScheduler.__index = RedrawScheduler

local DEFAULT_MIN_INTERVAL = 0.2 -- 5 Hz, per D7

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

-- True the moment a redraw is due, and only then -- calling this is what commits
-- to the redraw: the flag clears and the clock resets in the same call, so a
-- caller that gets `true` back is expected to actually draw.
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
