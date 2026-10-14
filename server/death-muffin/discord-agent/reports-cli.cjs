#!/usr/bin/env node
/**
 * DB side of in-game bug reports for the Discord dev-agent runner (report threads in #manual-bugs, !report) and announce-release.sh.
 * The agent itself never touches the database.
 *
 *   node reports-cli.cjs list                   -> JSON array of 'new' reports with context and game log (oldest first, at most 25)
 *   node reports-cli.cjs posted <id>            -> a 'new' report got its Discord thread: 'triaged' with a note for the player
 *   node reports-cli.cjs release <id,id,...>    -> marks reports whose fix just went live 'released'; prints the ones it changed
 *   node reports-cli.cjs recent                 -> JSON array of the 8 newest reports, any status (read-only; !report)
 *   node reports-cli.cjs show <id>              -> JSON of one report with its full context and game log, or null (read-only)
 */
const path = require('path');
const RUNTIME = process.env.DM_RUNTIME || '/home/ubuntu/death-muffin';
require(path.join(RUNTIME, 'backend/node_modules/dotenv')).config({ path: path.join(RUNTIME, 'backend/.env'), quiet: true });
const mysql = require(path.join(RUNTIME, 'backend/node_modules/mysql2/promise'));

// What the player sees in "Your reports" once their report has a thread (status 'triaged' = "Looked at").
const POSTED_NOTE = 'Thanks! The team has your report and is looking into it.';
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
    } else if (cmd === 'posted') {
      const id = Number(file);
      if (!Number.isInteger(id) || id <= 0) { console.error('posted needs a report id'); process.exit(2); }
      const [r] = await db.execute("UPDATE bug_reports SET status = 'triaged', agent_notes = ? WHERE id = ? AND status = 'new'", [POSTED_NOTE, id]);
      process.stdout.write(JSON.stringify({ changed: r.affectedRows }));
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
      console.error('usage: reports-cli.cjs list | posted <id> | release <ids> | recent | show <id>');
      process.exit(2);
    }
  } finally {
    await db.end();
  }
}
main().catch((err) => { console.error(err.message); process.exit(1); });
