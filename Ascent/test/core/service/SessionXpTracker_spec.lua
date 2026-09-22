-- How much experience the character has received since the client started,
-- however many levels that spans.

describe("SessionXpTracker", function()
  local ns, SessionXpTracker, XpGain, XpSource, EventTopic, bus

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "core/service/SessionXpTracker.lua", "test/fakes/RecordingEventBus.lua")
    SessionXpTracker = ns.core.SessionXpTracker
    XpGain = ns.core.XpGain
    XpSource = ns.core.XpSource
    EventTopic = ns.core.EventTopic
    bus = ns.fakes.RecordingEventBus.new()
  end)

  local function attribute(amount, source)
    bus:publish(EventTopic.XP_ATTRIBUTED, {
      gain = XpGain.new({ amount = amount, source = source or XpSource.MOB_KILL, at = 0 }),
    })
  end

  it("starts at zero", function()
    local tracker = SessionXpTracker.new({ bus = bus })
    assert.equal(0, tracker:total())
  end)

  it("accumulates every attributed gain, whatever its source", function()
    local tracker = SessionXpTracker.new({ bus = bus })

    attribute(100, XpSource.MOB_KILL)
    attribute(250, XpSource.QUEST_TURNIN)
    attribute(40, XpSource.EXPLORATION)

    assert.equal(390, tracker:total())
  end)

  it("keeps accumulating across a level boundary, unlike a LevelRecord's own total", function()
    local tracker = SessionXpTracker.new({ bus = bus })

    attribute(100)
    -- No level boundary between the two: the tracker does not know which
    -- LevelRecord is open, so one running total covers a session that crossed
    -- several.
    attribute(150)

    assert.equal(250, tracker:total())
  end)

  it("ignores a malformed payload instead of erroring", function()
    local tracker = SessionXpTracker.new({ bus = bus })

    local ok = pcall(function()
      bus:publish(EventTopic.XP_ATTRIBUTED, {})
    end)

    assert.is_true(ok)
    assert.equal(0, tracker:total())
  end)

  it("requires a bus", function()
    assert.has_error(function() SessionXpTracker.new({}) end)
  end)
end)
