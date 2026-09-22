describe("XpGain", function()
  local ns, XpGain, XpSource, XpModifier

  local function gain(fields)
    fields.source = fields.source or XpSource.MOB_KILL
    fields.at = fields.at or 100
    return XpGain.new(fields)
  end

  before_each(function()
    ns = AscentTest.loadDomain("core/model/Guard.lua", "core/model/CreatureKey.lua", "core/model/XpGain.lua")
    XpGain = ns.core.XpGain
    XpSource = ns.core.XpSource
    XpModifier = ns.core.XpModifier
  end)

  describe("the rested split", function()
    -- The client announces the total with the bonus already inside it, so the base
    -- is what is left after taking the bonus out. Adding them would double-count.
    it("derives the base by subtracting the bonus from the amount received", function()
      local g = gain({ amount = 88, restedBonus = 44 })

      assert.equal(88, g.amount)
      assert.equal(44, g.restedBonus)
      assert.equal(44, g:baseAmount())
    end)

    it("always has base and bonus adding up to exactly the amount", function()
      for _, case in ipairs({ { 100, 0 }, { 100, 1 }, { 100, 99 }, { 100, 100 }, { 7, 3 } }) do
        local g = gain({ amount = case[1], restedBonus = case[2] })
        assert.equal(g.amount, g:baseAmount() + g.restedBonus)
      end
    end)

    it("is all base when there was no rest", function()
      local g = gain({ amount = 44 })

      assert.equal(44, g:baseAmount())
      assert.equal(0, g.restedBonus)
      assert.is_false(g:hasRestedBonus())
    end)

    it("refuses a bonus larger than what was received", function()
      assert.has_error(function() return gain({ amount = 44, restedBonus = 45 }) end)
    end)
  end)

  describe("validation", function()
    it("refuses negative amounts", function()
      assert.has_error(function() return gain({ amount = -1 }) end)
      assert.has_error(function() return gain({ amount = 10, restedBonus = -5 }) end)
      assert.has_error(function() return gain({ amount = 10, groupBonus = -5 }) end)
    end)

    it("refuses fractional amounts", function()
      assert.has_error(function() return gain({ amount = 10.5 }) end)
    end)

    it("accepts zero, because a kill can legitimately pay nothing", function()
      assert.equal(0, gain({ amount = 0 }).amount)
    end)

    -- 0 is what the client answers out of a group and the adapter is what turns it
    -- into the one person who was there. If it ever reaches the model the
    -- translation broke, and every average measured afterwards would belong to a
    -- group size nobody plays at -- so it raises here instead of dividing by it.
    it("refuses a group that nobody is in", function()
      assert.has_error(function() return gain({ amount = 10, sharedBy = 0 }) end)
      assert.has_error(function() return gain({ amount = 10, sharedBy = -2 }) end)
      assert.has_error(function() return gain({ amount = 10, sharedBy = 1.5 }) end)
    end)

    -- Absent is a real answer and the commonest one: every gain recorded before
    -- this existed has no size, and so does every gain the addon posts for
    -- experience it never watched being earned.
    it("accepts a gain nobody counted the group for", function()
      assert.is_nil(gain({ amount = 10 }).sharedBy)
    end)

    it("refuses a source that is not a real source", function()
      assert.has_error(function() return XpGain.new({ amount = 10, at = 1, source = "quest" }) end)
      assert.has_error(function() return XpGain.new({ amount = 10, at = 1, source = nil }) end)
    end)

    it("requires a timestamp, because matching hints to deltas depends on it", function()
      assert.has_error(function() return XpGain.new({ amount = 10, source = XpSource.MOB_KILL }) end)
    end)
  end)

  describe("modifiers", function()
    it("reports each modifier's share of the gain", function()
      local g = gain({ amount = 100, restedBonus = 20, groupBonus = 7, raidPenalty = 3 })

      assert.equal(20, g:modifierAmount(XpModifier.RESTED_BONUS))
      assert.equal(7, g:modifierAmount(XpModifier.GROUP_BONUS))
      assert.equal(3, g:modifierAmount(XpModifier.RAID_PENALTY))
    end)

    it("does not let modifiers change the amount that was received", function()
      local g = gain({ amount = 100, groupBonus = 7, raidPenalty = 3 })

      assert.equal(100, g.amount)
    end)

    it("rejects a modifier that does not exist rather than answering zero", function()
      local g = gain({ amount = 100 })

      assert.has_error(function() return g:modifierAmount("mount_bonus") end)
    end)
  end)

  describe("splitting across a level boundary", function()
    it("keeps the source on both halves and loses nothing", function()
      local g = gain({ amount = 1000, source = XpSource.QUEST_TURNIN, questId = 42 })

      local head, tail = g:splitAt(300)

      assert.equal(300, head.amount)
      assert.equal(700, tail.amount)
      assert.equal(XpSource.QUEST_TURNIN, head.source)
      assert.equal(XpSource.QUEST_TURNIN, tail.source)
      assert.equal(42, head.questId)
      assert.equal(g.amount, head.amount + tail.amount)
    end)

    it("splits the rested bonus proportionally and keeps the identity on both halves", function()
      local g = gain({ amount = 1000, restedBonus = 400 })

      local head, tail = g:splitAt(250)

      assert.equal(g.restedBonus, head.restedBonus + tail.restedBonus)
      assert.equal(head.amount, head:baseAmount() + head.restedBonus)
      assert.equal(tail.amount, tail:baseAmount() + tail.restedBonus)
    end)

    -- Not just the rested portion: a kill in a group carries a group bonus, and a
    -- kill that dings is exactly when that would have gone missing.
    it("divides every modifier without losing any of it", function()
      local g = gain({ amount = 1000, restedBonus = 400, groupBonus = 150, raidPenalty = 70 })

      local head, tail = g:splitAt(250)

      for _, name in ipairs(ns.core.Frozen.keys(XpModifier)) do
        local modifier = XpModifier[name]
        assert.equal(g:modifierAmount(modifier),
          head:modifierAmount(modifier) + tail:modifierAmount(modifier),
          name .. " did not survive the split")
      end
    end)

    it("keeps the modifiers intact across many split points", function()
      for cut = 0, 1000, 137 do
        local g = gain({ amount = 1000, restedBonus = 333, groupBonus = 77, raidPenalty = 11 })
        local head, tail = g:splitAt(cut)

        assert.equal(g.amount, head.amount + tail.amount)
        assert.equal(g.restedBonus, head.restedBonus + tail.restedBonus)
        assert.equal(g.groupBonus, head.groupBonus + tail.groupBonus)
        assert.equal(g.raidPenalty, head.raidPenalty + tail.raidPenalty)
      end
    end)

    -- The group is not a quantity: one kill was paid by one server decision, and
    -- both sides of a level boundary were part of it. Dividing it the way the
    -- modifiers are divided would put half of a party of five on each level and
    -- describe two groups that never existed; dropping it from the tail would file
    -- the second half of a dinging kill under "nobody counted".
    it("carries the whole group onto both halves rather than dividing it", function()
      local g = gain({ amount = 1000, sharedBy = 5 })

      local head, tail = g:splitAt(250)

      assert.equal(5, head.sharedBy)
      assert.equal(5, tail.sharedBy)
    end)

    it("leaves an uncounted gain uncounted on both halves", function()
      local head, tail = gain({ amount = 1000 }):splitAt(250)

      assert.is_nil(head.sharedBy)
      assert.is_nil(tail.sharedBy)
    end)

    it("refuses to split off more than the gain holds", function()
      local g = gain({ amount = 100 })

      assert.has_error(function() return g:splitAt(101) end)
    end)
  end)
end)
