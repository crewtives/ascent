-- Ascent - whole-number shares that add up (task 6.1).
--
-- The report panel answers two different questions with what looks like the same
-- number, and until now it printed one while the capability promised the other
-- (design D36):
--
--   how far through the level am I    amount / xpRequired. In a level still in
--                                     progress these sum to LESS than 100, and
--                                     that is honest -- the rest has not been
--                                     earned yet.
--   what was this level made of       amount / observed. These sum to exactly
--                                     100, because the question is about the
--                                     composition of what WAS earned.
--
-- Only the second one is this module's business, and only the second one may be
-- forced to a hundred. Doing that naively -- rounding each share on its own --
-- produces a column of percentages that adds up to 99 or 101, which readers
-- notice immediately and trust for the rest of the session accordingly.
--
-- The fix is the largest-remainder method: hand out the whole part of every
-- share, then give the leftover points, one each, to whoever was closest to
-- rounding up. Ties break on the declared order, so the same input always gives
-- the same output and a diagnostic never depends on hash order.

local _, ns = ...
ns.core = ns.core or {}

local Composition = {}

local TOTAL = 100

-- `entries` is a list of { key = ..., amount = ... }, in the order they will be
-- displayed. Returns a list of { key = ..., percent = <integer> } in the same
-- order, whose percents sum to exactly 100 -- or to 0 when nothing was observed
-- at all, which is the one case where forcing a hundred would be inventing data.
function Composition.percentages(entries)
  local result = {}
  local total = 0
  for _, entry in ipairs(entries) do
    total = total + math.max(0, entry.amount or 0)
  end

  if total <= 0 then
    for index, entry in ipairs(entries) do
      result[index] = { key = entry.key, percent = 0 }
    end
    return result
  end

  local assigned = 0
  local remainders = {}
  for index, entry in ipairs(entries) do
    local exact = math.max(0, entry.amount or 0) / total * TOTAL
    local whole = math.floor(exact)
    result[index] = { key = entry.key, percent = whole }
    assigned = assigned + whole
    remainders[index] = { index = index, remainder = exact - whole }
  end

  -- Largest remainder first; ties go to whoever comes first in the caller's own
  -- order, which is what makes this reproducible rather than merely correct.
  table.sort(remainders, function(a, b)
    if a.remainder == b.remainder then
      return a.index < b.index
    end
    return a.remainder > b.remainder
  end)

  local leftover = TOTAL - assigned
  local cursor = 1
  while leftover > 0 and #remainders > 0 do
    local pick = remainders[cursor]
    result[pick.index].percent = result[pick.index].percent + 1
    leftover = leftover - 1
    cursor = cursor + 1
    if cursor > #remainders then
      cursor = 1
    end
  end

  return result
end

ns.core.Composition = Composition
