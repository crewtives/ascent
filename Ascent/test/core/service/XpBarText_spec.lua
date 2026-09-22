-- Every token has two faces: the value it prints when there is one, and the
-- not-available marker when there is not. Neither may be confused with a real
-- zero, so zero has its own cases.

describe("XpBarText", function()
  local ns, XpBarText, TextToken, TextKey, locale

  -- A stub, not the real tables: the cases are about which key each token reads
  -- and when. The texts are copied from locale/enUS.lua so assertions read as the
  -- player sees them, and a key missing here fails outright instead of falling
  -- back, so a forgotten literal cannot pass unnoticed.
  local function stubLocale(texts)
    texts = texts or {
      [TextKey.NOT_AVAILABLE]   = "n/a",
      [TextKey.PERCENT]         = "%d%%",
      [TextKey.DURATION_HM]     = "%dh %dm",
      [TextKey.DURATION_M]      = "%dm",
      [TextKey.DURATION_S]      = "%ds",
      [TextKey.TOKEN_SEPARATOR] = " ",
    }

    return {
      get = function(_, key, ...)
        local text = texts[key]
        if text == nil then
          error("the stub locale has no text for " .. tostring(key), 2)
        end
        if select("#", ...) > 0 then
          return text:format(...)
        end
        return text
      end,
      has = function(_, key)
        return texts[key] ~= nil
      end,
    }
  end

  before_each(function()
    ns = AscentTest.loadWith("core/service/XpBarText.lua")
    XpBarText = ns.core.XpBarText
    TextToken = ns.core.TextToken
    TextKey = ns.core.TextKey
    locale = stubLocale()
  end)

  local function formatOne(token, values)
    return XpBarText.format({ token }, values, locale)
  end

  describe("a value for every token", function()
    it("formats LEVEL", function()
      assert.equal("24", formatOne(TextToken.LEVEL, { level = 24 }))
    end)

    it("formats XP_CURRENT", function()
      assert.equal("350", formatOne(TextToken.XP_CURRENT, { xpCurrent = 350 }))
    end)

    it("formats XP_MAX", function()
      assert.equal("2100", formatOne(TextToken.XP_MAX, { xpMax = 2100 }))
    end)

    it("formats XP_PERCENT as a rounded whole-number percentage", function()
      assert.equal("42%", formatOne(TextToken.XP_PERCENT, { xpPercent = 0.4166 }))
    end)

    it("formats XP_REMAINING", function()
      assert.equal("150", formatOne(TextToken.XP_REMAINING, { xpRemaining = 150 }))
    end)

    it("formats RESTED", function()
      assert.equal("80", formatOne(TextToken.RESTED, { restedXp = 80 }))
    end)

    it("formats XP_PER_HOUR rounded to a whole number", function()
      assert.equal("1234", formatOne(TextToken.XP_PER_HOUR, { xpPerHour = 1234.49 }))
    end)

    it("formats TIME_TO_LEVEL as a duration", function()
      assert.equal("1h 5m", formatOne(TextToken.TIME_TO_LEVEL, { timeToLevel = 3900 }))
    end)

    it("formats TIME_ON_LEVEL as a duration", function()
      assert.equal("42m", formatOne(TextToken.TIME_ON_LEVEL, { timeOnLevel = 2530 }))
    end)

    it("formats SESSION_TIME as a duration", function()
      assert.equal("45s", formatOne(TextToken.SESSION_TIME, { sessionTime = 45 }))
    end)

    it("formats QUEST_PENDING", function()
      assert.equal("300", formatOne(TextToken.QUEST_PENDING, { questPending = 300 }))
    end)
  end)

  describe("no data available for every token", function()
    it("marks LEVEL unavailable", function()
      assert.equal("n/a", formatOne(TextToken.LEVEL, {}))
    end)

    it("marks XP_CURRENT unavailable", function()
      assert.equal("n/a", formatOne(TextToken.XP_CURRENT, {}))
    end)

    it("marks XP_MAX unavailable", function()
      assert.equal("n/a", formatOne(TextToken.XP_MAX, {}))
    end)

    it("marks XP_PERCENT unavailable", function()
      assert.equal("n/a", formatOne(TextToken.XP_PERCENT, {}))
    end)

    it("marks XP_REMAINING unavailable", function()
      assert.equal("n/a", formatOne(TextToken.XP_REMAINING, {}))
    end)

    it("marks RESTED unavailable", function()
      assert.equal("n/a", formatOne(TextToken.RESTED, {}))
    end)

    it("marks XP_PER_HOUR unavailable", function()
      assert.equal("n/a", formatOne(TextToken.XP_PER_HOUR, {}))
    end)

    it("marks TIME_TO_LEVEL unavailable, such as with no known pace", function()
      assert.equal("n/a", formatOne(TextToken.TIME_TO_LEVEL, {}))
    end)

    it("marks TIME_ON_LEVEL unavailable", function()
      assert.equal("n/a", formatOne(TextToken.TIME_ON_LEVEL, {}))
    end)

    it("marks SESSION_TIME unavailable", function()
      assert.equal("n/a", formatOne(TextToken.SESSION_TIME, {}))
    end)

    it("marks QUEST_PENDING unavailable", function()
      assert.equal("n/a", formatOne(TextToken.QUEST_PENDING, {}))
    end)
  end)

  describe("zero is a real answer, not a missing one", function()
    it("shows a rested reserve of exactly zero as \"0\", not the placeholder", function()
      assert.equal("0", formatOne(TextToken.RESTED, { restedXp = 0 }))
    end)

    it("shows zero experience remaining as \"0\", not the placeholder", function()
      assert.equal("0", formatOne(TextToken.XP_REMAINING, { xpRemaining = 0 }))
    end)
  end)

  it("composes several tokens in the order given, separated by a single space", function()
    local text = XpBarText.format(
      { TextToken.LEVEL, TextToken.XP_PERCENT, TextToken.RESTED },
      { level = 24, xpPercent = 0.5, restedXp = nil },
      locale
    )

    assert.equal("24 50% n/a", text)
  end)

  describe("duration thresholds", function()
    it("prints seconds below a minute", function()
      assert.equal("59s", formatOne(TextToken.SESSION_TIME, { sessionTime = 59 }))
    end)

    it("prints minutes from a minute up to an hour", function()
      assert.equal("59m", formatOne(TextToken.SESSION_TIME, { sessionTime = 3599 }))
    end)

    it("prints hours and minutes from an hour up", function()
      assert.equal("2h 0m", formatOne(TextToken.SESSION_TIME, { sessionTime = 7200 }))
    end)
  end)

  describe("the text comes from the locale", function()
    it("reads the marker, the shapes and the separator from it, not from literals", function()
      local translated = stubLocale({
        [TextKey.NOT_AVAILABLE]   = "sin datos",
        [TextKey.PERCENT]         = "%d por ciento",
        [TextKey.DURATION_HM]     = "%d h %d min",
        [TextKey.DURATION_M]      = "%d min",
        [TextKey.DURATION_S]      = "%d seg",
        [TextKey.TOKEN_SEPARATOR] = " | ",
      })

      local text = XpBarText.format(
        { TextToken.XP_PERCENT, TextToken.TIME_TO_LEVEL, TextToken.SESSION_TIME, TextToken.RESTED },
        { xpPercent = 0.5, timeToLevel = 3900, sessionTime = 45 },
        translated
      )

      assert.equal("50 por ciento | 1 h 5 min | 45 seg | sin datos", text)
    end)

    -- The stub above proves the module asks the locale; only the shipped tables
    -- prove the keys it asks for are ones a translator will actually find there.
    it("asks for keys the shipped tables have", function()
      local shipped = AscentTest.loadWith("core/port/", "core/service/XpBarText.lua", "locale/")
      local Token = shipped.core.TextToken
      local enUS = shipped.locale.LocaleTable.new({ locale = "enUS" })

      local text = shipped.core.XpBarText.format(
        { Token.LEVEL, Token.XP_PERCENT, Token.TIME_TO_LEVEL, Token.TIME_ON_LEVEL,
          Token.SESSION_TIME, Token.RESTED },
        { level = 24, xpPercent = 0.5, timeToLevel = 3900, timeOnLevel = 2530, sessionTime = 45 },
        enUS
      )

      assert.equal("24 50% 1h 5m 42m 45s n/a", text)
    end)
  end)
end)
