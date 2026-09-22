-- Ascent - the report panel's "abilities used" tab, as a pure view-model.
--
-- `record.abilities` is keyed by spell id or by one of AbilityKey's two reserved
-- synthetic keys for auto attacks, and the ranking treats both alike. Resolving
-- an icon needs the client API, which core/ may not touch, so each entry carries
-- `key` for the UI to resolve; the synthetic keys have nothing to resolve.
--
-- totalUses, the sum of every ability's count with auto attacks included, is the
-- single denominator of every entry's percentage: one ranking, not a split.

local _, ns = ...
ns.core = ns.core or {}

local AbilityRankingViewModel = {}

-- One row per ability, not per rank: in these clients every rank of a spell is
-- its own spell id, so a spell outgrown mid-level (Lesser Heal, say) would
-- otherwise show as two rows the player cannot tell apart. Grouped by name,
-- because that is what the player reads; a usage the client could not name
-- stands on its own key. The two synthetic auto-attack keys carry distinct
-- names, so nothing folds them together.
--
-- The row keeps the key of its biggest rank, since the key only serves the UI to
-- resolve an icon; ties go to the lower key so the choice does not depend on
-- `pairs` order.
local function groupByName(abilities)
  local groups, order = {}, {}

  for _, usage in pairs(abilities) do
    if usage.count > 0 then
      local groupKey = usage.name ~= nil
        and ("name:" .. tostring(usage.name))
        or ("key:" .. tostring(usage.key))

      local group = groups[groupKey]
      if group == nil then
        group = {
          key = usage.key,
          name = usage.name,
          count = 0,
          topRank = 0,
          isAutoAttack = usage:isAutoAttack(),
        }
        groups[groupKey] = group
        order[#order + 1] = group
      elseif usage.count > group.topRank
        or (usage.count == group.topRank and tostring(usage.key) < tostring(group.key)) then
        group.key = usage.key
      end

      if usage.count > group.topRank then
        group.topRank = usage.count
      end
      group.count = group.count + usage.count
    end
  end

  return order
end

-- One entry per ability actually used; a zero count produces no entry, as a zero
-- segment does in XpBarViewModel. Sorted by count descending, ties broken by the
-- string form of the key so the order does not depend on `pairs` order.
local function buildEntries(abilities, totalUses)
  local entries = {}
  for _, group in ipairs(groupByName(abilities)) do
    entries[#entries + 1] = {
      key = group.key,
      name = group.name,
      count = group.count,
      fraction = group.count / totalUses,
      isAutoAttack = group.isAutoAttack,
    }
  end

  table.sort(entries, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return tostring(a.key) < tostring(b.key)
  end)

  return entries
end

-- `record` may be nil (no level selected yet, or the report opened before any
-- data arrived), the only inactive case. An active record with no abilities used
-- yet is an empty ranking, not an error.
function AbilityRankingViewModel.build(record)
  if record == nil then
    return { active = false }
  end

  -- A level recorded without the combat log ranks nothing, not even the uses it
  -- did count (that would rank part of a level as if it were the level), and
  -- says why. Read from the record's data rather than LevelRecord's accessor: the
  -- plate ranks a pull through this same function, and a pull keeps no such mark.
  local marks = record.unavailable
  local withoutCombatLog = marks ~= nil and marks[ns.core.RecordedSource.COMBAT_LOG] or nil
  if withoutCombatLog ~= nil then
    return { active = true, unavailable = withoutCombatLog, entries = {} }
  end

  local totalUses = 0
  for _, usage in pairs(record.abilities) do
    totalUses = totalUses + usage.count
  end

  return {
    active = true,
    totalUses = totalUses,
    entries = buildEntries(record.abilities, totalUses),
  }
end

ns.core.AbilityRankingViewModel = AbilityRankingViewModel
