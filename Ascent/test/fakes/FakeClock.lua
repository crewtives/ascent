-- A clock the test drives by hand. Nothing in the suite may depend on real time:
-- a test that sleeps is a test that is slow and flaky at once.

local _, ns = ...
ns.fakes = ns.fakes or {}

local FakeClock = {}
FakeClock.__index = FakeClock

function FakeClock.new(startNow, startTimestamp)
  local clock = setmetatable({
    monotonic = startNow or 0,
    epoch = startTimestamp or 1700000000,
  }, FakeClock)

  return ns.core.Port.verify(ns.core.Clock, clock, "FakeClock")
end

function FakeClock:now()
  return self.monotonic
end

function FakeClock:timestamp()
  return self.epoch
end

-- Time passes for both clocks at once, as it does in the world.
function FakeClock:advance(seconds)
  self.monotonic = self.monotonic + seconds
  self.epoch = self.epoch + seconds
  return self
end

-- Jump the wall clock only: what a player changing their system time looks like.
function FakeClock:setTimestamp(epoch)
  self.epoch = epoch
  return self
end

ns.fakes.FakeClock = FakeClock
