-- What the addon costs the player at every logout. Saved variables are serialized
-- whole when the client closes, so the size of this file is a real cost of
-- quitting the game. This derives the budget from the pieces and holds a
-- synthetic full run to it, so a change to the stored format cannot make the file
-- quietly grow.
--
-- The pieces, measured against a writer shaped like the client's own, packed and
-- written a field to a line:
--
--                                     packed    a field to a line
--   an individual gain                  31 B          210 B
--   a (creature, level) aggregate       31 B          159 B
--   an ability                          26 B           90 B
--   a place entry                       42 B            --
--   the scalars of one level record    333 B          374 B
--
-- A run from one to seventy holds tens of thousands of individual gains, about
-- 4.1 MB written a field to a line. Packed, the file keeps every gain of every
-- level: the sequence of a level's gains is its time series.
--
-- A place entry is the dearest record and still cheap, since a run holds tens of
-- them and not tens of thousands: a zone name, which is free text, plus the
-- per-source breakdown behind the crossed reading. Its 42 B is measured
-- marginally (the run built at 0, 1, 4, 8, 16 and 32 entries a level and the
-- difference divided out), not the 33 a count of its characters would suggest.
--
-- The fixture is fuller than a real character: four hundred gains, thirty
-- creature combinations, twelve quests, twenty-five abilities and sixteen place
-- entries on every level, every metric group populated, and a quest reward cache
-- of two hundred entries.
--
--   measured, Classic Era 1-60        ~995 KB
--   measured, Burning Crusade 1-70   ~1159 KB
--
-- The quest name directory is not in those two numbers: it is account-wide, so a
-- second character adds nothing to it, and it is bounded by the quests the client
-- can name rather than by anything the player does. Measured at 44 B a name, 39 KB
-- for the 900 a full run accepts, it has its own budget.
--
-- There is no cap on place entries: the time collector creates one for every
-- distinct place crossed, flight paths included, and the game bounds how much
-- ground a character can cross in one level. At sixteen a level a full run pays
-- about 36 KB for the place split, three per cent of the budget.
--
-- The budget is those numbers with about a quarter of headroom. A very grindy run
-- at eight hundred gains a level comes to about 2 MB, the shape of the worst case
-- rather than the expected one. Exceeding the budget means the format changed, and
-- this number should change with it deliberately.

describe("the saved data budget", function()
  local ERA_LEVELS, ERA_BUDGET = 60, 1200000
  local TBC_LEVELS, TBC_BUDGET = 70, 1400000
  local GAINS_PER_LEVEL = 400
  -- Generous on purpose: an entry per distinct place crossed, not per place that
  -- paid, so a level with a couple of flight paths in it reaches double figures.
  local PLACES_PER_LEVEL = 16
  -- What one entry may cost before the format has changed enough to be a
  -- decision. Measured at 41.6 B at its worst across the sampled counts.
  local PLACE_ENTRY_BUDGET = 48

  local ns, C

  local ZONE_NAMES = {
    "Elwynn Forest", "Westfall", "Redridge Mountains", "Duskwood", "Stranglethorn Vale",
    "Loch Modan", "Wetlands", "Arathi Highlands", "The Hinterlands", "Searing Gorge",
    "Blasted Lands", "Un'Goro Crater", "Winterspring", "Eastern Plaguelands", "Silithus",
    "Burning Steppes", "Felwood", "Azshara", "Tanaris", "Feralas",
  }

  -- The places of one level: a third of them earn the experience and the rest are
  -- crossed for nothing, which is the shape the time collector actually produces.
  local function placesOf(count)
    local keys = {}
    for index = 1, count do
      local name = ZONE_NAMES[((index - 1) % #ZONE_NAMES) + 1]
      if index % 5 == 0 then
        keys[index] = C.PlaceKey.new(C.PlaceContext.DUNGEON, 300 + index, name .. " Depths")
      else
        keys[index] = C.PlaceKey.new(C.PlaceContext.WORLD, 1400 + index, name)
      end
    end
    return keys
  end

  local function levelRecord(number, gains, places)
    local record = ns.core.LevelRecord.new(number, 1700000000 + number * 90000)
    record.xpRequired = 100000000 -- never fills, so the fixture stays one level
    record.playedSeconds, record.sessions, record.lastSeenAt = 5400.25, 4, 12345.5

    places = places or PLACES_PER_LEVEL
    local keys = placesOf(places)
    local paying = math.max(1, math.floor(places / 3))

    for index = 1, gains do
      local fields = { amount = 40 + index % 60, at = 1000 + index * 7.25, source = C.XpSource.MOB_KILL }
      if index % 10 == 0 then
        fields.source = C.XpSource.QUEST_TURNIN
        fields.questId = 3000 + (index % 12)
      else
        fields.creature = C.CreatureKey.new(5000 + (index % 30), 10 + (index % 4), "Riverpaw Mongrel")
        if index % 10 < 4 then
          fields.restedBonus = math.floor(fields.amount / 2)
        end
      end
      C.XpLedger.post(record, C.XpGain.new(fields), nil, keys[(index % paying) + 1])
    end

    -- Every place costs time, including the ones that never paid: that row is the
    -- reason the rates of the others mean anything.
    for index = 1, places do
      record:placeEntry(keys[index]).seconds = 120.5 + index * 37.25
    end

    for index = 1, 25 do
      local usage = C.AbilityUsage.new(11000 + index, "Sinister Strike")
      usage:record(140)
      record.abilities[usage.key] = usage
    end

    -- Ability usage lives in record.abilities (populated above) and efficiency is
    -- derived, never stored. COMBAT_OUTCOME is a real CombatSummary, the one key of
    -- metrics that is a live object on its way in.
    local outcome = C.CombatSummary.new()
    for index = 1, 180 do
      outcome:record(0.3 + (index % 70) / 100, 0.2 + (index % 80) / 100)
    end

    record.metrics = {
      [C.MetricId.DEATHS] = { count = 3, timeLostToDeath = 271.5 },
      [C.MetricId.COMBAT_OUTCOME] = outcome,
      [C.MetricId.TIME] = { combatSeconds = 2400.5, recoverySeconds = 340.0 },
      [C.MetricId.DAMAGE] = { dealt = 184000, taken = 61000, healingReceived = 12400 },
    }

    return record
  end

  -- A whole run as the repository would hold it, with every level keeping everything
  -- it recorded, plus the account's options and the quest reward cache.
  local function wholeRun(levels, places)
    local repository = ns.fakes.InMemoryRepository.new()
    local store = ns.core.RecordStore.new({ repository = repository }):load()

    for number = 1, levels - 1 do
      local closed = levelRecord(number, GAINS_PER_LEVEL, places)
      closed.completedAt = 1700000000 + number * 90000 + 5400
      store:saveCompleted(closed)
    end
    store:saveCurrent(levelRecord(levels, GAINS_PER_LEVEL, places))

    local rewards = {}
    for index = 1, 200 do
      rewards[40000 + index] = C.QuestForecast.new({
        questId = 40000 + index, questLevel = 30, reward = 1050,
        origin = C.QuestXpOrigin.CLIENT, complete = index % 3 == 0,
      }):toStored()
    end
    repository:saveQuestRewards(rewards)
    repository:saveSettings({ bar_scale = 1.0, collect_damage = true })

    return ns.support.SavedVariables.size(repository.data)
  end

  -- Account-wide, and measured on its own for that reason. A levelling character
  -- accepts a few hundred quests; the ceiling is the client's own quest count, not
  -- anything a player can do more of.
  local NAMES_IN_A_RUN, NAME_DIRECTORY_BUDGET = 900, 64000

  local function questNameDirectory(count)
    local repository = ns.fakes.InMemoryRepository.new()
    local names = {}
    for index = 1, count do
      names[8000 + index] = ("The Missing Diplomat, Part %d"):format(index)
    end
    repository:saveQuestNames(names)
    return ns.support.SavedVariables.size(repository:questNames())
  end

  before_each(function()
    ns = AscentTest.loadWith("core/model/", "core/port/",
      "core/service/XpLedger.lua", "core/service/RecordStore.lua",
      "core/service/RetentionPolicy.lua",
      "test/fakes/InMemoryRepository.lua", "test/support/SavedVariables.lua")
    C = ns.core
  end)

  it("keeps the account-wide quest name directory inside its own budget", function()
    local size = questNameDirectory(NAMES_IN_A_RUN)

    assert.is_true(size <= NAME_DIRECTORY_BUDGET,
      ("%d quest names store %d bytes, over the %d byte budget")
        :format(NAMES_IN_A_RUN, size, NAME_DIRECTORY_BUDGET))
  end)

  -- One name is one line of a saved file, so the whole directory is linear in what
  -- the client can name. This is what makes "no retention policy" a measurement
  -- rather than an assumption.
  it("costs a bounded amount per name, so it cannot grow without a known limit", function()
    local perName = (questNameDirectory(900) - questNameDirectory(100)) / 800

    assert.is_true(perName <= 70,
      ("a quest name costs %.1f bytes, more than the 70 this was measured at"):format(perName))
  end)

  it("keeps a whole Classic Era run inside its budget", function()
    local size = wholeRun(ERA_LEVELS)

    assert.is_true(size <= ERA_BUDGET,
      ("a 1-%d run stores %d bytes, over the %d byte budget"):format(ERA_LEVELS, size, ERA_BUDGET))
  end)

  it("keeps a whole Burning Crusade run inside its budget", function()
    local size = wholeRun(TBC_LEVELS)

    assert.is_true(size <= TBC_BUDGET,
      ("a 1-%d run stores %d bytes, over the %d byte budget"):format(TBC_LEVELS, size, TBC_BUDGET))
  end)

  -- The budget is only meaningful if the fixture is near it. A synthetic run coming
  -- in at a tenth of the budget would pass whatever the format did.
  it("is a budget the run actually presses against", function()
    local size = wholeRun(TBC_LEVELS)

    assert.is_true(size >= TBC_BUDGET * 0.5,
      ("the fixture stores only %d bytes against a %d byte budget, so it guards nothing")
        :format(size, TBC_BUDGET))
  end)

  -- This price is what bounds the place split: there is no cap on entries per
  -- level, and even an absurd count fits the budget (the test below builds one).
  -- Measured marginally, building the run twice and dividing the difference, to
  -- charge an entry for the bytes the client's writer spends on it.
  it("costs no more than the declared price per place entry", function()
    local few, many = 4, 32
    local lean = wholeRun(ERA_LEVELS, few)
    local full = wholeRun(ERA_LEVELS, many)

    local perEntry = (full - lean) / ((many - few) * (ERA_LEVELS - 1) + (many - few))

    assert.is_true(perEntry <= PLACE_ENTRY_BUDGET,
      ("a place entry costs %.1f bytes, over the %d byte price this format declares")
        :format(perEntry, PLACE_ENTRY_BUDGET))
  end)

  -- Thirty-two distinct places on every level of a full run, which no character
  -- does: this stands in for the cap that is deliberately not there.
  it("survives a run where every level crossed thirty-two places", function()
    local size = wholeRun(TBC_LEVELS, 32)

    assert.is_true(size <= TBC_BUDGET,
      ("a 1-%d run with 32 places a level stores %d bytes, over the %d byte budget")
        :format(TBC_LEVELS, size, TBC_BUDGET))
  end)

  -- The retention limit bounds growth and is set high enough that a real level
  -- never reaches it: a ceiling, not a routine loss of the time series the panel
  -- is built on.
  it("keeps every gain of a real level, because the limit is above one", function()
    local record = levelRecord(24, GAINS_PER_LEVEL)

    ns.core.RetentionPolicy.new():apply(record)

    assert.equal(GAINS_PER_LEVEL, #record.gains)
    assert.is_true(GAINS_PER_LEVEL < ns.core.Defaults[ns.core.SettingKey.RETENTION_LIMIT])
  end)

  -- What the same data costs written a field to a line, against the packed
  -- encoding.
  it("shows what a field on its own line would have cost", function()
    local record = levelRecord(24, GAINS_PER_LEVEL)
    local packed = ns.support.SavedVariables.size(record:toStored())

    -- The same gains, written the way the client writes a table of tables.
    local unpacked = {}
    for index, gain in ipairs(record.gains) do
      unpacked[index] = {
        amount = gain.amount, source = gain.source, at = gain.at,
        restedBonus = gain.restedBonus, questId = gain.questId,
        creature = gain.creature and { npcId = gain.creature.npcId, level = gain.creature.level,
                                       name = gain.creature.name } or nil,
      }
    end
    local spread = record:toStored()
    spread.gains = unpacked

    assert.is_true(ns.support.SavedVariables.size(spread) > packed * 3,
      ("packing saved only %d of %d bytes on one level")
        :format(ns.support.SavedVariables.size(spread) - packed, ns.support.SavedVariables.size(spread)))
  end)
end)
