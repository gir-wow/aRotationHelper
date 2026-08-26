-- GENERATED FILE - do not edit by hand.
-- Source:    data/apls/monk/brewmaster/default.apl.json
-- Generator: tools/apl2lua/apl2lua.mjs
-- Regenerate with:
--   node tools/apl2lua/apl2lua.mjs --spec monk/brewmaster --preset default
--
-- 23 active priority lines (2 hidden lines dropped).
-- Opcodes used: and, auraIsActive, auraIsInactive, auraIsKnown, auraNumStacks, auraRemainingTime, autocastOtherCooldowns, brewmasterMonkCurrentStaggerPercent, castSpell, cmp, const, currentEnergy, currentHealthPercent, energyTimeToTarget, gcdTimeToReady, inputDelay, math, maxEnergy, monkCurrentChi, monkMaxChi, or, spellGcdHastedDuration, spellTimeToReady

local ADDON_NAME, ns = ...
ns.Rotations = ns.Rotations or {}

ns.Rotations["MONK_BREWMASTER_DEFAULT"] = {
  key = "MONK_BREWMASTER_DEFAULT",
  spec = "monk/brewmaster",
  preset = "default",
  source = "data/apls/monk/brewmaster/default.apl.json",
  prepull = {
    {
      idx = 1,
      at = -30,
      action = { op = "castSpell", id = 122278, name = "Dampen Harm" },
      spells = { 122278 },
    },
    {
      idx = 2,
      at = -1,
      action = { op = "castSpell", id = 115069, name = "Stance of the Sturdy Ox" },
      spells = { 115069 },
    },
    { idx = 3, at = -0.1, action = { op = "castSpell", other = "OtherActionPotion" }, spells = {} },
  },
  lines = {
    { idx = 1, action = { op = "autocastOtherCooldowns", passive = true }, spells = {} },
    {
      idx = 2,
      action = { op = "castSpell", id = 119582, name = "Purifying Brew" },
      cond = {
        op = "and",
        vals = {
          { op = "auraIsKnown", id = 138237 },
          { op = "auraIsActive", id = 138237 },
          {
            op = "or",
            vals = {
              {
                op = "cmp",
                cmpOp = "OpGt",
                lhs = { op = "brewmasterMonkCurrentStaggerPercent" },
                rhs = { op = "const", v = 0.06 },
              },
              {
                op = "cmp",
                cmpOp = "OpLe",
                lhs = { op = "auraRemainingTime", id = 138237 },
                rhs = {
                  op = "math",
                  mathOp = "OpAdd",
                  lhs = { op = "spellGcdHastedDuration", id = 100780, name = "Jab" },
                  rhs = { op = "inputDelay" },
                },
              },
            },
          },
        },
      },
      spells = { 138237, 100780, 119582 },
    },
    {
      idx = 3,
      action = { op = "castSpell", id = 115308, name = "Elusive Brew" },
      cond = {
        op = "and",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpGe",
            lhs = { op = "auraNumStacks", id = 128938, name = "Brewing: Elusive Brew" },
            rhs = { op = "const", v = 6 },
          },
          { op = "auraIsInactive", id = 115308, name = "Elusive Brew" },
        },
      },
      spells = { 128938, 115308 },
    },
    {
      idx = 4,
      action = { op = "castSpell", id = 115399, name = "Chi Brew" },
      cond = {
        op = "or",
        vals = {
          { op = "cmp", cmpOp = "OpEq", lhs = { op = "monkCurrentChi" }, rhs = { op = "const", v = 0 } },
          {
            op = "and",
            vals = {
              { op = "cmp", cmpOp = "OpLe", lhs = { op = "monkCurrentChi" }, rhs = { op = "const", v = 1 } },
              {
                op = "cmp",
                cmpOp = "OpGe",
                lhs = { op = "spellTimeToReady", id = 121253, name = "Keg Smash" },
                rhs = { op = "const", v = 1.5 },
              },
            },
          },
        },
      },
      spells = { 121253, 115399 },
    },
    {
      idx = 5,
      action = { op = "castSpell", id = 115295, name = "Guard" },
      cond = {
        op = "and",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpGt",
            lhs = { op = "auraRemainingTime", id = 115307, name = "Shuffle" },
            rhs = { op = "const", v = 2 },
          },
          { op = "cmp", cmpOp = "OpGe", lhs = { op = "monkCurrentChi" }, rhs = { op = "const", v = 3 } },
          { op = "auraIsActive", id = 118636, name = "Power Guard" },
          {
            op = "cmp",
            cmpOp = "OpGe",
            lhs = { op = "auraNumStacks", id = 120267, name = "Vengeance" },
            rhs = { op = "const", v = 80000 },
          },
        },
      },
      spells = { 115307, 118636, 120267, 115295 },
    },
    {
      idx = 6,
      action = { op = "castSpell", id = 100784, name = "Blackout Kick", tag = 1 },
      cond = {
        op = "and",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpLe",
            lhs = { op = "spellTimeToReady", id = 121253, name = "Keg Smash" },
            rhs = { op = "const", v = 1.5 },
          },
          {
            op = "cmp",
            cmpOp = "OpGe",
            lhs = { op = "monkCurrentChi" },
            rhs = { op = "math", mathOp = "OpSub", lhs = { op = "monkMaxChi" }, rhs = { op = "const", v = 1 } },
          },
        },
      },
      spells = { 121253, 100784 },
    },
    {
      idx = 8,
      action = { op = "castSpell", id = 124507, name = "Gift of the Ox" },
      cond = {
        op = "and",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpLe",
            lhs = { op = "currentHealthPercent" },
            rhs = { op = "const", v = 0.6 },
          },
        },
      },
      spells = { 124507 },
    },
    {
      idx = 9,
      action = { op = "castSpell", id = 138310 },
      cond = {
        op = "and",
        vals = {
          { op = "auraIsKnown", id = 138177 },
          {
            op = "cmp",
            cmpOp = "OpGt",
            lhs = { op = "energyTimeToTarget", target = { op = "maxEnergy" } },
            rhs = { op = "gcdTimeToReady" },
          },
        },
      },
      spells = { 138177, 138310 },
    },
    {
      idx = 10,
      action = { op = "castSpell", id = 121253, name = "Keg Smash" },
      spells = { 121253 },
    },
    {
      idx = 11,
      action = { op = "castSpell", id = 116847, name = "Rushing Jade Wind" },
      spells = { 116847 },
    },
    {
      idx = 12,
      action = { op = "castSpell", id = 115072, name = "Expel Harm" },
      cond = {
        op = "and",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpLe",
            lhs = { op = "auraRemainingTime", id = 115307, name = "Shuffle" },
            rhs = { op = "const", v = 2 },
          },
          { op = "cmp", cmpOp = "OpLe", lhs = { op = "monkCurrentChi" }, rhs = { op = "const", v = 1 } },
          {
            op = "cmp",
            cmpOp = "OpLt",
            lhs = { op = "currentHealthPercent" },
            rhs = { op = "const", v = 0.95 },
          },
        },
      },
      spells = { 115307, 115072 },
    },
    {
      idx = 13,
      action = { op = "castSpell", id = 100780, name = "Jab" },
      cond = {
        op = "and",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpLe",
            lhs = { op = "auraRemainingTime", id = 115307, name = "Shuffle" },
            rhs = { op = "const", v = 2 },
          },
          { op = "cmp", cmpOp = "OpLe", lhs = { op = "monkCurrentChi" }, rhs = { op = "const", v = 1 } },
        },
      },
      spells = { 115307, 100780 },
    },
    {
      idx = 14,
      action = { op = "castSpell", id = 100784, name = "Blackout Kick", tag = 1 },
      cond = {
        op = "or",
        vals = {
          {
            op = "cmp",
            cmpOp = "OpLe",
            lhs = { op = "auraRemainingTime", id = 115307, name = "Shuffle" },
            rhs = { op = "const", v = 1.5 },
          },
          {
            op = "and",
            vals = {
              {
                op = "cmp",
                cmpOp = "OpLe",
                lhs = { op = "spellTimeToReady", id = 121253, name = "Keg Smash" },
                rhs = { op = "const", v = 2 },
              },
              {
                op = "cmp",
                cmpOp = "OpGe",
                lhs = { op = "monkCurrentChi" },
                rhs = { op = "math", mathOp = "OpSub", lhs = { op = "monkMaxChi" }, rhs = { op = "const", v = 1 } },
              },
            },
          },
        },
      },
      spells = { 115307, 121253, 100784 },
    },
    {
      idx = 15,
      action = { op = "castSpell", id = 123904, name = "Invoke Xuen, the White Tiger" },
      spells = { 123904 },
    },
    {
      idx = 16,
      action = { op = "castSpell", id = 119582, name = "Purifying Brew" },
      cond = {
        op = "cmp",
        cmpOp = "OpGe",
        lhs = { op = "brewmasterMonkCurrentStaggerPercent" },
        rhs = { op = "const", v = 0.03 },
      },
      spells = { 119582 },
    },
    {
      idx = 17,
      action = { op = "castSpell", id = 115072, name = "Expel Harm" },
      cond = {
        op = "and",
        vals = {
          { op = "cmp", cmpOp = "OpGe", lhs = { op = "currentEnergy" }, rhs = { op = "const", v = 80 } },
          {
            op = "cmp",
            cmpOp = "OpLt",
            lhs = { op = "currentHealthPercent" },
            rhs = { op = "const", v = 0.95 },
          },
        },
      },
      spells = { 115072 },
    },
    {
      idx = 18,
      action = { op = "castSpell", id = 100780, name = "Jab" },
      cond = { op = "cmp", cmpOp = "OpGe", lhs = { op = "currentEnergy" }, rhs = { op = "const", v = 80 } },
      spells = { 100780 },
    },
    {
      idx = 19,
      action = { op = "castSpell", id = 100787, name = "Tiger Palm" },
      cond = {
        op = "cmp",
        cmpOp = "OpLe",
        lhs = { op = "auraRemainingTime", id = 125359, name = "Tiger Power" },
        rhs = { op = "const", v = 1.5 },
      },
      spells = { 125359, 100787 },
    },
    {
      idx = 20,
      action = { op = "castSpell", id = 100784, name = "Blackout Kick", tag = 1 },
      cond = { op = "cmp", cmpOp = "OpGe", lhs = { op = "monkCurrentChi" }, rhs = { op = "const", v = 3 } },
      spells = { 100784 },
    },
    { idx = 21, action = { op = "castSpell", id = 115098, name = "Chi Wave" }, spells = { 115098 } },
    {
      idx = 22,
      action = { op = "castSpell", id = 123986, name = "Chi Burst" },
      spells = { 123986 },
    },
    {
      idx = 23,
      action = { op = "castSpell", id = 124081, name = "Zen Sphere" },
      cond = {
        op = "cmp",
        cmpOp = "OpLt",
        lhs = { op = "auraNumStacks", id = 124081, name = "Zen Sphere", tag = 1 },
        rhs = { op = "const", v = 2 },
      },
      spells = { 124081 },
    },
    {
      idx = 25,
      action = { op = "castSpell", id = 100787, name = "Tiger Palm" },
      spells = { 100787 },
    },
  },
}
