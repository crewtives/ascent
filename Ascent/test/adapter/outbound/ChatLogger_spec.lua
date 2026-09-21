describe("ChatLogger", function()
  local messages

  local function load(debug)
    messages = {}
    _G.DEFAULT_CHAT_FRAME = {
      AddMessage = function(_, message) messages[#messages + 1] = message end,
    }

    local ns = AscentTest.loadWith("core/port/", "adapter/outbound/ChatLogger.lua")
    return ns.adapter.ChatLogger.new({ debug = debug })
  end

  after_each(function()
    _G.DEFAULT_CHAT_FRAME = nil
    _G.AscentCharDB = nil
  end)

  it("prefixes every message with the addon's own name", function()
    load(false):info("hello")

    assert.equal(1, #messages)
    assert.is_not_nil(messages[1]:find("Ascent", 1, true))
    assert.is_not_nil(messages[1]:find("hello", 1, true))
  end)

  it("always prints info", function()
    load(false):info("something happened")

    assert.equal(1, #messages)
  end)

  it("prints debug only when debug mode is on", function()
    load(false):debug("quiet")
    assert.equal(0, #messages)

    load(true):debug("loud")
    assert.equal(1, #messages)
  end)

  it("reports whether debug mode is on", function()
    assert.is_false(load(false):isDebug())
    assert.is_true(load(true):isDebug())
  end)

  it("shows the same warning only once", function()
    local logger = load(false)

    logger:warn("collector X failed")
    logger:warn("collector X failed")
    logger:warn("collector X failed")

    assert.equal(1, #messages)
  end)

  it("still shows a different warning even after an earlier one repeated", function()
    local logger = load(false)

    logger:warn("collector X failed")
    logger:warn("collector X failed")
    logger:warn("collector Y failed")

    assert.equal(2, #messages)
  end)

  -- Chat scrollback is not enough to reconstruct an ordering question after the
  -- fact -- it is shared with every other addon's output -- so debug lines are
  -- also kept in AscentCharDB.debugLog, the one thing a WoW addon can actually
  -- write to disk with (flushed by the client at logout/reload, read back from
  -- there rather than tailed live).
  describe("the persisted debug log", function()
    it("appends every debug line while debug mode is on", function()
      local logger = load(true)

      logger:debug("first")
      logger:debug("second")

      assert.same({ "first", "second" }, _G.AscentCharDB.debugLog)
    end)

    it("appends nothing while debug mode is off, same as it prints nothing", function()
      load(false):debug("quiet")

      assert.same({}, _G.AscentCharDB.debugLog)
    end)

    it("keeps working even if AscentCharDB already held other data", function()
      _G.AscentCharDB = { current = { level = 5 } }

      load(true):debug("hello")

      assert.equal(5, _G.AscentCharDB.current.level)
      assert.same({ "hello" }, _G.AscentCharDB.debugLog)
    end)

    it("caps the buffer instead of growing it forever, oldest entries first", function()
      local logger = load(true)

      for index = 1, 505 do
        logger:debug("line " .. index)
      end

      assert.equal(500, #_G.AscentCharDB.debugLog)
      assert.equal("line 6", _G.AscentCharDB.debugLog[1])
      assert.equal("line 505", _G.AscentCharDB.debugLog[500])
    end)
  end)
end)
