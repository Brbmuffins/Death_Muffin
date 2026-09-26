'use strict';
/**
 * MySQL storage for necromancer progression (schema.sql). Each mutation runs
 * in ONE transaction that row-locks the character (gold) and its progress
 * row, so a purchase can never double-spend and two tabs can't race.
 *
 * `pool` is a mysql2/promise pool (or anything with getConnection() whose
 * connections support beginTransaction/query/commit/rollback/release and
 * resolve query() to [rows]). If the auth server uses the callback `mysql`
 * package, wrap it (see VPS_HANDOFF.md) or reuse its existing promise pool.
 */
const { blankState, normalise } = require('./necro-rules.cjs');

const ident = (s) => {
  if (!/^[A-Za-z0-9_]+$/.test(s)) throw new Error(`necro-progress: bad identifier ${s}`);
  return '`' + s + '`';
};

function createMysqlStore(pool, { charactersTable = 'characters', idColumn = 'id', goldColumn = 'gold' } = {}) {
  const T = ident(charactersTable);
  const ID = ident(idColumn);
  const GOLD = ident(goldColumn);
  const parse = (v) => normalise(typeof v === 'string' ? JSON.parse(v) : v);

  async function tx(characterId, fn) {
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      const [chars] = await conn.query(`SELECT ${GOLD} AS gold FROM ${T} WHERE ${ID} = ? FOR UPDATE`, [characterId]);
      if (!chars.length) {
        await conn.rollback();
        return { notFound: true };
      }
      await conn.query('INSERT IGNORE INTO character_necro_progress (character_id, state) VALUES (?, ?)', [characterId, JSON.stringify(blankState())]);
      const [rows] = await conn.query('SELECT state FROM character_necro_progress WHERE character_id = ? FOR UPDATE', [characterId]);
      const gold = Number(chars[0].gold) || 0;
      const state = parse(rows[0].state);
      const out = (await fn(state, gold, conn)) || {};
      if (out.state) {
        await conn.query('UPDATE character_necro_progress SET state = ?, version = version + 1 WHERE character_id = ?', [JSON.stringify(out.state), characterId]);
      }
      if (out.gold !== undefined && out.gold !== gold) {
        await conn.query(`UPDATE ${T} SET ${GOLD} = ? WHERE ${ID} = ?`, [Math.max(0, Math.round(out.gold)), characterId]);
      }
      await conn.commit();
      return { ...out, state: out.state || state, gold: out.gold !== undefined ? out.gold : gold };
    } catch (err) {
      try {
        await conn.rollback();
      } catch {
        /* connection already broken */
      }
      throw err;
    } finally {
      conn.release();
    }
  }

  return {
    withLock: tx,
    /** Read-only load (still creates the blank row on first sight). */
    read: (characterId) => tx(characterId, () => ({})),
  };
}

/** In-memory store with the same contract, for tests and local dry runs. */
function createMemoryStore(characters = {}) {
  const progress = new Map();
  const chars = new Map(Object.entries(characters).map(([id, gold]) => [Number(id), { gold }]));
  let chain = Promise.resolve();
  function tx(characterId, fn) {
    const run = chain.then(async () => {
      const c = chars.get(characterId);
      if (!c) return { notFound: true };
      const state = normalise(progress.get(characterId) || blankState());
      const out = (await fn(state, c.gold)) || {};
      if (out.state) progress.set(characterId, JSON.parse(JSON.stringify(out.state)));
      if (out.gold !== undefined) c.gold = out.gold;
      return { ...out, state: out.state || state, gold: c.gold };
    });
    chain = run.catch(() => undefined);
    return run;
  }
  return { withLock: tx, read: (id) => tx(id, () => ({})), _chars: chars, _progress: progress };
}

module.exports = { createMysqlStore, createMemoryStore };
