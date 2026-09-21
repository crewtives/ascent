-- Ascent - the pull plate: a small frame that counts while the fight is
-- happening, and becomes a plaque when it is over.
--
-- EVERYTHING ON IT IS LIVE. That is not a default, it is the correction of a
-- wrong first cut: this used to hide the creature list, the ability list and the
-- footer until the pull closed, on the theory that the plaque was the payoff. In
-- the game that reads as a frame that does nothing -- a player three seconds
-- into a fight saw "0 XP, 0, 3s" and no sign that anything was being tracked,
-- because the only thing it could list was the dead, and nothing had died yet.
--
-- So the list counts what is being FOUGHT, not what has fallen (PullRecord's
-- `engaged` half exists for this), the abilities and the damage appear from the
-- first blow, and the header carries how much experience the level still needs.
-- Closing a pull no longer changes WHAT is shown -- it changes that the numbers
-- have stopped moving, and the skin's effects fire once to say so.
--
-- WHY IT DOES NOT FREEZE WHEN COMBAT ENDS. See PullPhase in
-- core/constants/Metrics.lua: in Classic the experience for a kill arrives after
-- the kill, often after the client has already said combat is over. The plate
-- therefore has a third visible state between the two above -- settling -- where
-- the numbers are still moving and the frame says so. Firing the plaque at
-- PLAYER_REGEN_ENABLED would make it wrong on most fights, and wrong in the
-- direction that matters: the last kill of the pull is the one it would drop.
--
-- WHAT THIS FILE OWNS AND WHAT IT DOES NOT. It owns a frame, where that frame
-- sits, and which of its rows are shown. It owns no arithmetic: every number it
-- prints comes out of PullViewModel already divided, and every effect it plays
-- comes out of ui/Effects.lua already built from the skin. That split is the
-- same one BarRenderer and XpBarView have, for the same reason -- it is what
-- makes the interesting half testable without a client.
--
-- POOLS ARE FIXED, AND SIZED FROM THE VIEW-MODEL'S OWN CEILINGS. Every row this
-- can ever draw is built once, at construction, and hidden rather than
-- destroyed. A plate that allocated a row per pull would allocate thousands over
-- a levelling session, in combat, which is the one place this addon must not.

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
local Effects = ns.ui.Effects

local WIDTH = 240
local PADDING = 10
local ROW_HEIGHT = 15
local CHIP_HEIGHT = 5

-- The header's rows, as distances from the top of the frame. Stated here once and
-- anchored to the FRAME rather than to each other, which is the correction of a
-- real defect: the "to level" line used to hang off the headline's own font
-- string, whose height depends on the text in it, so the source bar below was
-- laid at a fixed offset that the text grew into and overlapped.
local ROW_TITLE     = PADDING - 2
local ROW_XP        = PADDING + 14
local ROW_REMAINING = PADDING + 40
local ROW_CHIPS     = PADDING + 56
local ROW_RULE      = PADDING + 68
local ROW_BODY      = PADDING + 76
local ICON_SIZE     = 12

local MIN_HEIGHT = ROW_BODY + PADDING

-- How long a finished plaque stays on screen before it fades. Long enough to
-- read four numbers, short enough that the next pull does not queue behind it.
local HOLD_SECONDS = 6
local FADE_SECONDS = 1.2

-- The chip row carries colour and nothing else, and the colours are the bar's
-- own -- which is the point: a player who has learned what orange means on the
-- bar has already learned what it means here. Naming them again on a frame this
-- size would cost the numbers their room to say the same thing twice.
local SOURCE_PALETTE = {
  [XpSource.MOB_KILL] = "MOB_KILL",
  [XpSource.QUEST_TURNIN] = "QUEST_TURNIN",
  [XpSource.EXPLORATION] = "EXPLORATION",
  [XpSource.UNKNOWN] = "UNKNOWN",
}

local PullPlateView = {}
PullPlateView.__index = PullPlateView

-- ---------------------------------------------------------------------------
-- Formatting. Small, local, and free of `self` so they read on their own.
-- ---------------------------------------------------------------------------

-- Thousands folded into a k, because the plate's headline number has about six
-- characters of room and a level's worth of experience does not fit in six
-- digits plus a label. Below a thousand it is the exact figure: rounding a
-- 44-experience kill to "0.0k" would be worse than useless.
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

-- The two attacks with no spell behind them, each named and each given the
-- client's own icon for it. The report panel leaves auto attacks iconless on
-- purpose -- there is no spell id to resolve -- but the client DOES have a spell
-- for each of them, and borrowing its texture is what makes a row of the plate
-- scannable at a glance instead of a name with a gap where every other row has a
-- picture.
--
-- The labels are TextKeys shared with the panel, so the two surfaces cannot drift
-- into calling a melee swing and a ranged shot the same thing -- which is exactly
-- what they did until now.
local AUTO_ATTACK = {
  [AbilityKey.MELEE_SWING] = { label = TextKey.PANEL_AUTO_ATTACK, spell = 6603 },
  [AbilityKey.RANGED_AUTO] = { label = TextKey.PANEL_RANGED_ATTACK, spell = 75 },
}

-- Through whichever accessor this client has. The namespaced one arrived later
-- and the bare global is still there on both supported flavours, so this tries
-- the modern path first and falls back rather than assuming either (D38). A nil
-- answer costs the icon and nothing else: a row with no icon reads as "no icon",
-- a row with a placeholder reads as "something is broken".
local function spellTexture(spellId)
  if spellId == nil then
    return nil
  end
  if C_Spell ~= nil and type(C_Spell.GetSpellTexture) == "function" then
    local texture = C_Spell.GetSpellTexture(spellId)
    if texture ~= nil then
      return texture
    end
  end
  if type(GetSpellTexture) == "function" then
    return GetSpellTexture(spellId)
  end
  return nil
end

-- What the row is called and what it shows, for a spell or for either auto
-- attack. `name` is the one the combat log gave us, cached at the moment it was
-- used -- preferred over anything resolved later, because the client can fail to
-- resolve an id it happily named at the time.
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

-- options: parent, settings, saveSetting, locale, levelProgress, levelRecord
--
-- `levelProgress` is a function returning { remaining, percent } for the level in
-- progress, or nil when there is none (max level, gain switched off, nothing
-- recorded yet). A function and not a value, for the same reason every other
-- seam in this addon is one: the plate asks when it draws, and never learns that
-- a LevelRecord exists.
function PullPlateView.new(options)
  options = options or {}
  if options.locale == nil then
    error("PullPlateView needs a locale", 2)
  end

  local frame = CreateFrame("Frame", "AscentPullPlate", options.parent or UIParent)
  frame:SetSize(WIDTH, MIN_HEIGHT)
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
    appearance = nil,

    -- Which pull is on screen, so a redraw of the SAME pull does not restart a
    -- counter and a genuinely new one does.
    generation = nil,
    phase = PullPhase.IDLE,
    -- Seconds the finished plaque has been up. nil while a pull is running:
    -- a plate that faded mid-fight would take the numbers with it.
    heldFor = nil,
    counters = {},
  }, PullPlateView)

  self:build()
  self:applyPosition()
  return self
end

function PullPlateView:build()
  local frame = self.frame

  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(frame)
  self.background = background

  self.border = Effects.plaqueBorder(frame, { size = 1, inset = 0 })

  -- Header: what this is, and how long it has been going.
  self.title = newFontString(frame, 10, "LEFT")
  self.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -ROW_TITLE)
  self.title:SetText(self.locale:get(TextKey.PLATE_TITLE))

  self.clock = newFontString(frame, 10, "RIGHT")
  self.clock:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -ROW_TITLE)

  -- The headline: experience, big, counting.
  self.xp = newFontString(frame, 20, "LEFT", "THICKOUTLINE")
  self.xp:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -ROW_XP)
  -- ONE number, always. While the pull is running it is what the pull is on
  -- course to be worth, marked with a tilde; once the experience has actually
  -- landed it is that figure, unmarked. Showing both -- "0 / ~73 XP" -- was
  -- stating a sum and its forecast side by side, which is two claims where the
  -- player wants one, and the zero half of it was never the interesting one.
  --
  -- The same counter carries both, so confirmation is the number walking from
  -- the estimate to the real figure rather than one label being swapped for
  -- another.
  -- ONE number, always, and no marker glyph on it. A tilde reads above the
  -- baseline of the digits beside it in the client's own font, and a font string
  -- offers no way to centre one glyph against another -- so the mark that was
  -- meant to say "this is an estimate" only said "this is misaligned". The claim
  -- is carried by colour instead; see composeProjection.
  self.counters.xp = Effects.counter(self.xp, function(value)
    return self.locale:get(TextKey.PLATE_XP, compact(value))
  end)

  -- Kills and the running chain, right-aligned against the headline.
  self.kills = newFontString(frame, 18, "RIGHT", "THICKOUTLINE")
  self.kills:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -ROW_XP)
  -- Reads "killed/engaged" while any of them is still standing, and the plain
  -- count once they are all down. Two numbers rather than one because during the
  -- fight the interesting figure is how many are LEFT, and a lone "0" three
  -- seconds into a pull is exactly what made this frame look broken.
  self.counters.kills = Effects.counter(self.kills, function(value)
    if self.pending ~= nil and self.pending > 0 then
      return self.locale:get(TextKey.PLATE_KILLS_OF, value, self.engaged or value)
    end
    return self.locale:get(TextKey.PLATE_KILLS, value)
  end)

  -- How much the LEVEL still needs. Not the pull's own number and never drawn as
  -- one: it is the question a player asks between fights, and the plate is on
  -- screen exactly then.
  self.remaining = newFontString(frame, 10, "LEFT")
  -- Anchored to the FRAME and not to the headline above it. See the row
  -- constants: a font string's height follows its text, so hanging this off
  -- one made every row below it move whenever the number got longer -- which
  -- is how the source bar ended up drawn through this line.
  self.remaining:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -ROW_REMAINING)

  self.streak = newFontString(frame, 9, "RIGHT")
  self.streak:SetPoint("TOPRIGHT", self.kills, "BOTTOMRIGHT", 0, -1)

  -- The chip row: the pull's experience split by source, in the bar's own
  -- colours and the bar's own order. One texture per source, sized by share.
  self.chips = {}
  for index = 1, PullViewModel.SOURCE_COUNT do
    local chip = frame:CreateTexture(nil, "ARTWORK")
    chip:SetHeight(CHIP_HEIGHT)
    chip:Hide()
    self.chips[index] = chip
  end

  -- A hairline between the header and the body. It is the cheapest thing on the
  -- plate and does the most for it: without one, the source bar and the first
  -- creature row read as the same block, and the eye has nowhere to stop.
  self.rule = frame:CreateTexture(nil, "ARTWORK")
  self.rule:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -ROW_RULE)
  self.rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -ROW_RULE)
  self.rule:SetHeight(1)
  self.rule:Hide()

  -- Everything below here belongs to the plaque and is hidden while the fight
  -- is running.
  self.detail = {}

  self.creatureRows = {}
  for index = 1, PullViewModel.TOP_CREATURES do
    local row = { name = newFontString(frame, 10, "LEFT"), count = newFontString(frame, 10, "RIGHT") }
    row.name:Hide()
    row.count:Hide()
    self.creatureRows[index] = row
    self.detail[#self.detail + 1] = row.name
    self.detail[#self.detail + 1] = row.count
  end

  self.abilityRows = {}
  for index = 1, PullViewModel.TOP_ABILITIES do
    local row = {
      icon = frame:CreateTexture(nil, "ARTWORK"),
      name = newFontString(frame, 10, "LEFT"),
      count = newFontString(frame, 10, "RIGHT"),
    }
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    -- The client's icons carry a border baked into the outer few pixels; every
    -- addon that shows one trims it, and a plate that did not would draw a row of
    -- grey frames rather than a row of spells.
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon:Hide()
    row.name:Hide()
    row.count:Hide()
    self.abilityRows[index] = row
    self.detail[#self.detail + 1] = row.name
    self.detail[#self.detail + 1] = row.count
  end

  self.footerLeft = newFontString(frame, 10, "LEFT")
  self.footerRight = newFontString(frame, 10, "RIGHT")
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
    if self.settings ~= nil and self.settings[SettingKey.BAR_LOCKED] then
      return
    end
    moved:StartMoving()
  end)
  frame:SetScript("OnDragStop", function(moved)
    moved:StopMovingOrSizing()
    if self.saveSetting == nil then
      return
    end
    -- Both halves of the anchor. The client re-anchors a frame it has moved, and
    -- the point it ends up hung BY is not always the point it is hung TO -- so
    -- saving one and using it for both is how a frame lands somewhere nobody
    -- dropped it. The bar gets away with it because its anchor never changes
    -- shape; this one is resized on every draw.
    local point, _, relativePoint, x, y = moved:GetPoint()
    self.saveSetting(SettingKey.PLATE_POSITION, {
      point = point or "CENTER",
      relativePoint = relativePoint or point or "CENTER",
      x = x or 0,
      y = y or 0,
    })
  end)
end

-- Re-reads the settings and reapplies everything that comes out of them, the
-- same contract XpBarView:applySettings has.
--
-- IT MUST REBIND `self.settings`, and that is the whole reason this exists.
-- Settings.resolve builds a NEW frozen table on every save; the composition root
-- rebinds its own local and used to call this view's applySkin and applyPosition
-- individually, which left the plate reading the table it had captured at
-- construction. Dragging it therefore saved the new position and then
-- immediately re-anchored to the stale one -- a frame that would not stay where
-- it was put, for a reason nowhere near where it looked.
function PullPlateView:applySettings(settings)
  self.settings = settings or self.settings
  self:applySkin(self.settings[SettingKey.BAR_SKIN], self.settings[SettingKey.BAR_APPEARANCE],
    self.settings[SettingKey.BAR_COLORS], self.settings[SettingKey.HIGH_CONTRAST])
  self:applyPosition()
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

-- Takes the same resolved appearance the bar takes, from the same resolver, so
-- switching skin changes both at once and there is no second place a skin has to
-- be applied. Effects are rebuilt rather than retuned: they are a handful of
-- textures created once per skin change, which is not a hot path.
function PullPlateView:applyAppearance(appearance)
  self.appearance = appearance

  local background = appearance.background
  self.background:SetColorTexture(background.r, background.g, background.b,
    -- Floored, unlike the bar's: a bar may legitimately be invisible (the
    -- phantom skin) because the segments carry it. A plate with no background
    -- is floating text over the world.
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

-- Everything an effect is built from, as one comparable string. It exists
-- because applyAppearance runs on EVERY settings change -- the player nudging
-- the bar's width rebuilds the plate's appearance too -- and an animation group
-- cannot be destroyed once created. Without this, a minute in the options panel
-- would leave a stack of dead animation groups parented to the plate.
local function effectSignature(effects, scale)
  local parts = { ("%.3f"):format(scale) }
  for _, name in ipairs({ "glow", "sweep", "burst" }) do
    local spec = effects[name]
    local color = spec.color
    parts[#parts + 1] = ("%s|%.3f|%.2f,%.2f,%.2f"):format(spec.kind, spec.duration, color.r, color.g, color.b)
  end
  parts[#parts + 1] = ("%.2f|%d|%.1f|%.1f|%.3f")
    :format(effects.glow.peak, effects.burst.count, effects.burst.rise, effects.burst.spread, effects.burst.stagger)
  return table.concat(parts, "/")
end

-- Durations arrive already multiplied by the player's motion scalar, so a
-- scalar of zero produces effects whose duration is zero -- and Effects turns
-- those into the inert object through the same path everything else takes.
function PullPlateView:buildEffects(effects)
  local scale = 1
  if self.settings ~= nil then
    scale = self.settings[SettingKey.MOTION_SCALE] or 1
  end

  local signature = effectSignature(effects, scale)
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

  -- A quarter second, scaled like everything else, so "reduce motion" to zero
  -- turns this into the frame simply being there.
  self.entrance = Effects.entrance(self.frame, 0.25 * scale)

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

-- How much experience the level still needs. Deliberately NOT part of the pull's
-- own numbers and never drawn next to them: it answers a different question, on a
-- different denominator, and folding the two together is the exact confusion the
-- report panel's spec already calls out between "share of what was observed" and
-- "percentage of the level".
-- Whether the headline is currently a forecast, and how sure a one. Sets the
-- value the counter walks towards and paints the number to match.
--
-- It stays a forecast through the settling window on purpose. In Classic the
-- experience for a kill arrives AFTER the kill, so the moment the last target
-- falls is the moment the real figure is furthest from being known -- and a
-- headline that dropped to the banked zero right then would report a fight that
-- had just been won as worth nothing.
function PullPlateView:composeProjection(view)
  local projection = view.projection
  self.projecting = projection ~= nil and projection.estimated and not view.final

  if not self.projecting then
    local color = self.appearance.text.color
    self.xp:SetTextColor(color.r, color.g, color.b, color.a or 1)
    return
  end

  -- The colour is the whole claim now, and it carries D4's distinction as well:
  -- the skin's accent for a rate measured on THIS creature at THIS level, and a
  -- dimmer one where it had to fall back to the level's own mean. An elite and a
  -- critter of the same level pay very differently, so a figure resting on that
  -- mean must not look like a measurement.
  local accent = self.appearance.accent
  local measured = projection.basis == KillXpEstimator.Basis.CREATURE
  self.xp:SetTextColor(accent.r, accent.g, accent.b, measured and 1 or 0.6)
end

function PullPlateView:drawRemaining()
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

-- The chip row. Widths are shares of the pull, laid left to right in the bar's
-- channel order -- so a plate and a bar showing the same pull read the same way,
-- which is the whole reason the order is stated once in core and not twice here.
function PullPlateView:drawChips(view)
  local available = WIDTH - PADDING * 2
  local left = 0
  for index, chip in ipairs(self.chips) do
    local entry = view.sources[index]
    if entry == nil then
      chip:Hide()
    else
      local width = available * entry.fraction
      -- A source that contributed something must be visible as something. A
      -- single point of experience in a pull of ten thousand is a sub-pixel
      -- chip, and a chip nobody can see says the source did not contribute.
      if width < 2 then
        width = 2
      end
      local color = self.appearance.colors[SOURCE_PALETTE[entry.source]]
      chip:ClearAllPoints()
      chip:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PADDING + left, -ROW_CHIPS)
      chip:SetSize(width, CHIP_HEIGHT)
      -- A slice that has not been paid yet is drawn as the lighter claim it is,
      -- so the bar shows banked and expected as one length without passing the
      -- second off as the first.
      local alpha = (color.a or 1) * (entry.projected and 0.4 or 1)
      chip:SetColorTexture(color.r, color.g, color.b, alpha)
      chip:Show()
      left = left + width
    end
  end
end

-- The body of the plate: what is being fought, what is being pressed, what it is
-- costing. Drawn identically whether the pull is running or finished -- see the
-- module header for why that is the whole correction.
function PullPlateView:drawPlaque(view)
  self.rule:Show()
  local top = -ROW_BODY
  local width = WIDTH - PADDING * 2

  for index, row in ipairs(self.creatureRows) do
    local entry = view.creatures[index]
    if entry == nil then
      row.name:Hide()
      row.count:Hide()
    else
      row.name:ClearAllPoints()
      row.name:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PADDING, top)
      row.name:SetWidth(width - 32)
      row.name:SetText(entry.name)
      -- Explicit, because it is NOT the default. A font string inherited from
      -- GameFontNormalSmall arrives in the client's own gold, which is how these
      -- rows ended up a colour no skin had asked for.
      local text = self.appearance.text.color
      row.name:SetTextColor(text.r, text.g, text.b, text.a or 1)
      row.name:Show()

      row.count:ClearAllPoints()
      row.count:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -PADDING, top)
      if entry.pending > 0 then
        -- Still standing: how many are down out of how many were pulled, in the
        -- skin's accent so the eye finds the row that is still costing something.
        row.count:SetText(self.locale:get(TextKey.PLATE_ALIVE, entry.killed, entry.engaged))
        local accent = self.appearance.accent
        row.count:SetTextColor(accent.r, accent.g, accent.b, 1)
      else
        row.count:SetText(self.locale:get(TextKey.PLATE_COUNT, entry.killed))
        local color = self.appearance.text.color
        row.count:SetTextColor(color.r, color.g, color.b, color.a or 1)
      end
      row.count:Show()
      top = top - ROW_HEIGHT
    end
  end

  top = top - 4

  local text = self.appearance.text.color
  for index, row in ipairs(self.abilityRows) do
    local entry = view.abilities[index]
    if entry == nil then
      row.icon:Hide()
      row.name:Hide()
      row.count:Hide()
    else
      local label, icon = abilityRow(self.locale, entry)

      if icon ~= nil then
        row.icon:ClearAllPoints()
        row.icon:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PADDING, top - 1)
        row.icon:SetTexture(icon)
        row.icon:Show()
      else
        row.icon:Hide()
      end

      row.name:ClearAllPoints()
      -- Indented to the icon column whether or not this row got one, so a
      -- missing icon leaves a gap rather than knocking the row out of line.
      row.name:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PADDING + ICON_SIZE + 5, top)
      row.name:SetWidth(width - ICON_SIZE - 45)
      row.name:SetText(label)
      row.name:SetTextColor(text.r, text.g, text.b, text.a or 1)
      row.name:Show()

      row.count:ClearAllPoints()
      row.count:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -PADDING, top)
      row.count:SetText(self.locale:get(TextKey.PLATE_COUNT, entry.count))
      row.count:SetTextColor(text.r, text.g, text.b, (text.a or 1) * 0.75)
      row.count:Show()
      top = top - ROW_HEIGHT
    end
  end

  top = top - 4

  self.footerLeft:ClearAllPoints()
  self.footerLeft:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PADDING, top)
  self.footerLeft:SetText(self.locale:get(TextKey.PLATE_DPS, compact(view.damagePerSecond)))
  self.footerLeft:Show()

  self.footerRight:ClearAllPoints()
  self.footerRight:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -PADDING, top)
  self.footerRight:SetText(self.locale:get(TextKey.PLATE_XP_HOUR, compact(view.xpPerHour)))
  self.footerRight:Show()

  return math.abs(top) + ROW_HEIGHT + PADDING
end

-- `view` is what PullViewModel.build returned. Called when the tracker says
-- something changed, not every tick: the counters keep moving between draws
-- under tick() below, which is what makes a plate on screen cost nothing while
-- the player reads it.
function PullPlateView:update(view)
  -- Nothing to draw, or nothing worth drawing. A pull that has not yet landed a
  -- blow has a header full of zeroes and an empty body, and putting that on
  -- screen announces the addon rather than the fight: the plate waits until it
  -- has something to say. With the prelude replaying the opening shot, that is
  -- the same instant the player would call the fight started.
  if self.appearance == nil or not view.active or view.empty then
    self.frame:Hide()
    return self
  end

  self.frame:Show()

  local phase = view.phase
  local final = view.final

  -- The clock stops when the pull does, and says so rather than freezing
  -- silently: a number that stopped moving and a number that is still settling
  -- look identical otherwise.
  if phase == PullPhase.SETTLING then
    self.clock:SetText(self.locale:get(TextKey.PLATE_SETTLING))
  else
    self.clock:SetText(clockText(self.locale, view.elapsed))
  end

  -- All set before the counters, because their own formatters read them.
  self.engaged, self.pending = view.engaged, view.engaged - view.kills
  self:composeProjection(view)

  -- The forecast while there is one, the real figure once there is not -- both
  -- through the same counter, so the number walks from one to the other.
  -- The forecast while it is still ahead of what has landed, the real figure once
  -- it is not -- both through the same counter, so the number walks from one to
  -- the other instead of jumping.
  self.counters.xp:set(self.projecting and view.projection.total or view.xpTotal)
  self.counters.kills:set(view.kills)
  -- Both repaint for the same reason: a formatter whose INPUTS changed while its
  -- value did not still has to redraw. A second creature joining the pull moves
  -- the estimate without moving the banked number, and the last one dying takes
  -- the estimate away entirely.
  self.counters.xp:repaint()
  -- A counter whose FORMAT changed but whose value did not still has to repaint:
  -- the last serpent of a pull dying turns "1/2" into "2" without moving the
  -- number, and without this the row would keep claiming one is still standing.
  self.counters.kills:repaint()

  self:drawRemaining()

  if view.bestStreak >= 2 then
    local best = final and view.bestStreak or view.streak
    self.streak:SetText(self.locale:get(TextKey.PLATE_STREAK, best))
    self.streak:Show()
  else
    self.streak:Hide()
  end

  self:drawChips(view)

  -- Nothing waits for the pull to close. A fight in progress draws the same rows
  -- a finished one does; what closing changes is that the numbers stop moving.
  --
  -- A pull with nothing in it gets no message. It used to say so out loud, and
  -- that was worse than saying nothing: the header already reads "0 XP" and "0",
  -- so a sentence announcing emptiness added a line of text and no information.
  -- The plate simply stays at its smallest.
  self.frame:SetHeight(math.max(MIN_HEIGHT, self:drawPlaque(view)))

  self:resizeEffects()
  return self
end

-- Fires the skin's three effects, once, at the moment a pull becomes final.
-- Separate from update() because update() runs many times per pull and this must
-- run exactly once -- and because "what happened" and "celebrate it" are two
-- different statements even when they arrive together.
function PullPlateView:celebrate()
  self.frame:SetAlpha(1)
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
-- while it still has work, so the caller could stop calling it -- the bar's own
-- tick has the same shape and the same reason (visual-motion: rest costs
-- nothing).
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
    if self.heldFor >= HOLD_SECONDS + FADE_SECONDS then
      self.frame:Hide()
      self.frame:SetAlpha(1)
      self.heldFor = nil
      self.generation = nil
      return false
    elseif self.heldFor >= HOLD_SECONDS then
      -- Faded in Lua rather than by an animation group: this one has to be
      -- interruptible at any instant, because the next pull can start in the
      -- middle of it, and stopping an alpha animation leaves the frame at
      -- whatever alpha it had reached.
      self.frame:SetAlpha(1 - (self.heldFor - HOLD_SECONDS) / FADE_SECONDS)
    end
    busy = true
  end

  return busy
end

-- ---------------------------------------------------------------------------
-- The one call the composition root makes
-- ---------------------------------------------------------------------------

-- Reads the tracker, decides whether anything has to be redrawn, and handles the
-- two transitions that are not just a redraw: a new pull opening (reset the
-- counters, cancel any fade) and a pull becoming final (grow, and celebrate).
function PullPlateView:follow(tracker, now)
  local phase = tracker:currentPhase()
  local generation = tracker:currentGeneration()

  local isNewPull = generation ~= self.generation
  local becameFinal = phase == PullPhase.CLOSED and self.phase ~= PullPhase.CLOSED
  -- The same pull, alive again: the player pulled something while this was still
  -- fading, and the tracker reopened it rather than starting over. The frame has
  -- to come back to full strength and forget it was ever on its way out -- the
  -- counters are untouched, because nothing reset them.
  local resumed = not isNewPull and phase == PullPhase.ACTIVE and self.heldFor ~= nil

  if isNewPull then
    self.generation = generation
    self.heldFor = nil
    self.frame:SetAlpha(1)
    for _, counter in pairs(self.counters) do
      counter:reset()
    end
    for _, effect in ipairs({ self.glow, self.sweep, self.burst }) do
      if effect ~= nil then
        effect:stop()
      end
    end
    -- The arrival. Played here rather than in update(), which runs many times a
    -- fight: a frame that faded in on every redraw would strobe.
    self.arriving = true
  end

  if resumed then
    self.heldFor = nil
    self.frame:SetAlpha(1)
  end

  self.phase = phase
  -- The level in progress, asked for fresh on every draw, and only so the
  -- projection can be measured against what these creatures have paid. nil is a
  -- normal answer -- no level open -- and costs the estimate, nothing else.
  local record = nil
  if self.levelRecord ~= nil then
    local ok, value = pcall(self.levelRecord)
    record = ok and value or nil
  end
  self:update(PullViewModel.build(tracker:current(), phase, now, record))

  -- After update(), so the frame is at its real size and the glow is sized to
  -- match before either of them is seen.
  -- Only once the frame is actually up. A pull now stays hidden until it has
  -- something to show, so playing the arrival at the moment the pull OPENED would
  -- fade in a frame nobody can see and leave the real appearance abrupt.
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

-- Used by the options panel and by /ascent plate demo: resolves a skin and
-- applies it without needing a live pull, so a player can see what they picked.
function PullPlateView:applySkin(skinId, overrides, colors, highContrast)
  local appearance = SkinResolver.resolve({
    skin = SkinResolver.skinFor(SkinCatalog, skinId, ns.core.DEFAULT_SKIN_ID),
    overrides = overrides,
    colors = colors,
    palette = Palette,
    highContrast = highContrast,
  })
  return self:applyAppearance(appearance)
end

-- How long a finished plate stays readable, hold plus fade. Published because the
-- pull tracker's resume window is meant to be exactly this: a pull can be carried
-- on for as long as the player can still see it. Two constants that had to agree
-- would drift; one that is read is one.
PullPlateView.VISIBLE_SECONDS = HOLD_SECONDS + FADE_SECONDS

ns.ui.PullPlateView = PullPlateView
