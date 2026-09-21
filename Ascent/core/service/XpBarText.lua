-- Ascent - the experience bar's configurable text.
--
-- The bar's text is not one string but a sequence of tokens the player chose, in
-- the order they chose them (task 10.3): the composition lives in settings, and
-- this module only knows how to turn one already-decided token into the number or
-- duration it names.
--
-- Every value coming in is nilable, and nil means something specific: the addon
-- does not know yet, or cannot know for this character. That is different from a
-- real zero -- "no experience of descanso left" is a fact, "no idea" is not -- so a
-- nil value gets the not-available marker and a zero gets printed as "0" like any
-- other number. Losing that distinction would be showing the player an invented
-- answer, which is the one thing this addon is built not to do.
--
-- Every piece of text -- the marker, the percent sign, the duration shapes and even
-- the space between tokens -- comes from the Locale port handed to format(). It is
-- an argument rather than something read from a global because core/ never reaches
-- the client, and it is required rather than optional because a literal kept "just
-- in case" would be a second source of truth for text that is already translated.

local _, ns = ...
ns.core = ns.core or {}

local TextToken = ns.core.TextToken
local TextKey = ns.core.TextKey

local XpBarText = {}

local function plain(value, locale)
  if value == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  return tostring(value)
end

local function rounded(value, locale)
  if value == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  return tostring(math.floor(value + 0.5))
end

local function percent(value, locale)
  if value == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  return locale:get(TextKey.PERCENT, math.floor(value * 100 + 0.5))
end

-- Hours only appear once there is a full hour to show; below that the token
-- doesn't bother with a "0h" nobody asked for. There is no minutes-and-seconds
-- shape here on purpose: the bar's tokens jump from minutes to hours, and the
-- table's DURATION_MS belongs to the panel, which does show both.
local function duration(seconds, locale)
  if seconds == nil then
    return locale:get(TextKey.NOT_AVAILABLE)
  end
  if seconds >= 3600 then
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds - hours * 3600) / 60)
    return locale:get(TextKey.DURATION_HM, hours, minutes)
  elseif seconds >= 60 then
    return locale:get(TextKey.DURATION_M, math.floor(seconds / 60))
  end
  return locale:get(TextKey.DURATION_S, math.floor(seconds))
end

local FORMATTERS = {
  [TextToken.LEVEL]         = function(values, locale) return plain(values.level, locale) end,
  [TextToken.XP_CURRENT]    = function(values, locale) return plain(values.xpCurrent, locale) end,
  [TextToken.XP_MAX]        = function(values, locale) return plain(values.xpMax, locale) end,
  [TextToken.XP_PERCENT]    = function(values, locale) return percent(values.xpPercent, locale) end,
  [TextToken.XP_REMAINING]  = function(values, locale) return plain(values.xpRemaining, locale) end,
  [TextToken.RESTED]        = function(values, locale) return plain(values.restedXp, locale) end,
  [TextToken.XP_PER_HOUR]   = function(values, locale) return rounded(values.xpPerHour, locale) end,
  [TextToken.TIME_TO_LEVEL] = function(values, locale) return duration(values.timeToLevel, locale) end,
  [TextToken.TIME_ON_LEVEL] = function(values, locale) return duration(values.timeOnLevel, locale) end,
  [TextToken.SESSION_TIME]  = function(values, locale) return duration(values.sessionTime, locale) end,
  [TextToken.QUEST_PENDING] = function(values, locale) return plain(values.questPending, locale) end,
}

-- `tokens` is the player's chosen fields, in the order they chose to show them;
-- `values` is everything the caller currently knows, with whatever it doesn't
-- left nil. Joined with the locale's own separator -- a single space in enUS,
-- and the whole of the layout: nothing here decides spacing, separators or icons
-- beyond that.
function XpBarText.format(tokens, values, locale)
  values = values or {}

  local parts = {}
  for index = 1, #tokens do
    parts[#parts + 1] = FORMATTERS[tokens[index]](values, locale)
  end
  return table.concat(parts, locale:get(TextKey.TOKEN_SEPARATOR))
end

ns.core.XpBarText = XpBarText
