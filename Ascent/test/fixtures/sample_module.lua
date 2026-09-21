-- A stand-in for a real core module, used only to prove the harness contract:
-- it receives (ADDON_NAME, ns), registers itself on the namespace, and touches
-- nothing but the Lua standard library.
local ADDON_NAME, ns = ...

local Sample = {}

function Sample.describe()
  return ADDON_NAME .. " sample module"
end

function Sample.sum(numbers)
  local total = 0
  for i = 1, #numbers do
    total = total + numbers[i]
  end
  return total
end

ns.core.Sample = Sample
