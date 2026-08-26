// Offline reference interpreter for compiled aRotationHelper rotations.
//
// This mirrors core/engine.lua node for node. It exists so
// that rotation logic can be tested without launching WoW, and it is the
// foundation of the Warcraft Logs replay harness (report section 10): the replay
// reconstructs a State from log events and asks this interpreter what it would
// have recommended at each cast.
//
// Keep this in sync with engine.lua. `verify.mjs` asserts that both implement
// every opcode the registry declares.

import { EXECUTE_THRESHOLDS } from './opcodes.mjs';

const CMP = {
  OpEq: (a, b) => a === b,
  OpNe: (a, b) => a !== b,
  OpLt: (a, b) => a < b,
  OpLe: (a, b) => a <= b,
  OpGt: (a, b) => a > b,
  OpGe: (a, b) => a >= b,
};

const MATH = {
  OpAdd: (a, b) => a + b,
  OpSub: (a, b) => a - b,
  OpMul: (a, b) => a * b,
  OpDiv: (a, b) => (b === 0 ? 0 : a / b),
  OpMax: (a, b) => Math.max(a, b),
  OpMin: (a, b) => Math.min(a, b),
};

// op -> State method, mirroring READER in engine.lua
export const READER = {
  monkCurrentChi: 'Chi',
  monkMaxChi: 'MaxChi',
  brewmasterMonkCurrentStaggerPercent: 'StaggerPct',
  currentEnergy: 'Energy',
  maxEnergy: 'MaxEnergy',
  energyRegenPerSecond: 'EnergyRegen',
  currentHealth: 'Health',
  maxHealth: 'MaxHealth',
  currentHealthPercent: 'HealthPct',
  currentRunicPower: 'RunicPower',
  gcdIsReady: 'GcdReady',
  gcdTimeToReady: 'GcdRemain',
  currentTime: 'CombatTime',
  numberTargets: 'NumTargets',
  frontOfTarget: 'InFrontOfTarget',
  unitIsMoving: 'IsMoving',
  inputDelay: 'InputDelay',
  channelClipDelay: 'InputDelay',
  currentRuneCount: 'RuneCount',
  currentNonDeathRuneCount: 'NonDeathRuneCount',
};

// op -> State method taking a spell/aura id, mirroring ID_READER in engine.lua
export const ID_READER = {
  spellIsKnown: 'SpellKnown',
  spellIsReady: 'SpellReady',
  spellCanCast: 'SpellCanCast',
  spellTimeToReady: 'CdRemain',
  spellFullCooldown: 'CdDuration',
  spellGcdHastedDuration: 'HastedGcd',
  auraIsKnown: 'AuraKnown',
  auraIsActive: 'AuraUp',
  auraIsInactive: 'AuraDown',
  auraRemainingTime: 'AuraRemain',
  auraNumStacks: 'AuraStacks',
  dotPercentIncrease: 'DotPercentIncrease',
};

const truthy = (v) => v !== false && v !== null && v !== undefined && v !== 0;
const num = (v) => (v === true ? 1 : v === false || v == null ? 0 : Number(v) || 0);

export function evalValue(node, S) {
  if (node == null) return true;
  const op = node.op;

  if (op === 'const') return node.v;
  if (op === 'and') return node.vals.every((v) => truthy(evalValue(v, S)));
  if (op === 'or') return node.vals.some((v) => truthy(evalValue(v, S)));
  if (op === 'not') return !truthy(evalValue(node.val, S));
  if (op === 'cmp') {
    const f = CMP[node.cmpOp];
    if (!f) throw new Error(`unknown cmp op ${node.cmpOp}`);
    return f(num(evalValue(node.lhs, S)), num(evalValue(node.rhs, S)));
  }
  if (op === 'math') {
    const f = MATH[node.mathOp];
    if (!f) throw new Error(`unknown math op ${node.mathOp}`);
    return f(num(evalValue(node.lhs, S)), num(evalValue(node.rhs, S)));
  }
  if (op === 'max') return Math.max(...node.vals.map((v) => num(evalValue(v, S))));
  if (op === 'min') return Math.min(...node.vals.map((v) => num(evalValue(v, S))));

  if (op === 'currentRuneCount' || op === 'currentNonDeathRuneCount') return S[READER[op]](node.runeType);
  if (READER[op]) return S[READER[op]]();
  if (ID_READER[op]) return S[ID_READER[op]](node.id ?? node.item ?? 0);

  if (op === 'energyTimeToTarget') return S.EnergyTimeTo(num(evalValue(node.target, S)));
  if (op === 'isExecutePhase') return S.ExecutePhase(EXECUTE_THRESHOLDS[node.threshold] ?? 0.2);

  throw new Error(`interp: unhandled opcode '${op}'`);
}

function actionReady(action, S) {
  if (action.passive) return false;
  if (action.op === 'castSpell') return action.id ? S.SpellCanCast(action.id) : false;
  return false;
}

/**
 * The rotation tier: a direct transcription of sim/core/apl.go:507.
 * `lines` should already be filtered to what the character can use.
 */
export function pickRotation(lines, S) {
  for (const line of lines) {
    if (truthy(evalValue(line.cond, S)) && actionReady(line.action, S)) {
      return { action: line.action, lineIdx: line.idx, tier: 'ROTATION' };
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Mock state, mirroring core/state.lua
// ---------------------------------------------------------------------------
export const ECON = {
  100780: { energy: 40, gainChi: 1 },                                   // Jab
  100787: { applies: { 125359: 20, 118636: 30 } },                      // Tiger Palm (free)
  121253: { energy: 40, gainChi: 2, cd: 8 },                            // Keg Smash
  115072: { energy: 40, gainChi: 1, cd: 15 },                           // Expel Harm
  100784: { chi: 2, applies: { 115307: 6 } },                           // Blackout Kick
  115295: { chi: 2, cd: 30 },                                           // Guard
  119582: { chi: 1, cd: 1 },                                            // Purifying Brew
  115308: { cd: 6 },                                                    // Elusive Brew
  115399: { gainChi: 2, cd: 45 },                                       // Chi Brew
  115098: { cd: 15 },                                                   // Chi Wave
  123986: { cd: 30 },                                                   // Chi Burst
  124081: { cd: 10 },                                                   // Zen Sphere
  116847: { energy: 40, cd: 6 },                                        // Rushing Jade Wind
  123904: { cd: 180 },                                                  // Invoke Xuen
  124507: {},                                                           // Gift of the Ox
};

export class MockState {
  constructor(init = {}) {
    this.chi = 0;
    this.maxChi = 4;
    this.energy = 100;
    this.maxEnergy = 100;
    this.energyRegen = 10;
    this.runicPower = 0;
    this.runes = {};
    this.health = 100000;
    this.maxHealth = 100000;
    this.staggerPct = 0;
    this.gcdRemain = 0;
    this.combatTime = 10;
    this.numTargets = 1;
    this.targetHealthPct = 1;
    this.inFront = true;
    this.moving = false;
    this.inputDelay = 0.15;
    this.baseGcd = 1.0;
    this.auras = {};   // id -> { remain, stacks }
    this.cds = {};     // id -> remain
    this.known = new Set();
    this.knownAuras = new Set();
    Object.assign(this, init);
  }

  AuraRemain(id) { const a = this.auras[id]; return a ? a.remain : 0; }
  AuraUp(id) { return this.AuraRemain(id) > 0; }
  AuraDown(id) { return this.AuraRemain(id) <= 0; }
  AuraStacks(id) { const a = this.auras[id]; return a ? a.stacks ?? 0 : 0; }
  AuraKnown(id) { return this.knownAuras.has(id) || this.known.has(id); }
  SpellKnown(id) { return this.known.has(id); }
  CdRemain(id) { return this.cds[id] ?? 0; }
  CdDuration(id) { return ECON[id]?.cd ?? 0; }
  SpellReady(id) { return this.CdRemain(id) <= 0; }
  GcdReady() { return this.gcdRemain <= 0; }
  GcdRemain() { return this.gcdRemain; }
  HastedGcd() { return this.baseGcd; }
  InputDelay() { return this.inputDelay; }
  Chi() { return this.chi; }
  MaxChi() { return this.maxChi; }
  Energy() { return this.energy; }
  MaxEnergy() { return this.maxEnergy; }
  EnergyRegen() { return this.energyRegen; }
  RunicPower() { return this.runicPower; }
  RuneCount(kind) {
    return Object.values(this.runes).filter((r) => r.ready && (r.kind === kind || (kind !== 'RuneDeath' && r.death))).length;
  }
  NonDeathRuneCount(kind) {
    return Object.values(this.runes).filter((r) => r.ready && !r.death && r.kind === kind).length;
  }
  DotPercentIncrease() { return 0; }
  Health() { return this.health; }
  MaxHealth() { return this.maxHealth; }
  HealthPct() { return this.health / this.maxHealth; }
  StaggerPct() { return this.staggerPct; }
  CombatTime() { return this.combatTime; }
  NumTargets() { return this.numTargets; }
  InFrontOfTarget() { return this.inFront !== false; }
  IsMoving() { return this.moving === true; }
  EnergyTimeTo(target) {
    if (this.energyRegen <= 0) return 3600;
    return Math.max(0, (target - this.energy) / this.energyRegen);
  }
  ExecutePhase(threshold) { return this.targetHealthPct <= (threshold ?? 0.2); }

  SpellCanCast(id) {
    if (!this.known.has(id)) return false;
    if (this.CdRemain(id) > 0) return false;
    const e = ECON[id];
    if (e) {
      if (e.energy && this.energy < e.energy) return false;
      if (e.chi && this.chi < e.chi) return false;
    }
    return true;
  }

  clone() {
    const c = new MockState();
    Object.assign(c, this);
    c.auras = {};
    for (const [id, a] of Object.entries(this.auras)) c.auras[id] = { ...a };
    c.cds = { ...this.cds };
    c.known = this.known;
    c.knownAuras = this.knownAuras;
    return c;
  }

  applyCast(action) {
    if (!action || action.op !== 'castSpell' || !action.id) return;
    const e = ECON[action.id];
    if (e) {
      if (e.energy) this.energy = Math.max(0, this.energy - e.energy);
      if (e.chi) this.chi = Math.max(0, this.chi - e.chi);
      if (e.gainChi) this.chi = Math.min(this.maxChi, this.chi + e.gainChi);
      if (e.cd) this.cds[action.id] = e.cd;
      if (e.applies) {
        for (const [auraId, dur] of Object.entries(e.applies)) {
          const prev = this.auras[auraId];
          this.auras[auraId] = { remain: dur, stacks: prev?.stacks ?? 1 };
        }
      }
    }
    this.advance(Math.max(this.baseGcd, this.gcdRemain));
  }

  advance(dt) {
    if (dt <= 0) return;
    this.combatTime += dt;
    this.energy = Math.min(this.maxEnergy, this.energy + this.energyRegen * dt);
    this.gcdRemain = 0;
    for (const [id, a] of Object.entries(this.auras)) {
      a.remain = Math.max(0, a.remain - dt);
      if (a.remain <= 0) delete this.auras[id];
    }
    for (const id of Object.keys(this.cds)) {
      this.cds[id] = Math.max(0, this.cds[id] - dt);
      if (this.cds[id] <= 0) delete this.cds[id];
    }
  }
}

/** Filter lines to those this character could use, mirroring Rotation:LineApplies. */
export function activeLines(rotation, S) {
  return rotation.lines.filter((line) => {
    const a = line.action;
    if (a.passive || a.other || a.item) return false;
    if (a.op === 'castSpell' && a.id && !S.known.has(a.id)) return false;
    for (const id of line.spells || []) {
      if (id !== a.id && !S.known.has(id) && !S.knownAuras.has(id)) return false;
    }
    return true;
  });
}
