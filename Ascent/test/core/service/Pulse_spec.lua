describe("Pulse", function()
  local ns, Pulse

  before_each(function()
    ns = AscentTest.loadDomain("core/service/Pulse.lua")
    Pulse = ns.core.Pulse
  end)

  it("starts dark and inactive", function()
    local pulse = Pulse.new()

    assert.equal(0, pulse:alpha())
    assert.is_false(pulse:isActive())
    assert.is_false(pulse:advance(1 / 60))
  end)

  it("lights up when bumped", function()
    local pulse = Pulse.new():bump()

    assert.is_true(pulse:alpha() > 0)
    assert.is_true(pulse:isActive())
  end)

  it("never goes past its ceiling, however many times it is bumped", function()
    local pulse = Pulse.new()

    for _ = 1, 50 do
      pulse:bump()
      assert.is_true(pulse:alpha() <= 0.55)
    end
  end)

  -- A burst must not produce a falling edge between bumps: repeated, that is a
  -- strobe. Between two bumps the amplitude only decreases and a bump only
  -- increases it, so the shape is a single rise and a single fall, never an
  -- oscillation through zero.
  it("never drops back to nothing in the middle of a burst", function()
    local pulse = Pulse.new()

    for _ = 1, 6 do
      pulse:bump()
      for _ = 1, 4 do
        pulse:advance(1 / 60)
        assert.is_true(pulse:alpha() > 0, "the flash went dark mid-burst")
      end
    end
  end)

  it("gets brighter when bumped again rather than starting over", function()
    local pulse = Pulse.new():bump()
    local first = pulse:alpha()
    pulse:advance(0.05)
    local faded = pulse:alpha()
    pulse:bump()

    assert.is_true(faded < first)
    assert.is_true(pulse:alpha() > faded)
  end)

  it("fades monotonically once it stops being bumped", function()
    local pulse = Pulse.new():bump()
    local previous = pulse:alpha()

    while pulse:advance(1 / 60) do
      assert.is_true(pulse:alpha() <= previous)
      previous = pulse:alpha()
    end
  end)

  it("goes out, so the caller can stop drawing it", function()
    local pulse = Pulse.new():bump():bump():bump()

    local frames = 0
    while pulse:advance(1 / 60) do
      frames = frames + 1
      assert.is_true(frames < 600, "the flash never went out")
    end

    assert.equal(0, pulse:alpha())
    assert.is_false(pulse:isActive())
  end)

  it("fades the same amount of time whatever the framerate", function()
    local coarse, fine = Pulse.new():bump(), Pulse.new():bump()

    for _ = 1, 30 do coarse:advance(1 / 30) end
    for _ = 1, 144 do fine:advance(1 / 144) end

    assert.is_true(math.abs(coarse:alpha() - fine:alpha()) < 1e-9)
  end)
end)
