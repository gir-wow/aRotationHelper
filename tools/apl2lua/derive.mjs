#!/usr/bin/env node
// derive.mjs - derive a general APL from encounter-specific presets.
//
// Usage:
//   node tools/apl2lua/derive.mjs --spec death_knight/blood \
//     --presets horridon,iron_juggernaut,sha --output default
//
// A line common to every supplied preset is retained in the order of the first
// preset. Encounter-only lines are intentionally excluded. This is data
// preparation only; apl2lua.mjs still rejects an opcode until the live addon
// implementation and offline interpreter both support it.

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname).replace(/^\/([A-Za-z]:)/, '$1'), '../..');

function parseArgs(argv) {
  const out = { output: 'default' };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--spec') out.spec = argv[++i];
    else if (arg === '--presets') out.presets = argv[++i]?.split(',').filter(Boolean);
    else if (arg === '--output') out.output = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!out.help && (!out.spec || !out.presets || out.presets.length < 2)) {
    throw new Error('--spec and at least two comma-separated --presets are required');
  }
  return out;
}

function withoutUuids(value) {
  if (Array.isArray(value)) return value.map(withoutUuids);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => key !== 'uuid')
        .map(([key, child]) => [key, withoutUuids(child)]),
    );
  }
  return value;
}

function signature(line) {
  return JSON.stringify(withoutUuids(line));
}

function sharedInOrder(first, others) {
  const available = others.map((lines) => new Set(lines.map(signature)));
  return first.filter((line) => available.every((set) => set.has(signature(line))));
}

function loadPreset(spec, preset) {
  const file = path.join(ROOT, 'data', 'apls', spec, `${preset}.apl.json`);
  if (!fs.existsSync(file)) throw new Error(`no such preset: ${path.relative(ROOT, file)}`);
  return { file, data: JSON.parse(fs.readFileSync(file, 'utf8')) };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('usage: node tools/apl2lua/derive.mjs --spec class/spec --presets preset1,preset2 [--output default]');
    return;
  }

  const inputs = args.presets.map((preset) => loadPreset(args.spec, preset));
  const first = inputs[0].data;
  const priorityList = sharedInOrder(
    first.priorityList || [],
    inputs.slice(1).map(({ data }) => data.priorityList || []),
  );
  const prepullActions = sharedInOrder(
    first.prepullActions || [],
    inputs.slice(1).map(({ data }) => data.prepullActions || []),
  );
  const output = {
    type: first.type,
    simple: first.simple,
    prepullActions,
    priorityList,
  };
  const target = path.join(ROOT, 'data', 'apls', args.spec, `${args.output}.apl.json`);
  fs.writeFileSync(target, `${JSON.stringify(output, null, 2)}\n`);

  console.log(`${args.spec}/${args.output}`);
  console.log(`  inputs        : ${args.presets.join(', ')}`);
  console.log(`  shared prepull: ${prepullActions.length}`);
  console.log(`  shared lines  : ${priorityList.length}`);
  console.log(`  -> ${path.relative(ROOT, target).replace(/\\/g, '/')}`);
}

try {
  main();
} catch (error) {
  console.error(`\nderive failed:\n${error.message}\n`);
  process.exit(1);
}
