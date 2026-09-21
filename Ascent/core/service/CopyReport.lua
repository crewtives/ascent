-- Ascent - the report a player can actually hand over.
--
-- A WoW addon cannot make a network request, so there is no telemetry here and
-- there never will be: the only thing that can ever reach the author is what a
-- player decides to send. Chat is not that thing. Its text cannot be selected,
-- it is shared with every other addon's output, and it is gone once it scrolls
-- past -- so the same lines the diagnostics print are composed here into one
-- block and handed to an EditBox the player can select and copy.
--
-- Two decisions live in this file rather than in the dialog that shows it,
-- because both are about what the report SAYS and not about how it is drawn.
--
-- ESCAPES ARE STRIPPED. A line reading |cff20ff20Elwynn Forest|r is a colour in
-- the chat frame and is noise everywhere the player is going to paste it -- a
-- forum post, an issue, a text file. What they paste should be what they read.
--
-- THE REPORT IS BOUNDED, AND SAYS SO WHEN IT IS CUT. `debug strings` can dump
-- every experience template the client holds; an EditBox handed hundreds of
-- kilobytes is a stutter in exchange for a page nobody reads to the end. It is
-- cut at a stated size, at a line boundary, with a line saying it was cut: a
-- report that silently ends early is worse than a short one, because the reader
-- cannot tell the difference between "nothing more happened" and "the rest is
-- missing".

local _, ns = ...
ns.core = ns.core or {}

local CopyReport = {}

-- Room for the longest diagnostic this addon produces, and short of the size at
-- which an EditBox becomes the slowest thing on screen.
CopyReport.MAX_CHARACTERS = 15000

local CUT_NOTICE = "-- cut here: the report reached %d characters. Narrow it with /ascent copy summary."

-- Colour codes, texture escapes and hyperlinks: markup in the chat frame, litter
-- in a paste. The hyperlink keeps its visible text -- the name of a quest is the
-- part of the link worth reporting.
local function strip(value)
  local text = tostring(value == nil and "" or value)
  text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
  text = text:gsub("|r", "")
  text = text:gsub("|T.-|t", "")
  text = text:gsub("|A.-|a", "")
  text = text:gsub("|H.-|h(.-)|h", "%1")
  text = text:gsub("|n", "\n")
  return text
end

local function cutToLimit(text, limit)
  if #text <= limit then
    return text
  end

  local kept = text:sub(1, limit)
  -- Back up to the last line break: half a line reads as a corrupted report, and
  -- a reader cannot tell a truncated number from a wrong one.
  local lastBreak = kept:find("\n[^\n]*$")
  if lastBreak ~= nil and lastBreak > 1 then
    kept = kept:sub(1, lastBreak - 1)
  end
  return kept .. "\n" .. CUT_NOTICE:format(limit)
end

-- `header` is a list of { label, value } pairs -- a list and not a table, because
-- the order is read by a person: what the addon is, then what it is running on.
-- `lines` is the body, exactly as the diagnostics emitted it.
function CopyReport.build(options)
  options = options or {}

  local out = {}
  for _, entry in ipairs(options.header or {}) do
    out[#out + 1] = ("%s: %s"):format(strip(entry[1]), strip(entry[2]))
  end

  -- One blank line between what produced the report and the report itself, so a
  -- header with no body still ends cleanly rather than trailing a separator.
  local body = options.lines or {}
  if #out > 0 and #body > 0 then
    out[#out + 1] = ""
  end

  for _, line in ipairs(body) do
    out[#out + 1] = strip(line)
  end

  return cutToLimit(table.concat(out, "\n"), options.limit or CopyReport.MAX_CHARACTERS)
end

ns.core.CopyReport = CopyReport
