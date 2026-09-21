describe("PlaceKey", function()
  local ns, PlaceKey, PlaceContext

  before_each(function()
    ns = AscentTest.loadDomain(
      "core/model/Guard.lua", "core/model/Stored.lua", "core/model/Packed.lua", "core/model/PlaceKey.lua")
    PlaceKey = ns.core.PlaceKey
    PlaceContext = ns.core.PlaceContext
  end)

  it("identifies a place by its kind and the one identifier that means something there", function()
    local key = PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest")

    assert.equal(PlaceContext.WORLD, key.context)
    assert.equal(1429, key.areaId)
    assert.is_true(key:isKnown())
    assert.equal("world:1429", key:id())
  end)

  -- The property the whole per-place aggregate rests on: walk out of a zone and
  -- back in, and the experience has to land in the entry it landed in before.
  it("gives two readings of the same place the same key", function()
    local first = PlaceKey.new(PlaceContext.DUNGEON, 389, "Ragefire Chasm")
    local second = PlaceKey.new(PlaceContext.DUNGEON, 389, "Ragefire Chasm")

    assert.equal(first:id(), second:id())
    assert.is_true(first:equals(second))
  end)

  it("ignores the name for identity, because it is localized", function()
    local english = PlaceKey.new(PlaceContext.WORLD, 1429, "Elwynn Forest")
    local spanish = PlaceKey.new(PlaceContext.WORLD, 1429, "Bosque de Elwynn")

    assert.is_true(english:equals(spanish))
  end)

  -- An instance id and a map id are numbers from two different spaces, so the kind
  -- has to be part of the key or dungeon 33 and zone 33 would be one place.
  it("keeps places of different kinds apart even at the same number", function()
    assert.not_equal(
      PlaceKey.new(PlaceContext.DUNGEON, 33):id(),
      PlaceKey.new(PlaceContext.WORLD, 33):id())
  end)

  describe("when the client cannot say where the character is", function()
    it("falls into the reserved entry rather than inventing a place", function()
      local key = PlaceKey.unknown()

      assert.equal(PlaceContext.UNKNOWN, key.context)
      assert.is_nil(key.areaId)
      assert.is_false(key:isKnown())
      assert.equal("unknown:?", key:id())
    end)

    -- A kind with no number behind it is not a fifth kind of nowhere: every place
    -- the client could not identify is the same reserved entry.
    it("collapses a kind without an identifier into that same entry", function()
      assert.equal(PlaceKey.unknown():id(), PlaceKey.new(PlaceContext.DUNGEON, nil):id())
      assert.equal(PlaceKey.unknown():id(), PlaceKey.new(nil, 389):id())
    end)

    it("drops the name too, so two nameless somewheres do not fight over the entry", function()
      assert.is_nil(PlaceKey.new(PlaceContext.WORLD, nil, "Somewhere").name)
    end)
  end)

  it("rejects a kind that is not one of the six", function()
    assert.has_error(function() return PlaceKey.new("dungeon_raid", 1) end)
  end)

  describe("the on-disk fields", function()
    it("round-trip a known place, name included", function()
      local key = PlaceKey.new(PlaceContext.RAID, 409, "Molten Core")
      local restored = PlaceKey.fromFields(ns.core.Packed.split(ns.core.Packed.join(key:fields())), 1)

      assert.equal(key:id(), restored:id())
      assert.equal("Molten Core", restored.name)
    end)

    it("round-trip the reserved entry as itself", function()
      local restored = PlaceKey.fromFields(
        ns.core.Packed.split(ns.core.Packed.join(PlaceKey.unknown():fields())), 1)

      assert.equal("unknown:?", restored:id())
    end)

    -- A kind a future version renamed must not poison a frozen lookup on the way
    -- back in; the reserved entry is where an unreadable one belongs.
    it("read a kind this version does not know as the reserved entry", function()
      local restored = PlaceKey.fromFields({ "scenario", "12", false }, 1)

      assert.equal("unknown:?", restored:id())
    end)
  end)
end)
