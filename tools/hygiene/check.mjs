#!/usr/bin/env node
// Repo hygiene check: docs, references and retired terms must not outlive what they point at.
// See tools/hygiene/README.md. Plain Node, no dependencies.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const config = JSON.parse(readFileSync(path.join(root, 'tools/hygiene/retired.json'), 'utf8'));

const files = execFileSync('git', ['ls-files', '-z'], { cwd: root, maxBuffer: 1 << 28 })
  .toString().split('\0').filter(Boolean)
  .filter((f) => existsSync(path.join(root, f)));

// Glob -> RegExp: ** any depth, * within a segment, ? one char.
function globToRe(g) {
  let re = '';
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === '*') {
      if (g[i + 1] === '*') { re += '.*'; i++; if (g[i + 1] === '/') i++; } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$');
}
const globCache = new Map();
function matches(globs, file) {
  return (globs || []).some((g) => {
    if (!globCache.has(g)) globCache.set(g, globToRe(g));
    return globCache.get(g).test(file);
  });
}

const problems = [];
const report = (file, line, msg) => problems.push(`${file}:${line}: ${msg}`);
const read = (f) => readFileSync(path.join(root, f), 'utf8');
const lineOf = (text, idx) => text.slice(0, idx).split('\n').length;
const exists = (p) => existsSync(path.join(root, p));

const mdFiles = files.filter((f) => f.endsWith('.md') && !matches(['godot/tests/**'], f));

// Blank out fenced code blocks (keeping line numbers) when asked.
function stripFences(text) {
  let inFence = false;
  return text.split('\n').map((l) => {
    if (/^\s*(```|~~~)/.test(l)) { inFence = !inFence; return ''; }
    return inFence ? '' : l;
  }).join('\n');
}

// a. Relative Markdown links.
for (const f of mdFiles) {
  const text = stripFences(read(f));
  const re = /(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)|!\[[^\]]*\]\(([^)\s]+)\)/g;
  let m;
  while ((m = re.exec(text))) {
    let target = m[1] || m[2];
    if (/^([a-z][a-z0-9+.-]*:|#|\/\/)/i.test(target)) continue;
    target = decodeURI(target.split('#')[0].split('?')[0]);
    if (!target) continue;
    const abs = target.startsWith('/') ? target.slice(1) : path.posix.join(path.posix.dirname(f), target);
    if (!exists(abs)) report(f, lineOf(text, m.index), `broken link: ${m[1] || m[2]}`);
  }
}

// b. Backticked repo paths.
const ROOT_PREFIXES = ['godot/', 'server/', 'tools/', 'launcher/', 'docs/', '.github/', 'public/', 'art-manifest/'];
const rootFiles = new Set(files.filter((f) => !f.includes('/')));
const looksLikePath = (s) => /^[A-Za-z0-9_.\-/]+$/.test(s);
function resolvesAnywhere(p, docDir) {
  const cands = [p, path.posix.join(docDir, p)];
  if (/^(tests|next|rules|data|session|front)(\/|$)/.test(p)) cands.push('godot/' + p);
  return cands.some((c) => exists(c));
}
for (const f of mdFiles) {
  const text = stripFences(read(f));
  const re = /`([^`\n]+)`/g;
  let m;
  while ((m = re.exec(text))) {
    let s = m[1].trim().replace(/[.,:;]+$/, '');
    if (/[*<>{}]|NNN|\.\.\.|\$/.test(s) || /^(\/|~|https?:)/.test(s) || !looksLikePath(s)) continue;
    const isRepoish = ROOT_PREFIXES.some((p) => s.startsWith(p)) || rootFiles.has(s.replace(/\/$/, ''))
      || /^(tests|next)\//.test(s);
    if (!isRepoish) continue;
    s = s.replace(/\/$/, '');
    if ((config.allowPaths?.[f] || []).includes(s) || (config.allowPaths?.[f] || []).includes(s + '/')) continue;
    if (!resolvesAnywhere(s, path.posix.dirname(f))) report(f, lineOf(text, m.index), `path does not exist: \`${m[1]}\``);
  }
}
// Root-looking files named in backticks that are NOT tracked (README.md typo'd etc.) are not guessed; only listed ones are checked.
for (const f of mdFiles) {
  const text = stripFences(read(f));
  const re = /`((?:[A-Z][A-Z0-9_-]*)\.(?:md|json))`/g;
  let m;
  while ((m = re.exec(text))) {
    if (!resolvesAnywhere(m[1], path.posix.dirname(f)) && !files.some((x) => x.endsWith('/' + m[1])))
      report(f, lineOf(text, m.index), `file does not exist: \`${m[1]}\``);
  }
}

// c. Retired terms.
const scanExt = /\.(md|sh|cjs|mjs|js|ts|gd|yml|json)$/;
const scanSkip = config.scanExclude || [];
const scanFiles = files.filter((f) => scanExt.test(f) && !matches(scanSkip, f) && !f.split('/').includes('node_modules'));
for (const t of config.terms) {
  const re = new RegExp(t.pattern, t.flags || 'g');
  const g = re.flags.includes('g') ? re : new RegExp(re.source, re.flags + 'g');
  for (const f of scanFiles) {
    if (matches(t.allow, f)) continue;
    const lines = read(f).split('\n');
    for (let i = 0; i < lines.length; i++) {
      g.lastIndex = 0;
      let m;
      while ((m = g.exec(lines[i]))) {
        if (t.allowLine && new RegExp(t.allowLine).test(lines[i])) break;
        report(f, i + 1, `retired term "${m[0]}" (${t.id}): ${t.reason}`);
        if (m[0] === '') g.lastIndex++;
        break;
      }
    }
  }
}

// d. Test suite paths.
const suiteRe = /(?:res:\/\/)?\btests\/([A-Za-z0-9_\-]+)\/([A-Za-z0-9_\-]+\.gd)\b|res:\/\/tests\/([A-Za-z0-9_\-]+)\//g;
const suiteFiles = files.filter((f) => /\.(md|sh|yml)$/.test(f) && !matches(['godot/tests/**/fixtures/**', 'PATCH_NOTES.json', ...scanSkip.filter((g) => !g.startsWith('godot/tests'))], f));
for (const f of suiteFiles) {
  const text = read(f);
  let m;
  suiteRe.lastIndex = 0;
  while ((m = suiteRe.exec(text))) {
    const after = text[m.index + m[0].length];
    if (/[*<{$]/.test(after || '') || /[*<{$]/.test(text[m.index - 1] || '')) continue;
    const tok = m[0].replace(/^res:\/\//, '');
    // Skip when part of a longer path whose root is not godot (e.g. launcher/tests/..., server/x/tests/...).
    const before = text.slice(0, m.index);
    const lead = /([A-Za-z0-9_.\-/]*)$/.exec(before)[1];
    if (lead && !lead.endsWith('godot/') && !m[0].startsWith('res://')) continue;
    if (!exists('godot/' + tok)) report(f, lineOf(text, m.index), `test path does not exist: ${m[0]}`);
  }
}

// e. Large files.
const limit = (config.maxFileMB || 20) * 1024 * 1024;
for (const f of files) {
  const size = statSync(path.join(root, f)).size;
  if (size > limit && !(config.bigFileAllow || []).includes(f)) report(f, 1, `file is ${(size / 1048576).toFixed(1)} MB (> ${config.maxFileMB || 20} MB); add to bigFileAllow if intended`);
}

// f. 3D textures import VRAM-compressed (Godot's detect_3d never triggers for glTF-extracted images or headless imports).
const fixTextures = process.argv.includes('--fix-textures');
const fixed = [];
const tex3d = ['godot/assets/slice/models/', 'godot/assets/slice/art/textures/', 'godot/assets/fx/art/', 'godot/assets/fx/tex/',
  'godot/assets/fx/binbun/tex/', 'godot/assets/fx/models/', 'godot/world_fx/assets/'];
for (const f of files) {
  if (!f.endsWith('.import') || !tex3d.some((d) => f.startsWith(d))) continue;
  const text = read(f);
  if (!text.includes('importer="texture"')) continue;
  const isNormal = /(NormalGL|_n\.|normal)/i.test(f);
  const ok = /^compress\/mode=2$/m.test(text) && (!isNormal || /^compress\/normal_map=1$/m.test(text));
  if (ok) continue;
  if (fixTextures) {   // --fix-textures: rewrite the .import (BPTC for colour, RGTC for normal maps); re-import with `godot --headless --path godot --import`
    let t = text.replace(/^compress\/mode=\d+$/m, 'compress/mode=2').replace(/^compress\/high_quality=\w+$/m, `compress/high_quality=${isNormal ? 'false' : 'true'}`);
    if (isNormal) t = t.replace(/^compress\/normal_map=\d+$/m, 'compress/normal_map=1');
    writeFileSync(path.join(root, f), t);
    fixed.push(f);
    continue;
  }
  report(f, 1, isNormal ? 'a normal map must import VRAM Compressed with compress/normal_map=1 (npm run hygiene -- --fix-textures)'
    : 'a 3D texture must import VRAM Compressed, compress/mode=2 (npm run hygiene -- --fix-textures)');
}

if (fixed.length) console.log(`hygiene: fixed ${fixed.length} texture import(s); now run: godot --headless --path godot --import`);
if (problems.length) {
  console.error(problems.join('\n'));
  console.error(`\nhygiene: ${problems.length} violation(s). See tools/hygiene/README.md.`);
  process.exit(1);
}
console.log(`hygiene: OK (${mdFiles.length} docs, ${scanFiles.length} files scanned, ${config.terms.length} retired terms)`);
