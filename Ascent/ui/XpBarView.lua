-- Ascent - the experience bar (tasks 10.2, 10.4, 10.5, 10.7; 3.3, 3.6-3.9, 4.5-4.7).
--
-- This file is the COMPOSITOR. Everything that makes the bar a bar rather than a
-- picture of one lives here: where it sits, whether it can be dragged, what it
-- says, when it hides, and the two clocks that drive it. What it does NOT do is
-- paint -- ui/BarRenderer.lua does that, from a resolved appearance and a vector
-- of boundaries, and knows nothing about any of the above.
--
-- That split is design D34, and its reason is concrete: the options panel has to
-- show a live preview of a skin, and a preview must not be able to move the real
-- bar, persist its position, or hide itself because the player happens to be at
-- max level. A preview is a renderer with no compositor around it.
--
-- TWO CLOCKS, and this is D24's amendment to D7. The data clock still runs at
-- 5 Hz: update() rebuilds the view-model, recomposes the text, and states where
-- the bar should END UP. The presentation clock runs every frame: tick() moves
-- the geometry towards that target and repaints. The second one does no
-- allocation and no view-model work -- it interpolates numbers that are already
-- computed -- and it stops entirely once everything has arrived, so a bar at
-- rest costs nothing.
--
-- The bar never touches SavedVariables. It is handed an already-resolved
-- `settings` table and a `saveSetting(key, value)` callback for the handful of
-- things it persists on its own: position, lock state, scale.

local _, ns = ...
ns.ui = ns.ui or {}

local SettingKey = ns.core.SettingKey
local XpSource = ns.core.XpSource
local PlaceContext = ns.core.PlaceContext
local TextKey = ns.core.TextKey
local TextAnchor = ns.core.TextAnchor
local BarChannel = ns.core.BarChannel
local XpBarViewModel = ns.core.XpBarViewModel
local QuestNames = ns.core.QuestNames
local XpBarText = ns.core.XpBarText
local BarTextFields = ns.core.BarTextFields
local SkinResolver = ns.core.SkinResolver
local SkinCatalog = ns.core.SkinCatalog
local BarTween = ns.core.BarTween
local Pulse = ns.core.Pulse
local Palette = ns.core.Palette
local BarRenderer = ns.ui.BarRenderer
local BarGeometry = ns.core.BarGeometry
local BarSlotPolicy = ns.core.BarSlotPolicy

-- Tooltip labels, one per source -- TextKey values, not text: the label itself
-- is resolved through `self.locale` at the point of use. The same four keys back
-- the panel and the /ascent summary, which is why they live in core/constants,
-- not here.
local SOURCE_LABEL = {
  [XpSource.MOB_KILL] = TextKey.SOURCE_CREATURES,
  [XpSource.QUEST_TURNIN] = TextKey.SOURCE_QUESTS,
  [XpSource.EXPLORATION] = TextKey.SOURCE_EXPLORATION,
  [XpSource.UNKNOWN] = TextKey.SOURCE_UNCLASSIFIED,
}

-- The same six nouns the panel uses for a kind of place, for the same reason the
-- four source labels above are shared: the bar and the panel must not learn to
-- call the same thing by two names.
local PLACE_LABEL = {
  [PlaceContext.WORLD] = TextKey.PLACE_WORLD,
  [PlaceContext.DUNGEON] = TextKey.PLACE_DUNGEON,
  [PlaceContext.RAID] = TextKey.PLACE_RAID,
  [PlaceContext.BATTLEGROUND] = TextKey.PLACE_BATTLEGROUND,
  [PlaceContext.ARENA] = TextKey.PLACE_ARENA,
  [PlaceContext.UNKNOWN] = TextKey.PLACE_UNKNOWN,
}

-- Room left for the bar's own border and a little breathing space, when deciding
-- whether the composed text fits inside it.
local TEXT_PADDING = 8

-- How far off the visible screen a saved position is allowed to be before it is
-- pulled back. Not zero: a player may legitimately want the bar half off the
-- edge. Small enough that a bar saved on a monitor that no longer exists always
-- comes back within reach.
local OFFSCREEN_MARGIN = 40

-- ---------------------------------------------------------------------------
-- Small pure helpers, kept free of `self` so they stay easy to read in
-- isolation.
-- ---------------------------------------------------------------------------

-- `update`'s params argument is the same bag XpBarViewModel.build reads
-- (restedXp, questPending, showQuestPending) plus whatever the caller wants
-- forwarded into the bar's text (see buildTextValues below) -- XpBarViewModel
-- ignores keys it does not know about, so passing the same table to both is
-- safe. The one thing resolved here is `showQuestPending`: when the caller
-- does not pass it explicitly, it defaults to the player's own preference
-- instead of leaving the view-model to decide with no opinion at all.
local function resolveParams(params, settings)
  local resolved = {}
  if params ~= nil then
    for key, value in pairs(params) do
      resolved[key] = value
    end
  end
  if resolved.showQuestPending == nil then
    resolved.showQuestPending = settings[SettingKey.SHOW_QUEST_PENDING]
  end
  return resolved
end

-- The values XpBarText.format needs, built from whatever this module actually
-- has on hand. A field with no caller to supply it arrives nil, and XpBarText
-- renders a nil as its not-available marker rather than a fabricated number.
-- xpCurrent/xpRemaining read viewModel.xpTotal, not record.xpTotal directly: it
-- already folds in what the client confirmed but XpAttribution has not yet
-- settled into a source (D21), which is what lets the number on the bar move
-- within one redraw tick of a kill instead of lagging behind it.
local function buildTextValues(record, viewModel, params)
  return {
    level = record.level,
    xpCurrent = viewModel.xpTotal,
    xpMax = record.xpRequired,
    xpPercent = viewModel.percentComplete,
    xpRemaining = record.xpRequired - viewModel.xpTotal,
    restedXp = params.restedXp,
    xpPerHour = params.xpPerHour,
    timeToLevel = params.timeToLevel,
    timeOnLevel = record.playedSeconds,
    sessionTime = params.sessionTime,
    questPending = params.questPending,
  }
end

-- The ids BarTween needs, in the order BarChannel declares them. Built once.
local function channelIds()
  local ids = {}
  for _, channel in ipairs(BarChannel) do
    ids[#ids + 1] = channel.id
  end
  return ids
end

local XpBarView = {}
XpBarView.__index = XpBarView

-- ---------------------------------------------------------------------------
-- Construction and appearance (3.3, 3.6)
-- ---------------------------------------------------------------------------

-- Pulled back inside the visible screen when the saved position would put it out
-- of reach (task 3.9). The failure this prevents is not hypothetical: the
-- position is re-applied on every login, so a bar saved on a monitor that is no
-- longer attached stays unreachable forever, and the player cannot drag what
-- they cannot see.
function XpBarView:clampedPosition(position)
  local width, height = UIParent:GetWidth(), UIParent:GetHeight()
  if type(width) ~= "number" or type(height) ~= "number" or width <= 0 then
    return position
  end

  local limitX = width / 2 + OFFSCREEN_MARGIN
  local limitY = height / 2 + OFFSCREEN_MARGIN
  local x, y = position.x, position.y
  if x > limitX then x = limitX elseif x < -limitX then x = -limitX end
  if y > limitY then y = limitY elseif y < -limitY then y = -limitY end

  if x == position.x and y == position.y then
    return position
  end
  return { point = position.point, x = x, y = y }
end

function XpBarView:applySavedPosition()
  -- Suspended, not forgotten: while the bar sits in the client's slot the saved
  -- position stays on disk untouched and this simply declines to apply it. That
  -- is what makes turning the slot off a complete undo (D50).
  if self.slotFrame ~= nil then
    return
  end
  -- No "is there one saved?" branch: the resolved settings table always carries
  -- a complete position, because BAR_POSITION's default declares its shape and
  -- Settings.resolve completes a stored one key by key (Settings.lua).
  local position = self:clampedPosition(self.settings[SettingKey.BAR_POSITION])
  self.frame:ClearAllPoints()
  self.frame:SetPoint(position.point, UIParent, position.point, position.x, position.y)
end

-- ---------------------------------------------------------------------------
-- The client's slot (D47, D48, D50, D52)
-- ---------------------------------------------------------------------------

-- The width and height the bar actually has, which is not the same question as
-- what the player configured. Anchored to the client's bar, the settings are
-- suspended and the real measure is the frame's own -- and it is the frame's,
-- not the client frame's, because the two may be at different scales and the
-- anchor resolves that between them.
-- Asked of the slot every time, never remembered.
--
-- A remembered measure is a copy, and D47 is about not keeping one: the whole
-- reason the bar anchors instead of copying coordinates is that a copy goes stale
-- and nobody notices until it is painted. The cached width did exactly that --
-- change any visual setting and the bar repainted from the last measure rather
-- than the current one, drawing itself across the client's frame.
--
-- Reading it costs two calls on a settings change and none on a redraw.
function XpBarView:barWidth()
  if self.slotFrame ~= nil then
    local width = self:slotSize(self.slotFrame)
    if type(width) == "number" and width > 0 then
      return width
    end
  end
  return self.settings[SettingKey.BAR_WIDTH]
end

function XpBarView:barHeight()
  if self.slotFrame ~= nil then
    local _, height = self:slotSize(self.slotFrame)
    if type(height) == "number" and height > 0 then
      return height
    end
  end
  return self.settings[SettingKey.BAR_HEIGHT]
end

-- Anchoring rather than copying the geometry over: the four things that can move
-- the client's bar -- interface scale, resolution, the player, another addon --
-- are then not four events to get right but none at all (D47).
--
-- Position and size only. Not visibility: the client hides its own bar on its own
-- schedule, and inheriting that would put this bar's showing and hiding in the
-- client's hands instead of the player's (D48).
--
-- Depth too, and for the same reason as position: a copy goes stale. Which slot
-- the player chose decides whether the client's frame art draws over this bar or
-- under it (BarSlotPolicy.depth), and that has to be said out loud on every
-- attach -- see applyDepth.
function XpBarView:attachTo(clientFrame, slot)
  if clientFrame == nil then
    return self
  end

  self.slot = slot
  if self.slotFrame ~= clientFrame then
    self.slotFrame = clientFrame
    local frame = self.frame
    frame:ClearAllPoints()
    frame:SetAllPoints(clientFrame)
    frame:SetScript("OnSizeChanged", function()
      self:inheritSize()
    end)
  end

  -- Re-measured even when the frame was already the one we were on: the player
  -- can move between the two active slots without passing through off, and an
  -- early return there left the bar showing whatever it last measured.
  self:applyDepth(clientFrame, slot)
  self:inheritSize()
  return self
end

-- Where the bar sits in the drawing order while it stands in the client's slot:
-- the client frame's own strata, and the level the chosen slot asks for.
--
-- Re-applied on every attach rather than once when the frame changes, because the
-- level is the client's to move and it moves it without telling anyone -- a
-- loading screen, its own layout pass, another addon. Attaching already runs at
-- each of those moments (Bootstrap re-applies the slot on PLAYER_ENTERING_WORLD
-- and on every settings change), so a depth stated here is a depth that survives
-- them; a depth stated once is the bug the player reported, where the bar spent
-- an evening inside the client's frame and then started painting over it.
--
-- Every call is guarded: the frame arrives from _G by name (adapter/compat), and
-- a name another addon has taken for something else must cost the depth, not the
-- bar.
-- Each half written as "set it only if it is not already that", because this runs
-- on the data tick as well as on every attach (see holdDepth): the reads are two
-- numbers the client already has, and the writes are what a frame notices.
function XpBarView:applyDepth(clientFrame, slot)
  if clientFrame.GetFrameStrata ~= nil then
    local strata = clientFrame:GetFrameStrata()
    if type(strata) == "string" and self.frame:GetFrameStrata() ~= strata then
      self.frame:SetFrameStrata(strata)
    end
  end
  if clientFrame.GetFrameLevel == nil then
    return self
  end
  local level = BarSlotPolicy.depth(slot, clientFrame:GetFrameLevel(), self:slotFloor(clientFrame))
  -- Kept so the diagnostic can print what was ASKED FOR beside what the frame
  -- reads back. They are not the same question, and a client that quietly refuses
  -- a level -- or something that moves it afterwards -- looks exactly like a rule
  -- that computed the wrong number. Five rounds of screenshots could not tell
  -- those two apart.
  self.wantedLevel = level
  if level ~= nil and self.frame:GetFrameLevel() ~= level then
    self.frame:SetFrameLevel(level)
  end
  return self
end

-- How many frames up the client's own chain to look for the floor. The art that
-- has to stay on top belongs to the anchor's parent, and four is room for a
-- client that nests one or two deeper than that without walking to UIParent and
-- back on a tick.
local SLOT_CHAIN = 4

-- The lowest level among the client frames whose art must draw over this bar:
-- the anchor and the frames it hangs from, which is where the bar's own frame art
-- actually lives (BarSlotPolicy.depth says why the anchor alone is not it).
--
-- Only ancestors in the SAME strata are considered. A frame in another strata is
-- not competing on level at all, and folding its number in here would answer a
-- question nobody asked -- and could drag the bar below a strata it belongs in.
--
-- Nil when the chain says nothing useful, which leaves the rule to fall back on
-- the anchor's own level rather than on a number invented here.
function XpBarView:slotFloor(clientFrame)
  if clientFrame.GetParent == nil or clientFrame.GetFrameStrata == nil then
    return nil
  end
  local strata = clientFrame:GetFrameStrata()
  local floor, frame = nil, clientFrame
  for _ = 1, SLOT_CHAIN do
    if frame == nil or frame.GetFrameLevel == nil or frame.GetFrameStrata == nil then
      break
    end
    if frame:GetFrameStrata() == strata then
      local level = frame:GetFrameLevel()
      if type(level) == "number" and (floor == nil or level < floor) then
        floor = level
      end
    end
    -- UIParent is everyone's ancestor and its level says nothing about the art
    -- around the client's bar, so the walk stops there rather than at it.
    if frame == UIParent or frame.GetParent == nil then
      break
    end
    frame = frame:GetParent()
  end
  return floor
end

-- The depth, held rather than announced once.
--
-- Stating it on every attach is not enough and the player found the gap by using
-- the addon: the moments Ascent re-applies the slot are its own, and the client
-- re-lays its main bar out in moments that are the CLIENT's -- closing a settings
-- panel is one of them, which is why "I change the config and it covers the frame"
-- was the report. Whatever Ascent set a moment earlier is stale by then, and
-- nothing was watching.
--
-- So the slot's depth is asked the same way the slot's size is (barWidth): every
-- time, never remembered. On the 5 Hz data tick rather than the per-frame one,
-- because the client does not move a frame's level between two frames of
-- animation -- and at rest the tick is not running at all.
function XpBarView:holdDepth()
  if self.slotFrame == nil then
    return self
  end
  return self:applyDepth(self.slotFrame, self.slot)
end

-- The slot's measure, in this frame's coordinates.
--
-- Read from the CLIENT's frame, not from ours. Ours has just been anchored to it
-- and the client has not laid it out yet, so asking ours answers with the size
-- the bar had before the slot -- one frame painted at the old width, corrected on
-- the next layout pass. That is the blink, and it is avoidable by asking the
-- frame that already knows.
--
-- Scaled, because the two frames need not be at the same scale: anchoring makes
-- them cover the same screen area, which is a different number of points each.
function XpBarView:slotSize(clientFrame)
  local width, height = clientFrame:GetWidth(), clientFrame:GetHeight()
  local theirs, ours = clientFrame:GetEffectiveScale(), self.frame:GetEffectiveScale()
  if type(theirs) ~= "number" or type(ours) ~= "number" or ours == 0 then
    return width, height
  end
  return width * theirs / ours, height * theirs / ours
end

-- Where the bar draws, for the diagnostic to print next to the client's own rows.
-- Asked of the frame rather than remembered, for the same reason the slot's
-- measure is: what this addon last SET is not what the drawing order IS.
function XpBarView:depth()
  if self.frame.GetFrameStrata == nil or self.frame.GetFrameLevel == nil then
    return nil, nil
  end
  return self.frame:GetFrameStrata(), self.frame:GetFrameLevel(), self.wantedLevel
end

-- Back to the bar the player had. Nothing to undo in the settings, because
-- nothing was ever written over them (D50) -- the saved position and size were
-- only suspended, and reapplying them is the whole of it.
function XpBarView:detach()
  if self.slotFrame == nil then
    return self
  end

  self.slotFrame, self.slot, self.wantedLevel = nil, nil, nil
  self.paintedWidth, self.paintedHeight = nil, nil
  self.frame:SetScript("OnSizeChanged", nil)
  if type(self.freeStrata) == "string" then
    self.frame:SetFrameStrata(self.freeStrata)
  end
  if type(self.freeLevel) == "number" then
    self.frame:SetFrameLevel(self.freeLevel)
  end
  self.appearance = self:resolveAppearance()
  -- Position FIRST, then size, and the order is the whole of it. While the slot
  -- lasted the frame was held by SetAllPoints on the client's, which pins both
  -- corners -- and a frame pinned at both corners ignores SetSize. Sizing before
  -- releasing those anchors therefore did nothing at all, and the bar came back
  -- from the slot wearing the client's width. applySavedPosition is what releases
  -- them, so it has to happen before there is a size to apply.
  self:applySavedPosition()
  self.renderer:setSize(self.settings[SettingKey.BAR_WIDTH], self.settings[SettingKey.BAR_HEIGHT])
  self.renderer:applyAppearance(self.appearance)
  return self
end

-- The measure arrives from the frame rather than from a setting while the slot
-- lasts. Guarded against the zero the client reports for a frame it has not laid
-- out yet: a renderer sized zero is a bar that exists and occupies nothing.
-- The slot changed shape, so repaint at what it measures now. Takes no
-- measurements from its caller: the client hands OnSizeChanged the frame's new
-- size, and taking that would be keeping a copy again -- by the time it is used
-- the only number that matters is what the slot reads at that moment.
function XpBarView:inheritSize()
  local width, height = self:barWidth(), self:barHeight()
  if type(width) ~= "number" or width <= 0 or type(height) ~= "number" or height <= 0 then
    return self
  end
  if width == self.paintedWidth and height == self.paintedHeight then
    return self
  end

  self.paintedWidth, self.paintedHeight = width, height
  self.appearance = self:resolveAppearance()
  self.renderer:setSize(width, height)
  self.renderer:applyAppearance(self.appearance)
  return self
end

-- The appearance the renderer paints: the chosen skin, the player's own tweaks
-- on top, and the palette. Resolved in core/ and handed over whole, so this file
-- has no idea which skin it is showing (design D27).
function XpBarView:resolveAppearance()
  local options = {
    skin = SkinResolver.skinFor(SkinCatalog, self.settings[SettingKey.BAR_SKIN], ns.core.DEFAULT_SKIN_ID),
    overrides = self.settings[SettingKey.BAR_APPEARANCE],
    colors = self.settings[SettingKey.BAR_COLORS],
    palette = Palette,
    highContrast = self.settings[SettingKey.HIGH_CONTRAST],
  }

  local appearance = SkinResolver.resolve(options)
  local text = appearance.text
  local inside = text.anchor == TextAnchor.INSIDE_LEFT
    or text.anchor == TextAnchor.INSIDE_CENTER
    or text.anchor == TextAnchor.INSIDE_RIGHT

  local wanted = text.anchor

  -- In the client's slot there is no text to place: the bar shows none and the
  -- readout lives in the tooltip (see showText). So nothing here reconsiders the
  -- anchor -- the player's choice is suspended, not overruled, and it is waiting
  -- exactly as they left it for when the bar comes back out.
  if self.slotFrame ~= nil then
    return appearance
  end

  if inside then
    if BarGeometry.textFitsInside(self:barHeight(), text.size) then
      return appearance
    end
    wanted = self:outsideTextAnchor(text.size)
  elseif text.anchor == TextAnchor.BELOW then
    -- Below is a place, and in the client's slot there is no room there: the
    -- action bar is. This applies to a below the PLAYER chose as much as to one
    -- this code chose -- the first version only checked the text it had moved
    -- itself, so a player whose skin or own setting said below got a bar with no
    -- text at all and nothing to suggest why.
    wanted = self:outsideTextAnchor(text.size)
  end

  if wanted == text.anchor then
    return appearance
  end

  -- D52. The client's bar is much thinner than this bar's own default, so a skin
  -- that puts its text inside would be asking eleven points of font to live in
  -- ten pixels. Resolved again rather than edited: what comes back is frozen, and
  -- the size a skin asks for is only known after resolving once. Twice is free --
  -- this runs on a settings change and on a size change, never on a redraw.
  options.textAnchor = wanted
  return SkinResolver.resolve(options)
end

-- Which side the text ends up on when it has to leave the bar. The room below is
-- the bar's own distance from the bottom of the screen: in the client's slot that
-- is a handful of pixels, and the text that went there was drawn behind the
-- action bar. Unknown -- a frame the client has not laid out yet -- keeps the
-- conventional side rather than guessing.
function XpBarView:outsideTextAnchor(textSize)
  -- The frame may not exist yet, and that is not an edge case: the constructor
  -- resolves the appearance one line BEFORE it creates the frame, so a skin whose
  -- text sits below -- cartographer is one of the six -- reached this during
  -- construction and took the whole interface down with it, panel and options
  -- included. A frame that has not been laid out and a frame that does not exist
  -- yet are the same question here, and BarGeometry already answers it: a
  -- non-number room keeps the conventional side rather than guessing.
  local bottom = self.frame ~= nil and self.frame:GetBottom() or nil
  return BarGeometry.textAnchorOutside(bottom, textSize)
end

-- The composed text, and whether it is being shown right now. Kept apart because
-- the player can ask for a bar that says nothing until the cursor is on it: the
-- text is still composed on every update -- the cursor may arrive at any moment --
-- and only its showing waits.
function XpBarView:showText(value)
  if value ~= nil then
    self.composedText = value
  end
  -- Nothing at all while the bar stands in the client's slot, on the owner's
  -- instruction from the client: "no se llega a ver y tampoco se entiende".
  --
  -- The strip is twelve pixels tall and as wide as the screen, so the line was
  -- either too small to read or a row of unlabelled numbers running into each
  -- other -- and every place to put it OUTSIDE the bar is the client's own
  -- interface. There is no arrangement of that text that works there, and the
  -- readout the player actually wants already exists a hover away: the tooltip
  -- names every source and every number, with words next to them.
  if self.slotFrame ~= nil then
    self.renderer:setText("")
    return
  end
  local waiting = self.settings[SettingKey.BAR_TEXT_ON_HOVER] and not self.hovered
  self.renderer:setText(waiting and "" or self.composedText)
end

function XpBarView:createFrame()
  local frame = CreateFrame("Frame", "AscentBar", UIParent)
  frame:SetScale(self.settings[SettingKey.BAR_SCALE])
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")

  self.frame = frame
  -- The drawing order of a bar that is nobody's guest, READ rather than chosen:
  -- a bar that never enters the slot keeps exactly the depth it has always had,
  -- and one that leaves the slot is handed that same depth back (D50 again --
  -- the slot suspends, it does not overwrite).
  self.freeStrata = frame.GetFrameStrata ~= nil and frame:GetFrameStrata() or nil
  self.freeLevel = frame.GetFrameLevel ~= nil and frame:GetFrameLevel() or nil
  self.renderer = BarRenderer.new({
    parent = frame,
    width = self.settings[SettingKey.BAR_WIDTH],
    height = self.settings[SettingKey.BAR_HEIGHT],
  })
  self.renderer:setSize(self.settings[SettingKey.BAR_WIDTH], self.settings[SettingKey.BAR_HEIGHT])
  self.renderer:applyAppearance(self.appearance)

  self:applySavedPosition()
end

-- `options`: settings (a table already resolved by ns.core.Settings.resolve),
-- saveSetting (function(settingKey, value), this view's only way to persist
-- anything), locale (a ns.core.Locale -- every player-visible string the bar
-- shows is looked up through it), and onToggle (optional function(), called on
-- a plain left click).
function XpBarView.new(options)
  options = options or {}
  for _, required in ipairs({ "settings", "saveSetting", "locale" }) do
    if options[required] == nil then
      error("XpBarView needs a " .. required, 2)
    end
  end

  local self = setmetatable({
    settings = options.settings,
    saveSetting = options.saveSetting,
    locale = options.locale,
    onToggle = options.onToggle,
    -- The same directory the panel reads, so one quest is written the same way on
    -- both. Optional: a bar built without it numbers its quests.
    questNames = options.questNames,
    -- ASKED, not carried: a function called once, when the popup opens. Building
    -- and sorting the pending entries on the redraw tick -- five times a second,
    -- hovered or not -- is what `placesFor` exists to avoid, and this is the same
    -- shape of question.
    questEntries = options.questEntries,
    -- A local, mutable copy: self.settings is frozen and read-only, so the one
    -- piece of it that changes during play (the lock) needs a home of its own.
    locked = options.settings[SettingKey.BAR_LOCKED],
    dragging = false,
    tween = BarTween.new({ channels = channelIds() }),
    pulse = Pulse.new(),
    level = nil,
    -- The last total the bar was told about, so a redraw can tell "the player
    -- gained experience" from "nothing changed" and only flash for the first.
    previousTotal = nil,
    record = nil,
    viewModel = nil,
    params = nil,
  }, XpBarView)

  self.appearance = self:resolveAppearance()
  self:createFrame()
  self:attachDrag()
  self:attachTooltip()

  return self
end

-- Re-reads settings and reapplies everything that comes out of them, without
-- rebuilding a single frame or texture (the spec's "applies immediately, no
-- reload"). Recreating frames would be the obvious way to do this and is the
-- wrong one -- a WoW frame cannot be destroyed, so every rebuild leaks one.
function XpBarView:applySettings(settings)
  self.settings = settings or self.settings
  self.appearance = self:resolveAppearance()
  self.frame:SetScale(self.settings[SettingKey.BAR_SCALE])
  -- barWidth/barHeight rather than the settings directly: in the client's slot
  -- those two settings are suspended and the measure is the inherited one, so
  -- reapplying settings there must not resize the bar out of the slot it is in.
  self.renderer:setSize(self:barWidth(), self:barHeight())
  self.renderer:applyAppearance(self.appearance)
  self:showText()
  self:applySavedPosition()
  self:paint()
  return self
end

-- ---------------------------------------------------------------------------
-- Text (3.7, 3.8)
-- ---------------------------------------------------------------------------

-- The composed text, shortened until it fits. Fields are given up in the order
-- TEXT_PRIORITY declares, lowest rank first, so a bar too narrow for everything
-- sheds the same fields every time instead of whatever happens to be longest.
-- Only enforced when the text sits INSIDE the bar: above or below it has the
-- whole screen's width and nothing to collide with.
function XpBarView:composeText(values)
  local chosen = {}
  for _, token in ipairs(self.settings[SettingKey.BAR_TEXT_TOKENS]) do
    chosen[#chosen + 1] = token
  end

  local text = XpBarText.format(chosen, values, self.locale)
  local anchor = self.appearance.text.anchor
  local inside = anchor == TextAnchor.INSIDE_LEFT
    or anchor == TextAnchor.INSIDE_CENTER
    or anchor == TextAnchor.INSIDE_RIGHT
  if not inside then
    return text
  end

  local room = self:barWidth() - TEXT_PADDING
  while #chosen > 1 and self.renderer:widthOf(text) > room do
    local worst, worstRank = 1, -1
    for index, token in ipairs(chosen) do
      local rank = BarTextFields.rankOf(token)
      if rank > worstRank then
        worst, worstRank = index, rank
      end
    end
    table.remove(chosen, worst)
    text = XpBarText.format(chosen, values, self.locale)
  end

  return text
end

-- ---------------------------------------------------------------------------
-- Drawing and the presentation clock (4.5, 4.6, 4.7)
-- ---------------------------------------------------------------------------

function XpBarView:paint()
  self.renderer:draw(self.tween:boundaries())
  self.renderer:setFlash(self.pulse:alpha())
  return self
end

-- Called every frame by the composition root, from the OnUpdate that already
-- exists (design D32: no second per-frame script for this). Returns whether the
-- bar is still moving, so the caller can see at a glance that a resting bar
-- costs nothing -- but the cheap exit is here regardless of what the caller
-- does with it.
function XpBarView:tick(elapsed)
  local moving = self.tween:advance(elapsed)
  local flashing = self.pulse:advance(elapsed)
  if not moving and not flashing then
    return false
  end
  self:paint()
  return true
end

-- Nothing to show: max level, or experience disabled (10.7). No segment, no
-- rested mark, no pending channel, and no token-composed text -- the numbers
-- behind those tokens would not mean anything without an active level, and
-- showing them (even as zeroes) is exactly the misleading data the spec rules
-- out. `HIDE_WITHOUT_XP` decides between hiding the bar outright and showing
-- it with a fixed status line instead.
function XpBarView:drawInactive()
  self.renderer:hideProgress()
  if self.settings[SettingKey.HIDE_WITHOUT_XP] then
    self.frame:Hide()
    return
  end
  self.frame:Show()
  self:showText(self.locale:get(TextKey.BAR_NO_XP))
end

-- Rebuilds the view-model from `record`/`params` and states where the bar should
-- end up. This is the 5 Hz half of D24: it does not paint the final position, it
-- sets the target -- tick() walks there.
function XpBarView:update(record, params)
  -- Before the branch below can return early: a bar with nothing to show is still
  -- a bar standing in the client's slot, and the client re-levels its frames
  -- whether or not this character is earning experience.
  self:holdDepth()
  params = resolveParams(params, self.settings)
  self.record = record
  self.params = params

  local viewModel = XpBarViewModel.build(record, params)
  self.viewModel = viewModel

  if not viewModel.active then
    self:drawInactive()
    return self
  end

  self.frame:Show()

  local motion = self.settings[SettingKey.MOTION_SCALE]
  local shares = XpBarViewModel.shares(viewModel)

  -- A level-up is not a move, it is a reset. Animating the bar back down from
  -- full would show a completed level that is no longer the player's for as long
  -- as the animation lasts, which is precisely the misleading state 10.7 rules
  -- out elsewhere. So the vector is dropped to zero with no motion at all, and
  -- only the new level's progress is animated in.
  if self.level ~= nil and record.level ~= self.level then
    self.tween:setTarget({}, 0)
    self.pulse:bump():bump()
  elseif self.previousTotal ~= nil and viewModel.xpTotal > self.previousTotal then
    self.pulse:bump()
  end
  self.level = record.level
  self.previousTotal = viewModel.xpTotal

  self.tween:setTarget(shares, motion)

  local values = buildTextValues(record, viewModel, params)
  self:showText(self:composeText(values))
  self:paint()

  return self
end

-- ---------------------------------------------------------------------------
-- Tooltip (10.4)
-- ---------------------------------------------------------------------------

-- How many quests the popup names before it starts counting the rest. Three, and
-- the number is presentation, not data: the popup answers at a glance and the
-- panel answers in full (design.md D1), so this is "enough to recognise where the
-- pending experience is" and not "the list".
local QUESTS_IN_POPUP = 3

-- A blank line between blocks. GameTooltip has no rule to draw, and three headed
-- blocks running together read as one list with odd headings in it.
local function blockBreak(tooltip)
  tooltip:AddLine(" ")
end

-- Block one: the level. Its own total first, then the sources that make it up --
-- which is the order the question comes in ("how far am I, and from what").
local function addLevelBlock(view, tooltip, viewModel)
  local locale = view.locale
  local levelPercent = locale:get(TextKey.PERCENT, math.floor(viewModel.percentComplete * 100 + 0.5))
  tooltip:AddDoubleLine(locale:get(TextKey.BAR_TOOLTIP_LEVEL),
    locale:get(TextKey.BAR_TOOLTIP_VALUE, viewModel.xpTotal, levelPercent))

  local observation = viewModel.observation
  local declared = false

  for _, segment in ipairs(viewModel.segments) do
    -- segment.amount, not record:xpFrom(segment.source): UNKNOWN's segment can
    -- include experience the client confirmed but attribution has not settled
    -- yet (D21), which record:xpFrom alone would not show.
    local percentText = locale:get(TextKey.PERCENT, math.floor(segment.fraction * 100 + 0.5))
    tooltip:AddDoubleLine(locale:get(TextKey.BAR_TOOLTIP_PLACE, locale:get(SOURCE_LABEL[segment.source])),
      locale:get(TextKey.BAR_TOOLTIP_VALUE, segment.amount, percentText))

    -- Under the unclassified line, because that is the bucket whose ambiguity
    -- this resolves: both halves live in it and neither is legible without the
    -- other. The figures above are untouched -- the split is printed beneath
    -- them, never subtracted from them, so the percentages still sum to the
    -- level's own.
    if observation ~= nil and segment.source == XpSource.UNKNOWN then
      declared = true
      if observation.seededXp ~= nil then
        tooltip:AddDoubleLine(locale:get(TextKey.BAR_NOT_OBSERVED), tostring(observation.seededXp))
        -- Omitted at zero rather than printed as "0": everything unclassified
        -- here came in with the level, and a zero would invite the reader to
        -- look for a failure that did not happen.
        if observation.unexplainedXp > 0 then
          tooltip:AddDoubleLine(locale:get(TextKey.BAR_UNEXPLAINED), tostring(observation.unexplainedXp))
        end
      else
        -- A record from before the addon kept the figure. It can say the
        -- accounting is incomplete and no more.
        tooltip:AddLine(locale:get(TextKey.BAR_PARTIAL))
      end
    end
  end

  -- A partial level with nothing unclassified to hang it from -- one opened at
  -- its very first point, or one whose seed was spent by a level-up. The mark
  -- still belongs: it is a fact about the recording, not about the bucket.
  if observation ~= nil and not declared then
    tooltip:AddLine(locale:get(TextKey.BAR_PARTIAL))
  end
end

-- Block two: where it was earned. One line per place and never one per place per
-- source: a level played in one zone used to print that zone under every source,
-- saying it twice and never saying what the zone gave. The cross-reading of
-- source by place lives in the panel now (design.md D1).
local function addZoneBlock(view, tooltip, record)
  local places = XpBarViewModel.placesOf(record)
  if places == nil then
    return
  end

  blockBreak(tooltip)
  tooltip:AddLine(view.locale:get(TextKey.BAR_TOOLTIP_ZONES))
  for _, entry in ipairs(places) do
    local name = entry.place.name
      or view.locale:get(PLACE_LABEL[entry.place.context] or entry.place.context)
    tooltip:AddDoubleLine(view.locale:get(TextKey.BAR_TOOLTIP_PLACE, name), tostring(entry.amount))
  end
end

-- Block three: what has not been earned yet. A separate block, never folded into
-- the sources above: it is a projection from the quest log, not experience
-- actually earned, so it must not read as part of a total that sums to the
-- level's percentage.
local function addPendingBlock(view, tooltip, viewModel)
  if viewModel.pending == nil or view.params == nil then
    return
  end

  local locale = view.locale
  blockBreak(tooltip)
  tooltip:AddDoubleLine(locale:get(TextKey.BAR_PENDING), tostring(view.params.questPending))

  local entries = view.questEntries ~= nil and view.questEntries() or nil
  if entries == nil then
    return
  end

  -- Only the quests with a reward anybody knows: entries() sorts unknown ones
  -- last precisely because there is no figure to print beside them, and a name
  -- with a blank number in a block about how much is pending is noise. How many
  -- of them there are is already reported, by the panel, as its own count.
  local named, rest, restTotal = 0, 0, 0
  for _, entry in ipairs(entries) do
    if entry.adjustedReward ~= nil then
      if named < QUESTS_IN_POPUP then
        named = named + 1
        tooltip:AddDoubleLine(
          locale:get(TextKey.BAR_TOOLTIP_QUEST, QuestNames.labelOf(view.questNames, locale, entry.questId)),
          tostring(entry.adjustedReward))
      else
        rest = rest + 1
        restTotal = restTotal + entry.adjustedReward
      end
    end
  end

  -- One line for everything that did not fit, with its own total: without the
  -- figure the reader cannot tell the three shown from the whole, and the block
  -- would look like it disagrees with its own heading.
  if rest > 0 then
    tooltip:AddDoubleLine(locale:get(TextKey.BAR_TOOLTIP_MORE, rest), tostring(restTotal))
  end
end

function XpBarView:attachTooltip()
  local frame = self.frame

  frame:SetScript("OnEnter", function()
    self.hovered = true
    self:showText()
    -- Where the player keeps their tooltips, not where this addon would like
    -- them. GameTooltip_SetDefaultAnchor is the client's own answer to that
    -- question, and it is the function every tooltip addon in the ecosystem
    -- hooks -- Leatrix, TipTac -- so honouring it is how a bar that is not the
    -- player's only addon behaves. Anchoring to the bar instead put the
    -- breakdown wherever the bar happened to be, which on a bar the player can
    -- drag anywhere is nowhere in particular.
    --
    -- The fallback is not defensive: it is the older clients this addon
    -- supports, where the function may simply not be there.
    if GameTooltip_SetDefaultAnchor ~= nil then
      GameTooltip_SetDefaultAnchor(GameTooltip, frame)
    else
      GameTooltip:SetOwner(frame, "ANCHOR_BOTTOM")
    end
    GameTooltip:AddLine(self.locale:get(TextKey.BAR_TOOLTIP_TITLE))

    local viewModel = self.viewModel
    if viewModel ~= nil and viewModel.active and self.record ~= nil then
      addLevelBlock(self, GameTooltip, viewModel)
      addZoneBlock(self, GameTooltip, self.record)
      addPendingBlock(self, GameTooltip, viewModel)
    end

    GameTooltip:Show()
  end)

  frame:SetScript("OnLeave", function()
    self.hovered = false
    self:showText()
    GameTooltip:Hide()
  end)
end

-- ---------------------------------------------------------------------------
-- Drag, lock, scale, position, click-to-toggle (10.5)
-- ---------------------------------------------------------------------------

function XpBarView:attachDrag()
  local frame = self.frame

  frame:SetScript("OnDragStart", function()
    -- Two different reasons not to move, and the player is told them apart
    -- elsewhere: locked is their own doing, the slot is the geometry not being
    -- this bar's to give (D50).
    if self.locked or self.slotFrame ~= nil then
      return
    end
    self.dragging = true
    frame:StartMoving()
  end)

  frame:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    local point, _, _, x, y = frame:GetPoint()
    self.saveSetting(SettingKey.BAR_POSITION, { point = point, x = x, y = y })
    self.dragging = false
  end)

  -- OnMouseUp always fires; OnDragStart only fires once the drag threshold is
  -- actually crossed. So a plain click never sets `dragging`, and this is the
  -- standard way a WoW frame tells a click apart from a drag without a
  -- hand-rolled timer or distance check.
  frame:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" and not self.dragging and self.onToggle ~= nil then
      self.onToggle()
    end
  end)
end

function XpBarView:setScale(scale)
  self.frame:SetScale(scale)
  self.saveSetting(SettingKey.BAR_SCALE, scale)
end

function XpBarView:setLocked(locked)
  self.locked = locked
  self.saveSetting(SettingKey.BAR_LOCKED, locked)
end

ns.ui.XpBarView = XpBarView
