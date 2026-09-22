-- Ascent - Clock port.
--
-- Two clocks that must not be mixed: `now` measures durations inside a session,
-- `timestamp` dates persisted instants. A duration taken from `timestamp` counts
-- the time the client was closed.

local _, ns = ...
ns.core = ns.core or {}

ns.core.Clock = ns.core.Port.define("Clock", {
  now = "Monotonic seconds since the client started. Use for measuring durations "
     .. "inside a session. Unaffected by /reload or by returning to the character "
     .. "select screen, and meaningless across sessions.",

  timestamp = "Seconds since the epoch. Use for instants that get persisted, such "
           .. "as when a level started. Never use it to measure a duration: the "
           .. "player's clock can move.",
})
