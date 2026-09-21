-- The changelog as the player reads it. The case with no entries is the one worth
-- a test: an empty window and "this build carries no changelog" look identical
-- from the code and completely different from the chair.

describe("ChangelogText", function()
  local ChangelogText

  local ENTRIES = {
    { version = "0.2.0", date = "2026-10-01", lines = { "Added", "- Something new." } },
    { version = "0.1.0", date = "2026-09-21", lines = { "First public build." } },
  }

  before_each(function()
    ChangelogText = AscentTest.loadWith("core/service/ChangelogText.lua").core.ChangelogText
  end)

  it("says nothing at all when the build carries no changelog", function()
    assert.is_nil(ChangelogText.build(nil, "0.1.0"))
    assert.is_nil(ChangelogText.build({}, "0.1.0"))
  end)

  it("puts every version in, with its date", function()
    local text = ChangelogText.build(ENTRIES, "0.2.0")
    assert.is_truthy(text:find("0.2.0", 1, true))
    assert.is_truthy(text:find("2026-10-01", 1, true))
    assert.is_truthy(text:find("Something new.", 1, true))
    assert.is_truthy(text:find("First public build.", 1, true))
  end)

  it("leads with the version being played, even when it is not the newest", function()
    local text = ChangelogText.build(ENTRIES, "0.1.0")
    assert.is_true(text:find("0.1.0", 1, true) < text:find("0.2.0", 1, true))
  end)

  it("keeps the newest first when the running version is not in the list", function()
    local text = ChangelogText.build(ENTRIES, "9.9.9")
    assert.is_true(text:find("0.2.0", 1, true) < text:find("0.1.0", 1, true))
  end)
end)
