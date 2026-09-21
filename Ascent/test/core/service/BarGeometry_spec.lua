-- The property under test is the one that makes a multi-segment bar possible at
-- all: whatever the fractions are, the pieces tile the bar exactly -- no gap, no
-- overlap, and no total that drifts away from the percentage it represents.

describe("BarGeometry", function()
  local ns, BarGeometry

  before_each(function()
    ns = AscentTest.loadDomain("core/service/BarGeometry.lua")
    BarGeometry = ns.core.BarGeometry
  end)

  -- Cumulative boundaries from per-channel shares, which is how a caller thinks
  -- about it ("mobs paid 30% of the level") before handing it over.
  local function cumulative(shares)
    local out, running = {}, 0
    for index, share in ipairs(shares) do
      running = running + share
      out[index] = running
    end
    return out
  end

  local function sum(values)
    local total = 0
    for _, value in ipairs(values) do total = total + value end
    return total
  end

  describe("tiling", function()
    it("gives back one width per channel", function()
      local layout = BarGeometry.lay(cumulative({ 0.2, 0.3, 0.1 }), 400)

      assert.equal(3, #layout.widths)
    end)

    it("makes the widths add up to the last boundary, exactly", function()
      local layout = BarGeometry.lay(cumulative({ 0.31, 0.22, 0.17 }), 397)

      assert.equal(layout.edges[#layout.edges], sum(layout.widths))
    end)

    it("leaves no gap and no overlap between neighbours at any width", function()
      -- The fractions that break naive rounding are the ones that land on .5
      -- boundaries, so this sweeps widths rather than picking a lucky one.
      for width = 61, 400 do
        local layout = BarGeometry.lay(cumulative({ 1 / 3, 1 / 3, 1 / 6 }), width)
        local running = 0
        for index, value in ipairs(layout.widths) do
          running = running + value
          assert.equal(layout.edges[index], running, "boundary drift at width " .. width)
        end
      end
    end)

    it("never produces a negative width from a vector that dips", function()
      local layout = BarGeometry.lay({ 0.5, 0.4, 0.9 }, 400)

      for _, value in ipairs(layout.widths) do
        assert.is_true(value >= 0)
      end
    end)

    it("clamps a fraction past the end of the bar instead of overflowing it", function()
      local layout = BarGeometry.lay({ 0.5, 1.4 }, 400)

      assert.equal(400, layout.edges[#layout.edges])
    end)

    it("gives everything to a single channel that holds the whole bar", function()
      local layout = BarGeometry.lay({ 1 }, 400)

      assert.same({ 400 }, layout.widths)
    end)

    it("hands back zero widths for a level with nothing in it", function()
      local layout = BarGeometry.lay({ 0, 0, 0 }, 400)

      assert.same({ 0, 0, 0 }, layout.widths)
      assert.equal(0, layout.starved)
    end)
  end)

  describe("the minimum visible rule", function()
    it("gives a pixel to a source too small to draw", function()
      local layout = BarGeometry.lay(cumulative({ 0.5, 0.001 }), 400)

      assert.is_true(layout.widths[2] >= 1)
      assert.equal(0, layout.starved)
    end)

    it("takes that pixel from the widest channel, not from the total", function()
      local fat = BarGeometry.lay(cumulative({ 0.5 }), 400)
      local layout = BarGeometry.lay(cumulative({ 0.5, 0.001 }), 400)

      assert.equal(fat.widths[1], sum(layout.widths))
      assert.equal(fat.widths[1] - 1, layout.widths[1])
    end)

    it("keeps the total intact with several starved sources at once", function()
      -- A level that has just started: four sources, all of them sub-pixel.
      local shares = { 0.002, 0.001, 0.0015, 0.0005 }
      local layout = BarGeometry.lay(cumulative(shares), 400)
      local expected = math.floor(0.005 * 400 + 0.5)

      assert.equal(expected, sum(layout.widths))
    end)

    it("reports the ones it could not rescue instead of inventing width", function()
      -- Eighty pixels, five sources, every one of them sub-pixel: there is no
      -- donor wide enough, and pretending otherwise would be a lie about the
      -- level's percentage.
      local shares = { 0.001, 0.001, 0.001, 0.001, 0.001 }
      local layout = BarGeometry.lay(cumulative(shares), 80)

      assert.is_true(layout.starved > 0)
      assert.equal(0, sum(layout.widths))
    end)

    it("leaves a channel with nothing to show at zero", function()
      local layout = BarGeometry.lay(cumulative({ 0.5, 0, 0.2 }), 400)

      assert.equal(0, layout.widths[2])
      assert.equal(0, layout.starved)
    end)

    it("never leaves a donor starved in turn", function()
      local layout = BarGeometry.lay(cumulative({ 0.006, 0.001 }), 400)

      for index, value in ipairs(layout.widths) do
        assert.is_true(value >= 1, "channel " .. index .. " ended at " .. value)
      end
    end)
  end)
  -- D52: the bar that takes over the client's slot inherits a height much
  -- smaller than its own default, and the text has to leave the frame on its own.
  describe("text inside the bar", function()
    it("fits at the bar's own default height", function()
      assert.is_true(BarGeometry.textFitsInside(24, 11))
    end)

    it("does not fit in the thin bar the client's slot inherits", function()
      assert.is_false(BarGeometry.textFitsInside(10, 11))
    end)

    it("needs headroom, not just the glyph height", function()
      assert.is_false(BarGeometry.textFitsInside(12, 11))
      assert.is_true(BarGeometry.textFitsInside(17, 11))
    end)

    it("answers no rather than failing when a measure is missing", function()
      assert.is_false(BarGeometry.textFitsInside(nil, 11))
      assert.is_false(BarGeometry.textFitsInside(24, nil))
    end)
  end)
  describe("which side the text goes when it cannot stay inside", function()
    it("goes below when there is room below", function()
      assert.equal(ns.core.TextAnchor.BELOW, BarGeometry.textAnchorOutside(300, 11))
    end)

    -- The bar in the client's own slot: a handful of pixels off the bottom of
    -- the screen, where below is behind the action bar.
    it("goes above when there is not", function()
      assert.equal(ns.core.TextAnchor.ABOVE, BarGeometry.textAnchorOutside(8, 11))
    end)

    it("needs the same headroom below as it would inside", function()
      assert.equal(ns.core.TextAnchor.ABOVE, BarGeometry.textAnchorOutside(16, 11))
      assert.equal(ns.core.TextAnchor.BELOW, BarGeometry.textAnchorOutside(17, 11))
    end)

    it("keeps the conventional side when the room is not known yet", function()
      assert.equal(ns.core.TextAnchor.BELOW, BarGeometry.textAnchorOutside(nil, 11))
    end)
  end)
end)
