-- A stand-in client: enough of the WoW API for the addon to load and build its
-- interface, so that a Lua error in ui/ or app/ shows up here instead of as a
-- silent nothing in the game.
--
-- It does NOT pretend to be the real client: a stub accepts any template name
-- and any method call, so template-specific failures (a template that needs its
-- parent named, a method missing on one flavour) do not reproduce here. What it
-- does catch is every ordinary Lua fault -- a nil index, a missing field, a
-- method that does not exist on our OWN objects, a load-order mistake.

local ROOT = (...) or "Ascent"

local frames = {}

-- Every widget this stub ever hands out, frames and regions alike. It is what
-- makes "opening the panel allocates nothing" a measurable property rather than
-- a claim -- a pool that quietly built a row per open would show up here as a
-- number that grows.
local widgets = 0

local DEFAULT_FONT = "Fonts\\FRIZQT__.TTF"

local function newRegion(kind)
  widgets = widgets + 1
  local region = { kind = kind, points = {}, children = {} }
  setmetatable(region, {
    __index = function(self, key)
      -- Any client method we did not bother to model: record it and return a
      -- function that keeps the chain going. A nil here would mask the very
      -- errors this harness exists to find.
      if type(key) == "string" and key:match("^%u") then
        rawset(self, key, function(...) return self end)
        return rawget(self, key)
      end
      return nil
    end,
  })

  -- Same rule as SetWidth/SetHeight below: an anchored frame's size is the
  -- anchor's, and SetSize on one does nothing until the anchor is released.
  function region:SetSize(w, h)
    if self.allPointsOf == nil then self.w, self.h = w, h end
    return self
  end

  -- Which frame the scroll frame is actually scrolling. Auto-stubbed, the harness
  -- could not tell whether a control ended up inside it or past its bottom edge --
  -- and past its bottom edge is exactly where half this panel used to live.
  function region:SetScrollChild(child) self.scrollChild = child return self end

  -- The anchors back out again. Auto-stubbed, GetPoint returned self, and the
  -- options panel's own measurement of how tall its scroll child has to be could
  -- not walk one link of the chain it was built from.
  function region:GetPoint(index)
    local p = self.points[index or 1]
    if p == nil then return nil end
    return p[1], p[2], p[3], p[4], p[5]
  end
  -- A frame held by SetAllPoints is pinned at both corners, and the client
  -- ignores SetSize on one: its size comes from the anchor until the anchor is
  -- released. Without that rule here, the harness applies every size it is given
  -- and cannot see a bar that came back from the client's slot still wearing the
  -- client's width -- which is what the owner reported as "se queda con la
  -- dimension vieja".
  function region:SetWidth(w) if self.allPointsOf == nil then self.w = w end return self end
  function region:SetHeight(h) if self.allPointsOf == nil then self.h = h end return self end
  function region:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } return self end

  -- Which tab reads as "you are here". Auto-stubbed these returned self and recorded
  -- nothing, so the harness could walk every tab without being able to say which one
  -- ended up marked -- and "did not error" is exactly what a panel greying out its
  -- active tab would also produce.
  function region:LockHighlight() self.highlightLocked = true return self end
  function region:UnlockHighlight() self.highlightLocked = false return self end

  -- The client's vocabulary for "you cannot use this". Recorded so the harness can
  -- assert it is NOT how the active tab gets marked, which is the defect 1.3 exists
  -- to correct; auto-stubbed, a panel that went back to greying its tabs out would
  -- pass every gate in this repo.
  -- Alpha and mouse: how the addon makes the client's experience bar stop being
  -- seen without calling anything the client protects (D48). Auto-stubbed, both
  -- returned self and recorded nothing, so a slot that quieted the wrong frame --
  -- or nothing at all -- would have looked exactly like one that worked.
  function region:SetAlpha(value) self.alpha = value return self end
  function region:GetAlpha() return self.alpha or 1 end
  function region:EnableMouse(value) self.mouseEnabled = value ~= false return self end
  function region:IsMouseEnabled() return self.mouseEnabled ~= false end

  -- The one thing SetAllPoints does that this harness cares about: the frame ends
  -- up the size of what it was anchored to. That IS the slot (D47) -- auto-stubbed
  -- it returned self, the inherited size never moved, and the bar could have
  -- "taken over" the client's bar without ever changing shape.
  -- Records the anchor and NOTHING else, the way the client behaves: the frame's
  -- own size is recomputed on the next layout pass, not in this call. A harness
  -- that copied the size here would hide exactly the bug it should catch -- a bar
  -- that measures ITSELF right after anchoring and paints one frame at the size
  -- it had before.
  function region:SetAllPoints(other)
    self.allPointsOf = other
    return self
  end

  -- Who draws on top. Auto-stubbed, the setters returned self and the getters
  -- answered with the frame itself, so the bar could take the client's slot at any
  -- depth at all -- including the one that paints over the client's own frame art.
  -- That is the defect a player photographed twice before the harness could say a
  -- word about it: the same setting looked inset one evening and covered the
  -- client's frame the next, because nothing in the addon ever stated a depth.
  -- Who a frame hangs from. Auto-stubbed, GetParent answered with the frame
  -- itself and every chain was one link long -- so the bar could not tell the
  -- client's experience bar apart from the frame that draws the art around it,
  -- which is the whole difference between sitting inside that art and covering it.
  function region:SetParent(parent) self.parent = parent return self end
  function region:GetParent() return self.parent end

  function region:SetFrameStrata(value) self.strata = value return self end
  function region:GetFrameStrata() return self.strata or "MEDIUM" end
  function region:SetFrameLevel(value) self.level = value return self end
  function region:GetFrameLevel() return self.level or 0 end

  function region:GetEffectiveScale() return self.scale or 1 end
  -- Recorded, so the conversion between the slot's points and this frame's is
  -- actually exercised: anchored frames at different scales cover the same screen
  -- area and that is a different number of points each.
  function region:SetScale(value) self.scale = value return self end

  -- How far the frame sits off the bottom of the screen. Auto-stubbed it answered
  -- with the frame itself, so the rule that decides which side the bar's text
  -- goes to could only ever take its unknown-room branch.
  function region:GetBottom() return self.bottom end

  function region:SetEnabled(enabled) self.enabled = enabled ~= false return self end
  function region:Enable() self.enabled = true return self end
  function region:Disable() self.enabled = false return self end

  -- Text, font and colour are recorded rather than swallowed by the catch-all
  -- above. Without this the whole empty-state surface and every skinned cell
  -- are invisible to the harness: SetText returns self and the string is gone,
  -- so a panel that printed the wrong message passed just as happily as one
  -- that printed the right one.
  function region:SetText(value) self.text = value return self end
  function region:GetText() return self.text end
  function region:SetFont(path, size, flags)
    self.font = { path = path, size = size, flags = flags }
    return self
  end
  function region:SetTextColor(r, g, b, a) self.textColor = { r, g, b, a } return self end
  function region:SetWordWrap(value) self.wordWrap = value return self end

  -- Anchors are recorded, not swallowed. Where a cell actually sits inside its
  -- row is the whole of "no line is drawn outside the frame", and until this
  -- existed there was no way to ask.
  function region:SetPoint(...) self.points[#self.points + 1] = { ... } return self end
  -- Clears the SetAllPoints anchor too, the way the client does. Without that the
  -- harness could not see a frame still pinned to the client's bar after leaving
  -- the slot -- which is exactly how it came back wearing the client's width.
  function region:ClearAllPoints()
    self.points = {}
    -- Letting go of the anchor KEEPS the size the frame had while it was held:
    -- a frame does not shrink back to anything when its points are cleared, it
    -- simply stops being told what to be. That is why a bar that was sized
    -- before its anchors were released comes back wearing the client's width --
    -- the size it was given went nowhere, and this is the size that stayed.
    if self.allPointsOf ~= nil then
      self.w, self.h = self.allPointsOf:GetWidth(), self.allPointsOf:GetHeight()
      self.allPointsOf = nil
    end
    return self
  end

  function region:CreateTexture()
    local texture = newRegion("Texture")
    self.children[#self.children + 1] = texture
    return texture
  end
  function region:CreateFontString()
    local fontString = newRegion("FontString")
    self.children[#self.children + 1] = fontString
    return fontString
  end
  function region:CreateAnimationGroup() return newRegion("AnimationGroup") end
  -- The size it was actually given, not a constant. Every column width in
  -- ui/RowList.lua is derived from one of these, so a stub that answers 400 to
  -- everything runs the whole layout against a number no player will ever have
  -- -- and the arithmetic that decides whether a cell fits inside its row has
  -- then never been exercised at all.
  -- An anchored frame ANSWERS with its anchor's size, computed on the way out
  -- rather than copied on the way in. Copying is what the SetAllPoints note above
  -- refuses to do, and for a good reason; answering is what the client does, and
  -- without it a frame that never let go of the client's bar still reports the
  -- size the player configured, and reads as correct.
  function region:GetWidth()
    if self.allPointsOf ~= nil then return self.allPointsOf:GetWidth() end
    return self.w or 400
  end
  function region:GetHeight()
    if self.allPointsOf ~= nil then return self.allPointsOf:GetHeight() end
    return self.h or 300
  end
  function region:GetStringWidth() return 120 end
  function region:GetFont()
    if self.font ~= nil then
      return self.font.path, self.font.size, self.font.flags
    end
    return DEFAULT_FONT, 11, ""
  end
  function region:GetName() return self.name end
  -- The anchor it was actually given, when it was given the five-argument form
  -- the panel uses. Without this every position read back is the same constant,
  -- and the off-screen clamp -- whose whole job is to change a saved x -- has
  -- nothing that can observe it.
  function region:GetPoint()
    local p = self.points[1]
    if p ~= nil and #p == 5 then
      return p[1], p[2], p[3], p[4], p[5]
    end
    return "CENTER", nil, "CENTER", 0, 0
  end
  function region:GetValue() return 1 end
  -- Honest, rather than always false. The client's checkbox template flips
  -- itself and THEN runs OnClick, so a handler reading GetChecked sees the state
  -- the player just chose; a stub that always said false could only ever
  -- exercise switching things off.
  function region:SetChecked(value) self.checked = value and true or false return self end
  function region:GetChecked() return self.checked == true end
  function region:IsShown() return self.shown == true end
  function region:Show() self.shown = true return self end
  function region:Hide() self.shown = false return self end
  function region:IsVisible() return self.shown == true end
  function region:SetScript(name, fn) self.scripts = self.scripts or {}; self.scripts[name] = fn return self end
  function region:GetScript(name) return self.scripts and self.scripts[name] end
  function region:RegisterEvent() return self end
  function region:UnregisterAllEvents() return self end

  return region
end

function CreateFrame(kind, name, parent, template)
  local frame = newRegion(kind or "Frame")
  frame.name = name
  frame.template = template
  if name ~= nil then
    _G[name] = frame
    -- Templates that declare $parent children expose them as globals. Model the
    -- handful this addon reads back, so a missing one is a nil index here just
    -- as it would be in the client.
    for _, suffix in ipairs({ "Text", "Low", "High", "ScrollBar" }) do
      _G[name .. suffix] = newRegion("Region")
    end
  end
  frames[#frames + 1] = frame
  return frame
end

UIParent = newRegion("Frame")
GameTooltip = newRegion("GameTooltip")
-- The tooltip REMEMBERS what it was told. Left as an auto-stub, every AddLine and
-- AddDoubleLine returned self and recorded nothing, so the hover popup could only
-- ever be tested for "did not raise" -- which is exactly how the bar went on saying
-- nothing about a partial record while the panel said it. SetOwner clears, the way
-- the client's does, so each hover is read on its own.
-- The dropdown family, modelled rather than auto-stubbed. Auto-stubbed, the
-- options panel's probe would have found all five "present" and then built a
-- control whose entries nobody could count -- the harness would have walked the
-- dropdown path and been unable to tell it from the button it replaces.
local initialising
UIDropDownMenu_CreateInfo = function() return {} end
UIDropDownMenu_AddButton = function(info)
  if initialising ~= nil then
    initialising.entries[#initialising.entries + 1] = info
  end
end
UIDropDownMenu_Initialize = function(frame, initializer)
  frame.initializer, frame.entries = initializer, {}
  initialising = frame
  initializer(frame)
  initialising = nil
end
UIDropDownMenu_SetWidth = function(frame, width) frame.dropdownWidth = width end
UIDropDownMenu_SetText = function(frame, text) frame.dropdownText = text end

GameTooltip.lines = {}

-- The client's default placement. Recorded rather than stubbed away: the point
-- of calling it is that the tooltip lands where the PLAYER put their tooltips,
-- and a harness that swallowed the call could not tell that apart from a bar
-- that anchored the tooltip to itself.
GameTooltip_SetDefaultAnchor = function(tooltip, owner)
  tooltip.defaultAnchored, tooltip.owner, tooltip.lines = true, owner, {}
end
function GameTooltip:SetOwner(owner) self.owner, self.lines = owner, {} return self end
function GameTooltip:ClearLines() self.lines = {} return self end
function GameTooltip:AddLine(text) self.lines[#self.lines + 1] = { left = text } return self end
function GameTooltip:AddDoubleLine(left, right)
  self.lines[#self.lines + 1] = { left = left, right = right }
  return self
end
SlashCmdList = {}
UnitXP = function() return 0 end
UnitXPMax = function() return 1000 end
UnitLevel = function() return 23 end
UnitName = function() return "Tester" end
UnitGUID = function() return "Player-1-00000000" end
UnitClass = function() return "Warrior", "WARRIOR", 1 end
UnitRace = function() return "Human", "Human", 1 end
UnitHealth = function() return 100 end
UnitHealthMax = function() return 100 end
UnitPower = function() return 50 end
UnitPowerMax = function() return 100 end
UnitFactionGroup = function() return "Alliance" end
UnitExists = function() return false end
GetXPExhaustion = function() return nil end
GetRestState = function() return 1, "Normal", 1 end
IsResting = function() return false end
IsXPUserDisabled = function() return false end
GetMaxPlayerLevel = function() return 70 end

-- The client's own experience bar and the pieces around it, thin and wide the way
-- the real one is. Present before the addon loads because the capability probe
-- runs inside the composition root, not after it.
-- Hung off the main bar the way the client hangs it, because that relationship is
-- load-bearing: the addon makes the experience bar itself invisible, so the art
-- that still draws in that strip -- the divisions along it, the caps at its ends --
-- belongs to this parent and outlives the quieting. A chain one link long cannot
-- express that, and a bar that goes one level under the ANCHOR lands level with
-- the parent instead of under it.
MainMenuBar = newRegion("Frame")
MainMenuBar:SetSize(1024, 53)
MainMenuBar:SetFrameLevel(2)
MainMenuExpBar = newRegion("StatusBar")
MainMenuExpBar:SetSize(1024, 10)
MainMenuExpBar:SetParent(MainMenuBar)
MainMenuBarExpText = newRegion("FontString")
ExhaustionTick = newRegion("Frame")
ExhaustionLevelFillBar = newRegion("Texture")
MainMenuXPBarTextureLeftCap = newRegion("Texture")
MainMenuXPBarTextureRightCap = newRegion("Texture")
MainMenuXPBarTextureMid = newRegion("Texture")
GetTime = function() return 1000 end
time = os.time
date = os.date
difftime = os.difftime
RequestTimePlayed = function() end
GetRealmName = function() return "Spineshatter" end
GetZoneText = function() return "Elwynn Forest" end
GetSubZoneText = function() return "" end
GetInstanceInfo = function() return "none", "none" end
IsInInstance = function() return false, "none" end
IsInGroup = function() return false end
IsInRaid = function() return false end
GetNumGroupMembers = function() return 0 end
-- One accepted quest, so the sweep has something to read. Naming used to be
-- stubbed out here, which meant the whole path from GetQuestLogTitle to a row in
-- the panel was dead code as far as every gate in this repo could tell.
local QUEST_LOG = {
  { title = "Wanted: Hogger", level = 10, questId = 1234, isComplete = true, objectives = {
    { text = "Riverpaw Mongrel slain: 3/6", kind = "monster" },
    { text = "Hogger's Head: 0/1", kind = "item" },
  } },
}
-- The client's own sentence for a kill objective. Absent here until the sweep
-- started reading objectives, and its absence hid a load-order bug that would
-- have broken the addon on the first sweep in a real client.
QUEST_MONSTERS_KILLED = "%s slain: %d/%d"
GetNumQuestLeaderBoards = function(index)
  local entry = QUEST_LOG[index]
  return entry and entry.objectives and #entry.objectives or 0
end
GetQuestLogLeaderBoard = function(objectiveIndex, index)
  local entry = QUEST_LOG[index]
  local objective = entry and entry.objectives and entry.objectives[objectiveIndex]
  if objective == nil then return nil end
  return objective.text, objective.kind, false
end
GetNumQuestLogEntries = function() return #QUEST_LOG, #QUEST_LOG end
GetQuestLogTitle = function(index)
  local entry = QUEST_LOG[index]
  if entry == nil then return nil end
  return entry.title, entry.level, nil, nil, false, false, entry.isComplete, entry.questId
end
SelectQuestLogEntry = function() end
GetQuestLogSelection = function() return 0 end
GetQuestLogRewardXP = function() return 0 end
GetSpellInfo = function() return "Spell" end
GetSpellTexture = function() return "Interface\\Icons\\INV_Misc_QuestionMark" end
GetLocale = function() return "enUS" end
GetCVarBool = function() return false end
C_Timer = { After = function() end, NewTicker = function() return { Cancel = function() end } end }
C_CombatLog = { GetCurrentEventInfo = function() end }
CombatLogGetCurrentEventInfo = function() end
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
GetAddOnMetadata = function() return "0.1.0" end
-- Kept as well as printed. The composition root has no busted spec and cannot get
-- one -- CreateFrame runs at its file scope -- so what it prints is the only
-- surface its diagnostics can be asserted through.
local chatLines = {}
DEFAULT_CHAT_FRAME = {
  AddMessage = function(_, text)
    chatLines[#chatLines + 1] = tostring(text)
    print("  [chat] " .. tostring(text))
  end,
}
InterfaceOptions_AddCategory = function() end
-- Recorded rather than swallowed: the panel's shortcut into the settings is a
-- button whose whole job is to reach one of these, and a stub that returns
-- nothing cannot tell "it opened the options" from "it did nothing at all".
OPENED_OPTIONS = 0
InterfaceOptionsFrame_OpenToCategory = function() OPENED_OPTIONS = OPENED_OPTIONS + 1 end
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
Mixin = function(target) return target end
-- The colour picker, modelled closely enough to tell confirming from
-- cancelling. The options panel cannot ask the client whether the player
-- pressed Okay -- neither flavour has a callback for it -- so it infers the
-- answer from the frame hiding without cancelFunc having run
-- (ui/OptionsPanel.lua). That makes OnHide load-bearing, so this stub actually
-- fires it, and HookScript actually records a handler.
local pickerConfirms = false
ColorPickerFrame = {
  hooks = {},
  GetColorRGB = function() return 0.5, 0.25, 0.75 end,
  SetColorRGB = function() end,
  Show = function() end,
  HookScript = function(self, name, fn)
    self.hooks[name] = self.hooks[name] or {}
    self.hooks[name][#self.hooks[name] + 1] = fn
  end,
  Hide = function(self)
    for _, fn in ipairs(self.hooks.OnHide or {}) do fn(self) end
  end,
  SetupColorPickerAndShow = function(self, options)
    if options.swatchFunc then options.swatchFunc() end
    -- Alternating, so one smoke run walks both endings: a cancelled pick that
    -- must leave nothing behind, and a confirmed one that must write exactly
    -- once. Cancel first, because that is the path a bug hides in.
    if not pickerConfirms and options.cancelFunc then options.cancelFunc() end
    pickerConfirms = not pickerConfirms
    self:Hide()
  end,
}
Constants = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 0 end }) end })
Enum = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 0 end }) end })
ChatFrameUtil = { AddMessageEventFilter = function() end, RemoveMessageEventFilter = function() end }
ChatFrame_DisplayTimePlayed = function() end
C_Map = { GetBestMapForUnit = function() return 1 end }
C_Seasons = { GetActiveSeason = function() return 0 end }
C_GameRules = {}
C_Spell = {}
securecall = function(fn, ...) return fn(...) end
tContains = function() return false end
InCombatLockdown = function() return false end
PlaySound = function() end
geterrorhandler = function() return function(err) error(err, 0) end end
issecurevariable = function() return true end
hooksecurefunc = function() end
strsplit = function(sep, str) local out = {} for piece in str:gmatch("[^" .. sep .. "]+") do out[#out+1] = piece end return unpack(out) end
strtrim = function(str) return (str:gsub("^%s+", ""):gsub("%s+$", "")) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
-- The client's list of frames Escape closes. A window that appends itself to it
-- indexes a global that has to exist -- in the client it always does.
UISpecialFrames = {}
tremove = table.remove
format = string.format
floor = math.floor
max = math.max
min = math.min

-- NOT an empty installation, and that is the point. Every run of this harness
-- used to boot from nothing, so every path that depends on settings a player
-- already has was exercised only AFTER construction -- through applySettings,
-- where the frames exist. The construction path with real settings had no
-- coverage at all, and it is the one that fails hardest: a throw there costs the
-- bar, the panel AND the options category, which is how an addon that was
-- recording perfectly looked completely absent.
--
-- The skin is the trigger and is chosen deliberately: cartographer puts its text
-- BELOW the bar, which is the branch that asks how much room is under a frame
-- that the constructor has not made yet.
AscentDB = {
  settings = {
    bar_skin = "cartographer",
    high_contrast = true,
    bar_colors = {
      -- Saved by the client's colour picker, which writes r/g/b and no alpha.
      -- Every reader has to complete it, and this is the only place that says so.
      UNKNOWN = { r = 0, g = 0, b = 0 },
    },
  },
}
AscentCharDB = nil

-- Load every file the TOC declares, in TOC order, exactly as the client would.
local toc = assert(io.open(ROOT .. "/Ascent.toc"))
local files = {}
for line in toc:lines() do
  line = line:gsub("\r", ""):gsub("%s+$", "")
  if line ~= "" and not line:match("^#") and line:match("%.lua$") then
    files[#files + 1] = line
  end
end
toc:close()

local ns = {}
print(("loading %d files from the TOC"):format(#files))
for _, relative in ipairs(files) do
  local path = ROOT .. "/" .. relative
  local chunk, err = loadfile(path)
  if chunk == nil then
    print("SYNTAX ERROR in " .. relative .. ": " .. tostring(err))
    os.exit(1)
  end
  local ok, loadErr = pcall(chunk, "Ascent", ns)
  if not ok then
    print("LOAD ERROR in " .. relative .. ": " .. tostring(loadErr))
    os.exit(1)
  end
end
print("all files loaded")

-- Now fire ADDON_LOADED, which is what runs the composition root.
local fired = false
for _, frame in ipairs(frames) do
  local handler = frame.scripts and frame.scripts.OnEvent
  if handler ~= nil then
    fired = true
    local ok, err = pcall(handler, frame, "ADDON_LOADED", "Ascent")
    if not ok then
      print("BOOTSTRAP ERROR: " .. tostring(err))
      os.exit(1)
    end
  end
end

if not fired then
  print("no OnEvent handler was registered -- the loader never ran")
  os.exit(1)
end

print("bootstrap completed without raising")

-- Beyond loading: actually drive the thing. Every step below is something the
-- player does in the first minute, and each one is a path no unit test touches.
local context = ns.app and ns.app.context
if context == nil then
  print("no context was published")
  os.exit(1)
end

local failures = 0
local function step(what, fn)
  local ok, err = pcall(fn)
  if ok then
    print("  ok   " .. what)
  else
    failures = failures + 1
    print("  FAIL " .. what .. ": " .. tostring(err))
  end
end

local bar, panel = context.bar, context.panel
if bar == nil or panel == nil then
  print("the views were not built")
  os.exit(1)
end

step("bar tick while idle", function() bar:tick(0.016) end)

local demo = nil
for _, frame in ipairs(frames) do end
step("demo drives every visual state", function()
  local handler = SlashCmdList["ASCENT"]
  for _ = 1, 13 do handler("demo") end
  handler("demo off")
end)

step("bar animates towards its target", function()
  for _ = 1, 40 do bar:tick(0.016) end
end)

-- The panel reads the LIVE record, not the demo's, so without this every row the
-- per-place block draws would go unexecuted while the harness reported the tab
-- green. That block is the newest drawing code in the addon and the one most
-- likely to read a frozen table with a key it does not have, which is the exact
-- failure this harness exists to catch.
step("the level in progress has places to draw", function()
  local record = context.tracker:current()
  if record == nil then
    error("no level in progress to seed")
  end
  local PlaceKey, PlaceContext, XpSource = ns.core.PlaceKey, ns.core.PlaceContext, ns.core.XpSource
  -- TWO sources in one place, deliberately: with a single source, a popup that
  -- nests place under source and one that lists places on their own look
  -- identical, and the assertion below could not tell them apart.
  local chasm = record:placeEntry(PlaceKey.new(PlaceContext.DUNGEON, 389, "Ragefire Chasm"))
  chasm.xpTotal, chasm.seconds = 1200, 1800
  chasm.xpBySource[XpSource.MOB_KILL] = 900
  chasm.xpBySource[XpSource.QUEST_TURNIN] = 300
  -- Time and nothing else: the row whose whole content is the time it cost.
  record:placeEntry(PlaceKey.new(PlaceContext.WORLD, 1433, "Westfall")).seconds = 300
  -- And the reserved entry, whose name is deliberately absent.
  local nowhere = record:placeEntry(PlaceKey.unknown())
  nowhere.xpTotal = 100
  nowhere.xpBySource[XpSource.UNKNOWN] = 100
  record.xpTotal = record.xpTotal + 1300
  record.xpBySource[XpSource.MOB_KILL] = record.xpBySource[XpSource.MOB_KILL] + 900
  record.xpBySource[XpSource.QUEST_TURNIN] = (record.xpBySource[XpSource.QUEST_TURNIN] or 0) + 300
  record.xpBySource[XpSource.UNKNOWN] = record.xpBySource[XpSource.UNKNOWN] + 100
end)

-- The bar's half of "say what you did not see" (visual 1.5). Asserted, not merely
-- survived: the popup is read back line by line.
step("the popup separates what was never watched from what went unattributed", function()
  local LevelRecord, XpLedger, XpGain = ns.core.LevelRecord, ns.core.XpLedger, ns.core.XpGain
  local XpSource, TextKey = ns.core.XpSource, ns.core.TextKey

  local function hover(record)
    bar:update(record, {})
    local onEnter = bar.frame.scripts and bar.frame.scripts.OnEnter
    if onEnter == nil then
      error("the bar registered no OnEnter, so the popup can never be shown")
    end
    onEnter()
    return GameTooltip.lines
  end

  local function find(lines, key)
    local wanted = context.locale:get(key)
    for _, line in ipairs(lines) do
      if line.left == wanted then return line end
    end
    return nil
  end

  -- The 2026-09-17 session: a level joined at 8632, of which 184 more went
  -- unclaimed later. Both sit in UNKNOWN and neither is legible without the split.
  local seeded = LevelRecord.new(35, 1700000000)
  seeded.xpRequired = 54017
  XpLedger.post(seeded, XpGain.new({ amount = 8816, source = XpSource.UNKNOWN, at = 1 }))
  XpLedger.post(seeded, XpGain.new({ amount = 12918, source = XpSource.MOB_KILL, at = 2 }))
  seeded.partial, seeded.seededXp = true, 8632

  local lines = hover(seeded)
  local notObserved = find(lines, TextKey.BAR_NOT_OBSERVED)
  local unexplained = find(lines, TextKey.BAR_UNEXPLAINED)
  if notObserved == nil then
    error("the popup never said how much of the level it did not observe")
  end
  if notObserved.right ~= "8632" then
    error("expected 8632 unobserved, popup said " .. tostring(notObserved.right))
  end
  if unexplained == nil or unexplained.right ~= "184" then
    error("expected 184 unattributed, popup said " .. tostring(unexplained and unexplained.right))
  end

  -- And the figures the requirement says must not move.
  local unknownLine
  local unclassified = context.locale:get(TextKey.BAR_TOOLTIP_PLACE,
    context.locale:get(TextKey.SOURCE_UNCLASSIFIED))
  for _, line in ipairs(lines) do
    if line.left == unclassified then unknownLine = line end
  end
  if unknownLine == nil or not tostring(unknownLine.right):match("^8816") then
    error("the unclassified line changed: " .. tostring(unknownLine and unknownLine.right))
  end

  -- A record from before the addon kept the figure says it is partial and no more.
  seeded.seededXp = nil
  lines = hover(seeded)
  if find(lines, TextKey.BAR_PARTIAL) == nil then
    error("a partial record with no seed figure said nothing at all")
  end
  if find(lines, TextKey.BAR_NOT_OBSERVED) ~= nil then
    error("it invented a split it had no figure for")
  end

  -- And a level watched throughout reserves no room for any of it.
  local whole = LevelRecord.new(35, 1700000000)
  whole.xpRequired = 54017
  XpLedger.post(whole, XpGain.new({ amount = 500, source = XpSource.MOB_KILL, at = 1 }))

  lines = hover(whole)
  for _, key in ipairs({ TextKey.BAR_PARTIAL, TextKey.BAR_NOT_OBSERVED, TextKey.BAR_UNEXPLAINED }) do
    if find(lines, key) ~= nil then
      error("a fully watched level still made room for the partial mark")
    end
  end
end)

step("panel opens", function() panel:open() end)
for _, tab in ipairs({ "breakdown", "combat", "abilities", "pending", "history" }) do
  step("panel tab: " .. tab, function() panel:selectTab(tab) end)
end
-- Not decoration: without it the step above passes whether or not the block was
-- reached, and "the tab did not raise" is exactly the reassurance that let this
-- go unnoticed the first time.
step("the breakdown tab really drew the per-place block", function()
  local breakdown = panel.lastViewModel and panel.lastViewModel.breakdown
  if breakdown == nil or breakdown.places == nil or #breakdown.places == 0 then
    error("the panel rendered the sources tab without any place rows")
  end
end)

-- The shortcut the player asked for: from the surface they are looking at into
-- the settings, without a slash command. Asserted through the click, not by
-- reading the button's existence -- a button that is there and wired to nothing
-- is the failure worth catching.
step("the panel has a shortcut into the settings, and it opens them", function()
  local button = panel.optionsButton
  if button == nil then
    error("the panel has no way into the settings")
  end
  if button.text ~= "Options" then
    error(("the shortcut is labelled %q"):format(tostring(button.text)))
  end

  -- Counted as "more than none", not as an exact number: the legacy path this
  -- harness falls to opens twice on purpose (Blizzard's own long-standing
  -- workaround, see openOptionsPanel), and pinning the count here would make the
  -- step fail the day a client offers the modern path instead.
  local before = OPENED_OPTIONS
  button.scripts.OnEnter(button)
  button.scripts.OnClick(button)
  button.scripts.OnLeave(button)
  if OPENED_OPTIONS <= before then
    error("clicking the shortcut did not open the settings")
  end
end)

step("panel refresh", function() panel:refresh() end)
step("panel closes", function() panel:close() end)

-- ---------------------------------------------------------------------------
-- Group 6: the halves of the panel's tasks that do NOT need a running client.
--
-- Every assertion below was a claim in the plan before it was a line here. The
-- panel had no test of any kind -- ui/ still has no busted spec -- so a tab that
-- drew its text on top of its own icon, an empty state that could not be
-- reached and a selector that never left its own tab all passed every gate this
-- repo runs. "It did not raise" is not the same sentence as "it is right".
-- ---------------------------------------------------------------------------

local TABS_IN_ORDER = { "breakdown", "combat", "abilities", "pending", "history" }

-- Where a cell actually sits in its row: the x offset of its LEFT anchor, which
-- is what ui/RowList.lua's layoutCells sets.
local function cellLeft(cell)
  local point = cell.points and cell.points[1]
  return point and point[4] or nil
end

-- Every string a list is currently drawing, flattened. Reading the text back is
-- the difference between "the tab rendered" and "the tab rendered the right
-- thing", and until the stand-in recorded SetText there was no way to ask.
local function textsOf(list)
  local texts = {}
  for _, row in ipairs(list.rows) do
    if row.shown then
      for _, cell in ipairs(row.cells) do
        if cell.text ~= nil and cell.text ~= "" then texts[#texts + 1] = cell.text end
      end
    end
  end
  return texts
end

local function drawn(list, needle)
  for _, text in ipairs(textsOf(list)) do
    if text:find(needle, 1, true) then return true end
  end
  return false
end

-- Every tab needs rows before any of this means anything. Four of the five drew
-- nothing at all until this step existed, so the checks below were passing over
-- empty lists -- which is the quiet way a suite reports coverage it does not
-- have.
step("every tab has something to draw", function()
  local record = context.tracker:current()
  local MetricId, AbilityUsage = ns.core.MetricId, ns.core.AbilityUsage

  -- Abilities: a spell, which asks the client for an icon, and an auto attack,
  -- which deliberately does not.
  local fireball = AbilityUsage.new(133, "Fireball")
  fireball.count = 12
  record.abilities[133] = fireball
  local swings = AbilityUsage.new(ns.core.AbilityKey.MELEE_SWING, nil)
  swings.count = 40
  record.abilities[ns.core.AbilityKey.MELEE_SWING] = swings

  -- Top quests: seeded straight into the aggregates, the way the abilities above
  -- are, so the breakdown has quest rows at all. One the addon saw named, one it
  -- never could -- the two halves the rows have to tell apart.
  record.quests[1234] = { questId = 1234, turnIns = 1, xpTotal = 950, name = "Wanted: Hogger" }
  record.quests[5678] = { questId = 5678, turnIns = 2, xpTotal = 400 }

  -- A killed creature on the live record, seeded into the aggregate the way the
  -- quests below are rather than posted as a gain: this level is nearly full, and
  -- posting would fill it and ask the harness for the next one. Two kills at 42
  -- give the objectives below an average of this creature's own.
  local lynx = ns.core.CreatureKey.new(15343, 6, "Springpaw Lynx")
  record.creatures[lynx:id()] = { key = lynx, kills = 2, xpTotal = 84 }
  -- The level's own per-kill average needs a count of kills that paid; without
  -- one there is no fallback rate at all, and the marked-estimate path below
  -- would go unexercised while the step still passed.
  record.killsWithXp = record.killsWithXp + 2

  -- Top quests: seeded into the aggregates the way the abilities above are. 1234
  -- is the quest the stand-in log holds, so the directory can name it; 5678 was
  -- turned in by someone this addon never watched, and has only its number.
  record.quests[1234] = { questId = 1234, turnIns = 1, xpTotal = 950 }
  record.quests[5678] = { questId = 5678, turnIns = 2, xpTotal = 400 }

  -- Combat: `hasData` is combat seconds or deaths, and without either the tab
  -- renders its empty state and no rows.
  record.metrics[MetricId.TIME] = { combatSeconds = 600, recoverySeconds = 120 }
  record.metrics[MetricId.DEATHS] = { count = 2, timeLostToDeath = 90 }
  record.metrics[MetricId.DAMAGE] = { dealt = 40000, taken = 12000, healingReceived = 3000 }

  -- Pending: quest-log-wide, so it comes from the forecast service rather than
  -- the record. Standing in for it is the only way to reach these rows without
  -- a quest log.
  local forecast = panel.questForecastService
  -- One real sweep, which is what fills the name directory: the composition root
  -- wires the sweep to it, and nothing below can tell whether that wiring exists.
  forecast:markDirty()
  forecast:tick()
  forecast.report = function()
    return { total = 5200, readyTotal = 1200, unknownCount = 1 }
  end
  forecast.entries = function()
    return {
      { questId = 1234, questLevel = 22, reward = 1200, adjustedReward = 1200,
        title = "Wanted: Hogger", origin = ns.core.QuestXpOrigin.CLIENT, complete = true,
        objectives = {
          ns.core.QuestObjective.new({ creature = "Springpaw Lynx", done = 3, needed = 6 }),
          ns.core.QuestObjective.new({ creature = "Wretched Thug", done = 0, needed = 4 }),
        } },
      { questId = 5678, questLevel = 24, reward = 4000, adjustedReward = 4000,
        origin = ns.core.QuestXpOrigin.LEARNED, complete = false },
      { questId = 2001, questLevel = 24, reward = 300, adjustedReward = 300,
        origin = ns.core.QuestXpOrigin.CLIENT, complete = false },
      { questId = 2002, questLevel = 24, reward = 200, adjustedReward = 200,
        origin = ns.core.QuestXpOrigin.CLIENT, complete = false },
      { questId = 2003, questLevel = 24, reward = 200, adjustedReward = 200,
        origin = ns.core.QuestXpOrigin.CLIENT, complete = false },
      { questId = 9012, questLevel = 25, reward = nil, adjustedReward = nil,
        origin = ns.core.QuestXpOrigin.UNKNOWN, complete = false },
    }
  end

  -- History: two completed levels with a GAP between them, which is the case
  -- the comparison used to get wrong by asking for `selected - 1`.
  local LevelRecord, XpSource = ns.core.LevelRecord, ns.core.XpSource
  for _, spec in ipairs({ { level = 12, xp = 9000 }, { level = 15, xp = 11000 } }) do
    local past = LevelRecord.new(spec.level, 0)
    past.xpRequired = spec.xp
    past.xpBySource[XpSource.QUEST_TURNIN] = spec.xp
    past.xpTotal = spec.xp
    past.playedSeconds = 3000 + spec.level
    past.completedAt = spec.level
    context.store:saveCompleted(past)
  end

  panel:markDirty()
  panel:open()
  for _, tabId in ipairs(TABS_IN_ORDER) do
    panel:selectTab(tabId)
    local visible = 0
    for _, row in ipairs(panel.lists[tabId].rows) do
      if row.shown then visible = visible + 1 end
    end
    if visible == 0 then
      error(("tab %s still draws no rows, so nothing below actually checks it"):format(tabId))
    end
    print(("    %s: %d rows"):format(tabId, visible))
  end
end)

-- 6.5: the defect the note named. The name used to start at LEFT+6 while the
-- icon occupied LEFT+2 to LEFT+16, so every row whose icon resolved drew its
-- text across it.
step("a row's text starts clear of its icon, whether or not the icon resolved", function()
  panel:selectTab("abilities")
  local list = panel.lists.abilities
  local withIcon, seen, first = 0, 0, nil
  for _, row in ipairs(list.rows) do
    if row.shown then
      if row.icon.shown then withIcon = withIcon + 1 end
      local left = cellLeft(row.cells[1])
      if left == nil then error("a visible row has a cell with no anchor") end
      if left < 2 + 14 then
        error(("the first cell starts at %d, inside the icon that ends at %d"):format(left, 16))
      end
      -- One starting x for the whole list: a row whose icon did not resolve must
      -- not slide left, or a missing icon reads as a different kind of row.
      first = first or left
      if left ~= first then
        error(("rows in one list start at different x: %s and %s"):format(tostring(first), tostring(left)))
      end
      seen = seen + 1
    end
  end
  if withIcon == 0 then error("no row drew an icon, so the icon path is unexercised") end
  if seen == 0 then error("no visible rows to measure") end
  if panel.lists.abilities.indent <= 0 then error("the abilities list reserved no room for its icons") end
  if panel.lists.breakdown.indent ~= 0 then error("a list that never shows an icon is indenting anyway") end
end)

-- 6.3: the scenario is "ninguna fila se dibuja fuera del marco". Until the
-- stand-in returned the width it had actually been given, every column in the
-- addon had only ever been laid out against a constant.
-- 1.2: the list inside the FRAME. assertFits below checks a cell inside its row,
-- which is a different containment entirely and cannot see a list hanging past the
-- panel's bottom edge -- the list is anchored 66 below the top and sized from the
-- frame's height, and until now nothing tied those two numbers to each other.
local LIST_TOP_INSET = 66

local function assertListWithinFrame(where)
  local frameHeight = panel.frame.h
  for _, tabId in ipairs(TABS_IN_ORDER) do
    local bottom = LIST_TOP_INSET + (panel.lists[tabId].scroll.h or 0)
    if bottom > frameHeight then
      error(("%s: the %s list ends %d past the panel's bottom edge (%d inside %d)")
        :format(where, tabId, bottom - frameHeight, bottom, frameHeight))
    end
  end
end

local function assertFits(where)
  local checked = 0
  for _, tabId in ipairs(TABS_IN_ORDER) do
    panel:selectTab(tabId)
    local list = panel.lists[tabId]
    local width = list.scroll.w
    if type(width) ~= "number" or width <= 0 then
      error(("list %s has no width to lay out against (%s)"):format(tabId, tostring(width)))
    end
    local rows = 0
    for rowIndex, row in ipairs(list.rows) do
      if row.shown then
        rows = rows + 1
        local previousRight
        for column, cell in ipairs(row.cells) do
          local left, cellWidth = cellLeft(cell), cell.w
          if left == nil or cellWidth == nil then
            error(("%s row %d cell %d was never laid out"):format(tabId, rowIndex, column))
          end
          if left + cellWidth > width + 0.5 then
            error(("%s (%s) row %d cell %d ends at %.1f, past the row's %d"):format(
              tabId, where, rowIndex, column, left + cellWidth, width))
          end
          if previousRight ~= nil and left + 0.5 < previousRight then
            error(("%s (%s) row %d cell %d starts at %.1f, inside the cell before it"):format(
              tabId, where, rowIndex, column, left))
          end
          previousRight = left + cellWidth
          if cell.wordWrap ~= false then
            error(("%s row %d cell %d can still wrap, so a long name draws over the row below"):format(
              tabId, rowIndex, column))
          end
        end
      end
    end
    if rows == 0 then
      error(("%s (%s) drew no rows, so its columns were never checked"):format(tabId, where))
    end
    checked = checked + rows
  end
  return checked
end

step("no cell is drawn past the edge of its row, and none overlaps the next", function()
  if assertFits("default size") == 0 then error("nothing was checked") end
end)

-- The same, at the narrowest the panel can actually be: applySavedPosition
-- floors the frame at MIN_WIDTH and layoutLists takes 44 off that, so 256 is
-- the tightest width any column set is ever laid out against.
step("the columns still fit at the narrowest the panel can be dragged to", function()
  local SettingKey = ns.core.SettingKey
  local saved = context.settings()[SettingKey.PANEL_POSITION]
  local restore = { point = saved.point, x = saved.x, y = saved.y, width = saved.width, height = saved.height }

  context.saveSetting(SettingKey.PANEL_POSITION, { point = "CENTER", x = 0, y = 0, width = 1, height = 1 })
  -- The frame itself, which is the only thing that shows applySavedPosition did the
  -- clamping. The list width below cannot: layoutLists floors at MIN_WIDTH on its
  -- own, so its 256 comes out the same whether or not the saved size was sanitised
  -- -- a step that looked like it covered this and never did.
  if panel.frame.w ~= 300 or panel.frame.h ~= 240 then
    error(("a degenerate saved size survived being applied: %sx%s")
      :format(tostring(panel.frame.w), tostring(panel.frame.h)))
  end
  if panel.lists.breakdown.scroll.w ~= 256 then
    error("the panel did not land on its floor: " .. tostring(panel.lists.breakdown.scroll.w))
  end
  -- 1.2: the list inside the FRAME, not just a cell inside its row. assertFits only
  -- ever checked the latter, so nothing held the list to the panel's own height.
  assertListWithinFrame("minimum size")
  assertFits("minimum size")
  context.saveSetting(SettingKey.PANEL_POSITION, restore)
end)

-- 1.3: the active tab has to read as "you are here", never as "not available".
step("exactly one tab reads as selected, and none reads as unavailable", function()
  for _, tabId in ipairs(TABS_IN_ORDER) do
    panel:selectTab(tabId)

    local locked = {}
    for _, other in ipairs(TABS_IN_ORDER) do
      local button = panel.tabButtons[other]
      if button.highlightLocked then locked[#locked + 1] = other end
      if button.enabled == false then
        error(("with %s active, the %s tab was disabled -- the client's way of saying " ..
               "\"you cannot use this\", which is the opposite of what a tab means")
          :format(tabId, other))
      end
    end

    if #locked ~= 1 then
      error(("with %s active, %d tab(s) read as selected: %s")
        :format(tabId, #locked, #locked > 0 and table.concat(locked, ", ") or "none"))
    end
    if locked[1] ~= tabId then
      error(("with %s active, the marked tab was %s"):format(tabId, locked[1]))
    end
  end
end)

-- 6.9: four value equalities between the bar and the panel, none of which any
-- gate in this repo could see before.
step("the panel's border follows the skin's kind and thickness, like the bar's", function()
  local SettingKey = ns.core.SettingKey
  context.saveSetting(SettingKey.BAR_SKIN, "stormwind") -- a three-pixel FRAME border
  local horizontal, vertical = panel.edges[1], panel.edges[3]
  if horizontal.h ~= 3 or vertical.w ~= 3 then
    error(("the panel drew a %s/%s border where the skin asked for 3"):format(
      tostring(horizontal.h), tostring(vertical.w)))
  end

  context.saveSetting(SettingKey.BAR_SKIN, "tabard")
  context.saveSetting(SettingKey.BAR_APPEARANCE, { border = { kind = ns.core.BorderKind.NONE } })
  for index, edge in ipairs(panel.edges) do
    if edge.shown ~= false then
      error(("edge %d is still drawn after the player turned the border off"):format(index))
    end
  end

  -- And back: a border turned off and on again has to return, which is the half
  -- a hide-only check cannot see.
  context.saveSetting(SettingKey.BAR_APPEARANCE, {})
  for index, edge in ipairs(panel.edges) do
    if edge.shown ~= true then
      error(("edge %d never came back after the border was turned on again"):format(index))
    end
  end
  if panel.edges[1].h ~= 1 then
    error("the restored border did not take the skin's thickness")
  end
end)

step("a heavy skin reaches every part of the panel as a heavy face, in the skin's colour", function()
  local SettingKey = ns.core.SettingKey
  context.saveSetting(SettingKey.BAR_SKIN, "stormwind") -- TextStyle.HEAVY
  panel:markDirty()
  panel:refresh()
  panel:selectTab("breakdown")

  local expected = panel.appearance.text.color
  local function sameColor(painted, what)
    if painted == nil then error(what .. " was never given a colour") end
    for index, channel in ipairs({ expected.r, expected.g, expected.b }) do
      if math.abs(painted[index] - channel) > 0.001 then
        error(("%s is painted in a colour the skin never asked for"):format(what))
      end
    end
  end

  local checked = 0
  for _, row in ipairs(panel.lists.breakdown.rows) do
    if row.shown then
      for column, cell in ipairs(row.cells) do
        if cell.font == nil or cell.font.flags ~= "THICKOUTLINE" then
          error(("a cell came out as %s where the skin asked for THICKOUTLINE"):format(
            cell.font and tostring(cell.font.flags) or "unstyled"))
        end
        -- Column one may carry a source's own colour; the rest must be the
        -- skin's text colour and not an off-white constant.
        if column > 1 then
          sameColor(cell.textColor, "a cell")
          checked = checked + 1
        end
      end
    end
  end
  if checked == 0 then error("no cells were checked") end

  -- The panel's own furniture, which was the other half of 6.9's note and which
  -- nothing here could see until the stand-in recorded SetFont.
  if panel.title.font == nil or panel.title.font.flags ~= "THICKOUTLINE" then
    error("the panel title is still wearing the client's own font")
  end
  sameColor(panel.title.textColor, "the panel title")
  local tab = panel.tabButtons.breakdown
  if tab.font == nil or tab.font.flags ~= "THICKOUTLINE" then
    error("the tab buttons are still wearing the client's own font")
  end

  context.saveSetting(SettingKey.BAR_SKIN, "tabard")
end)

-- 6.6: the first-run message was unreachable, so a fresh install was told it
-- was at the maximum level. Driven through the view's own seams, which is what
-- they are there for.
step("each way of having no level to show gets its own sentence", function()
  local TextKey = ns.core.TextKey
  local currentRecord, completedLevels, atCap = panel.currentRecord, panel.completedLevels, panel.atCap
  local function state(recordFn, levels, capped)
    panel.currentRecord, panel.completedLevels, panel.atCap = recordFn, levels, capped
    panel.selectedLevel, panel.selectedRecord, panel.selectedRecordLevel = nil, nil, nil
    panel:selectTab("breakdown")
    panel:markDirty()
    panel:refresh()
    return panel.empty.text
  end

  local fresh = state(function() return nil end, function() return {} end, function() return false end)
  if fresh ~= context.locale:get(TextKey.PANEL_FIRST_RUN) then
    error("a fresh install does not get the first-run message, it gets: " .. tostring(fresh))
  end

  -- The same shape of state, but at the cap: promising that recording starts at
  -- the next point of experience is a promise that can never be kept there.
  local capped = state(function() return nil end, function() return {} end, function() return true end)
  if capped ~= context.locale:get(TextKey.PANEL_NO_LEVEL_MAX) then
    error("a character at the cap is told recording is about to start: " .. tostring(capped))
  end

  local withHistory = state(function() return nil end, function() return { 20, 21 } end, function() return false end)
  if withHistory ~= context.locale:get(TextKey.PANEL_NO_LEVEL_MAX) then
    error("a character with history behind it is told nothing has been recorded")
  end

  panel.currentRecord, panel.completedLevels, panel.atCap = currentRecord, completedLevels, atCap
  panel:markDirty()
  panel:refresh()
end)

-- 6.7: the selection never left the history tab. This is the whole feature, and
-- it is driven the way a player drives it -- by clicking the row.
step("clicking a level in the history moves every tab to it", function()
  local TextKey = ns.core.TextKey
  panel:open()
  panel:selectTab("history")

  local target = context.locale:get(TextKey.PANEL_LEVEL_ROW, 15)
  local clicked = false
  for _, row in ipairs(panel.lists.history.rows) do
    if row.shown and row.cells[1].text == target then
      local onClick = row.scripts and row.scripts.OnClick
      if onClick == nil then error("the history row has no click handler wired to it") end
      onClick(row)
      clicked = true
    end
  end
  if not clicked then error("no history row for level 15 to click") end

  if panel.viewedLevel ~= 15 then
    error("the panel is still reading level " .. tostring(panel.viewedLevel))
  end
  if panel.title.text ~= context.locale:get(TextKey.PANEL_TITLE_LEVEL, 15) then
    error("nothing on screen says which level is being read: " .. tostring(panel.title.text))
  end

  panel:selectTab("breakdown")
  if panel.lastViewModel.breakdown.observedTotal ~= 11000 then
    error("the sources tab is showing " .. tostring(panel.lastViewModel.breakdown.observedTotal))
  end

  -- The one tab the selection cannot follow says so, rather than presenting
  -- today's quest log as a past level's.
  panel:selectTab("pending")
  if panel.empty.text ~= context.locale:get(TextKey.PANEL_PENDING_IS_NOW) then
    error("the pending tab is presenting today's quest log as a past level's")
  end

  -- Clicking the level in progress goes back to following it -- number and
  -- title both -- rather than pinning the panel to a level that will be stale
  -- after the next level-up.
  panel:selectTab("history")
  panel:select(context.tracker:current().level)
  if panel.selectedLevel ~= nil then error("clicking the level in progress pinned the panel to it") end
  if panel.title.text ~= context.locale:get(TextKey.PANEL_TITLE_LEVEL, context.tracker:current().level) then
    error("the title did not follow the panel back to the live level: " .. tostring(panel.title.text))
  end
  panel:selectTab("breakdown")
end)

-- The history has a hole in it on purpose: 12 and 15, with nothing between. The
-- comparison used to ask for `selected - 1`, find nothing, and claim there was
-- no earlier level when there plainly was one.
step("the comparison reaches the previous RECORDED level across a gap", function()
  local TextKey = ns.core.TextKey
  panel:selectTab("history")
  panel:select(15)
  local list = panel.lists.history
  if not drawn(list, context.locale:get(TextKey.PANEL_COMPARE_HEADER, 12)) then
    error("level 15 is not compared against 12: " .. table.concat(textsOf(list), " | "))
  end
  panel:select(nil)
end)

-- 6.10: one directory, every surface. The bug this guards against is not a quest
-- with no name -- it is the SAME quest named in one tab and numbered in the next,
-- which is what two independent naming paths produced.
step("both tabs name the quests the addon has seen, and number the ones it has not", function()
  local TextKey = ns.core.TextKey

  panel:selectTab("breakdown")
  local breakdown = panel.lists.breakdown
  if not drawn(breakdown, "Wanted: Hogger") then
    error("the breakdown does not name quest 1234: " .. table.concat(textsOf(breakdown), " | "))
  end
  if not drawn(breakdown, context.locale:get(TextKey.PANEL_QUEST, "5678")) then
    error("a quest with no name lost its number too: " .. table.concat(textsOf(breakdown), " | "))
  end

  panel:selectTab("pending")
  local pending = panel.lists.pending
  if not drawn(pending, "Wanted: Hogger") then
    error("the pending tab does not name quest 1234: " .. table.concat(textsOf(pending), " | "))
  end
  if not drawn(pending, context.locale:get(TextKey.PANEL_QUEST, "9012")) then
    error("a quest with no name lost its number too: " .. table.concat(textsOf(pending), " | "))
  end
end)

-- A quest read as a spell in the tab whose whole job is showing which quests
-- paid best. Two call sites, one already-translated key, and no gate could see
-- either until a cell's text could be read back.
step("a quest is labelled a quest, not a spell", function()
  local TextKey = ns.core.TextKey
  panel:selectTab("pending")
  local list = panel.lists.pending
  if not drawn(list, context.locale:get(TextKey.PANEL_QUEST, "9012")) then
    error("the pending tab does not label its quests: " .. table.concat(textsOf(list), " | "))
  end
  if drawn(list, context.locale:get(TextKey.PANEL_SPELL, "9012")) then
    error("the pending tab still calls a quest a spell")
  end
end)

-- pending-detail 1.2 and 1.4. The defect behind the redesign is visible only by
-- reading the popup back: a level played in one zone used to print that zone once
-- under every source, and said 6305 pending without saying of what.
step("the popup is three blocks: a zone named once, and pending broken down", function()
  local TextKey = ns.core.TextKey
  local locale = context.locale

  bar:update(context.tracker:current(), { questPending = 6305, showQuestPending = true })
  local onEnter = bar.frame.scripts and bar.frame.scripts.OnEnter
  if onEnter == nil then
    error("the bar registered no OnEnter, so the popup can never be shown")
  end
  onEnter()
  local lines = GameTooltip.lines

  local function count(text)
    local seen = 0
    for _, line in ipairs(lines) do
      if line.left == text then seen = seen + 1 end
    end
    return seen
  end

  local chasm = locale:get(TextKey.BAR_TOOLTIP_PLACE, "Ragefire Chasm")
  if count(chasm) ~= 1 then
    error(("the zone is printed %d times, not once"):format(count(chasm)))
  end
  if count(locale:get(TextKey.BAR_TOOLTIP_ZONES)) ~= 1 then
    error("the popup has no zone block")
  end
  -- A place that only cost time belongs to the panel, which says how much time;
  -- in a block about where the experience came from it is a row of zeroes.
  if count(locale:get(TextKey.BAR_TOOLTIP_PLACE, "Westfall")) ~= 0 then
    error("a place that paid nothing took a line in the popup")
  end

  if count(locale:get(TextKey.BAR_TOOLTIP_LEVEL)) ~= 1 then
    error("the popup has no level block")
  end

  -- Named quests first, then one line standing for the rest WITH its total: two
  -- of the five known ones did not fit, and 200 + 200 is what they are worth.
  if count(locale:get(TextKey.BAR_TOOLTIP_QUEST, "Wanted: Hogger")) ~= 1 then
    error("the pending block does not name its quests: " .. tostring(#lines) .. " lines")
  end
  local more = locale:get(TextKey.BAR_TOOLTIP_MORE, 2)
  local moreLine
  for _, line in ipairs(lines) do
    if line.left == more then moreLine = line end
  end
  if moreLine == nil then
    error("the pending block never accounted for the quests it did not name")
  end
  if moreLine.right ~= "400" then
    error("the remainder line says " .. tostring(moreLine.right) .. ", not the 400 those two are worth")
  end

  -- And the other half of the rule: nothing left over, no line about it. A
  -- remainder of zero printed as a line would be the popup talking about quests
  -- that are all already on screen.
  local forecast = panel.questForecastService
  local everything = forecast.entries
  forecast.entries = function()
    return { { questId = 1234, questLevel = 22, reward = 1200, adjustedReward = 1200,
      origin = ns.core.QuestXpOrigin.CLIENT, complete = true } }
  end
  onEnter()
  for _, line in ipairs(GameTooltip.lines) do
    if tostring(line.left):find("and ", 1, true) == 4 then
      error("one quest and the popup still talked about the rest: " .. line.left)
    end
  end
  forecast.entries = everything
end)

-- pending-detail 4.1: the detail the popup deliberately does not carry. What can
-- only be checked here is that the two kinds of estimate are told apart on screen
-- -- one priced with the creature's own average, one with the level's.
step("the pending tab prices what each quest still asks the player to kill", function()
  local TextKey = ns.core.TextKey
  panel:selectTab("pending")
  local list = panel.lists.pending
  local texts = textsOf(list)

  local function drawnRow(needle)
    for _, text in ipairs(texts) do
      if text:find(needle, 1, true) then return true end
    end
    return false
  end

  -- Three left of a creature this level has killed twice for 42 each.
  if not drawnRow(context.locale:get(TextKey.PANEL_OBJECTIVE, "Springpaw Lynx", 3, 6)) then
    error("the pending tab does not say what is left to kill: " .. table.concat(texts, " | "))
  end
  if not drawnRow(context.locale:get(TextKey.PANEL_OBJ_ESTIMATE, 126)) then
    error("the objective was not priced with the creature's own average: " .. table.concat(texts, " | "))
  end
  -- And one it has never killed, priced with the level's average and MARKED.
  local levelRate = ns.core.KillXpEstimator.levelRate(context.tracker:current())
  local fallback = math.floor(4 * levelRate + 0.5)
  if not drawnRow(context.locale:get(TextKey.PANEL_OBJ_ROUGH, fallback)) then
    error("the fallback estimate is missing or unmarked: " .. table.concat(texts, " | "))
  end
  if not drawnRow(context.locale:get(TextKey.PANEL_OBJ_FOOTNOTE)) then
    error("a marked estimate was printed with nothing explaining the mark")
  end

  -- A quest with no objectives gains no rows: the tab lists five quests and only
  -- one of them asks for kills.
  local rows = 0
  for _, text in ipairs(texts) do
    if text:find("slain", 1, true) then rows = rows + 1 end
  end
  if rows > 0 then
    error("an objective row leaked the client's own sentence instead of the panel's")
  end
end)

-- 6.2: both halves of its verification, measured rather than asserted by note.
step("opening and closing the panel allocates nothing, and draws each tab once", function()
  local renders = 0
  local original = panel.renderActiveTab
  panel.renderActiveTab = function(self, ...) renders = renders + 1 return original(self, ...) end

  panel:open()
  for _, tabId in ipairs(TABS_IN_ORDER) do panel:selectTab(tabId) end
  panel:close()

  local before = widgets
  renders = 0
  panel:open()
  -- One open, one draw. Restoring the old unconditional renderActiveTab after
  -- refresh makes this two, which is every row of the tab drawn twice.
  if renders ~= 1 then
    error(("opening the panel drew the active tab %d times"):format(renders))
  end
  for _, tabId in ipairs(TABS_IN_ORDER) do panel:selectTab(tabId) end
  panel:close()

  for _ = 1, 10 do
    panel:open()
    for _, tabId in ipairs(TABS_IN_ORDER) do panel:selectTab(tabId) end
    panel:close()
  end
  panel.renderActiveTab = original

  if widgets ~= before then
    error(("the panel built %d new widgets across eleven open/close cycles"):format(widgets - before))
  end
end)

step("a closed panel does no work", function()
  panel:close()
  local rebuilds = panel.gate:rebuildCount()
  for _ = 1, 20 do
    panel:markDirty()
    panel:refresh()
  end
  if panel.gate:rebuildCount() ~= rebuilds then
    error("a closed panel rebuilt its view-model anyway")
  end

  -- And the half the gate never covered: a settings write used to run a whole
  -- tab's worth of rows into a hidden list.
  local renders = 0
  local original = panel.renderActiveTab
  panel.renderActiveTab = function(self, ...) renders = renders + 1 return original(self, ...) end
  context.saveSetting(ns.core.SettingKey.BAR_SKIN, "glass")
  context.saveSetting(ns.core.SettingKey.BAR_SKIN, "tabard")
  panel.renderActiveTab = original
  if renders ~= 0 then
    error(("a closed panel rendered %d time(s) for a settings write"):format(renders))
  end
end)

-- A saved position that would put the panel out of reach is pulled back on the
-- way IN, the same rule the bar applies to itself. Nothing could observe this
-- until the stand-in reported the anchor it had actually been given.
step("a panel saved off the screen comes back within reach", function()
  local SettingKey = ns.core.SettingKey
  local saved = context.settings()[SettingKey.PANEL_POSITION]
  local restore = { point = saved.point, x = saved.x, y = saved.y, width = saved.width, height = saved.height }

  context.saveSetting(SettingKey.PANEL_POSITION,
    { point = "CENTER", x = 5000, y = -5000, width = 420, height = 360 })
  local point = panel.frame.points[1]
  -- UIParent is 400x300 in this harness, so the limits are half of each plus the
  -- 40px margin the bar uses.
  if point == nil or point[4] ~= 240 or point[5] ~= -190 then
    error(("the panel was placed at %s, %s, outside the screen it was clamped to"):format(
      point and tostring(point[4]) or "nowhere", point and tostring(point[5]) or "nowhere"))
  end

  context.saveSetting(SettingKey.PANEL_POSITION, restore)
end)

step("every skin applies", function()
  local Frozen = ns.core.Frozen
  for _, id in ipairs(Frozen.keys(ns.core.SkinCatalog)) do
    context.saveSetting(ns.core.SettingKey.BAR_SKIN, id)
    bar:tick(0.016)
  end
end)

step("high contrast", function()
  context.saveSetting(ns.core.SettingKey.HIGH_CONTRAST, true)
  context.saveSetting(ns.core.SettingKey.HIGH_CONTRAST, false)
end)

step("motion off and on", function()
  context.saveSetting(ns.core.SettingKey.MOTION_SCALE, 0)
  context.saveSetting(ns.core.SettingKey.MOTION_SCALE, 1)
end)

step("bar resizes", function()
  context.saveSetting(ns.core.SettingKey.BAR_WIDTH, 120)
  context.saveSetting(ns.core.SettingKey.BAR_HEIGHT, 10)
  context.saveSetting(ns.core.SettingKey.BAR_WIDTH, 800)
end)

step("options panel refreshes", function()
  local optionsPanel = context.optionsPanel
  if optionsPanel == nil then error("the options panel was not built") end
  local onShow = optionsPanel:GetScript("OnShow")
  if onShow == nil then error("the options panel has no OnShow") end
  onShow()
end)

-- 7.4, the half of it that does not need a client: resetting ONE axis must put
-- that axis back and leave every other override exactly where it was. The
-- reset for the border thickness is AscentOptionsAxis1Reset -- the first entry
-- of SLIDERS in ui/OptionsPanel.lua.
step("resetting one axis leaves the others alone", function()
  local SettingKey = ns.core.SettingKey
  local button = _G["AscentOptionsAxis1Reset"]
  if button == nil then error("the panel built no per-axis reset to click") end

  context.saveSetting(SettingKey.BAR_APPEARANCE, {
    border = { thickness = 5, kind = "FRAME" },
    separator = { thickness = 3 },
  })

  button.scripts.OnClick(button, "LeftButton")

  -- Reading a key that may not be there off a table that may be frozen. An
  -- empty override table comes back plain, a non-empty one frozen, and a frozen
  -- one RAISES on a key it does not hold (core/constants/Frozen.lua).
  local function at(node, key)
    if node == nil then return nil end
    if ns.core.Frozen.isFrozen(node) then
      return ns.core.Frozen.has(node, key) and node[key] or nil
    end
    return node[key]
  end

  local overrides = context.settings()[SettingKey.BAR_APPEARANCE]
  if at(at(overrides, "border"), "thickness") ~= nil then
    error("resetting the border thickness left it behind")
  end
  if at(at(overrides, "border"), "kind") == nil then
    error("resetting the border thickness took the border kind with it")
  end
  if at(at(overrides, "separator"), "thickness") == nil then
    error("resetting the border thickness took the separator thickness with it")
  end

  -- And the last override of a branch prunes the branch, so nothing is left
  -- claiming the player still holds that axis.
  local kindReset = _G["AscentOptionsCycle1Reset"]
  kindReset.scripts.OnClick(kindReset, "LeftButton")
  if at(context.settings()[SettingKey.BAR_APPEARANCE], "border") ~= nil then
    error("emptying the border branch left an empty table behind")
  end

  context.saveSetting(SettingKey.BAR_APPEARANCE, {})
end)

-- 7.5, the half of it that does not need a client: a colour tried and then
-- cancelled must leave NOTHING in the saved settings, and a confirmed one must
-- leave exactly itself. The panel previews on every swatchFunc, so the bug this
-- guards against -- persisting each colour the player drags through -- shows up
-- here as a stored colour after a cancel.
step("a cancelled colour pick writes nothing, a confirmed one writes once", function()
  local SettingKey = ns.core.SettingKey
  local button = _G["AscentOptionsColorMOB_KILLButton"]
  if button == nil then error("the panel built no colour swatch to click") end

  -- BAR_COLORS reads back as a frozen proxy once it has keys and as a plain
  -- empty table while it has none, which is what freezing does to a map with
  -- nothing in it (core/constants/Frozen.lua). Counting it takes both readings.
  local function storedColorKeys()
    local colors = context.settings()[SettingKey.BAR_COLORS]
    if ns.core.Frozen.isFrozen(colors) then
      return ns.core.Frozen.keys(colors)
    end
    local keys = {}
    for key in pairs(colors) do keys[#keys + 1] = key end
    return keys
  end

  context.saveSetting(SettingKey.BAR_COLORS, {})

  pickerConfirms = false
  button.scripts.OnClick(button, "LeftButton")
  local kept = storedColorKeys()
  if #kept ~= 0 then
    error(("cancelling kept %d colour(s) (%s); it must keep none")
      :format(#kept, table.concat(kept, ", ")))
  end

  pickerConfirms = true
  button.scripts.OnClick(button, "LeftButton")
  local written = storedColorKeys()
  if #written ~= 1 or written[1] ~= "MOB_KILL" then
    error(("confirming stored %d colour(s) (%s); it must store just the one picked")
      :format(#written, table.concat(written, ", ")))
  end

  context.saveSetting(SettingKey.BAR_COLORS, {})
end)

-- Every button and every slider the addon builds, clicked and dragged. The
-- options panel alone is six skin swatches, six colour swatches, five cycling
-- axes, nine sliders, fourteen per-axis resets and two whole-section resets --
-- none of which any unit test can reach, and each of which is a line of code
-- that has never run until a player clicks it.
step("every button in the addon", function()
  for _, frame in ipairs(frames) do
    local onClick = frame.scripts and frame.scripts.OnClick
    if onClick ~= nil then
      onClick(frame, "LeftButton")
    end
  end
end)

step("every slider in the addon", function()
  for _, frame in ipairs(frames) do
    local onValue = frame.scripts and frame.scripts.OnValueChanged
    local onMouseUp = frame.scripts and frame.scripts.OnMouseUp
    if onValue ~= nil then
      onValue(frame, 1)
    end
    if onMouseUp ~= nil then
      onMouseUp(frame, "LeftButton")
    end
  end
end)

step("commands that need no views", function()
  local handler = SlashCmdList["ASCENT"]
  handler("")
  handler("summary")
  handler("pending")
  handler("options")
  handler("debug")
  handler("evidence on")
  handler("evidence")
  -- Off last, so nothing below pushes samples into a ring somebody might read.
  handler("evidence off")
end)

-- What the composition root prints, read back. Everything below was a defect that
-- every gate in this repo was structurally unable to see: the dump omitted the
-- templates the group and raid work added, the two place lines could contradict
-- each other in the same breath, and a registry with no probes at all printed the
-- same sentence as a healthy one.
local function chatSince(mark, needle)
  for index = mark, #chatLines do
    if chatLines[index]:find(needle, 1, true) then
      return chatLines[index]
    end
  end
  return nil
end

step("the string dump covers every template the parser reads", function()
  -- One command now, and the strings go to the debug log rather than to chat:
  -- fifteen lines of the client's own raw text used to push the rest of the
  -- diagnostic off the top of a 500-line ring.
  -- With the debug mode off the strings still reach the snapshot below, which is
  -- what a report is built from -- but not the log, so the harness turns it on to
  -- exercise the path a player chasing a mismatch actually uses.
  local wasDebug = context.logger:isDebug()
  context.logger:setDebug(true)
  AscentCharDB.debugLog = {}
  SlashCmdList["ASCENT"]("debug")
  context.logger:setDebug(wasDebug)

  local dump = AscentCharDB and AscentCharDB.globalStringDump
  if dump == nil or dump.strings == nil then
    error("the dump was not written to the saved variables")
  end
  for _, source in ipairs(ns.adapter.GlobalStringPattern.SOURCES) do
    -- Absent globals are recorded as `false`, not left nil, so this checks the
    -- coverage of the LIST rather than of this stand-in client.
    if dump.strings[source.global] == nil then
      error("the dump never looked at " .. source.global)
    end
    local printed = false
    for _, line in ipairs(AscentCharDB.debugLog or {}) do
      if tostring(line):find(source.global, 1, true) then printed = true end
    end
    if not printed then
      error("the dump never logged " .. source.global)
    end
  end
end)

-- One command, three sections. The three used to be three commands, and the one
-- a player needed was whichever one they had not run.
step("the diagnostic answers in one command, quest log included", function()
  local mark = #chatLines + 1
  SlashCmdList["ASCENT"]("debug")

  for _, needle in ipairs({
    "flavor:",                 -- the client section
    "capability ",             -- the capability roster
    "attribution:",            -- the attribution counters
    "places: ",                -- the place dimension
    "quest log scanned:",      -- the quest log sweep
    "quest names known:",      -- the name directory
    "kill objectives:",        -- and the one figure that needs a real client
    "client strings dumped",   -- the strings, summarised rather than dumped to chat
  }) do
    if chatSince(mark, needle) == nil then
      error("one command no longer answers for '" .. needle .. "'")
    end
  end
end)

step("the two place lines agree with each other", function()
  local mark = #chatLines + 1
  SlashCmdList["ASCENT"]("debug")

  local places = chatSince(mark, "places: ")
  if places == nil then error("no place line was printed") end
  local named, ledgered = places:match("(%d+) of (%d+) experience placed")
  if named == nil then error("could not read the place line: " .. places) end

  local unplacedLine = chatSince(mark, "with no place the client could name")
  if unplacedLine == nil then error("no unplaced line was printed") end
  local unplaced = tonumber(unplacedLine:match("name: (%d+)"))

  named, ledgered = tonumber(named), tonumber(ledgered)
  if named + unplaced ~= ledgered then
    error(("%d placed plus %d unplaced is not the %d the ledger holds"):format(named, unplaced, ledgered))
  end
  -- The harness seeds an unknown-place entry, so the contradiction the old lines
  -- could print -- everything placed AND everything unplaced -- is reachable here.
  if unplaced > 0 and named >= ledgered then
    error("the panel claims everything was placed while also claiming none of it was")
  end
end)

step("the diagnostic names what it probed, not only what was missing", function()
  local mark = #chatLines + 1
  SlashCmdList["ASCENT"]("debug")

  for _, name in ipairs({ "creature_level", "map_position", "quest_reward_on_turn_in", "settings_canvas" }) do
    if chatSince(mark, "capability " .. name) == nil then
      error("the diagnostic never reported the capability " .. name)
    end
  end
  -- The stand-in has C_Map.GetBestMapForUnit and nothing else on that list, so a
  -- roster that reported everything present would be lying.
  if chatSince(mark, "capability map_position: present") == nil then
    error("map_position should be present against this stand-in")
  end
  if chatSince(mark, "capability creature_level: absent") == nil then
    error("creature_level should be absent against this stand-in")
  end
end)


step("changing a setting from outside the panel refreshes the panel", function()
  local SettingKey = ns.core.SettingKey
  local dropdown = _G.AscentOptionsSlotDropdown
  local restore = context.settings()[SettingKey.BAR_SLOT]

  -- The way a chat command does it: straight through saveSetting, with nobody
  -- reopening the panel. Before this the panel went on showing what it was built
  -- with until it was closed and opened again, or the interface reloaded.
  context.saveSetting(SettingKey.BAR_SLOT, "off")
  local offText = dropdown.dropdownText
  context.saveSetting(SettingKey.BAR_SLOT, "replace")

  if dropdown.dropdownText == offText then
    error("the panel still reads " .. tostring(offText) .. " after the setting changed under it")
  end

  context.saveSetting(SettingKey.BAR_SLOT, restore)
end)


step("where the bar lives is a list of the three slots, not a button to cycle", function()
  local dropdown = _G.AscentOptionsSlotDropdown
  if dropdown == nil then
    error("this client has the dropdown family and the panel built a button anyway")
  end

  -- Rebuilt from the live setting every time it opens, which is what makes the
  -- tick land on the right entry after a chat command changed it underneath.
  dropdown.initializer(dropdown)
  if #dropdown.entries ~= 3 then
    error(("the list offers %d slots, expected 3"):format(#dropdown.entries))
  end

  local SettingKey = ns.core.SettingKey
  local restore = context.settings()[SettingKey.BAR_SLOT]
  context.saveSetting(SettingKey.BAR_SLOT, "off")
  dropdown.initializer(dropdown)

  local checkedCount = 0
  for _, entry in ipairs(dropdown.entries) do
    if entry.checked then checkedCount = checkedCount + 1 end
  end
  if checkedCount ~= 1 then
    error(("%d entries read as the current one"):format(checkedCount))
  end

  -- Choosing the last entry has to write it, the way clicking it would.
  dropdown.entries[#dropdown.entries].func()
  if context.settings()[SettingKey.BAR_SLOT] ~= "replace" then
    error("choosing a slot from the list did not write it")
  end

  context.saveSetting(SettingKey.BAR_SLOT, restore)
end)


step("the bar's breakdown goes where the player keeps their tooltips", function()
  GameTooltip.defaultAnchored = false
  local onEnter = context.bar.frame.scripts and context.bar.frame.scripts.OnEnter
  if onEnter == nil then
    error("the bar has no tooltip at all")
  end

  onEnter(context.bar.frame)

  if not GameTooltip.defaultAnchored then
    error("the bar anchored its own tooltip instead of asking the client where tooltips go")
  end
  if #GameTooltip.lines == 0 then
    error("the tooltip was placed and then had nothing to say")
  end

  -- The cursor leaves again. A step that enters and never leaves is not how a
  -- cursor behaves, and it left the bar believing it was hovered for the rest of
  -- the run.
  context.bar.frame.scripts.OnLeave(context.bar.frame)
end)


step("a bar asked to stay quiet says nothing until the cursor is on it", function()
  local SettingKey = ns.core.SettingKey
  local bar = context.bar
  local restore = context.settings()[SettingKey.BAR_TEXT_ON_HOVER]

  context.saveSetting(SettingKey.BAR_TEXT_ON_HOVER, true)
  bar:update(context.tracker:current(), {})
  if (bar.renderer.text.text or "") ~= "" then
    error("the bar is still talking: " .. tostring(bar.renderer.text.text))
  end

  -- The text is composed all along; only its showing waits, so it is there the
  -- instant the cursor arrives rather than a redraw later.
  bar.frame.scripts.OnEnter(bar.frame)
  if (bar.renderer.text.text or "") == "" then
    error("the bar said nothing with the cursor on it")
  end

  bar.frame.scripts.OnLeave(bar.frame)
  if (bar.renderer.text.text or "") ~= "" then
    error("the bar kept talking after the cursor left")
  end

  context.saveSetting(SettingKey.BAR_TEXT_ON_HOVER, restore)
  bar:update(context.tracker:current(), {})
  if (bar.renderer.text.text or "") == "" then
    error("the bar stayed quiet after the setting was turned back off")
  end
end)


step("the text field editor writes what the bar says, in the order it reads", function()
  local SettingKey, TextToken = ns.core.SettingKey, ns.core.TextToken

  -- A known selection with a late-ranking field in it, so "placed by rank"
  -- means something: the level has to land in front of the session time.
  context.saveSetting(SettingKey.BAR_TEXT_TOKENS, { TextToken.SESSION_TIME })

  local level = _G.AscentOptionsField1CheckButton
  if level == nil then
    error("the field editor was never built")
  end
  level:SetChecked(true)
  level.scripts.OnClick(level)

  local chosen = context.settings()[SettingKey.BAR_TEXT_TOKENS]
  if chosen[1] ~= TextToken.LEVEL or chosen[2] ~= TextToken.SESSION_TIME then
    error(("the fields came out as %s"):format(table.concat(chosen, ", ")))
  end

  -- And off again, which is the other half and the one that can empty the list.
  level:SetChecked(false)
  level.scripts.OnClick(level)
  chosen = context.settings()[SettingKey.BAR_TEXT_TOKENS]
  if #chosen ~= 1 or chosen[1] ~= TextToken.SESSION_TIME then
    error("switching a field off did not leave the rest alone")
  end
end)

step("a bar with no text at all is a choice, not a crash", function()
  local SettingKey = ns.core.SettingKey
  local restore = context.settings()[SettingKey.BAR_TEXT_TOKENS]

  context.saveSetting(SettingKey.BAR_TEXT_TOKENS, {})
  context.bar:update(context.tracker:current(), {})
  context.bar:tick(0.016)

  context.saveSetting(SettingKey.BAR_TEXT_TOKENS, restore)
end)


step("every options control fits inside the page it lives on", function()
  -- One page per section now, so a control is measured against ITS page rather
  -- than against a single canvas. The three defects this guards against were all
  -- the same shape: a control laid out somewhere the player cannot reach, with no
  -- error to find it by -- past the bottom of a scroll child, or past the right
  -- edge after inheriting a gallery's indent.
  local PAGES = { "Main", "Skin", "Colors", "Fields", "Size", "Behaviour" }

  local contents = {}
  for _, key in ipairs(PAGES) do
    local scroll = _G["AscentOptions" .. key .. "Scroll"]
    if scroll == nil or scroll.scrollChild == nil then
      error("page " .. key .. " has no scroll child")
    end
    contents[scroll.scrollChild] = key
  end

  local function pageOf(widget)
    local hops = 0
    while widget ~= nil and hops < 64 do
      if contents[widget] ~= nil then
        return widget, contents[widget]
      end
      local _, parent = widget:GetPoint(1)
      widget, hops = parent, hops + 1
    end
  end

  local function extent(widget, root)
    local down, across, hops = 0, 0, 0
    while widget ~= nil and widget ~= root and hops < 64 do
      local _, parent, _, x, y = widget:GetPoint(1)
      if parent == nil then break end
      down = down - (y or 0)
      across = across + (x or 0)
      if parent ~= root then
        down = down + (parent:GetHeight() or 0)
      end
      widget, hops = parent, hops + 1
    end
    return down, across
  end

  -- Nothing below the skin gallery may be drawn over it. The gallery's last row
  -- ends with a label hanging under the swatch, and a control anchored to the
  -- swatch's bottom edge lands on that label -- which is what the whole "Bar"
  -- section did, drawn across two rows of skins.
  local lastRow = _G.AscentOptionsSkinstormwindSwatch
  local contrast = _G.AscentOptionsHighContrastCheckButton
  if lastRow == nil or contrast == nil then
    error("the skin gallery or the control under it was never built")
  end
  do
    local content = pageOf(contrast)
    local galleryBottom = select(1, extent(lastRow, content)) + (lastRow.h or 0)
    local contrastTop = select(1, extent(contrast, content))
    if contrastTop < galleryBottom then
      error(("the section under the gallery starts %d down, over a gallery that ends at %d"):format(
        contrastTop, galleryBottom))
    end
  end

  -- Controls of the same kind in the same column share one left edge. They hang
  -- off one another, so an indent in the helper that builds them is not an indent
  -- -- it is an indent PER control, and five sliders in a row walked the last one
  -- forty pixels right of the first.
  for _, group in ipairs({
    { "AscentOptionsAxis1Slider", "AscentOptionsAxis3Slider", "AscentOptionsAxis5Slider" },
    { "AscentOptionsWidthSlider", "AscentOptionsHeightSlider", "AscentOptionsScaleSlider" },
  }) do
    local first, firstIndent
    for _, name in ipairs(group) do
      local widget = _G[name]
      if widget ~= nil then
        local _, across = extent(widget, pageOf(widget))
        if firstIndent == nil then
          first, firstIndent = name, across
        elseif across ~= firstIndent then
          error(("%s sits %d across and %s sits %d; they are meant to share a left edge"):format(
            name, across, first, firstIndent))
        end
      end
    end
  end

  -- Room for the widest label a control carries to its right.
  local LABEL = 150
  for _, name in ipairs({ "AscentOptionsSlotDropdown", "AscentOptionsColorMOB_KILLButton",
    "AscentOptionsColorEXPLORATIONButton", "AscentOptionsColorPENDINGButton",
    "AscentOptionsField1CheckButton", "AscentOptionsField11CheckButton",
    "AscentOptionsHighContrastCheckButton", "AscentOptionsAxis1Slider",
    "AscentOptionsWidthSlider", "AscentOptionsHeightSlider", "AscentOptionsMotionSlider" }) do
    local widget = _G[name]
    if widget == nil then
      error(name .. " was never built")
    end
    local content, key = pageOf(widget)
    if content == nil then
      error(name .. " does not live on any page")
    end
    local down, across = extent(widget, content)
    if down > (content.h or 0) then
      error(("%s sits %d below the top of the %s page, only %d tall"):format(name, down, key, content.h))
    end
    if across + (widget.w or 20) + LABEL > (content.w or 0) then
      error(("%s reaches %d across the %s page, only %d wide"):format(
        name, across + (widget.w or 20) + LABEL, key, content.w))
    end
  end
end)


-- ---------------------------------------------------------------------------
-- The client's slot: the three transitions, and the client that has no bar.
--
-- None of this is proof the names are right -- a stub accepts any frame under any
-- name, which is what spikes 0.2 and 0.3 are for. What it does catch is the
-- mechanics: that taking the slot changes the bar's shape, that the two degrees
-- differ, that turning it off is a complete undo, and that a missing bar costs
-- the slot rather than the addon.
-- ---------------------------------------------------------------------------

local slash = SlashCmdList["ASCENT"]

-- From a known state. The steps above drag every slider to its end and click
-- every button in the options panel -- which now includes the slot's own -- so by
-- here the bar's appearance and its slot are wherever that walk left them.
slash("options reset")
slash("options slot off")

local function assertSize(where, width, height)
  local renderer = context.bar.renderer
  if renderer.width ~= width or renderer.height ~= height then
    error(("%s: the bar is %sx%s, expected %sx%s"):format(
      where, tostring(renderer.width), tostring(renderer.height), tostring(width), tostring(height)))
  end
end

step("the bar starts on its own size, with the client's bar untouched", function()
  local settings = context.settings()
  assertSize("off", settings[ns.core.SettingKey.BAR_WIDTH], settings[ns.core.SettingKey.BAR_HEIGHT])
  if MainMenuExpBar:GetAlpha() ~= 1 then
    error("the client's bar was already quiet before anything asked for it")
  end
end)

-- The modern client's shape, which is the one the owner actually plays: no
-- MainMenuExpBar at all, the anchor is a CONTAINER, and the art of the client's
-- frame is its child. The classic fakes above cannot express that, and it is the
-- difference between the two slots there.
--
-- Built by hand rather than with newRegion, and that is the point: the harness
-- invents any capitalised method, so a newRegion texture answers
-- GetStatusBarTexture as readily as a status bar does, and everything inside the
-- container would look like the bar. A fake that says yes to every question
-- cannot be asked this one.
step("the inset slot keeps the client's frame and quiets only the bar inside it", function()
  local function piece(extra)
    local p = { alpha = 1, mouse = true }
    function p:GetAlpha() return self.alpha end
    function p:SetAlpha(v) self.alpha = v end
    function p:IsMouseEnabled() return self.mouse end
    function p:EnableMouse(v) self.mouse = v ~= false end
    function p:GetWidth() return 1024 end
    function p:GetHeight() return 12 end
    -- What the view asks of a frame it is about to stand in: the scale to convert
    -- the slot's measure into its own, and the depth to draw under.
    function p:GetEffectiveScale() return 1 end
    function p:GetFrameStrata() return "MEDIUM" end
    function p:GetFrameLevel() return 2 end
    function p:GetParent() return nil end
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
  end

  local statusBar = piece({ GetStatusBarTexture = function() return {} end })
  local frameArt = piece()
  local container = piece({ GetChildren = function() return statusBar, frameArt end })

  local keptExpBar, keptContainer = MainMenuExpBar, MainStatusTrackingBarContainer
  MainMenuExpBar = nil
  MainStatusTrackingBarContainer = container

  -- Collected rather than thrown, so the globals go back even when an assertion
  -- fails: every step after this one anchors to the classic bar.
  local problems = {}
  local function check(ok, what)
    if not ok then problems[#problems + 1] = what end
  end

  slash("options slot inset")
  check(statusBar.alpha == 0, "the bar inside the client's container is still showing")
  check(container.alpha == 1, "the inset slot took the client's frame down with the bar")
  check(frameArt.alpha == 1, "the art around the client's bar went quiet too")

  -- And the other slot still takes the whole thing, which is what makes them two
  -- slots rather than one -- on this client they were indistinguishable.
  slash("options slot replace")
  check(container.alpha == 0, "the replace slot left the client's frame showing")

  slash("options slot off")
  check(statusBar.alpha == 1 and container.alpha == 1,
    "turning the slot off did not give the client its bar back")

  MainMenuExpBar, MainStatusTrackingBarContainer = keptExpBar, keptContainer
  if #problems > 0 then
    error(table.concat(problems, "; "))
  end
end)

step("the inset slot inherits the client's geometry and quiets its readouts", function()
  slash("options slot inset")

  assertSize("inset", MainMenuExpBar:GetWidth(), MainMenuExpBar:GetHeight())
  if MainMenuExpBar:GetAlpha() ~= 0 or MainMenuExpBar:IsMouseEnabled() then
    error("the client's bar is still visible or still takes the cursor")
  end
  if MainMenuBarExpText:GetAlpha() ~= 0 or ExhaustionTick:GetAlpha() ~= 0 then
    error("a readout of the client's bar was left on")
  end
  if MainMenuXPBarTextureMid:GetAlpha() ~= 1 then
    error("the inset slot quieted the client's frame, which is the other slot's job")
  end
end)

-- The owner reversed the first half of D52 from the client, and the reason is the
-- one thing the desk could not see: outside the bar, in the slot, is the client's
-- own interface. Text sent above it lands on the action bar; below it, the same.
-- There is no outside to move to there -- only somebody else's pixels.
step("the slot shows no text at all, and the breakdown stays in the tooltip", function()
  local SettingKey, TextAnchor = ns.core.SettingKey, ns.core.TextAnchor
  local restore = context.settings()[SettingKey.BAR_APPEARANCE]
  context.bar.frame.bottom = 300

  -- Every arrangement was tried in the client and none of them worked: inside a
  -- twelve pixel strip the line is too small to read, and every position outside
  -- it lands on the client's own interface. "Text position: Above" is what the
  -- owner had when he reported it.
  context.saveSetting(SettingKey.BAR_APPEARANCE, { text = { anchor = TextAnchor.ABOVE } })
  context.bar:update(context.tracker:current(), {})

  local shown = context.bar.renderer.text.text
  if shown ~= nil and shown ~= "" then
    error(("the bar in the client's slot is still drawing text: %q"):format(tostring(shown)))
  end

  -- But the readout is not lost -- it is a hover away, with words next to the
  -- numbers, which is the whole reason taking it off the bar is acceptable.
  GameTooltip.lines = {}
  context.bar.frame.scripts.OnEnter(context.bar.frame)
  if #GameTooltip.lines == 0 then
    error("the breakdown went nowhere: no text on the bar and nothing in the tooltip")
  end
  context.bar.frame.scripts.OnLeave(context.bar.frame)

  context.saveSetting(SettingKey.BAR_APPEARANCE, restore)
end)

-- Out of the slot, the text comes straight back: suspended, never cleared (D50).
step("the text comes back when the bar leaves the slot", function()
  slash("options slot off")
  context.bar:update(context.tracker:current(), {})

  local shown = context.bar.renderer.text.text
  if shown == nil or shown == "" then
    error("the free bar came back from the slot with no text")
  end
  slash("options slot inset")
end)

-- The side-picking rule did not go away -- it moved to where it still means
-- something. A FREE bar the player dragged against the bottom edge has a real
-- outside, and "below" there is behind the action bar.
step("a free bar at the bottom of the screen puts its text above, not behind the action bar", function()
  local SettingKey, TextAnchor = ns.core.SettingKey, ns.core.TextAnchor
  local restore = context.settings()[SettingKey.BAR_APPEARANCE]
  slash("options slot off")

  -- The player's own setting, not a skin's default and not one this code chose:
  -- the first version only reconsidered the text it had moved itself, so a player
  -- who picked "below" got a bar with no text and nothing to explain it.
  context.bar.frame.bottom = 6
  context.saveSetting(SettingKey.BAR_APPEARANCE, { text = { anchor = TextAnchor.BELOW } })

  if context.bar.appearance.text.anchor ~= TextAnchor.ABOVE then
    error(("a chosen below stayed %s with six pixels under the bar"):format(
      tostring(context.bar.appearance.text.anchor)))
  end

  -- With room, the player's choice is exactly what they get.
  context.bar.frame.bottom = 300
  context.bar:applySettings(context.settings())
  if context.bar.appearance.text.anchor ~= TextAnchor.BELOW then
    error("the player's choice was overruled where there was room for it")
  end

  context.saveSetting(SettingKey.BAR_APPEARANCE, restore)
  slash("options slot inset")
end)

step("the replace slot quiets the client's frame too", function()
  slash("options slot replace")

  if MainMenuXPBarTextureMid:GetAlpha() ~= 0 or MainMenuXPBarTextureLeftCap:GetAlpha() ~= 0 then
    error("the client's frame is still drawn around a bar that is no longer there")
  end
  assertSize("replace", MainMenuExpBar:GetWidth(), MainMenuExpBar:GetHeight())
end)

-- The bug this step exists for was reported from the client with two screenshots
-- of the same setting: the bar sitting inside the client's frame, and the bar
-- painted flat over it, with the client's own divisions gone. Nothing had been
-- changed between them but a loading screen and a visit to the options panel.
--
-- What it could not be was position or size -- both were identical to the pixel.
-- It was depth, and depth was the one thing about the slot nobody had ever
-- stated: the bar is a frame hung on UIParent, and a frame that declares no level
-- takes whatever the creation order gave it.
step("the slot says who draws on top, and says it again whenever the client moves", function()
  local frame = context.bar.frame

  local function assertDepth(where, strata, level)
    if frame:GetFrameStrata() ~= strata or frame:GetFrameLevel() ~= level then
      error(("%s: the bar draws at %s:%s, expected %s:%s"):format(
        where, tostring(frame:GetFrameStrata()), tostring(frame:GetFrameLevel()),
        tostring(strata), tostring(level)))
    end
  end

  MainMenuBar:SetFrameStrata("LOW")
  MainMenuBar:SetFrameLevel(2)
  MainMenuExpBar:SetFrameStrata("LOW")
  MainMenuExpBar:SetFrameLevel(5)

  -- Inset: the client's frame stays visible and the bar goes inside it, so the
  -- frame's art has to draw over the bar. Under the frame that PAINTS that art --
  -- the anchor's parent, at 2 -- and not merely under the anchor at 5, which lands
  -- level with the parent and lets creation order decide.
  slash("options slot inset")
  assertDepth("inset", "LOW", 1)

  -- Replace: the place belongs to the bar alone, so it draws last, and where the
  -- art it is covering lives is none of its business.
  slash("options slot replace")
  assertDepth("replace", "LOW", 6)

  -- An ancestor in another strata is not competing on level and must not drag the
  -- bar down to meet it.
  slash("options slot inset")
  MainMenuBar:SetFrameStrata("BACKGROUND")
  context.bar:update(context.tracker:current(), {})
  assertDepth("with the parent in another strata", "LOW", 4)
  MainMenuBar:SetFrameStrata("LOW")

  -- The half that makes it stick across a loading screen: the client rebuilds its
  -- bar and can take different levels with it, and the addon re-applies the slot
  -- at exactly that moment (PLAYER_ENTERING_WORLD in Bootstrap).
  MainMenuBar:SetFrameStrata("MEDIUM")
  MainMenuBar:SetFrameLevel(10)
  MainMenuExpBar:SetFrameStrata("MEDIUM")
  MainMenuExpBar:SetFrameLevel(12)
  for _, each in ipairs(frames) do
    local handler = each.scripts and each.scripts.OnEvent
    if handler ~= nil then
      handler(each, "PLAYER_ENTERING_WORLD")
    end
  end
  assertDepth("after a loading screen", "MEDIUM", 9)

  -- And the half the player found by using it. Ascent re-applies the slot at
  -- moments that are ITS own; the client re-lays its main bar out at moments that
  -- are the CLIENT's, and closing a settings panel is one of them -- which is why
  -- the report was "I change the config and it covers the frame". Nothing is
  -- attached or applied here on purpose: the only thing that runs between the
  -- client moving and the assertion is the data tick.
  MainMenuBar:SetFrameLevel(20)
  MainMenuExpBar:SetFrameLevel(23)
  context.bar:update(context.tracker:current(), {})
  assertDepth("after the client re-levelled on its own", "MEDIUM", 19)

  -- Off again: the depth the bar had before any of this, given back the way the
  -- position and the size are (D50). Not a number chosen here -- the one the
  -- frame was created with.
  slash("options slot off")
  assertDepth("off", "MEDIUM", 0)

  -- And once off, the tick has no business touching the depth at all: a bar the
  -- player moved back onto the screen is not standing in anybody's slot.
  MainMenuBar:SetFrameLevel(30)
  context.bar:update(context.tracker:current(), {})
  assertDepth("off, after the client moved again", "MEDIUM", 0)
end)

step("a visual setting changed in the slot repaints at the slot's size, not the last one", function()
  local SettingKey = ns.core.SettingKey
  slash("options slot inset")

  local slotWidth = MainMenuExpBar:GetWidth()
  local restoreSkin = context.settings()[SettingKey.BAR_SKIN]

  -- Any visual setting: the bar rebuilds its appearance and repaints, and what it
  -- repaints at has to be what the slot measures NOW. Painting from a remembered
  -- measure is what drew the bar across the client's own frame.
  context.saveSetting(SettingKey.BAR_SKIN, "glass")
  assertSize("after a skin change", slotWidth, MainMenuExpBar:GetHeight())

  -- The width the player saved is suspended in the slot, so changing it must
  -- move nothing at all.
  context.saveSetting(SettingKey.BAR_WIDTH, 820)
  assertSize("after the suspended width changed", slotWidth, MainMenuExpBar:GetHeight())

  -- And scale, which is the one that used to break it: the frame covers the same
  -- screen area at any scale, which is a different number of points each.
  context.bar.frame.scale = 2
  context.saveSetting(SettingKey.BAR_SCALE, 2)
  assertSize("at twice the scale", slotWidth / 2, MainMenuExpBar:GetHeight() / 2)

  context.bar.frame.scale = 1
  context.saveSetting(SettingKey.BAR_SCALE, 1)
  context.saveSetting(SettingKey.BAR_SKIN, restoreSkin)
  slash("options slot off")
end)


-- The owner's third report: "cuando todo free on screen se queda con la dimension
-- vieja". The bar came back from the slot as wide as the screen. assertSize alone
-- could not see it -- the renderer's own numbers were right; it was the FRAME
-- that kept the client's width, because while the slot lasted SetAllPoints pinned
-- both its corners and a frame pinned at both corners ignores SetSize.
step("the frame itself lets go of the client's width, not just the renderer", function()
  slash("options slot inset")
  local settings = context.settings()
  slash("options slot off")

  local frame = context.bar.frame
  if frame.allPointsOf ~= nil then
    error("the frame is still anchored to the client's bar after leaving the slot")
  end
  if frame:GetWidth() ~= settings[ns.core.SettingKey.BAR_WIDTH]
    or frame:GetHeight() ~= settings[ns.core.SettingKey.BAR_HEIGHT] then
    error(("the frame came back %sx%s, expected %sx%s"):format(
      tostring(frame:GetWidth()), tostring(frame:GetHeight()),
      tostring(settings[ns.core.SettingKey.BAR_WIDTH]),
      tostring(settings[ns.core.SettingKey.BAR_HEIGHT])))
  end
end)

step("going back gives the client its bar and the player their size", function()
  local settings = context.settings()
  slash("options slot off")

  assertSize("off again", settings[ns.core.SettingKey.BAR_WIDTH], settings[ns.core.SettingKey.BAR_HEIGHT])
  if MainMenuExpBar:GetAlpha() ~= 1 or not MainMenuExpBar:IsMouseEnabled() then
    error("the client's bar was not given back")
  end
  if MainMenuXPBarTextureMid:GetAlpha() ~= 1 then
    error("the client's frame was not given back")
  end
end)

step("a client with no experience bar costs the slot, not the bar", function()
  local kept = MainMenuExpBar
  MainMenuExpBar = nil

  slash("options slot replace")
  local settings = context.settings()
  assertSize("no client bar", settings[ns.core.SettingKey.BAR_WIDTH], settings[ns.core.SettingKey.BAR_HEIGHT])
  -- The choice stays on disk: the addon that took the bar away may be gone
  -- tomorrow, and the player should not have to find the setting again (D49).
  if settings[ns.core.SettingKey.BAR_SLOT] ~= "replace" then
    error("the addon overwrote the player's choice instead of not honouring it")
  end

  MainMenuExpBar = kept
  slash("options slot off")
end)


-- The pull plate, driven the way a fight actually drives it. This is the only
-- gate in the repo that executes ui/PullPlateView.lua or ui/Effects.lua at all,
-- so it walks the whole arc rather than just constructing the frame: combat
-- opens, things die, EXPERIENCE LANDS AFTER COMBAT ENDS -- which is the case the
-- whole settling design exists for -- and only then does the plaque appear.
--
-- The three calls below are the three the composition root's own ticker makes,
-- in its order. Reaching into that OnUpdate from here would be more faithful and
-- far more brittle; keeping the order stated in both places is the trade.
step("a pull opens, counts, settles late experience, and becomes a plaque", function()
  local EventTopic, PullPhase = ns.core.EventTopic, ns.core.PullPhase
  local bus, plate, tracker = context.bus, context.plate, context.pullTracker
  if plate == nil then error("the plate was not built") end

  -- One Mana Serpent already killed at this level, for 86. That is what turns
  -- the plate's projection from "nobody knows" into a measurement, and without
  -- it the estimate below would correctly refuse to appear.
  do
    local record = context.tracker:current()
    if record == nil then error("no level in progress to seed") end
    local key = ns.core.CreatureKey.new(17204, 10, "Mana Serpent")
    record.creatures[key:id()] = { key = key, kills = 1, xpTotal = 86 }
    record.killsWithXp = record.killsWithXp + 1
    record.xpBySource[ns.core.XpSource.MOB_KILL] =
      (record.xpBySource[ns.core.XpSource.MOB_KILL] or 0) + 86
    record.xpTotal = record.xpTotal + 86
  end

  -- The stub's GetTime is a constant, and a settling window measured against a
  -- clock that never moves never closes. WowClock reads this global on every
  -- call, so driving it here drives the addon's own clock.
  local seconds = 1000
  local realGetTime = GetTime
  GetTime = function() return seconds end

  local function tick(dt)
    seconds = seconds + dt
    tracker:tick(seconds)
    if tracker:consumeChange() then
      plate:follow(tracker, seconds)
    end
    plate:tick(dt)
  end

  -- Combat opens with nothing in it: no blow landed, nothing to say. The plate
  -- stays off the screen rather than announcing itself with a header full of
  -- zeroes and an empty body.
  bus:publish(EventTopic.COMBAT_STARTED, {})
  tick(0.016)
  if plate.frame.shown then
    error("the plate showed itself before there was anything to show")
  end
  bus:publish(EventTopic.COMBAT_ENDED, {})
  for _ = 1, 60 do tick(0.1) end
  tracker:reset()

  -- The opener, cast BEFORE the client acknowledges combat -- which is the order
  -- it happens in for every pull, because the client opens combat when the target
  -- fights back. It has to end up in the pull it started.
  bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })
  bus:publish(EventTopic.DAMAGE_DEALT, { amount = 18, name = "Mana Serpent", guid = "Creature-0-1-1-1-17204-A" })
  seconds = seconds + 0.5

  bus:publish(EventTopic.COMBAT_STARTED, {})
  bus:publish(EventTopic.ABILITY_USED, { key = 1752, name = "Mind Blast" })
  bus:publish(EventTopic.ABILITY_USED, { key = 1752, name = "Mind Blast" })
  bus:publish(EventTopic.ABILITY_USED, { key = ns.core.AbilityKey.MELEE_SWING })
  bus:publish(EventTopic.ABILITY_USED, { key = ns.core.AbilityKey.RANGED_AUTO })
  -- Two of them, told apart by guid, and NEITHER dead yet -- the exact state the
  -- plate used to have nothing to say about.
  bus:publish(EventTopic.DAMAGE_DEALT, { amount = 240, name = "Mana Serpent", guid = "Creature-0-1-1-1-17204-A" })
  bus:publish(EventTopic.DAMAGE_DEALT, { amount = 60, name = "Mana Serpent", guid = "Creature-0-1-1-1-17204-B" })
  bus:publish(EventTopic.DAMAGE_TAKEN, { amount = 60 })
  bus:publish(EventTopic.HEALING_RECEIVED, { amount = 15 })
  tick(0.016)

  if not plate.frame.shown then
    error("the plate did not show itself during a fight")
  end
  if tracker:currentPhase() ~= PullPhase.ACTIVE then
    error("the pull should still be open while combat runs")
  end

  -- The correction this harness exists to hold: everything is LIVE. Nothing on
  -- the plate may wait for the pull to close, because the player is looking at it
  -- during the fight and a frame that shows four zeros reads as broken.
  if not plate.creatureRows[1].name.shown then
    error("the plate is not listing what is being fought")
  end
  if plate.creatureRows[1].name.text ~= "Mana Serpent" then
    error("the creature row named " .. tostring(plate.creatureRows[1].name.text))
  end
  -- Two pulled, none dead yet: the row has to say so rather than show a body count.
  if plate.creatureRows[1].count.text ~= "0/2" then
    error("the live creature row read " .. tostring(plate.creatureRows[1].count.text))
  end
  if not plate.footerLeft.shown then
    error("the plate is not showing dps during the fight")
  end

  -- The ability rows, each NAMED. The defect this replaces: both reserved
  -- synthetic keys shared one label, so a melee swing and a ranged shot were the
  -- same row to read -- and one of them was labelled with the report panel's tab
  -- name, "Abilities".
  do
    local seen = {}
    for _, row in ipairs(plate.abilityRows) do
      if row.name.shown then
        seen[row.name.text] = (seen[row.name.text] or 0) + 1
      end
    end
    for _, wanted in ipairs({ "Shadow Word: Pain", "Mind Blast", "Auto attack", "Ranged attack" }) do
      if seen[wanted] ~= 1 then
        error("the ability rows do not name " .. wanted)
      end
    end
    if seen["Abilities"] ~= nil then
      error("an ability row is still labelled with the panel's tab name")
    end
  end
  if not plate.remaining.shown then
    error("the plate is not saying how much experience the level still needs")
  end

  -- The projection, and it lives INSIDE the headline rather than beside it: the
  -- banked figure and the estimate are the same quantity, and an estimate set off
  -- in the margin reads as a footnote to the number instead of part of it.
  -- The seeded level has already been paid for a Mana Serpent, so two of them
  -- standing is a MEASURED estimate rather than a guess.
  -- Let the headline arrive before reading it. The number WALKS to its target --
  -- that is the whole point of the counter -- so asserting on the first frame
  -- would be asserting on the animation rather than on the answer.
  for _ = 1, 10 do tick(0.1) end

  -- ONE number, and while the fight runs it is the forecast rather than the zero
  -- that has landed so far. The seeded level has already been paid for a Mana
  -- Serpent, so two of them standing is a MEASURED estimate, not a guess.
  if plate.xp.text ~= "172 XP" then
    error("the headline read " .. tostring(plate.xp.text) .. ", expected 172 XP")
  end
  if not plate.entrance then
    error("the plate has no arrival to play")
  end

  -- Nothing has paid yet, so the source bar must not be drawn at all. It used to
  -- be laid at a fixed offset below a font string whose height follows its text,
  -- which put it through the "to level" line instead of under it; the row
  -- constants exist so that cannot happen again, and this holds the other half --
  -- a bar for experience nobody has earned.
  -- The bar and the rate both read the HEADLINE, not the banked total. Nothing
  -- has been paid yet, so what is drawn is the forecast as a slice of its own --
  -- which is the case that used to leave the bar empty and the footer at zero for
  -- the whole of every fight.
  do
    local shown = 0
    for _, chip in ipairs(plate.chips) do
      if chip.shown then shown = shown + 1 end
    end
    if shown ~= 1 then
      error(("the forecast is not on the bar: %d slices drawn"):format(shown))
    end
    if plate.footerRight.text == "0 xp/h" then
      error("the rate is still reading the banked total")
    end
  end

  -- Now they start falling. Two kills close enough to chain, so the streak row
  -- is drawn, and the live row has to stop claiming anything is still standing.
  seconds = seconds + 2
  bus:publish(EventTopic.CREATURE_DIED, { name = "Mana Serpent", at = seconds })
  bus:publish(EventTopic.XP_ATTRIBUTED, { gain = { amount = 44, source = ns.core.XpSource.MOB_KILL } })
  tick(0.016)
  do
    local chip = plate.chips[1]
    if not chip.shown then
      error("experience landed and the source bar was not drawn")
    end
    local y = chip.points[1] and chip.points[1][5]
    local remainingY = plate.remaining.points[1] and plate.remaining.points[1][5]
    if y == nil or remainingY == nil or y >= remainingY then
      error(("the source bar is not below the level line: bar %s, line %s")
        :format(tostring(y), tostring(remainingY)))
    end
    -- One serpent paid, one still expected: the bar carries both.
    if not plate.chips[2].shown then
      error("the bar does not separate what is banked from what is still expected")
    end
  end

  if plate.creatureRows[1].count.text ~= "1/2" then
    error("one down of two should read 1/2, read " .. tostring(plate.creatureRows[1].count.text))
  end

  seconds = seconds + 2
  bus:publish(EventTopic.CREATURE_DIED, { name = "Mana Serpent", at = seconds })
  tick(0.016)
  if not plate.streak.shown then
    error("a chain of two should have drawn the chain row")
  end
  -- Nothing left standing: the row goes back to a plain body count. This is the
  -- transition that moves no number, and the one a counter without repaint()
  -- would have left saying 1/2 forever.
  if plate.creatureRows[1].count.text ~= "x2" then
    error("with both down the row should read x2, read " .. tostring(plate.creatureRows[1].count.text))
  end
  -- Both dead and the experience for the second one not in yet: the headline must
  -- still be the forecast, NOT the 44 that has actually landed. This is the case
  -- that used to read "0 XP" on a fight that had just been won.
  if plate.xp.text ~= "172 XP" then
    error("the forecast did not survive the kill: " .. tostring(plate.xp.text))
  end
  if not plate.rule.shown then
    error("the body was drawn without its rule")
  end

  bus:publish(EventTopic.COMBAT_ENDED, {})
  tick(0.016)
  if tracker:currentPhase() ~= PullPhase.SETTLING then
    error("combat ending must not close the pull outright")
  end

  -- The case the design exists for: the second kill's experience arrives a
  -- second AFTER the client said the fight was over.
  seconds = seconds + 1
  bus:publish(EventTopic.XP_ATTRIBUTED, { gain = { amount = 51, source = ns.core.XpSource.MOB_KILL } })
  tick(0.016)
  if tracker:current().xpTotal ~= 95 then  -- 44 during the fight, 51 after it ended
    error("late experience was dropped: " .. tostring(tracker:current().xpTotal))
  end

  -- Past the window: the plaque.
  for _ = 1, 40 do tick(0.1) end
  if tracker:currentPhase() ~= PullPhase.CLOSED then
    error("the pull never closed")
  end
  if plate.frame.h <= 74 then
    error("the plaque never grew past its minimum height: " .. tostring(plate.frame.h))
  end
  if not plate.creatureRows[1].name.shown then
    error("the plaque drew no creature rows")
  end
  if not plate.footerLeft.shown then
    error("the plaque drew no footer")
  end

  -- Pulling the next thing WHILE it fades carries the same pull on. The plate has
  -- to come back to full strength with its counter intact -- not reset, not a new
  -- pull, not stuck half-faded at whatever alpha the fade had reached.
  local banked = tracker:current().xpTotal
  local generation = tracker:currentGeneration()
  -- Driven until the fade has actually begun rather than for a guessed number of
  -- ticks: how long the hold lasts is the view's business, and a harness that
  -- hard-coded it would break every time that changed.
  for _ = 1, 200 do
    tick(0.1)
    if not plate.frame.shown or plate.frame:GetAlpha() < 1 then
      break
    end
  end
  if not plate.frame.shown or plate.frame:GetAlpha() >= 1 then
    error(("the plate should be mid-fade here: shown=%s alpha=%s")
      :format(tostring(plate.frame.shown), tostring(plate.frame:GetAlpha())))
  end

  bus:publish(EventTopic.COMBAT_STARTED, {})
  bus:publish(EventTopic.DAMAGE_DEALT, { amount = 40, name = "Kobold Miner", guid = "Creature-0-1-1-1-6-C" })
  tick(0.016)

  if tracker:currentGeneration() ~= generation then
    error("pulling during the fade started a new pull instead of carrying it on")
  end
  if tracker:currentPhase() ~= PullPhase.ACTIVE then
    error("the resumed pull is not running")
  end
  if tracker:current().xpTotal ~= banked then
    error("the resumed pull lost its counter")
  end
  if plate.frame:GetAlpha() ~= 1 then
    error("the plate stayed half-faded after being carried on")
  end

  -- And it lets go of the screen on its own rather than sitting there forever.
  bus:publish(EventTopic.COMBAT_ENDED, {})
  for _ = 1, 200 do tick(0.1) end
  if plate.frame.shown then
    error("the plaque never faded out")
  end

  GetTime = realGetTime
end)

-- A pull the player turned off costs nothing: no record, no frame, no redraw.
step("a plate the player switched off records nothing at all", function()
  local EventTopic = ns.core.EventTopic
  local slash = SlashCmdList["ASCENT"]

  slash("options plate off")
  context.bus:publish(EventTopic.COMBAT_STARTED, {})
  context.bus:publish(EventTopic.XP_ATTRIBUTED, { gain = { amount = 44, source = ns.core.XpSource.MOB_KILL } })

  if context.pullTracker:current() ~= nil then
    error("a plate that is off still opened a pull")
  end
  if context.plate.frame.shown then
    error("a plate that is off is still on screen")
  end

  slash("options plate on")
end)

-- The demo path, which is the one a player uses to decide whether they like the
-- plate at all -- and the only way anyone sees it without finding something to
-- kill first. Driven to the end so that the hand-back at the bottom of its
-- script runs too: a demo that never gives the plate back would leave a
-- fictional fight on screen over a real one.
step("the plate demo runs a whole fake pull and hands the plate back", function()
  local plate = context.plate
  local seconds = 5000
  local realGetTime = GetTime
  GetTime = function() return seconds end

  SlashCmdList["ASCENT"]("options plate demo")

  -- The composition root's own frame clock, taken from the context rather than
  -- guessed at by scanning for an OnUpdate: several frames have one, and the
  -- last one built is an options page.
  local ticker = context.ticker and context.ticker.scripts and context.ticker.scripts.OnUpdate
  if ticker == nil then error("no OnUpdate to drive") end

  local sawPlaque = false
  for _ = 1, 260 do
    seconds = seconds + 0.1
    ticker(nil, 0.1)
    if plate.frame.shown and plate.frame.h > 74 then
      sawPlaque = true
    end
  end

  if not sawPlaque then
    error("the demo never reached the plaque")
  end
  if plate.frame.shown then
    error("the demo never gave the plate back")
  end

  GetTime = realGetTime
end)

-- Where the player puts it is where it stays. The defect this holds: the plate
-- captured the settings table it was built with, and every save builds a NEW
-- frozen one -- so dropping it wrote the new position and then re-anchored to
-- the stale one, and the frame walked back to wherever it had been before.
--
-- Driven through the real handlers: the drag scripts the view registered, the
-- real saveSetting, and then an unrelated settings change, which is what makes
-- the composition root re-apply the position.
step("the plate stays where it is dropped", function()
  local plate = context.plate
  local slash = SlashCmdList["ASCENT"]

  plate.frame:ClearAllPoints()
  plate.frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 321, -654)
  plate.frame.scripts.OnDragStop(plate.frame)

  local saved = context.settings()[ns.core.SettingKey.PLATE_POSITION]
  if saved.point ~= "TOPLEFT" or saved.x ~= 321 or saved.y ~= -654 then
    error(("the drop saved %s %s,%s"):format(tostring(saved.point), tostring(saved.x), tostring(saved.y)))
  end

  -- Anything at all that makes the root re-resolve and re-apply.
  slash("options contrast on")
  slash("options contrast off")

  local point, _, relativePoint, x, y = plate.frame:GetPoint()
  if point ~= "TOPLEFT" or relativePoint ~= "TOPLEFT" or x ~= 321 or y ~= -654 then
    error(("the plate moved to %s/%s %s,%s"):format(
      tostring(point), tostring(relativePoint), tostring(x), tostring(y)))
  end
end)

-- THE ONE CHANNEL BACK, driven the way a player reporting a bug drives it.
--
-- The report is generated by running the diagnostics with their output diverted,
-- which is a path nothing else exercises: if `copy` ever stopped capturing and
-- started printing, every assertion about the addon would still pass and the one
-- thing a player can send back would be empty.
step("the copy window holds the diagnostics as text, not as chat lines", function()
  local chatBefore = #chatLines
  slash("copy")

  local dialog = _G["AscentCopyDialog"]
  if dialog == nil or not dialog.shown then
    error("no copy window was opened")
  end

  -- Diverted, not printed: the diagnostics did NOT go to chat this time.
  if #chatLines > chatBefore then
    error(("the report printed %d line(s) to chat as well"):format(#chatLines - chatBefore))
  end

  local text
  for _, frame in ipairs(frames) do
    if frame.kind == "EditBox" and frame.text ~= nil then
      text = frame.text
    end
  end
  if text == nil or text == "" then
    error("the window opened with no report in it")
  end
  -- The header is what makes a pasted report readable; the body is the
  -- diagnostic itself. Both, or it is not a report.
  if not text:find("addon: ", 1, true) then
    error("the report has no header: " .. text:sub(1, 80))
  end
  if not text:find("flavor:", 1, true) then
    error("the report carries no diagnostics: " .. text:sub(1, 120))
  end
  if text:find("|c", 1, true) then
    error("the report still carries chat colour codes")
  end
end)

step("a report the player asked to narrow is the one they get", function()
  slash("copy summary")

  local text
  for _, frame in ipairs(frames) do
    if frame.kind == "EditBox" and frame.text ~= nil then
      text = frame.text
    end
  end
  if text == nil or text:find("flavor:", 1, true) then
    error("copy summary handed over the whole diagnostic")
  end
end)

step("an unknown report says what there is instead of opening an empty window", function()
  slash("copy nonsense")

  local last = chatLines[#chatLines] or ""
  if not last:find("debug, summary, pending", 1, true) then
    error("the player was not told what they can copy: " .. last)
  end
end)

step("the options panel offers the same report the command does", function()
  local button = _G["AscentOptionsCopyReport"]
  if button == nil then
    error("the behaviour page has no button for the report")
  end
  local onClick = button:GetScript("OnClick")
  if onClick == nil then
    error("the report button was built disabled: the composition root offered no report")
  end

  -- Closed first, or the assertion below would pass on the window an earlier
  -- step left open and the button could be doing nothing at all.
  local dialog = _G["AscentCopyDialog"]
  dialog.shown = false

  onClick(button)

  if not dialog.shown then
    error("the button did not open the report")
  end
end)

-- A known state, driven to rest, then look at what was painted. The demo's
-- "unclassified gain" step has all four sources plus a rested reserve and a
-- pending projection, so every one of the bar's six channels should end up with
-- a width. Anything less than that is the bar failing at its whole purpose.
do
  local handler = SlashCmdList["ASCENT"]
  handler("demo off")
  for _ = 1, 7 do handler("demo") end
  for _ = 1, 120 do context.bar:tick(0.016) end
end

-- Did anything actually get painted? Driving the demo and then looking at the
-- bar's own fill textures is the difference between "no error" and "a bar".
local painted = 0
local widest = 0
for index, texture in ipairs(context.bar.renderer.fills) do
  if texture.shown and (texture.w or 0) > 0 then
    painted = painted + 1
    widest = math.max(widest, texture.w)
    print(("  fill %d: shown, width %.1f, colour %s"):format(
      index, texture.w, table.concat(texture.color or {}, ",")))
  else
    print(("  fill %d: hidden (width %s)"):format(index, tostring(texture.w)))
  end
end
print(("painted %d fills, widest %.1f"):format(painted, widest))

print(failures == 0 and "ALL PATHS OK" or (failures .. " PATH(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
