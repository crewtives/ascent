-- The rule the view and the options panel both ask, so that neither keeps its own
-- copy of it. Suspended means inapplicable while the slot lasts -- never cleared.

describe("BarSlotPolicy", function()
  local ns, BarSlotPolicy, BarSlot

  before_each(function()
    ns = AscentTest.loadDomain("core/service/BarSlotPolicy.lua")
    BarSlotPolicy = ns.core.BarSlotPolicy
    BarSlot = ns.core.BarSlot
  end)

  it("suspends nothing while the bar is free on the screen", function()
    local suspended = BarSlotPolicy.suspends(BarSlot.OFF)

    assert.is_false(BarSlotPolicy.active(BarSlot.OFF))
    assert.is_false(suspended.position)
    assert.is_false(suspended.size)
  end)

  for _, slot in ipairs({ "INSET", "REPLACE" }) do
    it("suspends position and size in the " .. slot:lower() .. " slot", function()
      local suspended = BarSlotPolicy.suspends(BarSlot[slot])

      assert.is_true(BarSlotPolicy.active(BarSlot[slot]))
      assert.is_true(suspended.position)
      assert.is_true(suspended.size)
    end)
  end

  it("keeps the client's frame visible only in the inset slot", function()
    assert.is_true(BarSlotPolicy.keepsClientFrame(BarSlot.INSET))
    assert.is_false(BarSlotPolicy.keepsClientFrame(BarSlot.REPLACE))
    assert.is_false(BarSlotPolicy.keepsClientFrame(BarSlot.OFF))
  end)

  -- A stored value that resolving would have rejected cannot reach here, but a
  -- caller passing nil (a settings table from a version that lost the key) must
  -- get the safe answer rather than an error.
  it("treats an unknown slot as not active", function()
    assert.is_false(BarSlotPolicy.active(nil))
    assert.is_false(BarSlotPolicy.suspends(nil).position)
  end)

  -- The two slots differ in who draws on top, and a bar that states no depth
  -- takes whatever the creation order gave it, so the same setting could look
  -- inset in one session and paint over the client's frame in the next.
  it("draws under the client's frame in the inset slot, and over it in replace", function()
    assert.equals(4, BarSlotPolicy.depth(BarSlot.INSET, 5))
    assert.equals(6, BarSlotPolicy.depth(BarSlot.REPLACE, 5))
  end)

  it("has no depth to give where there is no slot to stand in", function()
    assert.is_nil(BarSlotPolicy.depth(BarSlot.OFF, 5))
    assert.is_nil(BarSlotPolicy.depth(nil, 5))
  end)

  -- A client that cannot say how deep its own frame is gets no answer invented
  -- for it: the view leaves the bar's depth alone rather than setting it to a
  -- number derived from nothing.
  it("has no depth to give when the client cannot say how deep its frame is", function()
    assert.is_nil(BarSlotPolicy.depth(BarSlot.INSET, nil))
    assert.is_nil(BarSlotPolicy.depth(BarSlot.REPLACE, "2"))
  end)

  -- The floor: the anchor is the client's experience bar, which the addon makes
  -- invisible; what still draws in the strip is the art of the frame around it,
  -- owned by the anchor's parent. One level under the anchor would tie with that
  -- parent, and a tie goes to creation order.
  it("goes under the frame that paints, not under the one it stands in", function()
    -- Anchor at 5, the frame whose art must stay on top at 2.
    assert.equals(1, BarSlotPolicy.depth(BarSlot.INSET, 5, 2))
  end)

  -- Replace has no such problem: the place belongs to the bar, so it draws last
  -- and the floor is none of its business.
  it("ignores the floor in the replace slot", function()
    assert.equals(6, BarSlotPolicy.depth(BarSlot.REPLACE, 5, 2))
  end)

  -- A floor above the anchor cannot raise the bar into the art it has to stay
  -- under: the two are combined by taking the lower, never the given one.
  it("never lets the floor push the bar up into the client's art", function()
    assert.equals(4, BarSlotPolicy.depth(BarSlot.INSET, 5, 9))
  end)

  -- No floor is not zero. A client whose chain says nothing useful falls back on
  -- the anchor's own level, which is the best answer available rather than the
  -- bottom of the world.
  it("falls back on the anchor when there is no floor to be had", function()
    assert.equals(4, BarSlotPolicy.depth(BarSlot.INSET, 5, nil))
    assert.equals(4, BarSlotPolicy.depth(BarSlot.INSET, 5, "2"))
  end)

  -- There is nothing below zero: the bar ties with the client's frame and the
  -- creation order decides. That is accepted for one frame on one client rather
  -- than adding a second rule that could itself be wrong.
  it("cannot go below the floor the client leaves it", function()
    assert.equals(0, BarSlotPolicy.depth(BarSlot.INSET, 0))
    assert.equals(0, BarSlotPolicy.depth(BarSlot.INSET, 5, 0))
    assert.equals(1, BarSlotPolicy.depth(BarSlot.REPLACE, 0))
  end)
end)
