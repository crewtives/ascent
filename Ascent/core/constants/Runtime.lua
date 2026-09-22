-- Ascent - runtime vocabulary.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

ns.core.SettingKey = Frozen.enum("SettingKey", {
  RECOVERY_THRESHOLD = "recovery_threshold", -- fraction of health/resource that counts as recovered
  RETENTION_LIMIT    = "retention_limit",    -- individual gains kept per level
  BAR_TEXT_TOKENS    = "bar_text_tokens",
  COLLECT_DAMAGE     = "collect_damage",
  SHOW_QUEST_PENDING = "show_quest_pending",
  BAR_LOCKED         = "bar_locked",
  BAR_SCALE          = "bar_scale",
  BAR_POSITION       = "bar_position",   -- saved anchor point/x/y for the xp bar
  PANEL_POSITION     = "panel_position", -- saved anchor point/x/y/width/height for the report panel
  HIDE_WITHOUT_XP    = "hide_without_xp",    -- at max level or with gain disabled
  BAR_WIDTH          = "bar_width",      -- the bar's own width, independent of BAR_SCALE
  BAR_HEIGHT         = "bar_height",
  BAR_SKIN           = "bar_skin",       -- an id in core/registry/SkinCatalog.lua
  BAR_SLOT           = "bar_slot",
  -- The bar says nothing until the cursor is on it.
  BAR_TEXT_ON_HOVER  = "bar_text_on_hover",       -- whether the bar takes over the client's own (BarSlot below)
  BAR_APPEARANCE     = "bar_appearance", -- the player's own tweaks ON TOP of that skin
  BAR_COLORS         = "bar_colors",     -- colours the player picked, per source
  HIGH_CONTRAST      = "high_contrast",  -- ignore every skin tint, show the palette raw
  MOTION_SCALE       = "motion_scale",   -- 1 is full, 0 is no animation at all (D33)
  -- The pull plate: the frame that counts a fight while it happens and becomes a
  -- plaque when it ends. Position is its own rather than shared with the bar --
  -- the two are read at different moments and a player who wants one at the
  -- bottom wants the other somewhere else.
  PLATE_ENABLED      = "plate_enabled",
  PLATE_POSITION     = "plate_position",
  -- Its own lock, deliberately not the bar's (D88). The two have opposite
  -- ergonomics -- the bar is placed once and locked for good, the plate moves
  -- whenever the fighting does -- and sharing one meant the bar slot, which
  -- disables the bar's lock when it suspends its position, silently decided
  -- whether the plate could be dragged.
  PLATE_LOCKED       = "plate_locked",
  PLATE_SCALE        = "plate_scale",
  PLATE_WIDTH        = "plate_width",  -- the plate's own width, independent of PLATE_SCALE
  -- A FACTOR on the alpha the plate is drawn with at each instant, never the
  -- frame's alpha itself: that channel IS how the plate fades out, so a setting
  -- written into it would fight the fade every frame and the last write would
  -- win (D91).
  PLATE_OPACITY      = "plate_opacity",
  -- How long the finished plaque stays before it fades -- and with it, how long a
  -- closed pull can still be resumed. One number for both on purpose: the spec
  -- says a pull continues while it is still on screen, so stretching what is seen
  -- stretches what can be continued (D89).
  PLATE_HOLD_SECONDS = "plate_hold_seconds",
  PLATE_ROWS         = "plate_rows",   -- creature and ability rows SHOWN; the rows built are the ceiling
  PLATE_ZONES        = "plate_zones",  -- which accessory zones are drawn (PlateZone below)
  PLATE_APPEARANCE   = "plate_appearance", -- the player's own tweaks ON TOP of the bar's resolved skin

  EVIDENCE           = "evidence", -- the flight recorder: file only, never chat
  -- Whether the addon asks the server for time played on entering the world.
  -- On by default and left alone by every normal path: it exists so spike 0.6
  -- can log in WITHOUT asking and see whether the server volunteers it anyway.
  -- A setting rather than a command because the request fires during the
  -- loading screen, so nothing typed afterwards could precede it.
  TIME_SYNC          = "time_sync",
  -- The peer version check, and what it remembers between sessions. Both live in
  -- the ACCOUNT settings and not per character: a player updates the addon once,
  -- not once per alt, and the upgrade notice would otherwise fire on every one of
  -- them (D72).
  UPDATE_CHECK       = "update_check",
  -- The version this addon last ran as. Empty means "never seen", which is what a
  -- fresh install reads as -- and why the default is a string rather than nil: a
  -- key with no default is a key `Settings.resolve` drops and `unknownKeys`
  -- reports as junk.
  LAST_SEEN_VERSION  = "last_seen_version",
  DEBUG              = "debug",
})

-- Where the bar lives. OFF is the addon's own bar, free on the screen, with the
-- client's experience bar left alone -- the behaviour every existing install has,
-- and the default, so an update never moves anyone's bar.
--
-- The other two take over the place of the client's bar: INSET leaves the frame
-- around it visible and draws inside it, REPLACE silences that frame too. Both
-- inherit position and size from the client's bar, and neither inherits its
-- visibility (D48).
ns.core.BarSlot = Frozen.enum("BarSlot", {
  OFF     = "off",
  INSET   = "inset",
  REPLACE = "replace",
})

-- The accessory zones of the pull plate, one word per thing the player can turn
-- off. The headline figure and its kill count are deliberately absent: they are
-- the reason the plate appears at all, and a frame that shows up in combat
-- without them is an empty frame with decoration (D90).
--
-- Order is not part of this vocabulary either. These strings are persisted, and
-- the order the plate reads in -- what you got, against what, what is left, where
-- it came from -- belongs to whoever lays it out, not to whatever order a saved
-- file happens to list them in.
ns.core.PlateZone = Frozen.enum("PlateZone", {
  CLOCK     = "clock",     -- how long the fight has been going
  REMAINING = "remaining", -- what the LEVEL still needs, not what the pull paid
  STREAK    = "streak",    -- the running kill chain
  SOURCES   = "sources",   -- the chip row: the pull's experience split by source
  CREATURES = "creatures",
  ABILITIES = "abilities",
  FOOTER    = "footer",    -- damage per second and experience per hour
})

ns.core.ClientFlavor = Frozen.enum("ClientFlavor", {
  CLASSIC_ERA     = "classic_era",
  BURNING_CRUSADE = "burning_crusade",
  FOREVER         = "forever",
  UNKNOWN         = "unknown",
})

-- The migration chain is wired from version 1, and RecordStore.MIGRATIONS holds a
-- step for every version below the current one: adding a migration is writing a
-- function and a test, not redesigning persistence under pressure.
--
--   1 -> 2   a level record gained its per-place breakdown. Nothing in the stored
--            shape had to change for it, which is exactly why the version moved:
--            a file at 2 is one this build has seen and stamped, and a record in
--            it with no places is a record written before they were recorded --
--            not one whose places went missing.
--   2 -> 3   a level record gained `seededXp`, the part of its UNKNOWN that was
--            seeded when the level was opened part-way through. Converts nothing,
--            for the same reason as the step above: a record at 2 genuinely cannot
--            say how much of its unclassified experience was seeded, so the field
--            restores nil -- "never recorded" -- rather than zero, which would
--            claim the whole of it was observed and left unattributed.
--   3 -> 4   a per-creature aggregate gained the size of the group the kills were
--            paid to. The first step that CONVERTS rather than defaults: the group
--            had to be written ahead of the creature's key, because the key is the
--            line's tail and trailing empties are dropped, so every stored creature
--            line shifts by one field. The step rewrites them with that field left
--            blank -- unknown, never one -- because a level recorded before this
--            distinction cannot say who was standing there (D84).
ns.core.SchemaVersion = Frozen.enum("SchemaVersion", {
  CURRENT = 4,
})
