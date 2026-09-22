-- Ascent - the experience bar's configurable text.
--
-- The bar's text is a sequence of tokens the player chose, in their order; the
-- composition lives in settings, and this module turns one token into the number
-- or duration it names.
--
-- Every value is nilable, and nil means "not known yet, or not knowable for this
-- character", which is not a real zero ("no rested experience left" is a fact).
-- nil prints the not-available marker; zero prints "0".
--
-- All text, including the marker, the percent sign, the duration shapes and the
-- space between tokens, comes from the Locale port passed to format(): core/
-- never reaches the client, and a literal fallback would be a second source of
-- truth for translated text.

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

-- Hours appear only once there is a full hour, so no "0h". There is no
-- minutes-and-seconds shape: the bar's tokens jump from minutes to hours, and
-- DURATION_MS belongs to the panel.
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

-- `tokens` is the player's chosen fields, in their order; `values` is everything
-- the caller knows, the rest nil. Joined with the locale's separator (a single
-- space in enUS), the only layout this module decides.
function XpBarText.format(tokens, values, locale)
  values = values or {}

  local parts = {}
  for index = 1, #tokens do
    parts[#parts + 1] = FORMATTERS[tokens[index]](values, locale)
  end
  return table.concat(parts, locale:get(TextKey.TOKEN_SEPARATOR))
end

ns.core.XpBarText = XpBarText
