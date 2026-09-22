-- Ascent - turning a skin plus the player's own choices into one painted form.
--
-- The only module that knows what a skin name means. Everything downstream
-- paints the table this returns without asking which skin it came from, so the
-- drawing code has no branch per skin. A pure function from tables to a table,
-- in this order:
--
--   normalize   fill every field of a possibly-partial skin from SkinShape.
--               Frozen proxies raise on a missing key rather than returning nil
--               (Frozen.lua), so no field downstream may be optional.
--   override    apply the player's choices on top, field by field, with the
--               same completion rules. An override never has to be whole.
--   palette     apply the skin's tint to the semantic colours evenly, so the
--               relations between them survive.
--   guarantee   walk back any tint that made two sources too close to tell
--               apart. A skin may change how the bar feels, not what it says.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local SkinShape = ns.core.SkinShape

local SkinResolver = {}

-- ---------------------------------------------------------------------------
-- Completion
-- ---------------------------------------------------------------------------

-- Reads a key off a table that may be frozen. Both inputs can be: the catalogue
-- is a frozen constant and the overrides come from a resolved, frozen settings
-- table. Indexing a frozen table for an undeclared key raises (Frozen.lua), and
-- a missing key is the normal case since a skin states only what it changes.
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

-- Public because a surface's own override map arrives frozen from resolved
-- settings, where an unstored axis raises instead of answering nil (the plate
-- asks whether it has its own text size). Anything outside this module reading
-- a partial appearance map goes through here.
SkinResolver.fieldOf = fieldOf

-- Recursive: a skin is two levels deep (border.color, fill.gloss), and
-- overriding only `border.thickness` must keep `border.color`.
--
-- `given` may be nil, of the wrong type, or carry unknown keys; in every case
-- the shape wins. Saved variables, imported presets and hand-edited files all
-- arrive through here.
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

-- A skin as the catalogue states it (only the fields it changes), completed to
-- the full shape. The result is a plain table: freezing happens once, at the
-- end of resolve.
function SkinResolver.normalize(skin)
  return complete(skin, SkinShape)
end

-- Applies the player's choices on top of an already-complete skin. The base
-- decides which keys exist, so an override carrying an undeclared key is a
-- no-op.
local function overlay(base, given)
  if type(given) ~= "table" then
    return base
  end
  -- `base` is always plain (normalize built it), so pairs works on it; only
  -- `given` may be frozen, which fieldOf handles.

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
-- Palette
-- ---------------------------------------------------------------------------

-- Perceptual weights, not a plain average: green carries most of perceived
-- brightness, blue almost none. Used both to desaturate towards grey and to
-- measure how far apart two colours look.
local LUMA_R, LUMA_G, LUMA_B = 0.30, 0.59, 0.11

local function clamp01(value)
  if value < 0 then return 0 end
  if value > 1 then return 1 end
  return value
end

-- `scale` is how much of the skin's tint to apply, 0..1, so the guarantee below
-- can walk a tint back part of the way.
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

-- How far apart the two closest colours in a palette look, weighted like the
-- desaturation above so distance is perceptual rather than in the RGB cube.
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

-- The separation floor a tint may not push the palette below, as a fraction of
-- the untinted palette's own closest pair. Relative, so it holds if the palette
-- is re-tuned.
local RETAINED_SEPARATION = 0.6

-- The tint scales tried in turn. The last, 0, is the untinted palette, which is
-- always a correct answer.
local WALKBACK = { 1, 0.66, 0.33, 0 }

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------

-- The catalogue entry for `id`, or the default one. An unknown id is expected,
-- not an error: saved data outlives versions, a preset may come from a newer
-- build, and the file is editable by hand. The bar must still draw.
function SkinResolver.skinFor(catalog, id, defaultId)
  if type(id) == "string" and Frozen.has(catalog, id) then
    return catalog[id]
  end
  return catalog[defaultId]
end

-- `options`:
--   skin          a catalogue entry (partial; only what it means to change)
--   overrides     the player's own choices (partial, same shape), optional
--   own           a second layer of the player's choices, on top of the one
--                 above, belonging to one surface. The pull plate follows the
--                 bar's skin and tweaks and adjusts a few axes of its own; an
--                 axis it does not state keeps following the bar, so a plate
--                 tweak survives the bar changing skin.
--   palette       the semantic colours, ns.core.Palette or a stand-in
--   highContrast  true to ignore every tint and show the palette untouched
--
-- Returns a frozen table: the skin's fields, plus `colors` (the palette as it
-- should be painted) and `tintScale` (how much of the tint survived the
-- guarantee, so a diagnostic can explain a skin that looks tamer than expected).
function SkinResolver.resolve(options)
  options = options or {}
  local palette = options.palette
  if palette == nil then
    error("SkinResolver.resolve needs a palette", 2)
  end

  -- Two passes rather than merging the two maps: `overlay` walks a complete base
  -- field by field, so the second layer wins where it states a value and the
  -- first holds elsewhere, with no deep merge of two partial tables.
  local appearance = overlay(SkinResolver.normalize(options.skin), options.overrides)
  appearance = overlay(appearance, options.own)

  -- The caller may know something about the frame no skin can: a bar at the
  -- client's own bar height is too thin for text inside it, so the text moves
  -- out. Applied while the appearance is still plain: a frozen table cannot be
  -- walked with `pairs`, so copying one afterwards would silently lose keys.
  if options.textAnchor ~= nil then
    appearance.text.anchor = options.textAnchor
  end

  local order = Frozen.keys(palette)
  local semantic = {}
  for key, color in Frozen.each(palette) do
    -- `a` is always filled in: the result is frozen, reading a missing key off
    -- a frozen table raises, and the domain palette carries only r/g/b while
    -- every drawer reads alpha.
    semantic[key] = { r = color.r, g = color.g, b = color.b, a = fieldOf(color, "a") or 1 }
  end

  local tint = appearance.tint
  local scale = 0
  if not options.highContrast and tint.mode == ns.core.ColorMode.MODULATED then
    -- The floor is measured against the untinted palette, so a skin is only
    -- asked to preserve separation the palette already had.
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

  -- A colour the player chose outright wins over the palette and the tint, and
  -- is not walked back: the guarantee stops a skin from blurring two sources,
  -- not a player's deliberate choice. Normalised to a complete r/g/b/a like
  -- every other colour here.
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
