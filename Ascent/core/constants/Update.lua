-- Ascent - the version channel's contract.
--
-- A WoW addon cannot make a network request, so "is there a newer version?" has
-- exactly one answerable form: ask the people who are already here. Everything in
-- this file is a number the client imposes or a number chosen against one, and
-- none of it is a preference.
--
-- The client's budget is the reason most of these exist: each registered prefix
-- gets 10 messages back at one per second, and sending past that returns
-- AddonMessageThrottle -- and, with several prefixes at once, can DISCONNECT the
-- player. An addon that spends its allowance on saying hello is an addon that
-- costs someone a wipe, so the numbers below stay far below the ceiling rather
-- than near it.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

-- The prefix messages travel under. The client allows 16 characters and the
-- documentation asks that it be the addon's name, so other authors can tell
-- whose traffic they are looking at.
ns.core.UPDATE_PREFIX = "Ascent"

-- Hard client limits, spelled out because the tests assert against them rather
-- than against a remembered number.
ns.core.UpdateLimit = Frozen.enum("UpdateLimit", {
  PREFIX = 16,
  MESSAGE = 255,
})

-- Where an announcement may go. Every one of these reaches people who already
-- share activity with the player.
--
-- Deliberately absent: WHISPER (an unsolicited message to one person), and SAY
-- and YELL -- which do carry addon messages in Classic, and are exactly the
-- noise that gets an addon uninstalled.
ns.core.UpdateChannel = Frozen.enum("UpdateChannel", {
  GUILD         = "GUILD",
  PARTY         = "PARTY",
  RAID          = "RAID",
  INSTANCE_CHAT = "INSTANCE_CHAT",
})

-- How many DISTINCT players have to announce the same newer version before the
-- addon repeats it to its own player.
--
-- The content of an addon message is written by someone else's client: it is
-- arbitrary text and nothing signs it. At a threshold of one, anybody running a
-- modified client could announce 99.0.0 and send a whole guild looking for a
-- version that does not exist. Three is what DBM requires, for the same reason:
-- it does not make lying impossible, it makes it cost three accounts.
ns.core.UPDATE_PEER_THRESHOLD = 3

-- The addon's own sending allowance, deliberately poorer than the client's.
--
-- Two announcements in reserve instead of ten, refilled every fifteen seconds
-- instead of every second. A player zoning in and out of a group repeatedly is
-- the ordinary case this protects: at the client's own rate that is a stream of
-- messages, and at this rate it is two and then silence. A dropped announcement
-- costs nothing -- somebody else's client will say the same thing a minute later.
ns.core.UpdateBudget = Frozen.enum("UpdateBudget", {
  CAPACITY = 2,
  REFILL_SECONDS = 15,
})
