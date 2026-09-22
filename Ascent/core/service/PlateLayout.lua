-- Ascent - where the pull plate's pieces sit, as arithmetic.
--
-- Kept in core/ so the layout is covered by unit tests; ui/ is exercised only
-- by the smoke run. The header offsets are distances from the top of the frame,
-- never from each other: a FontString is as tall as its text, so chaining them
-- lets a larger font draw the source bar through the headline. At the default
-- text size the offsets equal the previous fixed layout, so an unconfigured
-- plate draws as before. A zone that is off takes no space: the offsets below
-- it move up and the frame gets shorter, which is why `zones` reaches the
-- offsets and the height and not only the view's Show/Hide.

local _, ns = ...
ns.core = ns.core or {}

local PlateZone = ns.core.PlateZone

local PlateLayout = {}

-- The zones top to bottom, the order the plate reads in. Written out because
-- Frozen.keys sorts alphabetically; a test holds it to covering the vocabulary
-- exactly.
local ORDER = {
  PlateZone.CLOCK,
  PlateZone.REMAINING,
  PlateZone.STREAK,
  PlateZone.SOURCES,
  PlateZone.CREATURES,
  PlateZone.ABILITIES,
  PlateZone.FOOTER,
}

-- The default body text size, and the unit every other size is a multiple of:
-- the player's text size divided by this is the scale factor, so an
-- unconfigured plate scales by one.
local BASE_TEXT_SIZE = 10

-- The allowed text sizes. SkinResolver checks overrides by type, not by range
-- (see its `complete`), so this band is what keeps a hand-edited 200 from
-- drawing a plate taller than the screen. The bounds match the bar's text.
PlateLayout.TEXT_SIZE = { min = 8, max = 20, step = 1, default = BASE_TEXT_SIZE }

-- The plate's font sizes as multiples of the body size, so one setting scales
-- them in proportion. At the base size these are 10, 20, 18 and 9.
local FONT_RATIO = {
  title = 1,      -- the caption and the clock beside it
  headline = 2,   -- the experience figure
  kills = 1.8,    -- the count facing it
  streak = 0.9,   -- the chain, under the count
  body = 1,       -- every row, and the footer
}

local PADDING = 10

-- The caption sits two pixels above the padding: the font's ascent leaves a gap
-- of its own, and at the padding the caption reads as floating.
local TITLE_LIFT = 2

-- Space under each of the header's three text rows.
local GAP = 6

-- The source bar and the space under it. Its height does not scale with the
-- text: it is a band of colour, not a line to read.
local CHIP_HEIGHT = 5
local CHIP_GAP = 7

-- Distance from the hairline between header and body to the first body row;
-- larger than GAP so the rule reads as a separator.
local RULE_TO_BODY = 8

-- A body row's height beyond its text, and the space between the creature
-- block, the ability block and the footer.
local ROW_LEAD = 5
local BLOCK_GAP = 4

-- An ability icon is as tall as its row minus this, so it scales with the text.
local ICON_INSET = 3

local function round(value)
  return math.floor(value + 0.5)
end

local function textSizeOf(size)
  if type(size) ~= "number" then
    return BASE_TEXT_SIZE
  end
  if size < PlateLayout.TEXT_SIZE.min then
    return PlateLayout.TEXT_SIZE.min
  end
  if size > PlateLayout.TEXT_SIZE.max then
    return PlateLayout.TEXT_SIZE.max
  end
  return size
end

-- Which zones are drawn, in ORDER, and the same answer as a lookup.
--
-- The stored list is a set and may be in any order (the panel writes zones as
-- they are ticked), so the order returned is always ORDER's.
--
-- nil means every zone: the demo, a test, saved variables that never loaded.
-- An empty list is honoured as "headline only", a valid choice.
function PlateLayout.zones(chosen)
  local wanted
  if chosen ~= nil then
    wanted = {}
    for index = 1, #chosen do
      wanted[chosen[index]] = true
    end
  end

  local order, drawn = {}, {}
  for _, zone in ipairs(ORDER) do
    if wanted == nil or wanted[zone] then
      order[#order + 1] = zone
      drawn[zone] = true
    end
  end
  return order, drawn
end

-- Everything the plate needs to place itself, from one call so the height and
-- the offsets cannot be derived twice and disagree.
--
-- options.textSize   the plate's own text size, not the bar's (the plate ignores
--                    the bar's text.size, style and anchor). nil means the base.
-- options.zones      the stored list of zones. nil means all; see zones().
-- options.creatures  how many creature rows there are to draw, and
-- options.abilities  how many ability rows -- the counts the view-model already
--                    capped to what the player asked for, not the cap itself.
--                    A block with nothing in it takes no room at all.
function PlateLayout.lay(options)
  options = options or {}
  local order, draws = PlateLayout.zones(options.zones)
  local size = textSizeOf(options.textSize)

  local font = {}
  for name, ratio in pairs(FONT_RATIO) do
    font[name] = round(size * ratio)
  end

  local rowHeight = font.body + ROW_LEAD
  local header = {}

  header.title = PADDING - TITLE_LIFT
  header.xp = header.title + font.title + GAP

  -- The to-level line clears only the headline: it is in the left column, and
  -- the count and the chain are in the right one.
  header.remaining = header.xp + font.headline + GAP

  -- The source bar is full width, so it clears both columns: whichever ends
  -- lower (the right one, once the chain shows) decides where it starts.
  local leftEnd = header.remaining
  if draws[PlateZone.REMAINING] then
    leftEnd = leftEnd + font.body
  end
  local rightEnd = header.xp + font.kills
  if draws[PlateZone.STREAK] then
    rightEnd = rightEnd + 1 + font.streak
  end

  header.chips = math.max(leftEnd, rightEnd) + GAP
  header.rule = header.chips
  if draws[PlateZone.SOURCES] then
    header.rule = header.rule + CHIP_HEIGHT + CHIP_GAP
  end
  header.body = header.rule + RULE_TO_BODY

  -- Where each body block starts, so the view places rows without a cursor of
  -- its own that could disagree with the height computed below.
  local blocks = {}
  local cursor = header.body

  local creatures = draws[PlateZone.CREATURES] and (options.creatures or 0) or 0
  if creatures > 0 then
    blocks.creatures = cursor
    cursor = cursor + creatures * rowHeight + BLOCK_GAP
  end

  local abilities = draws[PlateZone.ABILITIES] and (options.abilities or 0) or 0
  if abilities > 0 then
    blocks.abilities = cursor
    cursor = cursor + abilities * rowHeight + BLOCK_GAP
  end

  if draws[PlateZone.FOOTER] then
    blocks.footer = cursor
    cursor = cursor + rowHeight
  end

  return {
    zones = order,
    draws = draws,
    font = font,
    padding = PADDING,
    rowHeight = rowHeight,
    chipHeight = CHIP_HEIGHT,
    iconSize = rowHeight - ICON_INSET,
    header = header,
    blocks = blocks,
    -- The body's bottom plus the padding. With every block empty this is the
    -- header plus the padding, the plate's minimum height.
    height = cursor + PADDING,
  }
end

ns.core.PlateLayout = PlateLayout
