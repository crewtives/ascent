-- Ascent - experience gained since this client session started.
--
-- A session is the current client run: stable across /reload and the character
-- select screen, ended only when the client restarts. clock:now() measures its
-- time; its experience needs this running total, fed by every XP_ATTRIBUTED gain
-- whatever level it landed on, since a LevelRecord resets at each level.
--
-- Not tied to EventTopic.SESSION_STARTED/SESSION_ENDED: those fire on every
-- PLAYER_ENTERING_WORLD, loading screens included (see WowEventRouter's header),
-- and resetting there would restart the session's pace at every dungeon.

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

-- The whole amount received, rested bonus included: the session's pace is how
-- fast the character is actually leveling.
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
