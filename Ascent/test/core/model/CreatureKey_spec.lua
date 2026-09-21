describe("CreatureKey", function()
  local ns, CreatureKey

  before_each(function()
    ns = AscentTest.loadDomain("core/model/Guard.lua", "core/model/CreatureKey.lua")
    CreatureKey = ns.core.CreatureKey
  end)

  it("identifies a creature by type and observed level", function()
    local key = CreatureKey.new(5644, 24, "Kobold Miner")

    assert.equal(5644, key.npcId)
    assert.equal(24, key.level)
    assert.is_true(key:isFullyKnown())
    assert.equal("5644:24", key:id())
  end)

  -- Experience depends on the creature's level, so the same type at two levels is
  -- two different things to average. Collapsing them would quietly dirty the data.
  it("treats the same type at different levels as different keys", function()
    local low = CreatureKey.new(5644, 22)
    local high = CreatureKey.new(5644, 24)

    assert.not_equal(low:id(), high:id())
    assert.is_false(low:equals(high))
  end)

  it("treats the same type and level as the same key", function()
    assert.is_true(CreatureKey.new(5644, 24):equals(CreatureKey.new(5644, 24)))
  end)

  it("ignores the name for identity, because it is localized", function()
    local english = CreatureKey.new(5644, 24, "Kobold Miner")
    local spanish = CreatureKey.new(5644, 24, "Minero kóbold")

    assert.is_true(english:equals(spanish))
  end)

  describe("when something could not be observed", function()
    it("says the level is unknown instead of guessing one", function()
      local key = CreatureKey.new(5644, nil, "Kobold Miner")

      assert.is_true(key:hasKnownType())
      assert.is_false(key:hasKnownLevel())
      assert.is_false(key:isFullyKnown())
      assert.equal("5644:?", key:id())
    end)

    it("supports a kill that could not be correlated at all", function()
      local key = CreatureKey.unknown("Kobold Miner")

      assert.is_false(key:hasKnownType())
      assert.is_false(key:hasKnownLevel())
      assert.equal("?:?", key:id())
    end)

    it("keeps unknown levels out of the bucket of a known one", function()
      local known = CreatureKey.new(5644, 24)
      local unknownLevel = CreatureKey.new(5644, nil)

      assert.not_equal(known:id(), unknownLevel:id())
    end)
  end)

  it("refuses impossible identifiers", function()
    assert.has_error(function() return CreatureKey.new(0, 24) end)
    assert.has_error(function() return CreatureKey.new(-5, 24) end)
    assert.has_error(function() return CreatureKey.new(5644, 0) end)
    assert.has_error(function() return CreatureKey.new(5644, -1) end)
    assert.has_error(function() return CreatureKey.new("5644", 24) end)
  end)
end)
