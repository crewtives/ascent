-- Ascent - test harness.
--
-- The client hands every addon file a vararg: `local ADDON_NAME, ns = ...`.
-- There is no require(), no package.path and no module system inside WoW, so that
-- vararg is the only namespace mechanism the addon has. This harness reproduces
-- that exact calling convention outside the client, which is what makes the
-- domain testable at all -- and what keeps `core/` honest about not needing the game.

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

-- The vocabulary every domain module depends on, read straight from the TOC so the
-- suite exercises the real load order. Keeping a second list here would let the two
-- drift, and the failure mode of a wrong order is a nil at load time in the client.
-- Every file the TOC declares under a prefix, in TOC order.
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

_G.AscentTest = Harness

return Harness
