-- A character the test can put in any state, including states that are tedious to
-- reach in game: one experience point from levelling, experience switched off, at
-- the maximum level, or on eight percent health.

local _, ns = ...
ns.fakes = ns.fakes or {}

-- Not the real experience table -- just strictly increasing, which is the property
-- that matters: a level that costs the same as the one before it would let a bug in
-- the level-crossing arithmetic pass unnoticed.
local function defaultXpForLevel(level)
  return 400 + (level - 1) * 100
end

local DEFAULTS = {
  _level = 1,
  _maxLevel = 60,
  _xp = 0,
  _xpMax = nil, -- derived from the level unless the caller pins it
  _restedXp = 0,
  _isResting = false,
  _isXpDisabled = false,
  -- Where the character is. Empty means the client cannot say, which is the state
  -- the reserved place entry exists for and the one a test would otherwise have to
  -- reach by deleting a field. Replaced wholesale by :set("place", {...}), never
  -- written into, so every fake sharing this one table is harmless.
  _place = {},
  _health = 1,
  _power = 1,
  _guid = "Player-0-TEST",
  _name = "Tester",
  _realm = "TestRealm",
  _xpForLevel = defaultXpForLevel,
}

local FakePlayerState = {}
FakePlayerState.__index = FakePlayerState

local function assertKnown(key)
  if DEFAULTS["_" .. key] == nil and key ~= "xpMax" then
    error("FakePlayerState: '" .. tostring(key) .. "' is not a field of the player state", 3)
  end
end

function FakePlayerState.new(overrides)
  local state = setmetatable({}, FakePlayerState)
  for key, value in pairs(DEFAULTS) do
    state[key] = value
  end

  local pinnedXpMax = false
  for key, value in pairs(overrides or {}) do
    assertKnown(key)
    state["_" .. key] = value
    pinnedXpMax = pinnedXpMax or key == "xpMax"
  end

  if not pinnedXpMax then
    state._xpMax = state._xpForLevel(state._level)
  end

  return ns.core.Port.verify(ns.core.PlayerState, state, "FakePlayerState")
end

function FakePlayerState:level() return self._level end
function FakePlayerState:maxLevel() return self._maxLevel end
function FakePlayerState:xp() return self._xp end
function FakePlayerState:xpMax() return self._xpMax end
function FakePlayerState:restedXp() return self._restedXp end
function FakePlayerState:isResting() return self._isResting end
function FakePlayerState:isXpDisabled() return self._isXpDisabled end
function FakePlayerState:healthFraction() return self._health end
function FakePlayerState:powerFraction() return self._power end
-- Three plain values, the way the port promises them: nothing here returns a table
-- the domain would have to know the shape of.
function FakePlayerState:place()
  return self._place.context, self._place.areaId, self._place.name
end

function FakePlayerState:guid() return self._guid end
function FakePlayerState:identity() return self._name, self._realm end

function FakePlayerState:set(field, value)
  assertKnown(field)
  self["_" .. field] = value
  return self
end

-- Gain experience the way the client would: the level rolls over when the bar
-- fills, the overflow carries into the next level, and the next level costs more.
-- A character at the maximum level, or with experience switched off, gains nothing
-- at all -- the two states the addon has to degrade into, and which a fake that
-- kept counting would hide.
function FakePlayerState:gain(amount)
  if self._isXpDisabled or self._level >= self._maxLevel then
    return self
  end

  self._xp = self._xp + amount
  while self._xp >= self._xpMax do
    self._xp = self._xp - self._xpMax
    self._level = self._level + 1

    if self._level >= self._maxLevel then
      self._xp = 0
      break
    end
    self._xpMax = self._xpForLevel(self._level)
  end

  return self
end

ns.fakes.FakePlayerState = FakePlayerState
