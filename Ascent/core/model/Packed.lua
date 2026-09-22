-- Ascent - writing down the things there are thousands of.
--
-- The client's saved variables writer spends about forty-five bytes on a line: a
-- tab per level of nesting, the key in brackets and quotes, the assignment, the
-- comma, and for an array element a `-- [n]` comment after it. That is a fine price
-- for a field, and far too much for a field of a record of a collection: written
-- that way an individual gain costs about 210 bytes, and a run from one to seventy
-- has tens of thousands of them, around four megabytes.
--
-- So the collections that are counted in thousands are written as text instead. One
-- record is one line:
--
--   44,mob_kill,1234.5,,,,5644,6            a kill worth 44, creature 5644 at level 6
--   250,quest_turnin,1300.2,,,,,,1234       a turn-in of quest 1234
--
-- and a whole collection is one string, records separated by semicolons. That is
-- about 31 bytes a gain rather than 210, it loses nothing, and it is what makes
-- keeping every level's full detail affordable.
--
-- Two rules:
--
--   * Trailing empty fields are dropped and leading ones are not, so the position of
--     a field is its identity and a record can gain a field in a future version
--     without every record written before it becoming unreadable.
--   * The separators are escaped inside values. Only names carry free text, a
--     creature called "Grunt, the Loyal" would otherwise corrupt its record, and
--     escaping costs nothing on the names that do not need it.

local _, ns = ...
ns.core = ns.core or {}

local Packed = {}

local FIELD = ","
local RECORD = ";"
local ESCAPE = "~"

local ESCAPED = { [ESCAPE] = ESCAPE .. "t", [FIELD] = ESCAPE .. "c", [RECORD] = ESCAPE .. "s" }
local UNESCAPED = { t = ESCAPE, c = FIELD, s = RECORD }

function Packed.escape(text)
  return (tostring(text):gsub("[~,;]", ESCAPED))
end

function Packed.unescape(text)
  return (text:gsub("~(.)", function(marker)
    -- An escape this version does not know is left as it was found rather than
    -- swallowed: stored data is never worth raising over, and never worth silently
    -- rewriting either.
    return UNESCAPED[marker] or (ESCAPE .. marker)
  end))
end

-- Join a record's fields. `nil` and `false` become empty; trailing empties are
-- dropped, which is where most of the saving is -- a gain carries ten fields and
-- usually fills three.
function Packed.join(fields)
  local last = 0
  for index = 1, #fields do
    if fields[index] ~= nil and fields[index] ~= false and fields[index] ~= "" then
      last = index
    end
  end

  local parts = {}
  for index = 1, last do
    local value = fields[index]
    if value == nil or value == false then
      parts[index] = ""
    elseif value == true then
      parts[index] = "1"
    elseif type(value) == "string" then
      parts[index] = Packed.escape(value)
    else
      parts[index] = tostring(value)
    end
  end

  return table.concat(parts, FIELD)
end

-- Split a record back into fields. An empty field comes back as `false`, so a reader
-- asks for field 7 and gets what field 7 was written as or nothing, never the value
-- of field 8 shifted into its place.
--
-- False rather than nil: a table with a hole in it has no defined length in 5.1,
-- so `join(split(text))` would drop everything after the first empty field and a
-- quest id in field nine would vanish on the way back from disk. Keeping the
-- sequence dense makes that round trip an identity.
function Packed.split(text)
  local fields = {}
  if type(text) ~= "string" then
    return fields
  end

  local index = 1
  local from = 1
  while true do
    local at = text:find(FIELD, from, true)
    local chunk
    if at == nil then
      chunk = text:sub(from)
    else
      chunk = text:sub(from, at - 1)
    end

    if chunk == "" then
      fields[index] = false
    else
      fields[index] = Packed.unescape(chunk)
    end
    index = index + 1

    if at == nil then
      break
    end
    from = at + 1
  end

  return fields
end

-- Write nothing when a field holds the value a reader would assume anyway. Spelled
-- out rather than with `and/or`, which collapses on exactly the values -- 0 and
-- false -- this is here to recognise.
function Packed.blankIf(value, default)
  if value == default then
    return false
  end
  return value
end

function Packed.number(fields, index)
  local value = fields[index]
  if type(value) ~= "string" then
    return nil
  end
  return tonumber(value)
end

function Packed.text(fields, index)
  local value = fields[index]
  if type(value) ~= "string" then
    return nil
  end
  return value
end

function Packed.flag(fields, index)
  return fields[index] == "1"
end

-- A sequence as one string, in the order it is in. Used where the order is the
-- data: the gains of a level are its time series.
function Packed.list(items, pack)
  local records = {}
  for index = 1, #items do
    records[index] = pack(items[index])
  end
  return table.concat(records, RECORD)
end

-- A keyed collection as one string, sorted. `pairs` walks a map in whatever order
-- the hash gives it, so without the sort the same unchanged record would write a
-- different file at every logout, and a file that cannot be diffed cannot be
-- migrated with confidence.
function Packed.set(items, pack)
  local records = {}
  for _, item in pairs(items) do
    records[#records + 1] = pack(item)
  end
  table.sort(records)
  return table.concat(records, RECORD)
end

-- Read a collection back. A record `unpack` cannot make sense of is skipped rather
-- than taking the rest of the level down with it.
function Packed.unlist(text, unpack)
  local items = {}
  if type(text) ~= "string" or text == "" then
    return items
  end

  local from = 1
  while true do
    local at = text:find(RECORD, from, true)
    local chunk
    if at == nil then
      chunk = text:sub(from)
    else
      chunk = text:sub(from, at - 1)
    end

    if chunk ~= "" then
      -- Both forms: a reader that wants a field asks for the fields, and one that
      -- restores a model of its own wants the record as it was written.
      local item = unpack(Packed.split(chunk), chunk)
      if item ~= nil then
        items[#items + 1] = item
      end
    end

    if at == nil then
      break
    end
    from = at + 1
  end

  return items
end

ns.core.Packed = Packed
