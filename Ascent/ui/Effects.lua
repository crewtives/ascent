-- Ascent - the shared vocabulary of things that happen once.
--
-- This is the drawing half of core/constants/Appearance.lua's `effects` block:
-- hand it a resolved effect spec and a frame, and it builds the textures and the
-- animation that spec describes. Nothing in here knows what a pull is, what a
-- bar is, or which skin it came from -- the pull plate is simply the first
-- surface to ask, and the bar and the report panel can ask for the same three
-- without a line of this changing.
--
-- WHERE THE TECHNIQUES COME FROM. These are reverse-engineered from LS: Toasts,
-- not lifted out of it: no code and no asset of that addon is used here. What
-- was worth learning turned out to be three things, and all three are cheaper
-- than they look:
--
--   1. The client draws the art. The glow and the band below are regions of
--      Interface\AchievementFrame\UI-Achievement-Alert-Glow, which ships with
--      every client and which any addon may use. Ascent needs no packaged file
--      to look like this, which is why this lands as a prototype rather than as
--      an art pipeline.
--   2. The animation belongs to the client too. An AnimationGroup runs on the C
--      side: once it is built and played, a glow that swells and fades costs
--      this addon nothing per frame. That is the opposite of how Ascent moves
--      its bar today (BarTween, per frame, in Lua) and it is the right trade for
--      an effect that is declarative and does not have to be interrupted.
--   3. "Particles" are a handful of textures with different start delays.
--      There is no particle system and there does not need to be one.
--
-- DEGRADATION (D38). Two things here are not as old as the game: animation
-- groups and SetTexCoord's eight-argument form. Both are probed, and the answer
-- to a missing one is a visible-but-static effect or no effect at all -- never a
-- frame that fails to build. A texture path that does not resolve on a given
-- flavour draws nothing and raises nothing, which is the same outcome by a
-- different road: the surface still works, one flourish is missing.
--
-- MOTION SCALE. Every duration that reaches here has already been multiplied by
-- the player's own scalar. A scalar of zero therefore arrives as a duration of
-- zero, and `play()` becomes a no-op through the same code path rather than
-- through a branch -- which is what the visual-motion capability asks for.

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

-- The mote. A four-pointed star the client has drawn on every finished cooldown
-- since vanilla, so it is as safe a bet as a texture path gets, and its shape
-- reads at eight pixels -- which is the whole requirement for something that is
-- on screen for half a second.
local MOTE = "Interface\\Cooldown\\star4"

local Effects = {}

-- Animation groups exist on both supported flavours as far as the interface
-- source says, but "as far as the source says" is exactly the standard D38
-- exists to refuse. Probed once per frame that asks, not once per addon: the
-- cost is a type check and the alternative is a global that has to be
-- initialised before anything draws.
local function canAnimate(frame)
  return type(frame.CreateAnimationGroup) == "function"
end

local function tint(texture, color)
  texture:SetVertexColor(color.r, color.g, color.b, color.a or 1)
end

-- THE ONE MECHANIC EVERYTHING BELOW DEPENDS ON, and the one that fails silently
-- if it is missed. A texture cannot own an animation group -- only a frame can --
-- so every animation here lives in a group belonging to the PLATE, and would by
-- default animate the plate itself: an alpha curve meant for a glow would fade
-- the whole frame, numbers and all. SetChildKey is what aims an animation at a
-- region of the parent instead, and it addresses that region BY FIELD NAME, so
-- the texture has to be reachable as `frame[key]`.
--
-- Nothing in the smoke harness can catch a missing one: a stubbed animation
-- accepts every call and reports nothing. It is checked by reading, which is why
-- it is written down here.
--
-- The client has no way to destroy a texture, so an effect rebuilt on every skin
-- change would leave the last one's regions parented to the plate forever. This
-- therefore caches what it made and re-dresses it on the next call.
--
-- The cache is a table of its own rather than a read of `frame[key]`, and that
-- is not defensiveness -- it is correctness in both places this runs. A frame is
-- an ordinary table, so `frame[key]` answers nil the first time in the client;
-- but the smoke harness's stand-in frame auto-stubs every capitalised field and
-- answers with a FUNCTION, which a cache reading it would happily try to paint.
-- The assignment below still has to happen, because SetChildKey resolves its
-- region by field name -- it is the read that must not go through it.
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
    -- What SetChildKey actually looks up. Both are needed and they are not the
    -- same statement: this one is for the client, the line above is for us.
    frame[key] = texture
  end
  return texture, key
end

-- ---------------------------------------------------------------------------
-- Glow: one additive wash over the whole frame, swelling and fading.
-- ---------------------------------------------------------------------------

-- The shape every effect in this file returns: something with `play()` and
-- `stop()` that is safe to call whether or not the effect could be built. A
-- caller never branches on whether an effect exists.
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
  -- Deliberately larger than the frame and centred on it: a bloom clipped to the
  -- frame's own edges looks like a rectangle lighting up, which is the one thing
  -- it must not look like.
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", frame, "CENTER", 0, 0)
  texture:Hide()

  local effect = { texture = texture }

  -- A burst is the same wash on a shorter, harder curve: most of the duration
  -- goes into the rise for a soft one and into the fall for a burst, which is
  -- the difference between "lit from inside" and "something landed".
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
    -- The bloom's own art is about twice as wide as it is tall, and it reads as
    -- light rather than as a shape only when it overhangs what it is lighting.
    self.texture:SetSize(width * 1.35, height * 2.2)
  end

  function effect:play()
    self.texture:Show()
    if self.group ~= nil then
      self.group:Stop()
      self.group:Play()
    else
      -- No animation system: the wash still says something happened, it just
      -- says it by being there. Whoever owns the frame clears it on its next
      -- tick, the same way it clears anything else it drew.
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

-- The one animation in this file with NO child key, and deliberately so: every
-- other one aims at a region of the frame, this one is about the frame itself.
-- A surface that blinks into existence reads as a bug for the first half second;
-- the same surface fading in over a quarter of one reads as a surface.
--
-- Alpha and nothing else. Translation would slide the frame and snap it back at
-- the end unless the offset is committed by hand, and Scale's setters are not the
-- same across the two supported flavours -- neither is worth a wrong-looking
-- frame on one of them (D38).
--
-- `alpha` is what the frame arrives AT, and it is a parameter because one caller
-- draws itself at an opacity its player chose (D91). SetToFinalAlpha leaves the
-- frame wherever the animation ended, so a fade-in hard-coded to one is not a
-- fade-in that can be overruled afterwards: it is the LAST write, a quarter of a
-- second after the caller's own. Defaulted rather than required, because arriving
-- at full strength is what a frame with no opinion wants.
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
  -- Unlike the glow, this one has no still image worth showing: a band that does
  -- not travel is a bright rectangle sitting on the frame. With no animation
  -- system there is nothing to degrade TO, so it degrades to nothing.
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

  -- All three in one order, so they run together: the band brightens as it
  -- starts moving and is already dimming by the time it reaches the far edge.
  -- Sequencing them would produce a band that appears, then moves, then fades --
  -- three events where there should be one gesture.
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
    -- The band starts flush with the left edge and ends flush with the right,
    -- so the distance is the frame minus the band rather than the frame: a band
    -- translated by the full width leaves the frame entirely and the last third
    -- of the effect happens where nobody can see it.
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

-- Where each mote starts, spread either side of centre and deliberately not in
-- order: motes leaving left to right read as a wipe, motes leaving in a
-- scattered order read as a burst. The pattern is the same idea LS: Toasts uses
-- for its five arrows, recomputed here for an arbitrary count.
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
    -- One group for every mote (see attach above): one object the client
    -- schedules rather than `count` of them.
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

-- LS: Toasts drives every animated number in the addon off one shared
-- C_Timer ticker. Ascent does not, and the reason is the visual-motion
-- capability's own requirement that rest cost nothing: a ticker running for the
-- life of the session is work done while nothing is happening. This is driven
-- from the tick the owning view already runs, and reports when it has arrived so
-- that view can stop calling it.
--
-- `format` turns the running value into the string shown. It exists because the
-- number a player reads is almost never the number being interpolated -- 4.2k is
-- not 4200 -- and doing that outside would mean formatting a value this object
-- has already thrown away.
local Counter = {}
Counter.__index = Counter

function Effects.counter(fontString, format)
  return setmetatable({
    fontString = fontString,
    format = format or tostring,
    value = 0,
    target = 0,
    -- Seconds to cross whatever distance is outstanding. Fixed rather than
    -- proportional to the distance, so a big number and a small one take the
    -- same time to settle and the plate has one rhythm instead of two.
    duration = 0.6,
    elapsed = 0,
  }, Counter)
end

-- `immediate` skips the animation entirely: used when a plate is reset for a new
-- pull, where counting up from the last pull's total would be a lie in motion.
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
-- eased counter reads as a number that hesitates, and a number that hesitates
-- reads as a number that is unsure.
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
    -- Rounded AWAY from where it started, so a counter always advances by at
    -- least one per tick and can never stall a pixel short of its target while
    -- the fraction rounds back to where it already was.
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

-- Repaints at the value it already holds. Needed because the FORMAT can depend
-- on state the counter does not own: the plate prints "1/2" while something is
-- still standing and "2" once nothing is, and that transition moves no number.
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

-- The technique LS: Toasts uses for every frame it draws, reimplemented over the
-- client's own dialog art. Eight regions rather than four is what buys a corner
-- that is a corner instead of two lines meeting -- which is the difference
-- between a panel and a plaque.
--
-- Unlike everything above this needs no animation and nothing modern, so it has
-- no degraded path: it is eight textures and eight anchors.
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
