-- The only thing that can ever reach the author is what a player pastes, so what
-- they paste has to survive the trip: no chat markup, and no silent truncation.

describe("CopyReport", function()
  local ns, CopyReport

  before_each(function()
    ns = AscentTest.loadDomain("core/service/CopyReport.lua")
    CopyReport = ns.core.CopyReport
  end)

  it("heads the report with what produced it, in the order given", function()
    local report = CopyReport.build({
      header = { { "addon", "Ascent 0.1.0" }, { "client", "BURNING_CRUSADE" } },
      lines = { "flavor: BURNING_CRUSADE" },
    })

    assert.equal("addon: Ascent 0.1.0\nclient: BURNING_CRUSADE\n\nflavor: BURNING_CRUSADE", report)
  end)

  -- Capabilities switched off are included too, each with the reason for its
  -- state.
  it("carries the identified client and every capability with its reason", function()
    local report = CopyReport.build({
      header = { { "client", "forever (interface 16001), max level 60" } },
      lines = CopyReport.capabilityLines({
        { name = "combat_log", present = false, reason = "unreadable" },
        { name = "quest_log", present = true, reason = "present" },
        { name = "xp_chat", present = false, reason = "absent" },
      }),
    })

    assert.equal(table.concat({
      "client: forever (interface 16001), max level 60",
      "",
      "  capability combat_log: unreadable",
      "  capability quest_log: present",
      "  capability xp_chat: absent",
    }, "\n"), report)
  end)

  it("ends cleanly when there is a header and nothing to report", function()
    local report = CopyReport.build({ header = { { "addon", "Ascent 0.1.0" } }, lines = {} })

    assert.equal("addon: Ascent 0.1.0", report)
  end)

  it("strips the colour codes that are markup in chat and litter in a paste", function()
    local report = CopyReport.build({ lines = { "|cff20ff20Elwynn Forest|r: 1200" } })

    assert.equal("Elwynn Forest: 1200", report)
  end)

  it("keeps the visible text of a hyperlink and drops the link itself", function()
    local report = CopyReport.build({
      lines = { "quest |Hquest:8887:12|hThe Missing Diplomat|h paid 1050" },
    })

    assert.equal("quest The Missing Diplomat paid 1050", report)
  end)

  it("drops texture escapes", function()
    local report = CopyReport.build({ lines = { "|TInterface\\Icons\\Ability:16|t Sinister Strike" } })

    assert.equal(" Sinister Strike", report)
  end)

  it("cuts an oversized report at a line boundary and says that it did", function()
    local lines = {}
    for index = 1, 200 do
      lines[index] = ("line %d: %s"):format(index, string.rep("x", 40))
    end

    local report = CopyReport.build({ lines = lines, limit = 500 })

    assert.is_true(#report < 700)
    assert.is_true(report:find("cut here", 1, true) ~= nil)

    -- The last line kept is a whole line: 40 x's, the same as every other one.
    local body = report:gsub("\n%-%- cut here.*$", "")
    local lastLine = body:match("([^\n]*)$")
    assert.is_true(lastLine:match("^line %d+: x+$") ~= nil, "the report was cut mid-line")
    assert.equal(40, #lastLine:match("x+"))
    -- What survived is the beginning, which is where the header and the client
    -- facts are: a report cut from the front would be worth nothing.
    assert.is_true(report:find("line 1:", 1, true) ~= nil)
  end)

  it("leaves a report that fits exactly as it is", function()
    local report = CopyReport.build({ lines = { "short" }, limit = 500 })

    assert.equal("short", report)
  end)

  it("survives a report with nothing in it", function()
    assert.equal("", CopyReport.build())
  end)
end)
