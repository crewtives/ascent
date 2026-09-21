describe("WowClock", function()
  local ns, clock

  before_each(function()
    _G.GetTime = function() return 1234.5 end
    _G.time = function() return 1700000000 end

    ns = AscentTest.loadWith("core/port/", "adapter/outbound/WowClock.lua")
    clock = ns.adapter.WowClock.new()
  end)

  after_each(function()
    _G.GetTime = nil
    _G.time = nil
  end)

  it("reads the monotonic clock from GetTime()", function()
    assert.equal(1234.5, clock:now())
  end)

  it("reads the wall clock from time()", function()
    assert.equal(1700000000, clock:timestamp())
  end)
end)
