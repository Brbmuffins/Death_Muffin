#!/usr/bin/env node
/**
 * DB side of the daily bug-report agent (run-bug-agent.sh). The agent itself never touches the database.
 *
 *   node reports-cli.cjs list                   -> JSON array of 'new' reports (oldest first, at most 25)
 *   node reports-cli.cjs apply <verdicts.json>  -> validates the agent's verdicts and writes status/agent_notes/fix_ref
 *   node reports-cli.cjs release <id,id,...>    -> marks reports whose fix just went live 'released'; prints the ones it changed
 *   node reports-cli.cjs recent                 -> JSON array of the 8 newest reports, any status (read-only; Discord agent's !report)
 *   node reports-cli.cjs show <id>              -> JSON of one report with its full context and game log, or null (read-only)
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
    } else if (cmd === 'release') {
      const ids = String(file || '').split(',').map(Number).filter((n) => Number.isInteger(n) && n > 0).slice(0, 100);
      if (!ids.length) return void process.stdout.write('[]');
      const marks = ids.map(() => '?').join(',');
      const [rows] = await db.execute(`SELECT id, category FROM bug_reports WHERE id IN (${marks}) AND status <> 'released'`, ids);
      if (rows.length) await db.execute(`UPDATE bug_reports SET status = 'released' WHERE id IN (${rows.map(() => '?').join(',')})`, rows.map((r) => r.id));
      process.stdout.write(JSON.stringify(rows));
    } else if (cmd === 'recent') {
      const [rows] = await db.query(
        `SELECT r.id, r.category, r.status, LEFT(r.message, 120) AS message, r.created_at, a.username,
                JSON_EXTRACT(r.context, '$.log') IS NOT NULL AS hasLog
         FROM bug_reports r JOIN accounts a ON a.id = r.account_id ORDER BY r.id DESC LIMIT 8`,
      );
      process.stdout.write(JSON.stringify(rows.map((r) => ({ id: r.id, category: r.category, status: r.status, reporter: r.username, createdAt: r.created_at, hasLog: !!r.hasLog, message: r.message }))));
    } else if (cmd === 'show') {
      const id = Number(file);
      if (!Number.isInteger(id) || id <= 0) return void process.stdout.write('null');
      const [rows] = await db.execute(
        `SELECT r.id, r.category, r.status, r.message, r.context, r.agent_notes, r.created_at, a.username
         FROM bug_reports r JOIN accounts a ON a.id = r.account_id WHERE r.id = ?`, [id],
      );
      const r = rows[0];
      process.stdout.write(JSON.stringify(r ? { id: r.id, category: r.category, status: r.status, reporter: r.username, createdAt: r.created_at, note: r.agent_notes,
        context: typeof r.context === 'string' ? JSON.parse(r.context) : r.context, message: r.message } : null));
    } else {
      console.error('usage: reports-cli.cjs list | apply <verdicts.json> | release <ids> | recent | show <id>');
      process.exit(2);
    }
  } finally {
    await db.end();
  }
}
main().catch((err) => { console.error(err.message); process.exit(1); });
