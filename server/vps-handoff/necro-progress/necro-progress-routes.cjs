'use strict';
/**
 * Necromancer progression REST routes for the auth server (/opt/rod-auth).
 * ADDITIVE ONLY: new /api/necro-progress/* routes; no existing route changes.
 *
 * Every rule (prices, unlocks, Ascension, boons, import clamps) comes from
 * necro-rules.cjs, generated from the web client's src/gameplay/necroRules.ts,
 * so client and server can't disagree. This file only does auth, ownership,
 * input shape and the row-locked transaction around each rule.
 *
 *   const { mountNecroProgress } = require('./necro-progress/necro-progress-routes.cjs');
 *   const { createMysqlStore } = require('./necro-progress/mysql-store.cjs');
 *   mountNecroProgress(app, {
 *     store: createMysqlStore(pool, { charactersTable: 'characters', idColumn: 'id', goldColumn: 'gold' }),
 *     requireAuth,                                  // the server's existing JWT middleware
 *     ownsCharacter: async (req, characterId) => …, // true if the JWT's account owns it
 *   });
 */
const rules = require('./necro-rules.cjs');

/** What the client sees (host-only bookkeeping stays server-side). */
function publicState(s) {
  return {
    damageTier: s.damageTier,
    waveTierOwned: s.waveTierOwned,
    waveTierActive: s.waveTierActive,
    soulShards: s.soulShards,
    areaKills: s.areaKills,
    unlockedAreas: s.unlockedAreas,
    bossKills: s.bossKills,
    totalKills: s.totalKills,
    ascension: s.ascension,
    ashes: s.ashes,
    boons: s.boons,
    run: s.run,
    summonsPending: s.summonsPending,
    migrated: s.migrated,
  };
}

/** Simple per-character token bucket so a broken client can't hammer the DB. */
function limiter(perMinute) {
  const hits = new Map();
  return (key) => {
    const now = Date.now();
    const list = (hits.get(key) || []).filter((t) => now - t < 60000);
    if (list.length >= perMinute) return false;
    list.push(now);
    hits.set(key, list);
    return true;
  };
}

function createNecroProgressHandlers({ store, ownsCharacter, logger = console, perMinute = 60 }) {
  if (!store || !ownsCharacter) throw new Error('necro-progress: store and ownsCharacter are required');
  const allow = limiter(perMinute);

  const send = (res, status, body) => res.status(status).json(body);
  const fail = (res, status, error) => send(res, status, { success: false, error });

  /** Common guard: valid id, owned by the caller, under the rate limit. */
  async function guard(req, res, raw) {
    const characterId = Number(raw);
    if (!Number.isInteger(characterId) || characterId <= 0) return fail(res, 400, 'characterId is required'), null;
    if (!(await ownsCharacter(req, characterId))) return fail(res, 403, 'That character is not yours'), null;
    if (!allow(characterId)) return fail(res, 429, 'Too many requests — slow down'), null;
    return characterId;
  }

  /** Run a rule inside the character's locked transaction and answer. */
  async function mutate(req, res, apply) {
    const characterId = await guard(req, res, req.body && req.body.characterId);
    if (!characterId) return;
    try {
      let outcome = null;
      const done = await store.withLock(characterId, (state, gold) => {
        const r = apply(state, gold, req.body || {});
        outcome = r;
        if (!r.ok) return {}; // nothing written
        return { state: r.state, gold: r.gold };
      });
      if (done && done.notFound) return fail(res, 404, 'Character not found');
      if (!outcome.ok) return fail(res, 400, outcome.error);
      const data = { progress: publicState(outcome.state) };
      if (outcome.gold !== undefined) data.gold = outcome.gold;
      if (outcome.earned !== undefined) data.earned = outcome.earned;
      if (outcome.cost !== undefined) data.cost = outcome.cost;
      return send(res, 200, { success: true, data });
    } catch (err) {
      logger.error('[necro-progress]', err);
      return fail(res, 500, 'Server error — progress not saved');
    }
  }

  return {
    async get(req, res) {
      const characterId = await guard(req, res, req.params.characterId);
      if (!characterId) return;
      try {
        const done = await store.read(characterId);
        if (done.notFound) return fail(res, 404, 'Character not found');
        return send(res, 200, { success: true, data: { progress: publicState(done.state), gold: done.gold } });
      } catch (err) {
        logger.error('[necro-progress]', err);
        return fail(res, 500, 'Server error — could not load progress');
      }
    },
    save: (req, res) =>
      mutate(req, res, (s, _g, b) =>
        rules.applySave(s, {
          waveTierActive: b.waveTierActive,
          areaKills: b.areaKills,
          shards: b.shards,
          prelateKills: b.prelateKills,
          peakWaveTier: b.peakWaveTier,
        }),
      ),
    purchase: (req, res) => mutate(req, res, (s, g, b) => rules.purchase(s, g, b.upgrade)),
    summonPrelate: (req, res) => mutate(req, res, (s) => rules.summonPrelate(s)),
    summonBoss: (req, res) => mutate(req, res, (s, _g, b) => rules.summonAreaBoss(s, b.boss)),
    ascend: (req, res) => mutate(req, res, (s) => rules.ascend(s)),
    boon: (req, res) => mutate(req, res, (s, _g, b) => rules.buyBoon(s, String(b.boonId || ''))),
    importLocal: (req, res) => mutate(req, res, (s, _g, b) => rules.importLocal(s, b.record)),
  };
}

function mountNecroProgress(app, opts) {
  const h = createNecroProgressHandlers(opts);
  const auth = opts.requireAuth;
  if (!auth) throw new Error('necro-progress: requireAuth middleware is required');
  app.get('/api/necro-progress/:characterId', auth, h.get);
  app.post('/api/necro-progress/save', auth, h.save);
  app.post('/api/necro-progress/purchase', auth, h.purchase);
  app.post('/api/necro-progress/summon-prelate', auth, h.summonPrelate);
  app.post('/api/necro-progress/summon-boss', auth, h.summonBoss);
  app.post('/api/necro-progress/ascend', auth, h.ascend);
  app.post('/api/necro-progress/boon', auth, h.boon);
  app.post('/api/necro-progress/import', auth, h.importLocal);
  return h;
}

module.exports = { createNecroProgressHandlers, mountNecroProgress, publicState };
