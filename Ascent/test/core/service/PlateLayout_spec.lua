-- Every claim about where the plate's pieces end up that can be made in numbers
-- is made here, since ui/ has no unit test. The header offsets matter most: they
-- derive from a text size the player can change.

describe("PlateLayout", function()
  local ns, PlateLayout, PlateZone, Frozen

  before_each(function()
    ns = AscentTest.loadDomain("core/service/PlateLayout.lua")
    PlateLayout = ns.core.PlateLayout
    PlateZone = ns.core.PlateZone
    Frozen = ns.core.Frozen
  end)

  -- Everything on, in the order they happen to have been written down. The tests
  -- that care about order scramble it on purpose.
  local function allZones()
    return { PlateZone.CLOCK, PlateZone.REMAINING, PlateZone.STREAK, PlateZone.SOURCES,
             PlateZone.CREATURES, PlateZone.ABILITIES, PlateZone.FOOTER }
  end

  local function without(zone)
    local kept = {}
    for _, candidate in ipairs(allZones()) do
      if candidate ~= zone then
        kept[#kept + 1] = candidate
      end
    end
    return kept
  end

  describe("which zones are drawn", function()
    it("answers in the canonical order whatever order they were stored in", function()
      local stored = { PlateZone.FOOTER, PlateZone.CLOCK, PlateZone.ABILITIES, PlateZone.REMAINING,
                       PlateZone.SOURCES, PlateZone.STREAK, PlateZone.CREATURES }

      local order = PlateLayout.zones(stored)

      assert.same({ PlateZone.CLOCK, PlateZone.REMAINING, PlateZone.STREAK, PlateZone.SOURCES,
                    PlateZone.CREATURES, PlateZone.ABILITIES, PlateZone.FOOTER }, order)
    end)

    it("leaves a zone that is off out of both answers", function()
      local order, draws = PlateLayout.zones(without(PlateZone.STREAK))

      for _, zone in ipairs(order) do
        assert.are_not.equal(PlateZone.STREAK, zone)
      end
      assert.is_nil(draws[PlateZone.STREAK])
      assert.is_true(draws[PlateZone.SOURCES])
    end)

    -- An empty list, every accessory zone off, is a choice; telling it apart
    -- from no list at all is why the setting is a list rather than seven flags.
    it("draws nothing accessory for an empty list, and everything for no list", function()
      local order, draws = PlateLayout.zones({})
      assert.equal(0, #order)
      assert.is_nil(draws[PlateZone.FOOTER])

      assert.equal(#allZones(), #PlateLayout.zones(nil))
    end)

    -- The ordering is written out by hand, so the failure this catches is a zone
    -- added to the vocabulary and forgotten here: it would be stored, offered in
    -- the panel, and never drawn.
    it("covers the vocabulary exactly once", function()
      local order = PlateLayout.zones(nil)
      local seen = {}
      for _, zone in ipairs(order) do
        assert.is_nil(seen[zone], tostring(zone) .. " is laid out twice")
        seen[zone] = true
      end
      for _, name in ipairs(Frozen.keys(PlateZone)) do
        assert.is_true(seen[PlateZone[name]] == true, name .. " is a zone nothing lays out")
      end
    end)
  end)

  describe("the header's six offsets", function()
    -- Pinned to the pixel: an install that updates and never opens the options
    -- page has to get the plate it had.
    it("lands on the view's own literals at the default text size", function()
      local layout = PlateLayout.lay({ zones = allZones() })

      assert.same({ title = 8, xp = 24, remaining = 50, chips = 66, rule = 78, body = 86 },
        layout.header)
    end)

    -- Whatever the text size, nothing may start before the thing above it has
    -- finished. The source bar has to clear both columns: the to-level line on
    -- the left and the chain on the right.
    for _, size in ipairs({ 8, 20 }) do
      it("keeps every row below the one above it at text size " .. size, function()
        local layout = PlateLayout.lay({ zones = allZones(), textSize = size })
        local header, font = layout.header, layout.font

        assert.is_true(header.xp >= header.title + font.title,
          "the headline starts inside the caption")
        assert.is_true(header.remaining >= header.xp + font.headline,
          "the to-level line starts inside the headline")
        assert.is_true(header.chips >= header.remaining + font.body,
          "the source bar is drawn through the to-level line")
        assert.is_true(header.chips >= header.xp + font.kills + 1 + font.streak,
          "the source bar is drawn through the chain")
        assert.is_true(header.rule >= header.chips + layout.chipHeight,
          "the hairline is drawn through the source bar")
        assert.is_true(header.body >= header.rule + 1,
          "the first body row is drawn through the hairline")
      end)
    end

    it("moves the whole header down as the text grows", function()
      local small = PlateLayout.lay({ zones = allZones(), textSize = 8 }).header
      local large = PlateLayout.lay({ zones = allZones(), textSize = 20 }).header

      for _, row in ipairs({ "xp", "remaining", "chips", "rule", "body" }) do
        assert.is_true(large[row] > small[row],
          row .. " sits where it did before the player chose a bigger font")
      end
    end)

    -- A zone that is off does not reserve its space, which is what makes turning
    -- one off different from the plate simply not having anything to say there.
    it("closes the gap a zone that is off would have left", function()
      local all = PlateLayout.lay({ zones = allZones() }).header
      local noRemaining = PlateLayout.lay({ zones = without(PlateZone.REMAINING) }).header
      local noSources = PlateLayout.lay({ zones = without(PlateZone.SOURCES) }).header

      assert.is_true(noRemaining.chips < all.chips, "the source bar kept the to-level line's row")
      assert.is_true(noSources.body < all.body, "the body kept the source bar's band")
    end)

    -- The plate's own appearance map is the only door to the text size and
    -- SkinResolver checks an override by type, never by range: a hand-edited file
    -- reaches here with whatever it likes, and a plate taller than the screen
    -- cannot be dragged back into it.
    it("pulls an out-of-band text size back to the band", function()
      local huge = PlateLayout.lay({ zones = allZones(), textSize = 200 })
      local tiny = PlateLayout.lay({ zones = allZones(), textSize = -4 })

      assert.same(PlateLayout.lay({ zones = allZones(), textSize = PlateLayout.TEXT_SIZE.max }).header,
        huge.header)
      assert.same(PlateLayout.lay({ zones = allZones(), textSize = PlateLayout.TEXT_SIZE.min }).header,
        tiny.header)
    end)
  end)

  describe("how tall the plate ends up", function()
    local function height(options)
      options.zones = options.zones or allZones()
      options.creatures = options.creatures or 4
      options.abilities = options.abilities or 4
      return PlateLayout.lay(options).height
    end

    -- Not "is hidden": shorter, which is what a player sees when they turn a zone
    -- off with the plate in front of them.
    it("shrinks when a zone is switched off", function()
      local all = height({})

      for _, zone in ipairs({ PlateZone.REMAINING, PlateZone.SOURCES, PlateZone.CREATURES,
                              PlateZone.ABILITIES, PlateZone.FOOTER }) do
        assert.is_true(height({ zones = without(zone) }) < all,
          tostring(zone) .. " is hidden rather than turned off")
      end
    end)

    it("never ends above what it is drawing", function()
      for _, size in ipairs({ 8, 10, 14, 20 }) do
        for _, rows in ipairs({ 0, 1, 6 }) do
          local layout = PlateLayout.lay({
            zones = allZones(), textSize = size, creatures = rows, abilities = rows,
          })
          local lowest = layout.header.body
          for _, block in pairs(layout.blocks) do
            lowest = math.max(lowest, block)
          end
          -- The bottom of the last thing drawn, plus the padding under it.
          local content = lowest + layout.rowHeight + layout.padding
          assert.is_true(layout.height >= content,
            ("%d rows at text %d end %d past the frame"):format(rows, size, content - layout.height))
        end
      end
    end)

    it("grows by exactly one row per row asked for", function()
      local three = height({ creatures = 3, abilities = 0 })
      local four = height({ creatures = 4, abilities = 0 })

      assert.equal(PlateLayout.lay({}).rowHeight, four - three)
    end)

    -- Its smallest is the header and the padding under it: a floor that follows
    -- from the arithmetic rather than a minimum asserted on top of it.
    it("is the header plus its padding with nothing in the body", function()
      local layout = PlateLayout.lay({ zones = {}, creatures = 0, abilities = 0 })

      assert.equal(layout.header.body + layout.padding, layout.height)
    end)

    it("does not reserve a block for rows it has none of", function()
      local layout = PlateLayout.lay({ zones = allZones(), creatures = 0, abilities = 2 })

      assert.is_nil(layout.blocks.creatures)
      assert.equal(layout.header.body, layout.blocks.abilities)
    end)
  end)
end)
