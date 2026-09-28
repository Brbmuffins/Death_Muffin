'use strict';
/**
 * POST /api/gather for the Death Muffin backend (roadmap §8).
 *
 * The client works a node, counts its actions, and sends them in batches
 * (~every 8 s). The server:
 *   1. checks ownership, the node id and the skill level,
 *   2. clamps the claimed actions to the elapsed time (checkBudget),
 *   3. rolls the loot and XP itself with the shared rules,
 *   4. writes items, gold, skill XP and the ledger in ONE transaction.
 * The client never names an item or an XP amount, so it can't mint either.
 *
 *   const { mountGathering } = require('./gathering/gathering-routes.cjs');
 *   const { createMysqlGatherStore } = require('./gathering/gather-store.cjs');
 *   mountGathering(app, { store: createMysqlGatherStore(pool), requireAuth: requireJWT, ownsCharacter });
 */
const rules = require('./gathering-rules.cjs');

/** Per-character request limiter (batches come every ~8 s; this only stops a runaway client). */
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

class PlayerError extends Error {}

/**
 * `isStaff(req)` (optional): staff accounts (accounts.role admin/gm or gm_enabled) skip the
 * node LEVEL check only — never ownership, the rate limit or the time budget. Their rolls use
 * the node's level as a floor; XP still lands on the real skill level.
 */
function createGatherHandlers({ store, ownsCharacter, isStaff = async () => false, logger = console, now = Date.now, rng = Math.random, perMinute = 30 }) {
  if (!store || !ownsCharacter) throw new Error('gathering: store and ownsCharacter are required');
  const allow = limiter(perMinute);
  const fail = (res, status, error) => res.status(status).json({ success: false, error });

  async function gather(req, res) {
    const body = req.body || {};
    const characterId = Number(body.characterId);
    if (!Number.isInteger(characterId) || characterId <= 0) return fail(res, 400, 'characterId is required');
    const def = rules.NODES[typeof body.nodeType === 'string' ? body.nodeType : ''];
    if (!def) return fail(res, 400, 'Unknown gathering node');
    const claimed = Math.floor(Number(body.actions));
    if (!Number.isFinite(claimed) || claimed < 1) return fail(res, 400, 'Nothing to gather');
    if (!(await ownsCharacter(req, characterId))) return fail(res, 403, 'That character is not yours');
    if (!allow(characterId)) return fail(res, 429, 'Too many requests — slow down');

    const staff = await isStaff(req).catch(() => false);
    try {
      const out = await store.withCharacter(characterId, async (tx) => {
        const skill = await tx.getSkill(def.skill);
        if (skill.level < def.level && !staff) throw new PlayerError(`Requires ${rules.SKILLS[def.skill].name} level ${def.level}`);
        const budget = rules.checkBudget(def, await tx.getLedger(), claimed, now(), body.afk === true);
        if (!budget.ok) throw new PlayerError(budget.error);
        const bag = await tx.getBag();
        // Tools are read from the bag here, never from the request.
        const toolTier = rules.toolTierFor(def.skill, bag.map((s) => s.itemId));
        const batch = rules.rollBatch(def, skill, budget.accepted, rng, toolTier, staff ? def.level : 0);
        const stacks = await tx.maxStacks(batch.items.map((g) => g.itemId));
        for (const g of batch.items) if (!stacks.has(g.itemId)) throw new PlayerError('This node is not available on the server yet');
        const placed = rules.placeItems(bag, batch.items, (id) => stacks.get(id));
        await tx.applyPlacement(placed);
        await tx.setSkill(def.skill, batch.progress);
        if (batch.gold > 0) await tx.addGold(batch.gold);
        await tx.setLedger(budget.ledger);
        return {
          node: def.id,
          skill: def.skill,
          accepted: budget.accepted,
          successes: batch.successes,
          xp: batch.xp,
          gold: batch.gold,
          items: placed.stored,
          rejected: placed.rejected,
          leveledUp: batch.leveled > 0,
          toolTier,
          skills: [{ profession_id: def.skill, skill_level: batch.progress.level, skill_xp: batch.progress.xp }],
        };
      });
      if (out && out.notFound) return fail(res, 404, 'Character not found');
      return res.status(200).json({ success: true, data: out });
    } catch (err) {
      if (err instanceof PlayerError) return fail(res, 400, err.message);
      logger.error('[gather]', err);
      return fail(res, 500, 'Server error — gathering not saved');
    }
  }

  async function startAfk(req, res) {
    const characterId = Number(req.body?.characterId);
    const def = rules.NODES[req.body?.nodeType];
    if (!Number.isInteger(characterId) || characterId <= 0 || !def) return fail(res, 400, 'Choose a gathering node.');
    if (!(await ownsCharacter(req, characterId))) return fail(res, 403, 'That character is not yours');
    if (!allow(characterId)) return fail(res, 429, 'Too many requests — slow down');
    const staff = await isStaff(req).catch(() => false);
    try {
      const out = await store.withCharacter(characterId, async tx => {
        const skill = await tx.getSkill(def.skill);
        if (skill.level < def.level && !staff) throw new PlayerError(`Requires ${rules.SKILLS[def.skill].name} level ${def.level}`);
        const ledger = await tx.getLedger();
        await tx.setLedger({ ...ledger, lastAt: now() });
        return { node: def.id };
      });
      if (out?.notFound) return fail(res, 404, 'Character not found');
      return res.status(200).json({ success: true, data: out });
    } catch (err) {
      if (err instanceof PlayerError) return fail(res, 400, err.message);
      logger.error('[afk gather]', err);
      return fail(res, 500, 'Could not start AFK gathering.');
    }
  }
  return { gather, startAfk };
}

function mountGathering(app, opts) {
  const h = createGatherHandlers(opts);
  if (!opts.requireAuth) throw new Error('gathering: requireAuth middleware is required');
  app.post('/api/gather', opts.requireAuth, h.gather);
  app.post('/api/gather/afk-start', opts.requireAuth, h.startAfk);
  return h;
}

module.exports = { createGatherHandlers, mountGathering, PlayerError };
