-- Ascent - the level report panel's "abilities used" tab, as a pure view-model
-- (11.4).
--
-- `record.abilities` is a plain table keyed by spell id or by one of AbilityKey's
-- two reserved synthetic keys for auto attacks (D9) -- this view-model does not
-- care which, it just ranks whatever is there. Resolving an icon from a spell id
-- is a UI-layer concern (it needs the client API, which core/ may never touch):
-- this module only carries `key` along so the UI can resolve one itself, and
-- knows there is nothing to resolve for the two synthetic keys.
--
-- totalUses -- the sum of every ability's count, auto attacks included -- is the
-- one shared denominator every entry's percentage is computed against, per this
-- task's own scenario (a single ranking, not a with/without-auto-attacks split).

local _, ns = ...
ns.core = ns.core or {}

local AbilityRankingViewModel = {}

-- ONE ROW PER ABILITY, NOT PER RANK.
--
-- In these clients every rank of a spell is its own spell id, so a priest who
-- outgrew Lesser Heal mid-level has two ids, two usages, and -- before this --
-- two rows reading "Lesser Heal" with nothing to tell them apart. Two rows the
-- player cannot distinguish is not a finer answer, it is a worse one: the
-- question this tab asks is what you pressed, and Lesser Heal is one button.
--
-- Grouped by NAME because that is what the player reads. A usage the client
-- could not name cannot be grouped that way and stands on its own key, which is
-- what it did before. The two synthetic auto-attack keys group themselves: they
-- carry distinct names, so nothing folds them together.
--
-- The row keeps the key of its BIGGEST rank, because the key is only there for
-- the UI to resolve an icon from, and ties go to the lower key so the choice
-- does not depend on `pairs`'s undefined order.
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

-- One entry per ability that was actually used; an ability sitting at zero (there
-- is no such thing today, but nothing guarantees it never will be) produces no
-- entry, the same call XpBarViewModel makes for a zero segment. Sorted by count
-- descending, ties broken by the string form of the key so the order is the same
-- on every build regardless of `pairs`'s own (undefined) iteration order.
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
-- data arrived) -- that is the only inactive case this view has: an active
-- record with no abilities used yet (a level just started) is not an error, it
-- is a ranking that happens to be empty.
function AbilityRankingViewModel.build(record)
  if record == nil then
    return { active = false }
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
