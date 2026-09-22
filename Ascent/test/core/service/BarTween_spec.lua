describe("BarTween", function()
  local ns, BarTween
  local CHANNELS = { "mob_kill", "quest_turnin", "exploration", "unknown" }

  before_each(function()
    ns = AscentTest.loadDomain("core/service/Easing.lua", "core/service/BarTween.lua")
    BarTween = ns.core.BarTween
  end)

  local function tween(options)
    options = options or {}
    options.channels = options.channels or CHANNELS
    return BarTween.new(options)
  end

  -- Puts the tween at a state without animating there, which is what a fresh
  -- login does: there is no previous frame to move from.
  local function settleAt(subject, shares)
    subject:setTarget(shares, 0)
    return subject
  end

  local function runToRest(subject, dt)
    local frames = 0
    while subject:advance(dt or 1 / 60) do
      frames = frames + 1
      assert.is_true(frames < 10000, "never came to rest")
    end
    return frames
  end

  it("needs the channels it animates", function()
    assert.has_error(function() BarTween.new({}) end)
    assert.has_error(function() BarTween.new({ channels = {} }) end)
  end)

  it("turns per-channel shares into cumulative boundaries", function()
    local subject = settleAt(tween(), { mob_kill = 0.3, quest_turnin = 0.2, unknown = 0.1 })

    assert.same({ 0.3, 0.5, 0.5, 0.6 }, subject:boundaries())
  end)

  it("places a channel the caller left out on its neighbour's edge, not out of the vector", function()
    local subject = settleAt(tween(), { mob_kill = 0.4 })
    local values = subject:boundaries()

    assert.equal(4, #values)
    assert.equal(0.4, values[2])
    assert.equal(0.4, values[4])
  end)

  it("lands on the target exactly, not a float away from it", function()
    local subject = settleAt(tween(), {})
    subject:setTarget({ mob_kill = 1 }, 1)
    runToRest(subject)

    assert.equal(1, subject:boundaries()[1])
    assert.equal(1, subject:boundaries()[4])
  end)

  it("arrives at the same place whatever the framerate", function()
    local slow = settleAt(tween(), { mob_kill = 0.1 })
    local fast = settleAt(tween(), { mob_kill = 0.1 })
    slow:setTarget({ mob_kill = 0.7, unknown = 0.1 }, 1)
    fast:setTarget({ mob_kill = 0.7, unknown = 0.1 }, 1)

    runToRest(slow, 1 / 30)
    runToRest(fast, 1 / 144)

    assert.same(slow:boundaries(), fast:boundaries())
  end)

  it("is at the same point halfway through whatever the framerate", function()
    local coarse = settleAt(tween({ duration = 1 }), { mob_kill = 0.1 })
    local fine = settleAt(tween({ duration = 1 }), { mob_kill = 0.1 })
    coarse:setTarget({ mob_kill = 0.9 }, 1)
    fine:setTarget({ mob_kill = 0.9 }, 1)

    for _ = 1, 15 do coarse:advance(1 / 30) end
    for _ = 1, 72 do fine:advance(1 / 144) end

    assert.is_true(math.abs(coarse:boundaries()[1] - fine:boundaries()[1]) < 1e-9)
  end)

  it("keeps the vector monotonic on every single frame", function()
    local subject = settleAt(tween(), { mob_kill = 0.6, unknown = 0.2 })
    subject:setTarget({ mob_kill = 0.1, quest_turnin = 0.5, exploration = 0.2 }, 1)

    repeat
      local values = subject:boundaries()
      for index = 2, #values do
        assert.is_true(values[index] >= values[index - 1] - 1e-12, "vector dipped mid-move")
      end
    until not subject:advance(1 / 60)
  end)

  it("grows a channel that appears for the first time out of nothing", function()
    local subject = settleAt(tween(), { mob_kill = 0.5 })
    subject:setTarget({ mob_kill = 0.5, exploration = 0.1 }, 1)

    local saw = false
    repeat
      local values = subject:boundaries()
      local width = values[3] - values[2]
      assert.is_true(width >= 0)
      if width > 0 and width < 0.1 then saw = true end
    until not subject:advance(1 / 60)

    assert.is_true(saw, "the new channel jumped to its full width instead of growing")
    assert.is_true(math.abs((subject:boundaries()[3] - subject:boundaries()[2]) - 0.1) < 1e-12)
  end)

  -- A reclassification moves experience already counted out of "unclassified"
  -- and into the source it came from. The total does not change, so the
  -- right-hand edge of the progress must not move, or it would read as a
  -- glitch.
  it("does not move the end of the progress during a reclassification", function()
    local subject = settleAt(tween(), { mob_kill = 0.3, unknown = 0.2 })
    subject:setTarget({ mob_kill = 0.5, unknown = 0 }, 1)

    local frames = 0
    repeat
      frames = frames + 1
      assert.equal(0.5, subject:boundaries()[4], "the total moved on frame " .. frames)
    until not subject:advance(1 / 60)

    assert.is_true(frames > 1, "the move was instant, so it proved nothing")
    assert.equal(0.5, subject:boundaries()[1])
  end)

  it("hands back the same table for thousands of frames", function()
    local subject = settleAt(tween(), { mob_kill = 0.1 })
    local first = subject:boundaries()

    for round = 1, 200 do
      subject:setTarget({ mob_kill = (round % 10) / 10 }, 1)
      for _ = 1, 10 do subject:advance(1 / 60) end
      assert.is_true(rawequal(first, subject:boundaries()), "allocated a new table on round " .. round)
    end
  end)

  it("stops doing work once it has arrived", function()
    local subject = settleAt(tween(), {})
    subject:setTarget({ mob_kill = 0.5 }, 1)
    runToRest(subject)

    assert.is_false(subject:isMoving())
    assert.is_false(subject:advance(1 / 60))
  end)

  it("lands immediately at a motion scale of zero", function()
    local subject = settleAt(tween(), {})

    subject:setTarget({ mob_kill = 0.5, unknown = 0.25 }, 0)

    assert.is_false(subject:isMoving())
    assert.same({ 0.5, 0.5, 0.5, 0.75 }, subject:boundaries())
  end)

  it("ends up in the same place with motion on and motion off", function()
    local animated = settleAt(tween(), { mob_kill = 0.2 })
    local instant = settleAt(tween(), { mob_kill = 0.2 })

    animated:setTarget({ mob_kill = 0.4, quest_turnin = 0.3 }, 1)
    runToRest(animated)
    instant:setTarget({ mob_kill = 0.4, quest_turnin = 0.3 }, 0)

    assert.same(instant:boundaries(), animated:boundaries())
  end)

  it("takes longer at a smaller motion scale, without changing where it lands", function()
    local full = settleAt(tween(), {})
    local half = settleAt(tween(), {})
    full:setTarget({ mob_kill = 1 }, 1)
    half:setTarget({ mob_kill = 1 }, 0.5)

    assert.is_true(runToRest(half) < runToRest(full))
    assert.same(full:boundaries(), half:boundaries())
  end)

  it("never pushes a boundary past the end of the bar", function()
    local subject = settleAt(tween(), {})
    subject:setTarget({ mob_kill = 0.8, quest_turnin = 0.8 }, 0)

    for _, value in ipairs(subject:boundaries()) do
      assert.is_true(value <= 1)
    end
  end)

  it("ignores a negative share rather than reversing a boundary", function()
    local subject = settleAt(tween(), { mob_kill = -0.5, quest_turnin = 0.2 })

    assert.same({ 0, 0.2, 0.2, 0.2 }, subject:boundaries())
  end)
end)
