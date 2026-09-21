-- Ascent - the appearance panel (12.7, and group 7's 7.2 through 7.5).
--
-- Everything the player can change about how Ascent looks lives here, in the
-- client's own AddOns settings, where they will look for it. The chat commands
-- are a shortcut and a way back when the interface itself cannot be used; they
-- are not the place to pick a skin.
--
-- THREE THINGS MAKE THIS DIFFERENT FROM THE USUAL ADDON OPTIONS PAGE:
--
--   * The skin gallery shows each skin DRAWN, not named. A swatch is a real
--     BarRenderer painting a real sample level, which is only possible because
--     the renderer was split from the compositor (design D34) -- a swatch has no
--     saved position, no drag and no ability to hide the real bar.
--   * A live preview sits at the top and reflects every change as it is made,
--     and replays the animation on demand. No addon in this ecosystem does this;
--     the usual flow is to change a dropdown and go outside to see what happened.
--   * Enumerated settings cycle through a button rather than opening a dropdown.
--     UIDropDownMenu would need five globals that cannot be verified against BC
--     Classic, and with three to five choices per axis a cycling button is fewer
--     clicks anyway.
--
-- WHY SLIDERS SPLIT OnValueChanged FROM OnMouseUp. Persisting means copying the
-- stored table, writing the repository and re-resolving and re-freezing every
-- setting. Right once, on release; wrong for every pixel of a drag. The preview
-- updates continuously; the write happens once.
--
-- Nothing here talks to SavedVariables, and nothing here draws the real bar: it
-- changes a setting and the bar reapplies itself.

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

-- Each cycling axis: where it lives in the appearance table, the values it can
-- take in order, and the label for each. Data, so adding an axis is a row.
-- What the bar can say, in the order it reads. The order itself is the domain's
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

-- A plain deep copy of a table that may be frozen. Frozen tables raise on a key
-- they do not have and cannot be walked with pairs, so neither a normal copy nor
-- a normal read works on one (see core/constants/Frozen.lua).
local function plainCopy(value)
  if Frozen.isFrozen(value) then
    local copy = {}
    for key, inner in Frozen.each(value) do
      copy[key] = plainCopy(inner)
    end
    return copy
  end
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, inner in pairs(value) do
    copy[key] = plainCopy(inner)
  end
  return copy
end

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

-- How far below `root` a widget's top edge ends up, following the same chain of
-- anchors the controls were built with.
--
-- This exists because the scroll child used to be 1400 tall because somebody
-- guessed, and the panel outgrew the guess: everything from the appearance axes
-- down -- the per-axis sliders, size, motion, behaviour -- sat past the child's
-- bottom edge, outside it, where no amount of scrolling reaches. In the client
-- the panel simply ended after the colour swatches, with no error and no gap to
-- suggest anything was missing.
--
-- Walked rather than tallied by hand: the offsets live at the call sites, and a
-- tally kept here would be a second copy of the layout that goes wrong the first
-- time somebody inserts a control.
local function depthBelow(widget, root)
  local total, hops = 0, 0
  local current = widget
  while current ~= nil and current ~= root and hops < 64 do
    local _, parent, _, _, y = current:GetPoint(1)
    if parent == nil then
      break
    end
    -- Anchored TOPLEFT to the previous control's BOTTOMLEFT: this one's top is
    -- the parent's top, plus the parent's own height, plus a negative offset.
    total = total - (y or 0)
    if parent ~= root then
      total = total + (parent:GetHeight() or 0)
    end
    current = parent
    hops = hops + 1
  end
  return total
end

-- How far right a widget sits from `root`, by the same walk depthBelow does
-- vertically. Sections hang off whatever control came last, and a control laid
-- out in the third column of a gallery carries that column's offset: inherited,
-- it pushed the colour swatches for exploration and pending clean off the right
-- edge of the panel, where the code that built them was perfectly correct and
-- nobody could click them.
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

-- Every section starts at the panel's left edge. The heading is what each one
-- hangs off, so pinning the heading pins the section -- and cancelling the
-- inherited indent here means no section has to know what came before it.
local function heading(panel, key, anchor, gap, locale)
  local text = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -indentFrom(anchor, panel), -(gap or 16))
  text:SetText(locale:get(key))
  return text
end

-- `place` is optional and only the field grid passes it: everything else stacks
-- one control under the last, which is what the default says.
-- Whether this client has the dropdown family. Five globals, all or nothing:
-- a client with three of them would build a control that opens onto nothing.
local HAS_DROPDOWN = UIDropDownMenu_Initialize ~= nil and UIDropDownMenu_CreateInfo ~= nil
  and UIDropDownMenu_AddButton ~= nil and UIDropDownMenu_SetWidth ~= nil
  and UIDropDownMenu_SetText ~= nil

ns.ui.HAS_DROPDOWN = HAS_DROPDOWN

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

-- Set while the panel is writing its controls from the settings. Without it,
-- refreshing is indistinguishable from the player dragging: SetValue fires
-- OnValueChanged, OnValueChanged previews, and previewing resizes the real bar.
-- Merely OPENING the options page would resize the player's bar to whatever the
-- slider's own bounds allowed -- a silent edit nobody asked for.
local refreshing = false

local function createSlider(panel, name, labelKey, anchor, locale, bounds, preview, commit)
  local slider = CreateFrame("Slider", "AscentOptions" .. name .. "Slider", panel, "OptionsSliderTemplate")
  -- No horizontal offset. Sliders hang off one another, so an indent here is not
  -- an indent -- it is an indent per slider, and five of them in a row walked the
  -- last one forty pixels right of the first.
  slider:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -26)
  slider:SetWidth(220)
  slider:SetMinMaxValues(bounds.min, bounds.max)
  slider:SetValueStep(bounds.step)
  if slider.SetObeyStepOnDrag then
    slider:SetObeyStepOnDrag(true)
  end
  -- The template centres its label over the slider, which is fine for "0.5" and
  -- wrong for "Motion intensity (0 turns animation off)": a label wider than its
  -- slider overflows BOTH ends, and the left end went off the page. Left-aligned
  -- above it instead, like every other label on these pages.
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

-- A one-axis reset (7.4). It does two jobs with one control, and the second is
-- the reason it is a button rather than a menu entry: it is ON SCREEN only
-- while the player actually holds an override on that axis, so what is left
-- showing after a skin change is exactly the list of their own settings still
-- being applied over the new skin -- which is the other thing the appearance
-- surface has to say and had no way of saying.
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
-- has. The modern one takes a table of callbacks; the older one takes fields on
-- the frame itself.
--
-- WHY THIS IS A STATE MACHINE AND NOT A CALLBACK. Every colour the player drags
-- through fires `swatchFunc`, and this panel's rule for a continuous setting is
-- the slider's rule (design D35): preview continuously, persist once. So a
-- trial colour only ever reaches the preview, and the repository is written --
-- at most once -- when the pick ends. Cancelling writes nothing at all, which
-- is what makes "no colour you tried is kept" true rather than approximately
-- true.
--
-- Neither flavour announces "the player pressed Okay": Okay just hides the
-- frame, and only Cancel has a callback. So confirmation is INFERRED -- cancel
-- empties the slot below, and a pick still in it when the frame hides was
-- confirmed.

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
-- A confirmed pick that never moved off the colour it opened on writes NOTHING,
-- and that is deliberate rather than an optimisation. The picker opens on the
-- colour the bar is PAINTING, which for a source the player never touched is
-- the palette colour as the current skin tinted it. Writing that back would pin
-- the source to today's skin and stop it following the palette -- the opposite
-- of what BAR_COLORS means (core/constants/Settings.lua).
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
-- stacks handlers, so hooking on every swatch click would replay the whole
-- session's picks on one Okay.
local function hookPicker()
  if hookedPicker then
    return
  end
  hookedPicker = true
  ColorPickerFrame:HookScript("OnHide", function() closePick(true) end)
end

-- `current` is the colour the bar paints for this source right now, which is
-- where the picker opens. `handlers` are `preview` (show it, persist nothing),
-- `commit` (persist, once) and `restore` (put back what was already stored --
-- there is nothing to undo, because nothing was written).
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
  -- `swatchFunc`, not `func`: this client's picker reads swatchFunc and never
  -- looks at func, so the older spelling would open a picker that changes
  -- nothing.
  ColorPickerFrame.swatchFunc = onSwatch
  ColorPickerFrame:SetColorRGB(r, g, b)
  -- Hidden, then armed, then shown. The Hide is what re-runs the picker's own
  -- setup on a frame that may already be open, and it fires the OnHide hook --
  -- so the slot is filled after it, never before, or opening a picker would
  -- read as confirming it.
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
  -- A question, not the adapter: the panel needs to know whether the client has a
  -- bar to take over, and nothing else about it. Optional, because a context
  -- built by an older path (or a test) has every right not to offer it.
  local clientBarPresent = context.clientBarPresent

  -- The level every preview on this page draws, built once and shared: they only
  -- ever read it. It comes from the composition root, which takes it from the
  -- demo driver (7.3), so there is one synthetic level in the addon and not one
  -- per surface that wants to show a bar.
  local sample = context.demoSample()

  -- ONE PAGE PER SECTION, each its own entry under Ascent in the AddOns list --
  -- the shape every other addon in this client uses, and the answer to three
  -- defects that were all the same defect. A single canvas two thousand pixels
  -- tall meant: controls laid out past the bottom of their own scroll child,
  -- where scrolling cannot reach them; a section inheriting two columns of
  -- indent from the gallery above it, which pushed two colour swatches off the
  -- right edge; and no way to see any of it, because the page that was wrong was
  -- also the page nobody could see the bottom of.
  --
  -- A page that holds one section is short enough to have neither problem, and
  -- the player gets a list instead of a scroll bar.
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

    -- A point of no size at the top left, so the first control of a section
    -- hangs off the page itself rather than off whatever the last page ended
    -- with. It is what makes indentFrom answer zero at the start of every page.
    local top = CreateFrame("Frame", nil, pageContent)
    -- Spelled out against the content rather than relying on the implicit
    -- parent: the chain of anchors is what measures a page, and a link that does
    -- not name what it hangs off cannot be walked.
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

  -- Shows a change in the preview WITHOUT persisting it, which is what makes a
  -- slider feel immediate without writing the repository per pixel.
  local function previewOverrides(overrides)
    view.preview:apply(appearanceFor(overrides), currentSettings()[SettingKey.MOTION_SCALE])
  end

  local function overridesWith(path, value)
    local overrides = plainCopy(currentSettings()[SettingKey.BAR_APPEARANCE])
    local node = overrides
    for index = 1, #path - 1 do
      node[path[index]] = node[path[index]] or {}
      node = node[path[index]]
    end
    node[path[#path]] = value
    return overrides
  end

  local function commitOverride(path, value)
    saveSetting(SettingKey.BAR_APPEARANCE, overridesWith(path, value))
    view.refresh()
  end

  -- Whether this axis is the PLAYER's rather than the skin's. Read off the
  -- override table and not off the resolved appearance, because the resolved
  -- one always has a value for every axis -- that is what resolving means -- and
  -- so cannot tell the two apart.
  local function hasOverride(path)
    return readPath(currentSettings()[SettingKey.BAR_APPEARANCE], path) ~= nil
  end

  -- The overrides with one axis taken out, and every other one untouched. Empty
  -- parents are pruned on the way back up: an override table still carrying
  -- `border = {}` reads as "the player touched the border" to hasOverride, so
  -- leaving one behind would keep the reset button on screen for a setting that
  -- is no longer overridden.
  local function overridesWithout(path)
    local overrides = plainCopy(currentSettings()[SettingKey.BAR_APPEARANCE])
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

  local function resetOverride(path)
    return function()
      saveSetting(SettingKey.BAR_APPEARANCE, overridesWithout(path))
      view.refresh()
    end
  end

  -- The size and motion axes are settings of their own rather than entries in
  -- the appearance table, so "back to default" is writing the default and
  -- "the player changed it" is differing from it. saveSetting hot-applies each
  -- of them through the bar (app/Bootstrap.lua), the same as any other write.
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

  -- The preview animates, so it needs a frame to drive it. One OnUpdate for the
  -- whole panel, and only while the panel is actually on screen.
  content:SetScript("OnUpdate", function(_, elapsed)
    view.preview:tick(elapsed)
  end)

  -- --- skin gallery --------------------------------------------------------

  -- FIRST, above the skins. Where the bar lives decides whether its position and
  -- its size are even the player's to set, so it belongs before the settings it
  -- governs rather than eleven controls below them.
  --
  -- Cycled rather than dropped down, like every other enumerated setting here.
  -- Declared in an order the player can follow -- free, then the two degrees of
  -- taking over -- rather than sorted, which would put inset before off.
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

  -- The label is its own line, because the control below shows the VALUE. A
  -- button that had to carry both ran off its own edge the moment the value was
  -- "in the client's bar, frame hidden".
  local slotLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  slotLabel:SetPoint("TOPLEFT", replay, "BOTTOMLEFT", 4, -12)
  slotLabel:SetText(locale:get(TextKey.OPT_BAR_SLOT))

  local function chooseSlot(slot)
    saveSetting(SettingKey.BAR_SLOT, slot)
    view.refresh()
  end

  -- A real dropdown when the client has one, and the cycling button when it does
  -- not. The panel's header explains why everything else here cycles: the five
  -- globals a dropdown needs could not be verified against the supported clients
  -- when that was written. They can be probed, though, which is what this does --
  -- and `/ascent debug` reports the answer, so the next client that is odd about
  -- it says so instead of being guessed at.
  --
  -- Three choices is the edge where the two are worth the same, and the slot is
  -- the one control here whose values are sentences rather than words: a dropdown
  -- shows them without the button having to be as wide as the longest one.
  if HAS_DROPDOWN then
    view.slotDropdown = CreateFrame("Frame", "AscentOptionsSlotDropdown", content, "UIDropDownMenuTemplate")
    -- The template draws its own left-hand padding outside the frame, so the
    -- control reads as aligned with the labels only when it is pulled back.
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

  -- Why the two sliders below are dead. Shown only while they are, so it never
  -- becomes a line the player learns to read past.
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
  -- The swatch that STARTS the last row, not the last swatch. Everything after
  -- the gallery hangs off this, and the difference is two columns of indent:
  -- anchored to the last swatch, every section below the skins -- the colours,
  -- the fields, the size, the behaviour -- started under whichever column the
  -- gallery happened to end in, and their own right-hand columns fell off the
  -- edge of the panel. Two colours could not be edited because of it.
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

    -- A real renderer painting a real sample: the swatch cannot look like
    -- something the bar would not.
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
    -- Every time a row starts, not only on the last swatch: the last swatch is in
    -- the third column and nested inside that test this never ran at all, so
    -- everything below the gallery anchored to the heading and was drawn over the
    -- swatches.
    if column == 0 then
      lastRowStart = holder
    end
  end

  local contrastCheck = createCheckbox(content, "HighContrast", TextKey.OPT_HIGH_CONTRAST,
    lastRowStart, locale, function(checked)
      saveSetting(SettingKey.HIGH_CONTRAST, checked)
      view.refresh()
    end,
    -- Clear of the swatch's NAME, which hangs below the swatch itself. Anchored
    -- to the swatch's bottom edge the checkbox landed on top of the label.
    { relativePoint = "BOTTOMLEFT", x = 0, y = -26 })

  -- --- colours -------------------------------------------------------------

  content = pageColors.content
  local colorHeading = heading(content, TextKey.OPT_SECTION_COLORS, pageColors.top, 4, locale)

  view.colorButtons = {}
  local lastColorRow = colorHeading
  for index, row in ipairs(COLOR_ROWS) do
    -- Named like the sliders and checkboxes: a swatch is the one control here
    -- whose behaviour cannot be read off the frame it lives on, so being able
    -- to name it -- from /framestack, or from the smoke harness -- is worth the
    -- global.
    local button = CreateFrame("Button", "AscentOptionsColor" .. row.key .. "Button", content)
    button:SetSize(20, 20)
    -- Two columns, not three. A page is narrower than the canvas this grid was
    -- laid out for, and the third column's label ran past its right edge -- which
    -- is how two colours ended up unreachable. Two columns of six fit with room
    -- for the longest label.
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
      -- The stored overrides as they were BEFORE the picker opened. Every
      -- handler below builds off this snapshot rather than re-reading the
      -- settings, because the whole point is that the settings do not move
      -- while the player is trying colours out.
      local stored = plainCopy(currentSettings()[SettingKey.BAR_COLORS])

      openColorPicker(appearanceFor().colors[row.key], {
        -- Preview: the demo bar and this swatch, and nothing else. No call
        -- reaches the repository, so a colour tried and abandoned leaves
        -- nothing behind to undo.
        preview = function(chosen)
          local trial = plainCopy(stored)
          trial[row.key] = chosen
          view.preview:apply(appearanceFor(nil, trial), currentSettings()[SettingKey.MOTION_SCALE])
          swatchTexture:SetColorTexture(chosen.r, chosen.g, chosen.b, 1)
        end,
        commit = function(chosen)
          stored[row.key] = chosen
          saveSetting(SettingKey.BAR_COLORS, stored)
          view.refresh()
        end,
        -- Nothing was written, so there is nothing to roll back: repainting
        -- from the settings is what puts the previewed colour away.
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
      commitOverride(cycle.path, cycle.values[nextIndex][1])
    end)
    view.cycles[index] = {
      button = button, cycle = cycle,
      reset = createAxisReset(content, "Cycle" .. index, button, locale, resetOverride(cycle.path)),
    }
    previous = button
  end

  view.sliders = {}
  for index, spec in ipairs(SLIDERS) do
    local slider = createSlider(content, "Axis" .. index, spec.labelKey, previous, locale, spec.bounds,
      function(value) previewOverrides(overridesWith(spec.path, value)) end,
      function(value) commitOverride(spec.path, value) end)
    view.sliders[index] = {
      slider = slider, spec = spec,
      reset = createAxisReset(content, "Axis" .. index, slider, locale, resetOverride(spec.path)),
    }
    previous = slider
  end

  pageSkin.last = previous

  -- --- what the bar says ---------------------------------------------------

  -- Two columns, because eleven checkboxes in one would be taller than the
  -- window and the order they read in would be lost in the scrolling. Column
  -- major: the fields keep their declared order down the left, then down the
  -- right, so the list still reads as an order rather than a grid.
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
      -- checkbox to its left: label widths differ, and anchoring to one would
      -- make the column's left edge follow the longest label above it.
      first and { relativePoint = "BOTTOMLEFT", x = column == 1 and 4 or 268, y = -8 }
        or { relativePoint = "BOTTOMLEFT", x = 0, y = -4 })
    view.fieldChecks[index] = { check = check, token = token }
    previousInColumn[column] = check
  end

  view.hoverCheck = createCheckbox(content, "TextOnHover", TextKey.OPT_TEXT_ON_HOVER,
    previousInColumn[1], locale, function(checked)
      saveSetting(SettingKey.BAR_TEXT_ON_HOVER, checked)
    end, { relativePoint = "BOTTOMLEFT", x = -4, y = -14 })

  -- Says what an empty selection means. A bar with no text is a legitimate
  -- choice, so this appears rather than argues.
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

  -- The same per-axis reset as the appearance axes above, for the four settings
  -- that live outside the appearance table.
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

  -- THE ONLY CHANNEL BACK, where a player actually looks for it.
  --
  -- No addon can make a network request, so everything the author will ever
  -- learn about a fault on someone else's machine is what that player pastes.
  -- `/ascent copy` does it, but somebody about to report something opens the
  -- options -- not a list of slash commands -- so the door is here too.
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
    -- A context that offers no report -- an older composition root, or a test --
    -- gets a button that says it cannot rather than one that does nothing.
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

  -- Each page is as tall as what it holds. Measured rather than guessed, which is
  -- the other half of why the old single canvas lost half of itself: its height
  -- was a constant somebody typed, and the panel outgrew it in silence.
  for _, page in ipairs(pages) do
    local last = page.last
    if last ~= nil then
      page.content:SetHeight(depthBelow(last, page.content) + (last:GetHeight() or 0) + 24)
    end
  end

  -- --- refresh -------------------------------------------------------------

  -- Every control is set from the live settings, not from what it was built
  -- with: the chat commands change the same values, and a panel showing a stale
  -- snapshot is worse than one that is merely plain.
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
      if hasOverride(entry.cycle.path) then entry.reset:Show() else entry.reset:Hide() end
    end

    for _, entry in ipairs(view.sliders) do
      entry.slider:SetValue(currentValue(entry.spec.path, entry.spec.bounds.min))
      if hasOverride(entry.spec.path) then entry.reset:Show() else entry.reset:Hide() end
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

    -- The slot, and what it costs. Suspended controls are DISABLED rather than
    -- hidden: a control that vanishes reads as a bug, and one that is greyed out
    -- with a sentence under it reads as a consequence (the spec's "suspended, and
    -- not broken").
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
      -- Emptied as well as hidden: a hidden font string keeps the height of the
      -- text it last held, and everything below it is anchored to this one.
      view.slotNote:SetText("")
      view.slotNote:Hide()
    end
    -- The other reason a slot does nothing, and the one the player cannot see
    -- from the bar: the client has no such bar to take over (D49).
    if BarSlotPolicy.active(slot) and clientBarPresent ~= nil and not clientBarPresent() then
      view.slotNote:SetText(locale:get(TextKey.OPT_SLOT_UNAVAILABLE))
      view.slotNote:Show()
    end
    if suspended.position then
      view.lockedCheck:Disable()
    else
      view.lockedCheck:Enable()
    end
    -- Where the text goes, suspended the same way and for a reason the player can
    -- see from the bar itself: in the client's slot there is no outside to put it
    -- on, only the client's interface. Found by its path rather than held in a
    -- field of its own, so adding or reordering a cycle cannot leave this
    -- pointing at the wrong button.
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
    refreshing = false
  end

  -- Reachable from outside, because the panel is not the only thing that writes
  -- these settings: a chat command, or the addon declining a slot the client
  -- cannot honour, changes them under an open panel. Without this the panel went
  -- on showing what it was built with until it was closed and reopened.
  -- Every page refreshes the whole view rather than only its own controls. They
  -- share one settings table and one preview, a page is only ever shown one at a
  -- time, and a refresh is cheap; a per-page refresh would be six functions that
  -- have to stay in step with which control lives where.
  for _, page in ipairs(pages) do
    page.frame.refresh = view.refresh
    page.frame:SetScript("OnShow", view.refresh)
  end
  view.refresh()

  -- The first is the parent category and the rest are its children, in order.
  return pages
end

ns.ui.OptionsPanel = OptionsPanel
