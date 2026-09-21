-- Ascent - a version, and whether one is newer than another.
--
-- Pure arithmetic over a string, which is what makes the whole update check
-- testable on a desktop: everything downstream -- the peer threshold, the
-- upgrade notice, the downgrade warning -- is this comparison plus bookkeeping.
--
-- THE CENTRAL RULE IS THAT A STRING WE CANNOT READ IS NEVER NEWER. The versions
-- being compared arrive from somebody else's client, as arbitrary text, and the
-- failure that matters is not "we missed an update": it is telling a player to go
-- and find a version that does not exist. Unparseable input loses, always.
--
-- This is also why the packaging keeps a clean semver in the TOC instead of the
-- standard packager's @project-version@ substitution, which yields things like
-- v0.1.0-5-gabc1234 on any commit that is not tagged (proposal.md). That string is
-- valid semver -- and is read as a PRE-RELEASE of 0.1.0, so a build five commits
-- after the tag orders before it. The failure would not be a refusal; it would be
-- telling someone ahead of the release that they are behind it.

local _, ns = ...
ns.core = ns.core or {}

local VersionNumber = {}

-- major.minor.patch, with an optional pre-release and optional build metadata.
-- A leading "v" is tolerated on the way in -- tags carry one, TOCs do not, and a
-- version that only differs by it is the same version.
--
-- Build metadata is parsed so it can be DISCARDED: semver orders two versions
-- that differ only in build metadata as equal, and the addon has no use for it.
function VersionNumber.parse(text)
  if type(text) ~= "string" then
    return nil
  end

  local body = text:match("^%s*[vV]?(.-)%s*$")
  local major, minor, patch, rest = body:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
  if major == nil then
    return nil
  end

  local pre
  if rest ~= "" then
    -- Strip build metadata first: it may follow a pre-release or stand alone.
    local withoutBuild = rest:match("^(.-)%+[%w%.%-]+$") or rest
    if withoutBuild ~= "" then
      pre = withoutBuild:match("^%-([%w%.%-]+)$")
      -- Something followed the patch number that is neither a pre-release nor
      -- build metadata. Not a version this addon knows how to order.
      if pre == nil then
        return nil
      end
    end
  end

  return {
    major = tonumber(major),
    minor = tonumber(minor),
    patch = tonumber(patch),
    pre = pre,
  }
end

-- One pre-release identifier against another, by semver's rule: all-digit
-- identifiers compare numerically and sort BEFORE alphanumeric ones.
local function compareIdentifier(a, b)
  local numericA, numericB = a:match("^%d+$"), b:match("^%d+$")

  if numericA and numericB then
    local left, right = tonumber(a), tonumber(b)
    if left == right then return 0 end
    return left < right and -1 or 1
  end
  if numericA then return -1 end
  if numericB then return 1 end

  if a == b then return 0 end
  return a < b and -1 or 1
end

local function split(text)
  local parts = {}
  for part in text:gmatch("[^%.]+") do
    parts[#parts + 1] = part
  end
  return parts
end

-- A version WITH a pre-release is older than the same version without one:
-- 0.2.0-beta1 comes before 0.2.0. Getting this backwards would tell everyone
-- running a release that a beta they already passed is an update.
local function comparePre(a, b)
  if a == nil and b == nil then return 0 end
  if a == nil then return 1 end
  if b == nil then return -1 end

  local left, right = split(a), split(b)
  for index = 1, math.max(#left, #right) do
    local one, other = left[index], right[index]
    -- A shorter set of identifiers is the smaller version when everything
    -- before it is equal: 1.0.0-beta precedes 1.0.0-beta.2.
    if one == nil then return -1 end
    if other == nil then return 1 end

    local result = compareIdentifier(one, other)
    if result ~= 0 then return result end
  end

  return 0
end

-- -1, 0 or 1, or nil when either side is not a version. nil is not an ordering
-- and callers have to treat it as one: see isNewer.
function VersionNumber.compare(a, b)
  local left, right = VersionNumber.parse(a), VersionNumber.parse(b)
  if left == nil or right == nil then
    return nil
  end

  for _, field in ipairs({ "major", "minor", "patch" }) do
    if left[field] ~= right[field] then
      return left[field] < right[field] and -1 or 1
    end
  end

  return comparePre(left.pre, right.pre)
end

-- The only question the rest of the addon asks. Anything that is not strictly a
-- later version -- equal, earlier, or unreadable -- answers false.
function VersionNumber.isNewer(candidate, current)
  return VersionNumber.compare(candidate, current) == 1
end

ns.core.VersionNumber = VersionNumber
