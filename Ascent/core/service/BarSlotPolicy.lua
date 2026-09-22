-- Ascent - what taking over the client's bar costs the player's own settings.
--
-- The bar lives either free on the screen, where the player put it, or in the
-- place of the client's own experience bar, where it inherits position and size.
-- While it does, some saved settings are inapplicable. The rule lives here so the
-- view and the options panel ask the same question and get the same answer.
--
-- Suspended is not cleared. Nothing here writes, and nothing that reads it may
-- overwrite a suspended setting with the inherited value: turning the slot off
-- gives the player back the bar they had.

local _, ns = ...
ns.core = ns.core or {}

local BarSlot = ns.core.BarSlot

local BarSlotPolicy = {}

-- Whether the bar is taking over the client's slot at all.
function BarSlotPolicy.active(slot)
  return slot == BarSlot.INSET or slot == BarSlot.REPLACE
end

-- Whether the frame the client draws around its bar stays visible. The only
-- difference between the two active slots, and the reason there are two of them.
function BarSlotPolicy.keepsClientFrame(slot)
  return slot == BarSlot.INSET
end

-- How deep the bar stands in the slot, given the level of the frame it stands in.
-- Nil when there is no slot to stand in, or when the client cannot say how deep
-- its own frame is.
--
-- The two slots differ in who draws on top. The bar is a frame of its own on
-- UIParent, and a frame that declares no level takes whatever creation order
-- gave it, so the client's frame art would land above or below the bar by
-- accident, and a loading screen or a client re-layout could swap the two.
--
--   inset   -- the client's frame stays visible and the bar goes inside it, so the
--              bar has to draw first and the frame's art over it. One level below.
--   replace -- the place belongs to the bar alone, so it draws last. One above.
--
-- A client frame already at zero has nothing below it: the bar ties with it and
-- creation order decides.
--
-- `floorLevel` is the lowest level among the frames whose art has to stay on top,
-- not the anchor's. The anchor, the client's experience bar, is made invisible;
-- what still draws in that strip is the art of the frame around it (the divisions
-- along the bar, the end caps), which belongs to the anchor's parent. One level
-- under the anchor can tie with that parent, and a tie falls to creation order.
-- Absent, the anchor's own level is used.
function BarSlotPolicy.depth(slot, clientLevel, floorLevel)
  if not BarSlotPolicy.active(slot) or type(clientLevel) ~= "number" then
    return nil
  end
  if not BarSlotPolicy.keepsClientFrame(slot) then
    return clientLevel + 1
  end
  local floor = type(floorLevel) == "number" and math.min(floorLevel, clientLevel) or clientLevel
  return math.max(0, floor - 1)
end

-- Which of the player's saved settings the slot makes inapplicable, as a table so
-- another suspended setting is a new key rather than a new return value.
function BarSlotPolicy.suspends(slot)
  local active = BarSlotPolicy.active(slot)
  -- In the client's slot every text position but inside the bar lands on the
  -- client's own interface, so textAnchor is suspended like position and size:
  -- not cleared, and handed back when the slot is turned off.
  return { position = active, size = active, textAnchor = active }
end

ns.core.BarSlotPolicy = BarSlotPolicy
