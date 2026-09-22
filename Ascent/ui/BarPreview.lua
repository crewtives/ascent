-- Ascent - a bar to look at while you change how it looks.
--
-- Built on BarRenderer alone, so it has no saved position, drag, scale or
-- hiding of its own and cannot move or hide the real bar. Its shares come from
-- XpBarViewModel, the same call the real bar makes. The sample level is handed
-- in from the demo driver, the one module that scripts a synthetic level.
-- Two sizes: the animated one at the top of the options panel, and the static
-- swatches of the skin gallery.

local _, ns = ...
ns.ui = ns.ui or {}

local XpBarViewModel = ns.core.XpBarViewModel
local BarTween = ns.core.BarTween
local BarChannel = ns.core.BarChannel
local BarRenderer = ns.ui.BarRenderer

local function channelIds()
  local ids = {}
  for _, channel in ipairs(BarChannel) do
    ids[#ids + 1] = channel.id
  end
  return ids
end

local BarPreview = {}
BarPreview.__index = BarPreview

-- `options`: parent, width, height, animated (false for a gallery swatch), and
-- `sample` -- a level to draw, as `{ record, restedXp, questPending }`.
function BarPreview.new(options)
  options = options or {}
  if options.parent == nil then
    error("BarPreview needs a parent frame", 2)
  end
  if options.sample == nil or options.sample.record == nil then
    error("BarPreview needs a sample level to draw", 2)
  end

  local frame = CreateFrame("Frame", nil, options.parent)
  frame:SetSize(options.width or 240, options.height or 20)

  local self = setmetatable({
    frame = frame,
    animated = options.animated ~= false,
    renderer = BarRenderer.new({
      parent = frame,
      width = options.width or 240,
      height = options.height or 20,
    }),
    tween = BarTween.new({ channels = channelIds() }),
    sample = options.sample,
  }, BarPreview)

  self.renderer:setSize(options.width or 240, options.height or 20)
  return self
end

-- `showQuestPending` is true whatever the player's setting says: the preview
-- shows every channel the bar can draw, so each one can be seen while styled.
function BarPreview:shares()
  return XpBarViewModel.shares(XpBarViewModel.build(self.sample.record, {
    restedXp = self.sample.restedXp,
    questPending = self.sample.questPending,
    showQuestPending = true,
  }))
end

-- Applies an appearance and repaints. `motion` of 0, the default for a gallery
-- swatch, lands on the final state at once: the path the real bar takes with
-- motion turned off.
function BarPreview:apply(appearance, motion)
  self.renderer:applyAppearance(appearance)
  self.tween:setTarget(self:shares(), self.animated and (motion or 1) or 0)
  self:paint()
  return self
end

function BarPreview:paint()
  self.renderer:draw(self.tween:boundaries())
  return self
end

function BarPreview:tick(elapsed)
  if not self.animated then
    return false
  end
  if not self.tween:advance(elapsed) then
    return false
  end
  self:paint()
  return true
end

-- Replays the move from empty to full, to show the current motion settings.
function BarPreview:replay(motion)
  self.tween:setTarget({}, 0)
  self.tween:setTarget(self:shares(), motion or 1)
  self:paint()
  return self
end

function BarPreview:setText(value)
  self.renderer:setText(value)
  return self
end

function BarPreview:setPoints(...)
  self.frame:ClearAllPoints()
  self.frame:SetPoint(...)
  return self
end

ns.ui.BarPreview = BarPreview
