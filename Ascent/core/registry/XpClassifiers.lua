-- Ascent - the classifiers v1 ships with.
--
-- Each one owns two decisions about its channel: whether a hint came from it, and
-- what that channel is able to say. The second is the part worth reading, because
-- the five channels are not equivalent:
--
--   quest_turn_in     QUEST_TURNED_IN(questID, xpReward). No parsing, and the only
--                     channel that carries the quest id. Highest priority so that
--                     when the same turn-in is announced twice the copy with the
--                     identifier is the one that gets consumed.
--   quest_message     the system-channel echo of that same turn-in. Same source,
--                     no id. Its own priority only matters if the event was missed.
--   zone_discovery    the system message; it names the zone and pays once.
--   mob_kill          the only channel that carries a creature name, and the only
--                     one that can carry a rested, group or raid breakdown -- the
--                     reserve is spent by kills and by nothing else.
--   anonymous_line    amount and instant, never a source. Marked amount-only, so
--                     the registry refuses to let it name one.
--
-- The rested figures ride along in the kill payload rather than being read off the
-- raw hint later, so that "what this channel can tell you" stays in one place.

local _, ns = ...
ns.core = ns.core or {}

local XpSource = ns.core.XpSource
local XpHintKind = ns.core.XpHintKind

local function ofKind(kind)
  return function(hint)
    return hint.kind == kind
  end
end

local XpClassifiers = {}

XpClassifiers.QUEST_TURN_IN = {
  id = "quest_turn_in",
  priority = 400,
  matches = ofKind(XpHintKind.QUEST_TURNED_IN),
  classify = function() return XpSource.QUEST_TURNIN end,
  payload = function(hint) return { questId = hint.questId } end,
}

XpClassifiers.QUEST_MESSAGE = {
  id = "quest_message",
  priority = 350,
  matches = ofKind(XpHintKind.QUEST_MESSAGE),
  classify = function() return XpSource.QUEST_TURNIN end,
}

XpClassifiers.ZONE_DISCOVERY = {
  id = "zone_discovery",
  priority = 300,
  matches = ofKind(XpHintKind.ZONE_DISCOVERED),
  classify = function() return XpSource.EXPLORATION end,
  payload = function(hint) return { zoneName = hint.zoneName } end,
}

XpClassifiers.MOB_KILL = {
  id = "mob_kill",
  priority = 200,
  matches = ofKind(XpHintKind.KILL_MESSAGE),
  classify = function() return XpSource.MOB_KILL end,
  payload = function(hint)
    return {
      creatureName = hint.creatureName,
      restedRaw = hint.restedRaw,       -- the parenthetical, read per RestedReading
      restedBefore = hint.restedBefore, -- the reserve around the kill, for the cross-check
      restedAfter = hint.restedAfter,
      groupBonus = hint.groupBonus,
      raidPenalty = hint.raidPenalty,
    }
  end,
}

-- No classify function on purpose, and the registry enforces its absence: this
-- channel is produced by quests, probably by discoveries, and is read as a kill by
-- at least one addon in the wild. It contributes an amount and an instant, and the
-- source comes from whichever hint claims it inside the window.
--
-- It does carry a payload, though, and that is not a contradiction: naming no
-- SOURCE is not the same as naming nothing. The group and raid templates of this
-- family print "(+18 group bonus)" beside an amount and no creature, and that
-- annotation is a fact about the announcement rather than about where the
-- experience came from. Only those two fields: the rested parenthetical is read
-- per kill (RestedReading) and means nothing without one.
XpClassifiers.ANONYMOUS_LINE = {
  id = "anonymous_line",
  priority = 100,
  amountOnly = true,
  matches = ofKind(XpHintKind.ANONYMOUS_MESSAGE),
  payload = function(hint)
    return { groupBonus = hint.groupBonus, raidPenalty = hint.raidPenalty }
  end,
}

XpClassifiers.ALL = {
  XpClassifiers.QUEST_TURN_IN,
  XpClassifiers.QUEST_MESSAGE,
  XpClassifiers.ZONE_DISCOVERY,
  XpClassifiers.MOB_KILL,
  XpClassifiers.ANONYMOUS_LINE,
}

function XpClassifiers.registerAll(registry)
  for index = 1, #XpClassifiers.ALL do
    registry:register(XpClassifiers.ALL[index])
  end
  return registry
end

ns.core.XpClassifiers = XpClassifiers
