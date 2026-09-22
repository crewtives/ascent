-- Ascent - the flight recorder: a bounded log of play, kept in the saved variables.
--
-- It answers what reading the code cannot: whether a group-kill figure is
-- already inside the credited total, how often the client can name the place
-- when experience lands, whether the fatigue templates ever appear, whether a
-- message's rested figure is the bonus or the base. It never writes to the chat
-- (debug mode is the switch that prints), so it can stay on for a whole session.
-- It records facts, not conclusions: the authoritative delta and the parsed
-- figures side by side, never their difference. It is bounded: a ring of recent
-- samples ("show me one") plus counters ("how often").
--
-- It lives in app/ because it reads the client directly and correlates topics
-- from several layers.

local _, ns = ...
ns.app = ns.app or {}

local EventTopic = ns.core.EventTopic

-- Enough samples to cover a couple of levels of real play, small enough that the
-- file stays openable. Each sample is about fifteen short fields.
local DEFAULT_LIMIT = 400

-- The shape of what is written to the saved variables. Data carried from a
-- previous session is dropped when the version differs: samples from another
-- build of the recorder are not comparable, and mixing them would make one
-- counter summarise two meanings under one name.
local VERSION = 3

-- Kinds that are counted but never kept in the ring. The kind of fact decides,
-- not the volume seen at runtime: a dynamic threshold would make the same fact
-- occupy a sample in one session and not the next, and two files would stop
-- being comparable. Declared up front, a reader knows which kinds a file can
-- hold.
--
-- A kind belongs here only if it happens many times in a session and its n-th
-- occurrence says nothing the first did not. Time played and session markers
-- would otherwise fill half the ring. Nothing on the experience path qualifies,
-- however frequent: there the n-th occurrence is the case being looked for.
local COUNTER_ONLY = {
  timePlayedReceived = true,
  timePlayedRequested = true,
  timePlayedSuppressed = true,
  timePlayedUnrequested = true,
  timePlayedLate = true,
  sessionStarted = true,
  -- Four times a second while a pull is open, and its n-th identical tally says
  -- nothing the first did not. `nameplateMix` is the sample: the sweep keeps one
  -- only when the tally actually changes.
  nameplateSweep = true,
}

-- Families of counter-only kinds whose names are not known in advance. The
-- census of combat log subevents this addon does not handle is named by the
-- client's own vocabulary, and listing it here would mean this file learning
-- every line the combat log can write. Each prefix is still declared on its
-- own: this is a rule about the kind, never about volume.
local COUNTER_ONLY_PREFIX = {
  ["subevent."] = true,
  -- What the pull plate was handed, by phase and by how many creatures were in
  -- it. Named by the combination rather than enumerated, and counted rather than
  -- kept: it changes on every redraw of a live fight.
  ["plate."] = true,
}

local function isCounterOnly(kind)
  if COUNTER_ONLY[kind] then
    return true
  end
  for prefix in pairs(COUNTER_ONLY_PREFIX) do
    if kind:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local EvidenceLog = {}
EvidenceLog.__index = EvidenceLog

-- Exposed so a test can enumerate the declaration: a wrong entry would
-- otherwise only show up as a session that recorded the wrong half.
EvidenceLog.COUNTER_ONLY = COUNTER_ONLY
EvidenceLog.COUNTER_ONLY_PREFIX = COUNTER_ONLY_PREFIX
EvidenceLog.isCounterOnly = isCounterOnly

-- Where the player is, as the client answers at this instant. Read from the
-- client rather than through the player-state port: the recorder keeps the raw
-- answers, not the model the port builds on them.
local function placeNow()
  local place = {}

  local inInstance, instanceType = IsInInstance()
  place.inInstance = inInstance == true
  place.instanceType = instanceType

  if inInstance and GetInstanceInfo ~= nil then
    local name, kind, difficulty, _, maxPlayers, _, _, instanceId = GetInstanceInfo()
    place.instanceName = name
    place.instanceKind = kind
    place.instanceId = instanceId
    place.maxPlayers = maxPlayers
    place.difficulty = difficulty
  end

  place.zone = GetZoneText()
  place.subZone = GetSubZoneText()

  if C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil then
    local ok, mapId = pcall(C_Map.GetBestMapForUnit, "player")
    place.uiMapId = ok and mapId or nil
  end

  place.inGroup = IsInGroup() == true
  place.inRaid = IsInRaid() == true
  place.groupSize = GetNumGroupMembers()

  return place
end

function EvidenceLog.new(options)
  options = options or {}
  if options.bus == nil or options.clock == nil or options.playerState == nil then
    error("EvidenceLog needs a bus, a clock and a playerState", 2)
  end

  return setmetatable({
    bus = options.bus,
    clock = options.clock,
    playerState = options.playerState,
    limit = options.limit or DEFAULT_LIMIT,
    enabled = options.enabled == true,
    samples = {},
    counters = {},
    startedAt = nil,
  }, EvidenceLog)
end

function EvidenceLog:isEnabled()
  return self.enabled
end

-- Switched from the chat command without a reload, in both directions: on,
-- recording begins at the next event; off, it stops at once, so the bounded ring
-- does not rotate over the evidence the player switched it off to keep.
--
-- Both edges are written into the file, on the inside of the switch: a gap with
-- no marker cannot be told from an hour in which nothing happened.
function EvidenceLog:enable(enabled)
  enabled = enabled == true
  if enabled == self.enabled then
    return self
  end

  if not enabled then
    self:push({ kind = "recordingChanged", on = false })
  end
  self.enabled = enabled
  if enabled then
    self:start()
    self:push({ kind = "recordingChanged", on = true })
  end
  return self
end

-- The entry point for a fact the bus does not carry, taken where the code that
-- knows it runs. Kinds and fields, never a formatted sentence: prose would turn
-- the file into a chat log.
function EvidenceLog:record(kind, fields)
  if not self.enabled then
    return self
  end

  self:count(kind)

  -- Counted, never kept. Returning here rather than inside push() also skips
  -- building the sample, and placeNow() costs eight client calls.
  if isCounterOnly(kind) then
    return self
  end

  local sample = {}
  for key, value in pairs(fields or {}) do
    sample[key] = value
  end
  sample.kind = kind
  sample.place = placeNow()

  self:push(sample)
  return self
end

function EvidenceLog:count(name)
  self.counters[name] = (self.counters[name] or 0) + 1
end

-- Bounded by dropping the oldest: the last hour of play matters, not the first.
-- Append-then-trim rather than a ring buffer keeps the table in chronological
-- order, so the saved variables can hold it by reference and the file reads
-- without unwrapping. Moving 400 references per sample is cheap next to a redraw.
function EvidenceLog:push(sample)
  sample.t = self.clock:now()
  sample.level = self.playerState:level()
  sample.xp = self.playerState:xp()

  self.samples[#self.samples + 1] = sample
  while #self.samples > self.limit do
    table.remove(self.samples, 1)
  end
end

-- Every subscription below goes through this, and the flag is read at delivery,
-- not at subscribe time: a subscription outlives the switch that made it, so a
-- check made only while subscribing would never stop the recorder.
--
-- The guard sits here rather than inside push() because building push's argument
-- already costs eight client calls through placeNow(); a guard further in would
-- pay for samples it then throws away.
local function whileEnabled(self, topic, handler)
  self.bus:subscribe(topic, function(payload)
    if not self.enabled then
      return
    end
    handler(payload)
  end)
end

-- Idempotent: the chat command can switch recording on mid-session, and
-- subscribing twice would silently double every counter in the file.
function EvidenceLog:start()
  if not self.enabled or self.started then
    return self
  end
  self.started = true

  self.startedAt = self.clock:now()

  -- The authoritative amount, recorded apart from the hint: whether the two
  -- agree is the question, so they are never written as one number.
  whileEnabled(self, EventTopic.XP_DELTA_OBSERVED, function(payload)
    self:count("delta")
    self:push({
      kind = "delta",
      amount = payload.amount,
      place = placeNow(),
      restedXp = self.playerState:restedXp(),
    })
  end)

  -- The claim about where that amount came from, with everything parsed out of
  -- the client's own sentence.
  whileEnabled(self, EventTopic.XP_HINT_RECEIVED, function(payload)
    self:count("hint")
    if payload.groupBonus ~= nil then
      self:count("hint.groupBonus")
    end
    if payload.raidPenalty ~= nil then
      self:count("hint.raidPenalty")
    end
    if payload.template ~= nil then
      self:count("template." .. payload.template)
    end
    self:push({
      kind = "hint",
      hintKind = payload.kind,
      amount = payload.amount,
      creature = payload.creatureName,
      groupBonus = payload.groupBonus,
      raidPenalty = payload.raidPenalty,
      restedBefore = payload.restedBefore,
      restedAfter = payload.restedAfter,
      questId = payload.questId,
      -- The client's own sentence, verbatim next to what was parsed from it, so
      -- a reader can re-parse it by eye instead of trusting the parser.
      template = payload.template,
      raw = payload.raw,
      place = placeNow(),
    })
  end)

  -- A sentence no template claimed. Counted and kept: the counter says whether
  -- and how often this client prints something unknown, the ring shows one.
  whileEnabled(self, EventTopic.XP_LINE_UNMATCHED, function(payload)
    self:count("unmatchedLine")
    self:push({
      kind = "unmatchedLine",
      raw = payload.raw,
      at = payload.at,
      place = placeNow(),
      restedBefore = payload.restedBefore,
      restedAfter = payload.restedAfter,
    })
  end)

  -- The reconciler's verdict, the third leg after delta and claim; a
  -- disagreement between any two is a bug. The topic carries
  -- `{ gain = XpGain }`, not the gain's fields spread across the payload, and the
  -- test publishes a real XpGain so a hand-written table cannot agree with a
  -- mistaken reader.
  whileEnabled(self, EventTopic.XP_ATTRIBUTED, function(payload)
    local gain = payload and payload.gain
    self:count("attributed")
    self:count("attributed." .. tostring(gain and gain.source))
    self:push({
      kind = "attributed",
      amount = gain and gain.amount,
      source = gain and gain.source,
      groupBonus = gain and gain.groupBonus,
      raidPenalty = gain and gain.raidPenalty,
      restedBonus = gain and gain.restedBonus,
      -- How many shared the kill. Not derivable from groupBonus, which is the
      -- bonus and not the group size; without it the file cannot confirm that
      -- each kill was filed under the right size.
      sharedBy = gain and gain.sharedBy,
    })
  end)

  -- Wrapped like the verdict above: the topic carries `{ record = LevelRecord }`,
  -- and the test publishes a real LevelRecord for the same reason.
  whileEnabled(self, EventTopic.LEVEL_COMPLETED, function(payload)
    local record = payload and payload.record
    self:count("levelCompleted")
    self:push({ kind = "levelCompleted", completedLevel = record and record.level })
  end)

  -- Who the pull enrolled and from where. Both paths, a combat log line and a
  -- nameplate seen coming, publish this topic, so the file answers whether
  -- anything enrolled at all: the first question about a pull that stayed empty.
  whileEnabled(self, EventTopic.ENEMY_ENGAGED, function(payload)
    self:count("engaged")
    self:push({
      kind = "engaged",
      creature = payload and payload.name,
      guid = payload and payload.guid,
      from = payload and payload.from,
    })
  end)

  whileEnabled(self, EventTopic.REST_CHANGED, function(payload)
    self:count("restChanged")
    self:push({ kind = "restChanged", restedXp = payload and payload.restedXp })
  end)

  return self
end

-- Hands the live tables to the saved-variables store by reference, so everything
-- recorded is already in the file when the client writes it at logout: no flush
-- to call, and nothing lost to a crash beyond what the client itself loses.
--
-- It also adopts what a previous session left there, because /reload is the
-- most common thing a player does while an addon is being tested and a recorder
-- that starts empty loses the session to it. The file becomes cumulative and
-- stays bounded: the ring trims to the same limit wherever its samples came from.
--
-- `environment` is what the samples cannot say: which client, which language,
-- and the templates it carries. It is always the current session's, never the
-- carried one, so it describes the client running now.
function EvidenceLog:attachTo(store, environment)
  local carried = store.evidence

  -- The identity check guards against attaching twice (the startup path and the
  -- chat command both call this): after the first attach the stored table is
  -- this one, and adopting it would append the ring to itself.
  if type(carried) == "table" and carried.version == VERSION
    and type(carried.samples) == "table" and carried.samples ~= self.samples then
    local adopted = {}
    for _, sample in ipairs(carried.samples) do
      adopted[#adopted + 1] = sample
    end
    for _, sample in ipairs(self.samples) do
      adopted[#adopted + 1] = sample
    end
    -- In place, because self.samples may already be the store's own table from an
    -- earlier attach in this same session.
    for index = #self.samples, 1, -1 do
      self.samples[index] = nil
    end
    for _, sample in ipairs(adopted) do
      self.samples[#self.samples + 1] = sample
    end
    while #self.samples > self.limit do
      table.remove(self.samples, 1)
    end

    if type(carried.counters) == "table" then
      for name, count in pairs(carried.counters) do
        if type(count) == "number" then
          self.counters[name] = (self.counters[name] or 0) + count
        end
      end
    end

    -- Counted, not kept. The count still tells a reader that reloads explain
    -- some gaps in the timestamps, while a sample per reload would scale with
    -- the noise and crowd the evidence out of the ring.
    self:count("sessionStarted")
  end

  store.evidence = {
    version = VERSION,
    startedAt = self.startedAt,
    environment = environment,
    counters = self.counters,
    samples = self.samples,
  }
  return self
end

-- Emptied in place, never replaced: the saved-variables store holds these very
-- tables, so swapping them for new ones would silently stop recording.
function EvidenceLog:reset()
  for index = #self.samples, 1, -1 do
    self.samples[index] = nil
  end
  for name in pairs(self.counters) do
    self.counters[name] = nil
  end
  self.startedAt = self.clock:now()
  return self
end

-- A one-line summary for the chat command, so the player can see it is recording
-- without reading the file.
function EvidenceLog:summary()
  local parts = {}
  local names = {}
  for name in pairs(self.counters) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    parts[#parts + 1] = ("%s=%d"):format(name, self.counters[name])
  end
  return ("%d sample(s); %s"):format(#self.samples,
    #parts > 0 and table.concat(parts, " ") or "nothing recorded yet")
end

ns.app.EvidenceLog = EvidenceLog
