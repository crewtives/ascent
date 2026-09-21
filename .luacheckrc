-- Ascent - static analysis configuration.
--
-- This file is not just lint settings: it is where the architecture's dependency
-- rule stops being a convention and becomes a check anyone can run.
--
--   core/     pure domain. The WoW API is NOT declared here, so touching it is an
--             error, not a code-review comment that erodes over time.
--   adapter/  translates between the client and the domain. Gets the WoW API.
--   ui/       draws view-models built by core. Gets the WoW API.
--   app/      composition root. Gets the WoW API and the saved variables.
--
-- Verify with: ./dev.sh lint

-- `std` governs which globals exist, not which syntax parses: it will flag a call
-- to a 5.2-only library function, but not a `goto`. Between this and LuaJIT the
-- runtime side is covered; the syntax side is a known, documented gap.
std = "lua51" -- the client runs Lua 5.1; anything newer is a bug waiting to ship
codes = true
max_line_length = 120

exclude_files = {
  "openspec/**",
  ".tools/**",
}

-- Every addon file is called by the client as `local ADDON_NAME, ns = ...`.
-- That vararg is the only namespace mechanism available without `require`.
self = false

-- ---------------------------------------------------------------------------
-- The client API surface the outer layers are allowed to touch.
-- Grouped by concern so that adding one is a deliberate, reviewable act.
-- ---------------------------------------------------------------------------
local WOW_API = {
  -- player and unit state
  "UnitXP", "UnitXPMax", "UnitLevel", "UnitName", "UnitGUID", "UnitClass", "UnitRace",
  "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax", "UnitFactionGroup",
  "UnitTokenFromGUID", "UnitExists", "UnitIsUnit", "UnitCanAttack", "UnitIsDead", "UnitAffectingCombat",
  -- nameplates: the only place a Classic client names a creature that has aggroed
  -- and not yet reached you
  "C_NamePlate",
  -- experience and rest
  "GetXPExhaustion", "GetRestState", "IsResting", "IsXPUserDisabled",
  "GetMaxPlayerLevel", "GetMaxLevelForExpansionLevel", "GetExpansionLevel",
  "GetAccountExpansionLevel",
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
  -- addon messages: the only API this addon uses to reach another client, and the
  -- only way "is there a newer version?" can be answered without a network request
  "C_ChatInfo",
  -- spells
  "GetSpellInfo", "GetSpellTexture", "C_Spell",
  -- frames and widgets
  "CreateFrame", "UIParent", "GameTooltip", "Mixin", "CreateFromMixins",
  -- The dropdown family, all five of it. The options panel probes for these
  -- rather than assuming them, and falls back to a cycling button.
  "UIDropDownMenu_Initialize", "UIDropDownMenu_CreateInfo", "UIDropDownMenu_AddButton",
  "UIDropDownMenu_SetWidth", "UIDropDownMenu_SetText",
  -- The client's own tooltip placement, and what every tooltip addon hooks: it is
  -- how the bar's breakdown ends up where the player keeps their tooltips.
  "GameTooltip_SetDefaultAnchor",
  -- CreateColor: the gradient call takes colour OBJECTS since the signature
  -- changed, so a gradient fill needs it. Both it and Texture:SetGradient are
  -- feature-checked at the call site and fall back to a flat fill -- BC Classic
  -- is not verifiable from here (design D38, spike 0.4).
  "CreateColor",
  "BackdropTemplateMixin", "InCombatLockdown", "PlaySound",
  -- The client's own list of frames Escape closes. Appended to rather than
  -- assigned, which is what a window the player opens is supposed to do.
  "UISpecialFrames",
  "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory", "Settings",
  -- chat and slash commands (SlashCmdList is NOT here: registering a command
  -- means writing a field into it, which a read-only global does not allow --
  -- see the app/ pattern below, the only layer that ever does that)
  "DEFAULT_CHAT_FRAME", "ChatFrameUtil", "ChatFrame_DisplayTimePlayed",
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
  -- The eight rested-AND-grouped templates. Nobody had counted them: they are the
  -- normal case of levelling rested with a friend, and without them that line
  -- falls back to the plain kill template and loses its modifier.
  "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION1_RAID",
  "COMBATLOG_XPGAIN_EXHAUSTION2_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION2_RAID",
  "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION4_RAID",
  "COMBATLOG_XPGAIN_EXHAUSTION5_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION5_RAID",
  "ERR_ZONE_EXPLORED_XP", "ERR_QUEST_REWARD_EXP_I", "LEVEL_UP", "XP",
}

-- Saved variables are declared in the TOC, so the client creates them as real globals.
local SAVED_VARIABLES = { "AscentDB", "AscentCharDB" }

-- ---------------------------------------------------------------------------
-- The rule itself.
-- core/ is absent on purpose: it inherits only the bare Lua 5.1 standard library.
-- ---------------------------------------------------------------------------
files["Ascent/adapter/**/*.lua"] = { read_globals = WOW_API, globals = SAVED_VARIABLES }
-- app/ additionally writes SlashCmdList (registering a command) and SLASH_ASCENT1
-- (the client-recognised naming convention an addon uses to declare one) -- both
-- are globals only the composition root touches.
files["Ascent/app/**/*.lua"]     = {
  read_globals = WOW_API,
  globals = { "AscentDB", "AscentCharDB", "SlashCmdList", "SLASH_ASCENT1" },
}
-- ui/ additionally WRITES fields on ColorPickerFrame: the client's older colour
-- picker is driven by assigning func/cancelFunc/previousValues onto the frame
-- itself, so that path cannot be taken with a read-only global. The modern
-- SetupColorPickerAndShow path needs no writes, and is preferred at the call site.
files["Ascent/ui/**/*.lua"]      = { read_globals = WOW_API, globals = { "ColorPickerFrame" } }
files["Ascent/locale/**/*.lua"]  = { read_globals = { "GetLocale" } }
files["Ascent/test/**/*.lua"]    = { std = "lua51+busted", globals = { "AscentTest" } }
-- The smoke harness IS the stand-in client: defining the client's globals is its
-- entire job, so the rule that protects every other file would only get in the way.
files["Ascent/test/smoke.lua"]  = { std = "lua51", allow_defined_top = true, max_line_length = false,
  ignore = { "11", "12", "13", "14", "21", "43", "63" } }
-- The changelog is GENERATED from CHANGELOG.md (tools/changelog.lua) and its lines
-- are prose, not code: one entry is a paragraph a person wrote. Wrapping them to
-- 120 columns would mean the generator deciding where a sentence breaks, and the
-- client re-wraps the text to the window anyway. `./dev.sh lint` checks this file
-- a better way -- by regenerating it and diffing.
files["Ascent/core/constants/Changelog.lua"] = { max_line_length = false }
