-- Ascent - rows with columns, instead of one block of tabbed text (tasks 6.2,
-- 6.3, 6.4, 6.5).
--
-- The panel used to build each tab as a single string and hand it to one
-- FontString. That has three problems and only the first is cosmetic: numbers
-- cannot be aligned by padding them with spaces in a proportional font, a long
-- level has no way to scroll, and a FontString anchored only at the top grows
-- past the frame and draws over the world.
--
-- So: real rows, pooled and reused, inside a scroll frame that clips. A row is a
-- frame with a striping texture, an optional proportion bar, an optional icon
-- and one FontString per column. The pool never shrinks -- hiding a frame is
-- cheap, and a WoW frame cannot be destroyed anyway, so a pool that "frees" its
-- rows would be pretending.
--
-- ON THE SCROLL BACKEND. The client has a modern scroll-box system, and it is
-- better than this one. It is not used here for a specific reason: it needs five
-- globals that are not in the lint allowlist, and none of them can be verified
-- against BC Classic, which this addon supports for real (design D38). A scroll
-- frame from a template as old as the game costs one call, works identically on
-- both clients, and needs no fallback path to rot. If the modern one is ever
-- wanted, it is a change inside this file and nowhere else.

local _, ns = ...
ns.ui = ns.ui or {}

local TextStyle = ns.core.TextStyle

local ROW_HEIGHT = 18
local ICON_SIZE = 14
local CELL_GAP = 6

-- The width a list gives up to its icon column, reserved for the WHOLE list and
-- never per row. That is the whole subtlety of it: a row whose icon the client
-- could not resolve must NOT slide its text back to the left, or a missing icon
-- would read as a different kind of row -- which is exactly the "hueco" 6.5
-- asks the degraded path not to leave. So the indent is a property of the list,
-- decided once, and a row without an icon simply leaves the space empty.
local ICON_COLUMN = ICON_SIZE + 4

-- What the panel paints a cell that does not name an experience source with,
-- when there is no skin resolved yet to say otherwise.
local DEFAULT_TEXT_COLOR = { r = 0.9, g = 0.9, b = 0.92 }

-- The same mapping the bar uses (ui/BarRenderer.lua's applyText). Written as
-- data here because the branch that used to do it collapsed HEAVY into OUTLINE,
-- so a skin whose whole identity is a heavy face got one weight on the bar and
-- a lighter one in the panel, three pixels apart on screen.
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
-- A column with no width takes whatever is left, so the common shape -- a name
-- that stretches plus a couple of right-aligned numbers -- needs no arithmetic
-- at the call site.
--
-- THE NAME IS REQUIRED HERE, but not for the reason it first appeared to be, and
-- the distinction is worth keeping straight in a project that separates verified
-- from assumed. UIPanelScrollFrameTemplate does declare its scroll bar as
-- `$parentScrollBar` -- but its OnLoad reaches every child through parentKey and
-- never calls GetName(), so an anonymous instance is demonstrably safe on both
-- target clients. Whether the ENGINE tolerates a `$parent`-named child FRAME
-- under an anonymous parent is genuinely not verified: Blizzard's own anonymous
-- instantiations from templates are all regions, never child frames. So the name
-- stays -- it costs nothing and removes a question nobody can answer -- but it
-- was NOT what broke initialisation. That was Frozen.enum returning a proxy for
-- a list, which left this bar with zero channels to animate.
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

  -- The proportion bar sits behind the text rather than beside it, so a row
  -- reads as "this much of the level" at a glance without giving up a column.
  row.bar = row:CreateTexture(nil, "BORDER")
  row.bar:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.bar:SetHeight(self.rowHeight - 4)
  row.bar:Hide()

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(ICON_SIZE, ICON_SIZE)
  row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
  row.icon:SetTexCoord(ICON_INSET, 1 - ICON_INSET, ICON_INSET, 1 - ICON_INSET)
  row.icon:Hide()

  -- HIGHLIGHT layer plus a mouse-enabled button is all a hover needs: the client
  -- shows and hides that layer itself, so there is no OnEnter/OnLeave pair here
  -- to get out of step with the row being reused for different data.
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

-- One FontString per column, laid out left to right. Widths are fixed so that
-- numbers line up down the column; the one column without a width absorbs the
-- remainder, which is what keeps a long creature name from pushing the figures
-- out of alignment.
-- `cells` is the row's own data, and it is here for one case: a row holding a
-- single cell is a header or a note, not a record, so it gets the whole width
-- instead of the first column's share. Without it a sentence is squeezed into the
-- name column, wraps, and -- since a row is pinned at a fixed height with nothing
-- clipping it -- draws over the rows beneath.
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
      -- A cell is given a width and lives in a row pinned to a fixed height with
      -- nothing clipping it, so a string longer than its column WRAPS onto a
      -- second line and draws over the row beneath. Turning wrapping off turns
      -- that overlap into a truncation, which is a legible failure instead of an
      -- illegible one. Guarded because this is a client call and the two
      -- flavours are not assumed to agree (design D38).
      if cell.SetWordWrap then
        cell:SetWordWrap(false)
      end
      row.cells[index] = cell
    end
    local cellWidth = column.width or flexibleWidth
    if single then
      -- The whole width for the one cell that has something in it, and NONE for
      -- the columns it does not use. The second half is not tidiness: keeping
      -- their declared widths anchored them one after another past the right
      -- edge of the row -- empty, so nothing was drawn, but the row was laid out
      -- outside the panel, and a pooled row reused for a record would have been
      -- drawing there before its next layout.
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
  -- GetFont for the path, never a literal: the client's default font differs by
  -- locale, and naming a Latin one here is invisible text on a Korean client.
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
  -- The skin's own text colour, not an off-white constant. The bar paints its
  -- text with this; a panel that did not was the same skin in two colours.
  local textColor = self.appearance ~= nil and self.appearance.text.color or DEFAULT_TEXT_COLOR

  for index, data in ipairs(rows) do
    local row = self:acquire(index)
    self:layoutCells(row, width, data.cells)

    -- Striping, not a border per row: alternating backgrounds are what let the
    -- eye follow a line across three columns without losing it.
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

    -- The indent is what makes room for the icon, and a list that did not ask
    -- for one has none: drawing an icon there would put it straight back under
    -- the first cell, which is the defect the indent exists to remove. So the
    -- invariant is enforced here rather than left to the caller to remember.
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
        -- Alpha included, the way the bar and the panel's own title pass it: a
        -- skin that dims its text dims it on both surfaces or on neither.
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
