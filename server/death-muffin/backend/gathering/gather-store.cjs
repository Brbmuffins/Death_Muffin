'use strict';
/**
 * Storage for POST /api/gather. `withCharacter(id, fn)` runs `fn(tx)` inside
 * one transaction that row-locks the character, the skill row, the ledger and
 * the bag, so two tabs can't double-claim the same time budget. If `fn`
 * throws, nothing is written.
 */
const rules = require('./gathering-rules.cjs');

function createMysqlGatherStore(pool) {
  async function withCharacter(characterId, fn) {
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      const [chars] = await conn.query('SELECT id FROM characters WHERE id = ? FOR UPDATE', [characterId]);
      if (!chars.length) {
        await conn.rollback();
        return { notFound: true };
      }
      const tx = {
        async getSkill(skill) {
          await conn.query('INSERT IGNORE INTO professions (character_id, profession_id, skill_level, skill_xp) VALUES (?, ?, 1, 0)', [characterId, skill]);
          const [[row]] = await conn.query(
            'SELECT skill_level, skill_xp FROM professions WHERE character_id = ? AND profession_id = ? FOR UPDATE',
            [characterId, skill],
          );
          return { level: Number(row.skill_level) || 1, xp: Number(row.skill_xp) || 0 };
        },
        async setSkill(skill, p) {
          await conn.query('UPDATE professions SET skill_level = ?, skill_xp = ? WHERE character_id = ? AND profession_id = ?', [p.level, p.xp, characterId, skill]);
        },
        async getLedger() {
          await conn.query('INSERT IGNORE INTO gather_ledger (character_id) VALUES (?)', [characterId]);
          const [[row]] = await conn.query('SELECT last_at, hour_start, hour_actions FROM gather_ledger WHERE character_id = ? FOR UPDATE', [characterId]);
          return { lastAt: Number(row.last_at) || 0, hourStart: Number(row.hour_start) || 0, hourActions: Number(row.hour_actions) || 0 };
        },
        async setLedger(l) {
          await conn.query('UPDATE gather_ledger SET last_at = ?, hour_start = ?, hour_actions = ? WHERE character_id = ?', [l.lastAt, l.hourStart, l.hourActions, characterId]);
        },
        async getBag() {
          const [rows] = await conn.query(
            'SELECT slot_index, item_id, quantity, equipped FROM inventory WHERE character_id = ? AND slot_index BETWEEN 0 AND ? FOR UPDATE',
            [characterId, rules.BAG_SLOTS - 1],
          );
          // Equipped rows hold their slot but never take a stack.
          return rows.map((r) => ({ slot: Number(r.slot_index), itemId: Number(r.equipped) ? '' : r.item_id, qty: Number(r.quantity) }));
        },
        /** Item ids on the tool belt (reserved slots BELT_BASE..): they count as carried tools but never take bag space. */
        async getBeltTools() {
          const [rows] = await conn.query(
            'SELECT item_id FROM inventory WHERE character_id = ? AND slot_index BETWEEN ? AND ? FOR UPDATE',
            [characterId, rules.BELT_BASE, rules.BELT_BASE + rules.BELT_SLOT_COUNT - 1],
          );
          return rows.map((r) => r.item_id);
        },
        async maxStacks(ids) {
          const unique = [...new Set(ids)];
          const out = new Map();
          if (!unique.length) return out;
          const [rows] = await conn.query(`SELECT id, stackable, max_stack_size FROM items WHERE id IN (${unique.map(() => '?').join(',')})`, unique);
          for (const r of rows) out.set(r.id, Number(r.stackable) ? Math.max(1, Number(r.max_stack_size) || 1) : 1);
          return out;
        },
        async applyPlacement(p) {
          for (const u of p.updates) {
            await conn.query('UPDATE inventory SET quantity = ? WHERE character_id = ? AND slot_index = ?', [u.qty, characterId, u.slot]);
          }
          for (const r of p.inserts) {
            await conn.query(
              'INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, ?, 0, NULL)',
              [characterId, r.slot, r.itemId, r.qty],
            );
          }
        },
        async addGold(n) {
          await conn.query('UPDATE characters SET gold = LEAST(2147483647, gold + ?) WHERE id = ?', [Math.max(0, Math.floor(n)), characterId]);
        },
      };
      const out = await fn(tx);
      await conn.commit();
      return out;
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
  return { withCharacter };
}

/**
 * Same contract in memory, for tests and dry runs. `items` maps item id →
 * max stack (1 = gear); anything missing is "unknown to the server".
 */
function createMemoryGatherStore({ characters = {}, items = {} } = {}) {
  const chars = new Map(Object.entries(characters).map(([id, c]) => [Number(id), { gold: 0, skills: {}, bag: [], ledger: rules.blankLedger(), ...c }]));
  let chain = Promise.resolve();
  function withCharacter(characterId, fn) {
    const run = chain.then(async () => {
      const live = chars.get(characterId);
      if (!live) return { notFound: true };
      const c = JSON.parse(JSON.stringify(live)); // work on a copy: a throw writes nothing
      const tx = {
        async getSkill(skill) {
          const s = c.skills[skill] || { level: 1, xp: 0 };
          return { ...s };
        },
        async setSkill(skill, p) {
          c.skills[skill] = { level: p.level, xp: p.xp };
        },
        async getLedger() {
          return { ...c.ledger };
        },
        async setLedger(l) {
          c.ledger = { ...l };
        },
        async getBag() {
          return c.bag.map((r) => ({ ...r }));
        },
        async getBeltTools() {
          return [...(c.belt || [])];
        },
        async maxStacks(ids) {
          return new Map(ids.filter((id) => items[id] !== undefined).map((id) => [id, items[id]]));
        },
        async applyPlacement(p) {
          for (const u of p.updates) c.bag.find((r) => r.slot === u.slot).qty = u.qty;
          for (const r of p.inserts) c.bag.push({ ...r });
        },
        async addGold(n) {
          c.gold += n;
        },
      };
      const out = await fn(tx);
      chars.set(characterId, c);
      return out;
    });
    chain = run.catch(() => undefined);
    return run;
  }
  return { withCharacter, _chars: chars };
}

module.exports = { createMysqlGatherStore, createMemoryGatherStore };
