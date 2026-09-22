-- Ascent - frozen tables.
--
-- Every symbol in this addon (sources, topics, settings, colors) lives in a table
-- built here. The point is not tidiness: it is that a typo has to fail loudly.
--
--   XpSource.QEUST  -->  error "'QEUST' is not a key of XpSource"
--
-- A plain Lua table would have returned nil and the bug would have surfaced hours
-- later as a missing segment on a bar. This is the cheapest place to catch it.
--
-- Two shapes, because Lua 5.1 forces the distinction:
--   * map-like tables become strict proxies (unknown reads error, writes error).
--   * array-like tables are copied and left plain, because `ipairs` and `#` use raw
--     access in 5.1 and ignore `__index`, so proxying an array silently yields an
--     empty sequence. A proxy there would be worse than no protection at all.
--
-- One consequence worth knowing before you trip on it: the array you read back IS
-- the backing store, not a copy. Writing into it corrupts the frozen table for the
-- rest of the session, with no error. Copy it before mutating. Returning a fresh
-- copy on every read would be safer and would also allocate on every bar redraw,
-- which is the one thing the hot path budget does not allow.

local ADDON_NAME, ns = ...

-- The client loads files in TOC order with no module system, so each file makes
-- sure its layer table exists rather than depending on whoever loaded first.
ns.core = ns.core or {}

local Frozen = {}

-- proxy -> backing store. Weak keys: freezing something must not keep it alive.
local stores = setmetatable({}, { __mode = "k" })

-- Mutually recursive: a list can hold maps and a map can hold lists.
local freeze, copyArray, copyOrFreeze

-- An empty table counts as an empty list. Proxying it would turn `t[1]` into an
-- error for a caller that legitimately expects nil -- and a strict proxy over no
-- keys protects nothing anyway, since every read of it would error regardless.
local function isArrayLike(value)
  return next(value) == nil or #value > 0
end

local function hasMapKeys(value)
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count ~= #value
end

function copyOrFreeze(name, value)
  if type(value) ~= "table" then
    return value
  end
  if isArrayLike(value) then
    -- A table that is both a list and a map has no single correct reading, and
    -- guessing one silently is how half a constant goes missing. Say so instead.
    if hasMapKeys(value) then
      error(("%s: %s mixes array and map keys; that shape is not supported")
        :format(ADDON_NAME, name), 0)
    end
    return copyArray(name, value)
  end
  return freeze(name, value)
end

function copyArray(name, source)
  local copy = {}
  for index = 1, #source do
    copy[index] = copyOrFreeze(("%s[%d]"):format(name, index), source[index])
  end
  return copy
end

function freeze(name, values)
  local store = {}

  for key, value in pairs(values) do
    store[key] = copyOrFreeze(name .. "." .. tostring(key), value)
  end

  local proxy = setmetatable({}, {
    __index = function(_, key)
      local value = store[key]
      if value == nil then
        error(("%s: '%s' is not a key of %s"):format(ADDON_NAME, tostring(key), name), 2)
      end
      return value
    end,
    __newindex = function(_, key)
      error(("%s: %s is read-only (tried to set '%s')"):format(ADDON_NAME, name, tostring(key)), 2)
    end,
    __metatable = false,
  })

  stores[proxy] = store
  return proxy
end

-- Build a frozen symbol table. `name` is what shows up in the error message, so it
-- should be the name the reader will be looking for in the source.
--
-- Goes through copyOrFreeze rather than straight to freeze, and that is not a
-- detail: a LIST handed to this function used to come back as a proxy, and a
-- proxy is an empty table with an __index. So `#` returned zero, `next` returned
-- nil and `ipairs` walked nothing, while Frozen.keys happily listed 1..n -- the
-- data was there, behind an interface that raw access cannot see. Nested lists
-- were already handled correctly (see the header); only the top level was not,
-- which meant the bug only appeared for a constant declared as a list, and then
-- appeared as "this table is empty" rather than as an error.
function Frozen.enum(name, values)
  if type(name) ~= "string" or name == "" then
    error(ADDON_NAME .. ": a frozen table needs a name", 2)
  end
  if type(values) ~= "table" then
    error(("%s: %s needs a table of values"):format(ADDON_NAME, name), 2)
  end
  return copyOrFreeze(name, values)
end

local function storeOf(frozen)
  local store = stores[frozen]
  if not store then
    error(ADDON_NAME .. ": not a frozen table", 3)
  end
  return store
end

-- Existence check that does not blow up. Use this when a key legitimately may not
-- be there (an unhandled combat log subevent, a locale without a translation).
function Frozen.has(frozen, key)
  return storeOf(frozen)[key] ~= nil
end

-- Whether `value` is one of this module's frozen proxies. Worth having because a
-- proxy is indistinguishable from an empty table from the outside -- `next` and
-- `#` both see the empty carrier, not the store behind it -- so code that walks a
-- table of constants cannot tell a frozen MAP from a plain empty one by looking.
-- Arrays are copied plain rather than proxied (see the header), so this answers
-- "is this a frozen map", which is exactly the question a caller has.
function Frozen.isFrozen(value)
  return type(value) == "table" and stores[value] ~= nil
end

-- Sorted for determinism: tests and printed diagnostics must not depend on hash order.
function Frozen.keys(frozen)
  local store = storeOf(frozen)
  local keys = {}
  for key in pairs(store) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

-- Iterate a frozen table. `pairs` cannot work on a proxy in 5.1 (no __pairs), so
-- this is the supported way to walk one.
function Frozen.each(frozen)
  local store = storeOf(frozen)
  local keys = Frozen.keys(frozen)
  local index = 0
  return function()
    index = index + 1
    local key = keys[index]
    if key == nil then
      return nil
    end
    return key, store[key]
  end
end

-- A plain, writable deep copy of a value that may be frozen. The two shapes both
-- need one and for different reasons: a map comes back as a proxy, which `pairs`
-- cannot walk and which raises on a key it does not have, and an array comes back
-- as the backing store itself (see the header), so whoever keeps one has the
-- addon's own constants one write away from whatever they kept it in.
--
-- Saved variables are the case that makes this more than tidiness. A proxy is an
-- empty carrier with a metatable, so writing one to disk stores an EMPTY table:
-- a setting reset to its default would come back from the next session having
-- lost itself, in silence, with nothing to read.
--
-- Not Stored.plainCopy, which is the other direction: that one walks a RECORD on
-- its way to disk and raises on a metatable, because a proxy in a record is a bug
-- rather than a table to copy. This one exists to get rid of exactly that proxy.
function Frozen.plain(value)
  if Frozen.isFrozen(value) then
    local copy = {}
    for key, inner in Frozen.each(value) do
      copy[key] = Frozen.plain(inner)
    end
    return copy
  end
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, inner in pairs(value) do
    copy[key] = Frozen.plain(inner)
  end
  return copy
end

ns.core.Frozen = Frozen
