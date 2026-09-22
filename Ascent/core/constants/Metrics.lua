-- Ascent - combat metric vocabulary.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

-- One id per collector. Adding a metric means registering a collector under a new
-- id; the level tracker never learns about it.
ns.core.MetricId = Frozen.enum("MetricId", {
  ABILITY_USAGE  = "ability_usage",
  COMBAT_OUTCOME = "combat_outcome", -- health and resource on leaving combat
  DEATHS         = "deaths",
  TIME           = "time",           -- in combat, out of combat, recovering, dead
  DAMAGE         = "damage",         -- dealt, taken, healing received
  EFFICIENCY     = "efficiency",     -- xp per minute of combat, xp per creature
  PLACE_TIME     = "place_time",     -- how long the level spent in each place
})

-- The life of one pull, as a closed set. SETTLING exists because in Classic the
-- experience for a kill arrives as a chat message, correlated with the combat
-- log's UNIT_DIED inside a window of a second and a half, and PLAYER_REGEN_ENABLED
-- can fire before it: freezing the numbers when combat ends would under-report the
-- last kill of most fights. Combat ending starts a countdown during which the
-- record still accepts what was in flight, and combat resuming cancels it, so a
-- chain of pulls with adds arriving seconds apart reads as one fight.
ns.core.PullPhase = Frozen.enum("PullPhase", {
  IDLE     = "idle",     -- nothing open
  ACTIVE   = "active",   -- in combat, recording
  SETTLING = "settling", -- combat ended, still accepting what was in flight
  CLOSED   = "closed",   -- final, readable until the next pull replaces it
})

-- Auto attacks have no spell id. Rather than let the domain meet a nil key, they
-- get reserved synthetic ones, and they are reported as their own category so the
-- ranking of real abilities is not drowned by them.
ns.core.AbilityKey = Frozen.enum("AbilityKey", {
  MELEE_SWING = "melee_swing",
  RANGED_AUTO = "ranged_auto",
})
