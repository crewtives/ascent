-- Ascent - dispatches combat-topic events to the metric collectors that declared
-- them.
--
-- The tracker never learns a collector exists: this subscribes to the bus on the
-- registry's behalf and writes into `currentRecord()`, read fresh on every event
-- and never cached, so a topic that lands after a level crossed goes to the level
-- it happened in without this module knowing about levels. A nil current record
-- (no level open: max level, or gain disabled) means nothing to attribute to, so
-- the event is dropped rather than guessed at.
--
-- EventBus already isolates a failing subscriber, but this one subscriber loops
-- over several collectors per topic, so each collector runs under its own pcall:
-- one broken collector must not stop the others from seeing the same event.

local _, ns = ...
ns.core = ns.core or {}

local Port = ns.core.Port

local CombatAggregator = {}
CombatAggregator.__index = CombatAggregator

function CombatAggregator.new(options)
  options = options or {}
  for _, required in ipairs({ "bus", "registry", "currentRecord" }) do
    if options[required] == nil then
      error("CombatAggregator needs a " .. required, 2)
    end
  end
  Port.verify(ns.core.EventBusPort, options.bus, "CombatAggregator bus")
  if type(options.currentRecord) ~= "function" then
    error("CombatAggregator needs currentRecord to be a function", 2)
  end

  local self = setmetatable({
    bus = options.bus,
    registry = options.registry,
    currentRecord = options.currentRecord,
    logger = options.logger,
    warned = {},
  }, CombatAggregator)

  self.subscriptions = {}
  for _, topic in ipairs(options.registry:topics()) do
    self.subscriptions[#self.subscriptions + 1] = options.bus:subscribe(topic, function(payload)
      self:dispatch(topic, payload)
    end)
  end

  return self
end

function CombatAggregator:dispatch(topic, payload)
  local record = self.currentRecord()
  if record == nil then
    return
  end

  for _, collector in ipairs(self.registry:collectorsFor(topic)) do
    local ok, err = pcall(collector.collect, record, payload, topic)
    if not ok and self.logger ~= nil then
      local message = ("metric collector '%s' failed on %s: %s"):format(tostring(collector.id), topic, tostring(err))
      if not self.warned[message] then
        self.warned[message] = true
        self.logger:warn(message)
      end
    end
  end
end

ns.core.CombatAggregator = CombatAggregator
