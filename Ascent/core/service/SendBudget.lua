-- Ascent - how often the addon is allowed to speak (design D67).
--
-- The client hands each registered prefix ten messages back at one per second,
-- and going past that returns AddonMessageThrottle -- or, with enough traffic on
-- enough prefixes, disconnects the player. Nothing this addon has to say is worth
-- that, so it spends far less than it is given: a couple of announcements in
-- reserve, refilled every fifteen seconds.
--
-- What it counts is ROUNDS, not messages. One round announces to whichever of the
-- channels are available at that moment, and a player is realistically in at most
-- two of them at once -- a guild and one kind of group. So a burst at full reserve
-- costs about four messages against an allowance of ten, and steady state costs
-- one round a quarter of a minute.
--
-- A refused round is DROPPED, never queued. A queue drains at the worst possible
-- moment, which for this addon means during a pull; and an announcement that never
-- goes out costs nobody anything, because the next client to log in says the same
-- thing.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local Clock = ns.core.Clock
local UpdateBudget = ns.core.UpdateBudget

local SendBudget = {}
SendBudget.__index = SendBudget

function SendBudget.new(options)
  options = options or {}
  Port.verify(Clock, options.clock, "SendBudget.clock")

  local capacity = options.capacity or UpdateBudget.CAPACITY
  local refillSeconds = options.refillSeconds or UpdateBudget.REFILL_SECONDS

  return setmetatable({
    clock = options.clock,
    capacity = capacity,
    refillSeconds = refillSeconds,
    -- Starts full: the first thing the addon does after logging in is announce
    -- itself, and a bucket that filled up over the following minute would make
    -- the one moment that matters the one moment it cannot speak.
    tokens = capacity,
    lastRefill = options.clock:now(),
  }, SendBudget)
end

-- Monotonic seconds, so this is immune to the player's clock moving. The refill
-- advances `lastRefill` by whole periods only -- moving it to `now` would throw
-- away the fraction already accumulated and make the real rate slower than the
-- stated one, indefinitely.
function SendBudget:refill()
  local elapsed = self.clock:now() - self.lastRefill
  if elapsed < self.refillSeconds then
    return
  end

  local earned = math.floor(elapsed / self.refillSeconds)
  self.tokens = math.min(self.capacity, self.tokens + earned)
  self.lastRefill = self.lastRefill + (earned * self.refillSeconds)
end

-- True exactly when a round may go out now, and it consumes the allowance.
-- Callers do not retry a false: the budget is the answer, not a suggestion.
function SendBudget:allow()
  self:refill()

  if self.tokens < 1 then
    return false
  end

  self.tokens = self.tokens - 1
  return true
end

ns.core.SendBudget = SendBudget
