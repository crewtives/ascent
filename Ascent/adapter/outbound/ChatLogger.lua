-- Ascent - the real Logger, printing to the default chat frame with the addon's
-- own prefix.
--
-- `warn` shows the same warning once, not on every later event that hits the
-- same broken collector.
--
-- `debug` also appends every line to AscentCharDB.debugLog, a circular buffer
-- capped at DEBUG_LOG_LIMIT, because chat scrollback is shared with every other
-- addon and gone once it scrolls past, which is too little to reconstruct the
-- order of events afterwards. SavedVariables is the only thing an addon can
-- write to disk, and the client flushes it only on logout or /reload, so the log
-- is read afterwards, not tailed live. It reaches the global directly, not
-- through the Repository port, as SavedVariablesRepository reaches AscentDB and
-- AscentCharDB: the port is for the domain's own records, and this is diagnostic
-- infrastructure.

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

-- No addon can send anything over the network, so a bug report is whatever the
-- player pastes, and chat text cannot be selected. The diagnostics run again with
-- their output diverted into a table and the lines go to the copy dialog.
-- Diverting rather than regenerating keeps a single builder for the report.
--
-- The lines come back without the chat prefix, which the report's header makes
-- redundant.
function ChatLogger:capture(fn)
  local sink = {}
  self.sink = sink
  local ok, err = pcall(fn)
  -- Cleared before anything else can throw: a logger left diverted would look
  -- like an addon that went silent.
  self.sink = nil
  if not ok then
    -- The lines already collected are kept and the failure is appended: where a
    -- diagnostic stopped is the most useful part of the report.
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
