/**
 * Player bug reports (Settings → Report a bug). The daily bug-report agent (server/death-muffin/bug-agent/) reads the 'new' rows,
 * fixes what it can on a branch for the owner to review, and writes its verdict back into status/agent_notes so the player sees it.
 *
 *   POST /api/bug-reports        -> { category, message, characterId?, context? }   files one report
 *   GET  /api/bug-reports/mine   -> [{ id, category, message, status, note, createdAt }]  the account's latest reports
 *
 * `message` is free player text and `context` is client-reported (area, level, release, recent errors): both are stored as data,
 * bounded in size, and never trusted. A per-account cap keeps one player from flooding the agent's daily queue.
 */

const CATEGORIES = ['bug', 'combat', 'ui', 'performance', 'balance', 'other'];
// 'released' is set by deploy-release.sh when a commit `Bug report #<id>: …` goes live.
const STATUSES = ['new', 'triaged', 'fixing', 'fixed', 'released', 'needs_info', 'duplicate', 'wontfix'];
const MESSAGE_MIN = 10;
const MESSAGE_MAX = 2000;
const CONTEXT_MAX_BYTES = 4000;
const DAILY_CAP = 10;

/** Player-facing wording for each status (the "Your reports" list). */
const STATUS_LABELS = {
  new: 'Received',
  triaged: 'Looked at',
  fixing: 'Fix in progress',
  fixed: 'Fixed in an upcoming update',
  released: 'Fixed — live now',
  needs_info: 'Need more detail',
  duplicate: 'Already known',
  wontfix: 'Working as intended',
};

/** Keep only short scalar context values (and a short list of recent client errors) under a byte budget. */
function cleanContext(raw) {
  const out = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out;
  for (const [key, value] of Object.entries(raw).slice(0, 24)) {
    if (!/^[a-zA-Z][a-zA-Z0-9_]{0,31}$/.test(key)) continue;
    if (typeof value === 'number' && Number.isFinite(value)) out[key] = value;
    else if (typeof value === 'boolean') out[key] = value;
    else if (typeof value === 'string') out[key] = value.slice(0, 300);
    else if (key === 'errors' && Array.isArray(value)) out.errors = value.filter((e) => typeof e === 'string').slice(-5).map((e) => e.slice(0, 400));
  }
  while (JSON.stringify(out).length > CONTEXT_MAX_BYTES && out.errors && out.errors.length) out.errors.shift();
  if (JSON.stringify(out).length > CONTEXT_MAX_BYTES) return { truncated: true };
  return out;
}

/** Validate a POST body. Returns { error } or { report }. */
function parseReport(body) {
  const b = body && typeof body === 'object' ? body : {};
  const category = CATEGORIES.includes(b.category) ? b.category : 'bug';
  // Control characters other than newline/tab are dropped; the text is stored as-is otherwise and escaped wherever it is shown.
  const message = typeof b.message === 'string' ? b.message.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim() : '';
  if (message.length < MESSAGE_MIN) return { error: `Please describe the problem in at least ${MESSAGE_MIN} characters.` };
  if (message.length > MESSAGE_MAX) return { error: `Please keep the report under ${MESSAGE_MAX} characters.` };
  const characterId = Number.isInteger(b.characterId) && b.characterId > 0 ? b.characterId : null;
  return { report: { category, message, characterId, context: cleanContext(b.context) } };
}

module.exports = function mountBugReports(app, pool, { requireAuth, ownsCharacter }) {
  app.post('/api/bug-reports', requireAuth, async (req, res) => {
    const parsed = parseReport(req.body);
    if (parsed.error) return res.status(400).json({ success: false, error: parsed.error });
    const { category, message, context } = parsed.report;
    let { characterId } = parsed.report;
    try {
      if (characterId && !(await ownsCharacter(req, characterId))) characterId = null;
      const [[{ n }]] = await pool.execute(
        'SELECT COUNT(*) AS n FROM bug_reports WHERE account_id = ? AND created_at > NOW() - INTERVAL 1 DAY',
        [req.user.accountId],
      );
      if (n >= DAILY_CAP) return res.status(429).json({ success: false, error: 'Thanks! You have sent plenty of reports today. Please try again tomorrow.' });
      const [result] = await pool.execute(
        'INSERT INTO bug_reports (account_id, character_id, category, message, context) VALUES (?, ?, ?, ?, ?)',
        [req.user.accountId, characterId, category, message, JSON.stringify(context)],
      );
      res.json({ success: true, data: { id: result.insertId } });
    } catch (err) {
      console.error('bug report save error:', err);
      res.status(500).json({ success: false, error: 'The report could not be saved. Please try again.' });
    }
  });

  app.get('/api/bug-reports/mine', requireAuth, async (req, res) => {
    try {
      const [rows] = await pool.execute(
        `SELECT id, category, message, status, agent_notes, created_at FROM bug_reports
         WHERE account_id = ? ORDER BY id DESC LIMIT 10`,
        [req.user.accountId],
      );
      res.json({
        success: true,
        data: rows.map((r) => ({
          id: r.id,
          category: r.category,
          message: r.message.length > 160 ? `${r.message.slice(0, 157)}…` : r.message,
          status: STATUS_LABELS[r.status] || STATUS_LABELS.new,
          // The agent's note is written for the player (see bug-agent/PROMPT.md); only shown once the report has a verdict.
          note: r.status !== 'new' && r.agent_notes ? String(r.agent_notes).slice(0, 300) : null,
          createdAt: r.created_at,
        })),
      });
    } catch (err) {
      console.error('bug report list error:', err);
      res.status(500).json({ success: false, error: 'Your reports could not be loaded.' });
    }
  });
};

module.exports.parseReport = parseReport;
module.exports.cleanContext = cleanContext;
module.exports.CATEGORIES = CATEGORIES;
module.exports.STATUSES = STATUSES;
module.exports.STATUS_LABELS = STATUS_LABELS;
