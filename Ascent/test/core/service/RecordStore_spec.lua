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
      assert.equal(1, restored.creatures["5644:6"].kills)
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

    -- The guard the chain never had. RecordStore.MIGRATIONS is the table production
    -- uses, and nothing above touches it: every test here injects its own. A version
    -- below the current one with no step does NOT mean "no conversion needed" --
    -- migrate() returns false and load() archives the character's whole history on
    -- first login. Raising SchemaVersion.CURRENT and forgetting the step is
    -- therefore silent data loss that passes test, lint and smoke alike.
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

    -- Options are account-wide and were never the thing that could not be read.
    it("keeps the player's options through an archive", function()
      repository:saveSettings({ bar_scale = 1.5 })
      repository:setSchemaVersion(99)

      newStore():load()

      assert.same({ bar_scale = 1.5 }, repository:settings())
    end)
  end)
end)
