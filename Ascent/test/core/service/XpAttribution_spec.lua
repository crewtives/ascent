-- The invariant every one of these cases is really about: the amount is
-- authoritative and the source is a claim. No hint may add experience, no hint may
-- inflate it, and nothing the addon fails to explain may be dropped.
--
-- Nothing is attributed until the window closes, so almost every test drives the
-- events and then settles past it. That is the behaviour, not a testing artefact:
-- deciding earlier is what let a channel without the quest id beat the one with it.

describe("XpAttribution", function()
  local ns, bus, registry, service
  local XpSource, XpHintKind, EventTopic, RestedReading

  local WINDOW = 0.75 -- mirrors XpAttribution.lua's DEFAULT_WINDOW
  -- KillCorrelator's own default (unrelated to XpAttribution's, and unchanged) --
  -- production wires KillCorrelator.new() with no override either. Kept as its own
  -- constant rather than reusing WINDOW: the two windows happened to be the same
  -- number before, never the same *thing*, and the "wired to the correlator" cases
  -- below specifically need a death to still count as within the hint's window --
  -- and to survive in the correlator's retention -- well past XpAttribution's own,
  -- faster window.
  local CORRELATOR_WINDOW = 1.5
  local LATER = 1000 -- comfortably past every window used in this file

  local function load()
    return AscentTest.loadWith("core/model/",
      "core/port/Port.lua", "core/port/EventBus.lua",
      "core/registry/ClassifierRegistry.lua", "core/registry/XpClassifiers.lua",
      "core/service/KillCorrelator.lua", "core/service/XpAttribution.lua",
      "test/fakes/RecordingEventBus.lua")
  end

  local function newService(options)
    options = options or {}
    options.bus = bus
    options.registry = registry
    return ns.core.XpAttribution.new(options)
  end

  local function delta(amount, at, place)
    bus:publish(EventTopic.XP_DELTA_OBSERVED, { amount = amount, at = at, place = place })
  end

  local function hint(fields)
    bus:publish(EventTopic.XP_HINT_RECEIVED, fields)
  end

  local function kill(name, amount, at, extra)
    local fields = { kind = XpHintKind.KILL_MESSAGE, creatureName = name, amount = amount, at = at }
    for key, value in pairs(extra or {}) do
      fields[key] = value
    end
    hint(fields)
  end

  local function quest(questId, amount, at)
    hint({ kind = XpHintKind.QUEST_TURNED_IN, questId = questId, amount = amount, at = at })
  end

  local function questEcho(amount, at)
    hint({ kind = XpHintKind.QUEST_MESSAGE, amount = amount, at = at })
  end

  local function anonymous(amount, at, extra)
    local fields = { kind = XpHintKind.ANONYMOUS_MESSAGE, amount = amount, at = at }
    for key, value in pairs(extra or {}) do
      fields[key] = value
    end
    hint(fields)
  end

  local function discovery(zone, amount, at)
    hint({ kind = XpHintKind.ZONE_DISCOVERED, zoneName = zone, amount = amount, at = at })
  end

  local function died(name, at, npcId, level)
    bus:publish(EventTopic.CREATURE_DIED, { name = name, at = at, npcId = npcId, level = level })
  end

  local function settleAll()
    service:settle(LATER)
  end

  local function gains()
    local found = {}
    for _, payload in ipairs(bus:payloadsFor(EventTopic.XP_ATTRIBUTED)) do
      found[#found + 1] = payload.gain
    end
    return found
  end

  local function totalBySource(source)
    local total = 0
    for _, gain in ipairs(gains()) do
      if gain.source == source then
        total = total + gain.amount
      end
    end
    return total
  end

  local function attributedTotal()
    local total = 0
    for _, gain in ipairs(gains()) do
      total = total + gain.amount
    end
    return total
  end

  before_each(function()
    ns = load()
    XpSource = ns.core.XpSource
    XpHintKind = ns.core.XpHintKind
    EventTopic = ns.core.EventTopic
    RestedReading = ns.core.RestedReading
    bus = ns.fakes.RecordingEventBus.new()
    registry = ns.core.XpClassifiers.registerAll(ns.core.ClassifierRegistry.new())
    service = newService()
  end)

  -- D43. The delta is the authoritative event and the hint can arrive up to a
  -- window and a half either side of it, so reading the place beside the hint would
  -- record a kill at a dungeon's door in whichever of the two places the
  -- announcement happened to catch.
  describe("where the experience was earned", function()
    local function placesAttributed()
      local found = {}
      for _, payload in ipairs(bus:payloadsFor(EventTopic.XP_ATTRIBUTED)) do
        found[#found + 1] = payload.place and payload.place:id() or nil
      end
      return found
    end

    local function dungeon()
      return ns.core.PlaceKey.new(ns.core.PlaceContext.DUNGEON, 389, "Ragefire Chasm")
    end

    it("keeps the delta's place when the hint arrived first", function()
      kill("Kobold Miner", 44, 10.0)
      delta(44, 10.05, dungeon())
      settleAll()

      assert.same({ "dungeon:389" }, placesAttributed())
    end)

    it("keeps the delta's place when the hint arrived afterwards", function()
      delta(44, 10.0, dungeon())
      kill("Kobold Miner", 44, 11.2)
      settleAll()

      assert.same({ "dungeon:389" }, placesAttributed())
    end)

    -- Experience nobody explained is still experience the player earned somewhere,
    -- and the place is known for it even when the source is not.
    it("carries it onto the remainder nothing claimed", function()
      delta(44, 10.0, dungeon())
      settleAll()

      assert.equal(XpSource.UNKNOWN, gains()[1].source)
      assert.same({ "dungeon:389" }, placesAttributed())
    end)

    it("splits a bounded claim without losing the place", function()
      kill("Kobold Miner", 44, 10.0)
      delta(20, 10.05, dungeon())
      settleAll()

      assert.equal(20, attributedTotal())
      assert.same({ "dungeon:389" }, placesAttributed())
    end)

    -- A publisher that says nothing about the place says nothing; inventing the
    -- reserved entry here would take that decision away from the ledger, which is
    -- the only thing that knows whether a record is even accumulating places.
    it("says nothing when the delta carried no place at all", function()
      delta(44, 10.0)
      settleAll()

      assert.same({}, placesAttributed())
    end)
  end)

  describe("matching a hint to a delta", function()
    it("attributes a kill announced just before the experience arrived", function()
      kill("Kobold Miner", 44, 10.0)
      delta(44, 10.05)
      settleAll()

      assert.equal(1, #gains())
      assert.equal(44, gains()[1].amount)
      assert.equal(XpSource.MOB_KILL, gains()[1].source)
    end)

    -- Which of the two orders the client uses is not verified for either flavour,
    -- so both have to work. This is the whole reason the window is bidirectional.
    it("attributes a kill announced just after the experience arrived", function()
      delta(44, 10.0)
      kill("Kobold Miner", 44, 10.3)
      settleAll()

      assert.equal(1, #gains())
      assert.equal(XpSource.MOB_KILL, gains()[1].source)
    end)

    it("keeps two sources in the same instant apart", function()
      quest(1234, 250, 10.0)
      kill("Kobold Miner", 44, 10.0)
      delta(294, 10.0)
      settleAll()

      assert.equal(250, totalBySource(XpSource.QUEST_TURNIN))
      assert.equal(44, totalBySource(XpSource.MOB_KILL))
      assert.equal(294, attributedTotal())
    end)

    it("attributes experience nobody explained to UNKNOWN rather than dropping it", function()
      delta(44, 10.0)
      settleAll()

      assert.equal(1, #gains())
      assert.equal(XpSource.UNKNOWN, gains()[1].source)
      assert.equal(44, gains()[1].amount)
    end)

    it("ignores a hint too far from the delta to be about it", function()
      kill("Kobold Miner", 44, 10.0)
      delta(44, 13.0)
      settleAll()

      assert.equal(44, totalBySource(XpSource.UNKNOWN))
      assert.equal(0, totalBySource(XpSource.MOB_KILL))
    end)

    it("keeps the quest identifier on the gain", function()
      quest(1234, 250, 10.0)
      delta(250, 10.0)
      settleAll()

      assert.equal(1234, gains()[1].questId)
    end)

    it("attributes a discovery", function()
      discovery("Northshire Abbey", 60, 10.0)
      delta(60, 10.0)
      settleAll()

      assert.equal(XpSource.EXPLORATION, gains()[1].source)
    end)
  end)

  describe("waiting out the window", function()
    -- Two windows, not one. One window is when the last hint that could be about
    -- this delta arrives; two is when that hint's own window has closed, so the
    -- delta it was really announcing has arrived and can be told apart from this one.
    it("decides nothing while a hint could still turn out to belong elsewhere", function()
      delta(250, 10.0)
      service:settle(10.0 + WINDOW * 2)

      assert.equal(0, #gains())
      assert.equal(1, service:diagnostics().pendingDeltas)
    end)

    it("decides once no hint can be in play any longer", function()
      delta(250, 10.0)
      service:settle(10.0 + WINDOW * 2 + 0.01)

      assert.equal(1, #gains())
      assert.equal(0, service:diagnostics().pendingDeltas)
    end)

    -- Regression. The delta used to settle the moment some hint filled it, which
    -- handed it to whichever channel spoke first. The system echo of a turn-in
    -- carries no quest id and the event that does can be milliseconds behind it, and
    -- a delta already attributed cannot take the better answer.
    it("lets the channel carrying the quest id win even when it speaks second", function()
      delta(250, 10.0)
      questEcho(250, 10.05)
      quest(1234, 250, 10.1)
      settleAll()

      assert.equal(1, #gains())
      assert.equal(250, gains()[1].amount)
      assert.equal(XpSource.QUEST_TURNIN, gains()[1].source)
      assert.equal(1234, gains()[1].questId)
    end)
  end)

  describe("consumption bounded by the delta", function()
    -- Quest experience is announced on two channels, verified. With min against the
    -- delta the second copy adds nothing and needs no special case.
    it("records a gain announced twice only once", function()
      quest(1234, 250, 10.0)
      questEcho(250, 10.02)
      delta(250, 10.05)
      settleAll()

      assert.equal(250, attributedTotal())
      assert.equal(250, totalBySource(XpSource.QUEST_TURNIN))
    end)

    it("keeps the identifier when the channel carrying it is the second to arrive", function()
      questEcho(250, 10.0)
      quest(1234, 250, 10.02)
      delta(250, 10.05)
      settleAll()

      assert.equal(250, attributedTotal())
      assert.equal(1234, gains()[1].questId)
    end)

    it("never attributes more than actually arrived", function()
      kill("Kobold Miner", 300, 10.0)
      delta(250, 10.0)
      settleAll()

      assert.equal(250, attributedTotal())
    end)

    it("sends what a hint did not cover to UNKNOWN", function()
      kill("Kobold Miner", 100, 10.0)
      delta(250, 10.0)
      settleAll()

      assert.equal(100, totalBySource(XpSource.MOB_KILL))
      assert.equal(150, totalBySource(XpSource.UNKNOWN))
      assert.equal(250, attributedTotal())
    end)

    -- Regression. The losing copy of a twice-announced turn-in used to keep its full
    -- amount and stay eligible, and it outranks the kill channel -- so the next
    -- creature's experience was booked to the quest, the kill hint expired unused,
    -- and the creature's death was reported as having paid nothing.
    it("does not let the second copy of a turn-in claim the next kill", function()
      quest(1234, 500, 10.0)
      questEcho(500, 10.02)
      delta(500, 10.05)
      kill("Kobold Miner", 44, 10.8)
      delta(44, 10.85)
      settleAll()

      assert.equal(500, totalBySource(XpSource.QUEST_TURNIN))
      assert.equal(44, totalBySource(XpSource.MOB_KILL))
      assert.equal(1, service:diagnostics().duplicateAnnouncements)
    end)

    -- Regression. Retiring a copy marked it spent, and spent was then read as "this
    -- one already paid" -- so the next real turn-in of the same reward was retired
    -- against the previous one's echo and its experience fell to UNKNOWN. Two quests
    -- worth the same amount a second apart is ordinary play.
    it("does not collapse two real turn-ins that happen to pay the same", function()
      quest(111, 250, 10.0)
      questEcho(250, 10.02)
      delta(250, 10.05)
      quest(222, 250, 10.6)
      questEcho(250, 10.62)
      delta(250, 10.65)
      settleAll()

      assert.equal(500, totalBySource(XpSource.QUEST_TURNIN))
      assert.equal(0, totalBySource(XpSource.UNKNOWN))

      local ids = {}
      for _, gain in ipairs(gains()) do
        ids[#ids + 1] = gain.questId
      end
      assert.same({ 111, 222 }, ids)
    end)

    it("still attributes a turn-in when only the system echo arrives", function()
      questEcho(250, 10.0)
      delta(250, 10.05)
      settleAll()

      assert.equal(250, totalBySource(XpSource.QUEST_TURNIN))
    end)

    -- Two creatures worth the same experience a second apart are two gains, not one
    -- announcement heard twice. The channel is what distinguishes them.
    it("does not collapse two kills of the same value into one", function()
      kill("Kobold Miner", 44, 10.0)
      kill("Kobold Miner", 44, 10.4)
      delta(44, 10.0)
      delta(44, 10.4)
      settleAll()

      assert.equal(88, totalBySource(XpSource.MOB_KILL))
      assert.equal(0, service:diagnostics().duplicateAnnouncements)
    end)
  end)

  describe("matching by amount", function()
    -- Regression, and the reason the design says the window matches by amount and
    -- not only by time. An unexplained delta stays open for its whole window; with
    -- purely time-based matching it took the front of the next kill's announcement,
    -- splitting one creature's death into two gains -- two kills in the aggregate,
    -- and half the experience per creature.
    it("does not let an older, unrelated delta take a hint that fits a later one", function()
      delta(20, 10.0)
      died("Kobold Miner", 10.5, 5644, 6)
      kill("Kobold Miner", 44, 10.5)
      delta(44, 10.55)
      settleAll()

      assert.equal(2, #gains())
      assert.equal(20, totalBySource(XpSource.UNKNOWN))
      assert.equal(44, totalBySource(XpSource.MOB_KILL))
    end)

    it("produces exactly one gain per announcement", function()
      delta(20, 10.0)
      kill("Kobold Miner", 44, 10.5)
      delta(44, 10.55)
      settleAll()

      local kills = 0
      for _, gain in ipairs(gains()) do
        if gain.source == XpSource.MOB_KILL then
          kills = kills + 1
        end
      end
      assert.equal(1, kills)
    end)

    -- Regression. An unexplained delta used to be attributed at one window, before
    -- the delta belonging to a hint in its window had necessarily arrived -- so the
    -- reservation check had nothing to see and the kill's announcement was eaten
    -- anyway, leaving the creature credited with 20 experience instead of 44.
    it("waits long enough to see the delta a hint is reserved for", function()
      delta(20, 10.0)
      kill("Kobold Miner", 44, 11.4)
      service:settle(11.6)          -- one window past the first delta, and no more
      delta(44, 11.7)
      settleAll()

      assert.equal(20, totalBySource(XpSource.UNKNOWN))
      assert.equal(44, totalBySource(XpSource.MOB_KILL))
    end)

    -- Regression. Channel priority used to outrank proximity, so when two gains from
    -- different channels happened to pay the same amount their experience was
    -- swapped -- and with a third gain in the chain the kill vanished from the level
    -- entirely, counted neither as productive nor as unproductive.
    it("gives a delta the nearest hint, not the one from the higher-ranked channel", function()
      kill("Kobold Miner", 250, 10.0)
      delta(250, 10.02)
      quest(409, 250, 11.3)
      delta(250, 11.32)
      quest(236, 250, 11.8)
      delta(250, 11.82)
      settleAll()

      assert.equal(250, totalBySource(XpSource.MOB_KILL))
      assert.equal(500, totalBySource(XpSource.QUEST_TURNIN))
      assert.equal(0, totalBySource(XpSource.UNKNOWN))
    end)

    it("prefers the hint that accounts for exactly what is left", function()
      quest(1234, 250, 10.0)
      kill("Kobold Miner", 44, 10.0)
      delta(44, 10.0)
      settleAll()

      assert.equal(44, totalBySource(XpSource.MOB_KILL))
      assert.equal(0, totalBySource(XpSource.QUEST_TURNIN))
    end)
  end)

  describe("the anonymous line", function()
    it("falls to UNKNOWN on its own, because it never names a source", function()
      anonymous(250, 10.0)
      delta(250, 10.0)
      settleAll()

      assert.equal(250, totalBySource(XpSource.UNKNOWN))
      assert.equal(250, attributedTotal())
    end)

    it("lets the system message claim the gain when it comes first", function()
      questEcho(250, 10.0)
      anonymous(250, 10.05)
      delta(250, 10.1)
      settleAll()

      assert.equal(250, totalBySource(XpSource.QUEST_TURNIN))
      assert.equal(250, attributedTotal())
    end)

    it("lets it claim the gain when it comes second", function()
      anonymous(250, 10.0)
      questEcho(250, 10.05)
      delta(250, 10.1)
      settleAll()

      assert.equal(250, totalBySource(XpSource.QUEST_TURNIN))
      assert.equal(250, attributedTotal())
    end)

    -- The case the precedence rule exists for: the anonymous line and the experience
    -- arrive together and the message that names the source lags.
    it("does not take the delta before the message that names the source arrives", function()
      anonymous(250, 10.0)
      delta(250, 10.05)
      questEcho(250, 10.3)
      settleAll()

      assert.equal(250, totalBySource(XpSource.QUEST_TURNIN))
      assert.equal(0, totalBySource(XpSource.UNKNOWN))
    end)

    -- Being claimed is recorded rather than merely tolerated: it is how the addon
    -- can answer whether discoveries emit this line too, which no public source says.
    it("records whether something claimed it", function()
      anonymous(250, 10.0)
      questEcho(250, 10.05)
      anonymous(60, 11.0)
      delta(250, 10.1)
      settleAll()

      assert.equal(1, service:diagnostics().anonymousClaimed)
      assert.equal(1, service:diagnostics().anonymousUnclaimed)
    end)
  end)

  describe("the rested portion", function()
    local function restedGain(reading, fields)
      bus = ns.fakes.RecordingEventBus.new()
      service = newService({ restedReading = reading })
      kill("Kobold Miner", 100, 10.0, fields)
      delta(100, 10.0)
      settleAll()
      return gains()[1]
    end

    it("reads the parenthetical as the bonus, which is the standing assumption", function()
      local gain = restedGain(RestedReading.BONUS, { restedRaw = 40 })

      assert.equal(40, gain.restedBonus)
      assert.equal(60, gain:baseAmount())
    end)

    -- Spike 0.4 decides which half the parenthetical names. What must not change
    -- either way is that the two halves add back up to what the player received.
    it("reads it as the base when the spike says so, and still adds up", function()
      local gain = restedGain(RestedReading.BASE, { restedRaw = 40 })

      assert.equal(60, gain.restedBonus)
      assert.equal(40, gain:baseAmount())
    end)

    it("holds the identity under both readings", function()
      for _, reading in ipairs({ RestedReading.BONUS, RestedReading.BASE }) do
        local gain = restedGain(reading, { restedRaw = 40 })
        assert.equal(gain.amount, gain:baseAmount() + gain.restedBonus)
      end
    end)

    it("is zero when the kill carried no parenthetical at all", function()
      local gain = restedGain(RestedReading.BONUS, {})

      assert.equal(0, gain.restedBonus)
      assert.equal(100, gain:baseAmount())
    end)

    it("never exceeds what was received", function()
      local gain = restedGain(RestedReading.BONUS, { restedRaw = 4000 })

      assert.equal(100, gain.restedBonus)
      assert.equal(0, gain:baseAmount())
    end)

    -- Only kills spend the reserve. A quest or a discovery carrying rested figures
    -- is a parse gone wrong, and the domain refuses it rather than recording it.
    it("is never carried by a quest or a discovery", function()
      quest(1234, 250, 10.0)
      delta(250, 10.0)
      discovery("Northshire Abbey", 60, 11.0)
      delta(60, 11.0)
      settleAll()

      assert.equal(2, #gains())
      for _, gain in ipairs(gains()) do
        assert.equal(0, gain.restedBonus)
      end
    end)
  end)

  describe("the rested bonus read from the reserve", function()
    -- The client's figure is twice the server's reserve, so a kill drops it by twice
    -- the base experience: halving the drop reads the bonus without the message.
    it("is half the drop in the reserve", function()
      assert.equal(40, ns.core.XpAttribution.restedFromReserve(1000, 920, 100))
    end)

    -- The reserve is denominated in doubled points, so an odd drop is a partial
    -- point of bonus. It has to come back whole: the model refuses a fractional
    -- bonus, and the error would be raised while attributing, losing the gain.
    it("rounds an odd drop down to a whole point", function()
      assert.equal(39, ns.core.XpAttribution.restedFromReserve(1000, 921, 100))
    end)

    it("is bounded by what was actually received", function()
      assert.equal(100, ns.core.XpAttribution.restedFromReserve(1000, 0, 100))
    end)

    it("is zero when the reserve did not move, and nothing without both readings", function()
      assert.equal(0, ns.core.XpAttribution.restedFromReserve(1000, 1000, 100))
      assert.is_nil(ns.core.XpAttribution.restedFromReserve(nil, 920, 100))
      assert.is_nil(ns.core.XpAttribution.restedFromReserve(1000, nil, 100))
    end)

    it("agrees with the parsed value and reports no disagreement", function()
      kill("Kobold Miner", 100, 10.0, { restedRaw = 40, restedBefore = 1000, restedAfter = 920 })
      delta(100, 10.0)
      settleAll()

      assert.equal(40, gains()[1].restedBonus)
      assert.equal(0, service:diagnostics().restedDisagreements)
    end)

    -- While the spike is open, a systematic disagreement is the evidence that the
    -- parenthetical is being read as the wrong half.
    it("counts a disagreement without overruling the parsed value", function()
      kill("Kobold Miner", 100, 10.0, { restedRaw = 40, restedBefore = 1000, restedAfter = 900 })
      delta(100, 10.0)
      settleAll()

      assert.equal(40, gains()[1].restedBonus)
      assert.equal(1, service:diagnostics().restedDisagreements)
    end)

    it("stands in when the message carried no parenthetical", function()
      kill("Kobold Miner", 100, 10.0, { restedBefore = 1000, restedAfter = 920 })
      delta(100, 10.0)
      settleAll()

      assert.equal(40, gains()[1].restedBonus)
    end)

    -- A sentence that announced no rested state needs no stand-in: the client prints
    -- the parenthetical whenever a bonus applies, so its absence is a zero. Standing
    -- in anyway read the reserve, which is sampled off the chat line and therefore
    -- describes the PREVIOUS kill.
    it("does not stand in for a line that announced no rested state at all", function()
      kill("Kobold Miner", 100, 10.0,
        { restedAnnounced = false, restedBefore = 1000, restedAfter = 920 })
      delta(100, 10.0)
      settleAll()

      assert.equal(0, gains()[1].restedBonus)
      assert.equal(100, gains()[1]:baseAmount())
    end)

    -- The case the fallback exists for, and the reason the flag is three-valued: a
    -- fatigue line, or a locale printing a percentage, announces the reserve moved
    -- and names no figure.
    it("still stands in for a line that announced rest without naming a figure", function()
      kill("Kobold Miner", 100, 10.0,
        { restedAnnounced = true, restedBefore = 1000, restedAfter = 920 })
      delta(100, 10.0)
      settleAll()

      assert.equal(40, gains()[1].restedBonus)
    end)

    -- The sequence as the 2026-09-21 file recorded it, twice: a rested kill, then a
    -- plain one whose reserve snapshot still shows the first one's drain. The bonus
    -- belongs to the first kill and to that kill only.
    it("charges a rested kill once, not again to the plain kill behind it", function()
      kill("Crazed Dragonhawk", 46, 10.0,
        { restedAnnounced = true, restedRaw = 7, restedBefore = 14, restedAfter = 14 })
      delta(46, 10.0)
      kill("Springpaw Stalker", 39, 20.0,
        { restedAnnounced = false, restedBefore = 14, restedAfter = 0 })
      delta(39, 20.0)
      settleAll()

      assert.equal(2, #gains())
      assert.equal(7, gains()[1].restedBonus)
      assert.equal(0, gains()[2].restedBonus)
    end)
  end)

  describe("group and raid modifiers", function()
    it("records the group bonus without changing what was received", function()
      kill("Kobold Miner", 44, 10.0, { groupBonus = 12 })
      delta(44, 10.0)
      settleAll()

      assert.equal(44, gains()[1].amount)
      assert.equal(12, gains()[1].groupBonus)
    end)

    it("records the raid penalty without changing what was received", function()
      kill("Kobold Miner", 30, 10.0, { raidPenalty = 14 })
      delta(30, 10.0)
      settleAll()

      assert.equal(30, gains()[1].amount)
      assert.equal(14, gains()[1].raidPenalty)
    end)

    it("divides them with the amount when only part of the hint is consumed", function()
      kill("Kobold Miner", 100, 10.0, { groupBonus = 10 })
      delta(50, 10.0)
      settleAll()

      assert.equal(50, gains()[1].amount)
      assert.equal(5, gains()[1].groupBonus)
    end)

    -- The anonymous family. Its templates print the same parenthetical beside an
    -- amount and NO creature name, which is what the client sends when it reports a
    -- group kill without naming what died. The channel resolves no source, so for a
    -- long time the annotation it carried was simply dropped -- and the task that
    -- claimed modifiers reach the level record only ever tested the named channel.

    it("adopts the parenthetical of an anonymous line onto the kill it duplicates", function()
      kill("Kobold Miner", 120, 10.0)
      anonymous(120, 10.05, { groupBonus = 18 })
      delta(120, 10.1)
      settleAll()

      assert.equal(1, #gains())
      assert.equal(XpSource.MOB_KILL, gains()[1].source)
      assert.equal(120, gains()[1].amount)
      assert.equal(18, gains()[1].groupBonus)
    end)

    it("adopts it whichever of the two announcements arrived first", function()
      anonymous(120, 10.0, { raidPenalty = 24 })
      kill("Kobold Miner", 120, 10.05)
      delta(120, 10.1)
      settleAll()

      assert.equal(1, #gains())
      assert.equal(24, gains()[1].raidPenalty)
    end)

    -- The spec forbids a group bonus and a raid penalty on one gain, so the named
    -- channel's own reading wins outright instead of being merged with this one.
    it("leaves a kill that already read a modifier of its own alone", function()
      kill("Kobold Miner", 120, 10.0, { raidPenalty = 14 })
      anonymous(120, 10.05, { groupBonus = 18 })
      delta(120, 10.1)
      settleAll()

      assert.equal(14, gains()[1].raidPenalty)
      assert.equal(0, gains()[1].groupBonus)
    end)

    -- A group bonus is a share of creature experience; a quest turn-in has none.
    -- Adopting onto one would invent a bonus the client never announced.
    it("never adopts onto a quest turn-in", function()
      quest(7, 250, 10.0)
      anonymous(250, 10.05, { groupBonus = 30 })
      delta(250, 10.1)
      settleAll()

      assert.equal(XpSource.QUEST_TURNIN, gains()[1].source)
      assert.equal(0, gains()[1].groupBonus)
    end)

    -- The case the whole thing exists for: the client announced the gain ONLY on
    -- the anonymous line, so its parenthetical is the only record that the player
    -- was in a group for it. The source stays unknown, which is honest.
    it("keeps the annotation when the anonymous line is the only announcement", function()
      anonymous(120, 10.0, { groupBonus = 18 })
      delta(120, 10.05)
      settleAll()

      assert.equal(1, #gains())
      assert.equal(XpSource.UNKNOWN, gains()[1].source)
      assert.equal(120, gains()[1].amount)
      assert.equal(18, gains()[1].groupBonus)
    end)

    it("spends that annotation once, not on every unexplained delta after it", function()
      anonymous(120, 10.0, { groupBonus = 18 })
      delta(120, 10.02)
      delta(120, 10.04)
      settleAll()

      assert.equal(2, #gains())
      assert.equal(18, gains()[1].groupBonus)
      assert.equal(0, gains()[2].groupBonus)
    end)

    -- Exact amount only. A remainder that is not the figure the line announced
    -- belongs to a different event, and spreading one parenthetical across two of
    -- them would invent a number the client never printed.
    it("does not stretch the annotation onto a remainder of a different size", function()
      anonymous(120, 10.0, { groupBonus = 18 })
      delta(90, 10.05)
      settleAll()

      assert.equal(0, gains()[1].groupBonus)
    end)
  end)

  describe("ordering", function()
    -- The consumer splits gains across level boundaries, so a gain landing on the
    -- wrong side of a level-up would corrupt two levels at once.
    it("emits gains in the order the experience arrived", function()
      kill("Kobold Miner", 44, 10.0)
      delta(44, 10.0)
      quest(1234, 250, 10.5)
      delta(250, 10.5)
      delta(7, 11.0)
      settleAll()

      assert.same(
        { XpSource.MOB_KILL, XpSource.QUEST_TURNIN, XpSource.UNKNOWN },
        { gains()[1].source, gains()[2].source, gains()[3].source })
    end)
  end)

  describe("diagnostics", function()
    it("counts a delta nothing claimed, and only that", function()
      delta(44, 10.0)
      settleAll()

      assert.equal(1, service:diagnostics().unmatchedDeltas)
      assert.equal(0, service:diagnostics().unclaimedHints)
    end)

    it("counts a hint nothing consumed, and only that", function()
      kill("Kobold Miner", 44, 10.0)
      settleAll()

      assert.equal(1, service:diagnostics().unclaimedHints)
      assert.equal(0, service:diagnostics().unmatchedDeltas)
    end)

    it("counts neither when hint and delta found each other", function()
      kill("Kobold Miner", 44, 10.0)
      delta(44, 10.0)
      settleAll()

      assert.equal(0, service:diagnostics().unmatchedDeltas)
      assert.equal(0, service:diagnostics().unclaimedHints)
    end)

    it("counts a channel no classifier recognises", function()
      hint({ kind = "chat_msg_loot", amount = 10, at = 10.0 })

      assert.equal(1, service:diagnostics().unclassifiedHints)
    end)
  end)

  -- D21: the bar reads this to show what the client already confirmed while the
  -- source is still settling, instead of showing a stale total for up to two
  -- windows.
  describe("pendingAmount", function()
    it("is zero with nothing observed", function()
      assert.equal(0, service:pendingAmount())
    end)

    it("is the delta's amount before its window has settled", function()
      delta(44, 10.0)

      assert.equal(44, service:pendingAmount())
    end)

    it("sums more than one delta still waiting to settle", function()
      delta(44, 10.0)
      delta(12, 10.2)

      assert.equal(56, service:pendingAmount())
    end)

    it("drops back to zero once the delta has settled", function()
      delta(44, 10.0)
      settleAll()

      assert.equal(0, service:pendingAmount())
    end)
  end)

  describe("wired to the correlator", function()
    local correlator

    before_each(function()
      bus = ns.fakes.RecordingEventBus.new()
      correlator = ns.core.KillCorrelator.new({ window = CORRELATOR_WINDOW })
      service = newService({ correlator = correlator })
    end)

    it("resolves the creature that paid for the gain", function()
      died("Kobold Miner", 10.0, 5644, 6)
      kill("Kobold Miner", 44, 10.05)
      delta(44, 10.1)
      settleAll()

      local creature = gains()[1].creature
      assert.equal(5644, creature.npcId)
      assert.equal(6, creature.level)
    end)

    it("resolves a creature whose death reached the combat log late", function()
      kill("Kobold Miner", 44, 10.0)
      delta(44, 10.0)
      died("Kobold Miner", 10.3, 5644, 6)
      settleAll()

      assert.equal(5644, gains()[1].creature.npcId)
    end)

    -- The join enriches; it never decides whether experience is recorded.
    it("records the gain anyway when no death ever matches", function()
      kill("Kobold Miner", 44, 10.0)
      delta(44, 10.0)
      settleAll()

      assert.equal(44, totalBySource(XpSource.MOB_KILL))
      assert.is_false(gains()[1].creature:hasKnownType())
      assert.equal(1, service:diagnostics().uncorrelatedKills)
    end)

    it("announces a death nothing ever paid for", function()
      died("Young Wolf", 10.0, 299, 3)
      settleAll()

      local unrewarded = bus:payloadsFor(EventTopic.KILL_UNREWARDED)
      assert.equal(1, #unrewarded)
      assert.equal(299, unrewarded[1].creature.npcId)
    end)

    it("says nothing about a death a gain accounted for", function()
      died("Kobold Miner", 10.0, 5644, 6)
      kill("Kobold Miner", 44, 10.05)
      delta(44, 10.1)
      settleAll()

      assert.equal(0, bus:countOf(EventTopic.KILL_UNREWARDED))
    end)

    -- Regression. A death used to be evicted one window after it happened, but the
    -- hint that claims it resolves only when its delta settles, which is later. The
    -- panel was telling a player that a kill worth 44 experience had paid nothing.
    it("keeps a death until the gain that pays for it has been attributed", function()
      died("Kobold Miner", 9.2, 5644, 6)
      kill("Kobold Miner", 44, 10.0)
      delta(100, 10.4) -- 44 from the kill, the rest unexplained
      died("Riverpaw Runt", 10.9, 476, 8)
      settleAll()

      assert.equal(5644, gains()[1].creature.npcId)
      local unrewarded = bus:payloadsFor(EventTopic.KILL_UNREWARDED)
      assert.equal(1, #unrewarded)
      assert.equal(476, unrewarded[1].creature.npcId)
    end)

    -- Regression. A kill the addon heard announced but never saw paid still killed
    -- the creature: reporting it as unproductive would be believing the silence over
    -- the message that said it paid.
    it("does not call a kill unproductive when its announcement went unclaimed", function()
      died("Kobold Miner", 10.0, 5644, 6)
      kill("Kobold Miner", 44, 10.0)
      settleAll()

      assert.equal(0, bus:countOf(EventTopic.KILL_UNREWARDED))
      assert.equal(1, service:diagnostics().unclaimedHints)
    end)

    -- Regression, and a defensive one. A lookup that found no death CLAIMED no
    -- death, so remembering it as the answer is how one kill gets counted twice:
    -- once as a paying kill with an unknown creature, and again as an unproductive
    -- one when its death is later evicted unclaimed. Settling two windows out means
    -- the combat log should always have spoken first, so this is the belt behind
    -- the braces -- driven here by handing the correlator a death whose instant is
    -- inside the hint's window but which reaches the addon after the gain is out.
    --
    -- THE TIMES ARE DERIVED, and they have to be. This case lives in a gap between
    -- two thresholds that are both multiples of the window: a delta is committed
    -- once it is two windows old, and the hint that explains it survives for three
    -- -- and it is the RETIRING hint that finally claims the late death (see
    -- XpAttribution:retireHint). So the gain must go out while the hint is still
    -- alive, which means settling between those two. Written as a literal, that
    -- instant silently fell out of the gap the moment the window was retuned, and
    -- the case stopped testing what it says it tests while still failing loudly.
    it("does not count a kill twice when its death reaches the addon late", function()
      local ANNOUNCED = 10.0
      -- Past the commit at 2 windows, inside the hint's retention at 3.
      local GAIN_OUT = ANNOUNCED + WINDOW * 2.5
      -- Late enough to miss the gain, near enough that the correlator still owns it.
      local DEATH_AT = ANNOUNCED + CORRELATOR_WINDOW * 0.9

      kill("Kobold Miner", 44, ANNOUNCED)
      delta(44, ANNOUNCED)
      service:settle(GAIN_OUT)

      assert.equal(1, #gains())
      assert.is_false(gains()[1].creature:hasKnownType())

      died("Kobold Miner", DEATH_AT, 5644, 6)
      settleAll()

      assert.equal(1, #gains(), "the gain was emitted a second time")
      assert.equal(0, bus:countOf(EventTopic.KILL_UNREWARDED))
      assert.equal(1, correlator:diagnostics().matched)
    end)

    it("claims one death per kill, not one per gain", function()
      died("Kobold Miner", 10.0, 5644, 6)
      died("Kobold Miner", 10.05, 5644, 9)
      kill("Kobold Miner", 44, 10.1)
      delta(44, 10.1)
      settleAll()

      assert.equal(1, #gains())
      assert.equal(6, gains()[1].creature.level)
      assert.equal(1, correlator:diagnostics().matched)
    end)
  end)

  describe("debug logging", function()
    -- A logger is optional and, absent, changes nothing: every test above already
    -- exercises that path. These only prove logging happens at the right moments
    -- when a logger IS given, not the exact wording of any message.
    local function fakeLogger()
      local messages = {}
      return { debug = function(_, msg) table.insert(messages, msg) end }, messages
    end

    local function anyMessageContains(messages, needle)
      for _, msg in ipairs(messages) do
        if msg:find(needle, 1, true) then
          return true
        end
      end
      return false
    end

    it("never errors and logs nothing when no logger is given", function()
      assert.has_no.errors(function()
        quest(1234, 500, 10.0)
        questEcho(500, 10.02)
        delta(500, 10.05)
        kill("Kobold Miner", 44, 10.8)
        delta(44, 10.85)
        settleAll()
      end)
    end)

    it("logs a delta arriving", function()
      local logger, messages = fakeLogger()
      bus = ns.fakes.RecordingEventBus.new()
      service = newService({ logger = logger })

      delta(44, 10.0)

      assert.is_true(anyMessageContains(messages, "delta arrived"))
    end)

    it("logs a hint being classified, and separately a hint nothing classifies", function()
      local logger, messages = fakeLogger()
      bus = ns.fakes.RecordingEventBus.new()
      service = newService({ logger = logger })

      kill("Kobold Miner", 44, 10.0)
      hint({ kind = "chat_msg_loot", amount = 10, at = 10.0 })

      assert.is_true(anyMessageContains(messages, "hint classified"))
      assert.is_true(anyMessageContains(messages, "hint unclassified"))
    end)

    it("logs a duplicate hint being retired", function()
      local logger, messages = fakeLogger()
      bus = ns.fakes.RecordingEventBus.new()
      service = newService({ logger = logger })

      quest(1234, 500, 10.0)
      questEcho(500, 10.02)
      delta(500, 10.05)

      assert.is_true(anyMessageContains(messages, "duplicate retired"))
    end)

    it("logs what a settling delta was split into, and its UNKNOWN remainder", function()
      local logger, messages = fakeLogger()
      bus = ns.fakes.RecordingEventBus.new()
      service = newService({ logger = logger })

      kill("Kobold Miner", 100, 10.0)
      delta(250, 10.0)
      settleAll()

      assert.is_true(anyMessageContains(messages, "settled"))
      assert.is_true(anyMessageContains(messages, "closed unclaimed"))
    end)

    it("logs a hint expiring unclaimed", function()
      local logger, messages = fakeLogger()
      bus = ns.fakes.RecordingEventBus.new()
      service = newService({ logger = logger })

      kill("Kobold Miner", 44, 10.0)
      settleAll()

      assert.is_true(anyMessageContains(messages, "expired unclaimed"))
    end)

    it("logs a disagreement between the parsed and reserve-measured rested bonus", function()
      local logger, messages = fakeLogger()
      bus = ns.fakes.RecordingEventBus.new()
      service = newService({ logger = logger })

      kill("Kobold Miner", 100, 10.0, { restedRaw = 40, restedBefore = 1000, restedAfter = 900 })
      delta(100, 10.0)
      settleAll()

      assert.is_true(anyMessageContains(messages, "rested bonus disagreement"))
    end)
  end)

  describe("construction", function()
    it("insists on a bus and a registry", function()
      assert.has_error(function() return ns.core.XpAttribution.new({ registry = registry }) end)
      assert.has_error(function() return ns.core.XpAttribution.new({ bus = bus }) end)
      assert.has_error(function()
        return ns.core.XpAttribution.new({ bus = {}, registry = registry })
      end)
    end)

    it("refuses a delta that is not a whole, non-negative amount", function()
      assert.has_error(function() delta(-1, 10.0) end)
      assert.has_error(function() delta(10.5, 10.0) end)
      assert.has_error(function() delta(44, nil) end)
    end)
  end)
end)
