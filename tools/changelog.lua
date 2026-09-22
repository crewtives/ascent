-- Ascent - CHANGELOG.md -> Ascent/core/constants/Changelog.lua
--
-- The in-game changelog is generated from CHANGELOG.md so that the two cannot
-- disagree: `./dev.sh lint` regenerates it into a temporary file and fails if the
-- result differs. Generation also refuses an entry over its length limit and a
-- client tag it does not know.
--
--   luajit tools/changelog.lua [output-path]

local KEEP = 5 -- how many versions travel inside the addon
local ENTRY_LIMIT = 160 -- characters in one entry, once formatting is removed
local STATUS_LIMIT = 200 -- characters in the line a version may open with
local CLIENT_TAGS = { Era = true, TBC = true, Forever = true }

local ROOT = arg[0]:match("^(.*)/tools/[^/]+$") or "."
local SOURCE = ROOT .. "/CHANGELOG.md"
local OUTPUT = arg[1] or (ROOT .. "/Ascent/core/constants/Changelog.lua")

local function read(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local body = handle:read("*a")
  handle:close()
  return body
end

-- A text box shows markdown as punctuation: emphasis and code ticks go, and a
-- link keeps its visible text without the URL.
local function plain(text)
  text = text:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
  text = text:gsub("%*%*(.-)%*%*", "%1")
  text = text:gsub("`(.-)`", "%1")
  return (text:gsub("%s+$", ""))
end

-- Characters, not bytes: a dash or an arrow is one character and three bytes.
local function length(text)
  return select(2, text:gsub("[^\128-\191]", ""))
end

local problems = {}

local function refuse(version, what, text)
  local start = #text > 60 and (text:sub(1, 57) .. "...") or text
  problems[#problems + 1] = ('%s: %s: "%s"'):format(version, what, start)
end

-- An entry is one sentence for a player, and says first which clients it is
-- about when it is not all of them.
local function checkEntry(version, text)
  local size = length(text)
  if size > ENTRY_LIMIT then
    refuse(version, ("entry of %d characters, over %d"):format(size, ENTRY_LIMIT), text)
  end
  local rest = text
  while true do
    local tag, after = rest:match("^%[([^%]]+)%]%s*(.*)$")
    if not tag then
      break
    end
    if not CLIENT_TAGS[tag] then
      refuse(version, "unknown client tag [" .. tag .. "]", text)
      break
    end
    rest = after
  end
end

local function checkStatus(entry, text)
  entry.paragraphs = (entry.paragraphs or 0) + 1
  if entry.paragraphs > 1 then
    refuse(entry.version, "more than one status line", text)
  end
  local size = length(text)
  if size > STATUS_LIMIT then
    refuse(entry.version, ("status line of %d characters, over %d"):format(size, STATUS_LIMIT), text)
  end
end

-- One entry per released version, newest first, already rendered to the lines
-- the addon shows, so the client never parses markdown.
local function parse(body)
  local versions = {}
  local current, bullet, paragraph

  -- A bullet or a paragraph may span several source lines. It stays open until a
  -- blank line, a new item or a new section, and becomes one line that the client
  -- wraps to its window.
  local function flush()
    if bullet ~= nil then
      local text = plain(bullet)
      checkEntry(current.version, text)
      current.lines[#current.lines + 1] = "- " .. text
      bullet = nil
    end
    if paragraph ~= nil then
      local text = plain(paragraph)
      checkStatus(current, text)
      current.lines[#current.lines + 1] = text
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
        -- Prose outside a list is the version's status line. Reference-style link
        -- definitions are skipped above.
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

if #problems > 0 then
  for _, problem in ipairs(problems) do
    io.stderr:write("CHANGELOG.md " .. problem .. "\n")
  end
  os.exit(1)
end

local out = {}
local function emit(line) out[#out + 1] = line end

emit("-- Ascent - what changed, version by version.")
emit("--")
emit("-- GENERATED from CHANGELOG.md by tools/changelog.lua. Do not edit by hand:")
emit("-- `./dev.sh lint` regenerates it and fails if this file disagrees with the")
emit("-- changelog it came from.")
emit("--")
emit(("-- The last %d released versions travel with the addon; older ones stay in the"):format(KEEP))
emit("-- repository, where nobody's client pays for them.")
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
