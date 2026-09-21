-- One property matters and everything else is a corollary of it: the numbers the
-- player reads add up to a hundred. A column of percentages summing to 99 is the
-- kind of small wrongness that costs trust in every other figure on the panel.

describe("Composition", function()
  local ns, Composition

  before_each(function()
    ns = AscentTest.loadDomain("core/service/Composition.lua")
    Composition = ns.core.Composition
  end)

  local function percentages(amounts)
    local entries = {}
    for index, amount in ipairs(amounts) do
      entries[index] = { key = "k" .. index, amount = amount }
    end
    return Composition.percentages(entries)
  end

  local function total(result)
    local sum = 0
    for _, entry in ipairs(result) do sum = sum + entry.percent end
    return sum
  end

  it("adds up to a hundred for the classic thirds that break naive rounding", function()
    assert.equal(100, total(percentages({ 1, 1, 1 })))
  end)

  it("adds up to a hundred across a sweep of awkward splits", function()
    for a = 1, 40 do
      for b = 1, 7 do
        assert.equal(100, total(percentages({ a, b, 3, 11 })), "a=" .. a .. " b=" .. b)
      end
    end
  end)

  it("gives the leftover point to whoever was closest to rounding up", function()
    -- 1/3 each: every share is 33.33, so the extra point goes to the first by
    -- the tie-break rule, not to a random one.
    local result = percentages({ 1, 1, 1 })

    assert.equal(34, result[1].percent)
    assert.equal(33, result[2].percent)
    assert.equal(33, result[3].percent)
  end)

  it("is reproducible: the same input always gives the same output", function()
    local first = percentages({ 7, 7, 7, 7, 1 })
    local second = percentages({ 7, 7, 7, 7, 1 })

    assert.same(first, second)
  end)

  it("keeps the caller's order, so a column reads in the order it was given", function()
    local result = Composition.percentages({
      { key = "mobs", amount = 10 },
      { key = "quests", amount = 90 },
    })

    assert.equal("mobs", result[1].key)
    assert.equal("quests", result[2].key)
  end)

  it("gives a single contributor the whole hundred", function()
    local result = percentages({ 4321 })

    assert.equal(100, result[1].percent)
  end)

  it("reports zero for everything when nothing was observed, rather than inventing a hundred", function()
    local result = percentages({ 0, 0, 0 })

    assert.equal(0, total(result))
  end)

  it("ignores a negative amount instead of letting it eat someone else's share", function()
    local result = percentages({ 50, -50, 50 })

    assert.equal(100, total(result))
    assert.equal(0, result[2].percent)
  end)

  it("handles an empty breakdown without failing", function()
    assert.same({}, Composition.percentages({}))
  end)

  it("never hands out a negative percentage", function()
    for _, entry in ipairs(percentages({ 1, 1000000, 1, 1 })) do
      assert.is_true(entry.percent >= 0)
    end
  end)

  it("still adds up when one contributor dwarfs the others", function()
    assert.equal(100, total(percentages({ 999999, 1, 1, 1 })))
  end)
end)
