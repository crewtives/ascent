-- Ascent - bounding what a level costs on disk.
--
-- Saved variables are serialized whole at every logout, so their size is paid each
-- time the player quits. A level's aggregates are small and kept forever; the list
-- of individual gains is not, and is what gets trimmed.
--
-- The trim is from the front, so a level keeps its most recent detail. It is a ring
-- functionally, realized as a bounded sequence because the persisted form is a plain
-- array either way and a true ring would have to store its head index.
--
-- The per-source totals, per-creature aggregates and kill counts already hold what
-- the discarded gains contributed: trimming costs the panel fine grain, never the
-- level its arithmetic.
--
-- A finished level keeps its detail, because the sequence of gains is the level's
-- time series. The packed on-disk encoding is what makes that affordable (about 31
-- bytes a gain, against about 210 written one field per line). The limit bounds
-- growth and is set high enough that a real level never reaches it.

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

-- Trims a record to the limit, oldest first. Returns how many were discarded, so
-- a caller in debug mode can report it.
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
