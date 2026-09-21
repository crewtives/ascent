-- An approximation of the writer the client uses for saved variables, so that the
-- size of what the addon stores can be measured outside the game.
--
-- It matters that this is the CLIENT's shape and not a compact one of our own: the
-- cost the player pays at every logout is the file the client writes, and that
-- writer is verbose in ways a naive `#tostring` would miss. One key or array element
-- per line, tab indentation that deepens with nesting, `["name"] = value,` for map
-- keys, and a `-- [n]` comment after every array element.
--
-- It is an approximation, and deliberately a slightly pessimistic one -- numbers are
-- written here the way Lua prints them rather than with the client's exact float
-- formatting. A budget checked against a writer that is a little more expensive than
-- the real one errs in the safe direction.

local _, ns = ...
ns.support = ns.support or {}

local SavedVariables = {}

local function isSequenceKey(key, count)
  return type(key) == "number" and key >= 1 and key <= count and key % 1 == 0
end

function SavedVariables.serialize(value, depth)
  depth = depth or 1

  if type(value) ~= "table" then
    if type(value) == "string" then
      return ('"%s"'):format(value)
    end
    return tostring(value)
  end

  local pad = string.rep("\t", depth)
  local closePad = string.rep("\t", depth - 1)
  local lines = {}
  local count = #value

  for index = 1, count do
    lines[#lines + 1] = ("%s%s, -- [%d]")
      :format(pad, SavedVariables.serialize(value[index], depth + 1), index)
  end

  local keys = {}
  for key in pairs(value) do
    if not isSequenceKey(key, count) then
      keys[#keys + 1] = key
    end
  end
  -- Sorted so the measurement is the same on every run; the client's own order is
  -- whatever `pairs` gives it, which costs the same number of bytes either way.
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, key in ipairs(keys) do
    local name
    if type(key) == "number" then
      name = ("[%d]"):format(key)
    else
      name = ('["%s"]'):format(key)
    end
    lines[#lines + 1] = ("%s%s = %s,"):format(pad, name, SavedVariables.serialize(value[key], depth + 1))
  end

  if #lines == 0 then
    return "{\n" .. closePad .. "}"
  end
  return "{\n" .. table.concat(lines, "\n") .. "\n" .. closePad .. "}"
end

function SavedVariables.size(value)
  return #SavedVariables.serialize(value)
end

ns.support.SavedVariables = SavedVariables
