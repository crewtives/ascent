-- Ascent - what one accepted quest is expected to pay out.
--
-- The stored reward is always the full, unreduced value. The reduction for
-- handing in a quest far below your level is applied when reporting, never when
-- storing: a reduced value stored once is reduced again at the next level-up,
-- and the forecast drifts downwards.
--
-- `reward = nil` and `reward = 0` are different answers. Nil means no trustworthy
-- source had a number, and those quests are counted and reported rather than
-- silently treated as worthless.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local Stored = ns.core.Stored
local Packed = ns.core.Packed
local QuestXpOrigin = ns.core.QuestXpOrigin

local QuestForecast = {}
QuestForecast.__index = QuestForecast

-- fields: questId, questLevel, title (optional), objectives (optional),
-- reward (nominal, optional), origin, complete
function QuestForecast.new(fields)
  if type(fields) ~= "table" then
    error("QuestForecast.new expects a table of fields", 2)
  end

  local reward = fields.reward
  if reward ~= nil then
    Guard.nonNegativeInteger(reward, "QuestForecast.reward")
  end

  local origin = Guard.member(QuestXpOrigin, "QuestXpOrigin", fields.origin, "QuestForecast.origin")
  if reward == nil and origin ~= QuestXpOrigin.UNKNOWN then
    error("QuestForecast: a quest with no reward must have origin UNKNOWN", 2)
  end
  if reward ~= nil and origin == QuestXpOrigin.UNKNOWN then
    error("QuestForecast: a quest with a reward must say where it came from", 2)
  end

  return setmetatable({
    questId = Guard.positiveInteger(fields.questId, "QuestForecast.questId"),
    questLevel = fields.questLevel and Guard.positiveInteger(fields.questLevel, "QuestForecast.questLevel"),
    -- What the sweep read, carried only as far as whoever asked for the sweep:
    -- the directory that keeps names is fed from there, and nothing downstream of
    -- this model reads it. Outside identity for the same reason the creature's
    -- name is -- a title is localized -- and deliberately not written by
    -- `toStored` below, which costs nothing: a forecast is rebuilt from a fresh
    -- sweep every time the quest log changes.
    title = type(fields.title) == "string" and fields.title ~= "" and fields.title or nil,
    -- The kill objectives still open, straight from the sweep. Like `complete`
    -- and unlike the reward, they describe the quest log as it is right now, so
    -- they are rebuilt on every sweep and never written down.
    objectives = fields.objectives,
    reward = reward,
    origin = origin,
    complete = fields.complete == true,
  }, QuestForecast)
end

function QuestForecast.unknown(questId, questLevel)
  return QuestForecast.new({
    questId = questId,
    questLevel = questLevel,
    origin = ns.core.QuestXpOrigin.UNKNOWN,
  })
end

function QuestForecast:isKnown()
  return self.reward ~= nil
end

function QuestForecast:isReadyToTurnIn()
  return self.complete
end

-- The reduction for out-levelling a quest needs the quest's own level, and that is
-- not always available: a reward learned from the quest dialogue arrives before the
-- quest is in the log. Without it the quest is reported at its full value and says
-- so, rather than being reduced by a level nobody knows.
function QuestForecast:isReducible()
  return self.questLevel ~= nil
end


-- questId, questLevel, reward, origin, complete. A reward of zero is written as a
-- zero and an absent one as nothing, because those are different answers.
function QuestForecast:toStored()
  return Packed.join({
    self.questId,
    self.questLevel or false,
    self.reward or false,
    self.origin,
    self.complete,
  })
end

function QuestForecast.restore(stored)
  if type(stored) ~= "string" then
    return nil
  end

  local fields = Packed.split(stored)

  local questId = Stored.positiveInteger(Packed.number(fields, 1))
  if questId == nil then
    return nil
  end

  local reward = Stored.count(Packed.number(fields, 3), nil)
  local origin = Stored.member(QuestXpOrigin, Packed.text(fields, 4), QuestXpOrigin.UNKNOWN)

  -- The constructor's invariant, restated rather than enforced. Stored data that
  -- claims a reward with no provenance, or a provenance with no reward, disagrees
  -- with itself, and is read as unknown.
  if reward == nil then
    origin = QuestXpOrigin.UNKNOWN
  elseif origin == QuestXpOrigin.UNKNOWN then
    reward = nil
  end

  return QuestForecast.new({
    questId = questId,
    questLevel = Stored.positiveInteger(Packed.number(fields, 2)),
    reward = reward,
    origin = origin,
    complete = Packed.flag(fields, 5),
  })
end

ns.core.QuestForecast = QuestForecast
