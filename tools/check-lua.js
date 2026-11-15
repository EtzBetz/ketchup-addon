// Lua 5.1 syntax check of every addon file (root *.lua and Locales/*.lua).
// Usage: node tools/check-lua.js
const lp = require('luaparse'); const fs = require('fs'); const path = require('path');
const root = path.resolve(__dirname, '..');
const files = [
  ...fs.readdirSync(root).filter(f => f.endsWith('.lua')),
  ...fs.readdirSync(path.join(root, 'Locales')).filter(f => f.endsWith('.lua')).map(f => 'Locales/' + f),
];
let bad = 0;
for (const f of files) {
  try { lp.parse(fs.readFileSync(path.join(root, f), 'utf8'), { luaVersion: '5.1' }); }
  catch (e) { bad++; console.log('ERR', f, e.message); }
}
console.log(bad ? `${bad} file(s) with syntax errors` : `${files.length} Lua files OK`);
process.exit(bad ? 1 : 0);
