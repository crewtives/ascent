-- Ascent - the internal event bus.
--
-- Pure Lua, no client involved: adapters publish what happened, services and views
-- react, and neither side can reach the other. It is the seam that lets a view be
-- added without touching the tracker.
--
-- Three details that look like over-thinking until they bite:
--
--   * Topics are validated against EventTopic. A publish to a topic nobody listens
--     to is indistinguishable from a typo, and both are silent.
--   * Unsubscribing during delivery is normal (a view hides itself while handling
--     an update), so subscriptions are marked dead and compacted afterwards rather
--     than removed mid-iteration. Delivery also walks a fixed count, so a handler
--     that subscribes does not get called in the round that created it. The
--     in-flight counter is kept PER TOPIC: a single global one never returns to
--     zero for a topic that is only ever published from inside another handler,
--     which is the shape this addon actually has (adapter publishes, a service
--     publishes from that handler), and its dead entries would pile up forever.
--   * A handler that throws must not stop the rest. Errors are never swallowed
--     though: they go to the error handler if there is one, and are re-raised
--     afterwards if there is not. Nothing inside the delivery loop is allowed to
--     propagate -- including the error handler itself, which is somebody else's
--     code too -- because an escape there would leave the counter stuck above zero
--     and quietly disable compaction for the rest of the session.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local EventTopic = ns.core.EventTopic

local KNOWN_TOPICS = {}
for _, topic in Frozen.each(EventTopic) do
  KNOWN_TOPICS[topic] = true
end

local EventBus = {}
EventBus.__index = EventBus

-- onError(topic, err) is optional. Without it a failing handler still cannot stop
-- the others, but the error surfaces once delivery is done instead of vanishing.
function EventBus.new(onError)
  if onError ~= nil and type(onError) ~= "function" then
    error("EventBus.new expects an error handler function or nothing", 2)
  end

  return setmetatable({
    subscribers = {},
    dead = {},
    delivering = {},
    onError = onError,
  }, EventBus)
end

-- Legitimate cascades in this design are short: adapter -> service -> view. Deeper
-- than that means a cycle, and failing with the topic named beats a stack overflow
-- that says nothing about which topics were chasing each other.
local MAX_CASCADE = 8

local function assertTopic(topic)
  if not KNOWN_TOPICS[topic] then
    error("EventBus: '" .. tostring(topic) .. "' is not an EventTopic", 3)
  end
end

function EventBus:subscribe(topic, handler)
  assertTopic(topic)
  if type(handler) ~= "function" then
    error("EventBus: a subscriber must be a function, got " .. type(handler), 2)
  end

  local list = self.subscribers[topic]
  if not list then
    list = {}
    self.subscribers[topic] = list
    self.dead[topic] = 0
  end

  -- Sealed with the bus that made it: unsubscribing a subscription from another
  -- bus must be a no-op, not a silent success that corrupts this one's bookkeeping.
  local subscription = { topic = topic, handler = handler, bus = self }
  list[#list + 1] = subscription
  return subscription
end

-- Idempotent on purpose: teardown order is not always knowable, and making a
-- second unsubscribe an error would only invite defensive checks at every caller.
function EventBus:unsubscribe(subscription)
  if type(subscription) ~= "table" or subscription.bus ~= self or subscription.handler == nil then
    return false
  end

  subscription.handler = nil
  local topic = subscription.topic
  self.dead[topic] = (self.dead[topic] or 0) + 1

  if (self.delivering[topic] or 0) == 0 then
    self:compact(topic)
  end
  return true
end

function EventBus:compact(topic)
  local list = self.subscribers[topic]
  if not list or (self.dead[topic] or 0) == 0 or (self.delivering[topic] or 0) > 0 then
    return
  end

  local alive = {}
  for index = 1, #list do
    if list[index].handler ~= nil then
      alive[#alive + 1] = list[index]
    end
  end

  self.subscribers[topic] = alive
  self.dead[topic] = 0
end

function EventBus:publish(topic, payload)
  assertTopic(topic)

  local list = self.subscribers[topic]
  if not list then
    return 0
  end

  local inFlight = self.delivering[topic] or 0
  -- Checked before the counter moves, so the counter stays consistent even here.
  if inFlight >= MAX_CASCADE then
    error(("EventBus: '%s' is cascading more than %d deep; topics are in a cycle")
      :format(tostring(topic), MAX_CASCADE), 2)
  end
  self.delivering[topic] = inFlight + 1

  local delivered, failed, firstError = 0, false, nil
  local count = #list -- fixed: a handler that subscribes is not called this round

  for index = 1, count do
    local subscription = list[index]
    local handler = subscription.handler
    if handler then
      local ok, err = pcall(handler, payload, topic)
      if ok then
        delivered = delivered + 1
      elseif self.onError then
        -- The error handler is somebody else's code as well. If it throws, it may
        -- not take the remaining subscribers down with it.
        pcall(self.onError, topic, err)
      elseif not failed then
        -- A flag, not `firstError ~= nil`: a handler calling plain `error()` raises
        -- nil, and using nil as the sentinel would swallow exactly that case.
        failed, firstError = true, err
      end
    end
  end

  self.delivering[topic] = self.delivering[topic] - 1
  if self.delivering[topic] == 0 then
    self:compact(topic)
  end

  if failed then
    error(firstError, 0)
  end

  return delivered
end

function EventBus:subscriberCount(topic)
  assertTopic(topic)
  local list = self.subscribers[topic]
  if not list then
    return 0
  end

  local alive = 0
  for index = 1, #list do
    if list[index].handler ~= nil then
      alive = alive + 1
    end
  end
  return alive
end

ns.core.EventBus = EventBus
