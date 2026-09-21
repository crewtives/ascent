-- AscentDB (account) and AscentCharDB (character) are plain globals the client
-- populates from disk before ADDON_LOADED and persists again at logout. There is no
-- disk here, so these tests stand in for a reload the way the rest of the suite
-- stands in for the client: by driving the same globals the client would and
-- checking what a second construction against them sees.

describe("SavedVariablesRepository", function()
  local function load()
    local ns = AscentTest.loadWith("core/port/", "adapter/outbound/SavedVariablesRepository.lua")
    return ns.adapter.SavedVariablesRepository.new()
  end

  after_each(function()
    _G.AscentDB = nil
    _G.AscentCharDB = nil
  end)

  it("creates both globals from nothing on a character that never saved", function()
    load()

    assert.is_table(_G.AscentDB)
    assert.is_table(_G.AscentCharDB)
  end)

  it("does not disturb an existing AscentDB or AscentCharDB", function()
    _G.AscentDB = { settings = { marker = "account" } }
    _G.AscentCharDB = { schemaVersion = 3, marker = "character" }

    load()

    assert.equal("account", _G.AscentDB.settings.marker)
    assert.equal("character", _G.AscentCharDB.marker)
  end)

  describe("the level in progress", function()
    it("round-trips through the character global", function()
      local repository = load()

      assert.is_nil(repository:currentRecord())

      repository:saveCurrentRecord({ level = 12, xp = 400 })

      assert.same({ level = 12, xp = 400 }, repository:currentRecord())
      assert.same({ level = 12, xp = 400 }, _G.AscentCharDB.current)
    end)

    -- What task 9.3 asks to confirm in the client: a fresh construction against the
    -- same globals -- the shape of what /reload leaves behind -- still sees it.
    it("survives a second construction against the same globals, as /reload would leave them", function()
      load():saveCurrentRecord({ level = 12, xp = 400 })

      local afterReload = load()

      assert.same({ level = 12, xp = 400 }, afterReload:currentRecord())
    end)
  end)

  describe("completed levels", function()
    it("answers nil for a level never recorded, distinct from one recorded at zero", function()
      local repository = load()

      assert.is_nil(repository:completedRecord(5))

      repository:saveCompletedRecord({ level = 5, xp = 0 })

      assert.same({ level = 5, xp = 0 }, repository:completedRecord(5))
    end)

    it("lists recorded levels ascending", function()
      local repository = load()

      repository:saveCompletedRecord({ level = 7, xp = 100 })
      repository:saveCompletedRecord({ level = 3, xp = 50 })

      assert.same({ 3, 7 }, repository:completedLevels())
    end)

    it("answers an empty list when nothing is recorded", function()
      assert.same({}, load():completedLevels())
    end)
  end)

  describe("settings", function()
    it("are nil on a fresh install, distinct from saved as empty", function()
      assert.is_nil(load():settings())
    end)

    it("live in the account-wide global, not the per-character one", function()
      local repository = load()

      repository:saveSettings({ barScale = 1.5 })

      assert.same({ barScale = 1.5 }, _G.AscentDB.settings)
      assert.is_nil(_G.AscentCharDB.settings)
    end)
  end)

  describe("quest rewards", function()
    it("default to an empty table, never nil", function()
      assert.same({}, load():questRewards())
    end)

    it("round-trip through the character global, keyed by quest id", function()
      local repository = load()

      repository:saveQuestRewards({ [1234] = 450 })

      assert.same({ [1234] = 450 }, repository:questRewards())
    end)
  end)

  describe("schema version", function()
    it("is nil on a character never recorded", function()
      assert.is_nil(load():schemaVersion())
    end)

    it("round-trips through the character global", function()
      local repository = load()

      repository:setSchemaVersion(2)

      assert.equal(2, repository:schemaVersion())
      assert.equal(2, _G.AscentCharDB.schemaVersion)
    end)
  end)

  describe("archiving incompatible data", function()
    it("tucks the whole previous character table under legacy and starts clean", function()
      _G.AscentCharDB = { schemaVersion = 99, current = { level = 40 } }
      local repository = load()

      repository:archiveIncompatible()

      assert.is_nil(repository:currentRecord())
      assert.is_nil(repository:schemaVersion())
      assert.same({ schemaVersion = 99, current = { level = 40 } }, _G.AscentCharDB.legacy)
    end)

    it("never touches the account-wide settings", function()
      _G.AscentDB = { settings = { marker = "keep me" } }
      local repository = load()

      repository:archiveIncompatible()

      assert.equal("keep me", repository:settings().marker)
    end)
  end)

  describe("clearing", function()
    it("wipes the character's recorded history", function()
      local repository = load()
      repository:saveCurrentRecord({ level = 12 })
      repository:saveCompletedRecord({ level = 5 })
      repository:saveQuestRewards({ [1] = 100 })

      repository:clear()

      assert.is_nil(repository:currentRecord())
      assert.same({}, repository:completedLevels())
      assert.same({}, repository:questRewards())
    end)

    it("never touches the account-wide settings", function()
      _G.AscentDB = { settings = { marker = "keep me" } }
      local repository = load()

      repository:clear()

      assert.equal("keep me", repository:settings().marker)
    end)
  end)
end)
