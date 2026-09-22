-- Ascent - PlayerState port.
--
-- Everything the domain needs to know about the character right now. Every value
-- is a plain number, string or boolean: no client objects cross this line.

local _, ns = ...
ns.core = ns.core or {}

ns.core.PlayerState = ns.core.Port.define("PlayerState", {
  level = "Current character level.",
  maxLevel = "Highest level reachable on this client. 60 on Classic Era, 70 on "
          .. "Burning Crusade.",

  xp = "Experience accumulated in the current level. This is the authoritative "
    .. "number: the difference between two readings is the only amount the addon "
    .. "trusts.",
  xpMax = "Experience the current level requires.",

  restedXp = "Rested reserve remaining, in experience points, as the client "
          .. "reports it. Zero when there is none. Note that the client's figure "
          .. "is twice the server's internal reserve, so it caps at 1.5x xpMax and "
          .. "falls by twice the base experience of each kill.",
  isResting = "Whether the character is somewhere that accrues rest.",

  isXpDisabled = "Whether the character has experience gain switched off. Treated "
              .. "as a truth value, never compared against true or 1.",

  place = "Returns context, areaId, name: where the character is right now. The "
       .. "context is a PlaceContext, the identifier is the instance id inside an "
       .. "instance and the map id outside it (D42), and the name is for display "
       .. "only. All three are nil when the client cannot say, which is a real "
       .. "answer and not an error: crossing a portal is exactly when it happens.",

  sharedBy = "How many characters a kill's experience is split between right "
          .. "now, the character included: one when playing alone, never zero. "
          .. "This is the population a measured average belongs to, which is why "
          .. "it is a count of people and not a reading of whether there is a "
          .. "group (D82): two and five divide very differently.",

  healthFraction = "Current health as a fraction of maximum, from 0 to 1.",
  powerFraction = "Current primary resource as a fraction of maximum, from 0 to 1.",

  guid = "Stable identifier of the character, used to tell characters apart.",
  identity = "Returns name, realm. Used to keep one character's history separate "
          .. "from another's.",
})
