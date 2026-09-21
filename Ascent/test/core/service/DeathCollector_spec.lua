describe("DeathCollector", function()
  local ns, collector, record, clock, MetricId, EventTopic

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "core/service/DeathCollector.lua", "test/fakes/FakeClock.lua")
    MetricId = ns.core.MetricId
    EventTopic = ns.core.EventTopic
    clock = ns.fakes.FakeClock.new(1000)
    collector = ns.core.DeathCollector.new({ clock = clock })
    record = ns.core.LevelRecord.new(5, 0)
  end)

  it("increments the death count on PLAYER_DIED", function()
    collector:collect(record, {}, EventTopic.PLAYER_DIED)

    assert.equal(1, record.metrics[MetricId.DEATHS].count)
  end)

  it("counts more than one death in the same level", function()
    collector:collect(record, {}, EventTopic.PLAYER_DIED)
    clock:advance(10)
    collector:collect(record, {}, EventTopic.PLAYER_REVIVED)
    clock:advance(20)
    collector:collect(record, {}, EventTopic.PLAYER_DIED)

    assert.equal(2, record.metrics[MetricId.DEATHS].count)
  end)

  it("adds the elapsed time to timeLostToDeath once the character revives", function()
    collector:collect(record, {}, EventTopic.PLAYER_DIED)
    clock:advance(45)

    collector:collect(record, {}, EventTopic.PLAYER_REVIVED)

    assert.equal(45, record.metrics[MetricId.DEATHS].timeLostToDeath)
  end)

  it("is zero for a level with no deaths at all", function()
    assert.equal(0, record:timeLostToDeath())
    assert.equal(0, record:deathCount())
  end)

  it("credits the corpse run to the record that is current when the character revives", function()
    local closingLevel = record
    local nextLevel = ns.core.LevelRecord.new(6, 0)

    collector:collect(closingLevel, {}, EventTopic.PLAYER_DIED)
    clock:advance(30)
    collector:collect(nextLevel, {}, EventTopic.PLAYER_REVIVED)

    assert.equal(0, closingLevel:timeLostToDeath())
    assert.equal(30, nextLevel:timeLostToDeath())
  end)

  it("ignores a revive with no matching death instead of crashing", function()
    assert.has_no.errors(function()
      collector:collect(record, {}, EventTopic.PLAYER_REVIVED)
    end)
    assert.equal(0, record:timeLostToDeath())
  end)
end)
