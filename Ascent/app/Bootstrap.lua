-- Ascent - the composition root.
--
-- The only place that sees core/, adapter/ and ui/ at once, and where each
-- port's real implementation meets the port. It runs once, on ADDON_LOADED for
-- this addon's name: SavedVariables are empty before that event, and reading
-- them earlier would make every character look freshly installed.
--
-- The build order below is the dependency graph (the bus's error handler needs
-- the logger, the bar's saveSetting needs the bar); out of order is a nil
-- reference. Constructors are not wrapped in pcall, since Port.verify and the
-- option checks already throw with the module's name. The views are the
-- exception: with scriptErrors off, the client's default, a throw while a view
-- runs CreateFrame is silent, and the slash commands are registered after the
-- views. So the views go through pcall, the error is reported through the
-- logger, and everything downstream guards against a missing view: the addon
-- keeps recording, keeps answering commands, and says what broke.

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
-- Further modules, such as the update check, are reached through `ns` at the
-- point of use rather than through a file-local alias like the lines above.
-- Lua 5.1 allows a function 60 upvalues and buildContext, which is most of this
-- file, spends all 60: every file-local above is one of them, so there is no
-- dead alias to reclaim. One more alias used in there fails to compile at load
-- time ("has more than 60 upvalues"), and LuaJIT blames the line of
-- buildContext's `end`, not the alias. `ns` is already one of the 60, so
-- `ns.core.X` at the point of use is free.

local LocaleTable = ns.locale.LocaleTable

ns.app = ns.app or {}

-- Text keys for the /ascent summary breakdown. app/ keeps its own table rather
-- than reaching into ui/ for XpBarView's SOURCE_LABEL, which also carries the
-- colours this does not need. Both tables name the same four keys, so the two
-- surfaces cannot drift apart in wording.
local SOURCE_NAME = {
  [XpSource.MOB_KILL] = TextKey.SOURCE_CREATURES,
  [XpSource.QUEST_TURNIN] = TextKey.SOURCE_QUESTS,
  [XpSource.EXPLORATION] = TextKey.SOURCE_EXPLORATION,
  [XpSource.UNKNOWN] = TextKey.SOURCE_UNCLASSIFIED,
}

-- Splits a slash command's message into its first token and everything after it,
-- both trimmed. Used for `/ascent <command> <rest>` and, inside the options
-- handler, for `<sub> <arg>`.
local function splitFirst(text)
  local head, tail = (text or ""):match("^%s*(%S*)%s*(.-)%s*$")
  return head or "", tail or ""
end

-- Registers the addon's pages against whichever options system the client has:
-- the first page is the category in the AddOns list and the rest its children,
-- the shape other addons in that list use. Recent Classic Era and Burning
-- Crusade Classic builds run the Settings canvas system, which replaces
-- InterfaceOptionsFrame, so a panel registered only the legacy way never appears
-- under Interface > AddOns. The modern path is tried first, the legacy one only
-- when Settings is absent.
--
-- Always `_G.Settings`, never the bare name: the file-local `Settings` is
-- ns.core.Settings, which shadows the client global and has no
-- RegisterCanvasLayoutCategory, so the bare name would always take the legacy
-- path whatever the client has.
local function registerOptionsPanel(pages)
  local parentPage = pages[1]
  local wowSettings = _G.Settings
  if wowSettings ~= nil and wowSettings.RegisterCanvasLayoutCategory ~= nil
    and wowSettings.RegisterAddOnCategory ~= nil then
    local category = wowSettings.RegisterCanvasLayoutCategory(parentPage.frame, parentPage.frame.name)
    wowSettings.RegisterAddOnCategory(category)
    -- Subcategories when the client has them. Without that function the children
    -- do not appear (one page of settings rather than six): a worse panel, not a
    -- broken addon.
    if wowSettings.RegisterCanvasLayoutSubcategory ~= nil then
      for index = 2, #pages do
        wowSettings.RegisterCanvasLayoutSubcategory(category, pages[index].frame, pages[index].frame.name)
      end
    end
    return category
  end
  -- Checked because InterfaceOptions_AddCategory is absent from Burning Crusade
  -- Classic 2.5.6: a client may have neither system, and calling a missing global
  -- here fails during initialisation, where it costs the most.
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
  -- The legacy Interface Options frame does not reliably select the category the
  -- first time it opens in a session; calling this twice in a row is the usual
  -- workaround. Only reached when the modern path above is absent.
  if type(_G.InterfaceOptionsFrame_OpenToCategory) == "function" then
    _G.InterfaceOptionsFrame_OpenToCategory(panel)
    _G.InterfaceOptionsFrame_OpenToCategory(panel)
  end
end

local function buildContext()
  -- ---------------------------------------------------------------------------
  -- Construction, in dependency order.
  -- ---------------------------------------------------------------------------

  local repository = SavedVariablesRepository.new()
  local store = RecordStore.new({ repository = repository }):load()
  local settings = Settings.resolve(repository:settings())

  local clock = WowClock.new()
  local playerState = WowPlayerState.new()

  local logger = ChatLogger.new({ debug = settings[SettingKey.DEBUG] })

  -- The client's language cannot change mid-session, so LocaleTable resolves it
  -- once from GetLocale. Diagnostic mode can, so it arrives as a function rather
  -- than the boolean read a line above: a key with no text must show itself the
  -- moment the player turns debug on, not after the next reload.
  local locale = LocaleTable.new({ isDebug = function() return logger:isDebug() end })

  -- The bus already isolates a failing handler (core/service/EventBus.lua); this
  -- onError only tells the player. logger:warn dedupes by exact text, so a
  -- handler failing on every event does not spam the chat frame.
  local bus = EventBus.new(function(topic, err)
    logger:warn(locale:get(TextKey.CMD_HANDLER_FAILED, tostring(topic), tostring(err)))
  end)

  local registry = ClassifierRegistry.new()
  XpClassifiers.registerAll(registry)

  local correlator = KillCorrelator.new({ logger = logger })

  -- XpAttribution subscribes itself to the bus in its constructor. Kept in a
  -- local so the context below can expose it.
  local xpAttribution = XpAttribution.new({ bus = bus, registry = registry, correlator = correlator, logger = logger })

  local tracker = LevelTracker.new({
    bus = bus, clock = clock, playerState = playerState, store = store, settings = settings, logger = logger,
  })

  -- Experience gained since the client started, which is what "session" means
  -- here. No LevelRecord can answer it, because a session spans whatever levels
  -- the player crosses in one sitting.
  local sessionXpTracker = SessionXpTracker.new({ bus = bus })

  -- Registering a collector never touches the tracker. None of the six is gated
  -- by client flavour: ability usage, combat outcome, deaths, time, place and
  -- damage read the same client API on Classic Era and Burning Crusade Classic,
  -- so all of them register unconditionally.
  --
  -- `recordingLevel`, not tracker:current(): current() can be non-nil while
  -- tracker:isRecording() is false, because experience gain switched off
  -- mid-session leaves the record open but frozen. LevelTracker's onAttributed
  -- gates on isRecording(); without the same gate here, combat metrics would keep
  -- accruing onto a level whose playedSeconds and xpTotal have stopped, breaking
  -- the invariant "combat + out-of-combat = played". CombatAggregator's dispatch
  -- and the per-tick sampling both read this, so neither path can drift.
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
  -- The `enabled` closure reads `settings` live (the upvalue saveSetting
  -- reassigns below), so toggling "collect damage data" takes effect at once,
  -- with no rebuild of the collector or the registry.
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

  -- A source closing mid-session, which the two routers below are the ones to
  -- see and the capability registry further down is the one to be told.
  -- Declared here because the routers are built first, and assigned once the
  -- registry exists: a closure cannot reach a local declared after it.
  local sourceClosed

  -- Kept in a local for its template-hit counter, which the diagnostic prints:
  -- it shows whether the group figure is already inside the credited total.
  local eventRouter = WowEventRouter.new({
    bus = bus, clock = clock, playerState = playerState, logger = logger,
    onUnreadable = function() sourceClosed(ns.core.RecordedSource.XP_CHAT) end,
  })
  eventRouter:start()

  -- The flight recorder (app/EvidenceLog.lua), subscribed before anything else
  -- publishes, so a session records from its first event rather than from
  -- whenever the rest of the wiring finished.
  --
  -- The environment goes in with it: which client, which language, and which
  -- experience templates this client carries. Samples without it cannot be
  -- interpreted away from the machine they came from.
  local evidence = EvidenceLog.new({
    bus = bus, clock = clock, playerState = playerState,
    enabled = settings[SettingKey.EVIDENCE],
  })
  -- The addon's version, read once, through whichever accessor this client has
  -- (C_AddOns.GetAddOnMetadata or the older global). The evidence file, the
  -- report header and the update check all read this one value, so a build
  -- cannot report one version and compare another. "unknown" rather than nil:
  -- it is printed, and must never read as a blank.
  local addonVersion = (C_AddOns ~= nil and C_AddOns.GetAddOnMetadata ~= nil
    and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
    or (GetAddOnMetadata ~= nil and GetAddOnMetadata(ADDON_NAME, "Version"))
    or "unknown"

  -- In one place because two paths need the same environment: startup, and the
  -- chat command that switches recording on mid-session.
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

  -- The entry point into the recorder for facts the bus does not carry. They go
  -- to the file, not through the logger: its 500-line chat ring, shared with
  -- about three lines per kill, is overwritten long before a session ends.
  local function recordEvidence(kind, fields)
    evidence:record(kind, fields)
  end

  CombatLogRouter.new({ bus = bus, clock = clock, playerState = playerState, logger = logger,
    recordEvidence = recordEvidence,
    onUnreadable = function() sourceClosed(ns.core.RecordedSource.COMBAT_LOG) end,
  }):start()
  TimePlayedSync.new({
    bus = bus, clock = clock, logger = logger,
    recordEvidence = recordEvidence,
    -- Switchable so a session can observe whether the server sends time played
    -- unprompted, which cannot be seen while the addon requests it on entering
    -- the world. Read here, not later, because the request fires during the
    -- loading screen.
    requests = settings[SettingKey.TIME_SYNC],
  }):start()

  local scheduler = RedrawScheduler.new({ clock = clock })

  local questLogReader = QuestLogReader.new()

  -- The client's own experience bar, as a place to stand and as something to
  -- quiet. Declared before the registry because register() runs its probe at
  -- once, so a probe that closes over this needs it to exist.
  local clientXpBar = ClientXpBar.new()

  -- One probe per client function this addon forks on. An empty registry would
  -- report `capabilities:missing()` as empty, the same as a healthy client.
  --
  -- `_G.Settings` is spelled out: the file-local `Settings` is the addon's own
  -- settings module, and it shadows the client global.
  local capabilities = Capabilities.new()
  capabilities:register("creature_level", function() return UnitTokenFromGUID ~= nil end)
  capabilities:register("map_position", function()
    return C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil
  end)
  capabilities:register("quest_reward_on_turn_in", function() return GetQuestLogRewardXP ~= nil end)
  -- Absent when another addon has replaced the main bar, and on any client whose
  -- bar is not where this one looks. The slot setting then stays on disk and
  -- does not take effect.
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
  -- The addon channel. Without it the addon loses only the news that somebody
  -- nearby runs a newer build, and keeps the changelog, the upgrade notice and
  -- everything else. Named here so the diagnostic can say it was off.
  capabilities:register("addon_messages", function() return ns.adapter.VersionChannel.isSupported() end)
  -- Absent when the player has nameplates switched off. A pull is then built from
  -- the combat log alone, which sees every creature that has touched the player
  -- and none of those still running at them.
  capabilities:register("nameplates", function() return ns.adapter.NameplateWatch.isSupported() end)

  -- The sources the whole addon hangs from. The probes above are about one
  -- feature each; these say what Ascent does on this client, registered together
  -- because that answer is this list, not a flavour name. Each can be absent (the
  -- client does not have it) or unreadable (it has it and will not let an addon
  -- read what it returns, as the 12.0 engine of World of Warcraft: Forever
  -- does), which is why a capability carries a reason.
  --
  -- The combat log, which every combat metric hangs from and nothing else does.
  -- Only a fight shows whether its lines are readable, so the probe reports
  -- unreadable only when handed something it may not read, never from the
  -- client's name.
  capabilities:register(ns.core.RecordedSource.COMBAT_LOG, function() return CombatLogRouter.isSupported() end)
  -- The chat channel that names where a gain came from. Without it the addon
  -- still sees the experience (PLAYER_XP_UPDATE is a separate source) but cannot
  -- say what paid it: the level still adds up, and every unnamed point is
  -- unclassified rather than guessed at.
  capabilities:register(ns.core.RecordedSource.XP_CHAT, function() return WowEventRouter.isXpChatSupported() end)
  -- The quest log, whichever way this client lets it be read. Absent means the
  -- pending tab has nothing to forecast from, not that nothing is pending.
  capabilities:register("quest_log", function() return QuestLogReader.isSupported() end)

  -- What a level remembers about the sources it was recorded without. Two
  -- moments mark it: the level opening or resuming while a source is already off
  -- (on World of Warcraft: Forever, the combat log from the first minute), and a
  -- source closing while the level is recorded. The views read the mark off the
  -- record, not off this registry, because a level may be read later, on a
  -- client that has the source.
  bus:subscribe(EventTopic.LEVEL_STARTED, function(payload)
    for _, source in Frozen.each(ns.core.RecordedSource) do
      if not capabilities:has(source) then
        payload.record:markUnavailable(source, capabilities:reasonFor(source))
      end
    end
  end)
  sourceClosed = function(source)
    if not capabilities:degrade(source, Capabilities.Reason.UNREADABLE) then
      return
    end
    local record = tracker:current()
    if record ~= nil then
      record:markUnavailable(source, Capabilities.Reason.UNREADABLE)
    end
    -- Rare by construction (once per source per session), so it is kept whole
    -- rather than only counted.
    recordEvidence("sourceClosed", { source = source, at = clock:now() })
    logger:debug(("source closed mid-session: %s"):format(source))
  end

  -- The version check. An addon cannot query a server, so the only source for
  -- "is there something newer" is the players around this one. Three pieces, and
  -- only the last touches the client: what is newer and who said so, how often
  -- this addon may speak, and the channel.
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
  -- one. It is fed here, from both places a client says a name (the log sweep
  -- just below and the quest dialogue further down), rather than by the services
  -- those two feed, so neither carries a string it does not use to a screen it
  -- does not know about.
  local questNames = QuestNames.new({ repository = repository })

  -- The only way this addon reads the quest log, so a title cannot be read and
  -- thrown away by one caller while another keeps it: the sweep reads a title
  -- for every accepted quest and the forecast service has no use for one. It
  -- also makes naming retroactive: a quest is named when it is accepted, so by
  -- the time it is handed in, and for every later level report, it is known.
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

  -- Experience pending from the quest log. `scan` is a plain function rather
  -- than the reader itself, for the reason LevelTracker takes `xpForLevel` as a
  -- function: core/ must never hold a reference typed by adapter/.
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
      -- The calibration record, not just its side effect, so a session's file
      -- can compare what turn-ins paid with what the forecast showed at the time.
      recordEvidence("questCalibration", questForecastService:calibrate(payload.questId, payload.xpReward))
    end
  end)
  -- The reward the quest dialogue shows, learned before the quest is turned in.
  bus:subscribe(EventTopic.QUEST_REWARD_SEEN, function(payload)
    questForecastService:learn(payload.questId, payload.reward)
    -- The dialogue's own title, which is the only way to name a quest that was
    -- accepted and handed in without a sweep in between.
    questNames:remember(payload.questId, payload.title)
  end)

  -- Forward-declared: redraw() has to ask whether the demo is running, and the
  -- demo cannot exist until the bar it drives does.
  local demo

  -- Forward-declared because saveSetting closes over the views and is written
  -- before any of them is built. optionsCategory rides along because the report
  -- panel's shortcut into the settings closes over it and optionsPanel, and that
  -- panel is built long before the options register themselves.
  local bar, panel, optionsPanel, optionsCategory, plate

  -- The pull plate's recorder, built outside the views' pcall: it is pure domain
  -- and cannot fail on a client quirk, and a session whose frames failed to
  -- build should still record pulls, as it still records levels.
  --
  -- `enabled` is read live rather than captured, so turning the plate off stops
  -- the recording on the same tick instead of after a reload.
  local pullTracker = PullTracker.new({
    bus = bus,
    clock = clock,
    enabled = function() return settings[SettingKey.PLATE_ENABLED] end,
    -- A pull can be carried on for exactly as long as the player can still see
    -- it. Derived rather than restated, so the offer the plate makes and the
    -- window the tracker honours cannot disagree.
    --
    -- A function, not the number, because the hold time is a player setting: a
    -- captured value would change what is drawn but not what counts as the same
    -- fight until the next /reload (the gap RECOVERY_THRESHOLD still has).
    resumeSeconds = function()
      return settings[SettingKey.PLATE_HOLD_SECONDS] + PullPlateView.FADE_SECONDS
    end,
  })

  -- A pull that never happened, for looking at the plate without finding
  -- something to kill. It stands in for the tracker rather than publishing on
  -- the bus: the topics a real pull rides on also feed the level's collectors
  -- and the experience ledger, so publishing them would write a fictional fight
  -- into the player's level record. The stand-in answers only what the plate
  -- asks (which pull, what phase, which generation).
  local plateDemo

  local function startPlateDemo()
    local pull = PullRecord.new(clock:now())
    plateDemo = {
      pull = pull,
      phase = PullPhase.ACTIVE,
      -- The script, in seconds from the start, written as data so its shape
      -- reads at a glance. Engagements come first so the demo shows two
      -- creatures pulled, both still standing and nothing dead; a script that
      -- opened with a kill would skip that state.
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
      -- Two beats past the last one, so the settling state, a real state of a
      -- real pull, stays on screen long enough to be read.
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

  -- Called from everywhere the answer could change: after the views exist, on
  -- every settings change, and on entering the world, which is both the first
  -- moment the client's bar is real and the moment after a loading screen when
  -- the client has redone whatever it does to its own bar.
  --
  -- Idempotent (ClientXpBar:applyQuiet converges), so a repeat call costs a
  -- table walk over four names and never records its own silence as the state
  -- to give back later.
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

  -- Whether the player hid the bar with `/ascent hide`. draw() in
  -- ui/XpBarView.lua shows the frame whenever it has something to draw, so
  -- without this the next redraw (any gain, rest change, anything on the topic
  -- list below) would undo the command. redraw() is the one place that honours it.
  local userHidden = false

  -- The bar's persistence callback (see ui/XpBarView.lua's header), and the
  -- hot-apply path: it re-resolves `settings` and pushes the new table into the
  -- views, which captured a copy at construction and cannot notice a change.
  --
  -- COLLECT_DAMAGE hot-applies without this function: DamageCollector's
  -- `enabled` closure reads the `settings` upvalue this reassigns.
  -- RECOVERY_THRESHOLD is the one construction-time-only setting:
  -- CombatTimeCollector.new stores it as a plain value, so changing it takes a
  -- reload.
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
    -- position to re-derive from the new table, and does it without rebuilding
    -- a frame (ui/XpBarView.lua), so a change applies with no reload.
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
      -- The whole table, so the view sees the settings this function just
      -- resolved. The plate follows the bar's skin rather than carrying its
      -- own, so the two surfaces never wear different skins.
      plate:applySettings(settings)
      if not settings[SettingKey.PLATE_ENABLED] then
        plate:hide()
        pullTracker:reset()
      end
    end
    -- The options panel too: it holds a control per setting, each showing a value
    -- that may just have changed. Guarded because it is built last and may not
    -- exist at all.
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

    -- The level report panel. `recordingLevel` (above) is the right indirection
    -- here too: the panel has no more business knowing isRecording()'s gate than
    -- the combat collectors do. Wired to the bar's click-to-toggle after both
    -- exist: XpBarView keeps `onToggle` as a plain field on `self`, read at click
    -- time, so assigning it here is simpler than reordering either constructor.
    panel = ReportPanelView.new({
      settings = settings, saveSetting = saveSetting, currentRecord = recordingLevel,
      questForecastService = questForecastService, questNames = questNames, locale = locale,
      -- How many are sharing the pay right now. The domain cannot ask the client,
      -- so the question crosses here through the port, like every other reading
      -- of the character's state, and is asked on each rebuild because the answer
      -- changes the moment the player joins or leaves a group.
      sharedBy = function() return playerState:sharedBy() end,
      -- The history seams. Functions rather than the store itself, for the same
      -- reason `currentRecord` is one: the view asks a question and gets an
      -- answer, and never learns that a RecordStore exists.
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
      -- Resolved at click time: the options panel registers itself much further
      -- down this function, so a value captured here would be nil for the whole
      -- session. The same two fields `/ascent options panel` reads.
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
      -- Read-only, for one purpose: KillXpEstimator needs this level's
      -- per-creature history to price what is still standing. The same
      -- `recordingLevel` indirection the panel and the collectors use.
      levelRecord = recordingLevel,
      -- The other half of what the forecast needs: which population to price it
      -- from. Same seam, same reason as the panel's.
      sharedBy = function() return playerState:sharedBy() end,
      -- What the level still needs, asked fresh on every draw. nil when no level
      -- is open, which the plate reads as "nothing to say" rather than as zero.
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

  -- The one place that repaints the bar, so every caller gets `userHidden`
  -- honoured. unattributedXp is what XpAttribution has confirmed from the client
  -- but not yet settled into a source; passing it lets the bar's total and
  -- percent move at once instead of lagging behind the settling window.
  local function redraw()
    -- No views this session (see the pcall above): nothing to paint.
    if bar == nil then
      return
    end
    -- The demo owns the bar while it is on: otherwise the next 5 Hz tick would
    -- paint the player's real level over the demo state (app/DemoDriver.lua).
    if demo ~= nil and demo:isActive() then
      return
    end

    local restedXp = playerState:restedXp()
    -- Pace and projections, computed fresh on every redraw from the record's
    -- live numbers. Nothing here is persisted, so nothing has to be kept in sync.
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
      -- "Time this session" (see XpBarView.buildTextValues) is the session
      -- clock, time since the client started, which SessionXpTracker's pace is
      -- also measured against.
      sessionTime = clock:now(),
      -- Everything accepted, not only what is ready to turn in: the pending
      -- channel projects what the whole quest log will pay.
      questPending = questForecastService:report().total,
    })
    if userHidden then
      bar.frame:Hide()
    end
  end

  for _, topic in ipairs({
    EventTopic.RECORD_UPDATED, EventTopic.REST_CHANGED, EventTopic.XP_STATE_CHANGED,
    EventTopic.LEVEL_STARTED, EventTopic.LEVEL_COMPLETED,
    -- A raw delta marks the scheduler dirty before it settles (~3 s later, into
    -- RECORD_UPDATED): xpAttribution:pendingAmount() is non-zero only in that
    -- window, and without this topic the bar would jump from the old total to
    -- the final one without showing the provisional state.
    EventTopic.XP_DELTA_OBSERVED,
  }) do
    bus:subscribe(topic, function()
      scheduler:markDirty()
      if panel ~= nil then
        panel:markDirty()
      end
    end)
  end

  -- XpAttribution:settle() otherwise runs only on intake (a delta, a hint, a
  -- death), so the timer below settles a lone delta with nothing after it, such
  -- as the last gain of a farming session; without it that gain would stay
  -- provisional instead of resolving to its source or to UNKNOWN. Once a second
  -- is well under the ~4.5 s settling window (3x the 1.5 s default), and costs
  -- nothing the 5 Hz redraw cap does not already pay for.
  local lastSettleAt = nil
  local lastObserveAt = nil
  local lastQuestScanAt = nil
  local lastSweepAt = nil
  local nameplateWatch = ns.adapter.NameplateWatch.new({
    bus = bus, recordEvidence = recordEvidence,
  }):start()

  local ticker = CreateFrame("Frame")
  ticker:SetScript("OnUpdate", function(_, elapsed)
    -- The presentation clock, inside this OnUpdate rather than a second script:
    -- this frame is already paid for. The call returns at once when the bar has
    -- arrived and nothing is flashing, so a bar at rest costs a comparison.
    if bar ~= nil then
      bar:tick(elapsed)
    end

    local now = clock:now()

    -- The pull plate, on the same frame clock: its counters interpolate and its
    -- finished plaque fades per frame, and neither is worth a second OnUpdate.
    --
    -- Three calls in a fixed order: tick the tracker so a settled pull closes,
    -- redraw only if something changed, then advance whatever the redraw left in
    -- motion. Redrawing unconditionally would rebuild a view-model sixty times a
    -- second during a fight whose numbers changed twice.
    pullTracker:tick(now)
    -- Nameplates: what was pulled and has not reached the player yet. The sweep
    -- runs outside pulls too, because it has to see a creature before the combat
    -- log does: one charging a shielded player writes nothing the client calls
    -- damage. The rate keeps the frame budget: four times a second inside a
    -- fight, where the answer changes, once a second outside one, still faster
    -- than anything can cross the ground to the player.
    local sweepEvery = pullTracker:current() ~= nil and 0.25 or 1
    if lastSweepAt == nil or now - lastSweepAt >= sweepEvery then
      lastSweepAt = now
      nameplateWatch:sweep()
    end
    if plate ~= nil then
      if plateDemo ~= nil then
        -- The demo owns the plate while it runs, as DemoDriver owns the bar:
        -- otherwise the next real change would paint a live pull over it.
        if not plateDemo:advance(now) then
          plateDemo = nil
          plate:hide()
        else
          plate:follow(plateDemo, now)
        end
      elseif pullTracker:consumeChange() then
        -- What the plate is handed, so the file can say whether a pull existed,
        -- what phase it was in and what the view was asked to draw, not only
        -- that a creature enrolled. Only on a change, which consumeChange
        -- throttles, and in a counter-only family so it cannot crowd the ring.
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
    -- CombatTimeCollector's recovery sampling, on its own 5 Hz throttle rather
    -- than scheduler:tick(), which fires only when something is dirty: a player
    -- standing still to recover triggers no bus event at all.
    if lastObserveAt == nil or now - lastObserveAt >= 0.2 then
      lastObserveAt = now
      combatTimeCollector:observe(recordingLevel(), playerState:healthFraction(), playerState:powerFraction())
      -- The place is sampled on the same tick for the same reason: the client
      -- fires no event for "the character is somewhere else now", and the time a
      -- place cost is the denominator of every rate the panel shows for it. The
      -- collector rebuilds its key only when the answer changes, so a tick that
      -- finds the character where it was costs two comparisons.
      placeTimeCollector:observe(recordingLevel(), playerState:place())
    end
    -- The quest forecast's cadence, on its own throttle for the same reason:
    -- QUEST_LOG_CHANGED marks this service dirty independently of the bar's
    -- scheduler, and accepting a quest with no experience gain must not wait
    -- for one.
    if lastQuestScanAt == nil or now - lastQuestScanAt >= 0.2 then
      lastQuestScanAt = now
      if questForecastService:tick() then
        -- A fresh forecast changes the bar's pending channel and the panel's
        -- pending tab, neither of which QUEST_LOG_CHANGED marks dirty: that
        -- topic only tells this service to rescan.
        scheduler:markDirty()
        if panel ~= nil then
          panel:markDirty()
        end
      end
    end
    if scheduler:tick() then
      redraw()
      -- On the scheduler's 5 Hz tick, the general redraw cap, rather than every
      -- frame. The panel's RebuildGate already skips the work when the panel is
      -- closed or nothing changed, but that caps the work, not how often this
      -- call is made while both are true.
      if panel ~= nil then
        panel:refresh()
      end
    end
  end)

  -- tracker:start() reads UnitXPMax("player") (via LevelTracker:requiredFor),
  -- which is not reliably populated at ADDON_LOADED on a fresh login: the client
  -- can still be on the loading screen, unit data not yet synced. A record with
  -- xpRequired == 0 reads as "nothing to show" to XpBarViewModel, and XpLedger
  -- refuses to post experience into it. A /reload does not show this, because
  -- the world is not torn down.
  --
  -- PLAYER_ENTERING_WORLD is the client's signal that the unit data exists, so
  -- it triggers the start. start() is safe to call again on every later firing
  -- (a loading screen mid-session, a /reload), as WowEventRouter's experience
  -- snapshot anchor also relies on.
  local entering = CreateFrame("Frame")
  entering:RegisterEvent(WowEvent.PLAYER_ENTERING_WORLD)
  entering:SetScript("OnEvent", function()
    tracker:start()
    -- The client rebuilds and re-shows its own bar across a loading screen, so
    -- whatever was done to it before one has to be done again after it.
    applyBarSlot()
    redraw()
  end)

  -- Everything built above, reachable so the options panel can read and write
  -- settings, toggle the bar and read diagnostics without rebuilding any of it.
  -- Read-only by convention: nothing outside this file replaces an entry.
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
    -- The frame clock itself, published like the views so the smoke harness can
    -- drive the addon: the three-call order inside this OnUpdate (close a
    -- settled pull, redraw if something changed, advance what is in motion) is
    -- behaviour worth exercising rather than restating in a test.
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
    -- The level the options panel's previews draw. A module function, not the
    -- driver instance: the panel wants the demo's script, not a demo to drive,
    -- and the instance exists only when the views were built.
    demoSample = DemoDriver.sample,
    -- The plate's page has no preview of its own: its button runs this, the
    -- same fake pull `/ascent options plate demo` runs, on the real plate.
    -- Published as the function rather than the stand-in it builds, because the
    -- panel starts a demo and does not drive one.
    startPlateDemo = startPlateDemo,
  }
  ns.app.context = context

  -- ---------------------------------------------------------------------------
  -- Chat commands.
  -- ---------------------------------------------------------------------------

  -- The keyword is a literal and the description is a key: the dispatcher below
  -- matches these spellings byte for byte, so a translated keyword would
  -- document a command that does not answer.
  local HELP_LINES = {
    { "show", TextKey.CMD_HELP_SHOW },
    { "hide", TextKey.CMD_HELP_HIDE },
    { "panel", TextKey.CMD_HELP_PANEL },
    { "summary", TextKey.CMD_HELP_SUMMARY },
    { "pending", TextKey.CMD_HELP_PENDING },
    -- Every subcommand handleOptions answers, and nothing else; the smoke harness
    -- runs what this line announces. Alternatives are bracketed so each one's
    -- first word is the keyword: `contrast on|off` unbracketed would read as two
    -- alternatives, the second of them "off", which is not a subcommand.
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

    -- xpRequired is nilable (core/model/LevelRecord.lua: "learned from the
    -- client; unknown until then"), so between login and the first
    -- PLAYER_XP_UPDATE there is no total to show, and the marker says so rather
    -- than printing "nil xp".
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
    -- The same sentence the panel and the bar say about this level: where the
    -- experience of creatures went when no kill line was there to name it.
    local unnamed = record:unavailableReason(ns.core.RecordedSource.XP_CHAT)
    if unnamed ~= nil then
      logger:info(locale:get(ns.core.UnavailableText[ns.core.RecordedSource.XP_CHAT][unnamed]))
    end
  end

  -- The pending total, the subtotal ready to turn in and the count of quests
  -- with no known reward, printed as a projection and never folded into
  -- printSummary's breakdown: pending experience is never counted as earned.
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
    -- Only when it would explain something: a player on the default slot has no
    -- reason to hear about a bar the addon was not going to touch.
    if BarSlotPolicy.active(settings[SettingKey.BAR_SLOT]) and not clientXpBar:present() then
      logger:warn(locale:get(TextKey.CMD_SLOT_NO_CLIENT_BAR))
    end
  end

  -- What `/ascent options plate` answers with no argument, as `skin` and `slot`
  -- do. It is for a player who cannot find the plate, so it leads with the three
  -- states that hide one (switched off, transparent, past the edge of the
  -- screen) and says where it is before what it draws. The lock is on the first
  -- line because it is what stops the plate moving once found.
  --
  -- The plate's own appearance map is not printed: it is partial by design (it
  -- only overrides the bar's skin), it belongs to the options page, and no axis
  -- in it can hide a plate.
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

    -- Through the layout service, so the zones print in the order the plate
    -- draws them rather than in the saved file's order.
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
      -- The way back. A player who made the bar unreadable, or dragged it out of
      -- reach, cannot fix it from a panel they have to see to click, so this
      -- path depends only on being able to type. Data is untouched: this resets
      -- how the addon looks, never what it recorded ("/ascent reset confirm" is
      -- the other one, and it asks first).
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
      -- This is the shortcut and, like every appearance command here, the way
      -- back when the interface cannot be used.
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
        -- The choices table is keyed by the slot names, so its keys are the
        -- vocabulary itself: sorted, with no second list to drift.
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
      -- starts is the surface a player may want gone in a hurry, so it gets a
      -- typed way out that does not need a checkbox.
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
        -- The way back, and for this surface the only one: the plate's page is
        -- reached by clicking, and a plate dragged off screen or left at an
        -- opacity that hides it cannot be clicked. Like the bar's reset, it
        -- resets how the plate looks, never what was recorded.
        --
        -- Its own keys and no others: the plate follows the bar's skin, palette
        -- and contrast, so resetting those from a command about the plate would
        -- undo choices made for the bar. The list is shared with the button on
        -- the plate's page so the two cannot disagree.
        for _, key in ipairs(ns.core.PlateSettingKeys) do
          -- A copy of the default, never the default itself: a frozen map's proxy
          -- written back is an empty carrier and reaches disk empty, and the zone
          -- list a frozen table answers with is its backing store.
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

    -- The re-seeding path LevelTracker_spec.lua exercises for "new character
    -- mid-level": clearing record and sessionMark and calling start() again
    -- reconciles a fresh record from the character's current state, with no
    -- separate reset mechanism.
    store:clear()
    tracker.record = nil
    tracker.sessionMark = nil
    tracker:start()
    redraw()
    -- The panel reads the store, and an open one holds a view-model built from
    -- records that no longer exist, including a selected level in its title.
    -- `select(nil)` drops the selection and rebuilds in one call; without it the
    -- panel shows an erased level until something else marks it dirty.
    if panel ~= nil then
      panel:select(nil)
    end

    logger:info(locale:get(TextKey.CMD_RESET_DONE))
  end

  -- XpAttribution's diagnostic counters, in a fixed order rather than the
  -- non-deterministic order of `pairs`. They tell a player whose experience
  -- landed in "Unclassified" whether it was a delta nothing claimed, a hint
  -- nothing settled, or a channel this build's classifiers do not recognise.
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

  -- The client's GlobalStrings and location answers, dumped to the debug log and
  -- to the saved variables. The parser builds its experience patterns from these
  -- strings, so their exact shape (which marker comes first, whether markers are
  -- positional) decides what each capture holds, and getting it wrong
  -- misclassifies silently. None of it is documented for Burning Crusade Classic.
  --
  -- Derived from the list the parser reads (GlobalStringPattern.SOURCES), not
  -- copied beside it, so a dump taken on a non-English client holds every
  -- template the parser uses, the EXHAUSTION*_GROUP/_RAID ones included.
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

    -- To the debug log, not to chat: fifteen lines of the client's raw text
    -- whose value is in the snapshot below and the log file. Printed, they would
    -- push the rest of the diagnostic off the top of the 500-line chat ring.
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

  -- The quest log's section of the diagnostic. The per-quest dump goes to the
  -- debug log (the reader writes it when given a logger); chat gets the three
  -- figures a player can act on, above all the last, the only way to tell "this
  -- client words a kill objective differently" from "these quests ask for
  -- feathers".
  local function printQuestDebug()
    -- The recorder goes in here and not into the `scan` closure the scheduler
    -- drives: this sweep is asked for once, while the ticker's runs on every
    -- quest-log change would evict everything else from the ring.
    local forecasts = sweepQuestLog(logger, recordEvidence)
    logger:info(locale:get(TextKey.CMD_QUESTS_SCANNED, #forecasts))
    logger:info(locale:get(TextKey.CMD_QUESTS_NAMED, questNames:count()))
    logger:info(locale:get(TextKey.CMD_QUESTS_OBJECTIVES, questLogReader:objectiveTally()))
  end

  -- What the group dimension has collected, with a sample count no other surface
  -- carries: the panel and the plate price a population but never say how thin
  -- it is. The count shows whether group sizes seen once a level are worth
  -- lumping in with a bigger one.
  --
  -- Grouped by name and not by aggregate, because the name is what the estimator
  -- matches on: `creatureRate` sums every level band of a name at one group size,
  -- so the population behind a number is the pair (name, size), and a listing
  -- split per band would show halves of one.
  local function printGroupDebug()
    -- Asked of the port rather than of `GetNumGroupMembers`, so the figure printed
    -- is the one the estimator is handed, including the translation of the
    -- client's zero into the one person who is always there.
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
      -- own, and a nil would drop them out of the list they belong in.
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
      -- Smallest group first and the uncounted one last: it holds kills recorded
      -- before group sizes were counted and no longer grows, so it belongs at
      -- the end.
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

    -- Which experience templates this client produced, and how often. A
    -- template at zero is as informative as one at a thousand: the fatigue
    -- family is expected never to appear on Classic Era or Burning Crusade
    -- Classic, and this is what would show otherwise.
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
      settings[SettingKey.TIME_SYNC] and "on" or "OFF (levels will not be time-anchored)"))
    -- With the reason, not present/absent: "absent" and "unreadable" are one
    -- "no" to the addon and two different clients to whoever reads this.
    for _, line in ipairs(CopyReport.capabilityLines(capabilities:all())) do
      logger:info(line)
    end
    local missing = capabilities:missing()
    if #missing == 0 then
      logger:info("missing capabilities: none")
    else
      logger:info(("missing capabilities: %s"):format(table.concat(missing, ", ")))
    end

    -- Two states that look the same from outside: the player left the bar where
    -- it was, or asked for the client's slot and the client had nothing to give.
    -- One line for both would send someone looking for a bug in a setting that
    -- works as written.
    local chosenSlot = settings[SettingKey.BAR_SLOT]
    local effectiveSlot = clientXpBar:effectiveSlot(chosenSlot)
    if chosenSlot == effectiveSlot then
      logger:info(("slot: %s"):format(tostring(chosenSlot)))
    else
      logger:info(("slot: %s requested, %s in effect -- no client bar to take over")
        :format(tostring(chosenSlot), tostring(effectiveSlot)))
    end

    -- The names, and what is under them. Printed always, not only when the bar
    -- is missing: a client where the slot works and one where it works for a
    -- different reason are not the same answer, and Classic Era and Burning
    -- Crusade Classic must be read the same way.
    for _, row in ipairs(clientXpBar:inventory()) do
      local mark = row.used and "  " or "  ? "
      local held = ""
      if row.quieted then
        held = (" -- quieted, gives back %s, reads %s"):format(
          tostring(row.givesBack), tostring(row.alphaNow))
      end
      -- Compared against the bar's own depth, printed just below: the two
      -- numbers answer "who draws on top", and the bar painting over the
      -- client's frame is what it looks like when they are wrong.
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

    -- The bar's own depth, in the same shape as the rows above so the two read
    -- side by side. Inset puts the bar one level under its anchor so the
    -- client's frame art draws over it; replace puts it one over. If these do
    -- not line up, the draw order is wrong.
    if bar ~= nil and bar.depth ~= nil then
      local strata, level, wanted = bar:depth()
      if strata ~= nil then
        -- The level it asked for is printed only when the frame disagrees:
        -- silence means the two match and the rule is what to look at; a second
        -- number means the client did not honour the request, a different
        -- problem with a different fix.
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

    -- How often the client could not say where the character was, counted
    -- because only real play answers it. The share matters, not the amount: a
    -- hundred unplaced experience means one thing in a level of two hundred and
    -- another in a level of twenty thousand.
    local record = tracker:current()
    if record ~= nil and record:hasPlaces() then
      -- Two different numbers. The reserved "unknown place" entry is a place to
      -- the ledger, which keeps the two dimensions equal, and the absence of one
      -- to a reader; printing the ledger's total as "placed" would contradict
      -- the unplaced line below it.
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

    -- Everything the diagnostic knows, in one command, so a player chasing one
    -- number does not have to know which command holds it.
    printQuestDebug()
    dumpStrings()
  end

  -- The only channel back. An addon cannot make network requests, so there is
  -- no telemetry: all that is learned about how it behaves on someone else's
  -- machine is what that player chooses to send. This runs the diagnostics
  -- above with their output diverted into a table (ChatLogger:capture) and shows
  -- the result in a window whose text can be selected. One generator, two
  -- destinations.
  local copyDialog

  -- What makes a pasted report worth reading. Without the build and the flavour
  -- a report is a column of numbers with nothing to compare it against, and the
  -- level is what makes the experience figures mean anything. Not the character
  -- name and not the realm: a report is going somewhere public.
  local function reportHeader()
    local environment = evidenceEnvironment()
    return {
      { "addon", ("%s %s"):format(ADDON_NAME, tostring(environment.addonVersion)) },
      -- The interface number alongside the name, because the name is derived
      -- from it: a report from a client this build does not know says
      -- "unknown", and the number is the only part anyone can act on.
      { "client", ("%s (interface %s), max level %s"):format(tostring(environment.flavor),
        tostring(Compat.interfaceVersion()), tostring(environment.maxLevel)) },
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

  -- The flight recorder's switch, a subcommand of debug: `/ascent debug` holds
  -- everything the addon knows about itself, so a player chasing one thing does
  -- not have to know which of two top-level words holds it.
  --
  -- It is not a second debug mode: debug prints to chat for a quick check, while
  -- this writes to the saved variables and is meant to stay on, unnoticed, for
  -- a whole levelling session.
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
      -- The report was captured instead of printed, so without this it would
      -- vanish with the window that failed to open; it goes to chat instead.
      for _, line in ipairs(lines) do
        logger:info(line)
      end
    end
  end

  -- What changed, version by version, in the window that already shows text.
  -- The entries are generated from CHANGELOG.md at build time, so no markdown is
  -- parsed on a player's machine, and a build carrying none says so rather than
  -- opening empty.
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
      -- No window, so only which build this is goes to chat: the whole
      -- changelog there would scroll out of reach.
      logger:info(locale:get(TextKey.CHANGELOG_RUNNING, tostring(addonVersion)))
    end
  end

  -- The same report, opened from the options panel (built further down, from
  -- this table). Assigned here rather than in the context table above because
  -- `handleCopy` is a local defined just above: a closure written there would
  -- capture a global nil instead.
  context.copyReport = function() handleCopy("") end
  -- Applied live, in both directions: the watch stops counting reports and the
  -- channel stops announcing, because `announce` asks the same object whether it
  -- speaks at all.
  context.setUpdateCheck = function(enabled) updateWatch:enable(enabled) end

  SLASH_ASCENT1 = "/ascent"
  -- The commands that cannot do anything without a frame. Everything else (the
  -- summary, the pending report, the diagnostics, the data wipe) works with no
  -- views, which is why the view failure is isolated.
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
        -- The time played request fires from PLAYER_ENTERING_WORLD, during the
        -- loading screen, so suppressing it has to be decided before the session
        -- starts: it takes effect on the next login. `printDebug` reports the
        -- state so a player who set it and forgot can find out.
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
  -- The Interface > AddOns options panel.
  -- ---------------------------------------------------------------------------

  -- Built last, after everything it reads from and writes through (bar,
  -- saveSetting, settings) exists on `context`, and kept on `context` itself so
  -- handleOptions' "panel" branch, defined earlier, can reach it.
  --
  -- Built only when there is a bar for its controls to drive. Its failure is
  -- reported separately: losing the options panel must not cost the commands,
  -- which are the way back when the interface is unusable.
  if bar ~= nil then
    local optionsOk, optionsError = pcall(OptionsPanel.new, context)
    if optionsOk then
      -- A list of pages, parent first. The context keeps both the pages to
      -- register and the parent frame, for everything that wants "the options
      -- panel": opening it, refreshing it.
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

  -- What changed since the last session. Last, so a session that had trouble
  -- building its interface has already said so before this speaks.
  --
  -- History written by a newer build cannot be migrated backwards, so
  -- RecordStore sets it aside on load (core/service/RecordStore.lua); the
  -- downgrade line tells the player where it went.
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
