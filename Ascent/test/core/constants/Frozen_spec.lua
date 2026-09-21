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

  -- The regression that took the whole addon down. A list handed to Frozen.enum
  -- came back as a proxy, and a proxy is an empty carrier table with an __index:
  -- `#` is zero, `next` is nil, `ipairs` walks nothing. The data was all there,
  -- behind an interface raw access cannot see -- so the failure did not look like
  -- an error, it looked like a constant that was inexplicably empty, four hundred
  -- lines away from where the UI gave up and took the slash commands with it.
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
