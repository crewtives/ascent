-- Ascent - which quest log reader this client can use.
--
-- Chosen by capability, never by flavour: this asks whether the API is there
-- instead of branching on `Compat.flavor()` for Forever, so a client that moves
-- its quest log without changing its name still gets a working reader. It is the
-- rule `Capabilities` applies everywhere else.
--
-- The modern reader wins where both exist: it never moves the selection in the
-- player's quest log.
--
-- A client with neither gets a reader that answers an empty log, while the
-- `quest_log` capability is registered off and the diagnostic says so. That keeps
-- the sweep, the ticker and the pending tab from each needing a nil check.

local _, ns = ...
ns.adapter = ns.adapter or {}

local ClassicQuestLogReader = ns.adapter.ClassicQuestLogReader
local ModernQuestLogReader = ns.adapter.ModernQuestLogReader

local EmptyQuestLogReader = {}
EmptyQuestLogReader.__index = EmptyQuestLogReader

function EmptyQuestLogReader.new()
  return ns.core.Port.verify(ns.core.QuestLog, setmetatable({}, EmptyQuestLogReader),
    "EmptyQuestLogReader")
end

function EmptyQuestLogReader:scan()
  return {}
end

function EmptyQuestLogReader:objectiveTally()
  return 0, 0
end

local QuestLogReader = {}

-- The implementation this client supports, or nil when it supports neither.
function QuestLogReader.pick()
  if ModernQuestLogReader.isSupported() then
    return ModernQuestLogReader
  end
  if ClassicQuestLogReader.isSupported() then
    return ClassicQuestLogReader
  end
  return nil
end

-- Whether the quest log can be read at all on this client. What the `quest_log`
-- capability probes, so that "no pending experience" and "no way to ask" are not
-- the same sentence to a player reading their own report.
function QuestLogReader.isSupported()
  return QuestLogReader.pick() ~= nil
end

function QuestLogReader.new()
  local implementation = QuestLogReader.pick()
  if implementation == nil then
    return EmptyQuestLogReader.new()
  end
  return implementation.new()
end

ns.adapter.QuestLogReader = QuestLogReader
ns.adapter.EmptyQuestLogReader = EmptyQuestLogReader
