#!/usr/bin/env node
// Repo hygiene check: docs, references and retired terms must not outlive what they point at.
// See tools/hygiene/README.md. Plain Node, no dependencies.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
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

const require_ = (p) => createRequire(import.meta.url)(path.join(root, p));
const problems = [];
const report = (file, line, msg) => problems.push(`${file}:${line}: ${msg}`);
const read = (f) => readFileSync(path.join(root, f), 'utf8');
const lineOf = (text, idx) => text.slice(0, idx).split('\n').length;
const exists = (p) => existsSync(path.join(root, p));

const mdFiles = files.filter((f) => f.endsWith('.md') && !matches(['client/tests/**'], f));

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
const ROOT_PREFIXES = ['client/', 'native/', 'server/', 'tools/', 'launcher/', 'teamapp/', 'docs/', '.github/', 'public/', 'art-manifest/'];
const rootFiles = new Set(files.filter((f) => !f.includes('/')));
const looksLikePath = (s) => /^[A-Za-z0-9_.\-/]+$/.test(s);
function resolvesAnywhere(p, docDir) {
  const cands = [p, path.posix.join(docDir, p)];
  if (/^(tests|next|rules|data|session|front)(\/|$)/.test(p)) cands.push('client/' + p);
  return cands.some((c) => exists(c));
}
// The decision log records what was true when each decision was made: its paths may name files that are gone since (config.historyDocs).
const historyDocs = config.historyDocs || [];
for (const f of mdFiles.filter((x) => !historyDocs.includes(x))) {
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
const suiteFiles = files.filter((f) => /\.(md|sh|yml)$/.test(f) && !historyDocs.includes(f) && !matches(['client/tests/**/fixtures/**', 'PATCH_NOTES.json', ...scanSkip.filter((g) => !g.startsWith('client/tests'))], f));
for (const f of suiteFiles) {
  const text = read(f);
  let m;
  suiteRe.lastIndex = 0;
  while ((m = suiteRe.exec(text))) {
    const after = text[m.index + m[0].length];
    if (/[*<{$]/.test(after || '') || /[*<{$]/.test(text[m.index - 1] || '')) continue;
    const tok = m[0].replace(/^res:\/\//, '');
    // Skip when part of a longer path whose root is not the game (e.g. launcher/tests/..., server/x/tests/...).
    const before = text.slice(0, m.index);
    const lead = /([A-Za-z0-9_.\-/]*)$/.exec(before)[1];
    if (lead && !lead.endsWith('client/') && !m[0].startsWith('res://')) continue;
    if (!exists('client/' + tok)) report(f, lineOf(text, m.index), `test path does not exist: ${m[0]}`);
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
const tex3d = ['client/assets/slice/models/', 'client/assets/slice/art/textures/', 'client/assets/fx/art/', 'client/assets/fx/tex/',
  'client/assets/fx/binbun/tex/', 'client/assets/fx/models/', 'client/world_fx/assets/'];
for (const f of files) {
  if (!f.endsWith('.import') || !tex3d.some((d) => f.startsWith(d))) continue;
  const text = read(f);
  if (!text.includes('importer="texture"')) continue;
  const isNormal = /(NormalGL|_n\.|normal)/i.test(f);
  const ok = /^compress\/mode=2$/m.test(text) && (!isNormal || /^compress\/normal_map=1$/m.test(text));
  if (ok) continue;
  if (fixTextures) {   // --fix-textures: rewrite the .import (BPTC for colour, RGTC for normal maps); re-import with `godot --headless --path client --import`
    let t = text.replace(/^compress\/mode=\d+$/m, 'compress/mode=2').replace(/^compress\/high_quality=\w+$/m, `compress/high_quality=${isNormal ? 'false' : 'true'}`);
    if (isNormal) t = t.replace(/^compress\/normal_map=\d+$/m, 'compress/normal_map=1');
    writeFileSync(path.join(root, f), t);
    fixed.push(f);
    continue;
  }
  report(f, 1, isNormal ? 'a normal map must import VRAM Compressed with compress/normal_map=1 (npm run hygiene -- --fix-textures)'
    : 'a 3D texture must import VRAM Compressed, compress/mode=2 (npm run hygiene -- --fix-textures)');
}

// g. No calls inside GDScript assert(): release exports strip asserts together with their expression, so a call there never runs in a
// shipped client (the co-op joiner's relay.join() did not, 2026-10-10). Tests may assert on calls; shipped code computes first, then asserts.
for (const f of files) {
  if (!f.startsWith('client/') || !f.endsWith('.gd') || f.includes('/tests/')) continue;
  const lines = read(f).split('\n');
  lines.forEach((l, i) => {
    const m = /^\s*assert\(([^,]*)/.exec(l);
    if (m && /[A-Za-z_]\w*\s*\(/.test(m[1])) report(f, i + 1, 'call inside assert() is stripped from release builds; compute it first, then assert the result');
  });
}

// h. The suite list matches the suite files: a suite nobody lists in tools/rebuild/run-client-tests.sh never runs, in CI or anywhere.
// Mirrors the runner: a suite is client/tests/<name>.gd, client/tests/<name>/run.gd, or <folder>/<runner> (a slash name). Top-level files
// that are helpers, not suites, are named in config.notSuites.
{
  const runner = 'tools/rebuild/run-client-tests.sh';
  const text = read(runner).replace(/\\\n/g, ' ');   // a trailing backslash continues a quoted list
  const listOf = (name) => {
    const m = new RegExp('^' + name + '="([^"]*)"', 'm').exec(text);
    if (!m) { report(runner, 1, `cannot find ${name}= in the runner (the hygiene rule that checks the suite list needs it)`); return null; }
    return m[1].split(/\s+/).filter(Boolean);
  };
  const suites = listOf('SUITES');
  if (suites) {
    const have = new Set(suites);
    const testFiles = files.filter((f) => f.startsWith('client/tests/'));
    const notSuites = Object.keys(config.notSuites || {});
    const candidates = [];
    for (const f of testFiles) {
      let m = /^client\/tests\/([^/]+)\.gd$/.exec(f);
      if (m) { candidates.push([m[1], f]); continue; }
      m = /^client\/tests\/([^/]+)\/run\.gd$/.exec(f);
      if (m) candidates.push([m[1], f]);
    }
    for (const [name, f] of candidates) {
      if (have.has(name) || notSuites.includes(f)) continue;
      report(f, 1, `${f} is a suite that ${runner} does not list: add it to SUITES (and to PACED if it plays game time); if it is a helper, not a suite, list it in notSuites in tools/hygiene/retired.json`);
    }
    for (const f of notSuites) if (!files.includes(f)) report('tools/hygiene/retired.json', 1, `notSuites names ${f}, which does not exist`);
    for (const name of suites) {
      const ok = name.includes('/') ? files.includes(`client/tests/${name}.gd`) : (files.includes(`client/tests/${name}.gd`) || files.includes(`client/tests/${name}/run.gd`));
      if (!ok) report(runner, lineOf(text, text.indexOf(name)), `SUITES names ${name}, but there is no client/tests/${name}.gd${name.includes('/') ? '' : ' or client/tests/' + name + '/run.gd'}`);
    }
    for (const list of ['PACED', 'LANE', 'WAITING']) {
      const names = listOf(list);
      for (const name of names || []) if (!have.has(name)) report(runner, lineOf(text, text.indexOf(`${list}=`)), `${list} names ${name}, which is not in SUITES (a typo here silently changes how a suite runs)`);
    }
  }
}

// i. The Discord agent's path rules name real paths. runner/lib/config.cjs holds the tier globs for godot mode and forbiddenPaths; a glob whose
// folder was renamed matches nothing, so its protection silently stops and the change drops to a lower approval tier. Markdown paths in the
// agent's prompt are rule b; this is the JS side. A glob's fixed part is everything before the first segment with a wildcard; one with no wildcard
// must exist itself; one with no fixed part (**/.env*) is skipped. Stale ones that are meant to stay: staleGlobs in retired.json.
{
  const { DEFAULTS } = require_('server/death-muffin/discord-agent/runner/lib/config.cjs');
  const cfgFile = 'server/death-muffin/discord-agent/runner/lib/config.cjs';
  const allowed = Object.keys(config.staleGlobs || {});
  const globs = [];
  for (const tier of Object.values(DEFAULTS.tiers || {})) for (const g of tier) globs.push(typeof g === 'string' ? g : g.glob);
  for (const g of DEFAULTS.forbiddenPaths || []) globs.push(g);
  const isTracked = (p) => files.includes(p) || files.some((f) => f.startsWith(p + '/'));
  const seen = new Set();
  for (const g of globs) {
    if (seen.has(g) || allowed.includes(g)) continue;
    seen.add(g);
    const segs = g.split('/');
    const wild = segs.findIndex((x) => /[*?[{]/.test(x));
    const fixed = (wild === -1 ? segs : segs.slice(0, wild)).join('/');
    if (!fixed || isTracked(fixed)) continue;
    const text = read(cfgFile);
    report(cfgFile, lineOf(text, Math.max(0, text.indexOf(`'${g}'`))), `the glob '${g}' protects nothing now: ${fixed} is not a tracked path. Update config.cjs in the same change as the rename (or list the glob in staleGlobs in tools/hygiene/retired.json if it is meant to name a path that does not exist)`);
  }
  for (const g of Object.keys(config.staleGlobs || {})) if (!globs.includes(g)) report('tools/hygiene/retired.json', 1, `staleGlobs names ${g}, which config.cjs no longer has`);
}

// j. No paid or foreign GitHub machines: GitHub-hosted standard runners are free for this public repo; larger runners (custom labels) cost money and
// self-hosted runners are somebody's own machine. Every runs-on in .github/workflows must be one of the standard labels (config.freeRunners), or a
// matrix expression whose values are all listed literally in the same workflow.
{
  const free = config.freeRunners || [];
  const unquote = (x) => x.replace(/\s+#.*$/, '').trim().replace(/^['"]|['"]$/g, '');
  for (const f of files.filter((x) => /^\.github\/workflows\/[^/]+\.ya?ml$/.test(x))) {
    const text = read(f);
    const lines = text.split('\n');
    const bad = (i, label) => report(f, i + 1, `runs-on: ${label} is not a free standard GitHub runner (${free.join(', ')}): it could cost money or run on someone's machine`);
    const matrixValues = (key) => {   // the literal values of matrix.<key>, or null when they are not all written out
      for (let i = 0; i < lines.length; i++) {
        const m = new RegExp('^(\\s+)' + key + ':\\s*(.*)$').exec(lines[i]);
        if (!m || /^\s*(runs-on|if)\b/.test(lines[i])) continue;
        const rest = unquote(m[2]);
        if (rest.startsWith('[') && rest.endsWith(']')) return rest.slice(1, -1).split(',').map(unquote);
        if (rest) continue;
        const vals = [];
        for (let j = i + 1; j < lines.length; j++) {
          const li = /^(\s+)-\s+(.*)$/.exec(lines[j]);
          if (!li || li[1].length <= m[1].length) break;
          vals.push(unquote(li[2]));
        }
        if (vals.length) return vals;
      }
      return null;
    };
    for (let i = 0; i < lines.length; i++) {
      const m = /^(\s*)runs-on:\s*(.*)$/.exec(lines[i]);
      if (!m) continue;
      let rest = m[2].replace(/\s+#.*$/, '').trim();
      let labels = [];
      if (!rest) {   // block list on the next lines
        for (let j = i + 1; j < lines.length; j++) { const li = /^\s+-\s+(.*)$/.exec(lines[j]); if (!li) break; labels.push(unquote(li[1])); }
        if (!labels.length) { bad(i, '(not a plain label)'); continue; }
      } else if (rest.startsWith('[') && rest.endsWith(']')) labels = rest.slice(1, -1).split(',').map(unquote);
      else labels = [unquote(rest)];
      for (const l of labels) {
        const mx = /^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$/.exec(l);
        if (mx) {
          const vals = matrixValues(mx[1]);
          if (!vals || !vals.length) bad(i, l);
          else for (const v of vals) if (!free.includes(v)) bad(i, `${v} (from ${l})`);
        } else if (!free.includes(l)) bad(i, l);
      }
      if (labels.length > 1) bad(i, `[${labels.join(', ')}] (a list of labels selects a custom runner)`);
    }
  }
}

if (fixed.length) console.log(`hygiene: fixed ${fixed.length} texture import(s); now run: godot --headless --path client --import`);
if (problems.length) {
  console.error(problems.join('\n'));
  console.error(`\nhygiene: ${problems.length} violation(s). See tools/hygiene/README.md.`);
  process.exit(1);
}
console.log(`hygiene: OK (${mdFiles.length} docs, ${scanFiles.length} files scanned, ${config.terms.length} retired terms)`);
