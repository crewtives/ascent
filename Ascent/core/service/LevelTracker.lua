-- Ascent - the level being played, and the ones that came before it.
--
-- Everything that changes a level record over time lives here: opening it, feeding
-- it attributed experience, measuring how long the player was actually on it,
-- closing it when it fills, and reconciling what was persisted against what the
-- character actually looks like at startup.
--
-- Three ideas are worth reading before the code.
--
-- WHAT IT OBSERVED VERSUS WHAT IT DEDUCED. A record carries two marks that are not
-- data but honesty. `partial` means the addon did not watch this whole level -- it
-- was installed mid-level, or levels went by while it was not running -- so the
-- sources still add up to the client's total only because the gap was seeded into
-- UNKNOWN. `timeAnchored` means the time on this level was confirmed against the
-- server's own played-time figure rather than only measured here. Neither is shown
-- as a footnote; the panel says so.
--
-- A LEVEL THAT WENT BY UNWATCHED IS NOT DECLARED COMPLETE. Closing a record because
-- the character is now two levels higher does NOT top it up to a hundred percent.
-- The addon did not see that experience and does not pretend it did.
--
-- THE TWO TERMINAL STATES ARE NOT THE SAME. At the client's maximum level the last
-- record closes and no new one opens: there is no level after it. With experience
-- gain switched off the level in progress stays open and simply stops moving -- it
-- is frozen, not finished, and switching gain back on continues it.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local LevelRecord = ns.core.LevelRecord
local XpGain = ns.core.XpGain
local XpLedger = ns.core.XpLedger
local XpSource = ns.core.XpSource
local EventTopic = ns.core.EventTopic
local RetentionPolicy = ns.core.RetentionPolicy

local LevelTracker = {}
LevelTracker.__index = LevelTracker

function LevelTracker.new(options)
  options = options or {}

  for _, required in ipairs({ "bus", "clock", "playerState", "store" }) do
    if options[required] == nil then
      error("LevelTracker needs a " .. required, 2)
    end
  end
  Port.verify(ns.core.EventBusPort, options.bus, "LevelTracker bus")
  Port.verify(ns.core.Clock, options.clock, "LevelTracker clock")
  Port.verify(ns.core.PlayerState, options.playerState, "LevelTracker playerState")

  local tracker = setmetatable({
    bus = options.bus,
    clock = options.clock,
    playerState = options.playerState,
    store = options.store,
    retention = options.retention or RetentionPolicy.new(options.settings),

    -- Diagnostic only: optional, and everything below works the same without one.
    -- A debug line for each reconciliation branch is how a player or a smoke-test
    -- checklist can see which one fired instead of inferring it from the saved
    -- state afterward.
    logger = options.logger,

    -- What a level costs, for levels the client is not currently on. The client only
    -- reports the requirement of the level being played, and one gain can cross more
    -- than one level at low level, so the levels in between need the compatibility
    -- layer's table. Absent, those records simply do not know their requirement and
    -- accumulate without splitting.
    xpForLevel = options.xpForLevel,

    record = nil,
    sessionMark = nil,
  }, LevelTracker)

  tracker.subscriptions = {
    options.bus:subscribe(EventTopic.XP_ATTRIBUTED, function(payload)
      tracker:onAttributed(payload)
    end),
    options.bus:subscribe(EventTopic.KILL_UNREWARDED, function()
      tracker:onUnrewardedKill()
    end),
    options.bus:subscribe(EventTopic.TIME_PLAYED_SYNCED, function(payload)
      tracker:anchorTime(payload)
    end),
    options.bus:subscribe(EventTopic.SESSION_ENDED, function()
      tracker:stop()
    end),
  }

  return tracker
end

function LevelTracker:current()
  return self.record
end

-- ---------------------------------------------------------------------------
-- Time on the level
-- ---------------------------------------------------------------------------

-- Only elapsed time inside a session is folded in, which is what excludes the hours
-- the player was logged out without any heuristic having to guess at them.
function LevelTracker:accrue(now)
  if self.record == nil or self.sessionMark == nil then
    return
  end

  local elapsed = now - self.sessionMark
  if elapsed > 0 then
    self.record.playedSeconds = self.record.playedSeconds + elapsed
  end
  self.sessionMark = now
end

function LevelTracker:playedSeconds()
  if self.record == nil then
    return 0
  end

  local pending = 0
  if self.sessionMark ~= nil then
    local elapsed = self.clock:now() - self.sessionMark
    if elapsed > 0 then
      pending = elapsed
    end
  end
  return self.record.playedSeconds + pending
end

-- The server's own figure for time on this level. It corrects the drift of a local
-- clock and, more usefully, gives a true answer for the level that was already half
-- played when the addon was installed. Measurement continues from here.
function LevelTracker:anchorTime(payload)
  if self.record == nil or type(payload) ~= "table" then
    return
  end

  local seconds = payload.levelSeconds
  if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
    return
  end

  -- The server's figure is for the level the character is on NOW. Attribution settles
  -- two windows after the experience arrives, so between the client's level-up and
  -- the ledger closing this record they are not the same level, and applying it there
  -- would trade a measured level's duration for the few seconds spent on the next one
  -- -- and call the result confirmed.
  if self.record.level ~= self.playerState:level() then
    if self.logger ~= nil then
      self.logger:debug(("time anchor ignored: record level=%d client level=%d")
        :format(self.record.level, self.playerState:level()))
    end
    return
  end

  self.record.playedSeconds = seconds
  self.record.timeAnchored = true
  self.sessionMark = self.clock:now()
  if self.logger ~= nil then
    self.logger:debug(("time anchor applied: level=%d seconds=%.3f"):format(self.record.level, seconds))
  end
  self:publishUpdate()
end

-- ---------------------------------------------------------------------------
-- Opening and closing
-- ---------------------------------------------------------------------------

-- A level requirement the addon can trust, or nil. Guards against the client
-- reporting a stale 0 for a beat right after a level transition (UnitXPMax not
-- yet repopulated) -- treating that as a real requirement instead of "unknown"
-- is what let XpLedger.post's own "level requires no experience" error fire on
-- the very next gain, silently, with nothing left to redraw the bar afterwards.
local function positiveOrNil(value)
  if type(value) == "number" and value > 0 then
    return value
  end
  return nil
end

-- The requirement of a level. The client is authoritative for the level it is on;
-- for any other, only the compatibility table can answer, and not knowing is a
-- legitimate answer that simply leaves the record unable to split.
function LevelTracker:requiredFor(level)
  if level == self.playerState:level() then
    return positiveOrNil(self.playerState:xpMax())
  end
  if self.xpForLevel == nil then
    return nil
  end
  return positiveOrNil(self.xpForLevel(level))
end

function LevelTracker:openLevel(level, seedXp)
  local record = LevelRecord.new(level, self.clock:timestamp())
  record.xpRequired = self:requiredFor(level)

  if seedXp ~= nil then
    -- A level the addon did not see begin. Whatever the character already had goes
    -- in whole as unclassified -- without that seed the promise that the sources add
    -- up to the level total would be false from the first minute -- and the record
    -- says it is partial, because the time and the breakdown before now are not
    -- things this addon watched.
    record.partial = true
    -- The amount, not only the fact. Zero is recorded as zero rather than left nil:
    -- a level opened with nothing carried in WAS seeded, and saying so is what lets
    -- a surface tell it from a record too old to know either way.
    record.seededXp = seedXp
    if seedXp > 0 then
      XpLedger.post(record, XpGain.new({
        amount = seedXp, source = XpSource.UNKNOWN, at = self.clock:now(),
      }))
    end
    if self.logger ~= nil then
      self.logger:debug(("level opened seeded: level=%d unknown=%d"):format(level, seedXp))
    end
  end

  if self.logger ~= nil then
    self.logger:debug(("level opened: level=%d"):format(level))
  end

  self.record = record
  self.sessionMark = self.clock:now()
  self.store:saveCurrent(record)
  self.bus:publish(EventTopic.LEVEL_STARTED, { record = record })
  return record
end

function LevelTracker:closeLevel(record, partial)
  self:accrue(self.clock:now())
  record.completedAt = self.clock:timestamp()
  record.lastSeenAt = self.clock:now()
  if partial then
    record.partial = true
  end

  -- Trimmed before it is written, not after: the other order stores the detail the
  -- policy has just decided not to keep, and the file grows without limit while only
  -- memory stays bounded.
  self.retention:apply(record)
  self.store:saveCompleted(record)

  -- A level that has just been closed is not the level in progress. Emptying the
  -- slot matters most where nothing refills it: at the maximum level the tracker
  -- lets go of the record and logout writes nothing, so the previous snapshot would
  -- sit there and every later login would close it again over the real record.
  self.store:saveCurrent(nil)

  if self.logger ~= nil then
    self.logger:debug(("level closed: level=%d partial=%s"):format(record.level, tostring(record.partial)))
  end

  self.bus:publish(EventTopic.LEVEL_COMPLETED, { record = record })
  return record
end

function LevelTracker:isAtCap()
  return self.playerState:level() >= self.playerState:maxLevel()
end

-- ---------------------------------------------------------------------------
-- Startup reconciliation
-- ---------------------------------------------------------------------------

function LevelTracker:start()
  local player = self.playerState

  -- A record already in hand is newer than the one on disk, so this can be called
  -- again -- when experience gain comes back on, say -- without throwing away the
  -- session it has been accumulating.
  local stored = self.record
  local resumed = false
  if stored == nil then
    stored = self.store:current()
    resumed = stored ~= nil
  end

  local level = player:level()

  -- Reconciled before anything adopts the record, the frozen branch below included.
  -- A stored record for a level the character has already left is not the level in
  -- progress, and freezing it would have experience recorded into the wrong level
  -- the moment gain was switched back on.
  if stored ~= nil and stored.level ~= level then
    if self.logger ~= nil then
      self.logger:debug(("reconciliation: closing stored level %d, character now at level %d")
        :format(stored.level, level))
    end
    self:closeLevel(stored, true)
    -- Levels the addon was not running for. A record for each says "there is no
    -- data here", which the history can show; leaving a hole would be indexed the
    -- same as a level that was never played.
    for skipped = stored.level + 1, level - 1 do
      local empty = LevelRecord.new(skipped, self.clock:timestamp())
      empty.xpRequired = self:requiredFor(skipped)
      self:closeLevel(empty, true)
    end
    stored = nil
  end

  -- Frozen, not finished. The level in progress stays in progress and stops moving;
  -- seeding or closing it would record a change the character did not make. Nothing
  -- new opens while gain is off, so a character who switches it back on without a
  -- record in progress gets one when the adapter calls start() again.
  if player:isXpDisabled() then
    if self.logger ~= nil then
      self.logger:debug(("reconciliation: frozen, experience gain disabled at level %d"):format(level))
    end
    self.record = stored
    self.sessionMark = nil
    return self
  end

  -- At the cap there is no level to open. The record before it has just been closed
  -- above, or was already closed, and nothing more is recorded.
  if self:isAtCap() then
    if self.logger ~= nil then
      self.logger:debug(("reconciliation: frozen, at level cap %d"):format(level))
    end
    self.record = nil
    self.sessionMark = nil
    self.store:saveCurrent(nil)
    return self
  end

  if stored == nil then
    if self.logger ~= nil then
      self.logger:debug(("reconciliation: fresh open, no stored record: level=%d"):format(level))
    end
    self:openLevel(level, player:xp())
  else
    if self.logger ~= nil then
      self.logger:debug(("reconciliation: resuming stored record: level=%d fromStore=%s")
        :format(level, tostring(resumed)))
    end
    self:resume(stored, resumed)
  end

  return self
end

-- Pick up a record that was already for this level. Anything the character gained
-- while the addon was not watching -- a reload, a late start -- shows up as a
-- positive difference and goes where every unexplained gain goes.
function LevelTracker:resume(record, fromStore)
  local player = self.playerState

  -- Whatever has been measured so far belongs to the level whether or not this is the
  -- first time the record is being picked up. Resetting the mark below without
  -- folding it in first would throw the session away every time reconciliation ran
  -- again, which is exactly what happens when gain is switched back on mid-session.
  self:accrue(self.clock:now())

  record.xpRequired = positiveOrNil(player:xpMax())

  local difference = player:xp() - record.xpTotal
  if difference > 0 then
    XpLedger.post(record, XpGain.new({
      amount = difference, source = XpSource.UNKNOWN, at = self.clock:now(),
    }))

    -- Experience earned while the addon was not running is experience it did NOT
    -- observe, and the record has to say so. Posting it to UNKNOWN and leaving the
    -- marks alone is how the breakdown ends up claiming the addon watched this and
    -- could not classify it -- the accusation the mark exists to prevent.
    --
    -- Three cases, because what a record may claim depends on what it already knows
    -- about itself:
    --
    --   watched throughout   every point until now has a source, so the whole gap
    --                        is the gap and the figure starts here.
    --   already seeded       the gap adds to what it carried in.
    --   seeded, figure nil   written before this field existed. It cannot say how
    --                        its existing UNKNOWN divides, and naming a number now
    --                        would invent the split for everything before the gap.
    --                        It stays unable to say, which is the honest answer.
    if record.seededXp ~= nil then
      record.seededXp = record.seededXp + difference
    elseif not record.partial then
      record.seededXp = difference
    end
    record.partial = true
  end

  -- A new sitting only if the record came off disk AND the client itself restarted.
  -- The monotonic clock survives a /reload and starts again from near zero when the
  -- client does, so a value below the one saved means a different run; a record that
  -- was already in hand is this same sitting being reconciled again. The rule
  -- misreads one case -- quitting and restarting the client inside its first minute
  -- -- and that is cosmetic.
  local now = self.clock:now()
  if fromStore and (record.lastSeenAt == nil or now < record.lastSeenAt) then
    record.sessions = record.sessions + 1
  end

  self.record = record
  self.sessionMark = now
  self.bus:publish(EventTopic.LEVEL_STARTED, { record = record, resumed = true })
  return record
end

function LevelTracker:stop()
  if self.record ~= nil then
    self:accrue(self.clock:now())
    self.record.lastSeenAt = self.clock:now()
    self.store:saveCurrent(self.record)
  end
  self.sessionMark = nil
  return self
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

function LevelTracker:isRecording()
  return self.record ~= nil and not self.playerState:isXpDisabled()
end

-- Experience gain can be switched back on in the middle of a session and there is no
-- event for the instant it happens: the tracker finds out because something arrives
-- to be recorded. Measurement of the level restarts here, so the frozen stretch stays
-- uncounted -- which is the honest floor -- and the play after it is counted instead
-- of being lost along with it.
function LevelTracker:resumeMeasuring()
  if self.record ~= nil and self.sessionMark == nil then
    self.sessionMark = self.clock:now()
  end
end

function LevelTracker:onAttributed(payload)
  if not self:isRecording() or type(payload) ~= "table" or payload.gain == nil then
    return
  end
  self:resumeMeasuring()

  -- A level opened without knowing its own requirement (requiredFor returned nil
  -- -- the client had not repopulated UnitXPMax yet) does not get a second chance
  -- on its own: openLevel/resume only set xpRequired once, at open time. Without
  -- this, a record stuck at "unknown" stays stuck until the next reload, which is
  -- the "always an old number, have to reload" bug -- retried here, on the next
  -- gain, because that is the next moment the client's own data might be ready.
  if self.record.xpRequired == nil then
    self.record.xpRequired = self:requiredFor(self.record.level)
  end

  local landed = XpLedger.post(self.record, payload.gain, function(filled)
    return self:advanceFrom(filled)
  end, payload.place)

  -- At the cap the ledger stops rather than opening a level that does not exist, and
  -- hands back the record it filled. The tracker has already let go of it, and every
  -- record it closed on the way was trimmed and saved as it went.
  if self.record ~= nil then
    self.record = landed
    self.retention:apply(landed)
  end

  self:publishUpdate()
end

-- Called by the ledger when a gain fills the level. Closing the old one and opening
-- the next belongs here rather than in the ledger, which owns no clock and announces
-- nothing.
function LevelTracker:advanceFrom(filled)
  self:closeLevel(filled, false)

  local nextLevel = filled.level + 1
  if nextLevel >= self.playerState:maxLevel() then
    self.record = nil
    self.sessionMark = nil
    return nil
  end

  return self:openLevel(nextLevel, nil)
end

function LevelTracker:onUnrewardedKill()
  if not self:isRecording() then
    return
  end
  self:resumeMeasuring()

  XpLedger.countUnrewardedKill(self.record)
  self:publishUpdate()
end

function LevelTracker:publishUpdate()
  self.bus:publish(EventTopic.RECORD_UPDATED, { record = self.record })
end

ns.core.LevelTracker = LevelTracker
