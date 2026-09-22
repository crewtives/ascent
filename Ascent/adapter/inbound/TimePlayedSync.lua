-- Ascent - the server's time-played anchor.
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
-- a floor of sixty seconds between requests, never two in flight. Every extra
-- request risks a message in the player's chat if the silencing fails while one
-- is already running.
--
-- A generation counter, not a cancelled timer, tells a late safety timeout apart
-- from a live one: C_Timer offers no cancel handle here, and a timeout whose
-- generation no longer matches finds nothing left to do.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Port = ns.core.Port
local WowEvent = ns.core.WowEvent
local EventTopic = ns.core.EventTopic
-- The figure the server sends back is a client read like any other.
local readable = ns.adapter.Readable.value

local MIN_INTERVAL = 60
local SAFETY_SECONDS = 15

-- How long the silence is held after the first answer lands. One request comes
-- back two to four times on Burning Crusade Classic, all in the same instant with
-- the same number, and restoring the chat frames on the first one re-registers
-- them inside that very dispatch, so the repetitions would print.
--
-- Held on a timer rather than on a count of expected answers because the count is
-- not known: it has never been measured on Classic Era, and calibrating to four
-- would fail silently on a client that sends five.
local SETTLE_SECONDS = 3

-- After the window closes, how long an arriving message is still more likely to
-- be a straggler of our own request than something the player asked for. It
-- changes no behaviour -- the message is on screen either way -- only which
-- counter it lands in, so a window that closed too early shows up in the
-- evidence file.
local LATE_HORIZON = 30

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
    -- False suppresses every request, so the evidence can show whether the
    -- server ever sends time played unprompted. Read at construction, not a
    -- runtime toggle: the first request fires from PLAYER_ENTERING_WORLD, during
    -- the loading screen, so nothing typed afterwards can precede it.
    requests = options.requests ~= false,

    lastRequestAt = nil,
    inFlight = false,
    -- The first answer landed and the repetitions may still be coming: the chat
    -- frames stay silenced through this.
    settling = false,
    releasedAt = nil,
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
  -- Any window still open belongs to the previous request; this one supersedes
  -- it. Left set, a straggler of the old request would be read as the first
  -- answer to the new one.
  self.settling = false
  self.lastRequestAt = self.clock:now()
  self.generation = self.generation + 1
  local generation = self.generation

  if self.recordEvidence ~= nil then
    self.recordEvidence("timePlayedRequested", { at = self.lastRequestAt })
  end

  C_Timer.After(SAFETY_SECONDS, function()
    self:onTimeout(generation)
  end)

  -- Lets a session check the cadence rules (once entering the world, once per
  -- level-up, a floor of MIN_INTERVAL, never two in flight) against reality.
  if self.logger ~= nil then
    self.logger:debug(("RequestTimePlayed() sent at %.3f"):format(self.lastRequestAt))
  end

  RequestTimePlayed()
  return true
end

-- A stale timeout -- the response already landed and its window already closed,
-- or a newer request superseded this one -- finds nothing left to do and touches
-- nothing.
--
-- It covers the settling state too: this timer guarantees the player is never
-- left permanently silenced, and holding the silence past the first answer is a
-- second way to be stuck. It fires at SAFETY_SECONDS against the window's
-- SETTLE_SECONDS, so in an ordinary run it finds the window closed.
function TimePlayedSync:onTimeout(generation)
  if not (self.inFlight or self.settling) or generation ~= self.generation then
    return
  end
  self.settling = false
  restoreChatFrames()
  self.inFlight = false
end

-- Not in flight means nothing here asked for this message: a stray
-- TIME_PLAYED_MSG (the /played command, another addon) is not this addon's
-- business and the chat frames were never silenced for it.
--
-- Logged before that early return on purpose: a TIME_PLAYED_MSG arriving while
-- inFlight is false is what shows the server sending it unprompted.
function TimePlayedSync:onTimePlayedMsg(_, timePlayedThisLevel)
  -- Before anything below compares it, prints it, or hands it to the recorder,
  -- whose file is the saved variables: a closed figure is one this addon lacks.
  timePlayedThisLevel = readable(timePlayedThisLevel)
  local now = self.clock:now()
  local mine = self.inFlight or self.settling

  if self.logger ~= nil then
    self.logger:debug(("TIME_PLAYED_MSG received at %.3f: levelSeconds=%s inFlight=%s")
      :format(now, tostring(timePlayedThisLevel), tostring(self.inFlight)))
  end
  -- To the evidence file as well as the debug log, and above the early return:
  -- `inFlight = false` here is the unprompted case, and a 500-line ring shared
  -- with three lines per kill will not still hold it when the session ends.
  --
  -- Every answer is counted, not only the first, so the repetitions that could
  -- reach the player's chat are measured.
  if self.recordEvidence ~= nil then
    self.recordEvidence("timePlayedReceived", {
      at = now,
      levelSeconds = timePlayedThisLevel,
      requested = mine,
      repeated = (mine and not self.inFlight) or nil,
    })
  end

  if not mine then
    -- Nothing here asked for this: the chat frames were never silenced and the
    -- message is on screen, which is right for a /played the player typed.
    --
    -- Counted apart by how recently our own window closed, because it can also
    -- be a straggler that arrived too late, the risk of holding the silence on a
    -- timer. Without this the evidence could not tell the two apart.
    if self.recordEvidence ~= nil then
      local late = self.releasedAt ~= nil and (now - self.releasedAt) <= LATE_HORIZON
      self.recordEvidence(late and "timePlayedLate" or "timePlayedUnrequested", { at = now })
    end
    return
  end

  if not self.inFlight then
    -- A repetition inside the window: counted above, still silenced, and not
    -- published again. The figure is identical to the one already published.
    return
  end

  -- The first answer. The chat frames stay silenced on purpose: restoring them
  -- here re-registers them inside this dispatch, and the repetitions that follow
  -- print. They are released by onSettled, once the window closes.
  self.inFlight = false
  self.settling = true
  local generation = self.generation
  C_Timer.After(SETTLE_SECONDS, function()
    self:onSettled(generation)
  end)

  if type(timePlayedThisLevel) == "number" and timePlayedThisLevel >= 0 then
    self.bus:publish(EventTopic.TIME_PLAYED_SYNCED, { levelSeconds = timePlayedThisLevel })
  end
end

-- The window closing. Keyed on the generation for the same reason the safety
-- timeout is: a newer request may have started meanwhile, and restoring then
-- would unsilence a live one.
function TimePlayedSync:onSettled(generation)
  if not self.settling or generation ~= self.generation then
    return
  end
  self.settling = false
  self.releasedAt = self.clock:now()
  restoreChatFrames()
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

-- Stopping mid-flight also restores the chat frames: this frame is the only one
-- that could hear TIME_PLAYED_MSG back, so leaving them silenced would strand
-- them until the safety timer fires, and an answer landing in that window would
-- reach no listener at all and be lost, not delayed.
function TimePlayedSync:stop()
  if self.frame == nil then
    return self
  end
  self.frame:UnregisterAllEvents()
  self.frame = nil

  -- Settling counts as mid-request here: the frames are silenced in that state
  -- too, and this frame is the only thing that could ever release them.
  if self.inFlight or self.settling then
    restoreChatFrames()
    self.inFlight = false
    self.settling = false
  end
  return self
end

ns.adapter.TimePlayedSync = TimePlayedSync
