-- Ascent - client compatibility: flavor and maximum level.
--
-- `MAX_PLAYER_LEVEL` is 0 on both Classic Era and Burning Crusade Classic -- only a
-- file neither flavor loads fills it in -- so the addon never reads it (D17).
-- `GetMaxPlayerLevel()` is what the client's own experience bar uses instead, and it
-- is also the one signal that tells the two flavors apart without guessing at a
-- project identifier or a TOC interface number this addon has not verified against
-- either client.

local _, ns = ...
ns.adapter = ns.adapter or {}

local ClientFlavor = ns.core.ClientFlavor

local FLAVOR_BY_MAX_LEVEL = {
  [60] = ClientFlavor.CLASSIC_ERA,
  [70] = ClientFlavor.BURNING_CRUSADE,
}

local Compat = {}

-- The level past which the current level's experience bar is meaningless -- 60 on
-- Classic Era, 70 on Burning Crusade Classic.
function Compat.maxLevel()
  return GetMaxPlayerLevel()
end

-- Which of the two supported clients is running. UNKNOWN rather than an error: a
-- client that reports some other maximum is exactly the case the addon has to
-- survive by degrading, not by refusing to load.
function Compat.flavor()
  return FLAVOR_BY_MAX_LEVEL[Compat.maxLevel()] or ClientFlavor.UNKNOWN
end

ns.adapter.Compat = Compat
