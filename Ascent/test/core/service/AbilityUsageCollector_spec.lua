describe("AbilityUsageCollector", function()
  local ns, collector, record, AbilityKey

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/AbilityUsageCollector.lua")
    AbilityKey = ns.core.AbilityKey
    collector = ns.core.AbilityUsageCollector.new()
    record = ns.core.LevelRecord.new(5, 0)
  end)

  it("counts repeated use of the same ability", function()
    collector:collect(record, { key = 12345, name = "Sinister Strike" })
    collector:collect(record, { key = 12345, name = "Sinister Strike" })
    collector:collect(record, { key = 12345, name = "Sinister Strike" })

    assert.equal(3, record.abilities[12345].count)
  end)

  it("tracks two abilities independently", function()
    collector:collect(record, { key = 111, name = "A" })
    collector:collect(record, { key = 222, name = "B" })
    collector:collect(record, { key = 111, name = "A" })

    assert.equal(2, record.abilities[111].count)
    assert.equal(1, record.abilities[222].count)
  end)

  it("counts auto attacks under their own reserved key, identified as such", function()
    collector:collect(record, { key = AbilityKey.MELEE_SWING, name = nil })
    collector:collect(record, { key = AbilityKey.MELEE_SWING, name = nil })
    collector:collect(record, { key = AbilityKey.RANGED_AUTO, name = nil })

    assert.equal(2, record.abilities[AbilityKey.MELEE_SWING].count)
    assert.is_true(record.abilities[AbilityKey.MELEE_SWING]:isAutoAttack())
    assert.equal(1, record.abilities[AbilityKey.RANGED_AUTO].count)
    assert.is_true(record.abilities[AbilityKey.RANGED_AUTO]:isAutoAttack())
  end)

  it("keeps a spell distinct from an auto attack in the same ranking", function()
    collector:collect(record, { key = 12345, name = "Sinister Strike" })
    collector:collect(record, { key = AbilityKey.MELEE_SWING, name = nil })

    assert.is_false(record.abilities[12345]:isAutoAttack())
    assert.is_true(record.abilities[AbilityKey.MELEE_SWING]:isAutoAttack())
  end)
end)
