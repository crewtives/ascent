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

  -- A source that closes after its probe has already said yes.
  describe("degrading mid-session", function()
    it("turns a present capability off, unreadable by default, and says it did", function()
      registry:register("xp_chat", function() return true end)

      assert.is_true(registry:degrade("xp_chat"))
      assert.is_false(registry:has("xp_chat"))
      assert.equal("unreadable", registry:reasonFor("xp_chat"))
      assert.same({ "xp_chat" }, registry:missing())
    end)

    -- The caller marks the level on a true answer, so a second closed line must
    -- not read as a second degradation -- and an absent capability was never on.
    it("changes nothing the second time, or for one that was never on", function()
      registry:register("xp_chat", function() return true end)
      registry:register("combat_log", function() return false end)
      registry:degrade("xp_chat")

      assert.is_false(registry:degrade("xp_chat"))
      assert.is_false(registry:degrade("combat_log", Capabilities.Reason.UNREADABLE))
      assert.equal("absent", registry:reasonFor("combat_log"))
    end)

    it("refuses a name nobody registered, and a reason that is not one", function()
      registry:register("xp_chat", function() return true end)

      assert.has_error(function() registry:degrade("never_registered") end)
      assert.has_error(function() registry:degrade("xp_chat", Capabilities.Reason.PRESENT) end)
      assert.has_error(function() registry:degrade("xp_chat", "gone") end)
      assert.is_true(registry:has("xp_chat"))
    end)
  end)

  -- `missing()` alone cannot tell a healthy registry from an empty one: both print
  -- nothing, so the diagnostic also needs everything that was probed.
  describe("the whole roster", function()
    it("lists what was probed, present and absent alike, sorted", function()
      registry:register("zebra", function() return true end)
      registry:register("alpha", function() return false end)

      assert.same(
        {
          { name = "alpha", present = false, reason = "absent" },
          { name = "zebra", present = true, reason = "present" },
        },
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
  -- Absent and unreadable are two states: a client that never had the function
  -- lacks the feature; one that has it but hands back values this addon may not
  -- read has taken it away, which is a different report and a different fix.
  describe("the reason a capability is in the state it is in", function()
    it("calls a capability that answered yes present", function()
      registry:register("here", function() return true end)

      assert.equal("present", registry:reasonFor("here"))
    end)

    it("calls one the client does not have absent", function()
      registry:register("gone", function() return false end)

      assert.equal("absent", registry:reasonFor("gone"))
    end)

    it("keeps the reason a probe gives for what it could not read", function()
      local Reason = ns.adapter.Capabilities.Reason
      registry:register("closed", function() return false, Reason.UNREADABLE end)

      assert.equal("unreadable", registry:reasonFor("closed"))
      assert.is_false(registry:has("closed"))
      assert.same({ "closed" }, registry:missing())
    end)

    -- Available and unreadable at the same time is not a state, it is a probe
    -- contradicting itself, and what the caller relies on is the yes.
    it("ignores a reason that disagrees with a yes", function()
      local Reason = ns.adapter.Capabilities.Reason
      registry:register("odd", function() return true, Reason.UNREADABLE end)

      assert.equal("present", registry:reasonFor("odd"))
    end)

    it("refuses a reason that is not one of the three", function()
      assert.has_error(function()
        registry:register("bad", function() return false, "because" end)
      end, "Capabilities: 'bad' gave the unknown reason 'because'")
    end)

    it("has no reason for a name nobody registered", function()
      assert.is_nil(registry:reasonFor("never-heard-of-it"))
    end)
  end)
end)
