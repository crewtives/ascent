-- Ascent - the registry of combat metric collectors.
--
-- Adding a metric means registering a descriptor and nothing else:
--
--   { id = MetricId.X, topics = { EventTopic.Y, ... }, collect(record, payload, topic) }
--
-- The tracker never learns a new collector exists: CombatAggregator is the only
-- thing that reads this registry, dispatching each event to whichever collectors
-- declared that topic. Unlike ClassifierRegistry there is no priority -- collectors
-- do not compete over the same event, each one writes its own corner of the
-- record, so registration order carries no meaning.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local MetricId = ns.core.MetricId
local EventTopic = ns.core.EventTopic

local MetricRegistry = {}
MetricRegistry.__index = MetricRegistry

function MetricRegistry.new()
  return setmetatable({ collectors = {}, byId = {}, byTopic = {} }, MetricRegistry)
end

local function assertDescriptor(self, collector)
  if type(collector) ~= "table" then
    error("MetricRegistry: a collector must be a table, got " .. type(collector), 3)
  end

  Guard.member(MetricId, "MetricId", collector.id, "MetricRegistry collector id")
  if self.byId[collector.id] ~= nil then
    error("MetricRegistry: '" .. tostring(collector.id) .. "' is already registered", 3)
  end

  if type(collector.topics) ~= "table" or #collector.topics == 0 then
    error("MetricRegistry: '" .. tostring(collector.id) .. "' needs a non-empty topics array", 3)
  end
  for _, topic in ipairs(collector.topics) do
    Guard.member(EventTopic, "EventTopic", topic,
      "MetricRegistry collector '" .. tostring(collector.id) .. "' topic")
  end

  if type(collector.collect) ~= "function" then
    error("MetricRegistry: '" .. tostring(collector.id) .. "' needs a collect(record, payload, topic) function", 3)
  end
end

function MetricRegistry:register(collector)
  assertDescriptor(self, collector)

  local entry = { id = collector.id, topics = collector.topics, collect = collector.collect }
  self.collectors[#self.collectors + 1] = entry
  self.byId[entry.id] = entry

  for _, topic in ipairs(entry.topics) do
    self.byTopic[topic] = self.byTopic[topic] or {}
    self.byTopic[topic][#self.byTopic[topic] + 1] = entry
  end

  return self
end

-- The collectors that declared this topic, in registration order. Never nil, so a
-- caller can always `ipairs` the result without a guard.
function MetricRegistry:collectorsFor(topic)
  return self.byTopic[topic] or {}
end

function MetricRegistry:count()
  return #self.collectors
end

-- Every topic at least one collector declared -- what CombatAggregator subscribes
-- to on the bus, so it never listens for a topic nothing registered wants.
function MetricRegistry:topics()
  local topics = {}
  for topic in pairs(self.byTopic) do
    topics[#topics + 1] = topic
  end
  return topics
end

function MetricRegistry:ids()
  local ids = {}
  for _, entry in ipairs(self.collectors) do
    ids[#ids + 1] = entry.id
  end
  return ids
end

ns.core.MetricRegistry = MetricRegistry
