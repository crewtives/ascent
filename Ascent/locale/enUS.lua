-- Ascent - the base language table.
--
-- enUS is the base: every other language falls back to it key by key, so this is
-- the only table that has to be complete. LocaleSource_spec asserts that every
-- TextKey the source uses has an entry here.
--
-- Keys are TextKey values, never bare strings, so a typo fails when this file
-- loads instead of showing the player a blank label.
--
-- Command keywords ("show", "lock", "confirm", ...) are absent: the dispatcher
-- matches what the player types literally, so a translated keyword would let a
-- help line document a command that does not answer.

local _, ns = ...
ns.locale = ns.locale or {}
ns.locale.tables = ns.locale.tables or {}

local TextKey = ns.core.TextKey

ns.locale.tables.enUS = {
  [TextKey.SOURCE_CREATURES]       = "Creatures",
  [TextKey.SOURCE_QUESTS]          = "Quests",
  [TextKey.SOURCE_EXPLORATION]     = "Exploration",
  [TextKey.SOURCE_UNCLASSIFIED]    = "Unclassified",

  [TextKey.PLACE_WORLD]            = "Open world",
  [TextKey.PLACE_DUNGEON]          = "Dungeon",
  [TextKey.PLACE_RAID]             = "Raid",
  [TextKey.PLACE_BATTLEGROUND]     = "Battleground",
  [TextKey.PLACE_ARENA]            = "Arena",
  [TextKey.PLACE_UNKNOWN]          = "Unrecorded",

  [TextKey.NOT_AVAILABLE]          = "n/a",
  [TextKey.PERCENT]                = "%d%%",
  [TextKey.DURATION_HM]            = "%dh %dm",
  [TextKey.DURATION_MS]            = "%dm %ds",
  [TextKey.DURATION_M]             = "%dm",
  [TextKey.DURATION_S]             = "%ds",
  [TextKey.TOKEN_SEPARATOR]        = " ",

  [TextKey.BAR_NO_XP]              = "No experience to track",
  [TextKey.BAR_TOOLTIP_TITLE]      = "Ascent",
  [TextKey.BAR_TOOLTIP_VALUE]      = "%d (%s)",
  -- Indented in the string itself, the way PANEL_SOURCE_ROW is: a tooltip line
  -- has no other way to say "this belongs to the line above it".
  [TextKey.BAR_TOOLTIP_PLACE]      = "   %s",
  [TextKey.BAR_TOOLTIP_LEVEL]      = "This level",
  [TextKey.BAR_TOOLTIP_ZONES]      = "By zone",
  -- Indented like a place, because it is the same kind of line: a detail under the
  -- heading it belongs to.
  [TextKey.BAR_TOOLTIP_QUEST]      = "   %s",
  [TextKey.BAR_TOOLTIP_MORE]       = "   and %d more",
  [TextKey.BAR_PENDING]            = "Pending (projected)",
  -- Indented like BAR_TOOLTIP_PLACE: these two belong to the unclassified line
  -- above them. Kept apart from PANEL_PARTIAL because the panel's sentence is a
  -- paragraph and a tooltip line is not; one key cannot serve both surfaces.
  [TextKey.BAR_NOT_OBSERVED]       = "   not observed",
  [TextKey.BAR_UNEXPLAINED]        = "   unattributed",
  [TextKey.BAR_PARTIAL]            = "|cffffcc00Level joined in progress|r",
  [TextKey.UNAVAILABLE_COMBAT_LOG_ABSENT] =
    "Not recorded: the client this level was played on gives addons no combat log.",
  [TextKey.UNAVAILABLE_COMBAT_LOG_CLOSED] =
    "Not recorded: the client closed its combat log to addons part-way through this level.",
  [TextKey.UNAVAILABLE_KILLS_ABSENT] =
    "Creature experience is under Unclassified: the client this level was played on does not name who paid it.",
  [TextKey.UNAVAILABLE_KILLS_CLOSED] =
    "Creature experience is under Unclassified from the point the client stopped naming who paid it.",

  [TextKey.PANEL_TITLE]            = "Ascent - Level Report",
  [TextKey.PANEL_TITLE_LEVEL]      = "Ascent - Level %d",
  [TextKey.PANEL_OPTIONS]          = "Options",
  [TextKey.PANEL_OPTIONS_TIP]      = "Skin, colours, what the bar says, size and behaviour.",
  [TextKey.TAB_SOURCES]            = "Sources",
  [TextKey.TAB_COMBAT]             = "Combat",
  [TextKey.TAB_ABILITIES]          = "Abilities",
  [TextKey.TAB_PENDING]            = "Pending",

  [TextKey.PANEL_NO_LEVEL]         = "No level in progress.",
  [TextKey.PANEL_NO_LEVEL_MAX]     =
    "No level in progress (at the maximum level, or experience gain is disabled). "
    .. "Pick a level in the History tab to read it.",

  [TextKey.PANEL_PROGRESS]         = "Level progress: %s",
  [TextKey.PANEL_PARTIAL]          =
    "|cffffcc00This level's record is partial: part of its experience was not observed.|r",
  [TextKey.PANEL_BY_SOURCE]        = "By source:",
  [TextKey.PANEL_NOTHING_YET]      = "  (nothing recorded yet)",
  [TextKey.PANEL_SOURCE_ROW]       = "  %s: %d (%s)",
  [TextKey.PANEL_RESTED_BONUS]     = "  of which, rested bonus: %d",
  [TextKey.PANEL_TOP_QUESTS]       = "Top quests:",
  [TextKey.PANEL_QUEST_ROW]        = "  #%d: %d xp (%d turn-in%s)",
  [TextKey.PANEL_QUEST]            = "Quest %s",
  [TextKey.PANEL_PENDING_IS_NOW]   =
    "Pending experience is read from your quest log as it is now, so it belongs to no past level.",
  [TextKey.PANEL_TURN_IN_PLURAL]   = "s",
  [TextKey.PANEL_TOP_CREATURES]    = "Top creatures:",
  [TextKey.PANEL_CREATURE_ROW]     = "  %s%s: %d kills, %d xp",
  [TextKey.PANEL_CREATURE_LEVEL]   = " (lvl %d)",
  [TextKey.PANEL_UNKNOWN_CREATURE] = "Unknown creature",
  [TextKey.PANEL_CREATURE_SHARED]  = " (shared by %d)",
  [TextKey.PANEL_CREATURE_MIXED]   = " (group not counted)",
  [TextKey.PANEL_BY_PLACE]         = "By place:",
  [TextKey.PANEL_PLACE_CONTEXT]    = " (%s, %s)",
  [TextKey.PANEL_UNKNOWN_PLACE]    = "Somewhere the client could not name",
  [TextKey.PANEL_PLACE_RATE_NOTE]  = "  |cffffcc00Rates include travel and downtime.|r",
  [TextKey.PANEL_PLACE_PARTIAL]    = "  |cffffcc00Places cover %d of %d: the rest predates them.|r",
  [TextKey.PANEL_PER_HOUR]         = "%d/h",

  [TextKey.PANEL_NO_COMBAT]        = "No combat recorded for this level.",
  [TextKey.PANEL_HEALTH]           = "Health on leaving combat: avg %s, worst %s",
  [TextKey.PANEL_RESOURCE]         = "Resource on leaving combat: avg %s, worst %s",
  [TextKey.PANEL_DEATHS]           = "Deaths: %d",
  [TextKey.PANEL_TIME_LOST]        = "Time lost to death: %s",
  [TextKey.PANEL_TIME_COMBAT]      = "Time in combat: %s",
  [TextKey.PANEL_TIME_RECOVER]     = "Time recovering: %s",
  [TextKey.PANEL_TIME_OUT]         = "Time out of combat: %s",
  [TextKey.PANEL_DAMAGE_DEALT]     = "Damage dealt: %d",
  [TextKey.PANEL_DAMAGE_TAKEN]     = "Damage taken: %d",
  [TextKey.PANEL_HEALING]          = "Healing received: %d",
  [TextKey.PANEL_XP_PER_MINUTE]    = "XP per minute of combat: %s",
  [TextKey.PANEL_XP_PER_KILL]      = "Average XP per kill: %s",

  [TextKey.PANEL_NO_ABILITIES]     = "No abilities used yet this level.",
  [TextKey.PANEL_TOTAL_USES]       = "Total uses: %d",
  [TextKey.PANEL_ABILITY_ROW]      = "  %s: %d (%s)",
  [TextKey.PANEL_AUTO_ATTACK]      = "Auto attack",
  [TextKey.PANEL_RANGED_ATTACK]    = "Ranged attack",
  [TextKey.PANEL_SPELL]            = "Spell %s",

  [TextKey.PANEL_NO_PENDING]       = "No experience pending: no quests accepted.",
  [TextKey.PANEL_PENDING_TOTAL]    = "Pending (projected): %d",
  [TextKey.PANEL_READY_TOTAL]      = "Ready to turn in: %d",
  [TextKey.PANEL_UNKNOWN_QUESTS]   = "%d quest(s) with no known reward",
  [TextKey.PANEL_BY_QUEST]         = "By quest:",
  -- Creature, then what is left of what it asks for. Indented under its quest.
  [TextKey.PANEL_OBJECTIVE]        = "   %s %d/%d",
  [TextKey.PANEL_OBJ_ESTIMATE]     = "~%d xp",
  -- The same figure, marked: it was priced with the level's average per kill
  -- rather than with this creature's, and those differ by a lot.
  [TextKey.PANEL_OBJ_ROUGH]        = "~%d xp*",
  -- Marked differently because it is a different kind of estimate: this
  -- creature's own average, but over kills recorded before the group size was
  -- counted, so it mixes populations that cannot be told apart. A plus rather
  -- than a second asterisk, since the two marks are not degrees of one another;
  -- ASCII, like every string here, because the client's font guarantees nothing
  -- else.
  [TextKey.PANEL_OBJ_MIXED]        = "~%d xp+",
  [TextKey.PANEL_OBJ_NO_RATE]      = "no rate yet",
  [TextKey.PANEL_OBJ_FOOTNOTE]     = "|cffffcc00* priced with this level's average per kill, not this creature's.|r",
  [TextKey.PANEL_OBJ_MIXED_FOOTNOTE] =
    "|cffffcc00+ priced with kills taken before the group sharing them was counted.|r",
  [TextKey.PANEL_PENDING_ROW]      = "  #%d: %s xp [%s]%s",
  [TextKey.PANEL_READY_MARK]       = " (ready)",
  [TextKey.PANEL_LBL_PROGRESS]        = "Level progress",
  [TextKey.PANEL_LBL_OBSERVED]        = "Recorded this level",
  [TextKey.PANEL_LBL_RESTED_BONUS]    = "of which rested bonus",
  [TextKey.PANEL_LBL_GROUP_BONUS]     = "of which group bonus",
  [TextKey.PANEL_LBL_RAID_PENALTY]    = "raid penalty applied",
  [TextKey.PANEL_LBL_HEALTH]          = "Health on leaving combat",
  [TextKey.PANEL_LBL_RESOURCE]        = "Resource on leaving combat",
  [TextKey.PANEL_LBL_DEATHS]          = "Deaths",
  [TextKey.PANEL_LBL_TIME_LOST]       = "Time lost to death",
  [TextKey.PANEL_LBL_TIME_COMBAT]     = "Time in combat",
  [TextKey.PANEL_LBL_TIME_RECOVER]    = "Time recovering",
  [TextKey.PANEL_LBL_TIME_OUT]        = "Time out of combat",
  [TextKey.PANEL_LBL_DAMAGE_DEALT]    = "Damage dealt",
  [TextKey.PANEL_LBL_DAMAGE_TAKEN]    = "Damage taken",
  [TextKey.PANEL_LBL_HEALING]         = "Healing received",
  [TextKey.PANEL_LBL_XP_PER_MINUTE]   = "XP per minute of combat",
  [TextKey.PANEL_LBL_XP_PER_KILL]     = "Average XP per kill",
  [TextKey.PANEL_LBL_TOTAL_USES]      = "Total uses",
  [TextKey.PANEL_LBL_PENDING_TOTAL]   = "Pending (projected)",
  [TextKey.PANEL_LBL_READY_TOTAL]     = "Ready to turn in",
  [TextKey.PANEL_LBL_UNKNOWN_QUESTS]  = "Quests with no known reward",
  [TextKey.PANEL_LBL_DURATION]        = "Time on this level",
  [TextKey.PANEL_TAB_HISTORY]         = "History",
  [TextKey.PANEL_HISTORY_EMPTY]       = "No levels recorded yet. Finish one and it will show up here.",
  [TextKey.PANEL_FIRST_RUN]  =
    "Nothing recorded yet. Ascent starts watching from your next point of experience.",
  [TextKey.PANEL_COMPARE_HEADER]      = "Compared with level %d",
  [TextKey.PANEL_NO_PREVIOUS]         = "No earlier level to compare against.",
  [TextKey.PANEL_AVG_WORST]           = "avg %s, worst %s",
  [TextKey.PANEL_LEVEL_ROW]           = "Level %d",
  [TextKey.PANEL_CURRENT_MARK]        = "in progress",
  [TextKey.PANEL_NOT_RECORDED]        = "not recorded",
  [TextKey.PANEL_DELTA_UP]            = "+%s",
  [TextKey.PANEL_DELTA_DOWN]          = "-%s",
  [TextKey.PANEL_DELTA_SAME]          = "=",
  [TextKey.PANEL_KILLS]               = "%d kills",
  [TextKey.PANEL_TURN_INS]            = "%d turn-ins",
  [TextKey.ORIGIN_CLIENT]          = "client",
  [TextKey.ORIGIN_LEARNED]         = "learned",
  [TextKey.ORIGIN_UNKNOWN]         = "unknown",

  [TextKey.OPTIONS_TITLE]          = "Ascent",
  [TextKey.OPTIONS_LOCK]           = "Lock bar position",
  [TextKey.OPTIONS_HIDE_NO_XP]     = "Hide the bar when there is no experience to track",
  [TextKey.OPTIONS_SHOW_PENDING]   = "Show pending experience from quests in progress",
  [TextKey.OPTIONS_COLLECT_DAMAGE] = "Collect damage data",
  [TextKey.OPTIONS_DEBUG]          = "Debug mode",
  [TextKey.OPTIONS_UPDATE_CHECK]   = "Tell me when someone nearby is running a newer version",
  [TextKey.OPTIONS_SCALE]          = "Bar scale",

  [TextKey.CMD_HELP_HEADER]        = "Ascent commands:",
  [TextKey.CMD_HELP_ROW]           = "  /ascent %s - %s",
  [TextKey.CMD_HELP_SHOW]          = "show the bar",
  [TextKey.CMD_HELP_HIDE]          = "hide the bar",
  [TextKey.CMD_HELP_PANEL]         = "open or close the level report panel",
  [TextKey.CMD_HELP_SUMMARY]       = "breakdown of the current level's experience",
  [TextKey.CMD_HELP_PENDING]       = "forecasted experience from quests in progress",
  [TextKey.CMD_HELP_OPTIONS]       = "how the addon looks, and where its surfaces sit",
  [TextKey.CMD_HELP_RESET]         = "erase this character's recorded history",
  [TextKey.CMD_HELP_DEBUG]         = "everything the addon knows about itself: client, capabilities, "
                                  .. "attribution, places, group, quests and client strings. evidence on|off|reset "
                                  .. "records a session to a file instead of the chat; timesync on|off toggles "
                                  .. "the played-time request",
  [TextKey.CMD_HELP_DEMO]          = "step the bar through every visual state; off to stop",
  [TextKey.CMD_HELP_CHANGELOG]     = "what changed, version by version",

  [TextKey.CMD_NO_LEVEL]           = "no level in progress (at the maximum level, or experience gain is disabled)",
  [TextKey.CMD_SUMMARY_HEADER]     = "level %d - %d / %s xp",
  [TextKey.CMD_SUMMARY_ROW]        = "  %s: %d",
  [TextKey.CMD_PENDING]            = "pending: %d (%d ready to turn in)",
  [TextKey.CMD_PENDING_UNKNOWN]    = "  %d quest(s) with no known reward",
  [TextKey.CMD_STATUS_LOCKED]      = "locked: %s",
  [TextKey.CMD_STATUS_SCALE]       = "scale: %s",
  [TextKey.CMD_STATUS_DEBUG]       = "debug: %s",
  [TextKey.CMD_RESET_PROMPT]       = "type /ascent reset confirm to erase this character's recorded history",
  [TextKey.CMD_RESET_DONE]         = "history cleared",
  [TextKey.CMD_QUESTS_SCANNED]     = "quest log scanned: %d entries (see debug log for the per-quest dump)",
  [TextKey.CMD_QUESTS_NAMED]       = "quest names known: %d (account-wide, and what every quest row reads)",
  -- The two numbers differ only when the client words a kill objective in a way
  -- the template does not match, which is the one failure a suite cannot see.
  [TextKey.CMD_QUESTS_OBJECTIVES]  = "kill objectives: %d read of %d seen",
  -- Names its source because an addon cannot query a server: the newer version
  -- is what other players' clients announced.
  [TextKey.UPDATE_AVAILABLE]       = "version %s is out there - you are running %s. "
                                  .. "(Seen from other players nearby; an addon cannot check for itself.)",
  [TextKey.UPDATE_INSTALLED]       = "updated to %s. /ascent changelog for what it brings",
  -- Explains something that already happened on load: history written by a
  -- newer build is archived, not migrated backwards.
  [TextKey.UPDATE_DOWNGRADED]      = "this is %s, older than the %s you were running. "
                                  .. "Level history written by the newer build has been set aside, "
                                  .. "not deleted: install %s again to read it",
  [TextKey.CHANGELOG_HEADER]       = "Ascent - what changed",
  [TextKey.CHANGELOG_RUNNING]      = "running %s",
  [TextKey.CHANGELOG_MISSING]      = "this build carries no changelog",

  [TextKey.CMD_STRINGS_DUMPED]     = "%d client strings dumped to AscentCharDB.globalStringDump "
                                  .. "(and to the debug log) -- /reload to write them to disk",
  [TextKey.CMD_DEBUG_FIRST]        = "turn debug on first: /ascent options debug on",

  [TextKey.CMD_BAD_SCALE]          = "'%s' is not a valid scale",
  [TextKey.CMD_SKINS]              = "skins: %s",
  [TextKey.CMD_BAD_SKIN]           = "no such skin: %s",
  [TextKey.OPT_BAR_SLOT]           = "Where the bar lives",
  [TextKey.OPT_SLOT_OFF]           = "free on screen",
  [TextKey.OPT_SLOT_INSET]         = "in the client's bar",
  [TextKey.OPT_SLOT_REPLACE]       = "in the client's bar, frame hidden",
  -- Suspended, and why: without the reason, two disabled sliders read as a
  -- broken options panel rather than as a consequence of the chosen slot.
  [TextKey.OPT_SLOT_SUSPENDED]     =
    "Position and size come from the client's bar while it lives there, and the bar shows no text -- "
    .. "the strip is too thin to read one, and outside it is the client's own interface. "
    .. "Hover the bar for the breakdown. Your settings are kept.",
  [TextKey.OPT_SLOT_UNAVAILABLE]   = "This client has no experience bar to take over.",
  [TextKey.CMD_STATUS_SLOT]        = "slot: %s",
  [TextKey.CMD_SLOTS]              = "slots: %s",
  [TextKey.CMD_BAD_SLOT]           = "'%s' is not a slot",
  -- Said when the setting is on but cannot take effect. It must read differently
  -- from the setting being off, or the player looks for a bug in the setting.
  [TextKey.CMD_SLOT_NO_CLIENT_BAR] =
    "this client has no experience bar to take over, so the bar stays where you put it",
  [TextKey.ERR_UI_FAILED]          =
    "the interface failed to load, so the bar and the panel are not available: %s",
  [TextKey.ERR_NO_UI]              = "that needs the interface, which failed to load this session",
  [TextKey.OPT_SECTION_PREVIEW]       = "Preview",
  [TextKey.OPT_COLOR_RESTED]       = "Rested",
  [TextKey.CMD_APPEARANCE_RESET]   = "appearance reset to defaults, bar back in the middle of the screen",

  -- The answer to /ascent options plate, indented under its first line like the
  -- summary rows. It is for a player who cannot see the plate, so it leads with
  -- what hides one (switched off, transparent, off screen) and says where it is
  -- before what it draws. The lock is on the first line because it is what stops
  -- the player moving the plate once found.
  [TextKey.CMD_PLATE_STATUS]       = "plate: %s (locked: %s)",
  [TextKey.CMD_PLATE_FRAME]        = "  scale %s, width %s, opacity %s, hold %ss, rows %s",
  [TextKey.CMD_PLATE_AT]           = "  at %s %s, %s",
  [TextKey.CMD_PLATE_ZONES]        = "  zones: %s",
  -- Every accessory zone off is a choice the panel offers, so this says what the
  -- plate still draws rather than reading as an empty line.
  [TextKey.CMD_PLATE_NO_ZONES]     = "  zones: none, the headline only",
  [TextKey.CMD_PLATE_RESET]        =
    "plate reset to defaults, back in the middle of the screen; the bar was left alone",
  [TextKey.CMD_BAD_PLATE]          = "plate what? one of: %s",
  [TextKey.CMD_EVIDENCE_ON]        =
    "evidence recording on -- nothing will be printed; play normally and /reload when done",
  [TextKey.CMD_EVIDENCE_OFF]       = "evidence recording off",
  [TextKey.CMD_EVIDENCE_STATUS]    = "evidence: %s",
  [TextKey.CMD_EVIDENCE_RESET]     = "evidence cleared",
  [TextKey.COPY_TITLE]             = "Ascent - report",
  [TextKey.COPY_HINT]              =
    "Selected already: press Ctrl-C (Cmd-C on a Mac) to copy, Escape to close. "
    .. "Edit it first if there is anything you would rather not send.",
  [TextKey.CMD_HELP_COPY]          =
    "show a report as selectable text you can copy into a bug report",
  [TextKey.CMD_BAD_COPY]           = "copy what? one of: %s",
  [TextKey.OPT_COPY_REPORT]        = "Copy a report",
  [TextKey.OPT_COPY_REPORT_TIP]    =
    "Opens the diagnostics as selectable text, ready to paste into a bug report. "
    .. "No character name, no realm, and you can edit it before you send it.",
  [TextKey.OPT_SECTION_COLORS]        = "Colours",
  [TextKey.OPT_SECTION_BAR]           = "Bar",
  [TextKey.OPT_SECTION_TEXT]          = "Text",
  [TextKey.OPT_REPLAY]                = "Replay the animation",
  [TextKey.OPT_RESET_COLORS]          = "Reset colours",
  [TextKey.OPT_RESET_AXIS]            = "Default",
  [TextKey.OPT_RESET_AXIS_TIP]        = "Yours, not the skin's. Give this one setting back to the skin.",
  [TextKey.OPT_RESET_ALL]             = "Reset everything to defaults",
  [TextKey.OPT_BORDER_KIND]           = "Border",
  [TextKey.OPT_BORDER_THICKNESS]      = "Border thickness",
  [TextKey.OPT_SEPARATOR_KIND]        = "Separator",
  [TextKey.OPT_SEPARATOR_THICKNESS]   = "Separator thickness",
  [TextKey.OPT_FILL_KIND]             = "Fill",
  [TextKey.OPT_GLOSS]                 = "Gloss",
  [TextKey.OPT_BACKGROUND_ALPHA]      = "Background opacity",
  [TextKey.OPT_SECTION_FIELDS]        = "What the bar says",
  [TextKey.OPT_PAGE_MAIN]             = "Ascent",
  -- One line under each page's title, as other addons in the client's AddOns
  -- list do: it says what the page is for before the controls have to.
  [TextKey.OPT_PAGE_MAIN_DESC]        =
    "Per-level leveling analytics. This page is where the bar lives; the rest is how it looks.",
  [TextKey.OPT_PAGE_SKIN_DESC]        =
    "The bar's whole look, as one choice -- and the pieces of it, if you want them.",
  [TextKey.OPT_PAGE_COLORS_DESC]      =
    "One colour per source of experience. These are what the segments of the bar mean.",
  [TextKey.OPT_PAGE_FIELDS_DESC]      =
    "Which fields the bar's text is made of, and how that text is drawn.",
  [TextKey.OPT_PAGE_SIZE_DESC]        =
    "How big the bar is and how much it moves.",
  [TextKey.OPT_PAGE_BEHAVIOUR_DESC]   =
    "What the addon records and when it gets out of the way.",
  -- Named for what the player sees on the bar, not for the token behind it.
  [TextKey.OPT_FIELD_LEVEL]           = "Level",
  [TextKey.OPT_FIELD_XP_CURRENT]      = "Experience so far",
  [TextKey.OPT_FIELD_XP_MAX]          = "Experience this level needs",
  [TextKey.OPT_FIELD_XP_PERCENT]      = "Percent of the level",
  [TextKey.OPT_FIELD_XP_REMAINING]    = "Experience still to go",
  [TextKey.OPT_FIELD_RESTED]          = "Rested experience",
  [TextKey.OPT_FIELD_XP_PER_HOUR]     = "Experience per hour",
  [TextKey.OPT_FIELD_TIME_TO_LEVEL]   = "Time to the next level",
  [TextKey.OPT_FIELD_TIME_ON_LEVEL]   = "Time on this level",
  [TextKey.OPT_FIELD_SESSION_TIME]    = "Time this session",
  [TextKey.OPT_FIELD_QUEST_PENDING]   = "Experience waiting in quests",
  [TextKey.OPT_TEXT_ON_HOVER]         = "Only show this text when the cursor is on the bar",
  -- A bar with no text is a legitimate choice, so this is a note rather than a
  -- warning: it says what the player will see.
  [TextKey.OPT_FIELDS_NONE]           = "With none of these on, the bar shows no text.",
  [TextKey.OPT_TEXT_STYLE]            = "Text style",
  [TextKey.OPT_TEXT_ANCHOR]           = "Text position",
  [TextKey.OPT_TEXT_SIZE]             = "Text size",
  [TextKey.BORDER_NONE]               = "None",
  [TextKey.BORDER_HAIRLINE]           = "Hairline",
  [TextKey.BORDER_BEVEL]              = "Bevel",
  [TextKey.BORDER_FRAME]              = "Frame",
  [TextKey.SEPARATOR_NONE]            = "None",
  [TextKey.SEPARATOR_HAIRLINE]        = "Hairline",
  [TextKey.SEPARATOR_NOTCH]           = "Notch",
  [TextKey.FILL_FLAT]                 = "Flat",
  [TextKey.FILL_GRADIENT_UP]          = "Gradient up",
  [TextKey.FILL_GRADIENT_DN]          = "Gradient down",
  [TextKey.FILL_ART]                  = "Textured",
  [TextKey.TEXTSTYLE_PLAIN]           = "Plain",
  [TextKey.TEXTSTYLE_OUTLINE]         = "Outline",
  [TextKey.TEXTSTYLE_HEAVY]           = "Heavy",
  [TextKey.ANCHOR_INSIDE_LEFT]        = "Inside, left",
  [TextKey.ANCHOR_INSIDE_CENTER]      = "Inside, centre",
  [TextKey.ANCHOR_INSIDE_RIGHT]       = "Inside, right",
  [TextKey.ANCHOR_ABOVE]              = "Above",
  [TextKey.ANCHOR_BELOW]              = "Below",
  [TextKey.SKIN_TABARD]                = "Tabard",
  [TextKey.SKIN_CARTOGRAPHER]          = "Cartographer",
  [TextKey.SKIN_STORMWIND]             = "Stormwind",
  [TextKey.SKIN_GLASS]                 = "Glass",
  [TextKey.SKIN_TELEMETRY]             = "Telemetry",
  [TextKey.SKIN_PHANTOM]               = "Phantom",
  [TextKey.OPT_SECTION_SKIN]          = "Skin",
  [TextKey.OPT_SECTION_SIZE]          = "Size",
  [TextKey.OPT_SECTION_MOTION]        = "Motion",
  [TextKey.OPT_SECTION_BEHAVIOUR]     = "Behaviour",
  [TextKey.OPT_HIGH_CONTRAST]         = "High contrast (ignore skin tinting)",
  [TextKey.OPT_BAR_WIDTH]             = "Bar width",
  [TextKey.OPT_BAR_HEIGHT]            = "Bar height",
  [TextKey.OPT_MOTION_SCALE]          = "Motion intensity (0 turns animation off)",
  [TextKey.OPT_PAGE_PLATE]            = "Pull plate",
  [TextKey.OPT_PAGE_PLATE_DESC]       =
    "The frame that counts a fight while it happens and stays as a plaque when it ends.",
  [TextKey.OPT_SECTION_PLATE_FRAME]   = "The frame",
  [TextKey.OPT_SECTION_PLATE_CONTENT] = "What it shows",
  -- "Its own", not "Appearance": the plate wears the bar's skin and palette, and
  -- this section holds only what it changes on top of them.
  [TextKey.OPT_SECTION_PLATE_LOOK]    = "Its own look",
  [TextKey.OPT_PLATE_ENABLED]         = "Show the pull plate",
  [TextKey.OPT_PLATE_LOCKED]          = "Lock the plate where it is",
  [TextKey.OPT_PLATE_SCALE]           = "Plate scale",
  [TextKey.OPT_PLATE_WIDTH]           = "Plate width",
  [TextKey.OPT_PLATE_OPACITY]         = "Plate opacity",
  [TextKey.OPT_PLATE_HOLD]            = "Seconds the plaque stays (and can be carried on)",
  [TextKey.OPT_PLATE_ROWS]            = "Creature and ability rows",
  [TextKey.OPT_PLATE_ZONE_CLOCK]      = "How long the fight has been going",
  [TextKey.OPT_PLATE_ZONE_REMAINING]  = "What the level still needs",
  [TextKey.OPT_PLATE_ZONE_STREAK]     = "The kill chain",
  [TextKey.OPT_PLATE_ZONE_SOURCES]    = "Where the experience came from",
  [TextKey.OPT_PLATE_ZONE_CREATURES]  = "Creatures",
  [TextKey.OPT_PLATE_ZONE_ABILITIES]  = "Abilities",
  [TextKey.OPT_PLATE_ZONE_FOOTER]     = "Damage per second and experience per hour",
  -- Every accessory zone off is a legitimate choice, so this says what is left,
  -- like the note a bar with no text gets.
  [TextKey.OPT_PLATE_ZONES_NONE]      =
    "With none of these on, the plate shows the experience and the kill count and nothing else.",
  [TextKey.OPT_PLATE_DEMO]            = "Show me a pull",
  [TextKey.OPT_PLATE_DEMO_TIP]        =
    "Runs a whole fake fight on the real plate. There is no separate preview here on purpose: "
    .. "this is the plate itself, at the settings you just chose.",
  [TextKey.OPT_PLATE_RESET]           = "Reset the plate to defaults",
  [TextKey.PLATE_TITLE]               = "Pull",
  [TextKey.PLATE_XP]                  = "%s XP",
  [TextKey.PLATE_KILLS]               = "%d",
  [TextKey.PLATE_KILLS_OF]            = "%d/%d",
  [TextKey.PLATE_REMAINING]           = "%s to level",
  -- Wraps the headline while it is still a forecast: an estimate from what these
  -- creatures have paid at this level. It comes off when the experience lands.
  [TextKey.PLATE_PROJECTION]          = "~%s",
  -- A row still being fought: how many are down out of how many were pulled.
  [TextKey.PLATE_ALIVE]               = "%d/%d",
  [TextKey.PLATE_STREAK]              = "chain x%d",
  [TextKey.PLATE_DPS]                 = "%s dps",
  [TextKey.PLATE_XP_HOUR]             = "%s xp/h",
  [TextKey.PLATE_COUNT]               = "x%d",
  [TextKey.PLATE_SETTLING]            = "settling",

  [TextKey.CMD_BAD_ON_OFF]         = "'%s' is not on or off",
  [TextKey.CMD_UNKNOWN_OPTION]     = "'%s' is not an Ascent option",
  [TextKey.CMD_UNKNOWN]            = "'%s' is not an Ascent command",
  [TextKey.CMD_HANDLER_FAILED]     = "a handler for %s failed: %s",
}
