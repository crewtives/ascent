-- Ascent - experience gained since this client session started (7.2).
--
-- "Session" here is D14's definition: the current client run, stable across
-- /reload and the character select screen, gone only when the client itself
-- restarts. clock:now() already measures that elapsed time directly -- no
-- tracking needed for it -- but the experience gained over it is not something
-- any existing record carries, because a LevelRecord resets to zero at every
-- level and a session can cross several. This is the one piece of state that
-- has to exist for the session's own xp/hour (7.2) to mean anything: a running
-- total, fed by every XP_ATTRIBUTED gain regardless of which level it landed on.
--
-- Deliberately NOT tied to EventTopic.SESSION_STARTED/SESSION_ENDED: those fire
-- on every PLAYER_ENTERING_WORLD, including a loading screen mid-session, not
-- only on login (WowEventRouter's own header explains why: they exist to
-- re-anchor after a gap, a narrower job than D14's session). Resetting this
-- tracker there would make the session's pace jump every time the player enters
-- a dungeon, which is not what "how fast am I leveling this sitting" means.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local EventTopic = ns.core.EventTopic

local SessionXpTracker = {}
SessionXpTracker.__index = SessionXpTracker

function SessionXpTracker.new(options)
  options = options or {}
  if options.bus == nil then
    error("SessionXpTracker needs a bus", 2)
  end
  Port.verify(ns.core.EventBusPort, options.bus, "SessionXpTracker bus")

  local tracker = setmetatable({ xpGained = 0 }, SessionXpTracker)

  tracker.subscription = options.bus:subscribe(EventTopic.XP_ATTRIBUTED, function(payload)
    tracker:onAttributed(payload)
  end)

  return tracker
end

-- The whole amount the player received, rested bonus included: the session's
-- pace is about how fast the character is actually leveling, and a bonused
-- gain is real experience the same as any other.
function SessionXpTracker:onAttributed(payload)
  if type(payload) ~= "table" or payload.gain == nil then
    return
  end
  self.xpGained = self.xpGained + payload.gain.amount
end

function SessionXpTracker:total()
  return self.xpGained
end

ns.core.SessionXpTracker = SessionXpTracker
