'use strict';
// Deterministic checkers for "casual" edits to content files. Input is a hunk: { removed: [lines], added: [lines] } (from `git diff -U0`).
// numericOnly: every changed line pair is identical except for numbers, and each new number is within +-tol% of the number it replaced.
// textOnly:    every changed line pair is identical except for the contents of string literals (optionally only values of allowed keys).
const NUM = /(?<![\w.$])-?\d+(?:\.\d+)?(?:e[+-]?\d+)?(?![\w.])/gi;

function numericPair(oldLine, newLine, tolPct) {
  const on = oldLine.match(NUM) || [], nn = newLine.match(NUM) || [];
  if (on.length === 0 || on.length !== nn.length) return false;
  if (oldLine.replace(NUM, '#') !== newLine.replace(NUM, '#')) return false;
  let changed = false;
  for (let i = 0; i < on.length; i++) {
    const a = Number(on[i]), b = Number(nn[i]);
    if (!Number.isFinite(a) || !Number.isFinite(b)) return false;
    if (a === b) continue;
    changed = true;
    if (a === 0) return false;                       // zero -> anything is not "within 25% of current"
    if (Math.sign(a) !== Math.sign(b)) return false;
    if (Math.abs(b - a) > Math.abs(a) * tolPct / 100 + 1e-12) return false;
  }
  return changed;
}
function numericOnly(hunk, tolPct = 25) {
  if (!hunk.removed.length || hunk.removed.length !== hunk.added.length) return false;
  return hunk.removed.every((l, i) => numericPair(l, hunk.added[i], tolPct));
}

const STR = /'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|`[^`\n]*`/g;
function splitStrings(line) {
  const strs = []; const pos = [];
  const skel = line.replace(STR, (m, off) => { strs.push(m); pos.push(off); return '⟦S⟧'; });
  return { skel, strs, pos };
}
function keyBefore(line, offset) {
  const m = /([A-Za-z_$][\w$]*|'[^']+'|"[^"]+")\s*:\s*$/.exec(line.slice(0, offset));
  return m ? m[1].replace(/^['"]|['"]$/g, '') : null;
}
function textPair(oldLine, newLine, keys) {
  const o = splitStrings(oldLine), n = splitStrings(newLine);
  if (o.skel !== n.skel || o.strs.length !== n.strs.length || o.strs.length === 0) return false;
  let changed = false;
  for (let i = 0; i < o.strs.length; i++) {
    if (o.strs[i] === n.strs[i]) continue;
    changed = true;
    if (n.strs[i][0] === '`' && n.strs[i].includes('${')) return false;
    if (o.strs[i][0] === '`' && o.strs[i].includes('${')) return false;
    if (/[<>]|javascript:|\bon\w+\s*=/i.test(n.strs[i])) return false;   // text, not markup
    if (keys !== '*') {
      const k = keyBefore(newLine, n.pos[i]);
      if (!k || !keys.includes(k)) return false;
    }
  }
  return changed;
}
function textOnly(hunk, keys = '*') {
  if (!hunk.removed.length || hunk.removed.length !== hunk.added.length) return false;
  return hunk.removed.every((l, i) => textPair(l, hunk.added[i], keys));
}
module.exports = { numericOnly, textOnly, numericPair, textPair };
