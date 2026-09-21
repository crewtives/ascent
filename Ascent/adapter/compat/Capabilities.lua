-- Ascent - capability probes.
--
-- Two supported clients share the bulk of an API surface that has grown for two
-- decades, but not all of it: a function a collector wants might not exist on the
-- flavor running, or might exist and never return anything useful. A probe answers
-- once, at registration time, whether the addon can rely on it -- so a missing
-- capability degrades the one collector that needed it instead of producing a nil
-- call deep inside a fight. See the addon-lifecycle spec's "capacidad ausente"
-- scenario: the addon still loads, and the player can see what got turned off.

local _, ns = ...
ns.adapter = ns.adapter or {}

local Capabilities = {}
Capabilities.__index = Capabilities

function Capabilities.new()
  return setmetatable({ results = {} }, Capabilities)
end

-- probe: a function with no arguments, called once, whose result is normalised to a
-- real boolean -- a probe written as `return SomeTable and SomeTable.Fn` answers
-- with the function itself, not `true`, and callers only ever need present/absent.
-- Errors from the probe itself are not caught: a probe that cannot even determine
-- presence is a bug in the probe, not an absent capability.
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

  self.results[name] = not not probe()
  return self
end

-- True only for a capability that was both registered and found present. A name
-- nobody registered is absent, the same as one that was probed and failed -- the
-- caller only ever needs to know whether it can rely on the capability, not why not.
function Capabilities:has(name)
  return self.results[name] == true
end

-- Names probed and found absent, sorted, for the diagnostic surface the
-- addon-lifecycle spec asks for: the player can see what got turned off.
function Capabilities:missing()
  local names = {}
  for name, present in pairs(self.results) do
    if not present then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- The whole roster, present and absent alike. `missing()` can only ever list
-- absences, so "missing capabilities: none" is what a healthy registry prints AND
-- what an empty one prints -- which is exactly how a registry with no probes at
-- all went unnoticed. A diagnostic that names what it checked cannot lie that way.
function Capabilities:all()
  local roster = {}
  for name, present in pairs(self.results) do
    roster[#roster + 1] = { name = name, present = present == true }
  end
  table.sort(roster, function(a, b) return a.name < b.name end)
  return roster
end

ns.adapter.Capabilities = Capabilities
