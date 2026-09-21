-- The format the collections that are counted in thousands are written in. Its
-- failure modes are the ones a text format has: a field that shifts position, a
-- separator inside a value, and a record that arrives mangled.

describe("Packed", function()
  local ns, Packed

  before_each(function()
    ns = AscentTest.loadWith("core/model/")
    Packed = ns.core.Packed
  end)

  describe("a record", function()
    it("joins fields and splits them back", function()
      assert.equal("44,mob_kill,1234.5", Packed.join({ 44, "mob_kill", 1234.5 }))
      assert.same({ "44", "mob_kill", "1234.5" }, Packed.split("44,mob_kill,1234.5"))
    end)

    -- Where most of the saving is: a gain carries nine fields and usually fills
    -- three. Only TRAILING empties go, because position is identity.
    it("drops trailing empties and keeps the ones in the middle", function()
      assert.equal("44,mob_kill", Packed.join({ 44, "mob_kill", false, false }))
      assert.equal("44,,1234.5", Packed.join({ 44, false, 1234.5 }))
    end)

    it("gives an empty field back as nothing, not as the next one", function()
      local fields = Packed.split("44,,1234.5")

      assert.equal("44", fields[1])
      assert.is_nil(Packed.number(fields, 2))
      assert.is_nil(Packed.text(fields, 2))
      assert.equal(1234.5, Packed.number(fields, 3))
    end)

    it("leaves a leading empty field in place", function()
      local fields = Packed.split(",,41,1813")

      assert.is_false(fields[1])
      assert.is_false(fields[2])
      assert.equal("41", fields[3])
    end)

    -- An empty field comes back as false rather than nil so that the sequence has no
    -- holes in it. A table with a hole has no defined length in 5.1, and re-joining
    -- one would drop every field after the first gap -- a quest id written in field
    -- nine would simply not come back.
    it("survives being split and joined again", function()
      for _, record in ipairs({
        "250,quest_turnin,20.0,,,,,,1234",
        ",,41,1813,Kobold Miner",
        "44",
        "",
      }) do
        assert.equal(record, Packed.join(Packed.split(record)))
      end
    end)

    it("writes false as empty and true as one", function()
      assert.equal("1234,,,client,1", Packed.join({ 1234, false, false, "client", true }))
      assert.is_true(Packed.flag(Packed.split("1234,,,client,1"), 5))
      assert.is_false(Packed.flag(Packed.split("1234,,,client"), 5))
    end)

    -- The field a reader would have assumed anyway is not worth a byte, and the
    -- values it recognises -- zero and false -- are exactly the ones `and/or` eats.
    it("blanks a field that holds its default", function()
      assert.is_false(Packed.blankIf(0, 0))
      assert.equal(22, Packed.blankIf(22, 0))
      assert.is_false(Packed.blankIf(false, false))
    end)
  end)

  describe("values that contain a separator", function()
    -- A creature called "Grunt, the Loyal" is not something to find out about from a
    -- player's corrupted history.
    it("survives a comma in a name", function()
      local record = Packed.join({ 5644, 6, "Grunt, the Loyal" })

      assert.same({ "5644", "6", "Grunt, the Loyal" }, Packed.split(record))
    end)

    it("survives a semicolon, which separates whole records", function()
      local list = Packed.list({ { name = "a;b" }, { name = "plain" } },
        function(item) return Packed.join({ item.name }) end)
      local read = Packed.unlist(list, function(fields) return fields[1] end)

      assert.same({ "a;b", "plain" }, read)
    end)

    it("survives the escape character itself", function()
      assert.same({ "wave~two,three" }, Packed.split(Packed.join({ "wave~two,three" })))
    end)

    -- Stored data is never worth raising over, and never worth silently rewriting.
    it("leaves an escape it does not recognise as it found it", function()
      assert.equal("~z", Packed.unescape("~z"))
    end)
  end)

  describe("a collection", function()
    local function pack(n) return Packed.join({ n, n * 2 }) end
    local function unpack(fields) return Packed.number(fields, 1) end

    it("writes every record into one string and reads them back in order", function()
      local text = Packed.list({ 1, 2, 3 }, pack)

      assert.equal("1,2;2,4;3,6", text)
      assert.same({ 1, 2, 3 }, Packed.unlist(text, unpack))
    end)

    it("is empty when there is nothing in it", function()
      assert.equal("", Packed.list({}, pack))
      assert.same({}, Packed.unlist("", unpack))
      assert.same({}, Packed.unlist(nil, unpack))
    end)

    -- One mangled record costs that record, not the level it was in.
    it("skips a record it cannot read and keeps the rest", function()
      assert.same({ 1, 3 }, Packed.unlist("1,2;nonsense;3,6", unpack))
    end)
  end)
end)
