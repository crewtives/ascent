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

  -- Every test above hands the token over on the frame, and the real client does
  -- not. That is why eight passing tests sat on top of a file that had never
  -- enrolled anybody: the fake was answering a question the client refuses.
  describe("where the token comes from", function()
    local frames

    local function eventDriven()
      frames = {}
      _G.CreateFrame = function()
        local frame = { events = {} }
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:UnregisterAllEvents() self.events = {} end
        function frame:SetScript(_, fn) self.onEvent = fn end
        frames[#frames + 1] = frame
        return frame
      end
      return ns.adapter.NameplateWatch.new({ bus = bus }):start()
    end

    after_each(function() _G.CreateFrame = nil end)

    -- The session of 2026-09-22, reproduced: plates on screen, every one of them
    -- without the field this used to read. Before the event path this was the
    -- whole story -- 168 seen, 168 rejected, nobody enrolled, ever.
    it("finds nobody when the client's frames carry no token", function()
      plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper")
      _G.C_NamePlate = { GetNamePlates = function() return { {}, {}, {} } end }

      assert.equal(0, watch:sweep())
    end)

    it("uses the token the client hands over with the nameplate event", function()
      local live = eventDriven()
      plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper")
      _G.C_NamePlate = { GetNamePlates = function() return { {} } end } -- still no token

      frames[1].onEvent(frames[1], "NAME_PLATE_UNIT_ADDED", "nameplate1")

      assert.equal(1, live:sweep())
      assert.equal("Withered Green Keeper", bus:lastOn(EventTopic.ENEMY_ENGAGED).name)
      assert.equal("nameplate", bus:lastOn(EventTopic.ENEMY_ENGAGED).from)
    end)

    it("forgets a token once the client takes its nameplate away", function()
      local live = eventDriven()
      plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper")
      _G.C_NamePlate = { GetNamePlates = function() return {} end }

      frames[1].onEvent(frames[1], "NAME_PLATE_UNIT_ADDED", "nameplate1")
      assert.equal(1, live:sweep())

      frames[1].onEvent(frames[1], "NAME_PLATE_UNIT_REMOVED", "nameplate1")
      assert.equal(0, live:sweep())
    end)
  end)

  -- Keyed on aggro, the rule answers "elsewhere" to every creature in a party
  -- pull, because they are all aiming at the tank. Experience credit has nothing
  -- to do with who is being hit.
  describe("a creature held by somebody else in the group", function()
    before_each(function()
      _G.IsInGroup = function() return true end
      _G.IsInRaid = function() return false end
      _G.GetNumGroupMembers = function() return 3 end
    end)

    after_each(function()
      for _, name in ipairs({ "IsInGroup", "IsInRaid", "GetNumGroupMembers" }) do _G[name] = nil end
    end)

    it("counts one the tank is holding", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper",
        { aimingAt = "party1" }))

      assert.equal(1, watch:sweep())
    end)

    it("counts one aiming at a group member's pet", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper",
        { aimingAt = "party2pet" }))

      assert.equal(1, watch:sweep())
    end)

    -- The objection the narrow rule was built for survives: somebody else's fight
    -- across the clearing is still not this pull.
    it("still leaves out a creature fighting nobody in the group", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper",
        { aimingAt = "party9" }))

      assert.equal(0, watch:sweep())
    end)
  end)

  -- One creature produced 45 announcements in the session of 2026-09-22, four a
  -- second for as long as it stayed on screen. Nothing broke, because the pull
  -- record deduplicates -- and a design that works only because somebody
  -- downstream is cleaning up after it is one edit away from not working.
  describe("saying it once", function()
    it("announces a creature once however many sweeps can still see it", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))

      for _ = 1, 8 do watch:sweep() end

      assert.equal(1, bus:countOf(EventTopic.ENEMY_ENGAGED))
    end)

    it("still reports it as found, so the sweep's own answer does not change", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))

      assert.equal(1, watch:sweep())
      assert.equal(1, watch:sweep())
    end)

    -- An EDGE, bounded by what this adapter can see for itself. It used to be
    -- bounded by the pull's generation, which is a domain concept an adapter
    -- looking at nameplates has no business holding a copy of -- and the pull
    -- already decides whether an engagement is news to it.
    it("announces it again after it stops qualifying and starts again", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))
      watch:sweep()

      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper",
        { inCombat = false, aimingAt = "nobody" }))
      watch:sweep()

      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))
      watch:sweep()

      assert.equal(2, bus:countOf(EventTopic.ENEMY_ENGAGED))
    end)

    it("forgets a token the client took away, so the next tenant is not mistaken for it", function()
      local frames = {}
      _G.CreateFrame = function()
        local frame = { events = {} }
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:UnregisterAllEvents() self.events = {} end
        function frame:SetScript(_, fn) self.onEvent = fn end
        frames[#frames + 1] = frame
        return frame
      end
      local live = ns.adapter.NameplateWatch.new({ bus = bus }):start()

      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))
      live:sweep()

      frames[1].onEvent(frames[1], "NAME_PLATE_UNIT_REMOVED", "nameplate1")
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-B", "Starving Ghostclaw"))
      live:sweep()

      assert.equal(2, bus:countOf(EventTopic.ENEMY_ENGAGED))
      assert.equal("Starving Ghostclaw", bus:lastOn(EventTopic.ENEMY_ENGAGED).name)
      _G.CreateFrame = nil
    end)

    it("tells two creatures of one name apart", function()
      showing(
        plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"),
        plate("nameplate2", "Creature-0-1-1-1-15636-B", "Withered Green Keeper"))

      watch:sweep()
      watch:sweep()

      assert.equal(2, bus:countOf(EventTopic.ENEMY_ENGAGED))
    end)
  end)

  -- Being on its threat list is true from the moment it came for you and stays
  -- true whoever it is swinging at. "Aiming at you" is one frame's photograph,
  -- and over the same stretch of play on 2026-09-22 it matched five times against
  -- threat's twenty-five.
  describe("a creature that has the player on its threat list", function()
    after_each(function() _G.UnitThreatSituation = nil end)

    it("counts one that is fighting somebody else entirely", function()
      _G.UnitThreatSituation = function() return 1 end
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper",
        { aimingAt = "somebodyelse" }))

      assert.equal(1, watch:sweep())
    end)

    -- The order of the checks, pinned. Threat sat BELOW the combat flag for one
    -- session and the file measured exactly what that costs: 62 readings with the
    -- player on a creature's threat list, and only 2 of them ever reached the
    -- threat check, because `idle` threw out 102 plates first.
    it("counts one on its threat list even when the combat flag says otherwise", function()
      _G.UnitThreatSituation = function() return 2 end
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper",
        { inCombat = false, aimingAt = "nobody" }))

      assert.equal(1, watch:sweep())
    end)

    -- And the objection the narrow rule was built for, answered by the new
    -- criterion rather than in spite of it: clicking a creature does not put you
    -- on its threat list.
    it("still ignores one the player merely clicked", function()
      _G.UnitThreatSituation = function() return nil end
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Keeper",
        { inCombat = false, aimingAt = "nobody" }))

      assert.equal(0, watch:sweep())
    end)

    it("leaves out one whose list the player is not on", function()
      _G.UnitThreatSituation = function() return nil end
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper",
        { aimingAt = "somebodyelse" }))

      assert.equal(0, watch:sweep())
    end)

    -- The target rule stays underneath rather than being deleted: this API
    -- belongs to a later client than the two supported here, and the day it is
    -- missing the old rule is what carries the fight.
    it("still falls back to the target when the client cannot be asked", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))

      assert.equal(1, watch:sweep())
    end)

    it("does not enrol somebody else's fight just because threat is unavailable", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper",
        { aimingAt = "somebodyelse" }))

      assert.equal(0, watch:sweep())
    end)
  end)

  -- Verified present on 2026-09-22 and verified useless as an enrolment test in
  -- the same reading: all forty creatures came back unclaimed, including the ones
  -- grazing in a field. It excludes, and that is all it does.
  describe("a creature somebody else has claimed", function()
    it("leaves out one that cannot pay this player", function()
      _G.UnitIsTapDenied = function() return true end
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))

      assert.equal(0, watch:sweep())
      _G.UnitIsTapDenied = nil
    end)

    it("keeps one that is still unclaimed", function()
      _G.UnitIsTapDenied = function() return false end
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))

      assert.equal(1, watch:sweep())
      _G.UnitIsTapDenied = nil
    end)

    it("does not raise where the client has no such question", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))

      assert.equal(1, watch:sweep())
    end)
  end)

  -- The sweep runs four times a second and its tally is already a summary, so a
  -- sample per sweep is the instrument drowning the evidence -- 105 of 108
  -- samples on 2026-09-22, every one identical.
  describe("what the sweep writes down", function()
    local kinds

    before_each(function()
      kinds = {}
      watch = ns.adapter.NameplateWatch.new({
        bus = bus,
        recordEvidence = function(kind) kinds[#kinds + 1] = kind end,
      })
    end)

    it("counts every sweep but keeps a sample only when the tally changes", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))

      for _ = 1, 5 do watch:sweep() end

      local sweeps, mixes = 0, 0
      for _, kind in ipairs(kinds) do
        if kind == "nameplateSweep" then sweeps = sweeps + 1 end
        if kind == "nameplateMix" then mixes = mixes + 1 end
      end
      assert.equal(5, sweeps)
      -- Two, not one: the first sweep announces the creature and the second finds
      -- it already announced, which is a different tally and worth seeing once.
      -- Sweeps three to five say the same thing as two and are only counted.
      assert.equal(2, mixes)
    end)

    -- The question the rule cannot ask yet. Written down and never consulted:
    -- "aiming at you" is one frame's photograph, "am I on its threat list" is the
    -- thing itself, and whether these clients can answer it is for a file to say.
    it("writes down whether the client can be asked about threat, without asking it", function()
      local tallies = {}
      watch = ns.adapter.NameplateWatch.new({
        bus = bus,
        recordEvidence = function(kind, fields)
          if kind == "nameplateMix" then tallies[#tallies + 1] = fields end
        end,
      })
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))

      watch:sweep()
      assert.equal(1, tallies[1].threatNoApi)

      _G.UnitThreatSituation = function() return 3 end
      watch:sweep()
      assert.equal(1, tallies[2].threatOn)

      _G.UnitThreatSituation = function() return nil end
      watch:sweep()
      assert.equal(1, tallies[3].threatNone)

      -- Recorded, never acted on: the verdict is the same either way.
      assert.equal(1, tallies[3].enrolled)
      _G.UnitThreatSituation = nil
    end)

    it("keeps a new sample when what it sees actually changes", function()
      showing(plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"))
      watch:sweep()
      showing(
        plate("nameplate1", "Creature-0-1-1-1-15636-A", "Withered Green Keeper"),
        plate("nameplate2", "Creature-0-1-1-1-15636-B", "Withered Green Keeper"))
      watch:sweep()

      local mixes = 0
      for _, kind in ipairs(kinds) do
        if kind == "nameplateMix" then mixes = mixes + 1 end
      end
      assert.equal(2, mixes)
    end)
  end)
end)
