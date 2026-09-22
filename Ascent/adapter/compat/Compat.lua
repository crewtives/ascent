-- Ascent - client compatibility: which client is running, and its maximum level.
--
-- A client is identified by the interface number it declares, not by its level
-- cap: Forever is a 1-60 game on the modern engine, so a client identified by its
-- cap reads as Classic Era and looks for a UI tree it does not have.
--
-- The key is expansion and major, not the whole number, because the last two
-- digits are the patch: Classic Era 1.15.9 declares 11509 and 1.15.10 declares
-- 11510. The table rides out a patch and still answers UNKNOWN for a release it
-- has never seen, such as a future 1.16.x or Retail's 11xxxx.
--
-- `MAX_PLAYER_LEVEL` is 0 on both classic flavours (only a file neither of them
-- loads fills it in), so the addon never reads it. `GetMaxPlayerLevel()` is what
-- the client's own experience bar uses, and is a fact about the identified
-- client, not its identity.

local _, ns = ...
ns.adapter = ns.adapter or {}

local ClientFlavor = ns.core.ClientFlavor
-- Both reads below are handed to the domain, so they pass the same guard as every
-- other client read. Readable loads before this file, so the TOC lists it first.
local readable = ns.adapter.Readable.value

-- Keyed on expansion and major: 11509 -> 115, 20506 -> 205, 16001 -> 160.
local FLAVOR_BY_RELEASE = {
  [115] = ClientFlavor.CLASSIC_ERA,      -- 1.15.x
  [205] = ClientFlavor.BURNING_CRUSADE,  -- 2.5.x
  [160] = ClientFlavor.FOREVER,          -- 1.60.x
}

local Compat = {}

-- The interface number the running client declares, or nil on a client that does
-- not answer. No supported client is in that case, but the client's identity is
-- not taken on faith from a single unguarded call.
function Compat.interfaceVersion()
  if GetBuildInfo == nil then
    return nil
  end
  return tonumber(readable((select(4, GetBuildInfo()))))
end

-- The level past which the current level's experience bar is meaningless -- 60 on
-- Classic Era and on Forever, 70 on Burning Crusade Classic.
function Compat.maxLevel()
  return readable(GetMaxPlayerLevel())
end

-- Which supported client is running. UNKNOWN rather than an error: a client that
-- declares some other release is exactly the case the addon has to survive by
-- degrading, not by refusing to load.
function Compat.flavor()
  local interface = Compat.interfaceVersion()
  if interface == nil then
    return ClientFlavor.UNKNOWN
  end
  return FLAVOR_BY_RELEASE[math.floor(interface / 100)] or ClientFlavor.UNKNOWN
end

ns.adapter.Compat = Compat
