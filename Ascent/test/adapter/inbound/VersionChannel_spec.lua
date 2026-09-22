-- The one part of Ascent that talks to other clients. It never answers an
-- announcement with an announcement (in a forty-player raid that is sixteen
-- hundred messages), never spends more than its own budget however hard it is
-- shaken, and a client that answers strangely costs the announcement rather
-- than the addon. What SendAddonMessage returns is unverified, so nothing
-- here asserts it.

describe("VersionChannel", function()
  local ns, WowEvent, channel, watch
  local frame, sent, warned, clock

  local VERSION = "0.1.0"

  local function stubFrame()
    local stub = { registered = {} }
    function stub:RegisterEvent(event) self.registered[event] = true end
    function stub:UnregisterAllEvents() self.registered = {} end
    function stub:SetScript(_, fn) self.onEvent = fn end
    return stub
  end

  local function fire(event, ...)
    frame.onEvent(frame, event, ...)
  end

  local function build(overrides)
    overrides = overrides or {}
    watch = ns.core.UpdateWatch.new({ version = overrides.version or VERSION })
    channel = ns.adapter.VersionChannel.new({
      watch = watch,
      budget = ns.core.SendBudget.new({ clock = clock }),
      onNewer = function(version) warned[#warned + 1] = version end,
    })
    return channel:start()
  end

  before_each(function()
    ns = AscentTest.loadWith("core/port/", "core/model/VersionNumber.lua",
      "core/service/SendBudget.lua", "core/service/UpdateWatch.lua",
      "adapter/compat/Readable.lua", "adapter/inbound/VersionChannel.lua", "test/fakes/FakeClock.lua")
    WowEvent = ns.core.WowEvent

    sent, warned = {}, {}
    frame = stubFrame()
    clock = ns.fakes.FakeClock.new(0)

    _G.CreateFrame = function() return frame end
    _G.C_ChatInfo = {
      RegisterAddonMessagePrefix = function() return true end,
      SendAddonMessage = function(prefix, message, channelName)
        sent[#sent + 1] = { prefix = prefix, message = message, channel = channelName }
        return true
      end,
    }
    _G.IsInGuild = function() return true end
    _G.IsInGroup = function() return false end
    _G.IsInRaid = function() return false end
  end)

  after_each(function()
    _G.CreateFrame, _G.C_ChatInfo = nil, nil
    _G.IsInGuild, _G.IsInGroup, _G.IsInRaid = nil, nil, nil
  end)

  describe("announcing", function()
    it("says its version to the guild on entering the world", function()
      build()
      fire(WowEvent.PLAYER_ENTERING_WORLD)

      assert.equal(1, #sent)
      assert.equal("Ascent", sent[1].prefix)
      assert.equal("V:" .. VERSION, sent[1].message)
      assert.equal("GUILD", sent[1].channel)
    end)

    it("says nothing when there is nobody to say it to", function()
      _G.IsInGuild = function() return false end
      build()
      fire(WowEvent.PLAYER_ENTERING_WORLD)

      assert.equal(0, #sent)
    end)

    it("uses one group channel, not every one it qualifies for", function()
      _G.IsInGroup = function() return true end
      _G.IsInRaid = function() return true end
      build()
      fire(WowEvent.PLAYER_ENTERING_WORLD)

      -- The guild and the raid; a PARTY message would reach the same people a
      -- second time and cost a second message to do it.
      assert.equal(2, #sent)
      assert.equal("GUILD", sent[1].channel)
      assert.equal("RAID", sent[2].channel)
    end)

    it("follows the player into and out of groups", function()
      build()
      fire(WowEvent.GROUP_ROSTER_UPDATE)
      assert.equal(1, #sent)
    end)

    it("says nothing at all when the check is switched off", function()
      build()
      watch:enable(false)
      fire(WowEvent.PLAYER_ENTERING_WORLD)

      assert.equal(0, #sent)
    end)

    it("says nothing when it cannot read its own version", function()
      build({ version = "unknown" })
      fire(WowEvent.PLAYER_ENTERING_WORLD)

      assert.equal(0, #sent)
    end)
  end)

  describe("not making things worse", function()
    it("never answers someone else's announcement with its own", function()
      build()
      for index = 1, 40 do
        fire(WowEvent.CHAT_MSG_ADDON, "Ascent", "V:0.0.9", "GUILD", "Player" .. index)
      end

      assert.equal(0, #sent)
    end)

    it("spends its own budget and then stays quiet", function()
      build()
      for _ = 1, 30 do
        fire(WowEvent.GROUP_ROSTER_UPDATE)
      end

      -- Two rounds of one channel each: the reserve, and nothing more until the
      -- refill. The client's own allowance is ten, and this never approaches it.
      assert.equal(ns.core.UpdateBudget.CAPACITY, #sent)

      clock:advance(ns.core.UpdateBudget.REFILL_SECONDS)
      fire(WowEvent.GROUP_ROSTER_UPDATE)
      assert.equal(ns.core.UpdateBudget.CAPACITY + 1, #sent)
    end)

    it("survives a client that refuses to send, without retrying", function()
      _G.C_ChatInfo.SendAddonMessage = function() error("throttled") end
      build()

      assert.has_no.errors(function() fire(WowEvent.PLAYER_ENTERING_WORLD) end)
      assert.equal(0, #sent)
    end)

    it("loads and stays quiet on a client with no addon channel", function()
      _G.C_ChatInfo = nil
      assert.is_false(ns.adapter.VersionChannel.isSupported())

      build()
      assert.is_nil(frame.onEvent)
    end)

    it("does nothing when the client refuses the prefix registration", function()
      _G.C_ChatInfo.RegisterAddonMessagePrefix = function() error("nope") end
      build()

      assert.is_nil(frame.onEvent)
    end)
  end)

  describe("listening", function()
    local function hear(sender, message, prefix)
      fire(WowEvent.CHAT_MSG_ADDON, prefix or "Ascent", message, "GUILD", sender)
    end

    it("warns once three distinct players report the same newer version", function()
      build()
      hear("Alpha", "V:0.9.0")
      hear("Beta", "V:0.9.0")
      assert.equal(0, #warned)

      hear("Gamma", "V:0.9.0")
      assert.same({ "0.9.0" }, warned)
    end)

    it("ignores traffic that is not ours", function()
      build()
      for _, name in ipairs({ "Alpha", "Beta", "Gamma", "Delta" }) do
        hear(name, "V:0.9.0", "SomeOtherAddon")
      end

      assert.equal(0, #warned)
    end)

    it("shrugs off a malformed message instead of erroring", function()
      build()
      assert.has_no.errors(function()
        hear("Alpha", "")
        hear("Beta", "V:")
        hear("Gamma", "V:nonsense")
        hear("Delta", nil)
        hear(nil, "V:0.9.0")
      end)

      assert.equal(0, #warned)
    end)
  end)

  -- Another player's message is a client read too. A closed sender would be a
  -- table key in the watch's tally, which the client refuses outright; the
  -- stand-in secret, being a table, is accepted as a new name every time, so
  -- the verdict is asserted rather than the raise.
  describe("on a client that closes what the channel carries", function()
    local function buildClosed()
      AscentTest.withSecretRegime(function()
        ns = AscentTest.loadWith("core/port/", "core/model/VersionNumber.lua",
          "core/service/SendBudget.lua", "core/service/UpdateWatch.lua",
          "adapter/compat/Readable.lua", "adapter/inbound/VersionChannel.lua", "test/fakes/FakeClock.lua")
      end)
      WowEvent = ns.core.WowEvent
      clock = ns.fakes.FakeClock.new(0)
      return build()
    end

    it("counts no sender it cannot read towards the warning", function()
      buildClosed()
      AscentTest.withClientTypes(function()
        for _ = 1, 4 do
          fire(WowEvent.CHAT_MSG_ADDON, "Ascent", "V:0.9.0", "GUILD", AscentTest.secret("Somebody"))
        end
      end)

      assert.equal(0, #warned)
    end)

    it("reads nothing into a message it cannot read", function()
      buildClosed()
      AscentTest.withClientTypes(function()
        assert.has_no.errors(function()
          for _, name in ipairs({ "Alpha", "Beta", "Gamma", "Delta" }) do
            fire(WowEvent.CHAT_MSG_ADDON, "Ascent", AscentTest.secret("V:0.9.0"), "GUILD", name)
          end
        end)
      end)

      assert.equal(0, #warned)
    end)
  end)
end)
