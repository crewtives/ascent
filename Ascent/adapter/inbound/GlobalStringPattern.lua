-- Ascent - turns the client's own GlobalStrings into match patterns, in any
-- locale, without translating anything by hand.
--
-- A GlobalString like "%s dies, you gain %d experience." uses two kinds of format
-- specifier. Most locales use them in the order they appear, as English does; a
-- few -- Russian and Korean among them -- use the numbered form (%1$s, %2$d, ...)
-- to reorder them. `compile` handles both: every %s/%d becomes a capture, and the
-- returned `order` gives the original placeholder number of each capture, in the
-- pattern's own physical order (not necessarily 1, 2, 3, 4). A caller that wants
-- "the amount" (placeholder 2) looks up where 2 sits in `order`, not `captures[2]`.
--
-- Lua's pattern magic characters -- ( ) . % + - * ? [ ] ^ $ -- are escaped
-- everywhere except inside a recognised specifier, so a literal "." or "(" in the
-- client's text is never read as pattern syntax.

local _, ns = ...
ns.adapter = ns.adapter or {}

local MAGIC = {
  ["("] = true, [")"] = true, ["."] = true, ["+"] = true, ["-"] = true,
  ["*"] = true, ["?"] = true, ["["] = true, ["]"] = true, ["^"] = true, ["$"] = true,
}

local function compile(template)
  local out, order = {}, {}
  local nextImplicit = 1
  local i, len = 1, #template

  while i <= len do
    local c = template:sub(i, i)

    if c == "%" then
      local numStr, kind, after = template:match("^(%d*)%$?([sd])()", i + 1)
      if kind then
        local placeholder = tonumber(numStr)
        if placeholder == nil then
          placeholder = nextImplicit
          nextImplicit = nextImplicit + 1
        end
        order[#order + 1] = placeholder
        out[#out + 1] = (kind == "d") and "(%d+)" or "(.-)"
        i = after
      else
        -- A "%" that is not one of the specifiers this addon reads: kept as a
        -- literal percent rather than failing on a format this addon does not use.
        out[#out + 1] = "%%"
        i = i + 1
      end
    elseif MAGIC[c] then
      out[#out + 1] = "%" .. c
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end

  return table.concat(out), order
end

-- ---------------------------------------------------------------------------
-- The experience family, in the order it must be tried
-- ---------------------------------------------------------------------------
--
-- The client announces a kill with one of the templates below, and the plain one
-- is a strict prefix of every other:
--
--   "%s dies, you gain %d experience."
--   "%s dies, you gain %d experience. (+%d group bonus)"
--   "%s dies, you gain %d experience. (%s exp %s bonus, -%d raid penalty)"
--
-- Unanchored, the first pattern matches all three and ignores the trailing text,
-- losing the group bonus while the amount is still recorded correctly. So: most
-- specific first, and anchored at the point of use.
--
-- Two collisions survive the anchoring, which is why specificity is an explicit
-- order: rested+group also matches plain rested, and rested+raid also matches the
-- fatigue template, which would record a raid penalty as a fatigue penalty.
--
-- `creature`, `amount`, `modifierAmount` and `restedAmount` are original
-- placeholder numbers, not capture positions: a locale that reorders the text
-- with numbered specifiers changes where each capture lands, not what each
-- placeholder means. `order` from compile() maps one to the other.
--
-- `rested` says the client was announcing a rested state; `restedAmount` says
-- where in that sentence the magnitude sits, and only the EXHAUSTION1/2 family
-- carries a rested bonus. EXHAUSTION4/5 are the fatigue templates -- "(%s exp %s
-- penalty)", a deduction -- so they name no restedAmount and nothing downstream
-- can mistake a penalty for a reserve being spent. Without a restedAmount the
-- reader falls back to the reserve rather than reading a number that means
-- something else.
--
-- The sign is never captured. It is literal text in the template, so `%d` always
-- yields a magnitude; which template matched is what says whether that magnitude
-- was added or taken away.
local XP_TEMPLATES = {
  -- Named kill, rested, with a group or raid modifier: the longest templates.
  { name = "EXHAUSTION1_GROUP", global = "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP",
    creature = 1, amount = 2, modifier = "group", modifierAmount = 5,
    rested = true, restedAmount = 3 },
  { name = "EXHAUSTION1_RAID", global = "COMBATLOG_XPGAIN_EXHAUSTION1_RAID",
    creature = 1, amount = 2, modifier = "raid", modifierAmount = 5,
    rested = true, restedAmount = 3 },
  { name = "EXHAUSTION2_GROUP", global = "COMBATLOG_XPGAIN_EXHAUSTION2_GROUP",
    creature = 1, amount = 2, modifier = "group", modifierAmount = 5,
    rested = true, restedAmount = 3 },
  { name = "EXHAUSTION2_RAID", global = "COMBATLOG_XPGAIN_EXHAUSTION2_RAID",
    creature = 1, amount = 2, modifier = "raid", modifierAmount = 5,
    rested = true, restedAmount = 3 },
  { name = "EXHAUSTION4_GROUP", global = "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP",
    creature = 1, amount = 2, modifier = "group", modifierAmount = 5, rested = true },
  { name = "EXHAUSTION4_RAID", global = "COMBATLOG_XPGAIN_EXHAUSTION4_RAID",
    creature = 1, amount = 2, modifier = "raid", modifierAmount = 5, rested = true },
  { name = "EXHAUSTION5_GROUP", global = "COMBATLOG_XPGAIN_EXHAUSTION5_GROUP",
    creature = 1, amount = 2, modifier = "group", modifierAmount = 5, rested = true },
  { name = "EXHAUSTION5_RAID", global = "COMBATLOG_XPGAIN_EXHAUSTION5_RAID",
    creature = 1, amount = 2, modifier = "raid", modifierAmount = 5, rested = true },

  -- Named kill, rested, no modifier.
  { name = "EXHAUSTION1", global = "COMBATLOG_XPGAIN_EXHAUSTION1",
    creature = 1, amount = 2, rested = true, restedAmount = 3 },
  { name = "EXHAUSTION2", global = "COMBATLOG_XPGAIN_EXHAUSTION2",
    creature = 1, amount = 2, rested = true, restedAmount = 3 },
  { name = "EXHAUSTION4", global = "COMBATLOG_XPGAIN_EXHAUSTION4",
    creature = 1, amount = 2, rested = true },
  { name = "EXHAUSTION5", global = "COMBATLOG_XPGAIN_EXHAUSTION5",
    creature = 1, amount = 2, rested = true },

  -- Named kill with a modifier, no rested bonus.
  { name = "FIRSTPERSON_GROUP", global = "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP",
    creature = 1, amount = 2, modifier = "group", modifierAmount = 3 },
  { name = "FIRSTPERSON_RAID", global = "COMBATLOG_XPGAIN_FIRSTPERSON_RAID",
    creature = 1, amount = 2, modifier = "raid", modifierAmount = 3 },

  -- Named kill, nothing else. The prefix of everything above.
  { name = "FIRSTPERSON", global = "COMBATLOG_XPGAIN_FIRSTPERSON",
    creature = 1, amount = 2 },

  -- Anonymous lines. QUEST is misleadingly named: it is the anonymous line with a
  -- bonus parenthetical, the same shape as the rested templates but with no
  -- creature. It must be tried before the plain anonymous one for the same
  -- prefix reason.
  { name = "UNNAMED_GROUP", global = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP",
    amount = 1, modifier = "group", modifierAmount = 2 },
  { name = "UNNAMED_RAID", global = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID",
    amount = 1, modifier = "raid", modifierAmount = 2 },
  { name = "QUEST", global = "COMBATLOG_XPGAIN_QUEST",
    amount = 1, rested = true, restedAmount = 2 },
  { name = "UNNAMED", global = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED", amount = 1 },
}

-- Compiles the family in order, anchored, skipping templates the client does not
-- have and templates whose text another one already produced.
--
-- Several of these templates are byte-identical in every locale checked: the
-- rested states they name cannot be told apart from the message alone, which is
-- why the rested state is read from the client API, never from this text. A
-- duplicate could never match, and a per-template hit count would report a
-- structurally unreachable template.
--
-- `text` is a function from a global's name to its value, so the caller decides
-- how to reach the client's globals and this stays testable without any.
local function compileXpFamily(text)
  local compiled, seen = {}, {}
  for _, template in ipairs(XP_TEMPLATES) do
    local value = text(template.global)
    if type(value) == "string" and value ~= "" then
      local pattern, order = compile(value)
      if not seen[pattern] then
        seen[pattern] = true
        compiled[#compiled + 1] = {
          name = template.name,
          -- Anchored here, not inside compile(): the same compiler serves the
          -- zone-discovery and quest-reward messages, which arrive on another
          -- channel where a prefix or suffix the client adds would break an
          -- untested anchor.
          pattern = "^" .. pattern .. "$",
          order = order,
          creature = template.creature,
          amount = template.amount,
          modifier = template.modifier,
          modifierAmount = template.modifierAmount,
          rested = template.rested == true,
          restedAmount = template.restedAmount,
        }
      end
    end
  end
  return compiled
end

-- Tries a compiled family against one line, in order, and returns what the
-- template that matched says the line means: the creature (when the template has
-- one), the amount, and the modifier with its magnitude.
--
-- Returns nil when nothing matches, which is a normal outcome: the client
-- announces plenty on this channel that is not a kill.
--
-- The caller gets `template` too, so a diagnostic can count hits per template:
-- that count is how a session shows whether the parenthetical bonus is included
-- in the total.
local function matchXp(compiled, line)
  if type(line) ~= "string" then
    return nil
  end

  for _, entry in ipairs(compiled) do
    local captures = { line:match(entry.pattern) }
    if #captures > 0 then
      -- Keyed by original placeholder number, so a locale that reorders the
      -- sentence does not reorder what each field means.
      local fields = {}
      for index, placeholder in ipairs(entry.order) do
        fields[placeholder] = captures[index]
      end

      local amount = tonumber(fields[entry.amount])
      if amount ~= nil then
        local modifierAmount
        if entry.modifierAmount ~= nil then
          modifierAmount = tonumber(fields[entry.modifierAmount])
        end
        -- The rested magnitude lands in a %s, not a %d: the client wraps it with
        -- its own sign, and at least one locale may put a percentage there
        -- instead of a figure. tonumber does the deciding -- "+147" reads as
        -- 147 and anything that is not a number reads as nil -- so a client whose
        -- parenthetical does not name an absolute amount degrades to the reserve
        -- reading instead of recording a percentage as experience.
        local restedAmount
        if entry.restedAmount ~= nil then
          restedAmount = tonumber(fields[entry.restedAmount])
        end
        return {
          template = entry.name,
          creature = entry.creature ~= nil and fields[entry.creature] or nil,
          amount = amount,
          modifier = entry.modifier,
          modifierAmount = modifierAmount,
          rested = entry.rested,
          restedAmount = restedAmount,
        }
      end
    end
  end

  return nil
end

-- The explicit list of sources. `COMBATLOG_XPGAIN` itself ("%s gains %d
-- experience.", third person) is deliberately absent: it would match another
-- player's gain, and the twenty-odd COMBATLOG_XPGAIN_* globals are not safe to
-- sweep blindly for exactly that reason.
local SOURCES = {
  { name = "FIRSTPERSON",               global = "COMBATLOG_XPGAIN_FIRSTPERSON" },
  { name = "FIRSTPERSON_UNNAMED",       global = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED" },
  { name = "FIRSTPERSON_GROUP",         global = "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP" },
  { name = "FIRSTPERSON_RAID",          global = "COMBATLOG_XPGAIN_FIRSTPERSON_RAID" },
  { name = "FIRSTPERSON_UNNAMED_GROUP", global = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP" },
  { name = "FIRSTPERSON_UNNAMED_RAID",  global = "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID" },
  { name = "QUEST",                     global = "COMBATLOG_XPGAIN_QUEST" },
  { name = "EXHAUSTION1",               global = "COMBATLOG_XPGAIN_EXHAUSTION1" },
  { name = "EXHAUSTION2",               global = "COMBATLOG_XPGAIN_EXHAUSTION2" },
  { name = "EXHAUSTION4",               global = "COMBATLOG_XPGAIN_EXHAUSTION4" },
  { name = "EXHAUSTION5",               global = "COMBATLOG_XPGAIN_EXHAUSTION5" },
  { name = "EXHAUSTION1_GROUP",         global = "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP" },
  { name = "EXHAUSTION1_RAID",          global = "COMBATLOG_XPGAIN_EXHAUSTION1_RAID" },
  { name = "EXHAUSTION2_GROUP",         global = "COMBATLOG_XPGAIN_EXHAUSTION2_GROUP" },
  { name = "EXHAUSTION2_RAID",          global = "COMBATLOG_XPGAIN_EXHAUSTION2_RAID" },
  { name = "EXHAUSTION4_GROUP",         global = "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP" },
  { name = "EXHAUSTION4_RAID",          global = "COMBATLOG_XPGAIN_EXHAUSTION4_RAID" },
  { name = "EXHAUSTION5_GROUP",         global = "COMBATLOG_XPGAIN_EXHAUSTION5_GROUP" },
  { name = "EXHAUSTION5_RAID",          global = "COMBATLOG_XPGAIN_EXHAUSTION5_RAID" },
  { name = "ZONE_EXPLORED",             global = "ERR_ZONE_EXPLORED_XP" },
  { name = "QUEST_REWARD_ECHO",         global = "ERR_QUEST_REWARD_EXP_I" },
}

ns.adapter.GlobalStringPattern = {
  compile = compile,
  compileXpFamily = compileXpFamily,
  matchXp = matchXp,
  XP_TEMPLATES = XP_TEMPLATES,
  SOURCES = SOURCES,
}
