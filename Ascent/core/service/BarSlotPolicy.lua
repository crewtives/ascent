-- Ascent - what taking over the client's bar costs the player's own settings.
--
-- The bar can live in two places: free on the screen, where the player put it, or
-- in the place of the client's own experience bar, where its position and its size
-- are not its own any more -- they are inherited (D47).
--
-- That inheritance makes two saved settings inapplicable while it lasts. The rule
-- for which ones lives here, in the domain, for one reason: the view can then ask
-- rather than decide, and the options panel can ask the same question and get the
-- same answer, instead of each holding its own copy of a rule that must not drift.
--
-- Suspended is not cleared (D50). Nothing here writes, and nothing that reads it is
-- allowed to overwrite a suspended setting with the value it inherited: the whole
-- point is that turning the slot off gives the player back the bar they had.

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
-- The two slots differ in WHO DRAWS ON TOP, and until this existed neither of them
-- said so. The bar is a frame of its own, hung on UIParent, and a frame that
-- declares no level takes whatever the creation order gave it -- so the client's
-- own frame art landed above the bar or below it by accident, and a loading screen
-- or anything that made the client lay its bar out again could swap the two. What
-- the player saw was a bar that sat inside the client's frame all evening and then
-- painted over it, with nothing done to cause it.
--
--   inset   -- the client's frame stays visible and the bar goes INSIDE it, so the
--              bar has to draw first and the frame's art over it. One level below.
--   replace -- the place belongs to the bar alone, so it draws last. One above.
--
-- A client frame already at zero has nothing below it: the bar ties with it and
-- the creation order decides again. That is the old behaviour, for one frame in
-- one client, rather than a second rule to get right.
-- `floorLevel` is the lowest level among the frames whose art has to stay on top,
-- and it is NOT the anchor's. The anchor is the client's experience bar, and the
-- addon makes that one invisible outright; what still draws in that strip is the
-- art of the frame AROUND it -- the divisions along the bar, the caps at its
-- ends -- which belongs to the anchor's parent and survives the anchor being
-- quieted. Going one level under the anchor therefore lands level with the parent
-- or above it, and a tie is decided by creation order, which is where this whole
-- defect lives. The floor is what makes "under the client's frame" mean the frame
-- that actually paints. Absent, the anchor's own level is used and the answer is
-- the best it can be with what it was given.
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

-- Which of the player's saved settings the slot makes inapplicable. Returned as a
-- table rather than two booleans so that a third suspended setting, if one ever
-- appears, is a key here and not a new return value at every call site.
function BarSlotPolicy.suspends(slot)
  local active = BarSlotPolicy.active(slot)
  -- textAnchor joins the other two on the owner's instruction, from the client.
  -- Where the text goes is a choice the player HAS, until the bar stands in the
  -- client's slot -- and there, every position but inside the bar lands on the
  -- client's own interface. It is suspended for the same reason position and size
  -- are: not broken, not cleared, and handed straight back on the way out.
  return { position = active, size = active, textAnchor = active }
end

ns.core.BarSlotPolicy = BarSlotPolicy
