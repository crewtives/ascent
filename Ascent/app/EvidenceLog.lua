-- Ascent - the flight recorder (design D45, and every open question after it).
--
-- Several things about this addon cannot be settled by reading: whether the
-- number in a group-kill parenthetical is already inside the credited total, how
-- often the client can say where the player is standing when experience lands,
-- whether the fatigue templates ever appear at all, whether the rested figure in
-- a message is the bonus or the base. Every one of them is answered by watching a
-- real player play for an hour.
--
-- So this records what happened, to the saved variables file, where it can be
-- read afterwards. Three rules shape it:
--
--   IT NEVER WRITES TO THE CHAT. The existing debug mode prints, which is fine
--   for a two-minute check and unusable for a levelling session. Evidence is a
--   separate switch for exactly that reason: it is meant to be left on while
--   playing normally, and a player should not notice it is there.
--
--   IT RECORDS FACTS, NOT CONCLUSIONS. Each sample carries the authoritative
--   delta AND the parsed figures side by side, rather than the difference between
--   them. Whoever reads the file draws the conclusion; the addon does not decide
--   in advance which of the two it believes, because that is the very thing under
--   question.
--
--   IT IS BOUNDED. A ring of the most recent samples plus counters that never
--   grow. The counters answer "how often"; the ring answers "show me one".
--
-- It lives in app/ because it reads the client directly and correlates topics
-- from several layers -- exactly the composition root's business, and nobody
-- else's.

local _, ns = ...
ns.app = ns.app or {}

local EventTopic = ns.core.EventTopic

-- Enough samples to cover a couple of levels of real play, small enough that the
-- file stays openable. Each sample is about fifteen short fields.
local DEFAULT_LIMIT = 400

-- The shape of what gets written to the saved variables. It is checked before
-- carrying anything forward from a previous session, because samples recorded by
-- a different build of this recorder are not comparable with these ones: version
-- 1 wrote every verdict blank and kept no raw lines. Dropping them on a version
-- change is the honest move; mixing them silently is how a counter ends up
-- summarising two different meanings under one name.
local VERSION = 3

-- Counting and keeping are two decisions, and the KIND of fact makes it -- not
-- the volume seen at runtime (D75). A dynamic threshold would make the evidence
-- depend on how long that session happened to run: the same fact would occupy a
-- sample one day and not the next, and two files would stop being comparable.
-- Declared up front, a reader knows before opening the file which kinds could
-- have been in it.
--
-- A kind belongs here only if it meets BOTH conditions (D76): it happens many
-- times in a session, AND its n-th occurrence says nothing the first did not.
-- Nothing on the experience path qualifies however frequent it gets -- there the
-- n-th occurrence is the case being hunted, and the volume is the whole reason
-- the ring exists.
--
-- What this fixes: of the 400 samples the session of 2026-09-21 left behind, 132
-- were time played received, 34 requested and 32 session markers. Half the file,
-- leaving 131 samples of experience -- four hours of clock turned into nine
-- minutes of readable play.
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

-- A FAMILY of counter-only kinds, for the case the declaration above cannot
-- express: a kind whose name is not known here in advance. The census of combat
-- log subevents this addon does not handle is named by the client's own
-- vocabulary, and enumerating it here would mean this file learning every line
-- the combat log can write -- which is the opposite of what the census is for.
--
-- Still a declaration and still explicit: a prefix is registered on purpose, one
-- at a time, and a kind that does not start with one is not counter-only. It is
-- not a rule about volume, which is the thing D75 refuses.
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

-- Exposed so the declaration can be enumerated by a test rather than trusted.
-- Getting a kind wrong here is not the risk; getting it wrong WITHOUT NOTICING
-- is, and it would only show up as a session that recorded the wrong half.
EvidenceLog.COUNTER_ONLY = COUNTER_ONLY
EvidenceLog.COUNTER_ONLY_PREFIX = COUNTER_ONLY_PREFIX
EvidenceLog.isCounterOnly = isCounterOnly

-- Where the player is, as the client will tell it at this instant. Read here
-- rather than through the player-state port on purpose: the port does not carry
-- a place yet (that is the next group of work), and this file exists precisely
-- to find out what the client answers before committing to a model for it.
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

-- Switched on from the chat command without a reload: recording begins at the
-- next event rather than at the next session. And switched OFF the same way --
-- which used to be a lie. `enabled` was read once, while subscribing, and never
-- again, so a recorder told to stop kept recording and kept rotating its bounded
-- ring over the very evidence the player switched it off to keep.
--
-- Both edges are written into the file, on the inside of the switch. A gap with no
-- marker either side of it cannot be told from an hour in which nothing happened,
-- and "the recorder was off" is an answer the person reading the file needs.
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

-- The door for a fact the bus does not carry: a spike's own measurement, taken
-- where the code that knows it runs. Kinds and fields, never a formatted
-- sentence -- the moment this accepts a line of prose it has become the bounded
-- chat ring it exists to replace.
function EvidenceLog:record(kind, fields)
  if not self.enabled then
    return self
  end

  self:count(kind)

  -- Counted, never kept. The tally still answers "how often"; the ring is left
  -- for what can only be understood by seeing one whole (D75). Returning here
  -- rather than inside push() also skips building the sample at all, and
  -- placeNow() costs eight client calls.
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

-- Bounded, and bounded by dropping the OLDEST: what matters is the last hour of
-- play, not the first. Written as append-then-trim rather than as a ring on
-- purpose -- the table stays in chronological order, which means it can be handed
-- to the saved variables by reference and read straight out of the file without
-- any unwrapping. Moving four hundred references once per kill is nothing next to
-- what a redraw already does.
function EvidenceLog:push(sample)
  sample.t = self.clock:now()
  sample.level = self.playerState:level()
  sample.xp = self.playerState:xp()

  self.samples[#self.samples + 1] = sample
  while #self.samples > self.limit do
    table.remove(self.samples, 1)
  end
end

-- Every subscription below goes through this, and the flag is read at DELIVERY
-- rather than at subscribe time. That distinction is the whole of `/ascent
-- evidence off`: a subscription outlives the switch that made it, so checking
-- `enabled` only while subscribing stops nothing.
--
-- Guarding here rather than inside push() is deliberate. Building push's argument
-- already costs eight client calls through placeNow(), so a guard further in would
-- pay for samples it then throws away -- and attachTo's session marker
-- legitimately goes through push while the recorder is off.
local function whileEnabled(self, topic, handler)
  self.bus:subscribe(topic, function(payload)
    if not self.enabled then
      return
    end
    handler(payload)
  end)
end

-- Idempotent, because the chat command switches recording on mid-session and
-- subscribing twice would record every event twice -- which would not fail, it
-- would quietly double every counter in the file and make the evidence wrong in
-- the one way that is hard to notice afterwards.
function EvidenceLog:start()
  if not self.enabled or self.started then
    return self
  end
  self.started = true

  self.startedAt = self.clock:now()

  -- The authoritative amount. Recorded on its own rather than merged with the
  -- hint: whether the two agree is the question, so they are never written as
  -- one number.
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
      -- The client's own sentence, kept verbatim next to what was made of it.
      -- Whoever reads the file can re-parse it by eye; without it they can only
      -- take the parser's word for what it was looking at.
      template = payload.template,
      raw = payload.raw,
      place = placeNow(),
    })
  end)

  -- What the reconciler decided in the end, which is the third leg: delta, claim,
  -- verdict. A disagreement between any two of them is a bug worth seeing.
  --
  -- The verdict arrives wrapped: the topic carries `{ gain = XpGain }`, not the
  -- gain's fields spread across the payload. Reading it flat cost the first
  -- recorded session its entire third leg -- every sample said "attributed" and
  -- nothing else -- so the shape is taken from the publisher here, and the test
  -- publishes a real XpGain rather than a hand-written table that can agree with
  -- a mistaken reader.
  -- The sentence no template claimed. Counted AND kept: the counter answers "does
  -- this client print something we do not know about, and how often", and the ring
  -- answers "show me one" -- which is the whole shape of this recorder, applied for
  -- the first time to the case it was most needed for.
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
      -- How many shared this one, which is NOT derivable from groupBonus above --
      -- that is the bonus, not the population, and telling a two-man from a
      -- five-man is the whole point. Without it the session that has to confirm
      -- each kill was filed under the right size cannot do it from the file, which
      -- is the only way anything here has ever been confirmed.
      sharedBy = gain and gain.sharedBy,
    })
  end)

  -- Wrapped exactly like the verdict above -- the topic carries `{ record }` -- and
  -- read flat here for a while, which cost the same thing in miniature: the file came
  -- back with five level completions and not one of them could say WHICH level had
  -- completed. The shape is taken from the publisher, and the test publishes a real
  -- LevelRecord.
  whileEnabled(self, EventTopic.LEVEL_COMPLETED, function(payload)
    local record = payload and payload.record
    self:count("levelCompleted")
    self:push({ kind = "levelCompleted", completedLevel = record and record.level })
  end)

  -- Who the pull enrolled and from where. The two paths -- a line of the combat
  -- log, and a nameplate seen coming -- publish the same topic on purpose, so what
  -- this answers afterwards is "did anything enrol at all", which is the first
  -- question when a player reports a pull that stayed empty.
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

-- Hands the live tables to the saved-variables store BY REFERENCE, so everything
-- recorded from here on is already in the file when the client writes it at
-- logout. No periodic flush, nothing to forget to call, and nothing lost to a
-- crash beyond what the client itself loses.
--
-- It also ADOPTS whatever a previous session left there. A recorder that starts
-- empty every time is not a flight recorder: a reload is the single most common
-- thing a player does while an addon is being worked on, and the first real
-- session was lost to exactly that -- an hour of play, including the only group
-- kill in it, replaced by three samples because /reload came before anyone read
-- the file. Carrying forward makes the file cumulative and still bounded: the
-- ring trims to the same limit whether its samples came from this session or the
-- last four.
--
-- `environment` is the part that cannot be derived from the samples: which
-- client, which language, and the templates it actually carries. Without it the
-- samples are uninterpretable by anyone who does not already know the machine
-- they came from. It is always the CURRENT session's, never the carried one: a
-- file that says which client it came from must mean the client running now.
function EvidenceLog:attachTo(store, environment)
  local carried = store.evidence

  -- The identity check is the guard against attaching twice -- the startup path
  -- and the chat command both call this -- because after the first attach the
  -- stored table IS this one, and adopting it would append the ring to itself.
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

    -- Counted, not kept (D76). The seam still matters -- without it a reader
    -- cannot tell a gap in the timestamps caused by a reload from one caused by
    -- the player walking away -- but the tally says it happened, and keeping one
    -- sample per reload is precisely what drowned the ring: a reload is the
    -- single most common thing a player does while an addon is being worked on,
    -- so this marker scaled with the noise instead of with the evidence.
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
