-- Ascent - the window a player copies a report out of.
--
-- This frame exists because of a hard limit rather than a preference: a WoW
-- addon cannot make a network request, so nothing about how the addon behaves
-- on someone else's machine can ever reach the author unless that player sends
-- it. Chat cannot be the channel -- its text is not selectable -- so the
-- diagnostics are rendered once more into an EditBox, selected on open, and the
-- player presses one chord.
--
-- THE TEXT IS EDITABLE ON PURPOSE. A report is going somewhere public, and the
-- player is the only one who can decide what should not go with it. Nothing in
-- here is worth protecting from them: the report carries no character name and
-- no realm -- what it carries is the addon's build, the client's flavour, and
-- counters -- and a player who wants to trim a line before pasting should be
-- able to.
--
-- It follows the bar's skin like every other surface (the plate's reasoning:
-- two windows of the same addon wearing different skins is a setting nobody
-- asked for), but resolves that skin on every open rather than subscribing to
-- settings changes: it is built on first use and lives a few seconds at a time.

local _, ns = ...
ns.ui = ns.ui or {}

local SettingKey = ns.core.SettingKey
local TextKey = ns.core.TextKey
local SkinResolver = ns.core.SkinResolver
local SkinCatalog = ns.core.SkinCatalog
local Palette = ns.core.Palette
local Effects = ns.ui.Effects

local WIDTH, HEIGHT = 560, 420
local PADDING = 14
-- Room for the scroll bar the template anchors to the frame's right edge.
local SCROLLBAR_ROOM = 28
local LINE_HEIGHT = 14

local CopyDialog = {}
CopyDialog.__index = CopyDialog

function CopyDialog.new(options)
  options = options or {}
  local self = setmetatable({
    locale = options.locale,
    settings = options.settings or {},
  }, CopyDialog)
  self:createFrame()
  return self
end

function CopyDialog:createFrame()
  -- Named because two different things need the name: the scroll bar the
  -- template builds as $parentScrollBar, and UISpecialFrames, which is how a
  -- frame gets closed by Escape without stealing the key from anything else.
  local frame = CreateFrame("Frame", "AscentCopyDialog", UIParent)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetPoint("CENTER")
  -- Above the client's own options frame, which is where the button that opens
  -- this one lives: at DIALOG the report would come up BEHIND the panel the
  -- player clicked it from.
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetToplevel(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  tinsert(UISpecialFrames, "AscentCopyDialog")

  self.frame = frame

  self.background = frame:CreateTexture(nil, "BACKGROUND")
  self.background:SetAllPoints(frame)

  self.border = Effects.plaqueBorder(frame, { size = 12, inset = 3 })

  self.title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  self.title:SetPoint("TOPLEFT", PADDING, -12)
  self.title:SetText(self.locale:get(TextKey.COPY_TITLE))

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 0, 0)
  close:SetScript("OnClick", function() self:hide() end)

  self.hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  self.hint:SetPoint("BOTTOMLEFT", PADDING, 12)
  self.hint:SetPoint("BOTTOMRIGHT", -PADDING, 12)
  self.hint:SetJustifyH("LEFT")
  self.hint:SetText(self.locale:get(TextKey.COPY_HINT))

  local scroll = CreateFrame("ScrollFrame", "AscentCopyScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", PADDING, -36)
  scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_ROOM, 34)
  self.scroll = scroll

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  -- No cap: the default is generous but finite, and a diagnostic silently
  -- missing its last page is the failure this whole window exists to prevent.
  edit:SetMaxLetters(0)
  edit:SetFontObject("ChatFontNormal")
  edit:SetWidth(WIDTH - PADDING - SCROLLBAR_ROOM - 4)
  edit:SetScript("OnEscapePressed", function() self:hide() end)
  scroll:SetScrollChild(edit)
  self.edit = edit

  -- The wheel, because a report is longer than the window and reaching for the
  -- scroll bar to read one is a small insult.
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta)
    scroll:SetVerticalScroll(math.max(0, scroll:GetVerticalScroll() - delta * LINE_HEIGHT * 3))
  end)

  frame:Hide()
  return self
end

-- The same skin the bar wears, floored the way the panel floors it: this is a
-- reading surface, and a nearly transparent skin meant for a 24-pixel strip
-- makes a page of diagnostics unreadable over the world.
function CopyDialog:applyAppearance()
  local appearance = SkinResolver.resolve({
    skin = SkinResolver.skinFor(SkinCatalog, self.settings[SettingKey.BAR_SKIN], ns.core.DEFAULT_SKIN_ID),
    overrides = self.settings[SettingKey.BAR_APPEARANCE],
    colors = self.settings[SettingKey.BAR_COLORS],
    palette = Palette,
    highContrast = self.settings[SettingKey.HIGH_CONTRAST],
  })

  local background = appearance.background
  self.background:SetColorTexture(background.r, background.g, background.b,
    math.max(background.a or 0, 0.92))

  self.border:setColor(appearance.accent)
  self.border:setThickness(math.max(1, appearance.border.thickness))
  self.border:show()

  local color = appearance.text.color
  self.title:SetTextColor(appearance.accent.r, appearance.accent.g, appearance.accent.b, 1)
  self.hint:SetTextColor(color.r, color.g, color.b, 0.7)
  return self
end

-- How tall the text is, which the scroll frame cannot work out for itself. The
-- count is of LOGICAL lines plus a quarter for the ones that wrap -- an estimate,
-- deliberately, because both ways of being wrong are harmless here: a little
-- empty space under the last line, or a scroll bar that stops a line early on a
-- report made entirely of long lines. The alternative is measuring wrapped text,
-- which is a lot of machinery for a window that shows counters.
local function textHeight(text)
  local lines = 1
  for _ in text:gmatch("\n") do
    lines = lines + 1
  end
  return math.ceil(lines * 1.25) * LINE_HEIGHT + LINE_HEIGHT
end

-- Shown with everything already selected: the player's next keystroke is the
-- copy, not a drag across four hundred lines they did not ask to aim at.
function CopyDialog:show(text)
  text = text or ""

  self:applyAppearance()
  self.edit:SetText(text)
  self.edit:SetHeight(math.max(self.scroll:GetHeight() or 0, textHeight(text)))
  self.scroll:SetVerticalScroll(0)

  self.frame:Show()
  self.edit:SetFocus()
  self.edit:HighlightText()
  return self
end

function CopyDialog:hide()
  self.edit:ClearFocus()
  self.frame:Hide()
  return self
end

function CopyDialog:isShown()
  return self.frame:IsShown()
end

ns.ui.CopyDialog = CopyDialog
