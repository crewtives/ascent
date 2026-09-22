-- The ranking reads `record.abilities`: what was used the most and its share of
-- every use in the level, with auto attacks in the same total and ranking but
-- tagged apart so the UI can treat them differently.

describe("AbilityRankingViewModel", function()
  local ns, AbilityRankingViewModel, LevelRecord, AbilityUsage, AbilityKey

  local function level()
    return LevelRecord.new(10, 0)
  end

  local function use(record, key, count, name)
    local usage = AbilityUsage.new(key, name)
    usage:record(count)
    record.abilities[key] = usage
    return usage
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/service/AbilityRankingViewModel.lua")
    AbilityRankingViewModel = ns.core.AbilityRankingViewModel
    LevelRecord = ns.core.LevelRecord
    AbilityUsage = ns.core.AbilityUsage
    AbilityKey = ns.core.AbilityKey
  end)

  describe("inactive state", function()
    it("has nothing to show with no record at all", function()
      assert.same({ active = false }, AbilityRankingViewModel.build(nil))
    end)
  end)

  it("ranks several abilities from most to least used, with percentages of the level's total", function()
    local record = level()
    use(record, 111, 5, "Sinister Strike")
    use(record, 222, 3, "Eviscerate")
    use(record, 333, 2, "Kick")

    local viewModel = AbilityRankingViewModel.build(record)

    assert.is_true(viewModel.active)
    assert.equal(10, viewModel.totalUses)
    assert.equal(3, #viewModel.entries)
    assert.equal(111, viewModel.entries[1].key)
    assert.equal(222, viewModel.entries[2].key)
    assert.equal(333, viewModel.entries[3].key)

    -- The fractions have to be internally consistent with totalUses, not just
    -- individually plausible.
    for _, entry in ipairs(viewModel.entries) do
      assert.near(entry.count, entry.fraction * viewModel.totalUses, 1e-9)
    end
  end)

  it("breaks a tie in count by the string form of the key, ascending", function()
    local record = level()
    use(record, 222, 4, "B")
    use(record, 111, 4, "A")

    local viewModel = AbilityRankingViewModel.build(record)

    assert.equal(111, viewModel.entries[1].key)
    assert.equal(222, viewModel.entries[2].key)
  end)

  it("tells an auto attack apart from a real spell in the same ranking", function()
    local record = level()
    use(record, 111, 5, "Sinister Strike")
    use(record, AbilityKey.MELEE_SWING, 20, nil)

    local viewModel = AbilityRankingViewModel.build(record)

    local byKey = {}
    for _, entry in ipairs(viewModel.entries) do
      byKey[entry.key] = entry
    end

    assert.is_false(byKey[111].isAutoAttack)
    assert.is_true(byKey[AbilityKey.MELEE_SWING].isAutoAttack)
    assert.equal(25, viewModel.totalUses)
  end)

  it("shows an empty ranking for a level that just started, without erroring", function()
    local record = level()

    local viewModel = AbilityRankingViewModel.build(record)

    assert.is_true(viewModel.active)
    assert.equal(0, viewModel.totalUses)
    assert.same({}, viewModel.entries)
  end)

  it("carries an ability's key even when its name was never cached", function()
    local record = level()
    use(record, 111, 1, nil)

    local viewModel = AbilityRankingViewModel.build(record)

    assert.equal(1, #viewModel.entries)
    assert.is_nil(viewModel.entries[1].name)
    assert.equal(111, viewModel.entries[1].key)
  end)

  -- Every rank of a spell is its own spell id in Classic Era and Burning
  -- Crusade Classic, so a level could report two rows both reading "Lesser
  -- Heal". One button, one row.
  describe("ranks of one spell", function()
    it("folds two ranks of the same spell into one row", function()
      local record = level()
      use(record, 2050, 3, "Lesser Heal")
      use(record, 2052, 2, "Lesser Heal")
      use(record, 585, 5, "Smite")

      local viewModel = AbilityRankingViewModel.build(record)

      assert.equal(2, #viewModel.entries)
      local byName = {}
      for _, entry in ipairs(viewModel.entries) do
        byName[entry.name] = entry
      end
      local healing = byName["Lesser Heal"]
      assert.is_not_nil(healing)
      assert.equal(5, healing.count)
      assert.equal(10, viewModel.totalUses)
      assert.equal(0.5, healing.fraction)
    end)

    it("keeps the key of the rank that was used the most, for the icon", function()
      local record = level()
      use(record, 2052, 2, "Lesser Heal")
      use(record, 2050, 7, "Lesser Heal")

      local viewModel = AbilityRankingViewModel.build(record)

      assert.equal(1, #viewModel.entries)
      assert.equal(2050, viewModel.entries[1].key)
    end)

    it("breaks a tie between two ranks on the lower key, not on pairs order", function()
      local record = level()
      use(record, 2052, 4, "Lesser Heal")
      use(record, 2050, 4, "Lesser Heal")

      local viewModel = AbilityRankingViewModel.build(record)

      assert.equal(1, #viewModel.entries)
      assert.equal(2050, viewModel.entries[1].key)
      assert.equal(8, viewModel.entries[1].count)
    end)

    it("does not fold together two abilities the client could not name", function()
      local record = level()
      use(record, 111, 2, nil)
      use(record, 222, 3, nil)

      local viewModel = AbilityRankingViewModel.build(record)

      assert.equal(2, #viewModel.entries)
    end)

    it("leaves the two auto attacks apart, because they are two different names", function()
      local record = level()
      use(record, AbilityKey.MELEE_SWING, 5, "Auto attack")
      use(record, AbilityKey.RANGED_AUTO, 8, "Ranged attack")

      local viewModel = AbilityRankingViewModel.build(record)

      assert.equal(2, #viewModel.entries)
      assert.equal("Ranged attack", viewModel.entries[1].name)
      assert.is_true(viewModel.entries[1].isAutoAttack)
    end)
  end)

  -- The ranking is one of the three metrics the combat log feeds. Not recorded
  -- is not "none used", and part of a level is not the level.
  describe("a level recorded without the combat log", function()
    it("ranks nothing and says why, even with uses counted before it closed", function()
      local record = ns.core.LevelRecord.new(10, 0)
      local fireball = ns.core.AbilityUsage.new(133, "Fireball")
      fireball.count = 12
      record.abilities[133] = fireball
      record:markUnavailable(ns.core.RecordedSource.COMBAT_LOG, "unreadable")

      local viewModel = ns.core.AbilityRankingViewModel.build(record)

      assert.is_true(viewModel.active)
      assert.equal("unreadable", viewModel.unavailable)
      assert.same({}, viewModel.entries)
      assert.is_nil(viewModel.totalUses)
    end)
  end)
end)
