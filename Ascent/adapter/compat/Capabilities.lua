-- Ascent - capability probes.
--
-- The three supported clients share most of their API, not all of it: a function
-- a collector wants might not exist on the running flavor, or might exist and
-- never return anything useful. A probe answers once, at registration time,
-- whether the addon can rely on it, so a missing capability degrades the one
-- collector that needed it instead of producing a nil call inside a fight. The
-- addon still loads, and the player can see what got turned off.
--
-- Each capability also records why it is off. A client that lacks the function
-- and one that has it but answers with values this addon may not read are
-- different reports: the second is a client that took the feature away. This
-- registry is the single place that knows either, instead of a flavour check in
-- every collector.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Capabilities = {}
Capabilities.__index = Capabilities

-- The three states a capability can be in, and the vocabulary a probe answers
-- with. They are strings rather than a boolean plus a flag because they are read
-- by people: this is what `/ascent copy` prints next to each name.
--
-- The two ways of being off are the domain's own vocabulary (SourceState), read
-- here rather than spelled again, so a level record uses the same word for the
-- same state.
Capabilities.Reason = {
  PRESENT = "present",
  -- The client does not have this at all.
  ABSENT = ns.core.SourceState.ABSENT,
  -- The client has it, and what it returns cannot be read by this addon.
  UNREADABLE = ns.core.SourceState.UNREADABLE,
}

local VALID_REASON = {
  [Capabilities.Reason.PRESENT] = true,
  [Capabilities.Reason.ABSENT] = true,
  [Capabilities.Reason.UNREADABLE] = true,
}

function Capabilities.new()
  return setmetatable({ results = {} }, Capabilities)
end

-- probe: a function with no arguments, called once, whose first result is
-- normalised to a real boolean (a probe written as `return SomeTable and
-- SomeTable.Fn` answers with the function itself). Its optional second result is
-- the reason, for the case the first cannot express: present in the client and
-- unreadable anyway. Without one, an absent capability gets ABSENT.
-- Errors from the probe are not caught: a probe that cannot determine presence
-- is a bug in the probe, not an absent capability.
function Capabilities:register(name, probe)
  if type(name) ~= "string" or name == "" then
    error("Capabilities: a capability needs a non-empty string name", 3)
  end
  if self.results[name] ~= nil then
    error("Capabilities: '" .. name .. "' is already registered", 3)
  end
  if type(probe) ~= "function" then
    error("Capabilities: '" .. name .. "' needs a probe() function", 3)
  end

  local present, reason = probe()
  present = not not present

  if present then
    -- A capability cannot be both available and unreadable: whatever a probe
    -- says, what the caller gets to rely on is that it answered yes.
    reason = Capabilities.Reason.PRESENT
  elseif reason == nil then
    reason = Capabilities.Reason.ABSENT
  elseif not VALID_REASON[reason] then
    error("Capabilities: '" .. name .. "' gave the unknown reason '" .. tostring(reason) .. "'", 3)
  end

  self.results[name] = { present = present, reason = reason }
  return self
end

-- A capability that was present when probed and stopped being so mid-session. A
-- probe runs once, at login, but two sources only show whether they are readable
-- when their first value arrives: the experience line and, on a client that has
-- one, the combat log's payload. The router that sees the first unreadable value
-- reports it here.
--
-- One way, and once: present to off, never back within the session, because a
-- source that closed once cannot promise to cover the rest of the level, and a
-- figure flickering with "not available" is worse than either. Answers whether
-- this call changed anything, so the caller marks the level exactly once.
function Capabilities:degrade(name, reason)
  local entry = self.results[name]
  if entry == nil then
    error("Capabilities: '" .. tostring(name) .. "' was never registered", 2)
  end
  reason = reason or Capabilities.Reason.UNREADABLE
  if reason == Capabilities.Reason.PRESENT or not VALID_REASON[reason] then
    error("Capabilities: '" .. name .. "' cannot be degraded to '" .. tostring(reason) .. "'", 2)
  end
  if not entry.present then
    return false
  end
  entry.present = false
  entry.reason = reason
  return true
end

-- True only for a capability that was both registered and found present. A name
-- nobody registered is absent, the same as one that was probed and failed -- the
-- caller only ever needs to know whether it can rely on the capability, not why not.
function Capabilities:has(name)
  local entry = self.results[name]
  return entry ~= nil and entry.present == true
end

-- Why a capability is in the state it is in, as one of Reason's three values, or
-- nil for a name nobody registered.
function Capabilities:reasonFor(name)
  local entry = self.results[name]
  return entry ~= nil and entry.reason or nil
end

-- Names probed and found absent, sorted, so the diagnostic can show the player
-- what got turned off.
function Capabilities:missing()
  local names = {}
  for name, entry in pairs(self.results) do
    if not entry.present then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- The whole roster, present and absent alike. `missing()` only lists absences,
-- so a healthy registry and an empty one print the same "none"; a diagnostic
-- that names what it checked tells them apart.
function Capabilities:all()
  local roster = {}
  for name, entry in pairs(self.results) do
    roster[#roster + 1] = { name = name, present = entry.present, reason = entry.reason }
  end
  table.sort(roster, function(a, b) return a.name < b.name end)
  return roster
end

ns.adapter.Capabilities = Capabilities
