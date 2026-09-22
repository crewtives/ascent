-- Ascent - turning a skin plus the player's own choices into one painted form
-- (tasks 2.2, 2.3, 2.4, 2.6).
--
-- This is the only module that knows what a skin NAME means. Everything
-- downstream receives the table this returns and paints it without ever asking
-- which skin it came from (design D27) -- that is what keeps the drawing code
-- free of a branch per skin, and what makes all of this testable with no client
-- running.
--
-- The order matters and is the whole design:
--
--   normalize   fill every field of a possibly-partial skin from SkinShape, so
--               nothing downstream can read a key that is not there. Frozen
--               proxies RAISE on a missing key rather than returning nil
--               (Frozen.lua), so "optional field" is not a thing that can exist
--               here -- see D28.
--   override    apply the player's own choices on top, field by field, with the
--               same completion rules. A player override never has to be whole.
--   palette     apply the skin's tint to the six semantic colours, evenly, so
--               that the RELATIONS between them survive (D29).
--   guarantee   walk back any tint that made two sources too close to tell
--               apart. A skin may change how the bar feels; it may not change
--               what it says.
--
-- Nothing here touches the client, and nothing here is a class: it is a pure
-- function from tables to a table.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local SkinShape = ns.core.SkinShape

local SkinResolver = {}

-- ---------------------------------------------------------------------------
-- Completion (2.2)
-- ---------------------------------------------------------------------------

-- Recursive on purpose: a skin is two levels deep (border.color, fill.gloss),
-- and a player who overrides only `border.thickness` must not lose
-- `border.color` on the way through.
--
-- `given` may be nil, may be of the wrong type, may carry keys this version has
-- never heard of. All three collapse to the same outcome: the shape wins. That
-- is deliberate -- this is the boundary that saved variables, imported presets
-- and hand-edited files all arrive through, and none of them is trustworthy.
-- Reading a key off a table that MIGHT be frozen. Both sides of this module's
-- input can be: the catalogue is frozen like every other constant here, and the
-- player's overrides arrive out of an already-resolved settings table, which is
-- frozen too. Indexing a frozen table for a key it does not declare raises
-- (Frozen.lua), and "the key is not there" is the normal case for both -- a skin
-- states only what it changes. So every read below goes through this.
local function fieldOf(given, key)
  if Frozen.isFrozen(given) then
    if Frozen.has(given, key) then
      return given[key]
    end
    return nil
  end
  if type(given) == "table" then
    return given[key]
  end
  return nil
end

-- Public for the same reason it exists: a surface's OWN override map has to be
-- read by whoever decides what to do with it -- the plate asks whether the player
-- gave it a text size of its own before laying itself out -- and that map reaches
-- the caller out of a resolved settings table, frozen, where an axis nobody ever
-- stored RAISES instead of answering nil. Everything outside this module that
-- reads a partial appearance map goes through here rather than indexing it.
SkinResolver.fieldOf = fieldOf

local function complete(given, shape)
  local result = {}
  for key, fallback in Frozen.each(shape) do
    local value = fieldOf(given, key)
    if Frozen.isFrozen(fallback) then
      result[key] = complete(value, fallback)
    elseif value ~= nil and type(value) == type(fallback) then
      result[key] = value
    else
      result[key] = fallback
    end
  end
  return result
end

-- A skin as the catalogue states it -- only the fields it means to change --
-- completed to the full shape. The result is a plain table: freezing happens
-- once, at the end of resolve, not at every step.
function SkinResolver.normalize(skin)
  return complete(skin, SkinShape)
end

-- Apply the player's own choices on top of an already-complete skin. The base is
-- a plain table by now, not the frozen shape, so this walks it with pairs -- and
-- it is the base that decides which keys exist, which is what makes an override
-- carrying a key nobody declared a no-op instead of a surprise downstream.
local function overlay(base, given)
  if type(given) ~= "table" then
    return base
  end
  -- `base` is always plain (normalize built it), so pairs is right for it. Only
  -- `given` may be frozen, which is what fieldOf handles.

  for key, current in pairs(base) do
    local value = fieldOf(given, key)
    if type(current) == "table" then
      base[key] = overlay(current, value)
    elseif value ~= nil and type(value) == type(current) then
      base[key] = value
    end
  end
  return base
end

-- ---------------------------------------------------------------------------
-- Palette (2.6)
-- ---------------------------------------------------------------------------

-- Perceptual weights, not a plain average: green carries most of what the eye
-- reads as brightness, blue almost none. Used both to desaturate towards grey
-- and to measure how far apart two colours actually look.
local LUMA_R, LUMA_G, LUMA_B = 0.30, 0.59, 0.11

local function clamp01(value)
  if value < 0 then return 0 end
  if value > 1 then return 1 end
  return value
end

-- `scale` is how much of the skin's tint to actually apply, 0..1. It exists so
-- that the guarantee below can walk a tint back part of the way instead of
-- having to choose between the skin's full identity and none of it.
local function tinted(color, tint, scale)
  local amount = tint.amount * scale
  local saturation = 1 + (tint.saturation - 1) * scale
  local brightness = 1 + (tint.brightness - 1) * scale

  local gray = color.r * LUMA_R + color.g * LUMA_G + color.b * LUMA_B
  local r = gray + (color.r - gray) * saturation
  local g = gray + (color.g - gray) * saturation
  local b = gray + (color.b - gray) * saturation

  r = r + (tint.towards.r - r) * amount
  g = g + (tint.towards.g - g) * amount
  b = b + (tint.towards.b - b) * amount

  return {
    r = clamp01(r * brightness),
    g = clamp01(g * brightness),
    b = clamp01(b * brightness),
    a = color.a or 1,
  }
end

-- How far apart the two closest colours in a palette look. Weighted the same way
-- as the desaturation above, so "far apart" means far apart to an eye rather
-- than far apart in the cube.
local function closestPair(colors, order)
  local closest
  for i = 1, #order do
    for j = i + 1, #order do
      local a, b = colors[order[i]], colors[order[j]]
      local dr, dg, db = a.r - b.r, a.g - b.g, a.b - b.b
      local distance = math.sqrt(dr * dr * LUMA_R + dg * dg * LUMA_G + db * db * LUMA_B)
      if closest == nil or distance < closest then
        closest = distance
      end
    end
  end
  return closest or 0
end

-- The floor a tint may not push the palette below, as a fraction of how far
-- apart the domain's own colours already are. Relative rather than absolute on
-- purpose: the palette is what defines "distinguishable" around here, so the
-- guarantee is stated against it and survives someone re-tuning it.
local RETAINED_SEPARATION = 0.6

-- How far the tint is walked back on each attempt before giving up on it
-- entirely. Four steps is enough to land on something usable for any tint that
-- is recoverable at all, and stopping is not a failure: SEMANTIC is always a
-- correct answer, just a less characterful one.
local WALKBACK = { 1, 0.66, 0.33, 0 }

-- ---------------------------------------------------------------------------
-- Resolution (2.3, 2.4)
-- ---------------------------------------------------------------------------

-- The catalogue entry for `id`, or the default one. An id that is not there is
-- the expected case, not an error: saved data outlives versions, a preset may
-- come from a newer build, and the file is editable by hand. Losing the skin is
-- survivable; refusing to draw the bar is not.
function SkinResolver.skinFor(catalog, id, defaultId)
  if type(id) == "string" and Frozen.has(catalog, id) then
    return catalog[id]
  end
  return catalog[defaultId]
end

-- `options`:
--   skin          a catalogue entry (partial; only what it means to change)
--   overrides     the player's own choices (partial, same shape), optional
--   own           a SECOND layer of the player's choices, applied on top of the
--                 one above and belonging to one surface rather than to all of
--                 them (D87). The pull plate follows the bar's skin and the bar's
--                 own tweaks and may then adjust a handful of axes for itself; an
--                 axis it does not state keeps following the bar, which is what
--                 makes a plate tweak survive the bar changing skin.
--   palette       the semantic colours, ns.core.Palette or a stand-in
--   highContrast  true to ignore every tint and show the palette untouched
--
-- Returns a frozen table: the skin's own fields, plus `colors` (the palette as
-- it should actually be painted) and `tintScale` (how much of the skin's tint
-- survived the guarantee -- carried so a diagnostic can say so rather than
-- leaving the player wondering why a skin looks tamer than advertised).
function SkinResolver.resolve(options)
  options = options or {}
  local palette = options.palette
  if palette == nil then
    error("SkinResolver.resolve needs a palette", 2)
  end

  -- Two passes and not a merge of the two maps, because `overlay` already walks a
  -- COMPLETE base field by field: laying the second layer over the result of the
  -- first says "whatever this one states wins, and whatever it leaves out keeps
  -- what the layer below decided" without anyone having to deep-merge two partial
  -- tables and get the nesting right.
  local appearance = overlay(SkinResolver.normalize(options.skin), options.overrides)
  appearance = overlay(appearance, options.own)

  -- Where the caller knows something about the frame that no skin can: a bar
  -- given the height of the client's own is too thin for text inside it, and the
  -- text has to move out (D52). Applied here, while the appearance is still a
  -- plain table, because the only other way is to copy a frozen one afterwards --
  -- and a frozen table cannot be walked with `pairs`, so that copy silently comes
  -- back with one key in it.
  if options.textAnchor ~= nil then
    appearance.text.anchor = options.textAnchor
  end

  local order = Frozen.keys(palette)
  local semantic = {}
  for key, color in Frozen.each(palette) do
    -- `a` is filled in here and never left out, which is the same rule D28 states
    -- for skins applied to the palette: what comes out of this module is frozen,
    -- and reading a key that is not there off a frozen table RAISES rather than
    -- returning nil. The domain's palette carries only r/g/b, so a drawer asking
    -- for alpha -- which every drawer does -- would blow up mid-redraw.
    semantic[key] = { r = color.r, g = color.g, b = color.b, a = fieldOf(color, "a") or 1 }
  end

  local tint = appearance.tint
  local scale = 0
  if not options.highContrast and tint.mode == ns.core.ColorMode.MODULATED then
    -- The floor is measured against the untouched palette, so a skin is only
    -- ever asked to preserve separation the domain actually had to begin with.
    local floor = closestPair(semantic, order) * RETAINED_SEPARATION
    for _, attempt in ipairs(WALKBACK) do
      local candidate = {}
      for key, color in pairs(semantic) do
        candidate[key] = tinted(color, tint, attempt)
      end
      if attempt == 0 or closestPair(candidate, order) >= floor then
        scale = attempt
        break
      end
    end
  end

  local colors = {}
  for key, color in pairs(semantic) do
    colors[key] = scale > 0 and tinted(color, tint, scale) or color
  end

  -- A colour the player chose outright wins over both the palette and the skin's
  -- tint, and is NOT walked back by the separation guarantee above: that
  -- guarantee exists to stop a SKIN from quietly blurring two sources together,
  -- not to overrule someone who picked a colour on purpose. Normalised to a
  -- complete r/g/b/a on the way in, for the same reason every other colour here
  -- is (D28).
  local overrides = options.colors
  if overrides ~= nil then
    for key in pairs(colors) do
      local chosen = fieldOf(overrides, key)
      if type(chosen) == "table" then
        local r, g, b = fieldOf(chosen, "r"), fieldOf(chosen, "g"), fieldOf(chosen, "b")
        if type(r) == "number" and type(g) == "number" and type(b) == "number" then
          colors[key] = { r = clamp01(r), g = clamp01(g), b = clamp01(b), a = fieldOf(chosen, "a") or 1 }
        end
      end
    end
  end

  appearance.colors = colors
  appearance.tintScale = scale
  return Frozen.enum("Appearance", appearance)
end

ns.core.SkinResolver = SkinResolver
