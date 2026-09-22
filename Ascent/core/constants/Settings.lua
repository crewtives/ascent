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
local PlateZone = ns.core.PlateZone

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

  -- On: an addon this early is going to be corrected version by version, and a
  -- player running a stale one reports bugs that were fixed weeks ago. Turning it
  -- off silences BOTH halves -- the announcing and the warning (D74).
  [SettingKey.UPDATE_CHECK] = true,
  [SettingKey.LAST_SEEN_VERSION] = "",
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

  -- Unlocked, like the bar's own lock and for the same reason: an update must not
  -- hand anyone a surface they cannot move. Whoever locked the bar in order to
  -- lock both finds the plate loose after updating -- the cost is declared in the
  -- proposal, and the alternative was a schema version and a migration for one
  -- checkbox (D88).
  [SettingKey.PLATE_LOCKED] = false,

  [SettingKey.PLATE_SCALE] = 1.0,

  -- These four were file literals in ui/PullPlateView.lua until they became
  -- settings -- WIDTH = 240, HOLD_SECONDS = 6 -- and the row counts were
  -- PullViewModel's own TOP_CREATURES and TOP_ABILITIES. The defaults ARE those
  -- numbers, so the first session after updating draws the plate that was there
  -- before and nothing moves under anyone who never opens the page.
  [SettingKey.PLATE_WIDTH] = 240,
  -- A factor, not an alpha: 1 is "whatever the plate would have drawn anyway",
  -- which is the only default that changes nothing (D91).
  [SettingKey.PLATE_OPACITY] = 1,
  [SettingKey.PLATE_HOLD_SECONDS] = 6,
  [SettingKey.PLATE_ROWS] = 4,

  -- Every zone on, for the same reason: the plate an existing install draws after
  -- updating is the plate it drew before. A list and not a map of flags, so that
  -- a zone this build does not know is one entry to drop rather than a key to
  -- explain -- see SettingListChoices below.
  [SettingKey.PLATE_ZONES] = {
    PlateZone.CLOCK,
    PlateZone.REMAINING,
    PlateZone.STREAK,
    PlateZone.SOURCES,
    PlateZone.CREATURES,
    PlateZone.ABILITIES,
    PlateZone.FOOTER,
  },

  -- Empty, exactly like BAR_APPEARANCE and for exactly the same reason: an empty
  -- table is array-like to Frozen, so it declares no shape and is taken or
  -- rejected WHOLE rather than completed key by key. That is the point -- what is
  -- stored here means "only what the player changed", so their one tweak survives
  -- the bar switching skins underneath it (D87).
  [SettingKey.PLATE_APPEARANCE] = {},

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

  -- The plate's half. Wide on purpose -- see SettingPanelRange below for the half
  -- the player is actually offered. A hold of zero would be a plaque gone before
  -- it can be read AND a resume window shut before the client has paid the
  -- experience for the last kill of the pull, which in Classic arrives after it.
  [SettingKey.PLATE_WIDTH] = { min = 120, max = 800 },
  [SettingKey.PLATE_SCALE] = { min = 0.5, max = 3.0 },
  [SettingKey.PLATE_OPACITY] = { min = 0, max = 1 },
  [SettingKey.PLATE_HOLD_SECONDS] = { min = 1, max = 120 },
  -- The ceiling here is also how many rows the plate BUILDS: they are created
  -- once and shown or hidden, never built in combat, so this number is paid for
  -- at load whether or not anybody asks for it.
  [SettingKey.PLATE_ROWS] = { min = 1, max = 8 },
})

-- What the options panel offers for those same settings, which is deliberately
-- narrower than what the setting admits. The two say different things: the range
-- above is the last line before a hand-edited file reaches a frame, and this one
-- is what makes sense to drag.
--
-- The bar has had both halves for a while -- its width admits 60..1600 and its
-- slider offers 120..900 -- with the panel's half written as a literal in
-- ui/OptionsPanel.lua. The plate's is declared here instead because the
-- containment between the two is a claim worth a test, and core/ is the only
-- layer that has any (D93).
--
-- It matters most for how long the plate stays. That number also decides how long
-- a closed pull can be resumed (D89), so a hold of minutes would quietly make
-- every fight in a zone the same pull: the setting still admits it, the panel
-- does not offer it.
ns.core.SettingPanelRange = Frozen.enum("SettingPanelRange", {
  [SettingKey.PLATE_SCALE] = { min = 0.75, max = 2.0, step = 0.05 },
  [SettingKey.PLATE_WIDTH] = { min = 180, max = 480, step = 10 },
  -- Not down to zero: a plate at zero opacity is a surface that is still there,
  -- still catching the mouse, and impossible to find again. That belongs to the
  -- hand-edited file and its reset command, not to a slider.
  [SettingKey.PLATE_OPACITY] = { min = 0.2, max = 1, step = 0.05 },
  [SettingKey.PLATE_HOLD_SECONDS] = { min = 3, max = 20, step = 1 },
  [SettingKey.PLATE_ROWS] = { min = 1, max = 6, step = 1 },
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

-- Settings whose value is a LIST, every entry of which must belong to a closed
-- vocabulary. What separates these from SettingChoices above is what a bad value
-- costs: a scalar outside its vocabulary carries no intent and the whole value
-- falls back, but a list is several choices in one key, and throwing all of them
-- away because a hand-edited file carries one word this build does not know would
-- charge the player for six decisions they did make. The unknown entry is dropped
-- and the key reported, the same way a value of the wrong type is.
--
-- An empty list survives this untouched, and that is deliberate: every accessory
-- zone off is a player who wants the headline and nothing else (D90), not a
-- corrupt file.
ns.core.SettingListChoices = Frozen.enum("SettingListChoices", {
  [SettingKey.PLATE_ZONES] = {
    [PlateZone.CLOCK] = true,
    [PlateZone.REMAINING] = true,
    [PlateZone.STREAK] = true,
    [PlateZone.SOURCES] = true,
    [PlateZone.CREATURES] = true,
    [PlateZone.ABILITIES] = true,
    [PlateZone.FOOTER] = true,
  },
})

-- Everything the plate owns, and nothing the bar does. Two resets are driven by
-- this list -- the button on the plate's page and `/ascent options plate reset`
-- -- and they have to return the same keys, because the one a player reaches for
-- is whichever surface they can still use. The bar is absent on purpose: the
-- plate follows its skin, palette and contrast (D87), so a reset that reached
-- those would undo, from a page and a command that never mention the bar,
-- choices made for the other surface.
--
-- Written out rather than matched on the `plate_` prefix the persisted strings
-- happen to share: which keys belong to the plate is a decision, and the prefix
-- is what the spec uses as an independent oracle to catch this list drifting
-- behind the vocabulary.
ns.core.PlateSettingKeys = Frozen.enum("PlateSettingKeys", {
  SettingKey.PLATE_ENABLED,
  SettingKey.PLATE_POSITION,
  SettingKey.PLATE_LOCKED,
  SettingKey.PLATE_SCALE,
  SettingKey.PLATE_WIDTH,
  SettingKey.PLATE_OPACITY,
  SettingKey.PLATE_HOLD_SECONDS,
  SettingKey.PLATE_ROWS,
  SettingKey.PLATE_ZONES,
  SettingKey.PLATE_APPEARANCE,
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

-- Drop the entries of a list-valued setting that its vocabulary does not name.
-- Hands back the very value it was given when the setting has no list vocabulary,
-- so a caller can pass anything through it -- the same shape `clamped` has, where
-- only a number with a declared range is touched.
local function pruned(key, value)
  if type(value) ~= "table" or not Frozen.has(ns.core.SettingListChoices, key) then
    return value
  end
  local vocabulary = ns.core.SettingListChoices[key]
  local kept = {}
  for index = 1, #value do
    if Frozen.has(vocabulary, value[index]) then
      kept[#kept + 1] = value[index]
    end
  end
  return kept
end

-- Whether pruning actually lost something, which is what makes a key worth
-- reporting. Identity is asked first on purpose: `pruned` returns the value
-- itself when there is nothing to prune, and `#` on a stored string would
-- otherwise raise inside the very function that exists to describe junk data.
local function prunes(key, value)
  local kept = pruned(key, value)
  return kept ~= value and #kept ~= #value
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
      resolved[key] = clamped(key, pruned(key, override))
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
    if override ~= nil and (not usable(override, fallback) or not allowed(key, override)
      or prunes(key, override)) then
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
