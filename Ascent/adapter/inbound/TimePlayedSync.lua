-- Ascent - the server's time-played anchor (D14).
--
-- `TIME_PLAYED_MSG` carries the one number nothing else here can give: how long the
-- character has actually played the current level, including whatever it had
-- already played before this addon was installed. Three things make it awkward:
--
--   * The server never pushes it. Getting it means calling RequestTimePlayed().
--   * The response cannot be filtered out of chat -- TIME_PLAYED_MSG is handled by
--     the chat frame's own system-event handler, which prints and stops before the
--     CHAT_MSG* filter chain it lives in even runs. The only lever is unregistering
--     the event from every chat frame around the request and registering it back.
--     `Constants.ChatFrameConstants.MaxChatWindows` is what walks them:
--     `NUM_CHAT_WINDOWS` and `ChatFrame_AddMessageEventFilter` are themselves
--     deprecated aliases behind the same CVar and may not exist.
--   * The response is a round trip, never read on the next line, so a safety timer
--     restores the chat frames if it never arrives -- the player is not left
--     permanently silenced by a request the server dropped.
--
-- The cadence is deliberately poor: once on entering the world, once per level-up,
-- a floor of sixty seconds between requests, never two in flight. The cost of
-- asking for more is the one message in the player's chat if the silencing ever
-- fails while a request is already running.
--
-- A generation counter, not a cancelled timer, is what tells a late safety timeout
-- apart from a live one: Lua's C_Timer has no cancel handle to speak of, and a
-- timeout whose generation no longer matches simply finds nothing left to do.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Port = ns.core.Port
local WowEvent = ns.core.WowEvent
local EventTopic = ns.core.EventTopic

local MIN_INTERVAL = 60
local SAFETY_SECONDS = 15

local function forEachChatFrame(fn)
  local max = Constants.ChatFrameConstants.MaxChatWindows
  for index = 1, max do
    local frame = _G["ChatFrame" .. index]
    if frame ~= nil then
      fn(frame)
    end
  end
end

local function silenceChatFrames()
  forEachChatFrame(function(frame) frame:UnregisterEvent(WowEvent.TIME_PLAYED_MSG) end)
end

local function restoreChatFrames()
  forEachChatFrame(function(frame) frame:RegisterEvent(WowEvent.TIME_PLAYED_MSG) end)
end

local TimePlayedSync = {}
TimePlayedSync.__index = TimePlayedSync

function TimePlayedSync.new(options)
  options = options or {}
  for _, required in ipairs({ "bus", "clock" }) do
    if options[required] == nil then
      error("TimePlayedSync needs a " .. required, 2)
    end
  end
  Port.verify(ns.core.EventBusPort, options.bus, "TimePlayedSync bus")
  Port.verify(ns.core.Clock, options.clock, "TimePlayedSync clock")

  return setmetatable({
    bus = options.bus,
    clock = options.clock,
    logger = options.logger,
    recordEvidence = options.recordEvidence,
    -- Spike 0.6 asks whether the server sends time played UNPROMPTED, and it
    -- cannot be asked while the addon requests it on entering the world. This is
    -- the suppression, and it has to be a value read at construction rather than a
    -- runtime toggle: the request fires from PLAYER_ENTERING_WORLD, during the
    -- loading screen, so nothing typed afterwards can precede it.
    requests = options.requests ~= false,

    lastRequestAt = nil,
    inFlight = false,
    generation = 0,

    frame = nil,
  }, TimePlayedSync)
end

-- Entry point for both triggers (entering the world, levelling up). Answers
-- whether a request actually went out, which is mostly useful to a test: the
-- cadence rules are enforced here, not by whoever calls this.
function TimePlayedSync:request()
  -- Before everything, and before silenceChatFrames in particular: silencing
  -- without requesting would strand the chat frames until the safety timer.
  if not self.requests then
    if self.recordEvidence ~= nil then
      self.recordEvidence("timePlayedSuppressed", { at = self.clock:now() })
    end
    return false
  end
  if self.inFlight then
    return false
  end
  if self.lastRequestAt ~= nil and (self.clock:now() - self.lastRequestAt) < MIN_INTERVAL then
    return false
  end

  silenceChatFrames()
  self.inFlight = true
  self.lastRequestAt = self.clock:now()
  self.generation = self.generation + 1
  local generation = self.generation

  if self.recordEvidence ~= nil then
    self.recordEvidence("timePlayedRequested", { at = self.lastRequestAt })
  end

  C_Timer.After(SAFETY_SECONDS, function()
    self:onTimeout(generation)
  end)

  -- Spike 0.6 reads this to check the cadence rules above (D14: once entering
  -- the world, once per level-up, a floor of MIN_INTERVAL between requests,
  -- never two in flight) against what actually happens in a real session.
  if self.logger ~= nil then
    self.logger:debug(("RequestTimePlayed() sent at %.3f"):format(self.lastRequestAt))
  end

  RequestTimePlayed()
  return true
end

-- A stale timeout -- the response already landed, or a newer request superseded
-- this one -- finds nothing left to do and touches nothing.
function TimePlayedSync:onTimeout(generation)
  if not self.inFlight or generation ~= self.generation then
    return
  end
  restoreChatFrames()
  self.inFlight = false
end

-- Not in flight means nothing here asked for this message, so nothing here
-- answers for it either: a stray TIME_PLAYED_MSG (the /played command, another
-- addon) is not this addon's business and the chat frames were never silenced
-- for it.
--
-- Logged BEFORE that early return, deliberately: spike 0.6 asks whether the
-- server ever sends this unprompted, and the answer to that is exactly a
-- TIME_PLAYED_MSG arriving while inFlight is false -- the one case the early
-- return below would otherwise make invisible.
function TimePlayedSync:onTimePlayedMsg(_, timePlayedThisLevel)
  if self.logger ~= nil then
    self.logger:debug(("TIME_PLAYED_MSG received at %.3f: levelSeconds=%s inFlight=%s")
      :format(self.clock:now(), tostring(timePlayedThisLevel), tostring(self.inFlight)))
  end
  -- To the file as well as to the chat ring, and for the same reason the debug
  -- line sits above the early return rather than below it: `inFlight = false` here
  -- IS the answer to spike 0.6, and a 500-line ring shared with three lines per
  -- kill will not still be holding it when the session ends.
  if self.recordEvidence ~= nil then
    self.recordEvidence("timePlayedReceived", {
      at = self.clock:now(),
      levelSeconds = timePlayedThisLevel,
      requested = self.inFlight,
    })
  end

  if not self.inFlight then
    return
  end

  restoreChatFrames()
  self.inFlight = false

  if type(timePlayedThisLevel) == "number" and timePlayedThisLevel >= 0 then
    self.bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = timePlayedThisLevel })
  end
end

function TimePlayedSync:start()
  if self.frame ~= nil then
    return self
  end

  local frame = CreateFrame("Frame")
  frame:RegisterEvent(WowEvent.PLAYER_ENTERING_WORLD)
  frame:RegisterEvent(WowEvent.PLAYER_LEVEL_UP)
  frame:RegisterEvent(WowEvent.TIME_PLAYED_MSG)
  frame:SetScript("OnEvent", function(_, event, ...)
    if event == WowEvent.TIME_PLAYED_MSG then
      self:onTimePlayedMsg(...)
    else
      self:request()
    end
  end)

  self.frame = frame
  return self
end

-- Stopping mid-flight is not just tearing down the frame: this frame is the only
-- thing that could ever have heard TIME_PLAYED_MSG back, so leaving the chat
-- frames silenced would strand them until the safety timer eventually fires, and
-- the server's answer -- if it lands in that window -- would arrive to no
-- listener at all and simply be lost, not delayed.
function TimePlayedSync:stop()
  if self.frame == nil then
    return self
  end
  self.frame:UnregisterAllEvents()
  self.frame = nil

  if self.inFlight then
    restoreChatFrames()
    self.inFlight = false
  end
  return self
end

ns.adapter.TimePlayedSync = TimePlayedSync
