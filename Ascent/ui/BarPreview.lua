-- Ascent - a bar to look at while you change how it looks (tasks 7.2, 7.3).
--
-- No addon in the ecosystem shows you the bar while you configure it; you pick a
-- texture from a dropdown and go outside to see what you did. This is the piece
-- that closes that, and it exists at all because of design D34: the renderer was
-- split from the compositor precisely so a second bar could be built that has no
-- saved position, no drag, no scale and no ability to hide itself. A preview
-- cannot be allowed to move or hide the real bar.
--
-- It derives its channel shares through core's own XpBarViewModel, the same call
-- the real bar makes, so the preview cannot drift into showing something the bar
-- would never show.
--
-- IT DOES NOT OWN THE LEVEL IT DRAWS (7.3). The sample is handed in, and the
-- composition root takes it from the demo driver -- the module that already
-- scripts a synthetic level, and the only one that should. A sample declared in
-- here instead would be a second synthetic level to keep level with the first by
-- hand, and it would drift the first time either changed.
--
-- Two sizes of the same thing: the big one at the top of the options panel, which
-- animates and replays events, and the small ones in the skin gallery, which are
-- static and exist only to answer "what does this one look like".

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

-- `showQuestPending` is true whatever the player's own setting says: this bar
-- exists to show what the bar CAN draw while they are choosing how it looks, and
-- a channel hidden by a setting is a channel they cannot see themselves style.
function BarPreview:shares()
  return XpBarViewModel.shares(XpBarViewModel.build(self.sample.record, {
    restedXp = self.sample.restedXp,
    questPending = self.sample.questPending,
    showQuestPending = true,
  }))
end

-- Applies an appearance and repaints. `motion` of 0 -- the default for a gallery
-- swatch -- lands on the final state with no animation at all, which is the same
-- code path the real bar takes when the player turns motion off.
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

-- Replays the move from empty to full, so the player can see the motion settings
-- they just changed without going outside to kill something.
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
