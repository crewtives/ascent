-- Ascent - reading values that came back from disk.
--
-- The mirror image of Guard. Guard protects the models from a caller that got it
-- wrong and raises, loudly, because that is a bug worth finding. This protects them
-- from the saved variables file, and never raises, because that file is not a bug:
-- it is a text file the player can edit, that two different versions of the addon
-- write to, and that an interrupted logout can truncate halfway through.
--
-- The rule the whole boundary rests on: loading always wins over preserving. A field
-- that is missing, of the wrong type or plain nonsense falls back to its default and
-- the record loads. Refusing to load because one number went bad would cost the
-- player their whole history to protect one field of it.
--
-- Only the identity of a record is allowed to fail -- `restore` returns nil then --
-- and that decision belongs to the model, not here.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

local Stored = {}

function Stored.number(value, default)
  if type(value) ~= "number" or value ~= value then -- value ~= value catches NaN
    return default
  end
  return value
end

function Stored.count(value, default)
  if type(value) ~= "number" or value ~= value or value < 0 or value % 1 ~= 0 then
    return default
  end
  return value
end

-- Nil rather than a default, for fields where "absent" is a real answer: a creature
-- whose level nobody read is not a creature of level zero.
function Stored.positiveInteger(value)
  if type(value) ~= "number" or value ~= value or value < 1 or value % 1 ~= 0 then
    return nil
  end
  return value
end

function Stored.fraction(value, default)
  if type(value) ~= "number" or value ~= value or value < 0 or value > 1 then
    return default
  end
  return value
end

function Stored.text(value, default)
  if type(value) ~= "string" then
    return default
  end
  return value
end

-- Written out rather than with `and/or`: a stored `false` is a perfectly good value
-- and that idiom would quietly replace it with the default.
function Stored.flag(value, default)
  if type(value) ~= "boolean" then
    return default
  end
  return value
end

-- A constant that is no longer in the enumeration -- a source some future version
-- renamed -- falls back rather than poisoning a frozen table lookup.
function Stored.member(enum, value, default)
  for _, allowed in Frozen.each(enum) do
    if allowed == value then
      return value
    end
  end
  return default
end

function Stored.table(value)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

local PLAIN = { boolean = true, number = true, string = true }

-- A deep copy of data on its way OUT to disk, which raises on anything the saved
-- variables file cannot hold. This direction is allowed to raise: a function or a
-- metatable here is the addon's own bug, and the file would swallow it silently and
-- surface it as a half-missing record on the next login.
function Stored.plainCopy(value, path, seen)
  local kind = type(value)
  if PLAIN[kind] or kind == "nil" then
    return value
  end
  if kind ~= "table" then
    error(("%s is a %s; saved variables hold only tables, numbers, strings and booleans")
      :format(path, kind), 0)
  end
  if getmetatable(value) ~= nil then
    error(("%s has a metatable, which saved variables drop on the way out; "
      .. "give it a toStored() of its own"):format(path), 0)
  end

  seen = seen or {}
  if seen[value] then
    error(("%s is part of a cycle, which saved variables cannot hold"):format(path), 0)
  end
  seen[value] = true

  local copy = {}
  for key, item in pairs(value) do
    local keyKind = type(key)
    if keyKind ~= "string" and keyKind ~= "number" then
      error(("%s has a %s key; saved variables hold only string and number keys")
        :format(path, keyKind), 0)
    end
    copy[key] = Stored.plainCopy(item, ("%s.%s"):format(path, tostring(key)), seen)
  end

  seen[value] = nil
  return copy
end

-- The same walk on the way IN. This direction never raises: it drops whatever the
-- file should not have been able to hold in the first place and keeps the rest,
-- because refusing to load is the one outcome the boundary is not allowed to have.
function Stored.plainRead(value, seen)
  if PLAIN[type(value)] then
    return value
  end
  if type(value) ~= "table" or getmetatable(value) ~= nil then
    return nil
  end

  seen = seen or {}
  if seen[value] then
    return nil
  end
  seen[value] = true

  local copy = {}
  for key, item in pairs(value) do
    local keyKind = type(key)
    if keyKind == "string" or keyKind == "number" then
      local kept = Stored.plainRead(item, seen)
      if kept ~= nil then
        copy[key] = kept
      end
    end
  end

  seen[value] = nil
  return copy
end

ns.core.Stored = Stored
