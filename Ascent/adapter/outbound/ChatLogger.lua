-- Ascent - the real Logger, printing to the default chat frame with the addon's
-- own prefix.
--
-- `warn` is the one method with a stated behaviour beyond printing: the same
-- warning is shown once, not on every recurrence -- the addon-lifecycle spec asks
-- for a single notice per failure, not a repeat on every subsequent event that
-- hits the same broken collector.
--
-- `debug` also has one: every debug line is appended to AscentCharDB.debugLog, a
-- circular buffer capped at DEBUG_LOG_LIMIT. Chat scrollback is not enough to
-- reconstruct an ordering question after the fact -- it is shared with every
-- other addon's output and gone once it scrolls past -- and the group 0 spikes
-- exist specifically to answer ordering questions. SavedVariables is the only
-- thing a WoW addon can actually write to disk with, and the client only flushes
-- it on logout/reload, so this is written to be read afterward, not tailed live.
-- This module reaches the global directly (not through the Repository port,
-- which is for the domain's own records) the same way SavedVariablesRepository
-- reaches AscentDB/AscentCharDB directly: both are adapters, and this is
-- diagnostic infrastructure, not a domain model with invariants to guard.

local ADDON_NAME, ns = ...
ns.adapter = ns.adapter or {}

local PREFIX = ADDON_NAME .. ": "
local DEBUG_LOG_LIMIT = 500

local ChatLogger = {}
ChatLogger.__index = ChatLogger

function ChatLogger.new(options)
  options = options or {}
  AscentCharDB = AscentCharDB or {}
  AscentCharDB.debugLog = AscentCharDB.debugLog or {}
  return ns.core.Port.verify(ns.core.Logger, setmetatable({
    debugEnabled = options.debug == true,
    warned = {},
  }, ChatLogger), "ChatLogger")
end

-- Every line leaves through here, which is what makes `capture` below possible
-- without a second copy of anything.
function ChatLogger:emit(message)
  if self.sink ~= nil then
    self.sink[#self.sink + 1] = message
    return
  end
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
end

-- WHAT THE PLAYER CAN HAND OVER.
--
-- The addon cannot send anything anywhere (no addon can), so a bug report is
-- whatever the player pastes. Chat text cannot be selected, so the diagnostics
-- run again with their output diverted into a table and the lines go to the copy
-- dialog instead. Diverted rather than regenerated on purpose: a second builder
-- for the same report is two reports the day somebody edits one of them.
--
-- The lines come back without the chat prefix -- it is on every line and says
-- nothing the report's own header does not.
function ChatLogger:capture(fn)
  local sink = {}
  self.sink = sink
  local ok, err = pcall(fn)
  -- Cleared before anything else can throw: a logger left diverted would look
  -- like an addon that went silent.
  self.sink = nil
  if not ok then
    -- The lines already collected are kept and the failure is appended to them.
    -- A diagnostic that dies halfway is exactly the one worth reading, and the
    -- place it stopped is the report.
    sink[#sink + 1] = "the report stopped early: " .. tostring(err)
  end
  return sink
end

function ChatLogger:info(message)
  self:emit(message)
end

function ChatLogger:warn(message)
  if self.warned[message] then
    return
  end
  self.warned[message] = true
  self:emit(message)
end

function ChatLogger:debug(message)
  if not self.debugEnabled then
    return
  end
  self:emit("[debug] " .. message)

  local log = AscentCharDB.debugLog
  log[#log + 1] = message
  if #log > DEBUG_LOG_LIMIT then
    table.remove(log, 1)
  end
end

function ChatLogger:isDebug()
  return self.debugEnabled
end

function ChatLogger:setDebug(value)
  self.debugEnabled = value == true
end

ns.adapter.ChatLogger = ChatLogger
