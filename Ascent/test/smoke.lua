-- A stand-in client: enough of the WoW API for the addon to load and build its
-- interface, so that a Lua error in ui/ or app/ shows up here instead of as a
-- silent nothing in the game.
--
-- It does NOT pretend to be the real client: a stub accepts any template name
-- and any method call, so template-specific failures (a template that needs its
-- parent named, a method missing on one flavour) do not reproduce here. What it
-- does catch is every ordinary Lua fault -- a nil index, a missing field, a
-- method that does not exist on our OWN objects, a load-order mistake.

-- Which client to pretend to be. The default is the classic tree this harness has
-- always modelled; "forever" turns it into the modern client at the bottom of the
-- file, where the two differ. See the change add-ascent-forever-support (D102).
local ROOT, PROFILE = ...
ROOT = ROOT or "Ascent"
PROFILE = PROFILE or "classic"

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

-- The interface number the client declares, which is what tells the flavours apart
-- (D95) now that two supported clients cap at the same level. The classic profile
-- reports Burning Crusade's, to agree with the maximum level just above it.
GetBuildInfo = function() return "2.5.6", "45745", "Jan 09 2026", 20506 end

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
C_Map = {
  GetBestMapForUnit = function() return 1 end,
  GetMapInfo = function(mapId) return { mapID = mapId, name = "Elwynn Forest" } end,
}
-- Present but showing nobody, which is the state a player in an empty field is in:
-- the sweep runs on every tick of every pull below and enrols nothing, so the pulls
-- these steps assert about are built from the combat log alone.
C_NamePlate = { GetNamePlates = function() return {} end }
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
    -- A version older than any this addon will ever be, so the composition root
    -- takes the "you updated" branch on the way up. It is the only way to see
    -- that path from here: the notice is decided once, while the addon loads.
    last_seen_version = "0.0.1",
    bar_colors = {
      -- Saved by the client's colour picker, which writes r/g/b and no alpha.
      -- Every reader has to complete it, and this is the only place that says so.
      UNKNOWN = { r = 0, g = 0, b = 0 },
    },
  },
}
AscentCharDB = nil

-- ---------------------------------------------------------------------------
-- The second client (D102).
--
-- Everything above models a classic client. This turns it into Forever, and it
-- only ever takes things away or swaps them for their modern namespace: a name
-- is absent below ONLY because the client's own API dump says it is absent there
-- (build 69913, see the change's design appendix). Nothing here is invented, and
-- nothing is removed on a hunch -- the frames of the client's own experience bar
-- stay exactly as the classic profile has them, because the dump carries no
-- frames at all and so says nothing either way about them.
--
-- A SECRET VALUE, and what this cannot model. In the real client a guarded read
-- returns a value that is present, has a type, and RAISES when tainted code
-- compares it or does arithmetic on it. Lua 5.1 only dispatches __eq and __lt
-- between two operands of the same type, so `secret == true` here answers false
-- instead of raising, the way it would in the client. Everything else does
-- raise: arithmetic, concatenation, indexing, calling, and comparing against a
-- number or another secret. So this profile catches a read that is USED, but it
-- cannot catch one that is only compared against a boolean -- which is exactly
-- the shape NameplateWatch is full of, and exactly why 3.2 converts those to go
-- through the guard rather than trusting this harness to find them.
-- ---------------------------------------------------------------------------

local SECRET = {}

-- One shared raise, not one per secret: Lua 5.1 only dispatches __eq when both
-- tables carry the SAME function, so a closure built per value would make
-- `secretA == secretB` answer false instead of raising.
local function raise() error("attempt to operate on a secret value", 2) end

function makeSecret(value)
  return setmetatable({ [SECRET] = value }, {
    __index = raise, __newindex = raise, __call = raise, __concat = raise,
    __add = raise, __sub = raise, __mul = raise, __div = raise, __mod = raise,
    __pow = raise, __unm = raise, __lt = raise, __le = raise, __eq = raise,
    __tostring = function() return "<secret>" end,
  })
end

local function isSecret(value)
  return type(value) == "table" and rawget(value, SECRET) ~= nil
end

-- Make the reads a collector does during a fight answer with secrets, for the
-- span of one call, and put them back afterwards. Opt-in on purpose: switched on
-- globally it would take the rest of the harness down with it, and what a caller
-- wants to know is whether ONE path survives a guarded client.
local COMBAT_READS = {
  "UnitIsTapDenied", "UnitIsUnit", "UnitCanAttack", "UnitIsDead",
  "UnitAffectingCombat", "UnitGUID", "UnitName", "UnitLevel",
  "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax",
}

function withSecretCombatReads(fn)
  local saved = {}
  for _, name in ipairs(COMBAT_READS) do
    saved[name] = _G[name]
    _G[name] = function() return makeSecret(saved[name] and saved[name]()) end
  end
  local savedEvent = C_CombatLog.GetCurrentEventInfo
  C_CombatLog.GetCurrentEventInfo = function() return makeSecret("SWING_DAMAGE") end

  local ok, err = pcall(fn)

  for _, name in ipairs(COMBAT_READS) do _G[name] = saved[name] end
  C_CombatLog.GetCurrentEventInfo = savedEvent
  if not ok then error(err, 0) end
end

if PROFILE == "forever" then
  -- Present in the dump, and the mechanism the guard of 3.1 is built on. Absent
  -- on the classic clients, which is why they only exist in this profile.
  issecretvalue = isSecret
  canaccessvalue = function(value) return not isSecret(value) end

  GetBuildInfo = function() return "1.60.1", "69913", "Sep 17 2026", 16001 end
  GetMaxPlayerLevel = function() return 60 end

  -- Gone from the dump. Every one of these is a call the addon makes today.
  GetQuestLogTitle = nil
  GetNumQuestLogEntries = nil
  SelectQuestLogEntry = nil
  GetQuestLogSelection = nil
  GetSpellTexture = nil
  GetSpellInfo = nil
  GetAddOnMetadata = nil
  GetNamePlates = nil
  CombatLogGetCurrentEventInfo = nil

  -- What it has instead.
  C_Spell = { GetSpellTexture = function() return "Interface\\Icons\\INV_Misc_QuestionMark" end }
  C_QuestLog = {
    GetNumQuestLogEntries = function() return #QUEST_LOG, #QUEST_LOG end,
    GetInfo = function(index)
      local entry = QUEST_LOG[index]
      if entry == nil then return nil end
      return {
        title = entry.title, level = entry.level, questID = entry.questId,
        isHeader = false, isComplete = entry.isComplete,
      }
    end,
    GetQuestIDForLogIndex = function(index)
      local entry = QUEST_LOG[index]
      return entry and entry.questId or 0
    end,
    IsComplete = function(questId)
      for _, entry in ipairs(QUEST_LOG) do
        if entry.questId == questId then return entry.isComplete == true end
      end
      return false
    end,
    GetQuestObjectives = function(questId)
      for _, entry in ipairs(QUEST_LOG) do
        if entry.questId == questId then
          local out = {}
          for _, objective in ipairs(entry.objectives or {}) do
            out[#out + 1] = { text = objective.text, type = objective.kind, finished = false }
          end
          return out
        end
      end
      return {}
    end,
    -- Recorded rather than ignored: the modern reader must never move the
    -- player's selection, and a harness that swallowed the call could not tell.
    selections = 0,
    GetSelectedQuest = function() return 0 end,
    SetSelectedQuest = function() C_QuestLog.selections = C_QuestLog.selections + 1 end,
  }
end

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

-- The harness checking its own stand-in before anything is built on it. A secret
-- that quietly behaved like an ordinary value would make every later assertion
-- about degrading meaningless -- it would pass by never having been tested.
if PROFILE == "forever" then
  step("a secret value is recognised as one, and raises when it is used", function()
    local secret = makeSecret(true)

    if issecretvalue(secret) ~= true then error("issecretvalue does not recognise a secret", 0) end
    if issecretvalue(true) ~= false then error("issecretvalue claims a plain value is secret", 0) end
    if canaccessvalue(secret) ~= false then error("canaccessvalue allows a secret", 0) end
    if canaccessvalue(true) ~= true then error("canaccessvalue denies a plain value", 0) end

    for what, use in pairs({
      ["ordering against a number"] = function() return secret < 5 end,
      ["equality against another secret"] = function() return secret == makeSecret(true) end,
      ["arithmetic"] = function() return secret + 1 end,
      ["concatenation"] = function() return secret .. "" end,
      ["indexing"] = function() return secret.field end,
      ["calling"] = function() return secret() end,
    }) do
      if pcall(use) then error(what .. " did not raise on a secret", 0) end
    end

    -- The one shape this stand-in CANNOT reproduce, asserted so that it stays a
    -- known limit instead of becoming a false sense of cover: Lua 5.1 only
    -- dispatches __eq between two tables, so this answers false where the real
    -- client raises. It is the shape NameplateWatch uses throughout (3.2).
    if (secret == true) ~= false then error("Lua 5.1 stopped short-circuiting mixed __eq", 0) end
  end)
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
  record.creatures[ns.core.LevelRecord.creatureId(lynx, nil)] =
    { key = lynx, kills = 2, xpTotal = 84 }
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

-- pending-detail 4.1 and group-aware-rates 3.1: the detail the popup deliberately
-- does not carry. What can only be checked here is that the THREE kinds of
-- estimate are told apart on screen -- one priced with this creature's average
-- measured in the group of now, one with its average over kills nobody counted,
-- and one with the level's blanket per-kill mean.
step("the pending tab prices what each quest still asks the player to kill", function()
  local TextKey = ns.core.TextKey
  panel:selectTab("pending")
  local list = panel.lists.pending

  local function drawnRow(needle)
    for _, text in ipairs(textsOf(list)) do
      if text:find(needle, 1, true) then return true end
    end
    return false
  end
  -- Exact rather than a substring, and that is the whole point of having it:
  -- "~126 xp" is a PREFIX of the marked "~126 xp+", so a find() would report an
  -- unmarked estimate as drawn on every screen that only ever drew a marked one.
  local function drawnExactly(needle)
    for _, text in ipairs(textsOf(list)) do
      if text == needle then return true end
    end
    return false
  end
  local function shown()
    return table.concat(textsOf(list), " | ")
  end

  -- Three left of a creature this level has killed twice for 42 each -- but those
  -- two kills were banked before anything counted who shared the pay, so 126 is
  -- this creature's own average over a population nobody can name. Marked, and
  -- not with the level's mark: it came from the right creature and the wrong
  -- context, which is a different kind of wrong.
  if not drawnRow(context.locale:get(TextKey.PANEL_OBJECTIVE, "Springpaw Lynx", 3, 6)) then
    error("the pending tab does not say what is left to kill: " .. shown())
  end
  if not drawnExactly(context.locale:get(TextKey.PANEL_OBJ_MIXED, 126)) then
    error("the objective priced from kills nobody counted was not marked as such: " .. shown())
  end
  if drawnExactly(context.locale:get(TextKey.PANEL_OBJ_ESTIMATE, 126)) then
    error("a mixed estimate was drawn exactly like one measured in this group: " .. shown())
  end
  if not drawnRow(context.locale:get(TextKey.PANEL_OBJ_MIXED_FOOTNOTE)) then
    error("a mixed estimate was printed with nothing explaining its mark")
  end
  -- And one it has never killed, priced with the level's average and MARKED.
  local levelRate = ns.core.KillXpEstimator.levelRate(context.tracker:current())
  local fallback = math.floor(4 * levelRate + 0.5)
  if not drawnRow(context.locale:get(TextKey.PANEL_OBJ_ROUGH, fallback)) then
    error("the fallback estimate is missing or unmarked: " .. shown())
  end
  if not drawnRow(context.locale:get(TextKey.PANEL_OBJ_FOOTNOTE)) then
    error("a marked estimate was printed with nothing explaining the mark")
  end

  -- A quest with no objectives gains no rows: the tab lists five quests and only
  -- one of them asks for kills.
  local rows = 0
  for _, text in ipairs(textsOf(list)) do
    if text:find("slain", 1, true) then rows = rows + 1 end
  end
  if rows > 0 then
    error("an objective row leaked the client's own sentence instead of the panel's")
  end

  -- The third state, and the one that makes the other two claims rather than
  -- decoration: give the same creature two kills taken with as many sharing the
  -- pay as there are right now, and the figure does not move while the mark goes
  -- away. Same 126, drawn two ways, because only its provenance changed.
  local record = context.tracker:current()
  local lynx = ns.core.CreatureKey.new(15343, 6, "Springpaw Lynx")
  local measuredId = ns.core.LevelRecord.creatureId(lynx, 1)
  record.creatures[measuredId] = { key = lynx, sharedBy = 1, kills = 2, xpTotal = 84 }
  panel:markDirty()
  panel:refresh()
  panel:selectTab("pending")

  if not drawnExactly(context.locale:get(TextKey.PANEL_OBJ_ESTIMATE, 126)) then
    error("an estimate measured in the group of now was still marked: " .. shown())
  end
  if drawnRow(context.locale:get(TextKey.PANEL_OBJ_MIXED_FOOTNOTE)) then
    error("the mixed footnote outlived the only row that carried its mark: " .. shown())
  end

  -- Left as it was found. Nothing above touched the level's kill counters, so
  -- dropping the bucket restores the record exactly for the steps that follow.
  record.creatures[measuredId] = nil
  panel:markDirty()
  panel:refresh()
end)

-- group-aware-rates 2.4: the only place the wiring itself can be checked. The
-- panel asks the client, through the port, how many are sharing the pay right
-- now, and the per-creature rows use that answer to say which of them describes
-- the character's current situation. A seam left unwired in the composition root
-- looks exactly like a client playing alone, and nothing in the domain suite can
-- tell the two apart.
step("the panel tells a creature's populations apart by the group of now", function()
  local TextKey = ns.core.TextKey
  local record = context.tracker:current()
  if record == nil then error("no level in progress to seed") end

  -- The same creature, the same average, killed alone: only the population
  -- differs, so nothing priced anywhere else moves.
  local lynx = ns.core.CreatureKey.new(15343, 6, "Springpaw Lynx")
  record.creatures[ns.core.LevelRecord.creatureId(lynx, 1)] =
    { key = lynx, sharedBy = 1, kills = 2, xpTotal = 84 }
  record.killsWithXp = record.killsWithXp + 2

  panel:markDirty()
  panel:refresh()
  panel:selectTab("breakdown")

  local uncounted, foreign, plain = 0, 0, 0
  for _, text in ipairs(textsOf(panel.lists.breakdown)) do
    if text:find("Springpaw Lynx", 1, true) then
      if text:find(context.locale:get(TextKey.PANEL_CREATURE_MIXED), 1, true) then
        uncounted = uncounted + 1
      elseif text:find(context.locale:get(TextKey.PANEL_CREATURE_SHARED, 1), 1, true) then
        -- The row that WAS measured with this group, marked as if it belonged to
        -- another one: what a seam the composition root never wired looks like.
        foreign = foreign + 1
      else
        plain = plain + 1
      end
    end
  end

  if uncounted ~= 1 then
    error(("the kills nobody counted were drawn %d times as their own population"):format(uncounted))
  end
  if plain ~= 1 or foreign ~= 0 then
    error(("the row measured in the current group was drawn %d times unmarked and %d times as another group's")
      :format(plain, foreign))
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

-- 4.6, the reset half: the plate page's own reset puts every key the plate owns
-- back to its default and touches NOT ONE of the bar's. The plate wears the bar's
-- skin, palette and contrast by design (D87), so the mistake this guards against
-- is the easy one -- a reset that reached them would undo, from a page that never
-- mentions the bar, choices made for the other surface.
--
-- HERE rather than with the other plate steps, because it is also the way back to
-- a known state: the two walks above dragged the plate's own sliders to their
-- ends and clicked its seven zone boxes off, and the plate steps further down
-- read the settings they find rather than writing every one of them first.
step("the plate page's reset gives the plate its defaults and the bar nothing", function()
  local SettingKey, Defaults, Frozen = ns.core.SettingKey, ns.core.Defaults, ns.core.Frozen
  local button = _G.AscentOptionsPlateReset
  if button == nil then error("the plate page built no reset to click") end

  -- Reading a default and a stored value the same way, whether either is a
  -- frozen proxy, a plain list or a number.
  local function flatten(value)
    if type(value) ~= "table" then return tostring(value) end
    local pieces = {}
    if Frozen.isFrozen(value) then
      for key, inner in Frozen.each(value) do
        pieces[#pieces + 1] = tostring(key) .. "=" .. flatten(inner)
      end
    else
      for key, inner in pairs(value) do
        pieces[#pieces + 1] = tostring(key) .. "=" .. flatten(inner)
      end
    end
    table.sort(pieces)
    return "{" .. table.concat(pieces, ",") .. "}"
  end

  -- The bar, deliberately NOT at its defaults: a bar already sitting on them
  -- would make "the reset left the bar alone" true for the wrong reason.
  context.saveSetting(SettingKey.BAR_SCALE, 1.35)
  context.saveSetting(SettingKey.BAR_APPEARANCE, { border = { thickness = 5 } })
  context.saveSetting(SettingKey.HIGH_CONTRAST, true)

  -- And the plate away from its own, including the two the walks above do not
  -- reach: where it was dragged to, and whether it is on at all.
  context.saveSetting(SettingKey.PLATE_ENABLED, false)
  context.saveSetting(SettingKey.PLATE_POSITION,
    { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 11, y = -22 })
  context.saveSetting(SettingKey.PLATE_LOCKED, true)
  context.saveSetting(SettingKey.PLATE_APPEARANCE, { text = { size = 17 } })

  button.scripts.OnClick(button, "LeftButton")

  for _, key in ipairs({ SettingKey.PLATE_ENABLED, SettingKey.PLATE_POSITION, SettingKey.PLATE_LOCKED,
                         SettingKey.PLATE_SCALE, SettingKey.PLATE_WIDTH, SettingKey.PLATE_OPACITY,
                         SettingKey.PLATE_HOLD_SECONDS, SettingKey.PLATE_ROWS, SettingKey.PLATE_ZONES,
                         SettingKey.PLATE_APPEARANCE }) do
    local now, want = flatten(context.settings()[key]), flatten(Defaults[key])
    if now ~= want then
      error(("%s reads %s after the reset, not its default %s"):format(key, now, want))
    end
  end

  if context.settings()[SettingKey.BAR_SCALE] ~= 1.35 then
    error("the plate's reset took the bar's scale with it")
  end
  if context.settings()[SettingKey.HIGH_CONTRAST] ~= true then
    error("the plate's reset took the bar's contrast with it")
  end
  if flatten(context.settings()[SettingKey.BAR_APPEARANCE]) ~= "{border={thickness=5}}" then
    error("the plate's reset reached the bar's own appearance: "
      .. flatten(context.settings()[SettingKey.BAR_APPEARANCE]))
  end

  context.saveSetting(SettingKey.BAR_SCALE, Defaults[SettingKey.BAR_SCALE])
  context.saveSetting(SettingKey.BAR_APPEARANCE, {})
  context.saveSetting(SettingKey.HIGH_CONTRAST, false)
end)

step("commands that need no views", function()
  local handler = SlashCmdList["ASCENT"]
  handler("")
  handler("summary")
  handler("pending")
  handler("options")
  handler("debug")
  handler("debug evidence on")
  handler("debug evidence")
  -- Off last, so nothing below pushes samples into a ring somebody might read.
  handler("debug evidence off")
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
    "sharing the pay",         -- how many the pay is split between right now
    "creature populations:",   -- and how many samples each context has collected
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

-- group-aware-rates 3.2: the instrument the design's open question needs, and the
-- only gate that can see either half of it. The size is asked of the client at the
-- moment the command runs -- a block that printed a constant, or one wired to
-- nothing, reads identically from inside the domain suite -- and the creature
-- lines have to group the way the estimator does, by name across level bands, or
-- the file shows halves of every population it is meant to size up.
step("the diagnostic says how many share the pay, and how thin each population is", function()
  local record = context.tracker:current()
  if record == nil then error("no level in progress to seed") end

  -- One creature, three aggregates: two level bands taken alone, which the
  -- estimator reads as ONE population of seven, and the kills nobody counted,
  -- which it reads as a population of its own (D84). Ids nothing else here uses,
  -- so the lines below can only come from these.
  local young = ns.core.CreatureKey.new(99001, 10, "Smoke Basilisk")
  local elder = ns.core.CreatureKey.new(99002, 11, "Smoke Basilisk")
  local seeded = {
    ns.core.LevelRecord.creatureId(young, 1),
    ns.core.LevelRecord.creatureId(elder, 1),
    ns.core.LevelRecord.creatureId(young, nil),
  }
  record.creatures[seeded[1]] = { key = young, sharedBy = 1, kills = 4, xpTotal = 168 }
  record.creatures[seeded[2]] = { key = elder, sharedBy = 1, kills = 3, xpTotal = 150 }
  record.creatures[seeded[3]] = { key = young, sharedBy = nil, kills = 2, xpTotal = 84 }

  local members = GetNumGroupMembers
  GetNumGroupMembers = function() return 5 end
  local mark = #chatLines + 1
  SlashCmdList["ASCENT"]("debug")
  GetNumGroupMembers = members

  for _, id in ipairs(seeded) do record.creatures[id] = nil end

  local shared = chatSince(mark, "sharing the pay")
  if shared == nil then error("the diagnostic never says how many share the pay") end
  if tonumber(shared:match("(%d+) sharing the pay")) ~= 5 then
    error("the group line does not read the client of the moment: " .. shared)
  end

  local line = chatSince(mark, "Smoke Basilisk:")
  if line == nil then error("no line was printed for a creature with two populations") end
  if not line:find("7 shared by 1", 1, true) then
    error("two level bands of one name were not counted as the one population the estimator reads: " .. line)
  end
  if not line:find("2 nobody counted", 1, true) then
    error("the kills nobody counted were not listed as a population of their own: " .. line)
  end
end)

step("the diagnostic names what it probed, not only what was missing", function()
  local mark = #chatLines + 1
  SlashCmdList["ASCENT"]("debug")

  for _, name in ipairs({ "creature_level", "map_position", "quest_reward_on_turn_in",
    "settings_canvas", "nameplates" }) do
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
  if chatSince(mark, "capability nameplates: present") == nil then
    error("nameplates should be present against this stand-in")
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
  -- Written out by hand, which is the risk this list carries: a page that is not
  -- named here is a page the only net for geometric containment does not cover,
  -- and nobody notices. "Plate" is the seventh (tasks.md 4.2).
  local PAGES = { "Main", "Skin", "Colors", "Fields", "Size", "Behaviour", "Plate" }

  local contents = {}
  for _, key in ipairs(PAGES) do
    local scroll = _G["AscentOptions" .. key .. "Scroll"]
    if scroll == nil or scroll.scrollChild == nil then
      error("page " .. key .. " has no scroll child")
    end
    -- Every page MEASURES its height off the last control on it. 100 is the
    -- provisional the scroll child is built with, and a page still wearing it is
    -- a page whose `last` was never set -- which is the whole defect again:
    -- controls laid out past the bottom edge, where scrolling cannot reach.
    if (scroll.scrollChild.h or 0) <= 100 then
      error(("the %s page is %s tall, still the provisional it was built with")
        :format(key, tostring(scroll.scrollChild.h)))
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
    "AscentOptionsWidthSlider", "AscentOptionsHeightSlider", "AscentOptionsMotionSlider",
    -- The plate's page, top to bottom: the first control, the last slider of each
    -- of its three sections, the last of its seven zone boxes, and the button at
    -- the foot of it. A page this long is exactly where a control falls off the
    -- bottom, and the reset is the furthest thing down it.
    "AscentOptionsPlateEnabledCheckButton", "AscentOptionsPlateHoldSlider",
    "AscentOptionsPlateZone7CheckButton", "AscentOptionsPlateLook3Slider",
    "AscentOptionsPlateReset" }) do
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
    record.creatures[ns.core.LevelRecord.creatureId(key, nil)] =
      { key = key, kills = 1, xpTotal = 86 }
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
  -- standing is an estimate rather than a guess.
  -- Let the headline arrive before reading it. The number WALKS to its target --
  -- that is the whole point of the counter -- so asserting on the first frame
  -- would be asserting on the animation rather than on the answer.
  for _ = 1, 10 do tick(0.1) end

  -- ONE number, and while the fight runs it is the forecast rather than the zero
  -- that has landed so far. The seeded level has already been paid for a Mana
  -- Serpent, so two of them standing is an estimate rather than a guess.
  if plate.xp.text ~= "172 XP" then
    error("the headline read " .. tostring(plate.xp.text) .. ", expected 172 XP")
  end
  if not plate.entrance then
    error("the plate has no arrival to play")
  end

  -- group-aware-rates 3.1: the plate has no room for a mark beside the digits --
  -- a glyph cannot be aligned against them -- so the claim is carried by how
  -- strongly the headline is drawn, and the three provenances have to be three
  -- weights. The seeded Serpent was banked before anything counted who shared the
  -- pay, so this 172 is an average over a population nobody can name.
  do
    local record = context.tracker:current()
    local key = ns.core.CreatureKey.new(17204, 10, "Mana Serpent")
    local function headlineAlpha()
      local color = plate.xp.textColor
      return color ~= nil and color[4] or nil
    end

    local uncounted = headlineAlpha()

    -- The same creature, the same 86, this time with as many sharing the pay as
    -- there are right now: the forecast does not move and the claim behind it
    -- does. Same number, drawn two ways, which is what makes the weight a
    -- statement about provenance instead of a style on estimates.
    record.creatures[ns.core.LevelRecord.creatureId(key, 1)] =
      { key = key, sharedBy = 1, kills = 1, xpTotal = 86 }
    plate:follow(tracker, seconds)
    local measured = headlineAlpha()

    if plate.xp.text ~= "172 XP" then
      error("pricing the same average from this group moved the headline to " .. tostring(plate.xp.text))
    end
    if measured == nil or uncounted == nil then
      error("the headline was drawn without a colour, so it claims nothing at all")
    end
    if uncounted >= measured then
      error(("a forecast from kills nobody counted was drawn at %s, no dimmer than the %s of one measured here")
        :format(tostring(uncounted), tostring(measured)))
    end

    -- And the widest of the three: a creature this level has never been paid for
    -- at all falls to the level's own mean, which must not look like either.
    record.creatures[ns.core.LevelRecord.creatureId(key, 1)] = nil
    record.creatures[ns.core.LevelRecord.creatureId(key, nil)] = nil
    plate:follow(tracker, seconds)
    local wide = headlineAlpha()
    if wide == nil or wide >= uncounted then
      error(("the level's own mean was drawn at %s, no dimmer than the %s of a mixed creature average")
        :format(tostring(wide), tostring(uncounted)))
    end

    -- Put the seed back: the rest of this step reads the 172 it produces.
    record.creatures[ns.core.LevelRecord.creatureId(key, nil)] =
      { key = key, kills = 1, xpTotal = 86 }
    plate:follow(tracker, seconds)
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

-- 4.6, the demo half: the plate's page has no preview of its own on purpose
-- (D92), and this button is what stands in for one -- the same fake pull the
-- command runs, on the real plate, at the settings just chosen. Driven to the
-- end like the step above, because the half that matters is the hand-back: a
-- button that left a fictional fight on screen over a real one would be worse
-- than no preview at all.
step("the plate page's demo button runs the whole pull and gives the plate back", function()
  local button = _G.AscentOptionsPlateDemo
  if button == nil then error("the plate page built no demo button") end
  if button.scripts == nil or button.scripts.OnClick == nil then
    error("the demo button does nothing: the composition root published no demo to run")
  end

  local plate = context.plate
  local seconds = 9000
  local realGetTime = GetTime
  GetTime = function() return seconds end

  button.scripts.OnClick(button, "LeftButton")

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

  GetTime = realGetTime

  if not sawPlaque then
    error("the button's demo never reached the plaque")
  end
  if plate.frame.shown then
    error("the button's demo never gave the plate back")
  end
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

-- ---------------------------------------------------------------------------
-- What the plate reads about ITSELF (tasks.md group 3). ui/ has no unit test, so
-- every claim below is made against what the stand-in client was actually told to
-- draw -- a text, a size, an anchor -- rather than against the addon not raising.
-- ---------------------------------------------------------------------------

-- The stub's GetTime is a constant, and a settling window measured against a
-- clock that never moves never closes. Swapped per step and put back even when
-- the step fails, because a harness that left a fake clock behind would take
-- every step after it with it.
local plateClock = 7000

-- Everything the steps below move, put back to its default whether the step
-- passed or not. A step that failed half way through would otherwise hand the
-- next one a plate nobody configured, and that one's failure would read as a
-- second defect somewhere else -- which is exactly how a run turns into a hunt.
local function restorePlateSettings()
  local SettingKey, Defaults = ns.core.SettingKey, ns.core.Defaults
  for _, key in ipairs({ SettingKey.PLATE_SCALE, SettingKey.PLATE_WIDTH,
                         SettingKey.PLATE_OPACITY, SettingKey.PLATE_HOLD_SECONDS,
                         SettingKey.PLATE_ROWS, SettingKey.PLATE_LOCKED,
                         SettingKey.BAR_LOCKED, SettingKey.MOTION_SCALE }) do
    context.saveSetting(key, Defaults[key])
  end
  -- Copied rather than handed back: the default list a frozen table answers with
  -- IS its backing store (Frozen's own header), and storing that reference in the
  -- saved variables would put the addon's constants one write away from a player.
  local zones = {}
  for _, zone in ipairs(Defaults[SettingKey.PLATE_ZONES]) do
    zones[#zones + 1] = zone
  end
  context.saveSetting(SettingKey.PLATE_ZONES, zones)
  context.saveSetting(SettingKey.PLATE_APPEARANCE, {})
end

local function plateStep(what, fn)
  step(what, function()
    local realGetTime = GetTime
    plateClock = 7000
    GetTime = function() return plateClock end
    local ok, err = pcall(fn)
    GetTime = realGetTime
    restorePlateSettings()
    if not ok then
      error(err, 0)
    end
  end)
end

-- The three calls the composition root's own ticker makes, in its order, exactly
-- as the long step above states them.
local function plateTick(dt)
  plateClock = plateClock + dt
  context.pullTracker:tick(plateClock)
  if context.pullTracker:consumeChange() then
    context.plate:follow(context.pullTracker, plateClock)
  end
  context.plate:tick(dt)
end

-- A fight with something in every zone -- two creatures, two abilities, two kills
-- close enough to chain, experience paid -- left OPEN, because an open pull is
-- what redraws when a setting changes under it. The counters are walked to their
-- targets first: the headline WALKS, so reading it on the first frame would be
-- reading the animation instead of the answer.
local function openAFight()
  local EventTopic, XpSource = ns.core.EventTopic, ns.core.XpSource
  local bus = context.bus
  context.pullTracker:reset()
  bus:publish(EventTopic.COMBAT_STARTED, {})
  bus:publish(EventTopic.ABILITY_USED, { key = 1752, name = "Mind Blast" })
  bus:publish(EventTopic.ABILITY_USED, { key = 589, name = "Shadow Word: Pain" })
  bus:publish(EventTopic.DAMAGE_DEALT, { amount = 240, name = "Mana Serpent", guid = "Creature-0-1-1-1-17204-A" })
  bus:publish(EventTopic.DAMAGE_DEALT, { amount = 180, name = "Kobold Miner", guid = "Creature-0-1-1-1-6-C" })
  bus:publish(EventTopic.CREATURE_DIED, { name = "Mana Serpent", at = plateClock })
  bus:publish(EventTopic.XP_ATTRIBUTED, { gain = { amount = 44, source = XpSource.MOB_KILL } })
  bus:publish(EventTopic.CREATURE_DIED, { name = "Kobold Miner", at = plateClock })
  bus:publish(EventTopic.XP_ATTRIBUTED, { gain = { amount = 51, source = XpSource.MOB_KILL } })
  for _ = 1, 20 do plateTick(0.1) end
  if not context.plate.frame.shown then
    error("the fight left nothing on the plate to look at")
  end
end

-- Where the plate's own arithmetic says its pieces go, asked the way the view
-- asks for it. Restated here rather than in numbers so that a changed constant
-- shows up as a changed PLATE, not as a harness that has to be edited to agree.
local function plateLayout(creatures, abilities)
  local settings = context.settings()
  local own = settings[ns.core.SettingKey.PLATE_APPEARANCE]
  local text = ns.core.SkinResolver.fieldOf(own, "text")
  return ns.core.PlateLayout.lay({
    textSize = ns.core.SkinResolver.fieldOf(text, "size"),
    zones = settings[ns.core.SettingKey.PLATE_ZONES],
    creatures = creatures,
    abilities = abilities,
  })
end

-- D88, and the whole of add-ascent-pull-recap 7.4. The defect: the plate asked
-- the BAR's lock, so a player who had locked the bar -- or who had taken the
-- client's bar slot, which DISABLES that lock -- could not move the plate, and
-- nothing anywhere said why.
plateStep("the plate has a lock of its own, and the bar's does not reach it", function()
  local SettingKey = ns.core.SettingKey
  local plate, save = context.plate, context.saveSetting
  local frame = plate.frame
  local wasAt = context.settings()[SettingKey.PLATE_POSITION]

  -- The client's StartMoving records nothing, and the stub auto-stubs it into a
  -- call that returns self -- so a drag that was refused and one that went
  -- through are the same nothing from out here. This is the stand-in that tells
  -- them apart.
  local realStartMoving = rawget(frame, "StartMoving")
  local started = 0
  frame.StartMoving = function() started = started + 1 end

  save(SettingKey.BAR_LOCKED, true)
  frame.scripts.OnDragStart(frame)
  if started ~= 1 then
    error("the bar's lock still stops the plate being dragged")
  end

  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 480, -96)
  frame.scripts.OnDragStop(frame)
  local saved = context.settings()[SettingKey.PLATE_POSITION]
  if saved.point ~= "TOPLEFT" or saved.x ~= 480 or saved.y ~= -96 then
    error(("the drop with the bar locked saved %s %s,%s")
      :format(tostring(saved.point), tostring(saved.x), tostring(saved.y)))
  end

  -- And its own lock does stop it, or it is not a lock.
  save(SettingKey.PLATE_LOCKED, true)
  frame.scripts.OnDragStart(frame)
  if started ~= 1 then
    error("the plate's own lock did not stop the drag")
  end

  save(SettingKey.PLATE_POSITION, { point = wasAt.point, relativePoint = wasAt.relativePoint,
    x = wasAt.x, y = wasAt.y })
  frame.StartMoving = realStartMoving
end)

-- 3.2: the frame takes the scale, the width and the height its contents ask for,
-- and the rows are cut to the width in force rather than to the 240 this file
-- used to carry.
plateStep("the plate is the size the player asked for, rows included", function()
  local SettingKey = ns.core.SettingKey
  local plate, save = context.plate, context.saveSetting
  local frame = plate.frame

  save(SettingKey.PLATE_SCALE, 1.5)
  save(SettingKey.PLATE_WIDTH, 320)
  openAFight()

  if frame:GetEffectiveScale() ~= 1.5 then
    error("the plate was drawn at scale " .. tostring(frame:GetEffectiveScale()))
  end
  if frame:GetWidth() ~= 320 then
    error("the plate was drawn " .. tostring(frame:GetWidth()) .. " wide")
  end
  -- The height is the layout service's answer and not the view's own running
  -- total: two of those would be free to disagree, and the one that decides how
  -- tall the frame is would win in silence.
  local layout = plateLayout(2, 2)  -- two creatures fought, two abilities pressed
  if frame:GetHeight() ~= layout.height then
    error(("the plate stands %s tall where its contents ask for %s")
      :format(tostring(frame:GetHeight()), tostring(layout.height)))
  end

  -- A row's text is cut to the width in force. At 240 this was 188.
  local row = plate.creatureRows[1]
  if row.name.w ~= 320 - layout.padding * 2 - 32 then
    error("a creature row was cut to " .. tostring(row.name.w) .. " on a plate 320 wide")
  end
  local chipsWide = 0
  for _, chip in ipairs(plate.chips) do
    if chip.shown then chipsWide = chipsWide + chip.w end
  end
  if math.abs(chipsWide - (320 - layout.padding * 2)) > 0.01 then
    error("the source bar spans " .. tostring(chipsWide) .. " on a plate 320 wide")
  end

  -- And the saved position is re-read AFTER the scale, so the anchor the player
  -- dropped it at is the one it is hanging from.
  local saved = context.settings()[SettingKey.PLATE_POSITION]
  local point, _, relativePoint, x, y = frame:GetPoint()
  if point ~= saved.point or relativePoint ~= saved.relativePoint or x ~= saved.x or y ~= saved.y then
    error(("scaling the plate left it at %s/%s %s,%s")
      :format(tostring(point), tostring(relativePoint), tostring(x), tostring(y)))
  end
end)

-- 3.5: a zone that is off is not drawn AND leaves no gap, the headline is not one
-- of the zones, and none of it builds a single new region.
plateStep("the plate draws the zones and the rows the player chose, and builds nothing", function()
  local SettingKey, PlateZone = ns.core.SettingKey, ns.core.PlateZone
  local plate, save = context.plate, context.saveSetting

  local before = widgets
  openAFight()

  for _, drawn in ipairs({ { "the clock", plate.clock }, { "the level line", plate.remaining },
                           { "the chain", plate.streak }, { "the first source", plate.chips[1] },
                           { "a creature row", plate.creatureRows[1].name },
                           { "an ability row", plate.abilityRows[1].name },
                           { "the footer", plate.footerLeft } }) do
    if not drawn[2].shown then
      error("with every zone on, " .. drawn[1] .. " was not drawn")
    end
  end
  local tall = plate.frame:GetHeight()

  -- One zone off. Not drawn, and the plate is SHORTER -- hiding it and leaving
  -- its gap behind would be the other thing, and the one D90 rules out.
  save(SettingKey.PLATE_ZONES, { PlateZone.CLOCK, PlateZone.REMAINING, PlateZone.STREAK,
    PlateZone.SOURCES, PlateZone.CREATURES, PlateZone.ABILITIES })
  openAFight()
  if plate.footerLeft.shown or plate.footerRight.shown then
    error("the footer was turned off and drawn anyway")
  end
  if plate.frame:GetHeight() >= tall then
    error(("turning a zone off left the plate %s tall, against %s with it on")
      :format(tostring(plate.frame:GetHeight()), tostring(tall)))
  end

  -- Every accessory zone off is a choice, not a corrupt file (D90). What is left
  -- is the figure the plate exists to show and the count facing it, and neither
  -- can be turned off: a frame that appears in combat without them is decoration.
  save(SettingKey.PLATE_ZONES, {})
  openAFight()
  for _, gone in ipairs({ { "the clock", plate.clock }, { "the level line", plate.remaining },
                          { "the chain", plate.streak }, { "the first source", plate.chips[1] },
                          { "a creature row", plate.creatureRows[1].name },
                          { "an ability row", plate.abilityRows[1].name },
                          { "the footer", plate.footerLeft } }) do
    if gone[2].shown then
      error("with every accessory zone off, " .. gone[1] .. " was still drawn")
    end
  end
  -- Never hidden and still carrying a figure. The figure itself is whatever the
  -- fight was worth -- this step is about the zones, and pinning the number here
  -- would make it fail for a reason it is not asking about.
  if plate.xp.shown == false or plate.xp.text == nil or not plate.xp.text:find("XP", 1, true) then
    error("the headline went with the zones: " .. tostring(plate.xp.text))
  end
  if plate.kills.shown == false or plate.kills.text ~= "2" then
    error("the count went with the zones: " .. tostring(plate.kills.text))
  end
  if plate.frame:GetHeight() ~= plateLayout(0, 0).height then
    error("a plate with nothing but its headline stands " .. tostring(plate.frame:GetHeight()))
  end

  -- How many rows, changed with the pull still open: the new number is drawn on
  -- the next redraw, with no frame rebuilt -- they all exist already.
  save(SettingKey.PLATE_ZONES, { PlateZone.CLOCK, PlateZone.REMAINING, PlateZone.STREAK,
    PlateZone.SOURCES, PlateZone.CREATURES, PlateZone.ABILITIES, PlateZone.FOOTER })
  openAFight()
  if not plate.creatureRows[2].name.shown then
    error("two creatures were fought and only one row drawn")
  end
  save(SettingKey.PLATE_ROWS, 1)
  plate:follow(context.pullTracker, plateClock)
  if not plate.creatureRows[1].name.shown or plate.creatureRows[2].name.shown then
    error("asking for one row mid-fight drew " .. tostring(plate.creatureRows[2].name.text))
  end
  if plate.abilityRows[2].name.shown then
    error("the row count reached the creatures and not the abilities")
  end

  save(SettingKey.PLATE_ROWS, 6)
  openAFight()
  if widgets ~= before then
    error(("the plate built %d new region(s) across four pulls and five settings changes")
      :format(widgets - before))
  end
end)

-- 3.3 and D91: the opacity is a FACTOR over whatever the plate is drawing at,
-- never the frame's alpha -- that channel is how the plate leaves.
plateStep("the plate is drawn at the opacity the player chose, and still fades to nothing", function()
  local SettingKey = ns.core.SettingKey
  local plate, save = context.plate, context.saveSetting
  local frame = plate.frame

  save(SettingKey.PLATE_OPACITY, 0.5)
  openAFight()
  if frame:GetAlpha() ~= 0.5 then
    error("a plate at half opacity was drawn at " .. tostring(frame:GetAlpha()))
  end

  -- Closing the pull is a reset of the frame's alpha all of its own, and it has
  -- to land on the factor rather than on one.
  context.bus:publish(ns.core.EventTopic.COMBAT_ENDED, {})
  local closed = false
  for _ = 1, 200 do
    plateTick(0.1)
    if context.pullTracker:currentPhase() == ns.core.PullPhase.CLOSED then
      closed = true
      break
    end
  end
  if not closed then
    error("the pull never closed")
  end
  if frame:GetAlpha() ~= 0.5 then
    error("closing the pull put the plate back to " .. tostring(frame:GetAlpha()))
  end

  -- Held, then fading, and never brighter than the factor at any instant in
  -- between: one that reached the fade and not the hold would be a plaque that
  -- brightens the moment it stops moving.
  local mid
  for _ = 1, 400 do
    plateTick(0.1)
    if not frame.shown then break end
    if frame:GetAlpha() > 0.5 then
      error("the plaque was drawn at " .. tostring(frame:GetAlpha()) .. " while it was up")
    end
    if frame:GetAlpha() < 0.5 then
      mid = frame:GetAlpha()
      break
    end
  end
  if mid == nil then
    error("the plate never started fading from the opacity it was drawn at")
  end

  -- Carried on rather than started over: the same pull, alive again. THIS is the
  -- reset D91 warns is the easy one to miss -- a resumed pull plays no arrival, so
  -- nothing else writes the alpha behind it, and a factor that had not reached
  -- this line would show up as a plate that brightens when the fighting resumes.
  context.bus:publish(ns.core.EventTopic.COMBAT_STARTED, {})
  context.bus:publish(ns.core.EventTopic.DAMAGE_DEALT,
    { amount = 40, name = "Kobold Miner", guid = "Creature-0-1-1-1-6-C" })
  plateTick(0.016)
  if frame:GetAlpha() ~= 0.5 then
    error("carrying the pull on put the plate back to " .. tostring(frame:GetAlpha()))
  end

  -- And it still leaves on its own. Half opacity is where the fade starts from,
  -- not a floor under it: a factor that stopped the plate disappearing would be a
  -- plaque sitting over the next fight.
  context.bus:publish(ns.core.EventTopic.COMBAT_ENDED, {})
  for _ = 1, 400 do
    plateTick(0.1)
    if not frame.shown then break end
  end
  if frame.shown then
    error("the plate never left")
  end
  -- Letting go of the screen puts the alpha back for the next time, and "back"
  -- is the factor: the fourth of the four resets D91 counts, and the only one
  -- whose write nothing else follows.
  if frame:GetAlpha() ~= 0.5 then
    error("the plate let go of the screen at " .. tostring(frame:GetAlpha()))
  end

  -- With motion turned off there IS no arrival -- a duration of zero builds the
  -- inert effect -- so a new pull's own reset is the only thing writing the
  -- frame's alpha. It is the reset the arrival hides in every other path.
  save(SettingKey.MOTION_SCALE, 0)
  openAFight()
  if frame:GetAlpha() ~= 0.5 then
    error("a new pull with motion off opened at " .. tostring(frame:GetAlpha()))
  end

  -- Below the floor the plate imposes on the SKIN's background, which is a floor
  -- on a colour and not on the player (D91).
  save(SettingKey.PLATE_OPACITY, 0.2)
  openAFight()
  if frame:GetAlpha() ~= 0.2 then
    error("an opacity under the background's floor was drawn at " .. tostring(frame:GetAlpha()))
  end
  local background = plate.background.color
  if background == nil or background[4] < 0.72 then
    error("the floor under the skin's own background went with it: " .. tostring(background and background[4]))
  end

  save(SettingKey.PLATE_OPACITY, ns.core.Defaults[SettingKey.PLATE_OPACITY])
  openAFight()
  if frame:GetAlpha() ~= 1 then
    error("putting the opacity back left the plate at " .. tostring(frame:GetAlpha()))
  end
end)

-- D89's half of the view: how long the plaque stays is the player's, read per
-- tick rather than captured, so a plaque already on screen when it changes
-- honours the new number. The OTHER half -- the window a closed pull can still be
-- carried on in, which is meant to be this same figure -- belongs to the
-- composition root and is not wired yet (tasks.md group 4).
plateStep("the plaque stays as long as the player asked, not as long as the file said", function()
  local SettingKey, PullPhase = ns.core.SettingKey, ns.core.PullPhase
  local plate, save = context.plate, context.saveSetting
  local frame = plate.frame

  save(SettingKey.PLATE_HOLD_SECONDS, 3)
  openAFight()
  context.bus:publish(ns.core.EventTopic.COMBAT_ENDED, {})
  local closed = false
  for _ = 1, 200 do
    plateTick(0.1)
    if context.pullTracker:currentPhase() == PullPhase.CLOSED then
      closed = true
      break
    end
  end
  if not closed then
    error("the pull never closed")
  end

  local heldFor
  for _ = 1, 300 do
    plateTick(0.1)
    if not frame.shown then break end
    if frame:GetAlpha() < 1 then
      heldFor = plate.heldFor
      break
    end
  end
  if heldFor == nil then
    error("the plaque never started fading")
  end
  -- Three seconds and change: the tick that notices is the first one past the
  -- hold, not the instant of it. Six would be the file's old literal.
  if heldFor < 3 or heldFor >= 4 then
    error(("the plaque held for %s seconds where the player asked for 3"):format(tostring(heldFor)))
  end

  for _ = 1, 300 do
    plateTick(0.1)
    if not frame.shown then break end
  end
  if frame.shown then
    error("the plaque never left")
  end
end)

-- 3.4 and D87: the plate follows the bar's skin and may adjust a few axes over
-- it. An axis it states wins, an axis it leaves out keeps following the bar, and
-- neither reaches the bar itself.
plateStep("the plate's own appearance sits on top of the bar's and stops there", function()
  local SettingKey = ns.core.SettingKey
  local plate, save = context.plate, context.saveSetting

  openAFight()
  local barAccent = context.bar.appearance.accent
  local signature = plate.effectSignature
  local glow = plate.glow

  save(SettingKey.PLATE_APPEARANCE, { accent = { r = 1, g = 0, b = 0, a = 1 } })
  openAFight()

  if plate.appearance.accent.r ~= 1 or plate.appearance.accent.g ~= 0 then
    error("the plate's own accent did not reach it")
  end
  -- Drawn with it, not merely resolved into a table nobody paints from.
  local title = plate.title.textColor
  if title == nil or title[1] ~= 1 or title[2] ~= 0 then
    error("the plate's caption is still the bar's colour")
  end
  if context.bar.appearance.accent.r ~= barAccent.r or context.bar.appearance.accent.g ~= barAccent.g then
    error("the plate's own accent reached the bar as well")
  end
  -- The axis it did NOT state still follows the bar, which is what makes one
  -- tweak survive the bar changing skin underneath it.
  if plate.appearance.background.r ~= context.bar.appearance.background.r then
    error("an axis the plate never stated stopped following the bar")
  end

  -- A text size of its own moves the plate's own arithmetic -- and only that: the
  -- plate has never read the skin's text size, so the bar's 11 does not reach it.
  save(SettingKey.PLATE_APPEARANCE, { text = { size = 16 } })
  openAFight()
  local big = plateLayout(2, 2)
  local titlePoint = plate.title.points[1]
  if titlePoint == nil or titlePoint[5] ~= -big.header.title then
    error("the plate's caption ignored the text size it was given")
  end
  if plate.xp.font.size ~= big.font.headline then
    error("the headline was drawn at " .. tostring(plate.xp.font.size))
  end
  if plate.frame:GetHeight() ~= big.height then
    error("a plate with bigger text did not grow to " .. tostring(big.height))
  end

  -- An axis of the map that reaches the EFFECTS has to reach the signature that
  -- decides whether they are rebuilt. An animation group cannot be destroyed, so
  -- a rebuild skipped in silence leaves the old one playing for good.
  save(SettingKey.PLATE_APPEARANCE, { effects = { glow = { color = { r = 1, g = 0, b = 0, a = 0.25 } } } })
  openAFight()
  if plate.effectSignature == signature or plate.glow == glow then
    error("an effect the plate's own map moved did not rebuild the effects")
  end
  local dimmed = plate.effectSignature
  save(SettingKey.PLATE_APPEARANCE, { effects = { glow = { color = { r = 1, g = 0, b = 0, a = 1 } } } })
  openAFight()
  if plate.effectSignature == dimmed then
    error("an effect colour that changed only in alpha left the signature alone")
  end

  save(SettingKey.PLATE_APPEARANCE, {})
  openAFight()
  if plate.appearance.accent.r ~= barAccent.r then
    error("clearing the plate's own map left it wearing one")
  end
  context.plate:hide()
end)

-- ---------------------------------------------------------------------------
-- The plate's page in the options panel (tasks.md group 4). ui/ has no unit
-- test, so each of these drives the real handlers the panel registered -- a
-- click, a drag, a release, an OnShow -- and asserts on what the stand-in client
-- was actually told, never on the addon merely not raising.
-- ---------------------------------------------------------------------------

-- The client's own SetValue FIRES OnValueChanged; the stand-in's is auto-stubbed
-- and records nothing. Both halves of that matter here: the guard against a page
-- writing settings merely by opening only exists because of the first, and a
-- control refreshed into the void cannot be read back because of the second. So
-- the client's behaviour is put back for the length of a step, and taken off
-- again afterwards -- including the auto-stub that was cached on the frame, or
-- the next access would silently build another one.
local function withLiveSliders(names, fn, dispatch)
  local restore = {}
  for _, name in ipairs(names) do
    local widget = _G[name]
    if widget == nil then
      error(name .. " was never built")
    end
    restore[widget] = { set = rawget(widget, "SetValue"), get = rawget(widget, "GetValue") }
    widget.SetValue = function(self, value)
      self.value = value
      local handler = self.scripts and self.scripts.OnValueChanged
      if dispatch and handler ~= nil then
        handler(self, value)
      end
    end
  end
  local ok, err = pcall(fn)
  for widget, saved in pairs(restore) do
    widget.SetValue, widget.GetValue = saved.set, saved.get
  end
  if not ok then
    error(err, 0)
  end
end

-- Dragging a slider to a value and letting go, the way the player does it. The
-- release reads the slider's OWN value, which the stand-in answers 1 to whatever
-- happened, so the value under the mouse is stated here and taken away after.
local function dragSlider(name, value)
  local slider = _G[name]
  if slider == nil then
    error(name .. " was never built")
  end
  local realGetValue = rawget(slider, "GetValue")
  slider.GetValue = function() return value end
  local handler = slider.scripts and slider.scripts.OnValueChanged
  if handler ~= nil then
    handler(slider, value)
  end
  local ok, err = pcall(slider.scripts.OnMouseUp, slider, "LeftButton")
  slider.GetValue = realGetValue
  if not ok then
    error(err, 0)
  end
end

local PLATE_FRAME_SLIDERS = {
  "AscentOptionsPlateScaleSlider", "AscentOptionsPlateWidthSlider",
  "AscentOptionsPlateOpacitySlider", "AscentOptionsPlateHoldSlider",
}

-- 4.3: the four sliders of the frame preview while they move and write when they
-- are let go. The guard that makes the first half possible is the one worth the
-- step: setting a slider's value fires its own handler, previewing resizes the
-- real surface, and so merely OPENING the page would otherwise resize the
-- player's plate to whatever the slider's bounds allowed.
plateStep("opening the plate page changes nothing, and dragging a slider writes once", function()
  local SettingKey = ns.core.SettingKey
  local frame = context.plate.frame

  context.saveSetting(SettingKey.PLATE_WIDTH, 260)

  withLiveSliders(PLATE_FRAME_SLIDERS, function()
    -- A width no slider on the page could produce, so a preview that ran shows
    -- up as the frame no longer wearing it.
    frame:SetWidth(999)
    local onShow = context.optionsPanel:GetScript("OnShow")
    onShow(context.optionsPanel)

    if frame:GetWidth() ~= 999 then
      error(("opening the page previewed and resized the plate to %s")
        :format(tostring(frame:GetWidth())))
    end
    if context.settings()[SettingKey.PLATE_WIDTH] ~= 260 then
      error("opening the page wrote a setting")
    end

    -- And a real drag: the preview lands on the frame, and nothing is persisted
    -- until the mouse comes up.
    local slider = _G.AscentOptionsPlateWidthSlider
    slider.scripts.OnValueChanged(slider, 300)
    if frame:GetWidth() ~= 300 then
      error(("dragging the width previewed %s"):format(tostring(frame:GetWidth())))
    end
    if context.settings()[SettingKey.PLATE_WIDTH] ~= 260 then
      error("dragging wrote the setting before the mouse came up")
    end
  end, true)

  dragSlider("AscentOptionsPlateWidthSlider", 300)
  if context.settings()[SettingKey.PLATE_WIDTH] ~= 300 then
    error(("letting go of the width wrote %s")
      :format(tostring(context.settings()[SettingKey.PLATE_WIDTH])))
  end

  -- The other three write their own setting and nobody else's: four sliders
  -- wired to three settings would be a page where one control moves two things.
  dragSlider("AscentOptionsPlateScaleSlider", 1.25)
  dragSlider("AscentOptionsPlateOpacitySlider", 0.6)
  dragSlider("AscentOptionsPlateHoldSlider", 9)
  for key, want in pairs({ [SettingKey.PLATE_SCALE] = 1.25, [SettingKey.PLATE_OPACITY] = 0.6,
                           [SettingKey.PLATE_HOLD_SECONDS] = 9, [SettingKey.PLATE_WIDTH] = 300 }) do
    if context.settings()[key] ~= want then
      error(("%s reads %s after its slider was dragged to %s")
        :format(key, tostring(context.settings()[key]), tostring(want)))
    end
  end

  -- D89's other half, which is the whole reason this slider is not cosmetic: how
  -- long the plaque stays IS how long a closed pull can be carried on, read live
  -- rather than captured at construction.
  if context.pullTracker:resumeWindow() ~= 9 + ns.ui.PullPlateView.FADE_SECONDS then
    error(("the resume window stayed at %s with the plaque held for 9")
      :format(tostring(context.pullTracker:resumeWindow())))
  end
end)

-- 4.4: the content block. What is stored is a SET of choices, so the list comes
-- back in the order the plate draws them and never in the order the boxes were
-- ticked (D90) -- and every box off is an answer, not a corrupt file.
plateStep("ticking a zone writes the list in the plate's order, and none is a choice", function()
  local SettingKey, PlateZone, TextKey = ns.core.SettingKey, ns.core.PlateZone, ns.core.TextKey
  local content = _G.AscentOptionsPlateScroll.scrollChild
  local wanted = context.locale:get(TextKey.OPT_PLATE_ZONES_NONE)

  -- The note that says an empty selection is a choice. It has no name of its
  -- own, like the bar's, so it is found by the words the player reads -- and
  -- found ONCE, while it is showing: refresh empties it as well as hiding it,
  -- because the section below is anchored to it and a hidden font string keeps
  -- the height of the text it last held.
  local note

  local function tick(name, checked)
    local check = _G[name]
    if check == nil then error(name .. " was never built") end
    -- The client's checkbox template flips itself and THEN runs OnClick, so the
    -- handler reads the state the player just chose.
    check:SetChecked(checked)
    check.scripts.OnClick(check, "LeftButton")
  end

  context.saveSetting(SettingKey.PLATE_ZONES, {})
  for _, child in ipairs(content.children) do
    if child.text == wanted then
      note = child
    end
  end
  if note == nil or not note.shown then
    error("every zone off and the page says nothing about it")
  end

  -- Ticked in the wrong order on purpose: the footer is the LAST zone the plate
  -- draws and the clock the first, so a list stored in the order they were
  -- clicked would come back with the footer at the front.
  tick("AscentOptionsPlateZone7CheckButton", true)
  tick("AscentOptionsPlateZone1CheckButton", true)

  local stored = context.settings()[SettingKey.PLATE_ZONES]
  if #stored ~= 2 or stored[1] ~= PlateZone.CLOCK or stored[2] ~= PlateZone.FOOTER then
    error(("the boxes stored %s, not the clock then the footer")
      :format(table.concat(stored, ", ")))
  end
  if note.shown or (note.text or "") ~= "" then
    error("two zones on and the page still says there are none")
  end

  -- Unticking the last of them is a choice the page states rather than argues
  -- with -- the same note, for the same reason, as a bar with no text.
  tick("AscentOptionsPlateZone1CheckButton", false)
  tick("AscentOptionsPlateZone7CheckButton", false)
  if #context.settings()[SettingKey.PLATE_ZONES] ~= 0 then
    error("unticking the last zone left something in the list")
  end
  if not note.shown or note.text ~= wanted then
    error("every zone off again and the note never came back")
  end

  -- There is a box for every zone the vocabulary names, counted against the
  -- vocabulary and not against seven: a zone added there and forgotten on this
  -- page is a zone nobody can turn off, and nothing else would say so.
  for _, name in ipairs(ns.core.Frozen.keys(PlateZone)) do
    local zone, found = PlateZone[name], false
    for index = 1, #ns.core.Frozen.keys(PlateZone) do
      local check = _G["AscentOptionsPlateZone" .. index .. "CheckButton"]
      if check ~= nil then
        context.saveSetting(SettingKey.PLATE_ZONES, { zone })
        if check:GetChecked() then
          found = true
        end
      end
    end
    if not found then
      error("no box on the page turns " .. tostring(zone) .. " off")
    end
  end

  dragSlider("AscentOptionsPlateRowsSlider", 3)
  if context.settings()[SettingKey.PLATE_ROWS] ~= 3 then
    error(("asking for three rows stored %s")
      :format(tostring(context.settings()[SettingKey.PLATE_ROWS])))
  end
end)

-- 4.5: the three axes of the plate's own map, each with a reset that is on screen
-- only while that axis really is the player's. What is left showing after a skin
-- change is therefore exactly the list of their own tweaks still being applied
-- over the new one -- the other thing this surface has to say.
plateStep("each axis of the plate's own look resets on its own, and says when it can", function()
  local SettingKey = ns.core.SettingKey

  -- Reading an axis off a map that may be frozen and may not hold it at all.
  local function at(node, key)
    if node == nil then return nil end
    if ns.core.Frozen.isFrozen(node) then
      return ns.core.Frozen.has(node, key) and node[key] or nil
    end
    return node[key]
  end

  context.saveSetting(SettingKey.PLATE_APPEARANCE, {})
  local backgroundReset = _G.AscentOptionsPlateLook1Reset
  local textReset = _G.AscentOptionsPlateLook3Reset
  if backgroundReset == nil or textReset == nil then
    error("the plate page built no per-axis reset")
  end
  if backgroundReset:IsShown() or textReset:IsShown() then
    error("a plate axis nobody has touched is offering to reset itself")
  end

  dragSlider("AscentOptionsPlateLook1Slider", 0.4)
  dragSlider("AscentOptionsPlateLook3Slider", 16)

  local own = context.settings()[SettingKey.PLATE_APPEARANCE]
  if at(at(own, "background"), "a") ~= 0.4 then
    error("the plate's own background opacity did not reach its map")
  end
  -- The text size is the axis the plate reads off its OWN map and nowhere else,
  -- which is what PullPlateView:ownTextSize asks for: a key of its own would be
  -- a second place to look and a third thing to keep in step.
  if at(at(own, "text"), "size") ~= 16 then
    error("the text size went somewhere other than the plate's own map")
  end
  if not backgroundReset:IsShown() or not textReset:IsShown() then
    error("an axis the player just set is not offering to reset itself")
  end

  textReset.scripts.OnClick(textReset, "LeftButton")
  own = context.settings()[SettingKey.PLATE_APPEARANCE]
  if at(at(own, "text"), "size") ~= nil then
    error("resetting the text size left it behind")
  end
  if at(at(own, "background"), "a") ~= 0.4 then
    error("resetting the text size took the background opacity with it")
  end
  -- The empty branch is pruned on the way back up. An override map still
  -- carrying `text = {}` reads as "the player touched the text", which would
  -- leave this button on screen for a setting nobody holds any more.
  if at(own, "text") ~= nil then
    error("resetting the last axis of a branch left the empty branch behind")
  end
  if textReset:IsShown() then
    error("the reset stayed on screen after the axis went back to the skin")
  end
  if not backgroundReset:IsShown() then
    error("resetting one axis took the other's reset off screen")
  end
end)

-- 4.7: every new control is written in the refresh, which is shared by all seven
-- pages. A control left out of it shows stale state with no error at all -- and
-- these settings are the ones a chat command is likeliest to have moved while the
-- panel was open.
plateStep("a plate setting changed from outside the panel shows on its page", function()
  local SettingKey, PlateZone = ns.core.SettingKey, ns.core.PlateZone
  local wasEnabled = context.settings()[SettingKey.PLATE_ENABLED]

  -- From outside the panel, the way the spec means it: a chat command for the
  -- one setting that has one, and saveSetting -- which is what every command
  -- goes through -- for the rest.
  SlashCmdList["ASCENT"]("options plate off")
  context.saveSetting(SettingKey.PLATE_WIDTH, 420)
  context.saveSetting(SettingKey.PLATE_ROWS, 5)
  context.saveSetting(SettingKey.PLATE_ZONES, { PlateZone.CLOCK })
  context.saveSetting(SettingKey.PLATE_APPEARANCE, { text = { size = 14 } })

  withLiveSliders({ "AscentOptionsPlateWidthSlider", "AscentOptionsPlateRowsSlider",
                    "AscentOptionsPlateLook3Slider" }, function()
    -- Scrambled first, and that is what makes this a test of the REFRESH rather
    -- than of saveSetting: every write above already refreshed the panel, so a
    -- control that is right because nothing touched it proves nothing.
    _G.AscentOptionsPlateWidthSlider.value = -1
    _G.AscentOptionsPlateRowsSlider.value = -1
    _G.AscentOptionsPlateLook3Slider.value = -1
    _G.AscentOptionsPlateEnabledCheckButton:SetChecked(true)
    _G.AscentOptionsPlateZone1CheckButton:SetChecked(false)
    _G.AscentOptionsPlateZone7CheckButton:SetChecked(true)

    local onShow = context.optionsPanel:GetScript("OnShow")
    onShow(context.optionsPanel)

    if _G.AscentOptionsPlateEnabledCheckButton:GetChecked() then
      error("the page still shows the plate as on after it was switched off")
    end
    for name, want in pairs({ AscentOptionsPlateWidthSlider = 420,
                              AscentOptionsPlateRowsSlider = 5,
                              AscentOptionsPlateLook3Slider = 14 }) do
      if _G[name].value ~= want then
        error(("%s shows %s where the setting reads %s")
          :format(name, tostring(_G[name].value), tostring(want)))
      end
    end
    if not _G.AscentOptionsPlateZone1CheckButton:GetChecked() then
      error("the only zone left on does not read as on")
    end
    if _G.AscentOptionsPlateZone7CheckButton:GetChecked() then
      error("a zone that was turned off still reads as on")
    end
    if not _G.AscentOptionsPlateLook3Reset:IsShown() then
      error("an axis set from outside the panel offers no way back")
    end
  end, false)

  context.saveSetting(SettingKey.PLATE_ENABLED, wasEnabled)
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

-- THE VERSION CHECK, driven from the composition root.
--
-- The channel itself is covered by its own spec against a stand-in client; what
-- can only be seen from here is the wiring: that the command exists, that the
-- window opens, and that a client with no addon channel at all -- which is
-- exactly what this harness is -- loads anyway and says what it turned off.

step("a client with no addon channel loads, and names what it turned off", function()
  local mark = #chatLines + 1
  slash("debug")

  if chatSince(mark, "addon_messages") == nil then
    error("the diagnostic does not mention the addon message channel at all")
  end
  local missing = chatSince(mark, "missing capabilities")
  if missing == nil or not missing:find("addon_messages", 1, true) then
    error("this harness defines no C_ChatInfo, so the channel must read as missing: "
      .. tostring(missing))
  end
end)

step("an update announces itself once, and is remembered", function()
  local said
  for _, line in ipairs(chatLines) do
    if line:find("updated to ", 1, true) then
      said = line
    end
  end
  if said == nil then
    error("loading over an older remembered version said nothing about it")
  end

  -- Remembered, or the same notice would greet the player on every login.
  local remembered = AscentDB.settings.last_seen_version
  if remembered == nil or remembered == "0.0.1" then
    error("the version in hand was not written back: " .. tostring(remembered))
  end
  if not said:find(remembered, 1, true) then
    error(("the notice named a different version than the one remembered: %s vs %s")
      :format(said, remembered))
  end
end)

-- ONE PLACE TO LOOK. The flight recorder used to be a top-level command beside
-- `debug`, which meant a player chasing one thing had to know which of the two
-- words held it -- the same reason the three diagnostic dumps were folded into
-- one before this. The old spelling has to be gone, not merely unadvertised:
-- a command that still half-answers is worse than one that says it does not exist.
step("the recorder answers under debug, and the old spelling does not answer at all", function()
  local mark = #chatLines + 1
  slash("debug evidence on")
  if chatSince(mark, "evidence recording on") == nil then
    error("`debug evidence on` did not turn the recorder on")
  end

  mark = #chatLines + 1
  slash("debug evidence off")
  if chatSince(mark, "evidence recording off") == nil then
    error("`debug evidence off` did not turn it off")
  end

  mark = #chatLines + 1
  slash("evidence on")
  if chatSince(mark, "evidence recording on") ~= nil then
    error("the old top-level command still works; there are two doors again")
  end
  if chatSince(mark, "evidence") == nil then
    error("an unknown subcommand said nothing at all")
  end
end)

step("the help offers what exists, and nothing that does not", function()
  local mark = #chatLines + 1
  slash("help")

  local rows = {}
  for index = mark, #chatLines do
    rows[#rows + 1] = chatLines[index]
  end
  local help = table.concat(rows, "\n")

  -- `debug quests` and `debug strings` were folded into `debug` itself, and the
  -- help went on offering them for months. Advertising a subcommand that no
  -- longer answers is the same bug as hiding one that does.
  if help:find("quests|strings", 1, true) then
    error("the help still offers subcommands that were folded away")
  end
  if not help:find("debug [evidence", 1, true) then
    error("the help does not say the recorder lives under debug: " .. help)
  end
  for _, row in ipairs(rows) do
    if row:find("/ascent evidence ", 1, true) then
      error("the help still lists evidence as a command of its own: " .. row)
    end
  end
end)

step("the help names the changelog, because a command not in it does not exist", function()
  local mark = #chatLines + 1
  slash("help")

  if chatSince(mark, "changelog") == nil then
    error("the help does not offer the changelog")
  end
end)

-- 5.1, the half that answers. `skin` and `slot` already print what they are set
-- to when asked with no argument, and the plate is the surface that needs it
-- most: it is the one a player can lose. Off, transparent, or dropped past the
-- edge of the screen all look identical from the chair -- nothing appears when a
-- fight starts -- and these four lines are what tell them apart.
--
-- Every value it is asked about is moved off its default first, deliberately. A
-- status print wired to the constants instead of to the settings would answer
-- correctly for a plate nobody had touched, which is the one plate nobody asks
-- about.
step("the plate says what state it is in, which is how a lost one is found", function()
  local SettingKey, PlateZone = ns.core.SettingKey, ns.core.PlateZone

  context.saveSetting(SettingKey.PLATE_LOCKED, true)
  context.saveSetting(SettingKey.PLATE_WIDTH, 317)
  context.saveSetting(SettingKey.PLATE_OPACITY, 0.35)
  context.saveSetting(SettingKey.PLATE_HOLD_SECONDS, 11)
  context.saveSetting(SettingKey.PLATE_ROWS, 2)
  context.saveSetting(SettingKey.PLATE_POSITION,
    { point = "TOPLEFT", relativePoint = "TOPLEFT", x = -940, y = 77 })
  -- Stored footer-first, which is NOT the order the plate draws them in.
  context.saveSetting(SettingKey.PLATE_ZONES, { PlateZone.FOOTER, PlateZone.CLOCK })

  local mark = #chatLines + 1
  slash("options plate")

  for _, needle in ipairs({ "locked: true", "317", "0.35", "11", "TOPLEFT", "-940", "77" }) do
    if chatSince(mark, needle) == nil then
      error("the plate's state never mentioned " .. needle)
    end
  end

  -- The order drawn, not the order stored (D90): the clock is above the footer,
  -- and what is printed has to be what the player will see.
  local zones = chatSince(mark, "zones:")
  if zones == nil or not zones:find("clock, footer", 1, true) then
    error("the zones were not printed in the order the plate draws them: " .. tostring(zones))
  end
end)

-- 5.1, the half that undoes. This is the ONLY way back for the plate: its page
-- is reached by clicking, and the plate the step above just left at 35% opacity
-- in the top-left corner is exactly the plate that cannot be clicked.
--
-- Two claims, and the second is the one with teeth: every key the plate owns
-- comes back, and not one of the bar's goes with it. The plate follows the bar's
-- skin, palette and contrast (D87), so a reset that reasoned about "appearance"
-- rather than about ownership would take the other surface's choices with it.
step("resetting the plate returns every key it owns and leaves the bar's alone", function()
  local SettingKey, Frozen = ns.core.SettingKey, ns.core.Frozen

  -- Borrowed, and given back at the bottom: the rest of the harness runs against
  -- whatever the bar was left at, so this step must not decide that for it.
  local borrowed = context.settings()
  local skin = borrowed[SettingKey.BAR_SKIN]
  local contrast = borrowed[SettingKey.HIGH_CONTRAST]
  local barWidth = borrowed[SettingKey.BAR_WIDTH]

  context.saveSetting(SettingKey.BAR_SKIN, "phantom")
  context.saveSetting(SettingKey.HIGH_CONTRAST, true)
  context.saveSetting(SettingKey.BAR_WIDTH, 512)

  slash("options plate reset")

  -- Compared key by key against the defaults, through the very list the command
  -- resets by: a plate key added to that list and skipped by the command would
  -- otherwise pass here by never being looked at.
  local function matchesDefault(value, default)
    if Frozen.isFrozen(default) then
      for key, inner in Frozen.each(default) do
        if not matchesDefault(value[key], inner) then return false end
      end
      return true
    end
    if type(default) == "table" then
      if type(value) ~= "table" then return false end
      -- An empty default is EMPTY, not merely short. The plate's own appearance
      -- map is one (D87), and a leftover axis in it has no index for `#` to
      -- count -- nor does a frozen proxy, which reads as empty from outside.
      if next(default) == nil then
        return not Frozen.isFrozen(value) and next(value) == nil
      end
      if #value ~= #default then return false end
      for index = 1, #default do
        if not matchesDefault(value[index], default[index]) then return false end
      end
      return true
    end
    return value == default
  end

  local settings = context.settings()
  for _, key in ipairs(ns.core.PlateSettingKeys) do
    if not matchesDefault(settings[key], ns.core.Defaults[key]) then
      error(key .. " did not come back to its default")
    end
  end

  -- What reached the repository, not what `resolve` handed back. Storing the
  -- default itself would put the addon's own constants one write away from the
  -- player's saved variables, and a frozen map stored that way reaches disk as
  -- the empty carrier it is -- a reset that loses itself by the next session.
  local stored = context.repository:settings()
  for _, key in ipairs(ns.core.PlateSettingKeys) do
    if Frozen.isFrozen(stored[key]) then
      error(key .. " was stored as a frozen proxy, which reaches disk empty")
    end
    if type(ns.core.Defaults[key]) == "table" and stored[key] == ns.core.Defaults[key] then
      error(key .. " was stored as the default table itself rather than as a copy")
    end
  end

  if settings[SettingKey.BAR_SKIN] ~= "phantom" or settings[SettingKey.HIGH_CONTRAST] ~= true
    or settings[SettingKey.BAR_WIDTH] ~= 512 then
    error("resetting the plate reached the bar's own choices")
  end

  context.saveSetting(SettingKey.BAR_SKIN, skin)
  context.saveSetting(SettingKey.HIGH_CONTRAST, contrast)
  context.saveSetting(SettingKey.BAR_WIDTH, barWidth)
end)

-- 5.2. The line had shipped three subcommands short -- `plate`, `slot` and
-- `panel` -- which is the same defect as advertising one that was folded away,
-- read from the other side: a player who never learns `plate reset` has no way
-- back to a plate they dragged off the screen.
--
-- Checked by RUNNING what the line announces rather than by matching it against a
-- list written here, which would be a second copy of the vocabulary to keep.
step("every option the help announces is one the addon answers", function()
  local mark = #chatLines + 1
  slash("help")

  local row
  for index = mark, #chatLines do
    if chatLines[index]:find("/ascent options ", 1, true) then
      row = chatLines[index]
    end
  end
  if row == nil then
    error("the help does not mention the options command at all")
  end

  local inside = row:match("%[(.+)%]")
  if inside == nil then
    error("the options line announces no subcommands: " .. row)
  end

  -- The alternatives at the top level of the bracket. Depth-aware because the
  -- ones that take an argument spell it inline -- `plate [on|off|demo|reset]` --
  -- and a plain split on "|" would offer "off" as a subcommand in its own right.
  local alternatives, depth, piece = {}, 0, ""
  for index = 1, #inside do
    local char = inside:sub(index, index)
    if char == "[" or char == "<" then depth = depth + 1 end
    if char == "]" or char == ">" then depth = depth - 1 end
    if char == "|" and depth == 0 then
      alternatives[#alternatives + 1] = piece
      piece = ""
    else
      piece = piece .. char
    end
  end
  alternatives[#alternatives + 1] = piece

  local announced = {}
  for _, alternative in ipairs(alternatives) do
    local keyword = alternative:match("^%s*(%a+)")
    if keyword == nil then
      error("the options line offers an alternative with no keyword: " .. alternative)
    end
    local before = #chatLines + 1
    slash("options " .. keyword)
    if chatSince(before, "is not an Ascent option") ~= nil then
      error("the help offers `options " .. keyword .. "`, which the addon does not answer")
    end
    announced[keyword] = true
  end

  -- Named explicitly because the loop above only proves that what IS announced
  -- answers; nothing in it would notice the line going short again.
  for _, keyword in ipairs({ "plate", "slot", "panel" }) do
    if not announced[keyword] then
      error("the options help still does not announce `" .. keyword .. "`")
    end
  end

  -- `lock` was one of the alternatives just run, and a locked bar is not the
  -- state this step found.
  slash("options unlock")
end)

step("the changelog opens as text, headed by the version being played", function()
  local dialog = _G["AscentCopyDialog"]
  if dialog ~= nil then dialog.shown = false end

  slash("changelog")

  dialog = _G["AscentCopyDialog"]
  if dialog == nil or not dialog.shown then
    error("no window was opened for the changelog")
  end

  local text
  for _, frame in ipairs(frames) do
    if frame.kind == "EditBox" and frame.text ~= nil then
      text = frame.text
    end
  end
  if text == nil or not text:find("what changed", 1, true) then
    error("the window did not open on the changelog: " .. tostring(text and text:sub(1, 80)))
  end
  -- Generated from CHANGELOG.md at build time, so the version in the TOC has to
  -- be in there. If this fails, the embedded changelog and the build disagree.
  if not text:find("running ", 1, true) then
    error("the changelog does not say which build this is")
  end
end)

step("the update check can be switched off from the options, both halves at once", function()
  local check = _G["AscentOptionsUpdateCheckCheckButton"]
  if check == nil then
    error("the behaviour page has no switch for the update check")
  end

  local onClick = check:GetScript("OnClick")
  if onClick == nil then
    error("the switch was built without a handler")
  end

  -- Off, and the composition root has to have applied it to the watch itself --
  -- not merely stored it -- or the addon would keep announcing after being told
  -- to stop (design D74).
  check.checked = false
  onClick(check)
  if context.settings()[ns.core.SettingKey.UPDATE_CHECK] ~= false then
    error("switching it off did not reach the settings")
  end

  check.checked = true
  onClick(check)
  if context.settings()[ns.core.SettingKey.UPDATE_CHECK] ~= true then
    error("switching it back on did not reach the settings")
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
