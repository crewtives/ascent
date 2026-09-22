-- Ascent - EventBus port.
--
-- Adapters publish, services and views subscribe, and neither knows the other
-- exists. Topics are always constants from EventTopic: publishing a bare string
-- is an error, because a mistyped topic would otherwise fail silently.

local _, ns = ...
ns.core = ns.core or {}

ns.core.EventBusPort = ns.core.Port.define("EventBus", {
  subscribe = "subscribe(topic, handler) -> subscription. The handler is called "
           .. "with the topic's payload. Returns a handle to unsubscribe with.",
  unsubscribe = "unsubscribe(subscription). Idempotent: unsubscribing twice is "
             .. "not an error, because teardown order is not always knowable.",
  publish = "publish(topic, payload). Delivers to every current subscriber. A "
         .. "handler that throws must not stop the others from being called: one "
         .. "broken collector cannot be allowed to take the addon down.",
})
