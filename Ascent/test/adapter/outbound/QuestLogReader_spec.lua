-- Which reader a client gets is decided by the API it has, never by which client
-- it is: the two stop agreeing as soon as a client moves its quest log without
-- renaming itself.

describe("QuestLogReader", function()
  local ns

  local function load()
    ns = AscentTest.loadWith("core/model/", "core/port/", "adapter/compat/Readable.lua",
      "adapter/inbound/GlobalStringPattern.lua", "adapter/outbound/QuestLogShape.lua",
      "adapter/outbound/ClassicQuestLogReader.lua", "adapter/outbound/ModernQuestLogReader.lua",
      "adapter/outbound/QuestLogReader.lua")
    return ns.adapter.QuestLogReader
  end

  local function classicApi()
    _G.GetQuestLogTitle = function() return nil end
    _G.GetNumQuestLogEntries = function() return 0 end
    _G.SelectQuestLogEntry = function() end
    _G.GetQuestLogSelection = function() return 0 end
  end

  local function modernApi()
    _G.C_QuestLog = {
      GetNumQuestLogEntries = function() return 0, 0 end,
      GetInfo = function() return nil end,
    }
  end

  before_each(function()
    _G.issecurevariable = function() return true end
  end)

  after_each(function()
    for _, name in ipairs({ "C_QuestLog", "GetQuestLogTitle", "GetNumQuestLogEntries",
      "SelectQuestLogEntry", "GetQuestLogSelection", "issecurevariable" }) do
      _G[name] = nil
    end
  end)

  it("takes the classic reader on a client with no C_QuestLog", function()
    classicApi()
    local QuestLogReader = load()

    assert.is_true(QuestLogReader.isSupported())
    assert.equal(ns.adapter.ClassicQuestLogReader, getmetatable(QuestLogReader.new()))
  end)

  it("takes the modern reader on a client with none of the classic globals", function()
    modernApi()
    local QuestLogReader = load()

    assert.is_true(QuestLogReader.isSupported())
    assert.equal(ns.adapter.ModernQuestLogReader, getmetatable(QuestLogReader.new()))
  end)

  -- Where both exist the modern one wins, and for a reason the player can see:
  -- it never moves the selection in their own quest log.
  it("prefers the modern reader on a client that has both", function()
    classicApi()
    modernApi()
    local QuestLogReader = load()

    assert.equal(ns.adapter.ModernQuestLogReader, getmetatable(QuestLogReader.new()))
  end)

  -- The capability goes off, and the addon still loads: an empty log is what the
  -- pending tab shows, and the diagnostic is where "it cannot be asked" is said.
  it("reports the capability absent on a client with neither, and reads an empty log", function()
    local QuestLogReader = load()

    assert.is_false(QuestLogReader.isSupported())

    local reader = QuestLogReader.new()
    assert.same({}, reader:scan())
    local read, seen = reader:objectiveTally()
    assert.equal(0, read)
    assert.equal(0, seen)
  end)

  -- A partial classic tree is not a classic client: the reader needs all four,
  -- and three of them plus a nil is how a sweep dies halfway through.
  it("does not take the classic reader from an incomplete classic tree", function()
    classicApi()
    _G.SelectQuestLogEntry = nil
    local QuestLogReader = load()

    assert.is_false(QuestLogReader.isSupported())
  end)
end)
