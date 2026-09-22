-- Ascent - which fields the bar's text is made of.
--
-- The composed text is an ordered list of tokens: the order the player reads
-- left to right, and the order the bar gives fields up in when it is too narrow
-- for all of them (lowest priority first). TEXT_PRIORITY declares it, and the
-- options panel and the bar both read the rank from here.
--
-- A field switched on lands at its declared position relative to the fields
-- already chosen, not at the end, and the ones already there do not move.

local _, ns = ...
ns.core = ns.core or {}

local TEXT_PRIORITY = ns.core.TEXT_PRIORITY

local BarTextFields = {}

-- Every field the bar can show, in the order they read. Copied rather than handed
-- out: the frozen list is its own backing store, and a caller that sorted it in
-- place would rewrite the priority order for the session.
function BarTextFields.all()
  local fields = {}
  for _, token in ipairs(TEXT_PRIORITY) do
    fields[#fields + 1] = token
  end
  return fields
end

-- Where a field sits in the declared order. A token nobody ranked sorts last, so
-- an unknown one is the first thing given up rather than the last.
function BarTextFields.rankOf(token)
  for index, ranked in ipairs(TEXT_PRIORITY) do
    if ranked == token then
      return index
    end
  end
  return #TEXT_PRIORITY + 1
end

function BarTextFields.has(chosen, token)
  for _, existing in ipairs(chosen or {}) do
    if existing == token then
      return true
    end
  end
  return false
end

-- The list with one field switched on or off. Always a new list: the caller's is
-- a resolved setting, and settings are not the view's to mutate.
function BarTextFields.toggled(chosen, token, wanted)
  chosen = chosen or {}
  local result = {}

  if not wanted then
    for _, existing in ipairs(chosen) do
      if existing ~= token then
        result[#result + 1] = existing
      end
    end
    return result
  end

  if BarTextFields.has(chosen, token) then
    for _, existing in ipairs(chosen) do
      result[#result + 1] = existing
    end
    return result
  end

  -- In front of the first chosen field that ranks after it. A player's own order,
  -- if they have one, survives switching another field on: only the new one is
  -- placed, and it is placed where its own rank says.
  local rank = BarTextFields.rankOf(token)
  local placed = false
  for _, existing in ipairs(chosen) do
    if not placed and BarTextFields.rankOf(existing) > rank then
      result[#result + 1] = token
      placed = true
    end
    result[#result + 1] = existing
  end
  if not placed then
    result[#result + 1] = token
  end
  return result
end

ns.core.BarTextFields = BarTextFields
