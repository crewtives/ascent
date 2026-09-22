-- Ascent - the Locale port, backed by the tables in this directory.
--
-- Lookup order, as core/port/Locale.lua defines it: the client's language, then
-- the base language, then a fallback. The fallback is the key itself in
-- diagnostic mode and the "no data" marker otherwise, so a missing text is never
-- a blank and never an internal identifier shown to a player who did not ask.
--
-- isDebug is a function, not a captured boolean: the player can toggle debug
-- mid-session, and a value read once at boot would stay stale.
--
-- It lives in locale/ rather than adapter/outbound/ because GetLocale is the one
-- client global .luacheckrc grants to this directory.

local _, ns = ...
ns.locale = ns.locale or {}

-- Last resort only. The real marker comes from the base table; this covers the
-- single case that would otherwise recurse: the marker's own key missing.
local FALLBACK_MARKER = "n/a"

local LocaleTable = {}
LocaleTable.__index = LocaleTable

local function never()
  return false
end

local function clientLocale()
  if type(GetLocale) == "function" then
    return GetLocale()
  end
  return nil
end

-- options.tables  map of locale name -> table of TextKey value -> string
-- options.base    name of the base language; its table must be complete
-- options.locale  the client's language; defaults to the running client's
-- options.isDebug function returning whether diagnostic mode is on right now
function LocaleTable.new(options)
  options = options or {}

  local tables = options.tables or ns.locale.tables or {}
  local baseName = options.base or "enUS"
  local base = tables[baseName]

  if type(base) ~= "table" then
    error(("Ascent: LocaleTable has no base table for '%s'"):format(tostring(baseName)), 2)
  end

  local name = options.locale or clientLocale()

  local instance = setmetatable({
    base = base,
    current = name and tables[name] or nil,
    missing = base[ns.core.TextKey.NOT_AVAILABLE] or FALLBACK_MARKER,
    isDebug = options.isDebug or never,
  }, LocaleTable)

  return ns.core.Port.verify(ns.core.Locale, instance, "LocaleTable")
end

function LocaleTable:get(key, ...)
  local text = self.current and self.current[key] or self.base[key]

  if text == nil then
    -- In diagnostic mode the key is shown so the player can paste it into a bug
    -- report and the gap can be found.
    text = self.isDebug() and tostring(key) or self.missing
  end

  if select("#", ...) > 0 then
    return text:format(...)
  end

  return text
end

function LocaleTable:has(key)
  return self.current ~= nil and self.current[key] ~= nil
end

ns.locale.LocaleTable = LocaleTable
