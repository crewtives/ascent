-- Fixtures modelled on the shape D5 describes for COMBATLOG_XPGAIN_FIRSTPERSON --
-- name, total, parenthetical amount, state word -- across four locales, two of
-- which (ruRU, koKR) reorder the specifiers the way D5 says those two do. The
-- wording is illustrative, not verified client text: only the specifier shapes
-- and the non-ASCII bytes matter here.
local FIXTURES = {
  {
    locale = "enUS",
    template = "%s dies, you gain %d experience. (%d %s)",
    line = "Boar dies, you gain 12 experience. (4 rested bonus)",
    expected = { [1] = "Boar", [2] = "12", [3] = "4", [4] = "rested bonus" },
  },
  {
    locale = "deDE",
    template = "%s stirbt, du erhaltst %d Erfahrung. (%d %s)",
    line = "Wildschwein stirbt, du erhaltst 12 Erfahrung. (4 Erholungsbonus)",
    expected = { [1] = "Wildschwein", [2] = "12", [3] = "4", [4] = "Erholungsbonus" },
  },
  {
    -- reorders the parenthetical: the state word comes before the amount.
    locale = "ruRU",
    template = "%1$s умирает, вы получаете %2$d опыта. (%4$s %3$d)",
    line = "Кабан умирает, вы получаете 12 опыта. (отдых 4)",
    expected = { [1] = "Кабан", [2] = "12", [3] = "4", [4] = "отдых" },
  },
  {
    -- reorders further: the total leads the sentence, ahead of the name.
    locale = "koKR",
    template = "%2$d의 경험치 획득 (%1$s, %4$s %3$d)",
    line = "12의 경험치 획득 (멧돼지, 휴식 4)",
    expected = { [1] = "멧돼지", [2] = "12", [3] = "4", [4] = "휴식" },
  },
}

describe("GlobalStringPattern", function()
  local ns, GlobalStringPattern

  before_each(function()
    ns = AscentTest.loadDomain("adapter/inbound/GlobalStringPattern.lua")
    GlobalStringPattern = ns.adapter.GlobalStringPattern
  end)

  -- Reconstructs fields by ORIGINAL placeholder number rather than by capture
  -- position, which is the whole point: a locale that reorders the specifiers
  -- also reorders where each field lands in the captures a match returns.
  local function captureFields(template, line)
    local pattern, order = GlobalStringPattern.compile(template)
    local results = { line:match(pattern) }
    local byPlaceholder = {}
    for i, placeholder in ipairs(order) do
      byPlaceholder[placeholder] = results[i]
    end
    return byPlaceholder
  end

  describe("escaping", function()
    it("escapes every Lua pattern magic character in literal text", function()
      local literal = "a.b(c)d+e-f*g?h[i]j^k$l%m"

      local pattern = GlobalStringPattern.compile(literal)

      assert.equal(literal, literal:match(pattern))
    end)
  end)

  describe("specifiers", function()
    it("captures %s as text and %d as digits", function()
      local pattern, order = GlobalStringPattern.compile("%s: %d")

      assert.same({ 1, 2 }, order)
      assert.same({ "Zone", "40" }, { ("Zone: 40"):match(pattern) })
    end)

    it("assigns implicit sequential placeholders when specifiers are unnumbered", function()
      local _, order = GlobalStringPattern.compile("%s %s %d")

      assert.same({ 1, 2, 3 }, order)
    end)
  end)

  describe("across locales, including two that reorder the specifiers", function()
    for _, fixture in ipairs(FIXTURES) do
      it("reads every field by its original position (" .. fixture.locale .. ")", function()
        assert.same(fixture.expected, captureFields(fixture.template, fixture.line))
      end)
    end

    it("is actually exercising reordering, not coincidentally passing in order", function()
      local _, ruOrder = GlobalStringPattern.compile(FIXTURES[3].template)
      local _, koOrder = GlobalStringPattern.compile(FIXTURES[4].template)

      assert.is_not.same({ 1, 2, 3, 4 }, ruOrder)
      assert.is_not.same({ 1, 2, 3, 4 }, koOrder)
    end)
  end)

  describe("the explicit source list", function()
    it("does not include the third-person global, which would match another player's gain", function()
      for _, source in ipairs(GlobalStringPattern.SOURCES) do
        assert.is_not.equal("COMBATLOG_XPGAIN", source.global)
      end
    end)

    it("lists exactly the globals D5 names, once each", function()
      local expected = {
        "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED",
        "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP", "COMBATLOG_XPGAIN_FIRSTPERSON_RAID",
        "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP", "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID",
        "COMBATLOG_XPGAIN_QUEST", "COMBATLOG_XPGAIN_EXHAUSTION1", "COMBATLOG_XPGAIN_EXHAUSTION2",
        "COMBATLOG_XPGAIN_EXHAUSTION4", "COMBATLOG_XPGAIN_EXHAUSTION5",
        -- The eight rested-AND-grouped templates, which nobody had counted: the
        -- normal case of levelling rested with a friend.
        "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION1_RAID",
        "COMBATLOG_XPGAIN_EXHAUSTION2_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION2_RAID",
        "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION4_RAID",
        "COMBATLOG_XPGAIN_EXHAUSTION5_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION5_RAID",
        "ERR_ZONE_EXPLORED_XP", "ERR_QUEST_REWARD_EXP_I",
      }

      local actual, seen = {}, {}
      for _, source in ipairs(GlobalStringPattern.SOURCES) do
        assert.is_nil(seen[source.global], source.global .. " is listed twice")
        seen[source.global] = true
        actual[#actual + 1] = source.global
      end
      table.sort(actual)
      table.sort(expected)
      assert.same(expected, actual)
    end)
  end)
end)

-- The experience family, with the client's real templates. These are not
-- illustrative like the fixtures above: they are the verbatim values read from
-- the client's own string table for the two builds this addon targets, and the
-- whole point of this block is that the family is matched by SPECIFICITY.
--
-- The plain kill template is a strict prefix of every other one in the family,
-- so an unanchored match in declaration order silently swallows the modifier and
-- records a group kill as an ordinary one. That is not hypothetical: it is what
-- the addon did until this suite existed.

describe("the experience template family", function()
  local ns, GlobalStringPattern

  before_each(function()
    ns = AscentTest.loadWith("adapter/inbound/GlobalStringPattern.lua")
    GlobalStringPattern = ns.adapter.GlobalStringPattern
  end)

  -- Verbatim from the client's string table, enUS, identical on both targets.
  local EN = {
    COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience.",
    COMBATLOG_XPGAIN_FIRSTPERSON_GROUP = "%s dies, you gain %d experience. (+%d group bonus)",
    COMBATLOG_XPGAIN_FIRSTPERSON_RAID = "%s dies, you gain %d experience. (-%d raid penalty)",
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = "You gain %d experience.",
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP = "You gain %d experience. (+%d group bonus)",
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID = "You gain %d experience. (-%d raid penalty)",
    COMBATLOG_XPGAIN_QUEST = "You gain %d experience. (%s exp %s bonus)",
    COMBATLOG_XPGAIN_EXHAUSTION1 = "%s dies, you gain %d experience. (%s exp %s bonus)",
    COMBATLOG_XPGAIN_EXHAUSTION2 = "%s dies, you gain %d experience. (%s exp %s bonus)",
    COMBATLOG_XPGAIN_EXHAUSTION4 = "%s dies, you gain %d experience. (%s exp %s penalty)",
    COMBATLOG_XPGAIN_EXHAUSTION5 = "%s dies, you gain %d experience. (%s exp %s penalty)",
    COMBATLOG_XPGAIN_EXHAUSTION1_GROUP =
      "%s dies, you gain %d experience. (%s exp %s bonus, +%d group bonus)",
    COMBATLOG_XPGAIN_EXHAUSTION1_RAID =
      "%s dies, you gain %d experience. (%s exp %s bonus, -%d raid penalty)",
    COMBATLOG_XPGAIN_EXHAUSTION2_GROUP =
      "%s dies, you gain %d experience. (%s exp %s bonus, +%d group bonus)",
    COMBATLOG_XPGAIN_EXHAUSTION2_RAID =
      "%s dies, you gain %d experience. (%s exp %s bonus, -%d raid penalty)",
    COMBATLOG_XPGAIN_EXHAUSTION4_GROUP =
      "%s dies, you gain %d experience. (%s exp %s penalty, +%d group bonus)",
    COMBATLOG_XPGAIN_EXHAUSTION4_RAID =
      "%s dies, you gain %d experience. (%s exp %s penalty, -%d raid penalty)",
    COMBATLOG_XPGAIN_EXHAUSTION5_GROUP =
      "%s dies, you gain %d experience. (%s exp %s penalty, +%d group bonus)",
    COMBATLOG_XPGAIN_EXHAUSTION5_RAID =
      "%s dies, you gain %d experience. (%s exp %s penalty, -%d raid penalty)",
  }

  -- esES on the 2.5.6 client. Kept because the Spanish templates DIFFER between
  -- the two supported clients while the English ones do not -- which is the
  -- proof that no translated literal may ever be written into this addon.
  local ES = {
    COMBATLOG_XPGAIN_FIRSTPERSON = "%s muere, obtienes %d p. de experiencia.",
    COMBATLOG_XPGAIN_FIRSTPERSON_GROUP = "%s muere, obtienes %d p. de experiencia. (+%d bonus de grupo)",
    COMBATLOG_XPGAIN_FIRSTPERSON_RAID =
      "%s muere, obtienes %d p. de experiencia. (-%d penalizacion por banda)",
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = "Obtienes %d p. de experiencia.",
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP = "Obtienes %d p. de experiencia. (+%d bonus por grupo)",
    COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID =
      "Obtienes %d p. de experiencia. (-%d de penalizacion por banda)",
  }

  local function lookup(table)
    return function(name) return table[name] end
  end

  -- Fills a template's specifiers in order of appearance, which is what the
  -- client does when it renders one.
  local function render(template, values)
    local index = 0
    return (template:gsub("%%[sd]", function()
      index = index + 1
      return tostring(values[index])
    end))
  end

  describe("compiling", function()
    it("compiles every template the client has", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))

      assert.is_true(#family > 0)
      for _, entry in ipairs(family) do
        assert.is_string(entry.pattern)
        assert.is_number(entry.amount)
      end
    end)

    it("anchors every pattern, which is what makes the longer ones reachable", function()
      for _, entry in ipairs(GlobalStringPattern.compileXpFamily(lookup(EN))) do
        assert.equal("^", entry.pattern:sub(1, 1))
        assert.equal("$", entry.pattern:sub(-1))
      end
    end)

    it("drops a template whose text another one already produced", function()
      -- EXHAUSTION1 and EXHAUSTION2 are byte identical, as are 4 and 5: the
      -- rested states they name cannot be told apart from the message, which is
      -- why that state is read from the client API instead.
      local names = {}
      for _, entry in ipairs(GlobalStringPattern.compileXpFamily(lookup(EN))) do
        names[entry.name] = true
      end

      assert.is_true(names.EXHAUSTION1)
      assert.is_nil(names.EXHAUSTION2)
      assert.is_true(names.EXHAUSTION4)
      assert.is_nil(names.EXHAUSTION5)
    end)

    it("skips a template this client does not have, without failing", function()
      local partial = { COMBATLOG_XPGAIN_FIRSTPERSON = EN.COMBATLOG_XPGAIN_FIRSTPERSON }
      local family = GlobalStringPattern.compileXpFamily(lookup(partial))

      assert.equal(1, #family)
      assert.equal("FIRSTPERSON", family[1].name)
    end)
  end)

  describe("the collision matrix", function()
    local CASES = {
      { template = "COMBATLOG_XPGAIN_FIRSTPERSON", values = { "Boar", 120 },
        expect = "FIRSTPERSON", creature = "Boar", amount = 120 },
      { template = "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP", values = { "Boar", 120, 18 },
        expect = "FIRSTPERSON_GROUP", creature = "Boar", amount = 120,
        modifier = "group", modifierAmount = 18 },
      { template = "COMBATLOG_XPGAIN_FIRSTPERSON_RAID", values = { "Boar", 120, 42 },
        expect = "FIRSTPERSON_RAID", creature = "Boar", amount = 120,
        modifier = "raid", modifierAmount = 42 },
      { template = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED", values = { 450 },
        expect = "UNNAMED", amount = 450 },
      { template = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP", values = { 450, 30 },
        expect = "UNNAMED_GROUP", amount = 450, modifier = "group", modifierAmount = 30 },
      { template = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID", values = { 450, 55 },
        expect = "UNNAMED_RAID", amount = 450, modifier = "raid", modifierAmount = 55 },
      { template = "COMBATLOG_XPGAIN_QUEST", values = { 450, "+10%", "rested" },
        expect = "QUEST", amount = 450 },
      { template = "COMBATLOG_XPGAIN_EXHAUSTION1", values = { "Boar", 120, "+10%", "rested" },
        expect = "EXHAUSTION1", creature = "Boar", amount = 120 },
      { template = "COMBATLOG_XPGAIN_EXHAUSTION4", values = { "Boar", 120, "-10%", "fatigue" },
        expect = "EXHAUSTION4", creature = "Boar", amount = 120 },
      { template = "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP",
        values = { "Boar", 120, "+10%", "rested", 18 },
        expect = "EXHAUSTION1_GROUP", creature = "Boar", amount = 120,
        modifier = "group", modifierAmount = 18 },
      -- The dangerous one. Without specificity ordering this also matches the
      -- FATIGUE template, and a raid penalty would be recorded as a fatigue
      -- penalty -- a different thing entirely, and wrong in a way nothing fails.
      { template = "COMBATLOG_XPGAIN_EXHAUSTION1_RAID",
        values = { "Boar", 120, "+10%", "rested", 42 },
        expect = "EXHAUSTION1_RAID", creature = "Boar", amount = 120,
        modifier = "raid", modifierAmount = 42 },
      { template = "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP",
        values = { "Boar", 120, "-10%", "fatigue", 18 },
        expect = "EXHAUSTION4_GROUP", creature = "Boar", amount = 120,
        modifier = "group", modifierAmount = 18 },
    }

    it("matches every rendered line with its own template and no other", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))

      for _, case in ipairs(CASES) do
        local line = render(EN[case.template], case.values)
        local matched = GlobalStringPattern.matchXp(family, line)

        assert.is_not_nil(matched, "no template matched: " .. line)
        assert.equal(case.expect, matched.template, "wrong template for: " .. line)
        assert.equal(case.amount, matched.amount, "wrong amount for: " .. line)
        if case.creature ~= nil then
          assert.equal(case.creature, matched.creature, "wrong creature for: " .. line)
        end
        assert.equal(case.modifier, matched.modifier, "wrong modifier for: " .. line)
        assert.equal(case.modifierAmount, matched.modifierAmount, "wrong magnitude for: " .. line)
      end
    end)

    it("never reads a modifier off a line that has none", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))
      local matched = GlobalStringPattern.matchXp(family, render(EN.COMBATLOG_XPGAIN_FIRSTPERSON, { "Boar", 120 }))

      assert.is_nil(matched.modifier)
      assert.is_nil(matched.modifierAmount)
    end)

    -- The parenthetical of a rested kill, which is the ONLY reading of the bonus
    -- anchored to the kill that announced it. The reserve diff is not: the client
    -- prints the line before it applies the gain, so a reserve sampled here belongs
    -- to the previous kill. These figures are transcribed from a real session.
    it("reads the rested magnitude off the parenthetical", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))
      local matched = GlobalStringPattern.matchXp(family,
        render(EN.COMBATLOG_XPGAIN_EXHAUSTION1, { "Scarlet Sentry", 294, "+147", "Rested" }))

      assert.equal("EXHAUSTION1", matched.template)
      assert.equal(294, matched.amount)
      assert.equal(147, matched.restedAmount)
    end)

    it("reads the rested magnitude and the group bonus off the same line", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))
      local matched = GlobalStringPattern.matchXp(family,
        render(EN.COMBATLOG_XPGAIN_EXHAUSTION1_GROUP, { "Scarlet Scout", 78, "+39", "Rested", 9 }))

      assert.equal("EXHAUSTION1_GROUP", matched.template)
      assert.equal(78, matched.amount)
      assert.equal(39, matched.restedAmount)
      assert.equal(9, matched.modifierAmount)
    end)

    -- A deduction wearing the same shape. Reading it as a rested bonus would credit
    -- the reserve for experience the player was docked.
    it("reads no rested magnitude off a fatigue line", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))
      local matched = GlobalStringPattern.matchXp(family,
        render(EN.COMBATLOG_XPGAIN_EXHAUSTION4, { "Boar", 120, "-10", "fatigue" }))

      assert.equal("EXHAUSTION4", matched.template)
      assert.is_nil(matched.restedAmount)
    end)

    -- Degrading to nil is the point: the domain falls back to the reserve rather
    -- than recording "10" as ten points of experience.
    it("reads no rested magnitude when the parenthetical is not a figure", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))
      local matched = GlobalStringPattern.matchXp(family,
        render(EN.COMBATLOG_XPGAIN_EXHAUSTION1, { "Boar", 120, "+10%", "rested" }))

      assert.equal(120, matched.amount)
      assert.is_nil(matched.restedAmount)
    end)

    it("captures the magnitude without its sign, whichever the template", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))
      local group = GlobalStringPattern.matchXp(family,
        render(EN.COMBATLOG_XPGAIN_FIRSTPERSON_GROUP, { "Boar", 120, 18 }))
      local raid = GlobalStringPattern.matchXp(family,
        render(EN.COMBATLOG_XPGAIN_FIRSTPERSON_RAID, { "Boar", 120, 42 }))

      -- The sign is literal text in the template; which template matched is what
      -- says whether the magnitude was added or taken away.
      assert.equal(18, group.modifierAmount)
      assert.equal(42, raid.modifierAmount)
    end)

    it("matches nothing for a line that is not experience at all", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(EN))

      assert.is_nil(GlobalStringPattern.matchXp(family, "Boar dies."))
      assert.is_nil(GlobalStringPattern.matchXp(family, "You have slain Boar."))
      assert.is_nil(GlobalStringPattern.matchXp(family, nil))
    end)

    it("works the same in Spanish, where the templates are not the English ones", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(ES))

      local group = GlobalStringPattern.matchXp(family,
        render(ES.COMBATLOG_XPGAIN_FIRSTPERSON_GROUP, { "Jabali", 120, 18 }))
      assert.equal("FIRSTPERSON_GROUP", group.template)
      assert.equal("group", group.modifier)
      assert.equal(18, group.modifierAmount)

      local plain = GlobalStringPattern.matchXp(family,
        render(ES.COMBATLOG_XPGAIN_FIRSTPERSON, { "Jabali", 120 }))
      assert.equal("FIRSTPERSON", plain.template)
      assert.is_nil(plain.modifier)
    end)

    it("tells the anonymous raid line from the plain anonymous one", function()
      local family = GlobalStringPattern.compileXpFamily(lookup(ES))
      local matched = GlobalStringPattern.matchXp(family,
        render(ES.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID, { 450, 55 }))

      assert.equal("UNNAMED_RAID", matched.template)
      assert.equal(450, matched.amount)
      assert.equal(55, matched.modifierAmount)
    end)
  end)
end)
