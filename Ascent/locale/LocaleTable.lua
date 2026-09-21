-- Ascent - the Locale port, backed by the tables in this directory.
--
-- Three branches, in the order core/port/Locale.lua fixes them: the client's
-- language has the text, so it wins; only the base has it, so the base is used;
-- nobody has it, and then the key itself shows *only* in diagnostic mode and the
-- bar's own "no data" marker shows otherwise. That last split is what keeps
-- "Idioma de la interfaz" honest -- a missing text is never a blank, and never an
-- internal identifier in front of a player who did not ask for one.
--
-- isDebug is a function, not a captured boolean, for the same reason the options
-- panel re-reads its state on every open: the player can toggle debug mid-session
-- and a value read once at boot would answer for the rest of it.
--
-- This lives in locale/ rather than adapter/outbound/ because GetLocale is the one
-- client global .luacheckrc grants to this directory -- the layering was drawn with
-- this file in mind.

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
    -- The key is the point in diagnostic mode: it is what the player pastes into a
    -- bug report so the gap can be found.
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
