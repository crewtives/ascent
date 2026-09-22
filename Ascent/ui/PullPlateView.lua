-- Ascent - the pull plate: a small frame that counts while the fight is
-- happening, and becomes a plaque when it is over.
--
-- Everything on it is live from the first blow: the list counts what is being
-- fought, not what has fallen (PullRecord's `engaged` half), abilities and
-- damage appear at once, and the header shows what the level still needs.
-- Closing a pull changes only that the numbers stop moving; the skin's effects
-- fire once to say so.
--
-- It does not freeze when combat ends (see PullPhase in
-- core/constants/Metrics.lua): in Classic a kill's experience often arrives
-- after the client has reported combat over. Between running and closed is a
-- visible settling state; closing at PLAYER_REGEN_ENABLED would drop the pull's
-- last kill on most fights.
--
-- This file owns a frame, its position and which rows show, and no arithmetic:
-- numbers come from PullViewModel, effects from ui/Effects.lua, so the logic is
-- testable without a client. Every row is built once, up to the view-model's
-- ceiling (the most rows a setting can ask for), and hidden rather than
-- destroyed, so nothing is allocated per pull in combat.

local _, ns = ...
ns.ui = ns.ui or {}

local TextKey = ns.core.TextKey
local XpSource = ns.core.XpSource
local Palette = ns.core.Palette
local PullPhase = ns.core.PullPhase
local PullViewModel = ns.core.PullViewModel
local KillXpEstimator = ns.core.KillXpEstimator
local AbilityKey = ns.core.AbilityKey
local SkinResolver = ns.core.SkinResolver
local SkinCatalog = ns.core.SkinCatalog
local SettingKey = ns.core.SettingKey
local Defaults = ns.core.Defaults
local PlateLayout = ns.core.PlateLayout
local PlateZone = ns.core.PlateZone
local Effects = ns.ui.Effects

-- Width, hold time, row counts and zones are settings; padding, row height,
-- chip and icon sizes, the header offsets and the height floor come from
-- core/service/PlateLayout.lua, which is tested.
--
-- The one number kept here: how long a finished plaque takes to fade once its
-- hold is over. It is not a setting of its own, because the motion scale
-- already governs movement.
local FADE_SECONDS = 1.2

-- The chip row carries colour only, in the bar's own colours, so what a colour
-- means on the bar it means here; labels would take the numbers' room.
local SOURCE_PALETTE = {
  [XpSource.MOB_KILL] = "MOB_KILL",
  [XpSource.QUEST_TURNIN] = "QUEST_TURNIN",
  [XpSource.EXPLORATION] = "EXPLORATION",
  [XpSource.UNKNOWN] = "UNKNOWN",
}

-- How strongly the headline is drawn for each provenance the forecast can have.
-- The alpha is the mark: a glyph beside the digits cannot be aligned with them
-- (see the headline counter), so three claims get three weights of colour.
--
-- The order must match BASIS_CONFIDENCE in core/service/PullViewModel.lua,
-- which picks the basis of a sum.
local BASIS_ALPHA = {
  [KillXpEstimator.Basis.CREATURE] = 1,
  [KillXpEstimator.Basis.MIXED] = 0.8,
  [KillXpEstimator.Basis.LEVEL] = 0.6,
}

local PullPlateView = {}
PullPlateView.__index = PullPlateView

-- ---------------------------------------------------------------------------
-- Formatting. Small, local, and free of `self` so they read on their own.
-- ---------------------------------------------------------------------------

-- Thousands folded into a k: the headline has about six characters of room.
-- Below a thousand it is the exact figure, so a 44-experience kill is not
-- "0.0k".
local function compact(value)
  if value == nil then
    return "-"
  end
  value = math.floor(value + 0.5)
  if value >= 10000 then
    return ("%dk"):format(math.floor(value / 1000))
  elseif value >= 1000 then
    return ("%.1fk"):format(value / 1000)
  end
  return tostring(value)
end

-- The two attacks with no spell behind them, each named and given the icon of
-- the client's own spell for it (Auto Attack 6603, Auto Shot 75), so every row
-- has a picture. The report panel leaves them iconless.
--
-- The labels are TextKeys shared with the panel, so both surfaces tell a melee
-- swing from a ranged shot the same way.
local AUTO_ATTACK = {
  [AbilityKey.MELEE_SWING] = { label = TextKey.PANEL_AUTO_ATTACK, spell = 6603 },
  [AbilityKey.RANGED_AUTO] = { label = TextKey.PANEL_RANGED_ATTACK, spell = 75 },
}

-- The one way this addon asks for an ability's icon, shared with the panel's
-- ranking: see ui/SpellIcon.lua.
local spellTexture = ns.ui.SpellIcon.texture

-- What the row is called and shows, for a spell or either auto attack. `name`
-- is the combat log's, cached when the ability was used, and preferred: the
-- client can later fail to resolve an id it named at the time.
local function abilityRow(locale, entry)
  local auto = AUTO_ATTACK[entry.key]
  if auto ~= nil then
    return locale:get(auto.label), spellTexture(auto.spell)
  end
  return entry.name or locale:get(TextKey.PANEL_SPELL, tostring(entry.key)), spellTexture(entry.key)
end

local function clockText(locale, seconds)
  seconds = math.floor(seconds or 0)
  if seconds >= 60 then
    return locale:get(TextKey.DURATION_MS, math.floor(seconds / 60), seconds % 60)
  end
  return locale:get(TextKey.DURATION_S, seconds)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

local function newFontString(parent, size, justify, flags)
  local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  local path = text:GetFont()
  if path ~= nil then
    text:SetFont(path, size, flags or "OUTLINE")
  end
  text:SetJustifyH(justify or "LEFT")
  return text
end

-- Re-sizes a font string already built, keeping its face and flags. They are
-- read back rather than restated because the outline differs per region: the
-- headline is thick-outlined and the rows are not.
local function resizeFont(text, size)
  local path, current, flags = text:GetFont()
  if path == nil or current == size then
    return
  end
  text:SetFont(path, size, flags)
end

-- options: parent, settings, saveSetting, locale, levelProgress, levelRecord,
-- sharedBy
--
-- `levelProgress` is a function returning { remaining, percent } for the level
-- in progress, or nil when there is none (max level, gain switched off, nothing
-- recorded yet). A function, like every seam here: the plate asks when it
-- draws, and never learns that a LevelRecord exists.
function PullPlateView.new(options)
  options = options or {}
  if options.locale == nil then
    error("PullPlateView needs a locale", 2)
  end

  local frame = CreateFrame("Frame", "AscentPullPlate", options.parent or UIParent)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:Hide()

  local self = setmetatable({
    frame = frame,
    locale = options.locale,
    settings = options.settings,
    saveSetting = options.saveSetting,
    levelProgress = options.levelProgress,
    levelRecord = options.levelRecord,
    -- How many are sharing the pay right now, also a function: what a creature
    -- pays depends on how many split it, so the forecast is priced for the group
    -- at each draw.
    sharedBy = options.sharedBy,
    appearance = nil,

    -- Which pull is on screen, so a redraw of the same pull does not restart a
    -- counter and a new pull does.
    generation = nil,
    phase = PullPhase.IDLE,
    -- Seconds the finished plaque has been up. nil while a pull is running:
    -- a plate that faded mid-fight would take the numbers with it.
    heldFor = nil,
    counters = {},
  }, PullPlateView)

  self:build()
  self:applyFrame()
  self:applyPosition()
  return self
end

-- ---------------------------------------------------------------------------
-- What the plate reads about itself
-- ---------------------------------------------------------------------------

-- One of the plate's settings, with the default when there is no settings
-- table (built before saved variables loaded, or by a test). Every key read
-- here is declared in Defaults, so neither read raises on the frozen table.
function PullPlateView:setting(key)
  if self.settings == nil then
    return Defaults[key]
  end
  return self.settings[key]
end

-- The text size the player gave the plate, or nil for its default size. Not
-- the resolved appearance's `text.size`: the plate ignores the skin's text size,
-- style and anchor, so existing plates keep their size. Read through
-- SkinResolver because the map is partial and frozen: indexing an axis the
-- player never touched raises.
function PullPlateView:ownTextSize()
  local own = self:setting(SettingKey.PLATE_APPEARANCE)
  return SkinResolver.fieldOf(SkinResolver.fieldOf(own, "text"), "size")
end

-- Where every piece of the plate sits, for a body holding this many rows. The
-- header's offsets depend only on the text size and the zones, so applyFrame
-- places the header once per settings change and each draw places the body.
function PullPlateView:layoutFor(creatures, abilities)
  return PlateLayout.lay({
    textSize = self:ownTextSize(),
    zones = self:setting(SettingKey.PLATE_ZONES),
    creatures = creatures,
    abilities = abilities,
  })
end

-- The alpha the frame should show now: how far through the hold and the fade
-- it is, times the player's opacity factor.
--
-- The factor multiplies the frame's alpha, which is also the fade channel, so
-- every place that restores the frame's alpha goes through this one function;
-- missing one would bring the plate back to full opacity on that path.
function PullPlateView:currentAlpha()
  local factor = self:setting(SettingKey.PLATE_OPACITY)
  local held = self.heldFor
  local hold = self:setting(SettingKey.PLATE_HOLD_SECONDS)
  if held == nil or held <= hold then
    return factor
  end
  local left = 1 - (held - hold) / FADE_SECONDS
  if left < 0 then
    left = 0
  end
  return left * factor
end

function PullPlateView:build()
  local frame = self.frame
  -- Built at the sizes the settings ask for. The layout for an empty body is
  -- enough: fonts and header do not depend on the body, and nothing has been
  -- fought yet.
  local layout = self:layoutFor(0, 0)
  local font = layout.font

  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(frame)
  self.background = background

  self.border = Effects.plaqueBorder(frame, { size = 1, inset = 0 })

  -- Header: what this is, and how long it has been going.
  self.title = newFontString(frame, font.title, "LEFT")
  self.title:SetText(self.locale:get(TextKey.PLATE_TITLE))

  self.clock = newFontString(frame, font.title, "RIGHT")

  -- The headline: experience, big, counting.
  self.xp = newFontString(frame, font.headline, "LEFT", "THICKOUTLINE")
  -- One number, always: while the pull runs, what it is on course to be worth;
  -- once the experience has landed, that figure. The same counter carries both,
  -- so confirmation walks from the estimate to the real figure.
  --
  -- No marker glyph: a tilde sits above the digits' baseline in the client's
  -- font, and a font string cannot centre one glyph against another. The
  -- estimate is marked by colour instead; see composeProjection.
  self.counters.xp = Effects.counter(self.xp, function(value)
    return self.locale:get(TextKey.PLATE_XP, compact(value))
  end)

  -- Kills and the running chain, right-aligned against the headline.
  self.kills = newFontString(frame, font.kills, "RIGHT", "THICKOUTLINE")
  -- Reads "killed/engaged" while any is still standing, and the plain count once
  -- all are down: during the fight what matters is how many are left.
  self.counters.kills = Effects.counter(self.kills, function(value)
    if self.pending ~= nil and self.pending > 0 then
      return self.locale:get(TextKey.PLATE_KILLS_OF, value, self.engaged or value)
    end
    return self.locale:get(TextKey.PLATE_KILLS, value)
  end)

  -- How much the level still needs, never drawn as the pull's own number: the
  -- plate is on screen between fights, when the player asks it.
  -- Anchored to the frame, not to the headline above, through PlateLayout's
  -- offsets: a font string's height follows its text, so hanging it off one
  -- would move every row below whenever the number got longer.
  self.remaining = newFontString(frame, font.body, "LEFT")

  self.streak = newFontString(frame, font.streak, "RIGHT")
  self.streak:SetPoint("TOPRIGHT", self.kills, "BOTTOMRIGHT", 0, -1)

  -- The chip row: the pull's experience split by source, in the bar's colours
  -- and order. One texture per source, sized by share.
  self.chips = {}
  for index = 1, PullViewModel.SOURCE_COUNT do
    local chip = frame:CreateTexture(nil, "ARTWORK")
    chip:Hide()
    self.chips[index] = chip
  end

  -- A hairline between header and body, so the source bar and the first
  -- creature row do not read as one block.
  self.rule = frame:CreateTexture(nil, "ARTWORK")
  self.rule:SetHeight(1)
  self.rule:Hide()

  -- Everything below here belongs to the plaque and is hidden while the fight
  -- is running.
  self.detail = {}

  self.creatureRows = {}
  for index = 1, PullViewModel.ROW_CEILING do
    local row = { name = newFontString(frame, font.body, "LEFT"),
                  count = newFontString(frame, font.body, "RIGHT") }
    row.name:Hide()
    row.count:Hide()
    self.creatureRows[index] = row
    self.detail[#self.detail + 1] = row.name
    self.detail[#self.detail + 1] = row.count
  end

  self.abilityRows = {}
  for index = 1, PullViewModel.ROW_CEILING do
    local row = {
      icon = frame:CreateTexture(nil, "ARTWORK"),
      name = newFontString(frame, font.body, "LEFT"),
      count = newFontString(frame, font.body, "RIGHT"),
    }
    -- The client's icons carry a border baked into the outer few pixels; trim
    -- it, as every addon does.
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon:Hide()
    row.name:Hide()
    row.count:Hide()
    self.abilityRows[index] = row
    self.detail[#self.detail + 1] = row.name
    self.detail[#self.detail + 1] = row.count
  end

  self.footerLeft = newFontString(frame, font.body, "LEFT")
  self.footerRight = newFontString(frame, font.body, "RIGHT")
  self.detail[#self.detail + 1] = self.footerLeft
  self.detail[#self.detail + 1] = self.footerRight
  self.detail[#self.detail + 1] = self.rule
  self.detail[#self.detail + 1] = self.remaining

  self:makeMovable()
end

function PullPlateView:makeMovable()
  local frame = self.frame
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(moved)
    -- Its own lock, not the bar's: a bar is placed once and locked, a plate
    -- moves with the fighting, and the bar's lock is disabled while the bar
    -- takes the client's slot.
    if self:setting(SettingKey.PLATE_LOCKED) then
      return
    end
    moved:StartMoving()
  end)
  frame:SetScript("OnDragStop", function(moved)
    moved:StopMovingOrSizing()
    if self.saveSetting == nil then
      return
    end
    -- Both halves of the anchor: the client re-anchors a moved frame, and the
    -- point it is hung by is not always the point it is hung to. The bar saves
    -- one because its size is stable; this frame is resized on every draw.
    local point, _, relativePoint, x, y = moved:GetPoint()
    self.saveSetting(SettingKey.PLATE_POSITION, {
      point = point or "CENTER",
      relativePoint = relativePoint or point or "CENTER",
      x = x or 0,
      y = y or 0,
    })
  end)
end

-- Re-reads the settings and reapplies everything that comes out of them, like
-- XpBarView:applySettings.
--
-- It must rebind `self.settings`: Settings.resolve builds a new frozen table on
-- every save, and a plate reading the table it captured at construction would
-- re-anchor to its old position right after a drag saved the new one.
function PullPlateView:applySettings(settings)
  self.settings = settings or self.settings
  -- Before the skin: building an effect sizes its textures to the frame, so a
  -- new width or scale must land first.
  self:applyFrame()
  self:applySkin(self.settings[SettingKey.BAR_SKIN], self.settings[SettingKey.BAR_APPEARANCE],
    self.settings[SettingKey.BAR_COLORS], self.settings[SettingKey.HIGH_CONTRAST])
  -- After it: the saved anchor is re-read once its scale is in force. An
  -- anchor's offsets are in the frame's own scale, and whether a scale applied
  -- after an anchor moves the frame is not yet measured in the client, so
  -- nothing compensates: that would move plates that sit where they were left.
  self:applyPosition()
  self.frame:SetAlpha(self:currentAlpha())
  return self
end

-- The scale, the width and the height the contents ask for, and everything
-- whose size follows the text size rather than the pull.
--
-- Run on a settings change, not on every draw, since none of it depends on the
-- fight. A draw places only the body, whose blocks move with the row counts.
function PullPlateView:applyFrame()
  local layout = self:layoutFor(0, 0)

  self.frame:SetScale(self:setting(SettingKey.PLATE_SCALE))
  self.frame:SetSize(self:setting(SettingKey.PLATE_WIDTH), layout.height)

  self:place(layout)
  self:resizeEffects()
  return self
end

-- Where the header sits and how big every piece of text is. Takes the layout
-- rather than asking for one, so a draw places its body with the same
-- arithmetic that placed the header.
function PullPlateView:place(layout)
  local frame, font, padding = self.frame, layout.font, layout.padding

  local function at(region, corner, x, y)
    region:ClearAllPoints()
    region:SetPoint(corner, frame, corner, x, y)
  end

  resizeFont(self.title, font.title)
  at(self.title, "TOPLEFT", padding, -layout.header.title)
  resizeFont(self.clock, font.title)
  at(self.clock, "TOPRIGHT", -padding, -layout.header.title)

  resizeFont(self.xp, font.headline)
  at(self.xp, "TOPLEFT", padding, -layout.header.xp)
  resizeFont(self.kills, font.kills)
  at(self.kills, "TOPRIGHT", -padding, -layout.header.xp)

  resizeFont(self.remaining, font.body)
  at(self.remaining, "TOPLEFT", padding, -layout.header.remaining)
  -- The chain is the one region hung off a neighbour rather than the frame:
  -- above it in the same column is the count, which cannot grow into it, and
  -- PlateLayout models it there.
  resizeFont(self.streak, font.streak)

  self.rule:ClearAllPoints()
  self.rule:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -layout.header.rule)
  self.rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -padding, -layout.header.rule)

  for _, chip in ipairs(self.chips) do
    chip:SetHeight(layout.chipHeight)
  end
  for _, row in ipairs(self.creatureRows) do
    resizeFont(row.name, font.body)
    resizeFont(row.count, font.body)
  end
  for _, row in ipairs(self.abilityRows) do
    resizeFont(row.name, font.body)
    resizeFont(row.count, font.body)
    row.icon:SetSize(layout.iconSize, layout.iconSize)
  end
  resizeFont(self.footerLeft, font.body)
  resizeFont(self.footerRight, font.body)
  return self
end

function PullPlateView:applyPosition()
  local position = self.settings ~= nil and self.settings[SettingKey.PLATE_POSITION] or nil
  self.frame:ClearAllPoints()
  if position == nil then
    self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
    return
  end
  local point = position.point or "CENTER"
  self.frame:SetPoint(point, UIParent, position.relativePoint or point, position.x or 0, position.y or 0)
end

-- ---------------------------------------------------------------------------
-- Appearance
-- ---------------------------------------------------------------------------

-- Takes the same resolved appearance as the bar, from the same resolver, so a
-- skin switch changes both at once. Effects are rebuilt rather than retuned:
-- a handful of textures per skin change is not a hot path.
function PullPlateView:applyAppearance(appearance)
  self.appearance = appearance

  local background = appearance.background
  self.background:SetColorTexture(background.r, background.g, background.b,
    -- Floored, unlike the bar's: a bar may be invisible (the phantom skin)
    -- because its segments carry it, but a plate without one is floating text.
    math.max(background.a or 0, 0.72))

  self.rule:SetColorTexture(appearance.accent.r, appearance.accent.g, appearance.accent.b, 0.28)

  self.border:setColor(appearance.accent)
  self.border:setThickness(math.max(1, appearance.border.thickness))
  self.border:show()

  for _, text in ipairs({ self.title, self.clock, self.streak, self.footerLeft, self.footerRight }) do
    local color = appearance.text.color
    text:SetTextColor(color.r, color.g, color.b, color.a or 1)
  end
  self.title:SetTextColor(appearance.accent.r, appearance.accent.g, appearance.accent.b, 1)
  -- Dimmer than the rows they sit under: these are labels, not findings.
  local muted = appearance.text.color
  for _, text in ipairs({ self.clock, self.remaining, self.footerLeft, self.footerRight }) do
    text:SetTextColor(muted.r, muted.g, muted.b, 0.7)
  end

  self:buildEffects(appearance.effects)
  return self
end

-- Everything an effect is built from, as one comparable string.
-- applyAppearance runs on every settings change, and an animation group cannot
-- be destroyed, so effects are rebuilt only when this changes.
local function effectSignature(effects, scale, opacity)
  local parts = { ("%.3f|%.3f"):format(scale, opacity) }
  for _, name in ipairs({ "glow", "sweep", "burst" }) do
    local spec = effects[name]
    local color = spec.color
    -- Alpha included: Effects tints with the whole colour, so a change of alpha
    -- alone must still trigger a rebuild. Everything the plate's appearance map
    -- can reach has to be in the signature.
    parts[#parts + 1] = ("%s|%.3f|%.2f,%.2f,%.2f,%.2f")
      :format(spec.kind, spec.duration, color.r, color.g, color.b, color.a)
  end
  parts[#parts + 1] = ("%.2f|%d|%.1f|%.1f|%.3f")
    :format(effects.glow.peak, effects.burst.count, effects.burst.rise, effects.burst.spread, effects.burst.stagger)
  return table.concat(parts, "/")
end

-- Durations are multiplied by the player's motion scale here, so a scale of
-- zero gives zero durations, which Effects turns into its inert object.
function PullPlateView:buildEffects(effects)
  local scale = 1
  if self.settings ~= nil then
    scale = self.settings[SettingKey.MOTION_SCALE] or 1
  end
  -- The opacity is part of the signature like the motion scale: the entrance
  -- is built from it and an animation group cannot be retuned. The entrance's
  -- final alpha is the last write to the frame, a quarter second after the
  -- others, so it must carry the player's opacity.
  local opacity = self:setting(SettingKey.PLATE_OPACITY)

  local signature = effectSignature(effects, scale, opacity)
  if signature == self.effectSignature then
    return
  end
  self.effectSignature = signature

  for _, existing in ipairs({ self.entrance, self.glow, self.sweep, self.burst }) do
    if existing ~= nil then
      existing:stop()
    end
  end

  local function scaled(spec, extra)
    local copy = { kind = spec.kind, color = spec.color, duration = spec.duration * scale }
    for key, value in pairs(extra or {}) do
      copy[key] = value
    end
    return copy
  end

  -- A quarter second, scaled like everything else, so a motion scale of zero
  -- shows the frame at once.
  self.entrance = Effects.entrance(self.frame, 0.25 * scale, opacity)

  self.glow = Effects.glow(self.frame, scaled(effects.glow, { peak = effects.glow.peak }))
  self.sweep = Effects.sweep(self.frame, scaled(effects.sweep))
  self.burst = Effects.burst(self.frame, scaled(effects.burst, {
    count = effects.burst.count,
    rise = effects.burst.rise,
    spread = effects.burst.spread,
    stagger = effects.burst.stagger * scale,
  }))

  self:resizeEffects()
end

function PullPlateView:resizeEffects()
  local width, height = self.frame:GetWidth(), self.frame:GetHeight()
  for _, effect in ipairs({ self.glow, self.sweep, self.burst }) do
    if effect ~= nil and effect.resize ~= nil then
      effect:resize(width, height)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

-- Whether the headline is currently a forecast, and how sure a one. Sets the
-- value the counter walks towards and paints the number to match.
--
-- It stays a forecast through the settling window: in Classic a kill's
-- experience arrives after the kill, so when the last target falls the real
-- figure is least known, and dropping to the banked zero then would report a
-- won fight as worth nothing.
function PullPlateView:composeProjection(view)
  local projection = view.projection
  self.projecting = projection ~= nil and projection.estimated and not view.final

  if not self.projecting then
    local color = self.appearance.text.color
    self.xp:SetTextColor(color.r, color.g, color.b, color.a or 1)
    return
  end

  -- The colour is the claim: the skin's accent at full strength for a rate
  -- measured on this creature at this level with this many sharing the pay, a
  -- step down where its kills were recorded without their group size, dimmer
  -- still where it fell back to the level's mean. An elite and a critter of one
  -- level pay very differently, as do a kill taken alone and one taken by five.
  --
  -- An unlisted basis takes the dimmest rung, not a nil alpha the client would
  -- read as full strength.
  local accent = self.appearance.accent
  self.xp:SetTextColor(accent.r, accent.g, accent.b,
    BASIS_ALPHA[projection.basis] or BASIS_ALPHA[KillXpEstimator.Basis.LEVEL])
end

-- How much experience the level still needs. Never drawn next to the pull's
-- own numbers: it has a different denominator, like the report panel's share of
-- what was observed versus percentage of the level.
function PullPlateView:drawRemaining(layout)
  if not layout.draws[PlateZone.REMAINING] then
    self.remaining:Hide()
    return
  end
  if self.levelProgress == nil then
    self.remaining:Hide()
    return
  end

  local ok, progress = pcall(self.levelProgress)
  if not ok or progress == nil or progress.remaining == nil then
    self.remaining:Hide()
    return
  end

  self.remaining:SetText(self.locale:get(TextKey.PLATE_REMAINING, compact(progress.remaining)))
  self.remaining:Show()
end

function PullPlateView:hideDetail()
  for _, region in ipairs(self.detail) do
    region:Hide()
  end
  for _, row in ipairs(self.abilityRows) do
    row.icon:Hide()
  end
end

-- The chip row. Widths are shares of the pull, left to right in the bar's
-- channel order (stated once in core), so a plate and a bar read the same way.
function PullPlateView:drawChips(view, layout)
  -- A zone that is off takes no room: the layout's offsets below it already
  -- close the gap, so it only has to go unpainted.
  if not layout.draws[PlateZone.SOURCES] then
    for _, chip in ipairs(self.chips) do
      chip:Hide()
    end
    return
  end

  local padding = layout.padding
  local available = self:setting(SettingKey.PLATE_WIDTH) - padding * 2
  local left = 0
  for index, chip in ipairs(self.chips) do
    local entry = view.sources[index]
    if entry == nil then
      chip:Hide()
    else
      local width = available * entry.fraction
      -- A source that contributed must be visible: one point in a pull of ten
      -- thousand would otherwise be a sub-pixel chip.
      if width < 2 then
        width = 2
      end
      local color = self.appearance.colors[SOURCE_PALETTE[entry.source]]
      chip:ClearAllPoints()
      chip:SetPoint("TOPLEFT", self.frame, "TOPLEFT", padding + left, -layout.header.chips)
      chip:SetSize(width, layout.chipHeight)
      -- A slice not yet paid is drawn lighter, so banked and expected make one
      -- length without the second passing for the first.
      local alpha = (color.a or 1) * (entry.projected and 0.4 or 1)
      chip:SetColorTexture(color.r, color.g, color.b, alpha)
      chip:Show()
      left = left + width
    end
  end
end

-- The body of the plate: what is being fought, what is being pressed, what it
-- is costing. Drawn the same whether the pull is running or finished.
--
-- Each block starts where the layout says, and a block the layout does not name
-- is not drawn (zone off, or nothing in it): the rows below were already lifted
-- by the arithmetic that set the frame's height, so drawing it would overlap
-- the next block.
function PullPlateView:drawPlaque(view, layout)
  self.rule:Show()
  local padding = layout.padding
  local width = self:setting(SettingKey.PLATE_WIDTH) - padding * 2

  local top = layout.blocks.creatures
  for index, row in ipairs(self.creatureRows) do
    local entry = top ~= nil and view.creatures[index] or nil
    if entry == nil then
      row.name:Hide()
      row.count:Hide()
    else
      row.name:ClearAllPoints()
      row.name:SetPoint("TOPLEFT", self.frame, "TOPLEFT", padding, -top)
      row.name:SetWidth(width - 32)
      row.name:SetText(entry.name)
      -- Explicit: a font string from GameFontNormalSmall arrives in the
      -- client's gold, not the skin's colour.
      local text = self.appearance.text.color
      row.name:SetTextColor(text.r, text.g, text.b, text.a or 1)
      row.name:Show()

      row.count:ClearAllPoints()
      row.count:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -padding, -top)
      if entry.pending > 0 then
        -- Still standing: how many are down out of how many were pulled, in the
        -- skin's accent so the eye finds the rows still in the fight.
        row.count:SetText(self.locale:get(TextKey.PLATE_ALIVE, entry.killed, entry.engaged))
        local accent = self.appearance.accent
        row.count:SetTextColor(accent.r, accent.g, accent.b, 1)
      else
        row.count:SetText(self.locale:get(TextKey.PLATE_COUNT, entry.killed))
        local color = self.appearance.text.color
        row.count:SetTextColor(color.r, color.g, color.b, color.a or 1)
      end
      row.count:Show()
      top = top + layout.rowHeight
    end
  end

  top = layout.blocks.abilities
  local text = self.appearance.text.color
  for index, row in ipairs(self.abilityRows) do
    local entry = top ~= nil and view.abilities[index] or nil
    if entry == nil then
      row.icon:Hide()
      row.name:Hide()
      row.count:Hide()
    else
      local label, icon = abilityRow(self.locale, entry)

      if icon ~= nil then
        row.icon:ClearAllPoints()
        row.icon:SetPoint("TOPLEFT", self.frame, "TOPLEFT", padding, -top - 1)
        row.icon:SetTexture(icon)
        row.icon:Show()
      else
        row.icon:Hide()
      end

      row.name:ClearAllPoints()
      -- Indented to the icon column whether or not this row has an icon, so a
      -- missing one leaves a gap rather than knocking the row out of line.
      row.name:SetPoint("TOPLEFT", self.frame, "TOPLEFT", padding + layout.iconSize + 5, -top)
      row.name:SetWidth(width - layout.iconSize - 45)
      row.name:SetText(label)
      row.name:SetTextColor(text.r, text.g, text.b, text.a or 1)
      row.name:Show()

      row.count:ClearAllPoints()
      row.count:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -padding, -top)
      row.count:SetText(self.locale:get(TextKey.PLATE_COUNT, entry.count))
      row.count:SetTextColor(text.r, text.g, text.b, (text.a or 1) * 0.75)
      row.count:Show()
      top = top + layout.rowHeight
    end
  end

  local footer = layout.blocks.footer
  if footer == nil then
    self.footerLeft:Hide()
    self.footerRight:Hide()
    return self
  end

  self.footerLeft:ClearAllPoints()
  self.footerLeft:SetPoint("TOPLEFT", self.frame, "TOPLEFT", padding, -footer)
  self.footerLeft:SetText(self.locale:get(TextKey.PLATE_DPS, compact(view.damagePerSecond)))
  self.footerLeft:Show()

  self.footerRight:ClearAllPoints()
  self.footerRight:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -padding, -footer)
  self.footerRight:SetText(self.locale:get(TextKey.PLATE_XP_HOUR, compact(view.xpPerHour)))
  self.footerRight:Show()

  return self
end

-- `view` is what PullViewModel.build returned. Called when the tracker reports
-- a change, not every tick: the counters move between draws under tick(), so a
-- plate at rest on screen costs nothing.
function PullPlateView:update(view)
  -- Nothing worth drawing: a pull that has not landed a blow is all zeroes, so
  -- the plate waits for one. With the prelude replaying the opening shot, that
  -- is the instant the player would call the fight started.
  if self.appearance == nil or not view.active or view.empty then
    self.frame:Hide()
    return self
  end

  self.frame:Show()

  local phase = view.phase
  local final = view.final
  -- With the counts this draw places, so the body blocks and the frame's height
  -- come from one call and cannot disagree. The header half matches what
  -- applyFrame placed: it follows only the text size and the zones.
  local layout = self:layoutFor(#view.creatures, #view.abilities)

  -- While settling the clock says so instead of freezing: a stopped number and a
  -- settling one would otherwise look identical.
  if not layout.draws[PlateZone.CLOCK] then
    self.clock:Hide()
  else
    if phase == PullPhase.SETTLING then
      self.clock:SetText(self.locale:get(TextKey.PLATE_SETTLING))
    else
      self.clock:SetText(clockText(self.locale, view.elapsed))
    end
    self.clock:Show()
  end

  -- Set before the counters, whose formatters read them.
  self.engaged, self.pending = view.engaged, view.engaged - view.kills
  self:composeProjection(view)

  -- The forecast while it is ahead of what has landed, the real figure once it
  -- is not, through the same counter, so the number walks instead of jumping.
  self.counters.xp:set(self.projecting and view.projection.total or view.xpTotal)
  self.counters.kills:set(view.kills)
  -- Both repaint because a formatter whose inputs changed must redraw even when
  -- its value did not: a creature joining moves the estimate without moving the
  -- banked number, and the last one dying removes the estimate.
  self.counters.xp:repaint()
  -- The last creature of a pull dying turns "1/2" into "2" without moving the
  -- number.
  self.counters.kills:repaint()

  self:drawRemaining(layout)

  if layout.draws[PlateZone.STREAK] and view.bestStreak >= 2 then
    local best = final and view.bestStreak or view.streak
    self.streak:SetText(self.locale:get(TextKey.PLATE_STREAK, best))
    self.streak:Show()
  else
    self.streak:Hide()
  end

  self:drawChips(view, layout)

  -- A fight in progress draws the same rows as a finished one. A pull with
  -- nothing in it gets no message, since the header already reads "0 XP" and
  -- "0"; the plate stays at its smallest.
  self:drawPlaque(view, layout)
  -- The height the contents ask for, floor included: with every block empty the
  -- layout already gives the smallest plate.
  self.frame:SetHeight(layout.height)

  self:resizeEffects()
  return self
end

-- Fires the skin's three effects, once, when a pull becomes final. Separate
-- from update(), which runs many times per pull.
function PullPlateView:celebrate()
  self.frame:SetAlpha(self:currentAlpha())
  for _, effect in ipairs({ self.glow, self.sweep, self.burst }) do
    if effect ~= nil then
      effect:play()
    end
  end
  return self
end

-- ---------------------------------------------------------------------------
-- The tick
-- ---------------------------------------------------------------------------

-- Drives the counters and the hold-then-fade of a finished plaque. Returns true
-- while it still has work, so the caller can stop calling it, like the bar's
-- tick: at rest it costs nothing.
function PullPlateView:tick(elapsed)
  if not self.frame:IsShown() then
    return false
  end

  local busy = false
  for _, counter in pairs(self.counters) do
    if counter:tick(elapsed) then
      busy = true
    end
  end

  if self.heldFor ~= nil then
    self.heldFor = self.heldFor + (elapsed or 0)
    -- Read per tick, not captured: the hold is a setting, and a plaque already
    -- on screen honours a change at once.
    local hold = self:setting(SettingKey.PLATE_HOLD_SECONDS)
    if self.heldFor >= hold + FADE_SECONDS then
      self.frame:Hide()
      self.heldFor = nil
      self.generation = nil
      self.frame:SetAlpha(self:currentAlpha())
      return false
    elseif self.heldFor >= hold then
      -- Faded in Lua, not by an animation group: the next pull can interrupt it
      -- at any instant, and stopping an alpha animation leaves the frame at
      -- whatever alpha it had reached.
      self.frame:SetAlpha(self:currentAlpha())
    end
    busy = true
  end

  return busy
end

-- ---------------------------------------------------------------------------
-- The one call the composition root makes
-- ---------------------------------------------------------------------------

-- Reads the tracker, redraws, and handles the two transitions that are more
-- than a redraw: a new pull opening (reset the counters, cancel any fade) and a
-- pull becoming final (celebrate).
function PullPlateView:follow(tracker, now)
  local phase = tracker:currentPhase()
  local generation = tracker:currentGeneration()

  local isNewPull = generation ~= self.generation
  local becameFinal = phase == PullPhase.CLOSED and self.phase ~= PullPhase.CLOSED
  -- The same pull, alive again: something was pulled while this was fading, and
  -- the tracker reopened it. The frame returns to full strength; the counters
  -- are untouched.
  local resumed = not isNewPull and phase == PullPhase.ACTIVE and self.heldFor ~= nil

  if isNewPull then
    self.generation = generation
    self.heldFor = nil
    self.frame:SetAlpha(self:currentAlpha())
    for _, counter in pairs(self.counters) do
      counter:reset()
    end
    for _, effect in ipairs({ self.glow, self.sweep, self.burst }) do
      if effect ~= nil then
        effect:stop()
      end
    end
    -- The arrival, flagged here rather than in update(), which runs many times
    -- a fight: fading in on every redraw would strobe.
    self.arriving = true
  end

  if resumed then
    self.heldFor = nil
    self.frame:SetAlpha(self:currentAlpha())
  end

  self.phase = phase
  -- The level in progress, asked on every draw so the projection can use what
  -- these creatures have paid. nil (no level open) costs only the estimate.
  local record = nil
  if self.levelRecord ~= nil then
    local ok, value = pcall(self.levelRecord)
    record = ok and value or nil
  end
  -- Guarded the same way: it ends in a client call, and a failure must cost the
  -- group context, not the plate.
  local sharedBy = nil
  if self.sharedBy ~= nil then
    local ok, value = pcall(self.sharedBy)
    sharedBy = ok and value or nil
  end
  -- How many rows to list, passed per draw rather than captured, so a change
  -- mid-fight shows on the next redraw; every row already exists.
  self:update(PullViewModel.build(tracker:current(), phase, now, record, sharedBy,
    self:setting(SettingKey.PLATE_ROWS)))

  -- After update(), so the frame and the glow have their real size first, and
  -- only once the frame is shown: a pull stays hidden until it has something to
  -- show, and an arrival played at opening would fade in an invisible frame.
  if self.arriving and self.frame:IsShown() then
    self.arriving = false
    if self.entrance ~= nil then
      self.entrance:play()
    end
    if self.glow ~= nil then
      self.glow:play()
    end
  end

  if becameFinal then
    self.heldFor = 0
    self:celebrate()
  end
  return self
end

function PullPlateView:hide()
  self.frame:Hide()
  self.generation = nil
  self.heldFor = nil
end

-- Also used by the options panel and /ascent plate demo: resolves a skin and
-- applies it without a live pull.
--
-- The skin, palette and high contrast are the bar's, so the chips match the
-- bar's segments. The plate adds its own appearance map over the bar's, read
-- from the settings: an axis it sets wins, an axis it leaves out follows the
-- bar, so a plate tweak survives the bar changing skin.
function PullPlateView:applySkin(skinId, overrides, colors, highContrast)
  local appearance = SkinResolver.resolve({
    skin = SkinResolver.skinFor(SkinCatalog, skinId, ns.core.DEFAULT_SKIN_ID),
    overrides = overrides,
    own = self:setting(SettingKey.PLATE_APPEARANCE),
    colors = colors,
    palette = Palette,
    highContrast = highContrast,
  })
  return self:applyAppearance(appearance)
end

-- How long a finished plate takes to fade once its hold is over, and how long it
-- stays up with the default hold.
--
-- The pull tracker's resume window uses VISIBLE_SECONDS, so a pull can resume
-- while the plate is still visible. It uses the default hold, so the hold
-- setting changes what is drawn, not what counts as the same fight; the live
-- figure, `settings[PLATE_HOLD_SECONDS] + FADE_SECONDS`, would have to be read
-- by the composition root per question.
PullPlateView.FADE_SECONDS = FADE_SECONDS
PullPlateView.VISIBLE_SECONDS = Defaults[SettingKey.PLATE_HOLD_SECONDS] + FADE_SECONDS

ns.ui.PullPlateView = PullPlateView
