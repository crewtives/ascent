-- Ascent - the client event router: WowEvent -> EventTopic.
--
-- Nothing here decides anything about experience; it only translates. Combat log
-- reading is deliberately not here -- that is CombatLogRouter's job (9.6-9.9) -- so
-- this file never touches COMBAT_LOG_EVENT_UNFILTERED, and creature deaths are
-- entirely out of scope. ADDON_LOADED is not handled here either: gating
-- construction on the addon's own name is the composition root's job (12.1), not
-- the router's -- by the time something calls :start(), the addon is already loaded.
--
-- THE WHOLE EXPERIENCE FAMILY IS MATCHED HERE, in order of specificity, and the
-- header used to say the opposite. What it claimed -- that a kill announced with a
-- group bonus was not recognised and landed in XpSource.UNKNOWN -- was FALSE, and
-- believing it kept the work parked for months.
--
-- What actually happened: patterns were not anchored, and the plain kill template
-- is a strict prefix of every other one in the family. So a group kill DID match,
-- as an ordinary kill, and its amount was recorded correctly. What was lost, in
-- silence, was the modifier: the player who levelled twenty levels in a group
-- never saw once what going along had contributed.
--
-- The fix is two rules that only work together (design D40): anchor, so the longer
-- templates become reachable at all, and try them most-specific-first, because two
-- collisions survive anchoring -- one of which would record a raid penalty as a
-- fatigue penalty, a different thing entirely.
--
-- The rested bonus does NOT wait on that gap. D18's reserve-diff cross-check
-- (`XpAttribution.restedFromReserve`) only needs restedXp() sampled before and
-- after a kill line, which is a client-API read (9.2), not a chat-text question --
-- so both named and anonymous kills carry restedBefore/restedAfter here already.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Port = ns.core.Port
local WowEvent = ns.core.WowEvent
local EventTopic = ns.core.EventTopic
local XpHintKind = ns.core.XpHintKind
local PlaceKey = ns.core.PlaceKey
local GlobalStringPattern = ns.adapter.GlobalStringPattern

-- ---------------------------------------------------------------------------
-- GlobalString patterns, compiled once at construction (D5)
-- ---------------------------------------------------------------------------

-- A missing GlobalString degrades to "this channel matches nothing" rather than
-- erroring the addon off the load screen -- the same capacity-absent tolerance
-- 9.1's Capabilities registry exists for, applied at the one spot that reads raw
-- client strings instead of calling a function.
local function compileIfPresent(template)
  if type(template) ~= "string" then
    return nil
  end
  local pattern, order = GlobalStringPattern.compile(template)
  return { pattern = pattern, order = order }
end

-- Every template of the family, by name, read once at construction. Spelled out
-- rather than reached through _G: the dependency rule gives this layer a curated
-- list of client symbols, and a table indexed by string would walk straight past
-- that list.
local function xpTemplateText()
  local texts = {
    COMBATLOG_XPGAIN_FIRSTPERSON = COMBATLOG_XPGAIN_FIRSTPERSON,
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED,
    COMBATLOG_XPGAIN_FIRSTPERSON_GROUP = COMBATLOG_XPGAIN_FIRSTPERSON_GROUP,
    COMBATLOG_XPGAIN_FIRSTPERSON_RAID = COMBATLOG_XPGAIN_FIRSTPERSON_RAID,
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP = COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP,
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID = COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID,
    COMBATLOG_XPGAIN_QUEST = COMBATLOG_XPGAIN_QUEST,
    COMBATLOG_XPGAIN_EXHAUSTION1 = COMBATLOG_XPGAIN_EXHAUSTION1,
    COMBATLOG_XPGAIN_EXHAUSTION2 = COMBATLOG_XPGAIN_EXHAUSTION2,
    COMBATLOG_XPGAIN_EXHAUSTION4 = COMBATLOG_XPGAIN_EXHAUSTION4,
    COMBATLOG_XPGAIN_EXHAUSTION5 = COMBATLOG_XPGAIN_EXHAUSTION5,
    COMBATLOG_XPGAIN_EXHAUSTION1_GROUP = COMBATLOG_XPGAIN_EXHAUSTION1_GROUP,
    COMBATLOG_XPGAIN_EXHAUSTION1_RAID = COMBATLOG_XPGAIN_EXHAUSTION1_RAID,
    COMBATLOG_XPGAIN_EXHAUSTION2_GROUP = COMBATLOG_XPGAIN_EXHAUSTION2_GROUP,
    COMBATLOG_XPGAIN_EXHAUSTION2_RAID = COMBATLOG_XPGAIN_EXHAUSTION2_RAID,
    COMBATLOG_XPGAIN_EXHAUSTION4_GROUP = COMBATLOG_XPGAIN_EXHAUSTION4_GROUP,
    COMBATLOG_XPGAIN_EXHAUSTION4_RAID = COMBATLOG_XPGAIN_EXHAUSTION4_RAID,
    COMBATLOG_XPGAIN_EXHAUSTION5_GROUP = COMBATLOG_XPGAIN_EXHAUSTION5_GROUP,
    COMBATLOG_XPGAIN_EXHAUSTION5_RAID = COMBATLOG_XPGAIN_EXHAUSTION5_RAID,
  }
  return function(name)
    return texts[name]
  end
end

local function compiledPatterns()
  return {
    xpFamily           = GlobalStringPattern.compileXpFamily(xpTemplateText()),
    zoneExplored       = compileIfPresent(ERR_ZONE_EXPLORED_XP),
    questRewardEcho    = compileIfPresent(ERR_QUEST_REWARD_EXP_I),
  }
end

-- Fields keyed by ORIGINAL placeholder number, the way 9.4 designed it to be read;
-- nil when the compiled pattern is absent or the line does not match it.
local function fieldsOf(compiled, line)
  if compiled == nil then
    return nil
  end

  local captures = { line:match(compiled.pattern) }
  if #captures == 0 then
    return nil
  end

  local fields = {}
  for index, placeholder in ipairs(compiled.order) do
    fields[placeholder] = captures[index]
  end
  return fields
end

-- ---------------------------------------------------------------------------
-- Internal state helpers
-- ---------------------------------------------------------------------------

-- The baseline PLAYER_XP_UPDATE and PLAYER_LEVEL_UP measure against. Re-anchored on
-- every PLAYER_ENTERING_WORLD -- including a mid-session one, like a loading screen
-- -- which is self-healing rather than redundant: it is one more point where any
-- drift this router might have accumulated gets corrected instead of compounding.
local function refreshXpSnapshot(self)
  self.lastLevel = self.playerState:level()
  self.lastXp = self.playerState:xp()
  self.lastXpMax = self.playerState:xpMax()
end

local function publishXpDelta(self)
  local level, xp = self.playerState:level(), self.playerState:xp()
  local amount = 0

  if self.lastLevel ~= nil then
    if level == self.lastLevel then
      amount = xp - self.lastXp
    elseif level > self.lastLevel then
      -- One level crossed, folded into the delta the way XpAttribution's contract
      -- expects. A gain crossing two or more levels at once under-counts the levels
      -- in between: nothing here knows what an arbitrary level costs, the same gap
      -- LevelTracker already tolerates when it is built without an `xpForLevel` table.
      amount = (self.lastXpMax - self.lastXp) + xp
    end
  end

  if amount > 0 then
    local at = self.clock:now()
    if self.logger ~= nil then
      self.logger:debug(("delta observed at %.3f: amount=%d"):format(at, amount))
    end
    -- Where the character is RIGHT NOW, read here and nowhere else (D43). This is
    -- the instant the experience is known to have been granted; the announcement
    -- that explains it can arrive a second and a half either side, by which time
    -- the character may be through a portal.
    self.bus:publish(EventTopic.XP_DELTA_OBSERVED, {
      amount = amount, at = at, place = PlaceKey.new(self.playerState:place()),
    })
  end
  refreshXpSnapshot(self)
end

-- Sampled once per kill line rather than off UPDATE_EXHAUSTION, and the session of
-- 2026-09-17 showed what that costs: the client does NOT apply the gain before it
-- prints the line, so both readings here are taken a kill too early and the window
-- they bound belongs to the PREVIOUS kill. Over 81 kills the reserve diff matched
-- the previous line's parenthetical 37 times and the current line's never once.
--
-- Internal consistency was the assumption written here, and it is exactly what does
-- not save it: the window is internally consistent AND shifted by one whole kill.
-- So this is no longer the source of the rested bonus -- the parenthetical is, read
-- off the template (restedRaw below) -- and what these two fields feed is the
-- reserve cross-check, which cannot be believed until it is re-anchored on
-- PLAYER_XP_UPDATE, where the evidence shows the reserve has already settled.
local function killRestedWindow(self)
  local before = self.lastRestedXp
  local after = self.playerState:restedXp()
  self.lastRestedXp = after
  return before, after
end

local function publishHint(self, kind, fields)
  fields.kind = kind
  fields.at = self.clock:now()
  self.bus:publish(EventTopic.XP_HINT_RECEIVED, fields)
end

-- ---------------------------------------------------------------------------
-- Dispatch table: WowEvent -> handler(self, ...)
-- ---------------------------------------------------------------------------

local function onPlayerEnteringWorld(self)
  refreshXpSnapshot(self)
  self.lastRestedXp = self.playerState:restedXp()
  self.bus:publish(EventTopic.SESSION_STARTED, {
    level = self.lastLevel, xp = self.lastXp, xpMax = self.lastXpMax,
  })
end

local function onPlayerLogout(self)
  self.bus:publish(EventTopic.SESSION_ENDED, {})
end

local function onRestChanged(self)
  self.bus:publish(EventTopic.REST_CHANGED, {
    restedXp = self.playerState:restedXp(),
    isResting = self.playerState:isResting(),
  })
end

local function onXpGainToggled(self)
  self.bus:publish(EventTopic.XP_STATE_CHANGED, { isXpDisabled = self.playerState:isXpDisabled() })
end

local function onCombatStarted(self)
  self.bus:publish(EventTopic.COMBAT_STARTED, {})
end

local function onCombatEnded(self)
  self.bus:publish(EventTopic.COMBAT_ENDED, {})
end

local function onPlayerDied(self)
  self.bus:publish(EventTopic.PLAYER_DIED, {})
end

local function onPlayerRevived(self)
  self.bus:publish(EventTopic.PLAYER_REVIVED, {})
end

-- QUEST_TURNED_IN(questID, xpReward, moneyReward). No parsing at all (D5): the
-- event itself is the authoritative source, and it needs no help from the chat
-- echo COMBATLOG_XPGAIN_QUEST would otherwise carry.
local function onQuestTurnedIn(self, questId, xpReward)
  -- Guarded once, used twice: the hint below always needed a valid number, and
  -- group 8's calibration (quest-xp-forecast) needs the same one on
  -- QUEST_COMPLETED to compare against what it had forecast for this quest.
  local validReward = (type(xpReward) == "number" and xpReward >= 0) and xpReward or nil

  self.bus:publish(EventTopic.QUEST_COMPLETED, { questId = questId, xpReward = validReward })

  if validReward ~= nil then
    -- Timestamped like the kill-message hint: spike 0.2 needs this to determine
    -- the order between the quest hint and its XP delta, the same open question
    -- already partly answered for kills.
    if self.logger ~= nil then
      self.logger:debug(("hint (quest turn-in) at %.3f: questId=%s amount=%s")
        :format(self.clock:now(), tostring(questId), tostring(validReward)))
    end
    publishHint(self, XpHintKind.QUEST_TURNED_IN, { questId = questId, amount = validReward })
  end
end

local function onQuestLogChanged(self)
  self.bus:publish(EventTopic.QUEST_LOG_CHANGED, {})
end

-- D15's level 2: a reward learned from the open quest dialogue (QUEST_DETAIL,
-- shown before accepting, and QUEST_COMPLETE, shown before turning in), cached
-- by questID so quest-xp-forecast can fall back to it when the quest log's own
-- GetQuestLogRewardXP is not trustworthy or comes back empty. Unlike that
-- function -- which design.md's own appendix tracks as verified present in
-- both Era and TBC -- neither GetQuestID nor GetRewardXP has been checked
-- against a real client anywhere in this codebase; this is a first, cautious
-- read of both; the same reason a bad shape here degrades to nothing published
-- rather than a fabricated event.
-- `GetTitleText` is the quest dialogue's own title, and the only place either
-- supported client names a quest it is not carrying in the log -- the turn-in
-- event carries no text, and Era cannot name a quest by id at all. Shape checked
-- like every other client read here, and absent rather than wrong when the client
-- has nothing to say. Published, not remembered: the directory that keeps names
-- is the thing that remembers, and it is fed at the composition root.
local function readQuestTitle()
  local title = type(GetTitleText) == "function" and GetTitleText() or nil
  if type(title) ~= "string" or title == "" then
    return nil
  end
  return title
end

local function onQuestRewardSeen(self)
  if type(GetQuestID) ~= "function" or type(GetRewardXP) ~= "function" then
    return
  end

  local questId = GetQuestID()
  if type(questId) ~= "number" or questId == 0 then
    return
  end

  local title = readQuestTitle()

  local reward = GetRewardXP()
  if type(reward) ~= "number" or reward < 0 or reward % 1 ~= 0 then
    return
  end

  if self.logger ~= nil then
    self.logger:debug(("quest reward seen at %.3f: questId=%s reward=%s title=%s")
      :format(self.clock:now(), tostring(questId), tostring(reward), tostring(title)))
  end

  self.bus:publish(EventTopic.QUEST_REWARD_SEEN, { questId = questId, reward = reward, title = title })
end

local function onChatCombatXpGain(self, message)
  if type(message) ~= "string" then
    return
  end

  local matched = GlobalStringPattern.matchXp(self.patterns.xpFamily, message)
  if matched == nil then
    -- Not experience, or a template this client has that the family does not
    -- know. Worth seeing verbatim rather than guessing, and worth sampling the
    -- reserve too in case the real template diverges from the very first word.
    local before, after = killRestedWindow(self)
    -- Published, not merely logged. The debug print goes to the chat frame and to a
    -- ring nobody reads afterwards, while THIS is the line that would tell us what a
    -- client prints for the cases the family does not cover yet. The recorder exists
    -- to keep exactly that -- the client's own sentence, verbatim -- and it was
    -- keeping it for every line except the ones still under question.
    self.bus:publish(EventTopic.XP_LINE_UNMATCHED, {
      raw = message,
      at = self.clock:now(),
      restedBefore = before,
      restedAfter = after,
    })
    if self.logger ~= nil then
      self.logger:debug(("CHAT_MSG_COMBAT_XP_GAIN matched no template at %.3f: %q restedBefore=%s restedAfter=%s")
        :format(self.clock:now(), message, tostring(before), tostring(after)))
    end
    return
  end

  -- Hits per template (design D45). This is what turns the one thing the
  -- research could not settle -- whether the parenthetical is already inside the
  -- total -- into something a real levelling session answers: the amount parsed
  -- sits on the same line as the delta the client reports, so the two can simply
  -- be compared.
  self.hitsByTemplate[matched.template] = (self.hitsByTemplate[matched.template] or 0) + 1

  local before, after = killRestedWindow(self)

  -- A template with a creature in it is a kill announcement; one without is the
  -- anonymous line, which is what quests and discoveries arrive on. The KIND
  -- comes from the template's own shape rather than from a second guess about
  -- the text.
  local kind = matched.creature ~= nil and XpHintKind.KILL_MESSAGE or XpHintKind.ANONYMOUS_MESSAGE

  -- Annotations, never addends (design D41). The big number is the experience
  -- actually credited: the group figure is a portion already inside it and the
  -- raid figure is what was taken off before crediting. Neither is added to nor
  -- subtracted from what gets recorded -- exactly the rule the rested bonus
  -- already follows.
  local groupBonus, raidPenalty
  if matched.modifier == "group" then
    groupBonus = matched.modifierAmount
  elseif matched.modifier == "raid" then
    raidPenalty = matched.modifierAmount
  end

  if self.logger ~= nil then
    self.logger:debug((
      "hint (%s) at %.3f: template=%s creature=%q amount=%s group=%s raid=%s " ..
      "restedRaw=%s restedBefore=%s restedAfter=%s raw=%q"
    ):format(tostring(kind), self.clock:now(), matched.template, tostring(matched.creature),
      tostring(matched.amount), tostring(groupBonus), tostring(raidPenalty),
      tostring(matched.restedAmount), tostring(before), tostring(after), message))
  end

  -- `template` and `raw` ride along for the flight recorder, and they are two
  -- different facts on purpose: `raw` is the sentence the client actually
  -- printed, `template` is which pattern this addon believed it was. Recording
  -- only the parse would record the conclusion under question -- the first
  -- session came back unable to say whether a group line had a parenthetical at
  -- all, because everything downstream of the parser agreed with the parser.
  -- Both are plain references to strings that already exist; neither allocates.
  publishHint(self, kind, {
    amount = matched.amount,
    creatureName = matched.creature,
    -- The figure the client printed, which is the only reading of the rested bonus
    -- that is anchored to THIS kill. nil whenever the template names no magnitude
    -- (a fatigue line, a client whose parenthetical is a percentage).
    restedRaw = matched.restedAmount,
    -- Whether the sentence announced a rested state AT ALL, which is a different
    -- fact from the magnitude and the one that says what a missing magnitude means:
    -- a line that mentions no reserve is a kill that paid no bonus, and a line that
    -- mentions one without naming a figure is the case the reserve reading exists
    -- for. Flattened to a boolean here rather than passed through, so that `nil`
    -- keeps meaning the third thing downstream -- no sentence was read at all.
    restedAnnounced = matched.rested == true,
    restedBefore = before,
    restedAfter = after,
    groupBonus = groupBonus,
    raidPenalty = raidPenalty,
    template = matched.template,
    raw = message,
  })
end

local function onChatSystem(self, message)
  if type(message) ~= "string" then
    return
  end

  local discovery = fieldsOf(self.patterns.zoneExplored, message)
  if discovery ~= nil then
    local amount = tonumber(discovery[2])
    if amount ~= nil then
      -- Timestamped like the kill-message hint (see that debug line, above): a
      -- player reported exploration XP landing half in EXPLORATION and half in
      -- UNKNOWN, and this channel had no diagnostics at all to tell whether the
      -- hint is missing its delta's matching window (D4/D5's Open Question 1,
      -- unverified for this channel) or something else entirely.
      if self.logger ~= nil then
        self.logger:debug(("hint (zone discovery) at %.3f: zone=%q amount=%s")
          :format(self.clock:now(), tostring(discovery[1]), tostring(amount)))
      end
      publishHint(self, XpHintKind.ZONE_DISCOVERED, { amount = amount, zoneName = discovery[1] })
    end
    return
  end

  local questEcho = fieldsOf(self.patterns.questRewardEcho, message)
  if questEcho ~= nil then
    local amount = tonumber(questEcho[1])
    if amount ~= nil then
      -- Timestamped like the quest turn-in hint above: this is its system-channel
      -- echo, and D5's precedence rule already assumes it arrives close to the
      -- turn-in event -- spike 0.2/0.3 is what actually checks that.
      if self.logger ~= nil then
        self.logger:debug(("hint (quest echo) at %.3f: amount=%s"):format(self.clock:now(), tostring(amount)))
      end
      publishHint(self, XpHintKind.QUEST_MESSAGE, { amount = amount })
    end
  end
end

local DISPATCH = {
  [WowEvent.PLAYER_ENTERING_WORLD] = onPlayerEnteringWorld,
  [WowEvent.PLAYER_LOGOUT]         = onPlayerLogout,

  [WowEvent.PLAYER_XP_UPDATE] = publishXpDelta,
  [WowEvent.PLAYER_LEVEL_UP]  = publishXpDelta,

  [WowEvent.UPDATE_EXHAUSTION]     = onRestChanged,
  [WowEvent.PLAYER_UPDATE_RESTING] = onRestChanged,

  [WowEvent.ENABLE_XP_GAIN]  = onXpGainToggled,
  [WowEvent.DISABLE_XP_GAIN] = onXpGainToggled,

  [WowEvent.PLAYER_REGEN_DISABLED] = onCombatStarted,
  [WowEvent.PLAYER_REGEN_ENABLED]  = onCombatEnded,

  [WowEvent.PLAYER_DEAD]    = onPlayerDied,
  [WowEvent.PLAYER_ALIVE]   = onPlayerRevived,
  [WowEvent.PLAYER_UNGHOST] = onPlayerRevived,

  [WowEvent.QUEST_TURNED_IN]  = onQuestTurnedIn,
  [WowEvent.QUEST_ACCEPTED]   = onQuestLogChanged,
  [WowEvent.QUEST_REMOVED]    = onQuestLogChanged,
  [WowEvent.QUEST_LOG_UPDATE] = onQuestLogChanged,

  [WowEvent.QUEST_DETAIL]   = onQuestRewardSeen,
  [WowEvent.QUEST_COMPLETE] = onQuestRewardSeen,

  [WowEvent.CHAT_MSG_COMBAT_XP_GAIN] = onChatCombatXpGain,
  [WowEvent.CHAT_MSG_SYSTEM]         = onChatSystem,
}

-- ---------------------------------------------------------------------------
-- The router
-- ---------------------------------------------------------------------------

local WowEventRouter = {}
WowEventRouter.__index = WowEventRouter

function WowEventRouter.new(options)
  options = options or {}
  for _, required in ipairs({ "bus", "clock", "playerState" }) do
    if options[required] == nil then
      error("WowEventRouter needs a " .. required, 2)
    end
  end
  Port.verify(ns.core.EventBusPort, options.bus, "WowEventRouter bus")
  Port.verify(ns.core.Clock, options.clock, "WowEventRouter clock")
  Port.verify(ns.core.PlayerState, options.playerState, "WowEventRouter playerState")

  local patterns = compiledPatterns()

  -- One counter per template that actually matched something. Read by the
  -- diagnostic command; costs one table and one increment per experience line,
  -- which is not a hot path (design D45).
  local templateHits = {}

  -- Diagnostic only: `logger` is optional and everything works the same without
  -- one. Which templates this client actually has is the first thing worth
  -- knowing when a kill line is not being recognised -- the family is thirteen
  -- templates and a given client may not carry them all.
  if options.logger ~= nil then
    for _, entry in ipairs(patterns.xpFamily) do
      options.logger:debug(("pattern '%s': compiled"):format(entry.name))
    end
    options.logger:debug(("xp family: %d template(s) compiled"):format(#patterns.xpFamily))
    -- The ones that did NOT make it, and why it is worth saying: a template can
    -- be absent because this client does not have it, or because its text is
    -- identical to one already compiled -- which several of them are, by design.
    -- Both are normal; a template missing that should be there is not.
    local compiledNames = {}
    for _, entry in ipairs(patterns.xpFamily) do
      compiledNames[entry.name] = true
    end
    for _, template in ipairs(GlobalStringPattern.XP_TEMPLATES) do
      if not compiledNames[template.name] then
        options.logger:debug(("pattern '%s': GlobalString missing, or duplicate of one already compiled")
          :format(template.name))
      end
    end
    for _, name in ipairs({ "zoneExplored", "questRewardEcho" }) do
      options.logger:debug(("pattern '%s': %s"):format(name,
        patterns[name] ~= nil and "compiled" or "GlobalString missing or not a string"))
    end
  end

  return setmetatable({
    bus = options.bus,
    clock = options.clock,
    playerState = options.playerState,
    logger = options.logger,
    patterns = patterns,
    hitsByTemplate = templateHits,

    lastLevel = nil, lastXp = nil, lastXpMax = nil, lastRestedXp = nil,
    frame = nil,
  }, WowEventRouter)
end

-- How many experience lines matched each template, for the diagnostic command.
-- A template that never appears is as informative as one that does: the research
-- holds that the fatigue family is dead code in both supported clients, and this
-- is what would show otherwise.
-- Named apart from the field it returns on purpose: a field and a method of the
-- same name cannot coexist on one table in Lua -- the field wins and the method
-- becomes uncallable, silently.
function WowEventRouter:templateHits()
  local copy = {}
  for name, count in pairs(self.hitsByTemplate) do
    copy[name] = count
  end
  return copy
end

-- The one method the tests drive directly: everything above is reachable without a
-- WoW frame, which is what "verify with adapter tests" means for a router.
function WowEventRouter:dispatch(event, ...)
  local handler = DISPATCH[event]
  if handler then
    handler(self, ...)
  end
end

function WowEventRouter:start()
  if self.frame ~= nil then
    return self
  end

  local frame = CreateFrame("Frame")
  for event in pairs(DISPATCH) do
    frame:RegisterEvent(event)
  end
  frame:SetScript("OnEvent", function(_, event, ...)
    self:dispatch(event, ...)
  end)

  self.frame = frame
  return self
end

function WowEventRouter:stop()
  if self.frame == nil then
    return self
  end
  self.frame:UnregisterAllEvents()
  self.frame = nil
  return self
end

ns.adapter.WowEventRouter = WowEventRouter
