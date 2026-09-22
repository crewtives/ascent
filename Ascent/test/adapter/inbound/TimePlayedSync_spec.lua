-- D14's three awkward parts, each with its own case below: the server never
-- pushes the figure (cadence), the response cannot be filtered out of chat
-- (silencing), and it is a round trip that may never come back (the safety timer,
-- told apart from a live response by a generation counter rather than a cancel
-- handle Lua's timers do not have).

describe("TimePlayedSync", function()
  local ns, EventTopic
  local bus, clock, sync
  local chatFrames, timers

  local function stubChatFrame()
    local frame = { registered = true }
    function frame:RegisterEvent() self.registered = true end
    function frame:UnregisterEvent() self.registered = false end
    return frame
  end

  local function load()
    return AscentTest.loadWith("core/port/", "adapter/inbound/TimePlayedSync.lua",
      "test/fakes/FakeClock.lua", "test/fakes/RecordingEventBus.lua")
  end

  before_each(function()
    ns = load()
    EventTopic = ns.core.EventTopic

    clock = ns.fakes.FakeClock.new(1000)
    bus = ns.fakes.RecordingEventBus.new()

    chatFrames = { stubChatFrame(), stubChatFrame() }
    _G.Constants = { ChatFrameConstants = { MaxChatWindows = 2 } }
    _G.ChatFrame1, _G.ChatFrame2 = chatFrames[1], chatFrames[2]

    timers = {}
    _G.C_Timer = { After = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end }

    _G.RequestTimePlayed = function() end

    sync = ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock })
  end)

  after_each(function()
    _G.Constants = nil
    _G.ChatFrame1, _G.ChatFrame2 = nil, nil
    _G.C_Timer = nil
    _G.RequestTimePlayed = nil
  end)

  local function fireTimeout(index)
    timers[index or #timers].fn()
  end

  describe("cadence", function()
    it("sends the first request", function()
      assert.is_true(sync:request())
    end)

    it("refuses a second request while one is already in flight", function()
      sync:request()

      assert.is_false(sync:request())
    end)

    it("refuses a request inside sixty seconds of the last one, even once it answered", function()
      sync:request()
      sync:onTimePlayedMsg(0, 100) -- answered, no longer in flight

      clock:advance(59)
      assert.is_false(sync:request())
    end)

    it("allows a request once sixty seconds have passed since the last one", function()
      sync:request()
      sync:onTimePlayedMsg(0, 100)

      clock:advance(60)
      assert.is_true(sync:request())
    end)
  end)

  describe("silencing chat while a request is in flight", function()
    it("unregisters TIME_PLAYED_MSG from every chat frame on request", function()
      sync:request()

      assert.is_false(chatFrames[1].registered)
      assert.is_false(chatFrames[2].registered)
    end)

    -- This used to assert that the first answer released them, and that
    -- assertion WAS the defect (D77): restoring here re-registers the frames
    -- inside the client's own dispatch, so the two to four repetitions that
    -- follow print. The silence is held until the window closes.
    it("keeps them silenced when the first response arrives, and releases them after", function()
      sync:request()

      sync:onTimePlayedMsg(0, 100)
      assert.is_false(chatFrames[1].registered)
      assert.is_false(chatFrames[2].registered)

      fireTimeout() -- the settle window closing

      assert.is_true(chatFrames[1].registered)
      assert.is_true(chatFrames[2].registered)
    end)

    -- The case the whole change exists for. The count is not known -- two to
    -- four seen in BC Classic, never measured in Era -- so this asserts the
    -- property that does not depend on it: however many arrive, none is on
    -- screen.
    it("keeps them silenced through every repetition, whatever their number", function()
      sync:request()

      for _ = 1, 6 do
        sync:onTimePlayedMsg(0, 100)
        assert.is_false(chatFrames[1].registered)
        assert.is_false(chatFrames[2].registered)
      end

      fireTimeout()

      assert.is_true(chatFrames[1].registered)
    end)

    it("publishes the figure once, not once per repetition", function()
      sync:request()

      for _ = 1, 4 do sync:onTimePlayedMsg(0, 450) end

      assert.equal(1, bus:countOf(EventTopic.TIME_PLAYED_SYNCED))
    end)

    it("does not silence a second time for a request the cadence already refused", function()
      sync:request()
      chatFrames[1].registered = true -- as if something else had restored it mid-flight

      sync:request() -- refused: already in flight

      assert.is_true(chatFrames[1].registered)
    end)
  end)

  describe("the response", function()
    it("publishes TIME_PLAYED_SYNCED with the level's played seconds", function()
      sync:request()

      sync:onTimePlayedMsg(9999, 450)

      assert.same({ levelSeconds = 450 }, bus:lastOn(EventTopic.TIME_PLAYED_SYNCED))
    end)

    it("ignores a message that arrives with nothing in flight -- not this addon's request", function()
      sync:onTimePlayedMsg(0, 100)

      assert.equal(0, bus:countOf(EventTopic.TIME_PLAYED_SYNCED))
      assert.is_true(chatFrames[1].registered) -- never silenced, so nothing to restore
    end)

    it("clears in-flight so the next request is not refused as a duplicate", function()
      sync:request()
      sync:onTimePlayedMsg(0, 100)

      clock:advance(60)
      assert.is_true(sync:request())
    end)
  end)

  describe("the safety timer", function()
    it("restores the chat frames if the response never arrives", function()
      sync:request()

      fireTimeout()

      assert.is_true(chatFrames[1].registered)
      assert.is_true(chatFrames[2].registered)
    end)

    it("does not publish anything -- a level with no anchor stays estimated, not wrongly synced", function()
      sync:request()

      fireTimeout()

      assert.equal(0, bus:countOf(EventTopic.TIME_PLAYED_SYNCED))
    end)

    it("clears in-flight, so a later request is not refused forever", function()
      sync:request()
      fireTimeout()

      clock:advance(60)
      assert.is_true(sync:request())
    end)

    it("still refuses a request right after a timeout -- cadence is not reset by it", function()
      sync:request()
      fireTimeout()

      assert.is_false(sync:request())
    end)

    -- Holding the silence past the first answer opened a second way to be stuck
    -- silenced: if the window's own timer never ran, nothing else would release
    -- the frames. This timer is what promises that cannot happen, so it has to
    -- know about the new state as well as the old one.
    it("releases the chat frames if the window's own timer never ran", function()
      sync:request()
      local safetyTimer = #timers
      sync:onTimePlayedMsg(0, 100)
      assert.is_false(chatFrames[1].registered)

      fireTimeout(safetyTimer) -- the settle timer never fires

      assert.is_true(chatFrames[1].registered)
      assert.is_true(chatFrames[2].registered)
    end)

    it("does nothing if the response already arrived and its window closed", function()
      sync:request()
      local safetyTimer = #timers
      sync:onTimePlayedMsg(0, 100)
      fireTimeout() -- the settle window closes, releasing them properly
      chatFrames[1].registered = false -- as if something else had silenced it again since

      fireTimeout(safetyTimer) -- the safety timer, arriving with nothing left to do

      assert.is_false(chatFrames[1].registered)
    end)

    it("does nothing for a superseded request -- an earlier generation's own timeout", function()
      sync:request()
      local firstTimeout = #timers

      sync:onTimePlayedMsg(0, 100)
      clock:advance(60)
      sync:request()
      chatFrames[1].registered = false -- the second request's own silencing

      fireTimeout(firstTimeout) -- the first request's timeout, arriving late

      assert.is_false(chatFrames[1].registered) -- untouched by the stale timeout
    end)
  end)

  describe("start/stop", function()
    local function stubFrame()
      local frame = { registered = {} }
      function frame:RegisterEvent(event) self.registered[event] = true end
      function frame:UnregisterAllEvents() self.registered = {} end
      function frame:SetScript(_, fn) self.onEvent = fn end
      return frame
    end

    it("registers for entering the world, levelling up, and the response, dispatching through them", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end

      sync:start()

      assert.is_true(frame.registered.PLAYER_ENTERING_WORLD)
      assert.is_true(frame.registered.PLAYER_LEVEL_UP)
      assert.is_true(frame.registered.TIME_PLAYED_MSG)

      frame.onEvent(frame, "PLAYER_ENTERING_WORLD")
      assert.is_true(sync.inFlight)

      frame.onEvent(frame, "TIME_PLAYED_MSG", 0, 100)
      assert.equal(1, bus:countOf(EventTopic.TIME_PLAYED_SYNCED))

      _G.CreateFrame = nil
    end)

    it("also dispatches PLAYER_LEVEL_UP to a request, not just PLAYER_ENTERING_WORLD", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end

      sync:start()
      frame.onEvent(frame, "PLAYER_ENTERING_WORLD")
      frame.onEvent(frame, "TIME_PLAYED_MSG", 0, 100) -- clears in-flight
      clock:advance(60) -- past the cadence floor

      frame.onEvent(frame, "PLAYER_LEVEL_UP")

      assert.is_true(sync.inFlight)
      _G.CreateFrame = nil
    end)

    it("restores the chat frames and clears in-flight if stopped mid-request", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end

      sync:start()
      frame.onEvent(frame, "PLAYER_ENTERING_WORLD") -- a request is now in flight
      assert.is_false(chatFrames[1].registered)

      sync:stop()

      assert.is_true(chatFrames[1].registered)
      assert.is_true(chatFrames[2].registered)
      assert.is_false(sync.inFlight)
      _G.CreateFrame = nil
    end)

    -- The same promise one state later. Between the first answer and the window
    -- closing the frames are still silenced, and this frame is the only thing
    -- that could ever release them -- so stopping there without restoring would
    -- leave the player muted with nobody left to undo it.
    it("restores the chat frames if stopped while the window is still open", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end

      sync:start()
      frame.onEvent(frame, "PLAYER_ENTERING_WORLD")
      frame.onEvent(frame, "TIME_PLAYED_MSG", 0, 100) -- answered; window now open
      assert.is_false(chatFrames[1].registered)

      sync:stop()

      assert.is_true(chatFrames[1].registered)
      assert.is_true(chatFrames[2].registered)
      assert.is_false(sync.settling)
      _G.CreateFrame = nil
    end)

    it("clears its frame on stop", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end

      sync:start()
      sync:stop()

      assert.is_nil(sync.frame)
      _G.CreateFrame = nil
    end)
  end)

  -- Spike 0.6: does the server ever send TIME_PLAYED_MSG without being asked?
  -- The answer is exactly a receipt logged while inFlight is false, which the
  -- early return in onTimePlayedMsg would otherwise make invisible.
  describe("spike 0.6 diagnostics (optional logger)", function()
    local function fakeLogger()
      local messages = {}
      return { debug = function(_, message) messages[#messages + 1] = message end }, messages
    end

    it("logs when a request is actually sent", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock, logger = logger })

      diagnosed:request()

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("RequestTimePlayed() sent at", 1, true))
    end)

    it("logs a receipt even while nothing is in flight, not just the ones it asked for", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock, logger = logger })

      diagnosed:onTimePlayedMsg(nil, 3600)

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("TIME_PLAYED_MSG received at", 1, true))
      assert.is_not_nil(joined:find("inFlight=false", 1, true))
    end)

    it("still works without a logger at all", function()
      assert.has_no.errors(function()
        ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock }):onTimePlayedMsg(nil, 100)
      end)
    end)
  end)

  -- Spike 0.6 asks whether the server sends time played unprompted. It could not
  -- be asked at all while the addon requested it on entering the world, and its
  -- answer could not survive a session while it went to a 500-line chat ring
  -- shared with three lines per kill.
  describe("running spike 0.6", function()
    local function recorder()
      local samples = {}
      return function(kind, fields)
        fields = fields or {}
        fields.kind = kind
        samples[#samples + 1] = fields
      end, samples
    end

    local function suppressed(extra)
      local options = { bus = bus, clock = clock, requests = false }
      for key, value in pairs(extra or {}) do options[key] = value end
      return ns.adapter.TimePlayedSync.new(options)
    end

    it("sends nothing at all when requests are suppressed", function()
      local sent = 0
      _G.RequestTimePlayed = function() sent = sent + 1 end
      local quiet = suppressed()

      assert.is_false(quiet:request())
      assert.equal(0, sent)
      assert.is_false(quiet.inFlight)
    end)

    -- Load-bearing: silencing without requesting would strand the chat frames
    -- until the safety timer, which is a worse bug than the one being diagnosed.
    it("leaves the chat frames alone when it suppresses a request", function()
      suppressed():request()

      for _, frame in ipairs(chatFrames) do
        assert.is_true(frame.registered)
      end
    end)

    it("still receives an unprompted message, and records that nobody asked", function()
      local record, samples = recorder()
      local quiet = suppressed({ recordEvidence = record })

      quiet:request()
      quiet:onTimePlayedMsg(nil, 4200)

      assert.equal("timePlayedSuppressed", samples[1].kind)
      assert.equal("timePlayedReceived", samples[2].kind)
      assert.equal(4200, samples[2].levelSeconds)
      assert.is_false(samples[2].requested)
      -- Never published: LevelTracker anchors off this topic, and a stray
      -- /played must not move the normal path for every player.
      assert.equal(0, bus:countOf(EventTopic.TIME_PLAYED_SYNCED))
    end)

    it("records a request it did send, and that the reply was the one it asked for", function()
      local record, samples = recorder()
      local asking = ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock, recordEvidence = record })

      asking:request()
      asking:onTimePlayedMsg(nil, 4200)

      assert.equal("timePlayedRequested", samples[1].kind)
      assert.is_true(samples[2].requested)
      assert.equal(1, bus:countOf(EventTopic.TIME_PLAYED_SYNCED))
    end)

    -- Counting one answer per request while the client sends four is how "what
    -- the player sees in the chat" ended up unmeasured. Every one is counted
    -- now, and the repetitions are marked as such so the file can say how many
    -- a single request really produces -- which is the number spike 0.1 goes
    -- looking for in Classic Era.
    it("counts every repetition, not just the first, and marks them as repeats", function()
      local record, samples = recorder()
      local asking = ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock, recordEvidence = record })

      asking:request()
      for _ = 1, 4 do asking:onTimePlayedMsg(nil, 4200) end

      local received = 0
      local repeats = 0
      for _, sample in ipairs(samples) do
        if sample.kind == "timePlayedReceived" then
          received = received + 1
          assert.is_true(sample.requested)
          if sample.repeated then repeats = repeats + 1 end
        end
      end
      assert.equal(4, received)
      assert.equal(3, repeats)
    end)

    -- The mitigation D77 owes for holding the silence on a timer instead of on a
    -- count: if the window is too short on some client, the straggler that got
    -- through has to leave a trace. Without this counter that failure would look
    -- exactly like the player typing /played, and nobody would ever find it.
    it("counts an answer that arrives just after the window as late, not as unrequested", function()
      local record, samples = recorder()
      local asking = ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock, recordEvidence = record })

      asking:request()
      asking:onTimePlayedMsg(nil, 4200)
      fireTimeout() -- the window closes
      clock:advance(2)
      asking:onTimePlayedMsg(nil, 4200)

      assert.equal("timePlayedLate", samples[#samples].kind)
    end)

    it("counts an answer long after the window as unrequested -- the player's own /played", function()
      local record, samples = recorder()
      local asking = ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock, recordEvidence = record })

      asking:request()
      asking:onTimePlayedMsg(nil, 4200)
      fireTimeout()
      clock:advance(600)
      asking:onTimePlayedMsg(nil, 4200)

      assert.equal("timePlayedUnrequested", samples[#samples].kind)
      -- On screen, which is correct: nothing here asked for it.
      assert.is_true(chatFrames[1].registered)
    end)

    -- The pin: suppression is opt-in, and a recorder is optional.
    it("requests exactly once when nothing was asked of it", function()
      local sent = 0
      _G.RequestTimePlayed = function() sent = sent + 1 end

      assert.is_true(ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock }):request())
      assert.equal(1, sent)
    end)
  end)
end)
