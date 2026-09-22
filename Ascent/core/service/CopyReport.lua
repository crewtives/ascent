-- Ascent - the report a player can actually hand over.
--
-- A WoW addon cannot make a network request, so the only thing that can reach
-- the author is what a player decides to send. Chat text cannot be selected, is
-- shared with every other addon's output and is gone once it scrolls past, so the
-- lines the diagnostics print are composed here into one block and handed to an
-- EditBox the player can select and copy. What the report says is decided here,
-- not in the dialog that shows it.
--
-- Escapes are stripped: |cff20ff20Elwynn Forest|r is a colour in the chat frame
-- and noise in a forum post, an issue or a text file.
--
-- The report is bounded and says so when it is cut. `debug strings` can dump
-- every experience template the client holds, and an EditBox handed hundreds of
-- kilobytes stutters. The cut falls at a stated size and a line boundary, with a
-- line saying so, because a report that silently ends early cannot be told apart
-- from one where nothing more happened.

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

-- The capability roster as the diagnostic prints it, to chat and into this
-- report alike, so the two cannot say different things. One line per capability,
-- with the reason for its state rather than yes or no: absent and unreadable are
-- the same "no" to the addon, but to whoever reads the report they are a client
-- without the feature and a client that took it away. `roster` is
-- Capabilities:all(), plain data by the time it gets here.
function CopyReport.capabilityLines(roster)
  local lines = {}
  for _, entry in ipairs(roster or {}) do
    lines[#lines + 1] = ("  capability %s: %s"):format(tostring(entry.name), tostring(entry.reason))
  end
  return lines
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
