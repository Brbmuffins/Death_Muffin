/**
 * Rolled loot instances (migration 020, rules: gathering/affix-rules.cjs generated from server/rules/gameplay/affixRules.ts).
 *
 * A `loot_instances` row is one piece of gear with an item level and affixes. Only this server ever writes the rolled fields:
 * loot.cjs mints them (server RNG), offline-full-sync.cjs re-creates validated ones on a save import, and everything else
 * (bag save, equip, belt, Vault, salvage) moves rows that POINT at an instance by id. All helpers run inside the caller's transaction.
 */
const affix = require('./gathering/affix-rules.cjs');

/** A refusal the route turns into a readable 400. */
class SaveRefusal extends Error {
  constructor(message) {
    super(message);
    this.refusal = true;
    this.player = true;
  }
}

const num = (v) => Number(v) || 0;

/** The affixes column as an array (mysql2 returns JSON columns parsed; a text driver returns a string). */
function parseAffixes(raw) {
  if (raw == null) return [];
  try {
    const v = typeof raw === 'string' ? JSON.parse(raw) : raw;
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

/** Insert a (legal) instance owned by `accountId`; returns its id. */
async function insertInstance(conn, accountId, itemId, inst) {
  const clean = affix.cleanInstance(inst);
  const [res] = await conn.execute('INSERT INTO loot_instances (account_id, item_id, ilvl, affixes) VALUES (?, ?, ?, ?)', [accountId, itemId, clean.ilvl, JSON.stringify(clean.affixes)]);
  return num(res.insertId);
}

/** How many of the account's instances nothing points at yet (gear on the ground, rolled but not picked up). */
async function countUnclaimed(conn, accountId) {
  const [[row]] = await conn.execute(
    `SELECT COUNT(*) AS n FROM loot_instances li
      LEFT JOIN inventory inv ON inv.instance_id = li.id
      LEFT JOIN account_vault v ON v.instance_id = li.id
     WHERE li.account_id = ? AND inv.id IS NULL AND v.account_id IS NULL`,
    [accountId],
  );
  return num(row && row.n);
}

/** Forget unclaimed instances older than two days (never picked up, or detached by an old client). */
async function pruneUnclaimed(conn, accountId) {
  await conn.execute(
    `DELETE li FROM loot_instances li
      LEFT JOIN inventory inv ON inv.instance_id = li.id
      LEFT JOIN account_vault v ON v.instance_id = li.id
     WHERE li.account_id = ? AND li.created_at < (NOW() - INTERVAL 2 DAY) AND inv.id IS NULL AND v.account_id IS NULL`,
    [accountId],
  );
}

/** Delete instances by id (salvaged, sold, dropped). */
async function deleteInstances(conn, ids) {
  const list = [...new Set(ids.filter((n) => Number.isInteger(n) && n > 0))];
  if (list.length) await conn.query('DELETE FROM loot_instances WHERE id IN (?)', [list]);
}

module.exports = { SaveRefusal, parseAffixes, insertInstance, countUnclaimed, pruneUnclaimed, deleteInstances, affix };
