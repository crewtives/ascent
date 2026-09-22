describe("WowPlayerState", function()
  local state

  local STUBBED_GLOBALS = {
    "GetMaxPlayerLevel", "UnitLevel", "UnitXP", "UnitXPMax", "GetXPExhaustion",
    "IsResting", "IsXPUserDisabled", "UnitHealth", "UnitHealthMax",
    "UnitPower", "UnitPowerMax", "UnitGUID", "UnitName", "GetRealmName",
    "IsInInstance", "GetInstanceInfo", "GetZoneText", "C_Map", "GetNumGroupMembers",
  }

  local function load(overrides)
    overrides = overrides or {}
    _G.GetMaxPlayerLevel = function() return overrides.maxLevel or 60 end
    _G.UnitLevel = function() return overrides.level or 10 end
    _G.UnitXP = function() return overrides.xp or 100 end
    _G.UnitXPMax = function() return overrides.xpMax or 1000 end
    _G.GetXPExhaustion = function() return overrides.restedXp end
    _G.IsResting = function() return overrides.isResting end
    _G.IsXPUserDisabled = function() return overrides.isXpDisabled end
    _G.UnitHealth = function() return overrides.health or 80 end
    _G.UnitHealthMax = function() return overrides.healthMax or 100 end
    _G.UnitPower = function() return overrides.power or 40 end
    _G.UnitPowerMax = function() return overrides.powerMax or 50 end
    _G.UnitGUID = function() return overrides.guid or "Player-1-00000001" end
    _G.UnitName = function() return overrides.name or "Tester" end
    _G.GetRealmName = function() return overrides.realm or "TestRealm" end
    _G.IsInInstance = function() return overrides.inInstance, overrides.instanceType end
    _G.GetInstanceInfo = function()
      return overrides.instanceName, overrides.instanceType, nil, nil, nil, nil, nil, overrides.instanceId
    end
    _G.GetZoneText = function() return overrides.zone or "Elwynn Forest" end
    -- 0 is what the live client answers out of a group, so it is the default here.
    _G.GetNumGroupMembers = function() return overrides.groupMembers or 0 end
    _G.C_Map = overrides.noMapApi and {} or {
      GetBestMapForUnit = function() return overrides.mapId end,
      -- Answers nothing unless a case asks for a map name, so the cases that do not
      -- keep exercising the zone-text fallback.
      GetMapInfo = function(mapId)
        if overrides.mapName == nil then
          return nil
        end
        return { mapID = mapId, name = overrides.mapName }
      end,
    }

    local ns = AscentTest.loadWith("core/port/", "adapter/compat/", "adapter/outbound/WowPlayerState.lua")
    state = ns.adapter.WowPlayerState.new()
  end

  after_each(function()
    for _, name in ipairs(STUBBED_GLOBALS) do
      _G[name] = nil
    end
  end)

  it("reads level and maximum level straight from the client", function()
    load({ level = 23, maxLevel = 60 })

    assert.equal(23, state:level())
    assert.equal(60, state:maxLevel())
  end)

  it("reads current and maximum experience", function()
    load({ xp = 4200, xpMax = 9000 })

    assert.equal(4200, state:xp())
    assert.equal(9000, state:xpMax())
  end)

  it("reports no rested reserve as zero rather than nil", function()
    load({ restedXp = nil })

    assert.equal(0, state:restedXp())
  end)

  it("reports a rested reserve as the client gives it, undivided", function()
    load({ restedXp = 500 })

    assert.equal(500, state:restedXp())
  end)

  it("normalises resting and experience-disabled to real booleans", function()
    load({ isResting = 1, isXpDisabled = nil })

    assert.is_true(state:isResting())
    assert.is_false(state:isXpDisabled())
  end)

  it("derives health and power as fractions of maximum", function()
    load({ health = 25, healthMax = 100, power = 3, powerMax = 5 })

    assert.equal(0.25, state:healthFraction())
    assert.equal(0.6, state:powerFraction())
  end)

  -- D42: the identifier that means something depends on where the character is,
  -- and getting the rule backwards collapses the whole open world into a few
  -- continents or leaves every dungeon without an identity at all.
  describe("where the character is", function()
    it("is the map id and the zone name out in the world", function()
      load({ inInstance = false, mapId = 1429, zone = "Elwynn Forest" })

      local context, areaId, name = state:place()

      assert.equal("world", context)
      assert.equal(1429, areaId)
      assert.equal("Elwynn Forest", name)
    end)

    -- One map id, two zone names: an indoor area answers with its own name while the
    -- id underneath stays the zone's. Taking the name from the id is what keeps a
    -- level spent across Eversong Woods from being filed under a building in it.
    it("names the map rather than the indoor area the client calls the zone", function()
      load({ inInstance = false, mapId = 1941, mapName = "Eversong Woods",
             zone = "Duskwither Spire" })

      local context, areaId, name = state:place()

      assert.equal("world", context)
      assert.equal(1941, areaId)
      assert.equal("Eversong Woods", name)
    end)

    it("falls back to the zone text where the map cannot name itself", function()
      load({ inInstance = false, mapId = 1941, zone = "Duskwither Spire" })

      assert.equal("Duskwither Spire", select(3, state:place()))
    end)

    it("is the instance id inside a dungeon, not the map id", function()
      load({ inInstance = true, instanceType = "party", instanceId = 389,
             instanceName = "Ragefire Chasm", mapId = 9999 })

      local context, areaId, name = state:place()

      assert.equal("dungeon", context)
      assert.equal(389, areaId)
      assert.equal("Ragefire Chasm", name)
    end)

    it("tells a raid, a battleground and an arena apart from a dungeon", function()
      load({ inInstance = true, instanceType = "raid", instanceId = 409 })
      assert.equal("raid", (state:place()))

      load({ inInstance = true, instanceType = "pvp", instanceId = 30 })
      assert.equal("battleground", (state:place()))

      load({ inInstance = true, instanceType = "arena", instanceId = 559 })
      assert.equal("arena", (state:place()))
    end)

    -- What the reserved entry is for. Crossing a portal is the case the design
    -- calls out, and it looks like this: the client answers with no usable number.
    it("says nothing rather than guessing when the client has no identifier yet", function()
      load({ inInstance = false, mapId = nil, zone = "" })

      local context, areaId, name = state:place()

      assert.equal("world", context)
      assert.is_nil(areaId)
      assert.is_nil(name)
    end)

    it("treats a zero identifier as no identifier", function()
      load({ inInstance = false, mapId = 0 })

      assert.is_nil(select(2, state:place()))
    end)

    it("degrades to no identifier where the map API is absent", function()
      load({ inInstance = false, noMapApi = true })

      assert.is_nil(select(2, state:place()))
    end)

    -- A kind this addon has never mapped answers nil rather than the nearest thing
    -- that resembles it: the domain files that under the reserved entry.
    it("answers no kind at all for an instance type it does not know", function()
      load({ inInstance = true, instanceType = "scenario", instanceId = 700 })

      assert.is_nil((state:place()))
    end)
  end)

  -- D85: the port asks how many people share the payment, not what
  -- `GetNumGroupMembers()` returns. The client counts a party and a raid through
  -- that one call, so both sizes arrive the same way -- and out of a group it
  -- answers 0, which is the one answer that is not a number of people.
  describe("how many share what a kill pays", function()
    it("is one alone, where the client counts nobody", function()
      load({ groupMembers = 0 })

      assert.equal(1, state:sharedBy())
    end)

    it("is the whole party, the character included", function()
      load({ groupMembers = 5 })

      assert.equal(5, state:sharedBy())
    end)

    it("is the whole raid inside one", function()
      load({ groupMembers = 25 })

      assert.equal(25, state:sharedBy())
    end)
  end)

  it("identifies the character by guid, name and realm", function()
    load({ guid = "Player-1-DEADBEEF", name = "Ascentia", realm = "TestRealm" })

    assert.equal("Player-1-DEADBEEF", state:guid())
    local name, realm = state:identity()
    assert.equal("Ascentia", name)
    assert.equal("TestRealm", realm)
  end)
end)
