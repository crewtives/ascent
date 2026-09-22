-- Ascent - gates an expensive rebuild behind "dirty AND visible".
--
-- A hidden view does no work; when shown, it rebuilds its view-model from the
-- record. The bar only throttles its redraws through RedrawScheduler, because
-- it is cheap. The report panel's view-model is three tabs of table building
-- and sorting, so it must not rebuild at all while the panel is closed. The
-- rule is generic, so this is too.

local _, ns = ...
ns.core = ns.core or {}

local RebuildGate = {}
RebuildGate.__index = RebuildGate

-- A fresh gate starts dirty: there is no prior view-model to keep showing, so
-- the first show rebuilds instead of waiting for a change that may never come.
function RebuildGate.new()
  return setmetatable({ dirty = true, rebuilds = 0 }, RebuildGate)
end

function RebuildGate:markDirty()
  self.dirty = true
end

function RebuildGate:rebuildCount()
  return self.rebuilds
end

-- Rebuilds and returns builder()'s result only when `visible` (the caller's
-- frame:IsShown() right now) and dirty both hold. Otherwise nil, meaning "keep
-- showing what you have", not an empty view-model.
function RebuildGate:refresh(visible, builder)
  if not visible or not self.dirty then
    return nil
  end

  self.dirty = false
  self.rebuilds = self.rebuilds + 1
  return builder()
end

ns.core.RebuildGate = RebuildGate
