-- Ascent - Repository port.
--
-- The boundary between the domain and saved variables. Implementations deal in
-- plain tables only: no metatables, no functions, nothing that cannot survive
-- being written to a file and read back by a different version of the addon.

local _, ns = ...
ns.core = ns.core or {}

ns.core.Repository = ns.core.Port.define("Repository", {
  schemaVersion = "schemaVersion() -> number|nil. Version of the stored format; "
               .. "nil on a character that has never been recorded.",
  setSchemaVersion = "setSchemaVersion(version). Stamp the format version after a "
                  .. "successful migration.",

  currentRecord = "currentRecord() -> table|nil. The level being played, or nil if "
               .. "there is none.",
  saveCurrentRecord = "saveCurrentRecord(record). Persist the level being played, or "
                   .. "nil when there is none. At the client's maximum level there is no "
                   .. "level in progress, and leaving the last snapshot in this slot would "
                   .. "have the next login reconcile from a record whose history is already "
                   .. "written, overwriting it.",

  completedRecord = "completedRecord(level) -> table|nil. The stored record for a "
                 .. "finished level; nil if that level was never recorded. Nil is a "
                 .. "real answer here and must stay distinguishable from a level "
                 .. "recorded as all zeroes.",
  saveCompletedRecord = "saveCompletedRecord(record). Persist a finished level, "
                     .. "keyed by record.level.",
  completedLevels = "completedLevels() -> array. Ascending list of the levels that "
                 .. "have a stored record; empty when there are none.",

  settings = "settings() -> table|nil. Stored options; nil on a fresh install, so "
          .. "the caller can tell 'never saved' from 'saved as empty'. "
          .. "Account-wide, not per character.",
  saveSettings = "saveSettings(settings). Persist options.",

  questRewards = "questRewards() -> table. Quest rewards learned from the quest "
              .. "dialogue, keyed by quest id; empty table when none. Per "
              .. "character, because which quests were seen is.",
  saveQuestRewards = "saveQuestRewards(rewards). Persist the learned rewards, "
                  .. "keyed by quest id.",

  questNames = "questNames() -> table. Quest names, keyed by quest id; empty "
            .. "table when none. Account-wide, unlike the rewards above: which "
            .. "quests a character saw is that character's, but what a quest is "
            .. "called is the client's, and identical on every alt.",
  saveQuestNames = "saveQuestNames(names). Persist the quest names, keyed by "
                .. "quest id.",

  archiveIncompatible = "archiveIncompatible(). Move data this version cannot "
                     .. "migrate somewhere safe and start clean, keeping the "
                     .. "account-wide options. Loading always wins over preserving: "
                     .. "the addon must never refuse to load because of old data.",
  clear = "clear(). Delete this character's recorded history, keeping the "
       .. "account-wide options. Used by the reset command, after the player "
       .. "confirms.",
})
