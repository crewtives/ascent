-- A client is identified by the interface number GetBuildInfo declares, not by
-- GetMaxPlayerLevel: World of Warcraft: Forever caps at 60, the same as Classic
-- Era, and the wrong flavour sends the addon looking for a UI tree the running
-- client does not have.

describe("Compat", function()
  local function loadWith(interface, maxLevel)
    _G.GetBuildInfo = function() return "0.0.0", "00000", "Jan 01 2026", interface end
    _G.GetMaxPlayerLevel = function() return maxLevel end
    local ns = AscentTest.loadDomain("adapter/compat/Readable.lua", "adapter/compat/Compat.lua")
    return ns.adapter.Compat, ns.core.ClientFlavor
  end

  after_each(function()
    _G.GetBuildInfo = nil
    _G.GetMaxPlayerLevel = nil
  end)

  local CASES = {
    { name = "Classic Era", interface = 11509, maxLevel = 60, flavorKey = "CLASSIC_ERA" },
    { name = "Burning Crusade Classic", interface = 20506, maxLevel = 70, flavorKey = "BURNING_CRUSADE" },
    { name = "Forever", interface = 16001, maxLevel = 60, flavorKey = "FOREVER" },
  }

  for _, case in ipairs(CASES) do
    it("reports " .. case.name .. "'s own maximum level and flavor", function()
      local Compat, ClientFlavor = loadWith(case.interface, case.maxLevel)

      assert.equal(case.maxLevel, Compat.maxLevel())
      assert.equal(case.interface, Compat.interfaceVersion())
      assert.equal(ClientFlavor[case.flavorKey], Compat.flavor())
    end)
  end

  it("tells Forever from Classic Era, which cap at the same level", function()
    local forever, ClientFlavor = loadWith(16001, 60)
    assert.equal(ClientFlavor.FOREVER, forever.flavor())

    local classic = loadWith(11509, 60)
    assert.equal(ClientFlavor.CLASSIC_ERA, classic.flavor())
  end)

  -- An interface number carries the patch in its last two digits, and a client
  -- that patches is the same client. Keyed on the whole number, the table would
  -- answer UNKNOWN on every patch day.
  it("keeps recognising a client across a patch of its own release", function()
    local Compat, ClientFlavor = loadWith(11510, 60)

    assert.equal(ClientFlavor.CLASSIC_ERA, Compat.flavor())
  end)

  it("degrades to UNKNOWN rather than guessing at a release it has never seen", function()
    local Compat, ClientFlavor = loadWith(11605, 60)

    assert.equal(ClientFlavor.UNKNOWN, Compat.flavor())
  end)

  -- A table of known releases, not a threshold: Forever's 16001 is a smaller
  -- number than Retail's, and the usual `>= 100000` test for "modern client"
  -- reads it as an old one.
  it("does not read Retail as one of the supported clients", function()
    local Compat, ClientFlavor = loadWith(110007, 80)

    assert.equal(ClientFlavor.UNKNOWN, Compat.flavor())
  end)

  it("survives a client that does not answer what it is", function()
    _G.GetBuildInfo = nil
    _G.GetMaxPlayerLevel = function() return 60 end
    local ns = AscentTest.loadDomain("adapter/compat/Readable.lua", "adapter/compat/Compat.lua")

    assert.is_nil(ns.adapter.Compat.interfaceVersion())
    assert.equal(ns.core.ClientFlavor.UNKNOWN, ns.adapter.Compat.flavor())
  end)
end)
