-- Ascent - experience vocabulary.
--
-- These string values are persisted in saved variables, so they are part of the
-- on-disk format: changing one is a schema migration, not a rename.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

-- Where a point of experience came from. UNKNOWN is a first-class source, not a
-- failure mode: the addon guarantees the sources add up to the level total, so
-- anything it could not attribute has to land somewhere visible.
ns.core.XpSource = Frozen.enum("XpSource", {
  MOB_KILL    = "mob_kill",
  QUEST_TURNIN = "quest_turnin",
  EXPLORATION = "exploration",
  UNKNOWN     = "unknown",
})

-- Adjustments that ride along with a gain. They describe a portion of the amount
-- already granted; they are never added on top of it.
ns.core.XpModifier = Frozen.enum("XpModifier", {
  RESTED_BONUS = "rested_bonus",
  GROUP_BONUS  = "group_bonus",
  RAID_PENALTY = "raid_penalty",
})

-- Where the forecast for a quest's reward came from. Recorded per quest so the
-- player can tell a real number from an absent one.
ns.core.QuestXpOrigin = Frozen.enum("QuestXpOrigin", {
  CLIENT   = "client",   -- read from the client's own quest log API
  LEARNED  = "learned",  -- captured when the player opened the quest, then cached
  UNKNOWN  = "unknown",  -- no trustworthy source; contributes nothing and is counted
})

-- Which channel a hint arrived on. The client announces experience through several
-- channels that carry very different amounts of information -- two of them carry
-- nothing but a number -- and the channel is the only thing that tells them apart.
-- The classifiers of D5 dispatch on this and on nothing else.
ns.core.XpHintKind = Frozen.enum("XpHintKind", {
  KILL_MESSAGE      = "kill_message",      -- "%s dies, you gain %d experience."
  ANONYMOUS_MESSAGE = "anonymous_message", -- "You gain %d experience." -- quests, maybe discoveries
  QUEST_TURNED_IN   = "quest_turned_in",   -- QUEST_TURNED_IN(questID, xpReward): no parsing at all
  QUEST_MESSAGE     = "quest_message",     -- ERR_QUEST_REWARD_EXP_I, the system-channel echo
  ZONE_DISCOVERED   = "zone_discovered",   -- ERR_ZONE_EXPLORED_XP
})

-- How to read the number in the parenthetical of a rested kill message. With a full
-- reserve both readings produce the same figure, which is why no static source can
-- settle it and why spike 0.4 exists. The identity base + bonus = amount received
-- holds either way; all that changes is which half the parenthetical names. The
-- domain therefore carries both readings instead of guessing one.
ns.core.RestedReading = Frozen.enum("RestedReading", {
  BONUS = "bonus",
  BASE  = "base",
})
