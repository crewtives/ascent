-- Ascent - how often the addon is allowed to speak.
--
-- The client gives each registered prefix ten messages, refilled at one per
-- second; past that C_ChatInfo.SendAddonMessage returns AddonMessageThrottle, and
-- enough traffic across prefixes can disconnect the player. This spends far less:
-- a couple of announcements in reserve, refilled every fifteen seconds.
--
-- It counts rounds, not messages. A round announces to whichever channels are
-- available, realistically at most two (a guild and one kind of group), so a
-- burst at full reserve costs about four messages of the ten.
--
-- A refused round is dropped, never queued: a queue could drain during a pull,
-- and a missed announcement costs nothing because the next client to log in
-- sends the same one.

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
    -- Starts full: the addon announces itself right after login.
    tokens = capacity,
    lastRefill = options.clock:now(),
  }, SendBudget)
end

-- Monotonic seconds, immune to the player's clock moving. `lastRefill` advances
-- by whole periods only; moving it to `now` would discard the accumulated
-- fraction and make the real rate slower than the stated one.
function SendBudget:refill()
  local elapsed = self.clock:now() - self.lastRefill
  if elapsed < self.refillSeconds then
    return
  end

  local earned = math.floor(elapsed / self.refillSeconds)
  self.tokens = math.min(self.capacity, self.tokens + earned)
  self.lastRefill = self.lastRefill + (earned * self.refillSeconds)
end

-- True exactly when a round may go out now, consuming the allowance. Callers do
-- not retry a false.
function SendBudget:allow()
  self:refill()

  if self.tokens < 1 then
    return false
  end

  self.tokens = self.tokens - 1
  return true
end

ns.core.SendBudget = SendBudget
