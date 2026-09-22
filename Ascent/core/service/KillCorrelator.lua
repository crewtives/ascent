-- Ascent - joining a creature's death to the experience it paid.
--
-- The two halves of the fact arrive by different roads and the client offers no key
-- that unites them:
--
--   chat            "Kobold Miner dies, you gain 44 experience."  -> name + amount
--   combat log      UNIT_DIED, destGUID = Creature-0-...-5644-... -> id + level
--
-- The GUID argument the chat message carries is the sender's, not the creature's,
-- so the only join available is the name and the instant. This keeps a bounded
-- buffer of recent deaths and matches a named hint against it.
--
-- Two rules:
--
--   * The join enriches; it never decides whether experience is recorded. A hint
--     with no candidate still resolves -- to a key that says the type and the level
--     are unknown. Guessing a level would quietly poison every average that key
--     feeds.
--   * With several creatures of the same name dying at once the match is ambiguous
--     by construction. It is resolved oldest-first and the error is accepted: it
--     lands on attribution by creature type and never on the totals.
--
-- The window is bidirectional because the order between UNIT_DIED and the
-- experience message is not verified on Classic Era (1.15.x) or Burning Crusade
-- Classic (2.5.x).
--
-- Every death it is given counts as one the player killed, because that is what
-- the unproductive-kill count means. The early combat-log filter lets bystander
-- deaths through (the correlator needs UNIT_DIED), so narrowing them to the
-- player's own kills belongs in the combat log router, not here.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local CreatureKey = ns.core.CreatureKey

local DEFAULT_WINDOW = 1.5
local DEFAULT_CAPACITY = 64

local KillCorrelator = {}
KillCorrelator.__index = KillCorrelator

-- Both sides of the join come from the client in the player's own language, so this
-- only has to make two spellings of the same name agree. In 5.1 `lower` folds ASCII
-- only, which is fine: both sides go through this same function, so a name the
-- client writes identically in both places still matches.
local function normalize(name)
  return (name:match("^%s*(.-)%s*$")):lower()
end

function KillCorrelator.new(options)
  options = options or {}
  local window = options.window or DEFAULT_WINDOW

  return setmetatable({
    window = window,
    -- A death has to outlive the window it can be matched in, by a wide margin. The
    -- hint that claims it may arrive a whole window late, the experience paying for
    -- that hint a window after, and the attribution of that experience settles two
    -- windows after that. Evicting a death at the matching window would make a paid
    -- kill look unpaid, and unpaid kills are a number the panel shows the player.
    retention = options.retention or window * 4,
    capacity = options.capacity or DEFAULT_CAPACITY,
    -- Diagnostic only (see Logger port): optional, nil by default, and every path
    -- below works identically without one.
    logger = options.logger,
    deaths = {},
    counters = {
      deaths = 0,          -- creatures seen dying
      matched = 0,         -- deaths a hint claimed
      unmatchedHints = 0,  -- kill hints that found no death to attach to
      expiredDeaths = 0,   -- deaths no hint ever claimed: the unproductive kills
      droppedDeaths = 0,   -- deaths pushed out of the buffer before their window ran out
    },
  }, KillCorrelator)
end

-- fields: name (required), npcId, level, at
function KillCorrelator:recordDeath(fields)
  if type(fields) ~= "table" then
    error("KillCorrelator: a death must be a table of fields, got " .. type(fields), 2)
  end
  if type(fields.name) ~= "string" or fields.name == "" then
    error("KillCorrelator: a death needs the creature's name; it is the only join available", 2)
  end

  local at = Guard.number(fields.at, "KillCorrelator death at")
  if fields.npcId ~= nil then
    Guard.positiveInteger(fields.npcId, "KillCorrelator death npcId")
  end
  if fields.level ~= nil then
    Guard.positiveInteger(fields.level, "KillCorrelator death level")
  end

  local death = {
    npcId = fields.npcId,
    level = fields.level,
    name = fields.name,
    normalized = normalize(fields.name),
    at = at,
    matched = false,
  }

  local deaths = self.deaths
  deaths[#deaths + 1] = death
  self.counters.deaths = self.counters.deaths + 1
  if self.logger ~= nil then
    self.logger:debug(("death recorded at %.3f: name=%q npcId=%s level=%s")
      :format(at, death.name, tostring(death.npcId), tostring(death.level)))
  end

  -- Only reachable by killing more than `capacity` creatures inside one window, so
  -- it is counted rather than reported as an unproductive kill: the hint for this
  -- death may simply not have arrived yet, and calling it unpaid would be a guess.
  if #deaths > self.capacity then
    local dropped = deaths[1]
    if not dropped.matched then
      self.counters.droppedDeaths = self.counters.droppedDeaths + 1
    end
    if self.logger ~= nil then
      self.logger:debug(("death dropped at %.3f: name=%q matched=%s")
        :format(dropped.at, dropped.name, tostring(dropped.matched)))
    end
    table.remove(deaths, 1)
  end

  return death
end

-- The death a hint would be matched with, without consuming it. The attribution
-- service asks this to decide whether a kill can be emitted now or has to wait out
-- the window for its other half.
function KillCorrelator:candidateFor(name, at)
  local wanted = normalize(name)
  local best

  for index = 1, #self.deaths do
    local death = self.deaths[index]
    if not death.matched and death.normalized == wanted
      and math.abs(death.at - at) <= self.window then
      if best == nil or death.at < best.at then
        best = death
      end
    end
  end

  return best
end

-- Resolve a named hint to the key its experience will be aggregated under, claiming
-- the death it matched. Always answers: with no candidate the key says the type and
-- the level are unknown, and the gain is recorded exactly the same.
function KillCorrelator:resolve(name, at)
  local death = self:candidateFor(name, at)
  if death == nil then
    self.counters.unmatchedHints = self.counters.unmatchedHints + 1
    if self.logger ~= nil then
      self.logger:debug(("hint unmatched at %.3f: name=%q"):format(at, name))
    end
    return CreatureKey.unknown(name)
  end

  death.matched = true
  self.counters.matched = self.counters.matched + 1
  if self.logger ~= nil then
    self.logger:debug(("hint matched at %.3f: name=%q npcId=%s level=%s")
      :format(at, death.name, tostring(death.npcId), tostring(death.level)))
  end
  return CreatureKey.new(death.npcId, death.level, death.name)
end

-- Drop everything past its retention and hand back the deaths nothing ever claimed.
-- Those are the creatures that died and paid nothing, which is the only signal the
-- client gives for that: a grey mob prints no message at all.
function KillCorrelator:prune(now)
  Guard.number(now, "KillCorrelator prune now")

  local deaths = self.deaths
  local expired = {}
  local write = 1

  for read = 1, #deaths do
    local death = deaths[read]
    if now - death.at <= self.retention then
      deaths[write] = death
      write = write + 1
    elseif not death.matched then
      self.counters.expiredDeaths = self.counters.expiredDeaths + 1
      expired[#expired + 1] = death
      -- Logged per creature, not only counted in expiredDeaths: this is the
      -- unproductive-kill signal, and a debug log should say which creature it was.
      if self.logger ~= nil then
        self.logger:debug(("death expired unclaimed at %.3f: name=%q"):format(death.at, death.name))
      end
    end
  end

  for index = #deaths, write, -1 do
    deaths[index] = nil
  end

  return expired
end

function KillCorrelator:pending()
  return #self.deaths
end

function KillCorrelator:diagnostics()
  local snapshot = { pending = #self.deaths }
  for key, value in pairs(self.counters) do
    snapshot[key] = value
  end
  return snapshot
end

ns.core.KillCorrelator = KillCorrelator
