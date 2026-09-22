-- Ascent - static analysis configuration.
--
-- Besides the lint settings, this is where the layer rule becomes a check:
--
--   core/     pure domain. No WoW API is declared for it, so using one is an error.
--   adapter/  translates between the client and the domain. Gets the WoW API.
--   ui/       draws view-models built by core. Gets the WoW API.
--   app/      composition root. Gets the WoW API and the saved variables.
--
-- Verify with: ./dev.sh lint

-- `std` governs which globals exist, not which syntax parses: a call to a
-- 5.2-only library function is flagged, a `goto` is not.
std = "lua51" -- the client runs Lua 5.1
codes = true
max_line_length = 120

exclude_files = {
  "openspec/**",
  ".tools/**",
}

-- Every addon file is called by the client as `local ADDON_NAME, ns = ...`.
-- That vararg is the only namespace mechanism available without `require`.
self = false

-- The client API the outer layers may use, grouped by concern.
local WOW_API = {
  -- player and unit state
  "UnitXP", "UnitXPMax", "UnitLevel", "UnitName", "UnitGUID", "UnitClass", "UnitRace",
  "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax", "UnitFactionGroup",
  "UnitTokenFromGUID", "UnitExists", "UnitIsUnit", "UnitCanAttack", "UnitIsDead", "UnitAffectingCombat",
  "UnitIsTapDenied", "UnitThreatSituation",
  -- nameplates: the only place a Classic client names a creature that has aggroed
  -- and not yet reached you
  "C_NamePlate",
  -- experience and rest
  "GetXPExhaustion", "GetRestState", "IsResting", "IsXPUserDisabled",
  "GetMaxPlayerLevel", "GetMaxLevelForExpansionLevel", "GetExpansionLevel",
  "GetAccountExpansionLevel",
  -- which client is running: its declared interface number identifies it
  "GetBuildInfo",
  -- time
  "GetTime", "time", "date", "difftime", "RequestTimePlayed", "C_Timer",
  -- quests
  "GetNumQuestLogEntries", "GetQuestLogTitle", "SelectQuestLogEntry", "GetQuestLogSelection",
  "GetQuestLogRewardXP", "GetRewardXP", "GetQuestID", "GetQuestLogIndexByID", "GetTitleText",
  "GetNumQuestLeaderBoards", "GetQuestLogLeaderBoard", "QUEST_MONSTERS_KILLED",
  -- combat log
  "C_CombatLog", "CombatLogGetCurrentEventInfo",
  -- world and group context
  "GetRealmName", "GetZoneText", "GetSubZoneText", "GetInstanceInfo", "IsInInstance",
  "IsInGroup", "IsInRaid", "GetNumGroupMembers", "C_Map", "C_Seasons", "C_GameRules",
  "IsInGuild", "LE_PARTY_CATEGORY_INSTANCE",
  -- addon messages: the only way to reach another client, and so to learn that a
  -- newer version exists
  "C_ChatInfo",
  -- spells
  "GetSpellInfo", "GetSpellTexture", "C_Spell",
  -- frames and widgets
  "CreateFrame", "UIParent", "GameTooltip", "Mixin", "CreateFromMixins",
  -- dropdowns: the options panel probes for these and falls back to a cycling button
  "UIDropDownMenu_Initialize", "UIDropDownMenu_CreateInfo", "UIDropDownMenu_AddButton",
  "UIDropDownMenu_SetWidth", "UIDropDownMenu_SetText",
  -- the client's tooltip placement, which tooltip addons hook, so the bar's
  -- breakdown appears where the player keeps tooltips
  "GameTooltip_SetDefaultAnchor",
  -- CreateColor: the gradient call takes colour objects. It and Texture:SetGradient
  -- are checked at the call site, with a flat fill as the fallback, because neither
  -- is verified on Burning Crusade Classic.
  "CreateColor",
  "BackdropTemplateMixin", "InCombatLockdown", "PlaySound",
  -- the frames Escape closes; a window is appended to it, never assigned
  "UISpecialFrames",
  "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory", "Settings",
  -- chat and slash commands. SlashCmdList is declared writable for app/ below,
  -- the only layer that registers a command.
  "DEFAULT_CHAT_FRAME", "ChatFrameUtil", "ChatFrame_DisplayTimePlayed",
  -- secret values of the 12.0 engine: present on Forever, absent on both classic
  -- clients; adapter/compat/Readable.lua is built on them
  "issecretvalue", "canaccessvalue",
  -- addon and system
  "C_AddOns", "GetAddOnMetadata", "GetLocale", "GetCVarBool", "issecurevariable",
  "hooksecurefunc", "securecall", "geterrorhandler", "Constants", "Enum",
  -- Lua helpers the client adds on top of 5.1
  "strsplit", "strjoin", "strtrim", "wipe", "tinsert", "tremove", "tContains",
  "max", "min", "abs", "floor", "ceil", "format", "gsub", "strfind", "strmatch",
  "strsub", "strlower", "strupper", "strlen", "tostringall",
  -- global strings used to build localized patterns
  "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED",
  "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP", "COMBATLOG_XPGAIN_FIRSTPERSON_RAID",
  "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP", "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID",
  "COMBATLOG_XPGAIN_QUEST", "COMBATLOG_XPGAIN_EXHAUSTION1", "COMBATLOG_XPGAIN_EXHAUSTION2",
  "COMBATLOG_XPGAIN_EXHAUSTION4", "COMBATLOG_XPGAIN_EXHAUSTION5",
  -- The eight rested-and-grouped templates, the usual case when levelling rested
  -- with a friend. Without them such a line falls back to the plain kill template
  -- and loses its modifier.
  "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION1_RAID",
  "COMBATLOG_XPGAIN_EXHAUSTION2_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION2_RAID",
  "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION4_RAID",
  "COMBATLOG_XPGAIN_EXHAUSTION5_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION5_RAID",
  "ERR_ZONE_EXPLORED_XP", "ERR_QUEST_REWARD_EXP_I", "LEVEL_UP", "XP",
}

-- Saved variables are declared in the TOC, so the client creates them as real globals.
local SAVED_VARIABLES = { "AscentDB", "AscentCharDB" }

-- The layer rule. core/ is absent on purpose: it gets only the Lua 5.1 standard
-- library.
files["Ascent/adapter/**/*.lua"] = { read_globals = WOW_API, globals = SAVED_VARIABLES }
-- app/ also writes SlashCmdList and SLASH_ASCENT1, which is how an addon registers
-- a slash command; only the composition root does.
files["Ascent/app/**/*.lua"]     = {
  read_globals = WOW_API,
  globals = { "AscentDB", "AscentCharDB", "SlashCmdList", "SLASH_ASCENT1" },
}
-- ui/ also writes fields on ColorPickerFrame: the older colour picker is driven by
-- assigning func, cancelFunc and previousValues to the frame. The newer
-- SetupColorPickerAndShow needs no writes and is preferred at the call site.
files["Ascent/ui/**/*.lua"]      = { read_globals = WOW_API, globals = { "ColorPickerFrame" } }
files["Ascent/locale/**/*.lua"]  = { read_globals = { "GetLocale" } }
files["Ascent/test/**/*.lua"]    = { std = "lua51+busted", globals = { "AscentTest" } }
-- The smoke harness is the stand-in client, so defining the client's globals is
-- its job.
files["Ascent/test/smoke.lua"]  = { std = "lua51", allow_defined_top = true, max_line_length = false,
  ignore = { "11", "12", "13", "14", "21", "43", "63" } }
-- Generated from CHANGELOG.md with one prose entry per line, which the client
-- wraps to its window. `./dev.sh lint` checks it by regenerating it.
files["Ascent/core/constants/Changelog.lua"] = { max_line_length = false }
