-- Ascent - the icon of an ability, looked up one way.
--
-- The pull plate and the panel's ability ranking both draw ability icons
-- through this one function, so an accessor that moves on some client moves
-- here only. World of Warcraft: Forever has no bare GetSpellTexture global.

local _, ns = ...
ns.ui = ns.ui or {}

local SpellIcon = {}

-- Tries C_Spell.GetSpellTexture first and falls back to the bare global, which
-- Classic Era and Burning Crusade Classic still have. A nil answer costs only
-- the icon: a row without one reads better than a row with a placeholder.
function SpellIcon.texture(spellId)
  if spellId == nil then
    return nil
  end
  if C_Spell ~= nil and type(C_Spell.GetSpellTexture) == "function" then
    local texture = C_Spell.GetSpellTexture(spellId)
    if texture ~= nil then
      return texture
    end
  end
  if type(GetSpellTexture) == "function" then
    return GetSpellTexture(spellId)
  end
  return nil
end

ns.ui.SpellIcon = SpellIcon
