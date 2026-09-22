-- Ascent - rows with columns, in a scroll frame that clips.
--
-- One FontString per tab cannot align numbers in a proportional font, cannot
-- scroll, and grows past its frame over the world. So rows are pooled frames:
-- a stripe, an optional proportion bar, an optional icon, one FontString per
-- column. The pool never shrinks, since a WoW frame cannot be destroyed.
--
-- The client's modern scroll-box system is not used: it needs globals that
-- are unverified on Burning Crusade Classic, while UIPanelScrollFrameTemplate
-- works the same on both clients. Swapping it would stay inside this file.

local _, ns = ...
ns.ui = ns.ui or {}

local TextStyle = ns.core.TextStyle

local ROW_HEIGHT = 18
local ICON_SIZE = 14
local CELL_GAP = 6

-- The icon column's width, reserved for the whole list, never per row: a row
-- whose icon the client could not resolve keeps its text where the others have
-- it and leaves the space empty, rather than reading as a different kind of row.
local ICON_COLUMN = ICON_SIZE + 4

-- What the panel paints a cell that does not name an experience source with,
-- when there is no skin resolved yet to say otherwise.
local DEFAULT_TEXT_COLOR = { r = 0.9, g = 0.9, b = 0.92 }

-- The same mapping as BarRenderer's applyText, HEAVY included, so a skin shows
-- the same font weight on the bar and in the panel.
local FONT_FLAGS = {
  [TextStyle.PLAIN] = "",
  [TextStyle.OUTLINE] = "OUTLINE",
  [TextStyle.HEAVY] = "THICKOUTLINE",
}

-- Icons ship with a border baked into the edges of the file; this is the crop
-- every addon uses to cut it off.
local ICON_INSET = 0.08

local RowList = {}
RowList.__index = RowList

-- `options`: parent, name, columns (a list of { width, justify }), rowHeight,
-- and `icons` -- true for a list whose rows can carry one, which reserves the
-- indent for every row in it.
--
-- A column with no width takes whatever is left, so a stretching name plus a
-- few right-aligned numbers needs no arithmetic at the call site.
--
-- The name is required. UIPanelScrollFrameTemplate declares its scroll bar as
-- `$parentScrollBar`, but its OnLoad reaches children through parentKey and
-- never calls GetName(), so the template itself tolerates an anonymous frame.
-- Whether the engine tolerates a `$parent`-named child frame under an anonymous
-- parent is unverified: the client's own anonymous template instances are all
-- regions. A name removes the question.
function RowList.new(options)
  options = options or {}
  if options.parent == nil then
    error("RowList needs a parent frame", 2)
  end
  if type(options.name) ~= "string" or options.name == "" then
    error("RowList needs a name: its scroll bar is created as $parentScrollBar", 2)
  end

  local scroll = CreateFrame("ScrollFrame", options.name, options.parent, "UIPanelScrollFrameTemplate")
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)

  return setmetatable({
    scroll = scroll,
    content = content,
    columns = options.columns or { {} },
    rowHeight = options.rowHeight or ROW_HEIGHT,
    indent = options.icons and ICON_COLUMN or 0,
    rows = {},
    appearance = nil,
    onSelect = options.onSelect,
  }, RowList)
end

function RowList:setPoints(...)
  self.scroll:ClearAllPoints()
  self.scroll:SetPoint(...)
  return self
end

function RowList:setSize(width, height)
  self.scroll:SetSize(width, height)
  self.content:SetWidth(width)
  return self
end

-- ---------------------------------------------------------------------------
-- The pool
-- ---------------------------------------------------------------------------

function RowList:buildRow(index)
  local row = CreateFrame("Button", nil, self.content)
  row:SetHeight(self.rowHeight)
  row:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -(index - 1) * self.rowHeight)
  row:SetPoint("RIGHT", self.content, "RIGHT", 0, 0)

  row.stripe = row:CreateTexture(nil, "BACKGROUND")
  row.stripe:SetAllPoints(row)
  row.stripe:Hide()

  -- The proportion bar sits behind the text, not beside it, so it costs no
  -- column.
  row.bar = row:CreateTexture(nil, "BORDER")
  row.bar:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.bar:SetHeight(self.rowHeight - 4)
  row.bar:Hide()

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(ICON_SIZE, ICON_SIZE)
  row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
  row.icon:SetTexCoord(ICON_INSET, 1 - ICON_INSET, ICON_INSET, 1 - ICON_INSET)
  row.icon:Hide()

  -- A HIGHLIGHT layer on a mouse-enabled button: the client shows and hides it
  -- on hover, so no OnEnter/OnLeave pair can fall out of step when the row is
  -- reused for other data.
  row:EnableMouse(true)
  row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
  row.highlight:SetAllPoints(row)
  row.highlight:SetColorTexture(1, 1, 1, 0.08)

  row.cells = {}
  self.rows[index] = row
  return row
end

function RowList:acquire(index)
  return self.rows[index] or self:buildRow(index)
end

-- One FontString per column, left to right. Fixed widths line numbers up down
-- the column; the one column without a width absorbs the remainder, so a long
-- creature name cannot push the figures out of alignment.
-- `cells` is the row's data, read for one case: a row holding a single cell is
-- a header or a note, and gets the whole width instead of the first column's.
function RowList:layoutCells(row, width, cells)
  local fixed, flexible = 0, 0
  for _, column in ipairs(self.columns) do
    if column.width then
      fixed = fixed + column.width
    else
      flexible = flexible + 1
    end
  end
  local indent = self.indent
  local spare = math.max(40, width - fixed - indent - CELL_GAP * (#self.columns + 1))
  local flexibleWidth = flexible > 0 and spare / flexible or 0

  -- A row holding a single cell is a heading or a note, not a record.
  local single = cells ~= nil and #cells == 1

  local left = CELL_GAP + indent
  for index, column in ipairs(self.columns) do
    local cell = row.cells[index]
    if cell == nil then
      cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      -- A row has a fixed height and nothing clips it, so a string longer than
      -- its column would wrap and draw over the row beneath; without wrapping it
      -- truncates instead. SetWordWrap is guarded: it is not assumed present on
      -- both clients.
      if cell.SetWordWrap then
        cell:SetWordWrap(false)
      end
      row.cells[index] = cell
    end
    local cellWidth = column.width or flexibleWidth
    if single then
      -- The whole width for the one cell in use and zero for the others: with
      -- their declared widths they would be anchored past the row's right edge,
      -- outside the panel, where a pooled row reused for a record would draw.
      cellWidth = index == 1 and math.max(cellWidth, width - indent - CELL_GAP * 2) or 0
    end
    cell:ClearAllPoints()
    cell:SetPoint("LEFT", row, "LEFT", left, 0)
    cell:SetWidth(cellWidth)
    cell:SetJustifyH(column.justify or "LEFT")
    if cellWidth > 0 then
      left = left + cellWidth + CELL_GAP
    end
  end
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

function RowList:applyAppearance(appearance)
  self.appearance = appearance
  return self
end

function RowList:styleCell(cell)
  local appearance = self.appearance
  if appearance == nil then
    return
  end
  -- GetFont for the path, never a literal: the default font differs by locale,
  -- and a Latin font draws no glyphs on a Korean client.
  local path = cell:GetFont()
  local flags = FONT_FLAGS[appearance.text.style] or "OUTLINE"
  if path ~= nil then
    cell:SetFont(path, math.max(9, appearance.text.size - 1), flags)
  end
end

-- `rows` is a list of:
--   cells      list of strings, one per column
--   bar        optional { fraction = 0..1, color = { r, g, b } }
--   icon       optional texture path or id
--   selected   optional; draws the row as the current selection
--   color      optional colour for the first cell, for a row that names a source
function RowList:setRows(rows)
  local width = self.scroll:GetWidth() or 0
  -- The skin's text colour, the one the bar paints with, so both surfaces agree.
  local textColor = self.appearance ~= nil and self.appearance.text.color or DEFAULT_TEXT_COLOR

  for index, data in ipairs(rows) do
    local row = self:acquire(index)
    self:layoutCells(row, width, data.cells)

    -- Alternating backgrounds, not a border per row, so the eye can follow a
    -- line across the columns.
    if index % 2 == 0 then
      row.stripe:SetColorTexture(1, 1, 1, 0.04)
      row.stripe:Show()
    else
      row.stripe:Hide()
    end

    if data.bar ~= nil and data.bar.fraction and data.bar.fraction > 0 then
      local color = data.bar.color or { r = 0.4, g = 0.4, b = 0.45 }
      row.bar:SetWidth(math.max(1, width * math.min(data.bar.fraction, 1)))
      row.bar:SetColorTexture(color.r, color.g, color.b, 0.35)
      row.bar:Show()
    else
      row.bar:Hide()
    end

    -- The indent makes room for the icon; a list without one would draw the
    -- icon under the first cell, so an icon is only drawn when there is an
    -- indent, whatever the caller passes.
    if data.icon ~= nil and self.indent > 0 then
      row.icon:SetTexture(data.icon)
      row.icon:Show()
    else
      row.icon:Hide()
    end

    if data.selected then
      row.stripe:SetColorTexture(1, 0.82, 0.3, 0.18)
      row.stripe:Show()
    end

    for column = 1, #self.columns do
      local cell = row.cells[column]
      self:styleCell(cell)
      cell:SetText(data.cells[column] or "")
      if column == 1 and data.color ~= nil then
        cell:SetTextColor(data.color.r, data.color.g, data.color.b)
      else
        -- Alpha included, as the bar and the panel title pass it, so a skin that
        -- dims its text dims it on every surface.
        cell:SetTextColor(textColor.r, textColor.g, textColor.b, textColor.a or 1)
      end
    end

    if self.onSelect ~= nil and data.level ~= nil then
      row:SetScript("OnClick", function() self.onSelect(data.level) end)
    else
      row:SetScript("OnClick", nil)
    end

    row:Show()
  end

  for index = #rows + 1, #self.rows do
    self.rows[index]:Hide()
  end

  self.content:SetHeight(math.max(1, #rows * self.rowHeight))
  return self
end

function RowList:clear()
  for _, row in ipairs(self.rows) do
    row:Hide()
  end
  self.content:SetHeight(1)
  return self
end

function RowList:show()
  self.scroll:Show()
  return self
end

function RowList:hide()
  self.scroll:Hide()
  return self
end

ns.ui.RowList = RowList
