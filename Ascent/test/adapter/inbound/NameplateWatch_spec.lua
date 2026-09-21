-- The rule under test is two conditions and neither is enough alone: a creature is
-- in YOUR pull when it is FIGHTING and it is AIMING at you or your pet. Fighting
-- alone takes in somebody else's fight across the clearing; aiming alone takes in
-- one the player merely clicked, which must never join the pull.

describe("NameplateWatch", function()
  local ns, EventTopic, bus, watch

  local units

  local function load()
    return AscentTest.loadWith("core/port/",
      "adapter/inbound/CreatureGuid.lua", "adapter/inbound/NameplateWatch.lua",
      "test/fakes/RecordingEventBus.lua")
  end

  -- One nameplate, described the way the client would answer about it. The
  -- defaults are the ordinary case: a live hostile creature fighting the player.
  local function plate(token, guid, name, options)
    options = options or {}
    units[token] = {
      guid = guid,
      name = name,
      hostile = options.friendly ~= true,
      dead = options.dead == true,
      inCombat = options.inCombat ~= false,
      aimingAt = options.aimingAt or "player",
    }
    return { namePlateUnitToken = token }
  end

  local function showing(...)
    local plates = { ... }
    _G.C_NamePlate = { GetNamePlates = function() return plates end }
  end

  before_each(function()
    ns = load()
    EventTopic = ns.core.EventTopic
    bus = ns.fakes.RecordingEventBus.new()
    units = {}

    _G.UnitExists = function(token) return units[token] ~= nil end
    _G.UnitCanAttack = function(_, token) return units[token] ~= nil and units[token].hostile end
    _G.UnitIsDead = function(token) return units[token] ~= nil and units[token].dead end
    _G.UnitAffectingCombat = function(token) return units[token] ~= nil and units[token].inCombat end
    _G.UnitIsUnit = function(target, unit)
      local token = target:gsub("target$", "")
      local entry = units[token]
      return entry ~= nil and entry.aimingAt == unit
    end
    _G.UnitGUID = function(token) return units[token] and units[token].guid end
    _G.UnitName = function(token) return units[token] and units[token].name end

    watch = ns.adapter.NameplateWatch.new({ bus = bus })
  end)

  after_each(function()
    for _, name in ipairs({ "C_NamePlate", "UnitExists", "UnitCanAttack", "UnitIsDead",
      "UnitAffectingCombat", "UnitIsUnit", "UnitGUID", "UnitName" }) do
      _G[name] = nil
    end
  end)

  -- The whole point: three creatures aggroed by one shot, two of them still
  -- crossing the ground. The combat log has written nothing about those two.
  it("names every hostile creature already coming for the player", function()
    showing(
      plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"),
      plate("nameplate2", "Creature-0-1-1-1-15636-B", "Withered Green Keeper"),
      plate("nameplate3", "Creature-0-1-1-1-15636-C", "Withered Green Keeper"))

    assert.equal(3, watch:sweep())
    assert.equal(3, bus:countOf(EventTopic.ENEMY_ENGAGED))
    assert.equal("Withered Green Keeper", bus:lastOn(EventTopic.ENEMY_ENGAGED).name)
  end)

  -- The failure that shaped the rule. Clicking a creature makes it YOUR target,
  -- which is not this test and never was -- and it is not fighting either, so both
  -- halves say no.
  it("does not enrol a creature the player merely clicked", function()
    showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Keeper",
      { inCombat = false, aimingAt = "nobody" }))

    assert.equal(0, watch:sweep())
    assert.equal(0, bus:countOf(EventTopic.ENEMY_ENGAGED))
  end)

  -- Aiming without fighting: a creature that has the player selected and is doing
  -- nothing about it is not in the pull.
  it("does not enrol one that is aiming at the player but not fighting", function()
    showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Keeper", { inCombat = false }))

    assert.equal(0, watch:sweep())
  end)

  -- Fighting without aiming: somebody else's fight pays somebody else.
  it("does not enrol one that is fighting anyone else", function()
    showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Keeper", { aimingAt = "other" }))

    assert.equal(0, watch:sweep())
  end)

  it("counts one coming for the pet, which is the same fight", function()
    showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Keeper", { aimingAt = "pet" }))

    assert.equal(1, watch:sweep())
  end)

  it("ignores the friendly and the dead", function()
    showing(
      plate("nameplate1", "Creature-0-1-1-1-15636-A", "Quest Giver", { friendly = true }),
      plate("nameplate2", "Creature-0-1-1-1-15636-B", "Keeper", { dead = true }))

    assert.equal(0, watch:sweep())
  end)

  it("ignores a nameplate that is not a creature at all", function()
    showing(plate("nameplate1", "Player-4657-0000AAAA", "Someone"))

    assert.equal(0, watch:sweep())
  end)

  -- Nameplates switched off in the client's own options: no tokens, nobody seen,
  -- nothing raised. The pull is then whatever the combat log saw, which is exactly
  -- what it was before this file existed.
  it("sees nobody, and does not raise, where the client has no nameplates", function()
    _G.C_NamePlate = nil

    assert.is_false(ns.adapter.NameplateWatch.isSupported())
    assert.equal(0, watch:sweep())
  end)
end)
