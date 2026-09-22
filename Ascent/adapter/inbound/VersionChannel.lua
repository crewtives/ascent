-- Ascent - the only part of this addon that talks to other clients.
--
-- It says one thing, "this is the version I am", and listens for other people
-- saying it. Every decision -- whether a version is newer, whether enough
-- distinct players said so, whether there is allowance left to speak -- lives in
-- core/ and is tested on a desktop.
--
-- The client is assumed to offer nothing. Every call is checked for existence and
-- wrapped, so a client that answers differently costs the announcement rather
-- than the addon. What SendAddonMessage returns is unverified on a live client,
-- so nothing here depends on it, only on whether calling it raised.

local _, ns = ...
ns.adapter = ns.adapter or {}

local WowEvent = ns.core.WowEvent
local UpdateChannel = ns.core.UpdateChannel
local UPDATE_PREFIX = ns.core.UPDATE_PREFIX
local UpdateWatch = ns.core.UpdateWatch
-- Another player's message is a client read like any other, and its sender
-- becomes a table key in the watch's tally, an operation a closed value raises on.
local readable = ns.adapter.Readable.value

local VersionChannel = {}
VersionChannel.__index = VersionChannel

-- The client's own group predicates, read through a guard: Burning Crusade Classic
-- and Classic Era both have these, but a missing client function degrades only the
-- feature that wanted it.
local function isInGuild()
  return type(IsInGuild) == "function" and IsInGuild() and true or false
end

local function isInRaid()
  return type(IsInRaid) == "function" and IsInRaid() and true or false
end

local function isInGroup(category)
  if type(IsInGroup) ~= "function" then
    return false
  end
  if category ~= nil then
    return IsInGroup(category) and true or false
  end
  return IsInGroup() and true or false
end

-- Where an announcement can go right now: the guild, plus at most one group
-- channel. Sending to both RAID and INSTANCE_CHAT would reach the same people
-- twice and spend twice the allowance for it.
local function availableChannels()
  local channels = {}

  if isInGuild() then
    channels[#channels + 1] = UpdateChannel.GUILD
  end

  -- LE_PARTY_CATEGORY_INSTANCE is a client constant, not a function: absent, the
  -- instance case simply never matches and the ordinary group channels answer.
  if LE_PARTY_CATEGORY_INSTANCE ~= nil and isInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    channels[#channels + 1] = UpdateChannel.INSTANCE_CHAT
  elseif isInRaid() then
    channels[#channels + 1] = UpdateChannel.RAID
  elseif isInGroup() then
    channels[#channels + 1] = UpdateChannel.PARTY
  end

  return channels
end

function VersionChannel.new(options)
  options = options or {}
  return setmetatable({
    watch = options.watch,
    budget = options.budget,
    -- Called with the version to warn about, once, when the threshold is met.
    -- The wording belongs to whoever has the locale, not here.
    onNewer = options.onNewer or function() end,
    frame = nil,
  }, VersionChannel)
end

-- Whether this client can carry addon messages at all. Registered as a capability
-- probe by the composition root, so a client without it names what it turned off
-- instead of failing silently.
function VersionChannel.isSupported()
  return C_ChatInfo ~= nil
    and type(C_ChatInfo.SendAddonMessage) == "function"
    and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function"
end

-- One round: the same sentence to every channel available now. The budget is
-- asked once for the round, not per channel: an event produces a round, and a
-- half-announced one helps nobody.
function VersionChannel:announce()
  if self.frame == nil or not self.watch:speaks() then
    return 0
  end

  local message = UpdateWatch.encode(self.watch.version)
  if message == nil then
    return 0
  end

  local channels = availableChannels()
  if #channels == 0 then
    -- Nobody to tell. Not a failure, and not worth an allowance: a player
    -- levelling alone would otherwise burn the budget announcing to nobody.
    return 0
  end

  if not self.budget:allow() then
    return 0
  end

  local sent = 0
  for _, channel in ipairs(channels) do
    -- The return value is deliberately ignored (see the header): a throttle
    -- answer and a plain false mean the same thing here, which is "not this
    -- time". Retrying a throttle is how a rate problem becomes a disconnect.
    if pcall(C_ChatInfo.SendAddonMessage, UPDATE_PREFIX, message, channel) then
      sent = sent + 1
    end
  end

  return sent
end

function VersionChannel:onEvent(event, ...)
  if event == WowEvent.CHAT_MSG_ADDON then
    local prefix, message, _, sender = ...
    prefix, message, sender = readable(prefix), readable(message), readable(sender)
    if prefix ~= UPDATE_PREFIX then
      return
    end

    -- Never answered with a round of one's own: in a forty-player raid, replying
    -- turns one arrival into sixteen hundred messages.
    local newer = self.watch:record(sender, message)
    if newer ~= nil then
      self.onNewer(newer)
    end
    return
  end

  -- Entering the world and every change of group: the announcement follows who
  -- is around to hear it, and nothing else schedules one.
  self:announce()
end

function VersionChannel:start()
  if self.frame ~= nil or not VersionChannel.isSupported() then
    return self
  end

  -- Without this the client delivers nothing on our prefix, however much anyone
  -- sends. A failure here costs the channel, not the addon.
  if not pcall(C_ChatInfo.RegisterAddonMessagePrefix, UPDATE_PREFIX) then
    return self
  end

  local frame = CreateFrame("Frame")
  frame:RegisterEvent(WowEvent.CHAT_MSG_ADDON)
  frame:RegisterEvent(WowEvent.PLAYER_ENTERING_WORLD)
  frame:RegisterEvent(WowEvent.GROUP_ROSTER_UPDATE)
  frame:SetScript("OnEvent", function(_, event, ...)
    self:onEvent(event, ...)
  end)

  self.frame = frame
  return self
end

function VersionChannel:stop()
  if self.frame == nil then
    return self
  end
  self.frame:UnregisterAllEvents()
  self.frame = nil
  return self
end

ns.adapter.VersionChannel = VersionChannel
