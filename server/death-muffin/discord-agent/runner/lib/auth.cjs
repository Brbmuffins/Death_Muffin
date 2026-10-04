'use strict';
const { approversFor } = require('./tiers.cjs');
// Who may do what. Pure functions + an in-memory rate limiter with an injectable clock (for tests).
function createAuth(cfg, now = () => Date.now()) {
  const hits = new Map();   // key -> [timestamps]
  const P = cfg.project;
  const inAny = (id) => P.requesters.includes(id) || ['casual', 'gameplay', 'sensitive'].some((t) => P.approvers[t].includes(id));
  const roleOf = (id) => {
    id = String(id || '');
    if (cfg.ownerIds.includes(id)) return 'owner';
    if (['casual', 'gameplay', 'sensitive'].some((t) => P.approvers[t].includes(id))) return 'approver';
    if (inAny(id)) return 'member';
    return null;
  };
  const canApprove = (id, tier) => approversFor(tier, cfg).includes(String(id || ''));
  const isOwner = (id) => cfg.ownerIds.includes(String(id || ''));
  // Full approver: owner or anyone who may approve sensitive changes. Limited: approves some tiers only.
  const isFull = (id) => isOwner(id) || canApprove(id, 'sensitive');
  // Highest tier this user may approve, counting only unbroken coverage from casual upward.
  const maxTier = (id) => (canApprove(id, 'casual') ? (canApprove(id, 'gameplay') ? (canApprove(id, 'sensitive') ? 'sensitive' : 'gameplay') : 'casual') : null);
  return {
    roleOf, isOwner, isFull, maxTier, canApprove,
    isAllowed: (id) => roleOf(id) !== null,
    canSwitchModel: (id) => isFull(id),
    canDiscard: (id, job, tier) => isFull(id) || String(id) === String(job.creatorId) || canApprove(id, tier || 'sensitive'),
    // Sliding-window limiter: returns true (and records the hit) if under the limit.
    rate(key, limit, windowMs) {
      const t = now(); const arr = (hits.get(key) || []).filter((x) => t - x < windowMs);
      if (arr.length >= limit) { hits.set(key, arr); return false; }
      arr.push(t); hits.set(key, arr); return true;
    },
    // Casual ships already made today (UTC) by this approver, from the ships log records.
    shipsToday(id, ships) {
      const day = new Date(now()).toISOString().slice(0, 10);
      return ships.filter((s) => s.type === 'live' && s.approverId === String(id) && String(s.ts).slice(0, 10) === day).length;
    },
  };
}
module.exports = { createAuth };
