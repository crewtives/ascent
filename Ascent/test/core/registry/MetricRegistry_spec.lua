describe("MetricRegistry", function()
  local ns, registry, MetricId, EventTopic

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/registry/MetricRegistry.lua")
    MetricId = ns.core.MetricId
    EventTopic = ns.core.EventTopic
    registry = ns.core.MetricRegistry.new()
  end)

  it("dispatches a topic only to the collectors that declared it", function()
    registry:register({
      id = MetricId.ABILITY_USAGE,
      topics = { EventTopic.ABILITY_USED },
      collect = function() end,
    })
    registry:register({
      id = MetricId.DAMAGE,
      topics = { EventTopic.DAMAGE_DEALT, EventTopic.DAMAGE_TAKEN },
      collect = function() end,
    })

    assert.equal(1, #registry:collectorsFor(EventTopic.ABILITY_USED))
    assert.equal(MetricId.ABILITY_USAGE, registry:collectorsFor(EventTopic.ABILITY_USED)[1].id)
    assert.equal(1, #registry:collectorsFor(EventTopic.DAMAGE_TAKEN))
    assert.equal(MetricId.DAMAGE, registry:collectorsFor(EventTopic.DAMAGE_TAKEN)[1].id)
    assert.equal(0, #registry:collectorsFor(EventTopic.COMBAT_STARTED))
  end)

  it("registers a collector for more than one topic", function()
    registry:register({
      id = MetricId.DEATHS,
      topics = { EventTopic.PLAYER_DIED, EventTopic.PLAYER_REVIVED },
      collect = function() end,
    })

    assert.equal(1, #registry:collectorsFor(EventTopic.PLAYER_DIED))
    assert.equal(1, #registry:collectorsFor(EventTopic.PLAYER_REVIVED))
  end)

  it("rejects a second collector under the same id", function()
    registry:register({ id = MetricId.DEATHS, topics = { EventTopic.PLAYER_DIED }, collect = function() end })

    assert.has_error(function()
      registry:register({ id = MetricId.DEATHS, topics = { EventTopic.PLAYER_REVIVED }, collect = function() end })
    end)
  end)

  it("rejects a collector with no topics", function()
    assert.has_error(function()
      registry:register({ id = MetricId.DEATHS, topics = {}, collect = function() end })
    end)
  end)

  it("rejects a collector with no collect function", function()
    assert.has_error(function()
      registry:register({ id = MetricId.DEATHS, topics = { EventTopic.PLAYER_DIED } })
    end)
  end)

  it("rejects an id that is not a known MetricId", function()
    assert.has_error(function()
      registry:register({ id = "not_a_metric", topics = { EventTopic.PLAYER_DIED }, collect = function() end })
    end)
  end)

  it("rejects a topic that is not a known EventTopic", function()
    assert.has_error(function()
      registry:register({ id = MetricId.DEATHS, topics = { "not_a_topic" }, collect = function() end })
    end)
  end)

  it("lists every topic at least one collector declared, and only those", function()
    registry:register({ id = MetricId.DEATHS, topics = { EventTopic.PLAYER_DIED }, collect = function() end })
    registry:register({
      id = MetricId.DAMAGE,
      topics = { EventTopic.DAMAGE_DEALT, EventTopic.DAMAGE_TAKEN },
      collect = function() end,
    })

    local topics = {}
    for _, topic in ipairs(registry:topics()) do topics[topic] = true end

    assert.is_true(topics[EventTopic.PLAYER_DIED])
    assert.is_true(topics[EventTopic.DAMAGE_DEALT])
    assert.is_true(topics[EventTopic.DAMAGE_TAKEN])
    assert.is_nil(topics[EventTopic.COMBAT_STARTED])
  end)

  it("counts registered collectors and lists their ids", function()
    registry:register({ id = MetricId.DEATHS, topics = { EventTopic.PLAYER_DIED }, collect = function() end })
    registry:register({ id = MetricId.DAMAGE, topics = { EventTopic.DAMAGE_DEALT }, collect = function() end })

    assert.equal(2, registry:count())
    assert.same({ MetricId.DEATHS, MetricId.DAMAGE }, registry:ids())
  end)
end)
