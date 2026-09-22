-- Ascent - the composition root (12.1-12.6).
--
-- Every other file in this addon defines something and waits to be asked for it.
-- This is the one file that actually asks: it is the only place that sees core/,
-- adapter/ and ui/ all at once, and the only place a port's real implementation
-- ever meets the port itself.
--
-- WHY IT WAITS FOR ADDON_LOADED. SavedVariables are not populated until the client
-- fires ADDON_LOADED for this addon's own name -- reading them any earlier would
-- read nothing, silently, and every character would look freshly installed. A frame
-- exists for exactly this one event, checks the name, and un-registers itself: the
-- rest of this file runs exactly once per session, after the moment its data
-- actually exists.
--
-- WHY THE ORDER BELOW IS NOT INCIDENTAL. Later constructors close over earlier ones
-- (the bus's error handler needs the logger, the bar's saveSetting needs the bar
-- itself), so building out of order is not a style problem, it is a nil reference.
-- The order here is the one dependency graph these modules actually have.
--
-- WHY ALMOST NOTHING HERE IS WRAPPED IN pcall. Every constructor below already
-- fails loudly on its own -- Port.verify and the explicit option checks throw
-- with the module's name in the message. Swallowing that here would hide exactly
-- the failure a composition root exists to surface.
--
-- THE ONE EXCEPTION IS THE VIEW LAYER, and it was earned the hard way. "Fails
-- loudly" is only true when the client is showing Lua errors, and it is NOT by
-- default: with scriptErrors off, a throw while building a frame is completely
-- silent. Because the views are built here and the slash commands are registered
-- three hundred lines below them, one bad CreateFrame turned into an addon that
-- collected data perfectly and answered nothing at all -- no bar, no panel, and
-- no way to ask it why.
--
-- So the views go through pcall, and the error is REPORTED rather than
-- swallowed: it goes to the chat frame through the logger, where it is visible
-- whether or not the client would have shown it. Everything downstream then
-- guards against a missing view instead of assuming one. That is the
-- capability's own "fault isolation" requirement applied to the layer that
-- actually needed it: the addon keeps recording, keeps answering commands, and
-- says what broke.

local ADDON_NAME, ns = ...

local SavedVariablesRepository = ns.adapter.SavedVariablesRepository
local WowClock = ns.adapter.WowClock
local WowPlayerState = ns.adapter.WowPlayerState
local ChatLogger = ns.adapter.ChatLogger
local WowEventRouter = ns.adapter.WowEventRouter
local GlobalStringPattern = ns.adapter.GlobalStringPattern
local CombatLogRouter = ns.adapter.CombatLogRouter
local TimePlayedSync = ns.adapter.TimePlayedSync
local Compat = ns.adapter.Compat
local Capabilities = ns.adapter.Capabilities
local QuestLogReader = ns.adapter.QuestLogReader
local ClientXpBar = ns.adapter.ClientXpBar

local RecordStore = ns.core.RecordStore
local Settings = ns.core.Settings
local SettingKey = ns.core.SettingKey
local EventTopic = ns.core.EventTopic
local EventBus = ns.core.EventBus
local ClassifierRegistry = ns.core.ClassifierRegistry
local XpClassifiers = ns.core.XpClassifiers
local KillCorrelator = ns.core.KillCorrelator
local XpAttribution = ns.core.XpAttribution
local LevelTracker = ns.core.LevelTracker
local SessionXpTracker = ns.core.SessionXpTracker
local ProgressEstimator = ns.core.ProgressEstimator
local QuestForecastService = ns.core.QuestForecastService
local QuestNames = ns.core.QuestNames
local RetentionPolicy = ns.core.RetentionPolicy
local BarSlotPolicy = ns.core.BarSlotPolicy
local RedrawScheduler = ns.core.RedrawScheduler
local MetricRegistry = ns.core.MetricRegistry
local AbilityUsageCollector = ns.core.AbilityUsageCollector
local CombatOutcomeCollector = ns.core.CombatOutcomeCollector
local DeathCollector = ns.core.DeathCollector
local CombatTimeCollector = ns.core.CombatTimeCollector
local PlaceTimeCollector = ns.core.PlaceTimeCollector
local PlaceKey = ns.core.PlaceKey
local DamageCollector = ns.core.DamageCollector
local CombatAggregator = ns.core.CombatAggregator
local PullTracker = ns.core.PullTracker
local PullRecord = ns.core.PullRecord
local PullPhase = ns.core.PullPhase
local XpSource = ns.core.XpSource
local Frozen = ns.core.Frozen
local WowEvent = ns.core.WowEvent
local TextKey = ns.core.TextKey

local XpBarView = ns.ui.XpBarView
local DemoDriver = ns.app.DemoDriver
local EvidenceLog = ns.app.EvidenceLog
local PullPlateView = ns.ui.PullPlateView
local ReportPanelView = ns.ui.ReportPanelView
local OptionsPanel = ns.ui.OptionsPanel
local CopyDialog = ns.ui.CopyDialog
local CopyReport = ns.core.CopyReport
-- The update check is reached through `ns` at the point of use rather than
-- through file-local aliases like the lines above. Lua 5.1 allows a function 60
-- upvalues and buildContext, which is this whole file, spends all 60: the budget
-- this note once advertised is gone, and ONE more alias used in there is a SYNTAX
-- error at load time, in the client, with nothing to read.
--
-- Re-measured 2026-09-22 (it had drifted -- this said 57): every file-local above
-- is an upvalue of buildContext, so there is no dead alias to reclaim, and a copy
-- with one more fails to compile with "has more than 60 upvalues". Worse, luajit
-- blames the line of buildContext's `end`, not the alias that overflowed it.
-- `ns` is already one of the 60, so `ns.core.X` at the point of use is free.
-- Method and figures: openspec/changes/add-ascent-plate-customisation/design.md.

local LocaleTable = ns.locale.LocaleTable

ns.app = ns.app or {}

-- Text keys for the /ascent summary breakdown (12.2). app/ keeps its own tiny table
-- instead of reaching into ui/ for XpBarView's SOURCE_LABEL: this only ever needs
-- a name to print next to a number, never the color that table also carries, and
-- app/ has no reason to depend on ui/ for that. Both tables now name the same four
-- keys, so the two surfaces cannot drift apart in wording the way two literal
-- tables could.
local SOURCE_NAME = {
  [XpSource.MOB_KILL] = TextKey.SOURCE_CREATURES,
  [XpSource.QUEST_TURNIN] = TextKey.SOURCE_QUESTS,
  [XpSource.EXPLORATION] = TextKey.SOURCE_EXPLORATION,
  [XpSource.UNKNOWN] = TextKey.SOURCE_UNCLASSIFIED,
}

-- Splits a slash command's message into its first token and everything after it,
-- both trimmed. Used for `/ascent <command> <rest>` and, inside opciones' own
-- handler, for `<sub> <arg>` -- the same shape one level deeper.
local function splitFirst(text)
  local head, tail = (text or ""):match("^%s*(%S*)%s*(.-)%s*$")
  return head or "", tail or ""
end

-- 12.7's registration, against whichever options system this build actually has.
-- Classic Era and BC Classic turn out to run the same Settings.* canvas system
-- retail has used since Dragonflight on at least some recent builds -- replacing
-- InterfaceOptionsFrame rather than sitting next to it, so a panel registered only
-- the legacy way never appears under Interface > AddOns at all. This tries the
-- modern path first and only falls back to the legacy one when Settings itself is
-- not there, rather than assuming either.
--
-- Explicitly `_G.Settings` throughout, never the bare name: this file already has
-- a local `Settings` bound to ns.core.Settings (the options-resolving module,
-- line ~39), and that local shadows the client global of the same name for the
-- rest of the file. Writing the bare name here would silently probe the wrong
-- table -- ns.core.Settings has no RegisterCanvasLayoutCategory, so it would
-- always look absent and this would always fall back to the legacy path,
-- regardless of what the client actually has.
-- Registers the addon's pages: the first is the category in the AddOns list and
-- the rest are its children, the shape every other addon in that list uses.
local function registerOptionsPanel(pages)
  local parentPage = pages[1]
  local wowSettings = _G.Settings
  if wowSettings ~= nil and wowSettings.RegisterCanvasLayoutCategory ~= nil
    and wowSettings.RegisterAddOnCategory ~= nil then
    local category = wowSettings.RegisterCanvasLayoutCategory(parentPage.frame, parentPage.frame.name)
    wowSettings.RegisterAddOnCategory(category)
    -- Subcategories when the client has them. Without that function the children
    -- simply do not appear -- one page of settings rather than six -- which is a
    -- worse panel and not a broken addon.
    if wowSettings.RegisterCanvasLayoutSubcategory ~= nil then
      for index = 2, #pages do
        wowSettings.RegisterCanvasLayoutSubcategory(category, pages[index].frame, pages[index].frame.name)
      end
    end
    return category
  end
  -- Verified absent from Burning Crusade Classic 2.5.6: this whole branch is the
  -- fallback for a client that has neither system, and calling a global that is
  -- not there would fail here, during initialisation, where it costs the most.
  if type(_G.InterfaceOptions_AddCategory) == "function" then
    _G.InterfaceOptions_AddCategory(parentPage.frame)
    -- The old system nests by name: a panel whose `parent` is another panel's
    -- name becomes its child in the list. Same six entries, different mechanism.
    for index = 2, #pages do
      pages[index].frame.parent = parentPage.frame.name
      _G.InterfaceOptions_AddCategory(pages[index].frame)
    end
  end
  return nil
end

local function openOptionsPanel(panel, category)
  local wowSettings = _G.Settings
  if category ~= nil and wowSettings ~= nil and wowSettings.OpenToCategory ~= nil then
    wowSettings.OpenToCategory(category:GetID())
    return
  end
  -- Blizzard's classic Interface Options frame has a long-known bug where the
  -- category is not reliably selected the first time it is opened in a session;
  -- calling this twice in a row is the standard addon-ecosystem workaround, not
  -- something to question. Only reached when the modern path above is absent.
  if type(_G.InterfaceOptionsFrame_OpenToCategory) == "function" then
    _G.InterfaceOptionsFrame_OpenToCategory(panel)
    _G.InterfaceOptionsFrame_OpenToCategory(panel)
  end
end

local function buildContext()
  -- ---------------------------------------------------------------------------
  -- 12.1: construction, in dependency order.
  -- ---------------------------------------------------------------------------

  local repository = SavedVariablesRepository.new()
  local store = RecordStore.new({ repository = repository }):load()
  local settings = Settings.resolve(repository:settings())

  local clock = WowClock.new()
  local playerState = WowPlayerState.new()

  local logger = ChatLogger.new({ debug = settings[SettingKey.DEBUG] })

  -- The client's language cannot change mid-session, so LocaleTable resolves it once
  -- from GetLocale. Diagnostic mode can change, which is why it arrives as a function
  -- and not as the boolean read a line above: a key with no text must start showing
  -- itself the moment the player turns debug on, not after the next reload.
  local locale = LocaleTable.new({ isDebug = function() return logger:isDebug() end })

  -- The bus already isolates a failing handler from the rest (core/service/EventBus.lua):
  -- this onError is only the notice to the player that it happened. logger:warn
  -- dedupes by exact text, so one handler stuck failing on every event does not
  -- spam the chat frame once per occurrence.
  local bus = EventBus.new(function(topic, err)
    logger:warn(locale:get(TextKey.CMD_HANDLER_FAILED, tostring(topic), tostring(err)))
  end)

  local registry = ClassifierRegistry.new()
  XpClassifiers.registerAll(registry)

  local correlator = KillCorrelator.new({ logger = logger })

  -- XpAttribution subscribes itself to the bus in its own constructor; nothing
  -- here calls it again. Kept anyway so the context below can expose it.
  local xpAttribution = XpAttribution.new({ bus = bus, registry = registry, correlator = correlator, logger = logger })

  local tracker = LevelTracker.new({
    bus = bus, clock = clock, playerState = playerState, store = store, settings = settings, logger = logger,
  })

  -- Group 7: experience gained since the client itself started (D14's definition
  -- of "session"), which no LevelRecord can answer on its own because it spans
  -- whatever levels the player crosses in one sitting.
  local sessionXpTracker = SessionXpTracker.new({ bus = bus })

  -- Group 6 (D10, D23): registering a collector never touches the tracker. None of
  -- the six needs flavor-gating -- ability usage, combat outcome, deaths, time and
  -- damage all read the same client-side API on Era and TBC -- so every one of them
  -- registers unconditionally, and Capabilities still has nothing to probe for
  -- these (see the comment on `capabilities` below, which is a separate concern).
  --
  -- `recordingLevel` (not tracker:current() directly): current() can be non-nil
  -- while tracker:isRecording() is false -- experience gain switched off mid-
  -- session leaves the record open but frozen (LevelTracker's own onAttributed
  -- already gates on isRecording()) -- and without the same gate here, combat
  -- metrics would keep accruing onto a level whose playedSeconds/xpTotal have
  -- stopped moving, breaking the very "combat + out-of-combat = played" invariant
  -- 6.5 exists to keep. Both CombatAggregator's dispatch and observe()'s own
  -- per-tick sampling read this, so neither path can drift from the other.
  local function recordingLevel()
    if tracker:isRecording() then
      return tracker:current()
    end
    return nil
  end

  local metricRegistry = MetricRegistry.new()
  local combatOutcomeCollector = CombatOutcomeCollector.new({ playerState = playerState })
  local deathCollector = DeathCollector.new({ clock = clock })
  local combatTimeCollector = CombatTimeCollector.new({
    clock = clock, recoveryThreshold = settings[SettingKey.RECOVERY_THRESHOLD],
  })
  local placeTimeCollector = PlaceTimeCollector.new({ clock = clock })
  -- The `enabled` closure reads `settings` live (the same upvalue saveSetting
  -- reassigns below), so toggling "collect damage data" in the options panel
  -- takes effect immediately -- no rebuild of the collector or the registry.
  local damageCollector = DamageCollector.new({ enabled = function() return settings[SettingKey.COLLECT_DAMAGE] end })
  for _, collector in ipairs({
    AbilityUsageCollector.new(), combatOutcomeCollector, deathCollector, combatTimeCollector, damageCollector,
    placeTimeCollector,
  }) do
    metricRegistry:register({ id = collector.id, topics = collector.topics, collect = function(record, payload, topic)
      return collector:collect(record, payload, topic)
    end })
  end
  CombatAggregator.new({ bus = bus, registry = metricRegistry, currentRecord = recordingLevel, logger = logger })

  -- Kept rather than discarded now that it counts template hits: that counter is
  -- what a real levelling session uses to settle whether the group figure is
  -- already inside the total (design D45), and the diagnostic command reads it.
  local eventRouter = WowEventRouter.new({
    bus = bus, clock = clock, playerState = playerState, logger = logger,
  })
  eventRouter:start()

  -- The flight recorder (app/EvidenceLog.lua). Subscribed BEFORE anything else
  -- starts publishing, so a session records from its first event rather than
  -- from whenever the rest of the wiring happened to finish.
  --
  -- The environment goes in with it: which client, which language, and which of
  -- the experience templates this client actually carries. Samples without that
  -- cannot be interpreted by anyone who was not sitting at the machine.
  local evidence = EvidenceLog.new({
    bus = bus, clock = clock, playerState = playerState,
    enabled = settings[SettingKey.EVIDENCE],
  })
  -- Gathered in one place because two paths need exactly the same environment:
  -- the one at startup, and the one the chat command takes when recording is
  -- switched on mid-session.
  -- THE ADDON'S VERSION, READ ONCE, IN ONE PLACE.
  --
  -- Read through whichever accessor this client has. Three things now depend on
  -- it -- the evidence file, the report header, and the update check -- and a
  -- second declaration anywhere would be a build that reports one version and
  -- compares another (spec addon-lifecycle, "Identidad del addon"). "unknown"
  -- rather than nil: it is printed, and it must never read as a blank.
  local addonVersion = (C_AddOns ~= nil and C_AddOns.GetAddOnMetadata ~= nil
    and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
    or (GetAddOnMetadata ~= nil and GetAddOnMetadata(ADDON_NAME, "Version"))
    or "unknown"

  local function evidenceEnvironment()
    local templates = {}
    for _, entry in ipairs(eventRouter.patterns.xpFamily) do
      templates[#templates + 1] = entry.name
    end
    return {
      locale = GetLocale(),
      flavor = Compat.flavor(),
      maxLevel = Compat.maxLevel(),
      addonVersion = addonVersion,
      xpTemplates = templates,
    }
  end

  if evidence:isEnabled() then
    AscentCharDB = AscentCharDB or {}
    evidence:start():attachTo(AscentCharDB, evidenceEnvironment())
  end

  -- One door into the recorder for the facts the bus does not carry. The spikes of
  -- group 0 are answered from a session that may run for hours, and their
  -- instrumentation used to write through the logger -- into a 500-line chat ring
  -- shared with roughly three lines per kill, which is overwritten long before the
  -- session ends. Everything that has to survive the session goes to the file.
  local function recordEvidence(kind, fields)
    evidence:record(kind, fields)
  end

  CombatLogRouter.new({ bus = bus, clock = clock, playerState = playerState, logger = logger,
    recordEvidence = recordEvidence }):start()
  TimePlayedSync.new({
    bus = bus, clock = clock, logger = logger,
    recordEvidence = recordEvidence,
    -- Spike 0.6 asks whether the server sends time played unprompted, which cannot
    -- be asked while the addon requests it on entering the world. Read here and not
    -- later because the request fires during the loading screen.
    requests = settings[SettingKey.TIME_SYNC],
  }):start()

  local scheduler = RedrawScheduler.new({ clock = clock })

  local questLogReader = QuestLogReader.new()

  -- The client's own experience bar, as a place to stand and as something to
  -- quiet. Declared before the registry because register() runs its probe there
  -- and then, so a probe that closes over this must have something to close over.
  local clientXpBar = ClientXpBar.new()

  -- One probe per client function this addon actually forks on. Until these
  -- existed the registry held nothing, so `capabilities:missing()` was
  -- structurally empty -- and an empty registry and a healthy one printed the
  -- same sentence, which is why nobody noticed for the whole of this change.
  --
  -- `_G.Settings` is spelled out on purpose: this file binds a local `Settings`
  -- for the addon's own settings module, and it shadows the client global
  -- everywhere below.
  local capabilities = Capabilities.new()
  capabilities:register("creature_level", function() return UnitTokenFromGUID ~= nil end)
  capabilities:register("map_position", function()
    return C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil
  end)
  capabilities:register("quest_reward_on_turn_in", function() return GetQuestLogRewardXP ~= nil end)
  -- Absent when another addon has replaced the main bar, and on any client whose
  -- bar is not where this one looks. The slot setting then stays on disk and
  -- simply does not take effect (D49).
  capabilities:register("client_xp_bar", function() return clientXpBar:present() end)
  -- Whether the options panel can offer a list rather than a button that cycles.
  -- Probed here, next to the others, so the answer reaches the diagnostic even on
  -- a session where the views failed to build.
  capabilities:register("dropdown_menu", function()
    return UIDropDownMenu_Initialize ~= nil and UIDropDownMenu_CreateInfo ~= nil
      and UIDropDownMenu_AddButton ~= nil and UIDropDownMenu_SetWidth ~= nil
      and UIDropDownMenu_SetText ~= nil
  end)
  capabilities:register("settings_canvas", function()
    return _G.Settings ~= nil and _G.Settings.RegisterCanvasLayoutCategory ~= nil
  end)
  -- The addon channel. Absent, the addon loses exactly one thing -- hearing that
  -- somebody nearby runs a newer build -- and keeps the changelog, the upgrade
  -- notice and everything else. Named here so the diagnostic can say it was off.
  capabilities:register("addon_messages", function() return ns.adapter.VersionChannel.isSupported() end)
  -- Absent when the player has nameplates switched off, and then a pull is built
  -- from the combat log alone -- which sees every creature that has touched you and
  -- none of the ones still running at you.
  capabilities:register("nameplates", function() return ns.adapter.NameplateWatch.isSupported() end)

  -- THE VERSION CHECK. An addon cannot ask a server anything, so the only source
  -- for "is there something newer" is the people already around the player. Three
  -- pieces, and only the last one touches the client (design D64): what is newer
  -- and who said so, how often this addon is allowed to speak, and the channel.
  local updateWatch = ns.core.UpdateWatch.new({
    version = addonVersion,
    enabled = settings[SettingKey.UPDATE_CHECK],
  })
  ns.adapter.VersionChannel.new({
    watch = updateWatch,
    budget = ns.core.SendBudget.new({ clock = clock }),
    -- The wording belongs here, where the locale is, and the threshold belongs to
    -- the domain: by the time this runs, three distinct players have said it.
    onNewer = function(version)
      logger:info(locale:get(TextKey.UPDATE_AVAILABLE, version, tostring(addonVersion)))
    end,
  }):start()

  -- Every quest the addon can name, in one place for every surface that shows
  -- one. It is fed HERE, from both of the places a client ever says a name --
  -- the log sweep just below and the quest dialogue further down -- rather than
  -- by the services those two feed, so that neither of them has to carry a
  -- string it does not use to a screen it does not know about.
  local questNames = QuestNames.new({ repository = repository })

  -- The only way this addon reads the quest log, so that a title cannot be read
  -- and thrown away by one caller while another keeps it. The sweep reads a title
  -- for every accepted quest and the forecast service has no use for one; this is
  -- where it stops being discarded. It is also what makes naming retroactive: a
  -- quest is named when it is ACCEPTED, so by the time it is handed in -- and for
  -- every level report written afterwards -- the directory already knows it.
  local function sweepQuestLog(sweepLogger, recorder)
    local forecasts = questLogReader:scan(sweepLogger, recorder)
    local learned = 0
    for _, forecast in ipairs(forecasts) do
      if questNames:remember(forecast.questId, forecast.title) then
        learned = learned + 1
      end
    end
    -- Only when it learned something: the sweep runs on every quest-log event, so
    -- a line per sweep would be a line per quest accepted, abandoned or advanced.
    if learned > 0 and logger ~= nil then
      logger:debug(("sweep named %d new quest(s); %d known"):format(learned, questNames:count()))
    end
    return forecasts
  end

  -- Group 8: experience pending from the quest log. `scan` is a plain
  -- function rather than handing the reader itself to the service, the same
  -- reason LevelTracker takes `xpForLevel` as a function (core/ must never
  -- hold a reference typed by adapter/).
  local questForecastService = QuestForecastService.new({
    playerState = playerState, repository = repository,
    scan = function() return sweepQuestLog() end,
    logger = logger,
  })
  bus:subscribe(EventTopic.QUEST_LOG_CHANGED, function() questForecastService:markDirty() end)
  -- Only when the turn-in actually paid something: WowEventRouter already
  -- guards `xpReward` the same way for its own hint, so a nil here means the
  -- client sent something this addon does not trust either.
  bus:subscribe(EventTopic.QUEST_COMPLETED, function(payload)
    if payload.xpReward ~= nil then
      -- The record, not just the side effect: task 8.7 wants twenty of these from
      -- a real session, compared against what the panel was showing at the time.
      recordEvidence("questCalibration", questForecastService:calibrate(payload.questId, payload.xpReward))
    end
  end)
  -- 8.4b: the quest-dialogue reward (D15's "level 2"), learned before the
  -- quest is ever turned in.
  bus:subscribe(EventTopic.QUEST_REWARD_SEEN, function(payload)
    questForecastService:learn(payload.questId, payload.reward)
    -- The dialogue's own title, which is the only way to name a quest that was
    -- accepted and handed in without a sweep in between.
    questNames:remember(payload.questId, payload.title)
  end)

  -- Forward-declared alongside `bar`: redraw() has to be able to ask whether the
  -- demo is running, and the demo cannot exist until the bar it drives does.
  local demo

  -- Forward-declared: saveSetting closes over it, but it is only assigned once the
  -- bar itself is constructed, a few lines below.
  -- optionsPanel is declared up here with the other two views and not where it is
  -- built, because saveSetting closes over it and is written long before it.
  -- optionsCategory rides along for the same reason: the report panel's shortcut
  -- into the settings closes over both, and that panel is built long before the
  -- options register themselves.
  local bar, panel, optionsPanel, optionsCategory, plate

  -- The pull plate's own recorder. Built here rather than inside the views'
  -- pcall on purpose: it is pure domain and cannot fail on a client quirk, and a
  -- session whose frames failed to build should still be RECORDING pulls -- the
  -- same principle that keeps the level tracker outside that pcall.
  --
  -- `enabled` is read live rather than captured, so turning the plate off stops
  -- the recording on the same tick instead of after a reload.
  local pullTracker = PullTracker.new({
    bus = bus,
    clock = clock,
    enabled = function() return settings[SettingKey.PLATE_ENABLED] end,
    -- A pull can be carried on for exactly as long as the player can still see
    -- it. Derived rather than restated, so the offer the plate is making and the
    -- window the tracker honours cannot disagree.
    --
    -- A FUNCTION and not the number, because how long the plaque stays is the
    -- player's now (D89): captured as a value, changing it would move what is
    -- drawn and not what counts as the same fight until the next /reload -- the
    -- gap RECOVERY_THRESHOLD still has and COLLECT_DAMAGE closed the same way.
    resumeSeconds = function()
      return settings[SettingKey.PLATE_HOLD_SECONDS] + PullPlateView.FADE_SECONDS
    end,
  })

  -- A pull that never happened, for looking at the plate without going to find
  -- something to kill. It stands in for the tracker rather than publishing on
  -- the bus, and that is the whole of its design: the topics a real pull rides
  -- on are the same ones the level's own collectors and the experience ledger
  -- read, so a demo that published them would write a fictional fight into the
  -- player's actual level record. A stand-in answers the three questions the
  -- plate asks -- which pull, what phase, which generation -- and touches
  -- nothing else.
  local plateDemo

  local function startPlateDemo()
    local pull = PullRecord.new(clock:now())
    plateDemo = {
      pull = pull,
      phase = PullPhase.ACTIVE,
      -- The script, in seconds from the start. Written as data so the shape of
      -- the demo is readable at a glance rather than spread through a branch.
      -- Engagements come FIRST and deliberately: the demo has to show the state
      -- the plate used to have nothing to say about -- two creatures pulled, both
      -- still standing, nothing dead. A script that opened with a kill would
      -- skip straight past the case this is meant to demonstrate.
      script = {
        { at = 0.2, damage = 90, on = { "Kobold Miner", "demo-a" }, ability = { 1752, "Sinister Strike" } },
        { at = 0.8, damage = 70, on = { "Kobold Miner", "demo-b" }, ability = { 1752, "Sinister Strike" } },
        { at = 1.4, ability = { ns.core.AbilityKey.MELEE_SWING } },
        { at = 1.6, damage = 180, on = { "Kobold Laborer", "demo-c" }, ability = { 2098, "Eviscerate" } },
        { at = 2.4, kill = "Kobold Miner", xp = 44, taken = 62 },
        { at = 3.2, damage = 240, on = { "Kobold Miner", "demo-b" }, ability = { 1752, "Sinister Strike" } },
        { at = 4.0, kill = "Kobold Miner", xp = 44, healing = 40 },
        { at = 4.8, damage = 310, on = { "Kobold Laborer", "demo-c" }, ability = { ns.core.AbilityKey.MELEE_SWING } },
        { at = 5.6, kill = "Kobold Laborer", xp = 51 },
      },
      step = 1,
      current = function(self) return self.pull end,
      currentPhase = function(self) return self.phase end,
      -- A constant the real tracker can never produce, so the plate treats the
      -- demo as one pull from first frame to last and does not reset its
      -- counters underneath it.
      currentGeneration = function() return -1 end,
    }

    function plateDemo:advance(now)
      local elapsed = now - self.pull.startedAt
      while self.step <= #self.script and self.script[self.step].at <= elapsed do
        local beat = self.script[self.step]
        if beat.kill then self.pull:recordKill(beat.kill, self.pull.startedAt + beat.at) end
        if beat.xp then self.pull:recordXp(beat.xp, XpSource.MOB_KILL) end
        if beat.ability then self.pull:recordAbility(beat.ability[1], beat.ability[2]) end
        if beat.damage then
          local on = beat.on or {}
          self.pull:recordDamageDealt(beat.damage, on[1], on[2])
        end
        if beat.taken then self.pull:recordDamageTaken(beat.taken) end
        if beat.healing then self.pull:recordHealing(beat.healing) end
        self.step = self.step + 1
      end
      -- Two beats past the last one, so the settling state is on screen long
      -- enough to be read -- it is a real state of a real pull and the demo
      -- exists to show the states.
      if self.step > #self.script and self.phase == PullPhase.ACTIVE and elapsed >= 6.5 then
        self.pull.endedAt = self.pull.startedAt + 6.5
        self.phase = PullPhase.SETTLING
      end
      if self.phase == PullPhase.SETTLING and elapsed >= 8 then
        self.phase = PullPhase.CLOSED
      end
      -- Hands the plate back once its own hold-and-fade has run its course.
      return elapsed < 20
    end

    return plateDemo
  end

  -- One function, called from everywhere the answer could change: after the views
  -- exist, on every settings change, and on entering the world -- which is both
  -- the first moment the client's bar is real and the moment after a loading
  -- screen when whatever the client did to its own bar has just been redone.
  --
  -- Idempotent on purpose (ClientXpBar:applyQuiet converges), so calling it again
  -- costs a table walk over four names and never records its own silence as the
  -- state to give back later.
  local function applyBarSlot()
    if bar == nil then
      return
    end
    local slot = clientXpBar:effectiveSlot(settings[SettingKey.BAR_SLOT])
    clientXpBar:applySlot(slot)
    if BarSlotPolicy.active(slot) then
      -- The slot travels with the frame: which one the player chose is what
      -- decides whether the client's frame art draws over the bar or under it,
      -- and the view has no other way to know (BarSlotPolicy.depth).
      bar:attachTo(clientXpBar:frame(), slot)
    else
      bar:detach()
    end
  end

  -- Whether the player asked to hide the bar via `/ascent ocultar`. draw() in
  -- ui/XpBarView.lua unconditionally shows the frame whenever it has something to
  -- draw, so without tracking this separately the very next redraw -- any XP gain,
  -- rest change, anything on the topic list below -- would silently undo the
  -- command within moments. redraw() further down is the one place that honors it.
  local userHidden = false

  -- The bar's own persistence callback (see ui/XpBarView.lua's header), and also
  -- 12.3's hot-apply: it re-resolves `settings` and pushes the new table into the
  -- three things that captured a copy at construction time and have no way to
  -- notice a change on their own.
  --
  -- COLLECT_DAMAGE now hot-applies too, but not through this function: DamageCollector's
  -- `enabled` closure reads the same `settings` upvalue this reassigns, so a toggle
  -- is visible on that collector's very next call with no rebuild needed.
  -- RECOVERY_THRESHOLD is the one setting still construction-time-only:
  -- CombatTimeCollector.new stores it as a plain value, not a closure, so changing
  -- it takes a reload -- the same gap COLLECT_DAMAGE had before group 6 existed.
  local function saveSetting(key, value)
    local stored = repository:settings()
    local merged = {}
    if stored ~= nil then
      for storedKey, storedValue in pairs(stored) do
        merged[storedKey] = storedValue
      end
    end
    merged[key] = value

    repository:saveSettings(merged)
    settings = Settings.resolve(merged)

    -- Not `bar.settings = settings`: the bar has an appearance, a size and a
    -- position to re-derive from the new table, and it does it without
    -- rebuilding a frame (ui/XpBarView.lua). That is the spec's "applies
    -- immediately, no reload".
    if bar ~= nil then
      bar:applySettings(settings)
      -- After applySettings, not before: that call re-resolves the appearance and
      -- the size from the new table, and the slot is what decides whether the
      -- size it just applied is the one the bar actually gets to keep.
      applyBarSlot()
    end
    if panel ~= nil then
      panel:applySettings(settings)
    end
    if plate ~= nil then
      -- The whole table, so the view is looking at the same settings this
      -- function just resolved. It follows the bar's skin rather than carrying
      -- one of its own: two surfaces of the same addon picking different skins
      -- is a setting nobody asked for and a screenshot nobody wants.
      plate:applySettings(settings)
      if not settings[SettingKey.PLATE_ENABLED] then
        plate:hide()
        pullTracker:reset()
      end
    end
    -- The options panel too, and for the same reason the bar gets told: it holds
    -- a control per setting, and every one of them is showing a value that just
    -- changed. Guarded because it is built last and may not exist at all.
    if optionsPanel ~= nil and optionsPanel.refresh ~= nil then
      optionsPanel.refresh()
    end
    logger:setDebug(settings[SettingKey.DEBUG])
    tracker.retention = RetentionPolicy.new(settings)
  end

  local viewsOk, viewsError = pcall(function()
    bar = XpBarView.new({
      settings = settings, saveSetting = saveSetting, locale = locale, onToggle = nil,
      -- The same directory the panel reads, and the pending entries as a
      -- question rather than a value: the popup asks when it opens, so the
      -- redraw tick pays nothing for a popup nobody is hovering.
      questNames = questNames,
      questEntries = function() return questForecastService:entries() end,
    })

    -- The slot the player chose, applied for the first time. Inside the views'
    -- pcall: a client whose bar is not where this addon looks must cost the slot,
    -- not the bar.
    applyBarSlot()

    -- Group 11.1: the level report panel. `recordingLevel` (defined above, group
    -- 6) is exactly the right indirection here too -- the panel has no more
    -- business knowing about isRecording()'s gate than the combat collectors do.
    -- Wired to the bar's click-to-toggle only now, after both exist: XpBarView
    -- reads `onToggle` once from its constructor options rather than re-reading
    -- it later, so setting the field directly here (it is a plain value on
    -- `self`, not a setter) is simpler than restructuring either constructor's
    -- order to make onToggle available up front.
    panel = ReportPanelView.new({
      settings = settings, saveSetting = saveSetting, currentRecord = recordingLevel,
      questForecastService = questForecastService, questNames = questNames, locale = locale,
      -- How many are sharing the pay right now. The domain cannot ask the client
      -- itself, so the question crosses here, through the port, exactly like every
      -- other reading of the character's state -- and it is asked on each rebuild
      -- because the answer changes the moment the player joins or leaves a group.
      sharedBy = function() return playerState:sharedBy() end,
      -- The three history seams (6.7). Functions rather than the store itself, for
      -- the same reason `currentRecord` is one: the view asks a question and gets
      -- an answer, and never learns that a RecordStore exists.
      completedLevels = function() return store:completedLevels() end,
      currentLevel = function()
        local record = tracker:current()
        return record ~= nil and record.level or nil
      end,
      -- "No level in progress" reads three ways and the panel has to tell them
      -- apart: a new install, experience switched off, and a character who has
      -- finished. Only the tracker knows which.
      atCap = function() return tracker:isAtCap() end,
      recordFor = function(level)
        local current = tracker:current()
        if current ~= nil and current.level == level then
          return current
        end
        return store:completed(level)
      end,
      -- Resolved at click time, not now: the options panel registers itself much
      -- further down this function, so a value captured here would be nil for the
      -- whole session. The same two fields `/ascent options panel` reads.
      onOpenOptions = function()
        openOptionsPanel(optionsPanel, optionsCategory)
      end,
    })
    bar.onToggle = function() panel:toggle() end

    -- The pull plate. Last of the three views and the only one that draws
    -- nothing until something happens, so a client that fails here costs the
    -- plate and leaves the bar and the panel already built above.
    plate = PullPlateView.new({
      settings = settings, saveSetting = saveSetting, locale = locale,
      -- What the LEVEL still needs, asked fresh on every draw. `recordingLevel`
      -- is the same indirection the panel and the collectors use: nil when there
      -- is no level open, which the plate reads as "nothing to say" rather than
      -- as zero.
      -- Read-only, and for one purpose: KillXpEstimator needs this level's own
      -- per-creature history to say what the things still standing are likely to
      -- pay. The same indirection everything else here uses.
      levelRecord = recordingLevel,
      -- The other half of what the forecast needs: which population to price it
      -- from. Same seam, same reason as the panel's.
      sharedBy = function() return playerState:sharedBy() end,
      levelProgress = function()
        local record = recordingLevel()
        if record == nil or record.xpRequired == nil or record.xpRequired <= 0 then
          return nil
        end
        local remaining = record.xpRequired - record.xpTotal
        if remaining < 0 then
          remaining = 0
        end
        return { remaining = remaining, percent = record.xpTotal / record.xpRequired }
      end,
    })
    plate:applySkin(settings[SettingKey.BAR_SKIN], settings[SettingKey.BAR_APPEARANCE],
      settings[SettingKey.BAR_COLORS], settings[SettingKey.HIGH_CONTRAST])

    demo = DemoDriver.new({
      bar = bar,
      logger = logger,
      -- Stopping does not paint the real bar itself: it marks the scheduler dirty
      -- and lets the redraw that already exists do it, so there is one path that
      -- paints real data and not two.
      onStop = function() scheduler:markDirty() end,
    })
  end)

  if not viewsOk then
    -- Reported, not hidden. The addon carries on without its views: recording,
    -- attribution and every command that does not need a frame keep working, and
    -- the player gets the reason instead of silence.
    logger:warn(locale:get(TextKey.ERR_UI_FAILED, tostring(viewsError)))
  end

  -- The one place that actually repaints the bar, so every call site that wants a
  -- redraw gets `userHidden` honored for free instead of having to remember it.
  -- unattributedXp is what XpAttribution has confirmed from the client but not
  -- yet settled into a source (D21) -- passed through so the bar's total and
  -- percent move immediately instead of lagging behind the settling window.
  local function redraw()
    -- No views this session (see the pcall above): everything else carries on,
    -- there is simply nothing to paint.
    if bar == nil then
      return
    end
    -- The demo owns the bar while it is on: without this, the next 5 Hz tick
    -- would paint the player's real level straight over whatever state they
    -- were looking at (app/DemoDriver.lua).
    if demo ~= nil and demo:isActive() then
      return
    end

    local restedXp = playerState:restedXp()
    -- Group 7: pace and projections, computed fresh on every redraw from the
    -- record's own live numbers -- nothing here is persisted, so there is
    -- nothing to keep in sync with the record besides calling this before
    -- reading it.
    local estimate = ProgressEstimator.build(tracker:current(), {
      playedSeconds = tracker:playedSeconds(),
      restedXp = restedXp,
      sessionSeconds = clock:now(),
      sessionXpGained = sessionXpTracker:total(),
    })

    bar:update(tracker:current(), {
      restedXp = restedXp,
      unattributedXp = xpAttribution:pendingAmount(),
      xpPerHour = estimate.xpPerHourLevel,
      timeToLevel = estimate.timeToLevel,
      -- "time on this sitting" (see XpBarView.buildTextValues) is D14's session
      -- clock, the same one SessionXpTracker's own pace is measured against.
      sessionTime = clock:now(),
      -- Group 8: everything accepted, not only what is already turned-in-ready
      -- -- the proposal's own framing ("lo que el personaje cobrará al
      -- entregar lo que ya lleva aceptado") is about the whole log, not just
      -- the subset ready this instant.
      questPending = questForecastService:report().total,
    })
    if userHidden then
      bar.frame:Hide()
    end
  end

  for _, topic in ipairs({
    EventTopic.RECORD_UPDATED, EventTopic.REST_CHANGED, EventTopic.XP_STATE_CHANGED,
    EventTopic.LEVEL_STARTED, EventTopic.LEVEL_COMPLETED,
    -- Without this one, redraw()'s own read of xpAttribution:pendingAmount() (D21,
    -- above) was correct but never got CALLED promptly: nothing marked the
    -- scheduler dirty on a raw delta, only once it settled ~3s later into
    -- RECORD_UPDATED -- at which point pendingAmount() was already back to zero
    -- and the bar jumped straight from the old total to the final one, never
    -- showing the provisional frame this fix exists to show.
    EventTopic.XP_DELTA_OBSERVED,
  }) do
    bus:subscribe(topic, function()
      scheduler:markDirty()
      if panel ~= nil then
        panel:markDirty()
      end
    end)
  end

  -- XpAttribution.settle() only runs on intake (a delta, a hint, a death arriving)
  -- -- see its own header comment: "Called after every intake and, from the
  -- composition root, on a timer, so a lone delta with nothing following it still
  -- settles." That timer never existed until now, so the last gain of a farming
  -- session (nothing arrives after it to trigger settle()) sat unsettled forever:
  -- shown as provisional (D21, above) but never resolved to its real source or to
  -- confirmed UNKNOWN. Throttled well under the ~4.5s window (3x the 1.5s default)
  -- this exists to drain, so it costs nothing that redraw's own 5Hz cap doesn't
  -- already pay for elsewhere.
  local lastSettleAt = nil
  local lastObserveAt = nil
  local lastQuestScanAt = nil
  local lastSweepAt = nil
  local nameplateWatch = ns.adapter.NameplateWatch.new({
    bus = bus, recordEvidence = recordEvidence,
  }):start()

  local ticker = CreateFrame("Frame")
  ticker:SetScript("OnUpdate", function(_, elapsed)
    -- The presentation clock (design D24). One line, inside the OnUpdate that
    -- already existed rather than a second script of its own (D32): this frame
    -- was already being paid for. The call returns immediately once the bar has
    -- arrived and nothing is flashing, so a bar at rest costs a comparison.
    if bar ~= nil then
      bar:tick(elapsed)
    end

    local now = clock:now()

    -- The pull plate, on the same frame clock the bar uses and for the same
    -- reason (D24, D32): its counters interpolate per frame and its finished
    -- plaque fades per frame, and neither is worth a second OnUpdate.
    --
    -- Three calls in a fixed order, and the order is the whole of it: tick the
    -- tracker so a settled pull closes, redraw only if something actually
    -- changed, then advance whatever the redraw left in motion. Redrawing
    -- unconditionally here would rebuild a view-model sixty times a second
    -- during a fight for a frame whose numbers changed twice.
    pullTracker:tick(now)
    -- What you pulled that has not reached you yet (D6's budget is why this is
    -- throttled AND gated): only while a pull is actually open, so out of combat
    -- it costs one comparison, and four times a second inside one, which is far
    -- faster than a creature can cross the ground between you.
    -- It used to run ONLY while a pull was already open, which put the one thing
    -- that could see a creature coming behind the thing it was supposed to
    -- precede: of nine fights recorded on 2026-09-22, eight were opened by a
    -- combat log line and the sweep was switched off for every one of them until
    -- after the fact. A creature charging you with a shield up writes nothing the
    -- client calls damage, so the plate stayed empty until something landed.
    --
    -- Now it always runs, and the rate is what keeps D6's budget: four times a
    -- second inside a fight, where creatures arrive and the answer changes, and
    -- once a second outside one, which is far faster than anything can cross the
    -- ground between you and still slow enough to disappear into the frame this
    -- OnUpdate was already paying for.
    local sweepEvery = pullTracker:current() ~= nil and 0.25 or 1
    if lastSweepAt == nil or now - lastSweepAt >= sweepEvery then
      lastSweepAt = now
      nameplateWatch:sweep()
    end
    if plate ~= nil then
      if plateDemo ~= nil then
        -- The demo owns the plate while it runs, the same way DemoDriver owns
        -- the bar: without this the next real change would paint a live pull
        -- straight over the state the player asked to look at.
        if not plateDemo:advance(now) then
          plateDemo = nil
          plate:hide()
        else
          plate:follow(plateDemo, now)
        end
      elseif pullTracker:consumeChange() then
        -- What the plate is actually being handed, which until now was the one
        -- link in this chain with no instrument on it. Three sessions were spent
        -- reasoning about an empty plate from enrolment data alone -- the file
        -- could say a creature joined a pull and nothing at all about whether a
        -- pull existed, what phase it was in, or what the view was asked to draw.
        --
        -- Only on a change, which is already throttled by consumeChange, and a
        -- counter-only family so it can never crowd the ring.
        local pull = pullTracker:current()
        recordEvidence("plate." .. tostring(pullTracker:currentPhase())
          .. "." .. (pull ~= nil and tostring(pull:engagedCount()) or "nopull"))
        plate:follow(pullTracker, now)
      end
      plate:tick(elapsed)
    end
    if lastSettleAt == nil or now - lastSettleAt >= 1 then
      lastSettleAt = now
      xpAttribution:settle(now)
    end
    -- CombatTimeCollector's recovery sampling (6.5, D23): tied to its own 5Hz
    -- throttle, not to scheduler:tick(), which only fires when something is
    -- already dirty -- a player standing still recovering triggers no bus event
    -- at all, so waiting on the redraw scheduler would mean this never runs.
    if lastObserveAt == nil or now - lastObserveAt >= 0.2 then
      lastObserveAt = now
      combatTimeCollector:observe(recordingLevel(), playerState:healthFraction(), playerState:powerFraction())
      -- The place is sampled on the same tick and for the same reason: the client
      -- fires no event for "the character is somewhere else now", and the time a
      -- place cost is the denominator of every rate the panel shows for it. The
      -- collector rebuilds its key only when the answer actually changes, so a
      -- tick that finds the character where it left them costs two comparisons.
      placeTimeCollector:observe(recordingLevel(), playerState:place())
    end
    -- Group 8's own cadence (8.3): tied to its own throttle rather than
    -- scheduler:tick(), for the same reason CombatTimeCollector's sampling
    -- above is -- QUEST_LOG_CHANGED marking this dirty has nothing to do with
    -- whatever marks the bar's own scheduler dirty, and accepting a quest
    -- with no XP gain in the same moment must not have to wait for one.
    if lastQuestScanAt == nil or now - lastQuestScanAt >= 0.2 then
      lastQuestScanAt = now
      if questForecastService:tick() then
        -- A fresh forecast changes the bar's pending channel and the panel's
        -- (future) pending tab, neither of which QUEST_LOG_CHANGED marks
        -- dirty on its own -- that topic only tells this service to rescan.
        scheduler:markDirty()
        if panel ~= nil then
          panel:markDirty()
        end
      end
    end
    if scheduler:tick() then
      redraw()
      -- Riding the bar's own 5Hz tick (D7's general cap, not just the bar's
      -- own) rather than calling this unthrottled every frame: the panel's
      -- RebuildGate (11.7) already answers "is it even open" and "did
      -- anything change" for free, but that is a cap on whether it does
      -- real work at all, not on how OFTEN this call itself would otherwise
      -- happen while both are true.
      if panel ~= nil then
        panel:refresh()
      end
    end
  end)

  -- tracker:start() reads UnitXPMax("player") (via LevelTracker:requiredFor), and
  -- that is not reliably populated yet at ADDON_LOADED -- the client can still be
  -- on the loading screen, unit data not yet synced from the server. Calling it
  -- there produced a level record with xpRequired == 0 on a fresh login: read as
  -- "nothing to show" by XpBarViewModel, and refused outright by XpLedger, which
  -- errors rather than post experience into a level that needs none. A /reload
  -- never showed the bug because the world was never torn down, so the unit data
  -- was already real.
  --
  -- PLAYER_ENTERING_WORLD is the client's own signal that this data now exists,
  -- so that is what triggers the actual start -- and start() is designed to be
  -- safe to call again on every later firing too (a loading screen mid-session,
  -- a second /reload), the same self-healing behaviour WowEventRouter already
  -- relies on for its own XP snapshot anchor.
  local entering = CreateFrame("Frame")
  entering:RegisterEvent(WowEvent.PLAYER_ENTERING_WORLD)
  entering:SetScript("OnEvent", function()
    tracker:start()
    -- The client rebuilds and re-shows its own bar across a loading screen, so
    -- whatever was done to it before one has to be done again after it.
    applyBarSlot()
    redraw()
  end)

  -- Everything built above, kept reachable so the options panel that is the next
  -- phase of this same work can read and write settings, toggle the bar and read
  -- diagnostics without reconstructing any of it. Read-only by convention: nothing
  -- outside this file should replace one of these wholesale.
  local context = {
    repository = repository,       -- the raw SavedVariables port
    store = store,                 -- the record store (current/completed levels)
    clock = clock,
    playerState = playerState,
    logger = logger,
    locale = locale,             -- the Locale port, for anything that prints
    bus = bus,
    registry = registry,           -- the XP classifier registry
    correlator = correlator,
    xpAttribution = xpAttribution,
    tracker = tracker,             -- the level tracker (current level, history)
    sessionXpTracker = sessionXpTracker,
    scheduler = scheduler,
    -- The frame clock itself. Published for the same reason the views are: the
    -- smoke harness has to be able to DRIVE the addon, and the three-call order
    -- inside this OnUpdate -- close a settled pull, redraw if something changed,
    -- advance what is in motion -- is behaviour worth exercising rather than
    -- restating in a test.
    ticker = ticker,
    bar = bar,                     -- the XpBarView instance
    panel = panel,                 -- the ReportPanelView instance
    plate = plate,                 -- the PullPlateView instance
    pullTracker = pullTracker,     -- the pull lifecycle (current pull, phase)
    questLogReader = questLogReader,
    capabilities = capabilities,
    -- Whether the client has an experience bar to take over. A question the
    -- options panel asks to explain a slot that is set and not in effect.
    clientBarPresent = function() return clientXpBar:present() end,
    saveSetting = saveSetting,     -- (key, value) -> persists + hot-applies
    settings = function() return settings end, -- always the current resolved table
    -- The level the options panel's previews draw (7.3). A module function, not
    -- the driver instance: the panel wants the demo's script, not a demo to
    -- drive, and asking for the instance would have tied the preview to a
    -- session where the views were built successfully.
    demoSample = DemoDriver.sample,
    -- The plate's page has no preview of its own and does not want one (D92):
    -- its button runs THIS, the same fake pull `/ascent options plate demo`
    -- runs, on the real plate. Published as the function rather than as the
    -- stand-in it builds, for the same reason demoSample is a module function --
    -- the panel wants to start one, not to drive one.
    startPlateDemo = startPlateDemo,
  }
  ns.app.context = context

  -- ---------------------------------------------------------------------------
  -- 12.2: chat commands.
  -- ---------------------------------------------------------------------------

  -- The keyword is a literal and the description is a key, deliberately: the
  -- dispatcher below matches these spellings byte for byte, so a translated keyword
  -- would document a command that no longer answers.
  local HELP_LINES = {
    { "show", TextKey.CMD_HELP_SHOW },
    { "hide", TextKey.CMD_HELP_HIDE },
    { "panel", TextKey.CMD_HELP_PANEL },
    { "summary", TextKey.CMD_HELP_SUMMARY },
    { "pending", TextKey.CMD_HELP_PENDING },
    -- Every subcommand handleOptions answers, and nothing else. It had grown three
    -- short: `plate`, `slot` and `panel` all shipped without ever reaching this
    -- line, which documents a command that does not exist just as surely as
    -- advertising one that was folded away does -- and the harness checks it by
    -- running what this line announces.
    --
    -- The alternatives are bracketed so that each one's first word IS the
    -- keyword: `contrast on|off` read as two alternatives, the second of them
    -- "off", which is not a subcommand at all.
    { "options [reset|skin <id>|slot <where>|plate [on|off|demo|reset]|panel"
      .. "|contrast <on|off>|motion <0-1>|lock|unlock|scale <n>|debug <on|off>]",
      TextKey.CMD_HELP_OPTIONS },
    { "reset confirm", TextKey.CMD_HELP_RESET },
    { "debug [evidence on|off|reset] [timesync on|off]", TextKey.CMD_HELP_DEBUG },
    { "demo [off]", TextKey.CMD_HELP_DEMO },
    { "copy [debug|summary|pending]", TextKey.CMD_HELP_COPY },
    { "changelog", TextKey.CMD_HELP_CHANGELOG },
  }

  local function printHelp()
    logger:info(locale:get(TextKey.CMD_HELP_HEADER))
    for _, entry in ipairs(HELP_LINES) do
      logger:info(locale:get(TextKey.CMD_HELP_ROW, entry[1], locale:get(entry[2])))
    end
  end

  local function printSummary()
    local record = tracker:current()
    if record == nil then
      logger:info(locale:get(TextKey.CMD_NO_LEVEL))
      return
    end

    -- xpRequired is nilable by design (core/model/LevelRecord.lua: "learned from
    -- the client; unknown until then"), so between login and the first PLAYER_XP_UPDATE
    -- there is genuinely no total to show. The marker says that; tostring(nil) said
    -- "nil xp".
    local xpRequired = record.xpRequired
      and tostring(record.xpRequired)
      or locale:get(TextKey.NOT_AVAILABLE)

    logger:info(locale:get(TextKey.CMD_SUMMARY_HEADER, record.level, record.xpTotal, xpRequired))

    for _, source in Frozen.each(XpSource) do
      local amount = record:xpFrom(source)
      if amount > 0 then
        logger:info(locale:get(TextKey.CMD_SUMMARY_ROW, locale:get(SOURCE_NAME[source]), amount))
      end
    end
  end

  -- 12.2's own scenario: total, subtotal ready to turn in, and the count of
  -- quests with no known reward -- printed as a projection, never folded into
  -- printSummary's own breakdown (quest-xp-forecast's "nunca se cuenta como
  -- obtenida").
  local function printPending()
    local report = questForecastService:report()
    logger:info(locale:get(TextKey.CMD_PENDING, report.total, report.readyTotal))
    if report.unknownCount > 0 then
      logger:info(locale:get(TextKey.CMD_PENDING_UNKNOWN, report.unknownCount))
    end
  end

  local function printOptionsStatus()
    logger:info(locale:get(TextKey.CMD_STATUS_LOCKED, tostring(bar.locked)))
    logger:info(locale:get(TextKey.CMD_STATUS_SCALE, tostring(settings[SettingKey.BAR_SCALE])))
    logger:info(locale:get(TextKey.CMD_STATUS_DEBUG, tostring(settings[SettingKey.DEBUG])))
    logger:info(locale:get(TextKey.CMD_STATUS_SLOT, tostring(settings[SettingKey.BAR_SLOT])))
    -- Only when it would explain something. A player on the default slot has no
    -- reason to be told about a bar the addon was not going to touch anyway.
    if BarSlotPolicy.active(settings[SettingKey.BAR_SLOT]) and not clientXpBar:present() then
      logger:warn(locale:get(TextKey.CMD_SLOT_NO_CLIENT_BAR))
    end
  end

  -- What `/ascent options plate` answers with no argument, the way `skin` and
  -- `slot` already do. Written for a player who cannot find the plate at all, so
  -- it leads with the three states that hide one -- switched off, transparent, or
  -- dropped past the edge of the screen -- and says where it is before what it
  -- draws. The lock is on the first line because it is what stops them moving it
  -- once they have found it.
  --
  -- The plate's own appearance map is deliberately not printed: it is partial by
  -- design (D87), it is the page's business, and no axis in it can hide a plate.
  local function printPlateStatus()
    logger:info(locale:get(TextKey.CMD_PLATE_STATUS,
      tostring(settings[SettingKey.PLATE_ENABLED]),
      tostring(settings[SettingKey.PLATE_LOCKED])))
    logger:info(locale:get(TextKey.CMD_PLATE_FRAME,
      tostring(settings[SettingKey.PLATE_SCALE]),
      tostring(settings[SettingKey.PLATE_WIDTH]),
      tostring(settings[SettingKey.PLATE_OPACITY]),
      tostring(settings[SettingKey.PLATE_HOLD_SECONDS]),
      tostring(settings[SettingKey.PLATE_ROWS])))

    local position = settings[SettingKey.PLATE_POSITION]
    logger:info(locale:get(TextKey.CMD_PLATE_AT,
      tostring(position.point), tostring(position.x), tostring(position.y)))

    -- Through the layout service, so what is printed is in the order the plate
    -- draws (D90) rather than in whatever order the saved file happens to list.
    local zones = ns.core.PlateLayout.zones(settings[SettingKey.PLATE_ZONES])
    if #zones == 0 then
      logger:info(locale:get(TextKey.CMD_PLATE_NO_ZONES))
    else
      logger:info(locale:get(TextKey.CMD_PLATE_ZONES, table.concat(zones, ", ")))
    end
  end

  -- The plate's vocabulary, spelled the way the dispatcher matches it. A literal
  -- rather than a locale string, for the same reason the help keywords are: a
  -- translated keyword would name a command that no longer answers.
  local PLATE_CHOICES = "on, off, demo, reset"

  local function handleOptions(rest)
    local sub, arg = splitFirst(rest)
    sub = sub:lower()

    if sub == "" then
      printOptionsStatus()
    elseif sub == "lock" then
      bar:setLocked(true) -- persists via saveSetting internally (ui/XpBarView.lua)
    elseif sub == "unlock" then
      bar:setLocked(false)
    elseif sub == "scale" then
      local scale = tonumber(arg)
      if scale == nil or scale ~= scale or scale <= 0 then
        logger:warn(locale:get(TextKey.CMD_BAD_SCALE, arg))
      else
        bar:setScale(scale) -- also persists internally
      end
    elseif sub == "reset" then
      -- The way back. A player who made the bar unreadable, or dragged it
      -- somewhere they cannot reach, cannot fix it from a panel they have to see
      -- to click -- so this path deliberately does not depend on the interface
      -- being usable, only on being able to type. Data is untouched: this resets
      -- how the addon LOOKS, never what it has recorded ("/ascent reset confirm"
      -- is the other one, and it asks first).
      saveSetting(SettingKey.BAR_APPEARANCE, {})
      saveSetting(SettingKey.BAR_COLORS, {})
      saveSetting(SettingKey.BAR_SKIN, ns.core.DEFAULT_SKIN_ID)
      saveSetting(SettingKey.HIGH_CONTRAST, false)
      saveSetting(SettingKey.MOTION_SCALE, 1)
      saveSetting(SettingKey.BAR_WIDTH, ns.core.Defaults[SettingKey.BAR_WIDTH])
      saveSetting(SettingKey.BAR_HEIGHT, ns.core.Defaults[SettingKey.BAR_HEIGHT])
      saveSetting(SettingKey.BAR_POSITION, { point = "CENTER", x = 0, y = 200 })
      logger:info(locale:get(TextKey.CMD_APPEARANCE_RESET))
    elseif sub == "skin" then
      -- The options panel is where a player picks a skin (ui/OptionsPanel.lua).
      -- This is the shortcut, and -- like every other appearance command here --
      -- the way back when the interface itself cannot be used: a bar dragged off
      -- screen or made unreadable cannot be fixed from a panel the player has to
      -- see to click.
      local catalog = ns.core.SkinCatalog
      if arg == "" then
        logger:info(locale:get(TextKey.CMD_SKINS, table.concat(ns.core.Frozen.keys(catalog), ", ")))
      elseif ns.core.Frozen.has(catalog, arg) then
        saveSetting(SettingKey.BAR_SKIN, arg)
      else
        logger:warn(locale:get(TextKey.CMD_BAD_SKIN, arg))
      end
    elseif sub == "slot" then
      -- Where the bar lives. The same shortcut-and-way-back reasoning as the
      -- appearance commands above: a player whose bar ended up somewhere
      -- unusable has to be able to undo it by typing.
      local wanted = arg:lower()
      if wanted == "" then
        logger:info(locale:get(TextKey.CMD_STATUS_SLOT, tostring(settings[SettingKey.BAR_SLOT])))
        -- The choices table is keyed BY the slot names, so its keys are the
        -- vocabulary itself -- sorted, and with no second list to drift.
        logger:info(locale:get(TextKey.CMD_SLOTS,
          table.concat(Frozen.keys(ns.core.SettingChoices[SettingKey.BAR_SLOT]), ", ")))
      elseif Frozen.has(ns.core.SettingChoices[SettingKey.BAR_SLOT], wanted) then
        saveSetting(SettingKey.BAR_SLOT, wanted)
        if BarSlotPolicy.active(wanted) and not clientXpBar:present() then
          logger:warn(locale:get(TextKey.CMD_SLOT_NO_CLIENT_BAR))
        end
      else
        logger:warn(locale:get(TextKey.CMD_BAD_SLOT, arg))
      end
    elseif sub == "plate" then
      -- The pull plate, on or off. A frame that appears the moment a fight
      -- starts is the one surface in this addon a player might want gone in a
      -- hurry -- mid-raid, mid-anything -- so it gets a typed way out that does
      -- not require finding a checkbox first.
      local wanted = arg:lower()
      if wanted == "" then
        printPlateStatus()
      elseif wanted == "on" then
        saveSetting(SettingKey.PLATE_ENABLED, true)
      elseif wanted == "off" then
        saveSetting(SettingKey.PLATE_ENABLED, false)
      elseif wanted == "demo" then
        if plate == nil then
          logger:warn(locale:get(TextKey.ERR_NO_UI))
        else
          startPlateDemo()
        end
      elseif wanted == "reset" then
        -- The way back, and for this surface the only one there is. The plate's
        -- page is reached by clicking, and a plate dragged off the screen or left
        -- at an opacity that hides it cannot be clicked: you cannot grab what you
        -- cannot see. Same argument as the bar's reset above, and the same
        -- promise -- this resets how the plate LOOKS, never what was recorded.
        --
        -- Its own keys and no others (D87): the plate follows the bar's skin,
        -- palette and contrast, so a reset that reached those would undo, from a
        -- command about one surface, choices made for the other. The list is
        -- shared with the button on the plate's page so the two cannot disagree.
        for _, key in ipairs(ns.core.PlateSettingKeys) do
          -- A COPY of the default, never the default itself: a frozen map's proxy
          -- written back is an empty carrier and reaches disk empty, and the zone
          -- list a frozen table answers with IS its backing store.
          saveSetting(key, Frozen.plain(ns.core.Defaults[key]))
        end
        logger:info(locale:get(TextKey.CMD_PLATE_RESET))
      else
        logger:warn(locale:get(TextKey.CMD_BAD_PLATE, PLATE_CHOICES))
      end
    elseif sub == "contrast" then
      if arg:lower() == "on" then
        saveSetting(SettingKey.HIGH_CONTRAST, true)
      elseif arg:lower() == "off" then
        saveSetting(SettingKey.HIGH_CONTRAST, false)
      else
        logger:warn(locale:get(TextKey.CMD_BAD_ON_OFF, arg))
      end
    elseif sub == "motion" then
      local motion = tonumber(arg)
      if motion == nil or motion ~= motion then
        logger:warn(locale:get(TextKey.CMD_BAD_SCALE, arg))
      else
        saveSetting(SettingKey.MOTION_SCALE, motion)
      end
    elseif sub == "debug" then
      if arg:lower() == "on" then
        saveSetting(SettingKey.DEBUG, true)
      elseif arg:lower() == "off" then
        saveSetting(SettingKey.DEBUG, false)
      else
        logger:warn(locale:get(TextKey.CMD_BAD_ON_OFF, arg))
      end
    elseif sub == "panel" then
      openOptionsPanel(context.optionsPanel, context.optionsCategory)
    else
      logger:warn(locale:get(TextKey.CMD_UNKNOWN_OPTION, sub))
    end
  end

  local function handleReset(rest)
    if rest ~= "confirm" then
      logger:info(locale:get(TextKey.CMD_RESET_PROMPT))
      return
    end

    -- 12.4: the same re-seeding path LevelTracker_spec.lua already exercises for
    -- "new character mid-level" -- clearing record/sessionMark and calling start()
    -- again lets it reconcile a fresh record from the character's current state,
    -- rather than inventing a separate reset mechanism.
    store:clear()
    tracker.record = nil
    tracker.sessionMark = nil
    tracker:start()
    redraw()
    -- The panel reads the store, and an open one is holding a view-model built
    -- from records that no longer exist -- including, since the level selector,
    -- a title naming one of them. `select(nil)` drops the selection and rebuilds
    -- in one call; without it the panel keeps showing an erased level until
    -- something unrelated happens to mark it dirty.
    if panel ~= nil then
      panel:select(nil)
    end

    logger:info(locale:get(TextKey.CMD_RESET_DONE))
  end

  -- 12.6: what the running client looks like. Two facets the design calls out by
  -- name have nothing to show today and this must not pretend otherwise --
  -- "collector registration gated by flavor" is group 6's job and "quest data
  -- provenance" is group 8's, neither exists yet, so neither has registered a
  -- capability probe. capabilities:missing() is genuinely empty, not faked empty.
  -- The order XpAttribution's counters print in, fixed rather than `pairs`
  -- (non-deterministic order, same reason D22 sorts before writing to disk).
  -- These already exist (XpAttribution:diagnostics()) but had no reader: a
  -- player who sees experience land in "Unclassified" had no way to tell
  -- whether it was a delta nothing claimed, a hint nothing settled, or a
  -- channel this build's classifiers do not recognise.
  local DIAGNOSTICS_LABELS = {
    { "pendingDeltas", "deltas awaiting settlement" },
    { "pendingHints", "hints awaiting settlement" },
    { "unmatchedDeltas", "deltas settled with no hint claiming them" },
    { "unclaimedHints", "hints that expired with no delta to claim" },
    { "unclassifiedHints", "hints on a channel no classifier recognises" },
    { "duplicateAnnouncements", "gains announced on two channels, counted once" },
    { "anonymousClaimed", "amount-only lines a source hint accounted for" },
    { "anonymousUnclaimed", "amount-only lines nothing claimed" },
    { "restedDisagreements", "parsed vs. reserve-derived rested bonus disagreed" },
    { "uncorrelatedKills", "kills whose death and XP hint never matched" },
  }

  -- Spike support for the group/raid experience work: dumps the client's own
  -- GlobalStrings and location APIs to chat AND to saved variables.
  --
  -- The reason it writes to disk rather than only printing: the addon parses
  -- experience messages by building patterns from these strings, so their exact
  -- shape -- which marker comes first, whether they use positional markers --
  -- decides what each capture group holds. Getting that wrong does not fail; it
  -- misclassifies silently. Reading them off the player's actual client is
  -- first-hand evidence, and none of it is documented for BC Classic anywhere.
  -- DERIVED from the list the parser actually reads, not pasted beside it. The
  -- paste had already drifted: the eight EXHAUSTION*_GROUP/_RAID templates were
  -- missing, which are exactly the ones the group and raid work added -- so the
  -- dump a tester takes on a non-English client to answer task 5.2 would not have
  -- contained the strings 5.2 is about.
  local XP_GLOBALS = {}
  for _, source in ipairs(GlobalStringPattern.SOURCES) do
    XP_GLOBALS[#XP_GLOBALS + 1] = source.global
  end
  -- The research extras: not parsed, but worth seeing on an unfamiliar client
  -- because they are what the parsed ones have to be told apart from.
  for _, name in ipairs({
    "LEVEL_UP", "XP", "COMBATLOG_HONORGAIN", "COMBATLOG_HONORAWARD",
    "COMBATLOG_XPGAIN_QUEST_UNNAMED",
  }) do
    XP_GLOBALS[#XP_GLOBALS + 1] = name
  end

  local function countKeys(map)
    local count = 0
    for _ in pairs(map) do
      count = count + 1
    end
    return count
  end

  local function dumpStrings()
    local dump = { locale = GetLocale(), flavor = Compat.flavor(), strings = {}, location = {} }

    -- To the debug log and not to chat. These are fifteen lines of the client's
    -- own raw text: their value is in the snapshot below and in the log file,
    -- and printing them pushed everything else in the diagnostic off the top of
    -- a 500-line chat ring -- the same reason the evidence recorder writes to a
    -- file instead of here.
    for _, name in ipairs(XP_GLOBALS) do
      local value = _G[name]
      dump.strings[name] = value ~= nil and value or false
      logger:debug(("%s = %s"):format(name, value ~= nil and tostring(value) or "<absent>"))
    end

    -- The location side of the same question, read where the player is standing
    -- right now. Worth capturing together: whether these are localized text or a
    -- stable id decides how a zone can be recorded at all.
    local inInstance, instanceType = IsInInstance()
    dump.location.inInstance = inInstance
    dump.location.instanceType = instanceType
    if GetInstanceInfo ~= nil then
      local name, kind, difficulty, difficultyName, maxPlayers, _, _, instanceId = GetInstanceInfo()
      dump.location.instanceName = name
      dump.location.instanceKind = kind
      dump.location.instanceId = instanceId
      dump.location.maxPlayers = maxPlayers
      dump.location.difficulty = difficulty
      dump.location.difficultyName = difficultyName
    end
    dump.location.zone = GetZoneText()
    dump.location.subZone = GetSubZoneText()
    if C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil then
      local ok, mapId = pcall(C_Map.GetBestMapForUnit, "player")
      dump.location.uiMapId = ok and mapId or false
    end
    dump.location.inGroup = IsInGroup()
    dump.location.inRaid = IsInRaid()
    dump.location.groupMembers = GetNumGroupMembers()

    for key, value in pairs(dump.location) do
      logger:debug(("location.%s = %s"):format(key, tostring(value)))
    end

    -- Written straight to the per-character store rather than through the
    -- repository: this is a diagnostic snapshot, not addon state, and it must
    -- survive even if everything else about the session is broken.
    AscentCharDB = AscentCharDB or {}
    AscentCharDB.globalStringDump = dump
    logger:info(locale:get(TextKey.CMD_STRINGS_DUMPED, countKeys(dump.strings)))
  end

  -- The quest log's own section of the diagnostic. Spike 0.5's per-quest dump
  -- goes to the debug log (the reader writes it when given a logger), and what
  -- comes to chat is the three figures a player can act on -- most of all the
  -- last one, which is the only way to tell "this client words a kill objective
  -- differently" apart from "these quests ask for feathers".
  local function printQuestDebug()
    -- The recorder goes in HERE and not into the `scan` closure the scheduler
    -- drives: this is the sweep an operator asked for, once, and the ticker's runs
    -- on every quest-log change would evict everything else from the ring.
    local forecasts = sweepQuestLog(logger, recordEvidence)
    logger:info(locale:get(TextKey.CMD_QUESTS_SCANNED, #forecasts))
    logger:info(locale:get(TextKey.CMD_QUESTS_NAMED, questNames:count()))
    logger:info(locale:get(TextKey.CMD_QUESTS_OBJECTIVES,
      questLogReader.objectivesRead, questLogReader.objectivesSeen))
  end

  -- What the group dimension has actually collected, which is the only way the
  -- design's open question -- whether sizes that turn up once a level deserve
  -- lumping in with a bigger one -- gets settled against a file instead of an
  -- argument. It needs a SAMPLE COUNT, and no other surface carries one: the panel
  -- and the plate price a population, they never say how thin it is.
  --
  -- Grouped by NAME and not by aggregate, because the name is what the estimator
  -- matches on: `creatureRate` sums every level band of a name at one group size,
  -- so the population behind a number is the pair (name, size), and a listing
  -- split per band would show halves of one.
  local function printGroupDebug()
    -- Asked of the port rather than of `GetNumGroupMembers`, so the figure printed
    -- here is the one the estimator will be handed -- including the translation
    -- of the client's zero into the one person who is always there (D85).
    logger:info(("group: %d sharing the pay"):format(playerState:sharedBy()))

    local record = tracker:current()
    local order, byName, populations = {}, {}, 0
    for _, bucket in pairs(record ~= nil and record.creatures or {}) do
      -- An aggregate nobody could identify has no name to print, and its id is
      -- what the rest of the addon calls it by.
      local name = bucket.key.name or bucket.key:id()
      local entry = byName[name]
      if entry == nil then
        entry = { kills = 0, sizes = {}, order = {} }
        byName[name] = entry
        order[#order + 1] = name
      end
      -- `false` and not nil: the kills nobody counted are a population of their
      -- own (D84), and a nil would drop them out of the very list they belong in.
      local size = bucket.sharedBy or false
      if entry.sizes[size] == nil then
        entry.sizes[size] = 0
        entry.order[#entry.order + 1] = size
        populations = populations + 1
      end
      entry.sizes[size] = entry.sizes[size] + bucket.kills
      entry.kills = entry.kills + bucket.kills
    end

    if #order == 0 then
      logger:info("creature populations: none recorded for the level in progress")
      return
    end

    -- Most-killed first, so a population of one reads as thin beside something
    -- that had a real chance to accumulate; by name after that, so the same level
    -- prints the same report twice running.
    table.sort(order, function(a, b)
      if byName[a].kills ~= byName[b].kills then
        return byName[a].kills > byName[b].kills
      end
      return a < b
    end)

    logger:info(("creature populations: %d across %d creatures"):format(populations, #order))
    for _, name in ipairs(order) do
      local entry = byName[name]
      -- Smallest group first and the uncounted one last: it is what was recorded
      -- before this distinction existed, and it stops growing the moment this
      -- build runs, so it belongs at the end rather than in the middle.
      table.sort(entry.order, function(a, b)
        return (a or math.huge) < (b or math.huge)
      end)
      local parts = {}
      for _, size in ipairs(entry.order) do
        parts[#parts + 1] = size
          and ("%d shared by %d"):format(entry.sizes[size], size)
          or ("%d nobody counted"):format(entry.sizes[size])
      end
      logger:info(("  %s: %s"):format(name, table.concat(parts, ", ")))
    end
  end

  local function printDebug()
    logger:info(("flavor: %s"):format(Compat.flavor()))
    logger:info(("max level: %d"):format(Compat.maxLevel()))

    -- Which experience templates this client actually produced, and how often.
    -- A template at zero is as informative as one at a thousand: the research
    -- holds that the fatigue family never appears on either supported client,
    -- and this is what would show otherwise.
    local hits = eventRouter:templateHits()
    local names = {}
    for name in pairs(hits) do
      names[#names + 1] = name
    end
    table.sort(names)
    if #names == 0 then
      logger:info("xp templates seen: none yet")
    else
      for _, name in ipairs(names) do
        logger:info(("xp template %s: %d"):format(name, hits[name]))
      end
    end

    logger:info(("time sync: %s"):format(
      settings[SettingKey.TIME_SYNC] and "on" or "OFF (spike 0.6; levels will not be time-anchored)"))
    for _, entry in ipairs(capabilities:all()) do
      logger:info(("  capability %s: %s"):format(entry.name, entry.present and "present" or "absent"))
    end
    local missing = capabilities:missing()
    if #missing == 0 then
      logger:info("missing capabilities: none")
    else
      logger:info(("missing capabilities: %s"):format(table.concat(missing, ", ")))
    end

    -- Two states that look the same from outside and are not: the player left the
    -- bar where it was, and the player asked for the client's slot and the client
    -- had nothing to give. A diagnostic that printed one line for both would send
    -- someone looking for a bug in a setting that is working exactly as written.
    local chosenSlot = settings[SettingKey.BAR_SLOT]
    local effectiveSlot = clientXpBar:effectiveSlot(chosenSlot)
    if chosenSlot == effectiveSlot then
      logger:info(("slot: %s"):format(tostring(chosenSlot)))
    else
      logger:info(("slot: %s requested, %s in effect -- no client bar to take over")
        :format(tostring(chosenSlot), tostring(effectiveSlot)))
    end

    -- The names, and what is actually under them. Printed always rather than only
    -- when the bar is missing: a client where the slot works and a client where it
    -- works for a different reason are not the same answer, and spike 0.2 wants
    -- both flavours read the same way.
    for _, row in ipairs(clientXpBar:inventory()) do
      local mark = row.used and "  " or "  ? "
      local held = ""
      if row.quieted then
        held = (" -- quieted, gives back %s, reads %s"):format(
          tostring(row.givesBack), tostring(row.alphaNow))
      end
      -- Compared against the bar's own depth, printed just below: the two
      -- numbers are the whole answer to "who draws on top", and the bar painting
      -- over the client's frame is what that reads like when they are wrong.
      if row.strata ~= nil then
        held = (" [%s:%s]"):format(tostring(row.strata), tostring(row.level)) .. held
      end
      if row.present and row.width ~= nil then
        logger:info(("%s%s: %dx%d%s"):format(mark, row.name, row.width, row.height, held))
      elseif row.present then
        logger:info(("%s%s: there, no geometry"):format(mark, row.name))
      else
        logger:info(("%s%s: absent"):format(mark, row.name))
      end
    end

    -- The bar's own depth, in the same shape as the rows above so the two can be
    -- read side by side. Inset puts the bar one level UNDER its anchor so the
    -- client's frame art draws over it; replace puts it one over. A reading where
    -- those two do not line up is the bug the player photographed twice.
    if bar ~= nil and bar.depth ~= nil then
      local strata, level, wanted = bar:depth()
      if strata ~= nil then
        -- The level it asked for is printed only when the frame disagrees with
        -- it. Silence means the two match and the rule is the thing to look at;
        -- a second number means the client did not honour the first, which is a
        -- different problem with a different fix.
        local asked = ""
        if wanted ~= nil and wanted ~= level then
          asked = (" -- asked for %s"):format(tostring(wanted))
        end
        logger:info(("  AscentBar: [%s:%s]%s"):format(tostring(strata), tostring(level), asked))
      end
    end

    logger:info("attribution:")
    local snapshot = xpAttribution:diagnostics()
    for _, entry in ipairs(DIAGNOSTICS_LABELS) do
      local key, label = entry[1], entry[2]
      if snapshot[key] ~= nil then
        logger:info(("  %s: %d"):format(label, snapshot[key]))
      end
    end

    -- How often the client could not say where the character was. The design
    -- would not settle this by reasoning -- "con qué frecuencia el cliente sabe
    -- decir dónde está" is on the list of things only a real session answers --
    -- so it is counted here rather than supposed. The number that matters is the
    -- share, not the amount: a hundred unplaced experience means one thing in a
    -- level of two hundred and another in a level of twenty thousand.
    local record = tracker:current()
    if record ~= nil and record:hasPlaces() then
      -- Two numbers that are not the same one, and printing the ledger's total
      -- under the word "placed" let these two lines contradict each other in the
      -- same breath: "1000 of 1000 experience placed" directly above "with no
      -- place the client could name: 1000 (100%)". The reserved entry is a place
      -- to the ledger -- that is what keeps the two dimensions equal -- and the
      -- absence of one to a reader.
      local unplaced = record:xpAt(PlaceKey.unknown())
      local named = record:placedXp()
      local ledgered = record:sumOfPlaces()
      logger:info(("places: %d entries, %d of %d experience placed")
        :format(countKeys(record.places), named, ledgered))
      logger:info(("  with no place the client could name: %d (%d%%)")
        :format(unplaced, ledgered > 0 and math.floor(unplaced / ledgered * 100 + 0.5) or 0))
      -- Only when it has something to say: the place dimension is supposed to
      -- equal the source dimension, so a difference is a bug, not a statistic.
      if ledgered ~= record.xpTotal then
        logger:info(("  the level holds %d, which the places do not add up to")
          :format(record.xpTotal))
      end
    else
      logger:info("places: none recorded for the level in progress")
    end

    printGroupDebug()

    -- Everything the diagnostic knows, in one command. There used to be three of
    -- them and no reason for it: a player chasing one number had to know which
    -- of the three held it, and the two extra ones existed only because they
    -- were written at different times.
    printQuestDebug()
    dumpStrings()
  end

  -- THE ONLY CHANNEL BACK.
  --
  -- No addon can make a network request, so there is no telemetry in this one
  -- and there cannot be: everything the author will ever learn about how it
  -- behaves on someone else's machine is what that player chooses to send. The
  -- diagnostics above were already written; this runs them with their output
  -- diverted into a table (ChatLogger:capture) and puts the result in a window
  -- whose text can be selected. One generator, two destinations.
  local copyDialog

  -- What makes a pasted report worth reading. Without the build and the flavour
  -- a report is a column of numbers with nothing to compare it against, and the
  -- level is what makes the experience figures mean anything. Not the character
  -- name and not the realm: a report is going somewhere public.
  local function reportHeader()
    local environment = evidenceEnvironment()
    return {
      { "addon", ("%s %s"):format(ADDON_NAME, tostring(environment.addonVersion)) },
      { "client", ("%s, max level %s"):format(tostring(environment.flavor), tostring(environment.maxLevel)) },
      { "locale", tostring(environment.locale) },
      { "character", ("level %s"):format(tostring(playerState:level())) },
    }
  end

  -- Built on first use: a player who never opens either window never pays a frame
  -- for one, and a client that cannot build it costs the window rather than the
  -- addon. Shared by the report and the changelog so there is one window, one
  -- failure path, and one place that knows how to recover.
  local function openWindow(text)
    if copyDialog == nil then
      local ok, built = pcall(CopyDialog.new, { locale = locale, settings = settings })
      if not ok then
        logger:warn(locale:get(TextKey.ERR_UI_FAILED, tostring(built)))
        return false
      end
      copyDialog = built
    end

    copyDialog:show(text)
    return true
  end

  -- The flight recorder's switch. A SUBCOMMAND of debug rather than a command of
  -- its own: `/ascent debug` is where everything the addon knows about itself
  -- lives, and a player chasing one thing should not have to know which of two
  -- top-level words holds it -- the same reason the three diagnostic dumps were
  -- folded into one.
  --
  -- What it is NOT is a second debug mode. Debug prints to chat, which is fine
  -- for a two-minute check; this writes to the saved variables file and is meant
  -- to be left on for a whole levelling session without being noticed.
  local function handleEvidence(sub)
    sub = sub:lower()
    if sub == "on" then
      saveSetting(SettingKey.EVIDENCE, true)
      -- Starts recording now rather than next session, and attaches to the
      -- store so what it records is already in the file at logout.
      evidence:enable(true)
      AscentCharDB = AscentCharDB or {}
      evidence:attachTo(AscentCharDB, evidenceEnvironment())
      logger:info(locale:get(TextKey.CMD_EVIDENCE_ON))
    elseif sub == "off" then
      saveSetting(SettingKey.EVIDENCE, false)
      evidence:enable(false)
      logger:info(locale:get(TextKey.CMD_EVIDENCE_OFF))
    elseif sub == "reset" then
      evidence:reset()
      logger:info(locale:get(TextKey.CMD_EVIDENCE_RESET))
    else
      logger:info(locale:get(TextKey.CMD_EVIDENCE_STATUS, evidence:summary()))
    end
  end

  local COPY_SECTIONS = {
    debug = printDebug,
    summary = printSummary,
    pending = printPending,
  }
  local COPY_CHOICES = "debug, summary, pending"

  local function handleCopy(rest)
    local which = rest:lower()
    if which == "" then
      -- The one a bug report wants. The other two are for a player who is
      -- reporting a number rather than a fault.
      which = "debug"
    end

    local printer = COPY_SECTIONS[which]
    if printer == nil then
      logger:info(locale:get(TextKey.CMD_BAD_COPY, COPY_CHOICES))
      return
    end

    local lines = logger:capture(printer)

    if not openWindow(CopyReport.build({ header = reportHeader(), lines = lines })) then
      -- The report was captured instead of printed, so without this the
      -- diagnostics would vanish into a window that does not exist. Chat is
      -- where they went before this command, and it is where they go now.
      for _, line in ipairs(lines) do
        logger:info(line)
      end
    end
  end

  -- What changed, version by version, in the window that already knows how to
  -- show text (design D71). The entries are generated from CHANGELOG.md at build
  -- time, so this never parses markdown on a player's machine -- and a build
  -- carrying none says so rather than opening empty.
  local function handleChangelog()
    local text = ns.core.ChangelogText.build(ns.core.CHANGELOG, addonVersion)
    if text == nil then
      logger:info(locale:get(TextKey.CHANGELOG_MISSING))
      return
    end

    local header = ("%s\n%s\n"):format(
      locale:get(TextKey.CHANGELOG_HEADER),
      locale:get(TextKey.CHANGELOG_RUNNING, tostring(addonVersion)))

    if not openWindow(header .. "\n" .. text) then
      -- No window, so the one thing worth saying goes to chat: which build this
      -- is. The whole changelog there would be a wall nobody can scroll back to.
      logger:info(locale:get(TextKey.CHANGELOG_RUNNING, tostring(addonVersion)))
    end
  end

  -- The same door, opened from the options panel (which is built further down,
  -- from this table). Assigned here rather than declared up with the rest of the
  -- context because `handleCopy` is a local defined just above: a closure written
  -- at line 919 would have captured a global nil instead.
  context.copyReport = function() handleCopy("") end
  -- Applied live, in both directions: the watch stops counting reports AND the
  -- channel stops announcing, because `announce` asks the same object whether it
  -- speaks at all (design D74).
  context.setUpdateCheck = function(enabled) updateWatch:enable(enabled) end

  SLASH_ASCENT1 = "/ascent"
  -- The commands that cannot do anything without a frame. Everything else --
  -- the summary, the pending report, the diagnostics, the data wipe -- works
  -- perfectly well with no views at all, and keeping them alive is the point of
  -- isolating the failure in the first place.
  local NEEDS_VIEWS = {
    show = true, hide = true, panel = true, demo = true, options = true,
  }

  SlashCmdList["ASCENT"] = function(msg)
    local command, rest = splitFirst(msg)
    command = command:lower()

    if NEEDS_VIEWS[command] and (bar == nil or panel == nil) then
      logger:warn(locale:get(TextKey.ERR_NO_UI))
      return
    end

    if command == "" or command == "help" then
      printHelp()
    elseif command == "show" then
      userHidden = false
      bar.frame:Show()
    elseif command == "hide" then
      userHidden = true
      bar.frame:Hide()
    elseif command == "panel" then
      panel:toggle()
    elseif command == "summary" then
      printSummary()
    elseif command == "pending" then
      printPending()
    elseif command == "options" then
      handleOptions(rest)
    elseif command == "reset" then
      handleReset(rest)
    elseif command == "copy" then
      handleCopy(rest)
    elseif command == "changelog" then
      handleChangelog()
    elseif command == "demo" then
      local sub = rest:lower()
      if sub == "off" or sub == "stop" then
        demo:stop()
      else
        demo:step()
      end
    elseif command == "debug" then
      local sub, arg = splitFirst(rest)
      sub = sub:lower()
      if sub == "evidence" then
        handleEvidence(arg)
      elseif sub == "timesync" then
        -- Spike 0.6's lever, and the only way to ask its question: the request
        -- fires from PLAYER_ENTERING_WORLD, during the loading screen, so
        -- suppressing it has to be decided before the session starts. It takes
        -- effect on the next login, and `printDebug` reports the state so a player
        -- who set it and forgot has somewhere to find out.
        local wanted = arg:lower()
        if wanted == "on" or wanted == "off" then
          saveSetting(SettingKey.TIME_SYNC, wanted == "on")
          logger:info(("time sync: %s (takes effect on the next login)"):format(wanted))
        else
          logger:warn(locale:get(TextKey.CMD_BAD_ON_OFF, arg))
        end
      else
        printDebug()
      end
    else
      logger:warn(locale:get(TextKey.CMD_UNKNOWN, command))
      printHelp()
    end
  end

  -- ---------------------------------------------------------------------------
  -- 12.7: the Interface > AddOns options panel.
  -- ---------------------------------------------------------------------------

  -- Built last, after everything it reads from and writes through (bar,
  -- saveSetting, settings) already exists on `context`. Kept on `context`
  -- itself, not a separate upvalue, so handleOptions' "panel" branch above --
  -- defined earlier in this same function, before this line runs -- can reach
  -- it too.
  -- Built only when there is a bar for its controls to drive. Its own failure is
  -- reported the same way, and separately: losing the options panel must not cost
  -- the commands, which are the way back when the interface is unusable.
  if bar ~= nil then
    local optionsOk, optionsError = pcall(OptionsPanel.new, context)
    if optionsOk then
      -- A list of pages now, parent first. The context keeps both: the pages to
      -- register, and the parent frame for everything that just wants "the
      -- options panel" -- opening it, refreshing it.
      context.optionsPages = optionsError
      context.optionsPanel = optionsError[1].frame
      optionsPanel = context.optionsPanel
    else
      logger:warn(locale:get(TextKey.ERR_UI_FAILED, tostring(optionsError)))
    end
  end
  if context.optionsPages ~= nil then
    context.optionsCategory = registerOptionsPanel(context.optionsPages)
    optionsCategory = context.optionsCategory
  end

  -- WHAT CHANGED SINCE THE LAST SESSION. Last, so a session that had trouble
  -- building its interface has already said so before this speaks.
  --
  -- The downgrade line is the only sentence in this addon that explains something
  -- which ALREADY happened and was never reported: a history written by a newer
  -- build cannot be migrated backwards, so RecordStore sets it aside on load
  -- (core/service/RecordStore.lua). Until now the player just found it missing.
  local lastSeen = settings[SettingKey.LAST_SEEN_VERSION]
  local since = ns.core.UpdateWatch.compareSeen(lastSeen, addonVersion)

  if since == "updated" then
    logger:info(locale:get(TextKey.UPDATE_INSTALLED, tostring(addonVersion)))
  elseif since == "downgraded" then
    logger:info(locale:get(TextKey.UPDATE_DOWNGRADED,
      tostring(addonVersion), tostring(lastSeen), tostring(lastSeen)))
  end

  -- A first install remembers the version without announcing itself as an update.
  if since ~= "same" then
    saveSetting(SettingKey.LAST_SEEN_VERSION, addonVersion)
  end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent(WowEvent.ADDON_LOADED)
loader:SetScript("OnEvent", function(_, _, loadedAddon)
  if loadedAddon ~= ADDON_NAME then
    return
  end
  loader:UnregisterAllEvents()
  buildContext()
end)
