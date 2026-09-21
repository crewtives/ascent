-- Switching a field on has to put it somewhere, and the answer is not "at the
-- end": the composed text is read left to right, and the same order decides what
-- the bar gives up when it is too narrow.

describe("BarTextFields", function()
  local ns, BarTextFields, TextToken

  before_each(function()
    ns = AscentTest.loadDomain("core/service/BarTextFields.lua")
    BarTextFields = ns.core.BarTextFields
    TextToken = ns.core.TextToken
  end)

  it("offers every field the bar can show, in the order they read", function()
    local fields = BarTextFields.all()

    assert.equal(TextToken.LEVEL, fields[1])
    assert.is_true(#fields > 1)
    assert.is_true(BarTextFields.rankOf(TextToken.LEVEL) < BarTextFields.rankOf(TextToken.SESSION_TIME))
  end)

  it("hands out a copy, not the priority order itself", function()
    local fields = BarTextFields.all()
    fields[1] = "tampered"

    assert.equal(TextToken.LEVEL, BarTextFields.all()[1])
  end)

  it("places a field switched on where its own rank says, not at the end", function()
    local chosen = { TextToken.XP_PERCENT, TextToken.SESSION_TIME }

    local result = BarTextFields.toggled(chosen, TextToken.LEVEL, true)

    assert.same({ TextToken.LEVEL, TextToken.XP_PERCENT, TextToken.SESSION_TIME }, result)
  end)

  it("appends a field that ranks after everything already chosen", function()
    local chosen = { TextToken.LEVEL, TextToken.XP_PERCENT }

    local result = BarTextFields.toggled(chosen, TextToken.SESSION_TIME, true)

    assert.same({ TextToken.LEVEL, TextToken.XP_PERCENT, TextToken.SESSION_TIME }, result)
  end)

  it("removes a field switched off and leaves the rest in order", function()
    local chosen = { TextToken.LEVEL, TextToken.XP_PERCENT, TextToken.RESTED }

    local result = BarTextFields.toggled(chosen, TextToken.XP_PERCENT, false)

    assert.same({ TextToken.LEVEL, TextToken.RESTED }, result)
  end)

  it("switching on a field that is already on changes nothing", function()
    local chosen = { TextToken.XP_PERCENT, TextToken.LEVEL }

    assert.same(chosen, BarTextFields.toggled(chosen, TextToken.LEVEL, true))
  end)

  it("switching off a field that is not on changes nothing", function()
    local chosen = { TextToken.LEVEL }

    assert.same(chosen, BarTextFields.toggled(chosen, TextToken.RESTED, false))
  end)

  -- An order the player set by hand is not rewritten by switching another field
  -- on: the fields already there keep their order relative to each other, and
  -- only the new one is placed -- by its own rank, which can put it first.
  it("keeps the relative order of fields already chosen", function()
    local chosen = { TextToken.SESSION_TIME, TextToken.XP_PERCENT }

    local result = BarTextFields.toggled(chosen, TextToken.RESTED, true)

    assert.same({ TextToken.RESTED, TextToken.SESSION_TIME, TextToken.XP_PERCENT }, result)

    local seenSession, seenPercent
    for index, token in ipairs(result) do
      if token == TextToken.SESSION_TIME then seenSession = index end
      if token == TextToken.XP_PERCENT then seenPercent = index end
    end
    assert.is_true(seenSession < seenPercent)
  end)

  it("never hands back the list it was given", function()
    local chosen = { TextToken.LEVEL }

    local result = BarTextFields.toggled(chosen, TextToken.RESTED, true)
    result[1] = "tampered"

    assert.equal(TextToken.LEVEL, chosen[1])
  end)

  it("switches the last field off without complaining", function()
    assert.same({}, BarTextFields.toggled({ TextToken.LEVEL }, TextToken.LEVEL, false))
  end)

  it("ranks a token nobody declared last, so it is given up first", function()
    assert.is_true(BarTextFields.rankOf("invented") > BarTextFields.rankOf(TextToken.SESSION_TIME))
  end)
end)
