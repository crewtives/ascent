-- Ascent - where the pull plate's pieces sit, as arithmetic (tasks 2.1, 2.2, 2.3).
--
-- WHY THIS IS IN core/ AT ALL (D93). All of it used to be file literals in
-- ui/PullPlateView.lua, and ui/ has no unit test: the only thing that exercises
-- that layer is ./dev.sh smoke against a client whose __index auto-stubs any
-- method it is asked for. A SetPoint can only be checked there. "With the clock
-- off and the text at 14, the source bar starts below the to-level line" is
-- arithmetic, and arithmetic is checked with busted.
--
-- THE SIX HEADER OFFSETS ARE WHY THIS FILE EXISTS. They are distances from the
-- TOP OF THE FRAME and never from each other, which is the correction of a real
-- defect (add-ascent-pull-recap 5.2): a FontString is as tall as the text in it,
-- so hanging the "to level" line off the headline let the source bar be drawn
-- THROUGH the number as soon as the number grew. Six literals were a correct
-- answer for exactly as long as the font sizes were literals too -- the moment
-- the player picks the text size they stop being one, and the defect comes back.
-- So they are derived here, with a test at the smallest and the largest text.
--
-- AT THE DEFAULT TEXT SIZE IT RETURNS THE NUMBERS THE VIEW CARRIED, to the pixel.
-- That is not nostalgia: an install that updates and never opens the new page has
-- to draw the plate it drew yesterday. There is a test pinning all six.
--
-- A ZONE THAT IS OFF COSTS NOTHING, which is the difference between hiding and
-- turning off (D90): every offset below it moves up and the frame gets shorter.
-- That is why `zones` reaches the offsets and the height rather than only the
-- view's Show/Hide calls.

local _, ns = ...
ns.core = ns.core or {}

local PlateZone = ns.core.PlateZone

local PlateLayout = {}

-- The zones top to bottom, which is also the order the plate reads in: what you
-- got, against what, what is left, where it came from. Written out rather than
-- taken from the vocabulary because Frozen.keys sorts alphabetically, and
-- alphabetical is not a layout -- the ordering is a decision (D90), so it is
-- stated once, here, and a test holds it to covering the vocabulary exactly.
local ORDER = {
  PlateZone.CLOCK,
  PlateZone.REMAINING,
  PlateZone.STREAK,
  PlateZone.SOURCES,
  PlateZone.CREATURES,
  PlateZone.ABILITIES,
  PlateZone.FOOTER,
}

-- The size the plate's body text has always been drawn at, and therefore the one
-- every other size on it is a multiple of. The player's own text size divided by
-- this is the factor everything scales by, so a plate left alone scales by one
-- and lands on the literals it landed on before.
local BASE_TEXT_SIZE = 10

-- What a text size may be. Published because the plate's own appearance map is
-- the only door to it and SkinResolver checks overrides by TYPE, not by range
-- (see its `complete`): without a band here, a hand-edited 200 would be a plate
-- taller than the screen with no way back except the reset command. The bounds
-- mirror what the panel already offers for the bar's text.
PlateLayout.TEXT_SIZE = { min = 8, max = 20, step = 1, default = BASE_TEXT_SIZE }

-- The nine font sizes the plate draws with, as multiples of the body size -- one
-- setting scaling them in proportion rather than nine controls (D94). At the base
-- these are the view's own 10, 20, 18 and 9.
local FONT_RATIO = {
  title = 1,      -- the caption and the clock beside it
  headline = 2,   -- the experience figure
  kills = 1.8,    -- the count facing it
  streak = 0.9,   -- the chain, under the count
  body = 1,       -- every row, and the footer
}

local PADDING = 10

-- The caption sits two pixels above the padding: it is a small line of text in a
-- font whose ascent leaves a gap of its own, and at the padding it reads as
-- floating rather than as a header.
local TITLE_LIFT = 2

-- Air under a line of text before whatever comes next. One number for the three
-- text rows of the header, because they are the same kind of gap.
local GAP = 6

-- The source bar, and the air under it. Its own height does not follow the text:
-- it is a band of colour, not a line to read, and a band that grew with the font
-- would take room from what the font is there to say.
local CHIP_HEIGHT = 5
local CHIP_GAP = 7

-- The hairline between header and body, and the distance from it to the first
-- body row. Eight rather than six: the rule is what stops the eye, and a rule
-- crowded against the row under it stops nothing.
local RULE_TO_BODY = 8

-- What a body row costs beyond its text, and the air between the creature block,
-- the ability block and the footer.
local ROW_LEAD = 5
local BLOCK_GAP = 4

-- An ability icon is as tall as its row minus a hair, so it grows with the text
-- instead of becoming a stamp beside a line twice its height.
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

-- Which zones are drawn, in the canonical order, and the same answer as a lookup.
--
-- The order returned is ORDER's and never the stored one: the list on disk is a
-- set of choices and a saved file may hold them in any order at all -- the panel
-- writes them as they are ticked, and a hand-edited file writes them however it
-- likes. Whoever lays the plate out decides the order (D90).
--
-- nil means every zone, which is what a caller with no settings gets -- the
-- demo, a test, a session whose saved variables never loaded. An EMPTY list is a
-- different answer and is honoured as one: a player who turned every accessory
-- zone off wants the headline and nothing else, and that is a choice rather than
-- a corrupt file.
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

-- Everything the plate needs to place itself, from one call so that the height
-- and the offsets cannot be derived twice and disagree.
--
-- options.textSize   the plate's OWN text size. Not the one it inherits from the
--                    bar: the plate has never read that (it ignores text.size,
--                    style and anchor), and starting to would move every plate
--                    that exists. nil means the base size.
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

  -- The to-level line clears the HEADLINE and nothing else, because it is in the
  -- left column and the count and the chain are in the right one. Making it clear
  -- all three is what would push it down a row it does not need.
  header.remaining = header.xp + font.headline + GAP

  -- The source bar is the full width of the plate, so it is the first thing that
  -- has to clear BOTH columns -- and the right one is the taller of the two as
  -- soon as the chain is showing. This is the defect of 5.2 in its general form:
  -- whichever column ends lower decides where the next full-width thing starts.
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

  -- Where each block of the body starts, so that the view places rows instead of
  -- keeping a running cursor of its own -- one that would be free to disagree
  -- with the height computed right below it.
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
    -- The body's own bottom plus the padding under it. With every block empty
    -- this is the header plus the padding, which is the smallest the plate can
    -- be -- the floor the view used to carry as MIN_HEIGHT falls out of the
    -- arithmetic rather than being asserted on top of it.
    height = cursor + PADDING,
  }
end

ns.core.PlateLayout = PlateLayout
