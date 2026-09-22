-- Ascent - the guard every client read passes through before it is used.
--
-- On the 12.0 engine a read can come back secret: a value that is present, has a
-- type, and raises a Lua error the moment addon code compares it, does arithmetic
-- on it, concatenates it or uses it as a table key. It is not nil, so an `if`
-- guard does not catch it. Nothing the client says reaches core/ without passing
-- through here, and an unreadable value becomes nil: the absence the domain
-- already handles, without core/ learning about one client's quirk.
--
-- On both classic flavours `issecretvalue` does not exist, every value is
-- readable, and this costs one upvalue test per call. The functions are captured
-- at load because this runs inside the combat log handler, hundreds of times a
-- second in a group, on every field of every line.

local _, ns = ...
ns.adapter = ns.adapter or {}

-- Captured once, at load. A client that has them does not lose them mid-session,
-- and one that lacks them is not going to grow them.
local isSecret = issecretvalue
local canAccess = canaccessvalue

local Readable = {}

-- The value when this addon is allowed to read it, nil when it is not.
--
-- `issecretvalue` is asked first and `canaccessvalue` only after it says yes, so
-- the common case, an ordinary value, costs one call. The second question is
-- still needed: a value can be secret and still be one this addon may read.
function Readable.value(value)
  if isSecret == nil then
    return value
  end
  if not isSecret(value) then
    return value
  end
  if canAccess ~= nil and canAccess(value) then
    return value
  end
  return nil
end

-- Whether the running client has secret values at all. Registered as a
-- capability so the diagnostic can report it, and read by nothing else: a caller
-- that branches on it has stopped treating an unreadable value as an absent one.
function Readable.isSupported()
  return isSecret ~= nil
end

ns.adapter.Readable = Readable
