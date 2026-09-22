-- The client's limits, asserted against the addon's own values, including the
-- version the TOC declares: a version that cannot be ordered would silently
-- break the update check in the client, so it fails here instead.

describe("the version channel's contract", function()
  local ns, UpdateWatch

  local function tocVersion()
    for line in io.lines((os.getenv("ASCENT_ROOT") or "Ascent") .. "/Ascent.toc") do
      local version = line:match("^## Version:%s*(.-)%s*$")
      if version then
        return version
      end
    end
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/VersionNumber.lua", "core/service/UpdateWatch.lua")
    UpdateWatch = ns.core.UpdateWatch
  end)

  it("uses a prefix the client will accept", function()
    local prefix = ns.core.UPDATE_PREFIX
    assert.is_true(#prefix > 0)
    assert.is_true(#prefix <= ns.core.UpdateLimit.PREFIX)
  end)

  it("declares a version this addon can announce and order", function()
    local version = tocVersion()
    assert.is_truthy(version, "the TOC declares no version")
    assert.is_truthy(ns.core.VersionNumber.parse(version),
      ("the TOC version %q is not a semver this addon can order"):format(tostring(version)))
  end)

  it("builds an announcement that fits the client's message limit", function()
    local message = UpdateWatch.encode(tocVersion())
    assert.is_truthy(message)
    assert.is_true(#message <= ns.core.UpdateLimit.MESSAGE)
  end)

  it("speaks only where other players already share activity with this one", function()
    local channels = {}
    for _, channel in ns.core.Frozen.each(ns.core.UpdateChannel) do
      channels[channel] = true
    end

    -- WHISPER is an unsolicited message to one person; SAY and YELL do carry
    -- addon messages in Classic and are noise to everyone nearby.
    for _, forbidden in ipairs({ "WHISPER", "SAY", "YELL", "CHANNEL", "OFFICER" }) do
      assert.is_nil(channels[forbidden], forbidden .. " is not a channel for this")
    end
    assert.is_true(channels.GUILD)
  end)

  it("keeps its own sending far below what the client allows", function()
    -- The client's own budget: 10 messages, one back per second. Anything close
    -- to that risks the player's connection, so this stays an order off it.
    assert.is_true(ns.core.UpdateBudget.CAPACITY <= 3)
    assert.is_true(ns.core.UpdateBudget.REFILL_SECONDS >= 10)
  end)

  it("needs more than one stranger's word before it repeats anything", function()
    assert.is_true(ns.core.UPDATE_PEER_THRESHOLD >= 3)
  end)
end)
