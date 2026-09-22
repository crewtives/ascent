-- Ascent - the skins, as data.
--
-- Each entry states only what it changes; SkinResolver.normalize fills the rest
-- from SkinShape, so a new skin is a combination of orthogonal axes rather than
-- a code path. No skin needs a packaged texture: every fill kind is a client
-- primitive. `effects` is what a skin does when experience lands, drawn from the
-- vocabulary in core/constants/Appearance.lua; a skin with none is quiet.
-- A skin's identity lives in its background, border, separator and text. Its
-- tint applies evenly to all six source colours, and SkinResolver walks it back
-- if it would make two sources hard to tell apart.

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
  -- The default: nothing but a frame, a hairline and readable text.
  tabard = {
    background = { r = 0, g = 0, b = 0, a = 0.55 },
    border = { kind = BorderKind.HAIRLINE, thickness = 1, color = { r = 0.6, g = 0.6, b = 0.62, a = 1 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 0, g = 0, b = 0, a = 0.55 } },
    text = { style = TextStyle.OUTLINE, anchor = TextAnchor.INSIDE_CENTER, size = 11,
             color = { r = 0.92, g = 0.92, b = 0.94, a = 1 } },
    accent = { r = 0.6, g = 0.6, b = 0.62, a = 1 },
    -- The quietest effect that still reads as an event: one soft wash, no band,
    -- no motes.
    effects = {
      glow = { kind = GlowKind.SOFT, color = { r = 0.95, g = 0.95, b = 1, a = 1 }, peak = 0.5, duration = 0.8 },
    },
  },

  -- Hard separators and a flat fill make every source colour in the bar legible
  -- in a single screenshot.
  cartographer = {
    background = { r = 0.02, g = 0.03, b = 0.04, a = 0.78 },
    border = { kind = BorderKind.HAIRLINE, thickness = 1, color = { r = 0.9, g = 0.92, b = 0.95, a = 0.9 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 0.95, g = 0.96, b = 1, a = 0.85 } },
    text = { style = TextStyle.OUTLINE, anchor = TextAnchor.BELOW, size = 10,
             color = { r = 0.85, g = 0.88, b = 0.92, a = 1 } },
    accent = { r = 0.9, g = 0.92, b = 0.95, a = 1 },
    -- One hard, short flash and nothing else.
    effects = {
      glow = { kind = GlowKind.BURST, color = { r = 1, g = 1, b = 1, a = 1 }, peak = 0.4, duration = 0.35 },
    },
  },

  -- Styled after the client's own status bars: a gradient and a gloss band.
  stormwind = {
    background = { r = 0.07, g = 0.06, b = 0.04, a = 0.85 },
    border = { kind = BorderKind.FRAME, thickness = 3, color = { r = 0.72, g = 0.6, b = 0.32, a = 1 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 0.72, g = 0.6, b = 0.32, a = 0.45 } },
    fill = { kind = FillKind.GRADIENT_UP, gloss = 0.14, glossHeight = 0.35 },
    text = { style = TextStyle.HEAVY, anchor = TextAnchor.INSIDE_CENTER, size = 11,
             color = { r = 0.98, g = 0.94, b = 0.82, a = 1 } },
    accent = { r = 0.72, g = 0.6, b = 0.32, a = 1 },
    -- The full vocabulary in gold, after the client's own loot alert: a wash, a
    -- band and a handful of motes.
    effects = {
      glow = { kind = GlowKind.SOFT, color = { r = 1, g = 0.86, b = 0.5, a = 1 }, peak = 0.75, duration = 0.9 },
      sweep = { kind = SweepKind.SHINE, color = { r = 1, g = 0.94, b = 0.76, a = 1 }, duration = 0.9 },
      burst = { kind = BurstKind.RISING, color = { r = 1, g = 0.84, b = 0.42, a = 1 },
                count = 5, rise = 60, spread = 18, stagger = 0.1, duration = 0.5 },
    },
  },

  -- The loudest gloss of the six. Its tint is the one most likely to be walked
  -- back on a re-tuned palette, which is expected.
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
    -- Light moving across a surface: the band, and no motes.
    effects = {
      glow = { kind = GlowKind.SOFT, color = { r = 0.82, g = 0.92, b = 1, a = 1 }, peak = 0.6, duration = 0.75 },
      sweep = { kind = SweepKind.SHINE, color = { r = 1, g = 1, b = 1, a = 1 }, duration = 0.7 },
    },
  },

  -- Instrument panel: small type, notched boundaries, one accent colour.
  telemetry = {
    background = { r = 0, g = 0, b = 0, a = 0.85 },
    border = { kind = BorderKind.HAIRLINE, thickness = 1, color = { r = 0.3, g = 0.85, b = 0.45, a = 0.8 } },
    separator = { kind = SeparatorKind.NOTCH, thickness = 2, color = { r = 0, g = 0, b = 0, a = 0.9 } },
    text = { style = TextStyle.PLAIN, anchor = TextAnchor.INSIDE_RIGHT, size = 10,
             color = { r = 0.3, g = 0.85, b = 0.45, a = 1 } },
    accent = { r = 0.3, g = 0.85, b = 0.45, a = 1 },
    tint = { mode = ColorMode.MODULATED, saturation = 0.9, brightness = 1.04,
             towards = { r = 0.1, g = 0.3, b = 0.15 }, amount = 0.06 },
    -- Motes in the panel's own green, more of them than any other skin uses, and
    -- only a brief flash behind them: the effect reads as a spiking reading.
    effects = {
      glow = { kind = GlowKind.BURST, color = { r = 0.3, g = 0.85, b = 0.45, a = 1 }, peak = 0.35, duration = 0.3 },
      burst = { kind = BurstKind.RISING, color = { r = 0.3, g = 0.95, b = 0.5, a = 1 },
                count = 7, rise = 48, spread = 14, stagger = 0.06, duration = 0.42 },
    },
  },

  -- No frame at all. With no background and no border, colour is the only cue
  -- left, so it states no tint.
  phantom = {
    background = { r = 0, g = 0, b = 0, a = 0 },
    border = { kind = BorderKind.NONE, thickness = 0, color = { r = 0, g = 0, b = 0, a = 0 } },
    separator = { kind = SeparatorKind.HAIRLINE, thickness = 1, color = { r = 0, g = 0, b = 0, a = 0.35 } },
    text = { style = TextStyle.OUTLINE, anchor = TextAnchor.ABOVE, size = 10,
             color = { r = 0.88, g = 0.88, b = 0.9, a = 0.9 } },
    accent = { r = 0.88, g = 0.88, b = 0.9, a = 0.6 },
    -- No effects either: there is no surface for a wash to sit on, and a band
    -- would be a bright rectangle crossing empty screen.
  },
})

-- The one every other resolution falls back to: an unknown id in saved data, a
-- preset from a future version, a hand-edited file.
ns.core.DEFAULT_SKIN_ID = "tabard"
