-- Ascent - bounding what a level costs on disk.
--
-- Saved variables are serialized whole at every logout, so their size is a cost the
-- player pays each time they quit. The aggregates of a level are small and bounded
-- and are kept forever; the list of individual gains is neither, and is what gets
-- trimmed.
--
-- The trim is from the front, so what a level keeps is its most recent detail. The
-- design calls this a circular buffer, and a ring is what it is functionally -- but
-- it is realized as a bounded sequence, because the persisted form has to be a plain
-- array either way and a true ring would have to store its head index and hand every
-- reader a rotation to undo.
--
-- What is NOT trimmed is the point: the per-source totals, the per-creature
-- aggregates and the kill counts already hold everything the discarded gains
-- contributed. Dropping detail costs the panel its fine grain; it never costs the
-- level its arithmetic.
--
-- A finished level keeps its detail. The sequence of a level's gains is its time
-- series -- when the questing stopped and the grinding started, where the rested
-- bonus ran out -- and that is the most interesting thing a leveling analytics addon
-- holds, not a cache to be swept. What makes keeping it affordable is the on-disk
-- encoding rather than a smaller buffer: written one field per line, a gain costs
-- about 210 bytes; packed into a line of its own it costs about 31. The limit below
-- exists because the spec requires growth to be bounded, and it is set high enough
-- that a real level never reaches it.

local _, ns = ...
ns.core = ns.core or {}

local SettingKey = ns.core.SettingKey

local RetentionPolicy = {}
RetentionPolicy.__index = RetentionPolicy

function RetentionPolicy.new(settings)
  local limit
  if settings == nil then
    limit = ns.core.Defaults[SettingKey.RETENTION_LIMIT]
  else
    limit = settings[SettingKey.RETENTION_LIMIT]
  end

  if type(limit) ~= "number" or limit ~= limit or limit < 0 then
    limit = ns.core.Defaults[SettingKey.RETENTION_LIMIT]
  end

  return setmetatable({ limit = math.floor(limit) }, RetentionPolicy)
end

-- Trim a record to the limit, oldest first. Returns how many were discarded, so a
-- caller in debug mode can say so rather than the detail thinning out in silence.
function RetentionPolicy:apply(record)
  local gains = record.gains
  local total = #gains
  local excess = total - self.limit

  if excess <= 0 then
    return 0
  end

  local kept = total - excess
  for index = 1, kept do
    gains[index] = gains[index + excess]
  end
  for index = total, kept + 1, -1 do
    gains[index] = nil
  end

  return excess
end

ns.core.RetentionPolicy = RetentionPolicy
