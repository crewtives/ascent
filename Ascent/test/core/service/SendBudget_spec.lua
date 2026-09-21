-- The client gives each prefix ten messages back at one a second, and overspending
-- can disconnect the player. This is the piece that makes sure the addon never
-- gets close, so the assertions are about what it REFUSES.

describe("SendBudget", function()
  local ns, clock, budget

  before_each(function()
    ns = AscentTest.loadWith("core/port/", "core/service/SendBudget.lua", "test/fakes/FakeClock.lua")
    clock = ns.fakes.FakeClock.new(0)
    budget = ns.core.SendBudget.new({ clock = clock, capacity = 2, refillSeconds = 15 })
  end)

  it("starts full, because the first announcement is the one that matters", function()
    assert.is_true(budget:allow())
    assert.is_true(budget:allow())
  end)

  it("stops at the capacity however many times it is asked in the same instant", function()
    local allowed = 0
    for _ = 1, 50 do
      if budget:allow() then allowed = allowed + 1 end
    end
    assert.equal(2, allowed)
  end)

  it("refuses again for the rest of the period once the reserve is spent", function()
    budget:allow()
    budget:allow()

    clock:advance(14)
    assert.is_false(budget:allow())

    clock:advance(1)
    assert.is_true(budget:allow())
    assert.is_false(budget:allow())
  end)

  it("never refills past the capacity, however long nobody speaks", function()
    budget:allow()
    budget:allow()
    clock:advance(15 * 100)

    local allowed = 0
    for _ = 1, 50 do
      if budget:allow() then allowed = allowed + 1 end
    end
    assert.equal(2, allowed)
  end)

  it("does not throw away the fraction of a period already waited", function()
    budget:allow()
    budget:allow()

    -- Ten seconds, then five more: the period is complete, and a refill that
    -- restarted the clock on every call would never let it be.
    clock:advance(10)
    assert.is_false(budget:allow())
    clock:advance(5)
    assert.is_true(budget:allow())
  end)

  it("needs a real clock, and says so at wiring time", function()
    assert.has_error(function() ns.core.SendBudget.new({ clock = {} }) end)
  end)
end)
