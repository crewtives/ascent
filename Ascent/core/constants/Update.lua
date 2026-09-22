-- Ascent - the version channel's contract.
--
-- A WoW addon cannot make a network request, so a newer version can only be
-- learned from other players running the addon. Every number in this file is a
-- client limit or a value chosen against one, not a preference.
--
-- The client's budget shapes most of them: each registered prefix gets 10 messages
-- back at one per second, and sending past that returns AddonMessageThrottle and,
-- with several prefixes at once, can disconnect the player. The numbers below stay
-- far below that ceiling.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

-- The prefix messages travel under. The client allows 16 characters and the
-- documentation asks that it be the addon's name, so other authors can tell
-- whose traffic they are looking at.
ns.core.UPDATE_PREFIX = "Ascent"

-- Hard client limits, named so the tests assert against them.
ns.core.UpdateLimit = Frozen.enum("UpdateLimit", {
  PREFIX = 16,
  MESSAGE = 255,
})

-- Where an announcement may go. Every one of these reaches people who already
-- share activity with the player.
--
-- Deliberately absent: WHISPER (an unsolicited message to one person), and SAY
-- and YELL, which do carry addon messages in Classic but reach strangers nearby.
ns.core.UpdateChannel = Frozen.enum("UpdateChannel", {
  GUILD         = "GUILD",
  PARTY         = "PARTY",
  RAID          = "RAID",
  INSTANCE_CHAT = "INSTANCE_CHAT",
})

-- How many distinct players have to announce the same newer version before the
-- addon repeats it to its own player.
--
-- An addon message is arbitrary text written by someone else's client, and
-- nothing signs it: at a threshold of one, a single modified client could announce
-- a version that does not exist to a whole guild. Three, as DBM uses, makes a false
-- announcement cost three accounts.
ns.core.UPDATE_PEER_THRESHOLD = 3

-- The addon's own sending allowance, deliberately poorer than the client's.
--
-- Two announcements in reserve instead of ten, refilled every fifteen seconds
-- instead of every second, so a player zoning in and out of a group repeatedly
-- sends two messages and then nothing. A dropped announcement costs nothing:
-- another player's client will repeat it.
ns.core.UpdateBudget = Frozen.enum("UpdateBudget", {
  CAPACITY = 2,
  REFILL_SECONDS = 15,
})
