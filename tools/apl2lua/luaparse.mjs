// A deliberately tiny parser for the subset of Lua the generator emits:
// table constructors containing numbers, strings, booleans, nil and nested
// tables, with either `key = value` or positional entries.
//
// Its whole job is to let verify.mjs prove that the Lua we hand to the addon
// describes exactly the same rotation as the JSON we test against. Without this
// the Lua emitter is the one unverified link in the chain, and a malformed table
// would only show up as a WoW load error.

export function parseLuaTable(src) {
  let i = 0;

  function err(msg) {
    const around = src.slice(Math.max(0, i - 40), i + 40).replace(/\n/g, '\\n');
    throw new Error(`luaparse: ${msg} at offset ${i} near "...${around}..."`);
  }

  function skip() {
    for (;;) {
      // whitespace
      while (i < src.length && /\s/.test(src[i])) i++;
      // line comment
      if (src[i] === '-' && src[i + 1] === '-') {
        while (i < src.length && src[i] !== '\n') i++;
        continue;
      }
      return;
    }
  }

  function readString() {
    const quote = src[i];
    i++;
    let out = '';
    while (i < src.length && src[i] !== quote) {
      if (src[i] === '\\') {
        i++;
        const c = src[i];
        if (c === 'n') out += '\n';
        else if (c === 't') out += '\t';
        else out += c;
        i++;
      } else {
        out += src[i++];
      }
    }
    if (src[i] !== quote) err('unterminated string');
    i++;
    return out;
  }

  function readName() {
    const start = i;
    while (i < src.length && /[A-Za-z0-9_]/.test(src[i])) i++;
    if (i === start) err('expected a name');
    return src.slice(start, i);
  }

  function readNumber() {
    const start = i;
    if (src[i] === '-' || src[i] === '+') i++;
    while (i < src.length && /[0-9.eE+-]/.test(src[i])) {
      // stop before a trailing comma/brace that regex would otherwise eat
      if ((src[i] === '+' || src[i] === '-') && !/[eE]/.test(src[i - 1])) break;
      i++;
    }
    const n = Number(src.slice(start, i));
    if (!Number.isFinite(n)) err('bad number');
    return n;
  }

  function readValue() {
    skip();
    const c = src[i];
    if (c === '{') return readTable();
    if (c === '"' || c === "'") return readString();
    if (c === '-' || c === '+' || /[0-9.]/.test(c)) return readNumber();
    const name = readName();
    if (name === 'true') return true;
    if (name === 'false') return false;
    if (name === 'nil') return null;
    err(`unexpected identifier '${name}'`);
  }

  function readTable() {
    skip();
    if (src[i] !== '{') err("expected '{'");
    i++;
    const map = {};
    const arr = [];
    let isArray = true;

    for (;;) {
      skip();
      if (src[i] === '}') {
        i++;
        break;
      }
      if (src[i] === ',' || src[i] === ';') {
        i++;
        continue;
      }

      // bracketed key: ["foo"] = / [1] =
      if (src[i] === '[') {
        i++;
        const key = readValue();
        skip();
        if (src[i] !== ']') err("expected ']'");
        i++;
        skip();
        if (src[i] !== '=') err("expected '=' after bracketed key");
        i++;
        map[String(key)] = readValue();
        isArray = false;
        continue;
      }

      // name = value, or a positional value
      const save = i;
      if (/[A-Za-z_]/.test(src[i])) {
        const name = readName();
        skip();
        if (src[i] === '=') {
          i++;
          map[name] = readValue();
          isArray = false;
          continue;
        }
        i = save; // it was a positional keyword value (true/false/nil)
      }
      arr.push(readValue());
    }

    if (isArray && arr.length > 0) return arr;
    if (arr.length > 0) {
      // mixed: expose positional entries under 1-based keys, matching Lua
      arr.forEach((v, idx) => {
        map[String(idx + 1)] = v;
      });
    }
    return map;
  }

  skip();
  const value = readTable();
  return value;
}

/**
 * Pull the single `ns.Rotations["KEY"] = { ... }` assignment out of a generated
 * rotation file and parse it.
 */
export function parseGeneratedRotation(src) {
  const m = src.match(/ns\.Rotations\[\s*"([^"]+)"\s*\]\s*=\s*/);
  if (!m) throw new Error('luaparse: no ns.Rotations assignment found');
  const key = m[1];
  const body = src.slice(m.index + m[0].length);
  return { key, data: parseLuaTable(body) };
}
