-- Ascent - the window a player copies a report out of.
--
-- A WoW addon cannot make network requests, so a player sending this text is
-- the only way diagnostics leave their machine. Chat text is not selectable, so
-- the report goes into an EditBox, selected on open, copied with one chord.
--
-- The text is editable on purpose: the player decides what goes into a public
-- report. It carries the addon build, the client flavour and counters, never a
-- character name or realm.
--
-- It wears the bar's skin like every other surface, resolved on each open
-- rather than subscribed to: the frame is built on first use and lives briefly.

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
  -- Named for two reasons: the template builds its scroll bar as
  -- $parentScrollBar, and UISpecialFrames, which closes a frame on Escape
  -- without stealing the key, lists frames by name.
  local frame = CreateFrame("Frame", "AscentCopyDialog", UIParent)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetPoint("CENTER")
  -- Above the client's options frame, which holds the button that opens this:
  -- at DIALOG strata the report would open behind that panel.
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
  -- No cap: the default limit is finite and would silently cut the end of a
  -- long report.
  edit:SetMaxLetters(0)
  edit:SetFontObject("ChatFontNormal")
  edit:SetWidth(WIDTH - PADDING - SCROLLBAR_ROOM - 4)
  edit:SetScript("OnEscapePressed", function() self:hide() end)
  scroll:SetScrollChild(edit)
  self.edit = edit

  -- Mouse wheel scrolling, three lines per notch.
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta)
    scroll:SetVerticalScroll(math.max(0, scroll:GetVerticalScroll() - delta * LINE_HEIGHT * 3))
  end)

  frame:Hide()
  return self
end

-- The bar's skin with the background alpha floored, as the panel does: a
-- nearly transparent skin meant for a thin strip leaves a page of text
-- unreadable over the world.
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

-- How tall the text is, which the scroll frame cannot work out for itself: an
-- estimate of logical lines plus a quarter for wrapping. Being wrong costs a
-- little empty space, or a scroll bar that stops a line early when most lines
-- wrap; measuring wrapped text is not worth it here.
local function textHeight(text)
  local lines = 1
  for _ in text:gmatch("\n") do
    lines = lines + 1
  end
  return math.ceil(lines * 1.25) * LINE_HEIGHT + LINE_HEIGHT
end

-- Shown with everything selected, so the next keystroke is the copy.
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
