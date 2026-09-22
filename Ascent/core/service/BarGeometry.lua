-- Ascent - from fractions of a level to whole pixels.
--
-- The cumulative boundaries are rounded and each width is the difference of two
-- of them, so neighbours share an edge. Rounding each width on its own lets the
-- sum drift from the total, which shows as a one-pixel seam that flickers while
-- the bar animates.
--
-- A source that paid something never vanishes: a channel under one pixel wide
-- gets a single pixel taken from the widest channel rather than added, because
-- the total width is the level's percentage. When no channel is wide enough to
-- donate, nothing is forced; the breakdown still lists the source.
--
-- Pure arithmetic on plain numbers: no client, no frames.

local _, ns = ...
ns.core = ns.core or {}

local BarGeometry = {}

-- The narrowest a channel is allowed to be once it has anything at all to show.
local MIN_VISIBLE = 1

-- A channel must keep at least this much after donating, so that taking a pixel
-- from the widest never creates a second starved channel.
local MIN_DONOR = 2

local function round(value)
  return math.floor(value + 0.5)
end

local function widthsFrom(edges)
  local widths = {}
  local previous = 0
  for index = 1, #edges do
    widths[index] = edges[index] - previous
    previous = edges[index]
  end
  return widths
end

-- The index of the widest channel able to give a pixel away, or nil.
local function donorFor(widths, needy)
  local best
  for index = 1, #widths do
    if index ~= needy and widths[index] >= MIN_DONOR then
      if best == nil or widths[index] > widths[best] then
        best = index
      end
    end
  end
  return best
end

-- `cumulative` is one entry per channel, in draw order: the fraction of the bar
-- at which that channel's right edge sits, non-decreasing, 0..1. BarTween
-- animates the same shape, boundaries rather than widths.
--
-- Returns `widths` (integers, in draw order), `edges` (the integer boundaries
-- they were derived from) and `starved`: how many channels had something to show
-- and still got no pixel. Reading `starved` is optional; it lets a diagnostic say
-- the bar is too narrow to show everything it knows.
function BarGeometry.lay(cumulative, width)
  local edges = {}
  for index = 1, #cumulative do
    local fraction = cumulative[index]
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    edges[index] = round(fraction * width)
    -- Forced monotonic: a vector that dips would otherwise produce a negative
    -- width, which the client raises as an error at draw time, far from here.
    if index > 1 and edges[index] < edges[index - 1] then
      edges[index] = edges[index - 1]
    end
  end

  local widths = widthsFrom(edges)

  local starved = 0
  local previousFraction = 0
  for index = 1, #cumulative do
    local share = cumulative[index] - previousFraction
    previousFraction = cumulative[index]
    if share > 0 and widths[index] < MIN_VISIBLE then
      local donor = donorFor(widths, index)
      if donor == nil then
        starved = starved + 1
      else
        widths[donor] = widths[donor] - MIN_VISIBLE
        widths[index] = widths[index] + MIN_VISIBLE
      end
    end
  end

  -- Rebuilt from the adjusted widths so drawing from `edges` and drawing from
  -- `widths` land on the same pixels.
  local running = 0
  for index = 1, #widths do
    running = running + widths[index]
    edges[index] = running
  end

  return { widths = widths, edges = edges, starved = starved }
end

-- Room a line of text needs above and below itself inside the bar: two pixels a
-- side plus the descenders the font's own size does not account for.
local TEXT_HEADROOM = 6

-- Whether text of a given size can sit inside a bar of a given height. The bar in
-- the client's slot inherits a height much smaller than its own default, and the
-- text has to move out of the frame on its own; the rule is pure and lives here
-- so the view asks it and a test can pin it down.
function BarGeometry.textFitsInside(height, textSize)
  if type(height) ~= "number" or type(textSize) ~= "number" then
    return false
  end
  return height >= textSize + TEXT_HEADROOM
end

-- Which side the text goes to when it cannot sit inside the bar. Below by
-- default, where it reads as belonging to the bar. A bar in the client's own slot
-- sits at the bottom edge of the screen, where below is behind the action bar or
-- off screen, so with no room below the text goes above, where that bar always
-- has room.
function BarGeometry.textAnchorOutside(roomBelow, textSize)
  local TextAnchor = ns.core.TextAnchor
  if type(roomBelow) ~= "number" or type(textSize) ~= "number" then
    return TextAnchor.BELOW
  end
  if roomBelow >= textSize + TEXT_HEADROOM then
    return TextAnchor.BELOW
  end
  return TextAnchor.ABOVE
end

ns.core.BarGeometry = BarGeometry
