describe("RetentionPolicy", function()
  local ns, LevelRecord, XpGain, XpSource

  local function recordWith(count)
    local record = LevelRecord.new(24, 0)
    for index = 1, count do
      ns.core.XpLedger.post(record, XpGain.new({
        amount = index, source = XpSource.MOB_KILL, at = index,
        creature = ns.core.CreatureKey.new(5644, 6, "Kobold Miner"),
      }))
    end
    return record
  end

  local function policyWith(limit)
    return ns.core.RetentionPolicy.new(ns.core.Settings.resolve({
      [ns.core.SettingKey.RETENTION_LIMIT] = limit,
    }))
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/XpLedger.lua",
      "core/service/RetentionPolicy.lua")
    LevelRecord = ns.core.LevelRecord
    XpGain = ns.core.XpGain
    XpSource = ns.core.XpSource
  end)

  it("takes its limit from the settings, and the default without them", function()
    assert.equal(ns.core.Defaults[ns.core.SettingKey.RETENTION_LIMIT],
      ns.core.RetentionPolicy.new().limit)
    assert.equal(10, policyWith(10).limit)
  end)

  it("does nothing while the record is under the limit", function()
    local record = recordWith(10)

    assert.equal(0, policyWith(10):apply(record))
    assert.equal(10, #record.gains)
  end)

  it("discards the oldest entries and keeps the most recent", function()
    local record = recordWith(10)

    assert.equal(6, policyWith(4):apply(record))

    assert.equal(4, #record.gains)
    assert.equal(7, record.gains[1].amount)
    assert.equal(10, record.gains[4].amount)
  end)

  -- The point of trimming detail is that it costs the panel its fine grain and
  -- never costs the level its arithmetic: everything the discarded gains
  -- contributed is already in the aggregates.
  it("leaves every total exactly where it was", function()
    local record = recordWith(10)
    local total, bySource = record.xpTotal, record:xpFrom(XpSource.MOB_KILL)
    local kills, creature = record.killsWithXp, record.creatures["5644:6@?"].xpTotal

    policyWith(3):apply(record)

    assert.equal(total, record.xpTotal)
    assert.equal(bySource, record:xpFrom(XpSource.MOB_KILL))
    assert.equal(kills, record.killsWithXp)
    assert.equal(creature, record.creatures["5644:6@?"].xpTotal)
    assert.is_true(record:sourcesAddUp())
  end)

  it("keeps trimming as the record keeps growing", function()
    local record = recordWith(5)
    local policy = policyWith(5)

    for index = 6, 12 do
      ns.core.XpLedger.post(record, XpGain.new({ amount = index, source = XpSource.MOB_KILL, at = index }))
      policy:apply(record)
      assert.is_true(#record.gains <= 5)
    end

    assert.equal(8, record.gains[1].amount)
    assert.equal(12, record.gains[5].amount)
  end)

  it("keeps no detail at all when told to keep none", function()
    local record = recordWith(10)

    policyWith(0):apply(record)

    assert.equal(0, #record.gains)
    assert.is_true(record:sourcesAddUp())
  end)

  it("falls back to the default rather than trusting a nonsense limit", function()
    local resolved = ns.core.Settings.resolve({ [ns.core.SettingKey.RETENTION_LIMIT] = -5 })

    assert.equal(ns.core.Defaults[ns.core.SettingKey.RETENTION_LIMIT],
      ns.core.RetentionPolicy.new(resolved).limit)
  end)
end)
