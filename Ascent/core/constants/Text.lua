-- Ascent - the key every player-visible string is looked up by.
--
-- Frozen so a misspelled key errors where it is read instead of reaching the
-- player as a blank label.
--
-- Deliberately not here: diagnostic output. The `logger:debug()` lines composed
-- in core/, the /ascent debug counter labels and the error() preconditions stay
-- literal English -- they are material for a bug report, not product copy. What
-- is localized is the bar, the panel and the commands.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

ns.core.TextKey = Frozen.enum("TextKey", {
  -- Shared: one key per source, read by the bar tooltip, the panel and /ascent summary
  -- alike.
  SOURCE_CREATURES    = "source_creatures",
  SOURCE_QUESTS       = "source_quests",
  SOURCE_EXPLORATION  = "source_exploration",
  SOURCE_UNCLASSIFIED = "source_unclassified",

  -- Shared: one key per kind of place, read by the panel's per-place block and by
  -- the bar's crossed reading, the same way the four source names above are shared.
  -- The kind is a noun on its own so a row can print "Elwynn Forest (Open world)"
  -- without a second format string per surface.
  PLACE_WORLD         = "place_world",
  PLACE_DUNGEON       = "place_dungeon",
  PLACE_RAID          = "place_raid",
  PLACE_BATTLEGROUND  = "place_battleground",
  PLACE_ARENA         = "place_arena",
  PLACE_UNKNOWN       = "place_unknown",

  -- Shared formatting. NOT_AVAILABLE is the marker the bar shows for a value it does
  -- not have; it is also what Locale:get falls back to when a key is missing outside
  -- debug mode, so the player never reads an internal identifier.
  NOT_AVAILABLE       = "not_available",
  PERCENT             = "percent",
  DURATION_HM         = "duration_hm",
  DURATION_MS         = "duration_ms",
  DURATION_M          = "duration_m",
  DURATION_S          = "duration_s",
  TOKEN_SEPARATOR     = "token_separator",

  -- Bar
  BAR_NO_XP           = "bar_no_xp",
  BAR_TOOLTIP_TITLE   = "bar_tooltip_title",
  BAR_TOOLTIP_VALUE   = "bar_tooltip_value",
  BAR_TOOLTIP_PLACE   = "bar_tooltip_place",
  BAR_TOOLTIP_LEVEL   = "bar_tooltip_level",
  BAR_TOOLTIP_ZONES   = "bar_tooltip_zones",
  BAR_TOOLTIP_QUEST   = "bar_tooltip_quest",
  BAR_TOOLTIP_MORE    = "bar_tooltip_more",
  BAR_PENDING         = "bar_pending",
  BAR_NOT_OBSERVED    = "bar_not_observed",
  BAR_UNEXPLAINED     = "bar_unexplained",
  BAR_PARTIAL         = "bar_partial",

  -- What stands in for a figure a level was recorded without: the source that was
  -- missing, and whether it was missing from the start or closed part-way. Read
  -- through UnavailableText below, never picked by a surface.
  UNAVAILABLE_COMBAT_LOG_ABSENT = "unavailable_combat_log_absent",
  UNAVAILABLE_COMBAT_LOG_CLOSED = "unavailable_combat_log_closed",
  UNAVAILABLE_KILLS_ABSENT      = "unavailable_kills_absent",
  UNAVAILABLE_KILLS_CLOSED      = "unavailable_kills_closed",

  -- Panel: frame and tabs
  PANEL_TITLE         = "panel_title",
  PANEL_TITLE_LEVEL   = "panel_title_level",
  PANEL_OPTIONS       = "panel_options",
  PANEL_OPTIONS_TIP   = "panel_options_tip",
  TAB_SOURCES         = "tab_sources",
  TAB_COMBAT          = "tab_combat",
  TAB_ABILITIES       = "tab_abilities",
  TAB_PENDING         = "tab_pending",

  -- Panel: states shared by every tab
  PANEL_NO_LEVEL      = "panel_no_level",
  PANEL_NO_LEVEL_MAX  = "panel_no_level_max",

  -- Panel: sources tab
  PANEL_PROGRESS      = "panel_progress",
  PANEL_PARTIAL       = "panel_partial",
  PANEL_BY_SOURCE     = "panel_by_source",
  PANEL_NOTHING_YET   = "panel_nothing_yet",
  PANEL_SOURCE_ROW    = "panel_source_row",
  PANEL_RESTED_BONUS  = "panel_rested_bonus",
  PANEL_TOP_QUESTS    = "panel_top_quests",
  PANEL_QUEST_ROW     = "panel_quest_row",
  PANEL_QUEST         = "panel_quest",
  PANEL_PENDING_IS_NOW= "panel_pending_is_now",
  PANEL_TURN_IN_PLURAL = "panel_turn_in_plural",
  PANEL_TOP_CREATURES = "panel_top_creatures",
  PANEL_CREATURE_ROW  = "panel_creature_row",
  PANEL_CREATURE_LEVEL = "panel_creature_level",
  PANEL_UNKNOWN_CREATURE = "panel_unknown_creature",
  PANEL_CREATURE_SHARED = "panel_creature_shared",
  PANEL_CREATURE_MIXED = "panel_creature_mixed",
  PANEL_BY_PLACE      = "panel_by_place",
  PANEL_PLACE_CONTEXT = "panel_place_context",
  PANEL_UNKNOWN_PLACE = "panel_unknown_place",
  PANEL_PLACE_RATE_NOTE = "panel_place_rate_note",
  PANEL_PLACE_PARTIAL = "panel_place_partial",
  PANEL_PER_HOUR      = "panel_per_hour",

  -- Panel: combat tab
  PANEL_NO_COMBAT     = "panel_no_combat",
  PANEL_HEALTH        = "panel_health",
  PANEL_RESOURCE      = "panel_resource",
  PANEL_DEATHS        = "panel_deaths",
  PANEL_TIME_LOST     = "panel_time_lost",
  PANEL_TIME_COMBAT   = "panel_time_combat",
  PANEL_TIME_RECOVER  = "panel_time_recover",
  PANEL_TIME_OUT      = "panel_time_out",
  PANEL_DAMAGE_DEALT  = "panel_damage_dealt",
  PANEL_DAMAGE_TAKEN  = "panel_damage_taken",
  PANEL_HEALING       = "panel_healing",
  PANEL_XP_PER_MINUTE = "panel_xp_per_minute",
  PANEL_XP_PER_KILL   = "panel_xp_per_kill",

  -- Panel: abilities tab
  PANEL_NO_ABILITIES  = "panel_no_abilities",
  PANEL_TOTAL_USES    = "panel_total_uses",
  PANEL_ABILITY_ROW   = "panel_ability_row",
  -- The two attacks that have no spell behind them, named apart so a melee swing
  -- and a ranged shot can be told apart.
  PANEL_AUTO_ATTACK   = "panel_auto_attack",
  PANEL_RANGED_ATTACK = "panel_ranged_attack",
  PANEL_SPELL         = "panel_spell",

  -- Panel: pending tab
  PANEL_NO_PENDING    = "panel_no_pending",
  PANEL_PENDING_TOTAL = "panel_pending_total",
  PANEL_READY_TOTAL   = "panel_ready_total",
  PANEL_UNKNOWN_QUESTS = "panel_unknown_quests",
  PANEL_BY_QUEST      = "panel_by_quest",
  PANEL_OBJECTIVE     = "panel_objective",
  PANEL_OBJ_ESTIMATE  = "panel_obj_estimate",
  PANEL_OBJ_ROUGH     = "panel_obj_rough",
  PANEL_OBJ_MIXED     = "panel_obj_mixed",
  PANEL_OBJ_NO_RATE   = "panel_obj_no_rate",
  PANEL_OBJ_FOOTNOTE  = "panel_obj_footnote",
  PANEL_OBJ_MIXED_FOOTNOTE = "panel_obj_mixed_footnote",
  PANEL_PENDING_ROW   = "panel_pending_row",
  PANEL_READY_MARK    = "panel_ready_mark",
  PANEL_LBL_PROGRESS      = "panel_lbl_progress",
  PANEL_LBL_OBSERVED      = "panel_lbl_observed",
  PANEL_LBL_RESTED_BONUS  = "panel_lbl_rested_bonus",
  PANEL_LBL_GROUP_BONUS   = "panel_lbl_group_bonus",
  PANEL_LBL_RAID_PENALTY  = "panel_lbl_raid_penalty",
  PANEL_LBL_HEALTH        = "panel_lbl_health",
  PANEL_LBL_RESOURCE      = "panel_lbl_resource",
  PANEL_LBL_DEATHS        = "panel_lbl_deaths",
  PANEL_LBL_TIME_LOST     = "panel_lbl_time_lost",
  PANEL_LBL_TIME_COMBAT   = "panel_lbl_time_combat",
  PANEL_LBL_TIME_RECOVER  = "panel_lbl_time_recover",
  PANEL_LBL_TIME_OUT      = "panel_lbl_time_out",
  PANEL_LBL_DAMAGE_DEALT  = "panel_lbl_damage_dealt",
  PANEL_LBL_DAMAGE_TAKEN  = "panel_lbl_damage_taken",
  PANEL_LBL_HEALING       = "panel_lbl_healing",
  PANEL_LBL_XP_PER_MINUTE = "panel_lbl_xp_per_minute",
  PANEL_LBL_XP_PER_KILL   = "panel_lbl_xp_per_kill",
  PANEL_LBL_TOTAL_USES    = "panel_lbl_total_uses",
  PANEL_LBL_PENDING_TOTAL = "panel_lbl_pending_total",
  PANEL_LBL_READY_TOTAL   = "panel_lbl_ready_total",
  PANEL_LBL_UNKNOWN_QUESTS= "panel_lbl_unknown_quests",
  PANEL_LBL_DURATION      = "panel_lbl_duration",
  PANEL_TAB_HISTORY       = "panel_tab_history",
  PANEL_HISTORY_EMPTY     = "panel_history_empty",
  PANEL_FIRST_RUN         = "panel_first_run",
  PANEL_COMPARE_HEADER    = "panel_compare_header",
  PANEL_NO_PREVIOUS       = "panel_no_previous",
  PANEL_AVG_WORST         = "panel_avg_worst",
  PANEL_LEVEL_ROW         = "panel_level_row",
  PANEL_CURRENT_MARK      = "panel_current_mark",
  PANEL_NOT_RECORDED      = "panel_not_recorded",
  PANEL_DELTA_UP          = "panel_delta_up",
  PANEL_DELTA_DOWN        = "panel_delta_down",
  PANEL_DELTA_SAME        = "panel_delta_same",
  PANEL_KILLS             = "panel_kills",
  PANEL_TURN_INS          = "panel_turn_ins",
  ORIGIN_CLIENT       = "origin_client",
  ORIGIN_LEARNED      = "origin_learned",
  ORIGIN_UNKNOWN      = "origin_unknown",

  -- Options panel
  OPTIONS_TITLE       = "options_title",
  OPTIONS_LOCK        = "options_lock",
  OPTIONS_HIDE_NO_XP  = "options_hide_no_xp",
  OPTIONS_SHOW_PENDING = "options_show_pending",
  OPTIONS_COLLECT_DAMAGE = "options_collect_damage",
  OPTIONS_DEBUG       = "options_debug",
  OPTIONS_UPDATE_CHECK = "options_update_check",
  OPTIONS_SCALE       = "options_scale",

  -- Chat commands: help
  CMD_HELP_HEADER     = "cmd_help_header",
  CMD_HELP_ROW        = "cmd_help_row",
  CMD_HELP_SHOW       = "cmd_help_show",
  CMD_HELP_HIDE       = "cmd_help_hide",
  CMD_HELP_PANEL      = "cmd_help_panel",
  CMD_HELP_SUMMARY    = "cmd_help_summary",
  CMD_HELP_PENDING    = "cmd_help_pending",
  CMD_HELP_OPTIONS    = "cmd_help_options",
  CMD_HELP_RESET      = "cmd_help_reset",
  CMD_HELP_DEBUG      = "cmd_help_debug",
  CMD_HELP_DEMO       = "cmd_help_demo",
  CMD_HELP_CHANGELOG  = "cmd_help_changelog",

  -- Chat commands: output
  CMD_NO_LEVEL        = "cmd_no_level",
  CMD_SUMMARY_HEADER  = "cmd_summary_header",
  CMD_SUMMARY_ROW     = "cmd_summary_row",
  CMD_PENDING         = "cmd_pending",
  CMD_PENDING_UNKNOWN = "cmd_pending_unknown",
  CMD_STATUS_LOCKED   = "cmd_status_locked",
  CMD_STATUS_SCALE    = "cmd_status_scale",
  CMD_STATUS_DEBUG    = "cmd_status_debug",
  CMD_RESET_PROMPT    = "cmd_reset_prompt",
  CMD_RESET_DONE      = "cmd_reset_done",
  CMD_QUESTS_SCANNED  = "cmd_quests_scanned",
  CMD_QUESTS_NAMED    = "cmd_quests_named",
  CMD_QUESTS_OBJECTIVES = "cmd_quests_objectives",
  CMD_STRINGS_DUMPED  = "cmd_strings_dumped",
  CMD_DEBUG_FIRST     = "cmd_debug_first",

  -- Versions: what the addon says about its own, and about other people's.
  UPDATE_AVAILABLE    = "update_available",
  UPDATE_INSTALLED    = "update_installed",
  UPDATE_DOWNGRADED   = "update_downgraded",
  CHANGELOG_HEADER    = "changelog_header",
  CHANGELOG_RUNNING   = "changelog_running",
  CHANGELOG_MISSING   = "changelog_missing",

  -- Chat commands: refusals
  CMD_BAD_SCALE       = "cmd_bad_scale",
  CMD_SKINS           = "cmd_skins",
  CMD_BAD_SKIN        = "cmd_bad_skin",
  OPT_BAR_SLOT        = "opt_bar_slot",
  OPT_SLOT_OFF        = "opt_slot_off",
  OPT_SLOT_INSET      = "opt_slot_inset",
  OPT_SLOT_REPLACE    = "opt_slot_replace",
  OPT_SLOT_SUSPENDED  = "opt_slot_suspended",
  OPT_SLOT_UNAVAILABLE = "opt_slot_unavailable",
  CMD_STATUS_SLOT     = "cmd_status_slot",
  CMD_SLOTS           = "cmd_slots",
  CMD_BAD_SLOT        = "cmd_bad_slot",
  CMD_SLOT_NO_CLIENT_BAR = "cmd_slot_no_client_bar",
  ERR_UI_FAILED       = "err_ui_failed",
  ERR_NO_UI           = "err_no_ui",
  OPT_SECTION_PREVIEW = "opt_section_preview",
  OPT_COLOR_RESTED    = "opt_color_rested",
  CMD_APPEARANCE_RESET= "cmd_appearance_reset",

  -- The plate, from chat. Its own keys and not the bar's status lines, even where
  -- the words would be the same: a key shared by two surfaces ends up wrong on one
  -- of them, and these are read side by side with the bar's.
  CMD_PLATE_STATUS    = "cmd_plate_status",
  CMD_PLATE_FRAME     = "cmd_plate_frame",
  CMD_PLATE_AT        = "cmd_plate_at",
  CMD_PLATE_ZONES     = "cmd_plate_zones",
  CMD_PLATE_NO_ZONES  = "cmd_plate_no_zones",
  CMD_PLATE_RESET     = "cmd_plate_reset",
  CMD_BAD_PLATE       = "cmd_bad_plate",
  CMD_EVIDENCE_ON     = "cmd_evidence_on",
  CMD_EVIDENCE_OFF    = "cmd_evidence_off",
  CMD_EVIDENCE_STATUS = "cmd_evidence_status",
  CMD_EVIDENCE_RESET  = "cmd_evidence_reset",

  -- The copy dialog. The report it shows is diagnostic output and stays literal
  -- English (see this file's header); these three are what the player reads
  -- around it, which is product copy.
  COPY_TITLE          = "copy_title",
  COPY_HINT           = "copy_hint",
  CMD_HELP_COPY       = "cmd_help_copy",
  CMD_BAD_COPY        = "cmd_bad_copy",
  OPT_COPY_REPORT     = "opt_copy_report",
  OPT_COPY_REPORT_TIP = "opt_copy_report_tip",
  OPT_SECTION_COLORS  = "opt_section_colors",
  OPT_SECTION_BAR     = "opt_section_bar",
  OPT_SECTION_TEXT    = "opt_section_text",
  OPT_REPLAY          = "opt_replay",
  OPT_RESET_COLORS    = "opt_reset_colors",
  OPT_RESET_AXIS      = "opt_reset_axis",
  OPT_RESET_AXIS_TIP  = "opt_reset_axis_tip",
  OPT_RESET_ALL       = "opt_reset_all",
  OPT_BORDER_KIND     = "opt_border_kind",
  OPT_BORDER_THICKNESS= "opt_border_thickness",
  OPT_SEPARATOR_KIND  = "opt_separator_kind",
  OPT_SEPARATOR_THICKNESS= "opt_separator_thickness",
  OPT_FILL_KIND       = "opt_fill_kind",
  OPT_GLOSS           = "opt_gloss",
  OPT_BACKGROUND_ALPHA= "opt_background_alpha",
  OPT_SECTION_FIELDS  = "opt_section_fields",
  OPT_PAGE_MAIN       = "opt_page_main",
  OPT_PAGE_MAIN_DESC  = "opt_page_main_desc",
  OPT_PAGE_SKIN_DESC  = "opt_page_skin_desc",
  OPT_PAGE_COLORS_DESC = "opt_page_colors_desc",
  OPT_PAGE_FIELDS_DESC = "opt_page_fields_desc",
  OPT_PAGE_SIZE_DESC  = "opt_page_size_desc",
  OPT_PAGE_BEHAVIOUR_DESC = "opt_page_behaviour_desc",
  OPT_FIELD_LEVEL         = "opt_field_level",
  OPT_FIELD_XP_CURRENT    = "opt_field_xp_current",
  OPT_FIELD_XP_MAX        = "opt_field_xp_max",
  OPT_FIELD_XP_PERCENT    = "opt_field_xp_percent",
  OPT_FIELD_XP_REMAINING  = "opt_field_xp_remaining",
  OPT_FIELD_RESTED        = "opt_field_rested",
  OPT_FIELD_XP_PER_HOUR   = "opt_field_xp_per_hour",
  OPT_FIELD_TIME_TO_LEVEL = "opt_field_time_to_level",
  OPT_FIELD_TIME_ON_LEVEL = "opt_field_time_on_level",
  OPT_FIELD_SESSION_TIME  = "opt_field_session_time",
  OPT_FIELD_QUEST_PENDING = "opt_field_quest_pending",
  OPT_FIELDS_NONE     = "opt_fields_none",
  OPT_TEXT_ON_HOVER   = "opt_text_on_hover",
  OPT_TEXT_STYLE      = "opt_text_style",
  OPT_TEXT_ANCHOR     = "opt_text_anchor",
  OPT_TEXT_SIZE       = "opt_text_size",
  BORDER_NONE         = "border_none",
  BORDER_HAIRLINE     = "border_hairline",
  BORDER_BEVEL        = "border_bevel",
  BORDER_FRAME        = "border_frame",
  SEPARATOR_NONE      = "separator_none",
  SEPARATOR_HAIRLINE  = "separator_hairline",
  SEPARATOR_NOTCH     = "separator_notch",
  FILL_FLAT           = "fill_flat",
  FILL_GRADIENT_UP    = "fill_gradient_up",
  FILL_GRADIENT_DN    = "fill_gradient_dn",
  FILL_ART            = "fill_art",
  TEXTSTYLE_PLAIN     = "textstyle_plain",
  TEXTSTYLE_OUTLINE   = "textstyle_outline",
  TEXTSTYLE_HEAVY     = "textstyle_heavy",
  ANCHOR_INSIDE_LEFT  = "anchor_inside_left",
  ANCHOR_INSIDE_CENTER= "anchor_inside_center",
  ANCHOR_INSIDE_RIGHT = "anchor_inside_right",
  ANCHOR_ABOVE        = "anchor_above",
  ANCHOR_BELOW        = "anchor_below",
  SKIN_TABARD         = "skin_tabard",
  SKIN_CARTOGRAPHER   = "skin_cartographer",
  SKIN_STORMWIND      = "skin_stormwind",
  SKIN_GLASS          = "skin_glass",
  SKIN_TELEMETRY      = "skin_telemetry",
  SKIN_PHANTOM        = "skin_phantom",
  OPT_SECTION_SKIN    = "opt_section_skin",
  OPT_SECTION_SIZE    = "opt_section_size",
  OPT_SECTION_MOTION  = "opt_section_motion",
  OPT_SECTION_BEHAVIOUR= "opt_section_behaviour",
  OPT_HIGH_CONTRAST   = "opt_high_contrast",
  OPT_BAR_WIDTH       = "opt_bar_width",
  OPT_BAR_HEIGHT      = "opt_bar_height",
  OPT_MOTION_SCALE    = "opt_motion_scale",

  -- The pull plate's own page. One page carrying the surface's name, with three
  -- headings inside it -- the frame, what it shows, and its own look -- rather
  -- than its lock filed under Behaviour and its width under Size.
  --
  -- Three of its controls deliberately have no key of their own: the background
  -- opacity, the border thickness and the text size are the same three words on
  -- this page as on the bar's, and a second string saying "Text size" is a second
  -- thing to translate and one more place for the two to drift apart.
  OPT_PAGE_PLATE      = "opt_page_plate",
  OPT_PAGE_PLATE_DESC = "opt_page_plate_desc",
  OPT_SECTION_PLATE_FRAME   = "opt_section_plate_frame",
  OPT_SECTION_PLATE_CONTENT = "opt_section_plate_content",
  OPT_SECTION_PLATE_LOOK    = "opt_section_plate_look",
  OPT_PLATE_ENABLED   = "opt_plate_enabled",
  OPT_PLATE_LOCKED    = "opt_plate_locked",
  OPT_PLATE_SCALE     = "opt_plate_scale",
  OPT_PLATE_WIDTH     = "opt_plate_width",
  OPT_PLATE_OPACITY   = "opt_plate_opacity",
  -- The label says what it costs, because it is not only a look: the plaque's
  -- time on screen is also the window in which a closed pull can be continued,
  -- which the player would otherwise only discover in their records.
  OPT_PLATE_HOLD      = "opt_plate_hold",
  OPT_PLATE_ROWS      = "opt_plate_rows",
  OPT_PLATE_ZONE_CLOCK     = "opt_plate_zone_clock",
  OPT_PLATE_ZONE_REMAINING = "opt_plate_zone_remaining",
  OPT_PLATE_ZONE_STREAK    = "opt_plate_zone_streak",
  OPT_PLATE_ZONE_SOURCES   = "opt_plate_zone_sources",
  OPT_PLATE_ZONE_CREATURES = "opt_plate_zone_creatures",
  OPT_PLATE_ZONE_ABILITIES = "opt_plate_zone_abilities",
  OPT_PLATE_ZONE_FOOTER    = "opt_plate_zone_footer",
  OPT_PLATE_ZONES_NONE = "opt_plate_zones_none",
  OPT_PLATE_DEMO      = "opt_plate_demo",
  OPT_PLATE_DEMO_TIP  = "opt_plate_demo_tip",
  OPT_PLATE_RESET     = "opt_plate_reset",

  -- The pull plate. Short on purpose: every one of these sits in a frame a
  -- couple of hundred pixels wide, next to a number that is the actual content,
  -- and must not wrap.
  PLATE_TITLE         = "plate_title",
  PLATE_XP            = "plate_xp",
  PLATE_KILLS         = "plate_kills",
  PLATE_KILLS_OF      = "plate_kills_of",
  PLATE_REMAINING     = "plate_remaining",
  PLATE_PROJECTION    = "plate_projection",
  PLATE_ALIVE         = "plate_alive",
  PLATE_STREAK        = "plate_streak",
  PLATE_DPS           = "plate_dps",
  PLATE_XP_HOUR       = "plate_xp_hour",
  PLATE_COUNT         = "plate_count",
  PLATE_SETTLING      = "plate_settling",

  CMD_BAD_ON_OFF      = "cmd_bad_on_off",
  CMD_UNKNOWN_OPTION  = "cmd_unknown_option",
  CMD_UNKNOWN         = "cmd_unknown",
  CMD_HANDLER_FAILED  = "cmd_handler_failed",
})

-- The sentence a surface says in place of what a level was recorded without, by
-- the source and the reason it was off. One table rather than a choice in each
-- surface, because three of them say it -- the panel, the bar and the chat
-- summary -- about the same level, and a level read in two places must not read
-- two ways. Strict like every frozen table: a reason is kept on a record only if
-- it is in SourceState, so the lookup cannot miss.
local RecordedSource, SourceState = ns.core.RecordedSource, ns.core.SourceState
local TextKey = ns.core.TextKey

ns.core.UnavailableText = Frozen.enum("UnavailableText", {
  -- the three combat metrics the combat log feeds: not recorded at all
  [RecordedSource.COMBAT_LOG] = {
    [SourceState.ABSENT]     = TextKey.UNAVAILABLE_COMBAT_LOG_ABSENT,
    [SourceState.UNREADABLE] = TextKey.UNAVAILABLE_COMBAT_LOG_CLOSED,
  },
  -- the kill line: the rest of the breakdown stands, and this says where the
  -- experience of creatures went instead
  [RecordedSource.XP_CHAT] = {
    [SourceState.ABSENT]     = TextKey.UNAVAILABLE_KILLS_ABSENT,
    [SourceState.UNREADABLE] = TextKey.UNAVAILABLE_KILLS_CLOSED,
  },
})
