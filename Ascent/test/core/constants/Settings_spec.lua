describe("Settings", function()
  local ns, Settings, SettingKey

  -- A stand-in for any domain service: it is handed settings at construction and
  -- keeps no fallbacks of its own. This is the contract every real service follows.
  local function buildService(settings)
    return {
      threshold = function() return settings[SettingKey.RECOVERY_THRESHOLD] end,
      retention = function() return settings[SettingKey.RETENTION_LIMIT] end,
    }
  end

  before_each(function()
    ns = AscentTest.loadDomain()
    Settings = ns.core.Settings
    SettingKey = ns.core.SettingKey
  end)

  describe("resolving", function()
    it("gives a service built without configuration the default values", function()
      local service = buildService(Settings.resolve())

      assert.equal(0.95, service.threshold())
      assert.equal(2000, service.retention())
    end)

    it("lets a caller override a single value without losing the rest", function()
      local settings = Settings.resolve({ [SettingKey.RECOVERY_THRESHOLD] = 0.5 })
      local service = buildService(settings)

      assert.equal(0.5, service.threshold())
      assert.equal(2000, service.retention())
    end)

    it("keeps an override that is false rather than treating it as absent", function()
      local settings = Settings.resolve({ [SettingKey.COLLECT_DAMAGE] = false })

      assert.is_false(settings[SettingKey.COLLECT_DAMAGE])
    end)

    it("covers every known setting, so no service can meet a nil", function()
      local settings = Settings.resolve()

      for _, key in ipairs(ns.core.Frozen.keys(ns.core.Defaults)) do
        assert.is_not_nil(settings[key], key .. " resolved to nil")
      end
    end)

    it("errors when read with a key that is not a setting", function()
      local settings = Settings.resolve()

      assert.has_error(function() return settings.not_a_setting end)
    end)

    it("cannot be written to after resolving", function()
      local settings = Settings.resolve()

      assert.has_error(function() settings[SettingKey.DEBUG] = true end)
    end)
  end)

  describe("stored data that cannot be trusted", function()
    -- Saved variables are a text file the player can edit, and a place two builds
    -- can write to. A service promised a fraction must not be handed a string.
    it("falls back to the default when a stored value has the wrong type", function()
      local settings = Settings.resolve({ [SettingKey.RECOVERY_THRESHOLD] = "ninety five" })

      assert.equal(0.95, settings[SettingKey.RECOVERY_THRESHOLD])
    end)

    it("can report which stored values it had to ignore", function()
      local invalid = Settings.invalidKeys({
        [SettingKey.RECOVERY_THRESHOLD] = "ninety five",
        [SettingKey.DEBUG] = true,
      })

      assert.same({ SettingKey.RECOVERY_THRESHOLD }, invalid)
    end)

    it("reports nothing when every stored value is usable", function()
      assert.same({}, Settings.invalidKeys({ [SettingKey.DEBUG] = true }))
      assert.same({}, Settings.invalidKeys(nil))
    end)

    -- A player who unticks every field leaves an empty list behind.
    it("keeps an empty text composition indexable instead of turning it into an error", function()
      local settings = Settings.resolve({ [SettingKey.BAR_TEXT_TOKENS] = {} })
      local tokens = settings[SettingKey.BAR_TEXT_TOKENS]

      assert.equal(0, #tokens)
      assert.is_nil(tokens[1])
    end)
  end)

  describe("stored data from another version", function()
    -- Saved variables written by a newer build must never stop this one loading.
    it("ignores keys it does not understand", function()
      local settings = Settings.resolve({ from_the_future = "???" })

      assert.equal(0.95, settings[SettingKey.RECOVERY_THRESHOLD])
    end)

    it("can report those keys so the player can be told", function()
      local unknown = Settings.unknownKeys({
        from_the_future = true,
        [SettingKey.DEBUG] = true,
      })

      assert.same({ "from_the_future" }, unknown)
    end)

    it("survives stored keys of mixed types instead of throwing while reporting them", function()
      local unknown = Settings.unknownKeys({ [7] = true, zulu = true })

      assert.same({ "7", "zulu" }, { tostring(unknown[1]), tostring(unknown[2]) })
    end)

    it("reports nothing for a clean set of options", function()
      assert.same({}, Settings.unknownKeys({ [SettingKey.DEBUG] = true }))
      assert.same({}, Settings.unknownKeys(nil))
    end)
  end)

  -- A setting whose default is a map declares the SHAPE that setting must have.
  -- This block is the regression suite for the bug that motivated it: the saved
  -- table reached the views missing a key, the resolved settings are frozen, and
  -- reading a missing key off a frozen table raises rather than returning nil --
  -- so an incomplete position on disk broke the bar at login.
  describe("structured settings", function()
    it("completes a stored position that lost a key", function()
      local settings = Settings.resolve({ [SettingKey.BAR_POSITION] = { x = 5 } })
      local position = settings[SettingKey.BAR_POSITION]

      assert.equal(5, position.x)
      assert.equal("CENTER", position.point)
      assert.equal(200, position.y)
    end)

    it("lets a view read any key of an incomplete stored position without raising", function()
      local settings = Settings.resolve({ [SettingKey.BAR_POSITION] = { x = 5 } })

      assert.has_no.errors(function()
        return settings[SettingKey.BAR_POSITION].point
      end)
    end)

    it("falls back a key whose stored value is of the wrong type", function()
      local settings = Settings.resolve({
        [SettingKey.BAR_POSITION] = { point = 42, x = 5, y = "north" },
      })
      local position = settings[SettingKey.BAR_POSITION]

      assert.equal("CENTER", position.point)
      assert.equal(200, position.y)
      assert.equal(5, position.x)
    end)

    it("drops a key this version does not know instead of carrying it through", function()
      local settings = Settings.resolve({
        [SettingKey.BAR_POSITION] = { point = "TOP", x = 1, y = 2, nonsense = true },
      })

      assert.same({ "point", "x", "y" }, ns.core.Frozen.keys(settings[SettingKey.BAR_POSITION]))
    end)

    it("completes the panel position, size included", function()
      local settings = Settings.resolve({ [SettingKey.PANEL_POSITION] = { point = "TOPLEFT" } })
      local position = settings[SettingKey.PANEL_POSITION]

      assert.equal("TOPLEFT", position.point)
      assert.equal(420, position.width)
      assert.equal(360, position.height)
    end)

    it("hands back the whole default shape when nothing is stored at all", function()
      local position = Settings.resolve()[SettingKey.BAR_POSITION]

      assert.same({ "point", "x", "y" }, ns.core.Frozen.keys(position))
      assert.equal("CENTER", position.point)
    end)

    it("still takes a list-valued setting whole rather than key by key", function()
      local tokens = { ns.core.TextToken.LEVEL }
      local settings = Settings.resolve({ [SettingKey.BAR_TEXT_TOKENS] = tokens })

      assert.same(tokens, settings[SettingKey.BAR_TEXT_TOKENS])
    end)
  end)

  describe("ranges", function()
    it("pulls a number below its floor up to the floor rather than to its default", function()
      local settings = Settings.resolve({ [SettingKey.BAR_WIDTH] = 0 })

      assert.equal(60, settings[SettingKey.BAR_WIDTH])
    end)

    it("pulls a number above its ceiling down to the ceiling", function()
      local settings = Settings.resolve({
        [SettingKey.BAR_WIDTH] = 5000,
        [SettingKey.BAR_SCALE] = 10,
      })

      assert.equal(1600, settings[SettingKey.BAR_WIDTH])
      assert.equal(2.0, settings[SettingKey.BAR_SCALE])
    end)

    it("keeps a number that is already inside its range", function()
      assert.equal(640, Settings.resolve({ [SettingKey.BAR_WIDTH] = 640 })[SettingKey.BAR_WIDTH])
    end)

    it("clamps the motion scale to the range where zero really means no motion", function()
      assert.equal(0, Settings.resolve({ [SettingKey.MOTION_SCALE] = -3 })[SettingKey.MOTION_SCALE])
      assert.equal(1, Settings.resolve({ [SettingKey.MOTION_SCALE] = 4 })[SettingKey.MOTION_SCALE])
    end)

    it("leaves a setting with no declared range alone", function()
      assert.equal(99999, Settings.resolve({ [SettingKey.RETENTION_LIMIT] = 99999 })[SettingKey.RETENTION_LIMIT])
    end)
  end)

  describe("appearance settings", function()
    it("defaults to a bar wide and tall enough for four segments and a line of text", function()
      local settings = Settings.resolve()

      assert.equal(400, settings[SettingKey.BAR_WIDTH])
      assert.equal(24, settings[SettingKey.BAR_HEIGHT])
    end)

    it("defaults to a skin that the catalogue actually has", function()
      local full = AscentTest.loadDomain("core/registry/SkinCatalog.lua")
      local chosen = Settings.resolve()[SettingKey.BAR_SKIN]

      assert.is_true(full.core.Frozen.has(full.core.SkinCatalog, chosen))
    end)

    it("keeps a partial appearance override exactly as stored, without completing it", function()
      local settings = Settings.resolve({
        [SettingKey.BAR_APPEARANCE] = { border = { thickness = 4 } },
      })
      local stored = settings[SettingKey.BAR_APPEARANCE]

      -- Partial on purpose: the player changed one thing, and that one thing is
      -- what has to survive switching to another skin. Completing it here would
      -- freeze the whole of the skin they happened to be using at the time.
      assert.equal(4, stored.border.thickness)
      assert.same({ "border" }, ns.core.Frozen.keys(stored))
    end)

    it("starts with no appearance overrides at all", function()
      assert.same({}, Settings.resolve()[SettingKey.BAR_APPEARANCE])
    end)
  end)

  describe("defaults", function()
    it("composes the bar text from real tokens", function()
      local valid = {}
      for _, value in ns.core.Frozen.each(ns.core.TextToken) do
        valid[value] = true
      end

      local tokens = ns.core.Defaults[SettingKey.BAR_TEXT_TOKENS]

      assert.is_true(#tokens > 0)
      for _, token in ipairs(tokens) do
        assert.is_true(valid[token] == true, token .. " is not a text token")
      end
    end)

    it("defaults the retention limit high enough that a real level never reaches it", function()
      assert.equal(2000, ns.core.Defaults[SettingKey.RETENTION_LIMIT])
    end)
  end)
  -- The bar's slot is the first setting whose value is a closed vocabulary rather
  -- than a number or a flag, and the first where a stored string of the right type
  -- can still be meaningless.
  describe("the bar slot", function()
    it("resolves to off for an install that has never had the setting", function()
      local settings = Settings.resolve({})

      assert.equal(ns.core.BarSlot.OFF, settings[SettingKey.BAR_SLOT])
    end)

    it("keeps a value the vocabulary declares", function()
      local settings = Settings.resolve({ [SettingKey.BAR_SLOT] = ns.core.BarSlot.INSET })

      assert.equal(ns.core.BarSlot.INSET, settings[SettingKey.BAR_SLOT])
    end)

    it("falls back to the default for a string outside the vocabulary", function()
      local settings = Settings.resolve({ [SettingKey.BAR_SLOT] = "sideways" })

      assert.equal(ns.core.BarSlot.OFF, settings[SettingKey.BAR_SLOT])
    end)

    it("reports a value outside the vocabulary as invalid, so it can be told", function()
      assert.same({ SettingKey.BAR_SLOT }, Settings.invalidKeys({ [SettingKey.BAR_SLOT] = "sideways" }))
    end)

    -- The migration the addon actually has: a profile written before the key
    -- existed is completed key by key, so it receives the new default and nothing
    -- it had configured moves.
    it("gives a profile saved before the key existed the default without touching the rest", function()
      local stored = {
        [SettingKey.BAR_WIDTH] = 520,
        [SettingKey.BAR_SKIN] = "glass",
        [SettingKey.BAR_POSITION] = { point = "TOP", x = 10, y = -40 },
      }

      local settings = Settings.resolve(stored)

      assert.equal(ns.core.BarSlot.OFF, settings[SettingKey.BAR_SLOT])
      assert.equal(520, settings[SettingKey.BAR_WIDTH])
      assert.equal("glass", settings[SettingKey.BAR_SKIN])
      assert.equal("TOP", settings[SettingKey.BAR_POSITION].point)
      assert.equal(10, settings[SettingKey.BAR_POSITION].x)
    end)
  end)

  -- The update check arrives into profiles that were written before it existed,
  -- which is every profile there is. Both of its keys have to survive that.
  describe("the update check", function()
    it("is on for a profile saved before it existed, without disturbing it", function()
      local settings = Settings.resolve({ [SettingKey.BAR_WIDTH] = 520 })

      assert.is_true(settings[SettingKey.UPDATE_CHECK])
      assert.equal(520, settings[SettingKey.BAR_WIDTH])
    end)

    it("remembers no version until one is written, and does not call that junk", function()
      local settings = Settings.resolve({})

      -- Empty, not nil: a key with no default is dropped by resolve and then
      -- reported as an unknown stored key, which is how a real setting would end
      -- up being described to the player as rubbish in their saved variables.
      assert.equal("", settings[SettingKey.LAST_SEEN_VERSION])
      assert.same({}, Settings.unknownKeys({ [SettingKey.LAST_SEEN_VERSION] = "0.1.0" }))
    end)

    it("keeps a remembered version and an explicit off", function()
      local settings = Settings.resolve({
        [SettingKey.UPDATE_CHECK] = false,
        [SettingKey.LAST_SEEN_VERSION] = "0.1.0",
      })

      assert.is_false(settings[SettingKey.UPDATE_CHECK])
      assert.equal("0.1.0", settings[SettingKey.LAST_SEEN_VERSION])
    end)
  end)
end)
