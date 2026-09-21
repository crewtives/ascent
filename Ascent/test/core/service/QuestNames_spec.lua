-- The directory exists so that two surfaces showing the same quest cannot
-- disagree about its name, and so that a name learned at any moment reaches
-- every surface, including the report of a level that was closed before anyone
-- knew what the quest was called.

describe("QuestNames", function()
  local ns, QuestNames, repository

  local function directory(seed)
    repository = ns.fakes.InMemoryRepository.new(seed)
    return QuestNames.new({ repository = repository })
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "test/fakes/InMemoryRepository.lua", "core/service/QuestNames.lua")
    QuestNames = ns.core.QuestNames
  end)

  it("needs a repository", function()
    assert.has_error(function() QuestNames.new({}) end)
  end)

  it("answers with the name it was told, and nil for a quest nobody named", function()
    local names = directory()

    names:remember(8887, "Grimscale Pirates!")

    assert.equal("Grimscale Pirates!", names:nameFor(8887))
    assert.is_nil(names:nameFor(8884))
  end)

  it("persists a new name immediately, so a reload keeps it", function()
    local names = directory()
    names:remember(8887, "Grimscale Pirates!")

    local reloaded = QuestNames.new({ repository = repository })

    assert.equal("Grimscale Pirates!", reloaded:nameFor(8887))
  end)

  -- The sweep re-reads the whole quest log on every quest-log event, so this is
  -- the difference between a handful of writes a session and a few hundred a
  -- minute for a map that did not move.
  it("writes only when it actually learned something", function()
    local names = directory()

    assert.is_true(names:remember(8887, "Grimscale Pirates!"))
    local afterFirst = repository.writes

    assert.is_false(names:remember(8887, "Grimscale Pirates!"))
    assert.equal(afterFirst, repository.writes)
  end)

  it("keeps the first name it was given rather than a later, different one", function()
    local names = directory()
    names:remember(8887, "Grimscale Pirates!")

    assert.is_false(names:remember(8887, "Grimscale Pirat"))

    assert.equal("Grimscale Pirates!", names:nameFor(8887))
  end)

  -- Both halves arrive from the client, so both are shape checked: a bad one is
  -- dropped here rather than written to a file it would outlive the session in.
  it("drops anything that is not a quest id and a name", function()
    local names = directory()

    assert.is_false(names:remember(8887, nil))
    assert.is_false(names:remember(8887, ""))
    assert.is_false(names:remember(8887, 42))
    assert.is_false(names:remember(nil, "Grimscale Pirates!"))
    assert.is_false(names:remember(0, "Grimscale Pirates!"))
    assert.is_false(names:remember(1.5, "Grimscale Pirates!"))

    assert.equal(0, names:count())
  end)

  -- Names describe the client, not the character, so a reset that wipes this
  -- character's history leaves every other character's names alone.
  it("survives a character's data being cleared", function()
    local names = directory()
    names:remember(8887, "Grimscale Pirates!")

    repository:clear()

    assert.equal("Grimscale Pirates!", QuestNames.new({ repository = repository }):nameFor(8887))
  end)

  it("counts what it can name", function()
    local names = directory()

    assert.equal(0, names:count())
    names:remember(8887, "Grimscale Pirates!")
    names:remember(8884, "The Wayward Apprentice")
    assert.equal(2, names:count())
  end)
end)
