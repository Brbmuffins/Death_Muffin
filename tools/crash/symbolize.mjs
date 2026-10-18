#!/usr/bin/env node
// Turns a combat-core crash note (native/README.md "Crash notes") into source lines with the symbols the publish kept for that build.
//   node tools/crash/symbolize.mjs <bug report id>      reads the automatic crash report's coreCrash from the database (sudo mysql)
//   node tools/crash/symbolize.mjs --file <note.txt>    reads a note saved by hand
// Env: SYMBOLS_DIR (default /home/ubuntu/death-muffin/symbols), DB (death_muffin). Frames outside the core are printed as they are.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

const SYMBOLS_DIR = process.env.SYMBOLS_DIR || '/home/ubuntu/death-muffin/symbols';
const CORE_WIN = 'libdmcore.windows.template_release.x86_64.dll';

function noteFromReport(id) {
  if (!/^\d+$/.test(id)) throw new Error(`not a report id: ${id}`);
  const sql = `SELECT JSON_UNQUOTE(JSON_EXTRACT(context,'$.coreCrash')), JSON_UNQUOTE(JSON_EXTRACT(context,'$.log')) FROM bug_reports WHERE id=${id}`;
  const out = execFileSync('sudo', ['mysql', '-N', '-r', process.env.DB || 'death_muffin', '-e', sql], { encoding: 'utf8' });
  const [core, log] = out.split('\t');
  const text = core && core !== 'NULL' ? core : (log || '');
  const at = text.indexOf('DMCORE CRASH NOTE');
  if (at < 0) throw new Error(`report ${id} carries no crash note (builds before the crash note, or a crash outside the game)`);
  return text.slice(at);
}

export function parseNote(text) {
  const lines = text.split('\n').map((l) => l.trim());
  const build = (lines.find((l) => l.startsWith('build ')) || 'build unknown').slice(6);
  const what = (lines.find((l) => l.startsWith('what ')) || 'what unknown').slice(5);
  const frames = [];
  for (const l of lines) {
    const m = /^#(\d+) (.+)\+0x([0-9a-f]+)$/i.exec(l);
    if (m) frames.push({ index: Number(m[1]), module: m[2], offset: BigInt(`0x${m[3]}`) });
  }
  return { build, what, frames };
}

function imageBase(debugFile) {
  const out = execFileSync('x86_64-w64-mingw32-objdump', ['-p', debugFile], { encoding: 'utf8' });
  const m = /^ImageBase\s+([0-9a-f]+)$/im.exec(out);
  if (!m) throw new Error(`no ImageBase in ${debugFile}`);
  return BigInt(`0x${m[1]}`);
}

// addr2line -a prints each address before its (possibly inlined) function and line pairs.
function lookup(debugFile, vmas) {
  const out = execFileSync('x86_64-w64-mingw32-addr2line', ['-a', '-f', '-C', '-i', '-e', debugFile, ...vmas.map((v) => `0x${v.toString(16)}`)], { encoding: 'utf8' });
  const blocks = [];
  for (const l of out.split('\n')) {
    if (/^0x[0-9a-f]+$/i.test(l)) blocks.push([]);
    else if (l && blocks.length) blocks[blocks.length - 1].push(l);
  }
  return blocks.map((b) => {
    const parts = [];
    for (let i = 0; i + 1 < b.length; i += 2) parts.push(`${b[i]} (${b[i + 1].replace(/^.*\/native\//, 'native/')})`);
    return parts.join(' <- inlined in ');
  });
}

function main() {
  const args = process.argv.slice(2);
  const text = args[0] === '--file' ? readFileSync(args[1], 'utf8') : noteFromReport(args[0] || '');
  const note = parseNote(text);
  console.log(`build ${note.build}: ${note.what}`);
  const debugFile = path.join(SYMBOLS_DIR, note.build, `${CORE_WIN}.debug`);
  const core = note.frames.filter((f) => f.module === CORE_WIN);
  let names = new Map();
  if (core.length && existsSync(debugFile)) {
    const base = imageBase(debugFile);
    // a frame after the first is a return address: the call is the byte before it
    const vmas = core.map((f) => base + f.offset - (f.index > 0 ? 1n : 0n));
    const found = lookup(debugFile, vmas);
    names = new Map(core.map((f, i) => [f.index, found[i]]));
  } else if (core.length) {
    console.log(`(no symbols for build ${note.build} in ${SYMBOLS_DIR}: builds published before the crash note have none)`);
  }
  for (const f of note.frames) {
    console.log(`#${f.index} ${f.module}+0x${f.offset.toString(16)}${names.has(f.index) ? `  ${names.get(f.index)}` : ''}`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { main(); } catch (e) { console.error(`symbolize: ${e.message}`); process.exit(1); }
}
