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

  -- The plate is the addon's second surface and the first whose settings arrive
  -- into profiles that already exist -- eight keys at once, with no migration and
  -- none needed, because `resolve` walks the defaults. What that leaves to prove
  -- is the SHAPE of each one: a number that clamps instead of falling back, a list
  -- that survives a word from another build, and a map that is NOT completed.
  describe("the pull plate", function()
    it("gives a profile written before it was configurable every default", function()
      local settings = Settings.resolve({ [SettingKey.BAR_WIDTH] = 520 })

      assert.is_false(settings[SettingKey.PLATE_LOCKED])
      assert.equal(1.0, settings[SettingKey.PLATE_SCALE])
      assert.equal(240, settings[SettingKey.PLATE_WIDTH])
      assert.equal(1, settings[SettingKey.PLATE_OPACITY])
      assert.equal(6, settings[SettingKey.PLATE_HOLD_SECONDS])
      assert.equal(4, settings[SettingKey.PLATE_ROWS])
      assert.equal(520, settings[SettingKey.BAR_WIDTH])
    end)

    -- D88. Two keys, so locking the bar leaves the plate loose -- the declared
    -- cost of the change, and this is what keeps it a decision rather than a
    -- coincidence of how the two happen to be named.
    it("does not take its lock from the bar's", function()
      local settings = Settings.resolve({ [SettingKey.BAR_LOCKED] = true })

      assert.is_true(settings[SettingKey.BAR_LOCKED])
      assert.is_false(settings[SettingKey.PLATE_LOCKED])
    end)

    -- Each stored value below is outside its range AND different from its default,
    -- so an edge and a fallback cannot be confused for one another. Somebody who
    -- typed 5000 for a width wanted a very wide plate.
    it("pulls a stored number to the edge of its range rather than to its default", function()
      local settings = Settings.resolve({
        [SettingKey.PLATE_WIDTH] = 5000,
        [SettingKey.PLATE_SCALE] = 0,
        [SettingKey.PLATE_OPACITY] = -1,
        [SettingKey.PLATE_HOLD_SECONDS] = 0,
        [SettingKey.PLATE_ROWS] = 99,
      })

      assert.equal(800, settings[SettingKey.PLATE_WIDTH])
      assert.equal(0.5, settings[SettingKey.PLATE_SCALE])
      assert.equal(0, settings[SettingKey.PLATE_OPACITY])
      assert.equal(1, settings[SettingKey.PLATE_HOLD_SECONDS])
      assert.equal(8, settings[SettingKey.PLATE_ROWS])
    end)

    -- Two ranges, and the panel's is the narrower one on purpose: the setting's
    -- range is the last line before a hand-edited file reaches a frame, the
    -- panel's is what makes sense to drag. The bar has had both halves since its
    -- width admitted 60..1600 while its slider offered 120..900.
    it("offers less in the panel than the setting admits, on every plate slider", function()
      for _, key in ipairs(ns.core.Frozen.keys(ns.core.SettingPanelRange)) do
        local domain = ns.core.SettingRange[key]
        local panel = ns.core.SettingPanelRange[key]

        assert.is_true(domain.min <= panel.min, key .. ": the panel starts below the setting's floor")
        assert.is_true(domain.max >= panel.max, key .. ": the panel reaches past the setting's ceiling")
        assert.is_true(domain.max - domain.min > panel.max - panel.min,
          key .. ": the panel offers the whole range instead of a narrower one")
      end
    end)

    -- D89, stated on its own because it is the one range whose width is not
    -- cosmetic: how long the plate stays is also how long a closed pull can be
    -- resumed, so a hold of minutes would make every fight in a zone one pull.
    it("keeps the longest hold it offers well short of the one it admits", function()
      assert.is_true(ns.core.SettingPanelRange[SettingKey.PLATE_HOLD_SECONDS].max
        < ns.core.SettingRange[SettingKey.PLATE_HOLD_SECONDS].max)
    end)

    it("starts with every zone the plate can draw turned on", function()
      local chosen = {}
      for _, zone in ipairs(Settings.resolve()[SettingKey.PLATE_ZONES]) do
        chosen[zone] = true
      end

      for _, name in ipairs(ns.core.Frozen.keys(ns.core.PlateZone)) do
        assert.is_true(chosen[ns.core.PlateZone[name]] == true, name .. " is off by default")
      end
    end)

    -- A list is several choices in one key, so one word this build does not know
    -- must not cost the player the others -- which is what taking the value whole
    -- would do, the way an unknown bar slot falls back whole.
    it("drops a zone it does not know without losing the ones it does", function()
      local PlateZone = ns.core.PlateZone
      local settings = Settings.resolve({
        [SettingKey.PLATE_ZONES] = { PlateZone.CLOCK, "disco_lights", PlateZone.FOOTER },
      })

      assert.same({ PlateZone.CLOCK, PlateZone.FOOTER }, settings[SettingKey.PLATE_ZONES])
    end)

    it("reports the key whose list it had to prune, so the player can be told", function()
      assert.same({ SettingKey.PLATE_ZONES }, Settings.invalidKeys({
        [SettingKey.PLATE_ZONES] = { ns.core.PlateZone.CLOCK, "disco_lights" },
      }))
    end)

    it("says nothing about a list whose every entry it knows", function()
      assert.same({}, Settings.invalidKeys({ [SettingKey.PLATE_ZONES] = { ns.core.PlateZone.STREAK } }))
    end)

    -- Every accessory zone off is a player who wants the headline and nothing
    -- else (D90), not a corrupt file: it stays empty, stays indexable, and is not
    -- reported as junk.
    it("keeps an empty zone list as the choice it is", function()
      local zones = Settings.resolve({ [SettingKey.PLATE_ZONES] = {} })[SettingKey.PLATE_ZONES]

      assert.equal(0, #zones)
      assert.is_nil(zones[1])
      assert.same({}, Settings.invalidKeys({ [SettingKey.PLATE_ZONES] = {} }))
    end)

    -- `same` alone cannot tell the two shapes apart: a frozen map reads as an
    -- empty table from the outside (Frozen's header), so a map-valued default
    -- would sail straight through it. NOT being frozen is the observable
    -- difference, and it is the very property that keeps this taken or rejected
    -- whole instead of completed key by key.
    it("starts with no appearance of its own, and no shape either", function()
      local stored = Settings.resolve()[SettingKey.PLATE_APPEARANCE]

      assert.same({}, stored)
      assert.is_false(ns.core.Frozen.isFrozen(stored))
    end)

    -- D87, and the trap the design named: a map-valued default would declare a
    -- shape and `resolve` would complete this key by key, nailing the plate to
    -- whichever skin the bar happened to be wearing when the tweak was made. What
    -- is stored is one axis, and one axis is what has to survive a skin change.
    it("keeps a partial plate appearance exactly as stored, without completing it", function()
      local stored = Settings.resolve({
        [SettingKey.PLATE_APPEARANCE] = { border = { thickness = 3 } },
      })[SettingKey.PLATE_APPEARANCE]

      assert.equal(3, stored.border.thickness)
      assert.same({ "border" }, ns.core.Frozen.keys(stored))
    end)

    it("leaves the bar's own appearance empty when the plate is given one", function()
      local settings = Settings.resolve({
        [SettingKey.PLATE_APPEARANCE] = { border = { thickness = 3 } },
      })

      assert.same({}, settings[SettingKey.BAR_APPEARANCE])
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
