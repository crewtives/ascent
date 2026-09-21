-- Ascent - settings contract.
--
-- Every tunable value has exactly one home: DEFAULTS. Services never read a
-- global config object and never carry their own fallbacks -- they are handed a
-- resolved settings table at construction. That is what makes them testable with
-- a different threshold without touching saved variables or the client.
--
--   local settings = Settings.resolve(savedOptions)   -- at the composition root
--   local collector = TimeCollector.new(settings)     -- everywhere else
--
-- The resolved table is frozen too, so a typo on read fails where it happens.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen
local SettingKey = ns.core.SettingKey
local TextToken = ns.core.TextToken
local BarSlot = ns.core.BarSlot

ns.core.Defaults = Frozen.enum("Defaults", {
  -- Fraction of health and primary resource above which the player counts as
  -- recovered, which is what ends the recovery clock after a fight.
  [SettingKey.RECOVERY_THRESHOLD] = 0.95,

  -- Individual gains kept per level. Aggregates are always kept in full; this only
  -- bounds the fine-grained detail, and with it the saved variables file.
  --
  -- Set high enough that a real level never reaches it. The sequence of a level's
  -- gains is its time series and the addon exists to show it, so the limit is here
  -- to bound growth in the worst case rather than to throw data away routinely. It
  -- is affordable because of how a gain is written, not because there are few of
  -- them: packed into a line of its own a gain costs about 31 bytes on disk, so even
  -- a level that somehow reached this limit would store about 62 KB.
  [SettingKey.RETENTION_LIMIT] = 2000,

  [SettingKey.BAR_TEXT_TOKENS] = {
    TextToken.LEVEL,
    TextToken.XP_CURRENT,
    TextToken.XP_MAX,
    TextToken.XP_PERCENT,
    TextToken.RESTED,
  },

  [SettingKey.COLLECT_DAMAGE] = true,
  [SettingKey.SHOW_QUEST_PENDING] = true,
  [SettingKey.BAR_LOCKED] = false,
  [SettingKey.BAR_SCALE] = 1.0,
  -- Spelled out rather than left empty. A default of `{}` declares no shape, so
  -- a saved position that lost a key -- an older build, a hand-edited file --
  -- reached the views as a frozen table missing it, and reading that key raised
  -- instead of returning nil. The default IS the shape: see resolve below.
  [SettingKey.BAR_POSITION] = { point = "CENTER", x = 0, y = 200 },
  [SettingKey.PANEL_POSITION] = { point = "CENTER", x = 0, y = -20, width = 420, height = 360 },
  [SettingKey.HIDE_WITHOUT_XP] = false,

  -- 400x24 rather than the 200x20 the view used to hard-code. At two hundred
  -- pixels, four segments, a one-pixel separator between each and a line of
  -- text on top have nowhere to be: every one of them is competing for the same
  -- handful of pixels. This is a default, not a limit -- see RANGES below.
  [SettingKey.BAR_WIDTH] = 400,
  [SettingKey.BAR_HEIGHT] = 24,

  [SettingKey.BAR_SKIN] = "tabard",

  -- OFF: the addon's own bar, free on the screen, client's bar untouched. An
  -- update must not move a bar somebody already placed, so taking over the
  -- client's slot is something the player turns on, never something they find on.
  [SettingKey.BAR_SLOT] = BarSlot.OFF,

  -- Off: the bar says what it says, all the time. On, it is quiet until the
  -- cursor is on it -- which is what a player who wants the bar to be a bar and
  -- not a readout asks for, and it costs nothing to offer.
  [SettingKey.BAR_TEXT_ON_HOVER] = false,

  -- Deliberately an EMPTY list, not a map. A map-valued default would declare a
  -- shape, and completing this one against a shape is exactly the wrong thing:
  -- its whole meaning is "only the fields the player actually changed", so that
  -- those survive switching skins. Readers go through SkinResolver, which reads
  -- possibly-frozen, possibly-partial tables safely.
  [SettingKey.BAR_APPEARANCE] = {},

  -- Same shape and same reason as BAR_APPEARANCE: only what the player actually
  -- chose, so a colour survives switching skins and an untouched source keeps
  -- following the palette.
  [SettingKey.BAR_COLORS] = {},

  [SettingKey.HIGH_CONTRAST] = false,
  [SettingKey.MOTION_SCALE] = 1,

  -- On: a pull that happens is a pull the player sees. The plate answers a
  -- question nothing else in the addon answers -- how did THAT fight go -- and a
  -- feature nobody finds is a feature nobody has.
  [SettingKey.PLATE_ENABLED] = true,
  -- Spelled out for the same reason BAR_POSITION is: the default IS the shape,
  -- and a saved table that lost a key must not reach a frozen read that raises.
  -- relativePoint is part of the shape, not an optional extra: the client can
  -- leave a dragged frame hung BY one point TO a different one, and a stored
  -- position missing the second half reaches a frozen read that raises.
  [SettingKey.PLATE_POSITION] = { point = "CENTER", relativePoint = "CENTER", x = 0, y = -120 },

  [SettingKey.EVIDENCE] = false,
  [SettingKey.TIME_SYNC] = true,
  [SettingKey.DEBUG] = false,
})

-- The floor and ceiling for the settings where a stored number could otherwise
-- make the interface unusable. This is not input validation for the options
-- panel -- that can guard itself -- it is the last line before a hand-edited
-- saved variables file reaches a frame: a width of zero is a bar that exists,
-- occupies nothing, and cannot be grabbed to fix itself.
ns.core.SettingRange = Frozen.enum("SettingRange", {
  [SettingKey.BAR_WIDTH] = { min = 60, max = 1600 },
  [SettingKey.BAR_HEIGHT] = { min = 6, max = 120 },
  [SettingKey.BAR_SCALE] = { min = 0.5, max = 2.0 },
  [SettingKey.MOTION_SCALE] = { min = 0, max = 1 },
  [SettingKey.RECOVERY_THRESHOLD] = { min = 0, max = 1 },
})

-- Settings whose value is a closed vocabulary rather than a number or a flag.
-- Type is not enough for these: "banana" is a perfectly good string and would
-- sail through `usable` into a view that then asks what to do with it. Unlike a
-- number out of range, a word outside the vocabulary carries no intent worth
-- honouring, so it falls back to the default rather than being pulled to an edge.
--
-- Not every enumerated setting belongs here. BAR_SKIN deliberately does not: an
-- unknown skin id falls back at the reader (SkinResolver.skinFor), which is what
-- lets a skin removed in an update leave the player's choice on disk for when it
-- comes back. A slot the client cannot honour is a different thing -- see D49.
ns.core.SettingChoices = Frozen.enum("SettingChoices", {
  [SettingKey.BAR_SLOT] = { [BarSlot.OFF] = true, [BarSlot.INSET] = true, [BarSlot.REPLACE] = true },
})

local Settings = {}

-- A number outside its declared range is pulled back to the edge rather than
-- thrown away for its default. The distinction matters: someone who typed 2000
-- for a width wanted a very wide bar, and the widest allowed is a better answer
-- than the default one.
local function clamped(key, value)
  if type(value) ~= "number" or not Frozen.has(ns.core.SettingRange, key) then
    return value
  end
  local range = ns.core.SettingRange[key]
  if value < range.min then return range.min end
  if value > range.max then return range.max end
  return value
end

-- Whether a stored value belongs to the vocabulary its setting declares. A key
-- with no declared vocabulary allows anything its type allows.
local function allowed(key, value)
  if not Frozen.has(ns.core.SettingChoices, key) then
    return true
  end
  return Frozen.has(ns.core.SettingChoices[key], value)
end

-- Saved variables are a text file the player can edit and a place older and newer
-- builds both write to, so resolving has one rule: never fail because of what is
-- stored. A value of the wrong type falls back to the default rather than reaching
-- a service that was promised a number -- silently, but reportably (see below).
local function usable(override, fallback)
  return override ~= nil and type(override) == type(fallback)
end

-- A setting whose default is a map declares a SHAPE, and a stored value for it is
-- never taken or rejected whole -- it is completed key by key. Anything absent or
-- of the wrong type falls back to that key's default, and anything this version
-- does not know is dropped. Two things depend on this: the resolved table is
-- frozen right after, where a missing key is an error rather than a nil, and a
-- caller reading `position.point` must not have to defend itself against a file
-- someone edited by hand.
local function completeShape(override, shape)
  local resolved = {}
  -- Frozen.each, not pairs: Defaults is itself frozen, so a map-valued default
  -- arrives here as a proxy whose keys `pairs` cannot see (Frozen.lua's header).
  for key, fallback in Frozen.each(shape) do
    if usable(override[key], fallback) then
      resolved[key] = override[key]
    else
      resolved[key] = fallback
    end
  end
  return resolved
end

-- Only a frozen MAP declares a shape. A list-valued default (the bar's text
-- tokens) is copied plain by Frozen rather than proxied, so it is taken or
-- rejected whole, the way it always was.
local function definesShape(fallback)
  return Frozen.isFrozen(fallback)
end

-- Resolve stored options against the defaults. Anything absent, unknown or of the
-- wrong type falls back.
function Settings.resolve(overrides)
  overrides = overrides or {}

  local resolved = {}
  for key, fallback in Frozen.each(ns.core.Defaults) do
    local override = overrides[key]
    -- Written out rather than with `and/or`: that idiom collapses when the stored
    -- value is `false`, which is a perfectly good setting.
    if definesShape(fallback) then
      resolved[key] = completeShape(type(override) == "table" and override or {}, fallback)
    elseif usable(override, fallback) and allowed(key, override) then
      resolved[key] = clamped(key, override)
    else
      resolved[key] = fallback
    end
  end

  return Frozen.enum("Settings", resolved)
end

-- Which stored values this version had to ignore because their type was wrong.
-- Same shape as unknownKeys: the caller decides whether to tell the player.
function Settings.invalidKeys(overrides)
  local invalid = {}
  for key, fallback in Frozen.each(ns.core.Defaults) do
    local override = (overrides or {})[key]
    if override ~= nil and (not usable(override, fallback) or not allowed(key, override)) then
      invalid[#invalid + 1] = key
    end
  end
  table.sort(invalid)
  return invalid
end

-- Which stored keys this version does not understand. The caller decides whether
-- that is worth telling the player about; resolving never fails because of them.
function Settings.unknownKeys(overrides)
  local unknown = {}
  for key in pairs(overrides or {}) do
    if not Frozen.has(ns.core.Defaults, key) then
      unknown[#unknown + 1] = key
    end
  end
  -- Stored keys can be of any type, and table.sort without a comparator throws
  -- when they are mixed -- in the very function that exists to report junk data.
  table.sort(unknown, function(a, b) return tostring(a) < tostring(b) end)
  return unknown
end

ns.core.Settings = Settings
