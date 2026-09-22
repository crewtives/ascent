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
  -- Whether the bar takes over the client's own (BarSlot below).
  BAR_SLOT           = "bar_slot",
  -- The bar says nothing until the cursor is on it.
  BAR_TEXT_ON_HOVER  = "bar_text_on_hover",
  BAR_APPEARANCE     = "bar_appearance", -- the player's own tweaks on top of that skin
  BAR_COLORS         = "bar_colors",     -- colours the player picked, per source
  HIGH_CONTRAST      = "high_contrast",  -- ignore every skin tint, show the palette raw
  MOTION_SCALE       = "motion_scale",   -- 1 is full, 0 is no animation at all
  -- The pull plate: the frame that counts a fight while it happens and becomes a
  -- plaque when it ends. Its position is not shared with the bar's: the two are
  -- read at different moments and usually wanted in different places.
  PLATE_ENABLED      = "plate_enabled",
  PLATE_POSITION     = "plate_position",
  -- Its own lock, not the bar's. The bar is placed once and locked for good, the
  -- plate moves whenever the fighting does, and the bar slot disables the bar's
  -- lock when it suspends the bar's position, which must not decide whether the
  -- plate can be dragged.
  PLATE_LOCKED       = "plate_locked",
  PLATE_SCALE        = "plate_scale",
  PLATE_WIDTH        = "plate_width",  -- the plate's own width, independent of PLATE_SCALE
  -- A factor on the alpha the plate is drawn with at each instant, never the
  -- frame's alpha itself: that channel is how the plate fades out, so a setting
  -- written into it would fight the fade every frame and the last write would win.
  PLATE_OPACITY      = "plate_opacity",
  -- How long the finished plaque stays before it fades, and with it how long a
  -- closed pull can still be resumed. One number for both: a pull continues while
  -- it is still on screen, so stretching what is seen stretches what can continue.
  PLATE_HOLD_SECONDS = "plate_hold_seconds",
  PLATE_ROWS         = "plate_rows",   -- creature and ability rows shown; the rows built are the ceiling
  PLATE_ZONES        = "plate_zones",  -- which accessory zones are drawn (PlateZone below)
  PLATE_APPEARANCE   = "plate_appearance", -- the player's own tweaks on top of the bar's resolved skin

  EVIDENCE           = "evidence", -- the flight recorder: file only, never chat
  -- Whether the addon asks the server for time played on entering the world.
  -- On by default; turning it off lets a login show whether the server sends it
  -- unasked. A setting rather than a command because the request fires during the
  -- loading screen, so nothing typed afterwards could precede it.
  TIME_SYNC          = "time_sync",
  -- The peer version check, and what it remembers between sessions. Both live in
  -- the account settings and not per character: a player updates the addon once,
  -- not once per alt, and the upgrade notice would otherwise fire on every one.
  UPDATE_CHECK       = "update_check",
  -- The version this addon last ran as. Empty means "never seen", which is what a
  -- fresh install reads as -- and why the default is a string rather than nil: a
  -- key with no default is a key `Settings.resolve` drops and `unknownKeys`
  -- reports as junk.
  LAST_SEEN_VERSION  = "last_seen_version",
  DEBUG              = "debug",
})

-- Where the bar lives. OFF is the addon's own bar, free on the screen, with the
-- client's experience bar left alone. It is the default, so an update never moves
-- anyone's bar.
--
-- The other two take over the place of the client's bar: INSET leaves the frame
-- around it visible and draws inside it, REPLACE silences that frame too. Both
-- inherit position and size from the client's bar, and neither inherits its
-- visibility.
ns.core.BarSlot = Frozen.enum("BarSlot", {
  OFF     = "off",
  INSET   = "inset",
  REPLACE = "replace",
})

-- The accessory zones of the pull plate, one word per thing the player can turn
-- off. The headline figure and its kill count are deliberately absent: they are
-- the reason the plate appears at all.
--
-- Order is not part of this vocabulary. These strings are persisted, and the
-- order the plate reads in belongs to its layout, not to the order a saved file
-- happens to list them in.
ns.core.PlateZone = Frozen.enum("PlateZone", {
  CLOCK     = "clock",     -- how long the fight has been going
  REMAINING = "remaining", -- what the level still needs, not what the pull paid
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

-- The client sources whose absence a level record has to remember. A capability
-- that is off right now is a fact about this session; one that was off while a
-- level was being recorded is a fact about that level, and it stays true when the
-- level is opened later on a client that has the source. Only these two feed what
-- a record keeps -- the quest log and the client's bar are about now, not about a
-- level -- and the values are the capability names the registry uses, so the two
-- vocabularies cannot drift.
ns.core.RecordedSource = Frozen.enum("RecordedSource", {
  -- ability counts, damage and healing, and the kills that paid nothing
  COMBAT_LOG = "combat_log",
  -- the line that names where a gain came from
  XP_CHAT    = "xp_chat",
})

-- Why a source was off, in the one vocabulary a level record keeps and the
-- capability registry answers with (adapter/compat/Capabilities.lua reads these
-- rather than spelling the strings again). A reason outside it is not kept: every
-- surface looks its sentence up by it, and the lookup is strict.
ns.core.SourceState = Frozen.enum("SourceState", {
  -- the client does not have it at all
  ABSENT     = "absent",
  -- the client has it but returns secret values (World of Warcraft: Forever)
  UNREADABLE = "unreadable",
})

-- The migration chain is wired from version 1, and RecordStore.MIGRATIONS holds a
-- step for every version below the current one: adding a migration is writing a
-- function and a test.
--
--   1 -> 2   a level record gained its per-place breakdown. The stored shape did
--            not change; the version moved so that a file at 2 is known to be
--            stamped by a build that records places, and a record in it with no
--            places reads as written before they were recorded, not as one whose
--            places went missing.
--   2 -> 3   a level record gained `seededXp`, the part of its UNKNOWN that was
--            seeded when the level was opened part-way through. Converts nothing,
--            for the same reason as the step above: a record at 2 genuinely cannot
--            say how much of its unclassified experience was seeded, so the field
--            restores nil -- "never recorded" -- rather than zero, which would
--            claim the whole of it was observed and left unattributed.
--   3 -> 4   a per-creature aggregate gained the size of the group the kills were
--            paid to. This step converts rather than defaults: the group is
--            written ahead of the creature's key, because the key is the line's
--            tail and trailing empties are dropped, so every stored creature line
--            shifts by one field. The step rewrites them with that field left
--            blank -- unknown, never one -- because a level recorded before this
--            cannot say who was standing there.
--   4 -> 5   a level record gained `unavailable`, the client sources it was
--            recorded without. Converts nothing: both classic clients always had
--            both sources, so a record written at 4 correctly restores with no mark.
ns.core.SchemaVersion = Frozen.enum("SchemaVersion", {
  CURRENT = 5,
})
