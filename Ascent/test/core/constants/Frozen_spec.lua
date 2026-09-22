describe("Frozen", function()
  local Frozen

  before_each(function()
    Frozen = AscentTest.loadFresh("core/constants/Frozen.lua").core.Frozen
  end)

  describe("reading", function()
    it("returns the value of a key that exists", function()
      local Colours = Frozen.enum("Colours", { RED = "red", BLUE = "blue" })

      assert.equal("red", Colours.RED)
      assert.equal("blue", Colours.BLUE)
    end)

    it("errors on a key that does not exist, naming the key and the table", function()
      local XpSource = Frozen.enum("XpSource", { QUEST_TURNIN = "quest" })

      local ok, err = pcall(function() return XpSource.QEUST end)

      assert.is_false(ok)
      assert.is_truthy(err:find("QEUST", 1, true))
      assert.is_truthy(err:find("XpSource", 1, true))
    end)
  end)

  describe("writing", function()
    it("errors when setting a new key", function()
      local Topics = Frozen.enum("Topics", { A = 1 })

      assert.has_error(function() Topics.B = 2 end)
    end)

    it("errors when overwriting an existing key", function()
      local Topics = Frozen.enum("Topics", { A = 1 })

      assert.has_error(function() Topics.A = 99 end)
      assert.equal(1, Topics.A)
    end)

    it("cannot be unfrozen by replacing the metatable", function()
      local Topics = Frozen.enum("Topics", { A = 1 })

      assert.is_false(getmetatable(Topics))
      assert.has_error(function() setmetatable(Topics, {}) end)
    end)
  end)

  describe("nested values", function()
    it("freezes map-like tables recursively", function()
      local Palette = Frozen.enum("Palette", { MOB = { r = 1, g = 0, b = 0 } })

      assert.equal(1, Palette.MOB.r)
      assert.has_error(function() Palette.MOB.r = 0 end)
      assert.has_error(function() return Palette.MOB.alpha end)
    end)

    -- ipairs and # use raw access in Lua 5.1 and ignore __index, so a proxied
    -- array would iterate as empty. Arrays are copied and left plain on purpose.
    it("keeps array-like tables iterable", function()
      local Defaults = Frozen.enum("Defaults", { ORDER = { "one", "two", "three" } })

      local seen = {}
      for _, item in ipairs(Defaults.ORDER) do
        seen[#seen + 1] = item
      end

      assert.equal(3, #Defaults.ORDER)
      assert.same({ "one", "two", "three" }, seen)
    end)

    it("treats an empty table as an empty list, not as a map", function()
      -- A player who unticks every field leaves an empty list behind. If that
      -- froze into a strict proxy, reading tokens[1] would error in the client.
      local Defaults = Frozen.enum("Defaults", { ORDER = {} })

      assert.equal(0, #Defaults.ORDER)
      assert.is_nil(Defaults.ORDER[1])
    end)

    it("freezes maps that live inside a list", function()
      local Bars = Frozen.enum("Bars", { SEGMENTS = { { key = "mob" }, { key = "quest" } } })

      assert.equal(2, #Bars.SEGMENTS)
      assert.equal("mob", Bars.SEGMENTS[1].key)
      assert.has_error(function() Bars.SEGMENTS[1].key = "changed" end)
      assert.has_error(function() return Bars.SEGMENTS[1].missing end)
    end)

    it("refuses a table that is both a list and a map, instead of picking one", function()
      assert.has_error(function()
        return Frozen.enum("Mixed", { ODD = { "first", named = true } })
      end)
    end)

    -- Documented limit, asserted so it stays deliberate: arrays are handed back by
    -- reference, so a caller that writes into one corrupts the constant.
    it("hands arrays back by reference, so callers must copy before mutating", function()
      local Defaults = Frozen.enum("Defaults", { ORDER = { "one", "two" } })

      Defaults.ORDER[1] = "mutated"

      assert.equal("mutated", Defaults.ORDER[1])
    end)

    it("copies arrays so the caller cannot mutate them through the original", function()
      local source = { "one", "two" }
      local Defaults = Frozen.enum("Defaults", { ORDER = source })

      source[1] = "changed"

      assert.equal("one", Defaults.ORDER[1])
    end)
  end)

  describe("inspection", function()
    it("answers whether a key exists without erroring", function()
      local Topics = Frozen.enum("Topics", { A = 1 })

      assert.is_true(Frozen.has(Topics, "A"))
      assert.is_false(Frozen.has(Topics, "NOPE"))
    end)

    it("lists keys in a deterministic order", function()
      local Topics = Frozen.enum("Topics", { CHARLIE = 3, ALPHA = 1, BRAVO = 2 })

      assert.same({ "ALPHA", "BRAVO", "CHARLIE" }, Frozen.keys(Topics))
    end)

    it("iterates keys and values", function()
      local Topics = Frozen.enum("Topics", { ALPHA = 1, BRAVO = 2 })

      local collected = {}
      for key, value in Frozen.each(Topics) do
        collected[key] = value
      end

      assert.same({ ALPHA = 1, BRAVO = 2 }, collected)
    end)

    it("refuses to inspect something that was never frozen", function()
      assert.has_error(function() return Frozen.keys({ plain = true }) end)
    end)
  end)

  -- A proxy is an empty carrier table with an __index: `#` is zero, `next` is
  -- nil, `ipairs` walks nothing. A list frozen into one does not raise, it reads
  -- as a constant that is inexplicably empty, so lists are left plain.
  describe("a constant declared as a list", function()
    it("can be counted, which a proxy cannot", function()
      local Channels = Frozen.enum("Channels", { "first", "second", "third" })

      assert.equal(3, #Channels)
    end)

    it("can be walked with ipairs, which is how every ordered constant is read", function()
      local Channels = Frozen.enum("Channels", { "first", "second", "third" })

      local seen = {}
      for _, value in ipairs(Channels) do
        seen[#seen + 1] = value
      end

      assert.same({ "first", "second", "third" }, seen)
    end)

    it("keeps its order, which is the only reason it is a list and not a map", function()
      local Channels = Frozen.enum("Channels", { "mob_kill", "quest_turnin", "rested" })

      assert.equal("mob_kill", Channels[1])
      assert.equal("rested", Channels[3])
    end)

    -- A list of tables: the entries themselves still get the frozen treatment, so
    -- a typo inside one is still caught. Only the top-level list is plain.
    it("still freezes the entries inside it", function()
      local Channels = Frozen.enum("Channels", { { id = "rested" }, { id = "pending" } })

      assert.equal("rested", Channels[1].id)
      assert.has_error(function() return Channels[1].di end)
    end)

    -- Says which of the two treatments a value got, since from the outside a
    -- proxy and an empty table are indistinguishable.
    it("is not reported as frozen, while a map is", function()
      assert.is_false(Frozen.isFrozen(Frozen.enum("Channels", { "first", "second" })))
      assert.is_true(Frozen.isFrozen(Frozen.enum("Topics", { ALPHA = 1 })))
      assert.is_false(Frozen.isFrozen({ plain = true }))
      assert.is_false(Frozen.isFrozen("not a table"))
    end)
  end)

  -- The way out of a frozen table for a caller that has to mutate what it read
  -- or store it, such as a reset writing a default back into the saved
  -- variables: a proxy would reach disk as the empty carrier it is.
  describe("copying", function()
    it("comes back walkable with pairs, which a proxy is not", function()
      local Position = Frozen.enum("Position", { point = "CENTER", x = 0 })

      local seen = {}
      for key in pairs(Frozen.plain(Position)) do
        seen[#seen + 1] = key
      end
      table.sort(seen)

      assert.same({ "point", "x" }, seen)
    end)

    it("hands back a copy that can be written into, leaving the original frozen", function()
      local Position = Frozen.enum("Position", { point = "CENTER", x = 0 })

      local copy = Frozen.plain(Position)
      copy.x = 42
      copy.relativePoint = "TOPLEFT"

      assert.equal(42, copy.x)
      assert.equal(0, Position.x)
      assert.is_false(Frozen.has(Position, "relativePoint"))
    end)

    it("copies a nested map rather than handing back the proxy inside it", function()
      local Defaults = Frozen.enum("Defaults", { position = { point = "CENTER", x = 0 } })

      local copy = Frozen.plain(Defaults)
      copy.position.x = 42

      assert.equal(0, Defaults.position.x)
      assert.is_false(Frozen.isFrozen(copy.position))
    end)

    -- The array a frozen table answers with is its backing store, so a copy that
    -- stopped at the top level would leave the caller holding the addon's own
    -- constants.
    it("copies a nested list, which is the backing store itself", function()
      local Defaults = Frozen.enum("Defaults", { zones = { "clock", "footer" } })

      local copy = Frozen.plain(Defaults)
      copy.zones[1] = "changed"

      assert.equal("clock", Defaults.zones[1])
      assert.same({ "clock", "footer" }, Defaults.zones)
    end)

    it("copies a plain table too, so a caller need not ask which one it has", function()
      local stored = { border = { thickness = 3 } }

      local copy = Frozen.plain(stored)
      copy.border.thickness = 6

      assert.equal(3, stored.border.thickness)
    end)

    it("hands back anything that is not a table as it is", function()
      assert.equal(6, Frozen.plain(6))
      assert.equal("tabard", Frozen.plain("tabard"))
      assert.is_false(Frozen.plain(false))
      assert.is_nil(Frozen.plain(nil))
    end)
  end)

  describe("construction", function()
    it("requires a name", function()
      assert.has_error(function() return Frozen.enum("", { A = 1 }) end)
      assert.has_error(function() return Frozen.enum(nil, { A = 1 }) end)
    end)

    it("requires a table of values", function()
      assert.has_error(function() return Frozen.enum("Topics", "nope") end)
    end)
  end)
end)
