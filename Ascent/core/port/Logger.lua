-- Ascent - Logger port.

local _, ns = ...
ns.core = ns.core or {}

ns.core.Logger = ns.core.Port.define("Logger", {
  info = "Something the player should see, in their chat frame.",
  warn = "Something went wrong but the addon carried on. Shown once, not repeatedly.",
  debug = "Diagnostics. Silent unless the player turned the debug setting on.",
  isDebug = "Whether debug output is on, so callers can skip building expensive "
         .. "messages that would be thrown away.",
})
