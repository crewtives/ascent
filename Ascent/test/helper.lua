-- Ascent - test harness.
--
-- The client hands every addon file a vararg: `local ADDON_NAME, ns = ...`.
-- There is no require(), no package.path and no module system inside WoW, so that
-- vararg is the only namespace mechanism the addon has. This harness reproduces
-- that calling convention outside the client, which makes the domain testable
-- and keeps `core/` from needing the game.

local ADDON_NAME = "Ascent"
local ADDON_ROOT = os.getenv("ASCENT_ROOT") or "Ascent"

local Harness = {}

Harness.ADDON_NAME = ADDON_NAME

-- A fresh namespace per test: specs must not leak state into each other.
function Harness.newNamespace()
  return { core = {}, adapter = {}, ui = {}, locale = {}, app = {} }
end

-- Load addon files into a namespace, in the given order, exactly as the TOC would.
function Harness.load(ns, ...)
  local paths = { ... }
  for i = 1, #paths do
    local full = ADDON_ROOT .. "/" .. paths[i]
    local chunk, err = loadfile(full)
    if not chunk then
      error(("harness could not load %s: %s"):format(full, tostring(err)), 2)
    end
    chunk(ADDON_NAME, ns)
  end
  return ns
end

-- Convenience for the common case: fresh namespace, load, hand it back.
function Harness.loadFresh(...)
  return Harness.load(Harness.newNamespace(), ...)
end

-- Every file the TOC declares under a prefix, in TOC order. Read straight from the
-- TOC so the suite exercises the real load order: a second list here would drift,
-- and a wrong order fails as a nil at load time in the client.
function Harness.tocPaths(prefix)
  local paths = {}
  for line in io.lines(ADDON_ROOT .. "/Ascent.toc") do
    local path = line:gsub("\\", "/"):match("^(" .. prefix .. ".+%.lua)%s*$")
    if path then
      paths[#paths + 1] = path
    end
  end
  if #paths == 0 then
    error("harness found nothing under '" .. prefix .. "' in the TOC; is the working directory the repo root?")
  end
  return paths
end

-- The vocabulary every domain module depends on.
Harness.CONSTANTS = Harness.tocPaths("core/constants/")

-- Load a mix of TOC directories and individual files, in the order given. Anything
-- ending in "/" is a directory and expands to everything the TOC declares under it,
-- in TOC order; anything else is a single file.
--
--   AscentTest.loadWith("core/model/", "core/port/", "core/service/LevelTracker.lua")
--
-- Building the list first is not a style choice: in 5.1 `unpack` only expands when
-- it is the last argument, so `loadDomain(unpack(paths), extra)` quietly loads one
-- file and leaves the rest of the domain nil.
function Harness.loadWith(...)
  local files = {}

  for _, item in ipairs({ ... }) do
    if item:sub(-1) == "/" then
      for _, path in ipairs(Harness.tocPaths(item)) do
        files[#files + 1] = path
      end
    else
      files[#files + 1] = item
    end
  end

  return Harness.loadDomain(unpack(files))
end

-- Fresh namespace with the constants prelude already in place, then whatever the
-- spec actually wants to exercise.
function Harness.loadDomain(...)
  local ns = Harness.load(Harness.newNamespace(), unpack(Harness.CONSTANTS))
  return Harness.load(ns, ...)
end

-- ---------------------------------------------------------------------------
-- The secret-value regime of the 12.0 engine, stood in for.
--
-- A secret is present, has a type, and raises when this addon's code operates on
-- it. What Lua 5.1 cannot reproduce is the comparison against a plain value:
-- `__eq` is only dispatched between two tables, so `secret == true` answers false
-- here where the real client raises. So the guard is applied by conversion rather
-- than by catching errors: the harness cannot find an unguarded comparison. The
-- other limit, a secret's type, has an opt-in answer: see `withClientTypes`.
-- ---------------------------------------------------------------------------

local SECRET = {}

-- One shared raise, not a closure per value: `__eq` is only dispatched when both
-- tables carry the same metamethod, so a per-value closure would make two secrets
-- compare false instead of raising.
local function raise() error("attempt to operate on a secret value", 2) end

local SECRET_META = {
  __index = raise, __newindex = raise, __call = raise, __concat = raise,
  __add = raise, __sub = raise, __mul = raise, __div = raise, __mod = raise,
  __pow = raise, __unm = raise, __lt = raise, __le = raise, __eq = raise,
  __tostring = function() return "<secret>" end,
}

-- Captured before anything can replace it: `withClientTypes` below swaps the
-- global, and the harness itself must keep asking the real question.
local rawtype = type

function Harness.secret(value)
  return setmetatable({ [SECRET] = value }, SECRET_META)
end

function Harness.isSecret(value)
  return rawtype(value) == "table" and getmetatable(value) == SECRET_META
end

-- The second limit of the stand-in: a secret here is a table, and in the client
-- it has the type of the value it closes. So `type(message) ~= "string"` quietly
-- throws a stand-in secret away, guard or no guard, where the client's secret
-- string walks straight past the same test and raises on the match after it. Run
-- `fn` with `type` answering the way the client does, so a check like that stops
-- passing for the wrong reason. Opt-in, and only for the span of `fn`, because it
-- is a global the whole test process shares.
function Harness.withClientTypes(fn)
  _G.type = function(value)
    if Harness.isSecret(value) then
      return rawtype(rawget(value, SECRET))
    end
    return rawtype(value)
  end

  local ok, err = pcall(fn)

  _G.type = rawtype
  if not ok then
    error(err, 0)
  end
end

-- Turn the regime on for the client globals, run `fn`, and put them back. The
-- globals go up before fn runs because the guard captures them at load time, so
-- a spec's own loadDomain has to happen inside.
function Harness.withSecretRegime(fn)
  local savedIs, savedCan = _G.issecretvalue, _G.canaccessvalue
  _G.issecretvalue = Harness.isSecret
  _G.canaccessvalue = function(value) return not Harness.isSecret(value) end

  local ok, err = pcall(fn)

  _G.issecretvalue, _G.canaccessvalue = savedIs, savedCan
  if not ok then
    error(err, 0)
  end
end

_G.AscentTest = Harness

return Harness
