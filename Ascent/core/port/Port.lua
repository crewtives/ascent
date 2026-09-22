-- Ascent - port contracts.
--
-- Lua has no interfaces, so a port here is a frozen table mapping each required
-- method to what it means:
--
--   * `Port.verify` reports a missing method as one error at wiring time, naming
--     every method that is missing, instead of a nil call deep inside a handler.
--   * the semantics live next to the name, so an implementer does not have to
--     infer the contract from a call site.
--
-- A port is added only when it enables testing without the client, or when it
-- has at least two plausible implementations.

local ADDON_NAME, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

local Port = {}

local names = setmetatable({}, { __mode = "k" })

-- methods: { methodName = "what it returns and what it means" }
function Port.define(name, methods)
  local contract = Frozen.enum(name, methods)
  names[contract] = name
  return contract
end

function Port.nameOf(contract)
  return names[contract] or "<unknown port>"
end

-- Every port defined so far, sorted, so the suite can assert the whole set.
function Port.all()
  local defined = {}
  for _, name in pairs(names) do
    defined[#defined + 1] = name
  end
  table.sort(defined)
  return defined
end

-- Check an implementation against its contract. Reports every missing method at
-- once, so a single reload shows them all.
function Port.verify(contract, implementation, label)
  local portName = Port.nameOf(contract)
  label = label or portName

  if type(implementation) ~= "table" then
    error(("%s: %s must be a table implementing %s, got %s")
      :format(ADDON_NAME, label, portName, type(implementation)), 2)
  end

  local missing = {}
  for _, method in ipairs(Frozen.keys(contract)) do
    if type(implementation[method]) ~= "function" then
      missing[#missing + 1] = method
    end
  end

  if #missing > 0 then
    error(("%s: %s does not implement %s; missing: %s")
      :format(ADDON_NAME, label, portName, table.concat(missing, ", ")), 2)
  end

  return implementation
end

ns.core.Port = Port
