'use strict';
// Never let a secret reach Discord, the audit log or a model prompt. Fail closed: a line that looks like a secret is dropped whole.
const PATTERNS = [
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  /\b[MNO][A-Za-z\d_-]{23,25}\.[\w-]{6}\.[\w-]{27,}\b/,        // Discord bot token
  /\bsk-[A-Za-z0-9_-]{16,}/,                                    // OpenAI / Anthropic style keys
  /\bgh[pousr]_[A-Za-z0-9]{20,}/, /\bgithub_pat_[A-Za-z0-9_]{20,}/,
  /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, // JWT
  /\b(?:mysql|postgres(?:ql)?|redis|mongodb):\/\/[^\s]*:[^\s@]*@/i,
  /\b(password|passwd|secret|api[_-]?key|token|private[_-]?key)\b\s*[:=]\s*['"]?[^\s'"]{8,}/i,
  /\b[0-9a-f]{40,}\b/i,                                         // long hex blobs
  /\btsk_[A-Za-z0-9_-]{16,}/,                                  // Tripo API key
  /\bAIza[0-9A-Za-z_-]{30,}/, /\bAQ\.[A-Za-z0-9_-]{20,}/,       // Google / Gemini API keys
];
let known = [];
function setKnownSecrets(list) { known = list.filter((s) => typeof s === 'string' && s.length >= 8); }
// Adds exact secret values (the art keys, read by the runner at use time) without dropping the ones already registered.
function addKnownSecrets(list) { known = [...new Set([...known, ...list.filter((s) => typeof s === 'string' && s.length >= 8)])]; }
function looksSecret(line) {
  if (PATTERNS.some((p) => p.test(line))) return true;
  return known.some((s) => line.includes(s));
}
function redactText(text) {
  return String(text == null ? '' : text).split('\n').map((l) => (looksSecret(l) ? '[redacted line]' : l)).join('\n');
}
// Redact every string inside an object (embeds), line by line, keeping the structure intact.
function redactDeep(v) {
  if (typeof v === 'string') return redactText(v);
  if (Array.isArray(v)) return v.map(redactDeep);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, k === 'url' ? x : redactDeep(x)]));
  return v;
}
module.exports = { redactDeep, redactText, looksSecret, setKnownSecrets, addKnownSecrets, PATTERNS };
