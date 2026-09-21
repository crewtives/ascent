-- Ascent - the changelog as one block of text.
--
-- The entries themselves are generated from CHANGELOG.md at build time
-- (tools/changelog.lua), already rendered to plain lines: a player's client has
-- no business parsing markdown. What is left is putting them in order and
-- deciding what happens when there is nothing to show -- which is the case worth
-- having a function for, because "no changelog" must read as a sentence and not
-- as an empty window.

local _, ns = ...
ns.core = ns.core or {}

local ChangelogText = {}

-- The version being played goes first even when the embedded list is ordered
-- newest-first and it is not the newest -- someone running an older build, or a
-- development one, is reading this to find out about the build in their hands.
local function ordered(entries, currentVersion)
  local head, rest = {}, {}
  for _, entry in ipairs(entries) do
    if entry.version == currentVersion then
      head[#head + 1] = entry
    else
      rest[#rest + 1] = entry
    end
  end

  for _, entry in ipairs(rest) do
    head[#head + 1] = entry
  end
  return head
end

-- One string, or nil when the build carries no changelog at all. nil rather than
-- an empty string: the caller has a sentence for that case and cannot tell the
-- difference between "nothing to say" and "a blank window" otherwise.
function ChangelogText.build(entries, currentVersion)
  if type(entries) ~= "table" or #entries == 0 then
    return nil
  end

  local out = {}
  for _, entry in ipairs(ordered(entries, currentVersion)) do
    if #out > 0 then
      out[#out + 1] = ""
    end

    local heading = entry.version
    if entry.date ~= nil and entry.date ~= "" then
      heading = heading .. "  -  " .. entry.date
    end
    out[#out + 1] = heading
    out[#out + 1] = ("="):rep(#heading)

    for _, line in ipairs(entry.lines or {}) do
      out[#out + 1] = line
    end
  end

  return table.concat(out, "\n")
end

ns.core.ChangelogText = ChangelogText
