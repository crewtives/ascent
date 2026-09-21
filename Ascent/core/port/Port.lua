-- Ascent - port contracts.
--
-- Lua has no interfaces, so a port here is a frozen table mapping each required
-- method to what it means. That buys two things a comment would not:
--
--   * `Port.verify` turns "the adapter forgot a method" into one clear error at
--     wiring time, naming every method that is missing, instead of a nil call
--     deep inside a combat handler an hour later.
--   * the semantics live next to the name, so an implementer does not have to
--     infer the contract from whichever call site they happened to read first.
--
-- The rule for adding a port is in the design and is deliberately strict: it has
-- to enable testing without the client, or have at least two plausible
-- implementations. Six exist. There is no seventh.

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

-- Every port defined so far, sorted. Exists so the suite can assert the whole set
-- rather than the six names it happens to remember.
function Port.all()
  local defined = {}
  for _, name in pairs(names) do
    defined[#defined + 1] = name
  end
  table.sort(defined)
  return defined
end

-- Check an implementation against its contract. Reports every missing method at
-- once: finding them one error at a time is a waste of a reload.
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
