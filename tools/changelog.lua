-- Ascent - CHANGELOG.md -> Ascent/core/constants/Changelog.lua
--
-- The addon shows what changed without leaving the game, and the text it shows
-- has to be the text in CHANGELOG.md. Writing it twice means writing it once and
-- forgetting the other, which is the mistake `add-ascent-copy-report` already
-- avoided once by refusing to build the same report from two places (D2).
--
-- So this generates, and `./dev.sh lint` regenerates into a temporary file and
-- compares: editing the changelog without regenerating fails the lint, the same
-- way check_toc fails on a file that is not listed. Both failures are silent
-- inside the client, which is the whole reason either check exists.
--
--   luajit tools/changelog.lua [output-path]
--
-- Runs on LuaJIT because the test suite and the smoke harness already require it.

local KEEP = 5 -- how many versions travel inside the addon (design D70)

local ROOT = arg[0]:match("^(.*)/tools/[^/]+$") or "."
local SOURCE = ROOT .. "/CHANGELOG.md"
local OUTPUT = arg[1] or (ROOT .. "/Ascent/core/constants/Changelog.lua")

local function read(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local body = handle:read("*a")
  handle:close()
  return body
end

-- Markdown emphasis and code ticks are punctuation in a text box, not formatting.
-- Link syntax keeps the visible half: [Keep a Changelog](https://...) is read by a
-- person, and the URL is noise inside the game.
local function plain(text)
  text = text:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
  text = text:gsub("%*%*(.-)%*%*", "%1")
  text = text:gsub("`(.-)`", "%1")
  return (text:gsub("%s+$", ""))
end

-- One entry per released version, newest first, each already rendered to the
-- lines the addon will show. Nothing is parsed at run time: a player's client
-- should not be reading markdown.
local function parse(body)
  local versions = {}
  local current, bullet, paragraph

  -- A bullet or a paragraph may be written across several source lines; both are
  -- one sentence to the reader, and the client wraps them again to the width of
  -- the window they end up in. Held open until a blank line, a new item or a new
  -- section closes them.
  local function flush()
    if bullet ~= nil then
      current.lines[#current.lines + 1] = "- " .. plain(bullet)
      bullet = nil
    end
    if paragraph ~= nil then
      current.lines[#current.lines + 1] = plain(paragraph)
      paragraph = nil
    end
  end

  for line in (body .. "\n"):gmatch("(.-)\n") do
    local version, date = line:match("^## %[([^%]]+)%]%s*%-?%s*(.*)$")
    if version then
      flush()
      -- "Unreleased" is a heading for the repository, not a version anybody runs.
      if version:lower() == "unreleased" then
        current = nil
      else
        current = { version = version, date = plain(date), lines = {} }
        versions[#versions + 1] = current
      end
    elseif current then
      local section = line:match("^### (.+)$")
      local item = line:match("^%-%s+(.+)$")
      local continuation = line:match("^%s%s+(%S.*)$")

      if section then
        flush()
        if #current.lines > 0 then
          current.lines[#current.lines + 1] = ""
        end
        current.lines[#current.lines + 1] = plain(section)
      elseif item then
        flush()
        bullet = item
      elseif continuation and bullet then
        bullet = bullet .. " " .. continuation
      elseif line:match("^%s*$") then
        flush()
      elseif not line:match("^%[") then
        -- Prose between the heading and the first section: the paragraph the
        -- author wrote for whoever is reading the release, which is exactly the
        -- audience here. Reference-style link definitions are skipped above.
        if bullet ~= nil then
          bullet = bullet .. " " .. line:gsub("^%s+", "")
        else
          paragraph = paragraph and (paragraph .. " " .. line:gsub("^%s+", "")) or line
        end
      end
    end
  end

  flush()
  return versions
end

local function quote(text)
  return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local versions = parse(read(SOURCE))
assert(#versions > 0, "no released version found in " .. SOURCE)

local out = {}
local function emit(line) out[#out + 1] = line end

emit("-- Ascent - what changed, version by version.")
emit("--")
emit("-- GENERATED from CHANGELOG.md by tools/changelog.lua. Do not edit by hand:")
emit("-- `./dev.sh lint` regenerates it and fails if this file disagrees with the")
emit("-- changelog it came from.")
emit("--")
emit(("-- The last %d released versions travel with the addon; older ones stay in the"):format(KEEP))
emit("-- repository, where nobody's client pays for them (design D70).")
emit("")
emit("local _, ns = ...")
emit("ns.core = ns.core or {}")
emit("")
emit("ns.core.CHANGELOG = {")

for index = 1, math.min(KEEP, #versions) do
  local entry = versions[index]
  emit("  {")
  emit(("    version = %s,"):format(quote(entry.version)))
  emit(("    date = %s,"):format(quote(entry.date)))
  emit("    lines = {")
  for _, line in ipairs(entry.lines) do
    emit(("      %s,"):format(quote(line)))
  end
  emit("    },")
  emit("  },")
end

emit("}")
emit("")

local handle = assert(io.open(OUTPUT, "w"), "cannot write " .. OUTPUT)
handle:write(table.concat(out, "\n"))
handle:close()

print(("changelog: %d version(s) -> %s"):format(math.min(KEEP, #versions), OUTPUT))
