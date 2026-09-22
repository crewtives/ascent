-- Three branches and no fourth: a client without the regime reads everything, a
-- readable value comes back as itself, and one this addon may not read comes back
-- as nil, which is the only shape core/ has to understand.

describe("Readable", function()
  local function load()
    return AscentTest.loadDomain("adapter/compat/Readable.lua").adapter.Readable
  end

  describe("on a client without the secret-value regime", function()
    it("hands back every value, because nothing there can be secret", function()
      local Readable = load()

      assert.equal(42, Readable.value(42))
      assert.equal("Boar", Readable.value("Boar"))
      assert.is_true(Readable.value(true))
      assert.is_nil(Readable.value(nil))
      assert.is_false(Readable.isSupported())
    end)
  end)

  describe("on a client that has it", function()
    it("hands back a value it is allowed to read", function()
      AscentTest.withSecretRegime(function()
        local Readable = load()

        assert.equal(42, Readable.value(42))
        assert.equal("Boar", Readable.value("Boar"))
        assert.is_true(Readable.value(true))
        assert.is_true(Readable.isSupported())
      end)
    end)

    it("turns a value it may not read into nil", function()
      AscentTest.withSecretRegime(function()
        local Readable = load()

        assert.is_nil(Readable.value(AscentTest.secret("Creature-0-1-1-1-1234-A")))
      end)
    end)

    -- The guard is what keeps the caller from ever touching the value, so it must
    -- not touch it either: `issecretvalue` answers without operating on it.
    it("never operates on the value it is asked about", function()
      AscentTest.withSecretRegime(function()
        local Readable = load()
        local secret = AscentTest.secret(1)

        assert.has_no.errors(function() Readable.value(secret) end)
      end)
    end)

    -- Secret and unreadable are not the same thing: a client may hand back a
    -- value that is marked and still allow this addon to read it.
    it("hands back a secret value this addon is allowed to access", function()
      local savedIs, savedCan = _G.issecretvalue, _G.canaccessvalue
      _G.issecretvalue = function() return true end
      _G.canaccessvalue = function() return true end

      local Readable = load()
      assert.equal(7, Readable.value(7))

      _G.issecretvalue, _G.canaccessvalue = savedIs, savedCan
    end)
  end)
end)
