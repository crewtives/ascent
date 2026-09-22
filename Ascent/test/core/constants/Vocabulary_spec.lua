-- Every constant set is asserted key by key: adapters, services and views all
-- speak these names, and several are persisted, so a silent rename is a data
-- migration in disguise.

describe("the constant vocabulary", function()
  local ns, Frozen

  before_each(function()
    ns = AscentTest.loadDomain()
    Frozen = ns.core.Frozen
  end)

  local function expectKeys(enum, expected)
    table.sort(expected)
    assert.same(expected, Frozen.keys(enum))
  end

  describe("every set", function()
    local names = {
      "XpSource", "XpModifier", "QuestXpOrigin", "PlaceContext",
      "EventTopic", "WowEvent", "CombatLogSubevent",
      "MetricId", "AbilityKey",
      "TextToken", "Palette", "PlateZone",
      "SettingKey", "ClientFlavor", "SchemaVersion",
    }

    it("is present on the namespace", function()
      for _, name in ipairs(names) do
        assert.is_truthy(ns.core[name], name .. " is missing")
      end
    end)

    it("rejects writes", function()
      for _, name in ipairs(names) do
        assert.has_error(function() ns.core[name].SOMETHING_NEW = true end,
          nil, name .. " accepted a write")
      end
    end)

    it("rejects reads of keys that do not exist", function()
      for _, name in ipairs(names) do
        assert.has_error(function() return ns.core[name].DEFINITELY_NOT_A_KEY end,
          nil, name .. " returned nil instead of erroring")
      end
    end)
  end)

  describe("experience", function()
    it("has exactly the four sources the attribution spec requires", function()
      expectKeys(ns.core.XpSource, { "MOB_KILL", "QUEST_TURNIN", "EXPLORATION", "UNKNOWN" })
    end)

    it("treats unknown as a real source, not an absence", function()
      assert.equal("unknown", ns.core.XpSource.UNKNOWN)
    end)

    it("has the modifiers that ride along with a gain", function()
      expectKeys(ns.core.XpModifier, { "RESTED_BONUS", "GROUP_BONUS", "RAID_PENALTY" })
    end)

    it("distinguishes where a quest forecast came from", function()
      expectKeys(ns.core.QuestXpOrigin, { "CLIENT", "LEARNED", "UNKNOWN" })
    end)

    -- A dimension of its own, never a seventh XpSource. These strings are
    -- persisted inside the key of every place entry.
    it("has the kinds of place a level can be spent in", function()
      expectKeys(ns.core.PlaceContext,
        { "WORLD", "DUNGEON", "RAID", "BATTLEGROUND", "ARENA", "UNKNOWN" })
    end)

    it("treats a place the client could not name as a real kind, not an absence", function()
      assert.equal("unknown", ns.core.PlaceContext.UNKNOWN)
    end)
  end)

  describe("events", function()
    it("separates the amount of a gain from the claim about its source", function()
      assert.not_equal(ns.core.EventTopic.XP_DELTA_OBSERVED, ns.core.EventTopic.XP_HINT_RECEIVED)
      assert.is_truthy(ns.core.EventTopic.XP_ATTRIBUTED)
    end)

    it("covers the level lifecycle", function()
      assert.is_truthy(ns.core.EventTopic.LEVEL_STARTED)
      assert.is_truthy(ns.core.EventTopic.LEVEL_COMPLETED)
      assert.is_truthy(ns.core.EventTopic.RECORD_UPDATED)
    end)

    it("names client events exactly as the client fires them", function()
      assert.equal("PLAYER_XP_UPDATE", ns.core.WowEvent.PLAYER_XP_UPDATE)
      assert.equal("COMBAT_LOG_EVENT_UNFILTERED", ns.core.WowEvent.COMBAT_LOG_EVENT_UNFILTERED)
      assert.equal("CHAT_MSG_SYSTEM", ns.core.WowEvent.CHAT_MSG_SYSTEM)
    end)

    it("listens on both channels that announce experience", function()
      -- Quest xp is echoed on the xp channel and the system channel, and zone
      -- discovery only arrives on the system one. Missing either loses a source.
      assert.is_truthy(ns.core.WowEvent.CHAT_MSG_COMBAT_XP_GAIN)
      assert.is_truthy(ns.core.WowEvent.CHAT_MSG_SYSTEM)
    end)

    it("covers the combat log subevents the metrics need", function()
      for _, key in ipairs({ "SPELL_CAST_SUCCESS", "SWING_DAMAGE", "RANGE_DAMAGE",
                             "SPELL_DAMAGE", "SPELL_HEAL", "UNIT_DIED", "PARTY_KILL" }) do
        assert.is_truthy(Frozen.has(ns.core.CombatLogSubevent, key), key .. " is missing")
      end
    end)

    -- Auto attacks count as used whether or not they land, so both branches need
    -- their miss subevent as well as their damage one.
    it("can count an auto attack that missed, for melee and for ranged alike", function()
      for _, prefix in ipairs({ "SWING", "RANGE" }) do
        assert.is_truthy(Frozen.has(ns.core.CombatLogSubevent, prefix .. "_DAMAGE"))
        assert.is_truthy(Frozen.has(ns.core.CombatLogSubevent, prefix .. "_MISSED"))
      end
    end)
  end)

  describe("metrics", function()
    -- PLACE_TIME is a collector like the rest even though what it accumulates lives
    -- in the level's place entries rather than in `metrics`: the registry is what
    -- gets it the session topics and the dispatch, and the id is what keeps two
    -- collectors from claiming the same slot.
    it("has one id per collector the combat spec requires", function()
      expectKeys(ns.core.MetricId,
        { "ABILITY_USAGE", "COMBAT_OUTCOME", "DEATHS", "TIME", "DAMAGE", "EFFICIENCY", "PLACE_TIME" })
    end)

    it("reserves synthetic keys for attacks that have no spell id", function()
      expectKeys(ns.core.AbilityKey, { "MELEE_SWING", "RANGED_AUTO" })
    end)
  end)

  describe("presentation", function()
    it("offers every field the bar text spec enumerates", function()
      expectKeys(ns.core.TextToken, {
        "LEVEL", "XP_CURRENT", "XP_MAX", "XP_PERCENT", "XP_REMAINING", "RESTED",
        "XP_PER_HOUR", "TIME_TO_LEVEL", "TIME_ON_LEVEL", "SESSION_TIME", "QUEST_PENDING",
      })
    end)

    it("has a colour for every source, plus rested and pending", function()
      for _, source in ipairs(Frozen.keys(ns.core.XpSource)) do
        assert.is_truthy(Frozen.has(ns.core.Palette, source), "no colour for " .. source)
      end
      assert.is_truthy(Frozen.has(ns.core.Palette, "RESTED"))
      assert.is_truthy(Frozen.has(ns.core.Palette, "PENDING"))
    end)

    it("keeps colours immutable", function()
      assert.has_error(function() ns.core.Palette.MOB_KILL.r = 0 end)
    end)

    it("names every zone of the pull plate the player can switch off", function()
      expectKeys(ns.core.PlateZone,
        { "CLOCK", "REMAINING", "STREAK", "SOURCES", "CREATURES", "ABILITIES", "FOOTER" })
    end)

    -- The list is closed: the headline figure and its kill count are why the
    -- plate appears, so there is no word for turning them off and no way for a
    -- hand-edited file to invent one.
    it("has no word for the headline or its count, so neither can be switched off", function()
      for _, name in ipairs({ "HEADLINE", "TITLE", "XP", "KILLS" }) do
        assert.is_false(Frozen.has(ns.core.PlateZone, name),
          name .. " is a zone, so the plate can be left with no figure on it")
      end
    end)
  end)

  describe("runtime", function()
    it("names every setting the tasks configure", function()
      for _, key in ipairs({ "RECOVERY_THRESHOLD", "RETENTION_LIMIT", "BAR_TEXT_TOKENS",
                             "COLLECT_DAMAGE", "SHOW_QUEST_PENDING" }) do
        assert.is_truthy(Frozen.has(ns.core.SettingKey, key), key .. " is missing")
      end
    end)

    it("names the plate's own settings, eight strings AscentDB will carry", function()
      for _, key in ipairs({ "PLATE_LOCKED", "PLATE_SCALE", "PLATE_WIDTH", "PLATE_OPACITY",
                             "PLATE_HOLD_SECONDS", "PLATE_ROWS", "PLATE_ZONES", "PLATE_APPEARANCE" }) do
        assert.is_truthy(Frozen.has(ns.core.SettingKey, key), key .. " is missing")
      end
    end)

    -- Both plate resets use this list, declared in Settings.lua: the button on
    -- its page, and `/ascent options plate reset` for a player who dragged the
    -- plate off the screen. The persisted prefix is the independent oracle that
    -- catches a plate key the list forgot, which neither reset would return.
    it("resets the plate by a list of every plate key and nothing else", function()
      local expected, listed = {}, {}
      for _, persisted in Frozen.each(ns.core.SettingKey) do
        if persisted:find("^plate_") then
          expected[#expected + 1] = persisted
        end
      end
      for _, key in ipairs(ns.core.PlateSettingKeys) do
        listed[#listed + 1] = key
      end
      table.sort(expected)
      table.sort(listed)

      assert.same(expected, listed)
    end)

    -- Every value is a string written into AscentDB: two keys sharing one are two
    -- settings overwriting each other on disk, and renaming a published key
    -- throws away what every player had stored.
    it("gives every setting a persisted string of its own", function()
      local seen = {}
      for name, value in Frozen.each(ns.core.SettingKey) do
        assert.is_nil(seen[value],
          value .. " is stored by both " .. tostring(seen[value]) .. " and " .. name)
        seen[value] = name
      end
    end)

    it("knows every supported client and admits it may know none of them", function()
      expectKeys(ns.core.ClientFlavor, { "CLASSIC_ERA", "BURNING_CRUSADE", "FOREVER", "UNKNOWN" })
    end)

    -- Format 5 adds the sources a level was recorded without, 4 the group a
    -- creature's kills were paid to, 3 `seededXp` and 2 the per-place breakdown.
    -- RecordStore archives any version it has no chain for, so moving this without
    -- adding the step would throw away every existing character's history.
    it("stamps the stored format at the version this build writes", function()
      assert.equal(5, ns.core.SchemaVersion.CURRENT)
    end)
  end)
end)
