-- Ascent - prove that a change to Lua files touched comments and nothing else.
--
-- Compiles both versions of every changed .lua file and compares the bytecode
-- with debug information stripped, which is what remains once comments, blank
-- lines and spacing are gone. The chunk name is fixed because LuaJIT stores it
-- in the dump, and the dump is deterministic ("d") because otherwise the order
-- of a constant table's keys depends on the garbage collector.
--
--   luajit tools/same-code.lua [<rev>] [-- <path>...]
--
-- compares the working tree with <rev> (HEAD), for every changed .lua file or
-- only for those under the given paths.

local rev, paths = "HEAD", {}
local index = 1
if arg[index] and arg[index] ~= "--" then
  rev = arg[index]
  index = index + 1
end
if arg[index] == "--" then
  for position = index + 1, #arg do
    paths[#paths + 1] = (arg[position]:gsub("/+$", ""))
  end
end

local function wanted(path)
  if #paths == 0 then
    return true
  end
  for _, prefix in ipairs(paths) do
    if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then
      return true
    end
  end
  return false
end

-- Only characters a revision can contain, because it is spliced into a command.
if not rev:match("^[%w%._/~%^@{}-]+$") then
  io.stderr:write("not a revision: " .. rev .. "\n")
  os.exit(2)
end

local function run(command)
  local handle = assert(io.popen(command))
  local output = handle:read("*a")
  handle:close()
  return output
end

-- Under Lua 5.1 semantics closing a pipe does not return the exit status, so the
-- shell prints it instead.
local known = run("git rev-parse --verify --quiet '" .. rev .. "^{commit}' >/dev/null && echo yes")
if known ~= "yes\n" then
  io.stderr:write("unknown revision: " .. rev .. "\n")
  os.exit(2)
end

local function bytecode(source)
  local chunk, err = loadstring(source, "=chunk")
  if not chunk then
    return nil, err
  end
  return string.dump(chunk, "sd")
end

local function readFile(path)
  local handle = assert(io.open(path, "rb"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local changed = {}

local diff = run("git diff --name-status --no-renames '" .. rev .. "' -- '*.lua'")
for status, path in diff:gmatch("(%u)%s+([^\n]+)") do
  if wanted(path) then
    changed[#changed + 1] = { status = status, path = path }
  end
end

-- Untracked files are not in a diff against a revision, and they are new code.
local untracked = run("git ls-files --others --exclude-standard -- '*.lua'")
for path in untracked:gmatch("[^\n]+") do
  if wanted(path) then
    changed[#changed + 1] = { status = "A", path = path }
  end
end

local problems = {}
local same = 0

for _, file in ipairs(changed) do
  if file.status == "A" then
    problems[#problems + 1] = "new file: " .. file.path
  elseif file.status == "D" then
    problems[#problems + 1] = "deleted: " .. file.path
  else
    local before, beforeErr = bytecode(run("git show '" .. rev .. ":" .. file.path .. "'"))
    local after, afterErr = bytecode(readFile(file.path))
    if not after then
      problems[#problems + 1] = "does not compile: " .. file.path .. " (" .. afterErr .. ")"
    elseif not before then
      problems[#problems + 1] = "did not compile at " .. rev .. ": " .. file.path .. " (" .. beforeErr .. ")"
    elseif before ~= after then
      problems[#problems + 1] = "code changed: " .. file.path
    else
      same = same + 1
    end
  end
end

if #problems > 0 then
  for _, line in ipairs(problems) do
    print("  " .. line)
  end
  os.exit(1)
end

local scope = #paths > 0 and (" under " .. table.concat(paths, ", ")) or ""
print(("  ok %d changed .lua file(s)%s against %s, comments and spacing only"):format(same, scope, rev))
