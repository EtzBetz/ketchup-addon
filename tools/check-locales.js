// Checks Locales/*.lua against the L["..."] keys used in the code: missing,
// unknown and duplicate keys, placeholder mismatches (%s/%d count and order;
// %n$ positional allowed) and line-break mismatches.
// Only literal keys are found, so always write L["text"], never L[variable].
// Usage: node tools/check-locales.js
const lp = require('luaparse'); const fs = require('fs'); const path = require('path');
const root = path.resolve(__dirname, '..');

// 1. every L["..."] key in the code (raw source spelling)
const keys = new Map();
for (const f of fs.readdirSync(root).filter(f => f.endsWith('.lua') && f !== 'Locale.lua')) {
  const ast = lp.parse(fs.readFileSync(path.join(root, f), 'utf8'), { luaVersion: '5.1' });
  (function walk(n) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) return n.forEach(walk);
    if (n.type === 'IndexExpression' && n.base && n.base.type === 'Identifier' && n.base.name === 'L'
        && n.index && n.index.type === 'StringLiteral') {
      const raw = n.index.raw.slice(1, -1);
      if (!keys.has(raw)) keys.set(raw, f);
    }
    for (const k in n) walk(n[k]);
  })(ast);
}
console.log(keys.size + ' keys in code');

// 2. each translation file against them
const ph = s => [...s.matchAll(/%(\d+\$)?([sd])/g)].map(m => ({ pos: m[1] ? parseInt(m[1]) : null, t: m[2] }));
let bad = 0;
for (const file of fs.readdirSync(path.join(root, 'Locales')).filter(f => f.endsWith('.lua')).sort()) {
  const src = fs.readFileSync(path.join(root, 'Locales', file), 'utf8');
  let ast;
  try { ast = lp.parse(src, { luaVersion: '5.1' }); } catch (e) { console.log(file, 'SYNTAX', e.message); bad++; continue; }
  const call = ast.body[1] && ast.body[1].expression; // ns.RegisterLocale("xxXX", { ... })
  const seen = new Map(); const problems = [];
  for (const f of call.arguments[1].fields) {
    const k = f.key.raw.slice(1, -1), v = f.value.raw.slice(1, -1);
    if (seen.has(k)) problems.push('duplicate: ' + k);
    seen.set(k, v);
    if (!keys.has(k)) problems.push('unknown key: ' + k);
    const pk = ph(k), pv = ph(v);
    if (pk.length !== pv.length) problems.push(`placeholder count ${pk.length}->${pv.length}: ${k}`);
    else if (pv.some(p => p.pos !== null)) {
      for (const p of pv) if (!p.pos || !pk[p.pos - 1] || pk[p.pos - 1].t !== p.t) problems.push('bad positional: ' + k);
    } else if (pk.map(p => p.t).join() !== pv.map(p => p.t).join()) problems.push('placeholder order: ' + k);
    if (/\\n/.test(k) !== /\\n/.test(v)) problems.push('line break mismatch: ' + k);
  }
  for (const k of keys.keys()) if (!seen.has(k)) problems.push('missing: ' + k);
  console.log(`${file}: ${seen.size} entries, ${problems.length ? problems.length + ' problem(s)' : 'OK'} (locale ${call.arguments[0].raw})`);
  problems.forEach(p => console.log('   ' + p)); bad += problems.length;
}
process.exit(bad ? 1 : 0);
