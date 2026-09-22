-- Ascent - frozen tables.
--
-- Every symbol in this addon (sources, topics, settings, colors) lives in a table
-- built here, so that a typo fails loudly:
--
--   XpSource.QEUST  -->  error "'QEUST' is not a key of XpSource"
--
-- A plain Lua table would return nil and the bug would surface later as, say, a
-- missing segment on a bar.
--
-- Two shapes, because Lua 5.1 forces the distinction:
--   * map-like tables become strict proxies (unknown reads error, writes error).
--   * array-like tables are copied and left plain, because `ipairs` and `#` use raw
--     access in 5.1 and ignore `__index`, so proxying an array silently yields an
--     empty sequence.
--
-- Consequence: the array read back is the backing store, not a copy. Writing into
-- it corrupts the frozen table for the rest of the session, with no error, so copy
-- it before mutating. A fresh copy on every read would allocate on every bar
-- redraw, which the hot path cannot afford.

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
-- error for a caller that legitimately expects nil, and a strict proxy over no
-- keys protects nothing.
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
    -- guessing one would silently drop half of it.
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
-- Goes through copyOrFreeze rather than straight to freeze, so a top-level list
-- comes back as a plain list: a proxy is an empty table with an __index, and `#`,
-- `next` and `ipairs` would see it as empty.
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

-- Whether `value` is one of this module's frozen proxies. From the outside a proxy
-- is indistinguishable from an empty table -- `next` and `#` both see the empty
-- carrier, not the store behind it. Arrays are copied plain rather than proxied
-- (see the header), so this answers "is this a frozen map".
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

-- A plain, writable deep copy of a value that may be frozen. Both shapes need one:
-- a map comes back as a proxy, which `pairs` cannot walk and which raises on a
-- missing key, and an array comes back as the backing store itself (see the
-- header), one write away from corrupting the addon's own constants.
--
-- Saved variables depend on it: a proxy is an empty carrier with a metatable, so
-- writing one to disk stores an empty table, and a setting reset to its default
-- would silently come back empty in the next session.
--
-- Not Stored.plainCopy, which walks a record on its way to disk and raises on a
-- metatable, because a proxy in a record is a bug. This one removes that proxy.
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
