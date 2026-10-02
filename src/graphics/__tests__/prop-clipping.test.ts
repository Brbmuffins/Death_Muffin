import * as THREE from 'three';
import { afterAll, describe, expect, it, vi } from 'vitest';
import type { ModelTemplate } from '../AssetCache';
import { CREATURE_MODELS } from '../modelPaths';
import { accumulate, bodyCore, bodyPoints, creatureTemplate, emptyStats, propPoints } from './propHarness';
import { CAST_FLOW } from '../../content/combatFlow';
import type { AbilityId } from '../../content/abilities';

const store = vi.hoisted(() => ({ models: new Map<string, ModelTemplate>(), props: new Map<string, string>() }));
vi.mock('../AssetCache', () => ({
  assets: {
    model: async (url: string, height: number) => {
      const prop = [...store.props].find(([k]) => url.endsWith(k));
      if (prop) {
        const h = await import('./propHarness');
        return h.propTemplate(prop[1], height);
      }
      return store.models.get(url);
    },
  },
}));
vi.mock('../fxTextures', async () => {
  const THREE = await import('three');
  return { fx: new Proxy({}, { get: () => () => new THREE.Texture() }) };
});

const { NecromancerAvatar } = await import('../Avatars');

const PROP_FILES: Record<string, string> = {
  'gear_staff.glb': 'public/models/props/gear_staff.glb',
  'gear_scythe.glb': 'public/models/props/gear_scythe.glb',
  'gear_wand.glb': 'public/models/props/gear_wand.glb',
  'gear_sickle.glb': 'public/models/props/gear_sickle.glb',
  'gear_skull_focus.glb': 'public/models/props/gear_skull_focus.glb',
  'gear_grimoire.glb': 'public/models/props/gear_grimoire.glb',
  'gear_mourning_bell.glb': 'public/models/props/gear_mourning_bell.glb',
  'tool_hatchet.glb': 'public/models/props/tool_hatchet.glb',
  'tool_pickaxe.glb': 'public/models/props/tool_pickaxe.glb',
  'tool_fishing_rod.glb': 'public/models/props/tool_fishing_rod.glb',
  'tool_spade.glb': 'public/models/props/tool_spade.glb',
};
for (const [k, v] of Object.entries(PROP_FILES)) store.props.set(k, v);

type Scenario = { name: string; abilities: AbilityId[]; moving?: boolean };
const SCENARIOS: Scenario[] = [
  { name: 'idle', abilities: [] },
  { name: 'run', abilities: [], moving: true },
  { name: 'cast', abilities: ['bone_needle', 'marrow_spear'] },
  { name: 'big', abilities: ['corpse_explosion', 'black_litany', 'exhume'] },
];

async function measure(slug: 'hero_gravecaller' | 'hero_mourner' | 'hero_ossuary' | 'hero_rotweaver', main: string | null, off: string | null) {
  const tpl = await creatureTemplate(slug, CREATURE_MODELS[slug].height);
  tpl.skinned = true;
  store.models.set(CREATURE_MODELS[slug].url, tpl);
  store.models.set(CREATURE_MODELS.necromancer.url, await creatureTemplate('necromancer', CREATURE_MODELS.necromancer.height));
  const scene = new THREE.Scene();
  const avatar = new NecromancerAvatar(scene, '#a26bff', false, slug);
  await vi.waitFor(() => expect(avatar.c.loaded).toBe(true));
  const eq: Record<string, { item_id: string }> = {};
  if (main) eq.main_hand = { item_id: main };
  if (off) eq.off_hand = { item_id: off };
  avatar.setEquipment(eq);
  // Wait for the GLB models to replace the primitive stand-ins.
  await vi.waitFor(() => {
    const w = (avatar as unknown as { worn: Map<string, { obj: THREE.Object3D }> }).worn;
    for (const { obj } of w.values()) expect(obj.userData.model === true).toBe(true);
  });
  const worn = (avatar as unknown as { worn: Map<string, { obj: THREE.Object3D }> }).worn;
  const props = () => [...worn.entries()].map(([slot, w]) => [slot, w.obj] as const).filter(([s]) => s !== 'head');
  const staff = (avatar as unknown as { staff: THREE.Object3D | null }).staff;
  const out: Record<string, Record<string, ReturnType<typeof emptyStats>>> = {};
  let x = 0;
  const dt = 1 / 60;
  const sink: Record<string, ReturnType<typeof emptyStats>> = {};
  const step = (moving: boolean, label: string, slotStats: Record<string, ReturnType<typeof emptyStats>>) => {
    x += moving ? 5.2 * dt : 0;
    avatar.update(dt, x, 0, 0.8, moving, 5.2);
    avatar.c.root.updateMatrixWorld(true);
    if (slotStats === sink) return;
    const parts: [string, THREE.Object3D][] = props().map(([s, o]) => [s, o]);
    if (!main && staff?.visible) parts.push(['main_hand', staff]);
    if (slotStats === sink) return;
    const core = bodyCore(avatar.c.root);
    const surface = bodyPoints(avatar.c.root, 8);
    const pts = new Map(parts.map(([slot, obj]) => [slot, propPoints(obj, 100)] as const));
    for (const [slot] of parts) accumulate((slotStats[slot] ??= emptyStats()), core, surface, pts.get(slot)!, slot === 'off_hand' ? pts.get('main_hand') : undefined);
    void label;
  };
  for (const sc of SCENARIOS) {
    const stats: Record<string, ReturnType<typeof emptyStats>> = {};
    for (let i = 0; i < 40; i++) step(false, sc.name, sink);
    if (sc.moving) {
      for (let i = 0; i < 20; i++) step(true, sc.name, sink);
      for (let i = 0; i < 90; i++) step(true, sc.name, stats);
    } else if (!sc.abilities.length) {
      for (let i = 0; i < 90; i++) step(false, sc.name, stats);
    } else {
      for (const a of sc.abilities) {
        avatar.cast(a === 'exhume' ? 'dig' : 'cast', 2, 0.8, CAST_FLOW[a].gestureSeconds, a);
        for (let i = 0; i < 70; i++) step(false, sc.name, stats);
        for (let i = 0; i < 30; i++) step(false, sc.name, sink);
      }
    }
    out[sc.name] = stats;
  }
  avatar.dispose();
  return out;
}

const REPORT = !!process.env.PROP_REPORT;

describe('held props clear the body', () => {
  const rows: string[] = [];
  const CASES: [string, string | null, string | null][] = [
    ['skull staff (default)', null, null],
    ['staff', 'staff_gold', null],
    ['scythe', 'scythe_gold', null],
    ['wand', 'wand_gold', null],
    ['sickle', 'sickle_gold', null],
    ['wand + skull focus', 'wand_gold', 'skull_focus_gold'],
    ['wand + grimoire', 'wand_gold', 'grimoire_gold'],
    ['wand + bell', 'wand_gold', 'mourning_bell_gold'],
  ];
  it.each(CASES)('%s', async (name, main, off) => {
    const res = await measure('hero_gravecaller', main, off);
    for (const [sc, slots] of Object.entries(res)) {
      for (const [slot, s] of Object.entries(slots)) {
        rows.push(`${name.padEnd(24)} ${sc.padEnd(5)} ${slot.padEnd(9)} buried ${(s.deep * 100).toFixed(1).padStart(5)}% (max ${s.maxDepth.toFixed(3)})  on-cloth ${(s.touching * 100).toFixed(1).padStart(5)}%  vs-main ${(s.cross * 100).toFixed(1).padStart(5)}%`);
        expect(s.frames).toBeGreaterThan(0);
        // Budget: at most 1.5% of a prop's vertices buried in the body core, none deeper than 7 cm.
        expect(s.deep, `${name} ${sc} ${slot}`).toBeLessThan(0.015);
        expect(s.maxDepth, `${name} ${sc} ${slot}`).toBeLessThan(0.07);
      }
    }
  }, 60_000);
  afterAll(() => {
    if (REPORT) console.log('\n' + rows.join('\n'));
  });
});


async function measureTool(slug: 'hero_gravecaller' | 'hero_mourner', skill: 'woodcutting' | 'mining' | 'fishing' | 'gravedigging') {
  const tpl = await creatureTemplate(slug, CREATURE_MODELS[slug].height);
  tpl.skinned = true;
  store.models.set(CREATURE_MODELS[slug].url, tpl);
  store.models.set(CREATURE_MODELS.necromancer.url, await creatureTemplate('necromancer', CREATURE_MODELS.necromancer.height));
  const avatar = new NecromancerAvatar(new THREE.Scene(), '#a26bff', false, slug);
  await vi.waitFor(() => expect(avatar.c.loaded).toBe(true));
  avatar.setGatheringTool(skill, 3);
  const tools = (avatar as unknown as { gatheringTools: Map<string, THREE.Object3D> }).gatheringTools;
  await vi.waitFor(() => expect(tools.has(skill)).toBe(true));
  const obj = tools.get(skill)!;
  const stats = emptyStats();
  const dt = 1 / 60;
  const gesture = skill === 'woodcutting' || skill === 'mining' ? 'attack' : 'dig';
  for (let i = 0; i < 40; i++) avatar.update(dt, 0, 0, 0.8, false, 5.2);
  for (let swing = 0; swing < 3; swing++) {
    avatar.cast(gesture, 1, 0.8, 0.8);
    for (let i = 0; i < 60; i++) {
      avatar.update(dt, 0, 0, 0.8, false, 5.2);
      avatar.c.root.updateMatrixWorld(true);
      accumulate(stats, bodyCore(avatar.c.root), bodyPoints(avatar.c.root, 8), propPoints(obj, 100));
    }
  }
  avatar.dispose();
  return stats;
}

describe('gathering tools clear the body', () => {
  const rows: string[] = [];
  it.each(['woodcutting', 'mining', 'fishing', 'gravedigging'] as const)('%s', async (skill) => {
    const s = await measureTool('hero_gravecaller', skill);
    rows.push(`tool ${skill.padEnd(13)} buried ${(s.deep * 100).toFixed(1).padStart(5)}% (max ${s.maxDepth.toFixed(3)})  on-cloth ${(s.touching * 100).toFixed(1).padStart(5)}%`);
    expect(s.frames).toBeGreaterThan(0);
    expect(s.deep, skill).toBeLessThan(0.01);
    expect(s.maxDepth, skill).toBeLessThan(0.07);
  }, 60_000);
  afterAll(() => {
    if (REPORT) console.log('\n' + rows.join('\n'));
  });
});
