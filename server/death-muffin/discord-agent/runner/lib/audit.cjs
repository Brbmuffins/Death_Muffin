'use strict';
const fs = require('fs');
const path = require('path');
const { redactText } = require('./redact.cjs');
// Append-only JSONL: every request, proposal, approval, refusal. Text fields are redacted and capped.
function createAudit(file) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  return {
    file,
    log(event, fields = {}) {
      const rec = { ts: new Date().toISOString(), event };
      for (const [k, v] of Object.entries(fields)) rec[k] = typeof v === 'string' ? (/^[0-9a-f]{7,40}$/.test(v) ? v : redactText(v)).slice(0, 2000) : v;
      try { fs.appendFileSync(file, JSON.stringify(rec) + '\n', { mode: 0o600 }); } catch (e) { console.error('audit write failed', e.message); }
      return rec;
    },
  };
}
module.exports = { createAudit };
