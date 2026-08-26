-- GENERATED FILE - do not edit by hand.
-- Source:    data/apls/death_knight/blood/default.apl.json
-- Generator: tools/apl2lua/apl2lua.mjs
-- Regenerate with:
--   node tools/apl2lua/apl2lua.mjs --spec death_knight/blood --preset default
--
-- 16 active priority lines (0 hidden lines dropped).
-- Opcodes used: and, auraIsActive, auraIsKnown, auraNumStacks, autocastOtherCooldowns, castSpell, cmp, const, currentHealthPercent, currentNonDeathRuneCount, currentRuneCount, currentRunicPower, currentTime, dotPercentIncrease, isExecutePhase, not, or, spellCanCast, strictSequence

local ADDON_NAME, ns = ...
ns.Rotations = ns.Rotations or {}

ns.Rotations["DEATH_KNIGHT_BLOOD_DEFAULT"] = {
  key = "DEATH_KNIGHT_BLOOD_DEFAULT",
  spec = "death_knight/blood",
  preset = "default",
  source = "data/apls/death_knight/blood/default.apl.json",
  prepull = {
    { idx = 1, at = -36, action = { op = "castSpell", id = 48263 }, spells = { 48263 } },
    { idx = 2, at = -1, action = { op = "castSpell", other = "OtherActionPotion" }, spells = {} },
  },
  lines = {
    {
      idx = 1,
      action = { op = "castSpell", id = 48982 },
      cond = { op = "auraIsActive", id = 96171 },
      spells = { 96171, 48982 },
    },
    {
      idx = 2,
      action = { op = "castSpell", id = 45529 },
      cond = {
        op = "and",
        vals = {
          { op = "auraIsKnown", id = 114851 },
          {
            op = "cmp",
            cmpOp = "OpLe",
            lhs = { op = "currentHealthPercent" },
            rhs = { op = "const", v = 0.5 },
          },
          { op = "not", val = { op = "spellCanCast", id = 49998, tag = 1 } },
        },
      },
      spells = { 114851, 49998, 45529 },
    },
    {
      idx = 3,
      action = { op = "castSpell", id = 47568 },
      cond = {
        op = "and",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpLe",
            lhs = { op = "currentHealthPercent" },
            rhs = { op = "const", v = 0.45 },
          },
          { op = "not", val = { op = "spellCanCast", id = 49998, tag = 1 } },
        },
      },
      spells = { 49998, 47568 },
    },
    { idx = 4, action = { op = "autocastOtherCooldowns", passive = true }, spells = {} },
    {
      idx = 5,
      action = { op = "castSpell", id = 49998, tag = 1 },
      cond = { op = "cmp", cmpOp = "OpLe", lhs = { op = "currentTime" }, rhs = { op = "const", v = 0.3 } },
      spells = { 49998 },
    },
    {
      idx = 6,
      action = { op = "castSpell", id = 49998, tag = 1 },
      cond = {
        op = "and",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpEq",
            lhs = { op = "currentRuneCount", runeType = "RuneFrost" },
            rhs = { op = "const", v = 2 },
          },
          {
            op = "cmp",
            cmpOp = "OpEq",
            lhs = { op = "currentRuneCount", runeType = "RuneUnholy" },
            rhs = { op = "const", v = 2 },
          },
        },
      },
      spells = { 49998 },
    },
    {
      idx = 7,
      action = { op = "castSpell", id = 56815 },
      cond = {
        op = "cmp",
        cmpOp = "OpGe",
        lhs = { op = "currentRunicPower" },
        rhs = { op = "const", v = 90 },
      },
      spells = { 56815 },
    },
    {
      idx = 8,
      action = { op = "castSpell", id = 114867, tag = 1 },
      cond = {
        op = "and",
        vals = {
          { op = "isExecutePhase", threshold = "E35" },
          {
            op = "cmp",
            cmpOp = "OpGe",
            lhs = { op = "currentNonDeathRuneCount", runeType = "RuneBlood" },
            rhs = { op = "const", v = 1 },
          },
        },
      },
      spells = { 114867 },
    },
    {
      idx = 9,
      action = { op = "castSpell", id = 55050 },
      cond = {
        op = "cmp",
        cmpOp = "OpGe",
        lhs = { op = "currentNonDeathRuneCount", runeType = "RuneBlood" },
        rhs = { op = "const", v = 2 },
      },
      spells = { 55050 },
    },
    {
      idx = 10,
      action = { op = "castSpell", id = 45529 },
      cond = {
        op = "and",
        vals = {
          { op = "auraIsKnown", id = 114851 },
          {
            op = "cmp",
            cmpOp = "OpGe",
            lhs = { op = "auraNumStacks", id = 114851 },
            rhs = { op = "const", v = 11 },
          },
        },
      },
      spells = { 114851, 45529 },
    },
    {
      idx = 11,
      action = { op = "castSpell", id = 48721 },
      cond = {
        op = "and",
        vals = {
          { op = "auraIsActive", id = 81141 },
          {
            op = "or",
            vals = {
              {
                op = "cmp",
                cmpOp = "OpGe",
                lhs = { op = "dotPercentIncrease", id = 55078 },
                rhs = { op = "const", v = 0 },
              },
              {
                op = "cmp",
                cmpOp = "OpGe",
                lhs = { op = "dotPercentIncrease", id = 55095 },
                rhs = { op = "const", v = 0 },
              },
            },
          },
        },
      },
      spells = { 81141, 55078, 55095, 48721 },
    },
    {
      idx = 12,
      action = { op = "castSpell", id = 43265 },
      cond = {
        op = "and",
        vals = { { op = "auraIsActive", id = 81141 }, { op = "spellCanCast", id = 43265 } },
      },
      spells = { 81141, 43265 },
    },
    {
      idx = 13,
      action = { op = "castSpell", id = 48721 },
      cond = { op = "auraIsActive", id = 81141 },
      spells = { 81141, 48721 },
    },
    {
      idx = 14,
      action = { op = "castSpell", id = 50613 },
      cond = {
        op = "and",
        vals = {
          { op = "not", val = { op = "spellCanCast", id = 56815 } },
          {
            op = "cmp",
            cmpOp = "OpGe",
            lhs = { op = "currentRunicPower" },
            rhs = { op = "const", v = 15 },
          },
        },
      },
      spells = { 56815, 50613 },
    },
    { idx = 15, action = { op = "castSpell", id = 56815 }, spells = { 56815 } },
    { idx = 16, action = { op = "castSpell", id = 57330 }, spells = { 57330 } },
  },
}
