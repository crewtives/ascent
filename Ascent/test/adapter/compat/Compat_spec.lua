-- The client fills MAX_PLAYER_LEVEL with zero on both flavors (D17), so
-- GetMaxPlayerLevel() is the only signal the addon trusts for the maximum level --
-- and, because the two supported flavors cap at different levels, the same call
-- doubles as flavor detection.

describe("Compat", function()
  local function loadWith(maxLevel)
    _G.GetMaxPlayerLevel = function() return maxLevel end
    local ns = AscentTest.loadDomain("adapter/compat/Compat.lua")
    return ns.adapter.Compat, ns.core.ClientFlavor
  end

  after_each(function()
    _G.GetMaxPlayerLevel = nil
  end)

  local CASES = {
    { name = "Classic Era", maxLevel = 60, flavorKey = "CLASSIC_ERA" },
    { name = "Burning Crusade Classic", maxLevel = 70, flavorKey = "BURNING_CRUSADE" },
  }

  for _, case in ipairs(CASES) do
    it("reports " .. case.name .. "'s own maximum level and flavor", function()
      local Compat, ClientFlavor = loadWith(case.maxLevel)

      assert.equal(case.maxLevel, Compat.maxLevel())
      assert.equal(ClientFlavor[case.flavorKey], Compat.flavor())
    end)
  end

  it("degrades to UNKNOWN rather than guessing at an unrecognised maximum level", function()
    local Compat, ClientFlavor = loadWith(80)

    assert.equal(ClientFlavor.UNKNOWN, Compat.flavor())
  end)
end)
