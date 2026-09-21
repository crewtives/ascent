-- Ascent - experience pending from the quest log (group 8, quest-xp-forecast).
--
-- Three ideas from design.md's D15 that shape everything below:
--
--   THE STORED VALUE IS ALWAYS NOMINAL. The reduction for outlevelling a quest
--   is applied only when reporting (`report()`), never when storing. Persist a
--   reduced number once and the next level-up reduces it again, and the
--   forecast drifts downward with nothing to show for it (the exact bug the
--   quest-xp-forecast spec's "no se reduce dos veces" scenario exists to rule
--   out).
--   PROVENANCE IS A CHAIN, AND THE ADAPTER DECIDES ITS FIRST LINK. QuestLogReader
--   (adapter/outbound) already refuses to claim CLIENT origin when
--   `issecurevariable("GetQuestLogRewardXP")` says the function has been
--   replaced -- that check needs the client API, so it cannot live here. What
--   arrives at this service is already either CLIENT (trustworthy) or UNKNOWN;
--   this service's own job is only the SECOND link -- falling an UNKNOWN entry
--   back to a reward it learned earlier (LEARNED), never inventing a number of
--   its own.
--   ABANDONING A QUEST FORGETS IT. There is no dedicated "quest abandoned"
--   event to listen for (QUEST_ACCEPTED/QUEST_REMOVED/QUEST_LOG_UPDATE all
--   collapse into one generic "something changed, rescan" signal) -- but every
--   rescan hands over the complete, current quest log, so any learned reward
--   whose quest is simply no longer in that list has its own answer: gone.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port
local QuestForecast = ns.core.QuestForecast
local QuestXpOrigin = ns.core.QuestXpOrigin

local QuestForecastService = {}
QuestForecastService.__index = QuestForecastService

-- ---------------------------------------------------------------------------
-- The reduction ladder (8.2), and its inverse for calibration (8.6). Verified
-- against the emulator code of both eras (design.md D15): up to five levels
-- above the quest, full reward; then 80/60/40/20/10 percent per level past
-- that, floored at ten.
-- ---------------------------------------------------------------------------

local function reductionFactor(levelDifference)
  if levelDifference <= 5 then return 1.0 end
  if levelDifference == 6 then return 0.8 end
  if levelDifference == 7 then return 0.6 end
  if levelDifference == 8 then return 0.4 end
  if levelDifference == 9 then return 0.2 end
  return 0.1
end

local function reduced(nominal, levelDifference)
  return math.floor(nominal * reductionFactor(levelDifference) + 0.5)
end

-- The inverse of `reduced`. The factor is never zero, so this always has an
-- answer; it is lossy the same way any inverse of a floor() is, which is the
-- rounding noise the spec's own calibration exists to absorb, not to erase.
local function nominalFrom(received, levelDifference)
  return math.floor(received / reductionFactor(levelDifference) + 0.5)
end

-- Shared by report() (which sums this) and entries() (which shows it
-- per-quest): nil for an unknown reward -- never a fabricated number -- and
-- unreduced when the quest's own level is not known (isReducible() false),
-- the same "no level to reduce by" honesty QuestForecast:isReducible()
-- documents.
local function adjustedRewardFor(characterLevel, forecast)
  if not forecast:isKnown() then
    return nil
  end
  local diff = forecast:isReducible() and (characterLevel - forecast.questLevel) or 0
  return reduced(forecast.reward, diff)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- options: playerState, repository (both ports), and `scan` -- a plain
-- function, not a port, returning the array of QuestForecast entries the
-- current quest log holds (adapter/outbound/QuestLogReader.lua's own shape).
-- A function rather than the reader itself for the same reason LevelTracker's
-- `xpForLevel` is a function and not a port: this needs one call signature and
-- nothing about the reader's own construction, so a closure is enough and
-- keeps this file from ever having to know the adapter type exists.
-- `logger` is optional (diagnostics only, as in WowEventRouter/CombatLogRouter).
function QuestForecastService.new(options)
  options = options or {}
  for _, required in ipairs({ "playerState", "repository", "scan" }) do
    if options[required] == nil then
      error("QuestForecastService needs a " .. required, 2)
    end
  end
  Port.verify(ns.core.PlayerState, options.playerState, "QuestForecastService playerState")
  Port.verify(ns.core.Repository, options.repository, "QuestForecastService repository")

  local service = setmetatable({
    playerState = options.playerState,
    repository = options.repository,
    scan = options.scan,
    logger = options.logger,

    -- Persisted across reloads (8.4): questId -> nominal reward, learned from
    -- the quest dialogue. `current` is the opposite -- rebuilt fresh on every
    -- scan, never itself persisted, because questLevel/complete belong to the
    -- live quest log, not to anything worth remembering between sessions.
    learned = options.repository:questRewards(),
    current = {},
    previous = {},

    -- 8.3's cadence: dirty until the first scan, then only after markDirty();
    -- scanning guards against a scan somehow triggering another one before the
    -- first has returned.
    dirty = true,
    scanning = false,
  }, QuestForecastService)

  return service
end

function QuestForecastService:markDirty()
  self.dirty = true
end

-- ---------------------------------------------------------------------------
-- Reconciling a fresh sweep (8.5's provenance chain, and the abandon-forgets
-- rule above)
-- ---------------------------------------------------------------------------

function QuestForecastService:reconcile(freshList)
  local rebuilt = {}
  -- Whatever was learned for a quest no longer in the fresh sweep is gone:
  -- the quest log no longer knows it, so neither does this cache. Built up
  -- fresh here rather than deleting from `self.learned` in place, so a quest
  -- simply missing from this particular sweep (should not happen -- the
  -- reader walks the whole log -- but nothing proves it never will) forgets
  -- it rather than the cache silently keeping stale entries forever.
  local stillLearned = {}

  for _, fresh in ipairs(freshList) do
    local questId = fresh.questId

    if fresh.origin == QuestXpOrigin.CLIENT then
      -- The adapter already vouches for this one; nothing to fall back to.
      rebuilt[questId] = fresh
    else
      local learnedReward = self.learned[questId]
      if learnedReward ~= nil then
        rebuilt[questId] = QuestForecast.new({
          questId = questId, questLevel = fresh.questLevel, objectives = fresh.objectives,
          reward = learnedReward, origin = QuestXpOrigin.LEARNED, complete = fresh.complete,
        })
        stillLearned[questId] = learnedReward
      else
        rebuilt[questId] = fresh -- already QuestXpOrigin.UNKNOWN
      end
    end
  end

  self.learned = stillLearned
  self.repository:saveQuestRewards(self.learned)

  -- Kept for exactly one reader: calibrate, when a rescan lands between a turn-in
  -- and the reward arriving. The scan runs off a throttled ticker and the two
  -- events have been measured arriving milliseconds apart, so without this the
  -- forecast that was on screen is simply gone by the time anyone asks what it was.
  self.previous = self.current
  self.current = rebuilt

  if self.logger ~= nil then
    local counts = { [QuestXpOrigin.CLIENT] = 0, [QuestXpOrigin.LEARNED] = 0, [QuestXpOrigin.UNKNOWN] = 0 }
    for _, forecast in pairs(rebuilt) do
      counts[forecast.origin] = counts[forecast.origin] + 1
    end
    self.logger:debug(("scan reconciled: client=%d learned=%d unknown=%d")
      :format(counts[QuestXpOrigin.CLIENT], counts[QuestXpOrigin.LEARNED], counts[QuestXpOrigin.UNKNOWN]))
  end
end

-- 8.3: at most one scan-and-reconcile per call, and only when something
-- actually changed since the last one. The reentrancy guard is not
-- theoretical -- `QuestLogReader:scan()` drives `SelectQuestLogEntry` across
-- the whole log, and nothing in this addon has verified that doing so cannot
-- itself fire a quest-log event synchronously; if it ever does, this refuses
-- to scan again from inside its own scan rather than trusting that it can't.
function QuestForecastService:tick()
  if self.scanning or not self.dirty then
    return false
  end

  self.scanning = true
  self.dirty = false
  local ok, err = pcall(function() self:reconcile(self.scan()) end)
  self.scanning = false

  if not ok then
    error(err, 0)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Learning a reward from the quest dialogue (8.4), and calibrating one
-- against the real payout of a turn-in (8.6)
-- ---------------------------------------------------------------------------

-- Called by whatever future adapter code reads GetRewardXP() while a quest's
-- dialogue is open (design.md D15's "level 2" of the provenance chain) -- this
-- service only owns the cache and its persistence, not how a reward gets read.
function QuestForecastService:learn(questId, reward)
  self.learned[questId] = reward
  self.repository:saveQuestRewards(self.learned)

  if self.logger ~= nil then
    self.logger:debug(("learn: questId=%s reward=%s"):format(tostring(questId), tostring(reward)))
  end

  -- Visible immediately rather than waiting for the next scheduler tick: a
  -- reward the player just saw in a quest dialogue should not wait up to a
  -- redraw cycle to show up as pending, and CLIENT origin (if this service
  -- already had one) always outranks what was just learned.
  local existing = self.current[questId]
  if existing == nil or existing.origin ~= QuestXpOrigin.CLIENT then
    self.current[questId] = QuestForecast.new({
      questId = questId,
      questLevel = existing and existing.questLevel or nil,
      reward = reward, origin = QuestXpOrigin.LEARNED,
      complete = existing and existing.complete or false,
    })
  end
end

-- Called when QUEST_COMPLETED carries a real xpReward (WowEventRouter already
-- guards against a missing/invalid one before publishing). Reconstructs the
-- nominal reward from what was actually paid and the level it was paid at,
-- and persists THAT -- never the received (possibly already-reduced) figure --
-- which is what keeps a calibrated quest from being reduced twice.
-- Returns the calibration record: what the panel was SHOWING for this quest, where
-- that figure came from, and what the client actually paid. Task 8.7 asks for
-- twenty of these from a real session, and until now there was nothing to collect.
--
-- The old logging here answered a different question. It was gated on the quest
-- already being in `learned`, so it compared the value the dialogue itself had just
-- taught the addon against the payout -- a quest whose reward came from the CLIENT
-- and was never learned produced nothing at all, and that is precisely the
-- provenance spike 0.5 exists to check. It compares the SHOWN figure now.
--
-- Built before `learn`, and that ordering is the whole of its honesty: `learn`
-- overwrites `self.current[questId]` with a forecast derived from the payout, so a
-- record built afterwards would be comparing the payout with itself.
function QuestForecastService:calibrate(questId, receivedReward)
  local forecast = self.current[questId] or self.previous[questId]
  -- A forecast lost to a rescan between the turn-in and this call is not the same
  -- as one that was never there, and it must not read as a perfect prediction: with
  -- no forecast, questLevel falls back to the character's own level, diff becomes
  -- zero and nominal equals received. Flagged so the session can discount it.
  local stale = self.current[questId] == nil and forecast ~= nil
  local questLevel = forecast and forecast.questLevel or self.playerState:level()
  local characterLevel = self.playerState:level()
  local diff = characterLevel - questLevel
  local nominal = nominalFrom(receivedReward, diff)

  local shown = forecast ~= nil and adjustedRewardFor(characterLevel, forecast) or nil
  local record = {
    questId = questId,
    shown = shown,
    reward = forecast ~= nil and forecast.reward or nil,
    origin = forecast ~= nil and forecast.origin or nil,
    received = receivedReward,
    nominal = nominal,
    questLevel = forecast ~= nil and forecast.questLevel or nil,
    characterLevel = characterLevel,
    -- Derived the way the panel derives it, through the forecast's own
    -- reducibility, rather than from the fallback `diff` above: otherwise a quest
    -- with no known level records a factor that came from a different branch than
    -- the number the player was shown.
    reducible = forecast ~= nil and forecast:isReducible() or false,
    stale = stale,
  }

  if self.logger ~= nil then
    self.logger:debug(("calibrate: questId=%s shown=%s received=%s nominal=%s origin=%s")
      :format(tostring(questId), tostring(shown), tostring(receivedReward),
        tostring(nominal), tostring(record.origin)))
  end

  self:learn(questId, nominal)
  return record
end

-- ---------------------------------------------------------------------------
-- Reporting (8.1, 8.2)
-- ---------------------------------------------------------------------------

-- { total, readyTotal, unknownCount }. total/readyTotal are always the
-- nominal reward run through the reduction ladder at the CURRENT character
-- level -- recomputed on every call, never cached, which is what makes a
-- level-up change the answer without this service having to notice the level
-- changed (the quest-xp-forecast spec's own "El personaje sube de nivel"
-- scenario).
function QuestForecastService:report()
  local unknownCount = 0
  for _, forecast in pairs(self.current) do
    if not forecast:isKnown() then
      unknownCount = unknownCount + 1
    end
  end

  if self.playerState:isXpDisabled() or self.playerState:level() >= self.playerState:maxLevel() then
    return { total = 0, readyTotal = 0, unknownCount = unknownCount }
  end

  local characterLevel = self.playerState:level()
  local total, readyTotal = 0, 0

  for _, forecast in pairs(self.current) do
    local amount = adjustedRewardFor(characterLevel, forecast)
    if amount ~= nil then
      total = total + amount
      if forecast:isReadyToTurnIn() then
        readyTotal = readyTotal + amount
      end
    end
  end

  return { total = total, readyTotal = readyTotal, unknownCount = unknownCount }
end

-- Per-quest detail for the pending-xp tab (11.5): unlike report()'s total, this
-- stays honest about what is known even at the cap or with xp disabled -- it
-- always runs the ladder, it just does not hide behind report()'s own
-- zero-everything special case. Sorted descending by adjustedReward, unknown
-- rewards last, ties (including two unknowns) broken by questId ascending: a
-- deterministic array a UI can render directly, never the internal map.
function QuestForecastService:entries()
  local characterLevel = self.playerState:level()
  local result = {}

  for questId, forecast in pairs(self.current) do
    result[#result + 1] = {
      questId = questId,
      questLevel = forecast.questLevel,
      objectives = forecast.objectives,
      reward = forecast.reward,
      origin = forecast.origin,
      complete = forecast.complete,
      adjustedReward = adjustedRewardFor(characterLevel, forecast),
    }
  end

  table.sort(result, function(a, b)
    local aKnown, bKnown = a.adjustedReward ~= nil, b.adjustedReward ~= nil
    if aKnown ~= bKnown then
      return aKnown
    end
    if aKnown and a.adjustedReward ~= b.adjustedReward then
      return a.adjustedReward > b.adjustedReward
    end
    return a.questId < b.questId
  end)

  return result
end

ns.core.QuestForecastService = QuestForecastService
