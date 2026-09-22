-- Ascent - what you pulled, including what has not reached you yet.
--
-- The combat log answers "who is fighting me" only once a line has been written
-- about it: a blow, a miss, a cast, a debuff. Aggro three creatures with one shot
-- and two of them spend several seconds running at you, writing nothing, so a
-- plate built from the combat log alone shows a pull of one while three are on
-- their way.
--
-- A nameplate is the only other place a Classic client says it: it is a unit
-- token, and a unit token can be asked what it is doing. A creature counts when it
-- is hostile, alive, not claimed by somebody else, and either has you on its
-- threat list or is in combat and aiming at you, your pet or your group. "In
-- combat" alone takes in a creature fighting somebody else across the clearing,
-- whose experience you will never be paid; "aiming at you" alone takes in one that
-- merely has you selected, and clicking a creature must never add it to the pull.
--
-- It publishes the same ENEMY_ENGAGED the combat log router does, so nothing
-- downstream knows there are two sources, and the pull record's per-creature rule
-- keeps one creature from being counted twice.
--
-- It degrades to nothing: with nameplates switched off in the client's options
-- there are no tokens and this sees nobody, which is not a failure. It is
-- registered as a capability so `/ascent debug` says which case the player is in.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Port = ns.core.Port
local EventTopic = ns.core.EventTopic
local WowEvent = ns.core.WowEvent
local CreatureGuid = ns.adapter.CreatureGuid
-- Every unit read below goes through this: on a client with secret values a unit
-- read can come back present, typed, and raising the moment it is compared, which
-- this file does with every one of them.
local readable = ns.adapter.Readable.value

local NameplateWatch = {}
NameplateWatch.__index = NameplateWatch

function NameplateWatch.isSupported()
  return C_NamePlate ~= nil and type(C_NamePlate.GetNamePlates) == "function"
end

-- Every unit token this could be asked about, the event source first.
--
-- The tokens come from NAME_PLATE_UNIT_ADDED, which hands one over as its own
-- argument. Reading `namePlateUnitToken` off the frames GetNamePlates() returns is
-- not the same thing: in play it gave no token for any of 168 nameplates. The
-- frames are still read as a fallback for a client that does hand the token over
-- that way, and the tally says which source answered.
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
    -- Optional, and what it writes is a tally rather than a line per nameplate: a
    -- sweep runs four times a second, and the question it has to answer after the
    -- fact is which of the conditions is throwing everyone out.
    recordEvidence = options.recordEvidence,

    -- Filled by NAME_PLATE_UNIT_ADDED, emptied by its removal. A set, not a list:
    -- the client may add the same token again after a removal it never sent, and
    -- one creature must never be counted twice.
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

-- Whether this creature is in this fight, and which condition said no. Every call
-- is guarded against two failures. A client without the function answers nil,
-- read as "no" rather than raising inside a sweep that runs mid-fight; and a value
-- this addon may not read answers nil too, through `readable`, because comparing
-- it is the error. Every read here is compared on the line it is made, and the
-- guard converts rather than catches because `secret == true` does not raise in
-- the test harness, only in the client.
--
-- A verdict rather than a boolean: these are separate client questions, any one
-- of them answering wrong leaves the pull empty, and the verdict says which.
local function verdictFor(token)
  if UnitExists == nil or not readable(UnitExists(token)) then
    return "gone"
  end
  if UnitCanAttack == nil or not readable(UnitCanAttack("player", token)) then
    return "friendly"
  end
  if UnitIsDead ~= nil and readable(UnitIsDead(token)) then
    return "dead"
  end
  -- Claimed by somebody who is not you and not yours: it can still be fought and
  -- will still pay nothing, so it does not belong in a plate that estimates what
  -- this fight is worth. UnitIsTapDenied has answered in play, but only ever as an
  -- exclusion: creatures standing idle in a field read as open too, so
  -- "unclaimed" says nothing about whether a pull happened.
  if UnitIsTapDenied ~= nil and readable(UnitIsTapDenied(token)) == true then
    return "tapped"
  end
  -- The question itself, where the client can be asked it. Being on a creature's
  -- threat list is true from the moment it decides to come for you and stays true
  -- whoever it is swinging at, so it answers the tank case without knowing about
  -- groups, and it does not blink when the creature glances elsewhere for a frame.
  --
  -- UnitThreatSituation belongs to a later client than Classic Era and Burning
  -- Crusade Classic, so it is asked for rather than assumed, and the target rule
  -- below stays as the fallback. In play it has always answered, and matched far
  -- more often than "aiming at me"; both keep their own verdicts so the evidence
  -- shows which one carries the work.
  if UnitThreatSituation ~= nil then
    local ok, status = pcall(UnitThreatSituation, "player", token)
    if ok and readable(status) ~= nil then
      return "threat"
    end
  end

  -- Below the threat question on purpose: UnitAffectingCombat often reads false
  -- for a creature that already has the player on its threat list, so asked first
  -- it would throw that creature out. If you are on its list it is fighting you,
  -- whatever the flag says this frame.
  --
  -- It still earns its place as the fallback: a creature standing in a field is
  -- not in combat, so selecting, targeting or hovering it enrols nothing -- and
  -- clicking does not put you on a threat list either.
  if UnitAffectingCombat == nil or not readable(UnitAffectingCombat(token)) then
    return "idle"
  end

  if UnitIsUnit == nil then
    return "noTargetApi"
  end

  local target = token .. "target"
  if readable(UnitIsUnit(target, "player")) == true or readable(UnitIsUnit(target, "pet")) == true then
    return "mine"
  end

  -- The same fight, aimed at somebody else in it. Experience credit has nothing
  -- to do with aggro: a creature the tank is holding pays the whole group, and in
  -- a party every creature aims at the tank.
  --
  -- Still not the whole answer -- the tag decides payment, not who is being hit --
  -- but it is the half these calls can ask. `tapDenied` in the tally covers the
  -- other half: whether this client can be asked about the tag at all.
  if IsInGroup ~= nil and readable(IsInGroup()) == true then
    local prefix = (IsInRaid ~= nil and readable(IsInRaid()) == true) and "raid" or "party"
    local count = GetNumGroupMembers ~= nil and readable(GetNumGroupMembers()) or 0
    for index = 1, count do
      local member = prefix .. index
      if readable(UnitIsUnit(target, member)) == true
        or readable(UnitIsUnit(target, member .. "pet")) == true then
        return "group"
      end
    end
  end

  return "elsewhere"
end

-- "Aiming at you" is a photograph of one frame: the creature hitting the tank
-- answers no, and so does one that glanced elsewhere for half a second. Being on
-- its threat list is the thing itself. This records, for the tally only, whether
-- UnitThreatSituation is missing, raises or answers on this client.
local function threatVerdict(token)
  if UnitThreatSituation == nil then
    return "threatNoApi"
  end
  local ok, status = pcall(UnitThreatSituation, "player", token)
  if not ok then
    return "threatRaised"
  end
  return readable(status) ~= nil and "threatOn" or "threatNone"
end

-- Recorded alongside the verdict, which threat decides first, so the evidence
-- still shows what the tap check answers: on a client without threat, this says
-- whether the fallback would carry the pull.
local function tapVerdict(token)
  if UnitIsTapDenied == nil then
    return "tapNoApi"
  end
  return readable(UnitIsTapDenied(token)) == true and "tapDenied" or "tapOpen"
end

-- Called from the ticker the addon already runs, and only while a pull is open:
-- out of combat there is nothing to enrol and this costs nothing at all.
-- It reports an edge, not a level: a poll that published everything it could see
-- would say the same thing four times a second, so a creature becoming one this
-- character is fighting is the event, and continuing to be one is not.
--
-- The edge is bounded by the token's own lifetime, both ends of which the client
-- announces. Whether an engagement is news to the fight is the pull's question,
-- not this adapter's.
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
      local guid = UnitGUID ~= nil and readable(UnitGUID(token)) or nil
      local name = UnitName ~= nil and readable(UnitName(token)) or nil
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

  -- Every sweep is counted; only a sweep that says something new is sampled.
  -- The tally is already a summary and the sweep runs four times a second, so one
  -- sample per sweep would fill the ring with identical entries. The signature
  -- collapses the repeats: the counter says how often, the sample shows one.
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
