-- 13.2: "verificar con un test que ninguna clave usada en el código falta en enUS".
--
-- The gap this closes is specific. Frozen already catches a misspelled TextKey at
-- load: TextKey.TPYO errors. What it cannot catch is a key that exists and simply
-- has no text behind it -- locale:get would then return the no-data marker, and the
-- player would read "n/a" where a label belongs. Nothing fails, nothing logs, and
-- the bug ships. So the check has to be static: read the source, collect every key
-- it mentions, and demand an entry for each.
--
-- Source of truth is the TOC, not a directory walk, for the same reason helper.lua
-- reads it: the TOC is what the client actually loads.

describe("the enUS table", function()
  local ADDON_ROOT = os.getenv("ASCENT_ROOT") or "Ascent"

  local ns, TextKey, enUS

  before_each(function()
    ns = AscentTest.loadWith("core/port/", "locale/")
    TextKey = ns.core.TextKey
    enUS = ns.locale.tables.enUS
  end)

  -- Every TextKey.NAME the shipped source mentions, with the file and line it came
  -- from so a failure names the site rather than just the key.
  local function keyUsesInSource()
    local uses = {}

    for _, path in ipairs(AscentTest.tocPaths("")) do
      local line = 0
      for text in io.lines(ADDON_ROOT .. "/" .. path) do
        line = line + 1
        for name in text:gmatch("TextKey%.([A-Z][A-Z0-9_]*)") do
          uses[#uses + 1] = { name = name, where = ("%s:%d"):format(path, line) }
        end
      end
    end

    return uses
  end

  it("has an entry for every key the source looks up", function()
    local uses = keyUsesInSource()

    -- A guard on the scan itself: if the pattern ever stops matching, the loop below
    -- would pass vacuously and the test would go green having checked nothing.
    assert.is_true(#uses > 50, ("only %d key uses found in the source; the scan is broken"):format(#uses))

    for _, use in ipairs(uses) do
      assert.is_true(ns.core.Frozen.has(TextKey, use.name),
        ("%s uses TextKey.%s, which is not a key of TextKey"):format(use.where, use.name))
      assert.is_truthy(enUS[TextKey[use.name]],
        ("%s uses TextKey.%s, which has no enUS text"):format(use.where, use.name))
    end
  end)

  it("covers every key declared in TextKey, so a key is never declared and left blank", function()
    for _, name in ipairs(ns.core.Frozen.keys(TextKey)) do
      assert.is_truthy(enUS[TextKey[name]], ("TextKey.%s has no enUS text"):format(name))
    end
  end)

  it("holds only non-empty strings", function()
    for _, name in ipairs(ns.core.Frozen.keys(TextKey)) do
      local text = enUS[TextKey[name]]
      assert.is_string(text, ("TextKey.%s is not a string"):format(name))
      assert.is_true(#text > 0, ("TextKey.%s is empty"):format(name))
    end
  end)
end)
