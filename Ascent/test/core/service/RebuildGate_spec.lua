-- The property task 11.7 asks for, literally: a closed view does zero rebuild
-- work, and an opened one rebuilds exactly once until something actually changes.

describe("RebuildGate", function()
  local ns, RebuildGate

  local function countingBuilder()
    local calls = 0
    return function()
      calls = calls + 1
      return calls
    end, function() return calls end
  end

  before_each(function()
    ns = AscentTest.loadWith("core/service/RebuildGate.lua")
    RebuildGate = ns.core.RebuildGate
  end)

  it("does not rebuild while hidden, however many times refresh is called", function()
    local gate = RebuildGate.new()
    local builder, calls = countingBuilder()

    for _ = 1, 5 do
      local result = gate:refresh(false, builder)
      assert.is_nil(result)
    end

    assert.equal(0, calls())
    assert.equal(0, gate:rebuildCount())
  end)

  it("rebuilds exactly once the first time it is shown, then stays quiet without a change", function()
    local gate = RebuildGate.new()
    local builder, calls = countingBuilder()

    local first = gate:refresh(true, builder)
    assert.equal(1, first)
    assert.equal(1, calls())
    assert.equal(1, gate:rebuildCount())

    -- Still visible, nothing marked dirty since: no more work.
    local second = gate:refresh(true, builder)
    assert.is_nil(second)
    assert.equal(1, calls())
    assert.equal(1, gate:rebuildCount())
  end)

  it("rebuilds again only after markDirty, and only once more per dirty mark", function()
    local gate = RebuildGate.new()
    local builder, calls = countingBuilder()

    gate:refresh(true, builder) -- consumes the initial dirty state
    assert.equal(1, calls())

    gate:markDirty()
    local rebuilt = gate:refresh(true, builder)
    assert.equal(2, rebuilt)
    assert.equal(2, calls())

    local unchanged = gate:refresh(true, builder)
    assert.is_nil(unchanged)
    assert.equal(2, calls())
  end)

  it("marking dirty while hidden does not spend a rebuild until it is shown", function()
    local gate = RebuildGate.new()
    local builder, calls = countingBuilder()

    gate:refresh(true, builder) -- clears the initial dirty state
    gate:markDirty()

    gate:refresh(false, builder)
    assert.equal(1, calls()) -- still just the first one; hidden did no work

    local shown = gate:refresh(true, builder)
    assert.equal(2, shown)
    assert.equal(2, calls())
  end)

  it("starts at a rebuild count of zero", function()
    local gate = RebuildGate.new()
    assert.equal(0, gate:rebuildCount())
  end)
end)
