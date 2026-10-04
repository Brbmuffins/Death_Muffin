'use strict';
// Tiny glob: ** crosses directories, * and ? do not. "**/x" also matches a root-level "x".
const cache = new Map();
function globToRegex(glob) {
  if (cache.has(glob)) return cache.get(glob);
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i++;
        if (glob[i + 1] === '/') { i++; re += '(?:.*/)?'; } else re += '.*';
      } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  const r = new RegExp('^' + re + '$');
  cache.set(glob, r);
  return r;
}
const matches = (glob, p) => globToRegex(glob).test(p);
const matchesAny = (globs, p) => globs.some((g) => matches(g, p));
module.exports = { globToRegex, matches, matchesAny };
