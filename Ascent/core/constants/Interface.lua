-- Ascent - presentation vocabulary.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

-- The fields a player can compose the bar text from.
ns.core.TextToken = Frozen.enum("TextToken", {
  LEVEL          = "level",
  XP_CURRENT     = "xp_current",
  XP_MAX         = "xp_max",
  XP_PERCENT     = "xp_percent",
  XP_REMAINING   = "xp_remaining",
  RESTED         = "rested",
  XP_PER_HOUR    = "xp_per_hour",
  TIME_TO_LEVEL  = "time_to_level",
  TIME_ON_LEVEL  = "time_on_level",
  SESSION_TIME   = "session_time",
  QUEST_PENDING  = "quest_pending",
})

-- One colour per thing the bar can draw. Kept here rather than in the view so the
-- palette can be asserted in a test and swapped without touching drawing code.
ns.core.Palette = Frozen.enum("Palette", {
  MOB_KILL     = { r = 0.82, g = 0.38, b = 0.26 },
  QUEST_TURNIN = { r = 0.35, g = 0.62, b = 0.86 },
  EXPLORATION  = { r = 0.47, g = 0.76, b = 0.49 },
  UNKNOWN      = { r = 0.55, g = 0.55, b = 0.58 },
  RESTED       = { r = 0.29, g = 0.35, b = 0.72 },
  PENDING      = { r = 0.85, g = 0.71, b = 0.30 },
})
