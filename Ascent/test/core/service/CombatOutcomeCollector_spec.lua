describe("CombatOutcomeCollector", function()
  local ns, collector, record, player, MetricId

  local function load(healthFraction, powerFraction)
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "core/service/CombatOutcomeCollector.lua", "test/fakes/FakePlayerState.lua")
    MetricId = ns.core.MetricId
    player = ns.fakes.FakePlayerState.new({ health = healthFraction, power = powerFraction })
    collector = ns.core.CombatOutcomeCollector.new({ playerState = player })
    record = ns.core.LevelRecord.new(5, 0)
  end

  it("records one sample with the player's current health and power", function()
    load(0.8, 0.6)

    collector:collect(record)

    local summary = record.metrics[MetricId.COMBAT_OUTCOME]
    assert.equal(1, summary.samples)
    assert.equal(0.8, summary:averageHealth())
    assert.equal(0.6, summary:averagePower())
  end)

  it("averages health across several fights ending during the level", function()
    load(1.0, 1.0)

    collector:collect(record)
    player:set("health", 0.5)
    collector:collect(record)

    local summary = record.metrics[MetricId.COMBAT_OUTCOME]
    assert.equal(2, summary.samples)
    assert.near(0.75, summary:averageHealth(), 1e-9)
  end)

  it("records the worst fight of the level", function()
    load(0.9, 0.9)

    collector:collect(record)
    player:set("health", 0.1)
    collector:collect(record)
    player:set("health", 0.5)
    collector:collect(record)

    assert.equal(0.1, record.metrics[MetricId.COMBAT_OUTCOME]:worstHealth())
  end)

  it("records a zero-health sample when combat ended because the character died", function()
    load(0.0, 0.3)

    collector:collect(record)

    assert.equal(0, record.metrics[MetricId.COMBAT_OUTCOME]:worstHealth())
    assert.equal(0.3, record.metrics[MetricId.COMBAT_OUTCOME]:worstPower())
  end)
end)
