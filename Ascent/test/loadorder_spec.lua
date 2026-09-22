-- The client has no require(): it loads an addon's files in TOC order into one
-- shared table, and every module binds what it needs to a local as it loads. A file
-- placed before its dependency binds nil and fails much later, in the client, as a
-- nil index in the middle of a fight. dev.sh checks that the TOC and the files
-- match; this checks that the order works, with a strict namespace so an early read
-- fails at the file that made it.

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
    -- `adapter` is strict for the same reason `core` is: as a plain table, an
    -- adapter bound before another defines it would read nil here and fail only
    -- in the client, e.g. at the first quest log sweep.
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
