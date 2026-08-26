// Canonical opcode registry for the aRotationHelper APL port.
//
// This is the single source of truth for "which APL opcodes do we understand".
// The generator (apl2lua.mjs) refuses to emit a rotation that uses anything not
// listed here, so an unimplemented opcode is a loud build failure rather than a
// silently dropped priority line.
//
// This file is metadata only. Evaluation lives in two places that must agree:
//   * core/engine.lua                        (in-game)
//   * tools/apl2lua/interp.mjs               (offline: tests and log replay)
// `npm run apl:verify` cross-checks that both know every opcode listed here.
//
// Fields:
//   type  semantic type, used by the percentage-vs-absolute lint
//   lua   name of the reader method on the Lua State object (nil for operators,
//         which both interpreters handle structurally)
//   args  which JSON key holds the operand, for the spell-reference scan

export const TYPES = {
  PCT: 'pct',   // a 0..1 fraction (the sim stores "60%" as 0.6)
  ABS: 'abs',   // an absolute quantity (health, attack power)
  TIME: 'time', // seconds
  INT: 'int',   // a small integer count (chi, targets)
  BOOL: 'bool',
  NUM: 'num',   // unknown/ambiguous - never flagged by the lint
};

/** Parse a sim const literal: "30%" -> 0.3, "1.5s" -> 1.5, "-.1s" -> -0.1, "6" -> 6 */
export function parseConst(raw) {
  if (typeof raw === 'number') return { value: raw, type: TYPES.NUM };
  const s = String(raw ?? '').trim();
  if (s === '') return { value: 0, type: TYPES.NUM };
  if (s.endsWith('%')) {
    const n = Number(s.slice(0, -1));
    if (!Number.isFinite(n)) throw new Error(`bad percent const: ${raw}`);
    return { value: n / 100, type: TYPES.PCT };
  }
  if (/[sm]$/.test(s)) {
    const unit = s.slice(-1);
    const n = Number(s.slice(0, -1));
    if (!Number.isFinite(n)) throw new Error(`bad duration const: ${raw}`);
    return { value: unit === 'm' ? n * 60 : n, type: TYPES.TIME };
  }
  if (s === 'true') return { value: true, type: TYPES.BOOL };
  if (s === 'false') return { value: false, type: TYPES.BOOL };
  const n = Number(s);
  if (!Number.isFinite(n)) throw new Error(`unparseable const: ${raw}`);
  return { value: n, type: TYPES.NUM };
}

/** Extract {spell,tag} / {item} / {other} from an ActionID node. */
export function actionId(node) {
  if (!node) return null;
  if (node.spellId !== undefined) return { spell: node.spellId, tag: node.tag ?? null };
  if (node.itemId !== undefined) return { item: node.itemId };
  if (node.otherId !== undefined) return { other: node.otherId };
  return null;
}

const T = TYPES;

// ---------------------------------------------------------------------------
// Value opcodes
// ---------------------------------------------------------------------------
export const VALUES = {
  // operators - handled structurally by both interpreters
  const: { type: null, lua: null },
  and: { type: T.BOOL, lua: null },
  or: { type: T.BOOL, lua: null },
  not: { type: T.BOOL, lua: null },
  cmp: { type: T.BOOL, lua: null },
  math: { type: T.NUM, lua: null },
  max: { type: T.NUM, lua: null },
  min: { type: T.NUM, lua: null },

  // monk / brewmaster
  monkCurrentChi: { type: T.INT, lua: 'Chi' },
  monkMaxChi: { type: T.INT, lua: 'MaxChi' },
  brewmasterMonkCurrentStaggerPercent: { type: T.PCT, lua: 'StaggerPct' },

  // generic resources
  currentEnergy: { type: T.ABS, lua: 'Energy' },
  maxEnergy: { type: T.ABS, lua: 'MaxEnergy' },
  energyRegenPerSecond: { type: T.ABS, lua: 'EnergyRegen' },
  currentHealth: { type: T.ABS, lua: 'Health' },
  maxHealth: { type: T.ABS, lua: 'MaxHealth' },
  currentHealthPercent: { type: T.PCT, lua: 'HealthPct' },
  currentRunicPower: { type: T.ABS, lua: 'RunicPower' },
  currentRuneCount: { type: T.INT, lua: 'RuneCount', args: { runeType: 'runeType' } },
  currentNonDeathRuneCount: { type: T.INT, lua: 'NonDeathRuneCount', args: { runeType: 'runeType' } },
  energyTimeToTarget: { type: T.TIME, lua: 'EnergyTimeTo', args: { value: 'targetEnergy' } },

  // GCD
  gcdIsReady: { type: T.BOOL, lua: 'GcdReady' },
  gcdTimeToReady: { type: T.TIME, lua: 'GcdRemain' },

  // spells
  spellIsKnown: { type: T.BOOL, lua: 'SpellKnown', args: { id: 'spellId' } },
  spellIsReady: { type: T.BOOL, lua: 'SpellReady', args: { id: 'spellId' } },
  spellCanCast: { type: T.BOOL, lua: 'SpellCanCast', args: { id: 'spellId' } },
  spellTimeToReady: { type: T.TIME, lua: 'CdRemain', args: { id: 'spellId' } },
  spellFullCooldown: { type: T.TIME, lua: 'CdDuration', args: { id: 'spellId' } },
  spellGcdHastedDuration: { type: T.TIME, lua: 'HastedGcd', args: { id: 'spellId' } },

  // auras
  auraIsKnown: { type: T.BOOL, lua: 'AuraKnown', args: { id: 'auraId' } },
  auraIsActive: { type: T.BOOL, lua: 'AuraUp', args: { id: 'auraId' } },
  auraIsInactive: { type: T.BOOL, lua: 'AuraDown', args: { id: 'auraId' } },
  auraRemainingTime: { type: T.TIME, lua: 'AuraRemain', args: { id: 'auraId' } },
  auraNumStacks: { type: T.ABS, lua: 'AuraStacks', args: { id: 'auraId' } },
  dotPercentIncrease: { type: T.PCT, lua: 'DotPercentIncrease', args: { id: 'spellId' } },

  // encounter / environment - live substitutions, see report section 4
  currentTime: { type: T.TIME, lua: 'CombatTime' },
  numberTargets: { type: T.INT, lua: 'NumTargets' },
  isExecutePhase: { type: T.BOOL, lua: 'ExecutePhase', args: { threshold: 'threshold' } },
  frontOfTarget: { type: T.BOOL, lua: 'InFrontOfTarget' },
  unitIsMoving: { type: T.BOOL, lua: 'IsMoving' },

  // sim latency model - replaced by a constant, see report section 4.2
  inputDelay: { type: T.TIME, lua: 'InputDelay' },
  channelClipDelay: { type: T.TIME, lua: 'InputDelay' },
};

// ---------------------------------------------------------------------------
// Action opcodes
// ---------------------------------------------------------------------------
export const ACTIONS = {
  castSpell: { args: { id: 'spellId' } },
  // The sim auto-fires trinkets/racials/tinkers here. We surface those in the
  // cooldown row instead, so these never win the rotation slot.
  autocastOtherCooldowns: { passive: true },
  castAllStatBuffCooldowns: { passive: true },
  // Blood's shared core uses strict sequences containing one cast plus a 10ms
  // wait. The wait is simulator scheduling detail; emit the single cast.
  strictSequence: { firstCastOnly: true },
};

export const KNOWN_VALUES = new Set(Object.keys(VALUES));
export const KNOWN_ACTIONS = new Set(Object.keys(ACTIONS));

export const EXECUTE_THRESHOLDS = {
  ExecuteProportion20: 0.2,
  ExecuteProportion25: 0.25,
  ExecuteProportion35: 0.35,
  ExecuteProportion45: 0.45,
  ExecuteProportion90: 0.9,
};
