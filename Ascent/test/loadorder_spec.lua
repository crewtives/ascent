-- The client has no require(). It loads an addon's files in the order the TOC
-- declares them, into one shared table, and every module here binds what it needs to
-- a local as it loads. A file placed before the one that defines its dependency
-- therefore binds nil, and the failure surfaces much later -- in the client, on
-- somebody else's machine, as a nil index in the middle of a fight.
--
-- dev.sh already checks that the TOC lists every file and that every listed file
-- exists. This checks the half it cannot: that the order it lists them in works.
-- The namespace is made strict for the duration, so reading a name that has not been
-- defined yet fails at the file that read it rather than somewhere downstream.

describe("the addon's load order", function()
  local function strictNamespace()
    local defined = {}
    local core = setmetatable({}, {
      __index = function(_, key)
        error(("ns.core.%s is read before any file has defined it"):format(tostring(key)), 2)
      end,
      __newindex = function(_, key, value)
        defined[key] = value
        rawset(_, key, value)
      end,
    })
    -- `adapter` is strict for the same reason `core` is, and it was not until a
    -- reader bound `ns.adapter.GlobalStringPattern` three files before anything
    -- defined it. Nothing failed here; it failed in the client, at the first
    -- quest log sweep, which is the exact failure this file exists to prevent.
    local adapter = setmetatable({}, {
      __index = function(_, key)
        error(("ns.adapter.%s is read before any file has defined it"):format(tostring(key)), 2)
      end,
      __newindex = function(_, key, value)
        defined[key] = value
        rawset(_, key, value)
      end,
    })
    return { core = core, adapter = adapter, ui = {}, locale = {}, app = {} }, defined
  end

  it("loads every core file in the order the TOC declares, outside the client", function()
    local paths = AscentTest.tocPaths("core/")
    local ns, defined = strictNamespace()

    for _, path in ipairs(paths) do
      local ok, err = pcall(AscentTest.load, ns, path)
      assert.is_true(ok, ("%s does not load in its TOC position: %s"):format(path, tostring(err)))
    end

    -- Every file registers something, so a file that loaded and left nothing behind
    -- is a file whose name the composition root will not find.
    local count = 0
    for _ in pairs(defined) do
      count = count + 1
    end
    assert.is_true(count >= #paths,
      ("%d core files registered only %d names"):format(#paths, count))
  end)

  -- The half this file did not check until an adapter bound another adapter's
  -- name three files before anything defined it. Nothing failed: `ns.adapter` was
  -- a plain table, so the read answered nil and the addon broke in the client, at
  -- the first quest log sweep, with the pattern compiler missing.
  it("loads every adapter file in the order the TOC declares, on top of core", function()
    local ns = strictNamespace()

    for _, path in ipairs(AscentTest.tocPaths("core/")) do
      AscentTest.load(ns, path)
    end

    for _, path in ipairs(AscentTest.tocPaths("adapter/")) do
      local ok, err = pcall(AscentTest.load, ns, path)
      assert.is_true(ok, ("%s does not load in its TOC position: %s"):format(path, tostring(err)))
    end
  end)
end)
