-- Ascent - QuestLog port.
--
-- Two implementations that share their result and nothing else. Classic Era and
-- Burning Crusade Classic read the quest log by selecting an entry
-- (`SelectQuestLogEntry`) and asking about the selection; World of Warcraft:
-- Forever asks `C_QuestLog` about a quest id and never touches what the player
-- has selected.

local _, ns = ...
ns.core = ns.core or {}

ns.core.QuestLog = ns.core.Port.define("QuestLog", {
  scan = "scan(logger?, recordEvidence?) -> array of QuestForecast, one per accepted "
      .. "quest, headers excluded, in the log's own order. Empty when the log is "
      .. "empty; never nil. A quest whose reward the reader cannot vouch for still "
      .. "appears, with its origin set to UNKNOWN rather than a plausible number. "
      .. "Both arguments are diagnostic and optional: with a logger the sweep says "
      .. "what it read, with a recorder it writes one sample for the whole sweep. "
      .. "The player's own quest log SHALL look the same after a scan as before it.",
  objectiveTally = "objectiveTally() -> read, seen. Kill objectives this reader "
                .. "parsed, against those the client typed as kills. They can only "
                .. "differ when the client words its objectives in a way the reader "
                .. "does not match, which is the one thing that tells a broken "
                .. "template apart from a quest that asks for feathers.",
})
