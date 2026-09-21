-- Ascent - the vocabulary of appearance (tasks 2.1, 2.2).
--
-- A skin is DATA, never code (design D27). Nothing in here draws anything, and
-- nothing downstream branches on a skin's name: ui/ is handed a resolved table
-- of these tokens and paints it. That is what makes a seventh skin a row in a
-- table rather than a seventh code path.
--
-- Two shapes live here and they are not the same thing:
--
--   * The ENUMS (FillKind, BorderKind, ...) are the closed sets of choices an
--     axis offers. A typo in one fails at load, like every other constant in
--     this addon.
--   * SKIN_SHAPE is the COMPLETE form a skin must have by the time anything
--     reads it. It exists because of a specific hazard: Frozen.enum builds
--     strict proxies, so reading a key that is not there RAISES rather than
--     returning nil (see Frozen.lua). A skin that omitted an optional field
--     would not degrade -- it would interrupt a redraw with the player looking
--     at it. So nothing is optional: SkinResolver.normalize fills every field
--     from here before anything is frozen, and the catalogue only ever states
--     what it means to change.
--
-- Colours are plain {r, g, b, a} tables in 0..1, the same convention
-- core/constants/Interface.lua's Palette already uses.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local XpSource = ns.core.XpSource

-- How the earned portion of a segment is painted. ART is the one that needs a
-- packaged file; every other value is primitives only and always available,
-- which is why FLAT is the floor the others fall back to (design D30).
ns.core.FillKind = Frozen.enum("FillKind", {
  FLAT        = "flat",
  GRADIENT_UP = "gradient_up",   -- darker at the bottom, lighter at the top
  GRADIENT_DN = "gradient_dn",   -- the reverse: lit from below
  ART         = "art",           -- a greyscale texture, tinted per channel
})

ns.core.BorderKind = Frozen.enum("BorderKind", {
  NONE     = "none",
  HAIRLINE = "hairline",  -- one pixel, one colour
  BEVEL    = "bevel",     -- light above, dark below
  FRAME    = "frame",     -- a real frame with its own thickness
})

-- How two abutting segments are told apart. Every one of these is drawn ON the
-- boundary and none of them takes width from either side -- the widths are the
-- level's percentage and that is verified by tests older than this file.
ns.core.SeparatorKind = Frozen.enum("SeparatorKind", {
  NONE     = "none",
  HAIRLINE = "hairline",
  NOTCH    = "notch",     -- a short mark rather than a full-height line
})

-- ---------------------------------------------------------------------------
-- Effects: the vocabulary of things that happen ONCE, as opposed to the fields
-- above, which describe how something looks while it sits still.
--
-- Reverse-engineered from LS: Toasts rather than copied from it. Strip that
-- addon's assets away and its whole visual signature reduces to three moves,
-- none of which needs a packaged file:
--
--   * an additive wash over the frame that swells and fades (its .Glow)
--   * a bright band that travels across the frame exactly once (its .Shine)
--   * a handful of motes that climb out of the frame on staggered delays,
--     which is what reads as "particles" and is really five textures with
--     different start delays (its .Arrow1..5)
--
-- They live in the skin, next to the border and the fill, because they are the
-- same kind of statement: a skin says what Ascent looks like, and now also what
-- it looks like at the moment something happens. The pull plate is the first
-- surface to draw them; the bar and the report panel can ask for the same three
-- without any of this changing.
--
-- NONE is a real member of each, not an absence, for the same reason
-- ColorMode.SEMANTIC is a tint of zero: one code path, not two.
ns.core.GlowKind = Frozen.enum("GlowKind", {
  NONE  = "none",
  SOFT  = "soft",   -- a slow swell, the frame lit from inside
  BURST = "burst",  -- the same wash, harder and shorter
})

ns.core.SweepKind = Frozen.enum("SweepKind", {
  NONE  = "none",
  SHINE = "shine",  -- one bright band, left to right, once
})

ns.core.BurstKind = Frozen.enum("BurstKind", {
  NONE   = "none",
  RISING = "rising", -- motes that climb out of the frame and fade on the way
})

ns.core.TextStyle = Frozen.enum("TextStyle", {
  PLAIN   = "plain",
  OUTLINE = "outline",
  HEAVY   = "heavy",      -- thick outline plus a shadow
})

ns.core.TextAnchor = Frozen.enum("TextAnchor", {
  INSIDE_LEFT   = "inside_left",
  INSIDE_CENTER = "inside_center",
  INSIDE_RIGHT  = "inside_right",
  ABOVE         = "above",
  BELOW         = "below",
})

-- What a skin is allowed to do to the six semantic colours. SEMANTIC is not a
-- "no tint" special case handled elsewhere -- it is a tint whose amount is
-- zero, so there is one code path, not two (the same reasoning as D33's motion
-- scalar).
ns.core.ColorMode = Frozen.enum("ColorMode", {
  SEMANTIC = "semantic",   -- the palette exactly as the domain defines it
  MODULATED = "modulated", -- the skin's own saturation/brightness/tint applied
})

-- The bar's channels, in draw order, and the only place that order is stated.
-- BarTween indexes its boundary vector by these ids and the renderer paints
-- them in this sequence, so the two cannot drift apart.
--
-- `palette` is the key into ns.core.Palette; `alpha` is how solid that channel
-- is drawn. Rested and pending are not experience the player has earned -- one
-- is a reserve, the other a projection -- and drawing them at full strength
-- would make the bar claim more progress than there is.
ns.core.BarChannel = Frozen.enum("BarChannel", {
  { id = XpSource.MOB_KILL,     palette = "MOB_KILL",     alpha = 1 },
  { id = XpSource.QUEST_TURNIN, palette = "QUEST_TURNIN", alpha = 1 },
  { id = XpSource.EXPLORATION,  palette = "EXPLORATION",  alpha = 1 },
  { id = XpSource.UNKNOWN,      palette = "UNKNOWN",      alpha = 1 },
  { id = "rested",                      palette = "RESTED",       alpha = 0.6 },
  { id = "pending",                     palette = "PENDING",      alpha = 0.75 },
})

-- The order text fields are given up in when the bar is too narrow to hold them
-- all (task 3.8). Stated as data, and stated once: the bar has to shed fields in
-- a predictable order, and "whatever fits" is not an order a player can learn.
-- Read back to front -- the LAST one is dropped first, so the level and the
-- percentage are the two that survive a very narrow bar.
ns.core.TEXT_PRIORITY = Frozen.enum("TEXT_PRIORITY", {
  ns.core.TextToken.LEVEL,
  ns.core.TextToken.XP_PERCENT,
  ns.core.TextToken.XP_CURRENT,
  ns.core.TextToken.XP_MAX,
  ns.core.TextToken.XP_REMAINING,
  ns.core.TextToken.RESTED,
  ns.core.TextToken.TIME_TO_LEVEL,
  ns.core.TextToken.XP_PER_HOUR,
  ns.core.TextToken.QUEST_PENDING,
  ns.core.TextToken.TIME_ON_LEVEL,
  ns.core.TextToken.SESSION_TIME,
})

-- The complete form of a skin. Read the module header before adding a field:
-- every one of these must have a value, always.
ns.core.SkinShape = Frozen.enum("SkinShape", {
  background = { r = 0, g = 0, b = 0, a = 0.6 },

  border = {
    kind = ns.core.BorderKind.NONE,
    thickness = 1,
    color = { r = 0.25, g = 0.25, b = 0.28, a = 1 },
  },

  separator = {
    kind = ns.core.SeparatorKind.NONE,
    thickness = 1,
    color = { r = 0, g = 0, b = 0, a = 0.5 },
  },

  fill = {
    kind = ns.core.FillKind.FLAT,
    -- 0 means no gloss band at all; the band is drawn additively over the top
    -- fraction of the bar when it is not.
    gloss = 0,
    glossHeight = 0.4,
  },

  text = {
    style = ns.core.TextStyle.OUTLINE,
    anchor = ns.core.TextAnchor.INSIDE_CENTER,
    color = { r = 1, g = 1, b = 1, a = 1 },
    size = 11,
  },

  -- Used by the border, the separator and anything else a skin wants to carry
  -- its identity in. Never by a segment's fill: that is the palette's job.
  accent = { r = 0.55, g = 0.55, b = 0.58, a = 1 },

  -- The modulation a skin applies to the semantic palette (design D29). It is
  -- applied evenly to all six channels, so the RELATIONS between them survive
  -- even when every one of them shifts.
  tint = {
    mode = ns.core.ColorMode.SEMANTIC,
    saturation = 1,   -- 1 keeps it, 0 is greyscale, above 1 deepens
    brightness = 1,
    towards = { r = 0, g = 0, b = 0 },
    amount = 0,       -- how far towards `towards`, 0..1
  },

  -- What the skin does at the instant something lands. Every duration here is
  -- multiplied by the player's motion scalar before it reaches a frame, so a
  -- scalar of zero means these have a duration of zero -- the same code path,
  -- arriving instantly (D33). Off by default: a skin opts in.
  effects = {
    glow = {
      kind = ns.core.GlowKind.NONE,
      color = { r = 1, g = 1, b = 1, a = 1 },
      peak = 0.7,        -- how opaque the wash gets at its brightest, 0..1
      duration = 0.7,    -- seconds from dark to bright to dark again
    },
    sweep = {
      kind = ns.core.SweepKind.NONE,
      color = { r = 1, g = 1, b = 1, a = 1 },
      duration = 0.85,
    },
    burst = {
      kind = ns.core.BurstKind.NONE,
      color = { r = 1, g = 1, b = 1, a = 1 },
      count = 5,         -- how many motes; the worst case a frame allocates
      rise = 56,         -- how far each one travels, in pixels
      spread = 18,       -- how far apart they start, horizontally
      stagger = 0.09,    -- seconds between one mote leaving and the next
      duration = 0.5,    -- how long one mote's own flight takes
    },
  },
})
