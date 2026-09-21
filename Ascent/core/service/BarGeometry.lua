-- Ascent - from fractions of a level to whole pixels (tasks 3.1, 3.2).
--
-- Two rules live here, and both exist because a bar made of several abutting
-- pieces fails in ways a single-fill bar never does.
--
-- ROUND THE BOUNDARIES, NEVER THE WIDTHS (design D26). Rounding each width on
-- its own lets the sum drift away from the total, and the drift shows up as a
-- one-pixel seam between two neighbours -- one that appears and disappears while
-- the bar animates, which reads as flicker rather than as a rounding error. So
-- the cumulative boundaries are rounded, and each width is the DIFFERENCE of two
-- of them. Two neighbours are then drawn from literally the same number, and the
-- seam cannot exist.
--
-- A SOURCE THAT PAID SOMETHING NEVER VANISHES SILENTLY (task 3.2). A channel
-- holding a third of a percent of the level is well under one pixel wide, and
-- dropping it would quietly contradict the breakdown, which still lists it. The
-- declared rule is: give it a single pixel, and take that pixel FROM THE WIDEST
-- channel. Not from thin air -- the total width is the level's percentage and
-- that is the addon's central invariant, verified by tests older than this file.
-- When no channel is wide enough to donate, nothing is forced: the bar is simply
-- too small to say it, and the tooltip still can.
--
-- Everything here is arithmetic on plain numbers. No client, no frames, no
-- floating-point comparisons left to chance.

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
-- that channel's RIGHT EDGE sits at. Monotonically non-decreasing, 0..1. That
-- shape -- boundaries rather than widths -- is the same one BarTween animates,
-- deliberately: the two modules speak about the bar the same way.
--
-- Returns `widths` (integers, in draw order) and `edges` (the integer boundaries
-- they were derived from), plus `starved`: how many channels had something to
-- show and still could not be given a pixel. The caller does not have to look at
-- `starved` -- nothing breaks if it does not -- but a diagnostic can say "this
-- bar is too narrow to show everything it knows" instead of leaving the player
-- to wonder.
function BarGeometry.lay(cumulative, width)
  local edges = {}
  for index = 1, #cumulative do
    local fraction = cumulative[index]
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    edges[index] = round(fraction * width)
    -- Monotonic by construction rather than by trust: a caller handing over a
    -- vector that dips would otherwise produce a negative width, and a negative
    -- width is an error the client raises at draw time, far from here.
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

  -- Rebuilt from the adjusted widths so the two views of the same layout cannot
  -- disagree: whoever draws from `edges` and whoever draws from `widths` must
  -- land on the same pixels.
  local running = 0
  for index = 1, #widths do
    running = running + widths[index]
    edges[index] = running
  end

  return { widths = widths, edges = edges, starved = starved }
end

-- Room a line of text needs above and below itself inside the bar before it stops
-- looking like text inside a bar and starts looking like text jammed into one.
-- Two pixels a side plus the descenders the font's own size does not account for.
local TEXT_HEADROOM = 6

-- Whether text of a given size can sit INSIDE a bar of a given height.
--
-- Pure, and here rather than in the view, because it is the whole of D52: the bar
-- that takes over the client's slot inherits a height much smaller than its own
-- default, and the text has to move out of the frame by itself instead of the
-- player discovering that it no longer fits. A rule the view could ask is a rule
-- a test can pin down; a branch inside the view is neither.
function BarGeometry.textFitsInside(height, textSize)
  if type(height) ~= "number" or type(textSize) ~= "number" then
    return false
  end
  return height >= textSize + TEXT_HEADROOM
end

-- Which side the text goes to when it cannot sit inside the bar.
--
-- Below, by default: that is where a bar's text conventionally goes and it reads
-- as belonging to the bar above it. But a bar that has taken over the client's
-- own slot sits at the bottom edge of the screen, and below there is behind the
-- action bar or off the screen entirely -- which is how the text came to be
-- invisible rather than merely misplaced. When there is no room below, it goes
-- above, where on that bar there always is.
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
