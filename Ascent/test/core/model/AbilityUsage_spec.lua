describe("AbilityUsage", function()
  local ns, AbilityUsage, AbilityKey

  before_each(function()
    ns = AscentTest.loadDomain("core/model/Guard.lua", "core/model/AbilityUsage.lua")
    AbilityUsage = ns.core.AbilityUsage
    AbilityKey = ns.core.AbilityKey
  end)

  it("counts a real ability by its spell id", function()
    local usage = AbilityUsage.new(133, "Fireball")

    assert.equal(0, usage.count)
    usage:record()
    usage:record()

    assert.equal(2, usage.count)
    assert.is_false(usage:isAutoAttack())
  end)

  it("can record several uses at once", function()
    local usage = AbilityUsage.new(133, "Fireball")

    usage:record(5)

    assert.equal(5, usage.count)
  end)

  -- Swings arrive with no spell attached. Reserved keys keep the domain from ever
  -- meeting a nil identifier, which is the first of many nil checks avoided.
  it("counts auto attacks under reserved keys and flags them", function()
    local melee = AbilityUsage.new(AbilityKey.MELEE_SWING)
    local ranged = AbilityUsage.new(AbilityKey.RANGED_AUTO)

    assert.is_true(melee:isAutoAttack())
    assert.is_true(ranged:isAutoAttack())
  end)

  it("keeps the cached name for when the client cannot resolve the id", function()
    assert.equal("Fireball", AbilityUsage.new(133, "Fireball").name)
  end)

  it("refuses keys that are neither a spell id nor a reserved key", function()
    assert.has_error(function() return AbilityUsage.new("auto_attack") end)
    assert.has_error(function() return AbilityUsage.new(0) end)
    assert.has_error(function() return AbilityUsage.new(-133) end)
    assert.has_error(function() return AbilityUsage.new(nil) end)
    assert.has_error(function() return AbilityUsage.new({}) end)
  end)

  it("refuses a non-positive number of uses", function()
    local usage = AbilityUsage.new(133)

    assert.has_error(function() usage:record(0) end)
    assert.has_error(function() usage:record(-1) end)
  end)
end)
