-- The router's own contract is the payload shapes XpAttribution and LevelTracker
-- already expect (read straight off their source, not guessed): XP_DELTA_OBSERVED
-- is {amount, at, place, sharedBy}, an XP_HINT_RECEIVED carries `kind` plus whatever its
-- channel can say, CREATURE_DIED is out of scope entirely (CombatLogRouter's job).
--
-- Group and raid kill messages ARE exercised here now. They used to be left out
-- because the router compiled no pattern for them -- which turned out to be only
-- half the story: it matched them against the plain kill template by prefix, so
-- the amount was right and the modifier vanished. These tests exist to keep that
-- from coming back.

local FIRSTPERSON = "%s dies, you gain %d experience."
local FIRSTPERSON_GROUP = "%s dies, you gain %d experience. (+%d group bonus)"
local FIRSTPERSON_RAID = "%s dies, you gain %d experience. (-%d raid penalty)"
local FIRSTPERSON_UNNAMED = "You gain %d experience."
local EXHAUSTION1 = "%s dies, you gain %d experience. (%s exp %s bonus)"
local EXHAUSTION1_GROUP = "%s dies, you gain %d experience. (%s exp %s bonus, +%d group bonus)"
local EXHAUSTION4 = "%s dies, you gain %d experience. (%s exp %s penalty)"
local ZONE_EXPLORED = "Discovered %s: %d experience gained"
local QUEST_REWARD_ECHO = "Experience gained: %d."

local function stubFrame()
  local frame = { registered = {} }
  function frame:RegisterEvent(event) self.registered[event] = true end
  function frame:UnregisterAllEvents() self.registered = {} end
  function frame:SetScript(_, fn) self.onEvent = fn end
  return frame
end

describe("WowEventRouter", function()
  local ns, WowEvent, EventTopic, XpHintKind
  local bus, clock, player, router

  local function load()
    return AscentTest.loadWith("core/model/", "core/port/",
      "adapter/inbound/GlobalStringPattern.lua", "adapter/inbound/WowEventRouter.lua",
      "test/fakes/FakeClock.lua", "test/fakes/FakePlayerState.lua", "test/fakes/RecordingEventBus.lua")
  end

  before_each(function()
    _G.COMBATLOG_XPGAIN_FIRSTPERSON = FIRSTPERSON
    _G.COMBATLOG_XPGAIN_FIRSTPERSON_GROUP = FIRSTPERSON_GROUP
    _G.COMBATLOG_XPGAIN_FIRSTPERSON_RAID = FIRSTPERSON_RAID
    _G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = FIRSTPERSON_UNNAMED
    _G.COMBATLOG_XPGAIN_EXHAUSTION1 = EXHAUSTION1
    _G.COMBATLOG_XPGAIN_EXHAUSTION1_GROUP = EXHAUSTION1_GROUP
    _G.COMBATLOG_XPGAIN_EXHAUSTION4 = EXHAUSTION4
    _G.ERR_ZONE_EXPLORED_XP = ZONE_EXPLORED
    _G.ERR_QUEST_REWARD_EXP_I = QUEST_REWARD_ECHO

    ns = load()
    WowEvent = ns.core.WowEvent
    EventTopic = ns.core.EventTopic
    XpHintKind = ns.core.XpHintKind

    clock = ns.fakes.FakeClock.new(1000)
    player = ns.fakes.FakePlayerState.new({ level = 10, xp = 100, xpMax = 1000, restedXp = 0 })
    bus = ns.fakes.RecordingEventBus.new()
    router = ns.adapter.WowEventRouter.new({ bus = bus, clock = clock, playerState = player })
  end)

  after_each(function()
    _G.COMBATLOG_XPGAIN_FIRSTPERSON = nil
    _G.COMBATLOG_XPGAIN_FIRSTPERSON_GROUP = nil
    _G.COMBATLOG_XPGAIN_FIRSTPERSON_RAID = nil
    _G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = nil
    _G.COMBATLOG_XPGAIN_EXHAUSTION1 = nil
    _G.COMBATLOG_XPGAIN_EXHAUSTION1_GROUP = nil
    _G.COMBATLOG_XPGAIN_EXHAUSTION4 = nil
    _G.ERR_ZONE_EXPLORED_XP = nil
    _G.ERR_QUEST_REWARD_EXP_I = nil
    _G.CreateFrame = nil
    _G.GetQuestID = nil
    _G.GetRewardXP = nil
    _G.GetTitleText = nil
  end)

  describe("session lifecycle", function()
    it("publishes SESSION_STARTED with the current snapshot on entering the world", function()
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      assert.same({ level = 10, xp = 100, xpMax = 1000 }, bus:lastOn(EventTopic.SESSION_STARTED))
    end)

    it("re-anchors the XP snapshot on entering the world, including mid-session", function()
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      -- A loading screen mid-session: the character is not where it was at login.
      player:set("xp", 400)
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:set("xp", 450)
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      -- 50, measured from the second anchor -- not 350, which would be measured
      -- from the first and silently count the loading screen as a gain.
      assert.equal(50, bus:lastOn(EventTopic.XP_DELTA_OBSERVED).amount)
    end)

    it("publishes SESSION_ENDED on logout", function()
      router:dispatch(WowEvent.PLAYER_LOGOUT)

      assert.equal(1, bus:countOf(EventTopic.SESSION_ENDED))
    end)
  end)

  describe("experience delta", function()
    it("reports a same-level gain as the plain difference", function()
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:set("xp", 150)
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      local payload = bus:lastOn(EventTopic.XP_DELTA_OBSERVED)
      assert.equal(50, payload.amount)
      assert.equal(clock:now(), payload.at)
    end)

    -- D43: the place belongs to the instant the experience was granted. The
    -- announcement that explains it may arrive a window and a half either side,
    -- by which time the character can be somewhere else entirely.
    it("stamps the delta with where the character is at that instant", function()
      player:set("place", { context = ns.core.PlaceContext.DUNGEON, areaId = 389, name = "Ragefire Chasm" })
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:set("xp", 150)
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      assert.equal("dungeon:389", bus:lastOn(EventTopic.XP_DELTA_OBSERVED).place:id())
    end)

    -- D81, and the same argument as the place above: the size is read at the one
    -- instant the server is known to have decided the split, because the addon
    -- settles a delta two windows after it arrives and the party can be left in
    -- between. The port already answers one for a character playing alone, so
    -- nothing here has to remember the client's zero.
    it("stamps the delta with how many shared it at that instant", function()
      player:set("sharedBy", 5)
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:set("xp", 150)
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      assert.equal(5, bus:lastOn(EventTopic.XP_DELTA_OBSERVED).sharedBy)
    end)

    it("says one, not nothing, for a character earning it alone", function()
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:set("xp", 150)
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      assert.equal(1, bus:lastOn(EventTopic.XP_DELTA_OBSERVED).sharedBy)
    end)

    it("stamps the reserved entry when the client cannot say where that was", function()
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:set("xp", 150)
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      assert.equal("unknown:?", bus:lastOn(EventTopic.XP_DELTA_OBSERVED).place:id())
    end)

    it("folds a single level-up into one delta, using the OLD level's requirement", function()
      player:set("level", 5):set("xpMax", 400):set("xp", 380)
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:gain(50) -- (400 - 380) to close level 5, + 30 into level 6

      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      assert.equal(50, bus:lastOn(EventTopic.XP_DELTA_OBSERVED).amount)
    end)

    it("also computes the delta from PLAYER_LEVEL_UP, not only PLAYER_XP_UPDATE", function()
      player:set("level", 5):set("xpMax", 400):set("xp", 380)
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:gain(50)
      router:dispatch(WowEvent.PLAYER_LEVEL_UP)

      assert.equal(50, bus:lastOn(EventTopic.XP_DELTA_OBSERVED).amount)
    end)

    it("does not publish a zero or negative delta", function()
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      router:dispatch(WowEvent.PLAYER_XP_UPDATE) -- nothing changed

      assert.equal(0, bus:countOf(EventTopic.XP_DELTA_OBSERVED))
    end)

    it("reports nothing for the very first update, with no anchor yet, but still anchors from it", function()
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)
      assert.equal(0, bus:countOf(EventTopic.XP_DELTA_OBSERVED))

      player:set("xp", 130)
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      assert.equal(30, bus:lastOn(EventTopic.XP_DELTA_OBSERVED).amount)
    end)
  end)

  describe("rest state", function()
    it("republishes the current rest state on UPDATE_EXHAUSTION", function()
      player:set("restedXp", 300):set("isResting", true)

      router:dispatch(WowEvent.UPDATE_EXHAUSTION)

      assert.same({ restedXp = 300, isResting = true }, bus:lastOn(EventTopic.REST_CHANGED))
    end)

    it("republishes it on PLAYER_UPDATE_RESTING too", function()
      player:set("isResting", true)

      router:dispatch(WowEvent.PLAYER_UPDATE_RESTING)

      assert.is_true(bus:lastOn(EventTopic.REST_CHANGED).isResting)
    end)
  end)

  it("republishes whether experience gain is on or off", function()
    player:set("isXpDisabled", true)
    router:dispatch(WowEvent.DISABLE_XP_GAIN)
    assert.is_true(bus:lastOn(EventTopic.XP_STATE_CHANGED).isXpDisabled)

    player:set("isXpDisabled", false)
    router:dispatch(WowEvent.ENABLE_XP_GAIN)
    assert.is_false(bus:lastOn(EventTopic.XP_STATE_CHANGED).isXpDisabled)
  end)

  it("routes combat start and end", function()
    router:dispatch(WowEvent.PLAYER_REGEN_DISABLED)
    router:dispatch(WowEvent.PLAYER_REGEN_ENABLED)

    assert.equal(1, bus:countOf(EventTopic.COMBAT_STARTED))
    assert.equal(1, bus:countOf(EventTopic.COMBAT_ENDED))
  end)

  it("routes the player's own death and revival", function()
    router:dispatch(WowEvent.PLAYER_DEAD)
    router:dispatch(WowEvent.PLAYER_ALIVE)
    router:dispatch(WowEvent.PLAYER_UNGHOST)

    assert.equal(1, bus:countOf(EventTopic.PLAYER_DIED))
    assert.equal(2, bus:countOf(EventTopic.PLAYER_REVIVED))
  end)

  describe("quests", function()
    it("turns a quest turn-in into a completed event and an XP hint, with no parsing", function()
      router:dispatch(WowEvent.QUEST_TURNED_IN, 1234, 250, 500)

      assert.same({ questId = 1234, xpReward = 250 }, bus:lastOn(EventTopic.QUEST_COMPLETED))
      assert.same(
        { kind = XpHintKind.QUEST_TURNED_IN, questId = 1234, amount = 250, at = clock:now() },
        bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      )
    end)

    it("still hints a quest worth zero experience, distinct from no hint at all", function()
      router:dispatch(WowEvent.QUEST_TURNED_IN, 1234, 0, 0)

      assert.equal(0, bus:lastOn(EventTopic.XP_HINT_RECEIVED).amount)
    end)

    it("signals the quest log changed on accept, removal or log update", function()
      router:dispatch(WowEvent.QUEST_ACCEPTED)
      router:dispatch(WowEvent.QUEST_REMOVED)
      router:dispatch(WowEvent.QUEST_LOG_UPDATE)

      assert.equal(3, bus:countOf(EventTopic.QUEST_LOG_CHANGED))
    end)
  end)

  describe("quest reward seen from the open dialogue (D15 level 2)", function()
    it("publishes the reward read from QUEST_DETAIL", function()
      _G.GetQuestID = function() return 1234 end
      _G.GetRewardXP = function() return 250 end

      router:dispatch(WowEvent.QUEST_DETAIL)

      assert.same({ questId = 1234, reward = 250 }, bus:lastOn(EventTopic.QUEST_REWARD_SEEN))
    end)

    it("publishes the reward read from QUEST_COMPLETE too", function()
      _G.GetQuestID = function() return 5678 end
      _G.GetRewardXP = function() return 80 end

      router:dispatch(WowEvent.QUEST_COMPLETE)

      assert.same({ questId = 5678, reward = 80 }, bus:lastOn(EventTopic.QUEST_REWARD_SEEN))
    end)

    it("publishes the title the dialogue is showing alongside the reward", function()
      _G.GetQuestID = function() return 1234 end
      _G.GetRewardXP = function() return 250 end
      _G.GetTitleText = function() return "Wanted: Hogger" end

      router:dispatch(WowEvent.QUEST_DETAIL)

      assert.same({ questId = 1234, reward = 250, title = "Wanted: Hogger" },
        bus:lastOn(EventTopic.QUEST_REWARD_SEEN))
    end)

    it("tolerates GetTitleText not existing, and an empty title, as no title at all", function()
      _G.GetQuestID = function() return 1234 end
      _G.GetRewardXP = function() return 250 end
      _G.GetTitleText = function() return "" end

      router:dispatch(WowEvent.QUEST_DETAIL)
      assert.is_nil(bus:lastOn(EventTopic.QUEST_REWARD_SEEN).title)

      _G.GetTitleText = nil
      router:dispatch(WowEvent.QUEST_DETAIL)
      assert.is_nil(bus:lastOn(EventTopic.QUEST_REWARD_SEEN).title)
    end)

    it("publishes nothing when GetQuestID reports no quest open (0)", function()
      _G.GetQuestID = function() return 0 end
      _G.GetRewardXP = function() return 250 end

      router:dispatch(WowEvent.QUEST_DETAIL)

      assert.equal(0, bus:countOf(EventTopic.QUEST_REWARD_SEEN))
    end)

    it("publishes nothing when GetQuestID returns nil", function()
      _G.GetQuestID = function() return nil end
      _G.GetRewardXP = function() return 250 end

      router:dispatch(WowEvent.QUEST_DETAIL)

      assert.equal(0, bus:countOf(EventTopic.QUEST_REWARD_SEEN))
    end)

    it("publishes nothing when GetRewardXP does not return a non-negative integer", function()
      _G.GetQuestID = function() return 1234 end
      _G.GetRewardXP = function() return -5 end

      router:dispatch(WowEvent.QUEST_DETAIL)

      assert.equal(0, bus:countOf(EventTopic.QUEST_REWARD_SEEN))
    end)

    it("tolerates GetQuestID/GetRewardXP not existing as globals at all", function()
      _G.GetQuestID = nil
      _G.GetRewardXP = nil

      assert.has_no.errors(function()
        local tolerant = ns.adapter.WowEventRouter.new({ bus = bus, clock = clock, playerState = player })
        tolerant:dispatch(WowEvent.QUEST_DETAIL)
        tolerant:dispatch(WowEvent.QUEST_COMPLETE)
      end)
      assert.equal(0, bus:countOf(EventTopic.QUEST_REWARD_SEEN))
    end)
  end)

  describe("chat: CHAT_MSG_COMBAT_XP_GAIN", function()
    it("reads a named kill's creature and amount", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 12 experience.")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(XpHintKind.KILL_MESSAGE, hint.kind)
      assert.equal("Boar", hint.creatureName)
      assert.equal(12, hint.amount)
    end)

    it("reads the anonymous line as amount only, with no creature name", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "You gain 12 experience.")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(XpHintKind.ANONYMOUS_MESSAGE, hint.kind)
      assert.equal(12, hint.amount)
      assert.is_nil(hint.creatureName)
    end)

    -- The two readings are still carried, and the shape below is still what the
    -- router publishes. What the 2026-09-17 session changed is what they MEAN: the
    -- client prints the line before applying the gain, so this window is shifted one
    -- kill and cannot be the source of the bonus. It is the cross-check input, and
    -- naming it after the kill it sits beside is the mistake that hid the defect for
    -- a whole change. See "reads the rested bonus off the parenthetical" below.
    it("carries the rested reserve either side of the sampling point (cross-check input)", function()
      player:set("restedXp", 300)
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 12 experience.")

      local first = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.is_nil(first.restedBefore) -- nothing sampled before the first kill
      assert.equal(300, first.restedAfter)

      player:set("restedXp", 280) -- the kill spent some of the reserve
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Wolf dies, you gain 12 experience.")

      local second = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(300, second.restedBefore) -- the previous sampling point, not the first kill's true after
      assert.equal(280, second.restedAfter)
    end)

    -- The regression test for the defect the 2026-09-17 session exposed. Both kills
    -- and both figures are transcribed from that file; only the reserve is rounded
    -- for legibility. Before the parenthetical was read, the recorded bonus was
    -- whatever the reserve diff said -- and the reserve diff is one kill behind, so
    -- Vishas's 522-point kill was filed with the Torturer's 101-point bonus. Over
    -- that session it under-reported the rested bonus by 1104 experience, 16.9%,
    -- and the panel showed the wrong figure with the suite fully green.
    it("reads the rested bonus off the parenthetical, not off the reserve behind it", function()
      player:set("restedXp", 45370)
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN,
        "Scarlet Torturer dies, you gain 202 experience. (+101 exp Rested bonus)")

      local first = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(202, first.amount)
      assert.equal(101, first.restedRaw)

      -- The client applies the gain only now: this is what makes the window lie.
      player:set("restedXp", 45168)
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN,
        "Interrogator Vishas dies, you gain 522 experience. (+261 exp Rested bonus)")

      local second = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(261, second.restedRaw)
      -- ...while the reserve this line bounds still describes the Torturer: a drop
      -- of 202, half of which is the 101 the previous line announced.
      assert.equal(101, (second.restedBefore - second.restedAfter) / 2)
    end)

    it("carries the group bonus and the rested figure off the same line", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN,
        "Scarlet Scout dies, you gain 78 experience. (+39 exp Rested bonus, +9 group bonus)")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(78, hint.amount)
      assert.equal(39, hint.restedRaw)
      assert.equal(9, hint.groupBonus)
    end)

    -- Fatigue is a deduction, and the reserve was never spent. Publishing a figure
    -- here would credit a rested bonus for experience the player was docked.
    it("publishes no rested figure for a fatigue line", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN,
        "Boar dies, you gain 120 experience. (-10 exp fatigue penalty)")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(120, hint.amount)
      assert.is_nil(hint.restedRaw)
    end)

    it("does not publish a hint for a line that matches neither pattern", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Something unrelated happened.")

      assert.equal(0, bus:countOf(EventTopic.XP_HINT_RECEIVED))
    end)

    -- But it does say so, verbatim and on the bus. That line is the only thing that
    -- can answer what this client prints for a case the family does not cover, and
    -- sending it only to the debug log put it in the one place it could not be read
    -- back from -- while the flight recorder, whose whole purpose is keeping the
    -- client's own sentences, never saw it.
    it("publishes a line that matched no template, with the sentence intact", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Something unrelated happened.")

      local unmatched = bus:lastOn(EventTopic.XP_LINE_UNMATCHED)
      assert.equal("Something unrelated happened.", unmatched.raw)
      assert.equal(1, bus:countOf(EventTopic.XP_LINE_UNMATCHED))
    end)

    it("says nothing on that topic for a line it did recognise", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 12 experience.")

      assert.equal(1, bus:countOf(EventTopic.XP_HINT_RECEIVED))
      assert.equal(0, bus:countOf(EventTopic.XP_LINE_UNMATCHED))
    end)

    it("ignores a non-string payload rather than erroring", function()
      assert.has_no.errors(function()
        router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, nil)
      end)
      assert.equal(0, bus:countOf(EventTopic.XP_HINT_RECEIVED))
    end)
  end)

  describe("chat: CHAT_MSG_SYSTEM", function()
    it("reads zone discovery as a hint with the zone name", function()
      router:dispatch(WowEvent.CHAT_MSG_SYSTEM, "Discovered Westfall: 50 experience gained")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(XpHintKind.ZONE_DISCOVERED, hint.kind)
      assert.equal("Westfall", hint.zoneName)
      assert.equal(50, hint.amount)
    end)

    it("reads the quest reward echo as amount only", function()
      router:dispatch(WowEvent.CHAT_MSG_SYSTEM, "Experience gained: 100.")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(XpHintKind.QUEST_MESSAGE, hint.kind)
      assert.equal(100, hint.amount)
    end)

    it("does not publish a hint for an unrelated system message", function()
      router:dispatch(WowEvent.CHAT_MSG_SYSTEM, "You are now afk.")

      assert.equal(0, bus:countOf(EventTopic.XP_HINT_RECEIVED))
    end)
  end)

  it("is a no-op for a WowEvent it does not route", function()
    router:dispatch(WowEvent.GROUP_ROSTER_UPDATE)

    assert.same({}, bus:topicsInOrder())
  end)

  describe("a GlobalString the client does not provide", function()
    it("degrades that one channel instead of erroring at construction", function()
      _G.COMBATLOG_XPGAIN_FIRSTPERSON = nil

      local degraded
      assert.has_no.errors(function()
        degraded = ns.adapter.WowEventRouter.new({ bus = bus, clock = clock, playerState = player })
      end)

      assert.has_no.errors(function()
        degraded:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 12 experience.")
      end)
      assert.equal(0, bus:countOf(EventTopic.XP_HINT_RECEIVED))

      -- The other channel, whose GlobalString is still present, is unaffected.
      degraded:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "You gain 12 experience.")
      assert.equal(1, bus:countOf(EventTopic.XP_HINT_RECEIVED))
    end)
  end)

  describe("start/stop", function()
    it("registers a frame for the events it routes and dispatches through it", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end

      router:start()

      assert.is_true(frame.registered[WowEvent.PLAYER_ENTERING_WORLD])
      assert.is_true(frame.registered[WowEvent.CHAT_MSG_COMBAT_XP_GAIN])
      assert.is_function(frame.onEvent)

      frame.onEvent(frame, WowEvent.PLAYER_LOGOUT)
      assert.equal(1, bus:countOf(EventTopic.SESSION_ENDED))
    end)

    it("does not create a second frame on a repeated start", function()
      local created = 0
      local frame = stubFrame()
      _G.CreateFrame = function() created = created + 1; return frame end

      router:start()
      router:start()

      assert.equal(1, created)
    end)

    it("clears its frame on stop", function()
      local frame = stubFrame()
      _G.CreateFrame = function() return frame end

      router:start()
      router:stop()

      assert.is_nil(router.frame)
    end)
  end)

  -- An optional diagnostic, added after the two chat-XP templates -- never
  -- verified against a real client (D5's Open Questions) -- turned out not to
  -- match a real kill line. Without a logger, none of this changes anything: the
  -- router works exactly as it did before this was added.
  describe("diagnostics (optional logger)", function()
    local function fakeLogger()
      local messages = {}
      return { debug = function(_, message) messages[#messages + 1] = message end }, messages
    end

    it("does not require a logger at all", function()
      assert.has_no.errors(function()
        ns.adapter.WowEventRouter.new({ bus = bus, clock = clock, playerState = player })
      end)
    end)

    it("reports which chat-XP patterns compiled at construction", function()
      local logger, messages = fakeLogger()

      ns.adapter.WowEventRouter.new({ bus = bus, clock = clock, playerState = player, logger = logger })

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("FIRSTPERSON': compiled", 1, true))
      assert.is_not_nil(joined:find("xp family:", 1, true))
    end)

    it("reports a missing GlobalString as missing, not as silently compiled", function()
      _G.COMBATLOG_XPGAIN_FIRSTPERSON = nil
      local logger, messages = fakeLogger()

      ns.adapter.WowEventRouter.new({ bus = bus, clock = clock, playerState = player, logger = logger })

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("'FIRSTPERSON': GlobalString missing", 1, true))
    end)

    it("logs a solo kill line that matched neither pattern, verbatim", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.WowEventRouter.new({
        bus = bus, clock = clock, playerState = player, logger = logger,
      })

      diagnosed:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "something the two known patterns do not match")

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("matched no template", 1, true))
      assert.is_not_nil(joined:find("something the two known patterns do not match", 1, true))
    end)

    it("logs a successful match too, so a mismatch and a downstream failure are not confused", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.WowEventRouter.new({
        bus = bus, clock = clock, playerState = player, logger = logger,
      })

      diagnosed:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 12 experience.")

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("hint (kill_message) at", 1, true))
      -- The template that matched rides along: it is what the group-bonus
      -- question is answered with (design D45).
      assert.is_not_nil(joined:find("template=FIRSTPERSON", 1, true))
      assert.is_not_nil(joined:find("Boar", 1, true))
      -- Spike 0.4 needs the raw text too: real play showed a rested-bonus kill
      -- matching this branch on its prefix alone, with the trailing parenthetical
      -- unparsed and, before this, unlogged entirely.
      assert.is_not_nil(joined:find("raw=", 1, true))
      assert.is_not_nil(joined:find("Boar dies, you gain 12 experience.", 1, true))
    end)

    -- A player reported exploration XP landing half in EXPLORATION and half in
    -- UNKNOWN with nothing to diagnose it by: this channel had no debug line at
    -- all before now, unlike the kill message above.
    it("logs a zone discovery hint the same timestamped way as a kill", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.WowEventRouter.new({
        bus = bus, clock = clock, playerState = player, logger = logger,
      })

      diagnosed:dispatch(WowEvent.CHAT_MSG_SYSTEM, "Discovered Westfall: 50 experience gained")

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("hint (zone discovery) at", 1, true))
      assert.is_not_nil(joined:find("Westfall", 1, true))
    end)

    -- Spike 0.2 needs a timestamp on the quest hint too, to determine the order
    -- between it and the XP delta -- the same open question already partly
    -- answered for kills.
    it("logs a quest turn-in hint timestamped the same way as a kill", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.WowEventRouter.new({
        bus = bus, clock = clock, playerState = player, logger = logger,
      })

      diagnosed:dispatch(WowEvent.QUEST_TURNED_IN, 1234, 250, 500)

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("hint (quest turn-in) at", 1, true))
      assert.is_not_nil(joined:find("1234", 1, true))
    end)

    it("logs the quest turn-in's system-channel echo timestamped too", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.WowEventRouter.new({
        bus = bus, clock = clock, playerState = player, logger = logger,
      })

      diagnosed:dispatch(WowEvent.CHAT_MSG_SYSTEM, "Experience gained: 250.")

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("hint (quest echo) at", 1, true))
    end)

    it("logs a quest reward seen from the dialogue view timestamped too", function()
      _G.GetQuestID = function() return 1234 end
      _G.GetRewardXP = function() return 250 end
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.WowEventRouter.new({
        bus = bus, clock = clock, playerState = player, logger = logger,
      })

      diagnosed:dispatch(WowEvent.QUEST_DETAIL)

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("quest reward seen at", 1, true))
      assert.is_not_nil(joined:find("1234", 1, true))
    end)

    it("logs the anonymous line timestamped too", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.WowEventRouter.new({
        bus = bus, clock = clock, playerState = player, logger = logger,
      })

      diagnosed:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "You gain 12 experience.")

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("hint (anonymous_message) at", 1, true))
    end)

    -- A rested-bonus kill whose text still shares `firstPerson`'s prefix matches
    -- that branch (unanchored matching), which already samples the reserve --
    -- covered by the "logs a successful match too" test above, updated to check
    -- for it. This test is for a line that shares nothing with any compiled
    -- template at all: the reserve still has to be sampled here too, in case the
    -- real EXHAUSTION wording diverges from the very first word.
    it("samples the rested reserve alongside a fully unmatched line", function()
      local logger, messages = fakeLogger()
      local diagnosed = ns.adapter.WowEventRouter.new({
        bus = bus, clock = clock, playerState = player, logger = logger,
      })

      diagnosed:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN,
        "You have been granted 44 experience for your valor.")

      local joined = table.concat(messages, "\n")
      assert.is_not_nil(joined:find("matched no template at", 1, true))
      assert.is_not_nil(joined:find("restedBefore=", 1, true))
      assert.is_not_nil(joined:find("restedAfter=", 1, true))
    end)
  end)

  -- The defect this change exists to fix, kept from coming back.
  describe("kill modifiers", function()
    it("records the group bonus of a kill in a group", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience. (+18 group bonus)")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(120, hint.amount)
      assert.equal("Boar", hint.creatureName)
      assert.equal(18, hint.groupBonus)
      assert.is_nil(hint.raidPenalty)
    end)

    it("records the raid penalty of a kill in a raid", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience. (-42 raid penalty)")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(120, hint.amount)
      assert.equal(42, hint.raidPenalty)
      assert.is_nil(hint.groupBonus)
    end)

    -- The amount is the experience actually credited; the modifier is an
    -- annotation on it and never changes it (design D41).
    it("keeps the amount the same whether or not there is a modifier", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience.")
      local plain = bus:lastOn(EventTopic.XP_HINT_RECEIVED).amount

      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience. (+18 group bonus)")
      local grouped = bus:lastOn(EventTopic.XP_HINT_RECEIVED)

      assert.equal(plain, grouped.amount)
      assert.equal(120, grouped.amount)
    end)

    -- The regression itself: before anchoring, this line matched the plain kill
    -- template on its prefix and arrived with no modifier at all.
    it("does not swallow a modified line into the plain template", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience. (+18 group bonus)")

      assert.is_not_nil(bus:lastOn(EventTopic.XP_HINT_RECEIVED).groupBonus)
    end)

    it("still hints a plain kill with no modifier at all", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience.")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.is_nil(hint.groupBonus)
      assert.is_nil(hint.raidPenalty)
    end)

    -- The first recorded session could not say whether a group line had a
    -- parenthetical at all: the file held only the parse, so the parser was the
    -- sole witness to its own work. These two fields are what let the raw line
    -- be re-read by eye afterwards, and the decision checked against it.
    it("carries the template it matched and the client's own line to the recorder", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience. (+18 group bonus)")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal("FIRSTPERSON_GROUP", hint.template)
      assert.equal("Boar dies, you gain 120 experience. (+18 group bonus)", hint.raw)
    end)

    it("carries them for a plain kill too, so a missing modifier is checkable", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience.")

      local hint = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal("FIRSTPERSON", hint.template)
      assert.equal("Boar dies, you gain 120 experience.", hint.raw)
    end)

    it("counts a hit per template, which is what answers the open question", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience.")
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience. (+18 group bonus)")
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 90 experience. (+12 group bonus)")

      local hits = router:templateHits()
      assert.equal(1, hits.FIRSTPERSON)
      assert.equal(2, hits.FIRSTPERSON_GROUP)
      assert.is_nil(hits.FIRSTPERSON_RAID)
    end)
  end)
end)
