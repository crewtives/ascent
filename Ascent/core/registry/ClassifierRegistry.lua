-- Ascent - the registry of experience classifiers.
--
-- Adding a source of experience is registering a descriptor and nothing else:
--
--   { id, priority, matches(hint), classify(hint) -> XpSource, payload(hint) }
--
-- The attribution service never learns the new source exists.
--
-- `amountOnly` marks a channel that says how much but never from what: the
-- client's anonymous "You gain %d experience." line, which quests emit, which
-- discoveries probably emit too, and which at least one published Classic addon
-- misreads as a kill. Such a classifier must not bring a `classify` function
-- (registering one is an error), so the rule lives in the descriptor's shape.
--
-- Priority breaks ties between channels that describe the same gain. The quest
-- event carries the quest id and the system echo of the same turn-in does not,
-- so the one with the id is offered the delta first; otherwise the gain would be
-- attributed correctly and still lose its quest id.

local _, ns = ...
ns.core = ns.core or {}

local Guard = ns.core.Guard
local XpSource = ns.core.XpSource

local ClassifierRegistry = {}
ClassifierRegistry.__index = ClassifierRegistry

function ClassifierRegistry.new()
  return setmetatable({ classifiers = {}, byId = {}, sorted = true }, ClassifierRegistry)
end

local function assertDescriptor(self, classifier)
  if type(classifier) ~= "table" then
    error("ClassifierRegistry: a classifier must be a table, got " .. type(classifier), 3)
  end

  local id = classifier.id
  if type(id) ~= "string" or id == "" then
    error("ClassifierRegistry: a classifier needs a non-empty string id", 3)
  end
  if self.byId[id] ~= nil then
    error("ClassifierRegistry: '" .. id .. "' is already registered", 3)
  end

  Guard.number(classifier.priority, "classifier '" .. id .. "' priority")

  if type(classifier.matches) ~= "function" then
    error("ClassifierRegistry: '" .. id .. "' needs a matches(hint) function", 3)
  end

  if classifier.amountOnly == true then
    if classifier.classify ~= nil then
      error("ClassifierRegistry: '" .. id .. "' is marked amount-only, so it must not bring a "
        .. "classify function: a channel that never names a source cannot resolve one", 3)
    end
  elseif type(classifier.classify) ~= "function" then
    error("ClassifierRegistry: '" .. id .. "' needs a classify(hint) function", 3)
  end

  if classifier.payload ~= nil and type(classifier.payload) ~= "function" then
    error("ClassifierRegistry: '" .. id .. "' payload must be a function, got "
      .. type(classifier.payload), 3)
  end
end

function ClassifierRegistry:register(classifier)
  assertDescriptor(self, classifier)

  local entry = {
    id = classifier.id,
    priority = classifier.priority,
    amountOnly = classifier.amountOnly == true,
    matches = classifier.matches,
    classify = classifier.classify,
    payload = classifier.payload,
  }

  self.classifiers[#self.classifiers + 1] = entry
  self.byId[entry.id] = entry
  self.sorted = false
  return self
end

-- Highest priority first, ties broken by id: table.sort is not stable, so without
-- the tie-break two classifiers of equal priority could swap places between runs
-- and make a failure impossible to reproduce.
local function ordered(self)
  if not self.sorted then
    table.sort(self.classifiers, function(a, b)
      if a.priority ~= b.priority then
        return a.priority > b.priority
      end
      return a.id < b.id
    end)
    self.sorted = true
  end
  return self.classifiers
end

local function payloadOf(entry, hint)
  if entry.payload == nil then
    return nil
  end
  return entry.payload(hint)
end

local function classificationOf(entry, hint, source)
  return {
    source = source,
    resolvesSource = not entry.amountOnly,
    amountOnly = entry.amountOnly,
    classifierId = entry.id,
    priority = entry.priority,
    payload = payloadOf(entry, hint),
  }
end

-- Classify a hint. Always answers; a hint nobody recognises is UNKNOWN with no
-- classifier named, which is what lets the caller tell "this channel is understood
-- and says nothing about the source" from "this channel is not understood at all".
function ClassifierRegistry:classify(hint)
  local amountOnlyMatch

  for _, entry in ipairs(ordered(self)) do
    if entry.matches(hint) then
      if entry.amountOnly then
        -- Remembered, not returned: a lower-priority classifier may still resolve
        -- the source, and an amount-only match must never stand in its way.
        if amountOnlyMatch == nil then
          amountOnlyMatch = entry
        end
      else
        local source = Guard.member(XpSource, "XpSource", entry.classify(hint),
          "classifier '" .. entry.id .. "'")
        return classificationOf(entry, hint, source)
      end
    end
  end

  if amountOnlyMatch ~= nil then
    return classificationOf(amountOnlyMatch, hint, XpSource.UNKNOWN)
  end

  return {
    source = XpSource.UNKNOWN,
    resolvesSource = false,
    amountOnly = false,
    classifierId = nil,
    priority = 0,
    payload = nil,
  }
end

function ClassifierRegistry:count()
  return #self.classifiers
end

-- Registered ids in the order classification considers them.
function ClassifierRegistry:ids()
  local ids = {}
  for _, entry in ipairs(ordered(self)) do
    ids[#ids + 1] = entry.id
  end
  return ids
end

ns.core.ClassifierRegistry = ClassifierRegistry
