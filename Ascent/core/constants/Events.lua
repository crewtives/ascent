-- Ascent - event vocabulary.
--
-- Three separate namespaces on purpose:
--   EventTopic          what Ascent publishes on its own bus. Domain language.
--   WowEvent           what the client fires. Only adapters may speak this.
--   CombatLogSubevent  the second field of a combat log entry.
--
-- Adapters translate the bottom two into the top one. Nothing in core/ ever
-- registers a WowEvent; that is the whole point of the split.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

ns.core.EventTopic = Frozen.enum("EventTopic", {
  -- experience
  XP_DELTA_OBSERVED = "xp_delta_observed", -- authoritative amount, source not yet known
  XP_HINT_RECEIVED  = "xp_hint_received",  -- a claim about a source, amount not authoritative
  -- A line on the experience channel that matched no template this client has.
  -- Published rather than only logged: it is the one sentence that can answer
  -- "what does this client actually print", and the questions still open about
  -- that are precisely the ones a debug print cannot settle after the fact.
  XP_LINE_UNMATCHED = "xp_line_unmatched",
  XP_ATTRIBUTED     = "xp_attributed",     -- amount and source reconciled
  -- level lifecycle
  LEVEL_STARTED     = "level_started",
  LEVEL_COMPLETED   = "level_completed",
  RECORD_UPDATED    = "record_updated",
  -- combat
  COMBAT_STARTED    = "combat_started",
  COMBAT_ENDED      = "combat_ended",
  ABILITY_USED      = "ability_used",
  DAMAGE_DEALT      = "damage_dealt",
  DAMAGE_TAKEN      = "damage_taken",
  -- A creature and this player are in the same fight, said by ANY line of the
  -- combat log that has one on each side. Separate from the damage topics on
  -- purpose: waiting for damage meant a creature that had charged you, swung and
  -- missed was not in the pull, and one you had not hit back was never in it at
  -- all. Being fought is not the same fact as being hurt.
  ENEMY_ENGAGED     = "enemy_engaged",
  HEALING_RECEIVED  = "healing_received",
  CREATURE_DIED     = "creature_died",
  KILL_UNREWARDED   = "kill_unrewarded", -- a creature died and nothing paid for it
  PLAYER_DIED       = "player_died",
  PLAYER_REVIVED    = "player_revived",
  -- state
  REST_CHANGED      = "rest_changed",
  XP_STATE_CHANGED  = "xp_state_changed", -- max level reached, or gain disabled
  QUEST_LOG_CHANGED = "quest_log_changed",
  QUEST_COMPLETED   = "quest_completed",
  QUEST_REWARD_SEEN = "quest_reward_seen", -- reward read from the open quest dialogue (D15 level 2)
  TIME_PLAYED_SYNCED = "time_played_synced",
  SETTINGS_CHANGED  = "settings_changed",
  SESSION_STARTED   = "session_started",
  SESSION_ENDED     = "session_ended",
})

ns.core.WowEvent = Frozen.enum("WowEvent", {
  ADDON_LOADED               = "ADDON_LOADED",
  PLAYER_ENTERING_WORLD      = "PLAYER_ENTERING_WORLD",
  PLAYER_LOGOUT              = "PLAYER_LOGOUT",
  PLAYER_XP_UPDATE           = "PLAYER_XP_UPDATE",
  PLAYER_LEVEL_UP            = "PLAYER_LEVEL_UP",
  UPDATE_EXHAUSTION          = "UPDATE_EXHAUSTION",
  PLAYER_UPDATE_RESTING      = "PLAYER_UPDATE_RESTING",
  ENABLE_XP_GAIN             = "ENABLE_XP_GAIN",
  DISABLE_XP_GAIN            = "DISABLE_XP_GAIN",
  CHAT_MSG_COMBAT_XP_GAIN    = "CHAT_MSG_COMBAT_XP_GAIN",
  CHAT_MSG_SYSTEM            = "CHAT_MSG_SYSTEM",
  CHAT_MSG_ADDON             = "CHAT_MSG_ADDON",
  QUEST_TURNED_IN            = "QUEST_TURNED_IN",
  QUEST_ACCEPTED             = "QUEST_ACCEPTED",
  QUEST_REMOVED              = "QUEST_REMOVED",
  QUEST_DETAIL               = "QUEST_DETAIL",
  QUEST_COMPLETE             = "QUEST_COMPLETE",
  QUEST_LOG_UPDATE           = "QUEST_LOG_UPDATE",
  COMBAT_LOG_EVENT_UNFILTERED = "COMBAT_LOG_EVENT_UNFILTERED",
  PLAYER_REGEN_DISABLED      = "PLAYER_REGEN_DISABLED",
  PLAYER_REGEN_ENABLED       = "PLAYER_REGEN_ENABLED",
  PLAYER_DEAD                = "PLAYER_DEAD",
  PLAYER_ALIVE               = "PLAYER_ALIVE",
  PLAYER_UNGHOST             = "PLAYER_UNGHOST",
  TIME_PLAYED_MSG            = "TIME_PLAYED_MSG",
  GROUP_ROSTER_UPDATE        = "GROUP_ROSTER_UPDATE",
  ZONE_CHANGED_NEW_AREA      = "ZONE_CHANGED_NEW_AREA",
  -- The only place the unit token of a nameplate is handed over. Reading it off
  -- the frame that C_NamePlate.GetNamePlates() returns looked equivalent and is
  -- not: on 2026-09-22 a session saw 168 nameplates and got a token from none of
  -- them, so the rule that decides what belongs to a pull never ran once.
  NAME_PLATE_UNIT_ADDED      = "NAME_PLATE_UNIT_ADDED",
  NAME_PLATE_UNIT_REMOVED    = "NAME_PLATE_UNIT_REMOVED",
})

-- What counts as "used" is execution, not impact: a swing that misses was still
-- swung. That is why both _DAMAGE and _MISSED are here for melee and ranged, while
-- spells are counted from SPELL_CAST_SUCCESS, which already means "it went off".
ns.core.CombatLogSubevent = Frozen.enum("CombatLogSubevent", {
  SPELL_CAST_SUCCESS   = "SPELL_CAST_SUCCESS",
  SWING_DAMAGE         = "SWING_DAMAGE",
  SWING_MISSED         = "SWING_MISSED",
  RANGE_DAMAGE         = "RANGE_DAMAGE",
  RANGE_MISSED         = "RANGE_MISSED",
  SPELL_DAMAGE         = "SPELL_DAMAGE",
  SPELL_PERIODIC_DAMAGE = "SPELL_PERIODIC_DAMAGE",
  -- Carried for who is in the fight rather than for what they did: a spell that
  -- misses and a debuff that lands both name a creature that is fighting you and
  -- neither of them moves a health bar.
  SPELL_MISSED         = "SPELL_MISSED",
  -- A hit that landed on a shield instead of on flesh. Carried for who is in the
  -- fight and nothing else -- it has no handler, which is a thing that could not
  -- be expressed until the router stopped requiring one.
  SPELL_ABSORBED       = "SPELL_ABSORBED",
  -- A creature winding up a spell at this character. Carried for the same reason
  -- and with the same absence of a handler: it is the earliest thing the combat
  -- log will ever say about a caster, and it was being dropped -- eleven of them
  -- in the census of 2026-09-22.
  SPELL_CAST_START     = "SPELL_CAST_START",
  SPELL_AURA_APPLIED   = "SPELL_AURA_APPLIED",
  SPELL_HEAL           = "SPELL_HEAL",
  SPELL_PERIODIC_HEAL  = "SPELL_PERIODIC_HEAL",
  UNIT_DIED            = "UNIT_DIED",
  PARTY_KILL           = "PARTY_KILL",
})
