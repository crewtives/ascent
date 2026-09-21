-- The demo is scenery, but scenery that lies is worse than none: if it can show
-- a bar the real addon could never produce, every skin verified against it is
-- verified against a fiction. So what is asserted here is not that it looks
-- nice -- it is that every state it produces is a state the domain permits, and
-- that between them they cover what the change's requirements actually name.
--
-- It is testable at all because DemoDriver touches no client API: it builds a
-- LevelRecord and calls one method on whatever it was handed as a bar.

describe("DemoDriver", function()
  local ns, DemoDriver, XpSource

  -- Records every update the driver pushes, standing in for XpBarView.
  local function fakeBar()
    local bar = { updates = {} }
    function bar:update(record, params)
      self.updates[#self.updates + 1] = { record = record, params = params }
      return self
    end
    return bar
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "app/DemoDriver.lua")
    DemoDriver = ns.app.DemoDriver
    XpSource = ns.core.XpSource
  end)

  local function driverWith(bar, onStop)
    return DemoDriver.new({ bar = bar, onStop = onStop })
  end

  -- Walks the whole script once and hands back every update it produced.
  local function walk(bar, driver)
    local count = #driver:stepNames()
    for _ = 1, count do driver:step() end
    return bar.updates, count
  end

  it("needs a bar to drive", function()
    assert.has_error(function() DemoDriver.new({}) end)
  end)

  it("starts inactive and takes the bar over on the first step", function()
    local bar = fakeBar()
    local driver = driverWith(bar)

    assert.is_false(driver:isActive())
    driver:step()
    assert.is_true(driver:isActive())
    assert.equal(1, #bar.updates)
  end)

  it("keeps every state it produces inside the addon's central invariant", function()
    local bar = fakeBar()
    local updates = walk(bar, driverWith(bar))

    for index, update in ipairs(updates) do
      assert.is_true(update.record:sourcesAddUp(), "step " .. index .. " does not add up")
      assert.is_true(update.record.xpTotal <= update.record.xpRequired, "step " .. index .. " overflows the level")
    end
  end)

  it("shows a source appearing for the first time", function()
    local bar = fakeBar()
    local updates = walk(bar, driverWith(bar))

    local sawAbsent, sawPresent = false, false
    for _, update in ipairs(updates) do
      local amount = update.record:xpFrom(XpSource.EXPLORATION)
      if amount == 0 and not sawPresent then sawAbsent = true end
      if amount > 0 and sawAbsent then sawPresent = true end
    end

    assert.is_true(sawAbsent and sawPresent, "no step introduces a source that was not there")
  end)

  -- The reclassification of D21 is the hardest state to reach by playing -- it
  -- needs attribution to settle several seconds after a kill -- and the one the
  -- motion spec makes the strongest promise about. If the demo cannot produce
  -- it, that promise cannot be checked against a real client at all.
  it("reproduces a reclassification: the total holds while a source hands over", function()
    local bar = fakeBar()
    local updates = walk(bar, driverWith(bar))

    local found = false
    for index = 2, #updates do
      local before, after = updates[index - 1].record, updates[index].record
      local unknownFell = after:xpFrom(XpSource.UNKNOWN) < before:xpFrom(XpSource.UNKNOWN)
      if unknownFell and after.xpTotal == before.xpTotal then
        assert.is_true(after:xpFrom(XpSource.MOB_KILL) > before:xpFrom(XpSource.MOB_KILL))
        found = true
      end
    end

    assert.is_true(found, "no step moves experience between sources at a constant total")
  end)

  it("reproduces a level-up, and starts the new level from nearly nothing", function()
    local bar = fakeBar()
    local updates = walk(bar, driverWith(bar))

    local levelled = false
    for index = 2, #updates do
      local before, after = updates[index - 1].record, updates[index].record
      if after.level > before.level then
        levelled = true
        assert.is_true(after.xpTotal < before.xpTotal, "the new level did not start over")
      end
    end

    assert.is_true(levelled, "the script never reaches a level-up")
  end)

  it("covers every source the bar can draw", function()
    local bar = fakeBar()
    local updates = walk(bar, driverWith(bar))

    for _, source in ns.core.Frozen.each(XpSource) do
      local seen = false
      for _, update in ipairs(updates) do
        if update.record:xpFrom(source) > 0 then seen = true end
      end
      assert.is_true(seen, "no step ever shows " .. tostring(source))
    end
  end)

  it("covers the rested reserve and the pending projection too", function()
    local bar = fakeBar()
    local updates = walk(bar, driverWith(bar))

    local rested, pending = false, false
    for _, update in ipairs(updates) do
      if (update.params.restedXp or 0) > 0 then rested = true end
      if (update.params.questPending or 0) > 0 then pending = true end
    end

    assert.is_true(rested, "no step shows a rested reserve")
    assert.is_true(pending, "no step shows pending experience")
  end)

  it("produces a state where a source is far too small to draw", function()
    local bar = fakeBar()
    local updates = walk(bar, driverWith(bar))

    local sliver = false
    for _, update in ipairs(updates) do
      for _, source in ns.core.Frozen.each(XpSource) do
        local amount = update.record:xpFrom(source)
        if amount > 0 and amount / update.record.xpRequired < 0.005 then sliver = true end
      end
    end

    assert.is_true(sliver, "nothing exercises the minimum-visible rule")
  end)

  it("wraps around instead of running off the end", function()
    local bar = fakeBar()
    local driver = driverWith(bar)
    local count = #driver:stepNames()

    for _ = 1, count + 1 do driver:step() end

    assert.equal(count + 1, #bar.updates)
    assert.is_true(driver:isActive())
  end)

  it("hands the bar back when it stops", function()
    local bar = fakeBar()
    local restored = 0
    local driver = driverWith(bar, function() restored = restored + 1 end)

    driver:step()
    driver:stop()

    assert.is_false(driver:isActive())
    assert.equal(1, restored)
  end)

  it("does nothing, and asks for nothing back, if it was never running", function()
    local restored = 0
    local driver = driverWith(fakeBar(), function() restored = restored + 1 end)

    driver:stop()

    assert.equal(0, restored)
  end)

  -- 7.3: the options panel's preview draws this, and no longer a sample of its
  -- own. What the appearance spec asks of that preview is "representative data
  -- -- several sources, a rested reserve and pending experience" and progress
  -- that does not depend on the character earning any, so that is what is
  -- asserted: the sample is a real level of the script, not an empty one, and it
  -- is a whole state rather than a record with the two loose channels missing.
  describe("the sample it hands the options panel", function()
    it("is a level the domain permits", function()
      local sample = DemoDriver.sample()

      assert.is_truthy(sample.record)
      assert.is_true(sample.record:sourcesAddUp())
      assert.is_true(sample.record.xpTotal > 0)
      assert.is_true(sample.record.xpTotal < sample.record.xpRequired)
    end)

    it("shows several sources at once, plus the rested reserve and the pending", function()
      local sample = DemoDriver.sample()

      local sources = 0
      for _, source in ns.core.Frozen.each(XpSource) do
        if sample.record:xpFrom(source) > 0 then sources = sources + 1 end
      end

      assert.is_true(sources >= 3, "only " .. sources .. " source(s) in the preview sample")
      assert.is_true(sample.restedXp > 0, "the preview sample has no rested reserve")
      assert.is_true(sample.questPending > 0, "the preview sample has no pending experience")
    end)

    it("is built fresh each time, so nothing that draws it can edit it for the next caller", function()
      local first = DemoDriver.sample()
      first.record.xpTotal = 0

      assert.is_true(DemoDriver.sample().record.xpTotal > 0)
    end)
  end)
end)
