-- Ascent - gates an expensive rebuild behind "dirty AND visible" (D7, extended
-- for the report panel's own stricter version of it, task 11.7).
--
-- D7 already states the rule for every view: "una vista oculta no consume
-- trabajo: al mostrarse, reconstruye su view-model desde el registro." The bar
-- (10.6) applies half of that through RedrawScheduler -- it throttles how often
-- a redraw happens, but it still calls XpBarViewModel.build on every tick
-- regardless of whether the bar is actually on screen, because the bar is cheap
-- enough that nobody asked for more. The report panel's view-model is three
-- tabs' worth of table-building and sorting, and 11.7 asks for the stronger
-- guarantee explicitly: literally zero rebuilds while the panel is closed, not
-- just fewer of them.
--
-- This is a generic little state machine, not panel-specific, because the rule
-- itself is not panel-specific -- it is D7 applied precisely.

local _, ns = ...
ns.core = ns.core or {}

local RebuildGate = {}
RebuildGate.__index = RebuildGate

-- A fresh gate starts dirty: there is no prior view-model to keep showing, so
-- the first time it becomes visible must rebuild rather than wait for a change
-- that may never come (a level with nothing new happening in it is still worth
-- showing once).
function RebuildGate.new()
  return setmetatable({ dirty = true, rebuilds = 0 }, RebuildGate)
end

function RebuildGate:markDirty()
  self.dirty = true
end

function RebuildGate:rebuildCount()
  return self.rebuilds
end

-- Rebuilds and returns builder()'s result only when both conditions hold at
-- once: `visible` is what the caller's own frame:IsShown() says right now, and
-- `dirty` is whatever changed since the last rebuild. Any other case returns
-- nil, which tells the caller "nothing new -- keep showing what you already
-- have" rather than "here is an empty view-model": a hidden or unchanged panel
-- is not the same claim as a panel with nothing in it.
function RebuildGate:refresh(visible, builder)
  if not visible or not self.dirty then
    return nil
  end

  self.dirty = false
  self.rebuilds = self.rebuilds + 1
  return builder()
end

ns.core.RebuildGate = RebuildGate
