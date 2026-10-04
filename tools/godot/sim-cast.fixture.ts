/**
 * Caster-path fixtures for godot/sim/sim_caster.gd: the REAL AbilitySystem (+ NewBloodSystem, Player, Effects projectile flight) casts into the
 * REAL WorldSim with scripted player movement and Math.random pinned to a constant. Every cast (id, target, result), the intents sent, the damage
 * numbers floated, the player state and the world are recorded; tests/sim/cast_runner.gd replays the casts against DmSimCaster + DmWorldSim and
 * must match. Run: npx vitest run --config tools/godot/vitest.sim.config.ts (vitest: same module mocks as src/gameplay/__tests__).
 */
import * as THREE from 'three';
import { describe, it, vi } from 'vitest';
import { mkdirSync, writeFileSync } from 'node:fs';

vi.mock('../../src/audio/Audio', () => ({ audio: { play: vi.fn(), loop: vi.fn(() => () => undefined) } }));
vi.mock('../../src/graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../../src/graphics/fxImages', () => ({ fxImage: () => new THREE.Texture() }));

import { AbilitySystem, veilTarget, type AbilityContext } from '../../src/gameplay/AbilitySystem';
import { Player } from '../../src/gameplay/Player';
import { Effects } from '../../src/graphics/Effects';
import { WorldSim } from '../../src/gameplay/sim/WorldSim';
import { BossBrain } from '../../src/gameplay/sim/BossBrain';
import { mulberry32 } from '../../src/gameplay/rng';
import { DISCIPLINES } from '../../src/content/disciplines';
import { AREAS, type AreaId } from '../../src/content/areas';
import { ABILITIES } from '../../src/content/abilities';
import { resolveWeaponLoadout } from '../../src/gameplay/weaponLine';
import { WORLD, worldNav, ALL_OPEN } from './sim-fixture-lib';
import { exactStringify } from './exact-json';
import { snapshot } from './sim-snapshot';

const OUT = 'godot/tests/sim/fixtures';
mkdirSync(OUT, { recursive: true });
type Any = any; // eslint-disable-line @typescript-eslint/no-explicit-any

class StubBrain extends BossBrain {
  protected onAwaken() {}
  protected onPhase() {}
  protected think() {}
}

const NECRO = ['bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany', 'corpse_explosion', 'wailing_skull', 'grave_step', 'grave_frost', 'bone_mantle', 'bone_fan', 'rot_lance', 'grave_offering', 'ivory_cleave', 'rally_dead', 'carrion_seed', 'soul_siphon', 'bone_prison', 'grave_hands', 'bone_storm', 'ossuary_wall', 'command_rend', 'dirge', 'plague_bloom', 'veil_step'];
const KNIGHT = ['hollow_cut', 'shield_bash', 'grave_slam', 'bulwark', 'corpse_vigil', 'grave_brand', 'oath_unbroken', 'bone_needle'];
const WARDEN = ['flail_swing', 'lantern_cone', 'chain_pull', 'burn_the_dead', 'watchmans_ward', 'cremate', 'last_light', 'bone_needle'];
const MONK = ['palm_strike', 'toll', 'resonant_step', 'knell', 'choir_of_one', 'sound_the_corpse', 'great_toll', 'bone_needle'];
const WITCH = ['hook_throw', 'harvest', 'crow_swarm', 'hook_pull', 'hex_charm', 'butcher', 'murder_of_crows', 'bone_needle'];
const VEIL = ['spirit_bolt', 'veil_form', 'echo', 'veil_tear', 'crossing', 'lay_to_rest', 'between_worlds', 'veil_step', 'bone_needle'];

interface Cfg {
  name: string; seed: number; discipline: string; level: number; worn: { main_hand?: string; off_hand?: string }; runes: Record<string, string>;
  mathRandom: number; area: AreaId; abilities: string[]; mods?: Record<string, unknown>; boss?: boolean; ticks?: number; every?: number;
}

function run(cfg: Cfg) {
  const ticks = cfg.ticks ?? 1600, every = cfg.every ?? 40, dt = 0.05;
  const bot = mulberry32(cfg.seed ^ 0x9e3779b1);
  const BR = (n: number) => Math.floor(bot() * n);
  const BP = <T,>(a: readonly T[]): T => a[BR(a.length)];
  const BRange = (lo: number, hi: number) => lo + bot() * (hi - lo);
  vi.spyOn(Math, 'random').mockReturnValue(cfg.mathRandom);

  const nav = worldNav(ALL_OPEN);
  const simRand = mulberry32(cfg.seed);
  let rngCalls = 0;
  const sim: Any = new WorldSim(nav, () => { rngCalls++; return simRand(); });
  if (cfg.boss) for (const id of Object.keys(sim.bosses)) sim.bosses[id] = new StubBrain(sim, id as Any);
  sim.waveTier = 2;
  sim.setCrypts(WORLD.crypts);
  const disc = { ...(DISCIPLINES as Any)[cfg.discipline] } as Any;
  disc.mods = { ...disc.mods, ...(cfg.mods ?? {}) };
  const family = disc.family as string;
  const stats = { level: cfg.level, maxHp: 800, spellPower: 70, maxEssence: 200, essenceRegen: 6, moveSpeed: 5.4, thrallHp: 160, thrallDamage: 22, damageBonusPct: 0 };
  const player = new Player(stats as Any, nav, family as Any);
  player.hp = stats.maxHp * 0.5;
  const rect = AREAS[cfg.area].rect;
  player.x = (rect.x0 + rect.x1) / 2;
  player.z = (rect.z0 + rect.z1) / 2;
  player.area = cfg.area;
  const worn: Any = {};
  if (cfg.worn.main_hand) worn.main_hand = { item_id: cfg.worn.main_hand };
  if (cfg.worn.off_hand) worn.off_hand = { item_id: cfg.worn.off_hand };
  player.loadout = resolveWeaponLoadout(worn, cfg.discipline);
  player.runes = { ...cfg.runes } as Any;
  const effects = new Effects(new THREE.Scene());
  const camera = new THREE.PerspectiveCamera();
  let sent: Any[] = [], numbers: Any[] = [], notes: Any[] = [], casts: Any[] = [];
  let nowMs = 0;
  let aimPoint = { x: player.x, z: player.z };
  const avatar = { tip: () => new THREE.Vector3(player.x, 1.4, player.z), cast: () => undefined };
  const ctx = {
    selfId: 'p1', player, discipline: disc, avatar, effects,
    enemies: () => sim.enemies, boss: () => sim.boss.state, corpses: () => sim.corpses,
    thrallCount: () => [...sim.thralls.values()].filter((t: Any) => t.owner === 'p1' && t.state !== 'dead').length,
    send: (i: Any) => { sent.push(JSON.parse(JSON.stringify(i))); sim.apply(i); },
    number: (x: number, z: number, amount: number, kind: string) => numbers.push({ x, z, amount, kind }),
    shake: () => undefined, note: (text: string, kind: string) => notes.push({ text, kind }),
    now: () => nowMs, thralls: () => sim.thralls,
    dash: (tx: number, tz: number) => veilTarget(nav, player.x, player.z, tx, tz),
    aim: () => aimPoint,
  } as unknown as AbilityContext;
  const abilities = new AbilitySystem(ctx);
  const follow = () => (player.alive ? player : null);
  // WorldScene.handleEvent, for the events that reach the caster.
  const handle = (ev: Any) => {
    const mine = ev.by === 'p1';
    switch (ev.t) {
      case 'mantle': abilities.onMantle(ev, mine, follow); break;
      case 'offering': abilities.onOffering(ev, mine, follow); break;
      case 'newBlood':
        if (ev.kind === 'heal' && ev.player === 'p1' && ev.amount) player.heal(player.stats.maxHp * ev.amount);
        abilities.onNewBlood(ev, mine);
        break;
      case 'heal':
        if (ev.player === 'p1' && player.alive) player.heal(ev.frac ? player.stats.maxHp * ev.frac : ev.amount);
        break;
      case 'exhumed':
        if (mine) {
          if (!ev.ok) { player.essence = Math.min(player.stats.maxEssence, player.essence + (ABILITIES as Any).exhume.essenceCost); player.cooldowns.delete('exhume'); }
          else { abilities.onCorpseConsumed(); if (disc.mods.corpseHeal) player.heal(player.stats.maxHp * disc.mods.corpseHeal); }
        }
        break;
      case 'litanyResult': abilities.onLitany(ev, mine); break;
      case 'detonated':
        if (ev.ok) abilities.onDetonated(ev, mine);
        else if (mine) { player.essence = Math.min(player.stats.maxEssence, player.essence + (ABILITIES as Any).corpse_explosion.essenceCost); player.cooldowns.delete('corpse_explosion'); }
        break;
      case 'death':
        if (ev.killer === 'p1' && player.alive) player.addSouls(1 + abilities.reapedSouls(ev.id));
        break;
      default: break;
    }
  };

  const bodyOf = () => ({ id: 'p1', x: player.x, z: player.z, alive: player.alive, area: player.area, family, level: cfg.level });
  const ally = { id: 'p2', x: player.x + 3, z: player.z + 2, alive: true, area: cfg.area, level: 10 };
  const script: Any[] = [];
  const checkpoints: Any[] = [];
  const foesOf = () => [...sim.enemies.values()].filter((e: Any) => e.area === player.area && e.state !== 'dead' && e.state !== 'burrow' && e.state !== 'rising');
  let wp = { x: player.x, z: player.z };
  const evs: string[] = [];
  const stateOf = () => ({
    x: player.x, z: player.z, facing: player.facing, hp: player.hp, barrier: player.barrier, barrierPeak: player.barrierPeak, barrierHoldUntil: player.barrierHoldUntil,
    resource: player.resource.value, castUntil: player.castUntil, rootedUntil: player.rootedUntil, souls: player.souls, unbreakableUntil: player.unbreakableUntil,
    bulwarkUntil: player.bulwarkUntil, bulwarkPerfectUntil: player.bulwarkPerfectUntil, veilForm: player.veilForm, betweenUntil: player.betweenUntil,
    area: player.area ?? '', alive: player.alive, cooldowns: [...player.cooldowns.entries()].sort(([a], [b]) => (a < b ? -1 : 1)),
    wisps: abilities.wispCount,
  });

  for (let tick = 0; tick < ticks; tick++) {
    nowMs = (tick + 1) * 50;
    const step: Any = { tick, body: null, sets: {}, casts: [], intents: [] };
    // Scripted player state.
    if (tick % 15 === 0) { player.resource.value = player.resource.max; step.sets.resource = player.resource.max; }
    if (tick === 350 || tick === 900 || tick === 1300) { player.souls = player.soulsMax; step.sets.souls = player.soulsMax; }
    if (tick === 700) { player.alive = false; step.sets.alive = false; }
    if (tick === 720) { player.alive = true; step.sets.alive = true; step.sets.hp = player.stats.maxHp * 0.5; player.hp = player.stats.maxHp * 0.5; }
    if (cfg.boss && tick === 30) step.intents.push({ t: 'summonBoss', by: 'p1', boss: 'prelate' });
    // Movement: hunt the nearest foe, else patrol.
    const foes = foesOf();
    let near: Any = null, nd = Infinity;
    for (const e of foes) { const d = Math.hypot(e.x - player.x, e.z - player.z); if (d < nd) { nd = d; near = e; } }
    if (player.alive) {
      if (near && nd > 7) wp = { x: near.x, z: near.z };
      else if (Math.hypot(wp.x - player.x, wp.z - player.z) < 1) wp = { x: rect.x0 + 4 + bot() * (rect.x1 - rect.x0 - 8), z: rect.z0 + 4 + bot() * (rect.z1 - rect.z0 - 8) };
      const d = Math.hypot(wp.x - player.x, wp.z - player.z);
      if (d > 0.01) {
        const s = Math.min(d, 4.6 * dt);
        const [nx, nz] = nav.resolve(player.x + ((wp.x - player.x) / d) * s, player.z + ((wp.z - player.z) / d) * s, 0.45);
        player.x = nx; player.z = nz;
      }
      player.area = nav.areaAt(player.x, player.z) ?? player.area;
    }
    aimPoint = near ? { x: near.x, z: near.z } : { x: player.x + 3, z: player.z };
    step.body = bodyOf();
    step.aim = aimPoint;
    sim.setPlayer({ ...step.body });
    if (tick === 0) sim.setPlayer({ ...ally });
    for (const i of step.intents) sim.apply(i);
    // Casts.
    if (tick % 4 === 1) {
      const n = BR(3) === 0 ? 2 : 1;
      for (let k = 0; k < n; k++) {
        const ready = cfg.abilities.filter((id) => abilities.ready(id as Any, nowMs));
        const id = (ready.length && BR(10) < 8 ? BP(ready) : BP(cfg.abilities)) as string;
        const corpses = [...sim.corpses.values()].filter((c: Any) => c.area === player.area);
        let nc: Any = null, cd = Infinity;
        for (const c of corpses) { const d = Math.hypot(c.x - player.x, c.z - player.z); if (d < cd) { cd = d; nc = c; } }
        let target: Any;
        const b = sim.boss.state;
        if (cfg.boss && b.active && BR(3) === 0) target = { x: b.x, z: b.z, boss: true };
        else if (near && BR(6) !== 0) target = { x: near.x, z: near.z, enemyId: near.id };
        else if (nc && BR(2) === 0) target = { x: nc.x + BRange(-0.4, 0.4), z: nc.z + BRange(-0.4, 0.4) };
        else target = { x: player.x + BRange(-9, 9), z: player.z + BRange(-9, 9) };
        const result = abilities.cast(id as Any, target, nowMs);
        step.casts.push({ id, target, result });
        casts.push({ id, result });
      }
    }
    abilities.update(nowMs);
    effects.update(dt, camera, 720);
    const events = sim.step(dt);
    for (const ev of events) { handle(ev); evs.push(`${ev.t}|${ev.kind ?? ''}`); }
    script.push(step);
    if ((tick + 1) % every === 0) {
      checkpoints.push({ tick: tick + 1, world: snapshot(sim, rngCalls, evs.splice(0)), player: stateOf(), sent, numbers, notes, casts });
      sent = []; numbers = []; notes = []; casts = [];
    }
  }
  const setup = {
    seed: cfg.seed, discipline: cfg.discipline, family, level: cfg.level, mods: disc.mods, stats, loadout: player.loadout, runes: cfg.runes, area: cfg.area, boss: !!cfg.boss,
    mathRandom: cfg.mathRandom, ticks, every, dt, hp0: stats.maxHp * 0.5, start: { x: (rect.x0 + rect.x1) / 2, z: (rect.z0 + rect.z1) / 2 }, ally, discipline_id: cfg.discipline,
  };
  writeFileSync(`${OUT}/cast_${cfg.name}.json`, exactStringify({ cast: cfg.name, setup, script, checkpoints }) + '\n');
  vi.restoreAllMocks();
  return { casts: script.reduce((n, s) => n + s.casts.length, 0), ok: script.reduce((n, s) => n + s.casts.filter((c: Any) => c.result === 'ok').length, 0), rngCalls };
}

const RUNES_A = { bone_needle: 'rune_splinter', marrow_spear: 'rune_ossuary_ring', exhume: 'rune_mass_grave', miasma: 'rune_creeping_rot', black_litany: 'rune_hollow_choir' };
const RUNES_B = { bone_needle: 'rune_marrow_tap', marrow_spear: 'rune_impale', exhume: 'rune_bone_colossus', miasma: 'rune_contagion', black_litany: 'rune_requiem' };
const RUNES_C = { bone_needle: 'rune_volley' };
const LEG = { corpseWisp: 8, wraithNova: 0.5, litanyShatter: 1, spearRally: 1, miasmaBurstsCorpses: true, corpseHeal: 0.03, litanyBarrier: 0.05, witheredBurstAt: 4 };

const CFGS: Cfg[] = [
  { name: 'necro_staff_runesA', seed: 11, discipline: 'ossuary', level: 30, worn: { main_hand: 'staff_gold', off_hand: 'skull_focus_gold' }, runes: RUNES_A, mathRandom: 0.5, area: 'graves', abilities: NECRO },
  { name: 'necro_scythe_runesB', seed: 12, discipline: 'gravecaller', level: 30, worn: { main_hand: 'scythe_hell', off_hand: 'grimoire_gold' }, runes: RUNES_B, mathRandom: 0.05, area: 'graves', abilities: NECRO },
  { name: 'necro_wand_volley', seed: 13, discipline: 'mourner', level: 30, worn: { main_hand: 'wand_iron', off_hand: 'mourning_bell_gold' }, runes: RUNES_C, mathRandom: 0.93, area: 'ossuary', abilities: NECRO },
  { name: 'necro_sickle_legend', seed: 14, discipline: 'rotweaver', level: 30, worn: { main_hand: 'sickle_moon' }, runes: {}, mathRandom: 0.5, area: 'graves', abilities: NECRO, mods: LEG },
  { name: 'necro_staff_boss', seed: 15, discipline: 'ossuary', level: 30, worn: { main_hand: 'staff_hell' }, runes: RUNES_A, mathRandom: 0.3, area: 'sanctum', abilities: NECRO, boss: true, mods: LEG },
  { name: 'necro_scythe_boss', seed: 16, discipline: 'gravecaller', level: 30, worn: { main_hand: 'scythe_gold' }, runes: { bone_needle: 'rune_splinter', marrow_spear: 'rune_impale' }, mathRandom: 0.07, area: 'sanctum', abilities: NECRO, boss: true },
  { name: 'knight', seed: 21, discipline: 'hollow_knight', level: 30, worn: {}, runes: {}, mathRandom: 0.5, area: 'graves', abilities: KNIGHT },
  { name: 'warden', seed: 22, discipline: 'grave_warden', level: 30, worn: {}, runes: {}, mathRandom: 0.5, area: 'graves', abilities: WARDEN },
  { name: 'monk', seed: 23, discipline: 'bell_monk', level: 30, worn: {}, runes: {}, mathRandom: 0.5, area: 'graves', abilities: MONK },
  { name: 'witch', seed: 24, discipline: 'carrion_witch', level: 30, worn: {}, runes: {}, mathRandom: 0.5, area: 'graves', abilities: WITCH },
  { name: 'veil', seed: 25, discipline: 'veilwalker', level: 30, worn: {}, runes: {}, mathRandom: 0.5, area: 'graves', abilities: VEIL },
];

describe('sim cast fixtures', () => {
  for (const c of CFGS) it(c.name, () => { const r = run(c); console.log(`cast_${c.name}`, r); });
});
