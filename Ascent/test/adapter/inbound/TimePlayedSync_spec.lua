-- Three awkward parts, each with its own block below: the server never pushes
-- the figure (cadence), TIME_PLAYED_MSG cannot be filtered out of chat
-- (silencing), and RequestTimePlayed is a round trip that may never come back
-- (the safety timer, told apart from a live response by a generation counter:
-- C_Timer.After has no cancel handle).

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
    return AscentTest.loadWith("core/port/", "adapter/compat/Readable.lua", "adapter/inbound/TimePlayedSync.lua",
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

    -- Restoring on the first answer would re-register the frames inside the
    -- client's own dispatch of TIME_PLAYED_MSG, so the repetitions that follow
    -- would print. The silence is held until the settle window closes.
    it("keeps them silenced when the first response arrives, and releases them after", function()
      sync:request()

      sync:onTimePlayedMsg(0, 100)
      assert.is_false(chatFrames[1].registered)
      assert.is_false(chatFrames[2].registered)

      fireTimeout() -- the settle window closing

      assert.is_true(chatFrames[1].registered)
      assert.is_true(chatFrames[2].registered)
    end)

    -- One request is answered two to four times on Burning Crusade Classic, and
    -- the count is unmeasured on Classic Era, so this asserts what does not
    -- depend on it: however many arrive, none is on screen.
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

    -- After the first answer the frames stay silenced until the settle window
    -- closes; if its timer never ran, the safety timer must release them.
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

    -- Between the first answer and the window closing the frames are still
    -- silenced, and nothing else would release them: stopping without restoring
    -- would leave the chat muted for good.
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

  -- A TIME_PLAYED_MSG the server sent unprompted shows up as a receipt logged
  -- while inFlight is false, which the early return in onTimePlayedMsg would
  -- otherwise hide.
  describe("request diagnostics (optional logger)", function()
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

  -- Telling whether the server sends time played unprompted needs the addon to
  -- stop requesting it on entering the world (requests = false), and the answer
  -- goes to the evidence recorder, where a session of kills cannot push it out.
  describe("with requests off, listening for an answer nobody asked for", function()
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

    -- Silencing without requesting would strand the chat frames until the safety
    -- timer.
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

    -- Every answer is counted and the repetitions are marked, so an evidence file
    -- says how many a single request produces; on Classic Era that is unmeasured.
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

    -- The silence is held on a timer, not a count: if the window is too short on
    -- some client, the straggler that got through must leave a trace, or it would
    -- look exactly like the player typing /played.
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

    -- Suppression is opt-in, and a recorder is optional.
    it("requests exactly once when nothing was asked of it", function()
      local sent = 0
      _G.RequestTimePlayed = function() sent = sent + 1 end

      assert.is_true(ns.adapter.TimePlayedSync.new({ bus = bus, clock = clock }):request())
      assert.equal(1, sent)
    end)
  end)

  -- A closed time played is a figure this addon does not have: nothing is anchored
  -- to it, and the recorder, which writes to the saved variables file, is not
  -- handed a value it cannot keep.
  describe("on a client that closes the figure", function()
    it("anchors nothing to a time played it cannot read", function()
      local recorded = {}
      local closed
      AscentTest.withSecretRegime(function()
        local scoped = load()
        closed = scoped.adapter.TimePlayedSync.new({
          bus = bus, clock = clock,
          recordEvidence = function(kind, fields) recorded[#recorded + 1] = { kind = kind, fields = fields } end,
        })
      end)
      closed:request()

      AscentTest.withClientTypes(function()
        assert.has_no.errors(function()
          closed:onTimePlayedMsg(AscentTest.secret(9999), AscentTest.secret(450))
        end)
      end)

      assert.equal(0, bus:countOf(EventTopic.TIME_PLAYED_SYNCED))
      local received
      for _, entry in ipairs(recorded) do
        if entry.kind == "timePlayedReceived" then received = entry end
      end
      assert.is_not_nil(received)
      assert.is_nil(received.fields.levelSeconds)
    end)
  end)
end)
