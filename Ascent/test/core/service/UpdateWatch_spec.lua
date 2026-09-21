-- What the addon believes about other people's versions, and what it refuses to
-- believe. The threshold is the security property of this change: a message body
-- is written by somebody else's client, so a single report has to be worth
-- nothing at all.

describe("UpdateWatch", function()
  local ns, UpdateWatch

  local function watching(version, overrides)
    local options = { version = version or "0.1.0" }
    for key, value in pairs(overrides or {}) do
      options[key] = value
    end
    return UpdateWatch.new(options)
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/VersionNumber.lua", "core/service/UpdateWatch.lua")
    UpdateWatch = ns.core.UpdateWatch
  end)

  describe("the wire format", function()
    it("announces a version and reads one back", function()
      local message = UpdateWatch.encode("0.1.0")
      assert.equal("V:0.1.0", message)
      assert.equal("0.1.0", UpdateWatch.decode(message))
    end)

    it("says nothing when the version is not one", function()
      assert.is_nil(UpdateWatch.encode(nil))
      assert.is_nil(UpdateWatch.encode("unknown"))
    end)

    it("refuses to announce a version too long for the client's message limit", function()
      -- Truncating would announce a version that is not ours, which is worse
      -- than staying quiet.
      assert.is_nil(UpdateWatch.encode("1.0.0-" .. ("x"):rep(ns.core.UpdateLimit.MESSAGE)))
    end)

    it("ignores anything on our prefix that is not an announcement", function()
      for _, message in ipairs({ "", "hello", "V:", "V:nonsense", "X:0.2.0" }) do
        assert.is_nil(UpdateWatch.decode(message), ("decoded %q"):format(message))
      end
      assert.is_nil(UpdateWatch.decode(nil))
    end)
  end)

  describe("the threshold", function()
    it("says nothing for a single report", function()
      local watch = watching("0.1.0")
      assert.is_nil(watch:record("Alpha", "V:0.9.0"))
    end)

    it("warns once three distinct players have said the same thing", function()
      local watch = watching("0.1.0")
      assert.is_nil(watch:record("Alpha", "V:0.9.0"))
      assert.is_nil(watch:record("Beta", "V:0.9.0"))
      assert.equal("0.9.0", watch:record("Gamma", "V:0.9.0"))
    end)

    it("counts a player once however many times they repeat themselves", function()
      local watch = watching("0.1.0")
      for _ = 1, 10 do
        assert.is_nil(watch:record("Alpha", "V:0.9.0"))
      end
      assert.is_nil(watch:record("Beta", "V:0.9.0"))
    end)

    it("does not add up reports of different versions", function()
      local watch = watching("0.1.0")
      assert.is_nil(watch:record("Alpha", "V:0.2.0"))
      assert.is_nil(watch:record("Beta", "V:0.3.0"))
      assert.is_nil(watch:record("Gamma", "V:0.4.0"))
    end)

    it("never counts a version it cannot read, or one that is not newer", function()
      local watch = watching("0.1.0")
      for _, name in ipairs({ "Alpha", "Beta", "Gamma", "Delta" }) do
        assert.is_nil(watch:record(name, "V:nonsense"))
        assert.is_nil(watch:record(name, "V:0.0.1"))
        assert.is_nil(watch:record(name, "V:0.1.0"))
      end
    end)

    it("ignores a report with no sender", function()
      local watch = watching("0.1.0")
      assert.is_nil(watch:record(nil, "V:0.9.0"))
      assert.is_nil(watch:record("", "V:0.9.0"))
    end)
  end)

  describe("speaking at all", function()
    it("warns exactly once per session", function()
      local watch = watching("0.1.0")
      watch:record("Alpha", "V:0.9.0")
      watch:record("Beta", "V:0.9.0")
      assert.equal("0.9.0", watch:record("Gamma", "V:0.9.0"))

      for _, name in ipairs({ "Delta", "Epsilon", "Zeta" }) do
        assert.is_nil(watch:record(name, "V:9.9.9"))
      end
    end)

    it("is silent in both directions when it is switched off", function()
      local watch = watching("0.1.0", { enabled = false })
      assert.is_false(watch:speaks())

      watch:record("Alpha", "V:0.9.0")
      watch:record("Beta", "V:0.9.0")
      assert.is_nil(watch:record("Gamma", "V:0.9.0"))
    end)

    it("comes back to life the moment it is switched on again, without a reload", function()
      local watch = watching("0.1.0", { enabled = false })
      watch:enable(true)
      assert.is_true(watch:speaks())
    end)

    it("says nothing at all when it cannot read its own version", function()
      local watch = watching("unknown")
      assert.is_false(watch:speaks())
      assert.is_nil(watch:record("Alpha", "V:0.9.0"))
    end)
  end)

  describe("what changed since the last session", function()
    it("treats a missing memory as an install, not an update", function()
      assert.equal("first", UpdateWatch.compareSeen(nil, "0.1.0"))
      assert.equal("first", UpdateWatch.compareSeen("", "0.1.0"))
    end)

    it("names an upgrade and a downgrade", function()
      assert.equal("updated", UpdateWatch.compareSeen("0.1.0", "0.2.0"))
      assert.equal("downgraded", UpdateWatch.compareSeen("0.2.0", "0.1.0"))
    end)

    it("says nothing when nothing changed", function()
      assert.equal("same", UpdateWatch.compareSeen("0.1.0", "0.1.0"))
    end)

    it("stays quiet rather than guessing when the running version is unreadable", function()
      assert.equal("same", UpdateWatch.compareSeen("0.1.0", "unknown"))
    end)
  end)
end)
