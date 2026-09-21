-- Ascent - which fields the bar's text is made of.
--
-- The composed text is a list of tokens, and the list is ordered: it is what the
-- player reads left to right, and it is also the order the bar gives fields up in
-- when it is too narrow for all of them (lowest priority first). One order, two
-- jobs, and TEXT_PRIORITY is where it is declared.
--
-- What lives here is the editing: turning a field on has to put it somewhere, and
-- "at the end" is the wrong answer -- a player who adds the level to a text that
-- already shows a percentage wants it where the level goes, not after everything
-- else. So a field switched on lands at its declared position relative to the
-- fields already chosen, and the ones already there do not move.
--
-- The rank is here rather than in the view because both readers need the same
-- one: the panel to place a field, the bar to decide which to give up first. Two
-- copies of a priority order is two orders the moment somebody edits one.

local _, ns = ...
ns.core = ns.core or {}

local TEXT_PRIORITY = ns.core.TEXT_PRIORITY

local BarTextFields = {}

-- Every field the bar can show, in the order they read. Copied rather than handed
-- out: the frozen list IS its backing store, and a caller that sorted it in place
-- would rewrite the priority order for the session.
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
