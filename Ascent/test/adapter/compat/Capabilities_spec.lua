describe("Capabilities", function()
  local ns, Capabilities, registry

  before_each(function()
    ns = AscentTest.loadDomain("adapter/compat/Capabilities.lua")
    Capabilities = ns.adapter.Capabilities
    registry = Capabilities.new()
  end)

  it("reports a capability present when its probe returns true", function()
    registry:register("present", function() return true end)

    assert.is_true(registry:has("present"))
  end)

  it("reports an absent capability as absent, not as an error", function()
    registry:register("absent", function() return false end)

    assert.is_false(registry:has("absent"))
  end)

  it("treats a name nobody registered as absent", function()
    assert.is_false(registry:has("never_registered"))
  end)

  it("normalises a truthy, non-boolean probe result to present", function()
    registry:register("truthy", function() return {} end)

    assert.is_true(registry:has("truthy"))
  end)

  it("lists what came back absent, sorted, for the diagnostic surface", function()
    registry:register("b_missing", function() return nil end)
    registry:register("a_missing", function() return false end)
    registry:register("present", function() return true end)

    assert.same({ "a_missing", "b_missing" }, registry:missing())
  end)

  it("refuses a duplicate name", function()
    registry:register("dupe", function() return true end)

    assert.has_error(function()
      registry:register("dupe", function() return true end)
    end)
  end)

  it("refuses a probe that is not a function", function()
    assert.has_error(function()
      registry:register("bad", "not a function")
    end)
  end)

  -- `missing()` alone cannot tell a healthy registry from an empty one: both print
  -- nothing. A diagnostic that can only ever report absences is how a registry
  -- with no probes at all went unnoticed for the whole of this change.
  describe("the whole roster", function()
    it("lists what was probed, present and absent alike, sorted", function()
      registry:register("zebra", function() return true end)
      registry:register("alpha", function() return false end)

      assert.same(
        { { name = "alpha", present = false }, { name = "zebra", present = true } },
        registry:all()
      )
    end)

    it("is empty for a registry nobody registered anything with", function()
      assert.same({}, registry:all())
    end)

    it("normalises a truthy answer that is not a boolean", function()
      registry:register("fn", function() return print end)

      assert.is_true(registry:all()[1].present)
    end)
  end)
end)
