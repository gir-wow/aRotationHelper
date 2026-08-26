#!/usr/bin/env node
// verify.mjs - prove the compiled rotation picks what we expect.
//
//   node tools/apl2lua/verify.mjs
//
// Three kinds of check:
//   1. Parity   - every opcode in the registry is implemented by BOTH the Lua
//                 engine and the offline interpreter. Catches the failure mode
//                 where the generator happily emits something the addon cannot
//                 read.
//   2. Scenarios- hand-built states with an asserted answer. This is where the
//                 interesting Brewmaster questions get pinned down: does Tiger
//                 Palm win over Jab when energy-starved, does Jab only appear at
//                 the energy cap, does Blackout Kick fire to rescue Shuffle.
//   3. Levelling- a character that knows only two abilities still gets sane
//                 advice, which is the whole basis of level 1-90 support.

import fs from 'node:fs';
import path from 'node:path';
import { VALUES, ACTIONS } from './opcodes.mjs';
import { READER, ID_READER, MockState, pickRotation, activeLines, evalValue } from './interp.mjs';
import { parseGeneratedRotation } from './luaparse.mjs';

const HERE = path.dirname(new URL(import.meta.url).pathname).replace(/^\/([A-Za-z]:)/, '$1');
const ROOT = path.resolve(HERE, '../..');

let pass = 0;
let fail = 0;
const failures = [];

function check(name, cond, detail) {
  if (cond) {
    pass++;
  } else {
    fail++;
    failures.push(`${name}${detail ? `\n      ${detail}` : ''}`);
  }
}

// ---------------------------------------------------------------------------
// spell ids
// ---------------------------------------------------------------------------
const ID = {
  JAB: 100780, TIGER_PALM: 100787, BLACKOUT_KICK: 100784, KEG_SMASH: 121253,
  EXPEL_HARM: 115072, GUARD: 115295, PURIFYING_BREW: 119582, ELUSIVE_BREW: 115308,
  CHI_BREW: 115399, CHI_WAVE: 115098, RJW: 116847, GIFT_OF_OX: 124507,
  INVOKE_XUEN: 123904,
  // auras
  SHUFFLE: 115307, TIGER_POWER: 125359, POWER_GUARD: 118636,
  BREWING_ELUSIVE: 128938, VENGEANCE: 120267,
  T15_PURIFIER: 138237, T15_WW_SPHERE: 138177,
};
const NAME = Object.fromEntries(Object.entries(ID).map(([k, v]) => [v, k]));

// A level-90 build: Chi Brew, Rushing Jade Wind, Chi Wave, no tier set bonuses.
const KNOWN_90 = new Set([
  ID.JAB, ID.TIGER_PALM, ID.BLACKOUT_KICK, ID.KEG_SMASH, ID.EXPEL_HARM,
  ID.GUARD, ID.PURIFYING_BREW, ID.ELUSIVE_BREW, ID.CHI_BREW, ID.CHI_WAVE,
  ID.RJW, ID.GIFT_OF_OX,
]);
const KNOWN_AURAS_90 = new Set([
  ID.SHUFFLE, ID.TIGER_POWER, ID.POWER_GUARD, ID.BREWING_ELUSIVE, ID.VENGEANCE,
  ID.ELUSIVE_BREW,
]);

function baseState(over = {}) {
  const s = new MockState({
    maxChi: 4,
    energy: 100,
    maxEnergy: 100,
    energyRegen: 10,
    health: 500000,
    maxHealth: 500000,
    known: KNOWN_90,
    knownAuras: KNOWN_AURAS_90,
    ...over,
  });
  s.auras = {};
  s.cds = {};
  for (const [k, v] of Object.entries(over.auras || {})) s.auras[k] = v;
  for (const [k, v] of Object.entries(over.cds || {})) s.cds[k] = v;
  return s;
}

const rotPath = path.join(ROOT, 'tools/apl2lua/out/monk_brewmaster_default.json');
if (!fs.existsSync(rotPath)) {
  console.error(`missing ${path.relative(ROOT, rotPath)} - run apl2lua.mjs first`);
  process.exit(1);
}
const rotation = JSON.parse(fs.readFileSync(rotPath, 'utf8'));
const bloodPath = path.join(ROOT, 'tools/apl2lua/out/death_knight_blood_default.json');
if (!fs.existsSync(bloodPath)) {
  console.error(`missing ${path.relative(ROOT, bloodPath)} - run addon:build:blood first`);
  process.exit(1);
}
const bloodRotation = JSON.parse(fs.readFileSync(bloodPath, 'utf8'));

// ---------------------------------------------------------------------------
// 1. parity between the two interpreters
// ---------------------------------------------------------------------------
console.log('--- interpreter parity ---');
const engineLua = fs.readFileSync(path.join(ROOT, 'core/engine.lua'), 'utf8');

const STRUCTURAL = new Set(['const', 'and', 'or', 'not', 'cmp', 'math', 'max', 'min',
  'energyTimeToTarget', 'isExecutePhase']);

for (const op of Object.keys(VALUES)) {
  if (STRUCTURAL.has(op)) {
    check(`engine.lua handles structural op '${op}'`, engineLua.includes(`"${op}"`));
    continue;
  }
  check(`interp.mjs implements '${op}'`, !!(READER[op] || ID_READER[op]));
  check(`engine.lua implements '${op}'`, new RegExp(`\\b${op}\\s*=`).test(engineLua),
    `expected an entry for ${op} in engine.lua's READER or ID_READER`);
}
for (const op of Object.keys(ACTIONS)) {
  check(`engine.lua knows action '${op}'`, ACTIONS[op].passive || ACTIONS[op].firstCastOnly || engineLua.includes(`"${op}"`));
}

// Every opcode the compiled rotation actually uses must evaluate without throwing.
console.log('--- rotation opcodes evaluate ---');
{
  const s = baseState();
  const lines = activeLines(rotation, s);
  let threw = null;
  for (const line of lines) {
    try {
      if (line.cond) evalValue(line.cond, s);
    } catch (e) {
      threw = `line #${line.idx}: ${e.message}`;
      break;
    }
  }
  check('all active conditions evaluate cleanly', threw === null, threw);
}

// ---------------------------------------------------------------------------
// 2. scenarios
// ---------------------------------------------------------------------------
console.log('--- scenarios ---');

function pick(state) {
  const lines = activeLines(rotation, state);
  return { pick: pickRotation(lines, state), lines };
}

function expectPick(label, state, wantId, note) {
  const { pick: p } = pick(state);
  const gotId = p?.action?.id ?? null;
  const ok = gotId === wantId;
  check(
    `${label} -> ${NAME[wantId] || wantId}`,
    ok,
    ok ? null : `got ${gotId ? `${NAME[gotId] || gotId} (line #${p.lineIdx})` : 'nothing'}${note ? `; ${note}` : ''}`,
  );
  return p;
}

// Set-bonus gating: without the T15 4pc we should not see its Purifying Brew line
// or the T15 Windwalker energy-sphere line at all.
{
  const s = baseState();
  const lines = activeLines(rotation, s);
  const idxs = lines.map((l) => l.idx);
  check('T15 4pc line (#2) dropped without the set', !idxs.includes(2));
  check('T15 WW sphere line (#9) dropped without the set', !idxs.includes(9));
  check('active line count is plausible for a 90 build', lines.length >= 8 && lines.length <= 20,
    `got ${lines.length} active lines: [${idxs.join(',')}]`);
  console.log(`      (level-90 build: ${lines.length}/${rotation.lines.length} lines active)`);
}

// Chi dumping ahead of Keg Smash. With Keg Smash ready and chi at maxChi-1, the
// sim spends chi first so Keg Smash's 2 chi does not overcap.
expectPick(
  'keg ready + chi 3 -> dump chi first',
  baseState({ chi: 3, auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 15 } } }),
  ID.BLACKOUT_KICK,
);

// Empty chi with Chi Brew available.
expectPick(
  'chi 0 -> Chi Brew',
  baseState({ chi: 0, auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 15 } } }),
  ID.CHI_BREW,
);

// Empty chi, Chi Brew on cooldown -> Keg Smash is the chi engine.
expectPick(
  'chi 0, Chi Brew down -> Keg Smash',
  baseState({
    chi: 0,
    cds: { [ID.CHI_BREW]: 30 },
    auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 15 } },
  }),
  ID.KEG_SMASH,
);

// THE Jab-vs-Tiger-Palm case. Energy-starved with nothing affordable: the free
// ability must win. The reference WeakAura gets this wrong because it gates Tiger
// Palm on chi >= 1, which is a Windwalker condition.
expectPick(
  'energy 20, chi 0, nothing affordable -> free Tiger Palm',
  baseState({
    chi: 0,
    energy: 20,
    cds: { [ID.CHI_BREW]: 30, [ID.KEG_SMASH]: 5, [ID.RJW]: 4, [ID.CHI_WAVE]: 10 },
    auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 0.5 } },
  }),
  ID.TIGER_PALM,
  'Jab costs 40 energy and we have 20; Tiger Palm is free for Brewmaster',
);

// Jab should appear only to avoid wasting energy, never as a general filler.
expectPick(
  'energy capped, everything else down -> Jab (energy dump)',
  baseState({
    chi: 2,
    energy: 100,
    cds: { [ID.CHI_BREW]: 30, [ID.KEG_SMASH]: 5, [ID.RJW]: 4, [ID.CHI_WAVE]: 10 },
    auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 15 } },
  }),
  ID.JAB,
);

// Shuffle rescue: it is about to drop and we can afford Blackout Kick.
expectPick(
  'Shuffle expiring -> Blackout Kick',
  baseState({
    chi: 3,
    energy: 50,
    cds: { [ID.KEG_SMASH]: 5, [ID.RJW]: 4 },
    auras: { [ID.SHUFFLE]: { remain: 1.0 }, [ID.TIGER_POWER]: { remain: 15 } },
  }),
  ID.BLACKOUT_KICK,
);

// Purifying Brew at moderate stagger (the sim's 3% threshold), once the damage
// abilities are unavailable.
expectPick(
  'moderate stagger -> Purifying Brew',
  baseState({
    chi: 2,
    energy: 30,
    staggerPct: 0.045,
    cds: { [ID.CHI_BREW]: 30, [ID.KEG_SMASH]: 5, [ID.RJW]: 4, [ID.CHI_WAVE]: 10 },
    auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 15 } },
  }),
  ID.PURIFYING_BREW,
);

// Light stagger is below the sim's 3% gate, so it must NOT purify.
{
  const s = baseState({
    chi: 2,
    energy: 30,
    staggerPct: 0.015,
    cds: { [ID.CHI_BREW]: 30, [ID.KEG_SMASH]: 5, [ID.RJW]: 4, [ID.CHI_WAVE]: 10 },
    auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 15 } },
  });
  const p = pick(s).pick;
  check('light stagger does NOT purify', p?.action?.id !== ID.PURIFYING_BREW,
    `got ${p ? NAME[p.action.id] || p.action.id : 'nothing'}`);
}

// Tiger Power upkeep beats the generic chi dump.
expectPick(
  'Tiger Power expiring -> Tiger Palm',
  baseState({
    chi: 3,
    energy: 30,
    cds: { [ID.CHI_BREW]: 30, [ID.KEG_SMASH]: 5, [ID.RJW]: 4, [ID.CHI_WAVE]: 10 },
    auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 1.0 } },
  }),
  ID.TIGER_PALM,
);

// Guard's Vengeance gate: the sim wants Vengeance >= 80000, which we normalise to
// a fraction of max health. With zero Vengeance the Guard line must not fire.
{
  const s = baseState({
    chi: 3,
    energy: 30,
    cds: { [ID.CHI_BREW]: 30, [ID.KEG_SMASH]: 5, [ID.RJW]: 4, [ID.CHI_WAVE]: 10 },
    auras: {
      [ID.SHUFFLE]: { remain: 5 },
      [ID.TIGER_POWER]: { remain: 15 },
      [ID.POWER_GUARD]: { remain: 20 },
      [ID.VENGEANCE]: { remain: 20, stacks: 0 },
    },
  });
  check('Guard held at zero Vengeance', pick(s).pick?.action?.id !== ID.GUARD);

  const hot = baseState({
    chi: 3,
    energy: 30,
    cds: { [ID.CHI_BREW]: 30, [ID.KEG_SMASH]: 5, [ID.RJW]: 4, [ID.CHI_WAVE]: 10 },
    auras: {
      [ID.SHUFFLE]: { remain: 5 },
      [ID.TIGER_POWER]: { remain: 15 },
      [ID.POWER_GUARD]: { remain: 20 },
      [ID.VENGEANCE]: { remain: 20, stacks: 90000 },
    },
  });
  expectPick('Guard fires at high Vengeance', hot, ID.GUARD);
}

// Elusive Brew at 6+ stacks.
expectPick(
  'Brewing: Elusive Brew at 6 stacks -> Elusive Brew',
  baseState({
    chi: 2,
    auras: {
      [ID.SHUFFLE]: { remain: 5 },
      [ID.TIGER_POWER]: { remain: 15 },
      [ID.BREWING_ELUSIVE]: { remain: 30, stacks: 6 },
    },
  }),
  ID.ELUSIVE_BREW,
);

// ---------------------------------------------------------------------------
// 3. levelling
// ---------------------------------------------------------------------------
console.log('--- levelling (graceful degradation) ---');
{
  // A low-level monk: Jab and Tiger Palm only.
  const lowKnown = new Set([ID.JAB, ID.TIGER_PALM]);
  const s = baseState({ chi: 0, energy: 100, known: lowKnown, knownAuras: new Set() });
  const { pick: p, lines } = pick(s);
  check('low level: some lines survive', lines.length > 0, `got ${lines.length}`);
  check('low level: nothing unlearned is suggested',
    p === null || lowKnown.has(p.action.id),
    `suggested ${p ? NAME[p.action.id] || p.action.id : 'nothing'}`);
  check('low level: an answer is produced', p !== null);
  console.log(`      (2 abilities known: ${lines.length}/${rotation.lines.length} lines active, picks ${p ? NAME[p.action.id] : 'nothing'})`);

  // Mid-level: add Blackout Kick and Keg Smash.
  const midKnown = new Set([ID.JAB, ID.TIGER_PALM, ID.BLACKOUT_KICK, ID.KEG_SMASH]);
  const m = baseState({ chi: 0, energy: 100, known: midKnown, knownAuras: new Set([ID.SHUFFLE, ID.TIGER_POWER]) });
  const mr = pick(m);
  check('mid level: more lines active than low level', mr.lines.length > lines.length,
    `${mr.lines.length} vs ${lines.length}`);
  check('mid level: picks Keg Smash with full energy and no chi',
    mr.pick?.action?.id === ID.KEG_SMASH,
    `got ${mr.pick ? NAME[mr.pick.action.id] || mr.pick.action.id : 'nothing'}`);
  console.log(`      (4 abilities known: ${mr.lines.length}/${rotation.lines.length} lines active)`);
}

// ---------------------------------------------------------------------------
// 3b. Blood DK rune mapping and shared core
// ---------------------------------------------------------------------------
console.log('--- Blood DK core ---');
{
  const bloodKnown = new Set([48982, 45529, 47568, 49998, 56815, 114867, 55050, 48721, 43265, 50613, 57330]);
  const bloodState = (over = {}) => new MockState({
    known: bloodKnown,
    knownAuras: new Set(),
    runes: {
      1: { kind: 'RuneBlood', ready: true },
      2: { kind: 'RuneBlood', ready: true },
      3: { kind: 'RuneFrost', ready: true },
      4: { kind: 'RuneFrost', ready: true },
      5: { kind: 'RuneUnholy', ready: true },
      6: { kind: 'RuneUnholy', ready: true },
    },
    ...over,
  });
  check('Blood DK derived core has 16 lines', bloodRotation.lines.length === 16,
    `got ${bloodRotation.lines.length}`);
  check('Blood DK maps two Frost runes from live type 3', bloodState().RuneCount('RuneFrost') === 2);
  check('Blood DK maps two Unholy runes from live type 2', bloodState().RuneCount('RuneUnholy') === 2);

  let pick = pickRotation(activeLines(bloodRotation, bloodState()), bloodState());
  check('Blood DK spends Frost + Unholy rune cap with Death Strike', pick?.action?.id === 49998,
    `got ${pick?.action?.id ?? 'nothing'}`);

  const noFrostUnholy = bloodState({
    runes: {
      1: { kind: 'RuneBlood', ready: true },
      2: { kind: 'RuneBlood', ready: true },
      3: { kind: 'RuneFrost', ready: false },
      4: { kind: 'RuneFrost', ready: false },
      5: { kind: 'RuneUnholy', ready: false },
      6: { kind: 'RuneUnholy', ready: false },
    },
  });
  pick = pickRotation(activeLines(bloodRotation, noFrostUnholy), noFrostUnholy);
  check('Blood DK spends two Blood runes with Heart Strike', pick?.action?.id === 55050,
    `got ${pick?.action?.id ?? 'nothing'}`);

  const runic = bloodState({ runicPower: 90, runes: {} });
  pick = pickRotation(activeLines(bloodRotation, runic), runic);
  check('Blood DK dumps high runic power with Rune Strike', pick?.action?.id === 56815,
    `got ${pick?.action?.id ?? 'nothing'}`);

  const forecast = [];
  let scratch = bloodState();
  for (let i = 0; i < 3; i++) {
    const next = pickRotation(activeLines(bloodRotation, scratch), scratch);
    if (!next) break;
    forecast.push(next.action.id);
    scratch.applyCast(next.action);
  }
  check('Blood DK forecast produces three projected actions', forecast.length === 3,
    `got [${forecast.join(', ')}]`);
  check('Blood DK forecast spends resources instead of repeating Death Strike',
    !(forecast[0] === 49998 && forecast[1] === 49998), `got [${forecast.join(', ')}]`);
}

// ---------------------------------------------------------------------------
// 4. projection
// ---------------------------------------------------------------------------
console.log('--- projection ---');
{
  const s = baseState({ chi: 3, auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 15 } } });
  const out = [];
  let scratch = s.clone();
  for (let i = 0; i < 3; i++) {
    const lines = activeLines(rotation, scratch);
    const p = pickRotation(lines, scratch);
    if (!p) break;
    out.push(p.action.id);
    scratch.applyCast(p.action);
  }
  check('projection produces 3 steps', out.length === 3, `got [${out.map((i) => NAME[i] || i).join(', ')}]`);
  check('projection does not repeat a 2-chi spender with no chi left',
    !(out[0] === ID.BLACKOUT_KICK && out[1] === ID.BLACKOUT_KICK),
    `got [${out.map((i) => NAME[i] || i).join(', ')}]`);
  console.log(`      (projected: ${out.map((i) => NAME[i] || i).join(' -> ')})`);

  // Projection must not mutate the live state.
  const before = { chi: s.chi, energy: s.energy };
  const lines2 = activeLines(rotation, s);
  const p2 = pickRotation(lines2, s);
  const c = s.clone();
  c.applyCast(p2.action);
  check('Clone/ApplyCast leaves the live state untouched',
    s.chi === before.chi && s.energy === before.energy,
    `chi ${before.chi}->${s.chi}, energy ${before.energy}->${s.energy}`);
}

// ---------------------------------------------------------------------------
// 5. the emitted Lua describes the same rotation as the JSON
// ---------------------------------------------------------------------------
// The Lua emitter is otherwise the one unverified link: a malformed table would
// only surface as a WoW load error.
console.log('--- Lua emitter round-trip ---');
{
  const luaFile = path.join(ROOT, 'rotations/monk_brewmaster_default.lua');
  check('generated Lua exists', fs.existsSync(luaFile));
  if (fs.existsSync(luaFile)) {
    let parsed = null;
    let parseErr = null;
    try {
      parsed = parseGeneratedRotation(fs.readFileSync(luaFile, 'utf8'));
    } catch (e) {
      parseErr = e.message;
    }
    check('generated Lua parses', parsed !== null, parseErr);

    if (parsed) {
      const L = parsed.data;
      check('Lua key matches', parsed.key === rotation.key, `${parsed.key} vs ${rotation.key}`);
      check('Lua line count matches JSON', (L.lines || []).length === rotation.lines.length,
        `${(L.lines || []).length} vs ${rotation.lines.length}`);
      check('Lua prepull count matches JSON', (L.prepull || []).length === rotation.prepull.length,
        `${(L.prepull || []).length} vs ${rotation.prepull.length}`);

      // Structural comparison of every line: same order, same action, same
      // condition shape.
      const norm = (v) => JSON.stringify(v, (k, val) => (val === null ? undefined : val));
      let mismatch = null;
      for (let n = 0; n < rotation.lines.length && !mismatch; n++) {
        const a = rotation.lines[n];
        const b = (L.lines || [])[n];
        if (!b) { mismatch = `line ${n + 1} missing from Lua`; break; }
        if (Number(b.idx) !== a.idx) mismatch = `line ${n + 1}: idx ${b.idx} vs ${a.idx}`;
        else if (norm(b.action) !== norm(a.action)) mismatch = `line ${n + 1} action: ${norm(b.action)} vs ${norm(a.action)}`;
        else if (norm(b.cond) !== norm(a.cond)) mismatch = `line ${n + 1} condition differs`;
      }
      check('every Lua line matches its JSON counterpart', mismatch === null, mismatch);

      // And the round-tripped Lua must drive the interpreter identically.
      const luaRot = { key: parsed.key, lines: (L.lines || []).map((l) => ({ ...l, idx: Number(l.idx) })) };
      const s = baseState({ chi: 3, auras: { [ID.SHUFFLE]: { remain: 5 }, [ID.TIGER_POWER]: { remain: 15 } } });
      const fromJson = pickRotation(activeLines(rotation, s), s);
      const fromLua = pickRotation(activeLines(luaRot, s), s);
      check('Lua and JSON pick the same action',
        fromJson?.action?.id === fromLua?.action?.id,
        `json=${fromJson?.action?.id} lua=${fromLua?.action?.id}`);
    }
  }
}

// ---------------------------------------------------------------------------
// results
// ---------------------------------------------------------------------------
console.log('');
if (fail === 0) {
  console.log(`all ${pass} checks passed`);
  process.exit(0);
}
console.log(`${pass} passed, ${fail} FAILED:\n`);
for (const f of failures) console.log(`  x ${f}`);
process.exit(1);
