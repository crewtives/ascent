-- Ascent - the real Clock, backed by the client's two timebases.
--
-- `GetTime()` is monotonic seconds since the client started: stable across
-- /reload and the character select screen, meaningless across sessions.
-- `time()` is the epoch: what gets persisted. Mixing them up is how a level ends
-- up claiming it took nine hours because the player went to bed -- see the Clock
-- port for the full rationale.

local _, ns = ...
ns.adapter = ns.adapter or {}

local WowClock = {}
WowClock.__index = WowClock

function WowClock.new()
  return ns.core.Port.verify(ns.core.Clock, setmetatable({}, WowClock), "WowClock")
end

function WowClock:now()
  return GetTime()
end

function WowClock:timestamp()
  return time()
end

ns.adapter.WowClock = WowClock
