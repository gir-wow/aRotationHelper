#!/usr/bin/env node
// apl2lua - compile a wowsims APL preset into an aRotationHelper rotation table.
//
//   node tools/apl2lua/apl2lua.mjs --spec monk/brewmaster --preset default
//   node tools/apl2lua/apl2lua.mjs --spec monk/brewmaster --preset default --lint-only
//
// Emits:
//   rotations/<class>_<spec>_<preset>.lua                         (for the addon)
//   tools/apl2lua/out/<class>_<spec>_<preset>.json                (for verify.mjs
//                                                                 and log replay)
//
// Design notes:
//  * Unknown opcodes are a hard error. A silently dropped priority line is the
//    worst possible failure mode for a rotation helper, so we refuse to build.
//  * `hide: true` lines are dropped, matching the sim.
//  * Every spell id referenced by a line - in the action AND anywhere in its
//    condition - is collected into `spells`, so the addon can drop lines whose
//    spells the player has not learned (levelling support).
//  * A percentage-vs-absolute lint catches the class of bug found in the Blood
//    DK preset, where `hpPct < maxHealth * 0.1` is always true.

import fs from 'node:fs';
import path from 'node:path';
import { VALUES, ACTIONS, KNOWN_VALUES, KNOWN_ACTIONS, TYPES, parseConst, actionId } from './opcodes.mjs';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname).replace(/^\/([A-Za-z]:)/, '$1'), '../..');

// ---------------------------------------------------------------------------
// args
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const out = { spec: 'monk/brewmaster', preset: 'default', lintOnly: false, quiet: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--spec') out.spec = argv[++i];
    else if (a === '--preset') out.preset = argv[++i];
    else if (a === '--file') out.file = argv[++i];
    else if (a === '--lint-only') out.lintOnly = true;
    else if (a === '--quiet') out.quiet = true;
    else if (a === '--help' || a === '-h') out.help = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  return out;
}

// ---------------------------------------------------------------------------
// spell name database
// ---------------------------------------------------------------------------
let NAMES = null;
function spellName(id) {
  if (!NAMES) {
    const dbPath = path.join(ROOT, 'data/spell-names.json');
    const names = JSON.parse(fs.readFileSync(dbPath, 'utf8'));
    NAMES = new Map(Object.entries(names).map(([id, name]) => [Number(id), name]));
  }
  return NAMES.get(id) || null;
}

// ---------------------------------------------------------------------------
// compile: APL JSON node -> IR node
// ---------------------------------------------------------------------------
class Ctx {
  constructor(file) {
    this.file = file;
    this.spells = new Set(); // per-line accumulator
    this.warnings = [];
    this.opcodes = new Set();
  }
  warn(where, msg) {
    this.warnings.push(`${where}: ${msg}`);
  }
}

function valueKey(node) {
  const keys = Object.keys(node).filter((k) => k !== 'uuid');
  if (keys.length === 0) throw new Error('empty value node');
  if (keys.length > 1) throw new Error(`ambiguous value node with keys [${keys.join(', ')}]`);
  return keys[0];
}

/** Returns { ir, type }. Throws on any opcode we do not implement. */
function compileValue(node, ctx, where) {
  if (node === undefined || node === null) throw new Error(`${where}: missing value`);
  const op = valueKey(node);
  const o = node[op] ?? {};

  if (!KNOWN_VALUES.has(op)) {
    throw new Error(
      `${where}: unimplemented value opcode '${op}'.\n` +
        `  Add it to tools/apl2lua/opcodes.mjs (VALUES) and implement the matching\n` +
        `  reader in core/state.lua before regenerating.`,
    );
  }
  ctx.opcodes.add(op);
  const spec = VALUES[op];

  switch (op) {
    case 'const': {
      const { value, type } = parseConst(o.val);
      return { ir: { op: 'const', v: value }, type };
    }
    case 'and':
    case 'or':
    case 'max':
    case 'min': {
      const vals = (o.vals || []).map((v, i) => compileValue(v, ctx, `${where}.${op}[${i}]`));
      if (vals.length === 0) throw new Error(`${where}: ${op} with no operands`);
      const type = op === 'and' || op === 'or' ? TYPES.BOOL : mergeType(vals.map((v) => v.type));
      return { ir: { op, vals: vals.map((v) => v.ir) }, type };
    }
    case 'not': {
      const v = compileValue(o.val, ctx, `${where}.not`);
      return { ir: { op: 'not', val: v.ir }, type: TYPES.BOOL };
    }
    case 'cmp': {
      const lhs = compileValue(o.lhs, ctx, `${where}.cmp.lhs`);
      const rhs = compileValue(o.rhs, ctx, `${where}.cmp.rhs`);
      lintCompare(lhs, rhs, ctx, `${where}.cmp`);
      return { ir: { op: 'cmp', cmpOp: o.op, lhs: lhs.ir, rhs: rhs.ir }, type: TYPES.BOOL };
    }
    case 'math': {
      const lhs = compileValue(o.lhs, ctx, `${where}.math.lhs`);
      const rhs = compileValue(o.rhs, ctx, `${where}.math.rhs`);
      return { ir: { op: 'math', mathOp: o.op, lhs: lhs.ir, rhs: rhs.ir }, type: mergeType([lhs.type, rhs.type]) };
    }
    case 'energyTimeToTarget': {
      const t = compileValue(o.targetEnergy, ctx, `${where}.energyTimeToTarget`);
      return { ir: { op, target: t.ir }, type: TYPES.TIME };
    }
    case 'isExecutePhase':
      return { ir: { op, threshold: o.threshold ?? 'ExecuteProportion20' }, type: TYPES.BOOL };
    default: {
      // leaf: either no operands, or a single ActionID under a known key
      const ir = { op };
      if (spec.args && spec.args.id) {
        const aid = actionId(o[spec.args.id]);
        if (!aid) throw new Error(`${where}: ${op} is missing its ${spec.args.id}`);
        if (aid.spell) {
          ir.id = aid.spell;
          ctx.spells.add(aid.spell);
          const n = spellName(aid.spell);
          if (n) ir.name = n;
        } else if (aid.item) {
          ir.item = aid.item;
        } else if (aid.other) {
          ir.other = aid.other;
        }
        if (aid.tag) ir.tag = aid.tag;
      }
      return { ir, type: spec.type ?? TYPES.NUM };
    }
  }
}

function mergeType(types) {
  const real = types.filter((t) => t && t !== TYPES.NUM);
  if (real.length === 0) return TYPES.NUM;
  return real.every((t) => t === real[0]) ? real[0] : TYPES.NUM;
}

/**
 * The percentage-vs-absolute lint.
 *
 * Catches `hpPct < (maxHealth * 0.1)` in the Blood DK presets: a 0..1 fraction
 * compared against an absolute health value, which is always true. The proto
 * carries enough type information to make this mechanical.
 */
function lintCompare(lhs, rhs, ctx, where) {
  const pair = new Set([lhs.type, rhs.type]);
  if (pair.has(TYPES.PCT) && pair.has(TYPES.ABS)) {
    ctx.warn(where, `compares a percentage against an absolute value (${lhs.type} vs ${rhs.type}) - this is almost certainly always-true or always-false`);
  }
  if (pair.has(TYPES.PCT) && pair.has(TYPES.NUM)) {
    // A percentage compared against a bare number > 1 can never be true.
    for (const side of [lhs, rhs]) {
      if (side.type === TYPES.NUM && side.ir.op === 'const' && typeof side.ir.v === 'number' && side.ir.v > 1) {
        ctx.warn(where, `compares a 0..1 percentage against the bare constant ${side.ir.v} - did you mean ${side.ir.v}%?`);
      }
    }
  }
}

function compileAction(node, ctx, where) {
  const cond = node.condition ? compileValue(node.condition, ctx, `${where}.condition`) : null;
  const keys = Object.keys(node).filter((k) => k !== 'condition');
  if (keys.length === 0) throw new Error(`${where}: action node has no action`);
  if (keys.length > 1) throw new Error(`${where}: ambiguous action with keys [${keys.join(', ')}]`);
  const op = keys[0];
  const o = node[op] ?? {};

  if (!KNOWN_ACTIONS.has(op)) {
    throw new Error(
      `${where}: unimplemented action opcode '${op}'.\n` +
        `  Add it to tools/apl2lua/opcodes.mjs (ACTIONS) and teach the engine how to\n` +
        `  execute it before regenerating. Sequences and channels are deliberately\n` +
        `  not yet supported - see the report, section 8.`,
    );
  }
  ctx.opcodes.add(op);

  const action = { op };
  const spec = ACTIONS[op];
  if (spec.args && spec.args.id) {
    const aid = actionId(o[spec.args.id]);
    if (!aid) throw new Error(`${where}: ${op} is missing its ${spec.args.id}`);
    if (aid.spell) {
      action.id = aid.spell;
      ctx.spells.add(aid.spell);
      const n = spellName(aid.spell);
      if (n) action.name = n;
    } else if (aid.item) action.item = aid.item;
    else if (aid.other) action.other = aid.other;
    if (aid.tag) action.tag = aid.tag;
  }
  if (spec.passive) action.passive = true;
  return { action, cond: cond ? cond.ir : null };
}

// ---------------------------------------------------------------------------
// compile a whole preset
// ---------------------------------------------------------------------------
export function compilePreset(specPath, presetName, explicitFile) {
  const file = explicitFile
    ? path.resolve(explicitFile)
    : path.join(ROOT, 'data', 'apls', specPath, `${presetName}.apl.json`);
  if (!fs.existsSync(file)) throw new Error(`no such preset: ${path.relative(ROOT, file)}`);
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  const ctx = new Ctx(file);

  const prepull = [];
  (raw.prepullActions || []).forEach((p, i) => {
    if (p.hide) return;
    ctx.spells = new Set();
    const { action, cond } = compileAction(p.action, ctx, `prepull[${i}]`);
    let at = null;
    if (p.doAtValue) {
      const v = compileValue(p.doAtValue, ctx, `prepull[${i}].doAtValue`);
      if (v.ir.op === 'const') at = v.ir.v;
    }
    prepull.push({ idx: i + 1, at, action, cond, spells: [...ctx.spells] });
  });

  const lines = [];
  let hidden = 0;
  (raw.priorityList || []).forEach((p, i) => {
    if (p.hide) {
      hidden++;
      return;
    }
    ctx.spells = new Set();
    const { action, cond } = compileAction(p.action, ctx, `priorityList[${i}]`);
    const line = { idx: i + 1, action, cond, spells: [...ctx.spells] };
    if (p.notes) line.notes = p.notes;
    lines.push(line);
  });

  return {
    spec: specPath,
    preset: presetName,
    source: path.relative(ROOT, file).replace(/\\/g, '/'),
    hiddenLines: hidden,
    prepull,
    lines,
    opcodes: [...ctx.opcodes].sort(),
    warnings: ctx.warnings,
  };
}

// ---------------------------------------------------------------------------
// Lua emitter
// ---------------------------------------------------------------------------
const LUA_IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;

function luaValue(v, indent) {
  if (v === null || v === undefined) return 'nil';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(v);
  if (typeof v === 'string') return `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  if (Array.isArray(v)) {
    if (v.length === 0) return '{}';
    const inner = v.map((x) => luaValue(x, indent + '  '));
    const oneLine = `{ ${inner.join(', ')} }`;
    if (oneLine.length <= 96 && !oneLine.includes('\n')) return oneLine;
    return `{\n${v.map((x) => `${indent}  ${luaValue(x, indent + '  ')},`).join('\n')}\n${indent}}`;
  }
  // table
  const entries = Object.entries(v).filter(([, val]) => val !== null && val !== undefined);
  if (entries.length === 0) return '{}';
  const parts = entries.map(([k, val]) => {
    const key = LUA_IDENT.test(k) ? `${k} = ` : `["${k}"] = `;
    return `${key}${luaValue(val, indent + '  ')}`;
  });
  const oneLine = `{ ${parts.join(', ')} }`;
  if (oneLine.length <= 96 && !oneLine.includes('\n')) return oneLine;
  return `{\n${parts.map((p) => `${indent}  ${p},`).join('\n')}\n${indent}}`;
}

function emitLua(compiled, key) {
  const L = [];
  L.push(`-- GENERATED FILE - do not edit by hand.`);
  L.push(`-- Source:    ${compiled.source}`);
  L.push(`-- Generator: tools/apl2lua/apl2lua.mjs`);
  L.push(`-- Regenerate with:`);
  L.push(`--   node tools/apl2lua/apl2lua.mjs --spec ${compiled.spec} --preset ${compiled.preset}`);
  L.push(`--`);
  L.push(`-- ${compiled.lines.length} active priority lines (${compiled.hiddenLines} hidden lines dropped).`);
  L.push(`-- Opcodes used: ${compiled.opcodes.join(', ')}`);
  L.push('');
  L.push(`local ADDON_NAME, ns = ...`);
  L.push(`ns.Rotations = ns.Rotations or {}`);
  L.push('');
  L.push(`ns.Rotations["${key}"] = ${luaValue(
    {
      key,
      spec: compiled.spec,
      preset: compiled.preset,
      source: compiled.source,
      prepull: compiled.prepull,
      lines: compiled.lines,
    },
    '',
  )}`);
  L.push('');
  return L.join('\n');
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('usage: node tools/apl2lua/apl2lua.mjs [--spec class/spec] [--preset name] [--lint-only]');
    return 0;
  }

  const compiled = compilePreset(args.spec, args.preset, args.file);
  const key = `${args.spec.replace('/', '_')}_${args.preset}`.toUpperCase();

  if (compiled.warnings.length) {
    console.warn(`\n${compiled.warnings.length} lint warning(s) for ${args.spec}/${args.preset}:`);
    for (const w of compiled.warnings) console.warn(`  ! ${w}`);
    console.warn('');
  }

  if (!args.quiet) {
    console.log(`${args.spec}/${args.preset}`);
    console.log(`  active lines : ${compiled.lines.length}`);
    console.log(`  hidden lines : ${compiled.hiddenLines} (dropped)`);
    console.log(`  prepull      : ${compiled.prepull.length}`);
    console.log(`  opcodes      : ${compiled.opcodes.length} (${compiled.opcodes.join(', ')})`);
  }

  if (args.lintOnly) return compiled.warnings.length ? 1 : 0;

  const luaDir = path.join(ROOT, 'rotations');
  const jsonDir = path.join(ROOT, 'tools/apl2lua/out');
  fs.mkdirSync(luaDir, { recursive: true });
  fs.mkdirSync(jsonDir, { recursive: true });

  const base = `${args.spec.replace('/', '_')}_${args.preset}`;
  const luaPath = path.join(luaDir, `${base}.lua`);
  const jsonPath = path.join(jsonDir, `${base}.json`);
  fs.writeFileSync(luaPath, emitLua(compiled, key));
  fs.writeFileSync(jsonPath, JSON.stringify({ key, ...compiled }, null, 1));

  if (!args.quiet) {
    console.log(`  -> ${path.relative(ROOT, luaPath).replace(/\\/g, '/')}`);
    console.log(`  -> ${path.relative(ROOT, jsonPath).replace(/\\/g, '/')}`);
  }
  return 0;
}

const invokedDirectly = process.argv[1] && process.argv[1].endsWith('apl2lua.mjs');
if (invokedDirectly) {
  try {
    process.exit(main());
  } catch (e) {
    console.error(`\napl2lua failed:\n${e.message}\n`);
    process.exit(1);
  }
}
