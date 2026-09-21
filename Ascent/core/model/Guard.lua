-- Ascent - argument guards shared by the models.
--
-- The models are the last place a bad number can be caught before it reaches the
-- saved variables, where it becomes someone's corrupted history. The messages name
-- the field on purpose: a stack trace from inside WoW is often all you get.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

local Guard = {}

-- The type is part of the message because the commonest failure these guards catch
-- is a string where a number belongs, and "got 24" reads identically either way.
local function reject(what, expected, value)
  error(("%s must be %s, got %s (%s)"):format(what, expected, tostring(value), type(value)), 4)
end

function Guard.nonNegativeInteger(value, what)
  if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
    reject(what, "a non-negative integer", value)
  end
  return value
end

function Guard.positiveInteger(value, what)
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
    reject(what, "a positive integer", value)
  end
  return value
end

function Guard.number(value, what)
  if type(value) ~= "number" then
    reject(what, "a number", value)
  end
  return value
end

-- Percentages are fractions of one throughout the domain. Formatting them as
-- "61%" is the view's job, not the model's.
function Guard.fraction(value, what)
  if type(value) ~= "number" or value < 0 or value > 1 then
    reject(what, "a fraction between 0 and 1", value)
  end
  return value
end

function Guard.member(enum, enumName, value, what)
  for _, allowed in Frozen.each(enum) do
    if allowed == value then
      return value
    end
  end
  reject(what, "a " .. enumName, value)
end

ns.core.Guard = Guard
