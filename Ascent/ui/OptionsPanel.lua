-- Ascent - the appearance panel.
--
-- Everything about how Ascent looks is set here, in the client's AddOns
-- settings; the chat commands are a shortcut and a way back when the interface
-- cannot be used.
--
-- The skin gallery draws each skin: a swatch is a BarRenderer painting a
-- sample level, with no position, drag or hiding of its own. A live preview at
-- the top reflects every change and replays the animation on demand.
-- Enumerated settings cycle through a button rather than a dropdown:
-- UIDropDownMenu needs five globals unverified on Burning Crusade Classic, and
-- with three to five choices a button is fewer clicks.
--
-- Sliders preview on OnValueChanged and persist on OnMouseUp: persisting copies
-- the stored table, writes the repository and re-resolves every setting, so it
-- happens once per release, not per pixel of a drag.
--
-- Nothing here talks to SavedVariables or draws the real bar: it changes a
-- setting and the bar reapplies itself.

local _, ns = ...
ns.ui = ns.ui or {}

local SettingKey = ns.core.SettingKey
local TextKey = ns.core.TextKey
local BarSlot = ns.core.BarSlot
local TextToken = ns.core.TextToken
local BarTextFields = ns.core.BarTextFields
local BarSlotPolicy = ns.core.BarSlotPolicy
local Frozen = ns.core.Frozen
local SkinCatalog = ns.core.SkinCatalog
local SkinResolver = ns.core.SkinResolver
local PlateLayout = ns.core.PlateLayout
local PlateZone = ns.core.PlateZone
local SettingPanelRange = ns.core.SettingPanelRange
local Palette = ns.core.Palette
local BorderKind = ns.core.BorderKind
local SeparatorKind = ns.core.SeparatorKind
local FillKind = ns.core.FillKind
local TextStyle = ns.core.TextStyle
local TextAnchor = ns.core.TextAnchor
local BarPreview = ns.ui.BarPreview

local SCALE = { min = 0.5, max = 2.0, step = 0.05 }
local WIDTH = { min = 120, max = 900, step = 10 }
local HEIGHT = { min = 8, max = 60, step = 1 }
local MOTION = { min = 0, max = 1, step = 0.05 }
local THICKNESS = { min = 0, max = 6, step = 1 }
local ALPHA = { min = 0, max = 1, step = 0.05 }
local TEXT_SIZE = { min = 8, max = 20, step = 1 }

local SWATCH_COLUMNS = 3
local SWATCH_WIDTH, SWATCH_HEIGHT = 150, 34

-- The colours the player may set, in the order the bar draws them.
local COLOR_ROWS = {
  { key = "MOB_KILL", labelKey = TextKey.SOURCE_CREATURES },
  { key = "QUEST_TURNIN", labelKey = TextKey.SOURCE_QUESTS },
  { key = "EXPLORATION", labelKey = TextKey.SOURCE_EXPLORATION },
  { key = "UNKNOWN", labelKey = TextKey.SOURCE_UNCLASSIFIED },
  { key = "RESTED", labelKey = TextKey.OPT_COLOR_RESTED },
  { key = "PENDING", labelKey = TextKey.BAR_PENDING },
}

-- What the bar can say, in the order it reads. The order is the domain's
-- (TEXT_PRIORITY, via BarTextFields); this only pairs each field with its label.
local FIELDS = {
  { TextToken.LEVEL, TextKey.OPT_FIELD_LEVEL },
  { TextToken.XP_PERCENT, TextKey.OPT_FIELD_XP_PERCENT },
  { TextToken.XP_CURRENT, TextKey.OPT_FIELD_XP_CURRENT },
  { TextToken.XP_MAX, TextKey.OPT_FIELD_XP_MAX },
  { TextToken.XP_REMAINING, TextKey.OPT_FIELD_XP_REMAINING },
  { TextToken.RESTED, TextKey.OPT_FIELD_RESTED },
  { TextToken.TIME_TO_LEVEL, TextKey.OPT_FIELD_TIME_TO_LEVEL },
  { TextToken.XP_PER_HOUR, TextKey.OPT_FIELD_XP_PER_HOUR },
  { TextToken.QUEST_PENDING, TextKey.OPT_FIELD_QUEST_PENDING },
  { TextToken.TIME_ON_LEVEL, TextKey.OPT_FIELD_TIME_ON_LEVEL },
  { TextToken.SESSION_TIME, TextKey.OPT_FIELD_SESSION_TIME },
}

-- Each cycling axis: where it lives in the appearance table, the values it can
-- take in order, and the label for each. Data, so adding an axis is a row.
local CYCLES = {
  {
    labelKey = TextKey.OPT_BORDER_KIND, path = { "border", "kind" },
    values = {
      { BorderKind.NONE, TextKey.BORDER_NONE }, { BorderKind.HAIRLINE, TextKey.BORDER_HAIRLINE },
      { BorderKind.BEVEL, TextKey.BORDER_BEVEL }, { BorderKind.FRAME, TextKey.BORDER_FRAME },
    },
  },
  {
    labelKey = TextKey.OPT_SEPARATOR_KIND, path = { "separator", "kind" },
    values = {
      { SeparatorKind.NONE, TextKey.SEPARATOR_NONE }, { SeparatorKind.HAIRLINE, TextKey.SEPARATOR_HAIRLINE },
      { SeparatorKind.NOTCH, TextKey.SEPARATOR_NOTCH },
    },
  },
  {
    labelKey = TextKey.OPT_FILL_KIND, path = { "fill", "kind" },
    values = {
      { FillKind.FLAT, TextKey.FILL_FLAT }, { FillKind.GRADIENT_UP, TextKey.FILL_GRADIENT_UP },
      { FillKind.GRADIENT_DN, TextKey.FILL_GRADIENT_DN },
    },
  },
  {
    labelKey = TextKey.OPT_TEXT_STYLE, path = { "text", "style" },
    values = {
      { TextStyle.PLAIN, TextKey.TEXTSTYLE_PLAIN }, { TextStyle.OUTLINE, TextKey.TEXTSTYLE_OUTLINE },
      { TextStyle.HEAVY, TextKey.TEXTSTYLE_HEAVY },
    },
  },
  {
    labelKey = TextKey.OPT_TEXT_ANCHOR, path = { "text", "anchor" },
    values = {
      { TextAnchor.INSIDE_LEFT, TextKey.ANCHOR_INSIDE_LEFT },
      { TextAnchor.INSIDE_CENTER, TextKey.ANCHOR_INSIDE_CENTER },
      { TextAnchor.INSIDE_RIGHT, TextKey.ANCHOR_INSIDE_RIGHT },
      { TextAnchor.ABOVE, TextKey.ANCHOR_ABOVE }, { TextAnchor.BELOW, TextKey.ANCHOR_BELOW },
    },
  },
}

-- The plate's accessory zones, each with the label beside its box. The order
-- is the layout service's, tested to cover the vocabulary exactly; this table
-- only pairs zone and label. A zone missing here could not be switched off, so
-- the smoke harness counts these rows against the vocabulary.
local PLATE_ZONE_ROWS = {
  { PlateZone.CLOCK, TextKey.OPT_PLATE_ZONE_CLOCK },
  { PlateZone.REMAINING, TextKey.OPT_PLATE_ZONE_REMAINING },
  { PlateZone.STREAK, TextKey.OPT_PLATE_ZONE_STREAK },
  { PlateZone.SOURCES, TextKey.OPT_PLATE_ZONE_SOURCES },
  { PlateZone.CREATURES, TextKey.OPT_PLATE_ZONE_CREATURES },
  { PlateZone.ABILITIES, TextKey.OPT_PLATE_ZONE_ABILITIES },
  { PlateZone.FOOTER, TextKey.OPT_PLATE_ZONE_FOOTER },
}

-- The axes of the plate's own appearance map that get a control here. The map
-- admits more, all type-checked by the resolver.
--
-- `own` marks an axis the plate reads from its own map only. The plate ignores
-- the skin's text size, style and anchor, so an untouched text size falls back
-- to the layout service's base, not to what the bar resolved.
local PLATE_AXES = {
  { labelKey = TextKey.OPT_BACKGROUND_ALPHA, path = { "background", "a" }, bounds = ALPHA },
  { labelKey = TextKey.OPT_BORDER_THICKNESS, path = { "border", "thickness" }, bounds = THICKNESS },
  { labelKey = TextKey.OPT_TEXT_SIZE, path = { "text", "size" }, bounds = PlateLayout.TEXT_SIZE, own = true },
}

local SLIDERS = {
  { labelKey = TextKey.OPT_BORDER_THICKNESS, path = { "border", "thickness" }, bounds = THICKNESS },
  { labelKey = TextKey.OPT_SEPARATOR_THICKNESS, path = { "separator", "thickness" }, bounds = THICKNESS },
  { labelKey = TextKey.OPT_GLOSS, path = { "fill", "gloss" }, bounds = ALPHA },
  { labelKey = TextKey.OPT_BACKGROUND_ALPHA, path = { "background", "a" }, bounds = ALPHA },
  { labelKey = TextKey.OPT_TEXT_SIZE, path = { "text", "size" }, bounds = TEXT_SIZE },
}

-- ---------------------------------------------------------------------------
-- Reading and writing the player's overrides
-- ---------------------------------------------------------------------------

local function readPath(root, path)
  local node = root
  for _, key in ipairs(path) do
    if Frozen.isFrozen(node) then
      if not Frozen.has(node, key) then
        return nil
      end
      node = node[key]
    elseif type(node) == "table" then
      node = node[key]
    else
      return nil
    end
    if node == nil then
      return nil
    end
  end
  return node
end

local OptionsPanel = {}

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

-- How far below `root` a widget's top edge ends up, following the chain of
-- anchors the controls were built with. It sizes the scroll child: controls
-- past the child's bottom edge cannot be scrolled to, and the client shows no
-- error. Walked rather than tallied, since the offsets live at the call sites.
local function depthBelow(widget, root)
  local total, hops = 0, 0
  local current = widget
  while current ~= nil and current ~= root and hops < 64 do
    local _, parent, _, _, y = current:GetPoint(1)
    if parent == nil then
      break
    end
    -- Anchored TOPLEFT to the previous control's BOTTOMLEFT: this one's top is
    -- the parent's top, plus the parent's height, plus a negative offset.
    total = total - (y or 0)
    if parent ~= root then
      total = total + (parent:GetHeight() or 0)
    end
    current = parent
    hops = hops + 1
  end
  return total
end

-- How far right a widget sits from `root`, by the walk depthBelow does
-- vertically. Sections hang off whatever control came last, and a control in a
-- gallery's third column carries that column's offset, which a section would
-- otherwise inherit and push off the panel's right edge.
local function indentFrom(widget, root)
  local total, hops = 0, 0
  while widget ~= nil and widget ~= root and hops < 64 do
    local _, parent, _, x = widget:GetPoint(1)
    if parent == nil then
      break
    end
    total = total + (x or 0)
    widget, hops = parent, hops + 1
  end
  return total
end

-- Every section starts at the panel's left edge: its heading cancels the
-- inherited indent, so no section needs to know what came before it.
local function heading(panel, key, anchor, gap, locale)
  local text = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -indentFrom(anchor, panel), -(gap or 16))
  text:SetText(locale:get(key))
  return text
end

-- Whether this client has the dropdown family. Five globals, all or nothing:
-- with only some, a control would open onto nothing.
local HAS_DROPDOWN = UIDropDownMenu_Initialize ~= nil and UIDropDownMenu_CreateInfo ~= nil
  and UIDropDownMenu_AddButton ~= nil and UIDropDownMenu_SetWidth ~= nil
  and UIDropDownMenu_SetText ~= nil

ns.ui.HAS_DROPDOWN = HAS_DROPDOWN

-- `place` is optional and only the field grid passes it; by default each
-- control stacks under the last.
local function createCheckbox(panel, name, labelKey, anchor, locale, onChange, place)
  local check = CreateFrame("CheckButton", "AscentOptions" .. name .. "CheckButton", panel,
    "InterfaceOptionsCheckButtonTemplate")
  place = place or { relativePoint = "BOTTOMLEFT", x = 0, y = -8 }
  check:SetPoint("TOPLEFT", anchor, place.relativePoint, place.x, place.y)
  _G[check:GetName() .. "Text"]:SetText(locale:get(labelKey))
  check:SetScript("OnClick", function(self)
    onChange(self:GetChecked() == true)
  end)
  return check
end

-- Set while the panel writes its controls from the settings. Otherwise a
-- refresh looks like a drag: SetValue fires OnValueChanged, which previews, and
-- previewing resizes the real bar, so opening the page would edit the bar.
local refreshing = false

local function createSlider(panel, name, labelKey, anchor, locale, bounds, preview, commit)
  local slider = CreateFrame("Slider", "AscentOptions" .. name .. "Slider", panel, "OptionsSliderTemplate")
  -- No horizontal offset: sliders hang off one another, so an indent here
  -- would accumulate per slider.
  slider:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -26)
  slider:SetWidth(220)
  slider:SetMinMaxValues(bounds.min, bounds.max)
  slider:SetValueStep(bounds.step)
  if slider.SetObeyStepOnDrag then
    slider:SetObeyStepOnDrag(true)
  end
  -- The template centres its label over the slider, so a label wider than the
  -- slider overflows both ends, off the page on the left. Left-aligned above it
  -- instead, like every other label here.
  local label = _G[slider:GetName() .. "Text"]
  label:SetText(locale:get(labelKey))
  label:ClearAllPoints()
  label:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 3)
  label:SetJustifyH("LEFT")
  _G[slider:GetName() .. "Low"]:SetText(tostring(bounds.min))
  _G[slider:GetName() .. "High"]:SetText(tostring(bounds.max))
  slider:SetScript("OnValueChanged", function(_, value)
    if refreshing then
      return
    end
    if preview ~= nil then preview(value) end
  end)
  slider:SetScript("OnMouseUp", function(self) commit(self:GetValue()) end)
  return slider
end

-- A one-axis reset. A button rather than a menu entry because it is shown only
-- while the player holds an override on that axis: after a skin change, the
-- visible buttons list exactly the player's settings still applied over it.
local function createAxisReset(panel, name, anchor, locale, onClick)
  local button = CreateFrame("Button", "AscentOptions" .. name .. "Reset", panel, "UIPanelButtonTemplate")
  button:SetSize(66, 20)
  button:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
  button:SetText(locale:get(TextKey.OPT_RESET_AXIS))
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(locale:get(TextKey.OPT_RESET_AXIS_TIP))
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  button:SetScript("OnClick", onClick)
  button:Hide()
  return button
end

-- The client's colour picker, driven through whichever interface this flavour
-- has: the modern one takes a table of callbacks, the older one fields on the
-- frame itself.
--
-- A state machine, not a callback: every colour dragged through fires
-- `swatchFunc`, and like a slider a pick previews continuously and persists at
-- most once, when it ends. Cancelling writes nothing.
--
-- Neither flavour reports Okay: it just hides the frame, and only Cancel has a
-- callback. So cancel empties the slot below, and a pick still in it when the
-- frame hides was confirmed.

-- The pick in progress, or nil. One slot is enough: the picker is a single
-- shared frame, so there is never a second pick to hold.
local pick = nil
local hookedPicker = false

local function sameColor(a, b)
  return a ~= nil and b ~= nil
    and math.abs(a.r - b.r) < 0.001
    and math.abs(a.g - b.g) < 0.001
    and math.abs(a.b - b.b) < 0.001
end

-- Ends the pick in progress. `confirmed` is false only from cancelFunc.
--
-- A confirmed pick that never moved off its opening colour writes nothing. The
-- picker opens on the colour the bar paints, which for an untouched source is
-- the palette colour as tinted by the current skin; writing it back would pin
-- the source to this skin instead of following the palette (BAR_COLORS in
-- core/constants/Settings.lua).
local function closePick(confirmed)
  local active = pick
  if active == nil then
    return
  end
  pick = nil
  if confirmed and active.trial ~= nil and not sameColor(active.trial, active.start) then
    active.commit(active.trial)
  else
    active.restore()
  end
end

-- Hooked once, never per click: ColorPickerFrame is shared and HookScript
-- stacks handlers, so per-click hooks would replay every pick of the session on
-- one Okay.
local function hookPicker()
  if hookedPicker then
    return
  end
  hookedPicker = true
  ColorPickerFrame:HookScript("OnHide", function() closePick(true) end)
end

-- `current` is the colour the bar paints for this source now, where the picker
-- opens. `handlers` are `preview` (show it, persist nothing), `commit` (persist,
-- once) and `restore` (repaint what is stored; nothing was written).
local function openColorPicker(current, handlers)
  local r, g, b = current.r, current.g, current.b

  hookPicker()

  local function onSwatch()
    -- The picker restores its own colour on cancel, which fires this again
    -- after the slot is gone. Nothing left to preview by then.
    if pick == nil then
      return
    end
    local nr, ng, nb = ColorPickerFrame:GetColorRGB()
    pick.trial = { r = nr, g = ng, b = nb }
    handlers.preview(pick.trial)
  end

  local function onCancel()
    closePick(false)
  end

  local function startPick()
    pick = {
      start = { r = r, g = g, b = b },
      trial = nil,
      commit = handlers.commit,
      restore = handlers.restore,
    }
  end

  if ColorPickerFrame.SetupColorPickerAndShow ~= nil then
    startPick()
    ColorPickerFrame:SetupColorPickerAndShow({
      r = r, g = g, b = b, hasOpacity = false,
      swatchFunc = onSwatch,
      cancelFunc = onCancel,
    })
    return
  end

  ColorPickerFrame.hasOpacity = false
  ColorPickerFrame.previousValues = { r = r, g = g, b = b }
  ColorPickerFrame.cancelFunc = onCancel
  -- `swatchFunc`, not `func`: this picker reads swatchFunc and ignores func, so
  -- the older spelling would open a picker that changes nothing.
  ColorPickerFrame.swatchFunc = onSwatch
  ColorPickerFrame:SetColorRGB(r, g, b)
  -- Hidden, then armed, then shown. The Hide re-runs the picker's setup on a
  -- frame that may already be open and fires the OnHide hook, so the slot is
  -- filled after it, or opening a picker would read as confirming it.
  ColorPickerFrame:Hide()
  startPick()
  ColorPickerFrame:Show()
end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

function OptionsPanel.new(context)
  local bar = context.bar
  local saveSetting = context.saveSetting
  local locale = context.locale
  -- A question, not the adapter: the panel only needs to know whether the
  -- client has a bar to take over. Optional, since a context (or a test) may
  -- not offer it.
  local clientBarPresent = context.clientBarPresent

  -- The level every preview here draws, built once and shared read-only. It
  -- comes from the demo driver through the composition root, so the addon has
  -- one synthetic level, not one per surface.
  local sample = context.demoSample()

  -- One page per section, each its own entry under Ascent in the AddOns list,
  -- as other addons do. A single tall canvas risks controls past the bottom of
  -- the scroll child and sections inheriting a gallery's indent; a one-section
  -- page is short enough for neither.
  local pages = {}

  local function newPage(key, titleKey, descriptionKey)
    local frame = CreateFrame("Frame")
    frame.name = locale:get(titleKey)

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(frame.name)

    local description = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    description:SetPoint("RIGHT", frame, "RIGHT", -28, 0)
    description:SetJustifyH("LEFT")
    description:SetText(locale:get(descriptionKey))

    -- Named, because UIPanelScrollFrameTemplate builds its scroll bar as
    -- $parentScrollBar and a nil name makes the whole CreateFrame fail.
    local scroll = CreateFrame("ScrollFrame", "AscentOptions" .. key .. "Scroll", frame,
      "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -10)
    scroll:SetPoint("BOTTOMRIGHT", -28, 12)

    local pageContent = CreateFrame("Frame", nil, scroll)
    pageContent:SetSize(520, 100)
    scroll:SetScrollChild(pageContent)

    -- A point of no size at the top left, so a section's first control hangs
    -- off the page itself and indentFrom answers zero at the start of a page.
    local top = CreateFrame("Frame", nil, pageContent)
    -- Anchored to the content explicitly, not by implicit parent: depthBelow
    -- measures a page by walking named anchors.
    top:SetPoint("TOPLEFT", pageContent, "TOPLEFT", 0, 0)
    top:SetSize(1, 1)

    local page = { frame = frame, content = pageContent, top = top, key = key }
    pages[#pages + 1] = page
    return page
  end

  local pageMain = newPage("Main", TextKey.OPT_PAGE_MAIN, TextKey.OPT_PAGE_MAIN_DESC)
  local pageSkin = newPage("Skin", TextKey.OPT_SECTION_SKIN, TextKey.OPT_PAGE_SKIN_DESC)
  local pageColors = newPage("Colors", TextKey.OPT_SECTION_COLORS, TextKey.OPT_PAGE_COLORS_DESC)
  local pageFields = newPage("Fields", TextKey.OPT_SECTION_FIELDS, TextKey.OPT_PAGE_FIELDS_DESC)
  local pageSize = newPage("Size", TextKey.OPT_SECTION_SIZE, TextKey.OPT_PAGE_SIZE_DESC)
  local pageBehaviour = newPage("Behaviour", TextKey.OPT_SECTION_BEHAVIOUR, TextKey.OPT_PAGE_BEHAVIOUR_DESC)
  -- The pull plate gets one page of its own rather than its settings spread
  -- across the bar's pages, so one surface is set in one place.
  local pagePlate = newPage("Plate", TextKey.OPT_PAGE_PLATE, TextKey.OPT_PAGE_PLATE_DESC)

  local content = pageMain.content

  local view = {}

  local function currentSettings()
    return context.settings()
  end

  local function appearanceFor(overrides, colors)
    local settings = currentSettings()
    return SkinResolver.resolve({
      skin = SkinResolver.skinFor(SkinCatalog, settings[SettingKey.BAR_SKIN], ns.core.DEFAULT_SKIN_ID),
      overrides = overrides or settings[SettingKey.BAR_APPEARANCE],
      colors = colors or settings[SettingKey.BAR_COLORS],
      palette = Palette,
      highContrast = settings[SettingKey.HIGH_CONTRAST],
    })
  end

  -- Shows a change in the preview without persisting it, so a slider feels
  -- immediate without writing the repository per pixel.
  local function previewOverrides(overrides)
    view.preview:apply(appearanceFor(overrides), currentSettings()[SettingKey.MOTION_SCALE])
  end

  -- Which override map, then the axis inside it. The key is a parameter because
  -- the plate's own map has the same shape as BAR_APPEARANCE and shares this
  -- code, pruning included.
  --
  -- Frozen.plain, always: settings come back frozen, and a proxy saved back
  -- reaches Frozen as an array-like table and is silently emptied.
  local function overridesWith(key, path, value)
    local overrides = Frozen.plain(currentSettings()[key])
    local node = overrides
    for index = 1, #path - 1 do
      node[path[index]] = node[path[index]] or {}
      node = node[path[index]]
    end
    node[path[#path]] = value
    return overrides
  end

  local function commitOverride(key, path, value)
    saveSetting(key, overridesWith(key, path, value))
    view.refresh()
  end

  -- Whether this axis is the player's rather than the skin's. Read from the
  -- override table: the resolved appearance has a value for every axis.
  local function hasOverride(key, path)
    return readPath(currentSettings()[key], path) ~= nil
  end

  -- The overrides with one axis taken out and the rest untouched. Empty parents
  -- are pruned: a leftover `border = {}` would read as an override to
  -- hasOverride and keep its reset button on screen.
  local function overridesWithout(key, path)
    local overrides = Frozen.plain(currentSettings()[key])
    local chain = { overrides }
    local node = overrides
    for index = 1, #path - 1 do
      node = node[path[index]]
      if type(node) ~= "table" then
        return overrides
      end
      chain[#chain + 1] = node
    end
    node[path[#path]] = nil
    for index = #chain, 2, -1 do
      if next(chain[index]) ~= nil then
        break
      end
      chain[index - 1][path[index - 1]] = nil
    end
    return overrides
  end

  local function resetOverride(key, path)
    return function()
      saveSetting(key, overridesWithout(key, path))
      view.refresh()
    end
  end

  -- The size and motion axes are settings of their own, not appearance entries:
  -- reset writes the default, and "changed" means differing from it.
  -- saveSetting hot-applies each through the bar (app/Bootstrap.lua).
  local function resetSetting(key)
    return function()
      saveSetting(key, ns.core.Defaults[key])
      view.refresh()
    end
  end

  local function differsFromDefault(key)
    return currentSettings()[key] ~= ns.core.Defaults[key]
  end

  local function currentValue(path, fallback)
    local stored = readPath(currentSettings()[SettingKey.BAR_APPEARANCE], path)
    if stored ~= nil then
      return stored
    end
    return readPath(appearanceFor(), path) or fallback
  end

  -- --- preview -------------------------------------------------------------

  local previewHeading = heading(content, TextKey.OPT_SECTION_PREVIEW, pageMain.top, 4, locale)
  view.preview = BarPreview.new({ parent = content, width = 400, height = 24, sample = sample })
  view.preview:setPoints("TOPLEFT", previewHeading, "BOTTOMLEFT", 4, -10)

  local replay = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  replay:SetSize(180, 22)
  replay:SetPoint("TOPLEFT", view.preview.frame, "BOTTOMLEFT", 0, -8)
  replay:SetText(locale:get(TextKey.OPT_REPLAY))
  replay:SetScript("OnClick", function()
    view.preview:replay(currentSettings()[SettingKey.MOTION_SCALE])
  end)

  -- One OnUpdate drives the preview's animation, running only while the page
  -- is shown.
  content:SetScript("OnUpdate", function(_, elapsed)
    view.preview:tick(elapsed)
  end)

  -- --- skin gallery --------------------------------------------------------

  -- First, above the skins: where the bar lives decides whether its position
  -- and size are the player's to set.
  --
  -- Declared in an order the player can follow (free, then the two degrees of
  -- taking over) rather than sorted, which would put inset before off.
  local SLOT_CYCLE = {
    { BarSlot.OFF, TextKey.OPT_SLOT_OFF },
    { BarSlot.INSET, TextKey.OPT_SLOT_INSET },
    { BarSlot.REPLACE, TextKey.OPT_SLOT_REPLACE },
  }

  local function slotNameOf(slot)
    for _, entry in ipairs(SLOT_CYCLE) do
      if entry[1] == slot then
        return locale:get(entry[2])
      end
    end
    return tostring(slot)
  end

  -- The label is its own line and the control shows the value: the values are
  -- long enough that one button carrying both would overflow.
  local slotLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  slotLabel:SetPoint("TOPLEFT", replay, "BOTTOMLEFT", 4, -12)
  slotLabel:SetText(locale:get(TextKey.OPT_BAR_SLOT))

  local function chooseSlot(slot)
    saveSetting(SettingKey.BAR_SLOT, slot)
    view.refresh()
  end

  -- A dropdown when the client has the five globals it needs (probed, and
  -- reported by `/ascent debug`), the cycling button otherwise. The slot is the
  -- one control whose values are sentences, which a dropdown shows without a
  -- button as wide as the longest one.
  if HAS_DROPDOWN then
    view.slotDropdown = CreateFrame("Frame", "AscentOptionsSlotDropdown", content, "UIDropDownMenuTemplate")
    -- The template draws its left padding outside the frame, so it is pulled
    -- back to align with the labels.
    view.slotDropdown:SetPoint("TOPLEFT", slotLabel, "BOTTOMLEFT", -16, -4)
    UIDropDownMenu_SetWidth(view.slotDropdown, 240)
    UIDropDownMenu_Initialize(view.slotDropdown, function()
      local current = currentSettings()[SettingKey.BAR_SLOT]
      for _, entry in ipairs(SLOT_CYCLE) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = locale:get(entry[2])
        info.checked = current == entry[1]
        info.func = function() chooseSlot(entry[1]) end
        UIDropDownMenu_AddButton(info)
      end
    end)
  else
    view.slotButton = CreateFrame("Button", "AscentOptionsSlotButton", content, "UIPanelButtonTemplate")
    view.slotButton:SetSize(260, 22)
    view.slotButton:SetPoint("TOPLEFT", slotLabel, "BOTTOMLEFT", 0, -6)
    view.slotButton:SetScript("OnClick", function()
      local current = currentSettings()[SettingKey.BAR_SLOT]
      local nextIndex = 1
      for position, entry in ipairs(SLOT_CYCLE) do
        if entry[1] == current then
          nextIndex = position % #SLOT_CYCLE + 1
        end
      end
      chooseSlot(SLOT_CYCLE[nextIndex][1])
    end)
  end

  view.slotControl = view.slotDropdown or view.slotButton

  -- Why the width and height sliders are disabled, shown only while they are.
  view.slotNote = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  view.slotNote:SetPoint("TOPLEFT", view.slotControl, "BOTTOMLEFT", view.slotDropdown and 20 or 0, -4)
  view.slotNote:SetWidth(320)
  view.slotNote:SetJustifyH("LEFT")
  view.slotNote:Hide()

  pageMain.last = view.slotNote

  content = pageSkin.content
  local skinHeading = heading(content, TextKey.OPT_SECTION_SKIN, pageSkin.top, 4, locale)

  view.swatches = {}
  local skinIds = Frozen.keys(SkinCatalog)
  -- The swatch that starts the last row, not the last swatch: what follows the
  -- gallery hangs off it, and the last swatch may sit in a later column, whose
  -- indent would push the next section off the panel's right edge.
  local lastRowStart = skinHeading
  for index, id in ipairs(skinIds) do
    local holder = CreateFrame("Button", "AscentOptionsSkin" .. id .. "Swatch", content)
    holder:SetSize(SWATCH_WIDTH, SWATCH_HEIGHT)
    local column = (index - 1) % SWATCH_COLUMNS
    local rowIndex = math.floor((index - 1) / SWATCH_COLUMNS)
    holder:SetPoint("TOPLEFT", skinHeading, "BOTTOMLEFT",
      4 + column * (SWATCH_WIDTH + 8), -10 - rowIndex * (SWATCH_HEIGHT + 22))

    local selected = holder:CreateTexture(nil, "BACKGROUND")
    selected:SetPoint("TOPLEFT", -3, 3)
    selected:SetPoint("BOTTOMRIGHT", 3, -3)
    selected:SetColorTexture(1, 0.82, 0.3, 0.35)
    selected:Hide()

    -- The bar's own renderer painting the sample, so a swatch looks exactly as
    -- the bar would.
    local swatch = BarPreview.new({
      parent = holder, width = SWATCH_WIDTH, height = 18, animated = false, sample = sample,
    })
    swatch:setPoints("TOPLEFT", holder, "TOPLEFT", 0, 0)
    swatch:apply(SkinResolver.resolve({
      skin = SkinCatalog[id], palette = Palette,
      colors = currentSettings()[SettingKey.BAR_COLORS],
    }), 0)

    local name = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("TOP", holder, "BOTTOM", 0, -2)
    name:SetText(locale:get("skin_" .. id))

    holder:SetScript("OnClick", function()
      saveSetting(SettingKey.BAR_SKIN, id)
      view.refresh()
    end)

    view.swatches[id] = { holder = holder, selected = selected, swatch = swatch }
    -- On every row start, not only at the last swatch, which is not in the
    -- first column; otherwise what follows would anchor to the heading and draw
    -- over the swatches.
    if column == 0 then
      lastRowStart = holder
    end
  end

  local contrastCheck = createCheckbox(content, "HighContrast", TextKey.OPT_HIGH_CONTRAST,
    lastRowStart, locale, function(checked)
      saveSetting(SettingKey.HIGH_CONTRAST, checked)
      view.refresh()
    end,
    -- Clear of the swatch's name, which hangs below the swatch itself.
    { relativePoint = "BOTTOMLEFT", x = 0, y = -26 })

  -- --- colours -------------------------------------------------------------

  content = pageColors.content
  local colorHeading = heading(content, TextKey.OPT_SECTION_COLORS, pageColors.top, 4, locale)

  view.colorButtons = {}
  local lastColorRow = colorHeading
  for index, row in ipairs(COLOR_ROWS) do
    -- Named like the sliders and checkboxes: a swatch's behaviour cannot be read
    -- off its frame, so a name for /framestack and the smoke harness is worth the
    -- global.
    local button = CreateFrame("Button", "AscentOptionsColor" .. row.key .. "Button", content)
    button:SetSize(20, 20)
    -- Two columns: on a page this narrow a third column's labels would run
    -- past the right edge. Two columns fit the longest label.
    local column = (index - 1) % 2
    local rowIndex = math.floor((index - 1) / 2)
    button:SetPoint("TOPLEFT", colorHeading, "BOTTOMLEFT",
      4 + column * 230, -10 - rowIndex * 26)

    local swatchTexture = button:CreateTexture(nil, "ARTWORK")
    swatchTexture:SetAllPoints(button)
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 1)

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", button, "RIGHT", 6, 0)
    label:SetText(locale:get(row.labelKey))

    button:SetScript("OnClick", function()
      -- The stored overrides as they were before the picker opened. Every
      -- handler builds off this snapshot: the settings do not change while
      -- colours are being tried.
      local stored = Frozen.plain(currentSettings()[SettingKey.BAR_COLORS])

      openColorPicker(appearanceFor().colors[row.key], {
        -- Preview: the demo bar and this swatch only. Nothing reaches the
        -- repository, so an abandoned colour leaves nothing to undo.
        preview = function(chosen)
          local trial = Frozen.plain(stored)
          trial[row.key] = chosen
          view.preview:apply(appearanceFor(nil, trial), currentSettings()[SettingKey.MOTION_SCALE])
          swatchTexture:SetColorTexture(chosen.r, chosen.g, chosen.b, 1)
        end,
        commit = function(chosen)
          stored[row.key] = chosen
          saveSetting(SettingKey.BAR_COLORS, stored)
          view.refresh()
        end,
        -- Nothing was written: repainting from the settings removes the
        -- previewed colour.
        restore = function() view.refresh() end,
      })
    end)

    view.colorButtons[row.key] = swatchTexture
    if index == #COLOR_ROWS then
      lastColorRow = button
    end
  end

  local resetColors = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  resetColors:SetSize(150, 22)
  resetColors:SetPoint("TOPLEFT", lastColorRow, "BOTTOMLEFT", 0, -10)
  resetColors:SetText(locale:get(TextKey.OPT_RESET_COLORS))
  resetColors:SetScript("OnClick", function()
    saveSetting(SettingKey.BAR_COLORS, {})
    view.refresh()
  end)

  -- --- bar shape -----------------------------------------------------------

  pageColors.last = resetColors

  content = pageSkin.content
  local barHeading = heading(content, TextKey.OPT_SECTION_BAR, contrastCheck, 24, locale)

  view.cycles = {}
  local previous = barHeading
  for index, cycle in ipairs(CYCLES) do
    local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    button:SetSize(230, 22)
    button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", index == 1 and 4 or 0, -8)
    button:SetScript("OnClick", function()
      local current = currentValue(cycle.path)
      local nextIndex = 1
      for position, entry in ipairs(cycle.values) do
        if entry[1] == current then
          nextIndex = position % #cycle.values + 1
        end
      end
      commitOverride(SettingKey.BAR_APPEARANCE, cycle.path, cycle.values[nextIndex][1])
    end)
    view.cycles[index] = {
      button = button, cycle = cycle,
      reset = createAxisReset(content, "Cycle" .. index, button, locale,
        resetOverride(SettingKey.BAR_APPEARANCE, cycle.path)),
    }
    previous = button
  end

  view.sliders = {}
  for index, spec in ipairs(SLIDERS) do
    local slider = createSlider(content, "Axis" .. index, spec.labelKey, previous, locale, spec.bounds,
      function(value) previewOverrides(overridesWith(SettingKey.BAR_APPEARANCE, spec.path, value)) end,
      function(value) commitOverride(SettingKey.BAR_APPEARANCE, spec.path, value) end)
    view.sliders[index] = {
      slider = slider, spec = spec,
      reset = createAxisReset(content, "Axis" .. index, slider, locale,
        resetOverride(SettingKey.BAR_APPEARANCE, spec.path)),
    }
    previous = slider
  end

  pageSkin.last = previous

  -- --- what the bar says ---------------------------------------------------

  -- Two columns, since eleven checkboxes in one would be taller than the
  -- window. Column major: the declared order runs down the left, then down the
  -- right, so it still reads as an order.
  content = pageFields.content
  local fieldsHeading = heading(content, TextKey.OPT_SECTION_FIELDS, pageFields.top, 4, locale)

  view.fieldChecks = {}
  local COLUMN = math.ceil(#FIELDS / 2)
  local columnTop = { fieldsHeading, fieldsHeading }
  local previousInColumn = { fieldsHeading, fieldsHeading }

  for index, field in ipairs(FIELDS) do
    local token, labelKey = field[1], field[2]
    local column = index <= COLUMN and 1 or 2
    local first = previousInColumn[column] == columnTop[column]
    local check = createCheckbox(content, "Field" .. index, labelKey, previousInColumn[column], locale,
      function(checked)
        saveSetting(SettingKey.BAR_TEXT_TOKENS,
          BarTextFields.toggled(currentSettings()[SettingKey.BAR_TEXT_TOKENS], token, checked))
        view.refresh()
      end,
      -- The second column hangs off the heading at an offset, not off the
      -- checkbox to its left, whose label width varies.
      first and { relativePoint = "BOTTOMLEFT", x = column == 1 and 4 or 268, y = -8 }
        or { relativePoint = "BOTTOMLEFT", x = 0, y = -4 })
    view.fieldChecks[index] = { check = check, token = token }
    previousInColumn[column] = check
  end

  view.hoverCheck = createCheckbox(content, "TextOnHover", TextKey.OPT_TEXT_ON_HOVER,
    previousInColumn[1], locale, function(checked)
      saveSetting(SettingKey.BAR_TEXT_ON_HOVER, checked)
    end, { relativePoint = "BOTTOMLEFT", x = -4, y = -14 })

  -- Says what an empty selection means; a bar with no text is a valid choice.
  view.fieldsNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  view.fieldsNote:SetPoint("TOPLEFT", view.hoverCheck, "BOTTOMLEFT", 4, -8)
  view.fieldsNote:SetWidth(520)
  view.fieldsNote:SetJustifyH("LEFT")
  view.fieldsNote:Hide()

  -- --- size, motion, behaviour ---------------------------------------------

  pageFields.last = view.fieldsNote

  content = pageSize.content
  local sizeHeading = heading(content, TextKey.OPT_SECTION_SIZE, pageSize.top, 4, locale)

  view.widthSlider = createSlider(content, "Width", TextKey.OPT_BAR_WIDTH, sizeHeading, locale, WIDTH,
    function(value) bar.renderer:setSize(value, currentSettings()[SettingKey.BAR_HEIGHT]) end,
    function(value) saveSetting(SettingKey.BAR_WIDTH, value) end)
  view.heightSlider = createSlider(content, "Height", TextKey.OPT_BAR_HEIGHT, view.widthSlider, locale, HEIGHT,
    function(value) bar.renderer:setSize(currentSettings()[SettingKey.BAR_WIDTH], value) end,
    function(value) saveSetting(SettingKey.BAR_HEIGHT, value) end)
  view.scaleSlider = createSlider(content, "Scale", TextKey.OPTIONS_SCALE, view.heightSlider, locale, SCALE,
    function(value) bar.frame:SetScale(value) end,
    function(value) bar:setScale(value) end)

  local motionHeading = heading(content, TextKey.OPT_SECTION_MOTION, view.scaleSlider, 24, locale)
  view.motionSlider = createSlider(content, "Motion", TextKey.OPT_MOTION_SCALE, motionHeading, locale, MOTION,
    nil, function(value)
      saveSetting(SettingKey.MOTION_SCALE, value)
      view.preview:replay(value)
    end)

  -- The per-axis reset, for the four settings outside the appearance table.
  view.settingResets = {
    { key = SettingKey.BAR_WIDTH,
      reset = createAxisReset(content, "Width", view.widthSlider, locale, resetSetting(SettingKey.BAR_WIDTH)) },
    { key = SettingKey.BAR_HEIGHT,
      reset = createAxisReset(content, "Height", view.heightSlider, locale, resetSetting(SettingKey.BAR_HEIGHT)) },
    { key = SettingKey.BAR_SCALE,
      reset = createAxisReset(content, "Scale", view.scaleSlider, locale, resetSetting(SettingKey.BAR_SCALE)) },
    { key = SettingKey.MOTION_SCALE,
      reset = createAxisReset(content, "Motion", view.motionSlider, locale, resetSetting(SettingKey.MOTION_SCALE)) },
  }

  pageSize.last = view.motionSlider

  content = pageBehaviour.content
  local behaviourHeading = heading(content, TextKey.OPT_SECTION_BEHAVIOUR, pageBehaviour.top, 4, locale)
  view.lockedCheck = createCheckbox(content, "Locked", TextKey.OPTIONS_LOCK, behaviourHeading, locale,
    function(checked) bar:setLocked(checked) end)
  view.hideCheck = createCheckbox(content, "HideWithoutXp", TextKey.OPTIONS_HIDE_NO_XP, view.lockedCheck, locale,
    function(checked) saveSetting(SettingKey.HIDE_WITHOUT_XP, checked) end)
  view.questCheck = createCheckbox(content, "ShowQuestPending", TextKey.OPTIONS_SHOW_PENDING, view.hideCheck,
    locale, function(checked) saveSetting(SettingKey.SHOW_QUEST_PENDING, checked) end)
  view.damageCheck = createCheckbox(content, "CollectDamage", TextKey.OPTIONS_COLLECT_DAMAGE, view.questCheck,
    locale, function(checked) saveSetting(SettingKey.COLLECT_DAMAGE, checked) end)
  view.debugCheck = createCheckbox(content, "Debug", TextKey.OPTIONS_DEBUG, view.damageCheck, locale,
    function(checked) saveSetting(SettingKey.DEBUG, checked) end)
  -- Switching this off silences both the announcing and the warning, so the
  -- context applies it at once rather than only saving it: otherwise the addon
  -- would keep talking to the channel until a reload.
  view.updateCheck = createCheckbox(content, "UpdateCheck", TextKey.OPTIONS_UPDATE_CHECK, view.debugCheck,
    locale, function(checked)
      saveSetting(SettingKey.UPDATE_CHECK, checked)
      if context.setUpdateCheck ~= nil then
        context.setUpdateCheck(checked)
      end
    end)

  -- The report, from the options too: no addon can make a network request, so
  -- a pasted report is the only way a fault reaches the author, and a player
  -- about to report opens the options rather than `/ascent copy`.
  local copyReport = CreateFrame("Button", "AscentOptionsCopyReport", content, "UIPanelButtonTemplate")
  copyReport:SetSize(240, 22)
  copyReport:SetPoint("TOPLEFT", view.debugCheck, "BOTTOMLEFT", 0, -16)
  copyReport:SetText(locale:get(TextKey.OPT_COPY_REPORT))
  copyReport:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(locale:get(TextKey.OPT_COPY_REPORT_TIP))
    GameTooltip:Show()
  end)
  copyReport:SetScript("OnLeave", function() GameTooltip:Hide() end)
  if context.copyReport == nil then
    -- A context that offers no report (a test, say) gets a disabled button
    -- rather than one that does nothing.
    copyReport:Disable()
  else
    copyReport:SetScript("OnClick", function() context.copyReport() end)
  end
  view.copyReport = copyReport

  local resetAll = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  resetAll:SetSize(240, 22)
  resetAll:SetPoint("TOPLEFT", copyReport, "BOTTOMLEFT", 0, -8)
  resetAll:SetText(locale:get(TextKey.OPT_RESET_ALL))
  resetAll:SetScript("OnClick", function()
    saveSetting(SettingKey.BAR_APPEARANCE, {})
    saveSetting(SettingKey.BAR_COLORS, {})
    saveSetting(SettingKey.BAR_SKIN, ns.core.DEFAULT_SKIN_ID)
    view.refresh()
  end)

  pageBehaviour.last = resetAll

  -- --- the pull plate ------------------------------------------------------

  -- No preview on this page: the plate has no separate renderer and no sample
  -- pull, and one would mean a fictional PullRecord. The button at the bottom
  -- runs the demo instead, which drives the real plate through a whole pull at
  -- the chosen settings.

  -- The plate may be missing: the three views are built in one pcall, so a
  -- client that failed at the plate still has the bar and this panel. Its
  -- settings stay editable, and every use of it is guarded.
  local plate = context.plate

  -- The appearance the plate resolves: the bar's, with the plate's own map laid
  -- over it. A function of its own, not a flag on appearanceFor, which feeds the
  -- bar's preview and must never show the plate's tweaks.
  local function plateAppearance()
    local settings = currentSettings()
    return SkinResolver.resolve({
      skin = SkinResolver.skinFor(SkinCatalog, settings[SettingKey.BAR_SKIN], ns.core.DEFAULT_SKIN_ID),
      overrides = settings[SettingKey.BAR_APPEARANCE],
      own = settings[SettingKey.PLATE_APPEARANCE],
      colors = settings[SettingKey.BAR_COLORS],
      palette = Palette,
      highContrast = settings[SettingKey.HIGH_CONTRAST],
    })
  end

  -- One axis of the plate's look now: the player's value when set, otherwise
  -- what the plate draws with, which for the text size is the layout service's
  -- base, not the skin's (see PLATE_AXES).
  local function plateAxisValue(spec)
    local stored = readPath(currentSettings()[SettingKey.PLATE_APPEARANCE], spec.path)
    if stored ~= nil then
      return stored
    end
    if spec.own then
      return spec.bounds.default
    end
    return readPath(plateAppearance(), spec.path) or spec.bounds.min
  end

  -- The stored list with one zone added or removed, rebuilt in the canonical
  -- order rather than the order the boxes were ticked: the layout owns the
  -- order, and what is stored is a set of choices.
  local function zonesToggled(zone, checked)
    local chosen = {}
    for _, current in ipairs(currentSettings()[SettingKey.PLATE_ZONES]) do
      if current ~= zone then
        chosen[#chosen + 1] = current
      end
    end
    if checked then
      chosen[#chosen + 1] = zone
    end
    -- The first return value only: `zones` also returns a lookup, and the
    -- setting declares a list.
    return (PlateLayout.zones(chosen))
  end

  content = pagePlate.content
  local plateFrameHeading = heading(content, TextKey.OPT_SECTION_PLATE_FRAME, pagePlate.top, 4, locale)

  -- First, because it decides whether anything below it matters, as the bar's
  -- slot heads its page.
  view.plateEnabledCheck = createCheckbox(content, "PlateEnabled", TextKey.OPT_PLATE_ENABLED,
    plateFrameHeading, locale, function(checked)
      saveSetting(SettingKey.PLATE_ENABLED, checked)
    end)

  -- Its own lock, never the bar's: the bar is placed once, the plate moves with
  -- the fighting, and the bar's slot disables the bar's lock.
  view.plateLockedCheck = createCheckbox(content, "PlateLocked", TextKey.OPT_PLATE_LOCKED,
    view.plateEnabledCheck, locale, function(checked)
      saveSetting(SettingKey.PLATE_LOCKED, checked)
    end)

  -- The slider ranges come from core (SettingPanelRange), not literals: the
  -- setting admits what a hand-edited file may hold, the panel range what makes
  -- sense to drag, and a test keeps the second inside the first. The bar's
  -- slider bounds at the top of this file have no such test.
  --
  -- The preview writes to the frame, never through the view's applyFrame, place
  -- or currentAlpha: applySettings is the one hot-apply path, and three frame
  -- calls give the preview its immediacy.
  local function previewPlate(apply)
    if plate ~= nil and plate.frame ~= nil then
      apply(plate.frame)
    end
  end

  view.plateScaleSlider = createSlider(content, "PlateScale", TextKey.OPT_PLATE_SCALE,
    view.plateLockedCheck, locale, SettingPanelRange[SettingKey.PLATE_SCALE],
    function(value) previewPlate(function(frame) frame:SetScale(value) end) end,
    function(value) saveSetting(SettingKey.PLATE_SCALE, value) end)

  view.plateWidthSlider = createSlider(content, "PlateWidth", TextKey.OPT_PLATE_WIDTH,
    view.plateScaleSlider, locale, SettingPanelRange[SettingKey.PLATE_WIDTH],
    function(value) previewPlate(function(frame) frame:SetWidth(value) end) end,
    function(value) saveSetting(SettingKey.PLATE_WIDTH, value) end)

  -- Previewed by writing the frame's alpha, the channel the plate's fade uses.
  -- Safe only as a preview: the plate's next draw overwrites it with the factor
  -- times the fade, so nothing outlives the drag.
  view.plateOpacitySlider = createSlider(content, "PlateOpacity", TextKey.OPT_PLATE_OPACITY,
    view.plateWidthSlider, locale, SettingPanelRange[SettingKey.PLATE_OPACITY],
    function(value) previewPlate(function(frame) frame:SetAlpha(value) end) end,
    function(value) saveSetting(SettingKey.PLATE_OPACITY, value) end)

  -- No preview: a duration can only be seen by watching a plaque leave. The
  -- label says it is also the window in which a closed pull can resume.
  view.plateHoldSlider = createSlider(content, "PlateHold", TextKey.OPT_PLATE_HOLD,
    view.plateOpacitySlider, locale, SettingPanelRange[SettingKey.PLATE_HOLD_SECONDS],
    nil, function(value) saveSetting(SettingKey.PLATE_HOLD_SECONDS, value) end)

  -- --- what the plate shows ------------------------------------------------

  local plateContentHeading = heading(content, TextKey.OPT_SECTION_PLATE_CONTENT,
    view.plateHoldSlider, 24, locale)

  -- How many rows are shown. The rows are built at the range's ceiling and only
  -- shown or hidden, so this rebuilds no frame and can change mid-fight.
  view.plateRowsSlider = createSlider(content, "PlateRows", TextKey.OPT_PLATE_ROWS,
    plateContentHeading, locale, SettingPanelRange[SettingKey.PLATE_ROWS],
    nil, function(value) saveSetting(SettingKey.PLATE_ROWS, value) end)

  view.plateZoneChecks = {}
  local previousZone = view.plateRowsSlider
  for index, row in ipairs(PLATE_ZONE_ROWS) do
    local zone = row[1]
    local check = createCheckbox(content, "PlateZone" .. index, row[2], previousZone, locale,
      function(checked)
        saveSetting(SettingKey.PLATE_ZONES, zonesToggled(zone, checked))
        view.refresh()
      end,
      -- The first box clears the slider above; the rest stack tight, so they
      -- read as one list.
      index == 1 and { relativePoint = "BOTTOMLEFT", x = 4, y = -12 }
        or { relativePoint = "BOTTOMLEFT", x = 0, y = -4 })
    view.plateZoneChecks[index] = { check = check, zone = zone }
    previousZone = check
  end

  -- Says what an empty selection leaves, as the bar's field list does; every
  -- zone off is a valid choice. The section below is anchored to it, so refresh
  -- empties it as well as hiding it.
  view.plateZonesNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  view.plateZonesNote:SetPoint("TOPLEFT", previousZone, "BOTTOMLEFT", 4, -8)
  view.plateZonesNote:SetWidth(460)
  view.plateZonesNote:SetJustifyH("LEFT")
  view.plateZonesNote:Hide()

  -- --- the plate's own look ------------------------------------------------

  local plateLookHeading = heading(content, TextKey.OPT_SECTION_PLATE_LOOK,
    view.plateZonesNote, 24, locale)

  -- No preview on these, unlike the bar's axes: the plate reads its own map
  -- from the settings inside applySkin, so no trial map can be handed to it,
  -- and outside a fight it is not on screen. The demo button covers this.
  view.plateAxes = {}
  local previousPlateAxis = plateLookHeading
  for index, spec in ipairs(PLATE_AXES) do
    local slider = createSlider(content, "PlateLook" .. index, spec.labelKey, previousPlateAxis,
      locale, spec.bounds, nil,
      function(value) commitOverride(SettingKey.PLATE_APPEARANCE, spec.path, value) end)
    view.plateAxes[index] = {
      slider = slider, spec = spec,
      reset = createAxisReset(content, "PlateLook" .. index, slider, locale,
        resetOverride(SettingKey.PLATE_APPEARANCE, spec.path)),
    }
    previousPlateAxis = slider
  end

  local plateDemoButton = CreateFrame("Button", "AscentOptionsPlateDemo", content, "UIPanelButtonTemplate")
  plateDemoButton:SetSize(240, 22)
  plateDemoButton:SetPoint("TOPLEFT", previousPlateAxis, "BOTTOMLEFT", 0, -26)
  plateDemoButton:SetText(locale:get(TextKey.OPT_PLATE_DEMO))
  plateDemoButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(locale:get(TextKey.OPT_PLATE_DEMO_TIP))
    GameTooltip:Show()
  end)
  plateDemoButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  if context.startPlateDemo == nil then
    -- A context that cannot run one (a test, say) gets a disabled button
    -- rather than one that does nothing.
    plateDemoButton:Disable()
  else
    plateDemoButton:SetScript("OnClick", function() context.startPlateDemo() end)
  end
  view.plateDemoButton = plateDemoButton

  local plateReset = CreateFrame("Button", "AscentOptionsPlateReset", content, "UIPanelButtonTemplate")
  plateReset:SetSize(240, 22)
  plateReset:SetPoint("TOPLEFT", plateDemoButton, "BOTTOMLEFT", 0, -8)
  plateReset:SetText(locale:get(TextKey.OPT_PLATE_RESET))
  plateReset:SetScript("OnClick", function()
    for _, key in ipairs(ns.core.PlateSettingKeys) do
      -- A copy of the default, never the default itself: a frozen proxy saved
      -- back reaches Frozen as an array-like table and is silently emptied, and
      -- the list a frozen table returns is its backing store, which would put
      -- the addon's constants one write away from the saved variables.
      saveSetting(key, Frozen.plain(ns.core.Defaults[key]))
    end
    view.refresh()
  end)

  pagePlate.last = plateReset

  -- Each page is as tall as what it holds, measured rather than a constant,
  -- which the content would silently outgrow.
  for _, page in ipairs(pages) do
    local last = page.last
    if last ~= nil then
      page.content:SetHeight(depthBelow(last, page.content) + (last:GetHeight() or 0) + 24)
    end
  end

  -- --- refresh -------------------------------------------------------------

  -- Every control is set from the live settings, not from what it was built
  -- with: the chat commands change the same values.
  function view.refresh()
    refreshing = true
    local settings = currentSettings()
    local appearance = appearanceFor()

    view.preview:apply(appearance, settings[SettingKey.MOTION_SCALE])

    local activeSkin = settings[SettingKey.BAR_SKIN]
    for id, entry in pairs(view.swatches) do
      if id == activeSkin then entry.selected:Show() else entry.selected:Hide() end
      entry.swatch:apply(SkinResolver.resolve({
        skin = SkinCatalog[id], palette = Palette, colors = settings[SettingKey.BAR_COLORS],
        highContrast = settings[SettingKey.HIGH_CONTRAST],
      }), 0)
    end

    for key, texture in pairs(view.colorButtons) do
      local color = appearance.colors[key]
      texture:SetColorTexture(color.r, color.g, color.b, 1)
    end

    for _, entry in ipairs(view.cycles) do
      local current = currentValue(entry.cycle.path)
      local label = locale:get(entry.cycle.labelKey)
      for _, value in ipairs(entry.cycle.values) do
        if value[1] == current then
          label = label .. ": " .. locale:get(value[2])
        end
      end
      entry.button:SetText(label)
      if hasOverride(SettingKey.BAR_APPEARANCE, entry.cycle.path) then
        entry.reset:Show()
      else
        entry.reset:Hide()
      end
    end

    for _, entry in ipairs(view.sliders) do
      entry.slider:SetValue(currentValue(entry.spec.path, entry.spec.bounds.min))
      if hasOverride(SettingKey.BAR_APPEARANCE, entry.spec.path) then
        entry.reset:Show()
      else
        entry.reset:Hide()
      end
    end

    for _, entry in ipairs(view.settingResets) do
      if differsFromDefault(entry.key) then entry.reset:Show() else entry.reset:Hide() end
    end

    contrastCheck:SetChecked(settings[SettingKey.HIGH_CONTRAST])

    local chosenFields = settings[SettingKey.BAR_TEXT_TOKENS]
    for _, entry in ipairs(view.fieldChecks) do
      entry.check:SetChecked(BarTextFields.has(chosenFields, entry.token))
    end
    view.hoverCheck:SetChecked(settings[SettingKey.BAR_TEXT_ON_HOVER])
    if #chosenFields == 0 then
      view.fieldsNote:SetText(locale:get(TextKey.OPT_FIELDS_NONE))
      view.fieldsNote:Show()
    else
      -- Emptied as well as hidden: the size section below is anchored to it.
      view.fieldsNote:SetText("")
      view.fieldsNote:Hide()
    end

    -- The slot, and what it suspends. Suspended controls are disabled, not
    -- hidden: a vanished control reads as a bug, a greyed-out one with a
    -- sentence under it as a consequence.
    local slot = settings[SettingKey.BAR_SLOT]
    local suspended = BarSlotPolicy.suspends(slot)
    if view.slotDropdown ~= nil then
      UIDropDownMenu_SetText(view.slotDropdown, slotNameOf(slot))
    else
      view.slotButton:SetText(slotNameOf(slot))
    end
    if suspended.size then
      view.widthSlider:Disable()
      view.heightSlider:Disable()
      view.slotNote:SetText(locale:get(TextKey.OPT_SLOT_SUSPENDED))
      view.slotNote:Show()
    else
      view.widthSlider:Enable()
      view.heightSlider:Enable()
      -- Emptied as well as hidden: a hidden font string keeps the height of its
      -- last text, and everything below is anchored to this one.
      view.slotNote:SetText("")
      view.slotNote:Hide()
    end
    -- The other reason a slot does nothing, invisible from the bar: the client
    -- has no such bar to take over.
    if BarSlotPolicy.active(slot) and clientBarPresent ~= nil and not clientBarPresent() then
      view.slotNote:SetText(locale:get(TextKey.OPT_SLOT_UNAVAILABLE))
      view.slotNote:Show()
    end
    if suspended.position then
      view.lockedCheck:Disable()
    else
      view.lockedCheck:Enable()
    end
    -- The text anchor is suspended the same way: in the client's slot there is
    -- no outside to put text on, only the client's interface. Found by path, so
    -- adding or reordering a cycle cannot point this at the wrong button.
    for _, entry in ipairs(view.cycles or {}) do
      local path = entry.cycle.path
      if path[1] == "text" and path[2] == "anchor" then
        if suspended.textAnchor then
          entry.button:Disable()
        else
          entry.button:Enable()
        end
      end
    end

    view.widthSlider:SetValue(settings[SettingKey.BAR_WIDTH])
    view.heightSlider:SetValue(settings[SettingKey.BAR_HEIGHT])
    view.scaleSlider:SetValue(settings[SettingKey.BAR_SCALE])
    view.motionSlider:SetValue(settings[SettingKey.MOTION_SCALE])
    view.lockedCheck:SetChecked(settings[SettingKey.BAR_LOCKED])
    view.hideCheck:SetChecked(settings[SettingKey.HIDE_WITHOUT_XP])
    view.questCheck:SetChecked(settings[SettingKey.SHOW_QUEST_PENDING])
    view.damageCheck:SetChecked(settings[SettingKey.COLLECT_DAMAGE])
    view.debugCheck:SetChecked(settings[SettingKey.DEBUG])
    view.updateCheck:SetChecked(settings[SettingKey.UPDATE_CHECK])

    -- The plate's page, also from the live settings: a control left out of this
    -- shared refresh shows stale state with no error, and chat commands often
    -- change the plate's settings while the panel is open.
    view.plateEnabledCheck:SetChecked(settings[SettingKey.PLATE_ENABLED])
    view.plateLockedCheck:SetChecked(settings[SettingKey.PLATE_LOCKED])
    view.plateScaleSlider:SetValue(settings[SettingKey.PLATE_SCALE])
    view.plateWidthSlider:SetValue(settings[SettingKey.PLATE_WIDTH])
    view.plateOpacitySlider:SetValue(settings[SettingKey.PLATE_OPACITY])
    view.plateHoldSlider:SetValue(settings[SettingKey.PLATE_HOLD_SECONDS])
    view.plateRowsSlider:SetValue(settings[SettingKey.PLATE_ROWS])

    -- Asked of the layout service, which returns the drawn zones as a lookup,
    -- so the checkboxes agree with what the plate lays out.
    local chosenZones = settings[SettingKey.PLATE_ZONES]
    local _, drawnZones = PlateLayout.zones(chosenZones)
    for _, entry in ipairs(view.plateZoneChecks) do
      entry.check:SetChecked(drawnZones[entry.zone] == true)
    end
    if #chosenZones == 0 then
      view.plateZonesNote:SetText(locale:get(TextKey.OPT_PLATE_ZONES_NONE))
      view.plateZonesNote:Show()
    else
      -- Emptied as well as hidden: a hidden font string keeps the height of its
      -- last text, and the section below is anchored to this one.
      view.plateZonesNote:SetText("")
      view.plateZonesNote:Hide()
    end

    for _, entry in ipairs(view.plateAxes) do
      entry.slider:SetValue(plateAxisValue(entry.spec))
      -- Shown only while the axis is the player's, read from the override map:
      -- the resolved appearance has a value for every axis.
      if hasOverride(SettingKey.PLATE_APPEARANCE, entry.spec.path) then
        entry.reset:Show()
      else
        entry.reset:Hide()
      end
    end
    refreshing = false
  end

  -- Reachable from outside: a chat command, or the addon declining a slot the
  -- client cannot honour, changes these settings under an open panel.
  -- Every page refreshes the whole view: the pages share one settings table and
  -- one preview, only one is shown at a time, and a refresh is cheap.
  for _, page in ipairs(pages) do
    page.frame.refresh = view.refresh
    page.frame:SetScript("OnShow", view.refresh)
  end
  view.refresh()

  -- The first is the parent category and the rest are its children, in order.
  return pages
end

ns.ui.OptionsPanel = OptionsPanel
