/** Canonical whole-world snapshot used by the sim fixture generators (the GDScript twin is tests/sim/scenario_runner.gd: keep the field lists in sync). */
type Any = any; // eslint-disable-line @typescript-eslint/no-explicit-any
// --- Canonical snapshot (the same field lists live in tests/sim/scenario_runner.gd) -------------------------------------------------------
export type K = 'n' | 's' | 'b' | 'id' | 'v' | 'm' | 'e';
export const ENEMY_F: [string, K][] = [['id', 'n'], ['def', 's'], ['area', 's'], ['level', 'n'], ['elite', 'b'], ['x', 'n'], ['z', 'n'], ['facing', 'n'], ['hp', 'n'], ['maxHp', 'n'], ['damage', 'n'], ['speed', 'n'], ['radius', 'n'], ['scale', 'n'], ['state', 's'], ['stateT', 'n'], ['attackCd', 'n'], ['targetPlayer', 's'], ['targetThrall', 'id'], ['aimX', 'n'], ['aimZ', 'n'], ['channelCorpse', 'id'], ['flankSide', 'n'], ['fracture', 'n'], ['fractureT', 'n'], ['withered', 'n'], ['witheredT', 'n'], ['witheredDps', 'n'], ['witheredOwner', 's'], ['contagious', 'b'], ['slowT', 'n'], ['wardSlowT', 'n'], ['lastHitBy', 's'], ['flash', 'n'], ['gait', 'n'], ['moving', 'b'], ['bleedT', 'n'], ['bleedDps', 'n'], ['bleedOwner', 's'], ['chillT', 'n'], ['sanctT', 'n'], ['hexT', 'n'], ['silenceT', 'n'], ['stunT', 'n'], ['rootT', 'n'], ['incenseT', 'n'], ['knellBeats', 'n'], ['knellNext', 'n'], ['knellOwner', 's'], ['knellDamage', 'n'], ['hexOwner', 's'], ['diving', 'b'], ['diveX', 'n'], ['diveZ', 'n'], ['groundT', 'n'], ['hooking', 'b'], ['hookCd', 'n'], ['fleeT', 'n'], ['erupting', 'v'], ['dugIn', 'b'], ['digPending', 'b'], ['burrowLeft', 'v'], ['unbindCd', 'n'], ['unboundBy', 'id'], ['blockFxAt', 'n'], ['auraCd', 'n'], ['affix', 's'], ['affixCd', 'v'], ['tollAt', 'v'], ['markT', 'n'], ['markBonus', 'n'], ['markBy', 's'], ['plagueAt', 'n'], ['extra', 'v']];
export const THRALL_F: [string, K][] = [['id', 'n'], ['owner', 's'], ['kind', 's'], ['x', 'n'], ['z', 'n'], ['facing', 'n'], ['hp', 'n'], ['maxHp', 'n'], ['damage', 'n'], ['attackInterval', 'n'], ['range', 'n'], ['speed', 'n'], ['state', 's'], ['stateT', 'n'], ['attackCd', 'n'], ['target', 'id'], ['slot', 'n'], ['bornAt', 'n'], ['empowered', 'b'], ['flash', 'n'], ['gait', 'n'], ['moving', 'b'], ['rallyT', 'n'], ['champion', 'b'], ['echoUntil', 'e'], ['allyHeal', 'n'], ['cursedT', 'n'], ['stallT', 'n'], ['nextPathAt', 'n'], ['detourUntil', 'n'], ['seatX', 'v'], ['seatZ', 'v']];
export const CORPSE_F: [string, K][] = [['id', 'n'], ['x', 'n'], ['z', 'n'], ['kind', 's'], ['enemy', 's'], ['elite', 'b'], ['facing', 'n'], ['scale', 'n'], ['area', 's'], ['bornAt', 'n'], ['expiresAt', 'n'], ['ruptureAt', 'm'], ['seedOwner', 's'], ['seedDmg', 'n'], ['seedCap', 'n'], ['seedArmedAt', 'm'], ['seedExpires', 'n'], ['echoOwner', 's']];
export const BOSS_F: [string, K][] = [['id', 's'], ['active', 'b'], ['x', 'n'], ['z', 'n'], ['facing', 'n'], ['hp', 'n'], ['maxHp', 'n'], ['phase', 'n'], ['state', 's'], ['stateT', 'n'], ['flash', 'n'], ['fracture', 'n'], ['fractureT', 'n'], ['withered', 'n'], ['witheredT', 'n'], ['witheredDps', 'n'], ['level', 'n'], ['empowered', 'b']];
export const ZONE_F: [string, K][] = [['id', 'n'], ['kind', 's'], ['owner', 's'], ['x', 'n'], ['z', 'n'], ['r', 'n'], ['until', 'n'], ['bornAt', 'n'], ['tick', 'n'], ['dps', 'n'], ['slow', 'n'], ['witheredCap', 'n'], ['bloom', 'b'], ['hostile', 'b'], ['creep', 'n'], ['contagion', 'b'], ['gen', 'm'], ['spreadT', 'm']];

export function norm(v: Any, k: K): Any {
  switch (k) {
    case 'n': return typeof v === 'number' ? v : 0;
    case 's': return typeof v === 'string' ? v : '';
    case 'b': return !!v;
    case 'id': return typeof v === 'number' ? v : -1;
    case 'e': return typeof v === 'number' ? v : -1;
    case 'm': return typeof v === 'number' && Number.isFinite(v) ? v : -1;
    default: return v === undefined ? null : v;
  }
}
export function pickFields(o: Any, fields: [string, K][]) {
  const out: Any = {};
  for (const [f, k] of fields) {
    let v = o[f];
    if (f === 'extra') v = (o.extra ?? []).map((x: Any) => ({ affix: x.affix, affixCd: x.affixCd ?? null, tollAt: x.tollAt ?? null }));
    if (f === 'tollAt') v = o.tollAt ?? null;
    out[f] = norm(v, k);
  }
  return out;
}
export const evKey = (ev: Any) => `${ev.t}|${ev.kind ?? ''}|${ev.reason ?? ''}|${ev.from ?? ''}|${ev.id ?? ev.corpse?.id ?? ev.zone?.id ?? ev.corpseId ?? ''}|${ev.player ?? ''}`;

export function snapshot(sim: Any, rngCalls: number, evs: string[]) {
  const sorted = <T extends { id: number }>(a: T[]) => [...a].sort((x, y) => x.id - y.id);
  const run = sim.depths;
  return {
    time: sim.time, nextId: sim.nextId, rngCalls, surgeIn: sim.surgeIn,
    enemies: sorted([...sim.enemies.values()] as Any[]).map((e) => pickFields(e, ENEMY_F)),
    thralls: sorted([...sim.thralls.values()] as Any[]).map((t) => ({ ...pickFields(t, THRALL_F), detourN: t.detour?.length ?? 0 })),
    corpses: sorted([...sim.corpses.values()] as Any[]).map((c) => pickFields(c, CORPSE_F)),
    zones: sorted([...sim.zones.values()] as Any[]).map((z) => pickFields(z, ZONE_F)),
    walls: sorted([...sim.walls.values()] as Any[]).map((w) => ({ id: w.id, owner: w.owner, x0: w.x0, z0: w.z0, x1: w.x1, z1: w.z1, until: w.until })),
    brands: [...sim.brands.entries()].map(([id, b]: Any) => ({ id, owner: b.owner, x: b.x, z: b.z, area: b.area, until: b.until })),
    surge: sim.surge ? { area: sim.surge.area, x: sim.surge.x, z: sim.surge.z, wavesSpawned: sim.surge.wavesSpawned, spawned: sim.surge.spawned, killed: sim.surge.killed, ids: sim.surge.ids.size } : null,
    waveTimers: [...sim.waveTimers.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    waveCounts: [...sim.waveCounts.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    vacantS: [...sim.vacantS.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    arrivedAt: [...sim.arrivedAt.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    nodes: [...sim.nodes.values()].map((n: Any) => [n.id, n.remaining, n.respawnAt]),
    depths: run ? { depth: run.depth, need: run.need, kills: run.kills, stairOpen: run.stairOpen, floorT: run.floorT, waveT: run.waveT, waved: run.waved, peak: run.peak, floors: run.floors, totalKills: run.totalKills } : null,
    raised: [...sim.raised.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    players: [...sim.players.values()].map((p: Any) => [p.id, p.x, p.z, p.alive, p.area ?? '']),
    bossId: sim.bossId, boss: pickFields(sim.boss.state, BOSS_F),
    events: evs,
  };
}

