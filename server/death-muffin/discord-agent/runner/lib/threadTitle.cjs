'use strict';
// Thread names for the Death Muffin dev agent: a clean first name from the request, a sanitizer for the agent's own title
// (untrusted text), and a per-thread rename queue that respects Discord's limit (about 2 name edits per 10 minutes per thread).

const NAME_MAX = 60;
const FALLBACK = 'Death Muffin request';
// 🔧 = the agent is working (owner, 2026-10-10). A ship keeps the 📝 title: Discord allows 2 thread renames per 10 min, and a 🔧 for the ship
// spent the one the ✅ needed (2361e6's ✅ waited 8 min after a 2-minute ship).
const MARKERS = { running: '🔧 ', shipping: '📝 ', proposed: '📝 ', shipped: '✅ ', discarded: '❌ ' };

// Cut at a word boundary within max characters (an ellipsis marks a cut).
function clipWords(s, max) {
  s = String(s);
  if (s.length <= max) return s;
  const cut = s.slice(0, max - 1);
  const sp = cut.lastIndexOf(' ');
  return (sp >= Math.floor(max / 2) ? cut.slice(0, sp) : cut).replace(/[\s.,;:!?-]+$/, '') + '…';
}
const sentence = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);

// Text that must never reach a thread name as-is: mentions, links, markdown, control characters.
function scrub(raw) {
  return String(raw == null ? '' : raw)
    .replace(/<(?:@[!&]?|#|a?:\w+:)\d*>?/g, ' ').replace(/<a?:\w+:\d+>/g, ' ')
    .replace(/@(everyone|here)\b/gi, ' ').replace(/@/g, '')
    .replace(/\b(?:https?:\/\/|www\.)\S+/gi, ' ').replace(/\b(?:discord\.gg|discord(?:app)?\.com)\/\S*/gi, ' ')
    .replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩﻿]/g, ' ')
    .replace(/[`*_~|>#\[\]\\]/g, ' ');
}

// First name, straight from the person's message.
function initialName(text, botNames = ['Muffin Core']) {
  let s = scrub(text).replace(/\s+/g, ' ').trim();
  for (const n of botNames.filter(Boolean)) s = s.replace(new RegExp(n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), ' ');
  s = s.replace(/\s+/g, ' ').trim();
  const filler = /^(?:(?:hey|hi|hello|yo|ok(?:ay)?|so|hmm|um|also|and|thanks|thank you)\b[\s,.!:-]*|(?:can|could|would|will)\s+you\b[\s,]*|(?:i\s+(?:want|need|would like|d like)\s+you\s+to)\b[\s,]*|(?:please|pls|plz)\b[\s,.!:-]*|(?:help me|let'?s|lets)\b[\s,]*|to\b[\s,]+)/i;
  for (let i = 0; i < 8; i++) { const n = s.replace(filler, '').replace(/^[\s,.!:;?-]+/, ''); if (n === s) break; s = n; }
  s = s.replace(/[\s.,;:!?-]+$/, '');
  if (!s) return FALLBACK;
  return clipWords(sentence(s), NAME_MAX);
}

// The agent's .dm-title: first non-empty line, one short plain line.
function sanitizeTitle(raw) {
  const line = String(raw == null ? '' : raw).split(/\r?\n/).map((l) => l.trim()).find(Boolean) || '';
  const s = scrub(line).replace(/\s+/g, ' ').trim().replace(/^[\s"'.,:;-]+|[\s"'.,;-]+$/g, '');
  if (!s) return '';
  return clipWords(sentence(s), NAME_MAX - 3);   // leaves room for a status marker
}
// Same title, ignoring case, spacing and punctuation.
const titleKey = (t) => String(t || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

const withMarker = (title, status) => `${MARKERS[status] || ''}${title}`.slice(0, 100);

// Keeps only the latest wanted name per thread; sends at most `max` renames per `windowMs` per thread; drops no-ops.
// send(threadId, name) is fire-and-forget. Timers use setTimer(fn, ms) so tests can run a fake clock.
function createRenamer({ send, now = Date.now, max = 2, windowMs = 600000, setTimer = (fn, ms) => { const t = setTimeout(fn, ms); if (t.unref) t.unref(); return t; }, clearTimer = clearTimeout }) {
  const st = new Map();   // threadId -> { current, want, sent: [timestamps], timer }
  const get = (id) => { let s = st.get(id); if (!s) { s = { current: null, want: null, sent: [], timer: null }; st.set(id, s); } return s; };
  function flush(id) {
    const s = get(id); s.timer = null;
    if (s.want == null || s.want === s.current) { s.want = null; return; }
    const t = now(); s.sent = s.sent.filter((x) => t - x < windowMs);
    if (s.sent.length >= max) { s.timer = setTimer(() => flush(id), s.sent[0] + windowMs - t + 50); return; }
    const name = s.want; s.want = null; s.current = name; s.sent.push(t);
    try { send(id, name); } catch { /* fire and forget */ }
  }
  return {
    // The name the thread already has (no rename is sent for it).
    setCurrent(id, name) { get(id).current = name; },
    want(id, name) {
      const s = get(id);
      if (name === s.current && s.want == null) return;
      s.want = name === s.current ? null : name;
      if (s.timer == null) flush(id);
    },
    forget(id) { const s = st.get(id); if (s && s.timer != null) clearTimer(s.timer); st.delete(id); },
    pending: (id) => (st.get(id) || {}).want || null,
  };
}

module.exports = { NAME_MAX, FALLBACK, MARKERS, initialName, sanitizeTitle, titleKey, withMarker, createRenamer, clipWords };
