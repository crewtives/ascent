-- 13.1: the three branches of Locale:get, and the one negative case the spec
-- states outright -- "En ningún caso SHALL mostrarse [...] un identificador
-- interno en lugar de un texto, salvo en modo de diagnóstico". A test that only
-- proved the key shows *in* debug mode would leave the forbidden half unproven.

describe("LocaleTable", function()
  local ns, TextKey, LocaleTable

  local function build(options)
    options = options or {}
    options.tables = options.tables or {
      enUS = {
        [TextKey.BAR_NO_XP]       = "No experience to track",
        [TextKey.NOT_AVAILABLE]   = "n/a",
        [TextKey.PANEL_DEATHS]    = "Deaths: %d",
      },
      esES = {
        [TextKey.BAR_NO_XP]       = "Sin experiencia que seguir",
      },
    }
    return LocaleTable.new(options)
  end

  before_each(function()
    ns = AscentTest.loadWith("core/port/", "locale/")
    TextKey = ns.core.TextKey
    LocaleTable = ns.locale.LocaleTable
  end)

  it("implements the Locale port", function()
    assert.equal("Locale", ns.core.Port.nameOf(ns.core.Locale))
    assert.has_no.errors(function() return build({ locale = "enUS" }) end)
  end)

  describe("choosing a text", function()
    it("uses the client's language when it has the text", function()
      assert.equal("Sin experiencia que seguir", build({ locale = "esES" }):get(TextKey.BAR_NO_XP))
    end)

    it("falls back to the base language key by key", function()
      -- esES has BAR_NO_XP but not PANEL_DEATHS: the gap falls through on its own,
      -- rather than dropping the whole language.
      local locale = build({ locale = "esES" })

      assert.equal("Sin experiencia que seguir", locale:get(TextKey.BAR_NO_XP))
      assert.equal("Deaths: 3", locale:get(TextKey.PANEL_DEATHS, 3))
    end)

    it("falls back to the base language when the client's language has no table at all", function()
      assert.equal("No experience to track", build({ locale = "deDE" }):get(TextKey.BAR_NO_XP))
    end)

    it("substitutes format arguments", function()
      assert.equal("Deaths: 12", build({ locale = "enUS" }):get(TextKey.PANEL_DEATHS, 12))
    end)
  end)

  describe("a key no language has", function()
    it("shows the key itself in diagnostic mode, so it can be located", function()
      local locale = build({ locale = "enUS", isDebug = function() return true end })

      assert.equal(TextKey.PANEL_BY_QUEST, locale:get(TextKey.PANEL_BY_QUEST))
    end)

    it("shows the no-data marker outside diagnostic mode, never the identifier", function()
      local locale = build({ locale = "enUS", isDebug = function() return false end })
      local text = locale:get(TextKey.PANEL_BY_QUEST)

      assert.equal("n/a", text)
      assert.is_nil(text:find(TextKey.PANEL_BY_QUEST, 1, true))
    end)

    it("is never blank and never nil, whichever mode is on", function()
      for _, debugOn in ipairs({ true, false }) do
        local text = build({ locale = "enUS", isDebug = function() return debugOn end })
          :get(TextKey.PANEL_BY_QUEST)

        assert.is_string(text)
        assert.is_true(#text > 0)
      end
    end)

    it("reads diagnostic mode live, not as a snapshot taken at boot", function()
      -- The player can toggle debug mid-session; a boolean captured in new() would
      -- answer for the rest of it. Same hazard 12.7 names for the options panel.
      local debugOn = false
      local locale = build({ locale = "enUS", isDebug = function() return debugOn end })

      assert.equal("n/a", locale:get(TextKey.PANEL_BY_QUEST))
      debugOn = true
      assert.equal(TextKey.PANEL_BY_QUEST, locale:get(TextKey.PANEL_BY_QUEST))
    end)

    it("falls back to a literal marker when even the marker's own key is missing", function()
      local locale = LocaleTable.new({
        tables = { enUS = { [TextKey.BAR_NO_XP] = "No experience to track" } },
        locale = "enUS",
      })

      assert.equal("n/a", locale:get(TextKey.PANEL_BY_QUEST))
    end)
  end)

  describe("has", function()
    it("is true only when the client's own language carries the text", function()
      local spanish = build({ locale = "esES" })

      assert.is_true(spanish:has(TextKey.BAR_NO_XP))
      assert.is_false(spanish:has(TextKey.PANEL_DEATHS))
    end)

    it("is false for every key when the client's language has no table", function()
      assert.is_false(build({ locale = "deDE" }):has(TextKey.BAR_NO_XP))
    end)
  end)

  it("refuses to wire without a base table, rather than degrading silently", function()
    local ok, err = pcall(LocaleTable.new, { tables = {}, base = "enUS" })

    assert.is_false(ok)
    assert.is_truthy(err:find("enUS", 1, true))
  end)

  it("defaults to the shipped tables when none are injected", function()
    local locale = LocaleTable.new({ locale = "enUS" })

    assert.equal("No experience to track", locale:get(TextKey.BAR_NO_XP))
  end)
end)
