-- What the router promises: the right topic, for the right side of the fight, and
-- nothing for a line neither the player nor their pet is part of. CREATURE_DIED
-- carries the {name, npcId, level, at} shape XpAttribution consumes.

local PLAYER_GUID = "Player-1-00000001"
local PET_GUID = "Pet-0-3661-0-11-9999-00000002"
local BOAR_GUID = "Creature-0-3661-0-11-1234-00001B4C21"
local OTHER_CREATURE_GUID = "Creature-0-3661-0-11-5678-00001B4C99"

describe("CombatLogRouter", function()
  local ns, CombatLogSubevent, EventTopic, AbilityKey
  local bus, clock, player, router

  local function load()
    return AscentTest.loadWith("core/port/", "adapter/compat/Readable.lua", "adapter/compat/Capabilities.lua",
      "adapter/inbound/CreatureGuid.lua", "adapter/inbound/CombatLogRouter.lua",
      "test/fakes/FakeClock.lua", "test/fakes/FakePlayerState.lua", "test/fakes/RecordingEventBus.lua")
  end

  -- Stands in for C_CombatLog.GetCurrentEventInfo(): the shared eleven-field
  -- prefix, then whatever extras that subevent carries.
  local function emit(subevent, sourceGUID, destGUID, destName, ...)
    local extra = { ... }
    _G.C_CombatLog = {
      GetCurrentEventInfo = function()
        return clock:now(), subevent, false, sourceGUID, "Source", 0, 0, destGUID, destName, 0, 0,
          unpack(extra)
      end,
    }
    router:handleCombatLogEvent()
  end

  before_each(function()
    ns = load()
    CombatLogSubevent = ns.core.CombatLogSubevent
    EventTopic = ns.core.EventTopic
    AbilityKey = ns.core.AbilityKey

    clock = ns.fakes.FakeClock.new(1000)
    player = ns.fakes.FakePlayerState.new({ guid = PLAYER_GUID })
    bus = ns.fakes.RecordingEventBus.new()

    _G.UnitGUID = function(unit) if unit == "pet" then return PET_GUID end end
    _G.UnitTokenFromGUID = function() return nil end
    _G.UnitLevel = function() return nil end

    router = ns.adapter.CombatLogRouter.new({ bus = bus, clock = clock, playerState = player })
  end)

  after_each(function()
    _G.C_CombatLog = nil
    _G.CombatLogGetCurrentEventInfo = nil
    _G.UnitGUID = nil
    _G.UnitTokenFromGUID = nil
    _G.UnitLevel = nil
  end)

  describe("the early filter that keeps the combat log cheap", function()
    it("discards an event where neither the player nor their pet is involved", function()
      emit(CombatLogSubevent.SPELL_CAST_SUCCESS, OTHER_CREATURE_GUID, BOAR_GUID, "Boar", 111, "Enemy Spell")

      assert.same({}, bus:topicsInOrder())
    end)

    -- Not SPELL_AURA_APPLIED: a debuff landing is dispatched, because it names a
    -- creature that is fighting you. A subevent outside the table costs nothing.
    it("discards a subevent nobody dispatches, even one involving the player", function()
      emit("SPELL_ENERGIZE", PLAYER_GUID, BOAR_GUID, "Boar")

      assert.same({}, bus:topicsInOrder())
    end)

    it("still keeps a UNIT_DIED whose destination is a creature, even with neither side the player", function()
      emit(CombatLogSubevent.UNIT_DIED, OTHER_CREATURE_GUID, BOAR_GUID, "Boar")

      assert.equal(1, bus:countOf(EventTopic.CREATURE_DIED))
    end)

    it("discards a UNIT_DIED whose destination is not a creature and involves neither the player nor their pet",
      function()
        emit(CombatLogSubevent.UNIT_DIED, OTHER_CREATURE_GUID, "Player-4657-0000B2C3", "SomeOtherPlayer")

        assert.same({}, bus:topicsInOrder())
      end)
  end)

  describe("abilities", function()
    it("counts a successful spell cast by its spell id, only from the player", function()
      emit(CombatLogSubevent.SPELL_CAST_SUCCESS, PLAYER_GUID, BOAR_GUID, "Boar", 12345, "Fireball", 4)

      assert.same({ key = 12345, name = "Fireball" }, bus:lastOn(EventTopic.ABILITY_USED))
    end)

    it("counts the pet's abilities too", function()
      emit(CombatLogSubevent.SPELL_CAST_SUCCESS, PET_GUID, BOAR_GUID, "Boar", 999, "Bite", 1)

      assert.equal(999, bus:lastOn(EventTopic.ABILITY_USED).key)
    end)

    it("counts a melee swing that hit as an ability use, under the synthetic key", function()
      emit(CombatLogSubevent.SWING_DAMAGE, PLAYER_GUID, BOAR_GUID, "Boar", 42)

      assert.equal(AbilityKey.MELEE_SWING, bus:lastOn(EventTopic.ABILITY_USED).key)
      assert.equal(42, bus:lastOn(EventTopic.DAMAGE_DEALT).amount)
    end)

    it("counts a melee swing that missed as used too, with no damage", function()
      emit(CombatLogSubevent.SWING_MISSED, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.equal(AbilityKey.MELEE_SWING, bus:lastOn(EventTopic.ABILITY_USED).key)
      assert.equal(0, bus:countOf(EventTopic.DAMAGE_DEALT))
    end)

    it("counts a ranged auto attack under its own synthetic key", function()
      emit(CombatLogSubevent.RANGE_DAMAGE, PLAYER_GUID, BOAR_GUID, "Boar", 75, "Shoot", 1, 15)

      assert.equal(AbilityKey.RANGED_AUTO, bus:lastOn(EventTopic.ABILITY_USED).key)
      assert.equal(15, bus:lastOn(EventTopic.DAMAGE_DEALT).amount)
    end)

    -- A wand reports every shot twice: as its own SPELL_CAST_SUCCESS and as a
    -- RANGE_DAMAGE carrying the same spell. Counting both would read twelve shots
    -- as "Shoot x12" and "Ranged attack x12".
    it("does not count a shot again when it announced its own cast", function()
      emit(CombatLogSubevent.SPELL_CAST_SUCCESS, PLAYER_GUID, BOAR_GUID, "Boar", 5019, "Shoot", 1)
      emit(CombatLogSubevent.RANGE_DAMAGE, PLAYER_GUID, BOAR_GUID, "Boar", 5019, "Shoot", 1, 15)

      assert.equal(1, bus:countOf(EventTopic.ABILITY_USED), "the same shot was counted twice")
      assert.equal(5019, bus:lastOn(EventTopic.ABILITY_USED).key)
      assert.equal(15, bus:lastOn(EventTopic.DAMAGE_DEALT).amount, "the damage still counts")
    end)

    it("keeps the synthetic key for a shot that never announces a cast", function()
      emit(CombatLogSubevent.RANGE_DAMAGE, PLAYER_GUID, BOAR_GUID, "Boar", 75, "Auto Shot", 1, 15)
      emit(CombatLogSubevent.RANGE_MISSED, PLAYER_GUID, BOAR_GUID, "Boar", 75, "Auto Shot", 1)

      assert.equal(2, bus:countOf(EventTopic.ABILITY_USED))
      assert.equal(AbilityKey.RANGED_AUTO, bus:lastOn(EventTopic.ABILITY_USED).key)
    end)

    it("counts a ranged miss as used too, with no damage", function()
      emit(CombatLogSubevent.RANGE_MISSED, PLAYER_GUID, BOAR_GUID, "Boar", 75, "Shoot", 1)

      assert.equal(AbilityKey.RANGED_AUTO, bus:lastOn(EventTopic.ABILITY_USED).key)
      assert.equal(0, bus:countOf(EventTopic.DAMAGE_DEALT))
    end)

    it("does not count a DoT tick as a new use -- only SPELL_CAST_SUCCESS does that", function()
      emit(CombatLogSubevent.SPELL_PERIODIC_DAMAGE, PLAYER_GUID, BOAR_GUID, "Boar", 50, "Rend", 1, 8)

      assert.equal(0, bus:countOf(EventTopic.ABILITY_USED))
      assert.equal(8, bus:lastOn(EventTopic.DAMAGE_DEALT).amount)
    end)
  end)

  -- Being fought is not the same fact as being hurt, and the plate needs the first
  -- one: a creature that charges you and misses is in the pull.
  describe("who is in the fight", function()
    it("engages the creature the player swung at", function()
      emit(CombatLogSubevent.SWING_DAMAGE, PLAYER_GUID, BOAR_GUID, "Boar", 30)

      assert.equal(BOAR_GUID, bus:lastOn(EventTopic.ENEMY_ENGAGED).guid)
      assert.equal("Boar", bus:lastOn(EventTopic.ENEMY_ENGAGED).name)
    end)

    it("engages a creature that swung at the player and missed", function()
      emit(CombatLogSubevent.SWING_MISSED, BOAR_GUID, PLAYER_GUID, "Player", "MISS")

      assert.equal(BOAR_GUID, bus:lastOn(EventTopic.ENEMY_ENGAGED).guid)
      assert.equal(0, bus:countOf(EventTopic.DAMAGE_TAKEN), "a miss hurt nobody")
    end)

    it("engages a creature whose spell missed, and one whose debuff landed", function()
      emit(CombatLogSubevent.SPELL_MISSED, BOAR_GUID, PLAYER_GUID, "Player", 133, "Fireball", 4, "RESIST")
      assert.equal(1, bus:countOf(EventTopic.ENEMY_ENGAGED))

      emit(CombatLogSubevent.SPELL_AURA_APPLIED, OTHER_CREATURE_GUID, PLAYER_GUID, "Player",
        589, "Shadow Word: Pain", 32, "DEBUFF")
      assert.equal(OTHER_CREATURE_GUID, bus:lastOn(EventTopic.ENEMY_ENGAGED).guid)
    end)

    it("engages what is fighting the pet, which is fighting the player", function()
      emit(CombatLogSubevent.SWING_DAMAGE, BOAR_GUID, PET_GUID, "Pet", 12)

      assert.equal(BOAR_GUID, bus:lastOn(EventTopic.ENEMY_ENGAGED).guid)
    end)

    -- A player duelling you, a falling rock, a training dummy's owner: damage with
    -- no creature on the other end engages nobody.
    it("engages nobody when the other side is not a creature", function()
      emit(CombatLogSubevent.SWING_DAMAGE, "Player-4657-0000AAAA", PLAYER_GUID, "Player", 30)

      assert.equal(0, bus:countOf(EventTopic.ENEMY_ENGAGED))
    end)

    -- A friendly NPC healing you is a creature on the other side of a line, and it
    -- is not a fight: enrolling it would put a quest giver in the pull and expect
    -- experience for killing them.
    it("engages nobody when a creature heals the player", function()
      emit(CombatLogSubevent.SPELL_HEAL, BOAR_GUID, PLAYER_GUID, "Player", 2050, "Lesser Heal", 2, 40)

      assert.equal(40, bus:lastOn(EventTopic.HEALING_RECEIVED).amount)
      assert.equal(0, bus:countOf(EventTopic.ENEMY_ENGAGED))
    end)

    -- On a death neither side is the player, and the creature that died is not
    -- something the player just engaged.
    it("engages nobody on a death it merely overheard", function()
      emit(CombatLogSubevent.UNIT_DIED, OTHER_CREATURE_GUID, BOAR_GUID, "Boar")

      assert.equal(0, bus:countOf(EventTopic.ENEMY_ENGAGED))
      assert.equal(1, bus:countOf(EventTopic.CREATURE_DIED))
    end)
  end)

  describe("damage taken and healing", function()
    it("reports damage the player takes as DAMAGE_TAKEN, not DAMAGE_DEALT", function()
      emit(CombatLogSubevent.SWING_DAMAGE, BOAR_GUID, PLAYER_GUID, "Player", 30)

      assert.equal(30, bus:lastOn(EventTopic.DAMAGE_TAKEN).amount)
      assert.equal(0, bus:countOf(EventTopic.DAMAGE_DEALT))
      assert.equal(0, bus:countOf(EventTopic.ABILITY_USED))
    end)

    -- A creature hitting the player is the only thing that names a fight the player
    -- did not start; without it the pull plate lists only what the player hit back.
    it("names the creature that landed the blow", function()
      emit(CombatLogSubevent.SWING_DAMAGE, BOAR_GUID, PLAYER_GUID, "Player", 30)

      local taken = bus:lastOn(EventTopic.DAMAGE_TAKEN)
      assert.equal(30, taken.amount)
      assert.equal("Source", taken.name)
      assert.equal(BOAR_GUID, taken.guid)
    end)

    -- Same guard as the blow the player lands: a fall, a trap or another player is
    -- damage with no creature on the other end, and a nameless enemy is an
    -- invention rather than a reading.
    it("names nothing when what hit the player is not a creature", function()
      emit(CombatLogSubevent.SWING_DAMAGE, "Player-4657-0000AAAA", PLAYER_GUID, "Player", 30)

      local taken = bus:lastOn(EventTopic.DAMAGE_TAKEN)
      assert.equal(30, taken.amount)
      assert.is_nil(taken.name)
      assert.is_nil(taken.guid)
    end)

    it("carries the attacker on spell and ranged damage as well as on a swing", function()
      emit(CombatLogSubevent.SPELL_DAMAGE, BOAR_GUID, PLAYER_GUID, "Player", 133, "Fireball", 4, 25)
      assert.equal(BOAR_GUID, bus:lastOn(EventTopic.DAMAGE_TAKEN).guid)

      emit(CombatLogSubevent.RANGE_DAMAGE, OTHER_CREATURE_GUID, PLAYER_GUID, "Player",
        75, "Shoot", 1, 12)
      assert.equal(OTHER_CREATURE_GUID, bus:lastOn(EventTopic.DAMAGE_TAKEN).guid)
    end)

    it("reports healing the player receives, from any source", function()
      emit(CombatLogSubevent.SPELL_HEAL, "Player-4657-0000AAAA", PLAYER_GUID, "Player", 50, "Flash Heal", 2, 40)

      assert.equal(40, bus:lastOn(EventTopic.HEALING_RECEIVED).amount)
    end)

    it("does not report healing cast on someone else", function()
      emit(CombatLogSubevent.SPELL_HEAL, PLAYER_GUID, OTHER_CREATURE_GUID, "Other", 50, "Flash Heal", 2, 40)

      assert.equal(0, bus:countOf(EventTopic.HEALING_RECEIVED))
    end)
  end)

  describe("creature deaths (feeding the kill correlator)", function()
    it("publishes CREATURE_DIED with the name and npc id from the GUID", function()
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.same(
        { name = "Boar", npcId = 1234, level = nil, at = clock:now() },
        bus:lastOn(EventTopic.CREATURE_DIED)
      )
    end)

    -- UnitTokenFromGUID is the only client call made inside the combat-log handler,
    -- once per death. A client without it would raise on the first kill and, with
    -- Lua errors off (the default), silently leave every later kill unattributed.
    it("still reports the death on a client that has no UnitTokenFromGUID", function()
      _G.UnitTokenFromGUID = nil

      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.equal(1, bus:countOf(EventTopic.CREATURE_DIED))
      assert.is_nil(bus:lastOn(EventTopic.CREATURE_DIED).level)
    end)

    it("resolves the creature's level when a unit token currently points at it", function()
      _G.UnitTokenFromGUID = function(guid) if guid == BOAR_GUID then return "target" end end
      _G.UnitLevel = function(token) if token == "target" then return 14 end end

      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.equal(14, bus:lastOn(EventTopic.CREATURE_DIED).level)
    end)

    it("leaves the level unknown, not guessed, when no token points at the creature", function()
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.is_nil(bus:lastOn(EventTopic.CREATURE_DIED).level)
    end)

    -- The client fires PARTY_KILL alongside UNIT_DIED for the same death (same GUID,
    -- same instant) whenever the player or their group caused it, never alone.
    -- Publishing both would book each kill twice, and the unclaimed copy would
    -- expire as a kill that paid no experience.
    it("ignores PARTY_KILL entirely -- UNIT_DIED alone already covers every death it would report", function()
      emit(CombatLogSubevent.PARTY_KILL, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.equal(0, bus:countOf(EventTopic.CREATURE_DIED))
    end)

    it("does not double-publish when the client fires both for the same kill", function()
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")
      emit(CombatLogSubevent.PARTY_KILL, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.equal(1, bus:countOf(EventTopic.CREATURE_DIED))
    end)

    -- A killing blow fires UNIT_DIED and PARTY_KILL for the same creature at the
    -- same GetTime() reading.
    it("does not publish CREATURE_DIED twice for one kill's UNIT_DIED and PARTY_KILL pair", function()
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")
      emit(CombatLogSubevent.PARTY_KILL, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.equal(1, bus:countOf(EventTopic.CREATURE_DIED))
    end)

    it("does not dedupe a different creature dying moments later", function()
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")
      clock:advance(0.1)
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, OTHER_CREATURE_GUID, "Wolf")

      assert.equal(2, bus:countOf(EventTopic.CREATURE_DIED))
    end)

    it("does not dedupe the same creature type dying again well outside the window", function()
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")
      clock:advance(5)
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")

      assert.equal(2, bus:countOf(EventTopic.CREATURE_DIED))
    end)

    it("never fires for a death that is not a creature's", function()
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, "Pet-0-3661-0-11-1235-00001B4C22", "SomePet")

      assert.equal(0, bus:countOf(EventTopic.CREATURE_DIED))
    end)
  end)

  it("falls back to the deprecated global only when C_CombatLog is absent", function()
    _G.C_CombatLog = nil
    _G.CombatLogGetCurrentEventInfo = function()
      return clock:now(), CombatLogSubevent.UNIT_DIED, false, PLAYER_GUID, "Source", 0, 0, BOAR_GUID, "Boar", 0, 0
    end

    router:handleCombatLogEvent()

    assert.equal(1, bus:countOf(EventTopic.CREATURE_DIED))
  end)

  -- CombatLogGetCurrentEventInfo is not in the World of Warcraft: Forever API, so
  -- the promise is that it is not even looked up. Every read of a name _G does not
  -- hold goes through __index, so a watcher there sees a lookup either way.
  it("never looks the deprecated global up on a client that has the modern reader", function()
    local looked = 0
    local saved = getmetatable(_G)
    setmetatable(_G, { __index = function(_, name)
      if name == "CombatLogGetCurrentEventInfo" then looked = looked + 1 end
    end })

    local ok, err = pcall(function()
      emit(CombatLogSubevent.UNIT_DIED, PLAYER_GUID, BOAR_GUID, "Boar")
      ns.adapter.CombatLogRouter.isSupported()
    end)
    setmetatable(_G, saved)
    assert(ok, err)

    assert.equal(1, bus:countOf(EventTopic.CREATURE_DIED))
    assert.equal(0, looked)
  end)

  it("reads nothing, and raises nothing, on a client with neither reader", function()
    _G.C_CombatLog = nil

    assert.has_no.errors(function() router:handleCombatLogEvent() end)
    assert.same({}, bus:topicsInOrder())
  end)

  -- The capability every combat metric hangs from, read the way the diagnostic
  -- reads it: through the registry, as the reason it prints.
  describe("whether this client offers it", function()
    local function reasonOn()
      local capabilities = ns.adapter.Capabilities.new()
      capabilities:register("combat_log", ns.adapter.CombatLogRouter.isSupported)
      return capabilities:reasonFor("combat_log")
    end

    it("is present with the modern reader and nothing on hand", function()
      _G.C_CombatLog = { GetCurrentEventInfo = function() end }

      assert.equal("present", reasonOn())
    end)

    it("is present with only the classic global", function()
      _G.C_CombatLog = nil
      _G.CombatLogGetCurrentEventInfo = function() end

      assert.equal("present", reasonOn())
    end)

    it("is absent with neither", function()
      _G.C_CombatLog = nil

      assert.equal("absent", reasonOn())
    end)

    -- The only way a probe at login can see a closed combat log: a line already on
    -- hand whose subevent it may not read.
    it("is unreadable when the line on hand is closed", function()
      local reason
      AscentTest.withSecretRegime(function()
        ns = load()
        _G.C_CombatLog = { GetCurrentEventInfo = function()
          return 1000, AscentTest.secret("SWING_DAMAGE")
        end }
        reason = reasonOn()
      end)

      assert.equal("unreadable", reason)
    end)
  end)

  describe("start/stop", function()
    local function stubFrame()
      local frame = { registered = {} }
      function frame:RegisterEvent(event) self.registered[event] = true end
      function frame:UnregisterAllEvents() self.registered = {} end
      function frame:SetScript(_, fn) self.onEvent = fn end
      return frame
    end

    it("registers only COMBAT_LOG_EVENT_UNFILTERED and dispatches through it", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end
      -- A client with a reader and nothing on hand yet, which is the state at login.
      local line
      _G.C_CombatLog = { GetCurrentEventInfo = function() if line then return line() end end }

      router:start()
      assert.is_true(frame.registered.COMBAT_LOG_EVENT_UNFILTERED)

      -- Set up the line without invoking it directly: the point of this test is
      -- that firing the frame's own OnEvent is what triggers the read.
      line = function()
        return clock:now(), CombatLogSubevent.UNIT_DIED, false, PLAYER_GUID, "Source", 0, 0,
          BOAR_GUID, "Boar", 0, 0
      end
      frame.onEvent()

      assert.equal(1, bus:countOf(EventTopic.CREATURE_DIED))
      _G.CreateFrame = nil
    end)

    -- World of Warcraft: Forever has C_CombatLog without GetCurrentEventInfo, and no
    -- CombatLogGetCurrentEventInfo global: nothing to read, so nothing is asked for.
    it("registers nothing on a client with no reader", function()
      local built = 0
      _G.CreateFrame = function() built = built + 1 return stubFrame() end
      _G.C_CombatLog = {}

      router:start()

      assert.equal(0, built)
      assert.is_nil(router.frame)
      _G.CreateFrame = nil
    end)

    it("clears its frame on stop", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end

      router:start()
      router:stop()

      assert.is_nil(router.frame)
      _G.CreateFrame = nil
    end)
  end)

  -- Enrolment runs before the handler lookup, so a subevent with no handler, such
  -- as SPELL_ABSORBED, still names who is fighting whom.
  describe("a line that only says who is fighting whom", function()
    local CREATURE = "Creature-0-1-1-1-15636-0000000001"

    it("enrols on a subevent that has no handler at all", function()
      emit(CombatLogSubevent.SPELL_ABSORBED, CREATURE, PLAYER_GUID, "Tester")

      assert.equal(1, bus:countOf(EventTopic.ENEMY_ENGAGED))
      assert.equal("combatlog", bus:lastOn(EventTopic.ENEMY_ENGAGED).from)
    end)

    it("enrols the same way when the player is the one being shielded from", function()
      emit(CombatLogSubevent.SPELL_ABSORBED, PLAYER_GUID, CREATURE, "Withered Green Keeper")

      assert.equal("Withered Green Keeper", bus:lastOn(EventTopic.ENEMY_ENGAGED).name)
    end)

    it("enrols on a cast this character has not been hit by yet", function()
      emit(CombatLogSubevent.SPELL_CAST_START, CREATURE, PLAYER_GUID, "Tester")

      assert.equal(1, bus:countOf(EventTopic.ENEMY_ENGAGED))
      assert.equal("combatlog", bus:lastOn(EventTopic.ENEMY_ENGAGED).from)
    end)

    it("still enrols on a miss, which never moved a health bar either", function()
      emit(CombatLogSubevent.SWING_MISSED, CREATURE, PLAYER_GUID, "Tester")

      assert.equal(1, bus:countOf(EventTopic.ENEMY_ENGAGED))
    end)
  end)

  -- The subevents the router drops, counted by the name the client gives them, so a
  -- session with the evidence recorder on lists what is being thrown away.
  describe("the census of what it does not handle", function()
    local CREATURE = "Creature-0-1-1-1-15636-0000000001"
    local kinds

    before_each(function()
      kinds = {}
      router = ns.adapter.CombatLogRouter.new({
        bus = bus, clock = clock, playerState = player,
        recordEvidence = function(kind) kinds[#kinds + 1] = kind end,
      })
    end)

    it("counts an unhandled line this character is in", function()
      emit("SPELL_INTERRUPT", CREATURE, PLAYER_GUID, "Tester")

      assert.same({ "subevent.SPELL_INTERRUPT" }, kinds)
    end)

    it("says nothing about a fight between two other people", function()
      emit("SPELL_INTERRUPT", CREATURE, "Creature-0-1-1-1-15637-0000000002", "Other")

      assert.same({}, kinds)
    end)

    it("says nothing about a line it already handles", function()
      emit(CombatLogSubevent.SWING_MISSED, CREATURE, PLAYER_GUID, "Tester")

      assert.same({}, kinds)
    end)
  end)

  -- A client that hands back fields this addon may not read. Each field is compared,
  -- added up or used as a table key soon after it is read, and on that client each
  -- of those operations raises.
  describe("on a client that closes the fields of a line", function()
    local scoped, closedBus, closedRouter

    local function emitClosed(subevent, sourceGUID, destGUID, destName, ...)
      local extra = { ... }
      _G.C_CombatLog = {
        GetCurrentEventInfo = function()
          return 1000, subevent, false, sourceGUID, "Source", 0, 0, destGUID, destName, 0, 0,
            unpack(extra)
        end,
      }
      closedRouter:handleCombatLogEvent()
    end

    before_each(function()
      AscentTest.withSecretRegime(function()
        scoped = load()
        closedBus = scoped.fakes.RecordingEventBus.new()
        closedRouter = scoped.adapter.CombatLogRouter.new({
          bus = closedBus,
          clock = scoped.fakes.FakeClock.new(1000),
          playerState = scoped.fakes.FakePlayerState.new({ guid = PLAYER_GUID }),
        })
      end)
    end)

    -- An unreadable death must not become a kill nobody claimed: that number means
    -- "you killed something and were paid nothing for it", and an unreadable line
    -- is evidence of neither half.
    it("drops a death whose destination it cannot read", function()
      local CLOSED = scoped.core.CombatLogSubevent.UNIT_DIED

      assert.has_no.errors(function()
        emitClosed(CLOSED, nil, AscentTest.secret(BOAR_GUID), AscentTest.secret("Boar"))
      end)

      assert.equal(0, #closedBus.published)
    end)

    -- The first line nothing can be read from says the source closed, once, and the
    -- router stops there: nothing it feeds accumulates, not even from a later
    -- readable line.
    it("reports the first line it cannot read at all, once, and reads nothing after it", function()
      local told = 0
      AscentTest.withSecretRegime(function()
        closedRouter = scoped.adapter.CombatLogRouter.new({
          bus = closedBus,
          clock = scoped.fakes.FakeClock.new(1000),
          playerState = scoped.fakes.FakePlayerState.new({ guid = PLAYER_GUID }),
          onUnreadable = function() told = told + 1 end,
        })
      end)
      local CAST = scoped.core.CombatLogSubevent.SPELL_CAST_SUCCESS

      emitClosed(AscentTest.secret(CAST), PLAYER_GUID, BOAR_GUID, "Boar", 133, "Fireball")
      emitClosed(AscentTest.secret(CAST), PLAYER_GUID, BOAR_GUID, "Boar", 133, "Fireball")
      emitClosed(CAST, PLAYER_GUID, BOAR_GUID, "Boar", 133, "Fireball")

      assert.equal(1, told)
      assert.equal(0, #closedBus.published)
    end)

    -- A closed name or a closed spell id is a sample lost, not a source lost: the
    -- line itself could still be routed.
    it("does not call a line with only its extras closed a closed source", function()
      local told = 0
      AscentTest.withSecretRegime(function()
        closedRouter = scoped.adapter.CombatLogRouter.new({
          bus = closedBus,
          clock = scoped.fakes.FakeClock.new(1000),
          playerState = scoped.fakes.FakePlayerState.new({ guid = PLAYER_GUID }),
          onUnreadable = function() told = told + 1 end,
        })
      end)

      emitClosed(scoped.core.CombatLogSubevent.SWING_DAMAGE, PLAYER_GUID, BOAR_GUID, AscentTest.secret("Boar"), 42)

      assert.equal(0, told)
      assert.equal(1, closedBus:countOf(scoped.core.EventTopic.DAMAGE_DEALT))
    end)

    -- An unguarded closed spell id is truthy, not a number, and never type-tested,
    -- so it would ride the payload into core/ and become a key in the collector's
    -- own table.
    it("counts no ability whose identity it cannot read", function()
      local CAST = scoped.core.CombatLogSubevent.SPELL_CAST_SUCCESS

      assert.has_no.errors(function()
        emitClosed(CAST, PLAYER_GUID, BOAR_GUID, "Boar",
          AscentTest.secret(133), AscentTest.secret("Fireball"))
      end)

      assert.equal(0, closedBus:countOf(scoped.core.EventTopic.ABILITY_USED))
    end)
  end)
end)
