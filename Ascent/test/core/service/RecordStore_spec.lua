-- The store is the only thing that knows both sides of the boundary: records with
-- methods on one, plain tables on the other. The repository double rejects anything
-- carrying a metatable, so a conversion this file forgets fails the suite here
-- rather than as half a record on somebody's next login.

describe("RecordStore", function()
  local ns, repository, store

  local function load()
    return AscentTest.loadWith("core/model/", "core/port/",
      "core/service/XpLedger.lua", "core/service/RecordStore.lua",
      "test/fakes/InMemoryRepository.lua")
  end

  local function newStore(options)
    options = options or {}
    options.repository = repository
    return ns.core.RecordStore.new(options)
  end

  local function record(level, xp)
    local built = ns.core.LevelRecord.new(level, 1700000000)
    built.xpRequired = 8800
    if xp ~= nil and xp > 0 then
      ns.core.XpLedger.post(built, ns.core.XpGain.new({
        amount = xp, source = ns.core.XpSource.MOB_KILL, at = 10,
        creature = ns.core.CreatureKey.new(5644, 6, "Kobold Miner"),
      }))
    end
    return built
  end

  before_each(function()
    ns = load()
    repository = ns.fakes.InMemoryRepository.new()
    store = newStore():load()
  end)

  describe("a character nobody has recorded", function()
    it("stamps the current format and has no record", function()
      assert.equal(ns.core.SchemaVersion.CURRENT, repository:schemaVersion())
      assert.is_nil(store:current())
      assert.is_false(store.archived)
    end)
  end)

  describe("records", function()
    it("survives a round trip through plain tables", function()
      store:saveCurrent(record(24, 350))

      local restored = store:current()
      assert.equal(24, restored.level)
      assert.equal(350, restored.xpTotal)
      assert.equal(1, restored.creatures["5644:6@?"].kills)
      assert.is_true(restored:sourcesAddUp())
    end)

    -- Nil and a level recorded as all zeroes are different answers: one means the
    -- addon was not there, the other means it was and the player gained nothing.
    it("tells a level with no record from a level recorded as empty", function()
      assert.is_nil(store:completed(23))

      store:saveCompleted(record(23, 0))

      local empty = store:completed(23)
      assert.is_not_nil(empty)
      assert.equal(0, empty.xpTotal)
      assert.is_nil(store:completed(22))
    end)

    it("lists the levels it holds, in order", function()
      store:saveCompleted(record(25, 10))
      store:saveCompleted(record(23, 10))
      store:saveCompleted(record(24, 10))

      assert.same({ 23, 24, 25 }, store:completedLevels())
    end)

    -- Loading always wins. One unreadable record costs that record, not the history
    -- around it and not the addon's ability to start.
    it("treats a record it cannot read as no record, and says so", function()
      repository:saveCurrentRecord({ level = "twenty four" })

      assert.is_nil(store:current())
      assert.is_true(store.discarded)
    end)

    it("refuses to be read before it has loaded", function()
      local unloaded = newStore()

      assert.has_error(function() return unloaded:current() end)
      assert.has_error(function() return unloaded:completedLevels() end)
    end)
  end)

  describe("migrating forward", function()
    it("walks the chain and stamps the new version", function()
      repository:setSchemaVersion(0)
      repository:saveCurrentRecord({ level = 24, xpTotal = 100 })

      local migrated = newStore({
        migrations = {
          [0] = function(repo)
            local stored = repo:currentRecord()
            stored.xpBySource = { mob_kill = stored.xpTotal }
            repo:saveCurrentRecord(stored)
          end,
          -- Every version between the stored one and the current one needs a step,
          -- including the ones that convert nothing.
          [1] = function() end,
          [2] = function() end,
          [3] = function() end,
          [4] = function() end,
        },
      }):load()

      assert.is_false(migrated.archived)
      assert.equal(ns.core.SchemaVersion.CURRENT, repository:schemaVersion())
      assert.equal(100, migrated:current():xpFrom(ns.core.XpSource.MOB_KILL))
    end)

    it("walks several steps in order", function()
      repository:setSchemaVersion(0)
      repository:saveCurrentRecord({ level = 24 })
      local seen = {}

      newStore({
        version = 3,
        migrations = {
          [0] = function() seen[#seen + 1] = 0 end,
          [1] = function() seen[#seen + 1] = 1 end,
          [2] = function() seen[#seen + 1] = 2 end,
        },
      }):load()

      assert.same({ 0, 1, 2 }, seen)
      assert.equal(3, repository:schemaVersion())
    end)

    -- RecordStore.MIGRATIONS is the table production uses; every other test here
    -- injects its own. A version below the current one with no step is not "no
    -- conversion needed": migrate() returns false and load() archives the
    -- character's whole history on first login.
    it("ships a step for every version below the current one", function()
      for version = 1, ns.core.SchemaVersion.CURRENT - 1 do
        assert.equal("function", type(ns.core.RecordStore.MIGRATIONS[version]),
          ("no migration step for version %d -> %d"):format(version, version + 1))
      end
    end)

    -- And the same thing end to end, because a table with the right keys is not
    -- proof that a real character survives the walk.
    it("carries a character forward from the previous version without archiving", function()
      repository:setSchemaVersion(ns.core.SchemaVersion.CURRENT - 1)
      repository:saveCurrentRecord({ level = 24, xpTotal = 100 })

      local loaded = newStore():load()

      assert.is_false(loaded.archived)
      assert.equal(ns.core.SchemaVersion.CURRENT, repository:schemaVersion())
      assert.equal(24, loaded:current().level)
    end)

    -- The 3 -> 4 step cannot be `function() end`: the group a creature's kills were
    -- paid to is written ahead of the creature's key, the line's variable-length
    -- tail, so every stored creature line shifts by a field. Pinned at 3 rather
    -- than derived from CURRENT, because this conversion belongs to that step.
    it("converts the creature aggregates its step was raised for", function()
      local step = ns.core.RecordStore.MIGRATIONS[3]
      assert.equal("function", type(step))

      repository:saveCurrentRecord({
        level = 24,
        creatures = "1,84,15343,6,Springpaw Lynx;2,104",
      })

      step(repository)

      -- The blank in the third field is the whole conversion. The unidentified
      -- aggregate keeps its two fields: its blank is trailing, and trailing blanks
      -- are dropped.
      assert.equal("1,84,,15343,6,Springpaw Lynx;2,104",
        repository:currentRecord().creatures)
    end)

    -- A file in the shape version 3 wrote, read back through the model: the
    -- end-to-end test above stores no creature aggregates at all. Pinned at 3, not
    -- derived from CURRENT, so a later bump walks it through every later step too.
    it("reads a file from version 3 with its creatures intact and uncounted", function()
      repository:setSchemaVersion(3)
      repository:saveCurrentRecord({
        level = 24, xpTotal = 128, killsWithXp = 3,
        xpBySource = { mob_kill = 128 },
        creatures = "1,84,15343,6,Springpaw Lynx;2,44,5644,6,Kobold Miner",
      })
      repository:saveCompletedRecord({
        level = 23, xpTotal = 44, killsWithXp = 1,
        xpBySource = { mob_kill = 44 },
        creatures = "1,44,5644,6,Kobold Miner",
      })

      local loaded = newStore():load()
      assert.is_false(loaded.archived)

      local current = loaded:current()
      local lynx = current.creatures["15343:6@?"]
      assert.equal(15343, lynx.key.npcId)
      assert.equal("Springpaw Lynx", lynx.key.name)
      assert.equal(1, lynx.kills)
      assert.equal(84, lynx.xpTotal)

      -- Unknown, and deliberately not solo: most of these kills probably were solo,
      -- which is exactly what would make claiming it undetectable.
      assert.is_nil(lynx.sharedBy)
      assert.is_nil(current.creatures["15343:6@1"])

      -- The levels already finished walk forward too. The step is handed the
      -- repository, and the history is the larger part of what is in it.
      assert.equal(44, loaded:completed(23).creatures["5644:6@?"].xpTotal)

      -- The level's own sums live outside the packed text: the step separates a
      -- breakdown, it does not restate a total.
      assert.equal(128, current:xpFrom(ns.core.XpSource.MOB_KILL))
      assert.equal(3, current.killsWithXp)
    end)

    -- 4 -> 5 converts nothing: every level written at 4 was recorded by a Classic
    -- client, which had both sources, so it comes back unmarked, neither marked
    -- nor refused.
    it("reads a level written at 4 as one recorded with every source", function()
      repository:setSchemaVersion(4)
      repository:saveCurrentRecord({ level = 24, xpTotal = 100, xpBySource = { mob_kill = 100 } })

      local loaded = newStore():load()

      assert.is_false(loaded.archived)
      assert.same({}, loaded:current().unavailable)
    end)
  end)

  describe("data this version cannot read", function()
    local function assertArchived(archivedStore)
      assert.is_true(archivedStore.archived)
      assert.is_not_nil(repository.legacy, "the old data was not kept aside")
      assert.equal(ns.core.SchemaVersion.CURRENT, repository:schemaVersion())
      assert.is_nil(archivedStore:current())
    end

    -- Written by a build newer than this one. A migration chain only walks forward.
    it("archives data from the future", function()
      repository:setSchemaVersion(99)
      repository:saveCurrentRecord({ level = 24 })

      assertArchived(newStore():load())
    end)

    it("archives a version with no migration to walk", function()
      repository:setSchemaVersion(0)
      repository:saveCurrentRecord({ level = 24 })

      assertArchived(newStore({ migrations = {} }):load())
    end)

    -- A migration that throws leaves the data half converted, which is exactly the
    -- state worth putting aside rather than handing to the rest of the addon.
    it("archives data a migration failed halfway through", function()
      repository:setSchemaVersion(0)
      repository:saveCurrentRecord({ level = 24 })

      assertArchived(newStore({
        migrations = { [0] = function() error("the shape was not what I expected") end },
      }):load())
    end)

    it("archives a version that is not a version at all", function()
      repository:setSchemaVersion("1.0")
      repository:saveCurrentRecord({ level = 24 })

      assertArchived(newStore():load())
    end)

    -- Options are account-wide and are not what could not be read.
    it("keeps the player's options through an archive", function()
      repository:saveSettings({ bar_scale = 1.5 })
      repository:setSchemaVersion(99)

      newStore():load()

      assert.same({ bar_scale = 1.5 }, repository:settings())
    end)
  end)
end)
