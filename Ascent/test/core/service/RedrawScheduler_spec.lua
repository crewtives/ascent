-- The scheduler is the pure half of D7's dirty-flag redraw: no frame, no client,
-- just whether a redraw is due. The rule under test throughout is that a burst of
-- dirty marks is never "more dirty" than a single one -- it still costs at most one
-- redraw per cycle -- and that the cycle is measured from the last real redraw, not
-- from when the scheduler happened to be built.

describe("RedrawScheduler", function()
  local ns, RedrawScheduler, clock, scheduler

  local function build(minInterval)
    clock = ns.fakes.FakeClock.new(0)
    scheduler = RedrawScheduler.new({ clock = clock, minInterval = minInterval })
  end

  before_each(function()
    ns = AscentTest.loadWith("core/port/", "core/service/RedrawScheduler.lua", "test/fakes/FakeClock.lua")
    RedrawScheduler = ns.core.RedrawScheduler
    build()
  end)

  it("never redraws without a dirty flag, no matter how much time passes", function()
    assert.is_false(scheduler:tick())

    clock:advance(10)
    assert.is_false(scheduler:tick())
  end)

  it("collapses a burst of markDirty() calls into at most one redraw", function()
    scheduler:markDirty()
    scheduler:markDirty()
    scheduler:markDirty()

    assert.is_true(scheduler:tick())
    assert.is_false(scheduler:tick())
  end)

  it("withholds the next redraw until minInterval has passed since the last one", function()
    scheduler:markDirty()
    assert.is_true(scheduler:tick())

    scheduler:markDirty()
    assert.is_false(scheduler:tick())
  end)

  it("redraws again once minInterval has elapsed", function()
    scheduler:markDirty()
    assert.is_true(scheduler:tick())

    clock:advance(0.2)
    scheduler:markDirty()

    assert.is_true(scheduler:tick())
  end)

  it("lets a freshly built scheduler redraw on its very first tick, without an initial wait", function()
    build()
    scheduler:markDirty()

    assert.is_true(scheduler:tick())
  end)
end)
