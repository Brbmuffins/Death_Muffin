#!/usr/bin/env node
/**
 * DB side of the daily bug-report agent (run-bug-agent.sh). The agent itself never touches the database.
 *
 *   node reports-cli.cjs list                   -> JSON array of 'new' reports (oldest first, at most 25)
 *   node reports-cli.cjs apply <verdicts.json>  -> validates the agent's verdicts and writes status/agent_notes/fix_ref
 *
 * Only ids from the batch handed to the agent (BUG_AGENT_IDS) may be updated; status must be one of the known values;
 * notes are capped. A verdict that fails validation is skipped and reported, never half-applied.
 */
const path = require('path');
const fs = require('fs');
const RUNTIME = process.env.DM_RUNTIME || '/home/ubuntu/death-muffin';
require(path.join(RUNTIME, 'backend/node_modules/dotenv')).config({ path: path.join(RUNTIME, 'backend/.env'), quiet: true });
const mysql = require(path.join(RUNTIME, 'backend/node_modules/mysql2/promise'));

const STATUSES = new Set(['triaged', 'fixing', 'fixed', 'needs_info', 'duplicate', 'wontfix']);
const BATCH = 25;

async function main() {
  const [cmd, file] = process.argv.slice(2);
  const db = await mysql.createConnection({ host: process.env.DB_HOST, user: process.env.DB_USER, password: process.env.DB_PASS, database: process.env.DB_NAME });
  try {
    if (cmd === 'list') {
      const [rows] = await db.query(
        `SELECT r.id, r.category, r.message, r.context, r.created_at, a.username
         FROM bug_reports r JOIN accounts a ON a.id = r.account_id
         WHERE r.status = 'new' ORDER BY r.id ASC LIMIT ${BATCH}`,
      );
      process.stdout.write(JSON.stringify(rows.map((r) => ({
        id: r.id, category: r.category, reporter: r.username, createdAt: r.created_at,
        context: typeof r.context === 'string' ? JSON.parse(r.context) : r.context, message: r.message,
      })), null, 2));
    } else if (cmd === 'apply') {
      const allowed = new Set(String(process.env.BUG_AGENT_IDS || '').split(',').map(Number).filter(Boolean));
      let verdicts;
      try {
        verdicts = JSON.parse(fs.readFileSync(file, 'utf8'));
      } catch (err) {
        console.error(`verdicts unreadable: ${err.message}`);
        process.exit(2);
      }
      if (!Array.isArray(verdicts)) verdicts = [];
      let applied = 0;
      for (const v of verdicts) {
        const id = Number(v && v.id);
        if (!allowed.has(id) || !STATUSES.has(v.status) || typeof v.note !== 'string' || !v.note.trim()) {
          console.error(`skipped verdict ${JSON.stringify(v).slice(0, 200)}`);
          continue;
        }
        const fixRef = typeof v.fixRef === 'string' && /^[0-9a-f]{7,40}$/.test(v.fixRef) ? v.fixRef : null;
        await db.execute("UPDATE bug_reports SET status = ?, agent_notes = ?, fix_ref = COALESCE(?, fix_ref) WHERE id = ? AND status = 'new'",
          [v.status, v.note.trim().slice(0, 600), fixRef, id]);
        applied++;
      }
      console.log(`applied ${applied}/${verdicts.length} verdicts`);
    } else {
      console.error('usage: reports-cli.cjs list | apply <verdicts.json>');
      process.exit(2);
    }
  } finally {
    await db.end();
  }
}
main().catch((err) => { console.error(err.message); process.exit(1); });
