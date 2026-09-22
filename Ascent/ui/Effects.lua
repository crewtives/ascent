-- Ascent - the shared vocabulary of things that happen once.
--
-- The drawing half of core/constants/Appearance.lua's `effects` block: given a
-- resolved effect spec and a frame, it builds the textures and animation the
-- spec describes, knowing nothing of pulls, bars or skins.
--
-- The techniques are reverse-engineered from LS: Toasts; no code or asset of
-- that addon is used. The art is the client's own
-- (Interface\AchievementFrame\UI-Achievement-Alert-Glow). An AnimationGroup runs
-- on the C side, so a playing effect costs no Lua per frame, unlike BarTween.
-- "Particles" are a few textures with different start delays.
--
-- Animation groups and SetTexCoord's eight-argument form are newer than the
-- original client; a missing one gives a static effect or none, never a frame
-- that fails to build. A texture path that does not resolve draws nothing.
-- Durations arrive already multiplied by the player's motion scale, so a scale
-- of zero makes `play()` a no-op through the same code path.

local _, ns = ...
ns.ui = ns.ui or {}

local GlowKind = ns.core.GlowKind
local SweepKind = ns.core.SweepKind
local BurstKind = ns.core.BurstKind

-- The client's own alert art. Two regions of one file: a wide soft bloom and a
-- small bright lozenge. Both are drawn additively, so they brighten whatever is
-- underneath instead of covering it.
local ALERT_GLOW = "Interface\\AchievementFrame\\UI-Achievement-Alert-Glow"
local GLOW_COORDS = { 5 / 512, 395 / 512, 5 / 256, 167 / 256 }
local SHINE_COORDS = { 403 / 512, 465 / 512, 14 / 256, 62 / 256 }

-- The mote: the four-pointed star the client has drawn on finished cooldowns
-- since the original release, so the path exists everywhere, and it reads at
-- eight pixels.
local MOTE = "Interface\\Cooldown\\star4"

local Effects = {}

-- Animation groups exist on both supported flavours according to the
-- interface source, which is not verification, so they are probed. Once per
-- frame that asks, not once per addon: a type check, and no global to
-- initialise before anything draws.
local function canAnimate(frame)
  return type(frame.CreateAnimationGroup) == "function"
end

local function tint(texture, color)
  texture:SetVertexColor(color.r, color.g, color.b, color.a or 1)
end

-- Only a frame can own an animation group, so every animation here lives in a
-- group of the host frame and by default animates the whole frame: a glow's
-- alpha curve would fade the numbers too. SetChildKey aims an animation at a
-- region instead, found by field name, so the texture must be `frame[key]`.
-- A missing SetChildKey fails silently, and the smoke harness's stubbed
-- animations cannot catch it.
--
-- A texture cannot be destroyed, so regions are cached and re-dressed on the
-- next call rather than rebuilt on every skin change. The cache is its own
-- table, read with rawget: the smoke harness's stand-in frame answers every
-- capitalised field with a function, so reading `frame[key]` would return one.
local REGISTRY = "ascentEffectRegions"

local function attach(frame, key, layer, sublevel)
  local registry = rawget(frame, REGISTRY)
  if registry == nil then
    registry = {}
    rawset(frame, REGISTRY, registry)
  end

  local texture = registry[key]
  if texture == nil then
    texture = frame:CreateTexture(nil, layer, nil, sublevel)
    registry[key] = texture
    -- What SetChildKey looks up; the registry above is what this file reads.
    frame[key] = texture
  end
  return texture, key
end

-- ---------------------------------------------------------------------------
-- Glow: one additive wash over the whole frame, swelling and fading.
-- ---------------------------------------------------------------------------

-- The shape every effect here returns: `play()` and `stop()`, safe to call
-- whether or not the effect could be built, so a caller never branches.
local INERT = {
  play = function() end,
  stop = function() end,
}

function Effects.glow(frame, spec)
  if spec.kind == GlowKind.NONE or spec.duration <= 0 or spec.peak <= 0 then
    return INERT
  end

  local texture, key = attach(frame, "AscentGlow", "OVERLAY", 6)
  texture:SetTexture(ALERT_GLOW)
  texture:SetTexCoord(unpack(GLOW_COORDS))
  texture:SetBlendMode("ADD")
  tint(texture, spec.color)
  texture:SetAlpha(0)
  -- Larger than the frame and centred on it: a bloom clipped to the frame's
  -- edges looks like a rectangle lighting up.
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", frame, "CENTER", 0, 0)
  texture:Hide()

  local effect = { texture = texture }

  -- A burst is the same wash on a harder curve: a soft glow spends more of its
  -- duration rising, a burst spends most of it falling.
  local rise = spec.kind == GlowKind.BURST and 0.15 or 0.4

  if canAnimate(frame) then
    local group = frame:CreateAnimationGroup()
    group:SetToFinalAlpha(true)

    local up = group:CreateAnimation("Alpha")
    up:SetChildKey(key)
    up:SetOrder(1)
    up:SetFromAlpha(0)
    up:SetToAlpha(spec.peak)
    up:SetDuration(spec.duration * rise)
    up:SetSmoothing("OUT")

    local down = group:CreateAnimation("Alpha")
    down:SetChildKey(key)
    down:SetOrder(2)
    down:SetFromAlpha(spec.peak)
    down:SetToAlpha(0)
    down:SetDuration(spec.duration * (1 - rise))
    down:SetSmoothing("IN")

    group:SetScript("OnFinished", function()
      texture:SetAlpha(0)
      texture:Hide()
    end)
    effect.group = group
  end

  function effect:resize(width, height)
    -- The bloom's art is about twice as wide as tall, and reads as light only
    -- when it overhangs what it lights.
    self.texture:SetSize(width * 1.35, height * 2.2)
  end

  function effect:play()
    self.texture:Show()
    if self.group ~= nil then
      self.group:Stop()
      self.group:Play()
    else
      -- No animation system: the wash is shown static at its peak, and the
      -- owning view clears it on its next tick like anything else it drew.
      self.texture:SetAlpha(spec.peak)
    end
  end

  function effect:stop()
    if self.group ~= nil then
      self.group:Stop()
    end
    self.texture:SetAlpha(0)
    self.texture:Hide()
  end

  return effect
end

-- ---------------------------------------------------------------------------
-- Entrance: the frame arriving, rather than appearing.
-- ---------------------------------------------------------------------------

-- The only animation here with no child key: it fades the frame itself in, so
-- a surface does not blink into existence.
--
-- Alpha only. A Translation snaps the frame back at the end unless the offset
-- is committed by hand, and the Scale setters differ between the two supported
-- flavours.
--
-- `alpha` is the opacity the frame arrives at, for a caller drawn at a
-- player-chosen opacity: SetToFinalAlpha makes the animation's end the last
-- write, after the caller's own, so a fade hard-coded to 1 would override it.
-- It defaults to 1.
function Effects.entrance(frame, duration, alpha)
  if duration == nil or duration <= 0 or not canAnimate(frame) then
    return INERT
  end
  alpha = alpha or 1

  local group = frame:CreateAnimationGroup()
  group:SetToFinalAlpha(true)

  local fade = group:CreateAnimation("Alpha")
  fade:SetOrder(1)
  fade:SetFromAlpha(0)
  fade:SetToAlpha(alpha)
  fade:SetDuration(duration)
  fade:SetSmoothing("OUT")

  local effect = { group = group, frame = frame, alpha = alpha }

  function effect:play()
    self.group:Stop()
    self.frame:SetAlpha(self.alpha)
    self.group:Play()
  end

  function effect:stop()
    self.group:Stop()
    self.frame:SetAlpha(self.alpha)
  end

  return effect
end

-- ---------------------------------------------------------------------------
-- Sweep: one bright band travelling across the frame, exactly once.
-- ---------------------------------------------------------------------------

function Effects.sweep(frame, spec)
  if spec.kind == SweepKind.NONE or spec.duration <= 0 then
    return INERT
  end
  -- Unlike the glow, a band that does not travel is just a bright rectangle, so
  -- without an animation system there is no sweep at all.
  if not canAnimate(frame) then
    return INERT
  end

  local texture, key = attach(frame, "AscentSweep", "OVERLAY", 7)
  texture:SetTexture(ALERT_GLOW)
  texture:SetTexCoord(unpack(SHINE_COORDS))
  texture:SetBlendMode("ADD")
  tint(texture, spec.color)
  texture:SetAlpha(0)
  texture:ClearAllPoints()
  texture:SetPoint("LEFT", frame, "LEFT", 0, 0)
  texture:Hide()

  local group = frame:CreateAnimationGroup()
  group:SetToFinalAlpha(true)

  -- All three share one order so they run together: the band brightens as it
  -- starts moving and is dimming before it reaches the far edge, one gesture
  -- rather than appear, move, fade.
  local fadeIn = group:CreateAnimation("Alpha")
  fadeIn:SetChildKey(key)
  fadeIn:SetOrder(1)
  fadeIn:SetFromAlpha(0)
  fadeIn:SetToAlpha(1)
  fadeIn:SetDuration(spec.duration * 0.2)

  local travel = group:CreateAnimation("Translation")
  travel:SetChildKey(key)
  travel:SetOrder(1)
  travel:SetDuration(spec.duration)

  local fadeOut = group:CreateAnimation("Alpha")
  fadeOut:SetChildKey(key)
  fadeOut:SetOrder(1)
  fadeOut:SetFromAlpha(1)
  fadeOut:SetToAlpha(0)
  fadeOut:SetStartDelay(spec.duration * 0.45)
  fadeOut:SetDuration(spec.duration * 0.55)

  local effect = { texture = texture, group = group, travel = travel }

  function effect:resize(width, height)
    local bandWidth = math.max(24, height * 2)
    self.texture:SetSize(bandWidth, height * 1.6)
    -- The band starts flush left and ends flush right, so it travels the
    -- frame's width minus its own; the full width would carry it off the frame.
    self.travel:SetOffset(width - bandWidth, 0)
  end

  function effect:play()
    self.texture:Show()
    self.group:Stop()
    self.group:Play()
  end

  function effect:stop()
    self.group:Stop()
    self.texture:SetAlpha(0)
    self.texture:Hide()
  end

  group:SetScript("OnFinished", function()
    texture:SetAlpha(0)
    texture:Hide()
  end)

  return effect
end

-- ---------------------------------------------------------------------------
-- Burst: motes climbing out of the frame on staggered delays.
-- ---------------------------------------------------------------------------

-- Where each mote starts, spread either side of centre and not in order: motes
-- leaving left to right read as a wipe, scattered ones as a burst. The idea of
-- LS: Toasts' five arrows, generalised to any count.
local function moteOffset(index, count, spread)
  local half = (count - 1) / 2
  local slot = index - 1
  -- Alternate outwards from the middle: 0, +1, -1, +2, -2, ...
  local step = math.ceil(slot / 2)
  if slot % 2 == 0 then
    step = -step
  end
  if step > half then step = half end
  if step < -half then step = -half end
  return step * spread
end

function Effects.burst(frame, spec)
  if spec.kind == BurstKind.NONE or spec.duration <= 0 or spec.count <= 0 then
    return INERT
  end
  if not canAnimate(frame) then
    return INERT
  end

  local group = frame:CreateAnimationGroup()
  group:SetToFinalAlpha(true)

  local motes = {}
  for index = 1, spec.count do
    -- One group for every mote, aimed through child keys: one object for the
    -- client to schedule rather than `count` of them.
    local texture, key = attach(frame, "AscentMote" .. index, "OVERLAY", 5)
    texture:SetTexture(MOTE)
    texture:SetBlendMode("ADD")
    tint(texture, spec.color)
    texture:SetSize(16, 16)
    texture:SetAlpha(0)
    texture:ClearAllPoints()
    texture:SetPoint("CENTER", frame, "TOP", moteOffset(index, spec.count, spec.spread), -4)
    motes[index] = texture

    local delay = (index - 1) * spec.stagger

    local appear = group:CreateAnimation("Alpha")
    appear:SetChildKey(key)
    appear:SetOrder(1)
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    appear:SetStartDelay(delay)
    appear:SetDuration(spec.duration * 0.25)
    appear:SetSmoothing("OUT")

    local climb = group:CreateAnimation("Translation")
    climb:SetChildKey(key)
    climb:SetOrder(1)
    climb:SetOffset(0, spec.rise)
    climb:SetStartDelay(delay)
    climb:SetDuration(spec.duration)
    climb:SetSmoothing("OUT")

    local fade = group:CreateAnimation("Alpha")
    fade:SetChildKey(key)
    fade:SetOrder(1)
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetStartDelay(delay + spec.duration * 0.4)
    fade:SetDuration(spec.duration * 0.6)
    fade:SetSmoothing("IN")
  end

  local effect = { motes = motes, group = group }

  local function darken()
    for _, texture in ipairs(motes) do
      texture:SetAlpha(0)
      texture:Hide()
    end
  end
  group:SetScript("OnFinished", darken)

  function effect:play()
    for _, texture in ipairs(self.motes) do
      texture:Show()
    end
    self.group:Stop()
    self.group:Play()
  end

  function effect:stop()
    self.group:Stop()
    darken()
  end

  return effect
end

-- ---------------------------------------------------------------------------
-- A number that counts instead of jumping.
-- ---------------------------------------------------------------------------

-- No shared C_Timer ticker: at rest the addon must cost nothing, so this is
-- driven from the tick the owning view already runs, and reports when it has
-- arrived so the view can stop calling it.
--
-- `format` turns the running value into the string shown (4.2k, not 4200),
-- since only this object holds the interpolated value.
local Counter = {}
Counter.__index = Counter

function Effects.counter(fontString, format)
  return setmetatable({
    fontString = fontString,
    format = format or tostring,
    value = 0,
    target = 0,
    -- Seconds to cross whatever distance is outstanding, fixed rather than
    -- proportional, so large and small changes settle in the same time.
    duration = 0.6,
    elapsed = 0,
  }, Counter)
end

-- `immediate` skips the animation, for a plate reset for a new pull, which must
-- not count from the last pull's total.
function Counter:set(value, immediate)
  self.target = value or 0
  if immediate or self.duration <= 0 then
    self.value = self.target
    self.elapsed = 0
    self.fontString:SetText(self.format(self.value))
    return
  end
  if self.value ~= self.target then
    self.elapsed = 0
  end
end

-- Returns true while there is still distance to cover. Linear on purpose: an
-- eased counter reads as a number that hesitates.
function Counter:tick(dt)
  if self.value == self.target then
    return false
  end

  self.elapsed = self.elapsed + (dt or 0)
  local progress = self.elapsed / self.duration
  if progress >= 1 then
    self.value = self.target
  else
    local from = self.value
    local step = (self.target - from) * progress
    -- Rounded away from where it started, so it advances at least one per tick
    -- and never stalls short of its target.
    if self.target > from then
      self.value = from + math.max(1, math.floor(step))
      if self.value > self.target then self.value = self.target end
    else
      self.value = from - math.max(1, math.floor(-step))
      if self.value < self.target then self.value = self.target end
    end
  end

  self.fontString:SetText(self.format(self.value))
  return self.value ~= self.target
end

-- Repaints at the value it holds, for a format that depends on state the
-- counter does not own: the plate prints "1/2" while something still stands and
-- "2" once nothing does, a change that moves no number.
function Counter:repaint()
  self.fontString:SetText(self.format(self.value))
end

function Counter:reset()
  self.value, self.target, self.elapsed = 0, 0, 0
  self.fontString:SetText(self.format(0))
end

-- ---------------------------------------------------------------------------
-- An art border: four corners and four tiling edges, from one strip.
-- ---------------------------------------------------------------------------

-- The technique LS: Toasts uses for its frames, reimplemented. Eight regions
-- rather than four give real corners instead of two lines meeting. It needs no
-- animation and no newer API, so it has no degraded path.
local SECTIONS = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT", "TOP", "BOTTOM", "LEFT", "RIGHT" }

function Effects.plaqueBorder(frame, options)
  options = options or {}
  local size = options.size or 12
  local inset = options.inset or 4
  local color = options.color or { r = 1, g = 1, b = 1, a = 1 }

  local border = { size = size, inset = inset }

  for _, section in ipairs(SECTIONS) do
    local texture = frame:CreateTexture(nil, "BORDER", nil, 1)
    texture:SetColorTexture(color.r, color.g, color.b, color.a or 1)
    border[section] = texture
  end

  border.TOPLEFT:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", inset, -inset)
  border.TOPRIGHT:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", -inset, -inset)
  border.BOTTOMLEFT:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", inset, inset)
  border.BOTTOMRIGHT:SetPoint("TOPLEFT", frame, "BOTTOMRIGHT", -inset, inset)

  border.TOP:SetPoint("TOPLEFT", border.TOPLEFT, "TOPRIGHT", 0, 0)
  border.TOP:SetPoint("TOPRIGHT", border.TOPRIGHT, "TOPLEFT", 0, 0)
  border.BOTTOM:SetPoint("BOTTOMLEFT", border.BOTTOMLEFT, "BOTTOMRIGHT", 0, 0)
  border.BOTTOM:SetPoint("BOTTOMRIGHT", border.BOTTOMRIGHT, "BOTTOMLEFT", 0, 0)
  border.LEFT:SetPoint("TOPLEFT", border.TOPLEFT, "BOTTOMLEFT", 0, 0)
  border.LEFT:SetPoint("BOTTOMLEFT", border.BOTTOMLEFT, "TOPLEFT", 0, 0)
  border.RIGHT:SetPoint("TOPRIGHT", border.TOPRIGHT, "BOTTOMRIGHT", 0, 0)
  border.RIGHT:SetPoint("BOTTOMRIGHT", border.BOTTOMRIGHT, "TOPRIGHT", 0, 0)

  function border:setColor(value)
    for _, section in ipairs(SECTIONS) do
      self[section]:SetColorTexture(value.r, value.g, value.b, value.a or 1)
    end
  end

  function border:setThickness(thickness)
    self.TOPLEFT:SetSize(thickness, thickness)
    self.TOPRIGHT:SetSize(thickness, thickness)
    self.BOTTOMLEFT:SetSize(thickness, thickness)
    self.BOTTOMRIGHT:SetSize(thickness, thickness)
    self.TOP:SetHeight(thickness)
    self.BOTTOM:SetHeight(thickness)
    self.LEFT:SetWidth(thickness)
    self.RIGHT:SetWidth(thickness)
  end

  function border:hide()
    for _, section in ipairs(SECTIONS) do
      self[section]:Hide()
    end
  end

  function border:show()
    for _, section in ipairs(SECTIONS) do
      self[section]:Show()
    end
  end

  border:setThickness(size)
  return border
end

ns.ui.Effects = Effects
