-- Ascent - the client's own experience bar, as a place to stand.
--
-- Two jobs, and they are not the same one. The first is to hand the view a frame
-- to anchor to, so that "same length, same position" is a property of the anchor
-- rather than two copies of a geometry somebody has to keep in step (D47). The
-- second is to make the client's bar stop being seen without ever calling
-- anything the client protects.
--
-- WHY NOT HIDE IT: hiding is protected on a child of the main bar, so it fails in
-- combat -- precisely when the player cannot read the error. Alpha is not
-- protected. And a frame left shown keeps a geometry that means something, which
-- is what the anchor hangs off; a hidden one would still have a size, but then the
-- addon would be inheriting position from a frame the client shows and hides on
-- its own schedule (at maximum level, for one). This module takes position and
-- size from it and never its visibility (D48).
--
-- WHY THE NAMES ARE DATA: every name below is a string looked up in _G at call
-- time, not a global this file binds to. Two reasons. The design only has it
-- verified that 1.12.1 and 2.4.3 expose MainMenuExpBar and that 1.15.9 drives it
-- through an ExpBarMixin -- whether the tree around it is the same on both
-- supported flavours is exactly what spike 0.2 is for, so these names are a
-- hypothesis with one edit site, not an API this code is entitled to. And a name
-- that is absent is an ordinary Tuesday here: another addon may have taken the
-- bar away, and that has to degrade rather than error (D49).

local _, ns = ...
ns.adapter = ns.adapter or {}

local BarSlotPolicy = ns.core.BarSlotPolicy
local BarSlot = ns.core.BarSlot

-- The frame the addon's bar anchors to, in the order it is looked for. There are
-- two different clients behind this list, and spike 0.2 is what found the second
-- one: the Anniversary Burning Crusade client has NO MainMenuExpBar and none of
-- its readouts -- the whole classic tree is absent -- and keeps its experience bar
-- in the modern status-tracking system instead. Measured there:
--
--   MainStatusTrackingBarContainer  1024x12   <- the strip the bar occupies
--   StatusTrackingBarManager        1024x23   <- the manager above it
--   MainMenuBar                     1024x53   <- the whole bar, too tall to be it
--
-- The container is what "same length, same position" means on that client, so it
-- comes before the manager. First one present wins.
local ANCHOR_NAMES = {
  "MainMenuExpBar",
  "MainStatusTrackingBarContainer",
  "StatusTrackingBarManager",
}

-- What has to go quiet, besides the anchor itself, for the client's bar to stop
-- being seen: the number over it and the two pieces that draw rested. All three
-- belong to the classic tree; on the modern system they do not exist as globals
-- -- the bar draws its own -- and quieting the anchor is the whole of it.
local READOUT_NAMES = {
  "MainMenuBarExpText",
  "ExhaustionTick",
  "ExhaustionLevelFillBar",
}

-- The art the client draws AROUND the bar. Left alone in the inset slot -- that is
-- the whole difference between the two -- and quieted in the replace slot.
--
-- Classic-tree names only. On the modern system that art is a child of the
-- container rather than a global, so there is nothing here to reach: the two
-- slots look the same on that client, and the honest place to say so is here.
local FRAME_NAMES = {
  "MainMenuXPBarTextureLeftCap",
  "MainMenuXPBarTextureRightCap",
  "MainMenuXPBarTextureMid",
}

-- Names this module does NOT use, probed only so the diagnostic can say what the
-- client has instead when the ones above are not there. Spike 0.2 is a question
-- about a client nobody here can open, and a player can answer it from a chat
-- window in one line -- but only if the addon asks it out loud.
local CANDIDATE_NAMES = {
  "MainMenuBar",
  "MainMenuExpBar1",
  "ExpBar",
}

local ClientXpBar = {}
ClientXpBar.__index = ClientXpBar

function ClientXpBar.new()
  -- name -> what that object looked like before this addon touched it. Empty
  -- means the client's bar is exactly as the client left it.
  return setmetatable({ quieted = {} }, ClientXpBar)
end

-- A texture and a font string take SetAlpha but not EnableMouse; a frame takes
-- both. Asking the object rather than assuming its kind is what lets one list hold
-- all of them.
local function capture(object)
  return {
    object = object,
    alpha = object.GetAlpha ~= nil and object:GetAlpha() or nil,
    mouse = object.IsMouseEnabled ~= nil and object:IsMouseEnabled() or nil,
  }
end

-- Whether the object is showing at all right now. An unknown alpha counts as
-- visible: the addon's business is what it can see, and a piece that cannot
-- answer is not evidence of being hidden.
local function visible(object)
  if object.GetAlpha == nil then
    return true
  end
  local alpha = object:GetAlpha()
  return type(alpha) ~= "number" or alpha > 0
end

local function quiet(object)
  if object.SetAlpha ~= nil then
    object:SetAlpha(0)
  end
  if object.EnableMouse ~= nil then
    object:EnableMouse(false)
  end
end

-- Puts back exactly what was there, including the case that matters: a piece that
-- was ALREADY invisible before Ascent existed -- another addon's doing, or the
-- client's -- must be left invisible, not turned on because this addon assumed
-- full opacity was the natural state.
local function giveBack(prior)
  if prior.alpha ~= nil then
    prior.object:SetAlpha(prior.alpha)
  end
  if prior.mouse ~= nil then
    prior.object:EnableMouse(prior.mouse)
  end
end

-- Which of the candidates this client actually has, or nil for a client that has
-- none. `GetWidth` rather than a type check: what the caller needs from it is a
-- geometry, and a name another addon has taken for something else offers none.
function ClientXpBar:anchorName()
  for _, name in ipairs(ANCHOR_NAMES) do
    local object = _G[name]
    if type(object) == "table" and object.GetWidth ~= nil then
      return name
    end
  end
  return nil
end

-- The frame to anchor to, or nil when this client does not have one.
function ClientXpBar:frame()
  local name = self:anchorName()
  if name == nil then
    return nil
  end
  return _G[name]
end

function ClientXpBar:present()
  return self:frame() ~= nil
end

-- The slot the addon can actually honour right now. A player who chose a slot on a
-- client that has the bar, and then installs something that takes the bar away,
-- gets their free bar back -- and keeps their choice on disk, so uninstalling that
-- addon brings the slot back without them having to find the setting again (D49).
function ClientXpBar:effectiveSlot(chosen)
  if not self:present() then
    return BarSlot.OFF
  end
  return chosen
end

-- Converge on a desired set of quiet objects: give back anything that should be
-- seen again, quiet anything that should not, and leave the rest alone. Written as
-- a convergence rather than a silence/restore pair because the player can switch
-- between the two active slots without passing through off, and because it makes
-- re-application idempotent -- calling it again never records alpha zero as the
-- value to give back later.
-- An entry is either a global's name, or a pair of a key and the object itself.
-- The second form exists because the modern client's experience bar has no global
-- name of its own: it is a child of the container, reachable only by walking
-- there (see barsInside).
local function resolve(entry)
  if type(entry) == "table" then
    return entry.key, entry.object
  end
  return entry, _G[entry]
end

function ClientXpBar:applyQuiet(entries)
  local wanted = {}
  for _, entry in ipairs(entries) do
    wanted[(resolve(entry))] = true
  end

  for name, prior in pairs(self.quieted) do
    if not wanted[name] then
      giveBack(prior)
      self.quieted[name] = nil
    end
  end

  for _, entry in ipairs(entries) do
    local name, object = resolve(entry)
    -- Only what is actually visible. A piece that was already invisible when this
    -- addon arrived is already quiet, and there is nothing here to do -- while
    -- recording it would be recording somebody else's state as ours to give back.
    --
    -- That distinction is not academic. The client hides pieces of its own bar
    -- during a loading screen, and other addons hide them on purpose; capture one
    -- of those transients and "giving it back" means setting it invisible again,
    -- for good. The native bar frame left hidden is what that looks like from
    -- the outside.
    if type(object) == "table" and (self.quieted[name] ~= nil or visible(object)) then
      if self.quieted[name] == nil then
        self.quieted[name] = capture(object)
      end
      quiet(object)
    end
  end
end

-- What the slot the player chose means for the client's bar. Safe to call on every
-- settings change and on every event the client's bar reacts to: it is the same
-- convergence either way, which is what keeps the alpha applied if the client's
-- own code puts it back (the risk spike 0.3 measures).
-- How deep to look for the bar inside the anchor. Two: on the modern client the
-- container holds a bar frame, and the bar frame holds the StatusBar.
local BARS_DEPTH = 2

-- The status bars living inside a frame, as key/object pairs. Empty for a client
-- whose anchor IS the bar rather than a container around one.
--
-- This is what makes the inset slot possible on the modern client, and its
-- absence is the defect the owner reported as "I change the appearance and the
-- native bars disappear". The anchor there is MainStatusTrackingBarContainer, and
-- the art of the frame is its CHILD -- so quieting the anchor, which is what both
-- slots did, took the frame with it. Inset promises the opposite: the client's
-- frame stays and the bar sits inside it. Reaching the status bar itself and
-- leaving everything around it is the only way to keep that promise.
--
-- Recognised by GetStatusBarTexture rather than by name, because on that client
-- the bar has no global name to look up -- it is only reachable by walking here.
function ClientXpBar:barsInside(frame)
  local found = {}
  if frame == nil or frame.GetChildren == nil then
    return found
  end

  local function walk(parent, depth, path)
    if depth > BARS_DEPTH or parent.GetChildren == nil then
      return
    end
    local ok, children = pcall(function() return { parent:GetChildren() } end)
    if not ok then
      return
    end
    for index, child in ipairs(children) do
      if type(child) == "table" then
        local key = ("%s/%d"):format(path, index)
        if child.GetStatusBarTexture ~= nil then
          found[#found + 1] = { key = key, object = child }
        else
          walk(child, depth + 1, key)
        end
      end
    end
  end

  walk(frame, 1, self:anchorName() or "anchor")
  return found
end

function ClientXpBar:applySlot(slot)
  if not BarSlotPolicy.active(slot) then
    return self:applyQuiet({})
  end

  -- The anchor first, because which frame that is depends on the client.
  local entries = {}
  local anchorName = self:anchorName()

  -- In the inset slot, reach past the anchor to the bar inside it when there is
  -- one: quieting the anchor there would take the client's frame down with it,
  -- which is the other slot's job. With no bar inside, the anchor IS the bar
  -- (the classic tree) and quieting it is exactly right.
  local inside = BarSlotPolicy.keepsClientFrame(slot) and self:barsInside(self:frame()) or {}
  if #inside > 0 then
    for _, entry in ipairs(inside) do
      entries[#entries + 1] = entry
    end
  else
    entries[#entries + 1] = anchorName
  end

  for _, name in ipairs(READOUT_NAMES) do
    entries[#entries + 1] = name
  end
  if not BarSlotPolicy.keepsClientFrame(slot) then
    for _, name in ipairs(FRAME_NAMES) do
      entries[#entries + 1] = name
    end
  end
  self:applyQuiet(entries)
end

-- Everything the client had, back. The reverse of any slot, from any slot.
function ClientXpBar:restore()
  self:applyQuiet({})
end

-- One row per name: what the client has under it, and how big it is. The
-- instrument for spike 0.2 and, in the same reading, for 0.4 -- the height it
-- reports is what decides whether the text has to leave the bar (D52).
--
-- Kept in the adapter because the names are here. A row is data, not a sentence:
-- who prints it and how is the composition root's business.
function ClientXpBar:inventory()
  local rows = {}

  -- `object` given for the pieces that have no global name -- the bars reached
  -- inside the anchor. Looked up by name otherwise, which is every fixed list.
  local function add(name, used, object)
    object = object or _G[name]
    local row = { name = name, used = used, present = type(object) == "table" }
    -- Both, asked for separately, for the same reason capture() asks before it
    -- calls: the list holds frames, textures and font strings, and not all of
    -- them answer the same questions.
    if row.present and object.GetWidth ~= nil and object.GetHeight ~= nil then
      row.width, row.height = object:GetWidth(), object:GetHeight()
    end
    -- Where in the drawing order it sits, which only a frame can answer -- a
    -- texture or a font string has no level of its own. It is the number the bar
    -- takes its own depth from (core BarSlotPolicy.depth), and printing both is
    -- what lets "the bar is painting over the client's frame" be read rather than
    -- photographed.
    if row.present and object.GetFrameLevel ~= nil and object.GetFrameStrata ~= nil then
      row.strata, row.level = object:GetFrameStrata(), object:GetFrameLevel()
    end
    rows[#rows + 1] = row
  end

  for _, name in ipairs(ANCHOR_NAMES) do add(name, true) end
  for _, name in ipairs(READOUT_NAMES) do add(name, true) end
  for _, name in ipairs(FRAME_NAMES) do add(name, true) end
  for _, name in ipairs(CANDIDATE_NAMES) do add(name, false) end

  -- What this addon is holding: the value it will give back, and what the piece
  -- reads now. Two numbers that should differ while a slot is active and match
  -- once it is not -- and a piece quieted with nothing recorded, or recorded as
  -- already invisible, is the shape of the bug where the client's bar is left
  -- hidden after the slot is turned off.
  -- Anything quieted that no fixed list names: the bars reached inside the
  -- anchor. They have no global name, so without this the diagnostic would show
  -- the container untouched and say nothing about what was actually silenced --
  -- which is precisely the question "did inset keep the client's frame?".
  local named = {}
  for _, row in ipairs(rows) do
    named[row.name] = true
  end
  for key, held in pairs(self.quieted) do
    if not named[key] then
      add(key, true, held.object)
    end
  end

  for _, row in ipairs(rows) do
    local held = self.quieted[row.name]
    if held ~= nil then
      row.quieted = true
      row.givesBack = held.alpha
      local object = _G[row.name]
      row.alphaNow = type(object) == "table" and object.GetAlpha ~= nil and object:GetAlpha() or nil
    end
  end
  return rows
end

ns.adapter.ClientXpBar = ClientXpBar
