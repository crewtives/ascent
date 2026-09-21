describe("DamageCollector", function()
  local ns, collector, record, MetricId, EventTopic

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/DamageCollector.lua")
    MetricId = ns.core.MetricId
    EventTopic = ns.core.EventTopic
    collector = ns.core.DamageCollector.new()
    record = ns.core.LevelRecord.new(5, 0)
  end)

  it("sums damage dealt -- the player's and the pet's, both arrive on the same topic", function()
    collector:collect(record, { amount = 40 }, EventTopic.DAMAGE_DEALT)
    collector:collect(record, { amount = 15 }, EventTopic.DAMAGE_DEALT) -- the pet's swing

    assert.equal(55, record.metrics[MetricId.DAMAGE].dealt)
  end)

  it("sums damage taken separately from damage dealt", function()
    collector:collect(record, { amount = 40 }, EventTopic.DAMAGE_DEALT)
    collector:collect(record, { amount = 20 }, EventTopic.DAMAGE_TAKEN)

    assert.equal(40, record.metrics[MetricId.DAMAGE].dealt)
    assert.equal(20, record.metrics[MetricId.DAMAGE].taken)
  end)

  it("sums healing received", function()
    collector:collect(record, { amount = 30 }, EventTopic.HEALING_RECEIVED)
    collector:collect(record, { amount = 12 }, EventTopic.HEALING_RECEIVED)

    assert.equal(42, record.metrics[MetricId.DAMAGE].healingReceived)
  end)

  describe("the player's opt-out (SettingKey.COLLECT_DAMAGE)", function()
    it("collects nothing while disabled", function()
      local disabled = ns.core.DamageCollector.new({ enabled = function() return false end })

      disabled:collect(record, { amount = 40 }, EventTopic.DAMAGE_DEALT)

      assert.is_nil(record.metrics[MetricId.DAMAGE])
    end)

    it("reads the flag live, not just once at construction -- toggling takes effect immediately", function()
      local flag = true
      local live = ns.core.DamageCollector.new({ enabled = function() return flag end })

      live:collect(record, { amount = 10 }, EventTopic.DAMAGE_DEALT)
      flag = false
      live:collect(record, { amount = 10 }, EventTopic.DAMAGE_DEALT)
      flag = true
      live:collect(record, { amount = 5 }, EventTopic.DAMAGE_DEALT)

      assert.equal(15, record.metrics[MetricId.DAMAGE].dealt)
    end)

    it("collects normally when no enabled function is given at all", function()
      assert.has_no.errors(function()
        collector:collect(record, { amount = 1 }, EventTopic.DAMAGE_DEALT)
      end)
      assert.equal(1, record.metrics[MetricId.DAMAGE].dealt)
    end)
  end)
end)
