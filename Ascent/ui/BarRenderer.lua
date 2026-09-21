-- Ascent - the one function that paints a bar (tasks 3.4, 3.5, 3.6, 3.7).
--
-- Everything about how the bar LOOKS happens here, and nothing here knows the
-- name of a single skin (design D27). It is handed a resolved appearance -- a
-- table of tokens, colours and numbers -- and a boundary vector, and it paints
-- them. Add a skin and this file does not change; that is the whole arrangement.
--
-- It is also deliberately ignorant of everything else the bar does. No dragging,
-- no saved position, no scale, no tooltip, no hiding itself because the player
-- is at max level. That is what makes it instantiable TWICE (D34): once as the
-- real bar, once as the live preview in the options panel, which must be able to
-- show a skin without the real bar moving or disappearing underneath it.
--
-- Textures are created once and reused forever, hidden rather than destroyed.
-- The worst case is fixed and small: one background, six channel fills, one
-- gloss band, five separators and four border edges.
--
-- On client differences: every call that is not as old as the game itself is
-- guarded and has a written fallback (D38). A gradient fill degrades to a flat
-- one, which is a skin that looks slightly plainer -- not a bar that fails to
-- draw. Nothing here ever leaves the player without a bar.

local _, ns = ...
ns.ui = ns.ui or {}

local BarChannel = ns.core.BarChannel
local BarGeometry = ns.core.BarGeometry
local FillKind = ns.core.FillKind
local BorderKind = ns.core.BorderKind
local SeparatorKind = ns.core.SeparatorKind
local TextStyle = ns.core.TextStyle
local TextAnchor = ns.core.TextAnchor

-- How much of the bar's height a NOTCH separator covers, measured from the top.
local NOTCH_FRACTION = 0.45

local BarRenderer = {}
BarRenderer.__index = BarRenderer

-- Colour-with-alpha, applied to a texture. `alpha` multiplies the channel's own
-- so that rested stays visibly lighter than earned progress under every skin.
local function paint(texture, color, alpha)
  texture:SetColorTexture(color.r, color.g, color.b, (color.a or 1) * (alpha or 1))
end

-- A vertical gradient over an already-coloured texture, when the client can do
-- it. Both the method and CreateColor are checked: the gradient signature
-- changed across versions and BC Classic is not verifiable from here, so the
-- flat fill underneath is the answer when anything is missing (D38, spike 0.4).
local function gradient(texture, color, alpha, lighterAtTop)
  if texture.SetGradient == nil or CreateColor == nil then
    return false
  end
  local base = (color.a or 1) * (alpha or 1)
  local dim, lit = 0.72, 1.18
  local function shade(factor)
    return CreateColor(
      math.min(color.r * factor, 1),
      math.min(color.g * factor, 1),
      math.min(color.b * factor, 1),
      base
    )
  end
  local top, bottom = shade(lit), shade(dim)
  if not lighterAtTop then
    top, bottom = bottom, top
  end
  -- pcall because this is the one call whose exact shape is not verified on both
  -- clients: a failure here must cost a gradient, not the frame.
  return pcall(texture.SetGradient, texture, "VERTICAL", bottom, top)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

local function createTexture(frame, layer, sublevel)
  local texture = frame:CreateTexture(nil, layer, nil, sublevel)
  texture:Hide()
  return texture
end

-- `options`: parent (the frame to draw into), width, height.
function BarRenderer.new(options)
  options = options or {}
  if options.parent == nil then
    error("BarRenderer needs a parent frame", 2)
  end

  local frame = options.parent
  local self = setmetatable({
    frame = frame,
    width = options.width or 400,
    height = options.height or 24,
    appearance = nil,
    background = createTexture(frame, "BACKGROUND"),
    gloss = createTexture(frame, "ARTWORK", 2),
    flash = createTexture(frame, "ARTWORK", 3),
    -- Where the EARNED progress ends, in pixels. Kept from the last draw so the
    -- flash can cover exactly that and not the rested reserve or the pending
    -- projection, neither of which the player just earned.
    progressEdge = 0,
    fills = {},
    separators = {},
    edges = {},
    channels = {},
  }, BarRenderer)

  -- Frozen copies list-shaped constants plain rather than proxying them (see
  -- Frozen.lua's header), so ipairs walks BarChannel directly. Copied into the
  -- instance anyway: this is read on every redraw, and the copy makes that a
  -- local lookup rather than a global one.
  for _, channel in ipairs(BarChannel) do
    self.channels[#self.channels + 1] = channel
  end

  for index = 1, #self.channels do
    self.fills[index] = createTexture(frame, "ARTWORK", 1)
  end
  for index = 1, #self.channels - 1 do
    self.separators[index] = createTexture(frame, "OVERLAY", 1)
  end
  for index = 1, 4 do
    self.edges[index] = createTexture(frame, "OVERLAY", 2)
  end

  local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  self.text = text

  return self
end

-- ---------------------------------------------------------------------------
-- Appearance (3.4, 3.5, 3.7)
-- ---------------------------------------------------------------------------

function BarRenderer:setSize(width, height)
  self.width, self.height = width, height
  self.frame:SetSize(width, height)
  if self.appearance ~= nil then
    self:applyAppearance(self.appearance)
  end
end

function BarRenderer:applyBorder(border)
  if border.kind == BorderKind.NONE or border.thickness <= 0 then
    for _, edge in ipairs(self.edges) do
      edge:Hide()
    end
    return
  end

  -- Four thin textures rather than a backdrop: a backdrop needs the frame to
  -- have been created from a template, which would make the renderer's parent
  -- its business, and it scales its edge art in ways a one-pixel line must not.
  local thickness = border.thickness
  local color = border.color
  local light = border.kind == BorderKind.BEVEL

  local geometry = {
    { "TOPLEFT", "TOPRIGHT", self.width, thickness, 0, 0 },
    { "BOTTOMLEFT", "BOTTOMRIGHT", self.width, thickness, 0, 0 },
    { "TOPLEFT", "BOTTOMLEFT", thickness, self.height, 0, 0 },
    { "TOPRIGHT", "BOTTOMRIGHT", thickness, self.height, 0, 0 },
  }

  for index, edge in ipairs(self.edges) do
    local spec = geometry[index]
    edge:ClearAllPoints()
    edge:SetPoint(spec[1], self.frame, spec[1], 0, 0)
    edge:SetSize(spec[3], spec[4])
    -- A bevel is the same four edges with the top lit and the bottom dimmed --
    -- the cheapest depth cue there is, and the one the client's own frames use.
    local factor = 1
    if light then
      factor = (index == 1 or index == 3) and 1.25 or 0.6
    end
    edge:SetColorTexture(
      math.min(color.r * factor, 1), math.min(color.g * factor, 1),
      math.min(color.b * factor, 1), color.a or 1
    )
    edge:Show()
  end
end

function BarRenderer:applyText(text)
  local fontString = self.text
  -- GetFont, not a hard-coded path: the client's default font differs by
  -- locale, and naming a Latin font here is invisible text on a Russian,
  -- Korean or Chinese client.
  local path = fontString:GetFont()
  local flags = ""
  if text.style == TextStyle.OUTLINE then
    flags = "OUTLINE"
  elseif text.style == TextStyle.HEAVY then
    flags = "THICKOUTLINE"
  end
  if path ~= nil then
    fontString:SetFont(path, text.size, flags)
  end
  fontString:SetTextColor(text.color.r, text.color.g, text.color.b, text.color.a or 1)

  -- A shadow only where there is no thick outline to carry the job already.
  if text.style == TextStyle.PLAIN then
    fontString:SetShadowColor(0, 0, 0, 0.85)
    fontString:SetShadowOffset(1, -1)
  else
    fontString:SetShadowColor(0, 0, 0, 0)
  end

  fontString:ClearAllPoints()
  local anchor = text.anchor
  if anchor == TextAnchor.ABOVE then
    fontString:SetPoint("BOTTOM", self.frame, "TOP", 0, 2)
  elseif anchor == TextAnchor.BELOW then
    fontString:SetPoint("TOP", self.frame, "BOTTOM", 0, -2)
  elseif anchor == TextAnchor.INSIDE_LEFT then
    fontString:SetPoint("LEFT", self.frame, "LEFT", 4, 0)
  elseif anchor == TextAnchor.INSIDE_RIGHT then
    fontString:SetPoint("RIGHT", self.frame, "RIGHT", -4, 0)
  else
    fontString:SetPoint("CENTER", self.frame, "CENTER", 0, 0)
  end
end

function BarRenderer:applyAppearance(appearance)
  self.appearance = appearance

  local background = appearance.background
  if (background.a or 0) <= 0 then
    self.background:Hide()
  else
    self.background:ClearAllPoints()
    self.background:SetAllPoints(self.frame)
    paint(self.background, background, 1)
    self.background:Show()
  end

  self:applyBorder(appearance.border)
  self:applyText(appearance.text)

  local gloss = appearance.fill.gloss
  if gloss > 0 then
    self.gloss:ClearAllPoints()
    self.gloss:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
    self.gloss:SetSize(self.width, self.height * appearance.fill.glossHeight)
    self.gloss:SetColorTexture(1, 1, 1, gloss)
    -- Additive, so the gloss brightens whatever colour is underneath instead of
    -- washing all six channels towards the same white.
    self.gloss:SetBlendMode("ADD")
    self.gloss:Show()
  else
    self.gloss:Hide()
  end

  return self
end

-- ---------------------------------------------------------------------------
-- Drawing (3.4, 3.5)
-- ---------------------------------------------------------------------------

-- `boundaries` is the cumulative vector BarTween maintains, in the channel order
-- BarChannel declares. Nothing else is needed: the widths, the separators and
-- the seams all come out of it.
function BarRenderer:draw(boundaries)
  local appearance = self.appearance
  if appearance == nil then
    return self
  end

  local layout = BarGeometry.lay(boundaries, self.width)
  local widths, edges = layout.widths, layout.edges
  local separator = appearance.separator
  local fillKind = appearance.fill.kind
  local left = 0

  for index, channel in ipairs(self.channels) do
    local texture = self.fills[index]
    local width = widths[index]
    if width <= 0 then
      texture:Hide()
    else
      local color = appearance.colors[channel.palette]
      texture:ClearAllPoints()
      texture:SetPoint("TOPLEFT", self.frame, "TOPLEFT", left, 0)
      texture:SetSize(width, self.height)
      paint(texture, color, channel.alpha)
      if fillKind == FillKind.GRADIENT_UP then
        gradient(texture, color, channel.alpha, true)
      elseif fillKind == FillKind.GRADIENT_DN then
        gradient(texture, color, channel.alpha, false)
      end
      texture:Show()
    end
    left = edges[index]
  end

  -- The earned progress ends where the last SOURCE channel does -- before the
  -- rested reserve and the pending projection, which are not progress.
  self.progressEdge = edges[#self.channels - 2] or 0

  -- Separators are drawn ON the boundary, never as a gap: a gap would take width
  -- from a segment, and a segment's width is the level's percentage.
  for index = 1, #self.separators do
    local mark = self.separators[index]
    local visible = separator.kind ~= SeparatorKind.NONE
      and widths[index] > 0 and widths[index + 1] > 0
    if not visible then
      mark:Hide()
    else
      local thickness = separator.thickness
      local height = self.height
      if separator.kind == SeparatorKind.NOTCH then
        height = self.height * NOTCH_FRACTION
      end
      mark:ClearAllPoints()
      -- Centred on the seam so that neither neighbour loses more than the other.
      mark:SetPoint("TOPLEFT", self.frame, "TOPLEFT", edges[index] - thickness / 2, 0)
      mark:SetSize(thickness, height)
      paint(mark, separator.color, 1)
      mark:Show()
    end
  end

  return self
end

-- How wide `value` would be in the bar's own font. Used to decide whether the
-- composed text fits inside the bar (task 3.8). Measuring means setting it, so
-- the caller is expected to set the text it settles on afterwards -- which is
-- exactly what composeText does.
function BarRenderer:widthOf(value)
  self.text:SetText(value or "")
  return self.text:GetStringWidth() or 0
end

-- An additive white wash over the earned progress, at `alpha`. Additive rather
-- than opaque so it BRIGHTENS the four channel colours underneath instead of
-- flattening all of them to the same white -- the segments have to stay
-- distinguishable during the flash, since that is the whole point of the bar.
function BarRenderer:setFlash(alpha)
  if alpha == nil or alpha <= 0 or self.progressEdge <= 0 then
    self.flash:Hide()
    return self
  end
  self.flash:ClearAllPoints()
  self.flash:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
  self.flash:SetSize(self.progressEdge, self.height)
  self.flash:SetColorTexture(1, 1, 1, alpha)
  self.flash:SetBlendMode("ADD")
  self.flash:Show()
  return self
end

function BarRenderer:setText(value)
  self.text:SetText(value or "")
end

function BarRenderer:hideProgress()
  for _, texture in ipairs(self.fills) do
    texture:Hide()
  end
  for _, mark in ipairs(self.separators) do
    mark:Hide()
  end
  self.gloss:Hide()
  self.flash:Hide()
  self.progressEdge = 0
end

ns.ui.BarRenderer = BarRenderer
