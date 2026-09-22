-- Ascent - the real Clock, backed by the client's two timebases.
--
-- `GetTime()` is monotonic seconds since the client started: stable across
-- /reload and the character select screen, meaningless across sessions.
-- `time()` is the epoch, and is what gets persisted. A duration measured on the
-- epoch would include the hours the client was closed; the Clock port has the
-- full contract.

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
