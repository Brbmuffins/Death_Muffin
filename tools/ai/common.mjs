/**
 * Shared helpers for the AI asset tools. Keys are read from .ai-keys.local
 * (gitignored) per invocation and are never printed, logged, or written into
 * manifests. Raw outputs go to art-src/ (gitignored); reproducibility records
 * (prompts, models, task ids, hashes, credits) go to art-manifest/ (committed).
 */
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// DM_ART_ROOT: the Discord agent's runner runs trusted copies of these tools (installed outside every worktree) against one job's worktree.
export const ROOT = process.env.DM_ART_ROOT || join(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const ART_SRC = join(ROOT, 'art-src');
export const MANIFEST_DIR = join(ROOT, 'art-manifest');

export function loadKey(name) {
  if (process.env[name]) return process.env[name];
  const file = join(ROOT, '.ai-keys.local');
  if (!existsSync(file)) throw new Error(`.ai-keys.local not found — add ${name}=... to it`);
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const i = line.indexOf('=');
    if (i > 0 && line.slice(0, i).trim() === name) {
      const v = line.slice(i + 1).trim();
      if (v) return v;
    }
  }
  throw new Error(`${name} missing from .ai-keys.local`);
}

export function ensureDir(p) {
  mkdirSync(p, { recursive: true });
  return p;
}

export function sha256(buf) {
  return 'sha256:' + createHash('sha256').update(buf).digest('hex');
}

export function readJson(path, fallback = null) {
  if (!existsSync(path)) return fallback;
  return JSON.parse(readFileSync(path, 'utf8'));
}

export function writeJson(path, data) {
  ensureDir(dirname(path));
  writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Redact anything key-shaped from error text before it reaches the console. */
export function redact(text) {
  return String(text).replace(/(key=|Bearer\s+)[A-Za-z0-9_\-.]+/gi, '$1[redacted]');
}
