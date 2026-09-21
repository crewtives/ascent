-- A bus that both delivers and remembers, so a test can assert what a service
-- announced without reaching inside it.
--
-- Written standalone rather than wrapping the real bus on purpose: if the real one
-- has a bug, the suite should show it rather than inherit it. Standalone does not
-- mean laxer, though: where the port states a behaviour -- isolating a handler that
-- throws, rejecting a topic that is not a constant, rejecting a handler that is not
-- callable -- this double matches it. A double that is more forgiving than the real
-- thing makes every test that uses it a little bit of a lie.

local _, ns = ...
ns.fakes = ns.fakes or {}

local Frozen = ns.core.Frozen

local KNOWN_TOPICS = {}
for _, topic in Frozen.each(ns.core.EventTopic) do
  KNOWN_TOPICS[topic] = true
end

local RecordingEventBus = {}
RecordingEventBus.__index = RecordingEventBus

function RecordingEventBus.new()
  local bus = setmetatable({
    published = {},
    subscribers = {},
    errors = {},
  }, RecordingEventBus)

  return ns.core.Port.verify(ns.core.EventBusPort, bus, "RecordingEventBus")
end

local function assertTopic(topic)
  if not KNOWN_TOPICS[topic] then
    error("RecordingEventBus: '" .. tostring(topic) .. "' is not an EventTopic", 3)
  end
end

function RecordingEventBus:subscribe(topic, handler)
  assertTopic(topic)
  if type(handler) ~= "function" then
    error("RecordingEventBus: a subscriber must be a function, got " .. type(handler), 2)
  end

  local list = self.subscribers[topic] or {}
  self.subscribers[topic] = list
  local subscription = { topic = topic, handler = handler, bus = self }
  list[#list + 1] = subscription
  return subscription
end

function RecordingEventBus:unsubscribe(subscription)
  if type(subscription) ~= "table" or subscription.bus ~= self or subscription.handler == nil then
    return false
  end
  subscription.handler = nil
  return true
end

function RecordingEventBus:publish(topic, payload)
  assertTopic(topic)
  self.published[#self.published + 1] = { topic = topic, payload = payload }

  local list = self.subscribers[topic] or {}
  local delivered, failed, firstError = 0, false, nil

  for index = 1, #list do
    local handler = list[index].handler
    if handler then
      local ok, err = pcall(handler, payload, topic)
      if ok then
        delivered = delivered + 1
      else
        -- Recorded as well as isolated, so a test can assert that something failed
        -- without having to reach inside the service that failed.
        self.errors[#self.errors + 1] = { topic = topic, err = err }
        if not failed then
          failed, firstError = true, err
        end
      end
    end
  end

  if failed then
    error(firstError, 0)
  end
  return delivered
end

-- Everything published on a topic, in order.
function RecordingEventBus:payloadsFor(topic)
  assertTopic(topic)
  local found = {}
  for index = 1, #self.published do
    if self.published[index].topic == topic then
      found[#found + 1] = self.published[index].payload
    end
  end
  return found
end

function RecordingEventBus:countOf(topic)
  return #self:payloadsFor(topic)
end

function RecordingEventBus:lastOn(topic)
  local all = self:payloadsFor(topic)
  return all[#all]
end

function RecordingEventBus:topicsInOrder()
  local order = {}
  for index = 1, #self.published do
    order[index] = self.published[index].topic
  end
  return order
end

function RecordingEventBus:reset()
  self.published = {}
  self.errors = {}
  return self
end

ns.fakes.RecordingEventBus = RecordingEventBus
