-- Ascent - the skins, as data (task 2.5).
--
-- Every entry here states ONLY what it changes; SkinResolver.normalize fills the
-- rest from SkinShape, so a skin is a handful of lines rather than forty fields
-- copied six times. That is the point of the axes being orthogonal (design D27):
-- these six are combinations, not implementations, and a seventh is another
-- combination rather than another code path.
--
-- None of these needs a packaged texture. That is not a limitation of the
-- catalogue, it is the first cut of it: the fill kinds below are primitives the
-- client has always had, so the whole catalogue works before a single .tga
-- exists, and ART skins join later without any of these changing.
--
-- Each entry now also states what it does at the moment something LANDS -- a
-- wash, a travelling band, a handful of rising motes. Those three are the whole
-- of the effect vocabulary (see core/constants/Appearance.lua), and they belong
-- here for the same reason the border does: they are part of what a skin IS, not
-- a feature layered on top of one. A skin that states none of them is not
-- broken, it is quiet.
--
-- On colour: a skin's identity lives in its background, border, separator and
-- text. What it may do to the six SOURCE colours is state a tint, applied evenly
-- to all of them -- and even that is walked back automatically if it would make
-- two sources hard to tell apart (D29, SkinResolver's guarantee). Three of the
-- six below do not tint at all, which is the honest default rather than a
-- missing feature: the colours ARE the information.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local FillKind = ns.core.FillKind
local BorderKind = ns.core.BorderKind
local SeparatorKind = ns.core.SeparatorKind
local TextStyle = ns.core.TextStyle
local TextAnchor = ns.core.TextAnchor
local ColorMode = ns.core.ColorMode
local GlowKind = ns.core.GlowKind
local SweepKind = ns.core.SweepKind
local BurstKind = ns.core.BurstKind

ns.core.SkinCatalog = Frozen.enum("SkinCatalog", {
  -- The default, and the one that has to be right before any other matters:
  -- nothing but a frame, a hairline and readable text. Everything a bar needs
  -- and not one thing more.
  tabard = {
    background = { r = 0, g = 0, b = 0, a = 0.55 },
    border = { kind = BorderKind.HAIRLINE, thickness = 1, color = { r = 0.6, g = 0.6, b = 0.62, a = 1 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 0, g = 0, b = 0, a = 0.55 } },
    text = { style = TextStyle.OUTLINE, anchor = TextAnchor.INSIDE_CENTER, size = 11,
             color = { r = 0.92, g = 0.92, b = 0.94, a = 1 } },
    accent = { r = 0.6, g = 0.6, b = 0.62, a = 1 },
    -- The default skin gets the quietest effect that still reads as an event:
    -- one soft wash, no band, no motes. A player who never opens the options
    -- should see something happen, and should not see a firework.
    effects = {
      glow = { kind = GlowKind.SOFT, color = { r = 0.95, g = 0.95, b = 1, a = 1 }, peak = 0.5, duration = 0.8 },
    },
  },

  -- The one that SELLS what Ascent is: hard separators and a flat fill make
  -- "this bar has four colours in it" legible in a single screenshot.
  cartographer = {
    background = { r = 0.02, g = 0.03, b = 0.04, a = 0.78 },
    border = { kind = BorderKind.HAIRLINE, thickness = 1, color = { r = 0.9, g = 0.92, b = 0.95, a = 0.9 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 0.95, g = 0.96, b = 1, a = 0.85 } },
    text = { style = TextStyle.OUTLINE, anchor = TextAnchor.BELOW, size = 10,
             color = { r = 0.85, g = 0.88, b = 0.92, a = 1 } },
    accent = { r = 0.9, g = 0.92, b = 0.95, a = 1 },
    -- An instrument does not sparkle. One hard, short flash and nothing else --
    -- which is also the honest reading of this skin: it is here to make four
    -- colours legible in a screenshot, not to celebrate.
    effects = {
      glow = { kind = GlowKind.BURST, color = { r = 1, g = 1, b = 1, a = 1 }, peak = 0.4, duration = 0.35 },
    },
  },

  -- As if it had shipped with the client. The gradient and the gloss band are
  -- what the client's own status bars have looked like since vanilla.
  stormwind = {
    background = { r = 0.07, g = 0.06, b = 0.04, a = 0.85 },
    border = { kind = BorderKind.FRAME, thickness = 3, color = { r = 0.72, g = 0.6, b = 0.32, a = 1 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 0.72, g = 0.6, b = 0.32, a = 0.45 } },
    fill = { kind = FillKind.GRADIENT_UP, gloss = 0.14, glossHeight = 0.35 },
    text = { style = TextStyle.HEAVY, anchor = TextAnchor.INSIDE_CENTER, size = 11,
             color = { r = 0.98, g = 0.94, b = 0.82, a = 1 } },
    accent = { r = 0.72, g = 0.6, b = 0.32, a = 1 },
    -- The full vocabulary, gold: this is the skin that is trying to look like
    -- the client's own loot alert, and the client's own loot alert is a wash, a
    -- band and a handful of motes.
    effects = {
      glow = { kind = GlowKind.SOFT, color = { r = 1, g = 0.86, b = 0.5, a = 1 }, peak = 0.75, duration = 0.9 },
      sweep = { kind = SweepKind.SHINE, color = { r = 1, g = 0.94, b = 0.76, a = 1 }, duration = 0.9 },
      burst = { kind = BurstKind.RISING, color = { r = 1, g = 0.84, b = 0.42, a = 1 },
                count = 5, rise = 60, spread = 18, stagger = 0.1, duration = 0.5 },
    },
  },

  -- Glass: the loudest gloss of the six, and the tint that goes with it is the
  -- one most likely to be walked back on a palette someone has re-tuned. That
  -- is the guarantee doing its job, not a bug in the skin.
  glass = {
    background = { r = 0.05, g = 0.07, b = 0.1, a = 0.5 },
    border = { kind = BorderKind.BEVEL, thickness = 1, color = { r = 0.8, g = 0.86, b = 0.95, a = 0.9 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 1, g = 1, b = 1, a = 0.7 } },
    fill = { kind = FillKind.GRADIENT_DN, gloss = 0.3, glossHeight = 0.45 },
    text = { style = TextStyle.OUTLINE, anchor = TextAnchor.INSIDE_CENTER, size = 11,
             color = { r = 1, g = 1, b = 1, a = 1 } },
    accent = { r = 0.8, g = 0.86, b = 0.95, a = 1 },
    tint = { mode = ColorMode.MODULATED, saturation = 1.08, brightness = 1.06,
             towards = { r = 0.85, g = 0.92, b = 1 }, amount = 0.08 },
    -- Glass is the skin whose whole idea is light moving across a surface, so
    -- it gets the band and skips the motes: a mote is a particle leaving the
    -- frame, and nothing leaves a pane of glass.
    effects = {
      glow = { kind = GlowKind.SOFT, color = { r = 0.82, g = 0.92, b = 1, a = 1 }, peak = 0.6, duration = 0.75 },
      sweep = { kind = SweepKind.SHINE, color = { r = 1, g = 1, b = 1, a = 1 }, duration = 0.7 },
    },
  },

  -- Instrument panel. Small type, notched boundaries, one accent colour doing
  -- all the talking.
  telemetry = {
    background = { r = 0, g = 0, b = 0, a = 0.85 },
    border = { kind = BorderKind.HAIRLINE, thickness = 1, color = { r = 0.3, g = 0.85, b = 0.45, a = 0.8 } },
    separator = { kind = SeparatorKind.NOTCH, thickness = 2, color = { r = 0, g = 0, b = 0, a = 0.9 } },
    text = { style = TextStyle.PLAIN, anchor = TextAnchor.INSIDE_RIGHT, size = 10,
             color = { r = 0.3, g = 0.85, b = 0.45, a = 1 } },
    accent = { r = 0.3, g = 0.85, b = 0.45, a = 1 },
    tint = { mode = ColorMode.MODULATED, saturation = 0.9, brightness = 1.04,
             towards = { r = 0.1, g = 0.3, b = 0.15 }, amount = 0.06 },
    -- Motes only, in the panel's own green, and more of them than anyone else
    -- uses: on an instrument panel a reading that spikes IS the event, so the
    -- effect is the spike rather than a light behind it.
    effects = {
      glow = { kind = GlowKind.BURST, color = { r = 0.3, g = 0.85, b = 0.45, a = 1 }, peak = 0.35, duration = 0.3 },
      burst = { kind = BurstKind.RISING, color = { r = 0.3, g = 0.95, b = 0.5, a = 1 },
                count = 7, rise = 48, spread = 14, stagger = 0.06, duration = 0.42 },
    },
  },

  -- No frame at all. This is the skin that depends most on the palette being
  -- left alone -- with no background and no border, colour is the only language
  -- left -- so it states no tint, deliberately.
  phantom = {
    background = { r = 0, g = 0, b = 0, a = 0 },
    border = { kind = BorderKind.NONE, thickness = 0, color = { r = 0, g = 0, b = 0, a = 0 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 0, g = 0, b = 0, a = 0.35 } },
    text = { style = TextStyle.OUTLINE, anchor = TextAnchor.ABOVE, size = 10,
             color = { r = 0.88, g = 0.88, b = 0.9, a = 0.9 } },
    accent = { r = 0.88, g = 0.88, b = 0.9, a = 0.6 },
    -- States no effect at all, on the same principle that makes it state no
    -- tint: with no background and no border there is no surface for a wash to
    -- sit on, and a band travelling across nothing is a bright rectangle
    -- crossing the player's screen for no reason.
  },
})

-- The one every other resolution falls back to: an unknown id in saved data, a
-- preset from a future version, a hand-edited file.
ns.core.DEFAULT_SKIN_ID = "tabard"
