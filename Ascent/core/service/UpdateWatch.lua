-- Ascent - everything the addon knows about versions other than its own.
--
-- One question, "is there something newer, and is it true?", in three parts:
--
--   * the wire format of an announcement, both directions;
--   * who announced what, and whether enough distinct players said it;
--   * what changed since the last session this addon ran in.
--
-- Nothing here touches the client: it is handed facts (a sender, a message, a
-- remembered version) and returns verdicts; the adapter does the talking.
--
-- A message body comes from someone else's client, unsigned and arbitrary, so
-- one sender is never enough: a threshold of one would let anyone send a guild
-- looking for a version that does not exist.

local _, ns = ...
ns.core = ns.core or {}

local VersionNumber = ns.core.VersionNumber
local UpdateLimit = ns.core.UpdateLimit
local UPDATE_PEER_THRESHOLD = ns.core.UPDATE_PEER_THRESHOLD

-- "V" for version, "^" between fields if there is ever a second one: the shape
-- BigWigs uses.
local ANNOUNCE = "V:"

local UpdateWatch = {}
UpdateWatch.__index = UpdateWatch

-- What the addon says about itself, or nil when it should say nothing: an
-- unreadable version, or one so long the message would not fit the client's 255
-- characters. Truncating instead would announce a version that is not ours.
function UpdateWatch.encode(version)
  if VersionNumber.parse(version) == nil then
    return nil
  end

  local message = ANNOUNCE .. version
  if #message > UpdateLimit.MESSAGE then
    return nil
  end

  return message
end

-- The version inside an announcement, or nil for anything else on our prefix: a
-- future message kind, a truncated line, a forged one.
function UpdateWatch.decode(message)
  if type(message) ~= "string" then
    return nil
  end

  local version = message:match("^V:([^%^]+)")
  if version == nil or VersionNumber.parse(version) == nil then
    return nil
  end

  return version
end

function UpdateWatch.new(options)
  options = options or {}
  return setmetatable({
    version = options.version,
    threshold = options.threshold or UPDATE_PEER_THRESHOLD,
    enabled = options.enabled ~= false,
    -- version -> set of sender -> true. A set and not a counter: the same player
    -- repeating an announcement must not walk towards the threshold.
    reports = {},
    warned = false,
  }, UpdateWatch)
end

function UpdateWatch:enable(flag)
  self.enabled = flag and true or false
  return self
end

-- Whether to speak at all: switched off, or with an unreadable own version, the
-- addon has nothing to say and nothing to compare against.
function UpdateWatch:speaks()
  return self.enabled and VersionNumber.parse(self.version) ~= nil
end

-- One announcement from one player. Returns the version to warn about, exactly
-- once per session, or nil.
--
-- The player's own announcement comes back on the guild channel and needs no
-- special case: it is never newer than our own version.
function UpdateWatch:record(sender, message)
  if not self:speaks() or self.warned or type(sender) ~= "string" or sender == "" then
    return nil
  end

  local version = UpdateWatch.decode(message)
  if version == nil or not VersionNumber.isNewer(version, self.version) then
    return nil
  end

  local report = self.reports[version]
  if report == nil then
    -- The count lives beside the set rather than inside it: a character called
    -- "count" would otherwise be indistinguishable from the tally.
    report = { senders = {}, count = 0 }
    self.reports[version] = report
  end

  if report.senders[sender] then
    return nil
  end
  report.senders[sender] = true
  report.count = report.count + 1

  if report.count < self.threshold then
    return nil
  end

  -- Warn once per session.
  self.warned = true
  return version
end

-- What happened between the last session and this one. The caller says
-- something different for each of four answers:
--
--   "first"      nothing remembered. An install, not an update: say nothing.
--   "same"       the ordinary case.
--   "updated"    show what this version brings.
--   "downgraded" say what it did to the history: a record store written by a
--                newer build is archived on load.
function UpdateWatch.compareSeen(lastSeen, current)
  if VersionNumber.parse(current) == nil then
    return "same"
  end
  if lastSeen == nil or VersionNumber.parse(lastSeen) == nil then
    return "first"
  end

  local order = VersionNumber.compare(current, lastSeen)
  if order == 0 then
    return "same"
  end
  return order == 1 and "updated" or "downgraded"
end

ns.core.UpdateWatch = UpdateWatch
