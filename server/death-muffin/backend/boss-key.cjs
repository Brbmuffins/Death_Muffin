/**
 * Covenant Seals as boss keys (rules: gathering/gold-sink-rules.cjs, generated from src/gameplay/goldSinkRules.ts).
 *
 *   POST /api/boss-key/summon -> { characterId, boss }
 *        takes one Covenant Seal from the bag and the boss's gold price (7,500 x shards^2), opens the character's bound summon of that
 *        boss, and answers { gold, cost, reused, bag }. The client then wakes the boss with the `empowered` flag. A summon already bound
 *        (a wipe, a reload) is reused FREE, so a lost fight never costs a second seal.
 *   POST /api/boss-key/refund -> { characterId, boss }
 *        gives the seal and gold back for a summon the host refused (another boss was awake), if made in the last two minutes.
 *   POST /api/boss-key/claim  -> { characterId, boss, discipline, level }
 *        pays the bound summon's prize once: ONE server-rolled gear piece (epic-or-better: three affixes, or a legendary set piece at
 *        2.5x the ordinary odds), minted as a loot_instances row the client drops at the corpse and picks up like any drop.
 *        -> { item_id, instance_id, ilvl, affixes, legendary }
 *
 * What the server owns: the seal, the gold, the area gate, and every roll of the prize. What it cannot see is the fight itself (the world
 * is simulated in the browser, as for every kill), so a claim is refused in the first 10 seconds and the price (a seal plus up to 367.5k
 * gold per prize) is the bound on anyone who skips the fight. Prizes are not retroactive: an unclaimed summon expires after three hours.
 */
const crypto = require('crypto');
const { audit } = require('./authority.cjs');
const store = require('./bag-store.cjs');
const loot = require('./loot-instances.cjs');
const sinks = require('./gathering/gold-sink-rules.cjs');

const affix = loot.affix;
const num = (v) => Number(v) || 0;
const playerError = (message) => Object.assign(new Error(message), { player: true });
const secureRandom = () => crypto.randomInt(0, 2 ** 30) / 2 ** 30;
const fmt = (n) => Number(n).toLocaleString('en-US');
const GOLD_MAX = 2147483647;
/** The soonest a prize may be claimed after the summon (ms): no real fight is shorter, and it stops a summon-and-claim loop in one breath. */
const MIN_FIGHT_MS = 10 * 1000;
const MAX_UNCLAIMED = 300;

module.exports = function mountBossKey(app, pool, { requireAuth, ownsCharacter, random = secureRandom, isStaff, now = () => Date.now(), areaOpen, killsMode, log = console }) {
  const lockedCharacter = async (conn, id) => {
    const [[char]] = await conn.execute('SELECT account_id, gold, level FROM characters WHERE id = ? FOR UPDATE', [id]);
    if (!char) throw playerError('Character not found.');
    return char;
  };
  const bossOf = (body) => {
    if (!sinks.canEmpower(body.boss)) throw playerError('That boss cannot be called with a Seal.');
    return body.boss;
  };
  const route = (name, handler) =>
    app.post(`/api/boss-key/${name}`, requireAuth, async (req, res) => {
      const conn = await pool.getConnection();
      try {
        const body = req.body || {};
        const id = parseInt(body.characterId, 10);
        if (!id || !(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
        await conn.beginTransaction();
        const data = await handler(conn, id, body, req);
        await conn.commit();
        res.json({ success: true, data });
      } catch (err) {
        await conn.rollback().catch(() => {});
        if (err && err.player) return res.status(200).json({ success: false, error: err.message });
        if (err && err.code === 'ER_NO_SUCH_TABLE') return res.status(200).json({ success: false, error: 'The Seals are not ready yet. Try again after the next update.' });
        console.error(`${req.method} ${req.path}:`, err.code || err.message);
        if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
      } finally {
        conn.release();
      }
    });

  /** The summon is open for claiming/reuse for this long. */
  const openRow = async (conn, id, boss, order) => {
    const [rows] = await conn.execute(
      `SELECT id, gold, UNIX_TIMESTAMP(created_at) * 1000 AS made, killed_at FROM empowered_summons
        WHERE character_id = ? AND boss = ? AND status = 'open' ORDER BY id ${order} FOR UPDATE`,
      [id, boss],
    );
    return rows.filter((r) => now() - num(r.made) < sinks.EMPOWER.claimWindowMs);
  };

  route('summon', async (conn, id, body, req) => {
    const boss = bossOf(body);
    const char = await lockedCharacter(conn, id);
    const staff = isStaff ? await isStaff(req).catch(() => false) : false;
    if (!staff && areaOpen && !(await areaOpen(conn, id, boss))) throw playerError('That ground is still sealed to you.');
    const bound = await openRow(conn, id, boss, 'ASC');
    if (bound.length) {
      const [bag] = await conn.execute(store.INV_SELECT, [id]);
      return { gold: num(char.gold), cost: 0, reused: true, summon_id: num(bound[0].id), bag };
    }
    const cost = sinks.empowerGold(boss);
    const bagRows = await store.loadBag(conn, id);
    const seal = bagRows.find((r) => r.itemId === sinks.COVENANT_SEAL && !r.fixed && r.qty > 0);
    if (!seal) throw playerError('You need a Covenant Seal in your bag to call an Empowered boss.');
    if (num(char.gold) < cost) throw playerError(`The Seal demands ${fmt(cost)} gold (you have ${fmt(num(char.gold))}).`);
    const after = bagRows.map((r) => (r === seal ? { ...r, qty: r.qty - 1 } : r)).filter((r) => r.qty > 0);
    await store.writeBag(conn, id, bagRows, after);
    await conn.execute('UPDATE characters SET gold = gold - ? WHERE id = ?', [cost, id]);
    const [made] = await conn.execute("INSERT INTO empowered_summons (character_id, boss, gold, status) VALUES (?, ?, ?, 'open')", [id, boss, cost]);
    const [bag] = await conn.execute(store.INV_SELECT, [id]);
    console.log(`[BOSSKEY] char#${id} called Empowered ${boss} for 1 seal + ${cost} gold`);
    return { gold: num(char.gold) - cost, cost, reused: false, summon_id: num(made && made.insertId), bag };
  });

  // Which bosses this character holds a paid, unexpired, unclaimed summon for (the altar asks, so a free retry survives a reload).
  route('status', async (conn, id) => {
    const [rows] = await conn.execute(
      `SELECT id, boss, UNIX_TIMESTAMP(created_at) * 1000 AS made FROM empowered_summons WHERE character_id = ? AND status = 'open' ORDER BY id`,
      [id],
    );
    const live = rows.filter((r) => now() - num(r.made) < sinks.EMPOWER.claimWindowMs);
    return { bound: [...new Set(live.map((r) => r.boss))], summons: live.map((r) => ({ id: num(r.id), boss: r.boss })) };
  });

  route('refund', async (conn, id, body) => {
    const boss = bossOf(body);
    const char = await lockedCharacter(conn, id);
    const [rows] = await conn.execute(
      `SELECT id, gold, UNIX_TIMESTAMP(created_at) * 1000 AS made FROM empowered_summons WHERE character_id = ? AND boss = ? AND status = 'open' ORDER BY id DESC LIMIT 1 FOR UPDATE`,
      [id, boss],
    );
    const row = rows[0];
    if (!row || now() - num(row.made) > sinks.EMPOWER.refundWindowMs) throw playerError('There is no recent summon to take back.');
    const bagRows = await store.loadBag(conn, id);
    const info = await store.loadInfo(conn, [sinks.COVENANT_SEAL]);
    const after = store.vaultRules.addGrants(bagRows, [{ itemId: sinks.COVENANT_SEAL, qty: 1 }], info);
    if (!after) throw playerError('Make room in your bag for the Seal, then try again.');
    await store.writeBag(conn, id, bagRows, after);
    const gold = Math.min(GOLD_MAX, num(char.gold) + num(row.gold));
    await conn.execute('UPDATE characters SET gold = ? WHERE id = ?', [gold, id]);
    await conn.execute("UPDATE empowered_summons SET status = 'refunded', resolved_at = NOW() WHERE id = ?", [row.id]);
    const [bag] = await conn.execute(store.INV_SELECT, [id]);
    return { gold, bag };
  });

  route('claim', async (conn, id, body, req) => {
    const boss = bossOf(body);
    const char = await lockedCharacter(conn, id);
    const bound = await openRow(conn, id, boss, 'ASC');
    // The kill ledger (AUTHORITY_KILLS): a summon whose kill the server has seen is claimed first.
    const row = bound.find((r) => r.killed_at) || bound[0];
    if (!row) throw playerError('No Empowered summon of that boss is waiting for a prize.');
    if (now() - num(row.made) < MIN_FIGHT_MS) throw playerError('The boss has barely woken. Finish the fight first.');
    const mode = killsMode ? killsMode() : require('./kills.cjs').killsMode();
    if (mode !== 'off' && !row.killed_at) {
      const staff = isStaff ? await isStaff(req).catch(() => false) : false;
      if (mode === 'enforce' && !staff) throw playerError('The server has not seen that boss die. Finish the fight (or wait a moment for your kills to reach it) and try again.');
      await audit(conn, { characterId: id, accountId: char.account_id, kind: 'boss_key_no_kill', mode, action: 'report', detail: { boss, summon: num(row.id) } }, log);
    }
    const discipline = typeof body.discipline === 'string' && /^[a-z0-9_]{1,32}$/.test(body.discipline) ? body.discipline : '';
    await loot.pruneUnclaimed(conn, char.account_id);
    if ((await loot.countUnclaimed(conn, char.account_id)) + 1 > MAX_UNCLAIMED) throw playerError('Too many unclaimed relics on the ground. Pick some up first.');

    // Pieces the character already carries or wears: a legendary prize favours the ones it lacks.
    const [owned] = await conn.execute('SELECT item_id FROM inventory WHERE character_id = ?', [id]);
    const prize = sinks.rollEmpoweredPrize(boss, discipline, random, new Set(owned.map((r) => r.item_id)));
    const [[meta]] = await conn.execute('SELECT rarity, item_type FROM items WHERE id = ?', [prize.item_id]);
    if (!meta || !affix.isAffixGear(meta.item_type)) throw playerError('The prize could not be rolled. Try again.');
    const level = affix.clampDropLevel(body.level, num(char.level) || 1);
    const inst = sinks.rollEmpoweredInstance(prize, meta.rarity || 'common', level, random);
    const instanceId = await loot.insertInstance(conn, char.account_id, prize.item_id, inst);
    await conn.execute("UPDATE empowered_summons SET status = 'claimed', resolved_at = NOW() WHERE id = ?", [row.id]);
    console.log(`[BOSSKEY] char#${id} claimed ${boss}: ${prize.item_id}${prize.legendary ? ' (legendary)' : ''}`);
    return { item_id: prize.item_id, instance_id: instanceId, ilvl: inst.ilvl, affixes: inst.affixes, legendary: prize.legendary };
  });
};

/** The default area gate: the character's necromancer record (character_necro_progress) must list the boss's area (no record = a fresh character: the Graves). Fails closed on an error. */
module.exports.areaOpenFromRecord = async (conn, characterId, boss) => {
  const area = sinks.bossArea(boss);
  try {
    const [[row]] = await conn.execute('SELECT state FROM character_necro_progress WHERE character_id = ?', [characterId]);
    const s = row && (typeof row.state === 'string' ? JSON.parse(row.state) : row.state);
    const open = s && Array.isArray(s.unlockedAreas) && s.unlockedAreas.length ? s.unlockedAreas : ['chapterhouse', 'graves'];
    return open.includes(area);
  } catch {
    return false;
  }
};
module.exports.MIN_FIGHT_MS = MIN_FIGHT_MS;

/**
 * Kill reports (kills.cjs, audit and enforce) name the bound summon an Empowered boss's kill ends: stamp it, once, on a summon this character
 * paid for that is still open and made the boss's kill possible (created before now). Fails open: a missing column or table changes nothing.
 */
module.exports.markSummonKills = async (conn, characterId, bosses, log = console) => {
  for (const b of bosses || []) {
    const summon = Number(b && b.summon);
    if (!(summon > 0) || !sinks.canEmpower(b.boss)) continue;
    try {
      await conn.execute("UPDATE empowered_summons SET killed_at = NOW() WHERE id = ? AND character_id = ? AND boss = ? AND status = 'open' AND killed_at IS NULL", [summon, characterId, b.boss]);
    } catch (err) {
      if (log && log.error) log.error(`[BOSSKEY] could not stamp a kill: ${err.code || err.message}`);
    }
  }
};
