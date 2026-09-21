describe("CombatSummary", function()
  local ns, CombatSummary

  before_each(function()
    ns = AscentTest.loadDomain("core/model/Guard.lua", "core/model/CombatSummary.lua")
    CombatSummary = ns.core.CombatSummary
  end)

  -- Nothing to average is not the same as averaging to nothing. A level spent in a
  -- city has no combat samples, and reporting 0% health there would be a lie.
  describe("with no samples", function()
    it("answers nil rather than zero", function()
      local summary = CombatSummary.new()

      assert.is_false(summary:hasSamples())
      assert.is_nil(summary:averageHealth())
      assert.is_nil(summary:averagePower())
      assert.is_nil(summary:worstHealth())
      assert.is_nil(summary:worstPower())
    end)
  end)

  describe("with samples", function()
    it("averages health and resource across the fights of the level", function()
      local summary = CombatSummary.new()

      summary:record(0.8, 0.5)
      summary:record(0.4, 0.1)

      assert.equal(2, summary.samples)
      assert.is_true(math.abs(summary:averageHealth() - 0.6) < 1e-9)
      assert.is_true(math.abs(summary:averagePower() - 0.3) < 1e-9)
    end)

    it("remembers the worst fight, not just the average", function()
      local summary = CombatSummary.new()

      summary:record(0.9, 0.9)
      summary:record(0.08, 0.2)
      summary:record(0.7, 0.6)

      assert.equal(0.08, summary:worstHealth())
      assert.equal(0.2, summary:worstPower())
    end)

    it("accepts a fight that ended in death as a zero-health sample", function()
      local summary = CombatSummary.new()

      summary:record(0, 0.35)

      assert.equal(0, summary:worstHealth())
      assert.equal(0, summary:averageHealth())
      assert.equal(0.35, summary:averagePower())
    end)
  end)

  it("refuses samples that are not fractions of one", function()
    local summary = CombatSummary.new()

    assert.has_error(function() summary:record(1.2, 0.5) end)
    assert.has_error(function() summary:record(-0.1, 0.5) end)
    assert.has_error(function() summary:record(0.5, 101) end)
    assert.has_error(function() summary:record(nil, 0.5) end)
  end)
end)
