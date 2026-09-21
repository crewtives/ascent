-- Ascent - Locale port.

local _, ns = ...
ns.core = ns.core or {}

ns.core.Locale = ns.core.Port.define("Locale", {
  get = "get(key, ...) -> string, never nil. Three cases, in order: the client's "
     .. "language has the text, so it is used; only the base language has it, so "
     .. "that is used; nobody has it, in which case the key itself is returned in "
     .. "diagnostic mode and the same 'no data' marker the bar uses otherwise. A "
     .. "player must never be shown a blank where a label belongs, nor an internal "
     .. "identifier outside diagnostic mode.",
  has = "has(key) -> boolean. Whether a key has text in the client's language. "
     .. "False does not mean get() will fail: it means it will fall back.",
})
