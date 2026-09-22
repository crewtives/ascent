-- Ascent - the experience bar.
--
-- The compositor: where the bar sits, dragging, its text, when it hides, and
-- the two clocks that drive it. Painting is BarRenderer's, which knows none of
-- this, so the options panel's preview is a renderer with no compositor and
-- cannot move, persist or hide the real bar.
--
-- Two clocks. The data clock runs at 5 Hz: update() rebuilds the view-model,
-- recomposes the text and sets where the bar should end up. The presentation
-- clock runs every frame: tick() interpolates towards that target without
-- allocating, and stops once everything has arrived, so a bar at rest costs
-- nothing.
--
-- The bar never touches SavedVariables: it gets a resolved `settings` table and
-- a `saveSetting(key, value)` callback for position, lock state and scale.

local _, ns = ...
ns.ui = ns.ui or {}

local SettingKey = ns.core.SettingKey
local XpSource = ns.core.XpSource
-- The sentence for what a level was recorded without, shared with the panel and
-- the chat summary so the three say it the same way.
local UnavailableText = ns.core.UnavailableText
local RecordedSource = ns.core.RecordedSource
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

-- Tooltip labels, one per source: TextKey values resolved through `self.locale`
-- at the point of use. The same keys back the panel and the /ascent summary.
local SOURCE_LABEL = {
  [XpSource.MOB_KILL] = TextKey.SOURCE_CREATURES,
  [XpSource.QUEST_TURNIN] = TextKey.SOURCE_QUESTS,
  [XpSource.EXPLORATION] = TextKey.SOURCE_EXPLORATION,
  [XpSource.UNKNOWN] = TextKey.SOURCE_UNCLASSIFIED,
}

-- The same nouns the panel uses for a kind of place, so the bar and the panel
-- never name one thing two ways.
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

-- How far off the visible screen a saved position may be before it is pulled
-- back. Not zero, so the bar can sit half off an edge; small enough that a bar
-- saved on a monitor that is gone comes back within reach.
local OFFSCREEN_MARGIN = 40

-- ---------------------------------------------------------------------------
-- Small pure helpers, kept free of `self` so they stay easy to read in
-- isolation.
-- ---------------------------------------------------------------------------

-- `update`'s params are the bag XpBarViewModel.build reads (restedXp,
-- questPending, showQuestPending) plus the values forwarded into the bar's text
-- (buildTextValues); XpBarViewModel ignores unknown keys, so one table serves
-- both. `showQuestPending` defaults to the player's setting when not passed.
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

-- The values XpBarText.format needs. A field no caller supplies arrives nil,
-- and XpBarText renders nil as its not-available marker, never a made-up number.
-- xpCurrent/xpRemaining read viewModel.xpTotal, not record.xpTotal: it includes
-- experience the client confirmed but XpAttribution has not yet assigned to a
-- source, so the number moves within one redraw tick of a kill.
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
-- Construction and appearance
-- ---------------------------------------------------------------------------

-- Pulled back inside the visible screen when the saved position is out of
-- reach: the position is re-applied on every login, so a bar saved on a
-- detached monitor would otherwise stay where it cannot be dragged back.
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
  -- While the bar sits in the client's slot the saved position stays on disk
  -- untouched and is not applied, so turning the slot off is a complete undo.
  if self.slotFrame ~= nil then
    return
  end
  -- No "is one saved?" branch: BAR_POSITION's default declares its shape and
  -- Settings.resolve completes a stored one key by key, so it is always whole.
  local position = self:clampedPosition(self.settings[SettingKey.BAR_POSITION])
  self.frame:ClearAllPoints()
  self.frame:SetPoint(position.point, UIParent, position.point, position.x, position.y)
end

-- ---------------------------------------------------------------------------
-- The client's slot
-- ---------------------------------------------------------------------------

-- The width and height the bar actually has, not what the player configured.
-- Anchored to the client's bar, the settings are suspended and the measure is
-- this frame's own, not the client frame's: the two may differ in scale, and
-- the anchor resolves that between them.
--
-- Asked of the slot every time, never cached: a remembered measure goes stale,
-- and a repaint from it draws the bar across the client's frame. It costs two
-- calls on a settings change and none on a redraw.
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

-- Anchored rather than copying geometry, so interface scale, resolution, the
-- player or another addon moving the client's bar needs no event handling.
--
-- Position and size only, not visibility: the client hides its own bar on its
-- own schedule, and this bar's showing and hiding belongs to the player.
--
-- Depth is re-stated on every attach, since a copy goes stale: the chosen slot
-- decides whether the client's frame art draws over this bar or under it
-- (BarSlotPolicy.depth, applyDepth).
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

  -- Re-measured even on the same frame: the player can switch between the two
  -- active slots without passing through off.
  self:applyDepth(clientFrame, slot)
  self:inheritSize()
  return self
end

-- Where the bar sits in the drawing order while in the client's slot: the
-- client frame's strata, and the level the chosen slot asks for.
--
-- Re-applied on every attach, not once per frame change: the client moves the
-- level silently (a loading screen, its own layout pass, another addon), and
-- Bootstrap re-attaches on PLAYER_ENTERING_WORLD and every settings change. A
-- depth set once ends up with the bar painting over the client's frame art.
--
-- Every call is guarded: the frame comes from _G by name, and a name another
-- addon took must cost the depth, not the bar. Each value is written only when
-- it differs, because this also runs on the data tick (holdDepth): the reads
-- are cheap, the writes are what a frame notices.
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
  -- Kept so the diagnostic prints the level asked for beside the one the frame
  -- reads back: a client that refuses a level, or something that moves it later,
  -- otherwise looks exactly like a rule that computed the wrong number.
  self.wantedLevel = level
  if level ~= nil and self.frame:GetFrameLevel() ~= level then
    self.frame:SetFrameLevel(level)
  end
  return self
end

-- How many frames up the client's chain to look for the floor. The art that
-- must stay on top belongs to the anchor's parent; four leaves room for a
-- client that nests one or two deeper without walking to UIParent on a tick.
local SLOT_CHAIN = 4

-- The lowest level among the client frames whose art must draw over this bar:
-- the anchor and the frames it hangs from, where the client bar's frame art
-- lives (BarSlotPolicy.depth says why the anchor alone is not enough).
--
-- Only ancestors in the same strata count: a frame in another strata does not
-- compete on level, and its number could drag the bar below where it belongs.
-- Nil when the chain says nothing, so the rule falls back on the anchor's level.
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
    -- UIParent is everyone's ancestor and says nothing about the art around the
    -- client's bar, so the walk ends there.
    if frame == UIParent or frame.GetParent == nil then
      break
    end
    frame = frame:GetParent()
  end
  return floor
end

-- The depth, held rather than set once.
--
-- Re-applying on attach is not enough: the client re-lays its main bar out at
-- moments of its own, closing its settings panel among them, and the depth set
-- earlier is stale by then. So it is re-applied on the 5 Hz data tick, like the
-- slot's size (barWidth); not per frame, since the client does not move a
-- level between two frames of animation.
function XpBarView:holdDepth()
  if self.slotFrame == nil then
    return self
  end
  return self:applyDepth(self.slotFrame, self.slot)
end

-- The slot's measure, in this frame's coordinates.
--
-- Read from the client's frame, not ours: ours was just anchored and is not laid
-- out yet, so it would answer with the pre-slot size and paint one frame at the
-- old width. Scaled by GetEffectiveScale, because the two frames may differ in
-- scale: they cover the same screen area in different numbers of points.
function XpBarView:slotSize(clientFrame)
  local width, height = clientFrame:GetWidth(), clientFrame:GetHeight()
  local theirs, ours = clientFrame:GetEffectiveScale(), self.frame:GetEffectiveScale()
  if type(theirs) ~= "number" or type(ours) ~= "number" or ours == 0 then
    return width, height
  end
  return width * theirs / ours, height * theirs / ours
end

-- Where the bar draws, for the diagnostic to print next to the client's rows.
-- Asked of the frame, not remembered: what was last set is not necessarily
-- what the drawing order is.
function XpBarView:depth()
  if self.frame.GetFrameStrata == nil or self.frame.GetFrameLevel == nil then
    return nil, nil
  end
  return self.frame:GetFrameStrata(), self.frame:GetFrameLevel(), self.wantedLevel
end

-- Back to the bar the player had. Nothing in the settings was overwritten, so
-- reapplying the saved position and size is all it takes.
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
  -- Position first, then size. In the slot the frame was held by SetAllPoints
  -- on the client's, which pins both corners, and a frame pinned at both corners
  -- ignores SetSize. applySavedPosition releases those anchors, so sizing before
  -- it would leave the bar at the client's width.
  self:applySavedPosition()
  self.renderer:setSize(self.settings[SettingKey.BAR_WIDTH], self.settings[SettingKey.BAR_HEIGHT])
  self.renderer:applyAppearance(self.appearance)
  return self
end

-- The slot changed shape: repaint at what it measures now. In the slot the
-- measure comes from the frame, not a setting, and a zero (a frame the client
-- has not laid out yet) is ignored, since a renderer sized zero draws nothing.
-- It ignores the size OnSizeChanged passes and asks the slot at the moment of
-- use, rather than keeping a copy.
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

-- The appearance the renderer paints: the chosen skin, the player's tweaks on
-- top, and the palette. Resolved in core/ and handed over whole, so this file
-- never knows which skin it shows.
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

  -- In the client's slot the bar shows no text (see showText), so the anchor is
  -- left alone: the player's choice is suspended, not overruled.
  if self.slotFrame ~= nil then
    return appearance
  end

  if inside then
    if BarGeometry.textFitsInside(self:barHeight(), text.size) then
      return appearance
    end
    wanted = self:outsideTextAnchor(text.size)
  elseif text.anchor == TextAnchor.BELOW then
    -- Below may have no room, as when the action bar sits there. This checks a
    -- below chosen by the player or the skin as well as one chosen here.
    wanted = self:outsideTextAnchor(text.size)
  end

  if wanted == text.anchor then
    return appearance
  end

  -- A bar thinner than the text cannot hold it inside. Resolved again rather
  -- than edited: the result is frozen, and the skin's text size is only known
  -- after resolving once. This runs on settings and size changes, never on a
  -- redraw, so twice costs nothing.
  options.textAnchor = wanted
  return SkinResolver.resolve(options)
end

-- Which side the text goes to when it has to leave the bar. The room below is
-- the bar's distance from the bottom of the screen; near the bottom, text there
-- would draw behind the action bar. Unknown room (a frame not laid out yet)
-- keeps the conventional side rather than guessing.
function XpBarView:outsideTextAnchor(textSize)
  -- The frame may not exist yet: the constructor resolves the appearance
  -- before it creates the frame, and a skin whose text sits below reaches this
  -- during construction. BarGeometry treats a nil room as unknown.
  local bottom = self.frame ~= nil and self.frame:GetBottom() or nil
  return BarGeometry.textAnchorOutside(bottom, textSize)
end

-- The composed text, and whether it is shown right now. Kept apart because the
-- bar can be set to show text only on hover: the text is still composed on
-- every update, since the cursor may arrive at any moment.
function XpBarView:showText(value)
  if value ~= nil then
    self.composedText = value
  end
  -- No text while the bar stands in the client's slot: the strip is about
  -- twelve pixels tall, too thin to read a line in, and every place outside it
  -- is the client's own interface. The tooltip carries the full readout.
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
  -- The free bar's drawing order, read rather than chosen: a bar that never
  -- enters the slot keeps its default depth, and one that leaves the slot gets
  -- this same depth back.
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
    -- The same directory the panel reads, so a quest is named the same way on
    -- both. Optional: without it the bar numbers its quests.
    questNames = options.questNames,
    -- A function called once when the popup opens, not data carried on every
    -- update: building and sorting the pending entries five times a second,
    -- hovered or not, is the cost `placesFor` also avoids.
    questEntries = options.questEntries,
    -- A local, mutable copy: self.settings is frozen, and the lock changes
    -- during play.
    locked = options.settings[SettingKey.BAR_LOCKED],
    dragging = false,
    tween = BarTween.new({ channels = channelIds() }),
    pulse = Pulse.new(),
    level = nil,
    -- The last total the bar was given, so a redraw flashes only when the
    -- player gained experience.
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

-- Re-reads settings and reapplies everything that comes out of them, at once
-- and without a reload, rebuilding no frame or texture: a WoW frame cannot be
-- destroyed, so every rebuild would leak one.
function XpBarView:applySettings(settings)
  self.settings = settings or self.settings
  self.appearance = self:resolveAppearance()
  self.frame:SetScale(self.settings[SettingKey.BAR_SCALE])
  -- barWidth/barHeight, not the settings: in the client's slot those settings
  -- are suspended and the measure is inherited.
  self.renderer:setSize(self:barWidth(), self:barHeight())
  self.renderer:applyAppearance(self.appearance)
  self:showText()
  self:applySavedPosition()
  self:paint()
  return self
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

-- The composed text, shortened until it fits. Fields are dropped in the order
-- TEXT_PRIORITY declares, lowest rank first, so a narrow bar always sheds the
-- same fields rather than the longest. Only when the text sits inside the bar:
-- above or below it has the screen's width.
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
-- Drawing and the presentation clock
-- ---------------------------------------------------------------------------

function XpBarView:paint()
  self.renderer:draw(self.tween:boundaries())
  self.renderer:setFlash(self.pulse:alpha())
  return self
end

-- Called every frame by the composition root from its existing OnUpdate, not a
-- second per-frame script. Returns whether the bar is still moving; the cheap
-- exit for a resting bar is here whatever the caller does with it.
function XpBarView:tick(elapsed)
  local moving = self.tween:advance(elapsed)
  local flashing = self.pulse:advance(elapsed)
  if not moving and not flashing then
    return false
  end
  self:paint()
  return true
end

-- Nothing to show: max level, or experience disabled. No segment, rested mark,
-- pending channel or token text: without an active level those numbers mean
-- nothing, and zeroes would mislead. `HIDE_WITHOUT_XP` chooses between hiding
-- the bar and showing a fixed status line.
function XpBarView:drawInactive()
  self.renderer:hideProgress()
  if self.settings[SettingKey.HIDE_WITHOUT_XP] then
    self.frame:Hide()
    return
  end
  self.frame:Show()
  self:showText(self.locale:get(TextKey.BAR_NO_XP))
end

-- Rebuilds the view-model from `record`/`params` and sets where the bar should
-- end up: the 5 Hz half. It sets the target; tick() walks there.
function XpBarView:update(record, params)
  -- Before the early return below: a bar with nothing to show may still stand
  -- in the client's slot, and the client re-levels its frames regardless.
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

  -- A level-up is a reset, not a move: animating down from full would show a
  -- finished level that is no longer the player's. The vector drops to zero at
  -- once and only the new level's progress animates in.
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
-- Tooltip
-- ---------------------------------------------------------------------------

-- How many quests the popup names before counting the rest. Presentation, not
-- data: the popup answers at a glance, the panel in full.
local QUESTS_IN_POPUP = 3

-- A blank line between blocks: GameTooltip has no rule to draw, and headed
-- blocks running together read as one list.
local function blockBreak(tooltip)
  tooltip:AddLine(" ")
end

-- Block one: the level. Its total first, then the sources that make it up.
local function addLevelBlock(view, tooltip, viewModel)
  local locale = view.locale
  local levelPercent = locale:get(TextKey.PERCENT, math.floor(viewModel.percentComplete * 100 + 0.5))
  tooltip:AddDoubleLine(locale:get(TextKey.BAR_TOOLTIP_LEVEL),
    locale:get(TextKey.BAR_TOOLTIP_VALUE, viewModel.xpTotal, levelPercent))

  local observation = viewModel.observation
  local declared = false
  -- Why creatures are not among the sources, when they are not. Printed under
  -- the unclassified line, the bucket it explains.
  local unnamed = viewModel.sourcesUnavailable ~= nil
    and locale:get(UnavailableText[RecordedSource.XP_CHAT][viewModel.sourcesUnavailable]) or nil
  local unnamedSaid = false

  for _, segment in ipairs(viewModel.segments) do
    -- segment.amount, not record:xpFrom(segment.source): UNKNOWN's segment
    -- includes experience the client confirmed but attribution has not
    -- assigned yet.
    local percentText = locale:get(TextKey.PERCENT, math.floor(segment.fraction * 100 + 0.5))
    tooltip:AddDoubleLine(locale:get(TextKey.BAR_TOOLTIP_PLACE, locale:get(SOURCE_LABEL[segment.source])),
      locale:get(TextKey.BAR_TOOLTIP_VALUE, segment.amount, percentText))

    -- Under the unclassified line, the bucket this splits. The split is printed
    -- beneath the figures, never subtracted from them, so the percentages still
    -- sum to the level's.
    if unnamed ~= nil and segment.source == XpSource.UNKNOWN then
      tooltip:AddLine(unnamed, nil, nil, nil, true)
      unnamedSaid = true
    end
    if observation ~= nil and segment.source == XpSource.UNKNOWN then
      declared = true
      if observation.seededXp ~= nil then
        tooltip:AddDoubleLine(locale:get(TextKey.BAR_NOT_OBSERVED), tostring(observation.seededXp))
        -- Omitted at zero: everything unclassified came in with the level, and
        -- a "0" would suggest a failure that did not happen.
        if observation.unexplainedXp > 0 then
          tooltip:AddDoubleLine(locale:get(TextKey.BAR_UNEXPLAINED), tostring(observation.unexplainedXp))
        end
      else
        -- A record saved before the addon kept this figure: it can only say
        -- the accounting is incomplete.
        tooltip:AddLine(locale:get(TextKey.BAR_PARTIAL))
      end
    end
  end

  -- A partial level with nothing unclassified to print it under (opened at its
  -- first point, or its seed spent by a level-up): the mark is about the
  -- recording, not the bucket, so it is still shown.
  if observation ~= nil and not declared then
    tooltip:AddLine(locale:get(TextKey.BAR_PARTIAL))
  end
  -- Nothing unclassified yet to print it under: it is still true of the level.
  if unnamed ~= nil and not unnamedSaid then
    tooltip:AddLine(unnamed, nil, nil, nil, true)
  end
end

-- Block two: where it was earned. One line per place, never one per place per
-- source; source by place is the panel's.
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
-- the sources: it is a projection from the quest log, not earned experience,
-- and must not read as part of the level's total.
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

  -- Only quests with a known reward: entries() sorts unknown ones last, and a
  -- name without a figure is noise here. The panel reports their count.
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

  -- One line for the rest, with its total, so the block still adds up to its
  -- heading.
  if rest > 0 then
    tooltip:AddDoubleLine(locale:get(TextKey.BAR_TOOLTIP_MORE, rest), tostring(restTotal))
  end
end

function XpBarView:attachTooltip()
  local frame = self.frame

  frame:SetScript("OnEnter", function()
    self.hovered = true
    self:showText()
    -- Where the player keeps tooltips: GameTooltip_SetDefaultAnchor is the
    -- client's answer, and the function tooltip addons such as Leatrix and
    -- TipTac hook. The SetOwner fallback is for older clients that may lack it.
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
-- Drag, lock, scale, position, click-to-toggle
-- ---------------------------------------------------------------------------

function XpBarView:attachDrag()
  local frame = self.frame

  frame:SetScript("OnDragStart", function()
    -- Two reasons not to move, reported to the player separately elsewhere:
    -- locked is their choice; in the slot the geometry is the client frame's.
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

  -- OnMouseUp always fires; OnDragStart only once the drag threshold is
  -- crossed. So a plain click never sets `dragging`, which tells a click from a
  -- drag without a timer or distance check.
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
