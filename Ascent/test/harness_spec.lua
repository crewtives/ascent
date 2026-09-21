describe("test harness", function()
  it("loads an addon file using the client's (addonName, ns) calling convention", function()
    local ns = AscentTest.loadFresh("test/fixtures/sample_module.lua")

    assert.is_table(ns.core.Sample)
    assert.equal("Ascent sample module", ns.core.Sample.describe())
    assert.equal(6, ns.core.Sample.sum({ 1, 2, 3 }))
  end)

  it("gives every test a namespace of its own", function()
    local first = AscentTest.newNamespace()
    first.core.marker = true

    local second = AscentTest.newNamespace()

    assert.is_nil(second.core.marker)
  end)

  it("reports a clear error when a file does not exist", function()
    assert.has_error(function()
      AscentTest.loadFresh("core/DoesNotExist.lua")
    end)
  end)

  it("runs on Lua 5.1 semantics, like the client does", function()
    assert.equal("Lua 5.1", _VERSION)
  end)

  it("runs with no WoW API in scope, so the domain cannot lean on it by accident", function()
    assert.is_nil(_G.UnitXP)
    assert.is_nil(_G.CreateFrame)
    assert.is_nil(_G.GetTime)
  end)
end)
