-- GUID shapes per D6: unitType-0-serverID-instanceID-zoneUID-ID-spawnUID for a
-- Creature; a Player GUID is a different, shorter shape entirely.

describe("CreatureGuid", function()
  local ns, CreatureGuid

  before_each(function()
    ns = AscentTest.loadDomain("adapter/inbound/CreatureGuid.lua")
    CreatureGuid = ns.adapter.CreatureGuid
  end)

  describe("typeOf", function()
    it("reads the unit type prefix", function()
      assert.equal("Creature", CreatureGuid.typeOf("Creature-0-3661-0-11-1234-00001B4C21"))
      assert.equal("Player", CreatureGuid.typeOf("Player-4657-0000A1B2"))
      assert.equal("Pet", CreatureGuid.typeOf("Pet-0-3661-0-11-1235-00001B4C22"))
      assert.equal("Vehicle", CreatureGuid.typeOf("Vehicle-0-3661-0-11-9999-00001B4C23"))
      assert.equal("GameObject", CreatureGuid.typeOf("GameObject-0-3661-0-11-5432-00001B4C24"))
    end)

    it("answers nil for a non-string or an empty value", function()
      assert.is_nil(CreatureGuid.typeOf(nil))
      assert.is_nil(CreatureGuid.typeOf(42))
      assert.is_nil(CreatureGuid.typeOf(""))
    end)
  end)

  describe("isCreature", function()
    it("is true only for a Creature GUID", function()
      assert.is_true(CreatureGuid.isCreature("Creature-0-3661-0-11-1234-00001B4C21"))
      assert.is_false(CreatureGuid.isCreature("Player-4657-0000A1B2"))
      assert.is_false(CreatureGuid.isCreature("Pet-0-3661-0-11-1235-00001B4C22"))
      assert.is_false(CreatureGuid.isCreature("Vehicle-0-3661-0-11-9999-00001B4C23"))
      assert.is_false(CreatureGuid.isCreature(nil))
    end)
  end)

  describe("npcId", function()
    it("reads the sixth field of a Creature GUID", function()
      assert.equal(1234, CreatureGuid.npcId("Creature-0-3661-0-11-1234-00001B4C21"))
    end)

    it("is nil for a Player GUID, whose sixth field is not an npc id at all", function()
      assert.is_nil(CreatureGuid.npcId("Player-4657-0000A1B2"))
    end)

    it("is nil for a Vehicle GUID -- same shape as Creature, different unit type", function()
      assert.is_nil(CreatureGuid.npcId("Vehicle-0-3661-0-11-9999-00001B4C23"))
    end)

    it("is nil for a Pet GUID", function()
      assert.is_nil(CreatureGuid.npcId("Pet-0-3661-0-11-1235-00001B4C22"))
    end)

    it("is nil for nil, an empty string, or a malformed GUID", function()
      assert.is_nil(CreatureGuid.npcId(nil))
      assert.is_nil(CreatureGuid.npcId(""))
      assert.is_nil(CreatureGuid.npcId("Creature-not-enough-fields"))
    end)
  end)
end)
