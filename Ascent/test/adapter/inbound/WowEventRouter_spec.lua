-- The router's contract is the payload shapes XpAttribution and LevelTracker expect:
-- XP_DELTA_OBSERVED is {amount, at, place, sharedBy}, an XP_HINT_RECEIVED carries
-- `kind` plus whatever its channel can say. CREATURE_DIED is CombatLogRouter's job.
-- Group and raid kill lines matched against the plain kill template by prefix would
-- keep the amount and lose the modifier.

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
    return AscentTest.loadWith("core/model/", "core/port/", "adapter/compat/Readable.lua",
      "adapter/compat/Capabilities.lua",
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

    -- The place belongs to the instant the experience was granted: the announcement
    -- that explains it may arrive a window and a half either side, by which time the
    -- character can be somewhere else entirely.
    it("stamps the delta with where the character is at that instant", function()
      player:set("place", { context = ns.core.PlaceContext.DUNGEON, areaId = 389, name = "Ragefire Chasm" })
      router:dispatch(WowEvent.PLAYER_ENTERING_WORLD)

      player:set("xp", 150)
      router:dispatch(WowEvent.PLAYER_XP_UPDATE)

      assert.equal("dungeon:389", bus:lastOn(EventTopic.XP_DELTA_OBSERVED).place:id())
    end)

    -- The group size is read at the instant the server decided the split: a delta
    -- settles two windows after it arrives, and the party can be left in between.
    -- The port answers one for a character alone, never GetNumGroupMembers's zero.
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

  describe("quest reward seen from the open dialogue", function()
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

    -- The client prints the line before it applies the gain, so the reserve sampled
    -- around it is shifted one kill: a cross-check input, never the source of the
    -- bonus, which is read off the parenthetical (see the test below).
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

    -- Both kills and their figures are transcribed from a real client's lines; only
    -- the reserve is rounded. Read off the reserve diff, which is one kill behind,
    -- Vishas's 522-point kill would be filed with the Torturer's 101-point bonus.
    it("reads the rested bonus off the parenthetical, not off the reserve behind it", function()
      player:set("restedXp", 45370)
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN,
        "Scarlet Torturer dies, you gain 202 experience. (+101 exp Rested bonus)")

      local first = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(202, first.amount)
      assert.equal(101, first.restedRaw)

      -- The client applies the Torturer's gain only now, after its line.
      player:set("restedXp", 45168)
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN,
        "Interrogator Vishas dies, you gain 522 experience. (+261 exp Rested bonus)")

      local second = bus:lastOn(EventTopic.XP_HINT_RECEIVED)
      assert.equal(261, second.restedRaw)
      -- The reserve this line bounds still describes the Torturer: a drop of 202,
      -- half of which is the 101 the previous line announced.
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

    -- An unmatched line is the only record of what this client prints for a case
    -- the family does not cover, so it goes on the bus verbatim, where the evidence
    -- recorder keeps it.
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

  -- The channel that names a gain's source, read the way the diagnostic reads it:
  -- through the registry, as the reason it prints.
  describe("whether this client offers the channel that names a gain", function()
    local function reasonOn(scoped)
      local capabilities = scoped.adapter.Capabilities.new()
      capabilities:register("xp_chat", scoped.adapter.WowEventRouter.isXpChatSupported)
      return capabilities:reasonFor("xp_chat")
    end

    it("is present when the client carries the kill template", function()
      assert.equal("present", reasonOn(ns))
    end)

    it("is absent when it does not", function()
      _G.COMBATLOG_XPGAIN_FIRSTPERSON = nil

      assert.equal("absent", reasonOn(ns))
    end)

    it("is unreadable when the template itself is closed", function()
      local reason
      AscentTest.withSecretRegime(function()
        local scoped = load()
        _G.COMBATLOG_XPGAIN_FIRSTPERSON = AscentTest.secret(FIRSTPERSON)
        reason = reasonOn(scoped)
      end)

      assert.equal("unreadable", reason)
    end)
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

  -- An optional logger that says which chat-XP templates compiled and what each
  -- line matched. Without one, the router behaves exactly the same.
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
      -- The template that matched rides along: it says whether a kill carried a
      -- group bonus.
      assert.is_not_nil(joined:find("template=FIRSTPERSON", 1, true))
      assert.is_not_nil(joined:find("Boar", 1, true))
      -- And the raw text, so a line matched on its prefix alone still shows the
      -- trailing parenthetical it left unparsed.
      assert.is_not_nil(joined:find("raw=", 1, true))
      assert.is_not_nil(joined:find("Boar dies, you gain 12 experience.", 1, true))
    end)

    -- Without it, exploration experience that lands in UNKNOWN instead of
    -- EXPLORATION leaves nothing to diagnose it by.
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

    -- The timestamp orders the quest hint against the experience delta, an order
    -- not yet confirmed on the client.
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

    -- A line that shares nothing with any compiled template still samples the
    -- reserve, in case a client's EXHAUSTION wording diverges from the first word.
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
    -- annotation on it and never changes it.
    it("keeps the amount the same whether or not there is a modifier", function()
      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience.")
      local plain = bus:lastOn(EventTopic.XP_HINT_RECEIVED).amount

      router:dispatch(WowEvent.CHAT_MSG_COMBAT_XP_GAIN, "Boar dies, you gain 120 experience. (+18 group bonus)")
      local grouped = bus:lastOn(EventTopic.XP_HINT_RECEIVED)

      assert.equal(plain, grouped.amount)
      assert.equal(120, grouped.amount)
    end)

    -- The plain kill template is a prefix of this line; only an anchored match
    -- keeps the modifier.
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

    -- With only the parse in the evidence file, the parser is the sole witness to
    -- its own work; the template and the raw line let a reader check it by eye.
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

  -- What an event carries is a client read too. On the 12.0 engine (World of
  -- Warcraft: Forever) the experience line may come closed: a string that raises on
  -- the match, which the stand-in secret, a table, reproduces only under
  -- withClientTypes.
  describe("on a client that closes what an event carries", function()
    local scoped, closedBus, closedRouter

    before_each(function()
      AscentTest.withSecretRegime(function()
        scoped = load()
        closedBus = scoped.fakes.RecordingEventBus.new()
        closedRouter = scoped.adapter.WowEventRouter.new({
          bus = closedBus,
          clock = scoped.fakes.FakeClock.new(1000),
          playerState = scoped.fakes.FakePlayerState.new({ level = 10, xp = 100, xpMax = 1000, restedXp = 0 }),
        })
      end)
    end)

    -- The line that would have named the source is not read, so nothing is named.
    -- The experience itself arrives on PLAYER_XP_UPDATE and is not this line's to lose.
    it("names no source from an experience line it cannot read", function()
      local line = AscentTest.secret("Boar dies, you gain 12 experience.")

      AscentTest.withClientTypes(function()
        assert.has_no.errors(function()
          closedRouter:dispatch(scoped.core.WowEvent.CHAT_MSG_COMBAT_XP_GAIN, line)
          closedRouter:dispatch(scoped.core.WowEvent.CHAT_MSG_SYSTEM, line)
        end)
      end)

      assert.same({}, closedBus:topicsInOrder())
    end)

    it("carries no closed field of a quest turn-in into the domain", function()
      AscentTest.withClientTypes(function()
        assert.has_no.errors(function()
          closedRouter:dispatch(scoped.core.WowEvent.QUEST_TURNED_IN,
            AscentTest.secret(1234), AscentTest.secret(250), AscentTest.secret(0))
        end)
      end)

      assert.same({ {} }, { closedBus:lastOn(scoped.core.EventTopic.QUEST_COMPLETED) })
      assert.equal(0, closedBus:countOf(scoped.core.EventTopic.XP_HINT_RECEIVED))
    end)

    it("learns nothing from a quest dialogue whose answers it cannot read", function()
      _G.GetQuestID = function() return AscentTest.secret(1234) end
      _G.GetRewardXP = function() return AscentTest.secret(250) end
      _G.GetTitleText = function() return AscentTest.secret("Wanted: Hogger") end

      AscentTest.withClientTypes(function()
        assert.has_no.errors(function()
          closedRouter:dispatch(scoped.core.WowEvent.QUEST_DETAIL)
        end)
      end)

      assert.equal(0, closedBus:countOf(scoped.core.EventTopic.QUEST_REWARD_SEEN))
    end)

    -- The experience line is the channel, so its first closed arrival is the
    -- capability closing. Said once; everything else keeps being routed, because
    -- the experience itself does not travel on this line.
    it("reports the first experience line it cannot read, once, and keeps routing", function()
      local told = 0
      closedRouter.onUnreadable = function() told = told + 1 end
      local line = AscentTest.secret("Boar dies, you gain 12 experience.")
      local Scoped = scoped.core.WowEvent

      closedRouter:dispatch(Scoped.PLAYER_ENTERING_WORLD)
      closedRouter:dispatch(Scoped.CHAT_MSG_COMBAT_XP_GAIN, line)
      closedRouter:dispatch(Scoped.CHAT_MSG_COMBAT_XP_GAIN, line)
      closedRouter:dispatch(Scoped.PLAYER_LOGOUT)

      assert.equal(1, told)
      assert.equal(1, closedBus:countOf(scoped.core.EventTopic.SESSION_ENDED))
    end)

    -- Any other event's closed argument is that event's business, not the channel's.
    it("does not read a closed system line as the experience channel closing", function()
      local told = 0
      closedRouter.onUnreadable = function() told = told + 1 end

      closedRouter:dispatch(scoped.core.WowEvent.CHAT_MSG_SYSTEM, AscentTest.secret("Discovered Goldshire"))
      closedRouter:dispatch(scoped.core.WowEvent.CHAT_MSG_COMBAT_XP_GAIN, nil)

      assert.equal(0, told)
    end)

    -- Read once, at construction, and compiled into a pattern: a closed template
    -- is a channel this client does not offer, the same as a missing one.
    it("compiles no pattern from a template the client closes", function()
      _G.COMBATLOG_XPGAIN_FIRSTPERSON = AscentTest.secret(FIRSTPERSON)

      local built
      AscentTest.withClientTypes(function()
        assert.has_no.errors(function()
          built = scoped.adapter.WowEventRouter.new({
            bus = closedBus,
            clock = scoped.fakes.FakeClock.new(1000),
            playerState = scoped.fakes.FakePlayerState.new({ level = 10, xp = 100, xpMax = 1000 }),
          })
        end)
      end)

      for _, entry in ipairs(built.patterns.xpFamily) do
        assert.are_not.equal("FIRSTPERSON", entry.name)
      end
    end)
  end)
end)
