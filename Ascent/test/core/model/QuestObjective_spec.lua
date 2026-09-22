describe("QuestObjective", function()
  local ns, QuestObjective

  before_each(function()
    ns = AscentTest.loadWith("core/model/")
    QuestObjective = ns.core.QuestObjective
  end)

  local function objective(fields)
    return QuestObjective.new(fields)
  end

  it("needs a creature name and a count that means something", function()
    assert.has_error(function() objective({ creature = "", done = 0, needed = 6 }) end)
    assert.has_error(function() objective({ creature = 42, done = 0, needed = 6 }) end)
    assert.has_error(function() objective({ creature = "Murloc", done = 0, needed = 0 }) end)
    assert.has_error(function() objective({ creature = "Murloc", done = -1, needed = 6 }) end)
  end)

  it("knows how many are left", function()
    local murlocs = objective({ creature = "Grimscale Murloc", done = 2, needed = 6 })

    assert.equal(4, murlocs:remaining())
    assert.is_false(murlocs:isComplete())
  end)

  it("is complete at nothing left", function()
    assert.is_true(objective({ creature = "Grimscale Murloc", done = 6, needed = 6 }):isComplete())
  end)

  -- A client reporting more done than needed would otherwise make `remaining`
  -- negative, and a negative remaining would subtract experience downstream.
  it("never has fewer than none left, whatever the client says", function()
    local murlocs = objective({ creature = "Grimscale Murloc", done = 9, needed = 6 })

    assert.equal(0, murlocs:remaining())
    assert.is_true(murlocs:isComplete())
  end)
end)
