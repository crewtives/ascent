describe("Easing", function()
  local ns, Easing, EasingName

  before_each(function()
    ns = AscentTest.loadDomain("core/service/Easing.lua")
    Easing = ns.core.Easing
    EasingName = ns.core.EasingName
  end)

  local function everyName()
    local names = {}
    for _, value in ns.core.Frozen.each(EasingName) do
      names[#names + 1] = value
    end
    return names
  end

  it("starts every curve at exactly zero and ends it at exactly one", function()
    for _, name in ipairs(everyName()) do
      assert.equal(0, Easing.at(name, 0), name .. " does not start at zero")
      assert.equal(1, Easing.at(name, 1), name .. " does not end at one")
    end
  end)

  -- Not a style preference: a curve that overshoots would drive one boundary
  -- past its neighbour's, and pieces of the bar crossing each other mid-move is
  -- a defect. If an overshoot curve is ever wanted, the tween has to clamp first.
  it("keeps every curve inside the unit interval all the way along", function()
    for _, name in ipairs(everyName()) do
      for step = 0, 100 do
        local value = Easing.at(name, step / 100)
        assert.is_true(value >= 0 and value <= 1, name .. " leaves [0,1] at t=" .. step / 100)
      end
    end
  end)

  it("never goes backwards", function()
    for _, name in ipairs(everyName()) do
      local previous = 0
      for step = 0, 100 do
        local value = Easing.at(name, step / 100)
        assert.is_true(value >= previous - 1e-12, name .. " dips at t=" .. step / 100)
        previous = value
      end
    end
  end)

  it("clamps a t outside the interval instead of extrapolating", function()
    assert.equal(0, Easing.at(EasingName.OUT_CUBIC, -3))
    assert.equal(1, Easing.at(EasingName.OUT_CUBIC, 4))
  end)

  it("falls back to the default for a name it does not know", function()
    local unknown = Easing.at("bouncy_supreme", 0.5)

    assert.equal(Easing.at(Easing.DEFAULT, 0.5), unknown)
  end)

  it("falls back for a name that is not even a string", function()
    assert.equal(Easing.at(Easing.DEFAULT, 0.5), Easing.at(nil, 0.5))
    assert.equal(Easing.at(Easing.DEFAULT, 0.5), Easing.at(7, 0.5))
  end)

  it("names a default that is one of the curves it has", function()
    local found = false
    for _, name in ipairs(everyName()) do
      if name == Easing.DEFAULT then found = true end
    end
    assert.is_true(found)
  end)
end)
