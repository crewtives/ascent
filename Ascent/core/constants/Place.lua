-- Ascent - where experience was earned.
--
-- A dimension of its own, orthogonal to XpSource: a creature killed inside a
-- dungeon is still a mob kill, and a quest turned in there is still a turn-in.
-- A "dungeon" source would force every gain to choose between two facts it knows,
-- and would silently change the meaning of every `mob_kill` already on disk.
--
-- These string values are persisted with the level record, so they are part of the
-- on-disk format: changing one is a schema migration, not a rename.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

-- What kind of place the character was in. The client answers this question in its
-- own vocabulary -- "none", "party", "raid", "pvp", "arena" -- and the translation
-- lives in the adapter, because the client's words are not the domain's.
--
-- UNKNOWN is a first-class member rather than a failure mode, for the same reason
-- XpSource.UNKNOWN is: the client cannot always say where the character is -- a
-- loading screen, the instant a portal is crossed -- and that experience still has
-- to land somewhere visible instead of disappearing or being filed under the last
-- place that happened to be known.
ns.core.PlaceContext = Frozen.enum("PlaceContext", {
  WORLD        = "world",
  DUNGEON      = "dungeon",
  RAID         = "raid",
  BATTLEGROUND = "battleground",
  ARENA        = "arena",
  UNKNOWN      = "unknown",
})
