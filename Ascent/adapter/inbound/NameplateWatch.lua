-- Ascent - what you pulled, including what has not reached you yet.
--
-- The combat log answers "who is fighting me" only once a line has been written
-- about it: a blow, a miss, a cast, a debuff. That is most of a pull and it is not
-- all of it. Aggro three creatures with one shot and two of them spend the next
-- several seconds running at you, writing nothing -- and a plate built from the
-- combat log alone shows a pull of one while three are on their way.
--
-- This is the only other place a Classic client will say it. A nameplate is a unit
-- token, and a unit token can be asked what it is doing. The rule is deliberately
-- narrow:
--
--   HOSTILE, ALIVE, FIGHTING, AND AIMING AT YOU. Both halves of that are needed
--   and neither is enough alone. "In combat" by itself takes in a creature
--   fighting somebody else across the clearing, and counting it would put
--   experience you will never be paid into the plate. "Aiming at you" by itself
--   takes in one that merely has you selected while it stands there -- and the
--   player clicking a creature must never add it to the pull, which is the exact
--   failure that made this rule two conditions instead of one.
--
-- It publishes the same ENEMY_ENGAGED the combat log router does, so nothing
-- downstream knows there are two ways to learn this, and the pull record's own
-- per-creature rule is what keeps one creature from being counted twice.
--
-- IT DEGRADES TO NOTHING. Nameplates can be switched off in the client's own
-- options, and then there are no tokens and this sees nobody -- which is exactly
-- the state the addon was in before this file existed, not a failure. It is
-- registered as a capability so `/ascent debug` says which of the two answers the
-- player is actually getting.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Port = ns.core.Port
local EventTopic = ns.core.EventTopic
local WowEvent = ns.core.WowEvent
local CreatureGuid = ns.adapter.CreatureGuid

local NameplateWatch = {}
NameplateWatch.__index = NameplateWatch

function NameplateWatch.isSupported()
  return C_NamePlate ~= nil and type(C_NamePlate.GetNamePlates) == "function"
end

-- Every unit token this could be asked about, newest first source.
--
-- The tokens come from NAME_PLATE_UNIT_ADDED, which hands one over as its own
-- argument. Reading `namePlateUnitToken` off the frames GetNamePlates() returns
-- was believed to be the same thing; the session of 2026-09-22 says it is not,
-- with 168 nameplates seen and a token from none of them. That single nil is why
-- this file had never enrolled anybody -- not the rule below, which never ran.
--
-- The frames are still read, as a fallback for a client that does hand the token
-- over that way, and the tally says which source answered so the next session
-- does not have to guess again.
local function tokensNow(self)
  local tokens = {}
  for token in pairs(self.tokens) do
    tokens[#tokens + 1] = token
  end
  if #tokens > 0 then
    return tokens, "event"
  end

  if C_NamePlate == nil or type(C_NamePlate.GetNamePlates) ~= "function" then
    return tokens, "none"
  end
  local plates = C_NamePlate.GetNamePlates()
  if type(plates) ~= "table" then
    return tokens, "none"
  end
  for _, plate in ipairs(plates) do
    local token = type(plate) == "table" and plate.namePlateUnitToken or nil
    if token ~= nil then
      tokens[#tokens + 1] = token
    end
  end
  return tokens, #plates > 0 and "frame" or "none"
end

function NameplateWatch.new(options)
  options = options or {}
  if options.bus == nil then
    error("NameplateWatch needs an event bus", 2)
  end
  Port.verify(ns.core.EventBusPort, options.bus, "NameplateWatch bus")

  return setmetatable({
    bus = options.bus,
    -- Optional, and what it writes is a TALLY rather than a line per nameplate: a
    -- sweep runs four times a second, and the question it has to answer after the
    -- fact is which of the conditions is throwing everyone out.
    recordEvidence = options.recordEvidence,

    -- Filled by NAME_PLATE_UNIT_ADDED, emptied by its removal. A set and not a
    -- list because the client may add the same token again after a removal it
    -- never sent, and a pull that counted one creature twice is the failure this
    -- whole file is downstream of.
    tokens = {},
    frame = nil,
    lastSignature = nil,

    -- Which tokens were already reported as fighting this character, so a steady
    -- state is not re-announced every quarter second. Emptied per token when the
    -- client takes its nameplate away, and per token when it stops qualifying --
    -- a creature that loses interest and comes back is a new edge.
    announced = {},
  }, NameplateWatch)
end

-- Whether this creature is in THIS fight, and WHICH condition said no. Every call
-- is guarded: a client without one of them answers nil, which reads as "no" rather
-- than raising inside a sweep that runs while the player is fighting.
--
-- The reason for a verdict rather than a boolean: these are four different client
-- questions and only one of them has to answer wrong for a pull to stay empty. A
-- sweep that could only say "nobody" left a reader with four suspects and no way to
-- tell them apart, which is exactly the state this was reported from.
local function verdictFor(token)
  if UnitExists == nil or not UnitExists(token) then
    return "gone"
  end
  if UnitCanAttack == nil or not UnitCanAttack("player", token) then
    return "friendly"
  end
  if UnitIsDead ~= nil and UnitIsDead(token) then
    return "dead"
  end
  -- Claimed by somebody who is not you and not yours. It can still be fought and
  -- it will still pay nothing, so it does not belong in a plate whose whole job
  -- is estimating what this fight is worth.
  --
  -- Used rather than instrumented because the file answered: 40 readings on
  -- 2026-09-22 and `tapNoApi` never once. What the same file also settled is that
  -- this is only ever an EXCLUSION -- every one of those 40 came back open,
  -- including the thirty-odd creatures standing in a field doing nothing, so
  -- "unclaimed" says nothing at all about whether a pull happened.
  if UnitIsTapDenied ~= nil and UnitIsTapDenied(token) == true then
    return "tapped"
  end
  -- THE QUESTION ITSELF, where the client can be asked it. Being on a creature's
  -- threat list is true from the moment it decided to come for you and stays true
  -- whoever it happens to be swinging at, so it answers the tank case without
  -- knowing anything about groups, and it does not blink when the creature glances
  -- somewhere else for a frame.
  --
  -- Verified present on 2026-09-22: 45 readings, `threatOn` 25 and `threatNone`
  -- 20, and not once did the client fail to answer. It belongs to a later client
  -- than these two, which is why it is asked for rather than assumed, and why the
  -- target rule below stays as the fallback instead of being deleted.
  --
  -- What the same reading also showed is why this is the better question at all:
  -- "aiming at me" matched five times over the same stretch. Both are kept, under
  -- their own verdicts, so the file keeps saying which one is carrying the work.
  if UnitThreatSituation ~= nil then
    local ok, status = pcall(UnitThreatSituation, "player", token)
    if ok and status ~= nil then
      return "threat"
    end
  end

  -- BELOW the threat question on purpose, and it was above it for one session,
  -- which is how the reason got measured: 62 readings had the player on a
  -- creature's threat list and only 2 of them ever reached the threat check --
  -- `idle` threw out 102 plates first, one of them in a single-plate sweep where
  -- there is no doubt which token it was. A combat flag is a weaker statement
  -- than a threat list: if you are on its list, it is fighting you, whatever the
  -- flag says about it this frame.
  --
  -- It still earns its place underneath. A creature standing in a field is not in
  -- combat, so selecting it, targeting it or hovering it enrols nothing -- and
  -- clicking does not put you on a threat list either, so the objection this rule
  -- was built for is answered twice over now.
  if UnitAffectingCombat == nil or not UnitAffectingCombat(token) then
    return "idle"
  end

  if UnitIsUnit == nil then
    return "noTargetApi"
  end

  local target = token .. "target"
  if UnitIsUnit(target, "player") == true or UnitIsUnit(target, "pet") == true then
    return "mine"
  end

  -- The same fight, aimed at somebody else in it. Without this the rule is keyed
  -- on AGGRO, and experience credit has nothing to do with aggro: a creature the
  -- tank is holding pays the whole group, and in a party every creature aims at
  -- the tank. The narrow rule was right about a creature across the clearing and
  -- wrong about the four in front of you, and it answers "elsewhere" to both.
  --
  -- Still not the whole answer -- what actually decides payment is the tag, not
  -- who is being hit -- but it is the half that can be asked with the calls this
  -- file already uses. `tapDenied` in the tally is the instrument for the other
  -- half: whether this client can be asked the real question at all.
  if IsInGroup ~= nil and IsInGroup() == true then
    local prefix = (IsInRaid ~= nil and IsInRaid() == true) and "raid" or "party"
    local count = GetNumGroupMembers ~= nil and GetNumGroupMembers() or 0
    for index = 1, count do
      local member = prefix .. index
      if UnitIsUnit(target, member) == true or UnitIsUnit(target, member .. "pet") == true then
        return "group"
      end
    end
  end

  return "elsewhere"
end

-- The question the rule above is really trying to ask, and cannot.
--
-- "Aiming at you" is a photograph of one frame: the creature hitting the tank
-- answers no, and so does the one that glanced elsewhere for half a second.
-- "Am I on its threat list" is the thing itself -- true from the moment it
-- decided to come for you, regardless of who it is currently swinging at, and
-- group-aware without knowing anything about the group.
--
-- Recorded and NOT acted on. It belongs to a later client than these two, so
-- whether it answers here is a question for a file and not for a guess; the rule
-- keeps using what is known to work until one says otherwise.
local function threatVerdict(token)
  if UnitThreatSituation == nil then
    return "threatNoApi"
  end
  local ok, status = pcall(UnitThreatSituation, "player", token)
  if not ok then
    return "threatRaised"
  end
  return status ~= nil and "threatOn" or "threatNone"
end

-- Kept alongside the verdict now that threat decides, so the file can still say
-- what the old rule WOULD have answered. The day threat is missing on some
-- client, this is what says whether the fallback would have carried it.
local function tapVerdict(token)
  if UnitIsTapDenied == nil then
    return "tapNoApi"
  end
  return UnitIsTapDenied(token) == true and "tapDenied" or "tapOpen"
end

-- Called from the ticker the addon already runs, and only while a pull is open:
-- out of combat there is nothing to enrol and this costs nothing at all.
-- What this reports is an EDGE, not a level. A poll that published everything it
-- could still see would say the same thing four times a second, so a creature
-- becoming one this character is fighting is the event, and continuing to be one
-- is not.
--
-- It used to key that on the pull's generation, which is a thing an adapter that
-- looks at nameplates has no business knowing: the token's own lifetime is what
-- bounds it, and the client already announces both ends of that. Whether an
-- engagement is NEWS to a fight is a different question, it belongs to the pull,
-- and the pull already answers it -- two copies of one rule in two layers is how
-- a change to it turns into an afternoon.
function NameplateWatch:sweep()
  if not NameplateWatch.isSupported() then
    return 0
  end

  local tokens, source = tokensNow(self)

  local found = 0
  local tally
  if self.recordEvidence ~= nil then
    tally = { plates = #tokens, source = source }
  end

  for _, token in ipairs(tokens) do
    local verdict = verdictFor(token)
    if tally ~= nil then
      local threat = threatVerdict(token)
      tally[threat] = (tally[threat] or 0) + 1
      local tap = tapVerdict(token)
      tally[tap] = (tally[tap] or 0) + 1
    end
    if verdict == "threat" or verdict == "mine" or verdict == "group" then
      local guid = UnitGUID ~= nil and UnitGUID(token) or nil
      local name = UnitName ~= nil and UnitName(token) or nil
      -- The same two guards the combat log router applies: a guid that is not a
      -- creature's is a player or a pet, and a creature with no name is one this
      -- addon cannot show a row for.
      if name ~= nil and CreatureGuid.isCreature(guid) then
        found = found + 1
        if self.announced[token] == nil then
          self.announced[token] = true
          self.bus:publish(EventTopic.ENEMY_ENGAGED, { guid = guid, name = name, from = "nameplate" })
        else
          verdict = "already"
        end
      else
        verdict = "notACreature"
      end
    else
      -- Stopped qualifying, so the next time it does is news again.
      self.announced[token] = nil
    end
    if tally ~= nil then
      tally[verdict] = (tally[verdict] or 0) + 1
    end
  end

  -- Every sweep is counted; only a sweep that SAYS something new is kept.
  --
  -- The tally is already a summary, and the sweep runs four times a second, so
  -- one sample per sweep is the ring drowning in its own instrument -- 105 of the
  -- 108 samples in the session of 2026-09-22, all of them identical. The
  -- signature collapses the repeats, which is the same bargain the recorder makes
  -- everywhere else: the counter says how often, the sample shows one.
  if tally ~= nil then
    tally.enrolled = found
    local keys = {}
    for key in pairs(tally) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = key .. "=" .. tostring(tally[key])
    end
    local signature = table.concat(parts, " ")

    self.recordEvidence("nameplateSweep")
    if signature ~= self.lastSignature then
      self.lastSignature = signature
      self.recordEvidence("nameplateMix", tally)
    end
  end
  return found
end

-- The tokens arrive here and nowhere else. Idempotent like every other start() in
-- this addon, because the capability probe and the composition root both reach it.
function NameplateWatch:start()
  if self.frame ~= nil or CreateFrame == nil then
    return self
  end

  local frame = CreateFrame("Frame")
  frame:RegisterEvent(WowEvent.NAME_PLATE_UNIT_ADDED)
  frame:RegisterEvent(WowEvent.NAME_PLATE_UNIT_REMOVED)
  frame:SetScript("OnEvent", function(_, event, token)
    if type(token) ~= "string" then
      return
    end
    if event == WowEvent.NAME_PLATE_UNIT_ADDED then
      self.tokens[token] = true
    else
      self.tokens[token] = nil
      -- The token is the client's, not ours: it reuses "nameplate3" for whatever
      -- stands there next. Forgetting it here is what keeps the next creature to
      -- wear that number from being taken for the one that just left.
      self.announced[token] = nil
    end
  end)

  self.frame = frame
  return self
end

function NameplateWatch:stop()
  if self.frame == nil then
    return self
  end
  self.frame:UnregisterAllEvents()
  self.frame = nil
  for token in pairs(self.tokens) do
    self.tokens[token] = nil
  end
  return self
end

ns.adapter.NameplateWatch = NameplateWatch
